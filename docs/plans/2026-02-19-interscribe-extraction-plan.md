# Plan: Interscribe Extraction (Knowledge Compounding)

**Bead:** `iv-sdqv`
**Date:** 2026-02-19

## Inputs
- Opportunity analysis: `docs/research/user-product-opportunity-review.md`
- Related research thread: `iv-qtcl` (relates-to)

## Goal
Produce an executable extraction and migration plan for moving compounding assets into an `interscribe` companion plugin with minimal workflow breakage.

## Scope
- Inventory assets to extract (skills, commands, hooks, research agents).
- Define target plugin boundaries and runtime ownership.
- Define migration order and compatibility bridge strategy.
- Create follow-on implementation beads with dependencies.

## Milestones
1. Source inventory
Catalog all candidate assets and current call paths (what invokes what, where coupling exists).

2. Boundary definition
Decide what must live in Clavain vs what moves to `interscribe`, including explicit interface contracts.

3. Migration sequencing
Design phased migration (scaffold, dual-run bridge, cutover, cleanup) with rollback points.

4. Compatibility and deprecation
Specify compatibility shims, alias behavior, and deprecation messaging for old entry points.

5. Execution backlog
Create implementation beads for each extraction slice and wire dependencies.

## Dependency Plan
- Keep `iv-qtcl` as a related research input, not a hard blocker.
- Add hard blockers only when implementation beads are created.

## Validation Gates
- Every extracted asset has a defined destination and owner.
- Migration order is dependency-safe and reversible.
- No user-facing command loses functionality during cutover.

## Risks and Mitigations
- Hidden coupling: require callgraph-backed inventory before cutover.
- User confusion during migration: publish explicit alias/deprecation map.
- Over-scoping: split by capability slice, not by file count.
