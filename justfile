# claude-config development + install orchestrator (DEC-021).
#
# Polyglot quality gates and the Phase 1 install map live here.
# Recipes call into per-language native tooling (uv for Python,
# shellcheck for Bash, bats/busted later for tests) — there's no
# wrapper/translator layer, the orchestration is just `just`.
#
# Common usage:
#   just                       # list recipes (default)
#   just sync                  # uv sync the dev .venv
#   just check                 # run all quality gates (lint + tests + …)
#   just install               # deploy Phase 1 to canonical host paths
#   just provision             # create claude-session user + ACLs (sudo)
#   just smoke                 # run sandbox/scripts/smoke-test.sh

# ── Variables (override on the command line: `just PREFIX=/tmp install`) ──

prefix      := env_var_or_default("PREFIX",      "/usr/local")
user_config := env_var_or_default("USER_CONFIG", env_var("HOME") + "/.config")
bin_dir     := env_var_or_default("BIN_DIR",     prefix + "/bin")
share_dir   := env_var_or_default("SHARE_DIR",   prefix + "/share/claude-sandbox")
profile_dir := env_var_or_default("PROFILE_DIR", user_config + "/claude-sandbox/profiles")
etc_dir     := env_var_or_default("ETC_DIR",     "/etc/claude-code")

# The install map lives in sandbox/scripts/_install-manifest.sh and reads
# BIN_DIR / SHARE_DIR / PROFILE_DIR / ETC_DIR from its environment.
# Variables are passed explicitly on each manifest invocation (not via
# Just's top-level `export`) so that `install-test`'s recursive
# `PREFIX=… just install` call cleanly overrides — top-level exports
# would leak the outer shell's stale values into the child recipe.

# ── Default: show the recipe catalog ──

default:
    @just --list

# ── Python (DEC-019: uv-managed project) ──

# Sync the dev .venv (creates if missing)
sync:
    uv sync

# Lint Python (ruff + mypy)
lint:
    uv run ruff check
    uv run mypy

# Auto-fix ruff issues
fix:
    uv run ruff check --fix

# Format Python
fmt:
    uv run ruff format

# Check Python formatting without modifying
fmt-check:
    uv run ruff format --check

# Build wheel + sdist
build:
    uv build

# ── Bash (DEC-022: shellcheck static analysis) ──

# shellcheck all bash scripts in the project
shellcheck:
    @find sandbox -name '*.sh' -print0 | xargs -0 shellcheck

# ── Tests (DEC-022: per-language native frameworks, orchestrated here) ──

# Run all native-framework tests: pytest (Python, tests/) +
# bats (Bash, tests-bats/). Args pass through to pytest only — bats
# discovers everything under tests-bats/ unconditionally. Lua/busted
# tests join when the first Lua hook lands (see tests-lua/README).
test *args:
    #!/usr/bin/env bash
    set -uo pipefail
    echo "── pytest ──"
    uv run pytest {{args}}; py_rc=$?
    echo
    echo "── bats ──"
    bats tests-bats/; bats_rc=$?
    if [ "$py_rc" -ne 0 ] || [ "$bats_rc" -ne 0 ]; then
        exit 1
    fi

# Run the Phase 1 wrapper smoke test (composed + standalone modes)
smoke:
    sandbox/scripts/smoke-test.sh

# ── Composite quality gate ──

# Run all language quality gates (ruff + mypy + ruff-format + shellcheck + pytest)
check: lint fmt-check shellcheck test

# ── Install map (ported from Makefile per DEC-021) ──
#
# The canonical list of (src, dst, mode) tuples lives in
# sandbox/scripts/_install-manifest.sh; install/uninstall/verify all
# consume it via env-var-driven invocation. Just doesn't have Make's
# implicit mtime-tracked file-target dep model, so these recipes always
# redeploy — which is fine for the ~6-file install map.

# Install Phase 1 components to the configured host paths
install:
    #!/usr/bin/env bash
    set -euo pipefail
    while IFS='|' read -r src dst mode; do
        install -d -m 0755 "$(dirname "$dst")"
        install -m "0${mode}" "$src" "$dst"
    done < <(BIN_DIR='{{bin_dir}}' SHARE_DIR='{{share_dir}}' PROFILE_DIR='{{profile_dir}}' ETC_DIR='{{etc_dir}}' sandbox/scripts/_install-manifest.sh)
    echo ""
    echo "✓ claude-config Phase 1 installed."
    echo "  Wrapper:    {{bin_dir}}/claude-sandbox"
    echo "  Profile:    {{profile_dir}}/default.yaml"
    echo "  ACL script: {{share_dir}}/scripts/setup-claude-session-acls.sh"
    echo "  Provision:  {{share_dir}}/scripts/provision-claude-session.sh"
    echo ""
    echo "Next steps:"
    echo "  1. just provision     — create the claude-session user + ACLs (sudo)"
    echo "  2. claude-sandbox --oauth — one-time Anthropic OAuth bootstrap"

# Test install to /tmp/claude-sandbox-test (non-destructive). Mirrors the
# Makefile's `install-test` target via env-var overrides.
install-test:
    PREFIX=/tmp/claude-sandbox-test \
        USER_CONFIG=/tmp/claude-sandbox-test/config \
        ETC_DIR=/tmp/claude-sandbox-test/etc/claude-code \
        just install
    @echo ""
    @echo "Test artifacts under /tmp/claude-sandbox-test/. Inspect with:"
    @echo "  find /tmp/claude-sandbox-test -type f"

# Uninstall the Phase 1 components (does NOT unprovision claude-session)
uninstall:
    #!/usr/bin/env bash
    set -euo pipefail
    while IFS='|' read -r src dst mode; do
        if [ -e "$dst" ]; then
            echo "  rm $dst"
            rm -f "$dst"
        fi
    done < <(BIN_DIR='{{bin_dir}}' SHARE_DIR='{{share_dir}}' PROFILE_DIR='{{profile_dir}}' ETC_DIR='{{etc_dir}}' sandbox/scripts/_install-manifest.sh)
    echo "✓ Uninstalled. (Empty parent dirs not removed.)"

# Provision claude-session (system user + subuid + ACLs; sudo-mediated)
provision:
    @echo "Provisioning claude-session (will prompt for sudo) ..."
    {{share_dir}}/scripts/provision-claude-session.sh \
        --acl-script {{share_dir}}/scripts/setup-claude-session-acls.sh

# Reverse `just provision`
unprovision:
    @echo "Un-provisioning claude-session (will prompt for sudo) ..."
    {{share_dir}}/scripts/provision-claude-session.sh --uninstall \
        --acl-script {{share_dir}}/scripts/setup-claude-session-acls.sh

# Verify installed files + wrapper version
verify:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Verifying claude-config Phase 1 install ..."
    while IFS='|' read -r src dst mode; do
        if [ -e "$dst" ]; then
            echo "  ✓ present: $dst"
        else
            echo "  ✗ MISSING: $dst"
        fi
    done < <(BIN_DIR='{{bin_dir}}' SHARE_DIR='{{share_dir}}' PROFILE_DIR='{{profile_dir}}' ETC_DIR='{{etc_dir}}' sandbox/scripts/_install-manifest.sh)
    if [ -x "{{bin_dir}}/claude-sandbox" ]; then
        echo ""
        echo "Wrapper version:"
        "{{bin_dir}}/claude-sandbox" --version 2>&1 | sed 's/^/  /'
    fi
