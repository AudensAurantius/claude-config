# Audit log

Per-session record of every tool invocation `claude-session` makes
inside the sandbox, delivered via two parallel channels so the right
query interface is available for the right job.

Implemented by `claude/scripts/hooks/audit-event.lua` (ClaudeConfig-40s.19;
DEC-017). Composes with DEC-012's UID separation so audit data
naturally segregates by identity.

## Two channels

### 1. journald (aggregator-friendly transport)

Each tool call emits one line via `systemd-cat`:

```
-t claude-session    # syslog tag = identity-named for query
-p info              # priority level
```

Payload is compact JSON, suitable for downstream parsing by an OTEL
Collector sidecar (ClaudeConfig-40s.21) or shipped as-is to BOCO
telemetry:

```json
{"event": "PreToolUse", "tool": "Bash", "session": "<uuid>", "cwd": "/path"}
```

**Forensic detail (`tool_input`, `tool_response`) is deliberately
omitted from the journald summary** — it lives in the JSONL channel
below. journald is the "what happened, when, where" surface; JSONL
is the "exactly what was passed and returned" surface.

### 2. Per-session JSONL (forensic detail)

For each session, `audit-event.lua` appends one line per tool call to:

```
/home/claude-session/.cache/claude-config/<session_id>/tool-calls.jsonl
```

Each line is a complete JSON record with full `tool_input`,
`tool_response` (when present — PostToolUse only), `cwd`, timestamps:

```json
{
    "ts": "2026-05-30T02:45:58.001Z",
    "event": "PreToolUse" | "PostToolUse",
    "session_id": "<opaque uuid from claude>",
    "tool_name": "Bash",
    "tool_input": {"command": "echo hello"},
    "tool_response": {"exit_code": 0, ...},   // PostToolUse only
    "cwd": "/path/to/project"
}
```

The JSONL file is bound rw from claude-session's host home into the
standalone bwrap namespace via `profiles/default.yaml`'s
`sandbox_home` entry for `${SANDBOX_HOME}/.cache/claude-config` — see
[hooks.md](hooks.md) and DEC-012 for the bind/UID model.

## Query interfaces

### journald (system-side)

```bash
# All tool calls by claude-session in the last hour
journalctl _UID=$(id -u claude-session) -t claude-session --since "1 hour ago"

# Just the Bash invocations
journalctl _UID=$(id -u claude-session) -t claude-session \
    --since today \
    --output cat | jq 'select(.tool == "Bash")'

# Live tail
journalctl _UID=$(id -u claude-session) -t claude-session -f
```

`_UID=` filters by the kernel-recorded UID of the process that wrote
the log — unforgeable per the systemd documentation. So even if
something else ran on the host as user `claude-session`, only events
the kernel attributed to that UID surface here.

### JSONL (forensic)

```bash
# All tool inputs/outputs for a specific session
sudo cat /home/claude-session/.cache/claude-config/<session-id>/tool-calls.jsonl

# Bash commands across all sessions
sudo find /home/claude-session/.cache/claude-config -name 'tool-calls.jsonl' \
    -exec jq -c 'select(.tool_name == "Bash") | {ts, command: .tool_input.command}' {} \;

# Session timeline (Pre + Post pairs)
sudo cat /home/claude-session/.cache/claude-config/<session-id>/tool-calls.jsonl \
    | jq -c '{ts, event, tool: .tool_name}'
```

## Retention

**Not yet implemented.** The JSONL grows unbounded per session. A
future bead will add session-id-keyed rotation (probably by mtime;
the host has no concept of "session ended" so a wall-clock TTL is
simplest). Until then, occasional `rm -rf
/home/claude-session/.cache/claude-config/<old-session-id>` cleanup
is the operator's responsibility.

journald handles its own rotation via systemd-journald.conf
(`SystemMaxUse`, `MaxRetentionSec`); no per-claude-config tuning
needed.

## Composition with future telemetry (ClaudeConfig-40s.21)

The journald output shape is intentionally the same compact JSON that
an OTEL Collector sidecar can ingest. When 40s.21 lands, the
Collector reads from journald (`systemd_journal` receiver) and
forwards to BOCO's New Relic ingest endpoint. The hook stays
language-agnostic — the Lua hook writes structured logs to journald,
the Collector translates to OTLP. No hook changes needed.

## Why two channels (not just JSONL)

- **journald is queryable across users.** The `_UID=999` filter is
  kernel-attributed; an investigator with `journalctl` access can see
  audit events without sudo into the claude-session account.
- **JSONL is comprehensive.** The `tool_response` field can be
  several KB (file contents, tool errors). journald's structured
  logging supports it, but bloating syslog with every tool's full
  output is noisy. Separation keeps each channel fit for its query
  pattern.

## References

- [`hooks.md`](hooks.md) — hook plumbing, including how `audit-event`
  composes with `config-guard` and (planned) `git-guard`.
- [`audit-event.lua`](../../claude/scripts/hooks/audit-event.lua) —
  source.
- [DEC-012](../../DECISION_LOG.md) — claude-session UID boundary.
- [DEC-017](../../DECISION_LOG.md) — Lua/LuaJIT runtime choice.
- [FOLLOWUP.md Q5](../../.tasks/ClaudeConfig-40s.13-claude-code-sandboxing-survey/FOLLOWUP.md)
  — the original journald-+-JSONL design sketch.
