#!/usr/bin/env bash
# claude-egress-broker-healthcheck.sh — ExecStartPre sentinel-decrypt
# health check (ClaudeConfig-bd5, hardening Slice B).
#
# Runs as claude-egress under the systemd unit's environment
# (GNUPGHOME, PASSWORD_STORE_DIR already set by the unit). Decrypts the
# sentinel ciphertext seeded by prime-egress-broker.sh. Exit 0 if the
# agent cache holds the passphrase, non-zero otherwise. Non-zero causes
# systemd to refuse to start the broker — better than the broker coming
# up and serving 500s on every request because gpg-agent prompts (and
# fails) for a pinentry that doesn't exist.

set -euo pipefail

sentinel="${GNUPGHOME:-/home/claude-egress/.gnupg}/sentinel.gpg"
marker="claude-egress-broker-sentinel-ok"

if [ ! -s "$sentinel" ]; then
    echo "egress-broker-healthcheck: sentinel missing at ${sentinel}." >&2
    echo "  Run prime-egress-broker on the coordinator host first." >&2
    exit 1
fi

if ! gpg --batch --quiet --decrypt "$sentinel" 2>/dev/null | grep -q "$marker"; then
    echo "egress-broker-healthcheck: sentinel decrypt failed — gpg-agent cache is cold." >&2
    echo "  Run prime-egress-broker on the coordinator host." >&2
    exit 1
fi
