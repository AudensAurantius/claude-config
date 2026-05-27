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
- *Amended 2026-05-05 by DEC-006.* The "control filesystem visibility"
  language above is policy-direction-neutral. DEC-006 records the
  choice of allow-list (positive enumeration of bind mounts against
  an empty default) over deny-list (enumerate-and-shadow sensitive
  paths). Profile YAML schema accordingly contains no `shadow_tmpfs:`
  or equivalent deny-list keys.

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

---

### DEC-006: Sandbox visibility uses allow-list policy, not deny-list (2026-05-05)

**Decision:** Sandboxed sessions see a default-empty filesystem; profiles
bind in only the paths the session needs. The active profile's
visibility configuration is a positive enumeration of read-only and
read-write bind mounts against an empty default. There is no
"shadow-list of sensitive paths" to maintain — the entire host
filesystem (or at minimum the user's home + every system path not
explicitly required) is invisible by default, and only the profile's
explicit binds appear inside the namespace.

**Context:** Initial Phase 1 sketching implied a deny-list shape: a
list of credential directories (`~/.config/snowflake/`,
`~/.password-store/`, `~/.aws/`, `~/.ssh/`, etc.) shadow-mounted with
empty tmpfs while the rest of the home directory remained visible.
Drafting `sandbox/profiles/default.yaml` for ClaudeConfig-40s.4
surfaced the brittleness of that approach: new tools install new
credential paths constantly (`~/.cargo/credentials.toml`,
`~/.git-credentials`, `~/.local/share/keyrings/`,
`~/.terraform.d/credentials.tfrc.json`, the next tool installed
tomorrow). A miss in the deny-list is a permanent credential leak with
no detection mechanism. The same kernel mechanism (mount namespaces)
supports either policy direction; the choice of *which* default lives
in this decision.

**Alternatives:**

- *Enumerate-and-deny* (the original framing). Rejected: brittle,
  requires perpetual maintenance to keep current with new tools, and
  silent failures are credential leaks. The cost of a single miss
  exceeds the operational benefit of having a permissive default.
- *Switch to a container runtime (Docker, Podman, systemd-nspawn) for
  the whitelist property.* Containers offer this property natively
  because they construct a fresh root via `pivot_root` rather than
  inheriting the host's mount tree. Rejected for *this* workload: per-
  invocation startup overhead is noticeable for an interactive Claude
  wrapper; image-management complexity is high; host-tooling
  integration (`bd`, `bd-timew`, `claude-mem`, `chezmoi`, `pass`,
  `git`, `gh`, etc.) is heavy enough that the bind-mount enumeration
  problem just inverts (now we enumerate what to expose). The
  whitelist property is achievable inside the namespace architecture
  without the container-runtime tax.

**Consequences:**

- Profile YAML structure has no `shadow_tmpfs:` key. Profiles are an
  allow-list of `read_only:` and `read_write:` bind specs against an
  empty default. The Phase 2 schema design (ClaudeConfig-a92.1) takes
  this as a hard constraint.
- "List of sensitive paths to hide" disappears from documentation. It
  is replaced by "list of paths the active profile exposes."
- ClaudeConfig-40s.4 (default profile + ACLs) work was halted mid-
  draft 2026-05-05 because the YAML encoded the wrong default. Work
  resumes after ClaudeConfig-40s.7 (bubblewrap evaluation) lands; the
  YAML is rewritten with the allow-list policy regardless of which
  primitive we end up using.
- This decision is independent of the bubblewrap-vs-unshare choice
  (ClaudeConfig-40s.7 / future DEC-007). The allow-list policy is
  required either way; bubblewrap is one implementation that bakes
  it in natively, but a hand-rolled `unshare --mount` wrapper can
  achieve the same property by tmpfs'ing `/home/<user>` (and other
  inherited mount roots) up front and bind-mounting back what's
  permitted.
- DEC-001 is amended (below) with a cross-reference; DEC-002 is
  unaffected (it concerns Dolt branch auth, not filesystem
  visibility).

---

### DEC-007: bubblewrap as Phase 1 sandbox primitive (2026-05-05)

**Decision:** Phase 1 ships the `claude-sandbox` wrapper as a thin
shell over [bubblewrap](https://github.com/containers/bubblewrap)
(`bwrap`). The wrapper is rootless (no sudoers entry, no privileged
helper script) and uses bwrap's allow-list semantics to implement
DEC-006 directly. The previously-planned hand-rolled `unshare --mount`
+ `sudo -u claude-session` design is dropped.

**Context:** ClaudeConfig-40s.7 evaluated bwrap against the four
Phase 1 acceptance criteria and validated all of them (POC at
`.tasks/40s.7-bwrap-eval/poc-wrapper.sh`):

- `claude --version` and `claude -p "..."` both succeed inside the
  sandbox (OAuth round-trip works).
- 13 enumerated credential paths are structurally invisible without
  an explicit deny-list.
- Memory write-back to `~/.claude/projects/<hash>/` works through a
  read-write bind.
- `--clearenv` strips inherited credentials cleanly; explicit
  `--setenv` covers what the session needs (HOME, USER, PATH, TERM,
  LANG).

**Alternatives:**

- *Hand-rolled `unshare --mount` + sudoers + privileged helper.*
  Rejected: bwrap implements the same kernel mechanism with a much
  smaller wrapper surface and no privileged components. The unshare
  approach offered no capability bwrap doesn't already cover.
- *Container runtime (Docker, Podman, systemd-nspawn).* Rejected per
  DEC-006: per-invocation startup overhead, image management
  complexity, and host-tooling integration cost are wrong fits for
  wrapping every interactive Claude session.

**Consequences:**

- **Phase 1 components reduced.** ClaudeConfig-40s.2 (privileged
  setup + sudoers) and J121-ft3 (claude-session user provisioning)
  are deferred pending the user-model follow-up (see "Open follow-up"
  below); they may close permanently or re-emerge in a different
  shape. ClaudeConfig-40s.4 narrows to the profile YAML alone
  (ACLs deferred under the same follow-up).
- **WSL2 quirk to document.** `/etc/resolv.conf` is a symlink to
  `/mnt/wsl/resolv.conf` on WSL2 hosts; the wrapper must
  `--ro-bind /mnt/wsl /mnt/wsl` for DNS resolution. Linux-native
  hosts skip this. Cross-platform support (VISION future scope) needs
  to handle this conditionally — the POC has the pattern.
- **`bd` from inside the sandbox is out of scope until Phase 5.**
  Reaching the host's Dolt server requires `BEADS_DOLT_PASSWORD` in
  env, which is exactly DEC-001's anti-pattern. Phase 5's
  `bd-claude-session` Dolt user is the proper resolution.
- **Telemetry compliance gap.** Claude's OTEL exporter fails to reach
  its target inside the sandbox (`FailedToOpenSocket`,
  `ECONNREFUSED`). BOCO IT uses New Relic for developer-usage
  telemetry; running sandboxed sessions invisible to that telemetry
  is a compliance concern. See "Open follow-up" below.

**Open follow-up (each warrants its own bead and possibly its own DEC):**

1. *User-model decision.* Same-UID (POC default) is simplest but
   gives no UID-level audit trail or filesystem permission backstop.
   Two non-trivial alternatives: (A) provision a real `claude-session`
   user account at install, run bwrap with `--uid`/`--gid` mapping or
   via `sudo -u claude-session`; (B) configure `/etc/subuid` for the
   user's range and use bwrap user namespaces to map UIDs without a
   real account. (A) yields readable audit trails and clean OAuth
   identity continuity at the cost of one-time provisioning; (B) is
   rootless and lighter but has opaque high-range UIDs in logs. If
   (A) is adopted, ACLs for `~/.claude/projects/` re-enter Phase 1
   scope (per the original DEC-001 design), and J121-ft3 / 40s.2
   come back in modified forms.
2. *New Relic telemetry.* DEC-001 prohibits credentials in the
   sandbox; New Relic's OTEL endpoint requires a license key. The
   damage radius of a leaked telemetry-ingest key is small (fake
   telemetry, not data exfiltration), so a bounded exception or a
   host-side telemetry sidecar are both viable. Decision deferred
   pending IT alignment.

---

### DEC-008: Tiered credential policy for sandboxed sessions (2026-05-05)

**Decision:** Sandboxed sessions hold credentials drawn from three
tiers, with explicit eligibility criteria for the least-restrictive
tier and supersession of DEC-001's binary framing. Tier classification
governs *how* a credential reaches the sandbox; tier-1 credentials
require their own DECISION_LOG entry establishing eligibility.

**The three tiers:**

| Tier | Credential character | Mechanism | Examples |
|---|---|---|---|
| **1. Owned by `claude-session`** | Bounded damage radius; provisioned to the sandbox identity directly | Lives in `claude-session`'s home, bound naturally into the sandbox at session start | Anthropic OAuth (DEC-009); New Relic ingest key; readonly Jira service-account token |
| **2. Mediated via host sidecar** | Medium damage radius; the host process holds the credential and exposes a constrained interface to the sandbox | Unix socket bound into the sandbox; host daemon translates sandbox requests into authenticated API calls | (none yet — reserved for executor pattern; DEC-003 is the formalization) |
| **3. Recommend-and-execute** | High damage radius (production state mutation, broad-scope external auth, persistent infrastructure changes) | Agent generates a paste-ready command; human (or, eventually, DEC-003 executor) runs it | Snowflake JWT, ADO PAT, AWS keys, SSH keys, prod deploys |

**Tier-1 eligibility criteria.** A credential is eligible for tier 1
only if ALL four of the following hold:

1. **Bounded damage radius.** A leaked instance, used adversarially,
   produces consequences at worst recoverable nuisance: fake
   telemetry, wasted API spend, information disclosure scoped to
   data the sandbox legitimately needs to read anyway. No production
   data mutation. No persistent state changes requiring human cleanup.
2. **Separate provisioning from `hactar`.** The credential is issued
   to the `claude-session` principal at the upstream service — not
   borrowed from `hactar`'s account. An exception path exists for
   credentials that cannot be issued to a separate principal (see
   DEC-NNN escape-hatch), but tier-1 by default means "claude-session
   has its own."
3. **Documented in a DECISION_LOG entry.** Each tier-1 credential
   gets its own DEC entry recording: scope, damage-radius assessment,
   provisioning mechanism, rotation procedure. Adding a tier-1
   credential is a deliberate act logged in the decision history.
4. **Rotation procedure exists and is tested.** If the credential
   cannot be rotated cleanly when leaked, it does not belong in
   tier 1.

**Context:** DEC-001's original framing — "no credentials in the
sandbox" — was binary and didn't survive contact with reality. The
moment we said "Anthropic OAuth stays" we had a credential, in the
sandbox, doing privileged work; DEC-001 hand-waved the exception with
"it's the agent's identity, not a credential to spend on the user's
behalf." That's a real distinction but the binary wording obscured
it. The tiered policy makes the actual structure explicit: some
credentials must be in the sandbox (tier 1), some pass through a
mediator (tier 2), some never enter (tier 3). Each tier comes with a
defined mechanism and a defined damage budget.

The tiered model also re-anchors DEC-002 (branch-restricted Dolt
auth) cleanly — `bd-claude-session` is just another tier-1 credential
once that infrastructure ships.

**Alternatives:**

- *Keep DEC-001's binary framing; treat OAuth as "not a credential."*
  Rejected: the framing was already false, and pretending otherwise
  invites accidents the next time a "low-risk" credential is added
  outside the framework.
- *Single-tier "no credentials except OAuth" as a one-off exception.*
  Rejected: the New Relic telemetry conversation already produced a
  second exception candidate; we'd be back to ad-hoc framework gaps
  on the next ask.
- *Looser policy permitting any credential the user wants.* Rejected:
  the sandbox loses its central security property. The criteria
  above are the line that distinguishes "principled exception" from
  "drift."

**Consequences:**

- **DEC-001 superseded for credentials policy specifically.** DEC-001
  retains its core principle (the human is the final-mile authority
  for privileged operations against external systems) but the
  "agents do not hold credentials" line is replaced by the tiered
  scheme above. DEC-001's original alternatives-considered section
  remains historically accurate.
- **Each tier-1 credential addition costs a DEC entry.** This is
  deliberate friction. The cost is the policy's enforcement
  mechanism.
- **Tier-2 awaits Phase 7.** DEC-003's privileged-action executor is
  the reference implementation of tier-2; until it ships, no
  credentials are in tier 2. Telemetry sidecar (option 2 of DEC-007
  open follow-up #2) is a tier-2 candidate but currently slated for
  tier 1 instead per the New Relic damage-radius assessment.
- **Escape-hatch mechanism.** A separate DEC entry will record the
  user's-credentials-shared-with-claude-session escape hatch
  (`share-credential.sh` with chown + chmod 600 + optional GPG
  encryption-at-rest). Tier-1-by-shared-mechanism remains tier 1
  policy-wise; it just acknowledges that some credentials cannot be
  cleanly issued to a separate principal at the upstream service
  (e.g., personal Atlassian tokens before a service account is
  provisioned).

---

### DEC-009: Tier-1 credential — Anthropic OAuth for `claude-session` (2026-05-05)

**Decision:** `claude-session` holds its own Anthropic OAuth refresh
token, distinct from `hactar`'s personal identity, in
`/home/claude-session/.claude/.credentials.json`. The token is
provisioned via a one-time interactive browser OAuth flow on the
first sandboxed invocation after install.

**Tier-1 eligibility (per DEC-008):**

1. *Bounded damage radius.* A leaked refresh token spends Anthropic
   API credit on the BOCO subscription's `claude-session` identity.
   Cap: detectable via Anthropic billing dashboards, revocable via
   Anthropic console, no access to other systems or persistent
   state.
2. *Separate provisioning from hactar.* `claude-session` does its
   own browser OAuth flow at first run; `hactar`'s OAuth identity
   is unrelated.
3. *Documented in DECISION_LOG.* This entry.
4. *Rotation procedure.* Revoke `claude-session`'s OAuth in the
   Anthropic console; re-run the first-run OAuth ceremony. Tested
   pre-Phase-1-ship.

**Context:** The architecture transcript called out that `HOME`
placement decides which OAuth identity Claude Code uses
(`${HOME}/.claude/.credentials.json` is the lookup path). Under the
A2 user-model decision (DEC-007 follow-up + bead J121-ft3), the
sandbox's HOME points to `/home/claude-session`, so the OAuth
credential is naturally on a separate identity. This DEC records that
arrangement as the canonical tier-1 reference example.

**Alternatives:**

- *Bind `hactar`'s `~/.claude/.credentials.json` into the sandbox.*
  Rejected: shares the user's interactive Anthropic identity with
  the agent; muddies audit trails (Anthropic's logs can't tell
  hactar-as-human apart from hactar-as-agent), and rotating hactar's
  personal token would force re-authentication of every agent
  session.
- *Run sandboxed sessions without OAuth, generating recommendations
  for the human to execute.* Rejected: defeats the purpose of
  running Claude in the sandbox at all. The point is that Claude
  IS executing; the OAuth is its identity for that execution.

**Consequences:**

- The first-run experience requires the user to complete a browser
  OAuth flow inside the sandboxed session. Documented in the Phase 1
  smoke-test bead (ClaudeConfig-40s.6).
- The `claude-session` identity should be visible in BOCO's Anthropic
  account as a distinct seat or service-account-style entry, if the
  subscription model supports it. If not, it shows as another
  authenticated session under the same account; that's acceptable
  but worth noting for visibility.
- Token rotation requires the same first-run ceremony; not
  automated. Acceptable for now given expected rotation cadence
  (rare; only on suspected compromise).

---

### DEC-010: Escape-hatch mechanism for sharing user credentials with `claude-session` (2026-05-05)

**Decision:** When a tier-1-eligible credential cannot be cleanly
issued to a separate principal at the upstream service (e.g.,
Atlassian's user-bound API tokens before a service account exists),
the user-owned credential may be shared with `claude-session` via a
documented escape-hatch script: `sandbox/scripts/share-credential.sh`.
The default mechanism is a static copy with chown + chmod 600 +
optional GPG encryption-at-rest (option a). A bind-mount-with-ACL
mechanism (option b) is available as an explicit exception for
credentials that rotate externally and frequently. In all cases,
the shared credential is still tier-1 per DEC-008 and still requires
its own DEC entry recording the rationale, scope, and damage-radius
assessment.

**The two mechanisms:**

- **Option (a) — `share-credential.sh` (default):**

  ```bash
  sandbox/scripts/share-credential.sh \
      <hactar-source-path> \
      <claude-session-relative-target> \
      [--encrypt]
  ```

  Steps: copy `<source>` to `/home/claude-session/<target>`; chown
  to `claude-session:claude-session`; chmod 600; if `--encrypt`,
  GPG-encrypt to claude-session's public key and remove the
  plaintext copy.

  Audit attestation: `claude-session`'s GPG public key is signed by
  `hactar`'s personal key. The signature *is* the cryptographic
  record that hactar deliberately authorized claude-session to hold
  this credential.

- **Option (b) — bind-mount with ACL (exception):**

  Profile YAML accepts a `shared_credentials.bind_mounts:` field
  (empty by default). Entries are paths in `hactar`'s home that
  receive an ACL granting `claude-session` read access; the wrapper
  bind-mounts each into the sandbox at session start.

  Reserved for credentials that rotate frequently and externally
  (cloud SSO refresh tokens, `pass`-managed entries that change
  behind the scenes). Discouraged because principal separation at
  the filesystem level is fuzzy — claude-session reads hactar's
  inode via ACL, and audit at filesystem level shows two principals
  reading the same file.

**Friction is structural.** Per DEC-008, every tier-1 credential
addition requires its own DEC entry. The DEC entry for a
shared-mechanism credential must additionally justify *why* the
credential cannot be issued to a separate principal at the upstream
service (e.g., "Atlassian's API tokens are user-bound; service
account pursuit blocked on IT response — see ClaudeConfig-40s.10").

**Context:** The user-model decision (DEC-007 follow-up #1, A2 path)
gave `claude-session` its own UID and home directory, enabling
upstream-service provisioning of credentials directly to that
principal. But not every upstream service supports separate
principals (Atlassian being the prompt for this DEC). Without an
escape hatch, those services would either be unreachable from
sandboxed sessions or would force degenerate workarounds (binding
hactar's full home, defeating DEC-006). The escape hatch carves out
a narrow exception path with explicit policy.

**Alternatives:**

- *Option (b) as default; option (a) as exception.* Rejected: option
  (b)'s live-rotation property is nice for the few cases where it
  fits, but as a default it loses the principal-separation property
  that motivates the user-model decision. Audit at filesystem level
  becomes "claude-session reads hactar's file" which compromises
  the audit clarity argument from Q1.
- *Direct env-var injection.* Rejected: this is exactly DEC-001's
  anti-pattern. Even with damage-radius bounds (DEC-008), env-var
  injection makes the credential visible to any subprocess and to
  any tool that dumps env. The on-disk copy under
  `claude-session`'s home is more contained.
- *No escape hatch; force the user to wait for upstream
  service-account provisioning.* Rejected: the wait can be
  open-ended (BOCO IT timeline for service-account requests is
  weeks-to-months) and blocks legitimate sandbox functionality
  during the wait. The escape hatch with structural friction is a
  better tradeoff than blocking.

**Consequences:**

- Implementation lands in `sandbox/scripts/share-credential.sh`,
  tracked by ClaudeConfig-40s.11.
- Phase 2 profile YAML schema (ClaudeConfig-a92.1) must accept the
  `shared_credentials.bind_mounts:` field for option-b cases. Empty
  by default; populated entries trigger ACL setup at install.
- Each shared credential's DEC entry is structured per DEC-008's
  tier-1 requirements *plus* the shared-mechanism justification
  paragraph.
- Encryption-at-rest via GPG is optional. Real win: backup snapshots
  of `/home/claude-session/` don't leak plaintext credentials. Not
  a runtime defense — claude-session necessarily has the GPG private
  key in its keyring at session time.
- The GPG signing chain (claude-session's key signed by hactar's)
  is documented as a recommended setup but not enforced by the
  script. Lowering enforcement here matches the discouraged-but-
  possible character of the escape hatch as a whole.

---

### DEC-011: Compose with upstream `/sandbox` + `srt`; `claude-sandbox` becomes augmentation layer (2026-05-26)

**Decision:** Phase 1's `claude-sandbox` wrapper is reframed as an
**augmentation layer** over Claude Code's built-in `/sandbox` and the
open-source `@anthropic-ai/sandbox-runtime` (`srt`) rather than a
standalone replacement. The wrapper supports two execution modes,
both first-class:

- **Composed mode (default):** `sudo -u claude-session <env-scrub>
  srt claude` — outer wrapper does the host-side prep (identity
  switch, ACL staging, broker/proxy bring-up), inner srt does the
  bwrap layer.
- **Standalone mode (`--standalone`):** `sudo -u claude-session
  <env-scrub> bwrap <our-args> -- claude` — outer wrapper does the
  host-side prep *and* the bwrap layer directly, with no srt
  involvement.

Both modes share the host-side prep, identity layer (DEC-012), and
egress mediation (DEC-013). Only the bwrap-doer differs. Standalone
mode exists for three reasons: (a) educational — exercising bwrap
directly grows the operator's understanding of what the composed
mode delegates; (b) trust-fallback — srt is in public preview and
the operator may not yet trust it for production use; (c)
environments where srt is unavailable or rejected.

The bubblewrap primitive choice from DEC-007 stands: `/sandbox` and
srt use bwrap on Linux, so adopting them does not reverse that
decision. What is reversed is the implementation scope: claude-config
no longer reproduces app-layer Bash/network policy enforcement from
scratch in composed mode, and DOES reproduce a sufficient subset of
it in standalone mode (replicating srt's filesystem/network policy
from our profile YAML).

**Context:** The ClaudeConfig-40s.13 survey
(`.tasks/ClaudeConfig-40s.13-claude-code-sandboxing-survey/REPORT.md`
+ `FOLLOWUP.md`, both 2026-05-25) found that between DEC-007
(2026-05-05) and the survey date, Anthropic shipped `/sandbox` and
`srt`, which together implement a near-superset of Phase 1's planned
wrapper functionality on the same primitive.

Two non-trivial facts shaped the framing:

1. **Active security churn at the upstream sandbox boundary.** The
   Register (2026-05-20) reported two `/sandbox` bypass bugs
   disclosed within five months — CVE-2025-66479 (sandbox-runtime
   v0.0.16, Dec 2025) and an uncatalogued SOCKS5 hostname null-byte
   injection (sandbox-runtime v0.0.43 / Claude Code v2.1.90,
   2026-03-31). The May 2026 fix was parser-hardening defense-in-
   depth, not structural. Nine related concerning issues remain
   open in `anthropic-experimental/sandbox-runtime`, with one
   (#122) filed 12 hours before the survey concluded. Treating
   `/sandbox` as the sole boundary on credentialed infrastructure
   is not defensible right now.
2. **Permissive defaults plus app-layer enforcement.** `/sandbox`
   leaves `~/.aws/credentials`, `~/.ssh/`, and the entire home
   directory readable by default. Auto mode reads `.env` and sends
   matched credentials to their target APIs as documented behavior.
   App-layer enforcement is bypassable by Python subprocesses
   calling `open()` directly, by classifier mispredictions, and by
   parser bugs of the Register-disclosed class.

The augmentation framing keeps `claude-sandbox` providing the
kernel-enforced fallback (separate UID via DEC-012, ACL-policed
credentials, deterministic egress mediation via DEC-013) **on top
of** Anthropic's app-layer fence. Each layer defends against failure
modes the other doesn't: the kernel boundary catches app-layer
bypasses; the app-layer fence is the always-on default that catches
mundane mistakes the kernel layer's policy would also catch but
more expensively.

**Alternatives:**

- *Drop `claude-sandbox` entirely; rely on `/sandbox` + `srt` alone.*
  Rejected for the Register-disclosure reasons above. Also rejected
  for a structural reason: claude-config holds the security policy
  under a separate UID's filesystem ownership and ACL controls,
  which is independent of whether the Claude Code process is correct
  or compromised. That property cannot be reconstructed inside the
  application.
- *Keep `claude-sandbox` as a from-scratch standalone replacement
  (the prior Phase 1 scope).* Rejected: reproducing the network-
  policy engine and proxy correctly is a 12–18-month effort that
  we'd be doing in parallel with Anthropic's own security team.
  The augmentation framing extracts the unique-to-us value and
  lets the app-layer fence be Anthropic's problem.
- *Standalone-only (no srt integration ever).* Rejected: gives up
  the upstream policy work for no benefit. The trust-fallback role
  for standalone mode is real but doesn't justify rejecting
  composed mode as default.
- *Nest bwrap calls (outer claude-sandbox bwrap → inner srt bwrap).*
  Rejected as the standard pattern. Nesting works in principle
  (mount + user namespaces are nestable) but produces mount-conflict
  errors when policy layers disagree. Cleaner: outer wrapper does
  host-side prep without bwrap, inner srt does the only bwrap
  layer.

**Consequences:**

- **DEC-007 narrows in scope, does not supersede.** The bubblewrap
  choice and the four validated POC criteria still hold. What
  changes is which process invokes bwrap: directly via our wrapper
  in standalone mode, indirectly via srt in composed mode. The POC
  at `.tasks/40s.7-bwrap-eval/poc-wrapper.sh` becomes the reference
  implementation for standalone mode.
- **Two acceptance test paths.** Both composed and standalone modes
  need smoke tests. ClaudeConfig-40s.6 (manual smoke-test docs)
  expands accordingly.
- **Settings.json emission is a Phase 2 concern.** Phase 2 profile
  YAML (ClaudeConfig-a92.1) gains a settings.json emitter for
  composed mode; standalone mode consumes the same YAML directly
  via bwrap argument construction.
- **Upstream-tracking obligation.** `srt`'s config schema is beta-
  stable but additive; Anthropic publishes no formal break-change
  policy beyond a beta banner. A quarterly upstream-review bead
  modeled on ClaudeConfig-40s.13 keeps drift visible. If srt
  introduces a breaking change, standalone mode is the fallback
  during the catch-up window.
  - *Note (2026-05-26, ClaudeConfig-40s.15.1):* srt is **not** GA.
    The npm package `@anthropic-ai/sandbox-runtime` latest dist-tag is
    `0.0.52`; no `1.0.0` is published. The `srt` CLI's `--version`
    misreports `1.0.0` (hardcoded string out of sync with
    package.json) — do **not** read it as a GA signal. Version-gate on
    `npm view @anthropic-ai/sandbox-runtime version` or the installed
    `package.json`, never on `srt --version`. The beta-stability
    stance above therefore stands unchanged.
- **DEC-007 follow-up #2 (telemetry) is partially answered.** Hooks
  run on the host, outside the sandbox boundary. The OTEL Collector
  sidecar pattern (FOLLOWUP.md Q5) is the integration path; a
  separate Phase 1.5 bead implements it.

---

### DEC-012: Retain `claude-session` user as kernel-enforced isolation boundary (2026-05-26)

**Decision:** The dedicated `claude-session` user (provisioned by
`sandbox/scripts/provision-claude-session.sh`, shipped per J121-ft3)
is retained as Phase 1's identity layer. The wrapper invokes the
sandboxed Claude Code process as `claude-session` (via `sudo -u
claude-session`) regardless of whether `/sandbox` and `srt` are also
engaged. This closes DEC-007's open follow-up #1 in favor of option
A (real user account) and against the ClaudeConfig-40s.13 survey's
initial DROP recommendation.

**Context:** The ClaudeConfig-40s.13 survey initially recommended
dropping `claude-session` in favor of `srt`'s
`CLAUDE_CODE_SUBPROCESS_ENV_SCRUB` environment scrubbing. On review,
that recommendation conflated *environment isolation* (what env vars
the sandbox process can see) with *process-level isolation* (what
the sandbox process can do to other processes and inodes on the
host). Env-scrubbing addresses the first; only a separate UID
addresses the second.

What a separate `claude-session` UID buys that env-scrubbing alone
does not:

- **Kernel-enforced inter-process boundary.** Sandbox processes
  cannot ptrace `hactar`'s processes, cannot read
  `/proc/<hactar-pid>/environ`, cannot reach `hactar`'s SSH agent
  socket, cannot signal `hactar`'s shells.
- **Filesystem ownership clarity.** Anything Claude writes is owned
  by `claude-session`. Forensic separation is automatic; no log-
  parsing heuristics required.
- **Standard Unix auditing.** `journalctl _UID=<claude-session-uid>`
  filters all session activity for free. auditd rules target the
  UID directly. cgroups-per-user (via systemd user slices) gate
  resource accounting.
- **Defense against `/sandbox` bypasses.** When (not if, per the
  Register disclosure) the next sandbox bypass lands, the attacker
  is still confined to a separate UID's filesystem view with no
  write access to `hactar`'s home outside ACL-granted paths. The
  kernel boundary holds when the app-layer fence breaks.
- **Audit trail clarity in BOCO IT systems.** Telemetry routed
  through journald + OTEL Collector (per DEC-011 telemetry
  consequence) carries `claude-session`-tagged spans,
  distinguishable from interactive user activity at the BOCO IT
  level without per-process inspection.

The cost is the provisioning complexity — already paid. J121-ft3
closed 2026-05-17 with `provision-claude-session.sh` end-to-end
verified.

**Alternatives:**

- *Same-UID execution with env-scrubbing only.* Rejected for the
  reasons enumerated above. Env-scrubbing is part of the answer; it
  is not the whole answer.
- *Per-session UIDs (one disposable user per session) instead of a
  shared `claude-session`.* Rejected: blast-radius improvement is
  marginal (sandbox sessions are already short-lived) and the
  provisioning cost is substantial (creating users on session start
  violates the install-time-only principle).
- *DEC-007 follow-up #1 option B (subuid namespaces, rootless).*
  Rejected for the identity layer: opaque high-range UIDs in logs
  lose the human-readable identity property that the named user
  provides, and standard Unix tooling (auditd, journalctl, sudo,
  systemd) is named-user-shaped. The rootless property is nice but
  not load-bearing given that J121-ft3 is shipped. **However, see
  Phase 6 note below — subuid is the right mechanism for a
  different problem.**

**Consequences:**

- **DEC-007 follow-up #1 closed in favor of option A.** ACLs for
  `~/.claude/projects/` re-enter Phase 1 scope as planned (partially
  shipped via the provisioning script).
- **`provision-claude-session.sh` retained.** No deprecation; the
  script becomes part of standard install and gains documentation
  under `docs/SANDBOX_GUIDE.md`.
- **Invocation chain documented.** The canonical sandboxed
  invocation is `sudo -u claude-session srt claude` (composed mode)
  or `sudo -u claude-session bwrap ... -- claude` (standalone mode).
  Both compose with DEC-013's egress mediation.
- **Audit log destinations split sensibly.** Swarm-daemon-level
  events (session lifecycle) land in journald under `_UID=claude-
  session`. Per-session tool-call traces land in
  `/home/claude-session/.cache/claude-config/<session-id>/` (XDG-
  compliant, UID-owned, naturally aged out). A `PostToolUse` hook
  bridges between them via `systemd-cat`.
- **OAuth identity isolation flows naturally.**
  `HOME=/home/claude-session` means the Anthropic OAuth refresh
  token (DEC-009) lives separately from `hactar`'s OAuth identity.
  No code change needed.
- **The `claude-session` UID never gets sudoers grants.** The
  privileged-helper sudoers entry (`/etc/sudoers.d/claude-sandbox`)
  authorizes `hactar` to invoke the privileged setup as root —
  `claude-session` itself remains an unprivileged user with no
  sudo access.

**Phase 6 note — subuid is the right mechanism for a different
problem.** Rejecting subuid for the identity layer does not reject
it everywhere. The Phase 6 autosession daemon will spawn multiple
concurrent agent workers; if they all share `claude-session`'s UID,
they can see each other's processes and files. The natural answer
is to allocate each worker a slice of `claude-session`'s subuid
range (`/etc/subuid` entry for `claude-session`) and have the
daemon launch each worker in its own user namespace mapped to that
slice. This gives per-worker kernel isolation without per-worker
user provisioning. A Phase 6-design bead should capture this; the
decision belongs there, not here.

---

### DEC-013: Egress mediation via Unix-socket broker (credentialed) and SNI-inspecting proxy (uncredentialed) (2026-05-26)

**Decision:** All outbound traffic from sandboxed sessions transits
one of two host-side mediation layers, both running under a
dedicated `claude-egress` UID (separate from `claude-session`):

1. **Credentialed endpoints** (e.g., OpenAI, GitHub, Anthropic API,
   …): a **Unix-socket broker**. The sandbox calls a local Unix-
   domain socket (bound into the sandbox's mount namespace at a
   fixed path); the broker receives the request, attaches the
   appropriate credential according to destination policy, and
   makes the real upstream HTTPS call. The sandbox never speaks
   TLS to the real destination. Credentials never enter the
   sandbox.

2. **Uncredentialed but allowlisted endpoints** (e.g., npm
   registry, GitHub raw, package mirrors, docs sites): an **SNI-
   inspecting passthrough proxy**. The sandbox makes normal
   outbound HTTPS; the proxy reads the SNI from the ClientHello
   (plaintext), checks against the allowlist, and either splices
   the encrypted bytes through to the real destination or drops
   the connection. No TLS termination, no CA cert installed in the
   sandbox.

Both layers run under `claude-egress`'s UID, with policy files
owned by root and readable by `claude-egress` (0640) —
`claude-session` cannot tamper with policy or eavesdrop on broker
plaintext. This composes with — does not replace — DEC-008's
tiered credential policy and DEC-009/010's existing credential
mechanisms.

**Context:** Two findings from ClaudeConfig-40s.13 motivate this DEC:

1. **The Register disclosure (2026-05-20)** documented a SOCKS5
   hostname null-byte injection that defeated `/sandbox`'s wildcard
   allowlist for ~5.5 months across `claude-session`'s GA window.
   The fix was parser-hardening, not structural. The same
   architectural pattern — hostname-string-as-boundary in an app-
   layer filter — remains in place. More bypasses of this class are
   likely (nine related open issues, one filed within 12 hours of
   the survey).
2. **Auto mode reads `.env` and sends credentials to matching APIs
   by documented design.** Verified verbatim from
   `docs.claude.com/docs/en/permission-modes`. The auto-mode
   classifier's decisions are statistical and unauditable from
   outside Anthropic.

Deterministic egress mediation is the only defense robust against
both classes. The two-pattern split (broker for credentialed,
SNI-proxy for uncredentialed) reflects a real architectural
distinction: credential injection requires the proxy to "see
inside" the request, but SNI inspection achieves destination
control without that. Forcing all egress through a single MITM-
style proxy would buy unified architecture at the cost of CA-cert-
in-sandbox concerns (see Alternatives).

**How each pattern handles its threat model:**

- **Broker (credentialed):** Sandbox can never exfil the credential
  because the credential isn't in the sandbox. Domain fronting is
  irrelevant — the broker enforces destination by *credential*
  (this credential routes to this hostname only), not by URL parsed
  from the sandbox's request. Parser bypasses in `/sandbox` don't
  help an attacker reach an exfil destination, because the attacker
  would still need to convince the broker to attach the credential,
  and broker policy is hardcoded per credential.
- **SNI proxy (uncredentialed):** No credentials at stake. The
  defense is destination-control: the sandbox cannot reach
  `evil.com` even if its app-layer allowlist is bypassed, because
  the proxy enforces SNI against a static allowlist with no parser
  shenanigans. Client-lies-about-SNI is defeated by the proxy
  resolving SNI to IPs itself and only connecting to those. ECH
  (Encrypted Client Hello) will eventually obsolete this technique;
  sunset path documented in Open follow-up.

**Alternatives:**

- *Trust `/sandbox`'s network allowlist as the sole egress
  boundary.* Rejected for the disclosure history. Wildcard
  allowlist users had no boundary for 5.5 months. The architectural
  pattern that produced both bypasses (parser + hostname-string
  boundary) is unchanged.
- *Single full-MITM proxy (e.g., mitmproxy with CA cert installed
  in sandbox).* Rejected. The CA cert becomes a trust root inside
  the sandbox; if exfiltrated via any sandbox bypass, the attacker
  can MITM all future HTTPS the sandbox makes. The mitmproxy
  process additionally sees all sandbox HTTPS in plaintext and
  becomes a high-value target. Bypass surface includes anything in
  the sandbox that doesn't honor the system CA store (Go
  `crypto/tls` with pinned certs, Python with `verify=False`). The
  broker pattern subsumes the credential-injection use case
  without the CA-trust footprint; SNI inspection subsumes the
  destination-control use case without decryption. Both are smaller
  attack surfaces than full MITM.
- *Per-credential outbound firewall rules (nftables on the host).*
  Considered as complement. nftables can enforce destination IP/
  port for the `claude-egress` UID, but cannot inject credentials
  or inspect SNI. Useful as belt-and-suspenders below the proxy/
  broker — a rule like "claude-egress can only reach destinations
  $allowlist_ips" hardens against proxy-bypass attempts. To be
  added as a Phase 1.5 enhancement.
- *Network-namespace confinement of the sandbox* (force all egress
  through the proxy at the kernel level by giving the sandbox no
  default route). Considered, **deferred to Phase 1.5 open
  discussion** per the WSL2 caveat below.
- *Implement the SNI proxy in Bash or Python from scratch.*
  Rejected. Bash can't speak TLS preread cleanly. Python is
  workable but `asyncio` + raw TLS parsing carries enough sharp
  edges that a small Go program is materially safer.
- *Wait for Anthropic to ship structural egress controls.*
  Rejected: timeline is open-ended and the disclosed bypass class
  is exactly the architecture-pattern bug that's least likely to
  get a structural rewrite. We can't put credentialed infrastructure
  on someone else's security team's timeline.

**Consequences:**

- **New Phase 1.5 components:**
  - `sandbox/bin/claude-egress-broker` — Unix-socket broker for
    credentialed endpoints. Runs as `claude-egress`. Implementation
    language: Python or Go (broker logic is HTTP/JSON, not bytes-
    shuffling — language choice can be looser than for the proxy).
  - `sandbox/bin/claude-egress-proxy` — SNI-inspecting passthrough
    proxy for allowlisted uncredentialed endpoints. Runs as
    `claude-egress`. Implementation language: Go, ~300 LOC using
    `crypto/tls.ClientHelloInfo` + `io.Copy`. Recommended.
- **New `claude-egress` UID.** Provisioned by an extension to
  `provision-claude-session.sh` (or a sibling script). No sudoers
  entry. Owns the broker and proxy processes; reads policy files
  from `/etc/claude-config/egress-policy/` (root-owned, 0640,
  `claude-egress` group-readable).
- **Credentials live in `/etc/claude-config/credentials/`.** Root-
  owned, 0640, `claude-egress` group-readable. File-per-credential.
  The broker reads them at startup or on-demand; they never appear
  in `claude-session`'s view of the filesystem.
- **Phase 2 profile YAML gains two new fields:**
  - `egress.broker:` — map of credential-name → upstream
    destination, compiled into the broker's policy file at install
    / profile-switch time.
  - `egress.allowlist:` — list of SNI hostnames for the passthrough
    proxy.
- **`/sandbox` and `srt` allowlists become a secondary layer.** Set
  to the union of (broker destinations expressed as the broker's
  local socket) + (proxy allowlist) per active profile; the broker/
  proxy is the deterministic enforcer below.
- **Auto mode is prohibited in deployed profiles** as a belt-and-
  suspenders matter (FOLLOWUP.md Q2 recommendation). The broker
  makes auto mode operationally safe (credentials aren't in the
  sandbox to be read), but disabling it removes the entire `.env`-
  reading classifier surface from the design — cheaper than
  reasoning about edge cases.
- **`.env` files in worktrees are denied-read by default.** Even
  though the broker makes their contents non-load-bearing,
  `denyRead` on `**/.env` removes the classifier's input. Belt-and-
  suspenders pattern.
  - *Correction (2026-05-26, ClaudeConfig-40s.15.2):* this is
    **macOS-only as stated**. On Linux, `srt`'s `denyRead` is
    bubblewrap-based and matches **absolute paths / directory
    subtrees only — filename globs like `**/.env` do NOT match**
    (verified empirically; srt documents globs for macOS only). The
    `.env`-anywhere-in-worktree case is therefore **unsolvable via
    `denyRead` on Linux** — and `allowRead` directories can't have
    files denied within them (srt issue #193) — so on Linux the
    broker is not belt-and-suspenders for `.env`, it is the **sole**
    defense. More broadly: composed-mode read protection rests
    PRIMARILY on the DEC-012 UID boundary (claude-session cannot read
    hactar's `0750` home regardless of `srt`), with `srt` `denyRead`
    as narrow absolute-path defense-in-depth for claude-session's own
    home. The credential `denyRead` baseline is accordingly emitted as
    absolute `${SANDBOX_HOME}`-anchored paths, not globs.
- **Tier 3 credentials still require human execution.** The broker
  makes tier-1 and (the implementation of) tier-2 mechanically
  safe; tier-3 (production-mutation, broad-scope external auth)
  remains recommend-and-execute. The broker is a hardening of the
  safe tiers, not a license to broaden them.
- **The broker and proxy are new attack surfaces.** Each becomes a
  load-bearing security boundary. Implementations must be small,
  reviewed thoroughly, and given their own security-review beads.

**Open follow-up:**

1. **Network-namespace confinement of the sandbox** — would force
   all sandbox egress through the proxy/broker at the kernel level,
   leaving no possibility of direct TCP/UDP from the sandbox to
   anywhere except via the mediation layers. Defers to Phase 1.5
   discussion because WSL2 has a documented kernel bug affecting
   network namespaces (see
   `~/.local/src/wsl-vpn-namespace/docs/PITFALLS.md`): non-blocking
   sockets using `select`/`poll` after a bidirectional handshake
   hang inside a netns on the WSL2 kernel, affecting pyOpenSSL and
   ssh. Most sandbox tooling uses curl/openssl/stdlib-SSL backends
   which are unaffected, but some Python tooling does use
   pyOpenSSL and would break. Decision needs both: (a) survey of
   which sandbox-relevant tools use pyOpenSSL, (b) tracking of
   WSL2 kernel fixes for the underlying bug. Out of scope here.
2. **nftables belt-and-suspenders for `claude-egress`** — a rule
   restricting `claude-egress`'s outbound by destination IP, below
   the proxy/broker, defending against proxy-bypass attempts.
   Phase 1.5 enhancement.
3. **ECH sunset for SNI proxy** — when Encrypted Client Hello is
   widely deployed, the SNI proxy's inspection technique fails.
   Track ECH adoption; switch to a different mechanism (e.g.,
   DNS-based allowlist + nftables IP rules) when adoption crosses
   a threshold. Pre-emptive Phase 6 bead.

---

### DEC-014: `docs/research/` home for upstream-overlap surveys (2026-05-26)

**Decision:** A new top-level documentation subdirectory
`docs/research/` is established as the home for upstream-tooling
surveys and similar "what does ecosystem X already do for us"
investigations. Distinct in purpose from `docs/reviews/` (review
checkpoint summaries tied to completed features) and
`docs/transcripts/` (design discussions). Each survey lives as a
single Markdown file with citations, dated to its survey date.

**Context:** ClaudeConfig-40s.13 is the first such survey; it
won't be the last. Phase 2 profile design, Phase 5 Dolt branch-
restriction, and Phase 7 dispatcher all have similar upstream-
overlap questions that benefit from periodic re-survey as the
ecosystem evolves. The working artifact (full report) lives under
`.tasks/`; the condensed, citation-trimmed, source-controlled
version lives here.

**Consequences:**

- `docs/research/claude-code-sandboxing-survey.md` lands as the
  first entry, condensed from the ClaudeConfig-40s.13 task dir.
- A `docs/research/README.md` documents the purpose and naming
  convention (date-suffix optional; topic-slug primary).
- Per CLAUDE.md, new top-level directory documented here in the
  decision log. No further sub-DEC required for individual
  surveys.

---

### DEC-015: `docs/design/` home for pre-decisional architecture designs (2026-05-26)

**Decision:** A new documentation subdirectory `docs/design/` holds
internal architecture design documents for not-yet-built or
future-phase capabilities. These are **pre-decisional**: they lay out
options, trade-offs, and a recommendation, but the binding decision
lands in this decision log when the phase actually starts. Distinct
from `docs/research/` (DEC-014, upstream-overlap surveys),
`docs/reviews/` (completed-feature checkpoints), `docs/transcripts/`
(verbatim design discussions), and `docs/guides/` (operator how-to).

**Context:** ClaudeConfig-759 produced a Phase 6 worker-isolation
design (subuid user-namespaces vs. Firecracker microVMs) while the
context was fresh, well ahead of Phase 6 implementation. It is neither
a survey (DEC-014) nor a finished-feature review nor a verbatim
transcript — it is forward-looking internal design. Capturing such
analysis when the reasoning is fresh, in a source-controlled and
discoverable location, is worth a dedicated home. The `.tasks/`
working-artifact directory is git-ignored and so unsuitable for design
that must persist and inform a future phase.

**Alternatives:**

- *Put it in `docs/research/`.* Rejected: DEC-014 scoped that
  directory to upstream-overlap surveys ("what does ecosystem X
  already do for us"). Internal forward-looking design is a different
  artifact; conflating them muddies both.
- *Put it in the decision log directly as a DEC.* Rejected: a DEC
  records a *decision*, and these documents are explicitly
  pre-decisional. Forcing a premature DEC would either misrepresent
  the status or pollute the log with options-analysis that belongs in
  a design doc. The binding DEC comes later, at phase kickoff, and can
  cite the design doc.
- *Leave it in `.tasks/`.* Rejected: git-ignored, so neither durable
  nor shareable; design that informs a future phase must survive.

**Consequences:**

- `docs/design/phase6-worker-isolation.md` is the first entry, with a
  `docs/design/README.md` documenting the convention (status header:
  pre-decisional / superseded-by-DEC-NNN / implemented-in-DEC-NNN).
- Design docs cite the bead that produced them and the DECs they
  relate to; the eventual binding DEC cites back to the design doc.
- Per CLAUDE.md, this new documentation subdirectory is recorded here.
