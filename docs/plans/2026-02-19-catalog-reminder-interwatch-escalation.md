# Plan: Catalog Reminder to Interwatch Escalation

**Bead:** `iv-444d`
**Date:** 2026-02-19

## Inputs
- Brainstorm: `hub/clavain/docs/brainstorms/2026-02-14-auto-drift-check-brainstorm.md`
- Interwatch signal model: `plugins/interwatch/config/watchables.yaml`
- Interwatch detection pipeline: `plugins/interwatch/scripts/interwatch-scan.py`

## Goal
When `catalog-reminder.sh` detects component-shape changes, emit an Interwatch-compatible signal so documentation drift scoring reflects the change immediately.

## Scope
- Define a minimal hook-to-interwatch signal handoff contract.
- Emit `component_count_changed` signal from Clavain hook path.
- Ensure Interwatch consumes the signal without requiring a full manual watch cycle.
- Keep behavior fail-safe when Interwatch is absent.

## Milestones
1. Signal contract
Define payload shape, write location, dedupe semantics, and expiration policy for `component_count_changed` handoff.

2. Hook emission
Update `hub/clavain/hooks/catalog-reminder.sh` to emit the signal only on relevant component add/remove/change paths.

3. Interwatch ingestion path
Update Interwatch scan/evaluation flow to read the hook-emitted signal and apply the configured weight.

4. Tests
Add hook-level smoke tests and interwatch-level integration tests for deterministic score changes.

5. Docs + rollout
Document the contract and fallback behavior in Clavain + Interwatch docs.

## Dependency Plan
- Coordinate with `iv-mqm4` to ensure session-start summaries reflect this signal.
- No blocker dependency needed for initial implementation.

## Validation Gates
- Signal emitted exactly once per qualifying change window.
- Interwatch drift score increases when signal is present.
- No-op behavior when Interwatch is not installed.
- No hook failures or blocking side effects in normal edit flow.

## Risks and Mitigations
- Duplicate signals: enforce per-session/per-file throttling.
- Cross-plugin coupling: keep a tiny versioned signal contract.
- False positives: limit emission to component file classes already used by catalog-reminder.
