#!/usr/bin/env bash
# share-credential.sh — escape-hatch for sharing a user-owned credential
# with the claude-session sandbox user (DEC-010).
#
# Default mechanism (option a): static copy with chown + chmod 600 and
# optional GPG encryption-at-rest. Use this when the upstream service does
# not support separate principals (e.g. API tokens are user-bound).
#
# Every credential shared via this script is still tier-1 per DEC-008 and
# requires its own DECISION_LOG entry justifying why a separate principal at
# the upstream service is not feasible.
#
# Usage:
#   share-credential.sh <source-path> <target-relative-path> [--encrypt]
#                       [--sandbox-user NAME] [--sandbox-home PATH]
#                       [--dry-run] [-h|--help]
#
# Arguments:
#   <source-path>           absolute or ~ path to the credential on hactar's fs
#   <target-relative-path>  path relative to claude-session's home where the
#                           credential should be placed (e.g. ".config/jira-token")
#
# Options:
#   --encrypt           GPG-encrypt the copy to claude-session's public key;
#                       writes <target>.gpg and removes the plaintext copy.
#                       Requires claude-session to have a GPG key in its
#                       keyring (see SCHEMA.md for key setup guidance).
#   --sandbox-user NAME sandbox user to own the copy (default: claude-session)
#   --sandbox-home PATH override sandbox home dir (default: ~<sandbox-user>)
#   --dry-run           print what would happen without doing it
#   -h, --help          show this help
#
# Exit codes:
#   0  success
#   1  usage error
#   2  source file not found or not readable
#   3  target directory creation failed
#   4  copy failed
#   5  chown/chmod failed
#   6  GPG encryption failed (plaintext copy preserved for retry)
#
# Cross-references:
#   DEC-008  tiered credential policy
#   DEC-010  escape-hatch mechanism (this script's design record)
#   DEC-032  escape-hatch policy formalization

set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────────────────────

sandbox_user="claude-session"
sandbox_home=""
encrypt=false
dry_run=false
source_path=""
target_rel=""

# ── Argument parsing ──────────────────────────────────────────────────────────

usage() {
    cat <<'EOF'
Usage:
  share-credential.sh <source-path> <target-relative-path> [--encrypt]
                      [--sandbox-user NAME] [--sandbox-home PATH]
                      [--dry-run] [-h|--help]

Arguments:
  <source-path>           absolute or ~ path to the credential on hactar's fs
  <target-relative-path>  path relative to claude-session's home where the
                          credential should be placed (e.g. ".config/jira-token")

Options:
  --encrypt           GPG-encrypt the copy to claude-session's public key;
                      writes <target>.gpg and removes the plaintext copy.
                      Requires claude-session to have a GPG key in its
                      keyring (see SCHEMA.md for key setup guidance).
  --sandbox-user NAME sandbox user to own the copy (default: claude-session)
  --sandbox-home PATH override sandbox home dir (default: ~<sandbox-user>)
  --dry-run           print what would happen without doing it
  -h, --help          show this help

Exit codes:
  0  success
  1  usage error
  2  source file not found or not readable
  3  target directory creation failed
  4  copy failed
  5  chown/chmod failed
  6  GPG encryption failed (plaintext copy preserved for retry)
EOF
}

positional=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --encrypt)
            encrypt=true
            shift
            ;;
        --sandbox-user)
            sandbox_user="$2"
            shift 2
            ;;
        --sandbox-home)
            sandbox_home="$2"
            shift 2
            ;;
        --dry-run)
            dry_run=true
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        -*)
            echo "share-credential: unknown option: $1" >&2
            exit 1
            ;;
        *)
            positional+=("$1")
            shift
            ;;
    esac
done

if [[ ${#positional[@]} -lt 2 ]]; then
    echo "share-credential: error: missing required arguments" >&2
    echo "" >&2
    usage >&2
    exit 1
fi

if [[ ${#positional[@]} -gt 2 ]]; then
    echo "share-credential: error: unexpected extra arguments: ${positional[*]:2}" >&2
    exit 1
fi

source_path="${positional[0]}"
target_rel="${positional[1]}"

# Expand ~ in source path
source_path="${source_path/#\~/$HOME}"

# ── Resolve sandbox home ──────────────────────────────────────────────────────

if [[ -z "$sandbox_home" ]]; then
    if ! sandbox_home="$(getent passwd "$sandbox_user" 2>/dev/null | cut -d: -f6)"; then
        echo "share-credential: error: cannot resolve home for user '$sandbox_user'" >&2
        exit 1
    fi
    if [[ -z "$sandbox_home" ]]; then
        echo "share-credential: error: user '$sandbox_user' not found in passwd" >&2
        exit 1
    fi
fi

target_path="${sandbox_home}/${target_rel#/}"

# ── Validate source ───────────────────────────────────────────────────────────

if [[ ! -e "$source_path" ]]; then
    echo "share-credential: error: source not found: $source_path" >&2
    exit 2
fi

if [[ ! -r "$source_path" ]]; then
    echo "share-credential: error: source not readable: $source_path" >&2
    exit 2
fi

if [[ ! -f "$source_path" ]]; then
    echo "share-credential: error: source must be a regular file: $source_path" >&2
    exit 2
fi

# ── Sanity-check: refuse to overwrite without warning ────────────────────────

if [[ -e "$target_path" ]] && ! $dry_run; then
    echo "share-credential: warning: target already exists: $target_path" >&2
    echo "share-credential: overwriting..." >&2
fi

if [[ -e "${target_path}.gpg" ]] && $encrypt && ! $dry_run; then
    echo "share-credential: warning: encrypted target already exists: ${target_path}.gpg" >&2
    echo "share-credential: overwriting..." >&2
fi

# ── Dry-run summary ───────────────────────────────────────────────────────────

if $dry_run; then
    echo "[dry-run] source:       $source_path"
    echo "[dry-run] sandbox user: $sandbox_user"
    echo "[dry-run] sandbox home: $sandbox_home"
    if $encrypt; then
        echo "[dry-run] target (gpg): ${target_path}.gpg"
        echo "[dry-run] steps: mkdir -p parent; cp; chown; chmod 600; gpg --encrypt; rm plaintext"
    else
        echo "[dry-run] target:       $target_path"
        echo "[dry-run] steps: mkdir -p parent; cp; chown; chmod 600"
    fi
    exit 0
fi

# ── Create target parent directory ───────────────────────────────────────────

target_dir="$(dirname "$target_path")"

if ! mkdir -p "$target_dir"; then
    echo "share-credential: error: could not create target directory: $target_dir" >&2
    exit 3
fi

# ── Copy ──────────────────────────────────────────────────────────────────────

if ! cp -- "$source_path" "$target_path"; then
    echo "share-credential: error: copy failed: $source_path -> $target_path" >&2
    exit 4
fi

# ── chown + chmod ─────────────────────────────────────────────────────────────

if ! chown "${sandbox_user}:${sandbox_user}" "$target_path"; then
    echo "share-credential: error: chown failed on $target_path" >&2
    rm -f "$target_path"
    exit 5
fi

if ! chmod 600 "$target_path"; then
    echo "share-credential: error: chmod failed on $target_path" >&2
    rm -f "$target_path"
    exit 5
fi

# ── Optional GPG encryption ───────────────────────────────────────────────────

if $encrypt; then
    # Resolve the sandbox user's GPG key. We look for a key with a UID
    # matching the sandbox username. Requires gpg to be available and
    # claude-session's keyring to contain a suitable public key.
    gpg_key=""
    if ! gpg_key="$(sudo -u "$sandbox_user" gpg --list-keys --with-colons 2>/dev/null |
        awk -F: '/^uid/ && /'"$sandbox_user"'/ { found=1 }
                  /^fpr/ && found { print $10; found=0; exit }')"; then
        echo "share-credential: error: could not query gpg keyring for $sandbox_user" >&2
        echo "share-credential: plaintext copy at $target_path is preserved" >&2
        exit 6
    fi

    if [[ -z "$gpg_key" ]]; then
        echo "share-credential: error: no GPG key found for $sandbox_user" >&2
        echo "share-credential: ensure claude-session has a GPG key with a UID containing '$sandbox_user'" >&2
        echo "share-credential: plaintext copy at $target_path is preserved" >&2
        exit 6
    fi

    encrypted_path="${target_path}.gpg"

    # Run gpg as sandbox_user so the result is in their keyring context
    if ! sudo -u "$sandbox_user" gpg \
        --yes \
        --output "$encrypted_path" \
        --recipient "$gpg_key" \
        --encrypt \
        "$target_path" 2>/dev/null; then
        echo "share-credential: error: GPG encryption failed" >&2
        echo "share-credential: plaintext copy at $target_path is preserved; $encrypted_path may be partial" >&2
        rm -f "$encrypted_path"
        exit 6
    fi

    chown "${sandbox_user}:${sandbox_user}" "$encrypted_path"
    chmod 600 "$encrypted_path"

    # Remove plaintext copy — the encrypted file is the canonical artifact
    rm -f "$target_path"

    echo "share-credential: ok — credential encrypted at $encrypted_path (owner: $sandbox_user, mode: 600)"
else
    echo "share-credential: ok — credential copied to $target_path (owner: $sandbox_user, mode: 600)"
fi
