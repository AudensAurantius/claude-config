#!/usr/bin/env bash
# provision-claude-session.sh — one-shot provisioning for the
# claude-session sandbox user (A2 user-model per DEC-007 follow-up #1).
#
# Creates the claude-session system account, adds the /etc/subuid +
# /etc/subgid mapping so the invoking user can map into its UID/GID
# inside a rootless bwrap user namespace, scaffolds claude-session's
# own home directory (for its independent Anthropic OAuth credentials
# per DEC-009), and applies ACLs to ~/.claude/projects/ so memory
# writes from inside the sandbox flow back to the host user's tree.
#
# Idempotent: re-runs are no-ops once provisioned.
# Reversible: `--uninstall` removes everything this script set up.
#
# Requires root (re-execs under sudo if invoked unprivileged).
#
# Usage: provision-claude-session.sh [--uninstall]
#                                    [--user NAME]
#                                    [--host-user NAME]
#                                    [--host-home PATH]
#                                    [--acl-script PATH]
#                                    [--no-acls]
#                                    [-h|--help]
#
# Options:
#   --uninstall       reverse all provisioning (userdel + subuid/subgid
#                     cleanup + ACL strip from host's ~/.claude/projects/)
#   --user NAME       sandbox user to create (default: claude-session)
#   --host-user NAME  host user that maps into the sandbox UID range
#                     (default: $SUDO_USER, or the invoker if not sudo'd)
#   --host-home PATH  host user's home for ACL targeting
#                     (default: ~$host_user)
#   --acl-script PATH override path to setup-claude-session-acls.sh
#                     (default: alongside this script)
#   --no-acls         skip the ACL step (user/subuid only)
#   -h, --help        show this help
#
# Cross-references:
#   DEC-007  bwrap as Phase 1 sandbox primitive (and A2 user-model)
#   DEC-008  no credential injection in profiles
#   DEC-009  claude-session's own Anthropic OAuth
#   J121-ft3 bead acceptance criteria

set -euo pipefail

# ── Argument parsing ─────────────────────────────────────────────────────────

mode="install"
claude_user="claude-session"
host_user="${SUDO_USER:-$(id -un)}"
host_home=""
acl_script=""
do_acls=1

usage() {
    sed -n '/^# provision-claude-session.sh/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)     usage; exit 0 ;;
        --uninstall)   mode="uninstall"; shift ;;
        --user)        claude_user="$2"; shift 2 ;;
        --host-user)   host_user="$2"; shift 2 ;;
        --host-home)   host_home="$2"; shift 2 ;;
        --acl-script)  acl_script="$2"; shift 2 ;;
        --no-acls)     do_acls=0; shift ;;
        *) echo "provision-claude-session.sh: unknown arg: $1" >&2; exit 1 ;;
    esac
done

# Default host_home from host_user once both are known
if [ -z "$host_home" ]; then
    host_home="$(getent passwd "$host_user" | cut -d: -f6)"
    if [ -z "$host_home" ]; then
        echo "provision-claude-session.sh: cannot resolve home for host user '$host_user'" >&2
        exit 1
    fi
fi

# Default ACL script alongside this one
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "$acl_script" ]; then
    acl_script="${script_dir}/setup-claude-session-acls.sh"
fi

claude_home="/home/${claude_user}"

# ── Privilege escalation ─────────────────────────────────────────────────────
# useradd, /etc/subuid edits, and chown all require root. Re-exec under
# sudo if invoked unprivileged, preserving args.

if [ "$(id -u)" -ne 0 ]; then
    if ! command -v sudo >/dev/null 2>&1; then
        echo "provision-claude-session.sh: must run as root and sudo is not available" >&2
        exit 1
    fi
    echo "→ re-execing under sudo ..."
    # Use printf rather than echo for the conditional flags: bash's
    # builtin echo prints anything starting with `--` literally (it
    # only honors -n/-e/-E), but that's not portable across shells
    # and the next reader shouldn't have to know that to feel safe.
    exec sudo -E "${BASH_SOURCE[0]}" \
        $( [ "$mode" = "uninstall" ] && printf '%s\n' --uninstall ) \
        --user "$claude_user" \
        --host-user "$host_user" \
        --host-home "$host_home" \
        --acl-script "$acl_script" \
        $( [ "$do_acls" -eq 0 ] && printf '%s\n' --no-acls )
fi

# ── /etc/subuid + /etc/subgid helpers ────────────────────────────────────────
# We add a single-entry mapping: "<host_user>:<claude-uid>:1". This lets
# bwrap's --unshare-user --uid <claude-uid> succeed for $host_user without
# needing a full 65k subuid range that includes the sandbox UID.

subuid_line() { printf '%s:%s:1\n' "$1" "$2"; }

add_sub_mapping() {
    local file="$1" user="$2" id="$3"
    local line; line="$(subuid_line "$user" "$id")"
    if grep -qxF "$line" "$file" 2>/dev/null; then
        echo "  ✓ ${file}: already has '${line}'"
        return 0
    fi
    # Avoid trailing-newline glitches: ensure file ends in a newline first.
    if [ -s "$file" ] && [ "$(tail -c1 "$file")" != "" ]; then
        printf '\n' >> "$file"
    fi
    printf '%s\n' "$line" >> "$file"
    echo "  ✓ ${file}: added '${line}'"
}

remove_sub_mapping() {
    local file="$1" user="$2" id="$3"
    local line; line="$(subuid_line "$user" "$id")"
    if [ ! -f "$file" ]; then return 0; fi
    if ! grep -qxF "$line" "$file"; then
        echo "  ✓ ${file}: '${line}' already absent"
        return 0
    fi
    local tmp; tmp="$(mktemp)"
    grep -vxF "$line" "$file" > "$tmp"
    install -m 0644 "$tmp" "$file"
    rm -f "$tmp"
    echo "  ✓ ${file}: removed '${line}'"
}

# ── Install ──────────────────────────────────────────────────────────────────

do_install() {
    echo "Provisioning sandbox user '${claude_user}' for host user '${host_user}' ..."

    # 1. Create system user (idempotent)
    if id -u "$claude_user" >/dev/null 2>&1; then
        echo "  ✓ user '${claude_user}' already exists (uid=$(id -u "$claude_user"))"
    else
        useradd \
            --system \
            --home-dir "$claude_home" \
            --create-home \
            --shell /usr/sbin/nologin \
            --comment "Claude Code sandbox principal (A2 model)" \
            "$claude_user"
        echo "  ✓ created user '${claude_user}' (uid=$(id -u "$claude_user"))"
    fi

    local claude_uid claude_gid
    claude_uid="$(id -u "$claude_user")"
    claude_gid="$(id -g "$claude_user")"

    # 2. Scaffold /home/claude-session/.claude/ for OAuth + .claude.json
    # Mode 0750 so claude-session owns its own state; group can read for
    # diagnostics, world cannot.
    install -d -m 0750 -o "$claude_user" -g "$claude_user" "$claude_home"
    install -d -m 0750 -o "$claude_user" -g "$claude_user" "$claude_home/.claude"
    echo "  ✓ scaffolded ${claude_home}/.claude/"

    # 3. /etc/subuid + /etc/subgid mappings for the host user
    add_sub_mapping /etc/subuid "$host_user" "$claude_uid"
    add_sub_mapping /etc/subgid "$host_user" "$claude_gid"

    # 4. ACLs on host user's ~/.claude/projects/ via the dedicated script
    if [ "$do_acls" -eq 1 ]; then
        if [ ! -x "$acl_script" ]; then
            echo "provision-claude-session.sh: ACL script not executable: $acl_script" >&2
            echo "  Pass --no-acls to skip, or --acl-script PATH to override." >&2
            exit 1
        fi
        echo "→ invoking ACL setup: $acl_script"
        "$acl_script" --user "$claude_user" --home-dir "$host_home"
    else
        echo "  • ACL setup skipped (--no-acls)"
    fi

    # 5. Install Claude Code for claude-session (DEC-016). Native binary in
    #    claude-session's OWN home: it cannot share the host user's binary
    #    (host's 0700 home), and composed mode (srt, no path remap) needs
    #    claude on claude-session's real PATH. Version is pinned to the host
    #    user's current claude (exact replica); CLAUDE_VERSION overrides.
    #    Idempotent: skips if already at the target version. Ongoing exact
    #    sync is the launcher's job (ClaudeConfig-40s.15.7).
    local host_claude_ver target_ver
    host_claude_ver="$(basename "$(readlink -f "${host_home}/.local/bin/claude" 2>/dev/null)" 2>/dev/null)"
    target_ver="${CLAUDE_VERSION:-$host_claude_ver}"
    if printf '%s' "$target_ver" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
        local cur_ver
        cur_ver="$(sudo -u "$claude_user" -H env PATH="${claude_home}/.local/bin:/usr/bin:/bin" \
            claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
        if [ "$cur_ver" = "$target_ver" ]; then
            echo "  ✓ ${claude_user} already at claude ${target_ver}"
        else
            echo "→ installing Claude Code ${target_ver} for ${claude_user} ..."
            sudo -u "$claude_user" -H bash -c \
                "curl -fsSL https://claude.ai/install.sh | bash -s ${target_ver}"
            echo "  ✓ installed claude ${target_ver} for ${claude_user}"
        fi
        # Pin: disable claude-session's background auto-updater (DEC-016).
        sudo -u "$claude_user" -H bash -c 'mkdir -p ~/.claude; f=~/.claude/settings.json; \
            if [ -f "$f" ]; then t=$(mktemp); jq ".env=(.env//{})+{\"DISABLE_AUTOUPDATER\":\"1\"}" "$f" >"$t" && mv "$t" "$f"; \
            else printf "{\"env\":{\"DISABLE_AUTOUPDATER\":\"1\"}}\n" >"$f"; fi'
        echo "  ✓ set DISABLE_AUTOUPDATER=1 for ${claude_user}"
    else
        echo "  • skipping claude install: no valid version (set CLAUDE_VERSION=X.Y.Z, or install claude for ${host_user})" >&2
    fi

    # 6. Node (LTS) + srt for claude-session (ClaudeConfig-40s.15.11; composed-
    #    mode prerequisite). srt is a Node SCRIPT (#!/usr/bin/env node) — it
    #    needs node at runtime — so claude-session gets its own Node + srt in
    #    its ~/.local (DEC-016 model). node + npm are KEPT (srt runtime + future
    #    srt updates, 40s.15.12). Pin srt via SRT_VERSION; Node via NODE_VERSION
    #    (default: latest Node 22 LTS, checksum-verified). Idempotent on the
    #    installed srt package version.
    local srt_version arch srt_pkg_json cur_srt
    srt_version="${SRT_VERSION:-0.0.52}"
    arch="$(uname -m)"; [ "$arch" = "x86_64" ] && arch="x64"
    srt_pkg_json="${claude_home}/.local/lib/node_modules/@anthropic-ai/sandbox-runtime/package.json"
    cur_srt=""
    [ -f "$srt_pkg_json" ] && cur_srt="$(jq -r .version "$srt_pkg_json" 2>/dev/null || true)"
    if [ "$cur_srt" = "$srt_version" ]; then
        echo "  ✓ ${claude_user} already has srt ${srt_version} (Node present)"
    else
        echo "→ installing Node (${NODE_VERSION:-latest-v22.x}) + srt ${srt_version} for ${claude_user} ..."
        sudo -u "$claude_user" -H bash -s -- "$arch" "$srt_version" "${NODE_VERSION:-latest-v22.x}" <<'NODESRT'
set -euo pipefail
arch="$1"; srt_version="$2"; node_dir="$3"
base="https://nodejs.org/dist/${node_dir}"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT; cd "$tmp"
curl -fsSLO "$base/SHASUMS256.txt"
tarball="$(grep -oE "node-v[0-9.]+-linux-${arch}\.tar\.xz" SHASUMS256.txt | head -1)"
[ -n "$tarball" ] || { echo "could not resolve Node tarball for ${arch} in ${base}" >&2; exit 1; }
curl -fsSLO "$base/$tarball"
grep " ${tarball}$" SHASUMS256.txt | sha256sum -c -          # integrity gate
rm -rf "$HOME/.local/node"; mkdir -p "$HOME/.local/node" "$HOME/.local/bin"
tar -xJf "$tarball" -C "$HOME/.local/node" --strip-components=1
for b in node npm npx; do ln -sf "$HOME/.local/node/bin/$b" "$HOME/.local/bin/$b"; done
"$HOME/.local/node/bin/npm" install -g --prefix "$HOME/.local" "@anthropic-ai/sandbox-runtime@${srt_version}" >/dev/null 2>&1
echo "    node $("$HOME/.local/bin/node" --version), srt ${srt_version} -> $HOME/.local/bin/srt"
NODESRT
        echo "  ✓ Node + srt ${srt_version} installed for ${claude_user}"
    fi

    # 7. Lua toolchain for claude-session (ClaudeConfig-58n.1; DEC-017 fast-path
    #    PreToolUse hooks + DEC-020 multi-interpreter project hooks). LuaJIT
    #    gives ~1 ms cold-start vs Python's ~50 ms; lyaml + lua-cjson cover the
    #    config + JSON-I/O surface for hook handlers.
    #
    #    Installed via Debian/Ubuntu packages rather than build-from-source —
    #    deviates from the 40s.15.11 heredoc-build pattern because (a) the
    #    apt-shipped LuaJIT/lyaml/lua-cjson are tested and current enough for
    #    DEC-017's hot-path use case, (b) build-from-source would pull in
    #    libyaml-dev + gcc + make as additional host deps. /usr/share/lua/5.1/
    #    and /usr/lib/.../lua/5.1/ are world-readable, so DEC-016's "claude-
    #    session owns its tools" rationale (host 0700 home blocking) does not
    #    apply to system libs. claude-session only needs a per-user `lua`
    #    symlink so #!/usr/bin/env lua resolves to LuaJIT (not the slower
    #    puc-rio lua, if that's also installed).
    local lua_marker_file lua_marker_desired lua_marker_cur
    lua_marker_file="${claude_home}/.local/share/claude-session/lua-toolchain.version"
    lua_marker_desired="luajit=$(dpkg-query -W -f='${Version}' luajit 2>/dev/null || echo missing) lyaml=$(dpkg-query -W -f='${Version}' lua-yaml 2>/dev/null || echo missing) cjson=$(dpkg-query -W -f='${Version}' lua-cjson 2>/dev/null || echo missing)"
    lua_marker_cur=""
    [ -f "$lua_marker_file" ] && lua_marker_cur="$(cat "$lua_marker_file" 2>/dev/null || true)"
    if echo "$lua_marker_desired" | grep -q missing || [ "$lua_marker_cur" != "$lua_marker_desired" ]; then
        echo "→ installing Lua toolchain (luajit + lua-yaml + lua-cjson) ..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
            luajit lua-yaml lua-cjson >/dev/null
        # Recompute after install — versions now resolved
        lua_marker_desired="luajit=$(dpkg-query -W -f='${Version}' luajit) lyaml=$(dpkg-query -W -f='${Version}' lua-yaml) cjson=$(dpkg-query -W -f='${Version}' lua-cjson)"
        sudo -u "$claude_user" -H bash -s -- "$lua_marker_file" "$lua_marker_desired" <<'LUASETUP'
set -euo pipefail
marker="$1"; desired="$2"
mkdir -p "$HOME/.local/bin" "$(dirname "$marker")"
luajit_bin="$(command -v luajit)"
[ -n "$luajit_bin" ] || { echo "luajit not on PATH after apt install" >&2; exit 1; }
# `#!/usr/bin/env lua` should resolve to LuaJIT, not puc-rio (if installed)
ln -sf "$luajit_bin" "$HOME/.local/bin/lua"
# Smoke: require lyaml + cjson via the per-user lua symlink (proves PATH + module load)
"$HOME/.local/bin/lua" -e "require('lyaml'); require('cjson'); print('    lua=' .. _VERSION .. '  lyaml + cjson loaded')"
echo "$desired" > "$marker"
LUASETUP
        echo "  ✓ Lua toolchain installed for ${claude_user} (${lua_marker_desired})"
    else
        echo "  ✓ ${claude_user} already has the Lua toolchain (${lua_marker_cur})"
    fi

    echo ""
    echo "✓ Provisioning complete."
    echo ""
    echo "Next: run the hardened one-time OAuth bootstrap (DEC-009; 40s.15.10):"
    echo ""
    echo "      claude-sandbox --oauth"
    echo ""
    echo "      This runs ${claude_user}'s claude with cwd forced to its own"
    echo "      home, so no caller-inherited cwd is exposed. Do NOT run bare"
    echo "      'claude' as ${claude_user} from an arbitrary directory — a 0700"
    echo "      home does not protect 0755 subdirs reached via an inherited cwd."
    echo "      The token lands in ${claude_home}/.claude/.credentials.json,"
    echo "      independent of your interactive identity."
}

# ── Uninstall ────────────────────────────────────────────────────────────────

do_uninstall() {
    echo "Un-provisioning sandbox user '${claude_user}' ..."

    local claude_uid="" claude_gid=""
    if id -u "$claude_user" >/dev/null 2>&1; then
        claude_uid="$(id -u "$claude_user")"
        claude_gid="$(id -g "$claude_user")"
    else
        echo "  • user '${claude_user}' does not exist; skipping userdel + subuid cleanup"
    fi

    # 1. Strip ACLs first (need the UID to exist for setfacl by name; if user
    # already gone, strip by numeric UID). The host user's projects/ tree
    # accumulates ACLs over time — leaving orphan numeric UIDs is ugly.
    if command -v setfacl >/dev/null 2>&1; then
        local projects_dir="${host_home}/.claude/projects"
        if [ -d "$projects_dir" ]; then
            local target="${claude_user}"
            [ -n "$claude_uid" ] && target="$claude_uid"  # numeric works either way
            setfacl -R    -x "u:${target}" "$projects_dir" 2>/dev/null || true
            setfacl -R -d -x "u:${target}" "$projects_dir" 2>/dev/null || true
            echo "  ✓ stripped ACLs for '${target}' from ${projects_dir}"
        fi
    fi

    # 2. Remove subuid/subgid mappings (only if we know the IDs we added)
    if [ -n "$claude_uid" ]; then
        remove_sub_mapping /etc/subuid "$host_user" "$claude_uid"
    fi
    if [ -n "$claude_gid" ]; then
        remove_sub_mapping /etc/subgid "$host_user" "$claude_gid"
    fi

    # 3. Delete user + home
    if [ -n "$claude_uid" ]; then
        # --remove deletes the home dir; --force allows even if logged in
        # (claude-session has nologin shell, but processes may exist).
        if userdel --remove --force "$claude_user" 2>/dev/null; then
            echo "  ✓ deleted user '${claude_user}' and removed ${claude_home}"
        else
            echo "  ! userdel failed; leftover state may remain at ${claude_home}" >&2
        fi
    fi

    echo ""
    echo "✓ Un-provisioning complete."
}

# ── Dispatch ─────────────────────────────────────────────────────────────────

case "$mode" in
    install)   do_install ;;
    uninstall) do_uninstall ;;
esac
