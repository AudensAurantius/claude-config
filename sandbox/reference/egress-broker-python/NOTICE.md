# Frozen Python reference broker

This directory contains the original Python reference implementation of
the egress credential broker (ClaudeConfig-ciw.2 slices 2-5). It is
preserved read-only for archaeological reference and as a wire-protocol
parity oracle.

The production broker is the Go implementation under
`sandbox/broker/`, installed at `/usr/local/sbin/claude-egress-broker`
and run by the systemd units under `sandbox/systemd/`. The two
implementations share:

- the same wire protocol (`internal/wire` ↔ `egress_broker/wire.py`)
- the same policy schema (`sandbox/egress-policy/README.md`)
- the same SO_PEERCRED auth gate
- the same `pass(1)` credential backend layout

## Freeze record

- **Frozen at**: 2026-06-02
- **Last live commit (slice 5 merge)**: `b77c8c5` and its ancestors
- **Slice 6 commit that froze this**: see git log for the commit that
  moved `src/claude_config/egress_broker/` → here
- **Original location**: `src/claude_config/egress_broker/` (in the
  Python package tree) and `tests/egress_broker/`

## Coverage status post-freeze

- **Not** in `[tool.ruff]` / `[tool.mypy]` `src=` paths anymore — the
  package is no longer pip-installable; it is read-only reference text.
- **Not** in `pytest`'s `testpaths` — the parity oracle role moved to
  the Go test suite under `sandbox/broker/internal/*/`.
- The `claude-egress-broker-py` console-script entry point was removed
  from `pyproject.toml`.

## Running the reference (operator escape hatch)

If you need to compare behavior against the original Python broker:

```bash
cd sandbox/reference/egress-broker-python
PYTHONPATH=. python -m egress_broker \
    --policy-dir /etc/claude-config/egress-policy \
    --peer-uid "$(id -u claude-session)" \
    --socket /tmp/python-broker.sock
```

The Python reference uses `Type=simple` (no sd_notify) — operators who
swap it under systemd must drop in `Type=simple` via
`systemctl edit claude-egress-broker.service`.

## Why preserve at all

The reference exists because the wire protocol and policy schema were
designed in Python (DEC-029); preserving the implementation makes it
easy to audit the Go port for divergence and to recover the design
rationale if the Go code grows beyond the original spec.

If the Go broker diverges substantively from this reference in a way
that breaks parity, that is a DECISION_LOG-worthy event — record it
and update or retire this directory accordingly.
