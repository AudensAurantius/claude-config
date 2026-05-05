# Sandbox Guide

Operator's reference for the `claude-sandbox` runtime: what it is, how it
behaves, and how to extend it.

This is the long-form pointer target for the marker-block snippet that
the installer inserts into `~/.claude/CLAUDE.md`. Sessions running inside
the sandbox have access to this file via the bind-mounted repo at
`~/Source/claude-config/`.

The architecture and reasoning behind the sandbox are documented in
[`VISION.md`](VISION.md), [`../DECISION_LOG.md`](../DECISION_LOG.md), and
[`transcripts/2026-05-04-sandbox-architecture-discussion.md`](transcripts/2026-05-04-sandbox-architecture-discussion.md).
This guide focuses on operational concerns.

## Status

**Stub.** This file fills in as Phases 1+ ship. Each phase contributes
the operational documentation for the capability it adds.

## Sections to write (Phase 1+)

### Mental model

What the sandbox is, what it isn't. The core invariants: separate user,
mount namespace, stripped environment, bind-mounted repo, profile-driven
visible context.

### Sandbox awareness for sessions

How to tell whether a Claude session is running inside the sandbox.
What capabilities are different (read-only `~/.claude/`, writable
worktree at `~/Source/claude-config/`, no environment-resident
credentials, `bd` access constrained per Phase 5+).

### The recommend-and-execute pattern

How agents should format privileged-command recommendations so the
human can paste-and-run them safely. Conventions for environment
prefixes, what to echo before executing, never including secrets in
the recommendation output.

### Profile authoring

Schema for `~/.config/claude-sandbox/profiles/*.yaml`. How to define
visible paths, worktrees, skill subsets. How to test a new profile.
How to share profiles between machines (commit to repo, redeploy).

### Self-modification workflow

How an agent proposes a change to its own configuration: feature
branch in the writable worktree, commit, push, request review,
human merges, next session sees the change.

### Troubleshooting

Common failure modes:

- *Auth not refreshing.* Symptoms, where to check (claude-session's
  OAuth token), how to redo the one-time flow.
- *Memory writes failing.* Symptoms, how to verify ACLs on
  `~/.claude/projects/`.
- *Profile not taking effect.* How to confirm which profile is
  active, how to dump the resolved namespace mounts.
- *Bind-mount conflicts.* When two sessions step on each other (Phase
  3+ should make this impossible by giving each session its own
  namespace; if it happens, file a bd issue).

### Phase-specific notes

Each phase appends a section here as it ships, documenting the new
capability and its operational concerns.
