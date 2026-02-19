# Plan: Hierarchical Dispatch Meta-Agent

**Bead:** `iv-quk4`
**Date:** 2026-02-19

## Inputs
- Brainstorm: `hub/clavain/docs/brainstorms/2026-02-14-agent-dispatch-context-optimization.md`
- Decision-gate context: `docs/prds/2026-02-16-interstat-token-benchmarking.md`

## Goal
Prototype hierarchical dispatch where the parent launches one meta-agent that fans out internally, reducing parent context growth from N task results to 1 synthesis result.

## Scope
- Add a meta-agent dispatch path for flux-drive/review workflows.
- Keep existing direct fan-out as fallback behind a feature flag.
- Measure token/context and latency impact for real runs.

## Milestones
1. Dispatch manifest + meta-agent contract
Define manifest schema (agent list, prompts, outputs, severity handling) and single-result return format.

2. Prototype meta-agent orchestration
Implement meta-agent that launches worker agents and writes per-worker artifacts to disk.

3. Notification behavior validation
Empirically test nested dispatch notification bubbling and document observed behavior.

4. Feature flag integration
Wire into Clavain workflow with safe fallback to current dispatch mode.

5. Measurement + decision gate
Compare baseline vs hierarchical mode (parent context, total tokens, latency, quality).

## Dependency Plan
- Coordinate with interstat measurement pipeline for objective rollout decisions.
- Can prototype before full historical measurement data is complete.

## Validation Gates
- Parent context overhead materially reduced in multi-agent runs.
- Quality of synthesized output is not degraded.
- Fallback path works reliably if nested dispatch behavior is unfavorable.

## Risks and Mitigations
- Hidden complexity in nested orchestration: keep strict manifest and artifact contracts.
- Latency regression: parallelize worker execution and cap retries.
- Tooling incompatibility: maintain direct fan-out fallback as release safety valve.
