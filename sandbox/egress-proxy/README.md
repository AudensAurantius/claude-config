# Egress proxy allowlist schema

Per-alias YAML files under `/etc/claude-config/egress-proxy/` (loaded
by `claude-egress-proxy`; DEC-013, ClaudeConfig-ciw.3). One file per
logical service. Each file lists the SNI hostnames the sandbox may
reach via uncredentialed TLS and the TCP ports those hostnames are
served on.

The proxy is **passthrough-only** — it never terminates TLS, so it
cannot see request bodies, headers, paths, or methods. Any service
named here is implicitly trusted to be benign in any shape the
sandbox might call it. Credentialed endpoints belong in
`sandbox/egress-policy/` (the broker), not here.

## Schema

```yaml
alias: anthropic-cdn          # required; must match filename stem
hostnames:                    # required; non-empty list
  - "api.anthropic.com"       # exact FQDN
  - "*.cdn.anthropic.com"     # left-anchored wildcard, one label
ports: [443]                  # optional; default [443]
```

## Hostname matching

- **Exact**: case-insensitive FQDN equality. Trailing dot tolerated on
  the SNI input.
- **Leftmost wildcard**: `*.example.com` matches exactly one DNS
  label. It matches `a.example.com` but NOT `a.b.example.com` and NOT
  `example.com` itself. This is the same semantics browsers apply to
  TLS wildcard SANs.
- Wildcards anywhere other than the leftmost label are rejected at
  load time. Single-label hostnames (e.g. `localhost`) are rejected —
  the proxy is for external services only.

## Load semantics

`claude-egress-proxy` validates every `*.yaml` under the policy
directory at startup. Failure on any file aborts the whole load — the
service does not start with a partially-loaded allowlist. Duplicate
aliases across files are also a load error.

## Anti-SNI-lying

The proxy ignores any `SO_ORIGINAL_DST` an iptables redirect might
attach. It dials the upstream by handing the SNI hostname itself to
the stdlib resolver and connecting to whatever IP DNS returns. A
client that puts `api.anthropic.com` in its SNI is connected to the
real `api.anthropic.com`, regardless of where it originally tried to
connect.

## ECH sunset

Encrypted ClientHello (ECH) hides the SNI from this proxy. When ECH
adoption crosses the threshold where SNI inspection no longer
provides useful signal, this allowlist will be replaced by an
IP-based one (or removed in favor of broker-only egress). Tracker:
ClaudeConfig-ciw.6.
