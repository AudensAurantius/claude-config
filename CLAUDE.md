# CLAUDE.md — claude-config

Canonical home for Claude tooling on this machine: skills, agent configs,
global settings, slash commands, sandbox infrastructure, and supporting
reference documentation. See:

- [`docs/VISION.md`](docs/VISION.md) — problem statement, goals, guiding
  principles, future scope.
- [`docs/SANDBOX_GUIDE.md`](docs/SANDBOX_GUIDE.md) — operator's reference
  for the sandboxing model and self-modification workflow. (Pointer
  target for the marker-block snippet inserted into `~/.claude/CLAUDE.md`
  by the installer.)
- [`DECISION_LOG.md`](DECISION_LOG.md) — architectural decisions with
  rationale.
- [`docs/transcripts/2026-05-04-sandbox-architecture-discussion.md`](docs/transcripts/2026-05-04-sandbox-architecture-discussion.md)
  — design discussion that established the architecture.

## Build & Run

This repo's contents are source-of-truth; the installer deploys them to
canonical host locations. The repository is self-contained: chezmoi's
role contracts to cloning the repo and invoking `just install`.

```bash
git clone <remote> ~/Source/claude-config
cd ~/Source/claude-config
just install               # deploys to canonical locations; non-destructive by default
just install-test          # deploy to /tmp/claude-sandbox-test (sanity check, no real deploy)
just uninstall             # reverse install (does NOT unprovision claude-session)
just provision             # create claude-session user + subuid + ACLs (sudo)
just                       # list all recipes (sync / lint / fmt / test / smoke / check / …)
```

Quality gates (DEC-022; per-language native tools, orchestrated by `just`):

```bash
just sync                  # uv sync the dev .venv
just lint                  # ruff check + mypy on src/
just fmt-check             # ruff format --check
just shellcheck            # shellcheck all sandbox/*.sh
just test                  # pytest (when 2s3.3 lands)
just check                 # full gate: lint + fmt-check + shellcheck + test
just smoke                 # sandbox/scripts/smoke-test.sh (composed + standalone)
```

Smoke test once Phase 1 ships:

```bash
claude-sandbox --version             # confirms wrapper + namespace + claude
claude-sandbox -p "echo hello"       # one-shot non-interactive sanity check
```

See [DEC-004](DECISION_LOG.md#dec-004-installer-based-deployment-with-non-destructive-defaults-2026-05-04)
for the deployment philosophy and per-file behavior categories.

## Architecture

### Repository layout

```
claude-config/
├── CLAUDE.md                       # this file
├── DECISION_LOG.md                 # architectural decisions with rationale
├── justfile                        # polyglot orchestrator (install map, lint/test/build recipes; DEC-021)
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
│   ├── SANDBOX_GUIDE.md            # sandbox operator reference
│   ├── transcripts/                # design discussion transcripts
│   ├── reviews/                    # review checkpoint summaries
│   └── migration/                  # one-shot migration plans (delete after execution)
└── .beads/                         # bd issue tracker (after migration)
```

Each subdirectory owns its own conventions; consult its own README
where present. New top-level directories require a DECISION_LOG entry.

### Install map (Linux/WSL2)

The installer maps source paths under `claude/` and `sandbox/` to
canonical host locations. Other platforms map to their analogues; the
installer abstracts those differences so the source layout remains
stable. Source paths under `claude/` and `sandbox/` are read-only at
runtime — edits go through the repo, then `just install`.

| Source (in repo) | Installed to | Behavior | Notes |
|---|---|---|---|
| `claude/CLAUDE.md.snippet` | `~/.claude/CLAUDE.md` (marker block) | Marker-block managed | Inserted/updated between delimiters; preserves user content |
| `claude/settings/default.json` | `~/.claude/settings.json` | Three-way prompt | keep / replace / merge-in-editor |
| `claude/settings/profiles/*.json` | `~/.claude/settings.profiles/*.json` | Direct install | Phase 2+ |
| `claude/skills/`, `claude/agents/`, `claude/commands/` | corresponding paths under `~/.claude/` | Direct install | Sandbox bind-mounts these read-only |
| `sandbox/bin/claude-sandbox` | `/usr/local/bin/claude-sandbox` | Direct install | User entry-point; calls `sudo` |
| `sandbox/sbin/claude-sandbox-priv` | `/usr/local/sbin/claude-sandbox-priv` | Direct install | Root-only; namespace setup |
| `sandbox/etc/sudoers.d/claude-sandbox` | `/etc/sudoers.d/claude-sandbox` | Direct install | NOPASSWD for the priv script |
| `sandbox/profiles/*.yaml` | `~/.config/claude-sandbox/profiles/*.yaml` | Direct install | Read by the wrapper at runtime |
| `sandbox/scripts/provision-claude-session.sh` | invoked via `just provision` after install | (provisioning script) | Creates user, sets ACLs, provisions Lua/Node toolchains |

Behavior categories (see [DEC-004](DECISION_LOG.md#dec-004-installer-based-deployment-with-non-destructive-defaults-2026-05-04)):

- **Marker-block managed** — installer inserts/updates a delimited
  region; content outside the markers is untouched. Used for files
  where claude-config owns part of the content but the user owns the
  rest.
- **Three-way prompt** — installer prompts on first install when an
  existing file is detected: keep / replace / merge-in-editor.
  Suppressible via `--accept-defaults` / `--accept-existing` /
  `--non-interactive`.
- **Direct install** — installer writes the file unconditionally
  (with timestamped backup if a prior version exists). Used for
  files claude-config exclusively owns.

### Runtime view (post-Phase-1)

Inside a sandboxed session, `claude-session` sees:

- `~/.claude/` → read-only bind mount of the host's `~/.claude/`
  (which itself was deployed from `claude/` in this repo by the
  installer).
- `~/Source/claude-config/` → writable feature-branch worktree, for
  agent self-modification.
- `~/Source/<project>/` → bind-mounted worktree at the canonical
  path (path-aliased; Phase 4).
- `~/.config/claude-sandbox/profiles/<active>.yaml` → read by the
  wrapper at session start; consumed before `claude` exec.
- All other host paths → either invisible (shadow-mounted tmpfs) or
  inaccessible (filesystem permissions on the user's home).

## Coding Conventions

- **Style:** Python ruff + mypy strict (DEC-019, DEC-022); shell
  scripts pass `shellcheck`; YAML lints via the pre-commit
  `check-yaml` hook. All gated through `just check` (single composite
  recipe; see "Build & Run").
- **Quality gates:** `just check` runs ruff + mypy + ruff-format-check
  + shellcheck + pytest + bats. Same gate fires automatically via
  pre-commit (configured in `.pre-commit-config.yaml`; bd's
  `.beads/hooks/pre-commit` stacks the framework on top of bd's own
  pre-commit logic — no separate `pre-commit install` step needed).
  Bootstrap: `just sync && just pre-commit-run` to confirm the gate
  is green before committing.
- **Commits:** Conventional Commits
  (`feat/fix/docs/refactor/test/chore`), with `Co-Authored-By` trailer
  when the change was AI-assisted.
- **Branches:** feature branches off `main`; merge via PR-style review
  even for solo work, because once Phase 6 ships agents will be
  proposing changes via the same mechanism.
- **Scopes:** `sandbox`, `skills`, `agents`, `commands`, `settings`,
  `installer`, `docs`, `migration`.
- **Decision records:** any choice that affects file layout, runtime
  behavior, or interfaces gets a numbered entry in `DECISION_LOG.md`
  with rationale and alternatives considered.
- **Transcripts:** preserve substantive design discussions under
  `docs/transcripts/<date>-<topic>.md` so the reasoning behind
  decisions doesn't disappear.

## Workflow

### Sandboxed sessions (post-Phase-1)

The default invocation is `claude-sandbox` (or aliased to `claude` in
the shell), which runs Claude Code in an isolated mount namespace as
the `claude-session` user with stripped environment. Per-project
profiles adjust which paths are visible. Profiles never inject
credentials — see [DEC-001](DECISION_LOG.md#dec-001-profiles-manage-visible-context-not-credentials-2026-05-04).

### Self-modification

When a Claude session needs to update tooling — add a skill, refine
an agent definition, edit settings.json — it does so on a feature
branch in the writable worktree at `~/Source/claude-config/`. The
user reviews and merges as with any PR. The canonical (read-only)
view does not update mid-session; new tooling takes effect on the
next session.

### Decisions

Significant choices land in `DECISION_LOG.md`. See the format header
in that file.

## Persistent State

This project participates in the same three-store split used elsewhere:

- **`bd remember` + `bd memories`** — project-technical facts
  (sandboxing pitfalls, namespace gotchas, OAuth quirks).
- **Auto-memory** (`~/.claude/projects/-home-hactar-Source-claude-config/memory/`)
  — preferences and feedback specific to this project's evolution.
- **CLAUDE.md** + `DECISION_LOG.md` — always-on rules and the
  canonical decision history.

## Common Pitfalls

Populate as discovered. Initial seed from the architecture discussion:

1. **Mount namespace requires CAP_SYS_ADMIN.** The sandbox wrapper
   escalates to root via sudoers (NOPASSWD) for the namespace setup,
   then drops to `claude-session` before exec'ing Claude. Putting the
   privileged script in `~/.local/bin/` would be unsafe — sudoers
   must point at a root-owned, user-non-writable path
   (`/usr/local/sbin/`).

2. **Path-aliasing is essential for memory.** If the agent's CWD
   doesn't match the canonical project path string, Claude Code's
   `~/.claude/projects/<hash>/` lookup misses and the agent starts
   without project memory.

3. **OAuth credential paths are HOME-relative.** Choosing where
   `HOME` points inside the sandbox decides which Anthropic identity
   Claude authenticates with. The design uses
   `HOME=/home/claude-session` so the sandbox has its own OAuth
   refresh token, distinct from the user's interactive identity.

4. **A `0700` home does not protect `0755` subdirs reached via an
   inherited cwd.** `sudo` preserves the working directory, so a
   `sudo -u claude-session` process launched from inside the user's
   home keeps a cwd *fd* there; relative reads from that cwd check
   only the immediate dir's perms, never re-checking the `0700` gate
   above. So `~/.local`, `~/.config`, etc. (commonly `0755`) are
   readable by `claude-session` if it inherits a cwd inside them.
   The bwrap/srt sandbox is unaffected (its namespace excludes the
   user's home), but **bare/unsandboxed `claude-session` invocations
   must use a controlled cwd** — always go through `claude-sandbox`
   (which `--chdir`s and runs a cwd guard) or `claude-sandbox --oauth`
   (forces claude-session's own home). Never run bare `claude` as
   `claude-session` from an arbitrary directory. (ClaudeConfig-40s.15.10.)

## Roadmap

Active roadmap: [`docs/VISION.md`](docs/VISION.md) — seven-phase
delivery plan. Per-phase tracking lives in beads under `area:claude-
config` (after Phase 5; until then, in the J121 bd instance under
existing labels).


<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:ca08a54f -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd dolt push
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
<!-- END BEADS INTEGRATION -->
