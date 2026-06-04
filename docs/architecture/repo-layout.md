# Repository layout

Source-tree layout for `claude-config`. Each subdirectory owns its own
conventions; consult its own README where present. New top-level
directories require a `DECISION_LOG.md` entry.

```
claude-config/
├── CLAUDE.md                       # project instructions
├── DECISION_LOG.md                 # architectural decisions with rationale
├── justfile                        # polyglot orchestrator (install map, lint/test/build recipes; DEC-021)
├── mise.toml                       # host-side dev tool version pins (ClaudeConfig-2s3.6)
├── mise.local.toml.example         # template for per-machine overrides (mise.local.toml gitignored)
├── pyproject.toml                  # uv-managed Python project (DEC-019)
├── claude/                         # Claude Code config — installed under ~/.claude/
│   ├── CLAUDE.md.snippet           # marker-block content for ~/.claude/CLAUDE.md
│   ├── settings/
│   │   ├── default.json            # base settings.json
│   │   └── profiles/               # variants selected by sandbox profile
│   ├── skills/                     # global skills
│   ├── agents/                     # global agent definitions
│   └── commands/                   # global slash commands
├── sandbox/                        # sandbox runtime — installed to host paths
│   ├── bin/claude-sandbox          # entry-point wrapper (user-invokable)
│   ├── sbin/claude-sandbox-priv    # privileged namespace setup (root)
│   ├── etc/sudoers.d/claude-sandbox
│   ├── profiles/                   # YAML profile configs (Phase 2+)
│   │   ├── default.yaml
│   │   └── full-trust.yaml
│   └── scripts/                    # provisioning, user creation, ACLs
├── docs/
│   ├── VISION.md                   # problem statement, goals, future scope
│   ├── ROADMAP.md                  # phased delivery plan
│   ├── architecture/               # current-system design (sandbox-model, hooks, audit-log, repo-layout, install-map, sandbox-runtime-view, …)
│   ├── usage/                      # problem statement + use cases + threat model
│   ├── guides/                     # operator how-to (oauth-bootstrap, profiles, troubleshooting, quickstart-upstream, etckeeper-protocol)
│   ├── specs/                      # forward-looking dev specs (e.g. phase6-worker-isolation.md)
│   ├── research/                   # upstream-tooling / ecosystem-overlap surveys
│   ├── transcripts/                # design discussion transcripts
│   ├── reviews/                    # review checkpoint summaries
│   └── migration/                  # one-shot migration plans (delete after execution)
└── .beads/                         # bd issue tracker
```
