# Bead Migration Plan — J121 → claude-config

One-shot plan for porting relevant J121 beads into the new claude-config
instance. Delete this file once migration is complete and the originals
are closed in J121.

## Beads to migrate

Snapshot taken 2026-05-04. Ranked by relevance to claude-config's scope.

### High-relevance (definite migrate)

These beads are pure claude-tooling and have no J121-specific context to
preserve.

| J121 ID | Title | Status | Notes |
|---|---|---|---|
| J121-9kp | Codify workflow into Claude skills + slash commands | in_progress | Parent epic |
| J121-9kp.2 | Wave 2: Productivity — conversational commands, capture/meta-tooling, Chezmoi | in_progress | |
| J121-9kp.2.1 | /envrc slash command | open | |
| J121-9kp.2.3 | Session lifecycle commands (/session-push + /session-end + /sync-all-repos) | open | |
| J121-9kp.2.4 | Conversational slash commands: /recommend, /discuss, /docs, /summarize | open | |
| J121-9kp.2.5 | Capture family + /log multiplexer | open | |
| J121-9kp.2.8 | /break + /resume-task slash commands | open | |
| J121-9kp.2.10 | /spool slash command — session transcript export | open | |
| J121-9kp.2.11 | Chezmoi skill + /chezmoi-add etc. | open | |
| J121-9kp.2.16 | /audit family — behavioral audit for skills/agents/commands | open | |
| J121-9kp.2.17 | [epic] /auto-session skill: session-scoped autonomous coordinator | open | Critical for Phase 6 |
| J121-9kp.2.17.1 | Ship /auto-session skill (final deploy + chezmoi-manage) | open | |
| J121-9kp.2.17.2 | [epic] Auto-session pre-ship cherry-picks (Tier-2) | open | |
| J121-9kp.2.17.2.1 | Upgrade exit-summary template with claude-handoff 12-item checklist | open | |
| J121-9kp.2.17.2.2 | Add PreCompact nudge and completion-report checklist | open | |
| J121-9kp.2.17.3 | Auto-session: Dolt-branch beads sandbox (Tier 1 — permission-based) | open | Now Phase 5 here |
| J121-9kp.2.17.4 | Auto-session: Dolt-clone beads sandbox (Tier 3) | deferred | |
| J121-9kp.3 | Wave 3: Scaffolding — mode-switching, project-init, TDD, project-docs | open | |
| J121-9kp.3.1 | Mode-switching: cwd-inferred + /mode override | open | |
| J121-9kp.3.2 | /timebox slash command | open | |
| J121-9kp.3.3 | test-driven-development cherry-pick from Superpowers | open | |
| J121-9kp.3.4 | /project-init python — full Python project scaffolding | open | |
| J121-9kp.4 | Audit boco-ai-skills + BOCO Claude plugins marketplace | open | |
| J121-9kp.5 | memory-hygiene skill — routing rules for stores | open | |
| J121-9kp.6 | Urgent-item monitor: email + calendar polling | open | Borderline; keep in J121 if BOCO-specific, move if generic |
| J121-9kp.6.1 | Urgency classifier: Anthropic API prompt | open | |
| J121-9kp.6.2 | Multi-source poller: MS Graph cron-scheduled | open | BOCO-specific (Graph API) |
| J121-9kp.6.3 | SessionStart hook: urgent-items briefing | open | |
| J121-9kp.7 | /import-session command | open | |
| J121-9kp.9 | Canonical bd formula exemplars | open | |
| J121-9kp.9.1 | bd formula for plugin-doc + worker-doc workflows | open | |
| J121-9kp.9.3 | bd formula for incident / postmortem playbook | open | |
| J121-1ov | Evaluate thrum PreCompact/PostCompact context-snapshot mechanism | open | |
| J121-dkc | Revisit workflow directive conflicts across Claude config sources | open | |
| J121-1aj | Evaluate process_triage for adoption | open | |
| J121-2ou | Evaluate flow-next plugin (incl. Ralph pattern) | open | |
| J121-6o9 | Evaluate mcp_agent_mail for adoption | open | |
| J121-crk | Evaluate meta_skill for adoption | open | |
| J121-pb7 | Install flow-next plugin | open | |
| J121-658 | Install and configure destructive_command_guard (dcg) via Chezmoi | open | |
| J121-y0i | Audit and add allowed-tools declarations to all slash commands | open | |
| J121-csw | /next integration: peek bd-timew queue before scoring | in_progress | |
| J121-1dn | /queue slash command: thin wrapper over bd-timew queue | open | |
| J121-6gw | /triage slash command — project-state briefing | open | |
| J121-014 | Slash-command family for personal capture + retrieval tools | (epic) | |
| J121-014.1 | (parent of capture family) | open | |
| J121-014.1.1 | /todo: dstask wrapper for one-off cross-project TODOs | open | |
| J121-014.1.2 | /note: agent-mediated dispatch | open | |
| J121-014.1.3 | /bookmark + /bookmark-note | open | |
| J121-014.1.4 | /snip + /snip-from-context | open | |
| J121-014.1.5 | /find-notes + /find-todos | open | |
| J121-ft3 | claude-sandbox: install-from-scratch provisioning script | open | Created during this very discussion; rename and re-anchor here |
| J121-119 | Validate Beads workflow after 2 weeks | deferred | |
| J121-0ci | Validate claude-mem observation quality after 2 weeks | open | |

### Plugin-candidate (migrate; tag for future plugin extraction)

These were initially classified as J121-leave-in-place but on review
fit the plugin-candidate pattern from VISION.md's Future Scope. They
should migrate now and carry an `area:plugin-candidate` label
indicating they are likely-extractable workflow integrations rather
than core sandbox infrastructure.

| J121 ID | Title | Status | Plugin candidate notes |
|---|---|---|---|
| J121-9kp.6 | Urgent-item monitor: email + calendar polling | open | Workflow-integration plugin: SessionStart briefing pattern; MS Graph is reference impl, but the pattern (poller + urgency classifier + briefing) generalizes |
| J121-9kp.6.1 | Urgency classifier: Anthropic API prompt | open | Plugin component |
| J121-9kp.6.2 | Multi-source poller: MS Graph cron-scheduled | open | Plugin component; BOCO-specific source, but the source connector is the abstraction point |
| J121-9kp.6.3 | SessionStart hook: urgent-items briefing | open | Plugin component |
| J121-32y | bd-tasks: dstask integration wrapper | open | bd-timew / time-tracking plugin candidate |
| J121-gc0 | bd-tasks: include bead summary in dstask-notify toast | open | Same plugin |
| J121-1b1 | beads-reconcile: materialize inherited billing labels | open | Same plugin (bd-timew billing-label propagation) |

After migration, label these with `area:plugin-candidate` plus their
specific area (`area:autosession`, `area:bd-timew`, etc.) to make the
plugin extraction set easy to query: `bd list
--label=area:plugin-candidate`.

### Low-relevance / leave in J121

These are J121-specific operational tasks. Leave them in J121's bd
instance:

- `J121-9kp.3.5` — Project-docs skill + /dashboard-update is explicitly
  J121-local.
- `J121-bc5` — Terraform/schemachange config unification; J121-specific.

## Migration mechanism

`bd export` produces JSONL (newline-delimited JSON), one issue per
line, with labels, dependencies, and comments included. **It also
includes memories from `bd remember` by default** (use
`--no-memories` to exclude) — so the same export/import flow handles
both beads and the project-technical memory store.

The flow:

```bash
# In J121: export the relevant subset to a file
cd ~/Source/J121
bd export -o /tmp/j121-claude-export.jsonl
# (Optional: filter to relevant beads only; see `bd export --help`
# for current filter flags. If filtering proves brittle, export
# everything and let the import on the destination side accept
# only the IDs in our migration table.)
```

Then in claude-config:

```bash
cd ~/Source/claude-config
bd import < /tmp/j121-claude-export.jsonl
# (Or with explicit allow-list of IDs from the migration table,
# depending on what `bd import` supports. Check `bd import --help`.)
```

Things to verify after import:

- **ID changes.** Beads regenerates IDs on import; new IDs will not
  match `J121-9kp.*`. The hierarchy (parent-child relationships)
  needs to be preserved by importing parents before children, or by
  re-establishing via `bd update --parent` after. Test with one parent
  and one child before doing the bulk migration.
- **Labels carry over.** Verify `area:claude` etc. survive the
  round-trip.
- **Status carries over.** `in_progress` items remain `in_progress`.
- **Comments and notes carry over.** These hold significant context
  and must not be lost.
- **Memories carry over.** Run `bd memories` in claude-config and
  confirm the relevant project-technical facts are present. Drop
  any J121-specific memories that came along for the ride
  (Snowflake, ADO, Jira specifics) — those should remain in J121's
  instance only.

If `bd export`/`bd import` doesn't round-trip cleanly for some
record class (e.g., parent-child links break), fallback is manual
recreation using `bd create` with the original title / description /
labels / status, taking values from `bd show <original-id>` in J121.

### Memory-specific filtering

Because `bd export` mixes beads and memories in one stream, expect to
do some post-import housekeeping:

```bash
# In claude-config after import:
bd memories                                 # list all migrated memories
bd memories <keyword>                       # search for a specific topic

# Forget memories that don't belong here:
bd forget <memory-id>                       # for J121-specific items
```

Audit candidates (likely belong in claude-config):

- bd-timew design notes
- claude-mem fix history
- Workflow / persistent-state policy
- bd capability matrix
- Beads label taxonomy

Audit candidates (likely stay in J121 — re-add them there if the
migration accidentally removes them):

- Snowflake share-grant model
- Jira ADF reference patterns
- Azure CLI cheatsheet seeds
- Portal stabilization checkpoints

If both projects need the same memory, it's fine to have it in both
beads instances — they're separate stores; no global uniqueness
constraint.

## After migration

1. Verify each migrated bead by spot-checking ~5 randomly:
   `bd show <new-id>` should match `bd show <old-id>` (in J121) on
   title, description, labels, status, parent.
2. Close each migrated J121 bead with a closing reason:
   `bd close <old-id> --reason="Migrated to claude-config (new id <X>)"`
3. Close `J121-ft3` last, with a closing reason referencing the
   claude-config bead that supersedes it.
4. Delete this migration plan from the repo.

## Open questions to resolve before executing

- Does `bd export` preserve parent-child hierarchy in a single
  invocation, or does it require manual re-linking? Test with
  `J121-9kp.2.17` and a child before doing the bulk migration.
- Does claude-mem observation cross-referencing (the inline IDs like
  `2219`, `S448`) need to be updated after migration? These are
  observation IDs, not bead IDs, so probably not — but verify.
