#!/usr/bin/env bash
# setup-claude-session-acls.sh — grant a sandbox user write access to the
# host user's ~/.claude/projects/ tree, so memory writes from inside the
# bwrap sandbox (running as claude-session) flow back to the canonical
# project memory dir owned by the host user.
#
# Idempotent: re-runs leave existing ACLs unchanged. Default ACLs are set
# so new files/subdirs inheriting the directory's ACL grant rwx automatically.
#
# Invoked by sandbox/scripts/provision-claude-session.sh (J121-ft3) at
# install time. Requires the sandbox user to exist already; J121-ft3
# creates it before invoking this script.
#
# Usage: setup-claude-session-acls.sh [--user NAME] [--home-dir PATH]
#
# Options:
#   --user NAME       sandbox user (default: claude-session)
#   --home-dir PATH   host user's home whose .claude/projects/ to ACL
#                     (default: ${HOME} of the invoker)
#   -h, --help        show this help
#
# Cross-references:
#   - DEC-006 (allow-list visibility) — ACLs gate write-back through the
#     read_write bind in sandbox/profiles/default.yaml.
#   - ROADMAP Phase 1, Phase 4 (memory continuity).

set -euo pipefail

usage() {
    sed -n '/^# setup-claude-session-acls.sh/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

claude_user="claude-session"
home_dir="$HOME"

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)  usage; exit 0 ;;
        --user)     claude_user="$2"; shift 2 ;;
        --home-dir) home_dir="$2";    shift 2 ;;
        *) echo "setup-claude-session-acls.sh: unknown arg: $1" >&2; exit 1 ;;
    esac
done

# ── Preconditions ────────────────────────────────────────────────────────────

if ! id -u "$claude_user" >/dev/null 2>&1; then
    echo "setup-claude-session-acls.sh: user '$claude_user' does not exist" >&2
    echo "  Run J121-ft3 (provision-claude-session.sh) first." >&2
    exit 1
fi

if ! command -v setfacl >/dev/null 2>&1; then
    echo "setup-claude-session-acls.sh: setfacl not found on PATH" >&2
    echo "  Install the 'acl' package: sudo apt install acl" >&2
    exit 1
fi

projects_dir="${home_dir}/.claude/projects"
if [ ! -d "$projects_dir" ]; then
    echo "setup-claude-session-acls.sh: $projects_dir does not exist; creating"
    mkdir -p "$projects_dir"
fi

# ── ACL filesystem support probe ─────────────────────────────────────────────
# Verify the underlying filesystem supports ACLs before attempting recursive
# setfacl. ext4/xfs/btrfs default to ACL-enabled on modern kernels; the
# probe gives a clearer error than setfacl's default message if they're not.

probe="$(mktemp -p "$projects_dir" .acltest.XXXXXX)"
if ! setfacl -m "u:${claude_user}:r" "$probe" 2>/dev/null; then
    rm -f "$probe"
    echo "setup-claude-session-acls.sh: filesystem does not support ACLs" >&2
    echo "  Underlying mount may be missing the ACL option." >&2
    exit 1
fi
rm -f "$probe"

# ── Apply recursive + default ACLs ───────────────────────────────────────────
# -m  modify (additive; preserves existing ACLs)
# -R  recursive
# -d  default ACL (inherited by newly-created files/dirs)

setfacl -R -m    "u:${claude_user}:rwx" "$projects_dir"
setfacl -R -d -m "u:${claude_user}:rwx" "$projects_dir"

# ── Verify ───────────────────────────────────────────────────────────────────

if getfacl --absolute-names "$projects_dir" 2>/dev/null | grep -q "user:${claude_user}:rwx"; then
    echo "✓ ACLs set: ${claude_user} has rwx on ${projects_dir}"
    echo "  Applied recursively + default ACL for newly-created files/dirs."
else
    echo "setup-claude-session-acls.sh: ACL verification failed" >&2
    echo "  Run: getfacl --absolute-names $projects_dir" >&2
    exit 1
fi
