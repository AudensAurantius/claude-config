# Agent conventions

How an agent running inside a claude-config session should structure
its interactions — both with the operator and with the system itself.

Audience: agent authors, skill authors, anyone defining
agent-orchestration patterns.

## The recommend-and-execute pattern

*Stub — to be written.* How agents should format privileged-command
recommendations so the human can paste-and-run them safely.
Conventions for:

- Environment prefixes (when to render `KEY=value …` vs leave bare).
- What to echo before executing (cwd hint, command preview, expected
  outcome).
- Never including secrets in the recommendation output (deny rules
  catch one case; agent discipline covers the rest).
- When to use this pattern vs invoking via the agent's own tool
  call (decision tree: side effect across identity boundaries → use
  the pattern; pure-Claude side effect → use the tool).

## References

- [`oauth-bootstrap.md`](oauth-bootstrap.md) — the canonical example
  of recommend-and-execute (the operator runs `claude-sandbox
  --oauth` themselves; the agent doesn't and can't).
- [`docs/architecture/sandbox-model.md`](../architecture/sandbox-model.md)
  — the trust-boundary framing this pattern operates against.
