# Plan: interband sideband hardening
**Bead:** iv-hoqj
**Phase:** done (as of 2026-02-17T23:22:26Z)
**Date:** 2026-02-17

## Goal
Complete the P0 hardening of interband after extraction into its own repo, while preserving backward compatibility for current plugins.

## Current baseline
- interband was extracted to `infra/interband` and published at `github.com/mistakeknot/interband`.
- interphase, clavain, interlock, and interline are already dual-read/write with legacy fallbacks.

## Sprint slice (this session)

### 1. Protocol validation (interband)
- [x] Add explicit payload validators for known message types:
  - `interphase/bead_phase`
  - `clavain/dispatch`
  - `interlock/coordination_signal`
- [x] Validate envelopes before read-path acceptance.
- [x] Keep unknown message types forward-compatible (object-only payload requirement).

### 2. Loader hardening (consumers)
- [x] Expand interband loader discovery in consumers beyond monorepo-relative path:
  - explicit `INTERBAND_LIB`
  - monorepo path
  - sibling `../interband` checkout path
  - optional local share path
- [x] Preserve fail-open behavior when interband is unavailable.

### 3. Coordination read migration (interline)
- [x] Read coordination signal from interband first.
- [x] Fall back to legacy `/var/run/intermute/signals/*.jsonl` parsing when interband snapshot is unavailable.
- [x] Keep current statusline UX semantics unchanged.

### 4. Validation and docs
- [x] Run syntax/tests for touched modules.
- [x] Update protocol docs for schema checks + loader behavior.
- [x] Append bead notes with what was completed and what remains.

### 5. Retention and stale cleanup
- [x] Add interband channel retention helpers with sensible defaults.
- [x] Apply automatic prune calls in active writers (`interphase`, `clavain`, `interlock`).
- [x] Add explicit session-end cleanup for interband artifacts where lifecycle hooks exist.

### 6. Go helper parity
- [x] Add Go module and package for interband pathing, envelope read/write, and validation.
- [x] Add Go retention helpers for channel pruning with env-based overrides.
- [x] Add Go unit tests for pathing, validation, read/write, and prune behavior.

## Acceptance for this slice
- No regressions in legacy consumers.
- Interband writes are schema-validated for known message contracts.
- Interline can show coordination state from interband without requiring legacy JSONL.
