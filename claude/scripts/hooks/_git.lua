-- _git.lua — shared utility for invoking git from Lua hooks.
-- ClaudeConfig-bi0.2 (foundation for the git-guard family + future
-- hooks that need git state). Exposes a minimal, stubbable surface:
--
--   git.run(cwd, args)             — low-level capture (stdout, stderr, rc)
--   git.current_branch(cwd)        — `git -C cwd rev-parse --abbrev-ref HEAD`
--   git.origin_head_branch(cwd)    — `git -C cwd symbolic-ref refs/remotes/origin/HEAD`
--
-- Tests stub the functions directly via busted's `stub.new(_git, "...")`.
-- Production shells out to `/usr/bin/git` via io.popen so it picks up the
-- caller's env + config (DEC-016 — claude-session uses its own gitconfig
-- per F-git1 / dsm).

local M = {}

local function shell_quote(s)
  -- Single-quote the argument; escape embedded single quotes.
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

--- Run a git command in the given working directory, capturing stdout.
--- @param cwd string absolute path to the working directory
--- @param args string[] argv to pass after `git -C <cwd>`
--- @return string stdout (trailing newline stripped); "" on failure
--- @return number exit_code 0 on success
function M.run(cwd, args)
  if type(cwd) ~= "string" or cwd == "" then
    return "", 1
  end
  if type(args) ~= "table" then
    return "", 1
  end
  local parts = { "git", "-C", shell_quote(cwd) }
  for _, a in ipairs(args) do
    parts[#parts + 1] = shell_quote(a)
  end
  -- Redirect stderr so we don't pollute the hook's stdout (the Claude
  -- Code hook contract surface). Capture only stdout, plus a trailing
  -- marker line for the exit code. io.popen's close() return value
  -- varies across Lua 5.1 / 5.2+ / LuaJIT (sometimes a boolean,
  -- sometimes a 3-tuple); shell-side capture is portable.
  local cmd = "{ " .. table.concat(parts, " ") .. "; } 2>/dev/null; printf '__rc=%d\\n' \"$?\""
  local p = io.popen(cmd, "r")
  if not p then
    return "", 1
  end
  local raw = p:read("*all") or ""
  p:close()
  local rc = tonumber(raw:match("__rc=(%d+)%s*$") or "1") or 1
  local out = raw:gsub("__rc=%d+%s*$", ""):gsub("\n+$", "")
  return out, rc
end

--- Returns the name of the current branch at `cwd`, or nil on detached
--- HEAD / not-a-repo / failure.
--- @param cwd string
--- @return string?
function M.current_branch(cwd)
  local out, rc = M.run(cwd, { "rev-parse", "--abbrev-ref", "HEAD" })
  if rc ~= 0 or out == "" or out == "HEAD" then
    return nil
  end
  return out
end

--- Returns the branch that `origin/HEAD` points at (with the `origin/`
--- prefix stripped), or nil if not set / no remote / failure.
--- DEC-017 / handoff §2 warns that this is unreliable as a "canonical
--- branch" indicator — use only as a last-resort fallback.
--- @param cwd string
--- @return string?
function M.origin_head_branch(cwd)
  local out, rc = M.run(cwd, { "symbolic-ref", "--short", "refs/remotes/origin/HEAD" })
  if rc ~= 0 or out == "" then
    return nil
  end
  -- Output is "origin/<branch>"; strip prefix.
  local stripped = out:match("^origin/(.+)$")
  return stripped or out
end

return M
