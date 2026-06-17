# Profile YAML Schema

Sandbox profiles configure what paths, credentials, and environment variables
are visible inside a `claude-sandbox` session. The Phase 1 schema is
documented here; Phase 2 (`ClaudeConfig-a92.1`) will add CUE-based
validation and per-profile overrides.

## Top-level keys

| Key | Type | Required | Description |
|-----|------|----------|-------------|
| `name` | string | yes | Profile identifier; used in log messages and the install map |
| `description` | string | no | Human-readable summary |
| `sandbox_user` | object | yes | Identity of the sandbox principal |
| `read_only` | list | no | Host paths bind-mounted read-only into the sandbox |
| `read_write` | list | no | Host paths bind-mounted read-write into the sandbox |
| `sandbox_home` | list | no | Paths from claude-session's own home bound into the sandbox |
| `shared_credentials` | object | no | Escape-hatch credential sharing (see below) |
| `worktree` | object | yes | Worktree policy for the active project |
| `network` | object | yes | Network policy (standalone bwrap mode) |
| `environment` | object | yes | Environment variable policy |
| `composed` | object | no | srt-composed-mode settings |

---

## `shared_credentials` — escape-hatch credential sharing

**This field exists to handle the narrow exception case where an upstream
service does not support separate principals (e.g. API tokens are
user-bound).** It is NOT the primary credential mechanism. Primary
credentials should be issued directly to `claude-session` at the upstream
service. See DEC-008 and DEC-010 for policy context.

Every use of `shared_credentials` requires:

1. A DECISION_LOG entry (DEC-NNN) that justifies why the credential cannot
   be issued to a separate principal at the upstream service.
2. The DEC entry must follow DEC-008's tier-1 structure *plus* include a
   shared-mechanism justification paragraph.

### `shared_credentials.bind_mounts`

**Option (b) escape-hatch** for credentials that rotate frequently and
externally (cloud SSO refresh tokens, `pass`-managed entries that change
behind the scenes). **Discouraged** — prefer `share-credential.sh` (option
a) for static credentials; reserve bind-mounts for credentials where option
(a)'s static-copy model would require re-running the script on every
rotation.

```yaml
shared_credentials:
  bind_mounts:
    - source: "${USER_HOME}/.config/some-service/token"
      target: "${SANDBOX_HOME}/.config/some-service/token"
      dec_ref: DEC-NNN   # required: cross-reference to the authorizing DEC
```

**How it works at install/session time:**

1. The wrapper reads each entry and runs `setfacl -m u:claude-session:r
   <source>` on the host file, granting claude-session read access to
   hactar's inode.
2. The wrapper adds a bwrap `--ro-bind <source> <target>` flag for this
   file, making it visible inside the sandbox at `<target>`.
3. If the credential is under a directory that is otherwise hidden from
   claude-session (e.g. inside `~hactar`), the wrapper also ensures the
   parent directories up to an accessible root have execute ACLs so the
   bind-mount can be resolved.

**Security note:** With option (b), audit at the filesystem level shows
`claude-session` reading `hactar`'s inode, which is weaker principal
separation than option (a)'s copy-to-owned-home model. This is the primary
reason option (b) is reserved for rotating credentials only.

**`dec_ref` is required** in each bind-mount entry. The wrapper rejects
entries without a `dec_ref` at session start to enforce the structural
friction DEC-010 prescribes.

Fields:

| Key | Type | Required | Description |
|-----|------|----------|-------------|
| `source` | string | yes | Absolute path on the host (variable substitution supported) |
| `target` | string | yes | Absolute path inside the sandbox |
| `dec_ref` | string | yes | DECISION_LOG entry authorizing this share (e.g. `DEC-033`) |

---

## Option (a): `share-credential.sh`

For static credentials (the common case), use the script directly — no
profile change needed:

```bash
# Copy and chown; no profile change required
sandbox/scripts/share-credential.sh \
    ~/.config/some-service/api-token \
    .config/some-service/api-token

# With GPG encryption at rest
sandbox/scripts/share-credential.sh \
    ~/.config/some-service/api-token \
    .config/some-service/api-token \
    --encrypt
```

The script places the credential at `/home/claude-session/<target>` with
`chown claude-session:claude-session` and `chmod 600`. The credential lives
in claude-session's own home and is never bind-mounted from hactar's home.

**Example: sharing an SSH deploy key with claude-session**

A deploy key is a good option-a candidate: it rotates infrequently, is
issued directly (even if user-generated), and benefits from clear principal
separation.

```bash
# 1. Record the rationale in the DECISION_LOG (required — DEC-008 tier-1)
#    Add a DEC-NNN entry explaining why a separate principal isn't available
#    at the upstream service (e.g. "GitHub deploy keys are repo-scoped but
#    not user-principal-scoped; the token owner is always a human user").

# 2. Run share-credential.sh as root (chown requires privilege)
sudo sandbox/scripts/share-credential.sh \
    ~/.ssh/id_ed25519_deploy_myrepo \
    .ssh/id_ed25519_deploy_myrepo

# 3. Verify
sudo -u claude-session stat /home/claude-session/.ssh/id_ed25519_deploy_myrepo
# Expected: owned claude-session:claude-session, mode 600

# 4. Dry-run mode for pre-flight checks
sudo sandbox/scripts/share-credential.sh \
    ~/.ssh/id_ed25519_deploy_myrepo \
    .ssh/id_ed25519_deploy_myrepo \
    --dry-run
```

---

## Variable substitution

The following variables are resolved by the wrapper at invocation time in
profile YAML values:

| Variable | Expands to |
|----------|------------|
| `${USER_HOME}` | host user's home (`/home/hactar` on this machine) |
| `${SANDBOX_HOME}` | sandbox user's home (`/home/claude-session`) |
| `${ACTIVE_PROJECT}` | cwd at wrapper invocation |
| `${INHERIT_TERM}` | value of `$TERM` from the host shell |
| `${INHERIT_LANG}` | value of `$LANG` from the host shell |

---

## Cross-references

- `DEC-008` — tiered credential policy (what is tier-1, when DEC entries are required)
- `DEC-010` — escape-hatch mechanism design (option a vs option b; structural friction)
- `DEC-032` — escape-hatch policy formalization (acceptance criteria, audit chain)
- `sandbox/scripts/share-credential.sh` — option (a) implementation
- `ClaudeConfig-a92.1` — Phase 2 bead for CUE schema validation
