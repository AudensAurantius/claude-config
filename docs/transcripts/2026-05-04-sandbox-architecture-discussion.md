# Transcript — Sandbox Architecture Discussion (2026-05-04)

Discussion that established the architectural foundations for `claude-config`:
universal Claude session sandboxing, the unified-canonical-config model, the
git-worktree agent pattern, and the autosession daemon roadmap.

The session began in the J121 working directory while debugging a Snowflake
deployment pipeline. After that work resolved, the conversation pivoted to
security: a VentureBeat article on AI coding agent exploits prompted a
discussion about sandboxing Claude Code on this machine. That discussion grew
substantially in scope and resulted in the decision to spin up `claude-config`
as the home for the resulting infrastructure.

This transcript preserves the architectural reasoning so the new project can
proceed without re-deriving it.

---

## Topic 1 — VentureBeat findings (summary)

Reference: <https://venturebeat.com/security/six-exploits-broke-ai-coding-agents-iam-never-saw-them>

The article disclosed six exploits across Codex, Claude Code, and Copilot,
all following the same pattern: an agent holds a credential, executes a
command, and authenticates to a production system without a human session
anchoring the request.

| # | Agent | Vector | Impact |
|---|-------|--------|--------|
| 1 | OpenAI Codex | Unicode-obfuscated git branch names injected into shell | GitHub OAuth token exfiltrated |
| 2 | Claude Code (CVE-2026-25723) | `sed`/`echo` pipe chains escaped sandbox | Read files outside project dir |
| 3 | Claude Code (CVE-2026-33068) | `.claude/settings.json` parsed before trust prompt; `bypassPermissions` honoured | Repo-controlled elevation |
| 4 | Claude Code (50-subcommand bypass) | Compound commands with 51+ subcommands skipped deny-rule analysis | All security checks bypassed |
| 5 | GitHub Copilot (CVE-2025-53773) | Hidden instructions in PR descriptions | Auto-approve mode enabled |
| 6 | Copilot/Codespaces | Symlinks via malicious issues | `GITHUB_TOKEN` exfiltrated |

Three of the six affected Claude Code directly. The 50-subcommand bypass was
particularly concerning given the workflow on this machine, where many repos
ship a `CLAUDE.md` that Claude Code reads on session start: a malicious repo
could embed 50 legitimate-looking build steps and exfiltrate credentials in
the 51st without any deny rule firing.

A separate non-exploit incident also surfaced: on 2026-03-31 Anthropic
accidentally shipped a JavaScript sourcemap exposing 512,000 lines of
Claude Code's TypeScript source to the npm registry. The leak gave researchers
the source needed to identify the 50-subcommand issue quickly.

**Initial recommendations against the existing workflow:**

- Update Claude Code to ≥ 2.1.90 (50-subcommand fix).
- Treat the pre-authorized repo list (`.beads/`, `tasks/`, `chezmoi`) as a
  blast-radius limit — adding broad directories like `~/Source/` would be
  unsafe.
- Recognize that `SNOWFLAKE_PRIVATE_KEY`, ADO PATs, and pass-store secrets in
  the environment are exactly the credentials these exploits exfiltrate, and
  the workflow currently keeps them in the same shell where Claude Code runs.

---

## Topic 2 — Initial sandbox proposals

The discussion considered three layers of mitigation.

### Dedicated Linux user

A `claude-session` user with reduced filesystem access. This works at the
filesystem level (the user can't read `~/.config/snowflake/keys/`) but doesn't
help if credentials are passed via environment variables. It's also not a
boundary against a Claude Code process running as the original user.

### `chroot` jail

Discarded as a weak boundary: it requires root, can be escaped by privileged
processes, and would require mirroring the entire Node/npm tree into the jail.

### Linux mount namespaces (`unshare --mount`)

Stronger than chroot. Allows shadow-mounting sensitive paths with empty
tmpfs so they appear empty to processes inside the namespace. Combined with
`env -i` to strip the environment and `sudo -u claude-session` to drop
privileges, this gives:

- No work credentials in env (`env -i`)
- No filesystem access to credential paths (mount namespace)
- No write access outside `~/.claude` (separate user)

This is the foundation we eventually built on.

---

## Topic 3 — The OAuth, memory, and chezmoi-conventions corrections

Three correction rounds shaped the design:

1. **OAuth, not API key.** The Anthropic auth for this workflow comes from a
   browser OAuth flow tied to a company subscription. Credentials live in
   `~/.claude/.credentials.json` as a refresh token. There is no
   `ANTHROPIC_API_KEY` to pass in the environment. This means `HOME` placement
   matters: Claude Code looks at `${HOME}/.claude/.credentials.json` to
   authenticate, so the choice of `HOME` determines which OAuth identity
   Claude uses.

2. **Memory writes are a hard requirement.** `~/.claude/projects/<hash>/`
   accumulates `claude-mem` observations and auto-memory files. If the
   sandbox user can read these but cannot write to them, sandboxed sessions
   silently drop their observations — defeating the memory system that the
   workflow depends on.

3. **Chezmoi conventions.** No hardcoded `/home/hactar` paths in template
   files. Template variables (`{{ .chezmoi.homeDir }}`,
   `{{ .chezmoi.username }}`) and the `.tmpl` suffix on scripts that need
   substitution.

These corrections drove the design toward bind-mounting the host's
`~/.claude/projects/` into the claude-session user's `~/.claude/projects/`
inside the namespace, so memory writes flow back to the canonical location.

---

## Topic 4 — Scope shift to universal sandboxing

The user pivoted the scope: rather than a "secure mode" for risky sessions,
**every** Claude session would be sandboxed by default, with per-project
levers for adjusting the level of isolation.

This dissolved several earlier design tensions:

- **Settings.json split.** With universal sandboxing, there is no "your
  normal" vs. "sandbox-specific" `settings.json`. The canonical `claude-config`
  IS your settings, used by all sessions. Profile differentiation (stricter
  for agent sessions, more permissive for interactive) becomes a choice
  among committed variants in the repo.
- **Skills exposure.** The same logic: `claude-config/skills/` is the
  canonical home, exposed read-only to all sandboxed sessions.

The repo became the source of truth for the entire Claude tooling
ecosystem on this machine.

---

## Topic 5 — Parallel sessions and agent collaboration

The user identified a tension: per-session mount namespaces give strong
isolation but break workflows where agents need to inspect each other's
work (review agents reading worker output, coordinator agents observing
session state).

Two options were considered:

- **A:** Reference-counted shared bind mounts. A counter file tracks the
  number of active sessions; the wrapper destroys the mount only when the
  last session exits.
- **B:** Per-session namespaces with isolation, accepting that agents can't
  directly read each other's filesystems.

**Decision: option B, with git/dolt as the collaboration medium.** Agents
collaborate the way humans on remote teams collaborate — through git, not by
reading each other's working directories. This has a strong observability
property: every inter-agent communication becomes a git commit, beads
update, or comment, all auditable and version-controlled.

Concrete coordination pattern:

```
Coordinator agent
  └─ reads beads queue for tasks
  └─ dispatches Worker agent for J121-xyz
       └─ fresh namespace, fresh worktree on session-W1/J121-xyz
       └─ implements, commits, pushes branch, updates bead
  └─ detects new branch + bead status change
  └─ dispatches Review agent
       └─ fresh namespace, READ-ONLY checkout of session-W1/J121-xyz
       └─ runs `git diff main...`, examines changes, posts review via bead
  └─ either dispatches Worker for revisions, or marks bead ready-to-merge
  └─ human does the actual merge
```

---

## Topic 6 — Git worktree pattern

Rather than bind-mounting project directories directly into the agent's
view, the agent gets a fresh `git worktree` on a session-specific feature
branch. This is enforced by the sandbox: the agent cannot see the parent
clone, only its worktree.

**Properties:**

- Agent sees only what's in source control. No `.envrc`, no `.beads/` (unless
  explicitly exposed), no untracked WIP, no accidentally-cached credentials.
- Branch enforcement is automatic. `git worktree add -b session-<id> <path>
  origin/main` starts the agent on a fresh feature branch off main. Server-
  side branch policies prevent direct pushes to main.
- Cleanup is trivial. Worktree gets destroyed at session end; agent state
  doesn't accumulate on disk.

**Wrinkle: project-hash continuity for memory.** Claude Code computes the
`~/.claude/projects/<hash>/` path from the working directory string. If the
agent's CWD is `/home/claude-session/Source/J121-worktree-abc/`, the hash
differs from the canonical clone, so memory continuity breaks.

**Solution: path-aliasing via mount namespace.** Inside the agent's
namespace, the worktree is bind-mounted at the canonical path
(`/home/hactar/Source/J121/`). The CWD string matches; the hash matches; the
agent shares memory with the canonical project.

This works because mount namespaces let the same path resolve to different
filesystems in different namespaces. Outside the namespace, the path is the
canonical clone. Inside, it's the worktree.

**Caveat to watch:** if agent observations flow into the canonical
`~/.claude/projects/<hash>/memory/`, they mix with the user's own
observations. A subdirectory marked as agent-origin
(`memory/agent-observations/`) that the auto-memory `MEMORY.md` index
doesn't auto-load is the cleanest mitigation. Treat agent memory like
agent code — propose, review, promote.

---

## Topic 7 — Beads sandboxing via Dolt branch restriction

To extend the sandboxing model to beads/Dolt:

- Create a `bd-claude-session` Dolt user.
- Grant SELECT on all branches (agents need full beads context to make good
  decisions).
- Grant INSERT/UPDATE/DELETE only on branches matching `claude/*`.
- Each agent session gets its own Dolt branch (`claude/<session-id>`).
- Coordinator (or human) merges approved branches back to `main`.

This mirrors the git worktree pattern: agents propose changes; humans (or a
designated coordinator) merge. Beads becomes a code-review workflow for
task state itself.

Per-class restrictions ("agents can only modify beads with
`area:agent-tasks`") were considered but deferred — branch-level granularity
is the right starting point because Dolt grants don't see row labels.
Application-level enforcement in `bd` itself can come later if needed.

---

## Architecture and Roadmap (Claude's synthesis, reproduced verbatim)

Reproduced verbatim from the assistant's final pre-decision response in this
discussion. Subsequent decisions (recorded in DECISION_LOG.md) accepted this
roadmap.

> **Universal sandboxing as the default.** This changes the framing
> significantly — you're not building a "secure mode" for risky sessions,
> you're rebuilding the foundation. The "per-project levers" concept is
> doing the real work here. Concretely, that becomes a profile system:
>
> ```
> ~/.config/claude-sandbox/profiles/
>   default.yaml         # baseline: nothing exposed
>   snowflake.yaml       # exposes ~/.config/snowflake/, snowflake_migrations/
>   portal-build.yaml    # exposes ADO PAT for NuGet, the J121 worktree
>   full-trust.yaml      # for emergency parity with old behavior
> ```
>
> `claude-sandbox --profile snowflake` (or auto-selected from the project's
> `.claude/sandbox-profile` file). The wrapper reads the profile and
> configures the namespace accordingly. This generalizes well to the
> autosession daemon — each spawned agent gets a profile based on its task
> class.
>
> ---
>
> **Unified claude-config project — endorsed, one refinement.** Your
> structure:
>
> ```
> ~/Source/claude-config/                  ← canonical, you edit on main
> ~/Source/claude-config-agent-worktree/   ← writable feature-branch worktree
>                                             bind-mounted into claude-session's home
> ```
>
> Inside the sandbox, claude-session sees:
>
> - `~/.claude/` → read-only bind mount of `~/Source/claude-config/` (your canonical)
> - `~/Source/claude-config/` → writable worktree on a session-specific feature branch
>
> The refinement: **don't symlink `~/.claude/`, bind-mount it.** Symlinks
> across the namespace boundary get awkward when the target lives in your
> home and the namespace is shadowing parts of your home. Bind mounts are
> explicit and the read-only flag is enforceable at the kernel level.
>
> Settings.json question dissolves under this model. There's no
> "sandbox-specific" settings.json vs. "your normal" one — the canonical
> claude-config IS your settings, used by both your direct `claude`
> invocations (eventually deprecated) and all sandboxed sessions. The repo
> becomes the source of truth. If you want differentiated settings (e.g.,
> agent sessions get stricter deny rules than your interactive sessions),
> that's a profile setting that picks one of N committed `settings.json`
> variants from the repo.
>
> ---
>
> **The parallel-session / coordinator-collaboration question — this is the
> meat.**
>
> Your two options are real, but I'd argue the answer is option B
> (per-session namespaces) **with git/dolt as the collaboration medium, not
> shared filesystems.**
>
> Reference-counted bind mounts (option A) work for serial+occasional-overlap
> use, but they're fighting the kernel. They also don't help with the deeper
> isolation problem: two agents in the same namespace can read each other's
> session files, scratch directories, claude-mem state, etc. That's exactly
> the kind of cross-contamination that erodes the security model you're
> building.
>
> For coordinator/review patterns, agents collaborate the way humans on
> remote teams collaborate: through git. Not through reading each other's
> working directories.
>
> ```
> Coordinator agent
>   └─ reads beads queue for tasks
>   └─ dispatches Worker agent for J121-xyz
>        └─ fresh namespace, fresh worktree on session-W1/J121-xyz
>        └─ implements, commits, pushes branch, updates bead
>   └─ detects new branch + bead status change
>   └─ dispatches Review agent
>        └─ fresh namespace, READ-ONLY checkout of session-W1/J121-xyz
>        └─ runs `git diff main...`, examines changes, posts review via bead comment
>   └─ either dispatches Worker for revisions, or marks bead ready-to-merge
>   └─ you do the actual merge
> ```
>
> The reviewer never reads the worker's filesystem. It reads the branch the
> worker pushed. This is identical to how you'd review a colleague's PR —
> you don't ssh into their machine, you fetch their branch.
>
> This pattern has a lovely property: agent collaboration is fully
> observable. Every "communication" between agents is a git commit, a beads
> update, or a comment — all auditable, all in version control. No invisible
> side channels.
>
> ---
>
> **Git worktree pattern — endorsed, plus the memory wrinkle.**
>
> This is the cleanest constraint mechanism I've seen for AI agents. Agent
> sees only what's in source control. No `.envrc`, no untracked config, no
> in-progress notes you forgot to commit. You don't have to remember to
> scrub the directory before launching an agent — git already did.
>
> The feature-branch enforcement is automatic: `git worktree add -b
> session-<id> <path> origin/main` creates a fresh worktree on a fresh
> branch off main. The agent's commits go to that branch. You merge if
> approved. (You can additionally enforce server-side that nobody pushes to
> main except via PR — your existing ADO branch policies already do this.)
>
> **The memory wrinkle.** Claude Code hashes the working directory path to
> compute the `~/.claude/projects/<hash>/` location. If the agent's CWD is
> `/home/claude-session/Source/J121-worktree-abc/`, the hash differs from
> your canonical `/home/hactar/Source/J121/`, so the agent has no access to
> your project memory. Each agent session would start cold.
>
> **Path aliasing via mount namespace** solves this elegantly. Inside the
> agent's namespace, you bind-mount the worktree at `/home/hactar/Source/
> J121/` — the same path your canonical clone occupies in your namespace.
> The agent's CWD matches your canonical path; the project hash matches;
> auto-memory `MEMORY.md`, claude-mem observations, and bd memories all
> resolve to the same location.
>
> Outside the namespace, that path is still your canonical clone. Inside,
> it's the worktree. Same string, different mount.
>
> One caveat to flag: if you let agent memory writes flow into your
> canonical `~/.claude/projects/<hash>/memory/`, agent observations mix
> with yours. That may or may not be desirable. The simplest mitigation is
> a labeled subdirectory (`agent-observations/`) that the auto-memory
> MEMORY.md index doesn't load by default — you review and promote
> selectively. Treat it as the same review pattern you're already using for
> code: agent proposes, you accept.
>
> ---
>
> **Dolt user for beads — yes, branch-level restriction.**
>
> Dolt has MySQL-compatible auth and grants. The right model:
>
> - `bd-claude-session` Dolt user, granted SELECT on all branches,
>   INSERT/UPDATE/DELETE only on branches matching `claude/*`
> - Each agent session gets a Dolt branch `claude/<session-id>`
> - Agent's `bd create`/`bd update`/`bd close` operations run against its
>   branch
> - A coordinator (or you) merges `claude/*` branches back to `main` after
>   review
>
> This mirrors the git pattern exactly: agents propose changes; you (or a
> designated coordinator) merge. Beads becomes a code-review-style workflow
> for task state itself.
>
> The class-restriction idea ("agents can only modify beads with
> `area:agent-tasks`") is appealing but harder — it requires application-
> level enforcement in `bd` because Dolt grants don't see row labels.
> Branch-level is the right starting point; per-class restrictions can come
> later if the pattern needs it.
>
> ---
>
> **Putting it together — the architecture roadmap.**
>
> | Phase | Deliverable | Unlocks |
> |---|---|---|
> | 1 | claude-sandbox wrapper (single profile, single worktree, single namespace per invocation) | Universal sandboxing for serial use |
> | 2 | Profile system (per-project levers via YAML configs) | Snowflake/Portal/general work all run sandboxed |
> | 3 | Per-session namespace + worktree creation | Parallel sessions; agent collaboration via git |
> | 4 | Path-aliasing for memory continuity | Auto-memory works inside sandboxed agents |
> | 5 | Dolt user + branch-restricted beads | Agent task state tracked safely |
> | 6 | Autosession daemon (coordinator + workers + reviewers) | The swarm |
>
> Phase 1 is what we were about to write. Phase 5 might want to come before
> Phase 6 because the daemon will want to query/update beads heavily and
> needs the auth model in place. Phases 3 and 4 likely land together since
> per-session namespaces without path-aliasing would break memory.

---

## User decisions reached this session

1. **Universal sandboxing is the workflow default.** Levers are
   per-project profile configs.
2. **`claude-config` is the unified canonical home.** Skills, settings,
   agents, global CLAUDE.md, sandbox infrastructure, autosession daemon —
   all live here.
3. **Per-session namespaces (option B), git as collaboration medium.**
4. **Git worktree pattern enabled by default in Phase 1.** The
   worktree-vs-canonical lever is exposed in per-project profiles for
   later phases; Phase 1 starts with worktrees on.
5. **Beads migrate from J121 to claude-config.** Dolt auth model can be
   refined later — re-importable if necessary.
6. **Project provisioning bead (J121-ft3) supersedes its J121-scoped
   framing.** It will be re-filed in claude-config beads after migration,
   then the J121 instance closed.

---

## Open items, deferred to follow-up sessions

- Phase 1 implementation (the actual `claude-sandbox` wrapper, sudoers,
  user provisioning script).
- Beads init in `claude-config` via `bd-timew init-project`.
- Bead migration from J121 to claude-config.
- Auto-memory migration audit and execution.
- claude-mem corpus handling (re-prime for new path or accept cross-corpus
  search; not blocking).
