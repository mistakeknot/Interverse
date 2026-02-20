# Architecture Review: PRD — Reflect Phase Sprint Integration
**PRD file:** `docs/prds/2026-02-20-reflect-phase-sprint-integration.md`
**Reviewed:** 2026-02-20
**Reviewer role:** Flux-drive Architecture & Design Reviewer

---

## Context and Scope

This review evaluates the PRD for wiring the reflect phase end-to-end across the kernel (intercore, L1) and OS (Clavain, L2) layers. The PRD proposes five features:

- **F1:** Sprint Command Reflect Step — insert Step 9 (Reflect) into `commands/sprint.md`
- **F2:** Sprint Phase Chain Alignment — reconcile `lib-sprint.sh` custom chain with kernel's `DefaultPhaseChain`
- **F3:** Reflect Command Artifact Registration — wire `/reflect` to call `ic run artifact add` and satisfy the kernel gate
- **F4:** Documentation Alignment — update glossary, vision doc, and AGENTS files to the 5-stage, 10-phase model
- **F5:** Sprint-to-Kernel Phase Mapping — document and resolve the naming divergence between OS phases (`shipping`, `plan-reviewed`) and kernel phases (`polish`, `review`)

The review is grounded in the project's documented architecture: intercore is Layer 1 (mechanism, not policy), Clavain is Layer 2 (OS), companion plugins are L2 extensions. This layering is documented in `infra/intercore/AGENTS.md`, `hub/clavain/CLAUDE.md`, and `docs/glossary.md`.

---

## Ground Truth on the Phase Divergence

Before evaluating features, it is necessary to establish the actual state of the divergence because the PRD describes it imprecisely.

### Kernel's DefaultPhaseChain (current — already updated in Go source)

From `/root/projects/Interverse/infra/intercore/internal/phase/phase.go`:

```go
var DefaultPhaseChain = []string{
    PhaseBrainstorm,
    PhaseBrainstormReviewed,
    PhaseStrategized,
    PhasePlanned,
    PhaseExecuting,
    PhaseReview,
    PhasePolish,
    PhaseReflect,
    PhaseDone,
}
```

This is 9 phases. The kernel does NOT include `plan-reviewed` or `shipping`. Both `PhaseReflect` and `PhasePolish` are live constants. The gate rule `{PhaseReflect, PhaseDone}` requiring `CheckArtifactExists` is already present in `/root/projects/Interverse/infra/intercore/internal/phase/gate.go`.

### OS's Custom Chain (current — lib-sprint.sh sprint_create)

From `/root/projects/Interverse/hub/clavain/hooks/lib-sprint.sh` line 78:

```bash
local phases_json='["brainstorm","brainstorm-reviewed","strategized","planned","plan-reviewed","executing","shipping","reflect","done"]'
```

This is also 9 phases. The custom chain passes `plan-reviewed` and `shipping` as OS-defined phase names. The kernel stores and enforces this chain without knowing what those names mean.

### lib-gates.sh Fallback Array

From `/root/projects/Interverse/hub/clavain/hooks/lib-gates.sh` line 25:

```bash
CLAVAIN_PHASES=(brainstorm brainstorm-reviewed strategized planned plan-reviewed executing shipping reflect done)
```

This matches the OS custom chain, not the kernel's `DefaultPhaseChain`.

### Summary of Divergence

The kernel and OS phase chains diverge at three positions:

| Position | Kernel DefaultPhaseChain | OS Custom Chain |
|----------|--------------------------|-----------------|
| 5 | `executing` | `plan-reviewed` |
| 6 | `review` | `executing` |
| 7 | `polish` | `shipping` |
| 8 | `reflect` | `reflect` |
| 9 | `done` | `done` |

The kernel has no `plan-reviewed` phase. The OS has no `review` or `polish` phase. `shipping` in the OS maps semantically to `polish` in the kernel. `plan-reviewed` in the OS is an OS-only phase with no kernel equivalent.

The OS custom chain is passed explicitly at `ic run create` time (`--phases='[...]'`), so new sprints use the OS chain, not `DefaultPhaseChain`. This is architecturally correct — the kernel stores the chain and enforces it; the OS defines its semantics. The divergence is a documentation and operational problem, not a runtime bug for existing sprints.

The critical implication: the gate rule `{PhaseReflect, PhaseDone}` in the kernel fires correctly for the OS chain because both chains end in `reflect → done`. The gate wiring works without any kernel change.

---

## Summary Assessment

The five features are structurally sound as a set. The problem they solve is real and well-motivated. Three concerns require resolution before implementation: F2 conflates two independent problems and should be split, F5 proposes a rename that has irreversible side effects on existing sprint state and must sequence after a migration step, and F3's acceptance criteria contradict the PRD's own Non-goals section on complexity-scaled thresholds. A fourth must-fix is that `commands/sprint.md`'s internal consistency gaps (step count, routing table, checkpoint step names) are omitted from every feature's scope. The remaining findings are moderate concerns or optional cleanup.

---

## 1. Boundaries and Coupling

### 1a. F2 conflates two independent problems — they have different risk profiles and must be separated

F2's acceptance criteria conflate two distinct changes:

**Problem A (required, low risk):** Adding `shipping → reflect` and `reflect → done` transitions to `_sprint_transition_table()` in `lib-sprint.sh`, and adding `reflect` to `sprint_phase_to_command()`. These transitions do not exist in the OS today. Adding them has no backward-compatibility risk.

**Problem B (optional, high risk):** Renaming `shipping` to `polish` and potentially removing `plan-reviewed` from the OS custom chain. This affects existing sprint state stored in beads and ic runs. A sprint currently at phase `shipping` would have its phase value orphaned if the phase name is removed from the chain definition without a migration step.

The PRD acknowledges the rename risk in Open Question 1 but treats both problems as a single feature. This means the implementation of Problem A is blocked until Problem B has a migration answer — unnecessarily. F1 and F3 depend on Problem A only.

**Must-fix — split F2 into two features:**
- F2a (ship now, no migration needed): Add `shipping → reflect`, `reflect → done` to `_sprint_transition_table()` and `sprint_next_step()`. Update `CLAVAIN_PHASES` in `lib-gates.sh`. No phase names are changed.
- F2b (requires migration decision from F5): If the rename decision is to rename `shipping` → `polish`, execute the migration before updating the chain definition in `sprint_create`. F2b is blocked by F5 and by the migration sequencing in finding 1b below.

F1 and F3 depend only on F2a. The current PRD structure forces F2b to block F1 and F3 even though no rename is needed for the gate wiring to work.

---

### 1b. F5's rename has irreversible side effects on existing sprint state — the migration sequencing is absent

The OS custom chain string `shipping` is stored in two durable locations for every existing sprint:

1. In the ic run's `phases` column (the JSON array set at `ic run create` time, stored in SQLite).
2. In the bead's `phase` state field (written by `advance_phase` on phase transitions, read by `sprint_read_state`).

If `lib-sprint.sh`'s `phases_json` in `sprint_create` is updated to replace `shipping` with `polish`, new sprints will use the new chain. Existing ic runs will still have `shipping` in their stored chain — this is safe because their chain is explicit and stored. But a sprint whose bead phase field reads `shipping` and whose ic run chain contains `shipping` will break if the bash transition table is updated to `polish` simultaneously: `_sprint_transition_table("shipping")` would return `""` (unknown phase → fallback to brainstorm in `sprint_next_step`).

More critically: the ic run's stored phases column is the chain enforced by the kernel for that run. Changing the chain name in `sprint_create` does not retroactively update existing runs. Existing runs at phase `shipping` continue to advance normally through their stored chain. The bash fallback is the only code path that reads the name from the transition table. If the table is updated to use `polish` while a run's stored chain still has `shipping`, the bash fallback will misroute any session that resumes after the rename ships.

**Must-fix — add migration prerequisite to F5 (or F2b if the rename is chosen):**

Before any phase rename in the OS chain takes effect, the implementation requires:
1. A query for all active sprints at phase `shipping` via `ic run list --active`.
2. For each sprint, note the current phase.
3. After the chain definition in `sprint_create` is updated, run `ic run skip <id> shipping --reason="migrated: shipping renamed to polish"` so the kernel has an audit trail.
4. Update each bead's `phase` state field from `shipping` to `polish`.

Alternatively — and this is the lower-risk path — keep `shipping` as an OS-specific name permanently and document it in F5 as a deliberate OS convention (per F5's own AC: "remaining OS-specific phase names documented with rationale"). This avoids the migration entirely and is consistent with the E3 brainstorm's decision (see `docs/brainstorms/2026-02-19-intercore-e3-hook-cutover-brainstorm.md`, Key Decision 4: "Clavain's 8-phase chain is canonical").

---

### 1c. F1 and F3 have an unstated dependency on F2a — the bash fallback path breaks without it

F1 adds "Step 9: Reflect" to the sprint command and requires the sprint to advance from the current phase to `reflect`. F3 requires `/reflect` to register an artifact.

Both depend on `sprint_advance "$CLAVAIN_BEAD_ID" "reflect"` succeeding. On the ic-backed path, this works today — ic's `run advance` uses the run's stored chain, which already includes `reflect`. On the beads-fallback path (ic unavailable), `sprint_advance` calls `_sprint_transition_table("shipping")` to determine the next phase. The current transition table has:

```bash
shipping) echo "reflect" ;;
```

This already exists in the current `lib-sprint.sh` (line 572). So F2a (adding `shipping → reflect`) is already partially present.

However, `sprint_next_step` maps phase names to commands. The current mapping (line 598):
```bash
reflect)  echo "reflect" ;;
```

This mapping already exists. So the bash routing for `reflect` is already in place. The gap is that `sprint_phase_to_command` is not a function that currently exists in `lib-sprint.sh` — the PRD uses this name but the actual function is `sprint_next_step`. The F2 acceptance criteria reference `sprint_phase_to_command` which does not exist in the codebase; this is a naming inconsistency in the PRD.

**Should-fix — correct F2 AC terminology:** Replace "sprint_phase_to_command" in F2's acceptance criteria with "sprint_next_step" to match the actual function name in `lib-sprint.sh`.

The actual gap F2a must address is `lib-gates.sh`'s `CLAVAIN_PHASES` array (line 25), which currently has `shipping` but not `reflect` in the sequence after `shipping`. Checking the file: `CLAVAIN_PHASES=(brainstorm brainstorm-reviewed strategized planned plan-reviewed executing shipping reflect done)` — reflect IS present. So the CLAVAIN_PHASES array already includes reflect. F2a may be smaller than the PRD implies.

---

### 1d. The gate for `polish → reflect` in the kernel has no rule — the kernel does not enforce entry into reflect for DefaultPhaseChain users

From `infra/intercore/internal/phase/gate.go`:

```go
// polish → reflect: no gate requirements (pass-through)
// reflect → done: soft gate — requires reflect artifact
{PhaseReflect, PhaseDone}: {
    {check: CheckArtifactExists, phase: PhaseReflect},
},
```

For sprints using the OS custom chain (`shipping → reflect → done`): the kernel evaluates the gate for transition `{shipping, reflect}`. This pair is not in `gateRules`, so the gate passes with no check. Entry into reflect is ungated — anything can call `ic run advance` and move the sprint to reflect before any artifact exists.

The enforcement that matters is `{reflect, done}` — exit from reflect requires the artifact. Entry into reflect does not. This is intentional and correct: reflect should be entered automatically after shipping completes, with the gate only blocking progression to done until learning is captured.

F3's wiring is therefore sufficient. The artifact must exist before `reflect → done`, not before `shipping → reflect`. This is architecturally clean.

This finding is informational: F3 does not need to add an entry gate for reflect. The current gate structure is correct.

---

### 1e. The quality gate kernel enforcement gap is a pre-existing risk that this PRD makes more visible

The kernel's `DefaultPhaseChain` enforces `CheckVerdictExists` at `{review, polish}`. The OS custom chain goes `executing → shipping` — no `review` phase. The kernel never evaluates the verdict gate for OS sprints.

The OS relies on the `enforce_gate "$CLAVAIN_BEAD_ID" "shipping"` call in `commands/sprint.md` Step 7. For ic-backed sprints, `enforce_gate` calls `intercore_gate_check "$run_id"`. The kernel evaluates the gate for the next transition of the OS chain, which is `{executing, shipping}`. This pair is not in `gateRules`. So `intercore_gate_check` returns pass regardless of whether any verdict exists.

The quality gate (`CheckVerdictExists`) is structurally unenforced by the kernel for OS sprints. This is a pre-existing gap this PRD does not create. But as the PRD expands gate coverage (adding the reflect gate), it becomes more important to note which gates are kernel-enforced versus command-enforced.

**Recommendation (out of scope for this PRD):** Add a gate rule for `{executing, shipping}` with `CheckVerdictExists` to the kernel's gateRules table. This would make quality gates kernel-enforced for OS sprints and eliminate the reliance on the sprint command's in-band `enforce_gate` call.

---

## 2. Pattern Analysis

### 2a. `commands/sprint.md` has internal consistency gaps that must be part of F1 or F4 scope — they are not optional documentation

`commands/sprint.md` contains multiple locations that will be inconsistent after F1 ships:

**Sprint Summary step count.** Line 349: `"Steps completed: <n>/9"`. After F1 adds Step 9 Reflect and Ship becomes Step 10, the display must read `/10`.

**Session Checkpointing step name list.** Line 134: `"Step names: brainstorm, strategy, plan, plan-review, execute, test, quality-gates, resolve, ship."` The step `reflect` is absent. Checkpoint step names are used by `checkpoint_write` and resume logic. An absent step name means a reflect step would write a checkpoint with an unrecognized step, potentially breaking `checkpoint_completed_steps` filtering.

**`--from-step` argument handling.** Line 113: `"Step names: brainstorm, strategy, plan, plan-review, execute, test, quality-gates, resolve, ship."` Same list, same gap. `--from-step reflect` would not be recognized.

**Sprint Resume routing table.** Lines 33-37: the routing table maps phase names to commands. It maps `ship → /clavain:quality-gates` (bead in shipping phase). It does not map `reflect → /reflect`. A sprint resuming at the reflect phase would fall through to Work Discovery and potentially start a new brainstorm instead of routing to `/reflect`.

These are correctness requirements, not documentation cleanup. A sprint that resumes at the reflect phase will misroute without the routing table fix. A sprint that completes all 10 steps will display "10/9 steps completed" without the count fix.

**Must-fix — assign these to F1 (they are part of the sprint command change):**
- Add `reflect` to the step name list in Session Checkpointing
- Add `reflect` to the `--from-step` valid names list
- Add `reflect` → `/reflect` to the Sprint Resume routing table
- Update `Steps completed: <n>/9` to `<n>/10` in Sprint Summary
- Update Error Recovery section's step count reference

---

### 2b. The `/reflect` command's phase precondition check creates a double-advance hazard

`hub/clavain/commands/reflect.md` Step 1 says: "confirm it is in the `shipping` or `reflect` phase."

The command then calls `sprint_advance "<sprint_id>" "reflect"` at Step 4. This call advances FROM reflect (not TO reflect). In the `sprint_advance` bash implementation, `current_phase` must equal the sprint's recorded phase for the advance to succeed. If the sprint is at `shipping`, `sprint_advance "<sprint_id>" "reflect"` will:

- In the bash fallback: check `actual_phase = bd state sprint_id phase`. If actual = `shipping`, but the caller passes `current_phase = "reflect"`, the stale-phase guard fires and returns `stale_phase|reflect|Phase already advanced to shipping` — which then causes the sprint command to route incorrectly.
- In the ic path: `ic run advance` ignores the `current_phase` parameter entirely (it uses the run's own state machine). If the run is at `shipping`, ic advances to `reflect`. Then the `/reflect` command's next step would need a second `sprint_advance` call to advance `reflect → done`, but the command only calls it once.

The result in the ic path: a sprint at `shipping` that invokes `/reflect` will end up at `reflect` with an artifact registered but never advance to `done`. The sprint is stuck.

**Must-fix — clarify the phase precondition:** `/reflect` should only be invoked when the sprint is already at `reflect` phase. The sprint command's Step 9 (F1) should advance the sprint from `shipping` to `reflect` via `sprint_advance` before invoking `/reflect`. The `/reflect` command's phase check should be `reflect` only. If invoked standalone with the sprint at `shipping`, the command should first advance to `reflect` explicitly:

```bash
if [[ "$current_phase" == "shipping" ]]; then
    sprint_advance "$sprint_id" "shipping"
    # Re-read phase after advance
    current_phase=$(sprint_read_state "$sprint_id" | jq -r '.phase // ""')
fi
[[ "$current_phase" != "reflect" ]] && { echo "Sprint not at reflect phase"; return 1; }
```

---

### 2c. Phase-advance ownership is unassigned between `/reflect` and the sprint command's Step 9

The current `/reflect` command calls `sprint_advance "<sprint_id>" "reflect"` at Step 4 — advancing FROM reflect TO done.

F1's acceptance criteria state: "Step 9 records `phase=reflect` via `advance_phase` after reflection completes."

If both the sprint command and `/reflect` call an advance function, one call will fail silently:
- If `/reflect` advances to `done` and the sprint command then calls `advance_phase "reflect"`, the kernel will see the sprint is at `done` and return a stale-phase error. `sprint_advance` swallows this silently.
- If the sprint command calls `advance_phase "shipping"` (into reflect) before invoking `/reflect`, and then `/reflect` calls `sprint_advance "reflect"` (into done), this is correct sequential behavior — no conflict.

The PRD does not specify which model is intended. F1 AC says "advance_phase after reflection completes" — this implies the sprint command advances the sprint after `/reflect` returns. But if `/reflect` already advanced to `done`, the sprint command would be double-advancing.

**Should-fix — assign phase-advance ownership explicitly in F1:** Either:
- Model A: `/reflect` owns both artifact registration and `reflect → done` advance. F1's Step 9 invokes `/reflect` and does NOT call `advance_phase` afterward. The sprint command's Step 9 only needs to advance `shipping → reflect` BEFORE invoking `/reflect`.
- Model B: `/reflect` owns only artifact registration. F1's Step 9 calls `sprint_advance` after `/reflect` returns.

Model A matches the current `/reflect` design and is simpler. F1's AC should be updated to say "Step 9 advances from `shipping` to `reflect` before invoking `/reflect`, then `/reflect` advances from `reflect` to `done`."

---

## 3. Simplicity and YAGNI

### 3a. F3 AC item 4 contradicts the Non-goals section — remove or reclassify it

F3 acceptance criteria item 4: "Complexity-scaled gate thresholds documented: C1=any artifact, C2=non-empty content, C3=solution doc."

The current kernel gate for `{PhaseReflect, PhaseDone}` uses `CheckArtifactExists`. Looking at `/root/projects/Interverse/infra/intercore/internal/phase/gate.go`:

```go
{PhaseReflect, PhaseDone}: {
    {check: CheckArtifactExists, phase: PhaseReflect},
},
```

`CheckArtifactExists` calls `CountArtifacts(ctx, runID, phase)` — it counts artifacts and returns pass if count > 0. There is no content-hash check, no path-pattern check for `docs/solutions/`, and no complexity-gated threshold logic. Implementing C2 (non-empty content) would require a new gate check type in the kernel. Implementing C3 (solution doc path pattern) would require the kernel to evaluate filesystem paths, which violates its mechanism-not-policy principle.

The PRD's Non-goals section correctly states: "The kernel gate already checks for artifact existence. Complexity-scaled quality checks (C1 vs C3 depth) are a future Interspect concern." AC item 4 contradicts this.

**Must-fix — revise F3 AC item 4:** Replace with: "Complexity-scaled gate thresholds noted as future work. Current gate behavior for all complexity levels: any artifact registered with `phase=reflect` satisfies the gate (equivalent to C1 threshold)."

---

### 3b. F5's phase mapping table is documentation debt if the rename decision is "rename"

F5 requires "a canonical phase mapping table added to AGENTS.md (or glossary) showing OS name to kernel name for every phase." If F5's rename decision is to rename `shipping` → `polish` (adopting kernel-canonical names), then after the migration there is no OS-to-kernel mapping divergence to document — the OS chain would match the kernel chain. The mapping table would document a historical artifact.

The mapping table is architecturally necessary only if the OS retains permanent OS-specific names. The PRD leaves the rename as an open question while requiring the table in either case.

**Recommendation — sequence the decision before speccing the table:** If the decision is "rename," the mapping table is temporary scaffolding and should live in a migration doc, not a permanent AGENTS.md entry. If the decision is "keep OS names," the table is the permanent contract and belongs in the glossary as a cross-layer bridge document. The PRD should resolve this before F5 is implemented.

---

### 3c. F4 requires verifying `infra/intercore/AGENTS.md` "already done" — the kernel's DefaultPhaseChain is already 9 phases

F4 acceptance criteria: "`infra/intercore/AGENTS.md` default chain documented as 10 phases (verify already done)."

The kernel's `DefaultPhaseChain` in Go source is 9 phases (including `reflect`). The comment in `phase.go` says "DefaultPhaseChain is the 10-phase Clavain lifecycle" but the array has 9 entries (brainstorm through done). The brainstorm document also describes "10 phases" but enumerates 9. This is a consistent off-by-one error in the description — the count should be 9.

F4 should clarify: the chain has 9 distinct phases (not counting any duplicates). The "10-phase" language in the brainstorm appears to be counting `done` as a phase AND also counting something else — possibly an earlier version of the chain that had a different phase count. The AGENTS.md update should say "9-phase" to match the actual array length.

**Minor fix — correct the phase count in F4 documentation targets from 10 to 9.**

---

## 4. Phase Chain Coherence — Overall Assessment

The core of this PRD is adding two bash transitions to the OS chain and inserting one new step into the sprint command. The kernel already has everything needed: `PhaseReflect`, gate rule `{reflect, done}`, and `CheckArtifactExists`. No kernel changes are required.

The coherence assessment across kernel and OS:

**What is already coherent (no work required):**
- Kernel `DefaultPhaseChain` already includes `reflect` (Go source updated).
- Kernel gate `{reflect, done}` already exists with `CheckArtifactExists`.
- OS custom chain already includes `reflect` in `sprint_create`'s `phases_json`.
- `_sprint_transition_table` already has `shipping → reflect` and `reflect → done`.
- `sprint_next_step` already maps `reflect → "reflect"` command.
- `CLAVAIN_PHASES` in `lib-gates.sh` already includes `reflect`.

**What the PRD must add:**
- Sprint command Step 9 (F1) — the sprint command does not invoke `/reflect` today.
- Artifact registration in `/reflect` (F3) — `/reflect` calls `sprint_set_artifact` but does not call `ic run artifact add` with `--phase=reflect` directly.
- Documentation consistency in `commands/sprint.md` — step count, routing table, checkpoint names (finding 2a).
- Phase-advance ownership clarity between sprint command and `/reflect` (finding 2c).

**What remains a permanent OS-kernel divergence (acceptable, must be documented):**
- `plan-reviewed` has no kernel equivalent. It cannot be removed without breaking the execution gate.
- `shipping` vs `polish` remains divergent unless F5 chooses rename + migration.
- The kernel enforces gates only for transitions in its gateRules table. OS custom chain transitions `{plan-reviewed, executing}` and `{executing, shipping}` have no kernel gate — enforced by OS commands only.

---

## 5. Issue Classification

### Must-Fix (correctness risks — resolve before implementation)

| # | Feature | Issue |
|---|---------|-------|
| 1a | F2 | Two independent problems conflated; F2 must split into F2a (add transitions, no rename) and F2b (rename, requires migration). F1 and F3 are unblocked by F2a alone. |
| 1b | F5 | Phase rename has irreversible side effects on existing sprint state in ic run `phases` column and bead `phase` field; no migration step specified |
| 2a | F1 | `commands/sprint.md` internal consistency gaps (step count, resume routing table, checkpoint step names, `--from-step` names) are omitted from F1 and F4 scope — they are correctness requirements |
| 2b | F3 + `/reflect` | `/reflect` phase precondition "shipping or reflect" combined with a single `sprint_advance "reflect"` call creates a stuck-at-reflect condition when invoked at `shipping` phase via the ic path |
| 3a | F3 | AC item 4 (C1/C2/C3 complexity-scaled thresholds) contradicts the Non-goals section; kernel gate supports only `CheckArtifactExists` and C2/C3 are not implementable without kernel changes |

### Should-Fix (coupling and boundary concerns)

| # | Feature | Issue |
|---|---------|-------|
| 2c | F1 + F3 | Phase-advance ownership is unassigned between `/reflect` and the sprint command's Step 9; both currently attempt to advance, causing a silent stale-phase no-op on the second call |
| 1c | F2 | F2 AC uses "sprint_phase_to_command" which does not exist; the correct function name is `sprint_next_step` |
| 1e | Pre-existing | Quality gate (`CheckVerdictExists`) is not kernel-enforced for OS sprints; kernel gateRules has no rule for `{executing, shipping}` |

### Optional Cleanup (low urgency)

| # | Feature | Issue |
|---|---------|-------|
| 3b | F5 | Phase mapping table is documentation debt if rename decision is "rename"; resolve the rename question before speccing the table |
| 3c | F4 | DefaultPhaseChain is 9 phases, not 10; F4 documentation targets should say "9-phase" |
| 1d | None | No action needed: kernel pass-through for `{shipping, reflect}` is correct behavior |

---

## 6. Recommended Sequencing

```
F2a (add transitions to bash table, update lib-gates.sh)
  → F3 (artifact registration in /reflect)
  → F1 (sprint command Step 9, /commands/sprint.md consistency)
  → F4 (documentation alignment)
  → F5 (rename decision)
  → F2b (rename migration, if rename is chosen)
```

F2a, F3, F1, and F4 can ship as a coherent unit. F5 is a decision gate, not implementation. F2b (if executed) requires F5 and a migration script.

The critical path is F1 — it is the user-visible change that makes reflection mandatory in the sprint flow. F3 is a precondition for F1 (artifact registration must work before the gate can pass). F2a is a precondition only for the beads-fallback path (ic-backed sprints already have the transitions via the stored chain).

---

## 7. Key File Locations

- PRD under review: `/root/projects/Interverse/docs/prds/2026-02-20-reflect-phase-sprint-integration.md`
- Sprint state library: `/root/projects/Interverse/hub/clavain/hooks/lib-sprint.sh`
- Sprint command: `/root/projects/Interverse/hub/clavain/commands/sprint.md`
- Reflect command: `/root/projects/Interverse/hub/clavain/commands/reflect.md`
- Gate shim (fallback CLAVAIN_PHASES): `/root/projects/Interverse/hub/clavain/hooks/lib-gates.sh`
- Kernel phase constants and DefaultPhaseChain: `/root/projects/Interverse/infra/intercore/internal/phase/phase.go`
- Kernel gate rules (reflect→done): `/root/projects/Interverse/infra/intercore/internal/phase/gate.go`
- Intercore kernel docs: `/root/projects/Interverse/infra/intercore/AGENTS.md`
- Reflect phase brainstorm: `/root/projects/Interverse/docs/brainstorms/2026-02-19-reflect-phase-learning-loop-brainstorm.md`
- Glossary: `/root/projects/Interverse/docs/glossary.md`
