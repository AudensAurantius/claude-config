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

function M._reset_config_cache()
  _config_cache = nil -- for tests
end

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

-- Split tokens at shell separators into "commands" (each a token list).
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

-- Check whether a branch name matches any pattern in the list.
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
function M.analyze_push(args, ctx)
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

-- Analyze a `git branch` invocation. Returns (decision, reason) when a
-- ref-rewrite concern fires; nil otherwise.
function M.analyze_branch(args, ctx)
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

-- ── C4: branch-naming enforcement ──

-- Extract the new branch name being CREATED by a given verb+args, if any.
-- Returns the name string or nil. Detects:
--   git checkout -b NAME [start]
--   git checkout -B NAME [start]
--   git switch   -c NAME [start]
--   git switch   -C NAME [start]
--   git branch    NAME [start]      (bare; no -d/-D/-f/--list/etc.)
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
  local protected_hit, generic_gated = nil, false

  -- Lazy-resolved per-decide-call: only compute current-branch + protected
  -- list when we actually see a STATE_CHANGING verb. Caches for the
  -- compound walk so we don't shell out to git twice.
  local cfg_cache, branch_cache, patterns_cache
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
