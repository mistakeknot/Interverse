# PRD: Dual-Mode Plugin Architecture

**Bead:** iv-gcu2

## Problem

Every Interverse plugin re-implements the same 15-30 lines of fail-open guards, creating feature duplication across 20+ plugins, upgrade friction when intercore evolves, a discoverability gap where standalone users don't know what companions would unlock, and a testing matrix that grows with every new integration point.

## Solution

A shared integration SDK (`interbase.sh`) distributed via centralized `~/.intermod/` with per-plugin stub fallback, an `integration.json` manifest declaring each plugin's ecosystem surface, and a companion nudge protocol that guides users toward the integrated experience. Validate the pattern by migrating interflux as a reference implementation.

## Features

### F1: Build `infra/interbase/` — Centralized interbase.sh SDK

**What:** Create the shared shell library that all Interverse plugins source for ecosystem integration, installed to `~/.intermod/interbase/interbase.sh`.

**Acceptance criteria:**
- [ ] `infra/interbase/interbase.sh` exists with load-once guard (`_INTERBASE_LOADED=1`) set before any sourcing
- [ ] Guard functions: `ib_has_ic`, `ib_has_bd`, `ib_has_companion`, `ib_in_ecosystem`, `ib_in_sprint`, `ib_get_bead`
- [ ] Phase tracking: `ib_phase_set` (no-op without bd)
- [ ] Event emission: `ib_emit_event` (no-op without ic)
- [ ] Session status: `ib_session_status` callable function (not auto-emitting at load time)
- [ ] Nudge protocol: `ib_nudge_companion` with durable state, aggregate budget, ecosystem-only routing (see F3)
- [ ] `~/.intermod/interbase/VERSION` file written at install time
- [ ] `INTERMOD_LIB` env variable overrides the centralized path for dev testing
- [ ] Install script or interbump hook that copies to `~/.intermod/interbase/` with `chmod 644`
- [ ] Unit tests: `infra/interbase/test-interbase.sh` covering guards in standalone mode (no ic/bd) and integrated mode (mocked ic/bd)

### F2: Define `integration.json` Schema + `interbase-stub.sh` Template

**What:** Create the per-plugin manifest schema and the minimal stub that every plugin ships alongside its hooks.

**Acceptance criteria:**
- [ ] `.claude-plugin/integration.json` JSON schema defined with fields: `ecosystem`, `interbase_min_version`, `standalone_features[]`, `integrated_features[{feature, requires}]`, `companions{recommended[], optional[]}`, `ecosystem_only` (boolean, default false)
- [ ] `hooks/interbase-stub.sh` template (~10 lines) with:
  - `_INTERBASE_LOADED` guard set unconditionally before live source attempt
  - Live source path: `${INTERMOD_LIB:-${HOME}/.intermod/interbase/interbase.sh}`
  - Inline fallback stubs for all `ib_*` functions with safe defaults
  - No `ib_in_ecosystem()` in stub path (dead function — structurally always false in fallback)
- [ ] Template files live in `infra/interbase/templates/` for interbump to copy at publish time
- [ ] `interbase_min_version` field is display-only documentation (enforcement deferred, noted in schema)

### F3: Companion Nudge Protocol Implementation

**What:** Implement the nudge logic inside centralized `interbase.sh` that guides users toward installing companion plugins, with safeguards against nagging.

**Acceptance criteria:**
- [ ] Nudge triggers on first successful operation completion per session (not session-start)
- [ ] Durable state stored in `~/.config/interverse/nudge-state.json` keyed by `plugin:companion` pair
- [ ] Session-level aggregate: max 2 nudges per session across all plugins, tracked via session-scoped file
- [ ] Dismissal: auto-dismiss when companion detected installed; mark dismissed after 3 session ignores (1 increment per session where nudge fired and companion not installed by next session)
- [ ] Ecosystem-only check: if companion's `integration.json` has `ecosystem_only: true`, route nudge to Clavain (`"run /clavain:setup"`) instead of direct companion install
- [ ] Nudge text includes actionable install command: `"[interverse] Tip: run /plugin install {companion} for {benefit}."`
- [ ] Output channel: stderr only, never blocks workflow
- [ ] Concurrency: atomic touch pattern prevents duplicate nudges from parallel hooks
- [ ] Tests: verify nudge fires once, respects budget, respects dismissal, routes ecosystem-only correctly

### F4: Migrate interflux as Dual-Mode Reference Implementation

**What:** First plugin to adopt the dual-mode pattern — add `integration.json`, add `interbase-stub.sh`, verify all three modes work.

**Acceptance criteria:**
- [ ] `plugins/interflux/.claude-plugin/integration.json` populated with actual interflux features, companions, `ecosystem_only: false`
- [ ] `plugins/interflux/hooks/interbase-stub.sh` sourced by all hook scripts that currently use inline guards
- [ ] Standalone mode: all existing hook tests pass with NO `~/.intermod/` present (stubs active)
- [ ] Integrated mode: with `~/.intermod/interbase/interbase.sh` installed, centralized copy is sourced and used
- [ ] Degradation: with partial ecosystem (beads but no ic, ic but no beads, etc.), each integration point degrades gracefully
- [ ] Existing inline guards in interflux hooks replaced with `ib_*` calls
- [ ] No user-visible behavior change for existing interflux standalone users (backwards-compatible)
- [ ] Session status line emitted via `ib_session_status` from interflux's `session-start.sh` when centralized interbase.sh is active

## Non-goals

- **F5: Clavain modpack auto-install** — Deferred. Ecosystem-only plugin distribution is a separate concern.
- **F6: Marketplace manifest drift fix** — Deferred. interbump auto-generation is independent of the SDK.
- **Migrating all plugins** — Only interflux in this iteration. Other plugins adopt the pattern in future sprints after the reference is proven.
- **Runtime version enforcement** — `interbase_min_version` is documentation only. No session-start warning when versions mismatch (deferred).
- **`~/.interband/` consolidation** — interband stays at `~/.interband/` for now. Moving it under `~/.intermod/` is a separate migration.
- **Session-level integration test harness** — The tooling for loading multiple plugins in a test Claude Code session doesn't exist. Per-plugin testing is sufficient for this iteration.

## Dependencies

- `infra/interband/` — existing pattern reference (already built, no changes needed)
- `infra/intercore/` — ic CLI must be installed for integrated-mode testing
- `plugins/interflux/` — target for reference migration
- `scripts/interbump.sh` — needs minor update to install interbase.sh to `~/.intermod/` at publish time

## Open Questions

1. **Should `clavain:setup` install `~/.intermod/interbase/` as part of its setup flow?** This would give ecosystem users the centralized copy immediately. Alternative: let the first `interbump` publish handle it.

2. **Nudge text customization** — Should plugins provide their own nudge benefit text via `integration.json`, or should `ib_nudge_companion` generate it from the `integrated_features` array? The former is more natural language, the latter is more DRY.
