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

    # 3b. Install gpg-agent.conf so the agent accepts preset passphrases
    # from the coordinator-side primer (ClaudeConfig-bd5). The conf
    # source-of-truth lives in the repo at sandbox/etc/gpg-agent.conf;
    # find it relative to this script.
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    gpg_agent_conf_src="${script_dir%/scripts}/etc/gpg-agent.conf"
    if [ -f "$gpg_agent_conf_src" ]; then
        install -m 0600 -o "$egress_user" -g "$egress_user" \
            "$gpg_agent_conf_src" "${gpg_home}/gpg-agent.conf"
        echo "  ✓ ${gpg_home}/gpg-agent.conf (0600 ${egress_user}:${egress_user})"
    else
        echo "  ! gpg-agent.conf source not found at ${gpg_agent_conf_src}; skipping" >&2
    fi

    echo ""
    echo "✓ Provisioning complete."
    echo ""
    echo "Next steps (operator, interactive):"
    echo ""
    echo "  1. Generate a 4096-bit RSA GPG key for ${egress_user}."
    echo ""
    echo "     Store the passphrase in your PERSONAL pass store FIRST so it"
    echo "     can be piped into the key-gen command and is on file for the"
    echo "     coordinator-side priming helper (ClaudeConfig-bd5):"
    echo ""
    echo "       pass generate -n claude-config/egress-broker-gpg-passphrase 40"
    echo ""
    echo "     Then generate the key non-interactively (rsa4096, no expiry):"
    echo ""
    echo "       pass show claude-config/egress-broker-gpg-passphrase \\"
    echo "         | sudo -u ${egress_user} -H \\"
    echo "             env GNUPGHOME=${gpg_home} \\"
    echo "             gpg --batch --pinentry-mode loopback \\"
    echo "                 --passphrase-fd 0 \\"
    echo "                 --quick-generate-key \\"
    echo "                   'claude-egress broker <claude-egress@localhost>' \\"
    echo "                   rsa4096 default 0"
    echo ""
    echo "     For an unprotected key (testing only — NOT recommended; breaks"
    echo "     the 2-factor-compromise property the broker design assumes),"
    echo "     substitute --passphrase '' for --passphrase-fd 0 and drop the"
    echo "     pass-show pipe."
    echo ""
    echo "     Capture the key fingerprint for step 2:"
    echo ""
    echo "       sudo -u ${egress_user} -H env GNUPGHOME=${gpg_home} \\"
    echo "         gpg --list-secret-keys --with-colons \\"
    echo "         | awk -F: '/^fpr:/ { print \$10; exit }'"
    echo ""
    echo "     WSL2 pinentry pitfall: if you fall back to an interactive"
    echo "     gpg invocation (no --batch), pinentry-curses errors with"
    echo "     'Inappropriate ioctl for device' under sudo because there is"
    echo "     no controlling TTY. Fixes: export GPG_TTY=\$(tty) before the"
    echo "     sudo, or install pinentry-tty and pin it via"
    echo "     'pinentry-program /usr/bin/pinentry-tty' in"
    echo "     ${gpg_home}/gpg-agent.conf. The --batch + --pinentry-mode"
    echo "     loopback recipe above sidesteps the issue entirely."
    echo ""
    echo "  2. Sign the new claude-egress key with your personal key so"
    echo "     local trust resolves without touching keyservers. Use"
    echo "     --lsign-key (LOCAL signature, non-exportable) — NOT"
    echo "     --sign-key, which would propagate this service key to any"
    echo "     keyserver you later push your personal key to:"
    echo ""
    echo "       sudo -u ${egress_user} -H env GNUPGHOME=${gpg_home} \\"
    echo "         gpg --export <claude-egress-fpr> \\"
    echo "         | gpg --import"
    echo "       gpg --lsign-key <claude-egress-fpr>"
    echo "       gpg --export <claude-egress-fpr> \\"
    echo "         | sudo -u ${egress_user} -H env GNUPGHOME=${gpg_home} \\"
    echo "             gpg --import"
    echo ""
    echo "  3. Initialize pass(1) against the new key:"
    echo "       sudo -u ${egress_user} -H \\"
    echo "         env GNUPGHOME=${gpg_home} PASSWORD_STORE_DIR=${pass_store} \\"
    echo "         pass init <claude-egress-fpr>"
    echo ""
    echo "  4. Insert each credential the broker policy references. For the"
    echo "     anthropic-api alias shipped with claude-config:"
    echo "       sudo -u ${egress_user} -H \\"
    echo "         env GNUPGHOME=${gpg_home} PASSWORD_STORE_DIR=${pass_store} \\"
    echo "         pass insert claude-egress/anthropic/api-key"
    echo ""
    echo "  5. Install policy files (samples ship under sandbox/egress-policy/):"
    echo "       sudo install -m 0640 -o root -g ${egress_user} \\"
    echo "         <repo>/sandbox/egress-policy/<alias>.yaml \\"
    echo "         ${policy_dir}/<alias>.yaml"
    echo ""
    echo "  6. Install the broker binary + helpers + systemd units:"
    echo "       just install-egress-broker"
    echo ""
    echo "  7. Substitute CLAUDE_SESSION_UID in the service unit:"
    echo "       sudo systemctl edit --full claude-egress-broker.service"
    echo "       # replace the literal 'CLAUDE_SESSION_UID' with"
    echo "       # \$(id -u claude-session)"
    echo "       sudo systemctl daemon-reload"
    echo ""
    echo "  8. Prime the agent with the broker key's passphrase. This"
    echo "     fetches the passphrase from your personal pass store and"
    echo "     hands it to claude-egress's gpg-agent; it never lands on"
    echo "     disk. Also creates the sentinel that ExecStartPre will"
    echo "     decrypt as a hot-cache health check:"
    echo "       sudo prime-egress-broker"
    echo ""
    echo "  9. Enable and start the broker:"
    echo "       sudo systemctl enable --now claude-egress-broker.socket"
    echo ""
    echo "     If the broker fails to start with 'sentinel decrypt failed',"
    echo "     re-run prime-egress-broker (the agent cache evaporates"
    echo "     across gpg-agent restarts, not broker restarts). See bd"
    echo "     memory 'claude-egress-broker-passphrase-gap-the-claude-egress'"
    echo "     for the architectural context."
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
