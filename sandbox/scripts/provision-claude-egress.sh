#!/usr/bin/env bash
# provision-claude-egress.sh — one-shot provisioning for the
# claude-egress UID (DEC-013 egress mediation principal).
#
# Creates the claude-egress system account (separate top-level UID,
# distinct from claude-session — a compromised claude-session must
# not tamper with proxy policy or eavesdrop on broker plaintext) and
# scaffolds the two policy/credential directories the broker and
# SNI proxy will read at runtime:
#
#   /etc/claude-config/egress-policy/   broker + proxy policy
#   /etc/claude-config/credentials/     per-credential files (broker)
#
# Both directories are root-owned with group claude-egress and mode
# 0750. Files written into them should be mode 0640 (root:claude-
# egress) — the broker/proxy can read but not write, and only the
# operator (root) can author policy. No sudoers entry for the
# claude-egress user.
#
# Idempotent: re-runs are no-ops once provisioned.
# Reversible: `--uninstall` removes the user. Operator-curated files
# in the policy/credential directories are NOT removed (preserves
# data the operator placed by hand); an explicit `--purge` flag
# removes the directories and their contents too.
#
# Requires root (re-execs under sudo if invoked unprivileged).
#
# Usage: provision-claude-egress.sh [--uninstall] [--purge]
#                                   [--user NAME]
#                                   [-h|--help]
#
# Options:
#   --uninstall  reverse provisioning (userdel; policy/cred dirs
#                preserved unless --purge is also given)
#   --purge      with --uninstall, also remove the policy and
#                credentials directories and their contents
#   --user NAME  egress user to create (default: claude-egress)
#   -h, --help   show this help
#
# Cross-references:
#   DEC-013  egress mediation (broker + SNI proxy)
#   ClaudeConfig-ciw.1  bead acceptance criteria

set -euo pipefail

# ── Argument parsing ─────────────────────────────────────────────────────────

mode="install"
purge=0
egress_user="claude-egress"

usage() {
    sed -n '/^# provision-claude-egress.sh/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        -h | --help)
            usage
            exit 0
            ;;
        --uninstall)
            mode="uninstall"
            shift
            ;;
        --purge)
            purge=1
            shift
            ;;
        --user)
            egress_user="$2"
            shift 2
            ;;
        *)
            echo "provision-claude-egress.sh: unknown arg: $1" >&2
            exit 1
            ;;
    esac
done

if [ "$purge" -eq 1 ] && [ "$mode" != "uninstall" ]; then
    echo "provision-claude-egress.sh: --purge requires --uninstall" >&2
    exit 1
fi

policy_dir="/etc/claude-config/egress-policy"
creds_dir="/etc/claude-config/credentials"
etc_root="/etc/claude-config"

# ── Privilege escalation ─────────────────────────────────────────────────────
# useradd + chown + /etc writes all require root. Re-exec under sudo
# if invoked unprivileged, preserving args.

if [ "$(id -u)" -ne 0 ]; then
    if ! command -v sudo >/dev/null 2>&1; then
        echo "provision-claude-egress.sh: must run as root and sudo is not available" >&2
        exit 1
    fi
    echo "→ re-execing under sudo ..."
    # SC2046: word-splitting is intentional — each conditional emits either
    # zero words (no flag) or exactly one. Quoting would pass an empty-string
    # argument when the condition is false.
    # shellcheck disable=SC2046
    exec sudo -E "${BASH_SOURCE[0]}" \
        $([ "$mode" = "uninstall" ] && printf '%s\n' --uninstall) \
        $([ "$purge" -eq 1 ] && printf '%s\n' --purge) \
        --user "$egress_user"
fi

# ── Install ──────────────────────────────────────────────────────────────────

do_install() {
    echo "Provisioning egress user '${egress_user}' ..."

    # 1. Create system user (idempotent). No home directory: the broker
    # and proxy will be systemd services with explicit WorkingDirectory;
    # no need for a writable $HOME. nologin shell + system UID range.
    if id -u "$egress_user" >/dev/null 2>&1; then
        echo "  ✓ user '${egress_user}' already exists (uid=$(id -u "$egress_user"))"
    else
        useradd \
            --system \
            --no-create-home \
            --home-dir /nonexistent \
            --shell /usr/sbin/nologin \
            --comment "Claude Code egress mediation principal (DEC-013)" \
            "$egress_user"
        echo "  ✓ created user '${egress_user}' (uid=$(id -u "$egress_user"))"
    fi

    # 2. Scaffold /etc/claude-config/ and the two policy/credential subdirs.
    # Parent dir is world-traversable (0755 root:root) so the broker/proxy
    # can reach the subdirs. Subdirs are 0750 root:claude-egress: group-
    # readable for the broker/proxy, not world-readable. Files inside
    # should be created mode 0640 (enforced by the broker/proxy authors,
    # not this script).
    install -d -m 0755 -o root -g root "$etc_root"
    echo "  ✓ ${etc_root}/ (0755 root:root)"

    install -d -m 0750 -o root -g "$egress_user" "$policy_dir"
    echo "  ✓ ${policy_dir}/ (0750 root:${egress_user})"

    install -d -m 0750 -o root -g "$egress_user" "$creds_dir"
    echo "  ✓ ${creds_dir}/ (0750 root:${egress_user})"

    echo ""
    echo "✓ Provisioning complete."
    echo ""
    echo "Next steps (Phase 1.5):"
    echo "  - ClaudeConfig-ciw.2 will install claude-egress-broker"
    echo "    (Unix-socket credential broker) and its systemd unit."
    echo "  - ClaudeConfig-ciw.3 will install claude-egress-proxy"
    echo "    (SNI-inspecting passthrough proxy) and its systemd unit."
    echo "  - Operator authors policy files under ${policy_dir}/ and"
    echo "    credential files under ${creds_dir}/ (mode 0640 root:${egress_user})."
}

# ── Uninstall ────────────────────────────────────────────────────────────────

do_uninstall() {
    echo "Un-provisioning egress user '${egress_user}' ..."

    if id -u "$egress_user" >/dev/null 2>&1; then
        # --force allows even if processes exist; nologin shell means
        # no interactive sessions to lose.
        if userdel --force "$egress_user" 2>/dev/null; then
            echo "  ✓ deleted user '${egress_user}'"
        else
            echo "  ! userdel failed for '${egress_user}'" >&2
        fi
    else
        echo "  • user '${egress_user}' does not exist; skipping userdel"
    fi

    if [ "$purge" -eq 1 ]; then
        # Operator opt-in to destroy policy + credential files.
        for d in "$policy_dir" "$creds_dir"; do
            if [ -d "$d" ]; then
                rm -rf "$d"
                echo "  ✓ purged ${d}/"
            fi
        done
        # Remove /etc/claude-config/ only if empty (other tooling may
        # add subdirs in the future).
        if [ -d "$etc_root" ] && [ -z "$(ls -A "$etc_root" 2>/dev/null)" ]; then
            rmdir "$etc_root"
            echo "  ✓ removed empty ${etc_root}/"
        fi
    else
        if [ -d "$policy_dir" ] || [ -d "$creds_dir" ]; then
            echo "  • policy + credential dirs preserved (operator data);"
            echo "    re-run with --purge to remove them."
        fi
    fi

    echo ""
    echo "✓ Un-provisioning complete."
}

# ── Dispatch ─────────────────────────────────────────────────────────────────

case "$mode" in
    install) do_install ;;
    uninstall) do_uninstall ;;
esac
