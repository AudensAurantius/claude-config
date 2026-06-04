# Install map (Linux/WSL2)

The installer maps source paths under `claude/` and `sandbox/` to
canonical host locations. Other platforms map to their analogues; the
installer abstracts those differences so the source layout remains
stable. Source paths under `claude/` and `sandbox/` are read-only at
runtime — edits go through the repo, then `just install`.

| Source (in repo) | Installed to | Behavior | Notes |
|---|---|---|---|
| `claude/CLAUDE.md.snippet` | `~/.claude/CLAUDE.md` (marker block) | Marker-block managed | Inserted/updated between delimiters; preserves user content |
| `claude/settings/default.json` | `~/.claude/settings.json` | Three-way prompt | keep / replace / merge-in-editor |
| `claude/settings/profiles/*.json` | `~/.claude/settings.profiles/*.json` | Direct install | Phase 2+ |
| `claude/skills/`, `claude/agents/`, `claude/commands/` | corresponding paths under `~/.claude/` | Direct install | Sandbox bind-mounts these read-only |
| `sandbox/bin/claude-sandbox` | `/usr/local/bin/claude-sandbox` | Direct install | User entry-point; calls `sudo` |
| `sandbox/sbin/claude-sandbox-priv` | `/usr/local/sbin/claude-sandbox-priv` | Direct install | Root-only; namespace setup |
| `sandbox/etc/sudoers.d/claude-sandbox` | `/etc/sudoers.d/claude-sandbox` | Direct install | NOPASSWD for the priv script |
| `sandbox/profiles/*.yaml` | `~/.config/claude-sandbox/profiles/*.yaml` | Direct install | Read by the wrapper at runtime |
| `sandbox/scripts/provision-claude-session.sh` | invoked via `just provision` after install | (provisioning script) | Creates user, sets ACLs, provisions Lua/Node toolchains |
| `sandbox/scripts/provision-claude-egress.sh` | invoked via `just provision-egress` (chained into `just provision`) | (provisioning script) | Creates claude-egress UID + `/etc/claude-config/{egress-policy,credentials}/` (DEC-013) |
| `sandbox/broker/` (Go source) → `sandbox/broker/bin/claude-egress-broker` | `/usr/local/sbin/claude-egress-broker` (via `just install-egress-broker`) | Build + sudo install | Production egress broker (DEC-013, DEC-029); Python reference frozen at `sandbox/reference/egress-broker-python/` |
| `sandbox/scripts/prime-egress-broker.sh` | `/usr/local/sbin/prime-egress-broker` (via `just install-egress-broker`) | sudo install | Coordinator-side gpg-agent primer (ClaudeConfig-bd5); seeds sentinel, runs `gpg-preset-passphrase` |
| `sandbox/scripts/claude-egress-broker-healthcheck.sh` | `/usr/local/sbin/claude-egress-broker-healthcheck` (via `just install-egress-broker`) | sudo install | ExecStartPre sentinel-decrypt; refuses broker start when agent cache is cold |
| `sandbox/etc/gpg-agent.conf` | `/home/claude-egress/.gnupg/gpg-agent.conf` (via `just provision-egress`) | Install via provision script | Enables `allow-preset-passphrase` + long cache TTL for the primed agent |
| `sandbox/systemd/claude-egress-broker.{socket,service}` | `/etc/systemd/system/` (via `just install-egress-broker`) | sudo install | Type=notify, socket-activated; operator substitutes CLAUDE_SESSION_UID via `systemctl edit`; service ExecStartPre validates primed gpg-agent |
| `sandbox/proxy/` (Go source) → `sandbox/proxy/bin/claude-egress-proxy` | `/usr/local/sbin/claude-egress-proxy` (via `just install-egress-proxy`) | Build + sudo install | SNI-passthrough proxy (DEC-013, DEC-030); no credentials, peeks ClientHello + splices |
| `sandbox/systemd/claude-egress-proxy.{socket,service}` | `/etc/systemd/system/` (via `just install-egress-proxy`) | sudo install | Type=notify; TCP socket-activated on 127.0.0.1:8443; runs as claude-egress with no GNUPGHOME |
| `sandbox/egress-proxy/` (sample policy + README) | `/etc/claude-config/egress-proxy/` (operator-curated) | Operator-installed | Per-alias allowlist YAML; directory scaffolded by `provision-claude-egress.sh` |

Behavior categories (see [DEC-004](../../DECISION_LOG.md#dec-004-installer-based-deployment-with-non-destructive-defaults-2026-05-04)):

- **Marker-block managed** — installer inserts/updates a delimited
  region; content outside the markers is untouched. Used for files
  where claude-config owns part of the content but the user owns the
  rest.
- **Three-way prompt** — installer prompts on first install when an
  existing file is detected: keep / replace / merge-in-editor.
  Suppressible via `--accept-defaults` / `--accept-existing` /
  `--non-interactive`.
- **Direct install** — installer writes the file unconditionally
  (with timestamped backup if a prior version exists). Used for
  files claude-config exclusively owns.
