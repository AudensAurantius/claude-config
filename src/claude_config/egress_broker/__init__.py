"""Claude egress broker — Python reference implementation.

Per DEC-013 and DEC-029. This package is the active reference broker:
mediates outbound HTTPS for sandboxed claude-session processes, attaching
credentials by named alias without ever exposing them to the sandbox.

The Go implementation under ``sandbox/bin/claude-egress-broker`` is the
production binary; this Python reference will be frozen-at-commit and
moved to ``sandbox/reference/egress-broker-python/`` once the Go port
reaches parity (ClaudeConfig-ciw.2 slice 7).
"""

__version__ = "0.0.1"
