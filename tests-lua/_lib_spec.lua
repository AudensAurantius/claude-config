--[[
tests-lua/_lib_spec.lua — busted unit tests for the shared hook
utility library (ClaudeConfig-40s.19; DEC-017).
]]

describe("_lib", function()
  local repo_root = io.popen("git rev-parse --show-toplevel"):read("*line")
  local lib_path = repo_root .. "/claude/scripts/hooks/_lib.lua"

  -- Fresh load with a chosen HOME so M.HOME captures it correctly.
  local function load_with_home(home)
    local real_getenv = os.getenv
    os.getenv = function(name)
      if name == "HOME" then
        return home
      end
      return real_getenv(name)
    end
    local mod = dofile(lib_path)
    os.getenv = real_getenv
    return mod
  end

  describe("now_iso()", function()
    local lib = load_with_home("/home/test")

    it("returns an RFC3339-ish UTC string with ms", function()
      local s = lib.now_iso()
      assert.is_truthy(s:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d%.%d%d%dZ$"), "got " .. s)
    end)
  end)

  describe("normalize_path()", function()
    local lib = load_with_home("/home/test")

    it("returns nil for empty/nil/relative", function()
      assert.is_nil(lib.normalize_path(nil))
      assert.is_nil(lib.normalize_path(""))
      assert.is_nil(lib.normalize_path("foo/bar"))
    end)

    it("expands ~ using M.HOME by default", function()
      assert.are.equal("/home/test/.claude", lib.normalize_path("~/.claude"))
      assert.are.equal("/home/test", lib.normalize_path("~"))
    end)

    it("respects home_override when supplied", function()
      assert.are.equal("/other/.claude", lib.normalize_path("~/.claude", "/other"))
    end)

    it("collapses dot-segments + dedupes slashes", function()
      assert.are.equal("/a/b/c", lib.normalize_path("/a//b/./c"))
      assert.are.equal("/etc/foo", lib.normalize_path("/etc/bar/../foo"))
    end)
  end)

  describe("match_paths()", function()
    local lib = load_with_home("/home/test")

    local exact = { "/home/test/.claude/CLAUDE.md", "/etc/claude-code/managed-settings.json" }
    local prefixes = { "/etc/claude-code/", "/home/test/.claude/hooks/" }

    it("matches exact entries", function()
      assert.is_true(lib.match_paths("/home/test/.claude/CLAUDE.md", exact, prefixes))
      assert.is_true(lib.match_paths("~/.claude/CLAUDE.md", exact, prefixes))
    end)

    it("matches under prefix with / boundary", function()
      assert.is_true(lib.match_paths("/etc/claude-code/whatever.json", exact, prefixes))
      assert.is_true(lib.match_paths("/home/test/.claude/hooks/foo.lua", exact, prefixes))
    end)

    it("does NOT match partial-name prefixes (boundary check)", function()
      assert.is_false(lib.match_paths("/etc/claude-code-foo", exact, prefixes))
      assert.is_false(lib.match_paths("/home/test/.claude-foo/x", exact, prefixes))
    end)

    it("resists dot-segment escape", function()
      assert.is_true(lib.match_paths("/home/test/.claude/../.claude/CLAUDE.md", exact, prefixes))
    end)

    it("handles empty exact + prefix sets gracefully", function()
      assert.is_false(lib.match_paths("/anywhere", {}, {}))
      assert.is_false(lib.match_paths("/anywhere", nil, nil))
    end)
  end)

  describe("parse_kv_args()", function()
    local lib = load_with_home("/home/test")

    it("extracts --key=value flags", function()
      local r = lib.parse_kv_args({ "--event=PreToolUse", "--config=foo.yaml" })
      assert.are.equal("PreToolUse", r.event)
      assert.are.equal("foo.yaml", r.config)
    end)

    it("ignores positional + bare-flag args", function()
      local r = lib.parse_kv_args({ "positional", "--bare", "--event=x" })
      assert.are.equal("x", r.event)
      assert.is_nil(r.bare)
      assert.is_nil(r.positional)
    end)

    it("returns empty table for nil/empty argv", function()
      assert.are.same({}, lib.parse_kv_args(nil))
      assert.are.same({}, lib.parse_kv_args({}))
    end)
  end)

  describe("append_jsonl()", function()
    local lib = load_with_home("/home/test")
    local cjson = require("cjson")
    local tmp

    before_each(function()
      tmp = io.popen("mktemp -d"):read("*line")
    end)
    after_each(function()
      os.execute(string.format("rm -rf %q", tmp))
    end)

    it("creates dir + appends one line per call", function()
      local d = tmp .. "/sub/dir"
      assert.is_true(lib.append_jsonl(d, { a = 1, b = "two" }))
      assert.is_true(lib.append_jsonl(d, { a = 2 }))
      local f = io.open(d .. "/tool-calls.jsonl")
      assert.is_not_nil(f)
      local lines = {}
      for line in f:lines() do
        lines[#lines + 1] = line
      end
      f:close()
      assert.are.equal(2, #lines)
      assert.are.equal(1, cjson.decode(lines[1]).a)
      assert.are.equal(2, cjson.decode(lines[2]).a)
    end)

    it("refuses unsafe dir paths", function()
      assert.is_false(lib.append_jsonl(tmp .. "/$(rm -rf /)", {}))
      assert.is_false(lib.append_jsonl(tmp .. "/foo;bar", {}))
    end)

    it("returns false on nil/empty dir", function()
      assert.is_false(lib.append_jsonl(nil, {}))
      assert.is_false(lib.append_jsonl("", {}))
    end)
  end)

  describe("is_main()", function()
    local lib = load_with_home("/home/test")
    -- arg[0] inside busted is something like
    -- "/usr/bin/busted" or busted's wrapped runner — definitely
    -- not a hook basename. So is_main() must return false here.
    it("returns false when loaded via test runner (dofile path)", function()
      assert.is_false(lib.is_main("config-guard.lua"))
      assert.is_false(lib.is_main("audit-event.lua"))
    end)
  end)
end)
