#!/usr/bin/env bash
# prime-egress-broker.sh — coordinator-side helper that primes the
# claude-egress gpg-agent with the broker GPG key's passphrase
# (ClaudeConfig-bd5, hardening Slice B).
#
# The broker's GPG key is passphrase-protected; the systemd service
# runs as claude-egress under containment that excludes TTY, pinentry,
# and the operator's pass store. This helper bridges the gap: it
# fetches the passphrase from the operator's PERSONAL pass store and
# hands it to claude-egress's gpg-agent via gpg-preset-passphrase,
# which keeps it cached in-memory for the lifetime of the agent.
#
# After priming, start (or restart) claude-egress-broker.service.
# Restarting the broker does NOT evaporate the agent cache — gpg-agent
# is its own user service. To force re-prime, restart gpg-agent:
#   sudo -u claude-egress -H env GNUPGHOME=/home/claude-egress/.gnupg \
#     gpgconf --kill gpg-agent
#
# First-run side effect: creates a sentinel ciphertext at
# ${GNUPGHOME}/sentinel.gpg, encrypted to the claude-egress key. The
# broker's ExecStartPre health-check decrypts this file to confirm
# the agent cache is hot; if it cannot, systemd refuses to start the
# broker (better than serving 500s on every request).
#
# Trust model: the operator's personal GPG key (via pass) AND a
# filesystem snapshot of /home/claude-egress are both required to
# recover broker credentials at rest. Compromising either alone is
# insufficient. See docs/architecture/egress-broker-threat-model.md
# (forthcoming, ClaudeConfig-7wi).
#
# Usage: prime-egress-broker [--user NAME] [--pass-entry PATH]
#                            [--gnupghome DIR] [-h|--help]
#
# Defaults:
#   --user        claude-egress
#   --pass-entry  claude-config/egress-broker-gpg-passphrase
#   --gnupghome   /home/<user>/.gnupg
#
# Requires sudo. Re-execs itself under sudo if invoked unprivileged
# so the operator's pass store still resolves (sudo -E preserves
# PASSWORD_STORE_DIR if set).

set -euo pipefail

# ── Defaults / argument parsing ─────────────────────────────────────────────

egress_user="claude-egress"
pass_entry="claude-config/egress-broker-gpg-passphrase"
gnupghome=""
sentinel_marker="claude-egress-broker-sentinel-ok"

usage() {
    sed -n '/^# prime-egress-broker.sh/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        -h | --help)
            usage
            exit 0
            ;;
        --user)
            egress_user="$2"
            shift 2
            ;;
        --pass-entry)
            pass_entry="$2"
            shift 2
            ;;
        --gnupghome)
            gnupghome="$2"
            shift 2
            ;;
        *)
            echo "prime-egress-broker: unknown arg: $1" >&2
            exit 1
            ;;
    esac
done

[ -z "$gnupghome" ] && gnupghome="/home/${egress_user}/.gnupg"
sentinel_path="${gnupghome}/sentinel.gpg"

# ── Pre-flight ──────────────────────────────────────────────────────────────

preset_bin=""
for candidate in /usr/lib/gnupg/gpg-preset-passphrase \
    /usr/lib/gnupg2/gpg-preset-passphrase \
    /usr/libexec/gpg-preset-passphrase; do
    if [ -x "$candidate" ]; then
        preset_bin="$candidate"
        break
    fi
done

if [ -z "$preset_bin" ]; then
    echo "prime-egress-broker: gpg-preset-passphrase not found in /usr/lib/gnupg{,2}/ or /usr/libexec/." >&2
    echo "  Install the GnuPG tools package providing it (Debian/Ubuntu: gnupg)." >&2
    exit 1
fi

if ! id -u "$egress_user" >/dev/null 2>&1; then
    echo "prime-egress-broker: user '${egress_user}' does not exist — run 'just provision-egress' first." >&2
    exit 1
fi

if ! command -v pass >/dev/null 2>&1; then
    echo "prime-egress-broker: pass(1) not installed on the coordinator host." >&2
    exit 1
fi

# ── Resolve keygrip (claude-egress side) ────────────────────────────────────
#
# Use the PRIMARY secret key's keygrip. The broker only decrypts to the
# primary; if the operator later adds encryption subkeys, this needs
# revisiting. (Realistic for now: --quick-generate-key rsa4096 produces
# one primary used for both sign and encrypt.)

keygrip="$(
    sudo -u "$egress_user" -H \
        env GNUPGHOME="$gnupghome" \
        gpg --list-secret-keys --with-keygrip --with-colons 2>/dev/null |
        awk -F: '/^grp:/ { print $10; exit }'
)"

if [ -z "$keygrip" ]; then
    echo "prime-egress-broker: no secret key found in ${gnupghome}." >&2
    echo "  Generate the broker key first (see provision-claude-egress.sh's next-steps output)." >&2
    exit 1
fi

# ── Prime the agent ─────────────────────────────────────────────────────────
#
# pass-show runs as the invoking operator; gpg-preset-passphrase runs
# as claude-egress and writes to claude-egress's gpg-agent socket. The
# passphrase never lands on disk.
#
# Hold this in a variable so we can reuse it for sentinel-creation
# below without re-prompting the operator's personal key.

passphrase="$(pass show "$pass_entry")"
if [ -z "$passphrase" ]; then
    echo "prime-egress-broker: pass entry '${pass_entry}' is empty." >&2
    exit 1
fi

printf '%s' "$passphrase" |
    sudo -u "$egress_user" -H \
        env GNUPGHOME="$gnupghome" \
        "$preset_bin" --preset "$keygrip"

echo "  ✓ primed gpg-agent for keygrip ${keygrip:0:16}…"

# ── Ensure sentinel exists ──────────────────────────────────────────────────
#
# Encrypt a small marker string to the claude-egress key. The broker's
# ExecStartPre will decrypt this on every start to verify the agent
# cache is hot. The sentinel is owned by claude-egress, mode 0600.

if ! sudo -u "$egress_user" test -s "$sentinel_path"; then
    fpr="$(
        sudo -u "$egress_user" -H \
            env GNUPGHOME="$gnupghome" \
            gpg --list-secret-keys --with-colons 2>/dev/null |
            awk -F: '/^fpr:/ { print $10; exit }'
    )"

    if [ -z "$fpr" ]; then
        echo "prime-egress-broker: could not resolve fingerprint for sentinel encryption." >&2
        exit 1
    fi

    printf '%s\n' "$sentinel_marker" |
        sudo -u "$egress_user" -H \
            env GNUPGHOME="$gnupghome" \
            gpg --batch --yes --quiet \
            --trust-model always \
            --recipient "$fpr" \
            --output "$sentinel_path" \
            --encrypt

    sudo chmod 0600 "$sentinel_path"
    sudo chown "${egress_user}:${egress_user}" "$sentinel_path"
    echo "  ✓ created sentinel: ${sentinel_path}"
fi

# ── Verify by decrypting the sentinel ───────────────────────────────────────
#
# If priming was successful, the decrypt below succeeds with no
# pinentry call. If it fails, the agent is cold (or the passphrase
# was wrong, or the cache TTL expired); systemd's ExecStartPre will
# fail at boot too, so surface that here.

if ! sudo -u "$egress_user" -H \
    env GNUPGHOME="$gnupghome" \
    gpg --batch --quiet --decrypt "$sentinel_path" 2>/dev/null |
    grep -q "$sentinel_marker"; then
    echo "prime-egress-broker: sentinel decrypt FAILED — the agent did not accept the passphrase." >&2
    echo "  Check that pass entry '${pass_entry}' matches the key's actual passphrase." >&2
    exit 1
fi

echo "  ✓ sentinel decrypt confirmed; broker may now be started"
echo ""
echo "Next: sudo systemctl restart claude-egress-broker.service"
