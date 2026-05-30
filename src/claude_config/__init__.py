"""claude-config — Python utilities supporting the sandbox + tooling stack.

Entry points (added as tooling lands per DEC-019) live under
``claude_config.<area>`` and are exposed as ``[project.scripts]`` in
``pyproject.toml``. Deployed via ``pipx`` / ``uv tool install`` into
``claude-session``'s home (DEC-016 model).
"""

__version__ = "0.0.0"
