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
#                                     [--project PATH]...
#
# Options:
#   --user NAME       sandbox user (default: claude-session)
#   --home-dir PATH   host user's home whose .claude/projects/ to ACL
#                     (default: ${HOME} of the invoker)
#   --project PATH    grant the sandbox user access to a project worktree
#                     (repeatable). Threads a traversal-only (--x) ACL through
#                     the 0700 home + intermediate dirs to reach PATH, then
#                     grants recursive rwX + default ACL on PATH itself. The
#                     rest of the home stays unreadable (DEC-012). Idempotent:
#                     skips the recursive pass if the ACL is already present.
#   -h, --help        show this help
#
# Cross-references:
#   - DEC-006 (allow-list visibility) — ACLs gate write-back through the
#     read_write bind in sandbox/profiles/default.yaml.
#   - DEC-012 (UID boundary) — 0700 home blocks traversal; --x ACLs thread
#     access to exactly the named project and nothing else.
#   - ROADMAP Phase 1, Phase 4 (memory continuity). ClaudeConfig-40s.15.9.

set -euo pipefail

usage() {
    sed -n '/^# setup-claude-session-acls.sh/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# Grant the sandbox user access to one project worktree (DEC-012 / 40s.15.9):
# thread a traversal-only (--x) ACL through every non-world-traversable
# ancestor (e.g. the 0700 home), then recursive rwX + default ACL on the
# worktree itself. The rest of the home stays unreadable. Idempotent.
grant_project_acl() {
    local project="$1"
    case "$project" in
        /*) ;;
        *)
            echo "  ✗ --project must be an absolute path: $project" >&2
            return 1
            ;;
    esac
    [ -d "$project" ] || {
        echo "  ✗ project dir not found: $project" >&2
        return 1
    }

    # 1. Traversal-only ACL on each ancestor that is not already world-
    #    traversable. A 0755 dir below a 0700 dir is common, so check every
    #    ancestor independently (do NOT stop at the first traversable one).
    local d perms last
    d="$(dirname "$project")"
    while [ "$d" != "/" ] && [ -n "$d" ]; do
        perms="$(stat -c '%A' "$d" 2>/dev/null || true)"
        last="${perms: -1}"
        # others-execute is set when the last char is 'x' (plain) or 't'
        # (sticky+execute); '-' or 'T' (sticky, no execute) means a blocked
        # ancestor that needs a traversal-only ACL.
        if [ -n "$perms" ] && [ "$last" != "x" ] && [ "$last" != "t" ]; then
            setfacl -m "u:${claude_user}:--x" "$d" ||
                echo "  warn: could not grant --x on $d (not owner?); traversal may fail" >&2
        fi
        d="$(dirname "$d")"
    done

    # 2. Recursive rwX + default ACL on the worktree. Idempotent: skip the
    #    (potentially slow) recursive pass if the top already carries the ACL.
    if getfacl --absolute-names "$project" 2>/dev/null | grep -q "^user:${claude_user}:"; then
        echo "  ✓ ${claude_user} already has an ACL on ${project} (skipped recursive pass)"
    else
        setfacl -R -m "u:${claude_user}:rwX" "$project"
        setfacl -R -d -m "u:${claude_user}:rwX" "$project"
        echo "  ✓ granted ${claude_user} rwX (recursive + default) on ${project}"
    fi
}

claude_user="claude-session"
home_dir="$HOME"
project_paths=()

while [ $# -gt 0 ]; do
    case "$1" in
        -h | --help)
            usage
            exit 0
            ;;
        --user)
            claude_user="$2"
            shift 2
            ;;
        --home-dir)
            home_dir="$2"
            shift 2
            ;;
        --project)
            project_paths+=("$2")
            shift 2
            ;;
        *)
            echo "setup-claude-session-acls.sh: unknown arg: $1" >&2
            exit 1
            ;;
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

# Idempotent-fast: skip the (potentially slow) recursive pass if the ACL is
# already present — this script is invoked per session by the launcher.
if getfacl --absolute-names "$projects_dir" 2>/dev/null | grep -q "^user:${claude_user}:rwx"; then
    echo "✓ ${claude_user} already has rwx on ${projects_dir} (skipped recursive pass)"
else
    setfacl -R -m "u:${claude_user}:rwx" "$projects_dir"
    setfacl -R -d -m "u:${claude_user}:rwx" "$projects_dir"
fi

# ── Verify ───────────────────────────────────────────────────────────────────

if getfacl --absolute-names "$projects_dir" 2>/dev/null | grep -q "user:${claude_user}:rwx"; then
    echo "✓ ACLs set: ${claude_user} has rwx on ${projects_dir}"
    echo "  Applied recursively + default ACL for newly-created files/dirs."
else
    echo "setup-claude-session-acls.sh: ACL verification failed" >&2
    echo "  Run: getfacl --absolute-names $projects_dir" >&2
    exit 1
fi

# ── Per-project worktree ACLs (optional, repeatable) ─────────────────────────

if [ "${#project_paths[@]}" -gt 0 ]; then
    for p in "${project_paths[@]}"; do
        [ -n "$p" ] || continue
        echo "→ project ACL: $p"
        grant_project_acl "$p"
    done
fi
