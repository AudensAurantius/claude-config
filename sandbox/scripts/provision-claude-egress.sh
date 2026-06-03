#!/usr/bin/env bash
# provision-claude-egress.sh — one-shot provisioning for the
# claude-egress UID (DEC-013 egress mediation principal).
#
# Creates the claude-egress system account (separate top-level UID,
# distinct from claude-session — a compromised claude-session must
# not tamper with proxy policy or eavesdrop on broker plaintext),
# scaffolds the policy/credential directories the broker and SNI
# proxy will read at runtime, and scaffolds the broker's credential-
# backend home (pass(1) + GPG, per DEC-029):
#
#   /etc/claude-config/egress-policy/   broker + proxy policy
#   /etc/claude-config/credentials/     per-credential files (proxy/legacy)
#   /home/claude-egress/                broker's home (pass + GPG)
#   /home/claude-egress/.password-store empty pass store
#   /home/claude-egress/.gnupg          empty GPG home
#
# Policy/credential dirs are root-owned, group claude-egress, mode
# 0750. Files within should be 0640 (root:claude-egress). The home
# directory and its dotdirs are 0700 owner claude-egress.
#
# Per DEC-029, claude-egress is a service principal: nologin shell,
# no Claude binary on its PATH, no sudoers entry permitting it to
# spawn anything. The reverse direction — claude-egress -> claude-
# session — is also forbidden.
#
# The GPG key and pass store contents are NOT created by this script
# (they require interactive passphrase entry); operator workflow is
# documented in the "Next steps" output.
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
egress_home="/home/claude-egress"
pass_store="${egress_home}/.password-store"
gpg_home="${egress_home}/.gnupg"

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

    # 1. Create system user (idempotent). Home directory is required:
    # the broker uses pass(1) under ${egress_home}/.password-store and
    # gpg-agent in ${egress_home}/.gnupg. nologin shell + system UID
    # range — claude-egress is a service principal, not a login user
    # (DEC-029).
    if id -u "$egress_user" >/dev/null 2>&1; then
        echo "  ✓ user '${egress_user}' already exists (uid=$(id -u "$egress_user"))"
        # Migrate an existing pre-broker provisioning (home was /nonexistent
        # in earlier ciw.1 deployments) to the new home location. usermod is
        # a no-op when the home already matches.
        current_home="$(getent passwd "$egress_user" | cut -d: -f6)"
        if [ "$current_home" != "$egress_home" ]; then
            usermod --home "$egress_home" "$egress_user"
            echo "  ✓ migrated home: ${current_home} -> ${egress_home}"
        fi
    else
        useradd \
            --system \
            --home-dir "$egress_home" \
            --no-create-home \
            --shell /usr/sbin/nologin \
            --comment "Claude Code egress mediation principal (DEC-013, DEC-029)" \
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

    # 3. Scaffold the broker's home + pass + GPG dirs (ciw.2). Empty
    # dirs only — the GPG key and pass store contents must be created
    # interactively by the operator because they require passphrase
    # entry.
    install -d -m 0700 -o "$egress_user" -g "$egress_user" "$egress_home"
    echo "  ✓ ${egress_home}/ (0700 ${egress_user}:${egress_user})"

    install -d -m 0700 -o "$egress_user" -g "$egress_user" "$pass_store"
    echo "  ✓ ${pass_store}/ (0700 ${egress_user}:${egress_user})"

    install -d -m 0700 -o "$egress_user" -g "$egress_user" "$gpg_home"
    echo "  ✓ ${gpg_home}/ (0700 ${egress_user}:${egress_user})"

    echo ""
    echo "✓ Provisioning complete."
    echo ""
    echo "Next steps (operator, interactive):"
    echo ""
    echo "  1. Generate a GPG key for ${egress_user} (passphrase required):"
    echo "       sudo -u ${egress_user} -H gpg --homedir ${gpg_home} --generate-key"
    echo "     Note the key id printed at the end."
    echo ""
    echo "  2. Initialize pass(1) against that key:"
    echo "       sudo -u ${egress_user} -H \\"
    echo "         env GNUPGHOME=${gpg_home} PASSWORD_STORE_DIR=${pass_store} \\"
    echo "         pass init <gpg-key-id>"
    echo ""
    echo "  3. Insert each credential the broker policy references. For the"
    echo "     anthropic-api alias shipped with claude-config:"
    echo "       sudo -u ${egress_user} -H \\"
    echo "         env GNUPGHOME=${gpg_home} PASSWORD_STORE_DIR=${pass_store} \\"
    echo "         pass insert claude-egress/anthropic/api-key"
    echo ""
    echo "  4. Install policy files (samples ship under sandbox/egress-policy/):"
    echo "       sudo install -m 0640 -o root -g ${egress_user} \\"
    echo "         <repo>/sandbox/egress-policy/<alias>.yaml \\"
    echo "         ${policy_dir}/<alias>.yaml"
    echo ""
    echo "  5. After ciw.2 broker is built, enable the systemd units (created"
    echo "     in slice 5 of ciw.2)."
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
        # Operator opt-in to destroy policy + credential files + GPG/pass store.
        for d in "$policy_dir" "$creds_dir" "$egress_home"; do
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
        if [ -d "$policy_dir" ] || [ -d "$creds_dir" ] || [ -d "$egress_home" ]; then
            echo "  • policy/credential dirs and ${egress_home}/ preserved"
            echo "    (operator data including GPG keys and pass store);"
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
