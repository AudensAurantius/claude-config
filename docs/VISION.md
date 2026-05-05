# Project Vision — claude-config

## Problem Statement

Claude Code on this machine is configured through a sprawl of files scattered
across `~/.claude/`, chezmoi-managed templates, project-local `CLAUDE.md`
files, and ad-hoc skills directories. There is no single canonical home for
"how I run Claude Code." This makes the configuration hard to evolve, hard
to review, and impossible to deploy reproducibly to another machine.

It also leaves the runtime exposed. Recent disclosures (BeyondTrust on
Codex, Adversa on Claude Code, see
[`docs/transcripts/2026-05-04-sandbox-architecture-discussion.md`](transcripts/2026-05-04-sandbox-architecture-discussion.md))
demonstrate that AI coding agents are now an actively-targeted credential
exfiltration surface. The current workflow runs Claude Code in the same
shell as Snowflake JWT keys, ADO Personal Access Tokens, the pass store,
and SSH keys. A successful prompt-injection attack against a malicious
`CLAUDE.md` would walk away with all of them.

`claude-config` solves both problems at once. It is the canonical home for
Claude tooling on this machine *and* the runtime sandbox infrastructure
that isolates Claude sessions from credentials they don't need.

## Goals

1. **Single source of truth for Claude tooling.** Skills, agent configs,
   global `CLAUDE.md`, settings.json variants, slash commands, and supporting
   reference documentation all live in this repo. The contents of
   `~/.claude/` on any working machine are a deployment of this repo (via
   chezmoi or bind mount).

2. **Universal session sandboxing.** Every interactive Claude Code
   invocation runs inside a Linux mount namespace as a dedicated
   `claude-session` user. Work credentials are not visible to the Claude
   process by default. Per-project profile configs expose only the
   credential paths needed for the task at hand.

3. **Reproducible agent collaboration.** Multiple agents can run in
   parallel in isolated namespaces. They collaborate via git and beads,
   not via shared filesystems. Every inter-agent communication is a
   commit, branch, or beads update — observable and version-controlled.

4. **Agent self-modification with human review.** Agents can propose
   changes to their own configuration (skills, settings, agent
   definitions) by committing to feature branches in this repo. Humans
   review and merge as with any other PR.

5. **Autosession swarm foundation.** The infrastructure built for
   single-session sandboxing extends naturally to a coordinator-and-workers
   pattern, where a long-lived coordinator dispatches short-lived agent
   sessions against a beads task queue.

## Guiding Principles

These principles inform every architectural choice in this repo. Decisions
that conflict with them require an explicit DECISION_LOG entry justifying
the exception.

### Agents do not hold credentials whose damage radius exceeds their sandbox

Sandbox profiles never inject credentials whose use can affect production
systems, external APIs, or shared state outside the sandbox. Auth that is
structurally bounded — branch-restricted Dolt users, the agent's own
Anthropic OAuth identity, write access to a dedicated git worktree — is
a *safety mechanism*, not a privilege, and is permitted. Privileged
operations against external systems (Snowflake, ADO, AWS, production
deployments) follow the recommend-and-execute pattern with the human (or
a future privileged-action executor agent) as the final-mile authority.

### Profiles manage visible context, not credentials

Profile configs control which filesystem paths are visible to a sandboxed
session, which worktrees exist (and whether they're writable), which
skills are loaded, and which network access is permitted. They do not
inject environment variables containing secrets, do not unlock the pass
store, and do not expose credential directories. If a task requires a
credential to complete, the agent generates a recommendation (a command,
a SQL statement, a deployment plan) and the human reviews and executes.

### Agent collaboration happens through git and beads, not shared filesystems

Per-session namespaces give strong isolation. Coordinator/review patterns
work the way human remote teams work: agents push branches and update bead
state; other agents read those branches and bead updates. Every
inter-agent communication is observable, version-controlled, and
auditable. No agent reads another agent's working directory.

### Self-modification follows the same review pattern as code

When agents need to update their own configuration — refine a skill, edit
an agent definition, propose a settings change — they do so on a feature
branch in this repo's writable worktree. A human reviews and merges. The
canonical (read-only) view does not update mid-session; new tooling takes
effect on the next session.

## Architecture (summary)

The detailed architecture and roadmap live in
[`docs/transcripts/2026-05-04-sandbox-architecture-discussion.md`](transcripts/2026-05-04-sandbox-architecture-discussion.md).
The seven-phase delivery plan:

| Phase | Deliverable | Unlocks |
|---|---|---|
| 1 | `claude-sandbox` wrapper (single profile, single worktree, single namespace per invocation) | Universal sandboxing for serial use |
| 2 | Profile system (per-project levers via YAML configs) | Differentiated visible-context per task class |
| 3 | Per-session namespace + worktree creation | Parallel sessions; agent collaboration via git |
| 4 | Path-aliasing for memory continuity | Auto-memory works inside sandboxed agents |
| 5 | Dolt user + branch-restricted beads | Agent task state tracked safely |
| 6 | Autosession daemon (coordinator + workers + reviewers) | The swarm, with human-in-the-loop for privileged actions |
| 7 | Privileged-action executor (mediator daemon) | Fully-autonomous swarms with bounded, audited privileged execution |

## Current Difficulties

- **OAuth credential placement.** The Anthropic auth lives in
  `~/.claude/.credentials.json` as a refresh token from a browser OAuth
  flow tied to a company subscription. The sandbox needs `HOME` set
  correctly for Claude Code to find it. The chosen design is for
  `claude-session` to do its own one-time OAuth flow, storing credentials
  in `/home/claude-session/.claude/`. This means the user's interactive
  Anthropic identity and the sandboxed sessions' identity are distinct
  by default.

- **Memory write continuity.** Sandboxed sessions need to write
  observations and auto-memory updates back to the canonical
  `~/.claude/projects/<hash>/` directory. The chosen mechanism is a
  bind-mount inside the namespace combined with ACLs on the host
  directory granting `claude-session` write access.

- **Agent observation provenance.** When agents write to the same
  memory directory the user's interactive sessions write to, agent
  observations mix with the user's. The proposed mitigation is a
  `memory/agent-observations/` subdirectory that the auto-memory
  `MEMORY.md` index doesn't auto-load.

- **claude-config can't yet self-host its sandbox.** Phase 1 has to be
  bootstrapped by an unsandboxed Claude session (paradoxically working
  on the sandbox itself). Once Phase 1 ships, all subsequent work can
  run sandboxed.

## Future Scope

Items beyond the immediate roadmap but worth designing toward, so
near-term decisions don't foreclose them.

- **Cross-platform installation paths.** The Linux + WSL2 implementation
  comes first because that's the development environment. Mac (with
  appropriate analogues to mount namespaces — likely sandbox-exec or a
  lighter-weight scheme) and Windows-native (potentially leveraging
  AppContainer or job-object isolation) are eventual targets. The
  intent is a tool that can be shared with coworkers and BOCO IT, not
  one that's locked to a single workstation. Phase boundaries should
  be drawn so the installer abstracts platform differences rather than
  hardcoding `/etc/sudoers.d/` etc. throughout the codebase.

- **Plugin architecture for workflow integrations.** The beads,
  claude-mem, and bd-timew couplings present in the current design are
  load-bearing for *this* user's workflow but would be friction for
  someone with a different stack. A plugin shape — workflow integrations
  declared via a manifest, loaded by the daemon at startup — would let
  the core sandbox + agent infrastructure be useful to others without
  bringing in beads as a hard dependency. Treat the current beads/Dolt
  integration as the reference implementation of one such plugin.

- **Generic AI agent framework potential.** With the plugin shape above,
  the autosession coordinator + worker model could become a reusable
  abstraction. Not pursuing this actively, but the namespace + worktree
  + git-as-collaboration-medium pattern is general enough that it would
  be worth designing API boundaries with future extraction in mind.

- **Reduced chezmoi role.** Once `claude-config` ships its installer
  (Makefile or install script), chezmoi's role contracts to a single
  bootstrap step: clone this repo and invoke the installer. Wrappers,
  scripts, profile configs, and deployed content all live in this repo
  and are emitted by its installer to canonical host locations
  (`/usr/local/bin/`, `/etc/sudoers.d/`, `~/.config/claude-sandbox/`,
  etc.). Chezmoi continues to manage other dotfiles; it just stops
  carrying Claude-specific content.

## Non-Goals

- **Hardening against a kernel-level adversary.** The threat model is
  prompt-injection attacks against an authenticated Claude Code session.
  An attacker with root on the host already has full access; the
  sandbox does not protect against that, and design choices that would
  raise the cost of operations for the legitimate user in pursuit of
  kernel-adversary resistance are out of scope.
