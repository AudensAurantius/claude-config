# Sandbox model

The conceptual frame for how `claude-sandbox` constrains a Claude
Code session. Audience: anyone designing, reviewing, or extending the
sandbox boundary.

For operational how-to (install, run, recover), see the sibling
[`docs/guides/`](../guides/) directory.

## Mental model

What the sandbox is: a process invoked under a separate Linux user
(`claude-session`, UID 999, DEC-012), running inside a bwrap mount
namespace populated by an allow-list profile (DEC-006), with a
stripped environment, and with the repo bind-mounted as the writable
worktree. What the sandbox *isn't*: a VM, a container, a defense
against host compromise.

The system's binding identity invariants:

- **Separate user** — claude-session, not the operator. ACL grants
  give it read+write access only to the worktree and the
  memory-write-back dir under the operator's home.
- **Mount namespace** — every path is allow-listed via the profile;
  paths outside the list are simply absent inside the sandbox.
- **Stripped environment** — `bwrap --clearenv` wipes everything;
  the profile's `environment.set` block injects only what the
  sandbox needs (HOME, USER, PATH, LANG, LUA_PATH, …).
- **Bind-mounted repo as writable worktree** — the operator's host
  repo is the only writable cross-user path; everything else
  inherits from claude-session's own home.
- **Profile-driven visible context** — the sandbox profile is the
  declarative source of truth for what's visible (and rw vs ro).

## Permission prompts vs OS-level sandboxing

Claude Code's per-tool permission prompts and `claude-sandbox`'s
bwrap-based isolation are two layers of the same defense — "limit
what Claude can do" — operating at different levels:

- **Prompts are application-layer checks.** Each tool invocation
  matches an allowlist or surfaces a blocking prompt. Cheap to add,
  but rely on the user being available to approve legitimate
  operations and on the prompt logic itself remaining unbypassable.
  Recent CVE history (50-subcommand bypass, settings-pre-trust
  bypass) shows the prompt model has had real holes.
- **The bwrap sandbox is OS-layer enforcement.** Filesystem
  visibility (DEC-006 allow-list), credential exposure (DEC-008
  tiered policy), and identity (DEC-009 separate `claude-session`
  OAuth) are bounded by the kernel and the namespace, regardless of
  what the agent tries to do. A prompt-bypass CVE doesn't compromise
  the sandbox boundary.

Once Phase 1 ships, **the bwrap sandbox subsumes most of what
per-tool prompts protect against.** Inside a sandboxed session, the
prompt model is largely redundant because the kernel enforces what
the prompt would have checked. Specifically:

- **Phase 6+ autosession daemons (workers, reviewers)** should run
  with `--dangerously-skip-permissions` *inside* the sandbox.
  Per-tool friction during autonomous execution defeats the purpose
  of an unattended swarm; the sandbox boundary remains the actual
  trust boundary, so prompt-skipping inside it is safe by
  construction.
- **Interactive sandboxed sessions** can also relax prompts (run
  with broader allowlists, or with `--dangerously-skip-permissions`
  for fully-trusted workflows) once the sandbox visibly bounds the
  blast radius. The user decides per profile.

Outside the sandbox (sessions invoked via `claude` directly,
bypassing `claude-sandbox`, or sessions running before Phase 1
ships), prompts remain the trust boundary and should be respected.

This composition principle is also why the spawn-agents pre-flight
convention matters less for sandboxed agents than for host-side
agents: a sandboxed worker that hits an unexpected `WebFetch` domain
isn't taking a host-level risk — the sandbox already constrains
what the response can do — so the convention's batch-approve-up-front
pattern can be relaxed there.

## Permission mode policy

Claude Code ships six permission modes (`default`, `acceptEdits`,
`plan`, `auto`, `dontAsk`, `bypassPermissions`). claude-config's
deployed profiles treat them asymmetrically — and the asymmetry is
deliberate, so it's worth stating plainly.

**`auto` mode is prohibited in deployed profiles.** Auto mode's
distinguishing feature is a server-side classifier that, by
documented default, *reads `.env` files and sends matched credentials
to their target API* and can autonomously set
`dangerouslyDisableSandbox: true` when a sandbox-caused failure is
hit (upstream issue #97). That credential-egress behavior is the
exact DEC-001 / DEC-008 anti-pattern. The lock-off is a
purpose-built managed-settings knob:

```json
// /etc/claude-code/managed-settings.json
{
  "permissions": {
    "disableAutoMode": "disable"
  }
}
```

Two further backstops make this robust: Claude Code already ignores
`defaultMode: "auto"` from project/local settings (a repo cannot
grant itself auto mode — only `~/.claude/settings.json` can set it),
and the `Read(**/.env)` deny rule shipped in the baseline settings
neutralizes the specific credential behavior even if auto mode were
somehow active. The docs themselves point at deny rules as the only
"hard guarantee" — conversational boundaries like "don't read .env"
are re-read from the transcript each check and lost on context
compaction.

Do **not** lock auto mode off by forcing `permissionMode: "default"`
in managed settings. That would also block `bypassPermissions` and
`dontAsk`, which we want available (see below). Use the surgical
`disableAutoMode` knob instead.

**`bypassPermissions` and `dontAsk` remain available inside the
sandbox.** Neither has auto mode's credential-classifier behavior;
they only change prompt handling. Inside the kernel sandbox the
boundary is enforced by the separate `claude-session` UID (DEC-012)
and the egress broker/proxy (DEC-013), not by prompts — so a
sandboxed worker running `--dangerously-skip-permissions`
(`bypassPermissions`) is safe by construction, and `dontAsk`
(pre-approved tools only) is ideal for fully unattended CI-style
runs. The managed-settings `disableAutoMode` lock is host-wide,
which is fine: we never want auto mode anywhere on this machine,
and we do **not** globally disable `bypassPermissions` because the
sandbox relies on it.

`autoMode.environment` is not a mitigation knob — it only *expands*
the classifier's trusted-infrastructure list. It cannot disable the
`.env`-credential behavior, so it plays no role in this policy.

## References

- [DEC-001, DEC-006, DEC-008, DEC-009, DEC-011, DEC-012, DEC-013](../../DECISION_LOG.md)
  — binding architectural decisions cited above.
- [VISION.md](../VISION.md) — project intent + roadmap framing.
- [`hooks.md`](hooks.md) — system-shipped hook plumbing layered on
  top of this model.
- [`audit-log.md`](audit-log.md) — per-session audit trail.
- [`docs/guides/oauth-bootstrap.md`](../guides/oauth-bootstrap.md) —
  the operational counterpart for first-time identity setup.
- [`transcripts/2026-05-04-sandbox-architecture-discussion.md`](../transcripts/2026-05-04-sandbox-architecture-discussion.md)
  — original design discussion.
