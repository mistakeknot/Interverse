# Correctness Review: PRD iv-8jpf — Reflect Phase Sprint Integration

**Reviewed:** 2026-02-20
**Document:** `/root/projects/Interverse/docs/prds/2026-02-20-reflect-phase-sprint-integration.md`
**Reviewer role:** Flux-drive Correctness (data integrity, phase state machines, gate logic)

---

## Invariants Under Review

These must remain true for the system to be correct. Every finding below is framed as a violation of one or more of these.

1. **Phase chain consistency:** The OS-layer `PHASES_JSON` (passed to `ic run create`), the OS-layer `_sprint_transition_table`, the OS-layer `sprint_phase_whitelist`, and the kernel `DefaultPhaseChain` must all agree on the same ordered set of phase names, or each divergence must be explicitly isolated with a documented translation layer.

2. **Gate rule coverage:** Every kernel gate rule in `gateRules` must reference phase names that exist in `DefaultPhaseChain`. Every transition the OS expects to gate must have a matching `gateRules` entry, or the OS must not rely on the gate for that transition.

3. **Beads state forward-compatibility:** Phase names written to beads state (`bd set-state phase=<name>`) must remain readable and routable after a rename. A rename without a migration leaves all existing sprints stranded at an unrecognized phase.

4. **PRD claim accuracy:** The PRD's stated facts about the kernel (phase count, chain contents, gate coverage) must match the actual source code, or implementation will be built on a false premise.

5. **Reflect gate reachability:** The `reflect → done` gate rule (`CheckArtifactExists, phase=reflect`) must be reachable via the OS-layer advance path. If the OS-layer chain never reaches a phase named `reflect` via the kernel's advance machinery, the gate can never fire.

---

## Finding 1 (HIGH): PRD Claims 10 Phases; Kernel Has 9

### What the PRD says

The PRD Problem statement says "the kernel-level reflect phase (intercore already ships `PhaseReflect`, gate rules, and a **10-phase** `DefaultPhaseChain`)." F4 says documentation should reference "10 phases." F2 acceptance criteria says the chain should be:

```
brainstorm → brainstorm-reviewed → strategized → planned → plan-reviewed → executing → review → polish → reflect → done
```

That is 10 elements.

### What the kernel actually contains

`/root/projects/Interverse/infra/intercore/internal/phase/phase.go`, lines 66-76:

```go
// DefaultPhaseChain is the 10-phase Clavain lifecycle.
// Used when a run has no explicit phases column (NULL in DB).
var DefaultPhaseChain = []string{
    PhaseBrainstorm,          // "brainstorm"
    PhaseBrainstormReviewed,  // "brainstorm-reviewed"
    PhaseStrategized,         // "strategized"
    PhasePlanned,             // "planned"
    PhaseExecuting,           // "executing"
    PhaseReview,              // "review"
    PhasePolish,              // "polish"
    PhaseReflect,             // "reflect"
    PhaseDone,                // "done"
}
```

That is 9 elements. The Go comment says "10-phase" but the slice has 9 entries. The kernel has no `plan-reviewed` phase constant at all — there is no `PhasePlanReviewed` in `phase.go`.

The `phase_test.go` test at line 26 confirms this:

```go
{"valid default chain", `["brainstorm","brainstorm-reviewed","strategized","planned","executing","review","polish","reflect","done"]`, DefaultPhaseChain, false},
```

Nine strings. The test would fail if `DefaultPhaseChain` were 10 elements.

The AGENTS.md for intercore (line 277-281) calls it "10-phase" and lists:

```
brainstorm → brainstorm-reviewed → strategized → planned → executing → review → polish → reflect → done
```

That is also 9 phases with a mislabeled comment. The wrong number is in three places: the Go comment, the AGENTS.md, and the PRD.

### Why this matters

The PRD's F2 acceptance criteria specifies that `lib-sprint.sh` should match a 10-phase kernel chain that includes `plan-reviewed`. If an implementer follows F2 literally and passes that 10-phase JSON to `ic run create`, the kernel will accept it (custom chains are allowed via `ParsePhaseChain`), but the run will use a custom chain, not `DefaultPhaseChain`. Gate rules in `gateRules` are keyed to `DefaultPhaseChain` phase-name pairs. If the stored chain includes `plan-reviewed` between `planned` and `executing`, the gate transition `{PhasePlanned, PhaseExecuting}` no longer exists in that run's chain; the kernel uses `ChainNextPhase` to compute the transition, and `gateRules[{planned, plan-reviewed}]` has no entry, so that transition passes without any gate check. The gate at `planned → executing` effectively disappears.

### Correction

The PRD must state: the kernel `DefaultPhaseChain` has **9 phases** (no `plan-reviewed`). The "10-phase" label in the PRD, the Go comment, and AGENTS.md are all wrong by one. This is a documentation error with a real implementation trap: any F2 work that targets "10-phase alignment" will be pulling in a direction the kernel does not support by default.

---

## Finding 2 (HIGH): OS Chain Contains `plan-reviewed` and `shipping` — Neither Exists in the Kernel; Gate Rules Are Blind to Both

### The divergence in detail

The OS layer (`lib-sprint.sh` line 78) passes this `phases_json` to `ic run create`:

```
["brainstorm","brainstorm-reviewed","strategized","planned","plan-reviewed","executing","shipping","reflect","done"]
```

The kernel `DefaultPhaseChain`:

```
["brainstorm","brainstorm-reviewed","strategized","planned","executing","review","polish","reflect","done"]
```

Position-by-position comparison:

| Position | OS chain          | Kernel chain |
|----------|-------------------|--------------|
| 1        | brainstorm        | brainstorm |
| 2        | brainstorm-reviewed | brainstorm-reviewed |
| 3        | strategized       | strategized |
| 4        | planned           | planned |
| 5        | plan-reviewed     | executing |
| 6        | executing         | review |
| 7        | shipping          | polish |
| 8        | reflect           | reflect |
| 9        | done              | done |

The OS chain has `plan-reviewed` at position 5; the kernel has `executing`. The OS has `shipping` at position 7; the kernel has `polish` (with `review` at position 6, which the OS lacks entirely).

### Gate rule consequences

`gateRules` in `/root/projects/Interverse/infra/intercore/internal/phase/gate.go` is keyed to kernel phase-name pairs. The rules that exist:

```go
{PhaseBrainstorm, PhaseBrainstormReviewed}: artifact_exists(brainstorm)
{PhaseBrainstormReviewed, PhaseStrategized}: artifact_exists(brainstorm-reviewed)
{PhaseStrategized, PhasePlanned}: artifact_exists(strategized)
{PhasePlanned, PhaseExecuting}: artifact_exists(planned)
{PhaseExecuting, PhaseReview}: agents_complete
{PhaseReview, PhasePolish}: verdict_exists
// polish → reflect: no gate (explicit comment)
{PhaseReflect, PhaseDone}: artifact_exists(reflect)
```

The OS-layer run uses an explicit custom chain (9 phases with `plan-reviewed` and `shipping`). When `ic run advance` is called, it uses the run's stored chain, not `DefaultPhaseChain`. The kernel evaluates `gateRules[[2]string{from, to}]`. For an OS-chain sprint:

- Transition `planned → plan-reviewed`: no gate rule exists. Passes unconditionally.
- Transition `plan-reviewed → executing`: no gate rule exists. Passes unconditionally.
- Transition `executing → shipping`: no gate rule exists. The intended `executing → review` gate (`CheckAgentsComplete`) never fires. Sprints can advance past execution without waiting for active agents to complete.
- Transition `shipping → reflect`: no gate rule exists. The intended `review → polish` gate (`CheckVerdictExists`) never fires. Sprints can skip past the verdict requirement.

The OS layer calls `enforce_gate "$CLAVAIN_BEAD_ID"` in `sprint.md` (Steps 5 and 7), which internally calls `intercore_gate_check "$run_id"` → `ic gate check <run_id>` → `EvaluateGate`. That evaluation uses the run's stored chain. Because the OS chain phase names do not match the gate rule keys, every gate check on an OS-created sprint returns `GatePass` with `tier=none` (no rules found) for transitions that should have hard requirements.

The two meaningful gates — "all agents must complete before shipping" and "a passing verdict must exist before polish" — are silently bypassed for every sprint created by `sprint_create()`.

### The `reflect → done` gate is unaffected

The one gate that does work correctly in both chains is `{PhaseReflect, PhaseDone}`. Both the kernel chain and the OS chain use `reflect` and `done` as the final two phases. F3 acceptance criteria (register reflect artifact, check gate, advance) will work as described.

### F5 mitigation path

The PRD asks whether to rename `shipping` to `polish` in F5. This is the correct direction but the PRD treats it as optional. It should be mandatory for gate correctness. Similarly, removing `plan-reviewed` from the OS chain (or adding it to the kernel with a corresponding gate rule) is necessary to make the gate system meaningful.

---

## Finding 3 (HIGH): Beads Phase State Migration — No Strategy for Existing `shipping` Records

### The problem

Beads state is written by `advance_phase` and `sprint_record_phase_completion` using OS-layer phase names. The fallback path in `sprint_read_state`, `sprint_advance`, and `sprint_find_active` reads `phase` from beads directly:

```bash
phase=$(bd state "$sprint_id" phase 2>/dev/null) || phase=""
```

If `shipping` is renamed to `polish` in `lib-sprint.sh`, all existing sprint beads that have `phase=shipping` stored in beads will be read back by code that no longer knows what `shipping` means.

The consequences cascade through every routing table in the codebase:

**`_sprint_transition_table()` (`lib-sprint.sh` line 563-577):**
```bash
executing)   echo "shipping" ;;
shipping)    echo "reflect" ;;
```
After rename: `shipping` case disappears. Any bead at `shipping` falls to `*)  echo "" ;;`, which causes `sprint_advance` to return 1 with "no next phase."

**`sprint_next_step()` (`lib-sprint.sh` line 583-601):**
```bash
shipping)    echo "ship" ;;
```
After rename: `shipping → ship` mapping disappears. Resumed sprints at phase `shipping` would route to `brainstorm` (the `*)` default).

**Sprint command routing (`sprint.md` line 92):**
```
`ship` → `/clavain:quality-gates` (bead is in shipping phase — run final gates)
```
After rename: the `ship` step maps to quality-gates, but `sprint_next_step` now returns `ship` when the phase is `polish`. The routing is now `polish → ship → quality-gates`, which is correct for new sprints. But for a sprint at `phase=shipping` in beads, `sprint_next_step("shipping")` returns `brainstorm` (the default case), not `ship`.

**`sprint_phase_whitelist()` (`lib-sprint.sh` lines 908-911):**
```bash
2) echo "planned plan-reviewed executing shipping reflect done" ;;
3|4|5) echo "brainstorm brainstorm-reviewed strategized planned plan-reviewed executing shipping reflect done" ;;
```
After rename: `shipping` in the whitelist is never matched by a phase named `polish`. A sprint at `polish` would be skipped by `sprint_should_skip`, and `sprint_next_required_phase` would walk past it to `reflect`.

**`lib-gates.sh` fallback stubs (`hub/clavain/hooks/lib-gates.sh` line 25):**
```bash
CLAVAIN_PHASES=(brainstorm brainstorm-reviewed strategized planned plan-reviewed executing shipping reflect done)
```
Still has `shipping`. If this is not updated, the fallback gate path treats `polish` as an invalid phase and `shipping` as valid, creating opposite-layer confusion.

**`interphase/hooks/lib-gates.sh` `VALID_TRANSITIONS` (lines 50-74):**
```
"executing:shipping"
"shipping:done"
"plan-reviewed:shipping"
```
All use `shipping`. After rename these are dead entries; `polish` transitions would hit the rejection path.

**Migration script** `/root/projects/Interverse/hub/clavain/scripts/migrate-sprints-to-ic.sh` line 29:
```bash
PHASES_JSON='["brainstorm","brainstorm-reviewed","strategized","planned","plan-reviewed","executing","shipping","done"]'
```
Uses the old chain without `reflect`. This was presumably written before reflect was added. It is now doubly stale.

### The silent corruption scenario

Sequence of events:

1. Sprint created before rename. Beads: `phase=shipping`. Kernel ic run: `phase=shipping` (stored in SQLite via the run's custom chain).
2. Rename ships. `_sprint_transition_table("shipping")` returns `""`.
3. User resumes sprint via `/sprint`. `sprint_find_active` uses ic run's `phase` field (from SQLite) — that still says `shipping`. It calls `sprint_next_step("shipping")`.
4. `sprint_next_step` calls `_sprint_transition_table("shipping")`. Returns `""`. `sprint_next_step` receives `""` and maps it to the `*)` case: returns `"brainstorm"`.
5. Sprint resume routes to `/clavain:brainstorm`. A sprint that was ready to ship is restarted from scratch.
6. If the user does not notice, a new brainstorm doc overwrites the existing one, a new strategy phase begins, and months of work are silently re-run.

This is not hypothetical — it is the deterministic outcome of the rename without migration.

### Required fix

Before renaming `shipping` to `polish`:

1. Write a migration that reads all beads with `phase=shipping` and writes `phase=polish`.
2. For ic runs in the SQLite database: update their stored `phases` JSON column to replace `shipping` with `polish` in the custom chain array. Alternatively, do not rename in the ic run's stored chain (treat the OS chain as a legacy custom chain) and translate at the `sprint_advance` / `sprint_next_step` boundary.
3. Update all routing tables atomically: `_sprint_transition_table`, `sprint_next_step`, `sprint_phase_whitelist`, `lib-gates.sh` stubs, `interphase/hooks/lib-gates.sh` `VALID_TRANSITIONS`.
4. The PRD open question "may break existing beads phase state" should be elevated from a question to a blocking requirement: **no rename ships without a migration plan.**

---

## Finding 4 (MEDIUM): F2 Acceptance Criteria Specifies `review` Phase; Sprint Command Writes `shipping` — The Gap Is Not Addressed

F2 AC says:

> `lib-sprint.sh` phase chain matches kernel: `brainstorm → brainstorm-reviewed → strategized → planned → plan-reviewed → executing → review → polish → reflect → done`

But `sprint.md` Step 7 currently writes:

```bash
advance_phase "$CLAVAIN_BEAD_ID" "shipping" "Quality gates passed" ""
sprint_record_phase_completion "$CLAVAIN_BEAD_ID" "shipping"
```

And Step 5 uses:

```bash
if ! enforce_gate "$CLAVAIN_BEAD_ID" "executing" "<plan_path>"; then
```

If F2 ships and `review` / `polish` replace `executing` / `shipping` in the OS chain, the sprint command itself must update these strings. The PRD does not list `commands/sprint.md` as a file requiring change. This omission means F2 can be accepted as "done" while the sprint command still writes `shipping`, immediately creating new beads with the deprecated phase name.

The accept criterion for F2 must include: "`commands/sprint.md` advance_phase calls use updated phase names."

---

## Finding 5 (MEDIUM): `reflect.md` Accepts Sprint in `shipping` Phase — After OS Rename This Path Silently Breaks

`/root/projects/Interverse/hub/clavain/commands/reflect.md` line 18:

```
1. **Identify the active sprint.** Use `sprint_find_active` (sourced from lib-sprint.sh) to find the current sprint and confirm it is in the `shipping` or `reflect` phase.
```

After the OS rename, no sprint will ever be found in `shipping` phase (new sprints start in `polish`). The `reflect` command's precondition check will reject sprints at `polish` phase. A user who runs `/reflect` mid-sprint (at the `polish` phase) will be told there is no active sprint in the right phase. They will have to manually advance the sprint or find a workaround.

This is not a data corruption risk, but it is a user-visible breakage that makes the F1 acceptance criterion ("Step 9: Reflect that invokes `/reflect`") silently fail for any sprint that reaches the OS-renamed phase.

---

## Finding 6 (LOW): `polish → reflect` Gate Comment Is Accurate, But F3 Criterion Is Ambiguously Worded

`gate.go` line 93:
```go
// polish → reflect: no gate requirements (pass-through)
```

The gate table has no entry for `{PhasePolish, PhaseReflect}`. This means `ic run advance` on a sprint at `polish` returns `GatePass` unconditionally (no rules found). This is intentional and the comment captures it, but the PRD F3 says:

> Gate check `ic gate check <run>` passes after `/reflect` completes

This is only true for the `reflect → done` transition. The `polish → reflect` transition passes the gate check trivially regardless of whether `/reflect` has been invoked. The PRD's phrasing could lead an implementer to believe gate enforcement wraps the transition into reflect, not just out of reflect. The F3 criterion should be reworded to: "Gate check `ic gate check <run>` passes after `/reflect` completes (verifying the `reflect → done` gate)."

---

## Finding 7 (LOW): `GateRulesInfo()` Iterates `DefaultPhaseChain` — Custom-Chain Sprints Show No Gate Rules

`gate.go` lines 264-288:

```go
for i := 0; i < len(DefaultPhaseChain)-1; i++ {
    from := DefaultPhaseChain[i]
    to := DefaultPhaseChain[i+1]
    gr, ok := gateRules[[2]string{from, to}]
```

`ic gate rules` will only display gate rules for the 9-phase default chain. Any sprint created by `sprint_create()` using the custom 9-phase OS chain (with `plan-reviewed` and `shipping`) will show no gate rules when a developer runs `ic gate rules`, reinforcing the incorrect belief that the sprint is fully gated. This is a pre-existing issue noted in `infra/intercore/docs/research/architecture-review-e1-changes.md` line 92, but the PRD does not acknowledge it and F5's mapping table will not fix it.

---

## Summary Table

| # | Severity | Invariant Violated | PRD Section Affected |
|---|----------|--------------------|---------------------|
| 1 | HIGH | PRD claim accuracy | Problem, F4, throughout |
| 2 | HIGH | Gate rule coverage; phase chain consistency | F2, F5 |
| 3 | HIGH | Beads state forward-compatibility | F5 Open Questions |
| 4 | MEDIUM | Phase chain consistency (sprint command) | F2 |
| 5 | MEDIUM | Phase chain consistency (reflect command) | F1 |
| 6 | LOW | Gate rule coverage documentation | F3 |
| 7 | LOW | Gate rule coverage (display) | F5 |

---

## Required Changes Before F5 (Rename) Can Be Attempted

These are blocking, not advisory:

1. **Correct the phase count claim everywhere.** The kernel has 9 phases. Update the PRD, the Go comment in `phase.go`, and `infra/intercore/AGENTS.md` to say 9. This prevents the "10-phase alignment" framing from pulling implementation in the wrong direction.

2. **Resolve whether `plan-reviewed` enters the kernel chain or stays OS-only.** There are two coherent options:
   - Option A: Remove `plan-reviewed` from the OS chain and absorb the plan-review step into `ic run skip` calls (pre-skip the slot, or use a shorter custom chain).
   - Option B: Add `PhasePlanReviewed` to `phase.go` and `DefaultPhaseChain`, add `{PhasePlanned, PhasePlanReviewed}` and `{PhasePlanReviewed, PhaseExecuting}` gate rules, and rebuild the kernel binary.
   Either option is acceptable. The PRD must choose one and make it explicit.

3. **Write the `shipping → polish` migration before the rename ships.** Migration must cover: beads state (`bd set-state phase=`), ic run stored `phases` JSON in SQLite, routing tables in `lib-sprint.sh`, `sprint.md`, `commands/reflect.md`, and both `lib-gates.sh` files.

4. **Add `commands/sprint.md` to F2's file list.** Its `advance_phase` call strings must be updated as part of F2, not as a follow-up.

5. **Update `reflect.md` precondition.** The accepted phase list must include `polish` (or whatever the post-rename name is for what is now `shipping`).

---

## Files With Ground-Truth Discrepancies (Absolute Paths)

| File | Issue |
|------|-------|
| `/root/projects/Interverse/infra/intercore/internal/phase/phase.go` | Go comment says "10-phase", slice has 9 entries |
| `/root/projects/Interverse/infra/intercore/AGENTS.md` | Says "10-phase", lists 9 phases |
| `/root/projects/Interverse/hub/clavain/hooks/lib-sprint.sh` line 78 | OS chain has `plan-reviewed` + `shipping`; no `review` or `polish` |
| `/root/projects/Interverse/hub/clavain/hooks/lib-sprint.sh` lines 563-577 | Transition table uses `shipping`, not `polish` |
| `/root/projects/Interverse/hub/clavain/hooks/lib-sprint.sh` lines 908-911 | Phase whitelist uses `shipping`, not `polish` |
| `/root/projects/Interverse/hub/clavain/hooks/lib-gates.sh` line 25 | Fallback `CLAVAIN_PHASES` still has `shipping` |
| `/root/projects/Interverse/plugins/interphase/hooks/lib-gates.sh` lines 50-74 | `VALID_TRANSITIONS` has `shipping`; missing `review`, `polish` |
| `/root/projects/Interverse/hub/clavain/commands/sprint.md` line 324 | Still writes `advance_phase ... "shipping"` |
| `/root/projects/Interverse/hub/clavain/commands/reflect.md` line 18 | Precondition checks for `shipping` phase, not `polish` |
| `/root/projects/Interverse/hub/clavain/scripts/migrate-sprints-to-ic.sh` line 29 | Old chain without `reflect`; doubly stale |
