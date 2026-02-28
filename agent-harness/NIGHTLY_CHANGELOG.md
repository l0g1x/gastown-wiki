# Agent Harness Nightly Changelog

## 2026-02-28 | ae11c53c → 7a6c8189

### Summary
Formula parser expanded with composition (extends/compose), AOP-style advice/pointcuts, conditional gates, squash behavior, and presets. Mail test infrastructure hardened against Dolt server zombies.

### Layer Changes
#### 08 — Execution Navigation
- `internal/formula/types.go` — Added 6 new top-level Formula fields (`Extends`, `Compose`, `Advice`, `Pointcuts`, `Squash`, `Presets`) and `Gate` on `Step`, plus 10 new supporting type definitions (`Compose`, `ComposeExpand`, `Advice`, `AdviceAround`, `AdviceStep`, `Pointcut`, `Squash`, `Gate`, `Preset`). These enable formula inheritance, AOP-style step injection, conditional gating, commit squash on completion, and named convoy presets.
- `internal/formula/parser.go` — Updated `validateWorkflow()` to accept composition formulas (with `extends` set, zero local steps is valid). Updated `validateAspect()` to accept `advice` as alternative to `aspects`.
- `internal/formula/parser_test.go` — 427 new lines: comprehensive tests for all new TOML sections (extends, compose, advice, pointcuts, squash, gate, presets) plus embedded formula validation.
- `internal/formula/integration_test.go` — Removed skip logic for advanced formulas (composition/AOP formulas now parse successfully).
- Assessment: doc updated

#### 07 — Communication
- `internal/mail/testmain_test.go` — New file: adds `TestMain` to cleanly shut down Dolt server after mail package tests, preventing zombie `dolt-server` processes.
- Assessment: no doc impact (test infrastructure only)

#### Infrastructure (not layer-specific)
- `internal/testutil/doltserver.go` — Added contract documentation: any package calling `RequireDoltServer` must have a `TestMain` calling `CleanupDoltServer()`.
- `internal/testutil/doltserver_unix.go` — Reduced zombie dolt-server reap timeout from 1 hour to 10 minutes.

### Layers With No Changes
01, 02, 03, 04, 05, 06, 09, 10

### Notes
- Baseline hash `ae11c53c` is no longer present in git history (likely lost to force-push). Proxy baseline `2484936a` (closest upstream commit before doc creation time 2026-02-28T06:19 UTC) was used for diffing. Actual delta may include additional changes not captured.
