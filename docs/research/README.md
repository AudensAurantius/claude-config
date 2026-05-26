# docs/research/

Upstream-tooling surveys and ecosystem-overlap investigations. Each
file answers a question of the form "what does ecosystem X already
do for us, and how does that affect our plan?"

Distinct in purpose from sibling directories:

- [`docs/reviews/`](../reviews/) — review checkpoint summaries tied
  to completed features or roadmap items
- [`docs/transcripts/`](../transcripts/) — design discussion
  transcripts, preserved verbatim
- [`docs/guides/`](../guides/) — operator-focused how-to guides

## Convention

- One Markdown file per survey, named by topic slug (e.g.,
  `claude-code-sandboxing-survey.md`). Date suffix optional — use
  when surveys recur on the same topic.
- Each file leads with: **Survey date** (when the research was
  conducted), one-paragraph headline, and a methodology section
  listing sources consulted.
- Working artifacts (full reports, raw fetches, agent output) live
  under `.tasks/<bead-id>-<slug>/` — not here. This directory
  holds the condensed, citation-trimmed, source-controlled version.
- Cite primary sources with URLs and access dates.

## Current surveys

- [`claude-code-sandboxing-survey.md`](claude-code-sandboxing-survey.md)
  — 2026-05-25 survey of Anthropic's upstream Claude Code
  sandboxing primitives (`/sandbox`, `srt`) vs. claude-config's
  Phase 1 plan. Source for DEC-011, DEC-012, DEC-013.
