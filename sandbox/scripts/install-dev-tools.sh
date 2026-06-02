#!/usr/bin/env bash
# install-dev-tools.sh — install Lua/Bash dev tooling formatters + LSP
# (ClaudeConfig-b7x; the F-fmt1 foundation bead).
#
# Tools: stylua (Lua formatter), shfmt (Bash formatter), lua-language-
# server (Lua LSP, used in `--check` mode for strict diagnostics).
# None are in Debian apt repos as of 2026-06, so the install path is
# GitHub releases (consistent with the Node/srt pattern in
# provision-claude-session.sh step 6).
#
# Usage:
#   PREFIX=$HOME/.local ./install-dev-tools.sh        # host install
#   PREFIX=/home/claude-session/.local sudo -u claude-session -H ./install-dev-tools.sh
#
# Variables (env-overridable):
#   PREFIX            install root (default: $HOME/.local)
#   STYLUA_VERSION    stylua tag including v-prefix (default: v2.5.2)
#   SHFMT_VERSION     shfmt tag including v-prefix (default: v3.13.1)
#   LUALS_VERSION     lua-language-server tag WITHOUT v-prefix (default: 3.18.2)
#
# Idempotent: skips a tool whose installed version marker matches the
# requested version. Re-run to upgrade by bumping the env vars.
set -euo pipefail

PREFIX="${PREFIX:-$HOME/.local}"
BIN="$PREFIX/bin"
LIB="$PREFIX/lib"
SHARE="$PREFIX/share/claude-config/dev-tools"
mkdir -p "$BIN" "$LIB" "$SHARE"

STYLUA_VERSION="${STYLUA_VERSION:-v2.5.2}"
SHFMT_VERSION="${SHFMT_VERSION:-v3.13.1}"
LUALS_VERSION="${LUALS_VERSION:-3.18.2}"

arch="$(uname -m)"
case "$arch" in
    x86_64)
        stylua_arch="x86_64"
        shfmt_arch="amd64"
        luals_arch="x64"
        ;;
    aarch64 | arm64)
        stylua_arch="aarch64"
        shfmt_arch="arm64"
        luals_arch="arm64"
        ;;
    *)
        echo "install-dev-tools: unsupported arch: $arch" >&2
        exit 1
        ;;
esac

# ── stylua ──────────────────────────────────────────────────────────

marker="$SHARE/stylua.version"
if [ "$(cat "$marker" 2>/dev/null || true)" = "$STYLUA_VERSION" ]; then
    echo "  ✓ stylua $STYLUA_VERSION (cached at $BIN/stylua)"
else
    echo "→ installing stylua $STYLUA_VERSION ..."
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    asset="stylua-linux-${stylua_arch}.zip"
    base="https://github.com/JohnnyMorganz/StyLua/releases/download/${STYLUA_VERSION}"
    curl -fsSL "${base}/${asset}" -o "$tmp/${asset}"
    if curl -fsSL "${base}/SHA256SUMS" -o "$tmp/SHA256SUMS" 2>/dev/null; then
        (cd "$tmp" && grep -F "$asset" SHA256SUMS | sha256sum -c -) || {
            echo "install-dev-tools: stylua checksum verification failed" >&2
            exit 1
        }
    else
        echo "  ! stylua: no SHA256SUMS for release; install proceeded without verification" >&2
    fi
    (cd "$tmp" && unzip -qo "$asset")
    install -m 0755 "$tmp/stylua" "$BIN/stylua"
    echo "$STYLUA_VERSION" >"$marker"
    rm -rf "$tmp"
    trap - EXIT
    echo "  ✓ stylua $STYLUA_VERSION → $BIN/stylua"
fi

# ── shfmt ───────────────────────────────────────────────────────────

marker="$SHARE/shfmt.version"
if [ "$(cat "$marker" 2>/dev/null || true)" = "$SHFMT_VERSION" ]; then
    echo "  ✓ shfmt $SHFMT_VERSION (cached at $BIN/shfmt)"
else
    echo "→ installing shfmt $SHFMT_VERSION ..."
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    asset="shfmt_${SHFMT_VERSION}_linux_${shfmt_arch}"
    base="https://github.com/mvdan/sh/releases/download/${SHFMT_VERSION}"
    curl -fsSL "${base}/${asset}" -o "$tmp/shfmt"
    if curl -fsSL "${base}/${asset}.sha256" -o "$tmp/${asset}.sha256" 2>/dev/null; then
        (cd "$tmp" &&
            sed "s|${asset}|shfmt|" "${asset}.sha256" >shfmt.sha256 &&
            sha256sum -c shfmt.sha256) || {
            echo "install-dev-tools: shfmt checksum verification failed" >&2
            exit 1
        }
    else
        echo "  ! shfmt: no .sha256 sidecar; install proceeded without verification" >&2
    fi
    install -m 0755 "$tmp/shfmt" "$BIN/shfmt"
    echo "$SHFMT_VERSION" >"$marker"
    rm -rf "$tmp"
    trap - EXIT
    echo "  ✓ shfmt $SHFMT_VERSION → $BIN/shfmt"
fi

# ── lua-language-server ────────────────────────────────────────────

marker="$SHARE/lua-language-server.version"
if [ "$(cat "$marker" 2>/dev/null || true)" = "$LUALS_VERSION" ]; then
    echo "  ✓ lua-language-server $LUALS_VERSION (cached at $BIN/lua-language-server)"
else
    echo "→ installing lua-language-server $LUALS_VERSION ..."
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    asset="lua-language-server-${LUALS_VERSION}-linux-${luals_arch}.tar.gz"
    base="https://github.com/LuaLS/lua-language-server/releases/download/${LUALS_VERSION}"
    curl -fsSL "${base}/${asset}" -o "$tmp/luals.tar.gz"
    # lua-language-server publishes a per-asset .sha256 (not a SHASUMS file)
    if curl -fsSL "${base}/${asset}.sha256" -o "$tmp/luals.sha256" 2>/dev/null; then
        (cd "$tmp" &&
            expected="$(awk '{print $1}' luals.sha256)" &&
            actual="$(sha256sum luals.tar.gz | awk '{print $1}')" &&
            [ "$expected" = "$actual" ]) || {
            echo "install-dev-tools: lua-language-server checksum verification failed" >&2
            exit 1
        }
    else
        echo "  ! lua-language-server: no .sha256 sidecar; install proceeded without verification" >&2
    fi
    rm -rf "$LIB/lua-language-server"
    mkdir -p "$LIB/lua-language-server"
    tar -xzf "$tmp/luals.tar.gz" -C "$LIB/lua-language-server"
    chmod +x "$LIB/lua-language-server/bin/lua-language-server"
    ln -sf "$LIB/lua-language-server/bin/lua-language-server" "$BIN/lua-language-server"
    echo "$LUALS_VERSION" >"$marker"
    rm -rf "$tmp"
    trap - EXIT
    echo "  ✓ lua-language-server $LUALS_VERSION → $BIN/lua-language-server"
fi

echo ""
echo "✓ Dev tools installed under $PREFIX."
echo "  Make sure $BIN is on your PATH:  export PATH=\"$BIN:\$PATH\""
