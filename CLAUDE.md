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
role contracts to cloning the repo and invoking `make install`.

```bash
git clone <remote> ~/Source/claude-config
cd ~/Source/claude-config
make install               # deploys to canonical locations; non-destructive by default
make install-quiet         # non-interactive: accept all installer defaults
make uninstall             # reverse install, restoring timestamped backups
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
├── Makefile                        # platform-aware installer entry point
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
runtime — edits go through the repo, then `make install`.

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
| `sandbox/scripts/provision-claude-session.sh` | runs once during `make install` | (provisioning script) | Creates user, sets ACLs |

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

- **Style:** shell scripts pass `shellcheck`; Python (where used) ruff
  + mypy strict; YAML lints via yamllint.
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

## Roadmap

Active roadmap: [`docs/VISION.md`](docs/VISION.md) — seven-phase
delivery plan. Per-phase tracking lives in beads under `area:claude-
config` (after Phase 5; until then, in the J121 bd instance under
existing labels).
