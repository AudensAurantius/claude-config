#!/usr/bin/env bash
# _install-manifest.sh — emit the Phase 1 install map as "src|dst|mode"
# lines on stdout. Sourced by the Justfile (DEC-021) for install /
# uninstall / verify recipes; canonical source of truth for what the
# deployment touches.
#
# Reads installation paths from environment variables set by the
# Justfile (or overridden on the command line):
#   BIN_DIR      — wrapper + emitter destination
#   PROFILE_DIR  — sandbox profile destination
#   SHARE_DIR    — supporting scripts destination
#   ETC_DIR      — system-wide managed-settings destination
set -euo pipefail

: "${BIN_DIR:?BIN_DIR not set}"
: "${PROFILE_DIR:?PROFILE_DIR not set}"
: "${SHARE_DIR:?SHARE_DIR not set}"
: "${ETC_DIR:?ETC_DIR not set}"

cat <<EOF
sandbox/bin/claude-sandbox|${BIN_DIR}/claude-sandbox|755
sandbox/bin/claude-sandbox-emit-srt-settings|${BIN_DIR}/claude-sandbox-emit-srt-settings|755
sandbox/profiles/default.yaml|${PROFILE_DIR}/default.yaml|644
claude/settings/managed-settings.json|${ETC_DIR}/managed-settings.json|644
sandbox/scripts/setup-claude-session-acls.sh|${SHARE_DIR}/scripts/setup-claude-session-acls.sh|755
sandbox/scripts/provision-claude-session.sh|${SHARE_DIR}/scripts/provision-claude-session.sh|755
EOF
