"""Smoke test for the claude-config package shell.

First Python test for the project (DEC-019, DEC-022). Real tests
arrive as Python entry points land; this exists so pytest collects
something on day one and the `just test` gate has a green path.
"""

from __future__ import annotations

import claude_config


def test_package_importable() -> None:
    """The package imports and exposes a non-empty version string."""
    assert isinstance(claude_config.__version__, str)
    assert claude_config.__version__  # non-empty
