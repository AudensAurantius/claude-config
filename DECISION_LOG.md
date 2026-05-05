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
