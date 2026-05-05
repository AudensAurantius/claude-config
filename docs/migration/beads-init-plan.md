# Beads Initialization Plan — claude-config

One-shot plan for initializing beads in this repo. Delete this file once
beads is live and the steps have been executed.

## Prerequisite check

The repo is already a git repository (initial commit `303a3f8`). Beads
requires git presence; this is satisfied.

## Initialization mechanism

Use `bd-timew init-project` rather than raw `bd init`. The bd-timew
wrapper does three things:

1. Runs `bd init` (creates `.beads/` nested git repo, default config).
2. Registers the project with bd-timew's auto-cleanup cron (so the Dolt
   compact + GC runs daily).
3. Scaffolds the `.beads/bd-timew.yaml` sidecar for billing-tuple
   resolution from labels.

Pass `--server` explicitly to provision the project in Dolt server
mode. This is required for Phase 5 (the `bd-claude-session` Dolt user
with branch-restricted writes — see [DEC-002](../../DECISION_LOG.md#dec-002-branch-restricted-dolt-auth-is-a-safety-mechanism-not-a-privilege-2026-05-04));
embedded Dolt mode does not support per-user auth. Even before Phase
5, server mode is the forward-compatible default.

Command:

```bash
cd ~/Source/claude-config
bd-timew init-project --server
```

If prompted for `--dolt-user` or `--pass-path`, supply the values that
match the existing bd-timew global Dolt server setup (consult `bd
memories dolt-server` if needed).

Follow the remaining prompts. When asked about the billing default,
the answer for this project is the BOCO AI Innovation tuple — see the
sidecar configuration below.

## Required post-init configuration

After `bd init` runs, apply the standard performance settings (per
global CLAUDE.md guidance):

```bash
bd config set dolt.auto-commit batch
bd config set no-push true
```

Then configure the sidecar for label → billing resolution. This
project is **partially billable**: time tracked against it bills to
BOCO's AI Innovation initiative as an overflow buffer to ensure 40
hours/week. Open `.beads/bd-timew.yaml` in `$EDITOR` and replace with:

```yaml
# Default billing tuple for claude-config beads.
#
# This project is partially billable: time tracked against it bills
# to BOCO AI Innovation as an overflow buffer for ensuring weekly
# billable hours. Track everything by default; the human filters
# which intervals to submit at end-of-week.

default:
  client: "PRJ001125 BOCO : BOCO : BOCO : BOCO AI Innovation"
  case:   "01_AI Innovation (Project Task)"
  svc:    "Technology Services"

patterns: []
```

(No regex patterns needed — this project is single-purpose. Compare
against J121's sidecar, which has many patterns because it spans many
billing categories.)

## Label taxonomy

Adopt the same Option B prefix-namespaced taxonomy used elsewhere
(`memory/reference-beads-label-taxonomy.md`):

- `src:` — zero or one. `src:jira` for any future Jira-synced beads;
  unlabeled for native Beads (the default for this repo).
- `scope:` — zero or one. `scope:local` is implicit; this entire
  project is local-scoped, so the label is rarely needed.
- `area:` — zero or more. Areas relevant to this project:
  - `area:sandbox` — claude-sandbox wrapper, namespace logic
  - `area:installer` — Makefile / install script work
  - `area:skills` — skills authoring or refinement
  - `area:agents` — agent definition work
  - `area:profiles` — profile system (Phase 2+)
  - `area:autosession` — autosession daemon (Phase 6+)
  - `area:executor` — privileged-action executor (Phase 7+)
  - `area:docs` — documentation
  - `area:migration` — one-shot migration tasks

## Smoke test

After init, verify with:

```bash
bd ready                              # should show no items
bd create --title="claude-config: smoke test" --type=task --priority=4 --label=area:docs
bd list                               # should show the smoke-test issue
bd close <id>                         # close it
bd ready                              # confirm closed
```

## Remaining steps (after beads init)

Once beads is live in this repo, proceed to:

1. [`bead-migration-plan.md`](bead-migration-plan.md) — port relevant
   J121 beads into the new instance.
2. [`auto-memory-migration-plan.md`](auto-memory-migration-plan.md) —
   move applicable auto-memory entries.

After both migrations complete and have been verified, close
`J121-ft3` (the original sandbox-provisioning bead in J121's instance,
now superseded by the work tracked here) with a closing reason
referencing the new project.
