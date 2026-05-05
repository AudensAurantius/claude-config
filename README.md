# claude-config

Canonical home for Claude Code tooling on this machine: skills, agent
configs, global settings, slash commands, sandbox infrastructure, and
supporting reference documentation.

This repo is the source of truth for the entire Claude tooling
ecosystem on this workstation. The contents of `~/.claude/` and the
sandbox runtime under `/usr/local/{bin,sbin}/` are deployed from here
by the installer.

## What this is for

Two problems, one repo:

1. **Configuration sprawl.** Claude Code on this machine has accumulated
   skills, agents, and settings across `~/.claude/`, chezmoi templates,
   and ad-hoc directories. This repo unifies all of it.

2. **Runtime exposure.** AI coding agents are an actively-targeted
   credential exfiltration surface. The current workflow runs Claude
   Code in the same shell as Snowflake JWTs, ADO PATs, and the pass
   store. `claude-config` ships a Linux-namespace sandbox that isolates
   Claude sessions from credentials they don't need.

See [`docs/VISION.md`](docs/VISION.md) for the full problem statement,
goals, and guiding principles.

## Documentation map

- [`docs/VISION.md`](docs/VISION.md) — problem statement, goals, guiding
  principles, future scope.
- [`docs/ROADMAP.md`](docs/ROADMAP.md) — seven-phase delivery plan with
  acceptance criteria per phase.
- [`docs/SANDBOX_GUIDE.md`](docs/SANDBOX_GUIDE.md) — operator's reference
  for the sandbox runtime (fills in as phases ship).
- [`DECISION_LOG.md`](DECISION_LOG.md) — architectural decisions with
  rationale and alternatives considered.
- [`CLAUDE.md`](CLAUDE.md) — project conventions and workflow.
- [`docs/transcripts/`](docs/transcripts/) — preserved design discussions
  underlying the architecture.
- [`docs/reviews/`](docs/reviews/) — review checkpoint summaries.

## Quick start

```bash
git clone <remote> ~/Source/claude-config
cd ~/Source/claude-config
make install               # deploys to canonical locations; non-destructive defaults
```

Once Phase 1 ships:

```bash
claude-sandbox --version             # confirms wrapper + namespace + claude
claude-sandbox -p "echo hello"       # one-shot non-interactive sanity check
```

See [`docs/ROADMAP.md`](docs/ROADMAP.md) for current phase status.

## Repository layout

```
claude-config/
├── README.md                       # this file
├── CLAUDE.md                       # project conventions
├── DECISION_LOG.md                 # architectural decisions
├── Makefile                        # platform-aware installer entry point
├── claude/                         # Claude Code config (deployed under ~/.claude/)
├── sandbox/                        # sandbox runtime (deployed to host paths)
├── docs/                           # vision, roadmap, sandbox guide, transcripts
└── .beads/                         # bd issue tracker
```

Top-level subdirectories own their own conventions; consult their own
README where present. New top-level directories require a
`DECISION_LOG.md` entry.

## Issue tracking

Active work tracks in beads under labels:

- `scope:infrastructure` — sandbox runtime, installer, Phase 1+ deliverables
- `scope:research` — tooling and plugin evaluations
- `scope:review` — audits and validation gates
- `scope:skills` — skills, slash commands, agent definitions
- `migrate-to:bd-timew` — bd-timew-related beads, destined for that repo's
  own beads instance

Phase-tagged work uses `area:phase1` through `area:phase7`. See
[`docs/ROADMAP.md`](docs/ROADMAP.md) for phase scope and acceptance.
