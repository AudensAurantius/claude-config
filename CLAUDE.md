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

```
claude-config/
├── CLAUDE.md                       # this file
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
│   ├── architecture/               # current-system design (sandbox-model, hooks, audit-log, …)
│   ├── usage/                      # problem statement + use cases + threat model
│   ├── guides/                     # operator how-to (oauth-bootstrap, profiles, troubleshooting, quickstart-upstream)
│   ├── specs/                      # forward-looking dev specs (e.g. phase6-worker-isolation.md)
│   ├── research/                   # upstream-tooling / ecosystem-overlap surveys
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
| `sandbox/scripts/provision-claude-egress.sh` | invoked via `just provision-egress` (chained into `just provision`) | (provisioning script) | Creates claude-egress UID + `/etc/claude-config/{egress-policy,credentials}/` (DEC-013) |
| `sandbox/broker/` (Go source) → `sandbox/broker/bin/claude-egress-broker` | `/usr/local/sbin/claude-egress-broker` (via `just install-egress-broker`) | Build + sudo install | Production egress broker (DEC-013, DEC-029); Python reference frozen at `sandbox/reference/egress-broker-python/` |
| `sandbox/scripts/prime-egress-broker.sh` | `/usr/local/sbin/prime-egress-broker` (via `just install-egress-broker`) | sudo install | Coordinator-side gpg-agent primer (ClaudeConfig-bd5); seeds sentinel, runs `gpg-preset-passphrase` |
| `sandbox/scripts/claude-egress-broker-healthcheck.sh` | `/usr/local/sbin/claude-egress-broker-healthcheck` (via `just install-egress-broker`) | sudo install | ExecStartPre sentinel-decrypt; refuses broker start when agent cache is cold |
| `sandbox/etc/gpg-agent.conf` | `/home/claude-egress/.gnupg/gpg-agent.conf` (via `just provision-egress`) | Install via provision script | Enables `allow-preset-passphrase` + long cache TTL for the primed agent |
| `sandbox/systemd/claude-egress-broker.{socket,service}` | `/etc/systemd/system/` (via `just install-egress-broker`) | sudo install | Type=notify, socket-activated; operator substitutes CLAUDE_SESSION_UID via `systemctl edit`; service ExecStartPre validates primed gpg-agent |

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

Whenever a session modifies anything under `/etc/` (installing systemd
units, dropping config files, substituting a placeholder via `sed -i`,
chmoding a unit-managed path, etc.), the session must commit those
changes to **etckeeper** before declaring the work complete. The repo
is at `/etc/.git` with remote
`git@github.com:AudensAurantius/etckeeper`.

Protocol:

1. **Audit first.** `sudo bash -c 'cd /etc && git status'` to see new
   and modified paths.
2. **Verify each new tracked file is correctly gated for secrets:**
   - If the file is root-only AND non-secret: add to
     `/etc/etckeeper/git-crypt-allowlist`.
   - If the file is root-only AND secret: add to `/etc/.gitattributes`
     with `<path> filter=git-crypt diff=git-crypt` **before the first
     commit**. (Once a secret is committed in the clear and pushed,
     rewriting history is the only fix — much worse than getting it
     right the first time.)
   - World-readable files (e.g. `passwd`, `group`, `systemd/system/*.service`)
     need no special treatment.
3. **Commit:** `sudo etckeeper commit "message describing the change"`.
   The `40check-secrets` pre-commit hook will block if step 2 was
   missed. Treat any block as a real failure: do not bypass with
   `--no-verify` or by editing the hook out.
4. **Push** (operator's choice): `sudo bash -c 'cd /etc && git push'`
   when ready. Pushing is optional from a session's standpoint —
   safety is enforced at commit-time, not push-time.

Background: the etckeeper repo is git-crypt-armed. Sensitive files
(`shadow`, `gshadow`, `ssl/private/**`, `mysql/debian.cnf`, etc.) are
transparently encrypted via `.gitattributes`; the hook is the safety
net for new sensitive files that haven't been wired up yet. Full
detail in bd memory `etckeeper-commit-protocol-this-host-s-etckeeper-repo`
(searchable via `bd memories etckeeper`).

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
