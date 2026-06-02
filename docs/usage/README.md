# docs/usage/

What problems claude-config solves, for whom, under what assumptions.

Audience: someone trying to decide whether claude-config fits their
workflow, or to understand the threat boundary the system commits to
defending.

Distinct from sibling directories:

- [`docs/architecture/`](../architecture/) — *how* the system is
  designed.
- [`docs/guides/`](../guides/) — *how-to* (install, run, recover).
- [`docs/specs/`](../specs/) — forward-looking design specs.

## Planned pages

- `problem-statement.md` — what makes running Claude Code under an
  arbitrary user identity risky enough to warrant this much
  scaffolding.
- `use-cases.md` — the concrete workflows this is meant to support
  (interactive development, multi-agent coordination, audit-required
  environments).
- `threat-model.md` — explicit threat actors, what the system
  protects against, and what it *doesn't* (no defense against host
  compromise; SNI proxy is sniff-not-decrypt; etc.).

Files are stubs until written. Filing as separate beads when scoped.
