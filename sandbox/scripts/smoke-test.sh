#!/usr/bin/env bash
# smoke-test.sh — Phase 1 two-mode smoke test for claude-sandbox.
# (ClaudeConfig-40s.15.4; expands the 40s.6 manual smoke-test doc.)
#
# Checks, per mode:
#   - `claude -p` returns the expected sentinel (full path works end-to-end)
# Plus a standalone isolation probe:
#   - runs as the sandbox UID (not the host user)
#   - no other users' homes are visible
#   - the environment is scrubbed of credential-ish vars
# Plus a multi-interpreter availability survey (ClaudeConfig-58n.3,
# DEC-020): python3, node, bash, perl, lua callable as the sandbox UID
# (project hooks under .claude-session/hooks/ rely on shebang dispatch
# into this set).
#
# Composed mode is SKIPPED when srt is not available to the sandbox user
# (its own prerequisite bead). Standalone needs no srt.
#
# Usage: smoke-test.sh            # run from any non-dotfile dir
#        CLAUDE_SANDBOX=/path/to/claude-sandbox smoke-test.sh
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
WRAPPER="${CLAUDE_SANDBOX:-$SELF_DIR/../bin/claude-sandbox}"
SANDBOX_USER="${SANDBOX_USER:-claude-session}"
SANDBOX_HOME="$(getent passwd "$SANDBOX_USER" 2>/dev/null | cut -d: -f6)"
pass=0; fail=0; skip=0

# Absolutize a relative profile-dir override before we cd away (test ergonomics;
# in production the wrapper's default profile dir is already absolute).
if [ -n "${CLAUDE_SANDBOX_PROFILE_DIR:-}" ]; then
    CLAUDE_SANDBOX_PROFILE_DIR="$(cd "$CLAUDE_SANDBOX_PROFILE_DIR" && pwd)"
    export CLAUDE_SANDBOX_PROFILE_DIR
fi

ok()    { echo "  ✓ $1"; pass=$((pass+1)); }
bad()   { echo "  ✗ $1"; fail=$((fail+1)); }
skipt() { echo "  • SKIP $1"; skip=$((skip+1)); }
expect() {  # expect <label> <actual> <wanted>
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', wanted '$3')"; fi
}

# Run from a clean throwaway project dir (passes the wrapper's cwd guard).
# srt/claude may write sandbox-user-owned files (e.g. node_modules) here; the
# sudo fallback cleans those on exit.
work="$(mktemp -d)"; trap 'rm -rf "$work" 2>/dev/null || sudo rm -rf "$work" 2>/dev/null' EXIT
cd "$work" || exit 1

run_mode() {  # run_mode <label> <sentinel> [extra wrapper flags...]
    local label="$1" sentinel="$2"; shift 2
    local out
    out="$(timeout 180 "$WRAPPER" "$@" -p "Reply with exactly: $sentinel" 2>&1)"
    # grep the whole output: claude -p may emit a trailing newline / extra lines.
    if printf '%s' "$out" | grep -q -- "$sentinel"; then
        ok "$label: claude -p returned $sentinel"
    else
        bad "$label: claude -p did not return $sentinel (got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-80))"
    fi
}

echo "== claude-sandbox smoke test =="
echo "wrapper: $WRAPPER ; sandbox user: $SANDBOX_USER ; cwd: $work"

echo "[standalone] end-to-end"
run_mode "standalone" "STANDALONE_OK" --standalone

echo "[composed] end-to-end (needs srt available to $SANDBOX_USER)"
if sudo -u "$SANDBOX_USER" -H env PATH="$SANDBOX_HOME/.local/bin:$SANDBOX_HOME/.bun/bin:/usr/local/bin:/usr/bin:/bin" \
        bash -c 'command -v srt' >/dev/null 2>&1; then
    run_mode "composed" "COMPOSED_OK"
else
    skipt "composed: srt not available to $SANDBOX_USER (provision-srt prerequisite bead)"
fi

echo "[standalone] isolation properties"
probe="$(sudo -u "$SANDBOX_USER" env -i HOME="$SANDBOX_HOME" USER="$SANDBOX_USER" PATH=/usr/bin:/bin \
    bwrap --unshare-all --share-net --proc /proc --dev /dev \
        --ro-bind /usr /usr --ro-bind /etc /etc \
        --symlink usr/bin /bin --symlink usr/lib /lib --symlink usr/lib64 /lib64 \
        --tmpfs "$SANDBOX_HOME" --die-with-parent \
        -- bash -c 'echo "WHO=$(id -un)"; echo "OTHERS=$(ls /home 2>/dev/null | grep -vx "$USER" | wc -l)"; echo "SECRETS=$(env | grep -ciE "anthropic|claude_code|aws_|_token")"' 2>/dev/null)"
who="$(printf '%s\n' "$probe"    | grep '^WHO='     | cut -d= -f2)"
others="$(printf '%s\n' "$probe" | grep '^OTHERS='  | cut -d= -f2)"
secrets="$(printf '%s\n' "$probe"| grep '^SECRETS=' | cut -d= -f2)"
expect "runs as $SANDBOX_USER (not host user)" "$who" "$SANDBOX_USER"
expect "no other users' homes visible" "${others:-?}" "0"
expect "environment scrubbed of credential-ish vars" "${secrets:-?}" "0"

echo "[interpreters] availability as $SANDBOX_USER (DEC-020 project-hook shebang dispatch)"
# Identity + PATH are identical between composed and standalone modes
# (both run as claude-session with the wrapper's scrubbed PATH), so a
# single sudo-as-$SANDBOX_USER check covers both. PATH below mirrors
# the wrapper's env-scrub block so claude-session's per-user binaries
# (e.g. ~/.local/bin/lua → /usr/bin/luajit) resolve as they would in
# a live session.
interp_path="$SANDBOX_HOME/.local/bin:$SANDBOX_HOME/.bun/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
for spec in \
    "python3:python3 --version" \
    "node:node --version" \
    "bash:bash --version" \
    "perl:perl -e exit" \
    "lua:lua -v"; do
    name="${spec%%:*}"; cmd="${spec#*:}"
    if sudo -u "$SANDBOX_USER" -H env -i HOME="$SANDBOX_HOME" PATH="$interp_path" \
            bash -c "$cmd" >/dev/null 2>&1; then
        ok "$name callable via #!/usr/bin/env $name"
    else
        bad "$name NOT callable (project hooks via #!/usr/bin/env $name will fail)"
    fi
done

echo "== result: $pass passed, $fail failed, $skip skipped =="
[ "$fail" -eq 0 ]
