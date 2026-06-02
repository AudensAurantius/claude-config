# claude/scripts/hooks/tests/

Busted unit tests for the Lua hooks colocated with their domain (per
ClaudeConfig-ew7 / F-test1). Each test exercises the pure decision /
helper functions of its sibling hook module; end-to-end stdin/stdout
behavior is covered by the smoke test (`just smoke`).

Run via `just test-hooks` (from the project root) or directly:

```bash
busted --lpath='./claude/scripts/hooks/?.lua' claude/scripts/hooks/tests/
```

Future: as more hook scripts land, tests follow the established pattern
(`<hook-name>_spec.lua`, single file per module, `dofile()` + clear
`package.loaded["_lib"]` for fresh env capture).
