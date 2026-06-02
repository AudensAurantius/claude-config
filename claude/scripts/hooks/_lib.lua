--[[
_lib.lua — shared utilities for claude-config hook scripts
(ClaudeConfig-40s.19; DEC-017 Lua port).

Required by config-guard.lua, audit-event.lua, and (in time) the
git-guard family + telemetry hook. Wrapper sets LUA_PATH so
`require("_lib")` resolves both at the install path and inside
claude-session's assembled home.

Extraction policy: pure utility code lives here. Hook-specific
domain (protected-path tables, tool-name matchers, record shapes)
stays in each hook. See bd memory `lua-hook-not-extracted`.

Functions:
    M.HOME                            — captured at chunk load
    M.now_iso()                       — RFC3339-ish UTC timestamp (ms)
    M.normalize_path(path[, home])    — pure-Lua realpath-lite
    M.match_paths(p, paths, prefixes) — path membership against
                                          exact set + prefix set
    M.parse_kv_args(argv)             — extract --key=value into table
    M.journal(tag, priority, line)    — systemd-cat + stderr fallback
    M.emit_hook_output(payload)       — cjson.encode + newline to stdout
    M.append_jsonl(dir, record)       — mkdir -p + append one line
    M.is_main(basename)               — arg[0]-matches-this-file guard
]]

local cjson = require("cjson")

--- @alias _lib.JournalPriority "emerg"|"alert"|"crit"|"err"|"warning"|"notice"|"info"|"debug"
--- The systemd-cat priority levels accepted by `journal()`. We use only a
--- handful in practice (`info`, `warning`, `err`).

local M = {}

--- @type string
--- `$HOME` at chunk-load time. Captured once so subsequent `os.getenv`
--- mutations (e.g. tests that swap HOME after load) don't affect the
--- cached value. Tests reset by clearing `package.loaded["_lib"]` before
--- re-`require`-ing.
M.HOME = os.getenv("HOME") or "/"

-- ── Time ────────────────────────────────────────────────────────────

--- RFC3339-ish UTC timestamp with millisecond precision.
--- Best-effort: Lua stdlib only exposes second granularity on `os.time`;
--- we approximate ms via `os.clock() % 1`. Sufficient for ordering audit
--- records that arrive >1 ms apart.
--- @return string iso8601 e.g. "2026-06-01T19:30:00.123Z"
function M.now_iso()
  -- Best-effort millisecond precision: Lua stdlib clock is seconds;
  -- os.clock() gives fractional CPU seconds since process start as
  -- an approximation. Adjacent audit events typically arrive
  -- >1 ms apart so the ordering is still meaningful.
  local t = os.time()
  local ms = math.floor((os.clock() % 1) * 1000)
  return os.date("!%Y-%m-%dT%H:%M:%S", t) .. string.format(".%03dZ", ms)
end

-- ── Paths ───────────────────────────────────────────────────────────

--- Pure-Lua realpath-lite. Expands `~`, collapses `..`/`.`, dedupes
--- slashes. No symlink resolution (Lua lacks a stdlib realpath;
--- symlink-escape requires write access that the OS-layer bind already
--- blocks in our threat model).
--- @param path string? input path; may be `~`/`~/...`-prefixed
--- @param home_override string? overrides `M.HOME` for `~` expansion
---        (test-only)
--- @return string? absolute_normalized nil for empty / nil /
---         unclassifiable-relative inputs
function M.normalize_path(path, home_override)
  if not path or path == "" then
    return nil
  end
  local home = home_override or M.HOME
  if path:sub(1, 2) == "~/" then
    path = home .. path:sub(2)
  elseif path == "~" then
    path = home
  end
  if path:sub(1, 1) ~= "/" then
    return nil
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

--- Path-membership test against an exact set + prefix set.
--- Normalizes everything internally; the `/` boundary on prefixes
--- means `/foo` does NOT match `/foo-bar`.
--- @param path string the candidate path
--- @param exact_paths string[]? paths to compare for exact equality
--- @param prefixes string[]? path prefixes (matched with `/` boundary)
--- @return boolean matched true on any hit
function M.match_paths(path, exact_paths, prefixes)
  local p = M.normalize_path(path)
  if not p then
    return false
  end
  for _, target in ipairs(exact_paths or {}) do
    if p == M.normalize_path(target) then
      return true
    end
  end
  for _, prefix in ipairs(prefixes or {}) do
    local n = M.normalize_path(prefix)
    if n and (p == n or p:sub(1, #n + 1) == n .. "/") then
      return true
    end
  end
  return false
end

-- ── Arg parsing ────────────────────────────────────────────────────

--- Extract `--key=value` flags from argv into a flat table.
--- Ignores positional args + bare flags. Sufficient for hook entry
--- points; not a full argparse.
--- @param argv string[]? argument vector (e.g. Lua's global `arg`)
--- @return table<string,string> kv flag-name → string value
function M.parse_kv_args(argv)
  local out = {}
  for _, a in ipairs(argv or {}) do
    local k, v = a:match("^%-%-([%w_%-]+)=(.+)$")
    if k then
      out[k] = v
    end
  end
  return out
end

-- ── Output ──────────────────────────────────────────────────────────

--- Send a single line to journald via `systemd-cat` with the given tag
--- and priority. Falls back to stderr on systems without systemd-cat.
--- Never fatal.
--- @param tag string syslog tag (typically the hook name)
--- @param priority _lib.JournalPriority systemd-cat priority level
--- @param line string the log payload (no trailing newline needed)
--- @return boolean ok true iff `systemd-cat` accepted the line
function M.journal(tag, priority, line)
  local cmd = string.format("systemd-cat -t %q -p %q 2>/dev/null", tag, priority)
  local p = io.popen(cmd, "w")
  if p then
    p:write(line)
    local ok = p:close()
    if ok then
      return true
    end
  end
  io.stderr:write(tag .. ": " .. line .. "\n")
  return false
end

--- Write a Claude Code hook output payload (a `hookSpecificOutput`-
--- shaped table) as one line of JSON on stdout. The Claude Code runtime
--- consumes one JSON document per line.
--- @param payload table any JSON-encodable hook output
function M.emit_hook_output(payload)
  io.stdout:write(cjson.encode(payload))
  io.stdout:write("\n")
end

--- Append one JSONL line (cjson.encode(record) + newline) to
--- `<dir>/tool-calls.jsonl`, creating `<dir>` if it doesn't exist.
--- Refuses if `dir` contains characters outside `[A-Za-z0-9_.\-/]` —
--- guards against shell-injection through hook-input fields like
--- session_id (opaque from our standpoint).
--- @param dir string target directory; created with `mkdir -p` if absent
--- @param record table any JSON-encodable record
--- @return boolean ok true on success, false (with stderr diagnostic)
---         otherwise
function M.append_jsonl(dir, record)
  if not dir or dir == "" then
    return false
  end
  if dir:find("[^%w%-%./_]") then
    io.stderr:write("_lib.append_jsonl: unsafe dir path; skipping\n")
    return false
  end
  os.execute(string.format("mkdir -p %q", dir))
  local f, err = io.open(dir .. "/tool-calls.jsonl", "a")
  if not f then
    io.stderr:write("_lib.append_jsonl: open failed: " .. (err or "") .. "\n")
    return false
  end
  f:write(cjson.encode(record))
  f:write("\n")
  f:close()
  return true
end

-- ── Runner guard ───────────────────────────────────────────────────

--- Runner-vs-library guard. True iff the script was invoked directly
--- as `<basename>` (vs being loaded via `dofile`/`require` from a test
--- runner). The canonical pattern in each hook entry point:
---
---     if lib.is_main("my-hook.lua") then os.exit(M.main(arg)) end
---     return M
---
--- @param basename string the hook's filename (matched with end-of-string)
--- @return boolean is_main
function M.is_main(basename)
  if not (arg and arg[0]) then
    return false
  end
  -- Pattern: end-of-string match for basename (escape dots).
  local pat = basename:gsub("([%.%-])", "%%%1") .. "$"
  return arg[0]:match(pat) ~= nil
end

return M
