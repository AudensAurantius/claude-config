# Polyglot Foundation Discussion — Architectural Pivot

**Date:** 2026-05-27 (discussion concluded 2026-05-29)
**Participants:** Michael Haynes (user), Claude Opus 4.7 (assistant)
**Outcome:** DEC-017 through DEC-025 committed; 3 new epics + 14 child
beads filed; existing fast-path-hook beads language-switched from
Python to Lua.

This document captures the architectural discussion that produced the
nine decisions DEC-017 through DEC-025, including the questions raised,
the proposals considered (initial and revised), and the reasoning that
shifted positions along the way. It is a synthesis, not a verbatim
transcript; see the project's session logs for the literal exchanges.

The pattern of the conversation matters: each exchange started from a
proposal the assistant made, and the user pushed back with the next
question. Several initial proposals were later revised or reversed. The
final decisions reflect the *end* state of that iteration, not the
first thing proposed.

---

## 1. Starting point

The assistant had begun implementing ClaudeConfig-40s.18 (the
PreToolUse config-guard hook for marker-block tamper protection) as a
Python script (`sandbox/scripts/hooks/config-guard.py`). Mid-
implementation, the user interrupted to raise two concerns:

1. **Tests not persisted.** The assistant had claimed to have
   "unit-tested" the handler — but the tests were ad-hoc inline Bash,
   not committed to the repo.
2. **Python tooling needs scaffolding.** Since the project is likely to
   accrue more Python over time, the user wanted to scaffold a uv-based
   project structure now, including a uv-managed venv, rather than
   piecemeal.

The assistant agreed, deferred 40s.18 (set status to `deferred`,
appended a resume checklist, committed the in-progress
`config-guard.py` as WIP), and the architectural discussion took over.

---

## 2. Three pushbacks that reshaped the foundation

### 2.1 "Stdlib-only deployed scripts" — too restrictive

The assistant's initial proposal had two halves: dev tools in a uv
venv (pytest, ruff, mypy), but **deployed scripts constrained to
stdlib-only** so the runtime didn't need to manage a venv.

**User pushback:** *"What if we made this project (or part of it) pipx-
installable, so that all required Python executables have access to
the dependencies declared in pyproject.toml even when installed on the
claude-session side?"*

The user pointed out that `git-guard` (a bead's implementation,
ClaudeConfig-bi0.1) explicitly needs `pyyaml` per the handoff doc —
which is not stdlib. The stdlib-only stance would force vendoring or
similar awkwardness.

**Assistant concession.** Packaging is the right call. Both the
`pyproject.toml` scaffolding and the `pipx`/`uv tool install` story
are happening *anyway*; the only question was whether to extend the
declared-dependency model to the deployed surface. Yes.

→ Recorded as **DEC-019**: Python (uv) for slower-path tools, packaged
as `[project.scripts]` entry points, pipx/uv-tool-installed per-user
for claude-session.

### 2.2 "Pytest for Bash" — wrong tool

The assistant's initial proposal was: use pytest as a universal test
runner, with `subprocess` calls to drive Bash scripts and assert on
outputs. "One runner, unified report."

**User pushback:** *"What's the actual projected overhead to adding a
purpose-built shell testing tool like bats? What benefits do we get
from the pytest-only approach that we couldn't replicate by adding a
thin test orchestration layer (e.g., via a Justfile) on top of the
language-specific tooling?"*

The user was right. `bats` (`@test "label" { ... }`) is the idiomatic
Bash test framework — single script, no dependencies, ~200 KB. Pytest-
as-Bash-driver loses native idiom in the name of a "unified runner"
property that an orchestrator can provide just as well.

**Assistant concession.** The proper polyglot pattern is per-language
native testing (pytest / bats / `go test` / `busted`) with a top-level
orchestrator (Just) running them all + aggregating results. This is
what kubernetes, nixpkgs, and many large polyglot projects do.

→ Recorded as **DEC-022**: per-language native testing; orchestrated
by `just test`.

### 2.3 "Python for hot-path hooks" — wrong language

This was the largest revision. The assistant's initial proposal had
`config-guard` (40s.18) and `git-guard` (bi0) in Python. The user
asked the obvious follow-up: *if PreToolUse hooks need to "bail in
milliseconds," is Python the right choice?*

The assistant initially considered three possibilities:

| Option | Per-call cost | Pros | Cons |
|---|---|---|---|
| Python (baseline) | ~50 ms | Rich libs (pyyaml), uniform with rest of project | Interpreter startup dominates |
| Python + pickle-cached YAML | ~40 ms | Reuses Python; saves the pyyaml import | Doesn't touch the dominant interpreter cost |
| Different language | varies | Could be ~1 ms | Adds a new toolchain |

The user then pushed harder: *"if millisecond- or sub-millisecond-level
latency really is the goal, could we use Lua (with a JIT compiler) or
some other 'fast' scripting language instead of Python? ... Even
compiled languages (Go, Rust, C/C++) would be fine if you think the
performance gain would be worthwhile."*

The assistant worked through the candidates explicitly:

| Language | Cold-start | YAML/JSON | Distribution | Notes |
|---|---|---|---|---|
| Go (compiled) | ~1 ms | stdlib JSON; mature YAML libs | single static binary | Best raw perf; user has no Go experience |
| Lua + LuaJIT | ~1 ms | `lyaml` (LibYAML binding), `lua-cjson` | small interpreter + per-Lua-version package manager | User has existing Lua experience |
| Perl | ~10 ms | mature CPAN | preinstalled most places | Few people enjoy maintaining Perl in 2026 |
| Node | ~50–100 ms | first-class | needs runtime | Worse than Python on startup |
| Python + pickle cache | ~40 ms | great | uv/pipx | Mostly papers over the interpreter cost |
| C/C++/Rust | ~1 ms | bring-your-own (C/C++); mature (Rust) | compile + ship | No startup-perf win over Go; markedly more complexity |

The user, weighing it: *"I'm basically new to Go, so I'd be more
comfortable with Lua, but on the other hand this seems like a good
learning opportunity — the hook scripts will likely be pretty
simple."* They then raised three sub-concerns:

1. **Lua's YAML libraries are "awkward" — in what way?**
2. **Is Go also right for the planned proxy?**
3. **Is there a case for C/C++ over Go?**

The assistant's answers:

1. **Lua YAML's "awkwardness" is install-side, not in-code.** The data
   model fit is excellent — `lyaml` returns Lua tables, which map to
   YAML structure perfectly; in-script ergonomics are clean. The pain
   is that the LibYAML binding needs per-Lua-version `luarocks install`
   plus LibYAML system headers — less uniform than Python's stdlib-
   level YAML/JSON support. But it's a one-time provisioning cost. The
   assistant had overstated the "awkward" framing.
2. **Yes — Go for the proxy.** The DEC-013 SNI proxy already implicitly
   chose Go (`crypto/tls.ClientHelloInfo`, goroutines per connection,
   single static binary). The broker is similar. And the Phase 6 swarm
   coordinator (when ClaudeConfig-g91 lands) will manage N concurrent
   workers — exactly where goroutines + channels shine.
3. **C/C++: no.** Memory safety, build complexity, stdlib parity all
   favor Go for our scale. The closest "smaller than Go" alternative
   would be Rust, but Rust's compile times + learning curve buy us
   nothing measurable here.

**Outcome.** Two languages, split by role:

- **Lua/LuaJIT for system-shipped fast-path hooks** (config-guard, git-
  guard, audit, telemetry). Recorded as **DEC-017**.
- **Go for the egress proxy, broker, and the future swarm coordinator.**
  Recorded as **DEC-018**.

This reverses the git-guard handoff's Python choice. All affected
hook beads (bi0 + bi0.1-bi0.9, 40s.18, 40s.19, 40s.21) carry an
append-notes entry recording the language switch.

The user explicitly invited the "polyglot" framing: *"this project is
already firmly in the 'polyglot' category, so even if we add Python
scaffolding (and I think we should), mixing in other languages is
just fine with me, if appropriate."*

---

## 3. The pickle-cache aside

Before the language switch was decided, the user proposed a Python-
side optimization: hash the YAML config file, cache the parsed object
as a pickle in `~/.cache/claude-session/config/<hash>.pkl`, load via
stdlib `pickle` on subsequent runs (avoiding the `pyyaml` import on
the fast path). They asked: *"is this a standard(ish) pattern? Do you
think the caching mechanism would be worth it?"*

The assistant's honest assessment:

- The pattern is **defensible** (mypy's incremental cache, Python's
  `__pycache__`) but not a *widely-followed idiom for hook scripts*
  specifically — ~6/10 on the "standardness" scale.
- The pickle security concern is moot when the cache dir is claude-
  session-owned (the attacker model already includes "can write the
  cache" implying "controls claude-session").
- The cache saves the `pyyaml` *import* cost (~10–20 ms) by loading
  with stdlib `pickle` instead — real saving.
- But the cache does **not** touch the dominant cost: Python's
  interpreter startup (~30–50 ms). A 100-call session at ~40 ms each
  still aggregates ~4 s of hook overhead.
- The cache is worth it *if staying in Python*. With the language
  switch to LuaJIT (~1 ms cold start), the cache becomes moot.

This aside is what crystallized the language-choice decision. Once
the user proposed Lua and the perf gap was quantified, the cache
pattern was no longer the right optimization to chase.

→ The pickle-cache pattern is mentioned in **DEC-017** as an
alternative considered and rejected. Not pursued.

---

## 4. Three further architectural threads

### 4.1 Multi-interpreter support for project-specific hooks

The user observed: *"I'd like to eventually support project-specific
claude-session hooks defined in the .claude-session/ project dir
(alongside the sidecar config). Using a compiled language like Go for
such one-off, project-specific hooks could be awkward, since the
coordinator would need to add a build step and would also need to
enforce toolchain consistency between claude-session's Go environment
and the declared deps of the project hooks. On the other hand,
performance might well be a concern for even these project-specific
hooks."*

The conclusion: tier the hooks.

- **System-shipped fast-path hooks** (written once, fire on every Bash
  call) → compiled or JIT-compiled language (Lua/LuaJIT per DEC-017).
- **Project-specific hooks** (per-project authorship, fire only on
  events the project cares about) → interpreted, shebang-dispatched
  from a fixed supported set: Python, Node, Bash, Perl, Lua.

The supported interpreter set is provisioned *once at install time* in
claude-session's home, not per-session. Python (via uv) and Node + npm
+ srt are already provisioned; Lua + LuaJIT + luarocks + lyaml + lua-
cjson gets added by Epic 58n's first child; Perl is system-available
on Ubuntu/Debian/WSL2 and just needs verification.

→ Recorded as **DEC-020**.

### 4.2 The Makefile / Justfile / redo question

Initial proposal: keep the existing Makefile for the install map, add
a Justfile as the polyglot dev/build orchestrator. The user noticed
the duplication: *"it seems odd to have both a 'Makefile' and a
'Justfile' in the same project; I'd have thought most projects would
choose one or the other. Exactly what features of `make` are we aiming
to use that `just` doesn't offer as well? Filesystem macros, rich
dependency declaration, or something else?"*

The honest answer: **less than the assistant implied.** Make's edge
was mtime-based file-target dep tracking. For our ~50-line install
map, that buys little; Just's explicit-recipe model is clearer for
polyglot work. Just alone is enough.

The user also asked about `redo` (DJB's content-addressable build
system, implemented by Avery Pennarun): *"It's something I'm
independently interested in, so if there's a good fit here I'd like to
at least consider using it."* The assistant's honest take: redo shines
for projects with complex artifact graphs (code-gen, many compiled
intermediates). Our build graph is too thin (`go build` is already
incremental, `uv build` is already incremental, the install map is
50 lines). redo would be friction-without-payoff at our scale; revisit
if the build graph grows materially.

→ Recorded as **DEC-021**: Just as the polyglot orchestrator; retire
the Makefile.

### 4.3 The "sandboxed agent can't reach project tooling" problem

The user raised a real concern: *"In projects I've worked on, Claude
usually needs access to project-level tooling to be effective — e.g.,
in a Python project, it needs access to the project-local venv to test
implementation ideas and iterate based on unit tests. However,
(a) venvs are typically gitignored, so they wouldn't be visible in
git worktrees, and (b) bind-mounting the actual project venv into the
sandbox could be a security leak."*

The user then proposed a solution: *"each project carries a 'Claude
session' sidecar config (we've already discussed this possibility in
other contexts) declaring the tools claude-session needs to work on
the project, and possibly even a lightweight 'toolchain installer'
script to be run as claude-session. The session coordinator would
then either run the sidecar installer directly (if it's an
executable) or install the listed tools (if it's declarative) when
setting up the sandbox, prior to starting Claude Code inside."*

The assistant agreed and refined: the host user's venv must **never**
be bind-mounted (security: installed packages may carry secrets / .pth
hooks; identity-coupled). The right shape is a **claude-session-owned
per-project venv** at `~/.cache/claude-session/projects/<project-
hash>/venv/`, populated from the project's declared deps via the
sidecar — never the user's venv.

Three modes cover the realistic project space:

- **Declarative** — sidecar lists Python deps (pyproject.toml source)
  + system tools + env vars + egress-allowlist additions.
- **Script** — sidecar points at an executable that does the setup
  imperatively. Escape hatch for projects with non-declarative needs.
- **Nix** — sidecar points at a flake.nix and an attribute; provides
  bit-reproducible session environments for projects that want that
  guarantee.

The user raised priority next: *"are you recommending it be scoped to
Phase 2/3 simply because you want to 'ship' Phase 1 as quickly as
possible, or because you think there's a valid conceptual reason to
put off designing the config shape for now? ... this is a personal
tooling project. Eventually I want to share it with colleagues and
perhaps even open-source it, but for now, there are no users and no
deadlines to meet. In light of this, any 'release pressure' informing
your recommendations should be set aside: the only task ordering that
matters is 'maximally conceptually correct'."*

The assistant conceded that the "Phase 2/3" framing was reflex
anchoring to VISION.md phases, not conceptual ordering. Without
release pressure, the right answer is: **design the sidecar shape
now**, with implementation phased as the dependency chain allows.
Priority P2 (not deferred).

→ Recorded as **DEC-023**.

### 4.4 Cue for schema/validation

The user followed up: *"Given that you proposed Go for the 'fast'
hooks, is there a case for using Cue for the configs (user-level
and/or project-level)? ... Cue is in the Go ecosystem, and Cue is much
more expressive than YAML, and in particular is better able to express
complex dependency networks (it's a lattice-based language, after
all), which might make it more suitable for use in a declarative
'project tooling' config."*

The assistant's analysis:

- For *simple* configs (fast-path hook configs like
  `git-guard.yaml` — a list of patterns, a flag or two), Cue is
  overkill; YAML is fine.
- For the *sidecar* config (with cross-field constraints like
  `egress_allowlist_additions ⊆ system_allowlist`, exactly-one-mode
  populated, dependency networks), Cue is a real fit.
- But forcing every hook interpreter (Python, Lua, Bash) to grok Cue
  at runtime would be costly.

**Split the roles.** Cue is the *schema + validation* language; YAML
remains the *runtime config format*. Workflow: author writes Cue
schemas; project authors write YAML conforming to them; `cue vet`
validates the YAML at session boot (or via `just check`). Hooks read
YAML at runtime via their native libraries.

→ Recorded as **DEC-024**.

### 4.5 Nix as a sidecar option

The user asked: *"Even further: is there a case for using Nix for the
sidecar config, or at least supporting Nix derivation(s) as an
alternative to procedural env-setup scripts and declarative configs?
If we want strong guarantees of environment reproducibility, then Nix
would seem like a natural choice."*

The honest trade-off:

- **For:** reproducibility is unmatched; handles polyglot deps
  uniformly; aligns with the "claude-session owns its tools" model.
- **Against:** paradigm shift for project authors (writing flake.nix
  vs pyproject.toml/package.json); ~5 GB Nix store install footprint;
  first-time builds slow; mixing with non-Nix project setups is
  awkward.

**Conclusion: Nix as one supported sidecar mode, not the default.**
Declarative (simplest) is the default; script for imperative setups;
Nix opt-in for projects wanting bit-reproducible environments. Nix
install in claude-session's home gated on at least one project
actually using Nix-mode.

→ Folded into **DEC-023** (sidecar is multi-modal).

### 4.6 Firecracker for swarms — not yet

Final architectural thread: *"you mentioned Firecracker VMs awhile back
as a viable route to 'swarm' coordination. Is there a case for
scaffolding the infrastructure to support running the sandbox inside a
Firecracker VM now, in preparation for the eventual swarm
implementation? ... Can you explain what the trade-offs are between
using container-based orchestration tools like Kubernetes and bare-
metal VMs for managing an agent swarm? In particular, what are the
security and performance implications of this decision?"*

The assistant's analysis (condensed):

| | Kubernetes (containers) | Firecracker (microVMs) | bwrap + subuid (the 759 default) |
|---|---|---|---|
| Isolation | Shared kernel; kernel-exploit escapes possible | HW virt boundary | Shared kernel; UID-DAC between workers |
| Per-worker overhead | MBs RAM, ms startup | ~5 MiB, ~125 ms boot | KB RAM, sub-ms |
| Operational complexity | High (control plane) | Moderate (FC = a binary) | Low (extends what we have) |
| Cross-platform | Linux everywhere | KVM-only; WSL2 nested-KVM unreliable | Linux/WSL2 OK |
| Right when | Multi-host scheduling, ops team | Adversarial multi-tenant code | Personal swarm, dozens of workers, same host |

For a personal swarm on one machine: Kubernetes shares the host kernel
just like bwrap + subuid does — its container isolation buys nothing
*over* subuid for worker-from-worker isolation, while adding
substantial operational scale (control plane, scheduler, kubelet)
that's overkill. Firecracker is materially stronger (HW-virt) but adds
KVM dependency (problematic on WSL2 per the documented nested-virt
bug) and operational complexity that we don't recoup until the swarm
hosts genuinely adversarial code beyond what subuid + DEC-013 egress
already bounds.

**Scaffolding Firecracker now would be premature.** Phase 6 swarm-
coordinator design (ClaudeConfig-g91) is not yet started; scaffolding
without workload patterns is guessing.

→ Recorded as **DEC-025**: Firecracker deferred to Phase 6 swarm-design
revisit; Kubernetes/containers explicitly rejected for swarms.

---

## 5. Summary of decisions

Nine decisions reached, all committed to `DECISION_LOG.md`:

| DEC | Decision (one line) |
|---|---|
| DEC-017 | Lua/LuaJIT for system fast-path PreToolUse hooks (supersedes git-guard's Python choice). |
| DEC-018 | Go for egress proxy/broker (confirms DEC-013) + future Phase 6 swarm coordinator. |
| DEC-019 | Python (uv) for slower-path tools, packaged as `[project.scripts]` entry points, pipx-installed per-user. |
| DEC-020 | Multi-interpreter support (Python/Node/Bash/Perl/Lua) for project-specific hooks via shebang. |
| DEC-021 | Just (Justfile) as polyglot orchestrator; retire the Makefile. |
| DEC-022 | Per-language native testing (pytest/bats/`go test`/busted); orchestrated by `just test`. |
| DEC-023 | Per-project session sidecar (P2; declarative + script + Nix modes); design now, impl later. |
| DEC-024 | Cue as schema/validation layer (sidecar + future schemas); YAML stays runtime config format. |
| DEC-025 | Firecracker deferred to Phase 6 revisit; Kubernetes/containers rejected for swarms. |

---

## 6. Beads filed

Three new epics + 14 children, all on the feature branch
`feat/40s.15-compose-upstream`:

**Epic ClaudeConfig-58n** — *Provision claude-session interpreter
toolchain (Lua + multi-interpreter)*, backed by DEC-017 + DEC-020.

- 58n.1: Provision LuaJIT + luarocks + lyaml + lua-cjson for
  claude-session. **(Blocks bi0.1-bi0.9, 40s.18, 40s.19, 40s.21.)**
- 58n.2: Verify Perl availability for claude-session.
- 58n.3: Extend smoke-test.sh with multi-interpreter availability
  check. (Depends on 58n.1.)

**Epic ClaudeConfig-2s3** — *Polyglot dev tooling foundation (uv +
Justfile + per-language testing)*, backed by DEC-019, DEC-021, DEC-022.

- 2s3.1: Scaffold uv-managed Python project (pyproject.toml + dev
  .venv + entry-point shell).
- 2s3.2: Port Makefile install map to Justfile; retire Makefile.
- 2s3.3: Add bats; persist tests; wire per-language test layout.
  (Depends on 2s3.1.)
- 2s3.4: Wire `just check`/`just test` into pre-commit + CLAUDE.md.
  (Depends on 2s3.2, 2s3.3.)
- 2s3.5: Provision pipx/uv-tool-install of the packaged Python tools
  for claude-session. (Depends on 2s3.1.)

**Epic ClaudeConfig-wy9** — *Per-project Claude-session sidecar
(declarative + script + Nix modes)*, backed by DEC-023, DEC-024. **P2;
design first.**

- wy9.1: Cue infrastructure (install + integration).
- wy9.2: Design sidecar Cue schema. (Depends on wy9.1.)
- wy9.3: Coordinator integration. (Depends on wy9.2.)
- wy9.4: Declarative-mode implementation. (Depends on wy9.3.)
- wy9.5: Script-mode implementation. (Depends on wy9.3.)
- wy9.6: Nix-mode implementation. (Depends on wy9.3.)

### Cross-epic / language-switch deps

All existing fast-path-hook beads were language-switched from Python
to Lua per DEC-017 and now depend on `ClaudeConfig-58n.1` (Lua
provisioning). Each affected bead carries an `append-notes` entry
recording the change:

- ClaudeConfig-bi0 epic note (git-guard); children **bi0.1–bi0.9**
  all blocked on 58n.1.
- ClaudeConfig-**40s.18** (config-guard, status: deferred). The WIP
  `config-guard.py` (committed 5764ea8) becomes a reference for the
  Lua port.
- ClaudeConfig-**40s.19** (audit hooks).
- ClaudeConfig-**40s.21** (telemetry hook portion; the OTEL Collector
  itself is unaffected).

---

## 7. What this does *not* change

To make explicit what is still in flight on the sandbox-wrapper queue:

- The two-mode (composed/standalone) wrapper architecture (DEC-011)
  is unchanged.
- The `claude-session` identity boundary (DEC-012) is unchanged.
- The egress mediation design (DEC-013) is unchanged; DEC-018 simply
  confirms the implementation language (Go) implicitly chosen there.
- The installer-based deployment model (DEC-004) is unchanged in
  spirit; the *mechanism* moves from Makefile to Justfile (DEC-021).
- The Phase 6 worker-isolation design (ClaudeConfig-759) is unchanged;
  DEC-025 simply records that Firecracker/containers were considered
  and explicitly held in reserve / rejected respectively.

---

## 8. Resume order on the sandbox-wrapper queue

With the foundation work filed, the resume order on the immediate
sandbox-wrapper work is:

1. **ClaudeConfig-58n.1** (Lua provisioning) — unblocks the entire
   fast-path-hook column (40s.18, 40s.19, bi0 family).
2. **ClaudeConfig-2s3.1** (uv scaffold) — supports 2s3.3 (tests) and
   2s3.5 (pipx provisioning) and any future Python tool work.
3. **ClaudeConfig-2s3.2** (Justfile port) — can run in parallel.
4. **ClaudeConfig-2s3.3** (bats + tests layout) — supports persisting
   the config-guard tests as a real pattern.
5. **ClaudeConfig-40s.18** (config-guard, currently deferred) —
   resume: port `config-guard.py` to `config-guard.lua` + busted
   tests; wire PreToolUse handler in claude-session settings.json;
   profile bind for `~/.claude/hooks`; in-session validation.

The pre-existing queue beyond that (40s.19 audit hooks, 40s.15.12 srt
version-sync, etc.) carries forward unchanged in scope, with the
language switches noted above.

---

## 9. Process notes

A few patterns from this discussion are worth carrying forward:

- **"No release pressure" → "conceptual correctness wins."** When the
  user removed the release-pressure constraint, the sidecar priority
  re-evaluation flipped from "defer to Phase 2/3" to "design now,
  P2." The reflex to phase-anchor was wrong here.
- **The assistant's first proposal was wrong on at least three
  fronts** (stdlib-only deployment, pytest-driven Bash tests, Python
  for hot-path hooks). All three flipped on user pushback. Future
  foundation discussions should expect this — the *first* proposal is
  an opening position, not a recommendation.
- **Per-language native tooling, polyglot orchestrator on top** is
  the established pattern for polyglot projects (kubernetes,
  nixpkgs). The "one unified runner" framing was an anti-pattern.
- **Decisions about *language* and *isolation model* are load-bearing
  enough to deserve their own DECs**, not buried in implementation
  beads.
