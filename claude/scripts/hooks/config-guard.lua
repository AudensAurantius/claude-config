#!/usr/bin/env lua
--[[
config-guard PreToolUse hook (ClaudeConfig-40s.18; Lua port of the
Python WIP per DEC-017).

Reactive layer-2 over DEC-012's read-only bind / ACL boundary: detects
a sandboxed session attempting to Write/Edit the *deployed* Claude
config (its global CLAUDE.md, settings files, managed settings) and
DENIES it, emitting a journald alert for the audit trail. The bind
already makes those paths read-only (preventative); this surfaces the
*attempt* before the OS write would fail, so tampering is visible,
not silent.

NOT protected: the claude-config *repo* tree (e.g. ~/Source/claude-
config/CLAUDE.md) — that is the legitimate self-modification surface
(edit in the repo, reinstall). Only the DEPLOYED config under the
session's home + the system managed settings are guarded.

PreToolUse contract: reads JSON on stdin
    {"tool_name": "...", "tool_input": {"file_path": "...", ...}, ...}
Emits on stdout:
    {"hookSpecificOutput": {"hookEventName": "PreToolUse",
        "permissionDecision": "deny"|"allow",
        "permissionDecisionReason": "..."}}

Fail-open is the policy for parse/dispatch errors on this hook
specifically — we never want our own bug to block all tool calls in
the session. Matched protected paths always deny.
]]

local cjson = require("cjson")

local M = {}

M.WRITE_TOOLS = {Write = true, Edit = true, MultiEdit = true, NotebookEdit = true}

-- HOME is captured at chunk load. PreToolUse hook processes are short-
-- lived (one fork per tool call), so a single capture is correct. Tests
-- dofile() this module after shadowing os.getenv, so they see the
-- test HOME consistently for the duration of the load.
local HOME = os.getenv("HOME") or "/"

local PROTECTED_PATHS = {
    HOME .. "/.claude/CLAUDE.md",
    HOME .. "/.claude/settings.json",
    HOME .. "/.claude/settings.local.json",
    HOME .. "/.claude.json",
}

local PROTECTED_PREFIXES = {
    "/etc/claude-code/",
    HOME .. "/.claude/scripts/hooks/",
    HOME .. "/.claude/hooks/",
}

-- Expose for tests (e.g. introspecting which HOME was used).
M.HOME = HOME

-- Pure-Lua path normalization: expand `~`, collapse `..`/`.`, dedupe
-- slashes. No symlink resolution: Lua lacks a stdlib realpath, and
-- symlink-based escapes require write access to a parent dir that
-- the OS-layer read-only bind already blocks (so this is in-scope
-- only for the bind+ACL belt-and-suspenders model, not for a defense
-- against attackers who already control the FS).
function M.normalize(path)
    if not path or path == "" then return nil end
    if path:sub(1, 2) == "~/" then
        path = HOME .. path:sub(2)
    elseif path == "~" then
        path = HOME
    end
    if path:sub(1, 1) ~= "/" then
        return nil  -- relative paths aren't classifiable
    end
    path = path:gsub("/+", "/")
    local parts = {}
    for part in path:gmatch("[^/]+") do
        if part == ".." then
            parts[#parts] = nil
        elseif part ~= "." then
            parts[#parts + 1] = part
        end
    end
    return "/" .. table.concat(parts, "/")
end

function M.is_protected(path)
    local p = M.normalize(path)
    if not p then return false end
    for _, target in ipairs(PROTECTED_PATHS) do
        if p == M.normalize(target) then return true end
    end
    for _, prefix in ipairs(PROTECTED_PREFIXES) do
        local n = M.normalize(prefix)
        if n and (p == n or p:sub(1, #n + 1) == n .. "/") then return true end
    end
    return false
end

local function emit(decision, reason)
    io.stdout:write(cjson.encode({
        hookSpecificOutput = {
            hookEventName = "PreToolUse",
            permissionDecision = decision,
            permissionDecisionReason = reason,
        },
    }))
    io.stdout:write("\n")
end

local function alert(msg)
    -- Best-effort journald (systemd-cat); stderr fallback for
    -- non-systemd hosts. Never fatal.
    local p = io.popen("systemd-cat -t claude-config-guard -p warning 2>/dev/null", "w")
    if p then
        p:write(msg)
        local ok = p:close()
        if ok then return end
    end
    io.stderr:write("claude-config-guard: " .. msg .. "\n")
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
    local raw = io.read("*all") or ""
    local ok, data = pcall(cjson.decode, raw)
    if not ok then
        emit("allow", "config-guard: unparseable hook input; allowing")
        return 0
    end
    local decision, reason = M.decide(data)
    if decision == "deny" then alert(reason) end
    emit(decision, reason)
    return 0
end

-- Run as a script when invoked directly (`lua config-guard.lua`);
-- return the module table when loaded via dofile() / require() for
-- testing (in those paths, arg[0] points at the test runner, not
-- this file).
if arg and arg[0] and arg[0]:match("config%-guard%.lua$") then
    os.exit(M.main())
end

return M
