# CLAUDE.md — claude-config

Canonical home for Claude tooling on this machine: skills, agent configs,
global settings, slash commands, sandbox infrastructure, and supporting
reference documentation. See:

- [`docs/VISION.md`](docs/VISION.md) — problem statement, goals, guiding
  principles, future scope.
- [`docs/architecture/`](docs/architecture/) — current-system design
  reference: [`sandbox-model.md`](docs/architecture/sandbox-model.md),
  [`hooks.md`](docs/architecture/hooks.md),
  [`audit-log.md`](docs/architecture/audit-log.md). (Pointer target
  for the marker-block snippet inserted into `~/.claude/CLAUDE.md` by
  the installer.)
- [`docs/guides/`](docs/guides/) — operator how-to:
  [`oauth-bootstrap.md`](docs/guides/oauth-bootstrap.md),
  [`profile-authoring.md`](docs/guides/profile-authoring.md),
  [`self-modification.md`](docs/guides/self-modification.md),
  [`troubleshooting.md`](docs/guides/troubleshooting.md),
  [`quickstart-upstream.md`](docs/guides/quickstart-upstream.md).
- [`DECISION_LOG.md`](DECISION_LOG.md) — architectural decisions with
  rationale.
- [`docs/transcripts/2026-05-04-sandbox-architecture-discussion.md`](docs/transcripts/2026-05-04-sandbox-architecture-discussion.md)
  — design discussion that established the architecture.

## Build & Run

This repo's contents are source-of-truth; the installer deploys them to
canonical host locations. The repository is self-contained: chezmoi's
role contracts to cloning the repo and invoking `just install`.

Host-side dev tooling is managed by [mise](https://mise.jdx.dev): tool
versions are pinned in `mise.toml` (committed); per-machine overrides
live in `mise.local.toml` (gitignored, see `mise.local.toml.example`).
Bootstrap on a fresh clone:

```bash
git clone <remote> ~/Source/claude-config
cd ~/Source/claude-config
mise install               # provisions Python, Go, LuaJIT, stylua, shfmt,
                           # lua-language-server, shellcheck, cue, bats;
                           # seeds .luarocks/ with lyaml + lua-cjson + busted
just install               # deploys to canonical locations; non-destructive by default
just install-test          # deploy to /tmp/claude-sandbox-test (sanity check, no real deploy)
just uninstall             # reverse install (does NOT unprovision claude-session)
just provision             # create claude-session user + subuid + ACLs (sudo)
just                       # list all recipes (sync / lint / fmt / test / smoke / check / …)
```

Build deps for `mise install`'s luarocks step: a C toolchain + libyaml-dev
(`apt install build-essential libyaml-dev`). Without these, the luarocks
seeding fails non-fatally; Lua tests will error loudly when run.

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

Full source tree with per-directory annotations:
[`docs/architecture/repo-layout.md`](docs/architecture/repo-layout.md).
Each subdirectory owns its own conventions; consult its own README
where present. New top-level directories require a DECISION_LOG entry.

### Install map (Linux/WSL2)

Full source → host mapping, per-row behavior, and the three install
behavior categories (marker-block managed, three-way prompt, direct
install) live in
[`docs/architecture/install-map.md`](docs/architecture/install-map.md).
See [DEC-004](DECISION_LOG.md#dec-004-installer-based-deployment-with-non-destructive-defaults-2026-05-04)
for the deployment philosophy that drives the categories.

### Runtime view (post-Phase-1)

What `claude-session` sees inside a sandboxed session (bind mounts,
visible host paths, shadow-mounted hidden paths): see
[`docs/architecture/sandbox-runtime-view.md`](docs/architecture/sandbox-runtime-view.md).

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
- **Branches:** feature branches off `main` are the default. Agents
  are allowed to operate on `main` directly for merges, hotfixes,
  beads-state commits, and similar bookkeeping — the "branches by
  default" rule is for *new feature work*, not a hard prohibition
  against ever touching `main`.
- **No orphan feature branches.** Any implementation work that lives
  on a feature branch must be either (a) merged to `main` before the
  session that produced it ends, or (b) accompanied by an explicit
  `review` / `merge` bead that **blocks** the next dependent
  implementation bead. The graph must reflect the reality on disk —
  if `ciw.2` can't proceed until `ciw.1`'s branch is merged, that
  dependency belongs in `bd`, not in a future Claude's head. Why this
  matters: bd's `ready` queue and `dep cycles` check are the
  authoritative "what can I work on" surface; a feature branch
  detached from a bead is invisible to that surface, and the next
  session will branch off a `main` that's missing prerequisites it
  has no way to know about.
- **Supplemental strategy — short branch lifetimes.** The review-bead
  pattern handles the legitimate case where a branch must persist
  across sessions (incubation, external review, large WIP). For
  routine work, the simpler rule "land it before the session ends"
  avoids the problem entirely. Prefer that path; reserve review beads
  for branches that genuinely need to outlive their session.
- **Scopes:** `sandbox`, `skills`, `agents`, `commands`, `settings`,
  `installer`, `docs`, `migration`.
- **Decision records:** any choice that affects file layout, runtime
  behavior, or interfaces gets a numbered entry in `DECISION_LOG.md`
  with rationale and alternatives considered.
- **Transcripts:** preserve substantive design discussions under
  `docs/transcripts/<date>-<topic>.md` so the reasoning behind
  decisions doesn't disappear.

## Workflow

### `/etc/` changes go to etckeeper

Any session that modifies `/etc/` (systemd units, config files, `sed -i`
substitutions, chmods on unit-managed paths, etc.) must commit those
changes to **etckeeper** before declaring the work complete. The repo
is git-crypt-armed; new sensitive files must be gated via
`/etc/.gitattributes` before their first commit. Full protocol in
[`docs/guides/etckeeper-protocol.md`](docs/guides/etckeeper-protocol.md).

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

Sandbox/namespace/OAuth/cwd-inheritance pitfalls live in bd memories under the
`pitfall-sandbox-*` prefix. See `bd memories pitfall-sandbox` for the catalog.
File new pitfalls there as discovered.

## Roadmap

Active roadmap: [`docs/VISION.md`](docs/VISION.md) — seven-phase
delivery plan. Per-phase tracking lives in beads under `area:claude-
config` (after Phase 5; until then, in the J121 bd instance under
existing labels).
