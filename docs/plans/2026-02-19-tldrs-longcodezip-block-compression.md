# Plan: tldrs LongCodeZip Block Compression

**Bead:** `iv-2izz`
**Date:** 2026-02-19

## Inputs
- Brainstorm: `plugins/tldr-swinton/docs/brainstorms/2026-02-12-longcodezip-block-compression.md`
- Research note: `plugins/tldr-swinton/docs/research/research-longcodezip-paper.md`

## Goal
Add within-function block compression so tldrs can preserve high-value code blocks under tight budgets instead of dropping whole function bodies.

## Scope
- Add a block-compression mode (L2.5 equivalent) for context generation.
- Segment function bodies using tree-sitter + structural heuristics.
- Score blocks using query relevance, diff proximity, and structural importance.
- Select blocks with budget-aware knapsack, preserving source order.
- Emit informative elision markers and stable output for reproducibility.

## Milestones
1. Interface + architecture
Define the user-facing entrypoint (`--compress blocks` or equivalent), output contract, and integration point in the context pipeline.

2. Block segmentation + scoring
Implement AST-based block segmentation and deterministic scoring function with tunable weights.

3. Budget allocator + rendering
Implement knapsack selector and elision rendering (`# ... (N lines, M tokens)`) while preserving readable order.

4. Tests + regression harness
Add unit tests for segmentation/scoring/selection and regression fixtures comparing L2, L2.5, and L4 behavior.

5. Evaluation + rollout
Benchmark token reduction and quality impact on representative tldrs scenarios; gate rollout behind a feature flag if needed.

## Dependency Plan
- No hard blocker dependency required; implementation can start immediately.
- Coordinate with tldrs regression suite owners before default enablement.

## Validation Gates
- Deterministic output for identical input/query/budget.
- At least 30% token reduction vs non-compressed body mode on long functions.
- No regression in critical-context completeness for benchmark cases.
- End-to-end command latency remains acceptable for interactive use.

## Risks and Mitigations
- Cross-block dependency loss: add conservative keep-rules for defining/used symbols.
- Over-aggressive compression: ship with explicit opt-in mode first.
- Complexity creep: keep scoring heuristics simple and documented.
