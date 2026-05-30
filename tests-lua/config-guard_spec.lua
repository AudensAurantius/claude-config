--[[
tests-lua/config-guard_spec.lua — busted unit tests for the
config-guard PreToolUse hook (ClaudeConfig-40s.18, DEC-017, DEC-022).

The hook lives at claude/scripts/hooks/config-guard.lua and exports a
table of testable functions (normalize, is_protected, decide) when
loaded via dofile() — the "run as script" branch only fires when
arg[0] resolves to its own filename.

These tests exercise the pure decision logic (no stdin/stdout I/O).
End-to-end stdin/stdout/journald is covered by the smoke test.
]]

describe("config-guard", function()
    local repo_root = io.popen("git rev-parse --show-toplevel"):read("*line")
    local script_path = repo_root .. "/claude/scripts/hooks/config-guard.lua"
    local original_home = os.getenv("HOME")

    -- Force a deterministic HOME for all tests so PROTECTED resolves
    -- against /home/test, not the dev machine's actual home.
    setup(function()
        os.execute("export HOME=/home/test")  -- noop in subshell; need a different mechanism
    end)

    -- Helper: load the module fresh with a chosen HOME. config-guard
    -- now requires _lib, which captures HOME at first load — clear
    -- the package.loaded["_lib"] cache so each call gets a fresh
    -- _lib with the shadowed HOME. Without this, only the first
    -- load_with_home() actually takes effect.
    local function load_with_home(home)
        package.loaded["_lib"] = nil
        local real_getenv = os.getenv
        os.getenv = function(name)
            if name == "HOME" then return home end
            return real_getenv(name)
        end
        local mod = dofile(script_path)
        os.getenv = real_getenv
        return mod
    end

    describe("normalize()", function()
        local cg = load_with_home("/home/test")

        it("returns nil for empty or nil paths", function()
            assert.is_nil(cg.normalize(nil))
            assert.is_nil(cg.normalize(""))
        end)

        it("returns nil for relative paths (not classifiable)", function()
            assert.is_nil(cg.normalize("foo/bar"))
            assert.is_nil(cg.normalize("./relative"))
        end)

        it("expands ~ to HOME", function()
            assert.are.equal("/home/test/.claude", cg.normalize("~/.claude"))
            assert.are.equal("/home/test", cg.normalize("~"))
        end)

        it("collapses dot-segments", function()
            assert.are.equal("/home/test/.claude/CLAUDE.md",
                cg.normalize("/home/test/.claude/../.claude/CLAUDE.md"))
            assert.are.equal("/etc",
                cg.normalize("/etc/./."))
        end)

        it("deduplicates slashes", function()
            assert.are.equal("/a/b/c", cg.normalize("/a//b///c"))
        end)
    end)

    describe("is_protected()", function()
        local cg = load_with_home("/home/test")

        it("protects the deployed CLAUDE.md", function()
            assert.is_true(cg.is_protected("/home/test/.claude/CLAUDE.md"))
            assert.is_true(cg.is_protected("~/.claude/CLAUDE.md"))
        end)

        it("protects settings.json + settings.local.json + ~/.claude.json", function()
            assert.is_true(cg.is_protected("/home/test/.claude/settings.json"))
            assert.is_true(cg.is_protected("/home/test/.claude/settings.local.json"))
            assert.is_true(cg.is_protected("/home/test/.claude.json"))
        end)

        it("protects /etc/claude-code/* (managed settings)", function()
            assert.is_true(cg.is_protected("/etc/claude-code/managed-settings.json"))
            assert.is_true(cg.is_protected("/etc/claude-code/anything.txt"))
        end)

        it("protects ~/.claude/hooks/ and ~/.claude/scripts/hooks/", function()
            assert.is_true(cg.is_protected("/home/test/.claude/hooks/config-guard.lua"))
            assert.is_true(cg.is_protected("/home/test/.claude/scripts/hooks/x.sh"))
        end)

        it("does NOT protect the repo tree (legitimate self-mod surface)", function()
            assert.is_false(cg.is_protected("/home/hactar/Source/claude-config/CLAUDE.md"))
            assert.is_false(cg.is_protected("/home/hactar/Source/claude-config/sandbox/foo.sh"))
        end)

        it("does NOT protect arbitrary project files", function()
            assert.is_false(cg.is_protected("/tmp/foo.txt"))
            assert.is_false(cg.is_protected("/home/test/project/main.py"))
        end)

        it("resists dot-segment escape attempts", function()
            -- /home/test/.claude/../.claude/CLAUDE.md normalizes to
            -- /home/test/.claude/CLAUDE.md (protected).
            assert.is_true(cg.is_protected("/home/test/.claude/../.claude/CLAUDE.md"))
        end)

        it("does NOT match partial-name prefixes", function()
            -- /home/test/.claude-foo/x should NOT match the
            -- ~/.claude/ prefix (no trailing slash boundary).
            assert.is_false(cg.is_protected("/home/test/.claude-foo/x"))
        end)
    end)

    describe("decide()", function()
        local cg = load_with_home("/home/test")

        it("allows non-write tools regardless of path", function()
            local d, _ = cg.decide({tool_name = "Bash", tool_input = {command = "ls"}})
            assert.are.equal("allow", d)
            d, _ = cg.decide({tool_name = "Read", tool_input = {file_path = "/home/test/.claude/CLAUDE.md"}})
            assert.are.equal("allow", d)
        end)

        it("allows write-class tools to unprotected paths", function()
            for _, tool in ipairs({"Write", "Edit", "MultiEdit", "NotebookEdit"}) do
                local d, r = cg.decide({tool_name = tool, tool_input = {file_path = "/tmp/foo"}})
                assert.are.equal("allow", d, "tool=" .. tool .. " reason=" .. r)
            end
        end)

        it("denies write-class tools to protected paths", function()
            for _, tool in ipairs({"Write", "Edit", "MultiEdit", "NotebookEdit"}) do
                local d, r = cg.decide({
                    tool_name = tool,
                    tool_input = {file_path = "/home/test/.claude/CLAUDE.md"},
                })
                assert.are.equal("deny", d, "tool=" .. tool)
                assert.is_truthy(r:find(tool), "reason should mention tool name")
                assert.is_truthy(r:find("CLAUDE.md"), "reason should mention path")
            end
        end)

        it("handles missing tool_input gracefully", function()
            local d, _ = cg.decide({tool_name = "Write"})
            assert.are.equal("allow", d)  -- empty path → not protected → allow
        end)

        it("handles missing tool_name gracefully", function()
            local d, _ = cg.decide({})
            assert.are.equal("allow", d)  -- empty tool → not in WRITE_TOOLS → allow
        end)

        it("handles nil payload gracefully", function()
            local d, _ = cg.decide(nil)
            assert.are.equal("allow", d)
        end)
    end)
end)
