# Claude Code sandboxing primitives — upstream survey

**Survey date:** 2026-05-25 (follow-up 2026-05-26)
**Source bead:** ClaudeConfig-40s.13
**Working artifacts:**
[`.tasks/ClaudeConfig-40s.13-claude-code-sandboxing-survey/REPORT.md`](../../.tasks/ClaudeConfig-40s.13-claude-code-sandboxing-survey/REPORT.md)
+ [`FOLLOWUP.md`](../../.tasks/ClaudeConfig-40s.13-claude-code-sandboxing-survey/FOLLOWUP.md)
**Decision outputs:** DEC-011, DEC-012, DEC-013

## Headline

Between DEC-007 (2026-05-05) and the survey date, Anthropic shipped a
near-complete superset of claude-config's Phase 1 capability inside
Claude Code itself, on the same primitives. The work is **substantial
and high quality**, but **app-layer**, with **permissive defaults**
and a **documented pattern of silent bypass-class fixes**. The right
posture for claude-config is to **compose with upstream** as the
default execution path and **layer kernel-enforced fallbacks** (separate
UID, ACL-policed credentials, deterministic egress) on top — defending
against the bypass class that upstream's parser-hardening approach
doesn't structurally address.

## What Anthropic ships

Two complementary pieces, both shipped between DEC-007 and the survey:

- **`/sandbox`** (built into Claude Code v2.0.55+). Wraps Bash tool
  invocations in bubblewrap (Linux/WSL2) or Seatbelt (macOS).
  Configured via `~/.claude/settings.json` `sandbox` key. Anthropic-
  reported impact: ~84% reduction in permission prompts.
- **`@anthropic-ai/sandbox-runtime` (`srt`)**. Apache-2.0, public
  preview. Process-level wrapper invoked as `srt claude`. Stricter
  defaults (no writes / no network unless allowlisted). Wraps the
  entire Claude Code process — file tools, MCP, hooks — in the same
  bwrap/Seatbelt boundary.

Plus a substantial supporting cast:

- Mature permission system with allow/ask/deny rules, gitignore-style
  path semantics, MCP scoping, enterprise lockdown
  (`allowManagedPermissionRulesOnly`).
- ~25 hook events including blocking `PreToolUse` (can rewrite tool
  input), `ConfigChange`, `WorktreeCreate`, `SubagentStart/Stop`.
- `auto` permission mode with Anthropic-side classifier for tool-
  call approval (with a major caveat — see below).
- `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB` for stripping credentials from
  Bash subprocess environments.

## What's permissive by default

`/sandbox` and `srt` operating with default settings leave the
following readable:

- `~/.aws/credentials`
- `~/.ssh/` private keys
- `~/.docker/config.json`
- `~/.netrc`
- `~/.gnupg/`
- Project-local `.env` files
- The entire home directory (yes, all of it)

Closing the gap is the user's responsibility via `denyRead` rules.
The [upstream quickstart](../guides/quickstart-upstream.md) ships a
14-path baseline `denyRead` list.

## What auto mode does with `.env`

**Documented behavior, verified verbatim from
`docs.claude.com/docs/en/permission-modes`:** "Allowed by default:
Reading `.env` and sending credentials to their matching API."

In practice: if `.env` contains `OPENAI_API_KEY=sk-…`, auto mode
classifier may approve sending that key to an OpenAI-shaped
endpoint without prompting. The classifier sees user messages,
tool calls, and CLAUDE.md context — but **not** tool results. Its
decisions are statistical and unauditable from outside Anthropic.

Recommendation for credentialed environments: **prohibit auto mode**
and apply `denyRead` to `**/.env` for belt-and-suspenders.

## What's publicly known about sandbox bypasses

Two disclosures within five months. Both reported by Aonan Guan
(Wyze Labs cloud and AI security).

### CVE-2025-66479 (December 2025)

Bypass of the `/sandbox` network allowlist via parser-level
vulnerability in `@anthropic-ai/sandbox-runtime`. Patched in
sandbox-runtime v0.0.16. CVE assigned against the library, **not**
against Claude Code itself ("the root cause is in the library").
Fix is structural per the agent's repo inspection (commit
`bea2930`).

### SOCKS5 hostname null-byte injection (May 2026)

Bypass of `/sandbox`'s wildcard allowlist via null-byte injection in
SOCKS5 hostname handling. Disclosed publicly via The Register
(2026-05-20) after Anthropic patched it. Patched in sandbox-runtime
v0.0.43 (2026-03-28) and Claude Code v2.1.90 (2026-04-01) under
PR #187 (commit `fd74a3f`) — titled, misleadingly, "Add
upstream/parent HTTP proxy support."

**No CVE issued for Claude Code**; researcher's HackerOne report
was closed as duplicate of an internal Anthropic finding. The
window between sandbox GA and v2.1.90 was 5.5 months — users with
wildcard allowlists during this period had no network boundary;
the researcher recommends treating that window as "a potential
exfiltration event."

**The May 2026 fix is parser-hardening defense-in-depth, NOT
structural.** The hostname-string-as-boundary architecture remains
in place. The same class of bypass can recur.

### Researcher's quote

> "Shipping a sandbox with a hole is worse than not shipping one.
> The user with no sandbox knows they have no boundary. The user
> with a broken sandbox thinks they do."

### Active churn at the security boundary

Nine related concerning issues remain open in
`anthropic-experimental/sandbox-runtime`. One (#122, "Security:
config fallback silently disables filesystem read restrictions")
was filed 12 hours before this survey concluded.

## `srt` stability and GA

- Current version (as of survey): `0.0.52`, released 2026-05-19.
- Weekly release cadence since first publication on 2025-10-20.
- No published GA target. No formal break-change policy beyond the
  README beta banner.
- Schema additive-only across the v0.0.38 → v0.0.52 window observed.
- Operational guidance: **pin the version, re-verify on bump.**
  Plan for a 12-month-plus beta tail.

## Side-by-side: claude-config plan vs. upstream

| Capability | claude-config plan | `/sandbox` | `srt` | Verdict |
|---|---|---|---|---|
| Isolation primitive (Linux) | bubblewrap (DEC-007) | bubblewrap | bubblewrap | Identical |
| Scope of isolation | Whole Claude process | Bash tool only | Whole process | `srt` ≈ plan |
| Filesystem write allow-list | DEC-006 YAML | Same model | Same model | Overlap |
| Filesystem read defaults | Deny-by-default | **Entire fs readable** | Entire fs readable | **Gap — close with denyRead** |
| Network policy | Host firewall + DNS scope | SNI-allowlist proxy | Same | Overlap |
| Settings-file tamper protection | Marker block + ACLs | bwrap write-denial + `ConfigChange` hook | Same | Layered — combine both |
| Identity isolation | Separate `claude-session` user | `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB` | Same + whole-process | **Different — combine both (DEC-012)** |
| OAuth identity isolation | Separate HOME → separate refresh token | `CLAUDE_CODE_OAUTH_TOKEN` env var | Same | Refactor onto upstream mechanism |
| Per-project profile | YAML consumed by our wrapper | `settings.json` hierarchy | Same | Compose — emit `settings.json` from YAML |
| Per-session worktree | Phase 3 | `--worktree` flag + `WorktreeCreate` hook | Same | Overlap — build on theirs |
| Path-aliasing for memory continuity | Phase 4 | **Not addressed** | **Not addressed** | **Unique to claude-config** |
| Dolt branch-restricted auth | Phase 5 | Not addressed | Not addressed | **Unique** |
| Multi-process agent swarm | Phase 6 | Sub-agents in-process only | Same | **Unique** |
| Credential deny-list | Planned | **Not shipped** — user responsibility | Same | Compose — ship baseline in `settings/default.json` |
| Audit logging | Planned | Not built-in — via hooks | Same | Compose — write hook |
| Mid-session tamper protection | Marker + ACLs | `ConfigChange` hook | Same | Compose |
| Enterprise lockdown | Not scoped | `failIfUnavailable`, `allowManagedReadPathsOnly`, etc. | Same | Useful for future managed rollout |
| Telemetry routing (NR / OTEL) | DEC-007 plan | **Not addressed** | **Not addressed** | **Gap persists** |

## Decisions

- **DEC-011** — Compose with upstream; `claude-sandbox` becomes
  augmentation layer over `srt claude` (composed mode) with
  `--standalone bwrap` as first-class fallback.
- **DEC-012** — Retain `claude-session` user. Provides kernel-
  enforced inter-process boundary, filesystem ownership clarity,
  and standard Unix auditing that env-scrubbing alone cannot.
  subuid noted as the right mechanism for Phase 6 per-worker
  isolation (separate problem).
- **DEC-013** — Deterministic egress mediation via two patterns:
  Unix-socket broker for credentialed endpoints (credentials never
  enter the sandbox), SNI-inspecting passthrough proxy for
  allowlisted uncredentialed endpoints. Both run under a separate
  `claude-egress` UID with root-owned policy files. Closes the
  bypass class documented in the Register disclosure by enforcing
  destination-by-credential and destination-by-SNI deterministically
  below the app-layer allowlist.

## Methodology

- Two-stage subagent survey: comprehensive initial pass (REPORT.md,
  33KB), then focused follow-up on five open questions (FOLLOWUP.md,
  33KB).
- Primary sources: `docs.claude.com`, `docs.anthropic.com`,
  Anthropic engineering blog, the `anthropic-experimental/sandbox-
  runtime` GitHub repository (releases, issues, commits), NVD/MITRE
  for CVEs, The Register for the May 2026 disclosure.
- Local context: this project's `docs/VISION.md`, `DECISION_LOG.md`
  DEC-001 through DEC-010, the J121-ft3 provision script.
- All citations dated to access date (2026-05-25 for both passes).
- Working artifacts preserved under `.tasks/ClaudeConfig-40s.13-
  claude-code-sandboxing-survey/` for future verification.

## Key sources

- `/sandbox` reference: <https://docs.claude.com/en/docs/claude-code/sandboxing>
- Permission modes (auto-mode `.env` behavior): <https://docs.claude.com/en/docs/claude-code/permission-modes>
- Hooks: <https://docs.claude.com/en/docs/claude-code/hooks>
- `srt` repository: <https://github.com/anthropic-experimental/sandbox-runtime>
- Anthropic engineering — "Sandboxing in Claude Code": <https://www.anthropic.com/engineering/claude-code-sandboxing>
- The Register (2026-05-20): <https://www.theregister.com/security/2026/05/20/even-claude-agrees-hole-in-its-sandbox-was-real-and-dangerous/5243662>
- NVD entry for CVE-2025-66479: <https://nvd.nist.gov/vuln/detail/CVE-2025-66479>
