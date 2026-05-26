# docs/design/

Internal architecture design documents for not-yet-built or future-phase
capabilities. **Pre-decisional**: these lay out options, trade-offs, and a
recommendation, but the binding decision lands in
[`DECISION_LOG.md`](../../DECISION_LOG.md) when the phase actually starts.

Distinct from sibling directories:

- [`docs/research/`](../research/) — upstream-tooling / ecosystem-overlap
  surveys ("what does X already do for us")
- [`docs/reviews/`](../reviews/) — review checkpoint summaries tied to
  completed features
- [`docs/transcripts/`](../transcripts/) — verbatim design discussions
- [`docs/guides/`](../guides/) — operator how-to

## Convention

- One file per design topic, named by capability slug.
- Lead with status (**pre-decisional** / **superseded by DEC-NNN** /
  **implemented in DEC-NNN**), the phase it targets, and the source bead.
- Present options and a recommendation; do not assert a final decision —
  that belongs in the decision log once the phase begins.

## Current designs

- [`phase6-worker-isolation.md`](phase6-worker-isolation.md) — per-worker
  isolation for the Phase 6 autosession swarm (subuid user-namespaces
  vs. Firecracker microVMs). Source: ClaudeConfig-759.
