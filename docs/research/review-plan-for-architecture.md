# Architecture Review: Reflect Phase Sprint Integration Plan
**Plan file:** `docs/plans/2026-02-20-reflect-phase-sprint-integration.md`
**PRD:** `docs/prds/2026-02-20-reflect-phase-sprint-integration.md`
**Reviewed:** 2026-02-20
**Reviewer role:** Flux-drive Architecture & Design Reviewer

---

## Context and Scope

This review evaluates an implementation plan that wires the kernel's existing `PhaseReflect` into the Clavain OS sprint flow. The three-layer model is:

- **Layer 1 (kernel):** `infra/intercore` — `ic` binary, Go, SQLite-backed phase state machine. `PhaseReflect`, `CheckArtifactExists` gate rule, `DefaultPhaseChain`, and `ic run artifact add` already exist.
- **Layer 2 (OS):** `hub/clavain` — Bash (`lib-sprint.sh`, `commands/sprint.md`, `commands/reflect.md`). The sprint command orchestrates steps; `/reflect` is the command that produces learning artifacts.
- **Layer 3 (apps):** Autarch — not touched.

The plan's 14 tasks cover: verification of existing transitions (Tasks 1-2), updates to `/reflect` command (Tasks 3-6), updates to sprint command (Tasks 7-10), and documentation (Tasks 11-14). The PRD explicitly accepts OS-kernel phase name divergence (`shipping` vs `polish`, `plan-reviewed` has no kernel equivalent) and defers the rename to a separate bead.

---

## Summary Assessment

The plan is structurally appropriate for a small wiring change. Layer boundaries are respected: the kernel receives no behavioral changes (only a stale comment fix), and all OS changes are contained to the sprint and reflect commands plus their shared library. The change surface is proportional to the problem.

Four issues require attention before implementation. Two are must-fix correctness problems: the wrong phase-advance function in Task 7, and a reference to a non-existent library function in Task 4. One is a must-cut: the soft-gate graduation mechanism in Task 7 is unimplementable with current infrastructure. One is a must-clarify: Task 6's dual artifact registration is redundant if the E3 cutover is already live.

---

## 1. Boundaries and Coupling

### 1a. Task 7 uses `advance_phase` from `lib-gates.sh` instead of `sprint_advance` from `lib-sprint.sh`

The PRD's phase-advance ownership rule (Section F1) is explicit:

> **Phase-advance ownership:** `/reflect` owns both artifact registration AND the `reflect → done` advance. The sprint command advances `shipping → reflect` before invoking `/reflect`, then does NOT call `advance_phase` after `/reflect` returns. This prevents the double-advance hazard.

Task 7, Step 2 writes the new Step 9 as:

```bash
export GATES_PROJECT_DIR="."; source "${CLAUDE_PLUGIN_ROOT}/hooks/lib-gates.sh"
advance_phase "$CLAVAIN_BEAD_ID" "reflect" "Entering reflect phase" ""
```

This uses `advance_phase` from `lib-gates.sh`. Reading the current `lib-gates.sh` confirms it is a stub:

```bash
# lib-gates.sh line 30:
advance_phase() { return 0; }
```

`advance_phase` in `lib-gates.sh` is a no-op. It will silently succeed without advancing anything. The bead phase stays at `shipping`, but the sprint command calls `/reflect` which now requires `reflect` phase (after Task 3 tightens the precondition). The result is a precondition failure on every sprint that reaches Step 9.

The correct function is `sprint_advance` from `lib-sprint.sh`, which delegates to `intercore_run_advance` when a kernel run exists, and falls back to the beads transition table when it does not. This is the pattern used at every other phase advance in `sprint.md` — for example, lines 316-326 of `commands/sprint.md`:

```bash
export SPRINT_LIB_PROJECT_DIR="."; source "${CLAUDE_PLUGIN_ROOT}/hooks/lib-sprint.sh"
# enforce_gate check...
sprint_advance "$CLAVAIN_BEAD_ID" "<current_phase>"
sprint_record_phase_completion "$CLAVAIN_BEAD_ID" "<phase>"
```

**Must-fix:** Replace the Step 9 code block in Task 7 with:

```bash
export SPRINT_LIB_PROJECT_DIR="."; source "${CLAUDE_PLUGIN_ROOT}/hooks/lib-sprint.sh"
sprint_advance "$CLAVAIN_BEAD_ID" "shipping"
sprint_record_phase_completion "$CLAVAIN_BEAD_ID" "shipping"
```

Remove the `lib-gates.sh` source line from this step. The sprint command uses `lib-sprint.sh` for all phase advances; using `lib-gates.sh` here is an inconsistency that will silently fail.

---

### 1b. Task 6 may triple-register the reflect artifact if E3 cutover is live

Task 6 adds dual artifact registration to `/reflect`:

```bash
# Kernel path: ic run artifact add (enables gate check)
run_id=$(bd state "<sprint_id>" run_id 2>/dev/null) || run_id=""
if [[ -n "$run_id" ]]; then
    ic run artifact add "$run_id" --phase=reflect --path="<path_to_doc>" 2>/dev/null || true
fi

# OS path: beads artifact (always)
sprint_set_artifact "<sprint_id>" "reflect" "<path_to_doc>"
```

`sprint_set_artifact` in `lib-sprint.sh` (lines 302-328) already does dual registration: it calls `intercore_run_artifact_add` when a run_id is available, then falls back to beads. This is the post-E3 implementation. If E3 is live when this plan is implemented, Task 6's explicit `ic run artifact add` call produces a third registration — two kernel records and one beads record for the same artifact.

If E3 is not yet live, `sprint_set_artifact` only writes to beads, and the explicit `ic run artifact add` is the only kernel registration. In that case, Task 6's code is correct.

**Must-clarify:** Task 6 must be conditioned on E3 deployment state. The safest resolution independent of E3 state: remove the explicit `ic run artifact add` block from Task 6 and rely solely on `sprint_set_artifact`. If E3 is not live at implementation time, add the kernel call inside `sprint_set_artifact` itself as part of E3 prep — do not duplicate registration logic in a Markdown command file. Document the decision in Task 6's commit message.

---

### 1c. Precondition tightening in Task 3 creates a deployment ordering constraint

Task 3 changes the `/reflect` precondition from `shipping or reflect` to `reflect` only. This is architecturally correct — `/reflect` should only run after the sprint command advances to `reflect`. However, a sprint currently at `shipping` that calls `/reflect` directly (standalone, outside the sprint command) will fail after Task 3 commits.

The plan sequences F3 (Tasks 3-6) before F1 (Tasks 7-10), which is correct. If both are committed in the same session, the window for a broken standalone `/reflect` is zero. The risk is a partial deployment where Task 3 ships without Task 7.

**Should-note:** Add a deployment gate comment to Task 3's commit: "This precondition tightening is safe only when Task 7 (sprint command Step 9) is also committed. Partial deployment leaves shipping-phase sprints unable to invoke standalone /reflect." This makes the constraint visible to anyone reviewing the git log.

---

## 2. Pattern Analysis

### 2a. Task 4 references `sprint_get_artifact` — this function does not exist in `lib-sprint.sh`

Task 4, Step 1 adds an idempotency check using:

```bash
existing=$(sprint_get_artifact "<sprint_id>" "reflect" 2>/dev/null) || existing=""
```

`sprint_get_artifact` is not defined in `/root/projects/Interverse/hub/clavain/hooks/lib-sprint.sh`. A search across the file finds no match for this function name. The existing API provides `sprint_set_artifact` for writing and `sprint_read_state` for reading all artifact state via JSON.

The correct way to check for an existing reflect artifact using current APIs is to parse the output of `sprint_read_state`:

```bash
state=$(sprint_read_state "$sprint_id" 2>/dev/null) || state="{}"
existing=$(echo "$state" | jq -r '.artifacts.reflect // ""' 2>/dev/null) || existing=""
```

**Must-fix:** Replace the `sprint_get_artifact` call in Task 4 with a `sprint_read_state` parse. Alternatively, if the plan intends for `sprint_get_artifact` to be added as part of this bead, that addition must be made explicit as a new task that adds the function to `lib-sprint.sh` with the appropriate ic-backed and beads-fallback implementations. As written, the idempotency check will fail with "command not found" at runtime.

---

### 2b. Task 5 reads complexity via direct `bd state` call, bypassing `sprint_read_state`

Task 5 adds complexity-aware branching to `/reflect`:

```bash
complexity=$(bd state "<sprint_id>" complexity 2>/dev/null) || complexity="3"
```

This is a direct beads state read from inside a Markdown command file. The established OS pattern for reading sprint state is `sprint_read_state`, which already returns the `complexity` field in its JSON output (confirmed, `lib-sprint.sh` lines 286-299 include `complexity` in the assembled state object). A direct `bd state` call bypasses the kernel-backed primary path: if an intercore run exists, `sprint_read_state` reads complexity from ic state; the `bd state` call reads only from beads and will return the value only if it was explicitly written there.

**Should-fix:** Replace the `bd state` call with:

```bash
state=$(sprint_read_state "$sprint_id" 2>/dev/null) || state="{}"
complexity=$(echo "$state" | jq -r '.complexity // "3"' 2>/dev/null) || complexity="3"
```

This is consistent with how the sprint command reads phase and artifact state, and correctly follows the kernel-first path established by the E3 cutover.

---

### 2c. Task 9 resume routing is hedged — the `reflect` entry is unconditionally required

Task 9, Step 1 adds `reflect → /reflect` to the sprint resume routing table but includes uncertainty language: "Verify there's no explicit `reflect` routing needed... Add `reflect` if missing."

Reading `sprint.md` lines 30-37 confirms `reflect` is not in the current routing table. `sprint_next_step("reflect")` returns `"reflect"` (confirmed, `lib-sprint.sh` line 602). Without a routing entry, a sprint resumed at the reflect phase has no match in the routing table, producing undefined behavior in the sprint command's LLM-interpreted Markdown.

**Minor fix:** Harden Task 9, Step 1: state positively that `reflect → /reflect` is absent from the current routing table and must be added. Remove the conditional framing.

---

## 3. Simplicity and YAGNI

### 3a. Task 7's soft-gate graduation mechanism is unimplementable with current infrastructure

Task 7, Step 2 includes:

```markdown
**Soft gate:** On initial shipment, emit a warning but allow advance if no reflect artifact exists. Graduate to hard gate after 10 successful reflect phases across sprints.
```

The "10 successful reflect phases" graduation criterion requires a cross-sprint counter. No such counter exists in the current architecture:

- The kernel gate system (`ic gate check`, `ic gate rules`) defines static rules per phase. There is no dynamic rule elevation based on runtime history.
- Beads does not provide cross-sprint aggregate queries.
- The sprint command's Markdown file has no mechanism to persist state across invocations other than through the sprint bead or ic run.

As written, this comment describes behavior that cannot function. An LLM implementing the sprint command will attempt to implement the "10 sprint" logic on every sprint completion and fail to find a mechanism. The PRD's Section F1 also includes this language, but the PRD's non-goals and open questions do not flag it as unresolved, suggesting it was accepted without verifying implementability.

**Must-cut:** Remove the "Graduate to hard gate after 10 successful reflect phases across sprints" sentence from Task 7. Replace with: "Gate hardness: emit a warning if no reflect artifact exists but allow advance (soft gate). Gate hardness graduation is deferred to a future bead that adds cross-sprint telemetry to the kernel." This is the smallest viable change: ship soft gate now, defer the graduation mechanism to when the infrastructure exists.

---

### 3b. Tasks 12-13 documentation scope is appropriate — no over-engineering

Tasks 12-13 update `clavain-vision.md` to reflect five macro-stages and the glossary to list Reflect. The change surface is proportional: adding one section to a vision doc and updating counts. The macro-stage table and handoff contracts in Task 12 are genuinely useful for orientation — the "Ship → Reflect → next cycle" handoff chain is architectural information that does not currently exist in docs. No YAGNI concern here.

Task 14 (sprint-to-kernel phase mapping table) is the most valuable documentation addition. The OS-kernel phase name divergence is a pre-existing condition that will cause confusion every time someone reads the kernel source. Making it explicit with a table that names the divergences and their rationale is a net positive for architectural legibility. The table is proportional in size to the problem it documents.

---

### 3c. Task 1-2 (verification) are correctly scoped as non-implementation tasks

Tasks 1-2 verify that the existing transition table, phase whitelists, and lib-gates.sh fallback already include `reflect`. This is a verification pass, not implementation work. The plan correctly marks them as skippable commits ("If all verifications pass with no changes needed, skip this step").

One structural note: `lib-sprint.sh` line 78 already contains the 9-phase `PHASES_JSON` with `reflect`:

```bash
local phases_json='["brainstorm","brainstorm-reviewed","strategized","planned","plan-reviewed","executing","shipping","reflect","done"]'
```

And the transition table at lines 573-580 already has `shipping → reflect → done`. The verification tasks will likely produce no changes, which is the expected outcome stated in the plan.

---

## 4. Issue Classification

### Must-Fix (correctness risks — resolve before implementation)

| # | Location in Plan | Issue |
|---|---|---|
| 1a | Task 7, Step 2 | `advance_phase` from `lib-gates.sh` is a no-op stub; must use `sprint_advance` from `lib-sprint.sh` for `shipping → reflect` advance |
| 2a | Task 4, Step 1 | `sprint_get_artifact` does not exist in `lib-sprint.sh`; must use `sprint_read_state` and parse `.artifacts.reflect` from the JSON output |
| 3a | Task 7, Step 2 | Soft-gate graduation "after 10 successful reflect phases" is unimplementable; cut and defer to a future bead |

### Must-Clarify (preconditions that affect implementation decisions)

| # | Location in Plan | Issue |
|---|---|---|
| 1b | Task 6 | Dual artifact registration is redundant if E3 cutover is live; clarify and remove explicit `ic run artifact add` call, rely on `sprint_set_artifact` |

### Should-Fix (pattern consistency and coupling)

| # | Location in Plan | Issue |
|---|---|---|
| 2b | Task 5, Step 1 | Direct `bd state complexity` read bypasses `sprint_read_state`; use `sprint_read_state` and parse `.complexity` from JSON |
| 1c | Task 3, Step 2 | Add a deployment gate comment: precondition tightening requires Task 7 to be deployed in the same session |
| 2c | Task 9, Step 1 | Remove conditional framing; `reflect → /reflect` routing is unconditionally absent and must be added |

### Clean (no issue)

| # | Location in Plan | Assessment |
|---|---|---|
| Tasks 1-2 | Verification pass | Correctly scoped; existing code already has reflect in all required locations |
| Task 3 | Precondition update | Correct direction; narrows pre-condition to the phase the sprint command guarantees |
| Task 11 | Go comment fix | Real discrepancy confirmed: `DefaultPhaseChain` has 9 entries, comment says 10 |
| Tasks 12-14 | Documentation | Proportional to the problem; mapping table is genuinely useful |

---

## 5. Key File Locations

- Plan under review: `/root/projects/Interverse/docs/plans/2026-02-20-reflect-phase-sprint-integration.md`
- PRD: `/root/projects/Interverse/docs/prds/2026-02-20-reflect-phase-sprint-integration.md`
- Sprint command: `/root/projects/Interverse/hub/clavain/commands/sprint.md`
- Reflect command: `/root/projects/Interverse/hub/clavain/commands/reflect.md`
- Sprint state library: `/root/projects/Interverse/hub/clavain/hooks/lib-sprint.sh`
- Gate shim (no-op stubs): `/root/projects/Interverse/hub/clavain/hooks/lib-gates.sh`
- Kernel phase definition: `/root/projects/Interverse/infra/intercore/internal/phase/phase.go`
- Intercore docs: `/root/projects/Interverse/infra/intercore/AGENTS.md`
