# Systemd units for the claude-egress mediation services

Source-of-truth unit files for the egress broker (DEC-013, DEC-029)
and the SNI-passthrough proxy (DEC-013, DEC-030).

## Install

```bash
sudo install -m 0644 -o root -g root \
    sandbox/systemd/claude-egress-broker.socket \
    /etc/systemd/system/claude-egress-broker.socket
sudo install -m 0644 -o root -g root \
    sandbox/systemd/claude-egress-broker.service \
    /etc/systemd/system/claude-egress-broker.service
# Substitute the literal CLAUDE_SESSION_UID placeholder with the host's UID.
sudo sed -i "s/CLAUDE_SESSION_UID/$(id -u claude-session)/" \
    /etc/systemd/system/claude-egress-broker.service
sudo systemctl daemon-reload
sudo systemctl enable --now claude-egress-broker.socket
```

The wrapping in `just install-sandbox` will eventually automate this;
slice-5 ships the units only.

## Verification

```bash
# Socket should be listening.
systemctl status claude-egress-broker.socket

# First connection activates the service. Use socat with a real
# request (see sandbox/egress-policy/README.md for the wire format).
echo "<framed request>" | sudo -u claude-session socat - UNIX-CONNECT:/run/claude-egress/broker.sock

# Service logs.
journalctl -u claude-egress-broker.service
```

## Hardening notes

The `.service` unit applies the standard systemd containment knobs
that don't break the broker's workload. Notable rules:

- `ProtectSystem=strict` + `ReadOnlyPaths=/etc/claude-config` —
  policy files are visible, nothing else under `/etc` is.
- `ProtectHome=read-only` — `/home/claude-egress` stays readable (we
  need it for the pass store and gpg agent), but the broker cannot
  write to any home.
- `RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6` — UDS in, HTTPS
  out, nothing else.
- `MemoryDenyWriteExecute=true` — no JIT trampolines or shellcode
  execution.
- `SystemCallFilter=@system-service` — covers stdlib's needs for
  Python and Go; tighten further once the production binary is
  profiled.

The most consequential rules are operational, not in the unit:

1. `claude-egress` has a `nologin` shell and no sudoers entry — there
   is no path to elevate to a session principal.
2. The socket is mode `0660 root:claude-session` — only `claude-session`
   can connect, and SO_PEERCRED inside the broker double-checks.
3. Policy files at `/etc/claude-config/egress-policy/` are
   `0640 root:claude-egress` — the broker can read, nothing else can
   read; only root can write.

## Priming gpg-agent (ClaudeConfig-bd5)

The broker decrypts credentials via pass(1), which delegates to
gpg-agent. The broker key is passphrase-protected (per DEC-029) and
the service runs with no TTY and no pinentry path. Before starting
the broker, the operator primes claude-egress's gpg-agent with the
passphrase using `prime-egress-broker`:

```bash
sudo prime-egress-broker
```

This:

- Fetches `claude-config/egress-broker-gpg-passphrase` from the
  operator's personal pass store.
- Hands it to claude-egress's gpg-agent via
  `gpg-preset-passphrase` (the passphrase never touches disk).
- Seeds a sentinel ciphertext at `/home/claude-egress/.gnupg/sentinel.gpg`
  on first run.
- Verifies the priming by decrypting the sentinel.

The service unit's `ExecStartPre=` runs the same sentinel decrypt
on every start; if the cache is cold, systemd refuses to start the
broker rather than have it serve 500s on every request.

Re-priming is needed only when gpg-agent itself restarts (manual
`gpgconf --kill gpg-agent`, host reboot, etc.). Restarting
`claude-egress-broker.service` does not evaporate the agent cache.

## SNI-passthrough proxy (DEC-013, DEC-030, ClaudeConfig-ciw.3)

The proxy is the broker's uncredentialed sibling: it listens on
`127.0.0.1:8443`, peeks the SNI from each inbound ClientHello,
verifies it against `/etc/claude-config/egress-proxy/*.yaml`, and
splices the bytes through to the upstream (or drops the connection).
No TLS termination, no MITM, no CA cert inside the sandbox.

Install:

```bash
just install-egress-proxy
sudo systemctl daemon-reload
sudo systemctl enable --now claude-egress-proxy.socket
```

Verify the listener:

```bash
systemctl status claude-egress-proxy.socket
sudo journalctl -u claude-egress-proxy.service
```

End-to-end smoke (allowed SNI; assumes the shipped sample
`anthropic-cdn.yaml` is installed):

```bash
openssl s_client -connect 127.0.0.1:8443 \
    -servername api.anthropic.com </dev/null
```

Denied SNI — should close before any application bytes flow:

```bash
openssl s_client -connect 127.0.0.1:8443 \
    -servername evil.example </dev/null
```

Hardening differences from the broker: no `GNUPGHOME` /
`PASSWORD_STORE_DIR` (no credentials), no `ExecStartPre` health
check (no agent cache to prime), `ProtectHome=true` (read-only is
unnecessary; the proxy reads nothing from `/home`),
`RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6` (UNIX kept for
sd_notify; INET for the inherited listener + outbound dials).

ECH-driven sunset of the SNI peek is tracked separately as
`ClaudeConfig-ciw.6`.
