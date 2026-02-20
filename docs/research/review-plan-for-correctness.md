# Correctness Review: Reflect Phase Sprint Integration Plan
**Reviewed:** 2026-02-20
**Plan file:** `/root/projects/Interverse/docs/plans/2026-02-20-reflect-phase-sprint-integration.md`
**Reviewer role:** Julik (data integrity + concurrency)

---

## Invariants That Must Hold

Before listing findings, here are the invariants the plan must preserve. Every finding below is a violation or a threat to one of these.

1. **Single advance owner per phase boundary.** Exactly one code path must fire the `reflect → done` advance. Two callers = double-advance = state corruption.
2. **State before reference.** If `sprint.md` invokes `/reflect` and `/reflect` reads or creates `reflect.md`, then `reflect.md`'s content must be stable before `sprint.md`'s step proceeds.
3. **Idempotent re-entry.** A resume that lands mid-reflect must not duplicate the artifact registration or double-fire the advance.
4. **Resume routing completeness.** The sprint resume routing table must cover every phase reachable by a live sprint. Missing entries silently strand the user.
5. **Checkpoint step list matches actual steps.** If checkpoint records `reflect` as a step name, the `--from-step` parser and the resume router must also know that name. Gaps cause silent re-execution of already-completed steps.
6. **Precondition gate matches the phase the sprint command sets.** If sprint advances to `reflect` before calling `/reflect`, then `/reflect`'s precondition must accept `reflect` (not `shipping`). Any weaker check leaves a window where `/reflect` runs on the wrong phase.
7. **Soft-gate graduation criterion is defined and enforced.** A "graduate to hard gate after 10 sprints" rule that is never enforced is not a gate; it is a comment.

---

## Findings

### F1 (Critical) — Double-Advance Hazard: sprint.md calls advance_phase for reflect, then /reflect also advances reflect → done

**Location:** Task 7, Step 2 (proposed sprint.md Step 9) and reflect.md Step 4.

**What the plan says:**

Task 7 inserts this into sprint.md Step 9:
```bash
advance_phase "$CLAVAIN_BEAD_ID" "reflect" "Entering reflect phase" ""
```
Then the step says: "Run `/reflect` — it captures learnings, registers the artifact, and advances `reflect → done`."

reflect.md Step 4 (existing, not changed by this plan) reads:
```bash
sprint_advance "<sprint_id>" "reflect"
```

The plan's ownership note says: "`/reflect` owns both artifact registration AND the `reflect → done` advance. Do NOT call `advance_phase` after `/reflect` returns."

**The problem:**

The plan instructs the implementor NOT to call `advance_phase` again after `/reflect` returns — but it DOES call `advance_phase("reflect")` BEFORE calling `/reflect`. That call transitions `shipping → reflect`. Then `/reflect` calls `sprint_advance("reflect")`, which transitions `reflect → done`. These are different transitions, so on the happy path they are not a double-advance.

However, there is a second, subtler issue: the plan uses `advance_phase` (from `lib-gates.sh`) for the `shipping → reflect` transition, and `sprint_advance` (from `lib-sprint.sh`) inside `/reflect` for `reflect → done`. These are two different functions backed by two different systems:

- `advance_phase` is a shim that delegates to the interphase plugin's `advance_phase`, which operates on the bead's phase field via beads.
- `sprint_advance` (when intercore is available) delegates to `intercore_run_advance`, which advances the ic run's phase chain.

The result is that the `shipping → reflect` transition is recorded against the beads layer only (via `advance_phase`), while the `reflect → done` transition is recorded against both layers (via `sprint_advance`). This asymmetry means:

- The ic run's phase chain stays at `shipping` until `/reflect` fires, because `advance_phase` does not touch ic.
- When `/reflect` calls `sprint_advance("reflect")`, intercore sees the run still at `shipping`, not `reflect`. `intercore_run_advance` walks the chain one step from `shipping` → `reflect`, not from `reflect` → `done`.

**Concrete failure sequence:**

1. Sprint is at `shipping` (ic run phase = `shipping`, bead phase = `shipping`).
2. sprint.md Step 9 calls `advance_phase "$CLAVAIN_BEAD_ID" "reflect" "..."` — bead phase becomes `reflect`, ic run phase stays `shipping`.
3. sprint.md Step 9 calls `/reflect`.
4. `/reflect` Step 1 reads the bead phase: sees `reflect`. Precondition passes.
5. `/reflect` Step 4 calls `sprint_advance("<sprint_id>" "reflect")`.
6. `sprint_advance` reads `ic_run_id`, calls `intercore_run_advance`.
7. Intercore advances ic run from `shipping` → `reflect`. This is a re-advance into a phase the OS already declared done.
8. The ic run is now at `reflect`, not `done`. The sprint is stuck.

**Correct fix:**

The `shipping → reflect` advance must go through `sprint_advance("shipping")` (not `advance_phase`), so both layers move together. Then `/reflect` calls `sprint_advance("reflect")` to move both layers to `done`. This keeps the two systems in lockstep.

Replace the proposed snippet in sprint.md Step 9:
```bash
# WRONG — only advances beads layer, leaves ic run at shipping
advance_phase "$CLAVAIN_BEAD_ID" "reflect" "Entering reflect phase" ""
```
with:
```bash
# Correct — advances both ic run and bead together
export SPRINT_LIB_PROJECT_DIR="."; source "${CLAUDE_PLUGIN_ROOT}/hooks/lib-sprint.sh"
sprint_advance "$CLAVAIN_BEAD_ID" "shipping" ""
```

---

### F2 (Critical) — Precondition Timing: reflect.md's precondition change is logically correct but the gate closure window is non-zero

**Location:** Task 3 (reflect.md line 18).

**Current precondition:** accepts `shipping` or `reflect`.
**Proposed precondition:** accepts `reflect` only.

This change is correct in intent: once sprint.md is the sole entry point that advances `shipping → reflect`, `/reflect` should not need to accept `shipping`. However, there is a race window during the rollout where:

- Old sprint.md (pre-plan) does NOT advance `shipping → reflect` before calling `/reflect`.
- New reflect.md (post-Task-3) only accepts `reflect`.

If a sprint session is mid-flight when the rollout deploys — specifically if it already passed quality-gates and is sitting at `shipping` waiting for the user to invoke `/reflect` manually — the next session that resumes will route to `/reflect` via `sprint_next_step("shipping") = "reflect"`, but the phase is still `shipping`. The new precondition will reject it.

**Severity:** This is a correctness hazard only during rollout overlap. It becomes permanent if any code path still invokes `/reflect` directly without the sprint command having first advanced to `reflect`. The plan does not audit all call sites of `/reflect`.

**Correct fix:**

Before tightening the precondition in Task 3, verify (or document as an assumption) that no user-facing documentation or command routes to `/reflect` when the sprint is in `shipping`. The plan notes "sprint command is responsible for advancing `shipping → reflect` before invoking `/reflect`" — but this only becomes true after Task 7 is complete and deployed. The plan's sequencing (Task 3 before Task 7) is correct, but the rollout order matters: both must be deployed atomically, or the precondition tightening must be in the same commit as the sprint.md change.

The plan puts reflect.md changes in Task 3-6 and sprint.md changes in Task 7-10, with separate commits. This means there is a window between commit `feat: update /reflect — precondition, idempotency, C1 path, ic artifact (F3)` and commit `feat: add Step 9 Reflect to sprint command` during which the system is broken: `/reflect` refuses `shipping` but no code has yet advanced to `reflect` before calling it.

**Correct fix:** Either combine the precondition tightening with the sprint.md change in one atomic commit, or keep the dual-accept precondition until both commits land, then do a follow-up commit that removes `shipping` from the accepted states.

---

### F3 (High) — Resume Routing Gap: the routing table at lines 30-37 of sprint.md has no `reflect` entry after Task 9

**Location:** Task 9, Step 1.

**What the plan says:**

The plan says to add:
```
- `reflect` → `/reflect`
```
after the existing `ship → /clavain:quality-gates` entry. The plan then hedges ("Wait — the current routing at line 36 says `ship` maps to quality-gates, which is actually the command for the shipping phase. Check if the `reflect` command route is already handled.") and leaves the resolution uncertain.

**What the actual code says (sprint.md lines 31-37):**
```
- `brainstorm` → `/clavain:brainstorm`
- `strategy` → `/clavain:strategy`
- `write-plan` → `/clavain:write-plan`
- `flux-drive` → `/interflux:flux-drive <plan_path from sprint_artifacts>`
- `work` → `/clavain:work <plan_path from sprint_artifacts>`
- `ship` → `/clavain:quality-gates`
- `done` → tell user "Sprint is complete"
```

`reflect` is not in this table. `sprint_next_step("shipping")` returns `"reflect"` (confirmed in lib-sprint.sh line 602). When a sprint resumes at `shipping`, the step name is `"reflect"`, which falls through the routing table with no match. The routing falls off silently with no command dispatched.

**Failure mode:**

User resumes a sprint that is at `shipping`. The resume router calls `sprint_next_step("shipping")` = `"reflect"`. No branch in the routing table matches `"reflect"`. The sprint resume silently does nothing or falls through to Work Discovery, restarting from scratch. The user loses the sprint context.

This is a 3 AM incident: the sprint is complete except for reflect, the user resumes the next day, and the sprint command acts as if nothing is in flight.

**Correct fix:**

Task 9 must unconditionally add the `reflect` entry to the routing table. The plan's hedging language ("Wait — check if...") means the implementor may skip this step if they misread the existing table. Make the addition mandatory, not conditional.

---

### F4 (High) — Checkpoint Step Name Missing: `reflect` is not in the Step Names list at line 134 until Task 8, but Task 8 is incomplete on this point

**Location:** Task 8, Step 2.

**What the plan says:**

Task 8, Step 2 changes line 134 from:
```
Step names: `brainstorm`, `strategy`, `plan`, `plan-review`, `execute`, `test`, `quality-gates`, `resolve`, `ship`.
```
to:
```
Step names: `brainstorm`, `strategy`, `plan`, `plan-review`, `execute`, `test`, `quality-gates`, `resolve`, `reflect`, `ship`.
```

This is correct for the Session Checkpointing section. However, the plan also updates `--from-step` (Task 8, Step 3, line 113) to include `reflect` before `ship`. These two updates are consistent.

**Gap:** The Session Checkpointing section (line 144) says:
```
When the sprint completes (Step 9 Ship), clear the checkpoint
```

After renumbering, Ship becomes Step 10. If the session checkpointing code references "Step 9 Ship" by step number (not name), the checkpoint clear will fire one step early — after reflect, not after ship. The plan does not update this line.

**Impact:** If the checkpoint is cleared after reflect completes (the old Step 9), the user cannot resume from ship if the session dies between reflect and ship. Minor but a correctness regression in the recovery path.

**Correct fix:** Task 8 should add a sub-step: find and update the "When the sprint completes (Step 9 Ship)" reference to "Step 10 Ship".

---

### F5 (High) — Idempotency Check Uses 2>/dev/null Suppression on the Value-Returning Path

**Location:** Task 4, Step 1 (idempotency check snippet).

**The proposed snippet:**
```bash
source hub/clavain/hooks/lib-sprint.sh
existing=$(sprint_get_artifact "<sprint_id>" "reflect" 2>/dev/null) || existing=""
```

`sprint_get_artifact` is called with `2>/dev/null` to suppress errors, and `|| existing=""` to handle non-zero exit. This is correct for suppressing stderr noise. However, the idempotency check then says:

"If `existing` is non-empty, report 'Reflect artifact already registered: <existing>. Skipping to advance.' and jump to step 4 (advance)."

Step 4 calls `sprint_advance("<sprint_id>" "reflect")`. This is correct: if the artifact was already registered but the advance never fired (e.g., the session died between registration and advance), re-running should still advance.

**The actual bug:** `sprint_get_artifact` is not defined anywhere in the reviewed codebase. The existing lib-sprint.sh defines `sprint_set_artifact`. There is no `sprint_get_artifact` function visible in the grep results. If `sprint_get_artifact` does not exist, the call silently returns empty string (because of `2>/dev/null || existing=""`), making the idempotency check a no-op that always re-runs the artifact registration.

The correct function to query an artifact from beads state would be something like:
```bash
existing=$(bd state "<sprint_id>" "artifact_reflect" 2>/dev/null) || existing=""
```
or equivalent — depending on how `sprint_set_artifact` actually stores the value.

**This is a silent correctness failure:** the idempotency check never fires, so every `/reflect` re-run re-invokes engineering-docs, writes a second artifact, and calls `sprint_set_artifact` a second time. For C3+ runs this means duplicate engineering docs and potentially duplicate intercore artifact registrations.

**Correct fix:** Before merging Task 4, verify `sprint_get_artifact` exists in lib-sprint.sh (or add it). If it does not exist, use the correct beads state key that `sprint_set_artifact` writes to.

---

### F6 (Medium) — Soft Gate Graduation Criterion Is Unenforceable as Written

**Location:** Task 7, Step 2, soft gate note.

**The plan says:**

"Soft gate: On initial shipment, emit a warning but allow advance if no reflect artifact exists. Graduate to hard gate after 10 successful reflect phases across sprints."

There is no mechanism described for:
- Counting successful reflect phases across sprints.
- Storing that counter.
- Checking the counter before deciding soft vs. hard.
- Who fires the promotion (a hook? a manual operator action? an ic run config field?).

This is a deferred design posture masquerading as an implemented rule. As written, the graduation never happens because nothing counts, stores, or checks the threshold. The gate stays soft indefinitely.

**Severity:** This is not a 3 AM incident by itself, but it means the "gate-enforced learning step" advertised in the plan's goal is not actually enforced during early adoption. A team shipping without reflect will see warnings and proceed — which is precisely the behavior the plan claims to prevent.

**Correct fix:** Either (a) implement the counter (e.g., store `reflect_count` on the project-level bead or an ic config field, increment it in the success path, gate-check it on entry), or (b) remove the graduation language and accept that the gate is always soft until a future plan hardens it. Vague graduation criteria are worse than explicit soft gates because they create false confidence.

---

### F7 (Medium) — Intercore Artifact Registration Silently Skipped When run_id Is Absent

**Location:** Task 6, Step 1 (new step 3 in reflect.md).

**The proposed snippet:**
```bash
run_id=$(bd state "<sprint_id>" run_id 2>/dev/null) || run_id=""
if [[ -n "$run_id" ]]; then
    ic run artifact add "$run_id" --phase=reflect --path="<path_to_doc>" 2>/dev/null || true
fi
```

This is guarded correctly — if there is no ic run, fall through to beads-only path. However, the comment says "enables gate check" for the kernel path. The kernel's `CheckArtifactExists` gate fires against ic run artifacts. If `run_id` is empty (e.g., the sprint was created before intercore integration), the artifact is registered only in beads — and the kernel gate will never pass because it checks ic, not beads.

**Failure mode:** A sprint created without an ic run (legacy path, or ic unavailable at creation time) goes through reflect, registers the artifact in beads, but the kernel's gate fires on `done` advance because the ic artifact is missing. The sprint is permanently stuck at `reflect` unable to advance to `done` through the normal path.

The `2>/dev/null || true` on the `ic` command means this failure is completely silent.

**Correct fix:** If `run_id` is empty, log a warning to stderr: "No ic run linked to sprint — kernel gate check will not see this artifact. Proceed with beads-only registration." This at least makes the condition visible in the session output.

---

### F8 (Low) — Task Sequencing Note Says "F3 must ship before F1" But Commits Are Separate

**Location:** Plan Sequencing section.

**The plan says:**

"F3 must ship before F1 because the sprint step invokes `/reflect`."

But Task 6, Step 2 commits reflect.md changes, and Task 10, Step 2 commits sprint.md changes in a later commit. The commits are on the same repo (`hub/clavain`). If both commits land in the same push, the ordering is fine. If they land separately (e.g., Task 3-6 commit is merged, then the implementor is interrupted before Task 7-10), there is a window where reflect.md accepts only `reflect` phase but sprint.md still shows `shipping` → Ship (no reflect step). In this window, sprints proceed from quality-gates directly to ship with no reflect. The reflect gate is "not skippable" per the goal, but during the deployment window it is effectively absent.

**Correct fix:** Document this deployment constraint explicitly: "Commits from Task 3-6 and Task 7-10 must be deployed atomically. Do not merge the reflect.md commit without immediately following with the sprint.md commit in the same session."

---

### F9 (Low) — `sprint_advance` Called With Argument "reflect" in /reflect Step 4 But `sprint_advance` Signature Expects `current_phase`

**Location:** reflect.md (current), Step 4.

**Current reflect.md Step 4:**
```bash
sprint_advance "<sprint_id>" "reflect"
```

**lib-sprint.sh `sprint_advance` signature (line 650-651):**
```bash
sprint_advance() {
    local sprint_id="$1"
    local current_phase="$2"
```

The second argument is `current_phase`. Passing `"reflect"` is correct: it tells `sprint_advance` that the sprint is currently at `reflect`, and the function uses the transition table to compute `done` as the next phase. This is not a bug — it is correct usage.

However, the plan's Task 4 idempotency shortcut says "jump to step 4 (advance)" without re-checking that the current phase is actually `reflect` at the time of the jump. If the artifact was already registered AND the advance already fired (i.e., the sprint is already at `done`), calling `sprint_advance("<sprint_id>" "reflect")` will try to advance from `reflect` to `done` again on a sprint that is already `done`. In the ic path, `intercore_run_advance` will reject this (ic run is already terminated or at final phase). In the beads fallback path, `_sprint_transition_table("done")` returns `"done"`, which hits the guard `"$next_phase" == "$current_phase"` at line 707 and returns 1. The beads fallback is safe. The ic path behavior depends on intercore's response to advancing a completed run — if it returns an error, `sprint_advance` surfaces it. If it silently succeeds, the run is in an undefined state.

**Correct fix in Task 4:** Before jumping to step 4, verify the actual current phase is `reflect`, not `done`. If it is already `done`, report "Sprint already complete" and stop cleanly.

---

## Summary Table

| ID | Severity | Area | One-line Description |
|----|----------|------|----------------------|
| F1 | Critical | Concurrency / Layer mismatch | `advance_phase` (beads) before `/reflect` leaves ic run at `shipping`; `sprint_advance("reflect")` inside `/reflect` advances ic `shipping→reflect` instead of `reflect→done` |
| F2 | Critical | Deployment ordering | Precondition tightening (Task 3) and sprint entry point addition (Task 7) must be atomic; separate commits create a window where the system is broken |
| F3 | High | Resume routing | `reflect` step name missing from sprint resume routing table; resume at `shipping` silently drops the sprint |
| F4 | High | Checkpoint correctness | "When sprint completes (Step 9 Ship)" reference not updated; checkpoint clears one step early after renumbering |
| F5 | High | Idempotency | `sprint_get_artifact` likely does not exist; idempotency check is a silent no-op, allowing duplicate artifact registration on re-run |
| F6 | Medium | Gate enforcement | Soft-gate graduation criterion ("10 sprints") has no implementation, counter, or enforcement mechanism |
| F7 | Medium | Error visibility | Silent `|| true` on ic artifact add means legacy sprints (no run_id) silently fail kernel gate check, stuck at `reflect` |
| F8 | Low | Deployment ordering | F3/F1 deployment atomicity constraint is documented in sequencing note but not enforced in commit strategy |
| F9 | Low | Edge case | Idempotency jump to step 4 does not guard against sprint already at `done`; benign on beads path, undefined on ic path |

---

## Recommended Actions Before Implementation

1. **Fix F1 first.** Replace the `advance_phase "reflect"` call in the proposed sprint.md Step 9 with `sprint_advance "$CLAVAIN_BEAD_ID" "shipping" ""`. This is the correct way to advance both the beads layer and the ic layer together.

2. **Merge Task 3-6 and Task 7-10 into one commit (or enforce atomic deployment).** The broken window between precondition tightening and sprint entry point addition is a real production risk for any sprint that was mid-flight at `shipping`.

3. **Add `reflect` to the sprint resume routing table unconditionally in Task 9.** Remove the hedging language; the entry is missing, it must be added.

4. **Add `sprint_get_artifact` to lib-sprint.sh, or replace the idempotency check with the correct beads state key.** The current snippet calls a function that does not exist.

5. **Either implement the soft-gate counter or remove the graduation language.** A gate that never hardens is not a gate.

6. **Add a warning log when `run_id` is empty during ic artifact registration.** Silent failure on legacy sprints should not be the default.

7. **Update "Step 9 Ship" → "Step 10 Ship" in the checkpoint clear comment** as part of Task 8.
