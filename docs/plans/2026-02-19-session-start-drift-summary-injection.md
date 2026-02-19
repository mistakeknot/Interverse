# Plan: Session-Start Drift Summary Injection

**Bead:** `iv-mqm4`
**Date:** 2026-02-19

## Inputs
- Brainstorm: `hub/clavain/docs/brainstorms/2026-02-14-auto-drift-check-brainstorm.md`
- Interwatch outputs: `.interwatch/drift.json` contract

## Goal
Expose drift risk early by injecting a compact Interwatch summary into session-start context when Medium/High/Certain drift is present.

## Scope
- Read and parse `.interwatch/drift.json` during `session-start.sh`.
- Add a concise summary to additional context only when severity threshold is met.
- Keep messaging short, deterministic, and non-spammy.
- Preserve graceful behavior when Interwatch data is missing or stale.

## Milestones
1. Data contract + thresholds
Define accepted `drift.json` schema subset and severity filter (`Medium+`).

2. Hook implementation
Add parser and summarizer to `hub/clavain/hooks/session-start.sh` with bounded output formatting.

3. UX guardrails
Limit number of surfaced watchables and ensure message stays high-signal.

4. Tests
Add shell-level tests for missing file, malformed JSON, low-severity-only, and mixed-severity cases.

5. Documentation
Document session-start drift behavior and knobs for tuning.

## Dependency Plan
- Works independently; benefits increase when `iv-444d` signal escalation is in place.

## Validation Gates
- No session-start failures when Interwatch is absent or JSON is malformed.
- Summary appears only for threshold-severity drift.
- Summary stays concise and actionable.

## Risks and Mitigations
- Context noise: cap items and keep one-line-per-watchable format.
- Parse fragility: strict fallback to silent no-op on parser errors.
- Alert fatigue: avoid emitting low-confidence drift by default.
