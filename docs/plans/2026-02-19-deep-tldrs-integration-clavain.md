# Plan: Deep tldrs Integration in Clavain Workflows

**Bead:** `iv-spad`
**Date:** 2026-02-19

## Inputs
- Vision brainstorm (P2 capability): `hub/clavain/docs/brainstorms/2026-02-14-clavain-vision-philosophy-brainstorm.md`
- Related context-efficiency research: `docs/research/token-efficiency-agent-orchestration-2026.md`

## Goal
Make tldrs the default code-context engine for Clavain’s code-reading-heavy workflows, with domain-aware context routing and measurable token/quality impact.

## Scope
- Identify Clavain stages where tldrs should be the default path.
- Define fallback behavior when tldrs is unavailable or low-confidence.
- Introduce plan/domain-aware context shaping for specialist agents.
- Track outcome impact (not only token reduction).

## Milestones
1. Integration matrix
Map commands/skills/phases to required context type and tldrs operation (find/context/impact/slice).

2. Adapter implementation
Implement reusable adapter wrappers so workflows call tldrs consistently with bounded output contracts.

3. Domain-aware context policy
Add context routing rules by agent domain (security/perf/architecture/etc.) with configurable profiles.

4. Fallback + safety
Add deterministic fallback to direct file reads when tldrs is unavailable or confidence is low.

5. Measurement and tuning
Evaluate token, latency, and quality effects; tune policies from observed outcomes.

## Dependency Plan
- Existing dependency on `iv-mb6u` is already satisfied.
- Coordinate with measurement work so routing changes are judged by outcome metrics.

## Validation Gates
- Target workflows run successfully with tldrs-first routing.
- Clear reduction in context/token overhead without quality regression.
- Fallback path proven on representative failure scenarios.

## Risks and Mitigations
- Over-routing to compressed context: include confidence thresholds and fallback.
- Integration drift across workflows: centralize adapter logic and contracts.
- Outcome-blind optimization: require quality and human-override metrics in evaluation.
