# Lua tests

Placeholder for [busted](https://lunarmodules.github.io/busted/) tests
covering Lua hook scripts (DEC-017, DEC-022).

Populated when the Tier-1 fast-path hooks land:

- `config-guard` — ClaudeConfig-40s.18 (currently deferred; Python WIP at
  `sandbox/scripts/hooks/config-guard.py` is the reference for the Lua
  port).
- `git-guard` — `ClaudeConfig-bi0` epic + `bi0.1`–`bi0.9` children.
- audit / telemetry hooks — `ClaudeConfig-40s.19`, `ClaudeConfig-40s.21`.

When the first Lua hook lands:

1. `apt-get install lua-busted` (or install via luarocks per-user).
2. Add a `tests-lua/<hook-name>_spec.lua` test file.
3. Extend the `justfile` `test` recipe to invoke `busted tests-lua/`.

Until then this directory is intentionally empty (the README ensures
git tracks the location).
