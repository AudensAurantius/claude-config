# docs/architecture/

How the claude-config system is designed **today**. Audience: anyone
working in or against the codebase — code reviewers, hook authors,
profile editors, future maintainers.

Distinct from sibling directories:

- [`docs/usage/`](../usage/) — *what* problems this solves, for whom.
- [`docs/guides/`](../guides/) — *how-to* (install, run, recover) for
  operators.
- [`docs/specs/`](../specs/) — forward-looking design specs for
  not-yet-built capabilities.

The system's binding architectural decisions live in
[`DECISION_LOG.md`](../../DECISION_LOG.md). These docs explain *how*
those decisions were realized in code; the DEC entries explain *why*.

## Current pages

- *(planned)* [`sandbox-model.md`](sandbox-model.md) — the two-mode
  (composed/standalone) sandbox model, permission layering, the
  `claude-session` identity boundary. Migrated from the legacy
  `SANDBOX_GUIDE.md` by bead ClaudeConfig-8so.
- *(planned)* [`identity-isolation.md`](identity-isolation.md) — DEC-012
  in prose: subuid mapping, ACL grants, what the boundary buys + does
  not buy.
- [`hooks.md`](hooks.md) — Lua PreToolUse/PostToolUse hook plumbing:
  `_lib.lua` shared utility, `_hooks-manifest.sh` single source of
  truth, the `assemble_claude_dir` mirror, deployment subtleties
  surfaced during 40s.18 + 40s.19.
- [`audit-log.md`](audit-log.md) — per-session JSONL + journald audit
  trail.
- *(planned, when DEC-013 lands)* `egress-mediation.md` — broker +
  SNI proxy.

## How these documents relate to DECs

A DEC entry is a binding decision with rationale. An architecture
page distills that decision (and any subsequent implementation
discoveries) into a reference a maintainer can consult without
re-reading the DEC log. When the page contradicts the DEC, the DEC
wins and the page is wrong — file a bead.
