#!/usr/bin/env lua
--[[
config-guard PreToolUse hook (ClaudeConfig-40s.18; Lua per DEC-017).

Reactive layer-2 over DEC-012's read-only bind / ACL boundary: detects
a sandboxed session attempting to Write/Edit the *deployed* Claude
config (its global CLAUDE.md, settings files, managed settings) and
DENIES it, emitting a journald alert for the audit trail. The bind
already makes those paths read-only (preventative); this surfaces the
*attempt* before the OS write would fail, so tampering is visible,
not silent.

NOT protected: the claude-config *repo* tree — that's the legitimate
self-modification surface. Only the DEPLOYED config under the
session's home + the system managed settings are guarded.

Fail-open is the policy for parse errors on this hook (we never want
our own bug to block all tool calls). Matched protected paths always
deny.
]]

local lib = require("_lib")
local M = {}

M.WRITE_TOOLS = {Write = true, Edit = true, MultiEdit = true, NotebookEdit = true}

local PROTECTED_PATHS = {
    lib.HOME .. "/.claude/CLAUDE.md",
    lib.HOME .. "/.claude/settings.json",
    lib.HOME .. "/.claude/settings.local.json",
    lib.HOME .. "/.claude.json",
}

local PROTECTED_PREFIXES = {
    "/etc/claude-code/",
    lib.HOME .. "/.claude/scripts/hooks/",
    lib.HOME .. "/.claude/hooks/",
}

M.HOME = lib.HOME

-- Exposed for tests; thin wrappers over the lib's generic helpers
-- with this hook's specific path tables baked in.
function M.normalize(path) return lib.normalize_path(path) end
function M.is_protected(path)
    return lib.match_paths(path, PROTECTED_PATHS, PROTECTED_PREFIXES)
end

-- Pure decision function: takes the parsed PreToolUse payload and
-- returns (decision, reason). No I/O — directly testable.
function M.decide(data)
    local tool = data and data.tool_name or ""
    if not M.WRITE_TOOLS[tool] then
        return "allow", "config-guard: not a write-class tool"
    end
    local input = data.tool_input
    local path = (type(input) == "table") and input.file_path or ""
    if M.is_protected(path) then
        local reason = string.format(
            "config-guard: blocked %s to deployed Claude config '%s'. "
            .. "Deployed config is managed (read-only to sandboxed sessions); "
            .. "change it in the claude-config repo and reinstall, not in-session.",
            tool, path)
        return "deny", reason
    end
    return "allow", "config-guard: not a protected config path"
end

function M.main()
    local cjson = require("cjson")
    local raw = io.read("*all") or ""
    local ok, data = pcall(cjson.decode, raw)
    if not ok then
        lib.emit_hook_output({
            hookSpecificOutput = {
                hookEventName = "PreToolUse",
                permissionDecision = "allow",
                permissionDecisionReason = "config-guard: unparseable hook input; allowing",
            },
        })
        return 0
    end
    local decision, reason = M.decide(data)
    if decision == "deny" then
        lib.journal("claude-config-guard", "warning", reason)
    end
    lib.emit_hook_output({
        hookSpecificOutput = {
            hookEventName = "PreToolUse",
            permissionDecision = decision,
            permissionDecisionReason = reason,
        },
    })
    return 0
end

if lib.is_main("config-guard.lua") then
    os.exit(M.main())
end

return M
