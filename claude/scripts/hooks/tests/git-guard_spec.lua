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

  -- ── C2 (bi0.2) — protected-branch resolution + ask-on-protected ──

  describe("glob_to_lua_pattern() (C2)", function()
    local gg2 = load_with_home("/tmp")

    it("anchors start and end (no partial matches)", function()
      local p = gg2.glob_to_lua_pattern("main")
      assert.is_truthy(("main"):match(p))
      assert.is_falsy(("main-fork"):match(p))
      assert.is_falsy(("origin/main"):match(p))
    end)

    it("translates * to .*", function()
      local p = gg2.glob_to_lua_pattern("release/*")
      assert.is_truthy(("release/1.0"):match(p))
      assert.is_truthy(("release/v2"):match(p))
      assert.is_falsy(("release"):match(p))
      assert.is_falsy(("hotfix/1.0"):match(p))
    end)

    it("translates ? to any single char", function()
      local p = gg2.glob_to_lua_pattern("v?")
      assert.is_truthy(("v1"):match(p))
      assert.is_falsy(("v10"):match(p))
      assert.is_falsy(("v"):match(p))
    end)

    it("escapes Lua-pattern special chars in the literal portion", function()
      local p = gg2.glob_to_lua_pattern("a.b+c")
      assert.is_truthy(("a.b+c"):match(p))
      assert.is_falsy(("axb_c"):match(p))
    end)
  end)

  describe("match_pattern() (C2)", function()
    local gg2 = load_with_home("/tmp")

    it("glob: matches when shape aligns", function()
      assert.is_true(gg2.match_pattern("main", "main"))
      assert.is_true(gg2.match_pattern("release/1.0", "release/*"))
      assert.is_false(gg2.match_pattern("main-fork", "main"))
    end)

    it("re: prefix triggers Lua-pattern regex", function()
      assert.is_true(gg2.match_pattern("DEV", "re:%u+"))
      assert.is_true(gg2.match_pattern("dev/foo/phase-2", "re:dev/[^/]+/phase%-%d+"))
      assert.is_false(gg2.match_pattern("dev/foo", "re:dev/[^/]+/phase%-%d+"))
    end)

    it("returns false on non-string inputs", function()
      assert.is_false(gg2.match_pattern(nil, "main"))
      assert.is_false(gg2.match_pattern("main", nil))
    end)
  end)

  describe("resolve_protected_branches() (C2)", function()
    local gg2 = load_with_home("/tmp")

    it("returns ([], 'none') when config is empty + no origin/HEAD", function()
      -- Stub origin_head_branch to return nil for this test.
      local stub = require("luassert.stub")
      local s = stub.new(gg2._git, "origin_head_branch").returns(nil)
      local patterns, source = gg2.resolve_protected_branches("/anywhere", {})
      assert.are.same({}, patterns)
      assert.are.equal("none", source)
      s:revert()
    end)

    it("falls back to origin_head_branch as last resort", function()
      local stub = require("luassert.stub")
      local s = stub.new(gg2._git, "origin_head_branch").returns("main")
      local patterns, source = gg2.resolve_protected_branches("/anywhere", {})
      assert.are.same({ "main" }, patterns)
      assert.are.equal("origin_head", source)
      s:revert()
    end)

    it("global protected_branches wins over origin/HEAD fallback", function()
      local stub = require("luassert.stub")
      local s = stub.new(gg2._git, "origin_head_branch").returns("main")
      local patterns, source = gg2.resolve_protected_branches("/anywhere", {
        protected_branches = { "develop", "release/*" },
      })
      assert.are.same({ "develop", "release/*" }, patterns)
      assert.are.equal("global", source)
      s:revert()
    end)

    it("per_repo override wins over global (first prefix match)", function()
      local config = {
        protected_branches = { "main" },
        per_repo = {
          { match = "/home/hactar/Source/J121/SmartStore_Base", protected_branches = { "DEV" } },
          { match = "/home/hactar/Source/J121/SmartStore_PlugIns", protected_branches = { "Prototype" } },
        },
      }
      local patterns, source = gg2.resolve_protected_branches("/home/hactar/Source/J121/SmartStore_Base", config)
      assert.are.same({ "DEV" }, patterns)
      assert.are.equal("per_repo", source)

      -- And the second entry matches its repo
      patterns, source = gg2.resolve_protected_branches("/home/hactar/Source/J121/SmartStore_PlugIns", config)
      assert.are.same({ "Prototype" }, patterns)
      assert.are.equal("per_repo", source)
    end)

    it("per_repo matches via prefix with `/` boundary", function()
      local config = {
        protected_branches = { "main" },
        per_repo = { { match = "/repo", protected_branches = { "DEV" } } },
      }
      assert.are.equal("per_repo", select(2, gg2.resolve_protected_branches("/repo", config)))
      assert.are.equal("per_repo", select(2, gg2.resolve_protected_branches("/repo/subdir", config)))
      -- /repo-fork must NOT match /repo (no path-boundary leak)
      assert.are.equal("global", select(2, gg2.resolve_protected_branches("/repo-fork", config)))
    end)

    it("falls through to global when per_repo entries don't match", function()
      local config = {
        protected_branches = { "main" },
        per_repo = { { match = "/other/repo", protected_branches = { "DEV" } } },
      }
      local patterns, source = gg2.resolve_protected_branches("/home/work", config)
      assert.are.same({ "main" }, patterns)
      assert.are.equal("global", source)
    end)
  end)

  describe("decide() — C2 state-changing matrix", function()
    local stub = require("luassert.stub")
    local gg2 = load_with_home("/tmp")
    local current_branch_stub
    local _git_module = gg2._git

    before_each(function()
      current_branch_stub = stub.new(_git_module, "current_branch")
      stub.new(_git_module, "origin_head_branch").returns(nil)
    end)

    after_each(function()
      _git_module.current_branch:revert()
      _git_module.origin_head_branch:revert()
      gg2._reset_config_cache()
    end)

    it("ALLOWS state-changing verb on a feature branch", function()
      current_branch_stub.returns("feat/x")
      -- Use default config (protected_branches = main, master)
      -- inherited from claude/scripts/hooks/git-guard.yaml… but in
      -- tests we don't load that file (HOME=/tmp). Stub the config
      -- explicitly.
      gg2.load_config = function()
        return { protected_branches = { "main", "master" } }
      end
      local d, r = gg2.decide({
        cwd = "/repo",
        tool_input = { command = "git commit -m foo" },
      })
      assert.are.equal("allow", d, r)
    end)

    it("ASKS for state-changing verb on a protected branch", function()
      current_branch_stub.returns("main")
      gg2.load_config = function()
        return { protected_branches = { "main", "master" } }
      end
      local d, r = gg2.decide({
        cwd = "/repo",
        tool_input = { command = "git commit -m foo" },
      })
      assert.are.equal("ask", d)
      assert.is_truthy(r:find("protected branch"))
      assert.is_truthy(r:find("main"))
    end)

    it("ASKS when current branch matches ask_branch_patterns", function()
      current_branch_stub.returns("release/1.0")
      gg2.load_config = function()
        return {
          protected_branches = { "main" },
          ask_branch_patterns = { "release/*" },
        }
      end
      -- Use a verb whose state-changing check truly hinges on current
      -- branch (commit). With `push origin release/1.0`, C3's analyze_push
      -- fires on the refspec dst before C2's current-branch path runs.
      local d, r = gg2.decide({
        cwd = "/repo",
        tool_input = { command = "git commit -m foo" },
      })
      assert.are.equal("ask", d)
      assert.is_truthy(r:find("ask_branch_patterns") or r:find("release/1.0"))
    end)

    it("ASKS when current branch is unavailable (detached HEAD)", function()
      current_branch_stub.returns(nil)
      gg2.load_config = function()
        return { protected_branches = { "main" } }
      end
      local d, r = gg2.decide({
        cwd = "/repo",
        tool_input = { command = "git rebase main" },
      })
      assert.are.equal("ask", d)
      assert.is_truthy(r:find("not on a branch") or r:find("detached"))
    end)

    it("ASKS for non-state-changing gated verbs (C1 fallback)", function()
      current_branch_stub.returns("feat/x")
      gg2.load_config = function()
        return { protected_branches = { "main" } }
      end
      local d, r = gg2.decide({
        cwd = "/repo",
        tool_input = { command = "git clean -fd" },
      })
      assert.are.equal("ask", d)
      assert.is_truthy(r:find("C1 fallback") or r:find("gated"))
    end)

    it("compound: state-changing on protected leg wins over feature leg", function()
      current_branch_stub.returns("main")
      gg2.load_config = function()
        return { protected_branches = { "main" } }
      end
      -- `git status` is safe, `git commit` is state-changing on main
      local d, r = gg2.decide({
        cwd = "/repo",
        tool_input = { command = "git status && git commit -m foo" },
      })
      assert.are.equal("ask", d)
      assert.is_truthy(r:find("protected") or r:find("commit"))
    end)

    it("per_repo override is consulted", function()
      current_branch_stub.returns("DEV")
      gg2.load_config = function()
        return {
          protected_branches = { "main", "master" },
          per_repo = {
            { match = "/home/hactar/SmartStore_Base", protected_branches = { "DEV" } },
          },
        }
      end
      local d, r = gg2.decide({
        cwd = "/home/hactar/SmartStore_Base",
        tool_input = { command = "git commit -m x" },
      })
      assert.are.equal("ask", d, r)
      assert.is_truthy(r:find("DEV"))
    end)
  end)

  -- ── C3 (bi0.3) — ref-rewriting denylist + refspec parsing ──

  describe("parse_push_refspec()", function()
    local gg3 = load_with_home("/tmp")

    it("extracts dst from src:dst form", function()
      local dst, del = gg3.parse_push_refspec("feat:main")
      assert.are.equal("main", dst)
      assert.is_false(del)
    end)

    it("extracts dst from bare-src form (dst = src)", function()
      local dst, del = gg3.parse_push_refspec("feature")
      assert.are.equal("feature", dst)
      assert.is_false(del)
    end)

    it("flags :dst (delete) form", function()
      local dst, del = gg3.parse_push_refspec(":main")
      assert.are.equal("main", dst)
      assert.is_true(del)
    end)

    it("strips leading + (force-push marker) before parsing", function()
      local dst, del = gg3.parse_push_refspec("+feat:main")
      assert.are.equal("main", dst)
      assert.is_false(del)
    end)

    it("returns nil on malformed input", function()
      assert.is_nil((gg3.parse_push_refspec("")))
      assert.is_nil((gg3.parse_push_refspec(nil)))
      assert.is_nil((gg3.parse_push_refspec("a:b:c")))
    end)
  end)

  describe("analyze_push()", function()
    local gg3 = load_with_home("/tmp")
    local ctx = { protected = { "main", "master" }, ask_patterns = { "release/*" } }

    it("returns nil for bare push (defer to C2)", function()
      local d = gg3.analyze_push({}, ctx)
      assert.is_nil(d)
    end)

    it("asks for push to '.' (loopback remote)", function()
      local d, r = gg3.analyze_push({ ".", "master:foo" }, ctx)
      assert.are.equal("ask", d)
      assert.is_truthy(r:find("push %."))
    end)

    it("asks for push --mirror", function()
      local d, r = gg3.analyze_push({ "--mirror", "origin" }, ctx)
      assert.are.equal("ask", d)
      assert.is_truthy(r:find("mirror"))
    end)

    it("asks for push --delete on protected ref", function()
      local d, r = gg3.analyze_push({ "--delete", "origin", "main" }, ctx)
      assert.are.equal("ask", d)
      assert.is_truthy(r:find("delete"))
    end)

    it("asks for push --delete on any ref (delete is always dangerous)", function()
      local d, r = gg3.analyze_push({ "--delete", "origin", "old-feat" }, ctx)
      assert.are.equal("ask", d)
      assert.is_truthy(r:find("delete"))
    end)

    it("asks for :dst (delete refspec)", function()
      local d, r = gg3.analyze_push({ "origin", ":main" }, ctx)
      assert.are.equal("ask", d)
      assert.is_truthy(r:find("deletes a remote ref"))
    end)

    it("asks for src:protected dst", function()
      local d, r = gg3.analyze_push({ "origin", "feat:main" }, ctx)
      assert.are.equal("ask", d)
      assert.is_truthy(r:find("main"))
    end)

    it("asks for force-push without protected dst (history rewrite)", function()
      local d, r = gg3.analyze_push({ "--force", "origin", "feature" }, ctx)
      assert.are.equal("ask", d)
      assert.is_truthy(r:find("force"))
    end)

    it("ALLOWS explicit feature-only refspec (don't fall through to C2)", function()
      local d, r = gg3.analyze_push({ "origin", "feature" }, ctx)
      assert.are.equal("allow", d)
      assert.is_truthy(r:find("explicit refspec"))
    end)

    it("ALLOWS multiple feature-only refspecs", function()
      local d = gg3.analyze_push({ "origin", "feat-a", "feat-b" }, ctx)
      assert.are.equal("allow", d)
    end)

    it("asks for ask_branch_patterns hit (release/*)", function()
      local d, r = gg3.analyze_push({ "origin", "feat:release/1.0" }, ctx)
      assert.are.equal("ask", d)
      assert.is_truthy(r:find("release/1.0"))
    end)
  end)

  describe("analyze_branch()", function()
    local gg3 = load_with_home("/tmp")
    local ctx = { protected = { "main" }, ask_patterns = {} }

    it("returns nil for benign branch invocations", function()
      assert.is_nil((gg3.analyze_branch({ "new-feature" }, ctx)))
    end)

    it("asks for branch -f (always asks, regardless of target)", function()
      local d, r = gg3.analyze_branch({ "-f", "feature", "HEAD" }, ctx)
      assert.are.equal("ask", d)
      assert.is_truthy(r:find("force"))
    end)

    it("asks for branch -d <protected>", function()
      local d, r = gg3.analyze_branch({ "-d", "main" }, ctx)
      assert.are.equal("ask", d)
      assert.is_truthy(r:find("main"))
    end)

    it("asks for branch -D <protected>", function()
      local d = gg3.analyze_branch({ "-D", "main" }, ctx)
      assert.are.equal("ask", d)
    end)

    it("does NOT escalate branch -d <feature> (deferred to generic gated)", function()
      assert.is_nil((gg3.analyze_branch({ "-d", "old-feature" }, ctx)))
    end)

    it("asks for branch --move touching protected ref", function()
      local d, r = gg3.analyze_branch({ "--move", "main", "old-main" }, ctx)
      assert.are.equal("ask", d)
      assert.is_truthy(r:find("main"))
    end)
  end)

  describe("decide() — C3 ref-rewriting matrix (integrated)", function()
    local stub = require("luassert.stub")
    local gg3 = load_with_home("/tmp")

    before_each(function()
      stub.new(gg3._git, "current_branch").returns("feat/x")
      stub.new(gg3._git, "origin_head_branch").returns(nil)
      gg3.load_config = function()
        return {
          protected_branches = { "main", "master" },
          ask_branch_patterns = { "release/*" },
        }
      end
    end)

    after_each(function()
      gg3._git.current_branch:revert()
      gg3._git.origin_head_branch:revert()
      gg3._reset_config_cache()
    end)

    it("asks for `git push origin :main`", function()
      local d, r = gg3.decide({ cwd = "/repo", tool_input = { command = "git push origin :main" } })
      assert.are.equal("ask", d)
      assert.is_truthy(r:find("deletes"))
    end)

    it("asks for `git push origin feat:main`", function()
      local d, r = gg3.decide({ cwd = "/repo", tool_input = { command = "git push origin feat:main" } })
      assert.are.equal("ask", d)
      assert.is_truthy(r:find("main"))
    end)

    it("allows `git push origin feature` from a protected current branch (refspec overrides)", function()
      gg3._git.current_branch:revert()
      stub.new(gg3._git, "current_branch").returns("main")
      local d = gg3.decide({ cwd = "/repo", tool_input = { command = "git push origin feature" } })
      assert.are.equal("allow", d)
    end)

    it("asks for `git push .` (loopback)", function()
      local d, r = gg3.decide({ cwd = "/repo", tool_input = { command = "git push . feat:foo" } })
      assert.are.equal("ask", d)
      assert.is_truthy(r:find("push %."))
    end)

    it("asks for `git push --force` even on feature", function()
      local d, r = gg3.decide({ cwd = "/repo", tool_input = { command = "git push --force origin feature" } })
      assert.are.equal("ask", d)
      assert.is_truthy(r:find("force"))
    end)

    it("asks for `git branch -f` (always)", function()
      local d, r = gg3.decide({ cwd = "/repo", tool_input = { command = "git branch -f main HEAD" } })
      assert.are.equal("ask", d)
      assert.is_truthy(r:find("force"))
    end)

    it("asks for `git branch -D main` (protected delete)", function()
      local d, r = gg3.decide({ cwd = "/repo", tool_input = { command = "git branch -D main" } })
      assert.are.equal("ask", d)
      assert.is_truthy(r:find("main"))
    end)

    it("asks for `git update-ref refs/heads/main HEAD`", function()
      local d, r = gg3.decide({ cwd = "/repo", tool_input = { command = "git update-ref refs/heads/main HEAD" } })
      assert.are.equal("ask", d)
      assert.is_truthy(r:find("update%-ref"))
    end)

    it("asks for `git fetch . main:other` (local-loopback fetch)", function()
      local d, r = gg3.decide({ cwd = "/repo", tool_input = { command = "git fetch . main:other" } })
      assert.are.equal("ask", d)
      assert.is_truthy(r:find("fetch %."))
    end)

    it("falls through to C2 for bare `git push` (no refspec)", function()
      gg3._git.current_branch:revert()
      stub.new(gg3._git, "current_branch").returns("main")
      local d, r = gg3.decide({ cwd = "/repo", tool_input = { command = "git push" } })
      assert.are.equal("ask", d)
      assert.is_truthy(r:find("protected branch"))
    end)
  end)
end)
