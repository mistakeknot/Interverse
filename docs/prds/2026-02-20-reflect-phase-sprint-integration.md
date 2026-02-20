# PRD: Reflect Phase Sprint Integration

**Bead:** iv-8jpf
**Date:** 2026-02-20
**Status:** Active
**Reviewed:** flux-drive (architecture, correctness, user-product) — 2026-02-20

## Problem

The Clavain sprint lifecycle has a kernel-level reflect phase (intercore already ships `PhaseReflect`, gate rules, and a **9-phase** `DefaultPhaseChain`) but the OS layer doesn't enforce it. The `/reflect` command exists standalone but isn't wired into the `/sprint` flow. The result: reflection is skippable by default, undermining the recursive self-improvement loop that justifies Clavain's existence.

## Solution

Wire the reflect phase end-to-end: update the sprint command to include a formal reflect step, ensure the `/reflect` command registers artifacts that satisfy the kernel gate, and align documentation with the 5-macro-stage model.

**Scope decision (from flux-drive review):** The `shipping → polish` rename (F2b) is deferred to a separate bead due to migration risk. This PRD ships the reflect wiring using the existing OS phase names. The OS chain and kernel chain will remain divergent for now — this is an accepted pre-existing condition, not introduced by this PRD.

## Phase Chain Reference

**Kernel `DefaultPhaseChain` (9 phases, source of truth):**
```
brainstorm → brainstorm-reviewed → strategized → planned → executing → review → polish → reflect → done
```

**OS `PHASES_JSON` (9 phases, custom chain passed to `ic run create`):**
```
brainstorm → brainstorm-reviewed → strategized → planned → plan-reviewed → executing → shipping → reflect → done
```

**Divergences (accepted, documented):**
- OS has `plan-reviewed` (kernel doesn't) — OS-only phase for flux-drive plan review gate
- OS has `shipping` (kernel has `polish`) — historical name, rename deferred to F2b
- OS lacks `review` (kernel has it) — quality gates are enforced by sprint command, not kernel gate rules

**Gate rule coverage:** The kernel gate rule `{PhaseReflect, PhaseDone}: CheckArtifactExists` fires correctly for both chains because both use `reflect` and `done` as the final two phases. All other kernel gate rules are keyed to kernel phase names and do not fire for OS-created sprints (pre-existing condition).

## Features

### F1: Sprint Command Reflect Step

**What:** Add a formal "Step 9: Reflect" to the sprint command, between Resolve (current Step 8) and Ship (current Step 9, becomes Step 10).

**Phase-advance ownership:** `/reflect` owns both artifact registration AND the `reflect → done` advance. The sprint command advances `shipping → reflect` before invoking `/reflect`, then does NOT call `advance_phase` after `/reflect` returns. This prevents the double-advance hazard.

**Acceptance criteria:**
- [ ] Sprint command (`commands/sprint.md`) includes Step 9: Reflect that invokes `/reflect`
- [ ] Sprint command advances `shipping → reflect` via `advance_phase` BEFORE calling `/reflect`
- [ ] Sprint command does NOT call `advance_phase` after `/reflect` returns (ownership is with `/reflect`)
- [ ] Step 10 (Ship, renumbered) is gated on the reflect artifact (enforced by `/reflect`'s internal advance)
- [ ] `--from-step` argument accepts `reflect` as a valid step name
- [ ] Session Checkpointing step name list includes `reflect` after `resolve`
- [ ] Sprint Resume routing table maps `reflect` → `/reflect`
- [ ] Sprint Summary step count updated from 9 to 10
- [ ] Sprint error recovery section updated to reference the new step count

**Gate hardness:** Soft gate on initial shipment (emit warning but allow advance if no reflect artifact). Graduate to hard gate after 10 successful reflect phases across sprints.

### F2a: Add reflect Transitions (no rename)

**What:** Verify that `lib-sprint.sh` transition table and phase whitelists correctly handle the `shipping → reflect → done` path. (Most of this is already implemented — verify and fix any gaps.)

**Acceptance criteria:**
- [ ] `_sprint_transition_table("shipping")` returns `"reflect"` (verify existing)
- [ ] `_sprint_transition_table("reflect")` returns `"done"` (verify existing)
- [ ] `sprint_phase_to_command("reflect")` returns `"reflect"` (verify existing)
- [ ] `sprint_phase_whitelist()` includes `reflect` for all complexity levels (verify existing)
- [ ] `lib-gates.sh` fallback `CLAVAIN_PHASES` array includes `reflect` (verify existing)
- [ ] `sprint-scan.sh` phase array includes `reflect` (verify existing)

### F2b: Phase Rename (`shipping` → `polish`) — DEFERRED

**What:** Rename `shipping` to `polish` in the OS layer to align with the kernel. **Deferred to a separate bead** due to migration risk identified in flux-drive review.

**Why deferred:** Renaming without migration corrupts all existing sprints at `phase=shipping` in beads. Requires: (1) migration script for beads state, (2) migration for ic run `phases` JSON in SQLite, (3) atomic update of 7+ files (transition table, phase whitelist, both lib-gates.sh, sprint.md, reflect.md, sprint-scan.sh). This is a separate work item with its own risk profile.

### F3: Reflect Command Artifact Registration

**What:** Ensure `/reflect` registers its output as a reflect-phase artifact in the intercore run, satisfying the kernel gate for `reflect → done`.

**Acceptance criteria:**
- [ ] `/reflect` calls `ic run artifact add <run> --phase=reflect --path=<doc>` after writing the engineering doc
- [ ] If no active intercore run, `/reflect` falls back to `sprint_set_artifact` (beads-only path)
- [ ] Gate check `ic gate check <run>` passes after `/reflect` completes (verifying the `reflect → done` gate)
- [ ] `/reflect` precondition updated: accept sprint at `reflect` phase only (not `shipping or reflect`)
- [ ] `/reflect` checks for existing reflect artifact before invoking engineering-docs (idempotent on re-run)
- [ ] C1 lightweight path: for complexity 1-2, `/reflect` registers a brief memory note directly instead of invoking the full engineering-docs skill
- [ ] "Clean sprint" artifact type defined: complexity calibration note satisfies C1 gate when no novel learnings exist

**Note:** Complexity-scaled gate thresholds (C2=non-empty content, C3=solution doc path) are future Interspect work. Current kernel gate is binary: artifact exists or not.

### F4: Documentation Alignment

**What:** Update all lifecycle documentation to reflect the 5-macro-stage model consistently.

**Acceptance criteria:**
- [ ] `docs/glossary.md` macro-stage table includes Reflect with sub-phase mapping
- [ ] `hub/clavain/AGENTS.md` sprint lifecycle references updated
- [ ] `infra/intercore/AGENTS.md` — fix Go comment "10-phase" → "9-phase"; fix AGENTS.md phase count
- [ ] `infra/intercore/internal/phase/phase.go` line 64 — fix comment "10-phase" → "9-phase"
- [ ] `hub/clavain/docs/clavain-vision.md` lifecycle description matches
- [ ] No remaining references to "8 phases" or "4 macro-stages" in active docs

### F5: Sprint-to-Kernel Phase Mapping Table

**What:** Document the OS ↔ kernel phase name mapping so both layers stay synchronized.

**Acceptance criteria:**
- [ ] Canonical phase mapping table added to `docs/glossary.md` showing OS name ↔ kernel name for every phase
- [ ] Divergent phase names (`plan-reviewed`, `shipping`) documented with rationale for their existence
- [ ] Table notes that `plan-reviewed` is OS-only (kernel has no equivalent) and `shipping` maps to kernel's `polish`

## Non-goals

- **Phase rename (`shipping` → `polish`) in this iteration.** Deferred to F2b (separate bead) with migration plan.
- **Custom reflect artifacts per complexity level in kernel gate.** The kernel gate supports only `CheckArtifactExists`. Complexity-scaled quality checks are a future Interspect concern.
- **Kernel gate alignment for OS-specific phases.** The pre-existing condition where OS phase names don't trigger kernel gates is out of scope. A future bead should add `{executing, shipping}` gate rules to the kernel.
- **Interspect integration.** iv-rafa (meta-learning loop) is blocked by this bead but handled separately.
- **Multi-agent reflect.** Deferred.
- **Reflect-phase Autarch UI.** iv-1d9u handles Bigend dashboard metrics separately.

## Dependencies

- **intercore kernel** — Already ships `PhaseReflect`, gate rules, 9-phase chain. No kernel changes needed (except fixing the "10-phase" comment in F4).
- **`/compound` and `engineering-docs` skill** — Already exist as reflect-phase artifact producers for C2+ sprints.
- **beads CLI (`bd`)** — Phase tracking via `advance_phase`.

## Resolved Questions (from flux-drive review)

1. **Phase count:** The kernel has **9 phases**, not 10. The Go comment, AGENTS.md, and this PRD's original draft were wrong. Corrected throughout.
2. **Phase-advance ownership:** `/reflect` owns both artifact registration and the `reflect → done` advance. The sprint command only advances `shipping → reflect`.
3. **F3 gate thresholds:** C2/C3 thresholds removed from F3 acceptance criteria. Current gate is binary (artifact exists). Complexity scaling is future Interspect work.
4. **Soft vs hard gate:** Ships soft, graduates to hard after validation period.
5. **F2 split:** F2a (verify existing transitions) ships with this PRD. F2b (rename) is a separate bead.

## Open Questions

1. **Should `plan-reviewed` eventually enter the kernel chain?** Two options: (A) remove from OS chain and absorb into `ic run skip`, or (B) add `PhasePlanReviewed` to kernel with gate rules. Deferred — does not affect reflect phase wiring.
2. **How should `/reflect` handle context compaction?** If the session's conversation history was compressed before the reflect phase, the engineering-docs skill may lack context. Should `/reflect` pass explicit context from the sprint's artifact list?

## Sequencing

```
F2a (verify transitions) → F3 (artifact registration) → F1 (sprint step) → F4 (docs) → F5 (mapping table)
```

F2a is a verification pass (mostly already done). F3 must ship before F1 because the sprint step invokes `/reflect`. F4 and F5 are parallel with F1.

## Review Artifacts

- `docs/research/architecture-review-reflect-phase-prd.md`
- `docs/research/correctness-review-of-prd.md`
- `docs/research/user-product-review-of-prd.md`
