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

### Permission prompts vs OS-level sandboxing

Claude Code's per-tool permission prompts and `claude-sandbox`'s
bwrap-based isolation are two layers of the same defense — "limit what
Claude can do" — operating at different levels:

- **Prompts are application-layer checks.** Each tool invocation
  matches an allowlist or surfaces a blocking prompt. Cheap to add,
  but rely on the user being available to approve legitimate
  operations and on the prompt logic itself remaining unbypassable.
  Recent CVE history (50-subcommand bypass, settings-pre-trust
  bypass) shows the prompt model has had real holes.
- **The bwrap sandbox is OS-layer enforcement.** Filesystem
  visibility (DEC-006 allow-list), credential exposure (DEC-008
  tiered policy), and identity (DEC-009 separate `claude-session`
  OAuth) are bounded by the kernel and the namespace, regardless of
  what the agent tries to do. A prompt-bypass CVE doesn't compromise
  the sandbox boundary.

Once Phase 1 ships, **the bwrap sandbox subsumes most of what per-tool
prompts protect against.** Inside a sandboxed session, the prompt
model is largely redundant because the kernel enforces what the
prompt would have checked. Specifically:

- **Phase 6+ autosession daemons (workers, reviewers)** should run
  with `--dangerously-skip-permissions` *inside* the sandbox.
  Per-tool friction during autonomous execution defeats the purpose
  of an unattended swarm; the sandbox boundary remains the actual
  trust boundary, so prompt-skipping inside it is safe by
  construction.
- **Interactive sandboxed sessions** can also relax prompts (run
  with broader allowlists, or with `--dangerously-skip-permissions`
  for fully-trusted workflows) once the sandbox visibly bounds the
  blast radius. The user decides per profile.

Outside the sandbox (sessions invoked via `claude` directly,
bypassing `claude-sandbox`, or sessions running before Phase 1
ships), prompts remain the trust boundary and should be respected.

This composition principle is also why the spawn-agents pre-flight
convention matters less for sandboxed agents than for host-side
agents: a sandboxed worker that hits an unexpected `WebFetch` domain
isn't taking a host-level risk — the sandbox already constrains what
the response can do — so the convention's batch-approve-up-front
pattern can be relaxed there.

### Permission mode policy

Claude Code ships six permission modes (`default`, `acceptEdits`,
`plan`, `auto`, `dontAsk`, `bypassPermissions`). claude-config's
deployed profiles treat them asymmetrically — and the asymmetry is
deliberate, so it's worth stating plainly.

**`auto` mode is prohibited in deployed profiles.** Auto mode's
distinguishing feature is a server-side classifier that, by
documented default, *reads `.env` files and sends matched credentials
to their target API* and can autonomously set
`dangerouslyDisableSandbox: true` when a sandbox-caused failure is
hit (upstream issue #97). That credential-egress behavior is the
exact DEC-001 / DEC-008 anti-pattern. The lock-off is a purpose-built
managed-settings knob:

```json
// /etc/claude-code/managed-settings.json
{
  "permissions": {
    "disableAutoMode": "disable"
  }
}
```

Two further backstops make this robust: Claude Code already ignores
`defaultMode: "auto"` from project/local settings (a repo cannot
grant itself auto mode — only `~/.claude/settings.json` can set it),
and the `Read(**/.env)` deny rule shipped in the baseline settings
neutralizes the specific credential behavior even if auto mode were
somehow active. The docs themselves point at deny rules as the only
"hard guarantee" — conversational boundaries like "don't read .env"
are re-read from the transcript each check and lost on context
compaction.

Do **not** lock auto mode off by forcing `permissionMode: "default"`
in managed settings. That would also block `bypassPermissions` and
`dontAsk`, which we want available (see below). Use the surgical
`disableAutoMode` knob instead.

**`bypassPermissions` and `dontAsk` remain available inside the
sandbox.** Neither has auto mode's credential-classifier behavior;
they only change prompt handling. Inside the kernel sandbox the
boundary is enforced by the separate `claude-session` UID (DEC-012)
and the egress broker/proxy (DEC-013), not by prompts — so a
sandboxed worker running `--dangerously-skip-permissions`
(`bypassPermissions`) is safe by construction, and `dontAsk` (pre-
approved tools only) is ideal for fully unattended CI-style runs. The
managed-settings `disableAutoMode` lock is host-wide, which is fine:
we never want auto mode anywhere on this machine, and we do **not**
globally disable `bypassPermissions` because the sandbox relies on it.

`autoMode.environment` is not a mitigation knob — it only *expands*
the classifier's trusted-infrastructure list. It cannot disable the
`.env`-credential behavior, so it plays no role in this policy.

### OAuth bootstrap and cwd safety

claude-session's one-time Anthropic OAuth uses `claude-sandbox --oauth`,
**not** bare `claude`. OAuth needs the login domains (not on the sandbox
network allowlist), so `--oauth` runs claude-session's own claude
*outside* the bwrap/srt boundary — but with **cwd forced to
claude-session's home**, so no caller-inherited working directory is
ever exposed.

Why the cwd matters: a `0700` home blocks *path traversal* but not an
*inherited cwd fd*. `sudo` preserves the cwd, so launching bare `claude`
as claude-session from inside the user's home (e.g. `~/.local/share/...`,
commonly `0755`) lets it read that directory via the inherited cwd,
bypassing the `0700` gate. `--oauth` (and the composed/standalone cwd
guard, which refuses the home root and `~/.dotfile` dirs) eliminate this.
**Never run bare `claude` as claude-session from an arbitrary directory**
— always go through `claude-sandbox`. See CLAUDE.md Common Pitfall #4 and
ClaudeConfig-40s.15.10.

Optional defense-in-depth (operator's call): tightening the perms on
claude-session-reachable `~/.local*`/`~/.config` subdirs from `0755`
narrows the inherited-cwd surface further, but is not required given the
sandbox namespace and the `--oauth`/cwd-guard controls above.

### Sandbox awareness for sessions

How to tell whether a Claude session is running inside the sandbox.
What capabilities are different (read-only `~/.claude/`, writable
worktree at `~/Source/claude-config/`, no environment-resident
credentials, `bd` access constrained per Phase 5+).

### Hooks and the supported-interpreter set

Per DEC-017 and DEC-020, sandbox-side hook scripts come in two tiers
with different language constraints:

**Tier 1 — system-shipped fast-path hooks** (PreToolUse handlers that
fire on every Bash call: config-guard, git-guard, audit, telemetry).
These are written in **Lua/LuaJIT** for sub-millisecond cold-start
(Python's ~50 ms × N tool calls is user-perceptible at session scale).
LuaJIT, lyaml, and lua-cjson are provisioned in claude-session's home
during install (`just provision`); the wrapper sets `~/.local/bin/lua`
→ `/usr/bin/luajit` so `#!/usr/bin/env lua` resolves to the JIT.

**Tier 2 — project-specific hooks** under `<project>/.claude-session/
hooks/`. Each project decides what guards or workflows are appropriate
to its scope. Authors pick the most natural interpreter via shebang:

| Interpreter | Provisioned by | Typical fit |
|---|---|---|
| `#!/usr/bin/env python3` | uv project + pipx provisioning (DEC-019) | Python projects; data-shape validation; `pyyaml`/`requests` available |
| `#!/usr/bin/env node` | 40s.15.11 (per-user Node + srt) | Node projects; JSON-heavy logic |
| `#!/usr/bin/env bash` | system (universal) | shell-level state checks; quick wrappers |
| `#!/usr/bin/env perl` | system (verified at `just provision`) | text-mangling, regex-heavy guards |
| `#!/usr/bin/env lua` | 58n.1 / Tier 1 toolchain | shared with Tier 1; minimal startup overhead |

The supported set is intentionally a small, common-denominator group
— extending it requires explicit provisioning (DEC-016 model: claude-
session owns its tools per-user) plus a smoke-test verification entry
in `sandbox/scripts/smoke-test.sh`. Don't reach for compiled languages
in this tier; the per-project build/distribute overhead is wrong for
small hook scripts.

If `perl` warns "NOT available" during provisioning, the host is
running a minimal image (some container bases strip it). Fix:
`apt-get install perl-base` (or distro equivalent) and re-run
`just provision`.

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
