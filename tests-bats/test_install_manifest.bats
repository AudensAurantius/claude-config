#!/usr/bin/env bats
# tests-bats/test_install_manifest.bats — bats smoke test for the
# install manifest script (sandbox/scripts/_install-manifest.sh).
#
# First bats test for the project (DEC-021, DEC-022). The install
# manifest is the canonical source of (src|dst|mode) tuples consumed
# by the justfile's install/uninstall/verify recipes; if its output
# shape changes, all three recipes break, so a regression test here
# pays for itself quickly.

load '/usr/lib/bats/bats-support/load'
load '/usr/lib/bats/bats-assert/load'

setup() {
    REPO_ROOT="$(git rev-parse --show-toplevel)"
    MANIFEST="$REPO_ROOT/sandbox/scripts/_install-manifest.sh"
    # Canonical-ish paths just for the test (any non-empty values work).
    export BIN_DIR="/tmp/test-bin"
    export SHARE_DIR="/tmp/test-share"
    export PROFILE_DIR="/tmp/test-profile"
    export ETC_DIR="/tmp/test-etc"
}

@test "manifest script is executable" {
    assert [ -x "$MANIFEST" ]
}

@test "emits one line per install entry" {
    run "$MANIFEST"
    assert_success
    # Phase 1 install map: 6 entries (wrapper, emitter, profile,
    # managed-settings, ACL script, provision script). Update this
    # count when the manifest grows.
    [ "${#lines[@]}" -eq 6 ]
}

@test "each line has src|dst|mode shape with three pipe-separated fields" {
    run "$MANIFEST"
    assert_success
    for line in "${lines[@]}"; do
        # 3 fields → exactly 2 pipes per line
        pipe_count="$(echo "$line" | tr -cd '|' | wc -c)"
        [ "$pipe_count" -eq 2 ]
    done
}

@test "interpolates BIN_DIR / SHARE_DIR / PROFILE_DIR / ETC_DIR from env" {
    run "$MANIFEST"
    assert_success
    assert_output --partial "$BIN_DIR/claude-sandbox"
    assert_output --partial "$SHARE_DIR/scripts/provision-claude-session.sh"
    assert_output --partial "$PROFILE_DIR/default.yaml"
    assert_output --partial "$ETC_DIR/managed-settings.json"
}

@test "fails loudly when required env vars are unset" {
    unset BIN_DIR
    run "$MANIFEST"
    assert_failure
    assert_output --partial "BIN_DIR not set"
}
