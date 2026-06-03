# Egress broker policy files

Per-alias YAML policy files for the credentialed egress broker
(DEC-013, DEC-029). One file per alias. Each file declares an upstream
destination, a credential to attach, and constraints on the request
shape the sandbox is allowed to send.

## Install location

| Path | Owner / mode | Notes |
|---|---|---|
| `/etc/claude-config/egress-policy/<alias>.yaml` | `root:claude-egress` / `0640` | Active policy. Broker reads at startup and on `SIGHUP`. |
| `/etc/claude-config/egress-policy/samples/` | `root:root` / `0755` | Sample files shipped with claude-config; the host operator copies / symlinks selectively into the parent. |

Files in this directory (`sandbox/egress-policy/` in-repo) install to
`samples/`. The operator decides which aliases the host actually
offers; that curation step is deliberate (DEC-029: host capability
set vs. per-project required-aliases manifest).

## Schema

```yaml
alias: <string>                # MUST match the filename stem
upstream:
  host: <fqdn>                 # exact host the broker connects to
  port: <int>                  # default 443
  scheme: https                # only https is supported
credential:
  backend: pass                # only pass(1) is supported in Phase 1.5
  path: <string>               # path within /home/claude-egress/.password-store
  attach:
    type: header               # header | bearer | query
    name: <string>             # header name for type=header; query key for type=query
    # for bearer, the broker emits: Authorization: Bearer <credential>
constraints:
  methods: [<string>, ...]     # uppercase HTTP verbs the sandbox may use
  paths:                       # at least one entry; glob syntax (fnmatch)
    - <pattern>
  max_request_bytes: <int>     # broker enforces; default 10485760 (10 MiB)
  timeout_seconds: <int>       # upstream call timeout; default 120
  block_request_headers:       # headers the broker strips before forwarding
    - <string>                 # case-insensitive
```

### Reserved & always-stripped request headers

Independent of `block_request_headers`, the broker always strips:

- `Host` (re-set from `upstream.host`)
- `Authorization` (broker adds its own per `credential.attach` if `type=bearer`)
- `Cookie` (no cross-request state from the sandbox)
- `X-Forwarded-*` / `Forwarded` (no spoofed provenance)
- The header named by `credential.attach.name` when `credential.attach.type=header`
  (stripped, then re-attached with the policy-controlled value)

### Validation rules

The broker rejects a policy file at load time if any of:

1. `alias` does not match the filename stem.
2. `upstream.host` is not a syntactically valid FQDN (no schemes,
   no paths, no userinfo).
3. `upstream.scheme` is anything other than `https`.
4. `credential.attach.type=query` is paired with `methods` other
   than `[GET]` (query-string credentials in request bodies are
   never appropriate).
5. `paths` is empty or any pattern contains `..` or unescaped
   shell metacharacters beyond `*` and `?`.
6. `max_request_bytes` exceeds 100 MiB (broker hard cap).

Validation errors fail the broker's load step loudly; partial
loads are not permitted.

## Why these constraints

Every constraint here narrows the request shape the sandbox can
influence. The broker's threat model assumes a hostile sandbox: any
field the sandbox can vary is a field the sandbox can attack. The
constraints make those fields explicit and bounded, so a compromised
sandbox cannot use a legitimate alias to reach an illegitimate
destination, run an unintended HTTP verb against the upstream, or
smuggle the credential into a place the policy doesn't authorize.

## Reload semantics

The broker reloads policy on `SIGHUP`. The reload is transactional:
all files in `/etc/claude-config/egress-policy/` are re-validated;
if any fails, the previous policy stays in effect and the broker
logs the error. There is no partial-apply mode.
