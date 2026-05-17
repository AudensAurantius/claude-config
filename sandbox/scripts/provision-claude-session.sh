#!/usr/bin/env bash
# provision-claude-session.sh — one-shot provisioning for the
# claude-session sandbox user (A2 user-model per DEC-007 follow-up #1).
#
# Creates the claude-session system account, adds the /etc/subuid +
# /etc/subgid mapping so the invoking user can map into its UID/GID
# inside a rootless bwrap user namespace, scaffolds claude-session's
# own home directory (for its independent Anthropic OAuth credentials
# per DEC-009), and applies ACLs to ~/.claude/projects/ so memory
# writes from inside the sandbox flow back to the host user's tree.
#
# Idempotent: re-runs are no-ops once provisioned.
# Reversible: `--uninstall` removes everything this script set up.
#
# Requires root (re-execs under sudo if invoked unprivileged).
#
# Usage: provision-claude-session.sh [--uninstall]
#                                    [--user NAME]
#                                    [--host-user NAME]
#                                    [--host-home PATH]
#                                    [--acl-script PATH]
#                                    [--no-acls]
#                                    [-h|--help]
#
# Options:
#   --uninstall       reverse all provisioning (userdel + subuid/subgid
#                     cleanup + ACL strip from host's ~/.claude/projects/)
#   --user NAME       sandbox user to create (default: claude-session)
#   --host-user NAME  host user that maps into the sandbox UID range
#                     (default: $SUDO_USER, or the invoker if not sudo'd)
#   --host-home PATH  host user's home for ACL targeting
#                     (default: ~$host_user)
#   --acl-script PATH override path to setup-claude-session-acls.sh
#                     (default: alongside this script)
#   --no-acls         skip the ACL step (user/subuid only)
#   -h, --help        show this help
#
# Cross-references:
#   DEC-007  bwrap as Phase 1 sandbox primitive (and A2 user-model)
#   DEC-008  no credential injection in profiles
#   DEC-009  claude-session's own Anthropic OAuth
#   J121-ft3 bead acceptance criteria

set -euo pipefail

# ── Argument parsing ─────────────────────────────────────────────────────────

mode="install"
claude_user="claude-session"
host_user="${SUDO_USER:-$(id -un)}"
host_home=""
acl_script=""
do_acls=1

usage() {
    sed -n '/^# provision-claude-session.sh/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)     usage; exit 0 ;;
        --uninstall)   mode="uninstall"; shift ;;
        --user)        claude_user="$2"; shift 2 ;;
        --host-user)   host_user="$2"; shift 2 ;;
        --host-home)   host_home="$2"; shift 2 ;;
        --acl-script)  acl_script="$2"; shift 2 ;;
        --no-acls)     do_acls=0; shift ;;
        *) echo "provision-claude-session.sh: unknown arg: $1" >&2; exit 1 ;;
    esac
done

# Default host_home from host_user once both are known
if [ -z "$host_home" ]; then
    host_home="$(getent passwd "$host_user" | cut -d: -f6)"
    if [ -z "$host_home" ]; then
        echo "provision-claude-session.sh: cannot resolve home for host user '$host_user'" >&2
        exit 1
    fi
fi

# Default ACL script alongside this one
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "$acl_script" ]; then
    acl_script="${script_dir}/setup-claude-session-acls.sh"
fi

claude_home="/home/${claude_user}"

# ── Privilege escalation ─────────────────────────────────────────────────────
# useradd, /etc/subuid edits, and chown all require root. Re-exec under
# sudo if invoked unprivileged, preserving args.

if [ "$(id -u)" -ne 0 ]; then
    if ! command -v sudo >/dev/null 2>&1; then
        echo "provision-claude-session.sh: must run as root and sudo is not available" >&2
        exit 1
    fi
    echo "→ re-execing under sudo ..."
    exec sudo -E "${BASH_SOURCE[0]}" \
        ${mode:+$( [ "$mode" = "uninstall" ] && echo --uninstall )} \
        --user "$claude_user" \
        --host-user "$host_user" \
        --host-home "$host_home" \
        --acl-script "$acl_script" \
        $( [ "$do_acls" -eq 0 ] && echo --no-acls )
fi

# ── /etc/subuid + /etc/subgid helpers ────────────────────────────────────────
# We add a single-entry mapping: "<host_user>:<claude-uid>:1". This lets
# bwrap's --unshare-user --uid <claude-uid> succeed for $host_user without
# needing a full 65k subuid range that includes the sandbox UID.

subuid_line() { printf '%s:%s:1\n' "$1" "$2"; }

add_sub_mapping() {
    local file="$1" user="$2" id="$3"
    local line; line="$(subuid_line "$user" "$id")"
    if grep -qxF "$line" "$file" 2>/dev/null; then
        echo "  ✓ ${file}: already has '${line}'"
        return 0
    fi
    # Avoid trailing-newline glitches: ensure file ends in a newline first.
    if [ -s "$file" ] && [ "$(tail -c1 "$file")" != "" ]; then
        printf '\n' >> "$file"
    fi
    printf '%s\n' "$line" >> "$file"
    echo "  ✓ ${file}: added '${line}'"
}

remove_sub_mapping() {
    local file="$1" user="$2" id="$3"
    local line; line="$(subuid_line "$user" "$id")"
    if [ ! -f "$file" ]; then return 0; fi
    if ! grep -qxF "$line" "$file"; then
        echo "  ✓ ${file}: '${line}' already absent"
        return 0
    fi
    local tmp; tmp="$(mktemp)"
    grep -vxF "$line" "$file" > "$tmp"
    install -m 0644 "$tmp" "$file"
    rm -f "$tmp"
    echo "  ✓ ${file}: removed '${line}'"
}

# ── Install ──────────────────────────────────────────────────────────────────

do_install() {
    echo "Provisioning sandbox user '${claude_user}' for host user '${host_user}' ..."

    # 1. Create system user (idempotent)
    if id -u "$claude_user" >/dev/null 2>&1; then
        echo "  ✓ user '${claude_user}' already exists (uid=$(id -u "$claude_user"))"
    else
        useradd \
            --system \
            --home-dir "$claude_home" \
            --create-home \
            --shell /usr/sbin/nologin \
            --comment "Claude Code sandbox principal (A2 model)" \
            "$claude_user"
        echo "  ✓ created user '${claude_user}' (uid=$(id -u "$claude_user"))"
    fi

    local claude_uid claude_gid
    claude_uid="$(id -u "$claude_user")"
    claude_gid="$(id -g "$claude_user")"

    # 2. Scaffold /home/claude-session/.claude/ for OAuth + .claude.json
    # Mode 0750 so claude-session owns its own state; group can read for
    # diagnostics, world cannot.
    install -d -m 0750 -o "$claude_user" -g "$claude_user" "$claude_home"
    install -d -m 0750 -o "$claude_user" -g "$claude_user" "$claude_home/.claude"
    echo "  ✓ scaffolded ${claude_home}/.claude/"

    # 3. /etc/subuid + /etc/subgid mappings for the host user
    add_sub_mapping /etc/subuid "$host_user" "$claude_uid"
    add_sub_mapping /etc/subgid "$host_user" "$claude_gid"

    # 4. ACLs on host user's ~/.claude/projects/ via the dedicated script
    if [ "$do_acls" -eq 1 ]; then
        if [ ! -x "$acl_script" ]; then
            echo "provision-claude-session.sh: ACL script not executable: $acl_script" >&2
            echo "  Pass --no-acls to skip, or --acl-script PATH to override." >&2
            exit 1
        fi
        echo "→ invoking ACL setup: $acl_script"
        "$acl_script" --user "$claude_user" --home-dir "$host_home"
    else
        echo "  • ACL setup skipped (--no-acls)"
    fi

    echo ""
    echo "✓ Provisioning complete."
    echo ""
    echo "Next: invoke claude-sandbox interactively to complete claude-session's"
    echo "      one-time Anthropic OAuth flow (DEC-009). The token is written to"
    echo "      ${claude_home}/.claude/ and is independent of your interactive"
    echo "      identity."
}

# ── Uninstall ────────────────────────────────────────────────────────────────

do_uninstall() {
    echo "Un-provisioning sandbox user '${claude_user}' ..."

    local claude_uid="" claude_gid=""
    if id -u "$claude_user" >/dev/null 2>&1; then
        claude_uid="$(id -u "$claude_user")"
        claude_gid="$(id -g "$claude_user")"
    else
        echo "  • user '${claude_user}' does not exist; skipping userdel + subuid cleanup"
    fi

    # 1. Strip ACLs first (need the UID to exist for setfacl by name; if user
    # already gone, strip by numeric UID). The host user's projects/ tree
    # accumulates ACLs over time — leaving orphan numeric UIDs is ugly.
    if command -v setfacl >/dev/null 2>&1; then
        local projects_dir="${host_home}/.claude/projects"
        if [ -d "$projects_dir" ]; then
            local target="${claude_user}"
            [ -n "$claude_uid" ] && target="$claude_uid"  # numeric works either way
            setfacl -R    -x "u:${target}" "$projects_dir" 2>/dev/null || true
            setfacl -R -d -x "u:${target}" "$projects_dir" 2>/dev/null || true
            echo "  ✓ stripped ACLs for '${target}' from ${projects_dir}"
        fi
    fi

    # 2. Remove subuid/subgid mappings (only if we know the IDs we added)
    if [ -n "$claude_uid" ]; then
        remove_sub_mapping /etc/subuid "$host_user" "$claude_uid"
    fi
    if [ -n "$claude_gid" ]; then
        remove_sub_mapping /etc/subgid "$host_user" "$claude_gid"
    fi

    # 3. Delete user + home
    if [ -n "$claude_uid" ]; then
        # --remove deletes the home dir; --force allows even if logged in
        # (claude-session has nologin shell, but processes may exist).
        if userdel --remove --force "$claude_user" 2>/dev/null; then
            echo "  ✓ deleted user '${claude_user}' and removed ${claude_home}"
        else
            echo "  ! userdel failed; leftover state may remain at ${claude_home}" >&2
        fi
    fi

    echo ""
    echo "✓ Un-provisioning complete."
}

# ── Dispatch ─────────────────────────────────────────────────────────────────

case "$mode" in
    install)   do_install ;;
    uninstall) do_uninstall ;;
esac
