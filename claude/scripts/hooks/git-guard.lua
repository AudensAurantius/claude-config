#!/usr/bin/env lua
--[[
git-guard PreToolUse hook (ClaudeConfig-bi0.1; DEC-017 Lua port of the
git-guard handoff doc's Python design).

Foundation tier ("C1") — establishes the structure all sibling beads
build on:
- Fast-bail on non-git Bash commands (this hook fires on every Bash
  call, must finish in ms when it has no work).
- Tokenize the command (single+double quote handling, escapes), split
  on shell separators (`&&`, `||`, `;`, `|`), find every git
  invocation, identify each verb past env-var prefixes + git-level
  flags (`-C`, `--git-dir`, `--work-tree`, `-c`).
- Safe-verb fast-allow for read-only / informational verbs and the
  benign subforms of `branch`/`tag`/`config`/`remote`.
- Gated verbs return "ask" (C1 uniform behavior; C2+ refine with
  protected-branch resolution, ref-rewriting denylist, etc.).
- Loads ~/.claude/hooks/git-guard.yaml when present; missing config
  is OK (built-in defaults). Parse failures or lyaml-unavailable →
  fail-safe to "ask" on gated verbs (never silently allow).

Guardrail, not a sandbox. Command-string inspection is defeatable
(`cd x && git ...`, env-var prefixes, `eval`, write-a-script-then-
run-it, base64). The value is stopping *accidental* canonical-branch
commits and surfacing *anomalous* commands — not defending against a
determined adversary. See handoff doc §8 for the honest framing.
]]

local lib = require("_lib")
local git = require("_git")

--- @alias git_guard.Decision "allow"|"ask"|"deny"
--- @alias git_guard.ProtectedSource "per_repo"|"global"|"origin_head"|"none"
--- @alias git_guard.VerbClass "safe"|"gated"

--- @class git_guard.HookPayload
--- @field tool_input { command: string? }?
--- @field cwd string?

--- @class git_guard.PathFlag
--- @field flag "-C"|"--git-dir"|"--work-tree"
--- @field target string the path the flag relocated git to

--- @class git_guard.AnalyzerCtx
--- @field public protected string[] protected branch patterns (the
---       `public` visibility hint is required because luals would
---       otherwise parse `@field protected ...` as a visibility
---       modifier on an anonymous field)
--- @field ask_patterns string[] additional ask-pattern branch globs

--- @class git_guard.Config
--- @field protected_branches string[]?
--- @field per_repo table[]?
--- @field ask_branch_patterns string[]?
--- @field branch_naming { patterns: string[]?, on_violation: ("ask"|"deny")? }?
--- @field options { fallback_on_unparseable: git_guard.Decision?, git_dash_c_policy: ("ask"|"allow")? }?

--- @class git_guard.ProjectConfig
--- @field allowed_git_dirs string[]?
--- @field options { hard_deny_out_of_allowlist: boolean? }?

local M = {}

-- Tests can stub the git interface via `stub.new(M._git, "current_branch")`.
-- Internal-only handle; refers to the same module the production hook calls.
M._git = git

-- ── Verb classification tables ──

-- Safe verbs: read-only or purely-informational. Fast-allow.
M.SAFE_VERBS = {
  log = true,
  diff = true,
  show = true,
  status = true,
  ["ls-files"] = true,
  ["ls-tree"] = true,
  ["rev-parse"] = true,
  ["rev-list"] = true,
  ["for-each-ref"] = true,
  ["cat-file"] = true,
  blame = true,
  describe = true,
  shortlog = true,
  reflog = true,
  ["symbolic-ref"] = true,
  grep = true,
}

-- Subform-conditional: the bare verb is gated, but the listed
-- subflags (or positional first-args) flip it to safe.
M.SAFE_SUBFORMS = {
  branch = { ["--list"] = true, ["--show-current"] = true },
  tag = { ["--list"] = true },
  config = { ["--get"] = true, ["--list"] = true },
  -- `git remote -v` and `git remote show <name>` are read-only.
  remote = { ["-v"] = true, show = true },
}

-- State-changing verbs (bi0.2 C2 scope): write to or modify the
-- current branch's history. The protected-branch check applies only
-- to these — other gated verbs (checkout/switch/clean/gc/fetch
-- without refspec) keep C1's generic-ask behavior.
M.STATE_CHANGING_VERBS = {
  commit = true,
  push = true,
  pull = true,
  merge = true,
  rebase = true,
  reset = true,
  ["cherry-pick"] = true,
  revert = true,
  am = true,
  apply = true,
  stash = true,
}

-- ── Config loading (fail-safe) ──

local CONFIG_PATH_DEFAULT = lib.HOME .. "/.claude/hooks/git-guard.yaml"

M.DEFAULT_OPTIONS = {
  fallback_on_unparseable = "ask",
  git_dash_c_policy = "ask",
}

-- Cached after first load. nil = not yet attempted; false = previously
-- failed (don't retry, just use defaults).
local _config_cache = nil

--- Reset the in-process config cache. Test-only.
--- @return nil
function M._reset_config_cache()
  _config_cache = nil -- for tests
end

--- Load the global git-guard config. Missing config returns defaults;
--- parse errors or unavailable lyaml fall back to defaults with a
--- stderr diagnostic. Result is memoized for the process lifetime.
--- @param path string? config path; defaults to `$HOME/.claude/hooks/git-guard.yaml`
--- @return git_guard.Config? config nil only when lyaml/parsing fails
function M.load_config(path)
  if _config_cache ~= nil then
    return _config_cache or nil
  end
  path = path or CONFIG_PATH_DEFAULT
  local f = io.open(path, "r")
  if not f then
    -- Missing config = use defaults; not an error.
    _config_cache = { options = M.DEFAULT_OPTIONS }
    return _config_cache
  end
  local raw = f:read("*all")
  f:close()
  local ok_req, yaml = pcall(require, "lyaml")
  if not ok_req then
    io.stderr:write("git-guard: lyaml unavailable; gated verbs will fall back to ask\n")
    _config_cache = false
    return nil
  end
  local parsed
  local ok_parse, perr = pcall(function()
    parsed = yaml.load(raw)
  end)
  if not ok_parse or type(parsed) ~= "table" then
    io.stderr:write(
      "git-guard: config parse error at " .. path .. " (" .. tostring(perr) .. "); falling back to defaults\n"
    )
    _config_cache = false
    return nil
  end
  parsed.options = parsed.options or {}
  for k, v in pairs(M.DEFAULT_OPTIONS) do
    if parsed.options[k] == nil then
      parsed.options[k] = v
    end
  end
  _config_cache = parsed
  return _config_cache
end

-- ── Cheap fast-path: is there a git invocation anywhere in this command? ──

--- Fast pre-check: does the command contain a `git` token that isn't part
--- of another identifier (e.g. `agitate`, `git_xxx`)?
--- @param command string? raw Bash command string
--- @return boolean
function M.has_git(command)
  if not command or command == "" then
    return false
  end
  -- Bound the match so `git_xxx`, `agitate`, and similar identifiers
  -- don't false-positive. Pad with spaces to handle string-start and
  -- string-end uniformly.
  local padded = " " .. command .. " "
  return padded:find("[^%w_]git[^%w_]") ~= nil
end

-- ── Shell-ish tokenizer ──

-- Tokenize a Bash command string. Honors single quotes (literal),
-- double quotes (with backslash escape), and unquoted backslash
-- escape. Whitespace separates tokens. Returns array on success;
-- (nil, errmsg) on parse failure (unbalanced quotes).
--- Tokenize a Bash command string. Honors single quotes (literal),
--- double quotes (with backslash escape), and unquoted backslash escape.
--- Whitespace separates tokens.
--- @param command string?
--- @return string[]? tokens nil on parse failure
--- @return string? err error message ("empty", "unbalanced quotes")
function M.tokenize(command)
  if not command then
    return nil, "empty"
  end
  local tokens = {}
  local cur = {}
  local state = "normal" -- normal | sq | dq
  local i, n = 1, #command
  while i <= n do
    local c = command:sub(i, i)
    if state == "normal" then
      if c:match("%s") then
        if #cur > 0 then
          tokens[#tokens + 1] = table.concat(cur)
          cur = {}
        end
      elseif c == "'" then
        state = "sq"
      elseif c == '"' then
        state = "dq"
      elseif c == "\\" and i < n then
        cur[#cur + 1] = command:sub(i + 1, i + 1)
        i = i + 1
      else
        cur[#cur + 1] = c
      end
    elseif state == "sq" then
      if c == "'" then
        state = "normal"
      else
        cur[#cur + 1] = c
      end
    elseif state == "dq" then
      if c == '"' then
        state = "normal"
      elseif c == "\\" and i < n then
        cur[#cur + 1] = command:sub(i + 1, i + 1)
        i = i + 1
      else
        cur[#cur + 1] = c
      end
    end
    i = i + 1
  end
  if state ~= "normal" then
    return nil, "unbalanced quotes"
  end
  if #cur > 0 then
    tokens[#tokens + 1] = table.concat(cur)
  end
  return tokens
end

local SHELL_SEPARATORS = { ["&&"] = true, ["||"] = true, [";"] = true, ["|"] = true }

--- Split tokens at shell separators (`&&`, `||`, `;`, `|`) into one
--- token list per command.
--- @param tokens string[]
--- @return string[][] commands
function M.split_commands(tokens)
  local out = {}
  local cur = {}
  for _, t in ipairs(tokens) do
    if SHELL_SEPARATORS[t] then
      if #cur > 0 then
        out[#out + 1] = cur
        cur = {}
      end
    else
      cur[#cur + 1] = t
    end
  end
  if #cur > 0 then
    out[#out + 1] = cur
  end
  return out
end

-- Within a single command's token list, find the first git invocation
-- and return its verb + args (everything after the verb). Returns nil
-- if no git verb is in this command. Handles:
--   git verb …
--   NAME=val git verb …                  (env-var prefix)
--   git -C <dir> verb …                  (separated flag value)
--   git --git-dir=… verb …               (joined flag value)
--   git -c k=v verb …                    (config flag)
--- Within a single command's token list, find the first git invocation
--- and return its verb + args (everything after the verb).
--- Handles env-var prefixes (`NAME=val git ...`) and git-level flags
--- (`-C <dir>`, `--git-dir=...`, `--work-tree=...`, `-c k=v`).
--- @param tokens string[]
--- @return string? verb nil when no git verb is in this command
--- @return string[]? args everything after the verb
function M.find_git_verb_in_command(tokens)
  local i = 1
  -- Skip env-var assignments at the start (NAME=value tokens).
  while i <= #tokens do
    local t = tokens[i]
    if t:match("^[%w_]+=") then
      i = i + 1
    else
      break
    end
  end
  if i > #tokens or tokens[i] ~= "git" then
    return nil
  end
  -- Past git; skip git-level flags to find the verb.
  local j = i + 1
  while j <= #tokens do
    local arg = tokens[j]
    if arg == "-C" or arg == "--git-dir" or arg == "--work-tree" or arg == "-c" then
      j = j + 2
    elseif arg:match("^%-%-git%-dir=") or arg:match("^%-%-work%-tree=") or arg:match("^%-c=") then
      j = j + 1
    elseif arg:sub(1, 1) == "-" then
      j = j + 1
    else
      local args = {}
      for k = j + 1, #tokens do
        args[#args + 1] = tokens[k]
      end
      return arg, args
    end
  end
  return nil
end

-- ── Pattern matching (C2: branch-name glob/regex matching) ──

-- Convert a glob (with `*` and `?` wildcards) to an anchored Lua pattern.
-- Escapes Lua-pattern special characters first; then translates `*`/`?`.
-- Anchored start+end so a glob like "main" doesn't match "main-fork".
--- Convert a glob (with `*` and `?` wildcards) to an anchored Lua
--- pattern. Escapes Lua-pattern special characters first; then
--- translates `*` → `.*` and `?` → `.`. Anchored start+end so `main`
--- doesn't match `main-fork`.
--- @param glob string
--- @return string lua_pattern anchored Lua pattern
function M.glob_to_lua_pattern(glob)
  -- TODO(F-lib): migrate to lua-glob-pattern (Debian luarocks-only) for
  -- full glob support (`[abc]`, `[!abc]`, `**`). Today's subset (`*`,
  -- `?`) covers branch-name patterns used in the wild.
  local p = glob:gsub("([%%%(%)%.%+%-%[%]%^%$])", "%%%1")
  p = p:gsub("%*", ".*")
  p = p:gsub("%?", ".")
  return "^" .. p .. "$"
end

-- Match a string against a pattern entry. Patterns prefixed with `re:`
-- are treated as Lua regex (not full PCRE — Lua patterns are simpler);
-- everything else is treated as a glob.
--- Match a string against a pattern entry. Entries prefixed with `re:`
--- are treated as Lua regex (not full PCRE); everything else is a glob.
--- @param s string? candidate
--- @param pattern string? pattern entry (glob or `re:`-prefixed)
--- @return boolean
function M.match_pattern(s, pattern)
  if type(s) ~= "string" or type(pattern) ~= "string" then
    return false
  end
  if pattern:sub(1, 3) == "re:" then
    return s:match("^" .. pattern:sub(4) .. "$") ~= nil
  end
  return s:match(M.glob_to_lua_pattern(pattern)) ~= nil
end

-- ── Protected-branch resolution (C2) ──

-- Resolve the protected branches for a given working directory.
-- Order: per_repo override (first prefix match on abs path) → global
-- protected_branches → origin/HEAD fallback (last resort; handoff §2
-- explicitly warns this is unreliable).
--
-- Returns (patterns, source) where:
--   patterns: list of branch patterns (globs or `re:`-prefixed regex)
--   source:   "per_repo" | "global" | "origin_head" | "none"
--- Resolve protected branches for a given cwd.
--- Order: `per_repo` (first prefix match on abs path) → global
--- `protected_branches` → `origin/HEAD` fallback (last resort; handoff
--- §2 explicitly warns this is unreliable).
--- @param cwd string absolute path
--- @param config git_guard.Config?
--- @return string[] patterns branch globs/`re:`-prefixed regexes
--- @return git_guard.ProtectedSource source which tier produced the patterns
function M.resolve_protected_branches(cwd, config)
  config = config or {}
  -- per_repo first (first-match-wins on prefix-match of cwd against
  -- entry.match; handoff §4 decision 2).
  local per_repo = config.per_repo or {}
  for _, entry in ipairs(per_repo) do
    local match = entry and entry.match
    if type(match) == "string" and match ~= "" then
      -- Prefix match with `/` boundary: `/home/X/Y` matches `/home/X/Y`,
      -- `/home/X/Y/sub/dir`, but NOT `/home/X/Y-foo`.
      local norm = match:gsub("/+$", "")
      if cwd == norm or cwd:sub(1, #norm + 1) == norm .. "/" then
        local patterns = entry.protected_branches
        if type(patterns) == "table" and #patterns > 0 then
          return patterns, "per_repo"
        end
      end
    end
  end

  -- Global protected_branches
  local global_patterns = config.protected_branches
  if type(global_patterns) == "table" and #global_patterns > 0 then
    return global_patterns, "global"
  end

  -- origin/HEAD fallback (last resort)
  local origin_head = M._git.origin_head_branch(cwd)
  if origin_head then
    return { origin_head }, "origin_head"
  end

  return {}, "none"
end

--- True iff `branch` matches any pattern in `patterns`.
--- @param branch string?
--- @param patterns string[]?
--- @return boolean
function M.branch_matches_any(branch, patterns)
  if not branch or type(patterns) ~= "table" then
    return false
  end
  for _, p in ipairs(patterns) do
    if M.match_pattern(branch, p) then
      return true
    end
  end
  return false
end

-- ── C3: refspec parsing + ref-rewriting denylist ──

-- Extract the destination ref from a single push refspec.
-- Refspecs: `[+]?<src>[:<dst>]` or `[+]?:<dst>` (delete).
-- Returns (dst, is_delete). dst is nil if the refspec is malformed.
-- For `src` with no colon, dst is implicitly src (push src to same name).
--- Extract the destination ref from a single push refspec.
--- Refspec grammar: `[+]?<src>[:<dst>]` or `[+]?:<dst>` (delete).
--- @param spec string?
--- @return string? dst nil if malformed
--- @return boolean is_delete true when the refspec has empty `src`
function M.parse_push_refspec(spec)
  if type(spec) ~= "string" or spec == "" then
    return nil, false
  end
  -- Strip leading `+` (force-push marker).
  local r = spec:gsub("^%+", "")
  local src, dst = r:match("^([^:]*):([^:]+)$")
  if dst then
    -- `:dst` (empty src) = delete dst on remote.
    return dst, src == ""
  end
  -- No colon: `src` becomes both src and dst.
  if r:find(":") then
    return nil, false -- malformed (multiple colons)
  end
  return r, false
end

-- Analyze a `git push` invocation's args.
-- Returns (decision, reason) where decision is one of:
--   "ask"   — issue found, ask the user
--   "allow" — explicit refspecs given, all dests safe (don't fall through
--              to the C2 current-branch check; the refspecs are
--              authoritative about what's being modified)
--   nil     — no explicit refspec, no special flag — defer to C2 default
--- Analyze a `git push` invocation. Three-valued.
--- @param args string[]?
--- @param ctx git_guard.AnalyzerCtx?
--- @return git_guard.Decision? decision `"ask"` on hit; `"allow"` to
---         bypass C2's current-branch check when refspecs are explicit;
---         `nil` to defer
--- @return string? reason
function M.analyze_push(args, ctx)
  args = args or {}
  ctx = ctx or {}
  local protected = ctx.protected or {}
  local ask_patterns = ctx.ask_patterns or {}

  local force_pushing, delete_flag, mirror_flag = false, false, false
  local positional = {}
  local i = 1
  while i <= #args do
    local a = args[i]
    if a == "--force" or a == "-f" or a == "--force-with-lease" then
      force_pushing = true
      i = i + 1
    elseif a == "--delete" or a == "-d" then
      delete_flag = true
      i = i + 1
    elseif a == "--mirror" then
      mirror_flag = true
      i = i + 1
    elseif a:sub(1, 1) == "-" then
      i = i + 1
    else
      positional[#positional + 1] = a
      i = i + 1
    end
  end

  local remote = positional[1]
  -- `git push .` (push to local repo as a remote) → always ask.
  if remote == "." then
    return "ask", "git-guard: 'git push .' rewrites local refs via remote-loopback — always asks"
  end

  -- `--mirror` rewrites every remote ref.
  if mirror_flag then
    return "ask", "git-guard: 'git push --mirror' rewrites every remote ref — always asks"
  end

  -- --delete <remote> <ref>: positional[2..N] are refs to delete.
  if delete_flag then
    for j = 2, #positional do
      local ref = positional[j]
      if M.branch_matches_any(ref, protected) or M.branch_matches_any(ref, ask_patterns) then
        return "ask", string.format("git-guard: 'git push --delete' on protected ref %q — always asks", ref)
      end
    end
    return "ask", "git-guard: 'git push --delete' rewrites refs — always asks"
  end

  -- Refspecs: positional[2..N]. Track whether any explicit refspec exists.
  local has_refspec = false
  for j = 2, #positional do
    has_refspec = true
    local spec = positional[j]
    local dst, is_delete = M.parse_push_refspec(spec)
    if is_delete then
      return "ask",
        string.format("git-guard: 'git push %s :%s' deletes a remote ref — always asks", remote or "?", dst)
    end
    if dst and (M.branch_matches_any(dst, protected) or M.branch_matches_any(dst, ask_patterns)) then
      return "ask",
        string.format(
          "git-guard: 'git push %s ...:%s' targets protected ref %q — confirm intent",
          remote or "?",
          dst,
          dst
        )
    end
  end

  if force_pushing then
    return "ask", "git-guard: 'git push --force[-with-lease]' rewrites history — confirm intent"
  end

  if has_refspec then
    -- Explicit refspecs given, none hit protected/ask patterns. The
    -- refspecs are authoritative about what's being modified; don't
    -- fall through to the current-branch check (which would over-ask
    -- when pushing a non-current-branch ref while sitting on a
    -- protected branch).
    return "allow", "git-guard: 'git push' with explicit refspec(s); none target protected refs"
  end

  -- Bare `git push` (no refspec, no special flag): defer to C2's
  -- current-branch check.
  return nil, nil
end

--- Analyze a `git branch` invocation. Returns a decision only when a
--- ref-rewrite concern fires (force-update, delete-of-protected,
--- move-touching-protected); nil otherwise.
--- @param args string[]?
--- @param ctx git_guard.AnalyzerCtx?
--- @return git_guard.Decision? decision `"ask"` or nil
--- @return string? reason
function M.analyze_branch(args, ctx)
  args = args or {}
  ctx = ctx or {}
  local protected = ctx.protected or {}
  local ask_patterns = ctx.ask_patterns or {}

  local force_flag, delete_flag, move_flag = false, false, false
  local positional = {}
  local i = 1
  while i <= #args do
    local a = args[i]
    if a == "-f" or a == "--force" then
      force_flag = true
      i = i + 1
    elseif a == "-d" or a == "-D" or a == "--delete" then
      delete_flag = true
      i = i + 1
    elseif a == "-m" or a == "-M" or a == "--move" then
      move_flag = true
      i = i + 1
    elseif a:sub(1, 1) == "-" then
      i = i + 1 -- skip other flags
    else
      positional[#positional + 1] = a
      i = i + 1
    end
  end

  if force_flag then
    -- `branch -f <name>` force-updates a branch ref to point at HEAD (or
    -- the given commit). Always asks.
    return "ask", "git-guard: 'git branch -f' force-updates a ref — always asks"
  end

  if delete_flag then
    for _, ref in ipairs(positional) do
      if M.branch_matches_any(ref, protected) or M.branch_matches_any(ref, ask_patterns) then
        return "ask", string.format("git-guard: 'git branch -d/-D' on protected branch %q — always asks", ref)
      end
    end
    return nil, nil -- delete of a feature branch is normal; allow path
  end

  if move_flag then
    -- branch -m / -M: rename. If renaming away from or to a protected
    -- ref → ask. Conservative: if any positional matches protected, ask.
    for _, ref in ipairs(positional) do
      if M.branch_matches_any(ref, protected) then
        return "ask",
          string.format("git-guard: 'git branch --move' touches protected branch %q — confirm intent", ref)
      end
    end
  end

  return nil, nil
end

-- Verbs that ALWAYS ask regardless of args (direct ref-rewrite primitives).
M.ALWAYS_ASK_REF_REWRITE = {
  ["update-ref"] = true,
}

-- ── C6: project-local git-dir allowlist (Subtlety 2, project half) ──

-- Per-process cache for project configs keyed by cwd. nil = not yet
-- attempted; false = previously failed (use defaults).
local _project_config_cache = {}

--- Reset the per-cwd project-config cache. Test-only.
--- @return nil
function M._reset_project_config_cache()
  _project_config_cache = {}
end

-- Load project-local config from `<cwd>/.claude-session/hooks/git-guard.yaml`
-- (preferred, matches our deployment convention) or
-- `<cwd>/.claude/git-guard.yaml` (handoff's original convention).
-- Returns the parsed table or nil. Caches per cwd.
--- Load project-local config from `<cwd>/.claude-session/hooks/
--- git-guard.yaml` (preferred) or `<cwd>/.claude/git-guard.yaml`
--- (handoff's original convention). Caches per cwd; returns nil when
--- no candidate is readable or parsing fails.
--- @param cwd string?
--- @return git_guard.ProjectConfig?
function M.load_project_config(cwd)
  if type(cwd) ~= "string" or cwd == "" then
    return nil
  end
  if _project_config_cache[cwd] ~= nil then
    return _project_config_cache[cwd] or nil
  end

  local candidates = {
    cwd .. "/.claude-session/hooks/git-guard.yaml",
    cwd .. "/.claude/git-guard.yaml",
  }
  local f, path
  for _, p in ipairs(candidates) do
    f = io.open(p, "r")
    if f then
      path = p
      break
    end
  end
  if not f then
    _project_config_cache[cwd] = false
    return nil
  end

  local raw = f:read("*all")
  f:close()
  local ok_req, yaml = pcall(require, "lyaml")
  if not ok_req then
    io.stderr:write("git-guard: lyaml unavailable; project config ignored\n")
    _project_config_cache[cwd] = false
    return nil
  end
  local parsed
  local ok_parse, perr = pcall(function()
    parsed = yaml.load(raw)
  end)
  if not ok_parse or type(parsed) ~= "table" then
    io.stderr:write(
      "git-guard: project config parse error at " .. (path or "?") .. " (" .. tostring(perr) .. "); ignoring\n"
    )
    _project_config_cache[cwd] = false
    return nil
  end
  _project_config_cache[cwd] = parsed
  return parsed
end

--- Resolve a path entry to an absolute, normalized form. Relative
--- entries are joined onto `base_cwd` before normalization.
--- @param entry string? path entry (absolute or cwd-relative)
--- @param base_cwd string? required when `entry` is relative
--- @return string? absolute_normalized
function M.resolve_path(entry, base_cwd)
  if type(entry) ~= "string" or entry == "" then
    return nil
  end
  local p = entry
  if p:sub(1, 1) ~= "/" then
    if not base_cwd or base_cwd == "" then
      return nil
    end
    p = base_cwd .. "/" .. p
  end
  return lib.normalize_path(p)
end

-- Check whether `target` (a path passed to git -C / --git-dir / --work-tree)
-- is covered by `allowed_entries`. Both sides are resolved against `cwd`
-- and normalized; the comparison supports:
--   - exact match
--   - prefix match with `/` boundary (entry "/repo" matches "/repo" or
--     "/repo/sub", NOT "/repo-fork")
--   - glob match (via M.match_pattern on the post-normalize string)
--- Check whether `target` (passed to git -C / --git-dir / --work-tree)
--- is covered by `allowed_entries`. Supports exact match, prefix match
--- with `/` boundary, and glob match (via `match_pattern`).
--- @param target string?
--- @param allowed_entries string[]?
--- @param cwd string? base for relative-path resolution
--- @return boolean
function M.target_in_allowed_dirs(target, allowed_entries, cwd)
  if not target or type(allowed_entries) ~= "table" then
    return false
  end
  local target_abs = M.resolve_path(target, cwd)
  if not target_abs then
    return false
  end
  for _, entry in ipairs(allowed_entries) do
    -- Try as a path first (resolve relative-to-cwd, exact-or-prefix-match).
    local entry_abs = M.resolve_path(entry, cwd)
    if entry_abs then
      if target_abs == entry_abs or target_abs:sub(1, #entry_abs + 1) == entry_abs .. "/" then
        return true
      end
    end
    -- Then try as a glob (matches the normalized target).
    if M.match_pattern(target_abs, entry) then
      return true
    end
  end
  return false
end

-- ── C5: git -C / --git-dir / --work-tree detection ──

-- Scan a single command's tokens for git-path-redirection flags
-- (-C <dir>, --git-dir <path> | --git-dir=<path>, --work-tree <path> |
-- --work-tree=<path>). These flags relocate the git operation to a
-- target dir, bypassing the cwd-based safety assumption.
-- Returns a list of `{flag = ..., target = ...}` records (one per
-- flag use; possible to have multiple in one invocation), or empty
-- table when none.
--
-- Walks from the start of the command: skips env-var prefixes,
-- expects `git` next, then collects path flags until the verb (first
-- non-flag positional).
--- Scan a single command's tokens for git-path-redirection flags
--- (`-C`, `--git-dir[=...]`, `--work-tree[=...]`). Each flag use
--- produces one record; multiple in one invocation is valid.
--- @param tokens string[]?
--- @return git_guard.PathFlag[] flags empty when none detected
function M.detect_git_path_flags(tokens)
  local results = {}
  if type(tokens) ~= "table" or #tokens == 0 then
    return results
  end

  local i = 1
  while i <= #tokens do
    local t = tokens[i]
    if t:match("^[%w_]+=") then
      i = i + 1
    else
      break
    end
  end
  if i > #tokens or tokens[i] ~= "git" then
    return results
  end
  i = i + 1

  while i <= #tokens do
    local arg = tokens[i]
    if arg == "-C" or arg == "--git-dir" or arg == "--work-tree" then
      local val = tokens[i + 1]
      if val then
        results[#results + 1] = { flag = arg, target = val }
      end
      i = i + 2
    elseif arg:match("^%-%-git%-dir=(.+)$") then
      local val = arg:match("^%-%-git%-dir=(.+)$")
      results[#results + 1] = { flag = "--git-dir", target = val }
      i = i + 1
    elseif arg:match("^%-%-work%-tree=(.+)$") then
      local val = arg:match("^%-%-work%-tree=(.+)$")
      results[#results + 1] = { flag = "--work-tree", target = val }
      i = i + 1
    elseif arg:match("^%-c=") or arg == "-c" then
      -- `-c key=value` config setter; not a path flag. Skip it (and
      -- its value, for the separated form).
      if arg == "-c" then
        i = i + 2
      else
        i = i + 1
      end
    elseif arg:sub(1, 1) == "-" then
      i = i + 1
    else
      -- Reached the verb (first non-flag positional). Stop.
      break
    end
  end

  return results
end

-- ── C4: branch-naming enforcement ──

-- Extract the new branch name being CREATED by a given verb+args, if any.
-- Returns the name string or nil. Detects:
--   git checkout -b NAME [start]
--   git checkout -B NAME [start]
--   git switch   -c NAME [start]
--   git switch   -C NAME [start]
--   git branch    NAME [start]      (bare; no -d/-D/-f/--list/etc.)
--- Extract the new branch name being created by a given verb+args, if
--- any. Detects `checkout -b/-B`, `switch -c/-C`, and bare `branch
--- <name>` (without destructive flags).
--- @param verb string?
--- @param args string[]?
--- @return string? name
function M.new_branch_name(verb, args)
  if not args then
    return nil
  end
  if verb == "checkout" or verb == "switch" then
    local i = 1
    while i <= #args do
      local a = args[i]
      if a == "-b" or a == "-B" or a == "-c" or a == "-C" then
        local name = args[i + 1]
        if name and name:sub(1, 1) ~= "-" then
          return name
        end
        return nil
      end
      i = i + 1
    end
    return nil
  end
  if verb == "branch" then
    -- bare branch <name> — confirm no destructive flags.
    local positional, has_destructive_flag = {}, false
    for _, a in ipairs(args) do
      if
        a == "-d"
        or a == "-D"
        or a == "--delete"
        or a == "-f"
        or a == "--force"
        or a == "--list"
        or a == "-m"
        or a == "-M"
        or a == "--move"
        or a == "--show-current"
        or a == "--edit-description"
      then
        has_destructive_flag = true
      elseif a:sub(1, 1) == "-" then
        -- Other flag; ignore for create-detection.
      else
        positional[#positional + 1] = a
      end
    end
    if has_destructive_flag then
      return nil
    end
    -- positional[1] is the new branch name; positional[2] (optional) is start-point.
    return positional[1]
  end
  return nil
end

-- Check a new-branch name against branch_naming.patterns. Three-valued:
--   "allow" — naming configured AND the new name conforms (overrides
--             C1's generic-gated checkout/switch/branch ask).
--   "ask" / "deny" — name violates the configured patterns (per
--             branch_naming.on_violation; default ask).
--   nil — naming unconfigured / not a create-form (defer).
--- Check a new-branch name against `branch_naming.patterns`.
--- @param verb string?
--- @param args string[]?
--- @param cfg git_guard.Config?
--- @return git_guard.Decision? decision `"allow"` on conforming match
---         (overrides C1 generic-gated); `"ask"` or `"deny"` per
---         `branch_naming.on_violation`; `nil` when unconfigured /
---         not a create-form
--- @return string? reason
function M.analyze_new_branch_name(verb, args, cfg)
  local name = M.new_branch_name(verb, args)
  if not name then
    return nil
  end
  local bn = (cfg or {}).branch_naming
  if type(bn) ~= "table" then
    return nil
  end
  local patterns = bn.patterns
  if type(patterns) ~= "table" or #patterns == 0 then
    return nil
  end

  for _, p in ipairs(patterns) do
    if M.match_pattern(name, p) then
      return "allow", string.format("git-guard: new branch %q matches branch_naming pattern %q", name, p)
    end
  end

  local action = (bn.on_violation == "deny") and "deny" or "ask"
  return action,
    string.format(
      "git-guard: new branch %q does not match branch_naming.patterns (configured: %s) — %s",
      name,
      table.concat(patterns, ", "),
      action == "deny" and "denied" or "confirm intent"
    )
end

-- ── Verb classification ──

--- Classify a verb as `"safe"` (fast-allow) or `"gated"` (further
--- analysis required). Honors `SAFE_VERBS` for unconditional fast-allow
--- and `SAFE_SUBFORMS` for verbs whose listed subflags flip them to
--- safe.
--- @param verb string
--- @param args string[]?
--- @return git_guard.VerbClass
function M.classify_verb(verb, args)
  if M.SAFE_VERBS[verb] then
    return "safe"
  end
  local subforms = M.SAFE_SUBFORMS[verb]
  if subforms then
    for _, a in ipairs(args or {}) do
      if subforms[a] then
        return "safe"
      end
    end
  end
  return "gated"
end

-- ── Decision ──

--- Pure decision function. Takes the parsed PreToolUse payload and
--- returns `(decision, reason)`. Walks every separator-delimited git
--- invocation in the compound command; the most-restrictive outcome
--- wins. See the file header and `git-guard.yaml` for the full
--- precedence rules (C1–C6).
--- @param data git_guard.HookPayload?
--- @return git_guard.Decision decision
--- @return string reason
function M.decide(data)
  local input = data and data.tool_input
  local command = (type(input) == "table") and input.command or nil
  if not command or command == "" then
    return "allow", "git-guard: no command in input"
  end
  if not M.has_git(command) then
    return "allow", "git-guard: not a git command"
  end

  local tokens, terr = M.tokenize(command)
  if not tokens then
    local cfg = M.load_config()
    local fallback = (cfg and cfg.options and cfg.options.fallback_on_unparseable) or "ask"
    return fallback, "git-guard: could not parse command (" .. (terr or "?") .. ")"
  end

  -- Walk every separator-delimited command; classify each git invocation.
  -- C2: STATE_CHANGING verbs (commit/push/merge/...) on a protected branch
  -- ask; on a feature branch allow. Other gated verbs (checkout, clean,
  -- gc, fetch, ...) keep C1's generic-ask. Compound logic: ANY ask
  -- wins (most-restrictive across the compound).
  local commands = M.split_commands(tokens)
  local cwd = (type(data) == "table" and type(data.cwd) == "string") and data.cwd or nil
  local any_git, last_verb = false, nil
  --- @type table?
  local protected_hit = nil
  --- @type string|false
  local generic_gated = false

  -- Lazy-resolved per-decide-call: only compute current-branch + protected
  -- list when we actually see a STATE_CHANGING verb. Caches for the
  -- compound walk so we don't shell out to git twice.
  --- @type git_guard.Config?
  local cfg_cache
  --- @type string|false|nil
  local branch_cache
  --- @type string[]?
  local patterns_cache
  local function get_config()
    if cfg_cache == nil then
      cfg_cache = M.load_config() or {}
    end
    return cfg_cache
  end
  local function get_current_branch()
    if branch_cache == nil and cwd then
      branch_cache = M._git.current_branch(cwd) or false
    end
    if branch_cache == false then
      return nil
    end
    return branch_cache
  end
  local function get_protected_patterns()
    if patterns_cache == nil then
      local p, _src = M.resolve_protected_branches(cwd or "/", get_config())
      patterns_cache = p
    end
    return patterns_cache
  end

  local ref_rewrite_hit = nil
  for _, cmd in ipairs(commands) do
    local verb, args = M.find_git_verb_in_command(cmd)
    if verb then
      any_git = true
      last_verb = verb

      -- C5: git -C / --git-dir / --work-tree always asks at the global
      -- level (handoff §5.3). C6 refines: when the project's
      -- allowed_git_dirs covers the target, the ask is upgraded to
      -- allow; if hard_deny_out_of_allowlist=true, an out-of-allowlist
      -- target is escalated from ask to deny. Honors
      -- options.git_dash_c_policy (default ask; "allow" disables the
      -- whole gate).
      local path_flags = M.detect_git_path_flags(cmd)
      if #path_flags > 0 then
        local cfg = get_config()
        local policy = ((cfg or {}).options or {}).git_dash_c_policy or "ask"
        if policy == "ask" then
          -- C6: consult project-local allowed_git_dirs.
          local project = cwd and M.load_project_config(cwd) or nil
          local allowed = (project and project.allowed_git_dirs) or {}
          local hard_deny = (project and project.options and project.options.hard_deny_out_of_allowlist) or false

          local all_targets_allowed = true
          local first_blocked = nil
          for _, pf in ipairs(path_flags) do
            if not M.target_in_allowed_dirs(pf.target, allowed, cwd) then
              all_targets_allowed = false
              first_blocked = first_blocked or pf
            end
          end

          if all_targets_allowed and #allowed > 0 then
            -- Every -C / --git-dir / --work-tree target is in the
            -- project's allowed_git_dirs. C6 override: allow.
            -- (Record nothing; loop continues to verb classification.)
          else
            local pf = first_blocked or path_flags[1]
            local extras = ""
            if #path_flags > 1 then
              extras = string.format(" (and %d more)", #path_flags - 1)
            end
            local decision = hard_deny and "deny" or "ask"
            local kind = hard_deny and "denied (hard_deny_out_of_allowlist)" or "always asks"
            local hint = "C6 project allowed_git_dirs may allow it"
            if hard_deny then
              hint = "hard_deny_out_of_allowlist=true rejects out-of-allowlist targets"
            end
            ref_rewrite_hit = {
              decision = decision,
              reason = string.format(
                "git-guard: 'git %s' (for verb %q) redirects git to %q%s — global hook %s (%s)",
                pf.flag,
                verb,
                pf.target,
                extras,
                kind,
                hint
              ),
            }
            break
          end
        end
        -- policy = "allow" → skip C5; fall through to normal classification.
      end

      local class = M.classify_verb(verb, args)
      if class == "gated" then
        -- C3: ref-rewriting checks fire first (override C2's current-
        -- branch check when an explicit refspec / ref-targeted op
        -- names the affected ref).
        local cfg = get_config()
        local ctx = {
          protected = get_protected_patterns(),
          ask_patterns = (cfg and cfg.ask_branch_patterns) or {},
        }

        if M.ALWAYS_ASK_REF_REWRITE[verb] then
          ref_rewrite_hit = {
            decision = "ask",
            reason = string.format("git-guard: '%s' is a direct ref-rewrite primitive — always asks", verb),
          }
          break
        end

        -- C4: branch-naming enforcement on new-branch creation forms.
        -- Fires before C3/C2 because the concern is the NEW name
        -- (independent of current-branch protection or refspec dst).
        do
          local naming_decision, naming_reason = M.analyze_new_branch_name(verb, args, cfg)
          if naming_decision then
            ref_rewrite_hit = { decision = naming_decision, reason = naming_reason }
            break
          end
        end

        local analyzer_decision, analyzer_reason
        if verb == "push" then
          analyzer_decision, analyzer_reason = M.analyze_push(args, ctx)
        elseif verb == "branch" then
          analyzer_decision, analyzer_reason = M.analyze_branch(args, ctx)
        elseif verb == "fetch" then
          -- `git fetch . <refspec>` writes local refs via loopback;
          -- always ask. Other fetch shapes fall through to C1 generic.
          if args and args[1] == "." and #args >= 2 then
            analyzer_decision = "ask"
            analyzer_reason =
              "git-guard: 'git fetch .' with refspec rewrites local refs via remote-loopback — always asks"
          end
        end

        if analyzer_decision == "ask" then
          ref_rewrite_hit = { decision = "ask", reason = analyzer_reason }
          break
        elseif analyzer_decision == "allow" then
          -- Explicit refspec / safe ref-targeted op; bypass C2 default.
          -- Record nothing; loop continues.
        elseif M.STATE_CHANGING_VERBS[verb] then
          -- C2: check current branch against protected + ask patterns.
          local current = get_current_branch()
          if current then
            local protected = ctx.protected
            local ask_branches = ctx.ask_patterns
            if M.branch_matches_any(current, protected) then
              protected_hit = { verb = verb, branch = current, kind = "protected" }
              break
            elseif M.branch_matches_any(current, ask_branches) then
              protected_hit = { verb = verb, branch = current, kind = "ask_branch_pattern" }
              break
            end
          else
            protected_hit = { verb = verb, branch = "?", kind = "no_current_branch" }
            break
          end
        else
          -- Non-state-changing gated verb (checkout, clean, gc, fetch,
          -- bare branch, …); carry C1's generic-ask.
          generic_gated = generic_gated or verb
        end
      end
    end
  end

  if not any_git then
    -- `has_git` matched but no actual git invocation parsed
    -- (e.g. `git=value`, comment, string content). Allow.
    return "allow", "git-guard: no git verb found after parse"
  end
  if ref_rewrite_hit then
    return ref_rewrite_hit.decision, ref_rewrite_hit.reason
  end
  if protected_hit then
    if protected_hit.kind == "protected" then
      return "ask",
        string.format(
          "git-guard: %s on protected branch %q — confirm intent",
          protected_hit.verb,
          protected_hit.branch
        )
    elseif protected_hit.kind == "ask_branch_pattern" then
      return "ask",
        string.format(
          "git-guard: %s on branch %q matched ask_branch_patterns — confirm intent",
          protected_hit.verb,
          protected_hit.branch
        )
    else
      return "ask",
        string.format(
          "git-guard: %s but cwd not on a branch (detached HEAD or not-a-repo) — confirm intent",
          protected_hit.verb
        )
    end
  end
  if generic_gated then
    return "ask", string.format("git-guard: gated verb %q (C1 fallback; covered by C3+ when refined)", generic_gated)
  end
  return "allow", "git-guard: all git verbs safe (last: " .. last_verb .. ")"
end

--- I/O driver. Reads one JSON document from stdin, runs `decide()`,
--- journals on ask/deny, and emits the Claude Code hook output payload.
--- Always returns 0.
--- @return integer exit_code always 0
function M.main()
  local cjson = require("cjson")
  local raw = io.read("*all") or ""
  local ok, data = pcall(cjson.decode, raw)
  if not ok then
    -- Fail-safe: ask rather than allow on parse error. git-guard
    -- specifically gates dangerous ops; bothering the human is the
    -- right default when we can't read our own input. Distinct from
    -- config-guard's "allow on unparseable input" (config-guard is
    -- defense-in-depth over the OS bind, so failing open is fine).
    lib.emit_hook_output({
      hookSpecificOutput = {
        hookEventName = "PreToolUse",
        permissionDecision = "ask",
        permissionDecisionReason = "git-guard: unparseable hook input; asking",
      },
    })
    return 0
  end
  local decision, reason = M.decide(data)
  lib.emit_hook_output({
    hookSpecificOutput = {
      hookEventName = "PreToolUse",
      permissionDecision = decision,
      permissionDecisionReason = reason,
    },
  })
  return 0
end

if lib.is_main("git-guard.lua") then
  os.exit(M.main())
end

return M
