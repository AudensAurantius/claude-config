# `/etc/` changes go to etckeeper

Whenever a session modifies anything under `/etc/` (installing systemd
units, dropping config files, substituting a placeholder via `sed -i`,
chmoding a unit-managed path, etc.), the session must commit those
changes to **etckeeper** before declaring the work complete. The repo
is at `/etc/.git` with remote `git@github.com:AudensAurantius/etckeeper`.

## Protocol

1. **Audit first.** `sudo bash -c 'cd /etc && git status'` to see new
   and modified paths.
2. **Verify each new tracked file is correctly gated for secrets:**
   - If the file is root-only AND non-secret: add to
     `/etc/etckeeper/git-crypt-allowlist`.
   - If the file is root-only AND secret: add to `/etc/.gitattributes`
     with `<path> filter=git-crypt diff=git-crypt` **before the first
     commit**. (Once a secret is committed in the clear and pushed,
     rewriting history is the only fix — much worse than getting it
     right the first time.)
   - World-readable files (e.g. `passwd`, `group`, `systemd/system/*.service`)
     need no special treatment.
3. **Commit:** `sudo etckeeper commit "message describing the change"`.
   The `40check-secrets` pre-commit hook will block if step 2 was
   missed. Treat any block as a real failure: do not bypass with
   `--no-verify` or by editing the hook out.
4. **Push** (operator's choice): `sudo bash -c 'cd /etc && git push'`
   when ready. Pushing is optional from a session's standpoint —
   safety is enforced at commit-time, not push-time.

## Background

The etckeeper repo is git-crypt-armed. Sensitive files (`shadow`,
`gshadow`, `ssl/private/**`, `mysql/debian.cnf`, etc.) are
transparently encrypted via `.gitattributes`; the `40check-secrets`
hook is the safety net for new sensitive files that haven't been
wired up yet. Full detail in bd memory
`etckeeper-commit-protocol-this-host-s-etckeeper-repo` (searchable
via `bd memories etckeeper`).
