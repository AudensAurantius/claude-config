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

--- @alias config_guard.Decision "allow"|"deny"
--- @alias config_guard.WriteToolName "Write"|"Edit"|"MultiEdit"|"NotebookEdit"

--- @class config_guard.ToolInput
--- @field file_path string? path the write tool is targeting

--- @class config_guard.HookPayload
--- @field tool_name string?
--- @field tool_input config_guard.ToolInput?

local M = {}

--- @type table<string, boolean>
--- The write-class tools whose target paths the hook inspects. Any tool
--- not in this set is allowed unconditionally.
M.WRITE_TOOLS = { Write = true, Edit = true, MultiEdit = true, NotebookEdit = true }

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

--- Thin wrapper over `lib.normalize_path` for test discoverability.
--- @param path string?
--- @return string?
function M.normalize(path)
  return lib.normalize_path(path)
end

--- True iff `path`, after normalization, matches one of the protected
--- exact files or sits under a protected prefix.
--- @param path string
--- @return boolean
function M.is_protected(path)
  return lib.match_paths(path, PROTECTED_PATHS, PROTECTED_PREFIXES)
end

--- Pure decision function. Takes the parsed PreToolUse payload and
--- returns `(decision, reason)`. No I/O — directly testable.
--- @param data config_guard.HookPayload?
--- @return config_guard.Decision decision
--- @return string reason
function M.decide(data)
  local tool = data and data.tool_name or ""
  if not M.WRITE_TOOLS[tool] then
    return "allow", "config-guard: not a write-class tool"
  end
  local input = data and data.tool_input
  --- @type string
  local path = ((type(input) == "table") and input and input.file_path) or ""
  if M.is_protected(path) then
    local reason = string.format(
      "config-guard: blocked %s to deployed Claude config '%s'. "
        .. "Deployed config is managed (read-only to sandboxed sessions); "
        .. "change it in the claude-config repo and reinstall, not in-session.",
      tool,
      path
    )
    return "deny", reason
  end
  return "allow", "config-guard: not a protected config path"
end

--- I/O driver: reads one JSON document from stdin, runs `decide()`,
--- journals on deny, and emits the Claude Code hook output payload.
--- Always returns 0 (fail-open on parse error).
--- @return integer exit_code always 0
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
