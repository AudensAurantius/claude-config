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
local M = {}

-- ── Verb classification tables ──

-- Safe verbs: read-only or purely-informational. Fast-allow.
M.SAFE_VERBS = {
    log = true, diff = true, show = true, status = true,
    ["ls-files"] = true, ["ls-tree"] = true,
    ["rev-parse"] = true, ["rev-list"] = true, ["for-each-ref"] = true,
    ["cat-file"] = true,
    blame = true, describe = true,
    shortlog = true, reflog = true,
    ["symbolic-ref"] = true,
    grep = true,
}

-- Subform-conditional: the bare verb is gated, but the listed
-- subflags (or positional first-args) flip it to safe.
M.SAFE_SUBFORMS = {
    branch = {["--list"] = true, ["--show-current"] = true},
    tag    = {["--list"] = true},
    config = {["--get"]  = true, ["--list"] = true},
    -- `git remote -v` and `git remote show <name>` are read-only.
    remote = {["-v"] = true, show = true},
}

-- ── Config loading (fail-safe) ──

local CONFIG_PATH_DEFAULT = lib.HOME .. "/.claude/hooks/git-guard.yaml"

M.DEFAULT_OPTIONS = {
    fallback_on_unparseable = "ask",
    git_dash_c_policy       = "ask",
}

-- Cached after first load. nil = not yet attempted; false = previously
-- failed (don't retry, just use defaults).
local _config_cache = nil

function M._reset_config_cache()
    _config_cache = nil  -- for tests
end

function M.load_config(path)
    if _config_cache ~= nil then
        return _config_cache or nil
    end
    path = path or CONFIG_PATH_DEFAULT
    local f = io.open(path, "r")
    if not f then
        -- Missing config = use defaults; not an error.
        _config_cache = {options = M.DEFAULT_OPTIONS}
        return _config_cache
    end
    local raw = f:read("*all"); f:close()
    local ok_req, yaml = pcall(require, "lyaml")
    if not ok_req then
        io.stderr:write("git-guard: lyaml unavailable; gated verbs will fall back to ask\n")
        _config_cache = false
        return nil
    end
    local parsed
    local ok_parse, perr = pcall(function() parsed = yaml.load(raw) end)
    if not ok_parse or type(parsed) ~= "table" then
        io.stderr:write("git-guard: config parse error at " .. path
            .. " (" .. tostring(perr) .. "); falling back to defaults\n")
        _config_cache = false
        return nil
    end
    parsed.options = parsed.options or {}
    for k, v in pairs(M.DEFAULT_OPTIONS) do
        if parsed.options[k] == nil then parsed.options[k] = v end
    end
    _config_cache = parsed
    return _config_cache
end

-- ── Cheap fast-path: is there a git invocation anywhere in this command? ──

function M.has_git(command)
    if not command or command == "" then return false end
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
    if not command then return nil, "empty" end
    local tokens = {}
    local cur = {}
    local state = "normal"  -- normal | sq | dq
    local i, n = 1, #command
    while i <= n do
        local c = command:sub(i, i)
        if state == "normal" then
            if c:match("%s") then
                if #cur > 0 then
                    tokens[#tokens + 1] = table.concat(cur)
                    cur = {}
                end
            elseif c == "'" then state = "sq"
            elseif c == '"' then state = "dq"
            elseif c == "\\" and i < n then
                cur[#cur + 1] = command:sub(i + 1, i + 1); i = i + 1
            else cur[#cur + 1] = c end
        elseif state == "sq" then
            if c == "'" then state = "normal" else cur[#cur + 1] = c end
        elseif state == "dq" then
            if c == '"' then state = "normal"
            elseif c == "\\" and i < n then
                cur[#cur + 1] = command:sub(i + 1, i + 1); i = i + 1
            else cur[#cur + 1] = c end
        end
        i = i + 1
    end
    if state ~= "normal" then return nil, "unbalanced quotes" end
    if #cur > 0 then tokens[#tokens + 1] = table.concat(cur) end
    return tokens
end

local SHELL_SEPARATORS = {["&&"] = true, ["||"] = true, [";"] = true, ["|"] = true}

-- Split tokens at shell separators into "commands" (each a token list).
function M.split_commands(tokens)
    local out = {}
    local cur = {}
    for _, t in ipairs(tokens) do
        if SHELL_SEPARATORS[t] then
            if #cur > 0 then out[#out + 1] = cur; cur = {} end
        else
            cur[#cur + 1] = t
        end
    end
    if #cur > 0 then out[#out + 1] = cur end
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
    if i > #tokens or tokens[i] ~= "git" then return nil end
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
            for k = j + 1, #tokens do args[#args + 1] = tokens[k] end
            return arg, args
        end
    end
    return nil
end

-- ── Verb classification ──

function M.classify_verb(verb, args)
    if M.SAFE_VERBS[verb] then return "safe" end
    local subforms = M.SAFE_SUBFORMS[verb]
    if subforms then
        for _, a in ipairs(args or {}) do
            if subforms[a] then return "safe" end
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
    local commands = M.split_commands(tokens)
    local any_git, any_gated, last_verb = false, false, nil
    for _, cmd in ipairs(commands) do
        local verb, args = M.find_git_verb_in_command(cmd)
        if verb then
            any_git = true
            last_verb = verb
            if M.classify_verb(verb, args) == "gated" then
                any_gated = true
                break  -- any gated verb anywhere in the compound → ask
            end
        end
    end

    if not any_git then
        -- `has_git` matched but no actual git invocation parsed
        -- (e.g. `git=value`, comment, string content). Allow.
        return "allow", "git-guard: no git verb found after parse"
    end
    if any_gated then
        return "ask",
            "git-guard: gated git verb in command (C1 placeholder; protected-branch logic in C2/C3)"
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
