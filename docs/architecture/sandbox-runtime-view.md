# Runtime view (post-Phase-1)

Inside a sandboxed session, `claude-session` sees:

- `~/.claude/` → read-only bind mount of the host's `~/.claude/`
  (which itself was deployed from `claude/` in this repo by the
  installer).
- `~/Source/claude-config/` → writable feature-branch worktree, for
  agent self-modification.
- `~/Source/<project>/` → bind-mounted worktree at the canonical
  path (path-aliased; Phase 4).
- `~/.config/claude-sandbox/profiles/<active>.yaml` → read by the
  wrapper at session start; consumed before `claude` exec.
- All other host paths → either invisible (shadow-mounted tmpfs) or
  inaccessible (filesystem permissions on the user's home).
