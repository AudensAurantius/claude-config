--[[
tests-lua/git-guard_spec.lua — busted unit tests for git-guard
(ClaudeConfig-bi0.1; DEC-017). Covers tokenize, command-splitting,
verb identification, classification, and the integrated decide()
matrix.
]]

describe("git-guard", function()
  local repo_root = io.popen("git rev-parse --show-toplevel"):read("*line")
  local script_path = repo_root .. "/claude/scripts/hooks/git-guard.lua"

  local function load_with_home(home)
    package.loaded["_lib"] = nil
    package.loaded["git-guard"] = nil
    local real_getenv = os.getenv
    os.getenv = function(name)
      if name == "HOME" then
        return home
      end
      return real_getenv(name)
    end
    local mod = dofile(script_path)
    os.getenv = real_getenv
    mod._reset_config_cache()
    return mod
  end

  local gg = load_with_home("/tmp")

  describe("has_git()", function()
    it("matches `git` as a standalone token", function()
      assert.is_true(gg.has_git("git status"))
      assert.is_true(gg.has_git("cd foo && git push"))
      assert.is_true(gg.has_git("FOO=bar git commit"))
    end)

    it("does NOT match `git` embedded in an identifier", function()
      assert.is_false(gg.has_git("git_log=verbose"))
      assert.is_false(gg.has_git("agitate"))
      assert.is_false(gg.has_git("legitimate"))
    end)

    it("returns false on empty/nil input", function()
      assert.is_false(gg.has_git(""))
      assert.is_false(gg.has_git(nil))
    end)
  end)

  describe("tokenize()", function()
    it("splits on whitespace", function()
      assert.are.same({ "git", "status" }, gg.tokenize("git status"))
      assert.are.same({ "a", "b", "c" }, gg.tokenize("a   b\tc"))
    end)

    it("preserves single-quoted strings literally", function()
      assert.are.same({ "git", "log", "--grep=foo bar" }, gg.tokenize("git log '--grep=foo bar'"))
    end)

    it("preserves double-quoted strings; processes \\ escapes inside", function()
      assert.are.same({ "git", "log", "--grep=foo bar" }, gg.tokenize('git log "--grep=foo bar"'))
      assert.are.same({ 'a"b' }, gg.tokenize('"a\\"b"'))
    end)

    it("returns nil + error on unbalanced quotes", function()
      local t, err = gg.tokenize('git log "unbalanced')
      assert.is_nil(t)
      assert.are.equal("unbalanced quotes", err)
    end)
  end)

  describe("split_commands()", function()
    it("splits on shell separators", function()
      local toks = gg.tokenize("cd foo && git status ; ls")
      assert.are.same({ { "cd", "foo" }, { "git", "status" }, { "ls" } }, gg.split_commands(toks))
    end)

    it("preserves single-command inputs as one entry", function()
      local toks = gg.tokenize("git push origin main")
      assert.are.same({ { "git", "push", "origin", "main" } }, gg.split_commands(toks))
    end)
  end)

  describe("find_git_verb_in_command()", function()
    it("extracts the verb from bare git invocations", function()
      local v, args = gg.find_git_verb_in_command({ "git", "status" })
      assert.are.equal("status", v)
      assert.are.same({}, args)
      v, args = gg.find_git_verb_in_command({ "git", "log", "-p", "HEAD" })
      assert.are.equal("log", v)
      assert.are.same({ "-p", "HEAD" }, args)
    end)

    it("skips env-var prefixes", function()
      local v = gg.find_git_verb_in_command({ "FOO=bar", "BAZ=qux", "git", "push" })
      assert.are.equal("push", v)
    end)

    it("skips git-level flag/value pairs", function()
      assert.are.equal("status", gg.find_git_verb_in_command({ "git", "-C", "/repo", "status" }))
      assert.are.equal("status", gg.find_git_verb_in_command({ "git", "-c", "user.name=x", "status" }))
      assert.are.equal("commit", gg.find_git_verb_in_command({ "git", "--git-dir", "/r/.git", "commit" }))
    end)

    it("handles joined --flag=value forms", function()
      assert.are.equal("status", gg.find_git_verb_in_command({ "git", "--git-dir=/r/.git", "status" }))
    end)

    it("returns nil when no git invocation in the command", function()
      assert.is_nil(gg.find_git_verb_in_command({ "cd", "foo" }))
      assert.is_nil(gg.find_git_verb_in_command({ "NAME=val", "true" }))
    end)
  end)

  describe("classify_verb()", function()
    it("recognizes safe read-only verbs", function()
      for _, v in ipairs({
        "log",
        "diff",
        "show",
        "status",
        "ls-files",
        "rev-parse",
        "cat-file",
        "blame",
      }) do
        assert.are.equal("safe", gg.classify_verb(v, {}), "expected safe: " .. v)
      end
    end)

    it("gates bare verbs that have safe subforms", function()
      assert.are.equal("gated", gg.classify_verb("branch", {}))
      assert.are.equal("gated", gg.classify_verb("config", {}))
      assert.are.equal("gated", gg.classify_verb("remote", {}))
    end)

    it("flips subform-conditional verbs to safe when subflag present", function()
      assert.are.equal("safe", gg.classify_verb("branch", { "--list" }))
      assert.are.equal("safe", gg.classify_verb("branch", { "--show-current" }))
      assert.are.equal("safe", gg.classify_verb("config", { "--get", "user.name" }))
      assert.are.equal("safe", gg.classify_verb("config", { "--list" }))
      assert.are.equal("safe", gg.classify_verb("remote", { "-v" }))
      assert.are.equal("safe", gg.classify_verb("remote", { "show", "origin" }))
      assert.are.equal("safe", gg.classify_verb("tag", { "--list" }))
    end)

    it("gates the obviously-dangerous verbs", function()
      for _, v in ipairs({
        "push",
        "commit",
        "merge",
        "rebase",
        "reset",
        "checkout",
        "switch",
        "clean",
        "stash",
      }) do
        assert.are.equal("gated", gg.classify_verb(v, {}), "expected gated: " .. v)
      end
    end)
  end)

  describe("decide() — integrated matrix", function()
    it("allows non-git commands", function()
      local d = gg.decide({ tool_input = { command = "ls -la" } })
      assert.are.equal("allow", d)
    end)

    it("allows safe git invocations", function()
      for _, c in ipairs({
        "git status",
        "git log -p HEAD",
        "git diff --stat",
        "git -C /repo status",
        "FOO=bar git rev-parse HEAD",
      }) do
        local d, r = gg.decide({ tool_input = { command = c } })
        assert.are.equal("allow", d, "expected allow for: " .. c .. " (got " .. d .. " :: " .. r .. ")")
      end
    end)

    it("asks on gated verbs (C1 placeholder)", function()
      for _, c in ipairs({
        "git push",
        "git commit -m ok",
        "git branch new-feature", -- bare branch, no --list
        "git checkout -b feat/x",
        "git reset --hard HEAD~1",
      }) do
        local d = gg.decide({ tool_input = { command = c } })
        assert.are.equal("ask", d, "expected ask for: " .. c)
      end
    end)

    it("upgrades safe subforms to allow", function()
      local d = gg.decide({ tool_input = { command = "git branch --list" } })
      assert.are.equal("allow", d)
      d = gg.decide({ tool_input = { command = "git remote -v" } })
      assert.are.equal("allow", d)
    end)

    it("asks if any leg of a compound has a gated verb", function()
      local d = gg.decide({ tool_input = { command = "git status && git push" } })
      assert.are.equal("ask", d)
    end)

    it("allows compounds whose every git leg is safe", function()
      local d = gg.decide({ tool_input = { command = "git fetch || git status" } })
      -- `fetch` isn't in our safe-verbs list, so we expect ask;
      -- this confirms our list is conservative (intentionally so
      -- — fetch can pull anything from any remote).
      assert.are.equal("ask", d)
      d = gg.decide({ tool_input = { command = "git status && git diff" } })
      assert.are.equal("allow", d)
    end)

    it("uses fallback_on_unparseable on tokenizer failure", function()
      local d = gg.decide({ tool_input = { command = "git log 'unbalanced" } })
      assert.are.equal("ask", d) -- default fallback
    end)

    it("handles `git=value` (assignment to var named git) as not-git", function()
      -- has_git() returns true (the substring matches the bound
      -- pattern), but find_git_verb_in_command returns nil because
      -- the token "git=value" is an env-assignment, not the
      -- literal "git" token.
      local d = gg.decide({ tool_input = { command = "git=hello echo $git" } })
      assert.are.equal("allow", d)
    end)
  end)
end)
