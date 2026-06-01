# Hook plumbing

How system-shipped Claude Code hooks (PreToolUse, PostToolUse) are
authored, deployed, and wired into `claude-session`'s sandbox under
DEC-017's Lua/LuaJIT runtime choice.

Audience: hook authors, maintainers, and anyone debugging why a hook
isn't firing.

---

## Two tiers of hooks

| Tier | Where | Language | Provisioning |
|---|---|---|---|
| **1. System-shipped fast-path** (`config-guard`, `audit-event`, the upcoming `git-guard` family) | This repo, under `claude/scripts/hooks/` | **Lua/LuaJIT** (DEC-017; ~1 ms cold start vs Python's ~50 ms) | Shipped by `just install`; mirrored into `~/.claude/hooks/` at session boot by the wrapper |
| **2. Project-specific** (per-project guards, project-author-defined) | `<project>/.claude-session/hooks/` | Python, Node, Bash, Perl, or Lua (DEC-020) via `#!` shebang dispatch | Interpreters provisioned once-per-install in claude-session's home |

This page covers Tier 1. See [DEC-020](../../DECISION_LOG.md) for the
Tier 2 contract.

## Shared utility library: `_lib.lua`

Every Tier 1 hook requires `_lib` from the sibling directory:

```lua
local lib = require("_lib")
```

Resolved via `LUA_PATH` set in `profiles/default.yaml` (see
"Deployment subtleties" below). The library exposes:

| Function | Purpose |
|---|---|
| `lib.HOME` | Captured at chunk load — `$HOME` at process start |
| `lib.now_iso()` | RFC3339-ish UTC timestamp with ms |
| `lib.normalize_path(path[, home])` | Pure-Lua realpath-lite: expands `~`, collapses `..`/`.`, dedups slashes. No symlink resolution |
| `lib.match_paths(p, exact_set, prefix_set)` | Path membership against exact list + prefix list (with `/` boundary) |
| `lib.parse_kv_args(argv)` | Extract `--key=value` flags into a table |
| `lib.journal(tag, priority, line)` | Best-effort `systemd-cat`; stderr fallback |
| `lib.emit_hook_output(payload)` | `cjson.encode` + newline to stdout |
| `lib.append_jsonl(dir, record)` | `mkdir -p` + append one JSON line; refuses unsafe dir paths |
| `lib.is_main(basename)` | The `arg[0]` runner-vs-library guard |

**Not in `_lib`** (intentionally): hook-specific domain logic such as
`config-guard`'s `PROTECTED_PATHS` / `PROTECTED_PREFIXES`, or
`audit-event`'s `build_record()`. Keep that inline in each hook;
extraction would couple the lib to specific threats.

See bd memory `lua-hook-shared-lib-pattern` for the extraction rule,
`lua-hook-not-extracted` for the negative list, and
`lua-hook-bytecode-cache-deferred` for the future perf option.

## Hook file shape

Each Tier 1 hook is a single Lua file with a fixed structure:

```lua
#!/usr/bin/env lua
local lib = require("_lib")
local M = {}

-- Hook-specific constants here (PROTECTED_PATHS, WRITE_TOOLS, …).

-- Pure decision function — directly testable via busted:
function M.decide(data) ... end

-- I/O-driving entry point:
function M.main()
    local cjson = require("cjson")
    local raw = io.read("*all") or ""
    local ok, data = pcall(cjson.decode, raw)
    if not ok then
        lib.emit_hook_output({ ... fail-open default ... })
        return 0
    end
    local decision, reason = M.decide(data)
    -- side effects (alerts, JSONL append) as needed
    lib.emit_hook_output({ ... })
    return 0
end

-- Runner guard: load via dofile (tests) returns M; direct lua
-- invocation runs main + exits.
if lib.is_main("my-hook.lua") then
    os.exit(M.main())
end
return M
```

Tests `dofile()` the hook (clearing `package.loaded["_lib"]` first
to pick up shadowed env), exercise `M.decide` and other pure
helpers, never touching stdin/stdout. End-to-end stdin/stdout +
journald + JSONL is covered by `sandbox/scripts/smoke-test.sh` and
the smoke recipe (`just smoke`).

## Registration: `_hooks-manifest.sh`

The single source of truth for the `.hooks` block in
`claude-session`'s `settings.json` is
[`sandbox/scripts/_hooks-manifest.sh`](../../sandbox/scripts/_hooks-manifest.sh).
Adding a new hook is a manifest edit, not a wrapper-jq edit.

The manifest is a Bash script that emits one JSON document on stdout:

```json
{
    "PreToolUse": [
        {
            "matcher": "Write|Edit|MultiEdit|NotebookEdit",
            "hooks": [{"type": "command",
                       "command": "lua /home/claude-session/.claude/hooks/config-guard.lua"}]
        },
        ...
    ],
    "PostToolUse": [...]
}
```

It interpolates `SANDBOX_HOME` (passed by the wrapper) so the command
paths are absolute. See the next section for why absolute.

## Wiring: the wrapper's `assemble_claude_dir`

At every session boot, `sandbox/bin/claude-sandbox`'s
`assemble_claude_dir`:

1. Mirrors `${SHARE_HOOK_DIR}/*` (host-side, where `just install`
   placed the hooks) into `claude-session`'s `~/.claude/hooks/`
   directory via a `/tmp` staging dir + `sudo -u claude-session rsync`.
   Parallel to how skills/agents/commands/scripts are mirrored.
2. Pre-creates `~/.cache/claude-config/` (for the audit-log rw bind;
   bwrap would refuse to bind a missing source).
3. Sources `_hooks-manifest.sh` with `SANDBOX_HOME` exported to
   produce the canonical `.hooks` JSON.
4. Injects that JSON + the credential deny rules into
   `~/.claude/settings.json` via one `jq` pass (idempotent across
   re-runs).

## Deployment subtleties

The four subtleties surfaced during 40s.18 + 40s.19 diagnostics, in
the order one is likely to hit them:

### 1. `"matcher": ""` matches NOTHING; use `".*"` for catch-all

Claude Code's hook `matcher` field is a regex on tool name. The empty
string matches the empty string only — which never appears — so
`"matcher": ""` silently disables the hook. Hook authors targeting
*all* tools must write `"matcher": ".*"`.

### 2. The `command` field does NOT shell-expand `~`

Claude Code exec's the hook command without `~` expansion. A path
like `lua ~/.claude/hooks/audit-event.lua` will be invoked literally
with `~` as a file in the cwd — and fail silently when `lua` can't
find it. **Always use absolute paths.** `_hooks-manifest.sh`
interpolates `$SANDBOX_HOME` for this reason.

### 3. `bwrap --clearenv` drops `LUA_PATH`

The wrapper's `SCRUB_ENV` block sets `LUA_PATH` for the composed
(srt) and oauth modes. But standalone mode invokes `bwrap
--clearenv` (per `profiles/default.yaml`'s `environment.clearenv:
true`), which strips everything not in `environment.set`. The
canonical place for `LUA_PATH` is the profile's `environment.set`
block. Set in both places (or factor out — but the cost is low).

### 4. Hooks live in `~/.claude/hooks/`, not at a system path

The install map ships hooks to `${SHARE_DIR}/hooks/` (host), but
that path is invisible inside `claude-session`'s standalone bwrap
namespace. The wrapper mirrors them into `~/.claude/hooks/` (where
the profile's `sandbox_home` bind exposes them) and the manifest
references that in-home path. Composed mode also reads the in-home
path via srt's namespace; one location, both modes.

## Adding a new hook (checklist)

1. **Author**: `claude/scripts/hooks/<name>.lua` (follow the file
   shape above; `require("_lib")`).
2. **Test**: `tests-lua/<name>_spec.lua` (busted; `dofile` + clear
   `package.loaded["_lib"]` for fresh env capture).
3. **Install map**: add an entry in `sandbox/scripts/_install-manifest.sh`
   shipping the new file to `${SHARE_DIR}/hooks/<name>.lua` (mode
   `755` for executables, `644` for libraries like `_lib.lua`).
4. **bats install-manifest test**: bump the expected line-count
   assertion in `tests-bats/test_install_manifest.bats`.
5. **Register**: add an entry to `sandbox/scripts/_hooks-manifest.sh`
   under the appropriate event key (PreToolUse, PostToolUse). Use
   `${SANDBOX_HOME}` for the path and the right matcher (`.*` for
   catch-all; a regex like `Write|Edit` for tool-class scoping).
6. **Smoke**: `just smoke` (the wrapper's full boot) + manual
   `claude-sandbox -p "Use Bash to ..."` against an install-test
   prefix.
7. **Docs**: update this page's "Current hooks" section (below).

## Current Tier-1 hooks

| Hook | Event(s) | Matcher | Source bead |
|---|---|---|---|
| `config-guard.lua` | PreToolUse | `Write\|Edit\|MultiEdit\|NotebookEdit` | ClaudeConfig-40s.18 |
| `audit-event.lua` | PreToolUse + PostToolUse (one script, `--event=` selects) | `.*` | ClaudeConfig-40s.19 |
| *(planned)* `git-guard.lua` | PreToolUse | (regex on Bash with git verbs) | ClaudeConfig-bi0.* family |

## References

- [DEC-017](../../DECISION_LOG.md) — Lua/LuaJIT for fast-path hooks
- [DEC-020](../../DECISION_LOG.md) — multi-interpreter support for
  project-specific hooks (Tier 2)
- [DEC-022](../../DECISION_LOG.md) — per-language native testing
- bd memory `lua-hook-shared-lib-pattern`, `lua-hook-not-extracted`,
  `lua-hook-bytecode-cache-deferred`
