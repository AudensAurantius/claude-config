# claude-config — root justfile (DEC-021; ClaudeConfig-zdk).
#
# The root file owns: cross-cutting quality gates (lint, fmt, test,
# check); top-level orchestration (`just install`, `just verify` as
# deps on per-domain recipes); language-toolchain setup (dev-tools,
# sync). Per-domain install + provision + smoke + per-domain verify
# recipes live in their respective sub-justfiles, imported flat below.
#
# First-time setup (after clone):
#   mise install               # provision host-side tools per mise.toml
#                              # (Python, Go, LuaJIT, stylua, shfmt,
#                              #  lua-language-server, shellcheck, cue,
#                              #  bats; seeds .luarocks/ with lyaml +
#                              #  lua-cjson + busted)
#
# Common usage:
#   just                       # list recipes
#   just sync                  # uv sync the dev .venv
#   just check                 # all quality gates (lint + fmt + test + …)
#   just install               # deploy all domains to canonical host paths
#   just install-test          # deploy to /tmp/claude-sandbox-test (no real deploy)
#   just provision             # create claude-session user + ACLs (sudo)
#   just smoke                 # sandbox/scripts/smoke-test.sh
#
# Per-domain sub-justfiles:
#   sandbox/justfile             — wrapper, profile, provisioning, smoke
#   claude/scripts/hooks/justfile — Lua hooks + their config

# ── Variables (override on the command line: `just PREFIX=/tmp install`) ──

prefix      := env_var_or_default("PREFIX",      "/usr/local")
user_config := env_var_or_default("USER_CONFIG", env_var("HOME") + "/.config")
bin_dir     := env_var_or_default("BIN_DIR",     prefix + "/bin")
share_dir   := env_var_or_default("SHARE_DIR",   prefix + "/share/claude-sandbox")
profile_dir := env_var_or_default("PROFILE_DIR", user_config + "/claude-sandbox/profiles")
etc_dir     := env_var_or_default("ETC_DIR",     "/etc/claude-code")

# ── Imports (flat-merge of per-domain sub-justfiles) ──

import 'sandbox/justfile'
import 'claude/scripts/hooks/justfile'
import 'claude/scripts/git-hooks/justfile'

# ── Default: show the recipe catalog ──

default:
    @just --list

# ── Python (DEC-019: uv-managed project) ──

# Sync the dev .venv (creates if missing)
sync:
    uv sync

# Host-side dev tools are managed by mise (mise.toml). On first clone,
# run `mise install` to provision stylua, shfmt, lua-language-server,
# etc. The install-dev-tools.sh script is retained for claude-session
# provisioning only (sandbox/scripts/provision-claude-session.sh
# step 7b) — host devs should not invoke it directly.

# Lint Python (ruff + mypy)
lint:
    uv run ruff check
    uv run mypy

# Auto-fix ruff issues
fix:
    uv run ruff check --fix

# Format all languages: Python (ruff) + Lua (stylua) + Bash (shfmt).
fmt:
    uv run ruff format
    stylua claude/scripts/hooks
    shfmt -w -i 4 -ci sandbox/bin sandbox/scripts

# Check formatting without modifying.
fmt-check:
    uv run ruff format --check
    stylua --check claude/scripts/hooks
    shfmt -d -i 4 -ci sandbox/bin sandbox/scripts

# Strict-mode Lua static type-checking via lua-language-server, plus
# the LuaCATS annotation gate (ClaudeConfig-nun / F-fmt2: every public
# M.* in the hook + lib set must carry a doc-block with at least one
# `@param`/`@return`/`@class`/`@field`/`@alias`/`@type` tag).
lua-check:
    #!/usr/bin/env bash
    set -euo pipefail
    out="$(mktemp -d)"
    trap 'rm -rf "$out"' EXIT
    lua-language-server --check claude/scripts/hooks --checklevel=Warning --logpath="$out" --configpath="$(pwd)/.luarc.json"
    diag="$out/check.json"
    if [ ! -s "$diag" ] || [ "$(jq -r '. | length' "$diag" 2>/dev/null || echo 0)" -eq 0 ]; then
        echo "(no Lua diagnostics)"
    else
        cat "$diag"
        exit 1
    fi
    python3 sandbox/scripts/check-lua-annotations.py

# Build wheel + sdist
build:
    uv build

# ── Bash (DEC-022: shellcheck static analysis) ──

# shellcheck all bash scripts in the project
shellcheck:
    @find sandbox -name '*.sh' -print0 | xargs -0 shellcheck

# ── Tests (DEC-022: per-language native frameworks; F-test1 will
#    colocate tests into per-domain trees) ──

# Aggregate per-language unit tests: pytest (Python; root tests/ is
# reserved for true integration tests, currently only one smoke case)
# + per-domain busted/bats via sub-justfile recipes. F-test1 (ew7)
# colocated Lua tests under claude/scripts/hooks/tests/; sandbox bats
# tests join as each install/smoke recipe gets behavioral coverage.
test *args:
    #!/usr/bin/env bash
    set -uo pipefail
    echo "── pytest (root tests/) ──"
    uv run pytest {{args}}; py_rc=$?
    echo
    echo "── busted (hook domain) ──"
    just test-hooks; bu_rc=$?
    if [ "$py_rc" -ne 0 ] || [ "$bu_rc" -ne 0 ]; then
        exit 1
    fi

# ── Composite quality gate ──

# Run all language quality gates (ruff + mypy + ruff-format + stylua-check
# + shfmt-check + shellcheck + lua-language-server --check + pytest + bats
# + busted)
check: lint fmt-check shellcheck lua-check test

# ── Pre-commit hooks (ClaudeConfig-2s3.4) ──

# Run all pre-commit hooks against every tracked file
pre-commit-run:
    uv run pre-commit run --all-files

# ── Top-level install / uninstall / verify (delegate to per-domain) ──

# Install all domains to the configured host paths
install: install-sandbox install-hooks install-git-hooks
    @echo ""
    @echo "✓ claude-config installed."
    @echo ""
    @echo "Next steps:"
    @echo "  1. just provision           — create the claude-session user + ACLs (sudo)"
    @echo "  2. claude-sandbox --oauth   — one-time Anthropic OAuth bootstrap"

# Reverse `just install` (does NOT unprovision)
uninstall: uninstall-sandbox uninstall-hooks uninstall-git-hooks
    @echo "✓ claude-config uninstalled. (Empty parent dirs not removed.)"

# Test install to /tmp/claude-sandbox-test (non-destructive).
install-test:
    PREFIX=/tmp/claude-sandbox-test \
        USER_CONFIG=/tmp/claude-sandbox-test/config \
        ETC_DIR=/tmp/claude-sandbox-test/etc/claude-code \
        just install
    @echo ""
    @echo "Test artifacts under /tmp/claude-sandbox-test/. Inspect with:"
    @echo "  find /tmp/claude-sandbox-test -type f"

# Verify all installed files across domains
verify: verify-sandbox verify-hooks verify-git-hooks

# Build all manpages (ClaudeConfig-4g0). Per-domain `build-man-<slug>`
# recipes do the actual scdoc invocation; this aggregates.
build-man: build-man-sandbox

# Install all manpages to ${PREFIX}/share/man/.
install-man: install-man-sandbox

# Uninstall all manpages.
uninstall-man: uninstall-man-sandbox
