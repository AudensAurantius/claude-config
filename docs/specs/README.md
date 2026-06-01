# docs/specs/

Forward-looking dev specs for not-yet-built or future-phase capabilities.
**Pre-decisional**: each spec lays out options, trade-offs, and a
recommendation; the binding decision lands in
[`DECISION_LOG.md`](../../DECISION_LOG.md) when the phase actually starts.

Distinct from sibling directories:

- [`docs/architecture/`](../architecture/) — *current* system design (how
  it works *now*), audience: anyone working in or against the codebase.
- [`docs/usage/`](../usage/) — problem statement, use cases, threat model
  (the *what* and *why*).
- [`docs/guides/`](../guides/) — operator how-to (install, run, recover).
- [`docs/research/`](../research/) — upstream-tooling / ecosystem-overlap
  surveys.
- [`docs/reviews/`](../reviews/) — checkpoint summaries tied to completed
  features.
- [`docs/transcripts/`](../transcripts/) — verbatim design discussions.

## Convention

- One file per spec topic, named by capability slug.
- Lead with status (**pre-decisional** / **superseded by DEC-NNN** /
  **implemented in DEC-NNN**), the phase it targets, and the source bead.
- Present options and a recommendation; do not assert a final decision —
  that belongs in the decision log once the phase begins.

## Current specs

- [`phase6-worker-isolation.md`](phase6-worker-isolation.md) — per-worker
  isolation for the Phase 6 autosession swarm (subuid user-namespaces
  vs. Firecracker microVMs). Source: ClaudeConfig-759.
