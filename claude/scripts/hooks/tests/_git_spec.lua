--[[
tests/_git_spec.lua — busted unit tests for the _git shared module.
ClaudeConfig-bi0.2. Tests stub-mode the io.popen call; one integration
case exercises a real git invocation against the repo itself.
]]

describe("_git", function()
  local repo_root = io.popen("git rev-parse --show-toplevel"):read("*line")
  local lib_path = repo_root .. "/claude/scripts/hooks/_git.lua"

  local function fresh_load()
    package.loaded["_git"] = nil
    return dofile(lib_path)
  end

  describe("run() (real git invocation)", function()
    local git = fresh_load()

    it("returns (stdout, 0) on success", function()
      local out, rc = git.run(repo_root, { "rev-parse", "--show-toplevel" })
      assert.are.equal(0, rc)
      assert.are.equal(repo_root, out)
    end)

    it('returns ("", non-zero rc) on failure', function()
      -- An unknown subcommand reliably exits non-zero across git versions.
      local out, rc = git.run(repo_root, { "this-is-not-a-real-git-subcommand-xyz" })
      assert.are_not.equal(0, rc)
      assert.are.equal("", out)
    end)

    it('returns ("", 1) on empty/invalid input', function()
      local out, rc = git.run("", { "status" })
      assert.are.equal("", out)
      assert.are.equal(1, rc)
      out, rc = git.run(repo_root, nil)
      assert.are.equal("", out)
      assert.are.equal(1, rc)
    end)
  end)

  describe("current_branch()", function()
    local git = fresh_load()

    it("returns the current branch for a real repo", function()
      local b = git.current_branch(repo_root)
      assert.is_string(b)
      assert.is_truthy(#b > 0)
      -- We're running this from the repo's working tree; should match
      -- `git symbolic-ref --short HEAD`.
      local expected = io.popen("git -C '" .. repo_root .. "' rev-parse --abbrev-ref HEAD"):read("*line")
      assert.are.equal(expected, b)
    end)

    it("returns nil for a non-repo cwd", function()
      assert.is_nil(git.current_branch("/tmp"))
    end)
  end)

  describe("origin_head_branch()", function()
    local git = fresh_load()

    it("returns nil when no remote / no origin/HEAD set", function()
      -- This repo's clone may or may not have origin/HEAD set; we
      -- can't assert a specific value. Just verify the function
      -- returns either nil or a non-empty string (and no error).
      local b = git.origin_head_branch(repo_root)
      if b ~= nil then
        assert.is_string(b)
        assert.is_truthy(#b > 0)
        -- Verify the origin/ prefix is stripped.
        assert.are_not.equal("origin/", b:sub(1, 7))
      end
    end)

    it("returns nil for a non-repo cwd", function()
      assert.is_nil(git.origin_head_branch("/tmp"))
    end)
  end)
end)
