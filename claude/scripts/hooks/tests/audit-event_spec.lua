--[[
tests-lua/audit-event_spec.lua — busted unit tests for audit-event
(ClaudeConfig-40s.19; DEC-017).

End-to-end stdin/stdout/journald is covered by the smoke test; these
target the pure build_record / journal_line helpers + the cache_root
indirection (so a real session_id-named subdir lands in claude-
session's home in production).
]]

describe("audit-event", function()
  local repo_root = io.popen("git rev-parse --show-toplevel"):read("*line")
  local script_path = repo_root .. "/claude/scripts/hooks/audit-event.lua"
  local cjson = require("cjson")

  local function load_with_home(home)
    package.loaded["_lib"] = nil
    local real_getenv = os.getenv
    os.getenv = function(name)
      if name == "HOME" then
        return home
      end
      return real_getenv(name)
    end
    local mod = dofile(script_path)
    os.getenv = real_getenv
    return mod
  end

  describe("build_record()", function()
    local ae = load_with_home("/home/test")

    it("propagates session_id, tool_name, tool_input, cwd, event", function()
      local r = ae.build_record("PreToolUse", {
        session_id = "abc-123",
        tool_name = "Bash",
        tool_input = { command = "ls" },
        cwd = "/tmp",
      }, "2026-05-30T00:00:00.000Z")
      assert.are.equal("PreToolUse", r.event)
      assert.are.equal("abc-123", r.session_id)
      assert.are.equal("Bash", r.tool_name)
      assert.are.equal("ls", r.tool_input.command)
      assert.are.equal("/tmp", r.cwd)
      assert.are.equal("2026-05-30T00:00:00.000Z", r.ts)
    end)

    it("includes tool_response only when present (PostToolUse)", function()
      local pre = ae.build_record("PreToolUse", { session_id = "x", tool_name = "Bash" })
      assert.is_nil(pre.tool_response)
      local post = ae.build_record("PostToolUse", {
        session_id = "x",
        tool_name = "Bash",
        tool_response = { exit_code = 0 },
      })
      assert.are.equal(0, post.tool_response.exit_code)
    end)

    it("handles nil/empty payload gracefully", function()
      local r = ae.build_record("PreToolUse", nil)
      assert.are.equal("PreToolUse", r.event)
      assert.is_nil(r.session_id)
      assert.is_nil(r.tool_name)
    end)
  end)

  describe("journal_line()", function()
    local ae = load_with_home("/home/test")

    it("emits compact JSON with the standard fields", function()
      local record = {
        ts = "2026-05-30T00:00:00.000Z",
        event = "PreToolUse",
        session_id = "abc",
        tool_name = "Bash",
        tool_input = { command = "ls -la" },
        cwd = "/tmp",
      }
      local line = ae.journal_line(record)
      local decoded = cjson.decode(line)
      assert.are.equal("PreToolUse", decoded.event)
      assert.are.equal("Bash", decoded.tool)
      assert.are.equal("abc", decoded.session)
      assert.are.equal("/tmp", decoded.cwd)
      -- tool_input is NOT in the journald summary (forensic
      -- detail lives in the JSONL, not the systemd log).
      assert.is_nil(decoded.tool_input)
    end)
  end)

  describe("cache_root()", function()
    it("resolves against the captured HOME", function()
      local ae1 = load_with_home("/home/A")
      assert.are.equal("/home/A/.cache/claude-config", ae1.cache_root())
      local ae2 = load_with_home("/home/B")
      assert.are.equal("/home/B/.cache/claude-config", ae2.cache_root())
    end)
  end)
end)
