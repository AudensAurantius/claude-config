#!/usr/bin/env bash
# _hooks-manifest.sh — emit the canonical `.hooks` block that gets
# merged into claude-session's settings.json by the wrapper's
# assemble_claude_dir (DEC-017; ClaudeConfig-40s.18, 40s.19).
#
# Output: a single JSON document on stdout suitable for `jq --argjson`
# consumption. Each Claude Code hook event (PreToolUse, PostToolUse,
# …) maps to an array of `{matcher, hooks: [{type, command}]}` entries.
# Empty matcher = NO match (it's a regex of the tool name — empty
# string matches nothing); use ".*" for match-all.
#
# Hook command paths are ABSOLUTE because Claude Code does not shell-
# expand ~ in the command field. The wrapper passes SANDBOX_HOME so we
# can interpolate the in-sandbox home path (= claude-session's host
# home under DEC-012, so the absolute string is correct in both
# composed and standalone views). assemble_claude_dir mirrors the
# install-side hook scripts into $SANDBOX_HOME/.claude/hooks/ at
# session boot.
set -euo pipefail

: "${SANDBOX_HOME:?SANDBOX_HOME not set}"

cat <<EOF
{
    "PreToolUse": [
        {
            "matcher": "Write|Edit|MultiEdit|NotebookEdit",
            "hooks": [
                {"type": "command", "command": "lua ${SANDBOX_HOME}/.claude/hooks/config-guard.lua"}
            ]
        },
        {
            "matcher": ".*",
            "hooks": [
                {"type": "command", "command": "lua ${SANDBOX_HOME}/.claude/hooks/audit-event.lua --event=PreToolUse"}
            ]
        }
    ],
    "PostToolUse": [
        {
            "matcher": ".*",
            "hooks": [
                {"type": "command", "command": "lua ${SANDBOX_HOME}/.claude/hooks/audit-event.lua --event=PostToolUse"}
            ]
        }
    ]
}
EOF
