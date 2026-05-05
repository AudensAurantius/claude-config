# Auto-Memory Migration Plan — J121 → claude-config

One-shot plan for migrating relevant auto-memory entries from the J121
project memory directory to claude-config's. Delete this file once the
migration has been executed and verified.

## Scope: which "memory" this covers

There are three persistent stores in play. This plan covers only #1.
The other two are covered elsewhere:

1. **Auto-memory** — Markdown files under
   `~/.claude/projects/<hash>/memory/` with a `MEMORY.md` index. Manual
   curation. *This document.*
2. **bd memories** — `bd remember` / `bd memories` content stored in
   the project's Dolt database. Migrates alongside beads via `bd
   export` / `bd import`. See
   [`bead-migration-plan.md`](bead-migration-plan.md), section
   "Memory-specific filtering".
3. **claude-mem observations** — Hosted MCP corpus, keyed by project
   path. Not file-migrated; corpus rebuilds organically per project.
   Brief discussion at the bottom of this file.

## Source and destination

- **Source:** `~/.claude/projects/-home-hactar-Source-J121/memory/`
- **Destination:** `~/.claude/projects/-home-hactar-Source-claude-config/memory/`
  (created on first session in the new project, or seeded manually)

## Entries to migrate (definite)

These are claude-tooling entries that belong in claude-config's memory:

| File | Notes |
|---|---|
| `tooling-decisions-2026-04-15.md` | Beads + jira-cli + claude-mem evaluation decisions |
| `tooling-claude-mem-session-fix.md` | claude-mem 12.1.4 → 12.2.0 fix |
| `feedback-time-tracking.md` | Beads-as-billing-source-of-truth + bd-timew sidecar convention |
| `feedback-chezmoi-patterns.md` | Chezmoi pitfalls and patterns; cross-cutting but originates with claude tooling work |
| `reference-bd-capabilities.md` | bd capability matrix; reference doc, repo-agnostic |
| `reference-beads-label-taxonomy.md` | Option B prefix-namespaced label convention; repo-agnostic |
| `reference-chezmoi-zsh-plugin-framework.md` | YAML-driven zinit wrapper; tooling reference |
| `project-persistent-state-policy-2026-04-18.md` | Three-tier persistent state split; cross-cutting policy |
| `checkpoint-2026-04-18-tooling-integration.md` | Persistent-state policy shift; label taxonomy applied |
| `checkpoint-2026-04-19-timew-workflow-and-agents.md` | bd-timew bridge, Claude config + agents Chezmoi-managed |
| `checkpoint-2026-04-20-meta-tooling-wave2.md` | J121-9kp.2.6 closed (10-command CRUD family); metadata frontmatter convention |

## Entries to leave in J121

These are J121-project-specific and don't migrate:

| File | Reason |
|---|---|
| `feedback-jira-comment-style.md` | Jira-specific; ties to BOCO Atlassian instance |
| `feedback-jira-draft-frontmatter.md` | Jira-specific |
| `reference-azure-cli-cheatsheet.md` | J121 Azure cheatsheet |
| `reference-snowflake-share-grants.md` | Snowflake / J121-specific |
| `vpn-wsl2-setup.md` | BOCO VPN specific |
| `editor-and-shell-config.md` | Cross-cutting workstation config; could go either place. Leave in J121 for now (created there; J121 sessions reference it). |
| All `checkpoint-2026-03-*` and `checkpoint-2026-04-0[0-9]-*` files | J121 Snowflake, security, portal stabilization checkpoints |

## Entries to evaluate case-by-case

| File | Notes |
|---|---|
| `checkpoint-2026-04-17-tooling-integration.md` | Predates 04-18; check if superseded |
| `checkpoint-2026-03-05-workflow-review.md` | Dated; may be partially obsolete. Skim before deciding. |

## Migration mechanism

Auto-memory files are plain Markdown with YAML frontmatter. Each
migrating file:

1. `cp` from J121's memory dir to claude-config's memory dir.
2. Update the frontmatter `description:` field if it references J121
   specifically and the content is repo-agnostic.
3. Remove from J121's `MEMORY.md` index.
4. Add to claude-config's `MEMORY.md` index (create the index file
   if it doesn't exist yet).

The `MEMORY.md` index in each project is a curated one-line-per-entry
list, max ~150 chars per line, kept under 200 lines total. Format:
`- [Title](file.md) — one-line hook`.

## Cross-references to update

Some J121 docs cross-reference these memory files (`see
memory/reference-bd-capabilities.md` and similar). After moving the
files, these references break. Strategies:

- Leave a "stub" file in J121's memory with a one-line pointer:
  `Moved to claude-config; see ~/.claude/projects/-home-hactar-Source-claude-config/memory/<file>.md`.
- Update the J121 `MEMORY.md` index to remove the entries (so they
  don't appear at SessionStart).
- Update J121's `CLAUDE.md` to drop links to migrated entries.

The user's J121 `CLAUDE.md` currently references several of these
(e.g., `[reference-beads-label-taxonomy.md]`, `[bd capability matrix]`).
Audit and update those references.

## After migration

1. Open a session in `~/Source/claude-config/` and verify the
   migrated memory files appear in the SessionStart context.
2. Open a session in `~/Source/J121/` and verify the migrated
   files no longer appear (only the J121-specific ones remain).
3. Confirm no cross-references in J121 are broken (run a `grep` over
   `~/Source/J121/CLAUDE.md` and `~/Source/J121/docs/` for any
   reference to a migrated filename).
4. Delete this migration plan from the repo.

## Side question: claude-mem observation migration

claude-mem observations are stored in a hosted/MCP-backed corpus,
keyed by project path. They are not migrated as files; the
mechanism is different.

Two relevant facts:

1. **Search via `mem-search` skill or `query_corpus` MCP tool spans
   corpora** — searches return matching observations regardless of
   which project they were observed in. Migration is therefore not
   *required* for cross-project recall; you can search for "auto-
   session" or "bd-timew" from any project and find J121-originated
   observations.

2. **The new project corpus seeds itself organically.** As soon as
   you start working in `~/Source/claude-config/`, the claude-mem
   observer creates a new corpus for that project path and begins
   accumulating observations there. No manual intervention needed.

If you specifically want J121's claude-config-relevant observations
visible at SessionStart in the new project (rather than just
findable via search), the options are:

- **Re-prime an additional corpus.** Use the claude-mem MCP's
  `prime_corpus` against the new path, but this generates a fresh
  corpus from scratch — it doesn't *copy* J121's observations.
- **Manual cherry-pick to memory files.** For specific observations
  that are valuable enough to surface at SessionStart, distill them
  into a checkpoint-style memory file in the new project. This is
  what auto-memory checkpoints already do.

Recommendation: don't migrate observations as a bulk operation. The
distilled content (in the checkpoint and reference files migrated
above) already captures what's persistently valuable. The
observation corpus is a recency cache, not a historical record;
let it rebuild organically.
