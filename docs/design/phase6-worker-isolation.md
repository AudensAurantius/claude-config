# Phase 6 worker isolation — design

**Status:** pre-decisional (binding choice lands in a DEC at Phase 6 kickoff)
**Targets:** Phase 6 (autosession daemon / multi-worker swarm)
**Source bead:** ClaudeConfig-759
**Related:** DEC-011 (augmentation layer), DEC-012 (claude-session UID),
DEC-013 (egress mediation)

## Problem

The Phase 6 autosession daemon spawns multiple concurrent agent workers.
Under the DEC-012 identity model they would all run as the single
`claude-session` UID. That gives each worker kernel-enforced isolation
*from the host user* (`hactar`) — but **not from each other**. Same-UID
processes can `ptrace` one another, read each other's `/proc/<pid>/environ`,
and read/write each other's files. For a swarm where one worker might be
processing untrusted input (a malicious dependency, a prompt-injection
payload in a fetched page), worker-to-worker isolation matters: a
compromised worker should not be able to reach into a sibling's session.

Two candidate mechanisms, at different points on the isolation-strength /
operational-cost curve.

## Option A — subuid user-namespaces (recommended default)

Allocate `claude-session` a subordinate UID range and launch each worker
in its own user namespace mapped to a distinct slice of that range.

### Mechanism

`/etc/subuid` and `/etc/subgid` grant `claude-session` a block of
subordinate IDs:

```
claude-session:100000:65536
```

The daemon launches each worker via `bwrap --userns` (or `unshare --user`
+ `newuidmap`/`newgidmap`) mapping the worker's in-namespace UID 0 to a
distinct host-side subordinate UID — e.g. worker N maps to
`100000 + N`. A 65536 block trivially covers any realistic worker count;
even a conservative 1024-wide allocation gives 1024 concurrent workers.

Each worker then sees itself as root inside its namespace but the host
kernel sees a distinct, unprivileged subordinate UID per worker. Two
workers mapped to `100042` and `100043` cannot `ptrace` or read each
other's `/proc` entries — standard cross-UID DAC denies it.

### Worker lifecycle

- **Creation:** daemon assigns the next free slice from a free-list,
  launches `bwrap --userns` (composed mode wraps `srt claude`; standalone
  wraps `claude` directly per DEC-011). The slice index is the worker's
  identity for logging and egress routing.
- **Exit cleanup:** user namespaces are reaped automatically when the
  worker process tree exits — no lingering host state. The daemon returns
  the slice to the free-list. Files the worker wrote to its scratch dir
  are owned by the mapped subordinate UID; cleanup is a `rm -rf` of the
  per-worker scratch (the daemon, running as `claude-session`, owns the
  parent of the subordinate range and can remove it).
- **Crash recovery:** a crashed worker's namespace dies with its process;
  the daemon detects exit via `waitpid`/`pidfd`, returns the slice, and
  may relaunch. No manual teardown of namespace artifacts.

### Interaction with DEC-013 egress mediation

**Recommendation: shared broker/proxy, per-worker identity tag.** The
`claude-egress` broker and SNI proxy (DEC-013) run once on the host, not
per worker. Each worker's bwrap mount namespace binds in the same broker
socket path (`/run/claude-broker.sock`). To keep per-worker attribution
and policy, the daemon passes the worker's slice index to the broker via
the connecting credential (SO_PEERCRED gives the broker the connecting
UID; since each worker has a distinct mapped UID, the broker can attribute
and, if desired, apply per-worker egress policy). This avoids spinning up
N brokers while preserving per-worker auditability.

Per-worker brokers are possible but rejected as the default: N broker
processes multiply the load-bearing-security-surface count (DEC-013 already
flags the broker as a security-critical component) for marginal benefit,
since the broker's policy is destination-by-credential and doesn't need
per-worker process isolation to be correct.

### Cost

- One-time `/etc/subuid` + `/etc/subgid` entry (install-time, root).
- Depends on `kernel.unprivileged_userns_clone=1` (default on Ubuntu,
  Fedora, Debian, WSL2 — but a centrally-disable-able knob; document as a
  prerequisite).
- `newuidmap`/`newgidmap` setuid helpers (from `uidmap` package) if not
  using bwrap's built-in userns handling.

### Why this is the default

It reuses the bwrap primitive already chosen (DEC-007/011), needs no
hypervisor, boots as fast as a process, and gives kernel-strength
cross-worker DAC isolation — which is the actual threat (sibling worker
reach-in), not VM-escape-grade adversaries. It is the proportionate
answer.

## Option B — Firecracker microVMs (reserve for VM-strength requirement)

If the threat model escalates to "a worker may run genuinely adversarial
code that could attempt kernel-exploit escape," user-namespace isolation
(shared host kernel) is insufficient and VM-strength isolation is wanted.

### What Firecracker is

A microVM hypervisor (AWS, open-source 2018; runs Lambda and Fargate). It
boots a minimal guest with a hardened KVM device model — only virtio-net,
virtio-block, a serial console. Characteristics:

- ~125 ms boot.
- ~5 MiB memory overhead per VM.
- ~10× smaller device-model attack surface than QEMU/KVM.

### Trade-off vs. Option A

| Dimension | subuid user-ns | Firecracker microVM |
|---|---|---|
| Isolation boundary | Shared host kernel, cross-UID DAC | Dedicated guest kernel, hardware virtualization |
| Defends against | Sibling worker reach-in (ptrace, /proc, files) | All of A + guest-kernel-exploit escape |
| Boot cost | Process-fast (ms) | ~125 ms |
| Memory cost | Negligible | ~5 MiB+ per VM |
| Host requirement | `unprivileged_userns_clone=1` | KVM (bare-metal or nested-virt cloud instance) |
| Operational complexity | Low (reuses bwrap) | High (VM images, virtio networking, guest rootfs) |
| WSL2 viability | Works (with userns caveat) | **Problematic** — nested KVM on WSL2 is unreliable |

### Why not the default

Firecracker answers a threat (VM-escape-grade adversarial workers) that
the Phase 6 swarm does not obviously face — its workers run Claude Code
against the user's own projects, not arbitrary untrusted tenants. The
operational cost (KVM dependency, VM image management, virtio networking
that interacts badly with the documented WSL2 network-namespace bug — see
DEC-013 follow-up #1 and `~/.local/src/wsl-vpn-namespace/docs/PITFALLS.md`)
is disproportionate. Reserve as the escalation path if a concrete
multi-tenant or untrusted-code requirement appears.

## Recommendation

1. **Default: Option A (subuid user-namespaces).** Proportionate to the
   actual threat (sibling worker isolation), reuses existing primitives,
   no hypervisor, WSL2-viable.
2. **Egress: shared DEC-013 broker/proxy with per-worker UID attribution
   via SO_PEERCRED** — not per-worker brokers.
3. **Reserve Option B (Firecracker)** for a future escalation if a
   genuine VM-strength requirement emerges (untrusted multi-tenant
   workloads). File a fresh design bead at that point; don't pre-build.

## Open questions for Phase 6 kickoff

- **subuid range width** — 65536 (full block) vs. a narrower 1024. Wider
  is simpler; narrower bounds blast radius if the range is somehow
  enumerable. Lean wide; revisit if a reason to bound appears.
- **Per-worker scratch layout** — `/home/claude-session/.cache/claude-config/<worker-slice>/`
  mirrors the DEC-012 single-session layout. Confirm the daemon's
  free-list survives daemon restart (persist to a state file vs. rederive
  from live namespaces).
- **WSL2 userns reliability** — Option A depends on
  `unprivileged_userns_clone`; confirm WSL2 kernel behavior under many
  concurrent user namespaces (the documented WSL2 bug is network-namespace
  specific, but validate user-namespaces at swarm scale before relying on
  it).
- **Interaction with the network-namespace confinement question**
  (DEC-013 follow-up #1) — if Phase 1.5 adopts netns confinement, each
  worker's egress confinement must compose with its user-namespace; the
  WSL2 netns bug becomes load-bearing here. Resolve the Phase 1.5 netns
  question first.
