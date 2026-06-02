claude-sandbox(1)

# NAME

claude-sandbox - run Claude Code under a kernel-enforced isolation boundary

# SYNOPSIS

*claude-sandbox* [_options_] [-- _claude-args_...]++
*claude-sandbox* *--standalone* [_options_] [-- _claude-args_...]++
*claude-sandbox* *--oauth*++
*claude-sandbox* *--version*

# DESCRIPTION

*claude-sandbox* invokes Claude Code as a separate Linux identity
(*claude-session*, UID 999) inside a bubblewrap (bwrap) mount
namespace, with a stripped environment, allow-listed filesystem
visibility, and identity-isolated Anthropic OAuth credentials.

Two run modes are supported:

. *composed* mode (default): delegates to *srt(1)* (Anthropic's
  sandbox-runtime), which wraps Claude Code with bwrap + Seatbelt-
  parity primitives. The augmentation layer composes on top: separate
  user, additional credential deny rules, audit + config-guard
  hooks. This is the recommended mode.
. *standalone* mode (--standalone): claude-sandbox builds the bwrap
  layer directly from the active profile, no srt. Fallback when
  composed mode is unavailable or undesirable.

Per-tool permission prompts and the OS-level sandbox are two layers
of the same defense. Inside the sandbox, the kernel enforces what
the prompt would have checked; the architecture page in
*docs/architecture/sandbox-model.md* covers the composition model.

# OPTIONS

*--standalone*
	Use the direct-bwrap path instead of srt. (DEC-011 fallback;
	see the architecture documentation.)

*--oauth*
	Run claude-session's *claude(1)* outside the bwrap/srt boundary
	for the one-time Anthropic OAuth flow. cwd is forced to claude-
	session's own home (see *Cwd safety* below).

*--dry-run*
	Print the resolved bwrap / srt invocation without executing it.
	Useful for debugging profile resolution.

*--version*
	Print claude-sandbox + bwrap + srt + claude versions and exit.

*-h*, *--help*
	Print usage and exit.

All other arguments are passed through to *claude(1)* unchanged.

# ENVIRONMENT

*CLAUDE_SANDBOX_PROFILE_DIR*
	Override the profile-search directory (default:
	*~/.config/claude-sandbox/profiles*).

*CLAUDE_SANDBOX_SRT_SETTINGS*
	Override the srt settings file (composed mode only). Bypasses
	the emitter; consumer responsibility for soundness.

*CLAUDE_SANDBOX_ACL_SCRIPT*
	Override the setup-claude-session-acls.sh resolution path.

# FILES

_/usr/local/bin/claude-sandbox_
	The wrapper script (this binary).

_~/.config/claude-sandbox/profiles/default.yaml_
	Default sandbox profile: bind-mounts, network policy, env-set
	declarations. The wrapper reads this at invocation.

_/usr/local/share/claude-sandbox/scripts/provision-claude-session.sh_
	One-shot provisioning for the claude-session system account.
	Invoke via *just provision* or directly with sudo.

_/usr/local/share/claude-sandbox/scripts/setup-claude-session-acls.sh_
	ACL granter for per-project worktrees. Invoked by the wrapper.

_/usr/local/share/claude-sandbox/hooks/_
	System-shipped Claude Code PreToolUse / PostToolUse hooks
	(config-guard.lua, audit-event.lua, git-guard.lua). Mirrored into
	claude-session's *~/.claude/hooks/* at session boot.

_/usr/local/share/claude-sandbox/git-hooks/_
	System-shipped git hooks (pre-commit, pre-push). Mirrored into
	claude-session's *~/.config/git/hooks/* at session boot;
	claude-session's *core.hooksPath* redirects there.

_/home/claude-session/.claude/.credentials.json_
	claude-session's Anthropic OAuth token, distinct from the host
	user's. Created by *claude-sandbox --oauth*.

# CWD SAFETY

A *0700* home blocks path traversal but not an inherited cwd
file descriptor. *sudo* preserves cwd; launching bare *claude(1)*
as claude-session from inside the user's home (e.g. *~/.local/share/
some-tool/*, commonly *0755*) lets the spawned process read that
directory via the inherited cwd, bypassing the 0700 gate above.

*claude-sandbox --oauth* and the composed/standalone cwd guard
eliminate this: cwd is forced to claude-session's own home (oauth)
or the active project root (composed/standalone), with the home root
and *~/.dotfile* dirs explicitly refused.

*Never run bare claude(1) as claude-session from an arbitrary
directory.* Always go through *claude-sandbox*.

# EXIT STATUS

*0*
	Success (or claude-sandbox terminated normally per claude's exit
	code).

*1*
	Generic failure. Usual causes: no profile found, sudo
	password prompt failed, provisioning incomplete.

*2*
	Usage error (unknown flag, --standalone without bwrap installed,
	etc.).

Wrapped *claude(1)* may produce other exit codes; the wrapper passes
them through unchanged.

# EXAMPLES

Run a one-shot prompt in composed mode:

```
claude-sandbox -p "Refactor src/foo.py to use dataclasses"
```

Interactive composed-mode session:

```
claude-sandbox
```

Standalone mode (no srt):

```
claude-sandbox --standalone -p "ls -la"
```

One-time Anthropic OAuth bootstrap (run once per host):

```
claude-sandbox --oauth
```

Verify deployment without launching a session:

```
claude-sandbox --version
just verify
```

# SEE ALSO

*claude*(1), *srt*(1), *bwrap*(1), *sudo*(8)

# DOCUMENTATION

The architectural reference for the sandbox model:
_/usr/local/share/doc/claude-config/sandbox/sandbox-model.md_ (after
F-doc2 lands the doc migration; until then,
*docs/architecture/sandbox-model.md* in the source tree).

Hook plumbing reference:
_docs/architecture/hooks.md_.

Decision history:
_DECISION_LOG.md_ at the repo root.

# AUTHORS

claude-config maintainers <https://github.com/AudensAurantius/claude-config>
