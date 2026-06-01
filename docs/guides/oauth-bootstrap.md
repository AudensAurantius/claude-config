# OAuth bootstrap + cwd safety

How to complete claude-session's one-time Anthropic OAuth flow, and
the cwd safety rule that makes it (and every other bare-claude
invocation) safe.

Audience: operators setting up a fresh host, or anyone debugging an
"auth not refreshing" symptom.

## The flow

```bash
claude-sandbox --oauth
```

This runs claude-session's *own* `claude` for the one-time login.
The token lands at `/home/claude-session/.claude/.credentials.json`
— independent of your interactive identity (DEC-009).

`--oauth` deliberately runs **outside** the bwrap/srt boundary: the
Anthropic login domains aren't on the sandbox network allowlist, so
the OAuth dance needs the open egress that the augmentation layer
otherwise withholds. The cwd-safety hardening (below) is what makes
that exception tolerable.

## Why never bare `claude` as claude-session

A `0700` home blocks **path traversal** — `claude-session` can't
`ls ~hactar/.local` because the gate denies it. But that gate does
NOT protect against an **inherited cwd fd**.

`sudo` preserves the current working directory. If you `sudo -u
claude-session claude` from inside the host user's home — say
`~/.local/share/some-tool/`, commonly `0755` — the spawned process
keeps a cwd file descriptor pointing into that directory. Relative
reads from that cwd check **only the immediate directory's perms**,
not the `0700` gate above. So directories like `~/.local`,
`~/.config`, `~/.cache`, etc. (commonly `0755`) become readable by
claude-session through the inherited cwd, **bypassing the 0700
gate** entirely.

`claude-sandbox --oauth` (and the composed/standalone cwd guard,
which refuses the host home root and `~/.dotfile` dirs) eliminate
this by forcing cwd to claude-session's *own* home before exec.

**Never run bare `claude` as claude-session from an arbitrary
directory.** Always go through `claude-sandbox`. See
[CLAUDE.md](../../CLAUDE.md) "Common Pitfalls" #4 and
ClaudeConfig-40s.15.10 for the discovery context.

## Defense in depth (optional)

Tightening the perms on claude-session-reachable `~/.local*` /
`~/.config` subdirs from `0755` further narrows the inherited-cwd
surface. **Not required** given the sandbox namespace + the
`--oauth`/cwd-guard controls above — but available as belt-and-
suspenders for paranoid setups.

## Sandbox awareness (in-session)

*Stub — to be written.* How to tell, from inside a session, whether
you're running under `claude-sandbox` (vs bare `claude`): what
capabilities differ (read-only `~/.claude/`, writable worktree at
`~/Source/claude-config/`, no environment-resident credentials,
constrained `bd` access per Phase 5+), and how to detect via
environment / mount-table probes.

## References

- [DEC-009](../../DECISION_LOG.md) — claude-session's separate
  Anthropic OAuth identity.
- [DEC-012](../../DECISION_LOG.md) — UID separation and the host
  `0700` home as the foundational boundary.
- [`docs/architecture/sandbox-model.md`](../architecture/sandbox-model.md)
  — the architectural framing this guide operates within.
- ClaudeConfig-40s.15.10 — the source bead for the cwd-inheritance
  diagnosis and `--oauth` hardening.
