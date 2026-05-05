# Roadmap — claude-config

Phase-by-phase delivery plan for the canonical `claude-config` project.
Synthesized from [`VISION.md`](VISION.md) and the architecture transcript at
[`transcripts/2026-05-04-sandbox-architecture-discussion.md`](transcripts/2026-05-04-sandbox-architecture-discussion.md).
Decisions referenced inline link to [`DECISION_LOG.md`](../DECISION_LOG.md)
entries.

Active per-phase tracking lives in beads under
`scope:infrastructure` + `area:phaseN` labels.

## Status legend

- 🟦 **Active** — currently being implemented
- ⬜ **Planned** — design clear, not started
- 🟧 **Designed** — architecture set; sub-tasks not yet broken down
- 🟪 **Provisional** — placeholder; design not yet finalized

## Phase summary

| Phase | Status | Deliverable | Unlocks |
|---|---|---|---|
| 1 | 🟦 Active | `claude-sandbox` wrapper (single profile, single worktree, single namespace per invocation) | Universal sandboxing for serial use |
| 2 | ⬜ Planned | Profile system (per-project levers via YAML configs) | Differentiated visible-context per task class |
| 3 | ⬜ Planned | Per-session namespace + worktree creation | Parallel sessions; agent collaboration via git |
| 4 | ⬜ Planned | Path-aliasing for memory continuity | Auto-memory works inside sandboxed agents |
| 5 | ⬜ Planned | Dolt user + branch-restricted beads | Agent task state tracked safely |
| 6 | 🟧 Designed | Autosession daemon (coordinator + workers + reviewers) | Multi-agent swarm with human-in-the-loop |
| 7 | 🟪 Provisional | Privileged-action executor (mediator daemon) | Fully-autonomous swarms with bounded privileged execution |

Phase dependencies are linear (1 → 2 → 3 → 4 → 5 → 6 → 7) with the
exception that Phases 3 and 4 land together — per-session namespaces
without path-aliasing would break memory continuity. Phase 5 lands
before Phase 6 because the autosession daemon needs the Dolt auth
model in place.

---

## Phase 1 — claude-sandbox wrapper

**Goal:** Every interactive Claude Code invocation runs inside a Linux
mount namespace as a dedicated `claude-session` user with a stripped
environment. Single fixed profile, single worktree of the active project,
single namespace per `claude-sandbox` invocation. No parallelism yet.

**Deliverables:**

- `sandbox/bin/claude-sandbox` — user-invokable entry-point wrapper.
  Calls `sudo /usr/local/sbin/claude-sandbox-priv` for the privileged
  namespace setup, then drops to `claude-session` and execs `claude`.
- `sandbox/sbin/claude-sandbox-priv` — root-only namespace setup script.
  Owns the `unshare --mount` invocation and the shadow-tmpfs mounts of
  credential paths. Lives in `/usr/local/sbin/` because sudoers must
  point at a root-owned, user-non-writable path. (See
  [Common Pitfall #1](../CLAUDE.md#common-pitfalls).)
- `sandbox/etc/sudoers.d/claude-sandbox` — `NOPASSWD` rule for the
  privileged script.
- `sandbox/scripts/provision-claude-session.sh` — one-shot user creation
  with ACLs on `~/.claude/projects/` for write-back.
- One-time OAuth flow for `claude-session` (interactive setup; the user
  authenticates the sandboxed identity once with their company
  subscription).
- `Makefile` `install` target wired up to deploy all of the above per
  [DEC-004](../DECISION_LOG.md#dec-004-installer-based-deployment-with-non-destructive-defaults-2026-05-04).

**Acceptance:**

```bash
claude-sandbox --version             # confirms wrapper + namespace + claude
claude-sandbox -p "echo hello"       # one-shot non-interactive sanity check
```

Inside the session, `~/.config/snowflake/`, `~/.password-store/`, and
similar credential paths must be empty (shadow-tmpfs mounted). `env`
must show no `SNOWFLAKE_PRIVATE_KEY`, no `JIRA_API_TOKEN`, etc.
`~/.claude/` must be the bind-mounted read-only deployment of this
repo's `claude/` content. `~/Source/claude-config/` must be a writable
worktree on a session-specific feature branch.

**Open questions to resolve before completion:**

- One-time OAuth flow ergonomics. The first `claude-sandbox` invocation
  on a new machine will land in a session with no Anthropic credentials;
  the user has to complete the browser flow inside that sandboxed
  session. Document the bootstrap.
- Smoke test in CI vs. manual. CI cannot easily execute the privileged
  namespace setup; the smoke test stays manual for now.

**Related beads:** see `bd list --label=area:phase1`.

---

## Phase 2 — Profile system

**Goal:** Per-project levers for adjusting the level of isolation, via
YAML profile configs. The wrapper reads the active profile and configures
the namespace accordingly.

**Deliverables:**

- Profile YAML schema (documented in `sandbox/profiles/SCHEMA.md`).
  Keys for: visible filesystem paths (read-only and read-write), worktree
  policy (auto-create / use-existing / disabled), skill subset to expose,
  network policy (Phase 2+ baseline = host-network for now).
- Profile loader in the wrapper. Reads `~/.config/claude-sandbox/
  profiles/<active>.yaml` at session start; consumed before `claude` exec.
- Profile discovery: per-project `.claude/sandbox-profile` file or
  `--profile <name>` flag.
- Reference profiles committed to the repo: `default.yaml` (baseline,
  nothing extra exposed) and `full-trust.yaml` (escape hatch for emergency
  parity with pre-sandbox behavior).
- Schema enforcement: profiles **must not** contain a `credentials:` or
  `env:` key for secret injection per
  [DEC-001](../DECISION_LOG.md#dec-001-profiles-manage-visible-context-not-credentials-2026-05-04).
  Loader rejects profiles that try.

**Acceptance:**

```bash
claude-sandbox --profile full-trust         # broader visibility
cd ~/Source/some-project && claude-sandbox  # auto-selects from .claude/sandbox-profile
```

**Open questions:**

- Whether to ship per-project example profiles in this repo. Probably no
  — projects own their own profile files; this repo ships only the schema
  and the reference defaults.

---

## Phase 3 — Per-session namespace + worktree creation

**Goal:** Parallel sessions in independent namespaces. Each session gets
its own mount namespace and its own git worktree on a session-specific
feature branch. Agents collaborate via git/beads, never via shared
filesystems (per
[DEC-001](../DECISION_LOG.md#dec-001-profiles-manage-visible-context-not-credentials-2026-05-04)
and the architecture transcript Topic 5).

**Deliverables:**

- Session ID generation (timestamp + short random suffix).
- Auto-worktree creation: `git worktree add -b session-<id> <path>
  origin/main` at session start.
- Worktree teardown at session end (`git worktree remove`).
- Namespace lifecycle independent of any other session — no shared
  bind-mount counters, no cross-session reference counts.
- Concurrent-session smoke test (two `claude-sandbox` invocations
  simultaneously, neither sees the other's worktree).

**Acceptance:**

Two sessions running in parallel, each in its own worktree, can be
verified independent: `git worktree list` shows both; killing one
namespace does not disturb the other; pushed branches from each are
visible to the other only through `git fetch`.

**Open questions:**

- Worktree cleanup on abnormal session exit (kill -9, machine reboot).
  Likely a `git worktree prune` step in the wrapper's startup or via a
  systemd-managed periodic cleaner.

---

## Phase 4 — Path-aliasing for memory continuity

**Goal:** Auto-memory and claude-mem observations work correctly inside
sandboxed sessions. The agent's working directory string matches the
canonical clone's path string, so `~/.claude/projects/<hash>/` resolves
to the same directory.

**Deliverables:**

- Bind-mount the session's worktree at the **canonical** project path
  (`/home/hactar/Source/<project>/`) inside the namespace, not at a
  worktree-specific path. This ensures the project-hash for
  `~/.claude/projects/` matches between agent and human sessions. (See
  [Common Pitfall #2](../CLAUDE.md#common-pitfalls).)
- `memory/agent-observations/` subdirectory convention. Auto-memory
  `MEMORY.md` does not auto-load this subtree, so agent observations
  don't intermix with the user's at session start. Human reviews and
  promotes relevant entries.
- ACLs on `~/.claude/projects/<hash>/` granting `claude-session` write
  access (set up in Phase 1's provisioning script; verified here).

**Acceptance:**

Inside a sandboxed session, `bd memories` returns the same memories the
user sees in their interactive session for the same project. Auto-memory
files load correctly. claude-mem observations recorded by the agent
appear in the canonical corpus on the next interactive session.

**Open questions:**

- Whether claude-mem corpus distinguishes agent-origin vs. human-origin
  observations natively. If not, the agent-observations subdirectory
  pattern carries the audit trail.

---

## Phase 5 — Dolt user + branch-restricted beads

**Goal:** Sandboxed agents can read all bead state and write to their
own branch only. Bead state mutation flows through a code-review-style
merge workflow (per
[DEC-002](../DECISION_LOG.md#dec-002-branch-restricted-dolt-auth-is-a-safety-mechanism-not-a-privilege-2026-05-04)).

**Deliverables:**

- `bd-claude-session` Dolt user, created via SQL bootstrap script.
- GRANTs:
  - `SELECT` on all branches (full read).
  - `INSERT/UPDATE/DELETE` on branches matching `claude/*` only.
- Per-session Dolt branch (`claude/<session-id>`) created at sandbox
  startup, deleted (or merged) at session end.
- Coordinator merge process: a `bd merge` workflow that reviews the
  agent's branch and merges to `main` after approval.
- Wrapper integration: the `BEADS_DOLT_USER` and `BEADS_DOLT_PASSWORD`
  for `bd-claude-session` are set inside the namespace; the user's own
  bd-write credentials are not exposed.

**Acceptance:**

A sandboxed agent can `bd ready`, `bd list`, `bd show` (full read), and
`bd update --claim`, `bd close` against its own branch. An attempt to
write to `main` directly via SQL fails with auth denied. The merge
workflow surfaces the agent's branch contents for review.

**Open questions:**

- Per-class restriction (e.g., agent can only modify beads with
  `area:agent-tasks`). Deferred per Topic 7 of the transcript —
  branch-level granularity is sufficient as a starting point because
  Dolt grants don't see row labels. Application-level enforcement in `bd`
  itself can come later.

---

## Phase 6 — Autosession daemon

**Goal:** Long-lived coordinator agent that dispatches short-lived
worker and reviewer agents against a beads task queue. Single
human-in-the-loop checkpoint at merge time; everything else autonomous.

**Deliverables:**

- Coordinator process (likely systemd-managed).
- Worker dispatch: spawns a `claude-sandbox` session in a fresh worktree
  + Dolt branch, scoped to one bead.
- Reviewer dispatch: spawns a `claude-sandbox` read-only checkout of a
  worker's branch, posts review via bead comment.
- Beads queue integration: the coordinator polls
  `bd ready --label=area:agent-tasks` (or similar) for available work.
- Bead state machine: `open → claimed → in_progress → ready_for_review
  → reviewed → ready_to_merge → merged`.

**Related work:** the existing `auto-session` skill family
(J121-9kp.2.17 epic, currently deferred) is a session-launcher — a
human-driven ancestor of this daemon. It informs the daemon design but
is not the daemon itself.

**Acceptance:**

The coordinator runs unattended overnight, picks up new beads as they
become ready, dispatches workers for implementation and reviewers for
review, and surfaces ready-to-merge work for the user in the morning.

**Open questions:**

- Whether the coordinator itself runs sandboxed (yes; same model as
  workers), or as a privileged service (no — wider blast radius).
- Failure-mode handling. A worker that runs out of context budget, hits
  a tool-use error, or produces no useful change must surface that to
  the coordinator without leaving the bead in `in_progress` indefinitely.
  Likely a heartbeat + timeout pattern.

---

## Phase 7 — Privileged-action executor

**Goal:** Bounded, audited execution of privileged actions (Snowflake
deploys, ADO pipeline runs, AWS CLI) without a human in the per-action
loop. See
[DEC-003](../DECISION_LOG.md#dec-003-phase-7-placeholder-privileged-action-executor-mediates-between-agent-requests-and-host-execution-2026-05-04).

**Deliverables (provisional — finalized when Phase 7 begins
implementation):**

- Mediator daemon (Unix socket, JSON request/response schema).
- Capability manifest (YAML, default-deny). Each capability declares:
  what it can do, what credentials it holds, what the audit format is.
- Audit log (append-only, signed if practical).
- Recommendation evaluator: when a worker requests a privileged action,
  the executor reviews for non-privileged alternatives, evaluates the
  request against scoped capabilities, and either executes within scope,
  suggests an alternative, or escalates to the human with paste-ready
  instructions.

**Acceptance:**

A worker agent's request to "run this Snowflake script in DEV" is
satisfied by the executor (within the DEV-scope capability). The same
worker requesting "run this in PROD" is escalated to the human. The
audit log records both decisions with the worker's `justification` field.

**This phase will be replaced by a non-provisional plan when Phase 7
begins implementation.** DEC-003 will be replaced with a finalized
decision entry capturing the actual schema and capability set.

---

## Cross-cutting tracks

These run alongside the phase work and don't fit cleanly into a single
phase.

### `scope:research` — tooling and plugin evaluations

Evaluations of upstream Claude/agent tooling for adoption. Examples:
`process_triage`, `flow-next`, `mcp_agent_mail`, `meta_skill`. Adoption
decisions feed Phase 1+ skill content.

### `scope:review` — audits and validation gates

Periodic audits of skill/agent behavior, allowed-tools declarations, and
adopted-tooling validation. Run between phases or at scheduled intervals.

### `scope:skills` — skills, slash commands, agent definitions

Authoring and refining the global skill / command / agent library. Largely
independent of the sandbox phases (skills work even before Phase 1
sandboxing ships). Decoupled from infrastructure track.

### `migrate-to:bd-timew` — beads destined for the bd-timew repo

Beads describing bd-timew bugs, features, or design work that should
eventually live in a dedicated bd-timew project's beads instance. Tagged
here for batch migration when bd-timew gets its own home.

---

## Out of scope (per VISION.md)

- Hardening against a kernel-level adversary.
- Cross-platform support beyond Linux/WSL2 in the initial implementation
  (Mac and Windows-native are future-scope).
- Plugin architecture for non-beads workflow integrations (future-scope).
