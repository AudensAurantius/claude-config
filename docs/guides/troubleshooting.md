# Troubleshooting

Common failure modes and where to start digging.

Audience: operators who hit something unexpected. Each entry leads
with symptom, then where to look, then how to fix.

## Auth not refreshing

**Symptom**: in-session messages about expired tokens, or
`/login` prompts inside a sandboxed session.

**Where to check**: claude-session's OAuth token at
`/home/claude-session/.claude/.credentials.json`. Tokens have refresh
semantics handled by Claude Code itself; manual intervention is
rarely needed.

**Fix**: redo the one-time flow per
[`oauth-bootstrap.md`](oauth-bootstrap.md). The token is rebuilt;
existing sessions need a restart to pick it up.

## Memory writes failing

**Symptom**: claude-mem observations / auto-memory `MEMORY.md`
updates appear to take but don't persist across sessions.

**Where to check**: ACLs on the host user's `~/.claude/projects/`
directory. `getfacl ~/.claude/projects/` should show `claude-session`
with `rwx` (and the same on the default ACL for new files).

**Fix**: re-run the ACL setup:

```bash
just provision   # also re-runs setup-claude-session-acls.sh
```

Or run the ACL script directly for a specific project subtree per
`sandbox/scripts/setup-claude-session-acls.sh --help`.

## Profile not taking effect

**Symptom**: changes to a profile YAML don't show up in the next
session, OR the wrong profile appears to be active.

**Where to check**:

1. Which profile dir is the wrapper reading?
   `CLAUDE_SANDBOX_PROFILE_DIR=...` overrides the default;
   `~/.config/claude-sandbox/profiles/default.yaml` is the default.
2. `just install` was re-run after the edit? Profiles deploy from
   `sandbox/profiles/` to `~/.config/claude-sandbox/profiles/`; an
   un-deployed edit doesn't take effect.

**Fix**:

```bash
just install      # redeploys profile + wrapper
just smoke        # confirms a sandbox session boots with new profile
```

To inspect the resolved bwrap arg sequence without booting:

```bash
CLAUDE_SANDBOX_PROFILE_DIR=sandbox/profiles \
    bash sandbox/bin/claude-sandbox --standalone --dry-run -p hi
```

## Bind-mount conflicts (Phase 1)

**Symptom**: two sandbox sessions launched in parallel step on each
other (one reads stale state from the other's writes).

**Why it happens**: Phase 1 uses a single shared assembled
`~/.claude/` layout for claude-session. Two concurrent sessions
share the same mirror destination. The assembly runs at session
boot, so the second-launched session's view wins.

**Fix (current)**: don't run two concurrent sandboxed sessions.

**Fix (planned, Phase 3+)**: per-session worktrees + per-session
namespace, so each session gets its own mirror. ClaudeConfig-40s
sub-beads track this; until then, serialize.

## Phase-specific notes

This section appends as new phases ship — each adds operational
concerns specific to its new capability.

### Phase 1

- The egress allowlist for composed mode is the broker-mediated
  list, NOT the profile's `composed.network.allowed_domains` alone.
  When DEC-013 (broker + SNI proxy, ClaudeConfig-ciw.*) lands, the
  effective allowlist is `profile ∩ broker-policy`.
- The wrapper accepts `--oauth` only outside the bwrap/srt
  boundary; this is intentional per
  [`oauth-bootstrap.md`](oauth-bootstrap.md).

## References

- [`docs/architecture/sandbox-model.md`](../architecture/sandbox-model.md)
  — the architectural framing.
- [`oauth-bootstrap.md`](oauth-bootstrap.md) — auth flow + cwd
  safety.
- [`profile-authoring.md`](profile-authoring.md) — profile schema.
- [CLAUDE.md "Common Pitfalls"](../../CLAUDE.md) — the canonical
  list of known gotchas.
