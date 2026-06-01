# Self-modification workflow

How an agent running inside a sandboxed session proposes a change to
its own configuration.

Audience: agent authors, anyone reviewing agent-proposed PRs.

## The mechanism (sketch)

The sandbox profile mounts the claude-config repo as a writable
worktree at `~/Source/claude-config/`. From inside the sandbox, the
agent can:

1. Create a feature branch off `main`.
2. Develop incrementally with modular commits (per CLAUDE.md
   "Session Discipline").
3. Push to the remote.
4. Open a PR (or note the branch for manual review).
5. Operator merges via the same review mechanism that applies to any
   change.
6. Next session boot sees the merged change (deployed configs are
   read-only inside the sandbox; the legitimate self-mod surface is
   the repo, not the deployed copy — see
   [`docs/architecture/hooks.md`](../architecture/hooks.md) and the
   `config-guard` hook for how that distinction is enforced).

## To be written

*Stub.* Pending content:

- Detailed branch-naming convention for agent-proposed changes
  (`agent/<topic>` vs `feat/<topic>` — currently undefined).
- Review checklist for operators receiving agent PRs (what to spot-
  check: identity-changing settings, profile bind additions, new
  hooks).
- How the upcoming `config-guard` extension to the *repo* path
  (currently it only guards deployed configs) might add a "is this
  edit allowed from the sandboxed UID?" tier — currently
  out-of-scope.

## References

- [`docs/architecture/hooks.md`](../architecture/hooks.md) —
  `config-guard` enforces "deployed config is managed, not edited
  in-session."
- [DEC-004](../../DECISION_LOG.md) — installer-based deployment with
  non-destructive defaults.
- [CLAUDE.md](../../CLAUDE.md) — "Session Discipline" + feature-
  branch conventions.
