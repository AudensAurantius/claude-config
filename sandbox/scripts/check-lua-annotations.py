#!/usr/bin/env python3
"""LuaCATS annotation gate for the hook + lib Lua modules.

Fail if any `function M.X(...)` lacks a preceding doc-comment block
with at least one `--- @(param|return|class|field|alias|type)` tag in
the 12 lines immediately above. Implements ClaudeConfig-nun (F-fmt2)'s
pre-commit gate: luals strict mode catches type mismatches but does
not require annotations; this fills that gap.

Usage:
    sandbox/scripts/check-lua-annotations.py [<file>...]

With no args, checks the canonical hook + lib set.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

DEFAULT_TARGETS = [
    "claude/scripts/hooks/_lib.lua",
    "claude/scripts/hooks/_git.lua",
    "claude/scripts/hooks/config-guard.lua",
    "claude/scripts/hooks/audit-event.lua",
    "claude/scripts/hooks/git-guard.lua",
]

FUNC_RE = re.compile(r"^function M\.([A-Za-z_][A-Za-z0-9_]*)\(")
TAG_RE = re.compile(r"^--- @(param|return|class|field|alias|type)\b")


def check_file(path: Path) -> list[str]:
    """Return one entry per undocumented public function in `path`."""
    failures: list[str] = []
    lines = path.read_text().splitlines()
    for i, line in enumerate(lines):
        m = FUNC_RE.match(line)
        if not m:
            continue
        # Look back up to 12 lines; require at least one --- @tag.
        ctx = lines[max(0, i - 12) : i]
        if any(TAG_RE.match(c) for c in ctx):
            continue
        failures.append(f"{path}:{i + 1}: function M.{m.group(1)} lacks LuaCATS annotation")
    return failures


def main(argv: list[str]) -> int:
    """CLI entry point. Returns 0 on pass, 1 on annotation gap, 2 on missing file."""
    targets = [Path(p) for p in (argv or DEFAULT_TARGETS)]
    failures: list[str] = []
    for t in targets:
        if not t.exists():
            print(f"{t}: not found", file=sys.stderr)
            return 2
        failures.extend(check_file(t))
    if failures:
        print("LuaCATS annotation gate (ClaudeConfig-nun / F-fmt2):", file=sys.stderr)
        for f in failures:
            print(f"  {f}", file=sys.stderr)
        print(
            "\nAdd a `--- @param`/`--- @return` doc-block before each "
            "public M.* function. See existing examples in the same file.",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
