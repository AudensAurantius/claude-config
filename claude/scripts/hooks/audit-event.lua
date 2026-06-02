#!/usr/bin/env lua
--[[
audit-event PreToolUse + PostToolUse hook (ClaudeConfig-40s.19;
DEC-017 Lua port). One handler shared between both events; the
--event=PreToolUse / --event=PostToolUse arg selects which.

Per the audit-log architecture from 40s.13's FOLLOWUP.md Q5:
each tool call produces (a) one journald entry tagged
"claude-session" (-p info) so `journalctl _UID=<claude-session-uid>`
is the natural query interface, plus (b) one JSONL line appended to
`$HOME/.cache/claude-config/<session-id>/tool-calls.jsonl`. Composes
with DEC-012's UID separation.

Both emissions are best-effort. The hook NEVER blocks tool execution
— PreToolUse always emits allow; PostToolUse emits no decision
(informational, post-hoc).

PreToolUse input:  {session_id, tool_name, tool_input, cwd}
PostToolUse input: {session_id, tool_name, tool_input, tool_response, cwd}
]]

local lib = require("_lib")
local M = {}

M.HOME = lib.HOME

-- Override hook for tests (point at tmp dir); production reads from
-- claude-session's HOME-relative cache.
function M.cache_root()
  return lib.HOME .. "/.cache/claude-config"
end

-- Build the structured payload from the parsed input + event tag.
-- Pure function; directly testable.
function M.build_record(event, data, now)
  return {
    ts = now or lib.now_iso(),
    event = event,
    session_id = data and data.session_id or nil,
    tool_name = data and data.tool_name or nil,
    tool_input = data and data.tool_input or nil,
    tool_response = data and data.tool_response or nil,
    cwd = data and data.cwd or nil,
  }
end

-- Compose the one-line journald summary. Compact JSON for downstream
-- parseability (40s.21 / OTEL Collector consumes the same shape).
function M.journal_line(record)
  local cjson = require("cjson")
  return cjson.encode({
    event = record.event,
    tool = record.tool_name,
    session = record.session_id,
    cwd = record.cwd,
  })
end

function M.main(argv)
  local cjson = require("cjson")
  local flags = lib.parse_kv_args(argv)
  local event = flags.event or "Unknown"

  local raw = io.read("*all") or ""
  local ok, data = pcall(cjson.decode, raw)
  if not ok then
    io.stderr:write("audit-event: unparseable hook input; emitting decision only\n")
    data = nil
  end

  if data then
    local record = M.build_record(event, data)
    lib.journal("claude-session", "info", M.journal_line(record))
    if record.session_id and record.session_id ~= "" then
      lib.append_jsonl(M.cache_root() .. "/" .. record.session_id, record)
    end
  end

  -- PreToolUse needs an explicit allow; PostToolUse just acknowledges
  -- the event without a decision field.
  if event == "PreToolUse" then
    lib.emit_hook_output({
      hookSpecificOutput = {
        hookEventName = "PreToolUse",
        permissionDecision = "allow",
        permissionDecisionReason = "audit-event: informational; not a gate",
      },
    })
  else
    lib.emit_hook_output({
      hookSpecificOutput = { hookEventName = event },
    })
  end
  return 0
end

if lib.is_main("audit-event.lua") then
  os.exit(M.main(arg))
end

return M
