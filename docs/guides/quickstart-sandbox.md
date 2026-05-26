# Quickstart: `/sandbox` and `srt` for claude-config sessions

This guide gets you running Claude Code under Anthropic's upstream
sandboxing primitives **today**, before claude-config's augmentation
layer ships. It's the recommended starting point if you want to
evaluate the upstream tooling for coordination work, parallel agent
sessions, or general isolation hygiene.

> **Scope.** This guide is operator-focused: install, configure, run,
> verify. It does NOT cover the augmentation-layer work tracked under
> ClaudeConfig-40s (separate `claude-session` user, ACL-policed
> credentials, deterministic egress mediation). See
> [`docs/VISION.md`](../VISION.md) and
> [`DECISION_LOG.md`](../../DECISION_LOG.md) DEC-011/012/013 for the
> full architecture.

## What you're getting

Two complementary upstream tools:

- **`/sandbox`** — a slash command built into Claude Code (v2.0.55+).
  Wraps Bash tool invocations in bubblewrap (Linux/WSL2) or Seatbelt
  (macOS). Anthropic's own data: ~84% reduction in permission prompts
  when enabled.
- **`srt` (`@anthropic-ai/sandbox-runtime`)** — a process-level
  wrapper, open-source under Apache-2.0. Invoked as `srt claude` from
  the shell. Wraps the **entire** Claude Code process — file tools,
  MCP, hooks — in the same bwrap/Seatbelt boundary. Stricter defaults
  than `/sandbox` (no writes / no network unless allowlisted).

**Relationship:** complementary. `/sandbox` is a fine-grained
in-process fence; `srt` is a coarse-grained process-level fence. Both
use the same primitive (bwrap on Linux). Most useful together:
`srt claude` to enforce the outer boundary, then `/sandbox`'s
settings drive the network and filesystem policy that `srt` consumes.

## What you're NOT getting (yet)

Read this carefully if your workflow touches credentials.

- **Permissive defaults.** `/sandbox` leaves `~/.aws/credentials`,
  `~/.ssh/`, and your entire home directory readable by default.
  Any explicit `denyRead` rules must be added by you.
- **`.env` files are readable** by default and, in **auto permission
  mode**, are read by Claude Code and credentials matched in them
  may be sent to APIs the classifier judges they belong to. This is
  documented behavior, not a bug. **Do not use auto mode on
  credentialed infrastructure.**
- **Documented bypass history.** Two `/sandbox` bypass bugs were
  disclosed within five months (CVE-2025-66479 in Dec 2025; an
  uncatalogued SOCKS5 hostname null-byte injection patched in
  Claude Code v2.1.90 on 2026-03-31). The May 2026 fix was parser-
  hardening, not structural. Nine related concerning issues remain
  open in `anthropic-experimental/sandbox-runtime`. **Treating
  `/sandbox` as the sole boundary on credentialed infrastructure is
  not advisable.** This is the gap the claude-config augmentation
  layer (DEC-011/012/013) closes.
- **`srt` is in public preview.** No published GA target, weekly
  releases since 2025-10-20, JSON config schema additive-only across
  the v0.0.38 → v0.0.52 window observed. Operational guidance: pin
  the version, re-verify on bump.

If your work is high-trust (production credentials, write access to
shared infrastructure, sensitive customer data), wait for the
augmentation layer. If your work is medium-trust (open-source
contributions, agentic coding experimentation, parallel session
coordination), this quickstart is the right entry point.

## Prerequisites

- Linux with `unprivileged_userns_clone=1` (default on Ubuntu, Fedora,
  Debian, WSL2). Check with
  `sysctl kernel.unprivileged_userns_clone`.
- `bubblewrap` (`bwrap`) installed. Ubuntu/Debian:
  `sudo apt install bubblewrap`. Fedora: `sudo dnf install
  bubblewrap`.
- Node.js 18+ (for `srt` via npm). Confirm with `node --version`.
- Claude Code v2.0.55+ for `/sandbox`. Confirm with `claude --version`.

WSL2 note: a one-time bind of `/mnt/wsl` into the sandbox is
required for DNS resolution. `srt` and `/sandbox` handle this
automatically in recent versions. If DNS fails inside a sandboxed
session, check the section "Troubleshooting — WSL2 DNS" at the end.

## Install `srt`

```bash
npm install -g @anthropic-ai/sandbox-runtime
srt --version
```

Pin the version in any automation:

```bash
npm install -g @anthropic-ai/sandbox-runtime@0.0.52
```

Bump deliberately. The schema is additive-only so far but Anthropic
publishes no formal break-change policy beyond the README beta
banner.

## Configure `/sandbox`

`/sandbox` is configured via `~/.claude/settings.json` (or
project-local `.claude/settings.json`). The minimum useful
configuration:

```json
{
  "sandbox": {
    "enabled": true,
    "filesystem": {
      "writable": ["$CWD"],
      "denyRead": [
        "~/.aws/**",
        "~/.ssh/**",
        "~/.docker/config.json",
        "~/.netrc",
        "~/.gnupg/**",
        "**/.env",
        "**/.env.*",
        "**/credentials.json",
        "**/*.pem",
        "**/*.key",
        "**/id_rsa*",
        "**/id_ed25519*",
        "**/id_ecdsa*",
        "~/.config/gh/hosts.yml"
      ]
    },
    "network": {
      "allowedDomains": [
        "api.anthropic.com",
        "registry.npmjs.org",
        "pypi.org",
        "files.pythonhosted.org",
        "github.com",
        "objects.githubusercontent.com",
        "raw.githubusercontent.com",
        "api.github.com"
      ]
    }
  }
}
```

The `denyRead` list above closes the documented "permissive default"
gap. Tune for your environment — add corporate proxies, package
mirrors, internal docs sites as needed in `network.allowedDomains`.

**Inside a session,** invoke `/sandbox` (the slash command) to
activate. Confirm with `/sandbox status`.

## Configure `srt`

`srt` reads `~/.config/srt/config.json` (or `--config <path>`). A
starter config that mirrors the `/sandbox` settings above:

```json
{
  "filesystem": {
    "writable": ["$CWD"],
    "denyRead": [
      "~/.aws/**",
      "~/.ssh/**",
      "~/.docker/config.json",
      "~/.netrc",
      "~/.gnupg/**",
      "**/.env",
      "**/.env.*"
    ]
  },
  "network": {
    "allowedDomains": [
      "api.anthropic.com",
      "registry.npmjs.org",
      "pypi.org",
      "files.pythonhosted.org",
      "github.com",
      "raw.githubusercontent.com",
      "api.github.com"
    ]
  },
  "env": {
    "scrub": true
  }
}
```

`env.scrub: true` enables `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB` —
strips Anthropic and cloud-provider credentials from Bash
subprocess environments. The exact scrub list isn't in the public
docs as of 2026-05-25; treat it as a defense-in-depth measure, not
a complete inventory.

## Run a session

Composed mode (recommended):

```bash
srt claude
```

Then, inside the session, type `/sandbox` to also activate the
inner Bash-tool fence. (Redundant given `srt` wraps the whole
process, but the `/sandbox` settings drive both layers' policy.)

For a non-interactive one-shot:

```bash
srt claude -p "describe the architecture in 50 words"
```

## Verify isolation

Inside a sandboxed session, run these commands to confirm the
boundary is doing what you expect:

```bash
# Should fail or return empty: ~/.aws is denied
ls ~/.aws/

# Should fail: .env in the worktree is denied
cat .env 2>&1 | head -5

# Should fail: not on the allowlist
curl -sS https://example.com/ 2>&1 | head -5

# Should succeed: on the allowlist
curl -sS https://api.github.com/ | head -5

# Should show env without Anthropic creds
env | grep -i anthropic
```

If any of the "should fail" lines succeed, your configuration isn't
loading. Common causes:

- Config file path is wrong. `srt` checks `--config`,
  `~/.config/srt/config.json`, and then no config (permissive
  defaults). `/sandbox` reads `~/.claude/settings.json` and project-
  local `.claude/settings.json`.
- JSON syntax error. Run `jq . <config.json>` to validate.
- Older `srt` or Claude Code version. Check `srt --version` and
  `claude --version`.

## Recommended workflows

### Parallel session coordination

Open multiple terminal windows, each invoking `srt claude` in a
different worktree (e.g., one per Beads issue). Each session is
process-isolated; concurrent edits to disjoint worktrees don't
interfere. This is the closest you can get today to claude-config's
eventual Phase 6 autosession daemon — manual rather than daemonized,
but functional.

Pair with `git worktree add` for clean separation:

```bash
git worktree add ../proj-feature-A feature/A
git worktree add ../proj-feature-B feature/B

# Terminal 1
cd ../proj-feature-A && srt claude

# Terminal 2
cd ../proj-feature-B && srt claude
```

### Sandboxed evaluation of untrusted scripts

Drop the script into a temp worktree, invoke `srt claude` against
that worktree, ask Claude to explain or run the script. The
`denyRead` list above keeps credentials out of reach even if the
script is malicious; the `allowedDomains` list keeps any exfil
attempts from reaching arbitrary destinations.

This is not a hard guarantee — see "What you're NOT getting" above
for the documented bypass class. For untrusted scripts of real
concern, use a VM, not a sandbox.

### Replace `bash` with sandboxed `bash` for casual work

`srt bash` works the same way `srt claude` does. Useful when you
want the filesystem/network fence without Claude Code at all (e.g.,
inspecting a tarball, running a one-off Python script with unclear
provenance).

## Troubleshooting

### WSL2 DNS

If DNS resolution fails inside a session, `srt` or `/sandbox` may
not be binding `/mnt/wsl/resolv.conf` correctly. Workaround until
fixed in upstream:

```bash
# In your srt config.json, add:
"filesystem": {
  "extraReadBinds": ["/mnt/wsl"]
}
```

For `/sandbox`, the equivalent in `~/.claude/settings.json`:

```json
"sandbox": {
  "filesystem": {
    "extraReadBinds": ["/mnt/wsl"]
  }
}
```

### Permission prompts despite sandbox enabled

`/sandbox` reduces but doesn't eliminate permission prompts.
Operations outside Bash (Write, Edit, MCP calls) still use the
existing permission system. Add specific allow rules in
`~/.claude/settings.json` `permissions.allow` for things you trust
implicitly.

### "srt: command not found"

`npm install -g` installs to a path that may not be in your shell's
`PATH`. Run `npm config get prefix` to find the install dir; add
`$(npm config get prefix)/bin` to `PATH`.

### Composed mode appears to do nothing extra

If you've configured `srt` and run `srt claude`, the outer bwrap
fence is already active. `/sandbox` inside the session is then
redundant for Bash isolation but still drives policy. To verify
the outer fence is active, run `cat /proc/self/status | grep
^NSpid` inside the session — non-trivial NSpid values indicate
namespace isolation.

## What's next for claude-config

The claude-config project layers on top of these tools with:

- A separate `claude-session` user for kernel-enforced identity
  isolation independent of `/sandbox`'s app-layer fence
  ([DEC-012](../../DECISION_LOG.md#dec-012-retain-claude-session-user-as-kernel-enforced-isolation-boundary-2026-05-26))
- ACL-policed credential staging for things `denyRead` can't cover
- Deterministic egress mediation (Unix-socket broker for
  credentialed endpoints, SNI-inspecting proxy for allowlisted
  uncredentialed endpoints) per
  [DEC-013](../../DECISION_LOG.md#dec-013-egress-mediation-via-unix-socket-broker-credentialed-and-sni-inspecting-proxy-uncredentialed-2026-05-26)
- A `claude-sandbox` wrapper that handles all the host-side prep
  and exec's `srt claude` (composed mode) or `bwrap ... -- claude`
  (standalone mode)

Use this quickstart today; migrate to the augmentation layer when
it ships.

## References

- `/sandbox` documentation: <https://docs.claude.com/en/docs/claude-code/sandboxing>
- `srt` repository: <https://github.com/anthropic-experimental/sandbox-runtime>
- Permission modes (incl. auto mode caveat): <https://docs.claude.com/en/docs/claude-code/permission-modes>
- ClaudeConfig-40s.13 survey (full):
  `.tasks/ClaudeConfig-40s.13-claude-code-sandboxing-survey/REPORT.md`
- ClaudeConfig-40s.13 follow-up (broker patterns, OTEL hook
  sketches, CVE corroboration):
  `.tasks/ClaudeConfig-40s.13-claude-code-sandboxing-survey/FOLLOWUP.md`
- Condensed survey:
  [`docs/research/claude-code-sandboxing-survey.md`](../research/claude-code-sandboxing-survey.md)
