# Decision Log

Significant design and architectural decisions, recorded with context for
future reference. Entries are append-only; if a decision is superseded, add
a new entry that references the prior one rather than rewriting history.

Format:

```
### DEC-NNN: Title (YYYY-MM-DD)
Decision: one-sentence statement.
Context: what problem this solves; what tradeoffs are being made.
Alternatives: what was considered; why rejected.
Consequences: what this implies; what it forecloses.
```

---

### DEC-001: Profiles manage visible context, not credentials (2026-05-04)

**Decision:** Sandbox profiles never inject credentials into the agent's
runtime. They control filesystem visibility, worktree creation, skill
subsets, and (eventually) network policy. For privileged operations
against external systems, the agent generates a recommendation and the
human (or, eventually, a privileged-action executor — see DEC-003)
executes.

**Context:** AI coding agents are an actively-targeted credential
exfiltration surface. The cost of credential sharing with an agent
exceeds the operational benefit even for trusted workflows. A successful
prompt-injection attack against any session with credentials present
walks away with full access to whatever those credentials unlock.

**Alternatives:**

- *Per-profile credential injection* (e.g., a `snowflake.yaml` profile
  exposes `~/.config/snowflake/keys/` and `SNOWFLAKE_PRIVATE_KEY`).
  Rejected: this is the exact pattern the disclosed exploits target; any
  perceived ergonomic benefit is dwarfed by the blast radius.
- *Credentials-but-with-deny-rules* (rely on Claude Code's deny rules to
  prevent exfil even with credentials present). Rejected: deny rules
  have already been bypassed in the wild (Adversa CVE on the
  50-subcommand bypass), and the cost of a single bypass is total
  compromise of the credential.

**Consequences:**

- Profile YAML schema has no `credentials:` or `env:` keys for secret
  injection. (Anthropic OAuth is structurally different — it's the
  agent's *identity*, not a credential to spend on the user's behalf
  — and stays.)
- `env -i` in the sandbox wrapper strips the environment totally, not
  selectively.
- Tasks requiring credentials produce recommendations the human runs.
  This is a deliberate friction point that scales: if the friction is
  high enough, it pushes credential-bearing operations toward
  formalization (scripts, CI pipelines, audited paths) instead of
  ad-hoc human-in-the-loop forever.
- A future "command-recommender" skill formalizes the recommendation
  format so agents produce paste-ready output reliably.

---

### DEC-002: Branch-restricted Dolt auth is a safety mechanism, not a privilege (2026-05-04)

**Decision:** Sandboxed agents may hold a Dolt-MySQL user account
(`bd-claude-session`) with SELECT on all branches and INSERT/UPDATE/DELETE
restricted to branches matching `claude/*`. This is permitted under
DEC-001 because the auth is structurally bounded and merge approval is
mandatory before changes affect canonical beads state.

**Context:** During architectural discussion an over-cautious reading of
DEC-001 ("agents have no credentials at all") was considered, which
would have ruled out bd write access. On reflection, this conflated
two distinct categories: external-system credentials (Snowflake JWT,
ADO PAT) whose damage radius is unbounded, vs. local-only auth scoped
to a structurally-reviewable subset of state.

**Alternatives:**

- *No bd write access at all; agents propose bead changes via files in
  the writable worktree.* Rejected: introduces unnecessary friction
  for a workflow whose entire purpose is inter-agent task tracking.
  Beads is already designed for the agent-collaboration use case.
- *Full bd write access on all branches.* Rejected: breaks the
  structural-review property and gives any compromised agent the
  ability to corrupt canonical task state.

**Consequences:**

- Beads becomes a code-review-style workflow for task state itself:
  agents propose on `claude/<session-id>` branches; coordinators or
  humans merge to `main`.
- The Dolt user model is itself a Phase 5 deliverable; until then,
  agents working on this repo coordinate via git branches and a
  manual handoff protocol.
- DEC-001's principle is refined: it concerns the *damage radius* of
  the credential, not its mere existence.

---

### DEC-003: (Phase 7+ placeholder) Privileged-action executor mediates between agent requests and host execution (2026-05-04)

**Decision (provisional, Phase 7+):** Fully-autonomous swarms gain a
dedicated executor daemon that accepts structured privileged-command
requests from worker agents, applies a policy-and-judgment layer
(reviewing for non-privileged alternatives, evaluating against scoped
capabilities), and either executes within its scope, suggests
alternatives, or escalates to the human with paste-ready instructions.

**Context:** Phases 1–6 rely on the human as the final-mile authority
for privileged operations. This is appropriate for interactive use and
for the first iteration of overnight autonomous swarms. To scale beyond
that — to let autonomous swarms run continuously without per-action
human approval — a structured intermediary is needed that holds
narrowly-scoped capabilities and exercises judgment about whether to
use them.

**Alternatives:**

- *No executor; humans always approve every privileged action.* Valid
  for Phases 1–6 but doesn't scale to long-running unattended swarms.
- *Worker agents hold their own scoped credentials per task.*
  Rejected by DEC-001: spreads credential-holding across many less-
  audited surfaces; expands the prompt-injection blast radius.

**Consequences (provisional):**

- Credential concentration at one auditable trust boundary instead of
  N worker agents.
- Structured request/response interface (Unix socket, JSON schema)
  with append-only audit log.
- The executor's own prompt-injection surface is minimized: it
  processes only constrained-schema requests, does not ingest
  free-form repo content or worker reasoning beyond the
  `justification` field.
- Capability-by-default-deny: new capabilities require explicit DEC
  entries and YAML manifest updates.
- This DEC will be replaced by a non-provisional version when Phase 7
  begins implementation, with the actual schema and capability-set
  decisions recorded.

---

### DEC-004: Installer-based deployment with non-destructive defaults (2026-05-04)

**Decision:** The repo ships an installer (Makefile and/or shell
script) that deploys to canonical host locations
(`/usr/local/bin/`, `/etc/sudoers.d/`, `~/.config/claude-sandbox/`,
`~/.claude/`). Deployment behavior varies by file class:

- *Marker-block managed* for files where claude-config owns part of
  the content (e.g., `~/.claude/CLAUDE.md`). The installer inserts or
  updates a delimited block; user content outside the block is
  preserved.
- *Three-way prompt* for files claude-config wants to replace but the
  user may have customized (e.g., `~/.claude/settings.json`). Default
  prompt: keep / replace / merge-in-editor; non-interactive flags
  (`--accept-defaults`, `--accept-existing`, `--non-interactive`)
  available.
- *Direct install* (no prompt) for files claude-config exclusively
  owns (`/usr/local/bin/claude-sandbox`, `/etc/sudoers.d/...`,
  `~/.config/claude-sandbox/profiles/*.yaml`).

Always: timestamped backup before any modification. Always: idempotent
re-runs. The installer also provides `make uninstall` that restores
backups in reverse order.

**Context:** chezmoi's role contracts to a single bootstrap step
("clone this repo and run `make install`"). The repo becomes self-
contained, which is a prerequisite for the cross-platform and
shareability goals in VISION.md. Non-destructive defaults respect
existing user customization and avoid surprise overwrites of valuable
content like the user's personal CLAUDE.md.

**Alternatives:**

- *Always-overwrite installer.* Rejected: overwriting `~/.claude/CLAUDE.md`
  loses substantial user content (workflow rules, tool preferences).
- *Symlink-based install (à la stow).* Rejected for files like
  CLAUDE.md where claude-config owns *part* of the content but not
  all of it; symlinks are all-or-nothing.
- *Fully interactive every install.* Rejected: friction for first-time
  setup and CI/automation cases.
- *dpkg-style `ucf` per-change diff/apply.* Considered; better UX than
  three-way prompts for users who want to review every byte. Deferred
  to a future polish phase rather than a Phase 1 requirement.

**Consequences:**

- Source paths in repo (under `claude/` and `sandbox/`) map to host
  destinations via the installer's deployment table; the table is the
  authoritative source for "where does this end up?".
- Deployment behavior for new files is decided per-file at the time
  it's added; the deployment-table entry encodes the choice.
- The CLAUDE.md marker-block content stays short — sandbox awareness
  + a pointer to `docs/SANDBOX_GUIDE.md` — so the canonical user-
  facing config remains user-controlled.

---

### DEC-005: Bead label clusters and infrastructure-priority elevation (2026-05-05)

**Decision:** Beads in this project carry one of four `scope:` labels —
`scope:infrastructure`, `scope:research`, `scope:review`,
`scope:skills` — categorizing the kind of concern the bead addresses.
Beads destined for migration to a future dedicated bd instance carry a
`migrate-to:<repo>` label. Phase-tagged work additionally carries
`area:phaseN` (1–7) labels matching the
[`docs/ROADMAP.md`](docs/ROADMAP.md) phase structure. Beads tagged
`scope:infrastructure` receive elevated priority (P1–P2) over beads in
other scopes (P3–P4) regardless of their position in the dependency
graph.

**Context:** The migration of beads from J121 to claude-config produced
a heterogeneous queue: sandbox infrastructure work, plugin evaluations,
audit tasks, and skills authoring all share the same priority space.
The existing `area:*` labels capture topic but not concern-category, so
`bd ready` surfaces unrelated work classes interleaved. A `scope:`
cluster gives `bd list --label=scope:<x>` and `bd ready --label=...`
queries that match how the work is actually organized in the project's
roadmap.

The infrastructure-priority elevation rule reflects that Phase 1+
deliverables are the project's reason for existing — skills and
research are valuable but secondary. Even when an infrastructure bead
is blocked by a non-infrastructure dependency, its priority remains
high so that when it unblocks, it surfaces above the rest. (`bd ready`
filters out blocked beads; priority orders the ready set.)

The `migrate-to:<repo>` label cluster is forward-leaning: bd-timew is
the first repo expected to receive its own bd instance, but the same
pattern fits future extractions (e.g., `migrate-to:bd-tasks` if dstask
integration grows into its own project).

**Alternatives:**

- *Use `area:` labels for concern-category.* Rejected: `area:` is already
  saturated with topic labels (`area:claude`, `area:beads`, `area:tooling`,
  `area:workflow`, etc.) and treating it as a category space conflates
  topic with concern. Topic and category are independent dimensions;
  separate label clusters keep them queryable independently.
- *Use `type:` labels.* Rejected: `type:` is a bd-native field
  (bug/feature/task/epic), not a free-form label space. Overloading it
  would break native filters.
- *Encode category in priority alone (P1 = infrastructure, P3 = research,
  etc.).* Rejected: priority is a single dimension and other meaningful
  variation (urgency, risk) wants the same axis. Separating "what kind
  of work" from "how urgent" preserves both.

**Consequences:**

- New beads in this project must carry exactly one `scope:` label.
  `bd lint`-style auditing (when implemented) should warn on missing
  scope labels.
- The infrastructure-priority elevation is a manual convention, not
  enforced by bd. New `scope:infrastructure` beads are created at P1–P2;
  others default to P3.
- `bd ready --label=scope:infrastructure` becomes the default first-pass
  query for "what to do next on the project's core deliverables."
- The `migrate-to:` label cluster supports later batch operations:
  `bd export --label=migrate-to:bd-timew` produces the migration set
  cleanly when the destination repo is ready.
