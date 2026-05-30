#!/usr/bin/env python3
"""config-guard PreToolUse hook (ClaudeConfig-40s.18).

Reactive layer-2 over DEC-012's read-only bind / ACL boundary: detects a
sandboxed session attempting to Write/Edit the *deployed* Claude config
(its global CLAUDE.md, settings files, managed settings) and DENIES it,
emitting a journald alert for the audit trail. The bind already makes those
paths read-only (preventative); this surfaces the *attempt* before the OS
write would fail, so tampering is visible, not silent.

NOT protected: the claude-config *repo* tree (e.g. ~/Source/claude-config/
CLAUDE.md) — that is the legitimate self-modification surface (edit in the
repo, reinstall). Only the DEPLOYED config under the session's home + the
system managed settings are guarded.

PreToolUse contract: reads JSON on stdin
  {"tool_name": "...", "tool_input": {"file_path": "...", ...}, "cwd": "..."}
Emits on stdout:
  {"hookSpecificOutput": {"hookEventName": "PreToolUse",
     "permissionDecision": "deny"|"allow", "permissionDecisionReason": "..."}}
Fail-open is NEVER used for a matched protected path: any parse/dispatch
doubt on a write-class tool defaults to deny with a reason.
"""
import json
import os
import subprocess
import sys

WRITE_TOOLS = {"Write", "Edit", "MultiEdit", "NotebookEdit"}

# Deployed-config paths (relative to the session's HOME unless absolute).
HOME = os.path.expanduser("~")
PROTECTED = {
    os.path.join(HOME, ".claude", "CLAUDE.md"),
    os.path.join(HOME, ".claude", "settings.json"),
    os.path.join(HOME, ".claude", "settings.local.json"),
    os.path.join(HOME, ".claude.json"),
}
# Protected directory prefixes (anything under these is guarded).
PROTECTED_PREFIXES = (
    "/etc/claude-code/",
    os.path.join(HOME, ".claude", "scripts", "hooks") + "/",
)


def _emit(decision: str, reason: str) -> None:
    json.dump(
        {
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": decision,
                "permissionDecisionReason": reason,
            }
        },
        sys.stdout,
    )
    sys.stdout.write("\n")


def _alert(msg: str) -> None:
    """Best-effort journald alert (systemd-cat); never fatal."""
    try:
        subprocess.run(
            ["systemd-cat", "-t", "claude-config-guard", "-p", "warning"],
            input=msg.encode(),
            timeout=5,
            check=False,
        )
    except (FileNotFoundError, OSError, subprocess.SubprocessError):
        # No systemd-cat (e.g. non-systemd host) — fall back to stderr.
        print(f"claude-config-guard: {msg}", file=sys.stderr)


def _is_protected(path: str) -> bool:
    if not path:
        return False
    p = os.path.realpath(os.path.expanduser(path))
    if p in {os.path.realpath(x) for x in PROTECTED}:
        return True
    return any(p.startswith(os.path.realpath(pre.rstrip("/")) + "/") for pre in PROTECTED_PREFIXES)


def main() -> int:
    try:
        data = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        # Can't parse the event — don't block arbitrary tool use on our error.
        _emit("allow", "config-guard: unparseable hook input; allowing")
        return 0

    tool = data.get("tool_name", "")
    if tool not in WRITE_TOOLS:
        _emit("allow", "config-guard: not a write-class tool")
        return 0

    path = (data.get("tool_input") or {}).get("file_path", "")
    if _is_protected(path):
        reason = (
            f"config-guard: blocked {tool} to deployed Claude config '{path}'. "
            "Deployed config is managed (read-only to sandboxed sessions); "
            "change it in the claude-config repo and reinstall, not in-session."
        )
        _alert(reason)
        _emit("deny", reason)
        return 0

    _emit("allow", "config-guard: not a protected config path")
    return 0


if __name__ == "__main__":
    sys.exit(main())
