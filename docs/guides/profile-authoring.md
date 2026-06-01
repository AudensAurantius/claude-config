# Profile authoring

How to write, test, and ship a sandbox profile.

Audience: anyone defining a new profile or modifying the default.

## What a profile is

A YAML file under `~/.config/claude-sandbox/profiles/` (deployed by
`just install` from `sandbox/profiles/`) declaring what's visible to
a sandboxed session: read-only binds, writable binds, network
policy, environment variables to inject. See the schema in
[`sandbox/profiles/default.yaml`](../../sandbox/profiles/default.yaml)
— the comments in that file are currently the canonical reference;
Phase 2 (ClaudeConfig-a92.1) formalizes the schema with Cue
validation per DEC-024.

## To be written

*Stub.* Pending content:

- Field-by-field schema reference (extracted from `default.yaml`
  comments + DEC-024 schema once a92.1 lands).
- How to test a new profile against a throwaway prefix
  (`CLAUDE_SANDBOX_PROFILE_DIR=… just install-test …`).
- How to share profiles across machines (commit to repo, redeploy
  via `just install`).
- Profile-vs-environment-vars trade-offs (when to set things in
  profile `environment.set` vs the wrapper's `SCRUB_ENV`; see
  [hooks.md "Deployment subtlety 3"](../architecture/hooks.md) for
  the LUA_PATH cautionary tale).

## References

- [DEC-001](../../DECISION_LOG.md) — profiles never inject
  credentials beyond the tier-1 set claude-session owns at the
  upstream service.
- [DEC-006](../../DECISION_LOG.md) — allow-list visibility model.
- [DEC-024](../../DECISION_LOG.md) — Cue schema/validation layer
  (planned; sidecar feature lands it first, profiles inherit).
- ClaudeConfig-a92.1 — profile schema formalization (Phase 2).
