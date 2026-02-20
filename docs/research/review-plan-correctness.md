# Correctness Review: 2026-02-19-intercore-e3-hook-cutover.md

**Reviewer:** Julik (Flux-drive Correctness Reviewer)
**Date:** 2026-02-19
**Plan file:** `/root/projects/Interverse/docs/plans/2026-02-19-intercore-e3-hook-cutover.md`
**Source files examined:**
- `/root/projects/Interverse/hub/clavain/hooks/lib-sprint.sh`
- `/root/projects/Interverse/hub/clavain/hooks/lib-intercore.sh`
- `/root/projects/Interverse/infra/intercore/AGENTS.md`

---

## Invariants That Must Hold

Before listing defects I name the invariants the plan must preserve. If any of these break, the sprint lifecycle becomes unreliable.

1. **Claim exclusion** — At most one session holds an active claim on a sprint run at any instant. A second session must see the claim and fail.
2. **Phase monotonicity** — A run's phase sequence is strictly forward. No phase can be re-entered. A double-advance must be detected and rejected.
3. **Bead/run link integrity** — Every sprint bead with `sprint=true` has exactly one linked ic run for its lifetime, stored as `ic_run_id` in bead state.
4. **Artifact atomicity** — An artifact record for phase P is either written or not; it cannot be partially written against a wrong phase.
5. **Checkpoint currency** — `checkpoint_read` returns the checkpoint belonging to the currently active run, not a stale one from a previous run.
6. **Migration idempotency** — Running the migration script twice produces the same final state. The first run creates ic runs; the second run skips them.
7. **No side-effect events during migration** — Phase-advance calls in the migration script must not trigger SpawnHandler or HookHandler events that kick off real agent work.

---

## Finding 1 — CRITICAL: sprint_claim is a read-then-act race (TOCTOU)

**Location:** Task 3, `sprint_claim` (ic path, lines 516–547 of the plan)

### What the code does

```bash
# Check for existing active agents (concurrent sessions)
agents_json=$("$INTERCORE_BIN" run agent list "$run_id" --json ...) || agents_json="[]"
active_agents=$(echo "$agents_json" | jq '[.[] | select(.status == "active" and .agent_type == "session")]')
active_count=$(echo "$active_agents" | jq 'length')

if [[ "$active_count" -gt 0 ]]; then
    ...
    if [[ $age_minutes -lt 60 ]]; then
        echo "Sprint $sprint_id is active in session ${existing_name:0:8}" >&2
        return 1
    fi
    # Stale — mark old agent as failed, then claim
    "$INTERCORE_BIN" run agent update "$old_agent_id" --status=failed ...
fi

# Register this session as an agent
intercore_run_agent_add "$run_id" "session" "$session_id" ...
```

### The race

Session A and Session B both wake up for the same sprint at t=0 (e.g. two tmux panes doing `/sprint resume`).

```
t=0  A: run agent list → empty → active_count=0
t=0  B: run agent list → empty → active_count=0
t=1  A: intercore_run_agent_add → inserts agent A (status=active)
t=1  B: intercore_run_agent_add → inserts agent B (status=active)
```

Both succeed. Both believe they are the exclusive holder. Invariant 1 is broken. The sprint now has two active session agents and both sessions will write artifacts, advance phases, and write checkpoints concurrently.

### Why the old code was safe here

The old code used `intercore_lock "sprint-claim"` (filesystem mkdir atomicity via `ic lock acquire`) to serialize the list → check → write sequence. The new code removes that lock entirely for the ic path.

### The staleness check does not help

The 60-minute staleness check is evaluated before the registration write. It is part of the check, not part of the write. Even with the staleness check, two sessions evaluating simultaneously (both seeing zero agents) both proceed to register.

### Fix

Wrap the entire list-check-register sequence in an `intercore_lock "sprint-claim" "$sprint_id"` call, exactly as the old code did. The ic-path claim must be: acquire lock → list agents → check → (conditionally) expire old agent → add new agent → release lock. The lock serializes the check-then-act.

Alternatively, ic could offer an atomic "claim-or-fail" RPC (a CAS on a reserved slot), but that requires a Go change. The filesystem lock is the correct fix with the current architecture.

```bash
sprint_claim() {
    ...
    if [[ -n "$run_id" ]] && intercore_available; then
        intercore_lock "sprint-claim" "$sprint_id" "500ms" || return 1
        # ... all list/check/mark-stale/add logic ...
        intercore_unlock "sprint-claim" "$sprint_id"
        return 0
    fi
    ...
}
```

---

## Finding 2 — HIGH: sprint_advance has a TOCTOU between run_id resolution and ic run advance

**Location:** Task 4, `sprint_advance` (ic path, lines 683–723 of the plan)

### What the code does

```bash
sprint_advance() {
    local sprint_id="$1"
    local current_phase="$2"
    ...
    local run_id
    run_id=$(bd state "$sprint_id" ic_run_id 2>/dev/null) || run_id=""

    if [[ -n "$run_id" ]] && intercore_available; then
        local result
        result=$(intercore_run_advance "$run_id") || { ... return 1; }
        ...
        return 0
    fi
    ...
}
```

### The race scenario

This is a two-level staleness problem:

**Scenario A: wrong run_id**

```
t=0  Session A reads bd state sprint_id ic_run_id → run_id=run-abc
t=1  Sprint is cancelled and recreated (e.g. by another process)
t=1  New ic run created: run_id=run-xyz; bead state updated to ic_run_id=run-xyz
t=2  Session A calls ic run advance "run-abc"
     → run-abc is cancelled; advance may fail or advance the wrong run
```

In practice sprint recreation is rare during a session, but the broader issue is:

**Scenario B: stale current_phase argument vs actual ic phase**

The caller passes `current_phase` which it read from somewhere else (likely from `sprint_find_active` or an earlier `sprint_read_state` call). The ic `Advance()` uses optimistic concurrency (`WHERE phase = ?`), but that check is against the ic DB, not the caller-supplied `current_phase`. If ic's actual phase has already moved forward (another session or the migration script advanced it), `ic run advance` will return `ErrStalePhase`, and the bash wrapper handles this in the error branch. However:

The error branch in the plan:
```bash
result=$(intercore_run_advance "$run_id") || {
    local rc=$?
    ...
    case "$event_type" in
        block) ... ;;
        pause) ... ;;
        *)
            local actual_phase
            actual_phase=$(intercore_run_phase "$run_id") || actual_phase=""
            if [[ -n "$actual_phase" && "$actual_phase" != "$current_phase" ]]; then
                echo "stale_phase|$current_phase|Phase already advanced to $actual_phase"
            fi
            ;;
    esac
    return 1
}
```

The `result` variable is set from the command substitution output of `intercore_run_advance`. But `intercore_run_advance` returns JSON **only with the --json flag active**. When the command exits with a non-zero code (e.g. blocked or errored), the output on stdout is implementation-dependent — it may be empty or a plain error message. The code then tries to parse `$result` as JSON to extract `event_type`:

```bash
event_type=$(echo "$result" | jq -r '.event_type // ""' 2>/dev/null) || event_type=""
```

If `result` is empty (because the failed command produced no stdout), `event_type` will always be `""`, and the `case` will always fall through to the `*` branch. The block/pause distinction is effectively lost. Only the stale-phase path works correctly.

This is a correctness gap: if `ic run advance` fails because of a gate block, the Bash layer cannot distinguish it from a DB error.

### Fix

Verify with the intercore implementation that `ic run advance --json` always writes structured JSON to stdout on failure (not just on success). If it does, the code is correct. If the `--json` flag only affects success output, add explicit handling — e.g., check exit code 1 vs 2+ separately, parsing stdout only if exit code is in a known range.

The `intercore_run_advance` wrapper in the plan sends `--json`:
```bash
args=(run advance "$run_id" --priority="$priority" --json)
```
But the error path relies on stdout containing the reason for failure. Confirm that `ic run advance --json` outputs `{"event_type": "block", ...}` on stdout when blocked, not just an exit code.

---

## Finding 3 — HIGH: sprint_find_active cross-store consistency window

**Location:** Task 2, `sprint_find_active` (ic path, lines 229–270 of the plan)

### What the code does

```bash
sprint_find_active() {
    if intercore_available; then
        runs_json=$(intercore_run_list "--active") || runs_json="[]"
        # For each run with a scope_id:
        while ...; do
            scope_id=$(echo "$runs_json" | jq -r ".[$i].scope_id // empty")
            if [[ -n "$scope_id" ]]; then
                # Verify bead still exists and is a sprint
                is_sprint=$(bd state "$scope_id" sprint 2>/dev/null) || is_sprint=""
                initialized=$(bd state "$scope_id" sprint_initialized 2>/dev/null) || initialized=""
                ...
            fi
        done
        ...
    fi
}
```

### The consistency gap

`ic run list --active` reads from the ic SQLite DB. `bd state "$scope_id" sprint` reads from the beads Dolt DB. These are two separate stores. There is no distributed transaction spanning both.

**Scenario A: bead cancelled between ic list and bd check**

```
t=0  ic run list --active → returns [run-abc (scope_id=iv-1234)]
t=1  User cancels sprint → bd update iv-1234 --status=cancelled
t=2  sprint_find_active checks: bd state iv-1234 sprint → "true" (state field not cleared)
     → sprint appears active even though bead is cancelled
```

The bead's `sprint` state field is never cleared on cancellation. Sprint state cleanup is not atomically coupled to bead status. This was true in the old code too (bd-only), but the dual-store model makes the window explicit.

**Scenario B: stale ic run after bead cancel**

If a bead is cancelled but its ic run is not cancelled, `sprint_find_active` will keep returning it (because the ic run is still active and the bd state fields say sprint=true/initialized=true). The sprint will appear resumable. A `sprint_claim` call would succeed (no claim in the agent table), and a session could resume a cancelled sprint.

### Severity

Scenario B causes a zombie sprint to appear resumable after cancellation. This is user-visible and can lead to data mutation on a cancelled sprint. Scenario A is cosmetic (hint appears but claim works).

### Fix

When a sprint is cancelled (whatever code path handles that), also cancel the linked ic run: `ic run cancel "$run_id"`. Then `ic run list --active` will naturally exclude it. Add this to the sprint cancellation command or `sprint_release` when finality is detected.

---

## Finding 4 — HIGH: checkpoint_read returns stale data after sprint restart

**Location:** Task 5, `checkpoint_read` (lines 897–914 of the plan)

### What the code does

```bash
checkpoint_read() {
    if intercore_available; then
        local run_id
        run_id=$(intercore_run_current "$(pwd)") || run_id=""
        if [[ -n "$run_id" ]]; then
            local ckpt
            ckpt=$(intercore_state_get "checkpoint" "$run_id") || ckpt=""
            if [[ -n "$ckpt" ]]; then
                echo "$ckpt"
                return 0
            fi
        fi
    fi
    # Fallback: file-based
    [[ -f "$CHECKPOINT_FILE" ]] && cat "$CHECKPOINT_FILE" 2>/dev/null || echo "{}"
}
```

### The staleness scenario

`intercore_run_current` (from `ic run current --project=<dir>`) returns "the most recent active run for a project directory" per the AGENTS.md. Multiple ic runs can exist for the same project directory simultaneously if the session started a new sprint before the old one's ic run was cancelled.

```
Sprint 1 (old): bead=iv-abc, run=run-aaa (status=active)
Sprint 2 (new): bead=iv-xyz, run=run-bbb (status=active, created later)
```

`ic run current` returns `run-bbb` (latest created_at). But the caller is working on sprint 1 (iv-abc) and calls `checkpoint_read` expecting iv-abc's checkpoint. They get run-bbb's checkpoint instead (or empty, if run-bbb has none).

This is a staleness violation of Invariant 5.

### Deeper issue: checkpoint_read is disconnected from sprint context

The original `checkpoint_read` had no sprint context — it just read the file. The new version introduces an implicit "find active run" lookup that may pick up the wrong run. The `checkpoint_write` function correctly scopes the checkpoint to a specific `run_id` (resolved from `bd state "$bead" ic_run_id`). But `checkpoint_read` uses `intercore_run_current` which is project-scoped, not bead-scoped. This asymmetry is the bug.

### Fix

`checkpoint_read` must accept an optional `bead_id` parameter so it can look up the correct `run_id` via `bd state "$bead_id" ic_run_id`. If no bead_id is provided, fall back to `intercore_run_current`.

```bash
checkpoint_read() {
    local bead_id="${1:-}"
    if intercore_available; then
        local run_id=""
        if [[ -n "$bead_id" ]]; then
            run_id=$(bd state "$bead_id" ic_run_id 2>/dev/null) || run_id=""
        fi
        if [[ -z "$run_id" ]]; then
            run_id=$(intercore_run_current "$(pwd)") || run_id=""
        fi
        if [[ -n "$run_id" ]]; then
            local ckpt
            ckpt=$(intercore_state_get "checkpoint" "$run_id") || ckpt=""
            if [[ -n "$ckpt" ]]; then
                echo "$ckpt"
                return 0
            fi
        fi
    fi
    [[ -f "$CHECKPOINT_FILE" ]] && cat "$CHECKPOINT_FILE" 2>/dev/null || echo "{}"
}
```

All callers that know the sprint/bead context should pass it. The integration test in Task 11 should verify this.

---

## Finding 5 — HIGH: Migration script triggers SpawnHandler on phase-advance calls

**Location:** Task 10, migration script (lines 1342–1347 of the plan)

### What the code does

```bash
# Advance ic run to match current phase
current_ic_phase="brainstorm"
while [[ "$current_ic_phase" != "$phase" && "$current_ic_phase" != "done" ]]; do
    result=$(ic run advance "$run_id" --priority=4 --json 2>/dev/null) || break
    current_ic_phase=$(echo "$result" | jq -r '.to_phase // ""' 2>/dev/null) || break
done
```

### The side-effect problem

From the intercore AGENTS.md:

> **SpawnHandler** — Registered Always. Auto-spawns pending agents when phase transitions to "executing"; wired in `cmdRunAdvance`.

> **HookHandler** — Registered Always. Executes `.clavain/hooks/on-phase-advance` with event JSON on stdin; async goroutine with 5s timeout.

Every call to `ic run advance` fires `SpawnHandler` and `HookHandler`. The `SpawnHandler` auto-spawns agents when the run transitions to the `executing` phase. The migration script advances runs through all phases up to their current phase, including potentially through `executing`.

**Failure narrative:**

Sprint iv-abc was at phase `executing` when it was last active. The migration script creates a new ic run at `brainstorm` and then calls `ic run advance` seven times to reach `executing`. On the seventh advance (from `plan-reviewed` to `executing`), `SpawnHandler` fires. If `CLAVAIN_DISPATCH_SH` is resolvable, this spawns a real Codex agent for a sprint that has already completed its executing phase and is being migrated as a record-keeping exercise.

This violates Invariant 7. The migration could launch live agent work against historical sprints.

### Fix — Two independent approaches, both needed

**Approach 1: Use `ic run skip` instead of `ic run advance` for migration**

Instead of advancing through phases, pre-skip all phases up to the target using `ic run skip`. Per the intercore AGENTS.md, `ic run skip` writes to the phase audit trail. If `ic run skip` does not fire `PhaseEventCallback` through the Advance path (which is what wires SpawnHandler), this is safe. Verify this assumption in `internal/phase/machine.go` before relying on it.

```bash
# Migration: skip all phases before the target phase
phases_array=("brainstorm" "brainstorm-reviewed" "strategized" "planned" "plan-reviewed" "executing" "shipping" "done")
for p in "${phases_array[@]}"; do
    [[ "$p" == "$phase" ]] && break
    ic run skip "$run_id" "$p" --reason="historical-migration" --actor="migrate-script" 2>/dev/null || true
done
# Then advance once to land on target (or skip if target is done)
[[ "$phase" != "brainstorm" ]] && \
    ic run advance "$run_id" --priority=4 --json 2>/dev/null || true
```

**Approach 2: Set a guard sentinel before the migration loop**

If `ic run skip` is not available or also fires events, set a sentinel that the SpawnHandler checks before spawning:

```bash
export CLAVAIN_NO_SPAWN=1  # SpawnHandler must honor this env var
# run migration
unset CLAVAIN_NO_SPAWN
```

This requires Go-side support in SpawnHandler and is the cleaner long-term solution.

The safest practical fix for this plan iteration is Approach 1 with the caveat verified against `internal/phase/machine.go`.

---

## Finding 6 — MEDIUM: `intercore_run_list` uses unquoted `$@` — word-splitting hazard

**Location:** Task 1, `intercore_run_list` wrapper (lines 89–93 of the plan)

### What the code does

```bash
intercore_run_list() {
    if ! intercore_available; then echo "[]"; return 0; fi
    # shellcheck disable=SC2086
    "$INTERCORE_BIN" run list --json $@ 2>/dev/null || echo "[]"
}
```

The `# shellcheck disable=SC2086` suppresses the warning but does not fix the underlying word-splitting issue. If a caller passes `"--scope=iv-1234 --active"` as a single string (which can happen when building flags dynamically), it will be passed as a single token to `$INTERCORE_BIN`, which will fail to parse it.

The current call site `intercore_run_list "--active"` passes a single literal string and works accidentally. The issue bites if a future caller builds a flag string with spaces.

### Fix

Use `"$@"` (quoted) — the shellcheck disable is unnecessary:

```bash
intercore_run_list() {
    if ! intercore_available; then echo "[]"; return 0; fi
    "$INTERCORE_BIN" run list --json "$@" 2>/dev/null || echo "[]"
}
```

---

## Finding 7 — MEDIUM: sprint_create non-atomicity — bead-run link can be lost on crash

**Location:** Task 2, `sprint_create` (lines 140–193 of the plan)

### What the code does

```bash
sprint_create() {
    # Step 1: Create bead
    sprint_id=$(bd create ...) || { echo ""; return 0; }
    bd set-state "$sprint_id" "sprint=true" ...
    bd update "$sprint_id" --status=in_progress ...

    # Step 2: Create ic run
    run_id=$(intercore_run_create "$(pwd)" "$title" "$phases_json" "$sprint_id") || run_id=""
    if [[ -z "$run_id" ]]; then
        bd update "$sprint_id" --status=cancelled ...
        echo ""
        return 0
    fi

    # Step 3: Store link  ← crash here → orphaned ic run
    bd set-state "$sprint_id" "ic_run_id=$run_id" 2>/dev/null || true

    # Step 4: Verify
    ...
}
```

### The crash window

Between Step 2 (ic run created with `scope_id=sprint_id`) and Step 3 (bd set-state ic_run_id), if the process crashes:

- A live ic run exists in the ic DB with `scope_id=sprint_id`
- The bead has no `ic_run_id` in its state
- On the next `sprint_create` call for the same bead, `intercore_run_create` will create a second ic run with the same `scope_id`
- `ic run list --active --scope=<bead_id>` now returns two runs; `sprint_find_active` sees both

There is no cleanup path for this orphaned ic run in the plan.

### Fix

Add a pre-flight check in `sprint_create`: before creating a new ic run, check for and cancel any existing orphaned runs with the same scope_id:

```bash
# Crash recovery: cancel any orphaned ic runs for this bead
if intercore_available; then
    existing_json=$(ic run list --active --scope="$sprint_id" --json 2>/dev/null) || existing_json="[]"
    echo "$existing_json" | jq -r '.[].id' | while read -r orphan_id; do
        ic run cancel "$orphan_id" 2>/dev/null || true
    done
fi
```

Alternatively, treat the orphaned run as a valid recovery path: if an ic run already exists for this scope_id, reuse it and write its ID to bead state instead of creating another.

---

## Finding 8 — MEDIUM: sprint_release has a pipeline-subshell race — updates are unverifiable

**Location:** Task 3, `sprint_release` (lines 599–608 of the plan)

### What the code does

```bash
sprint_release() {
    ...
    if [[ -n "$run_id" ]] && intercore_available; then
        local agents_json
        agents_json=$("$INTERCORE_BIN" run agent list "$run_id" --json ...) || agents_json="[]"
        echo "$agents_json" | jq -r '.[] | select(.status == "active" and .agent_type == "session") | .id' | \
            while read -r agent_id; do
                "$INTERCORE_BIN" run agent update "$agent_id" --status=completed ... || true
            done
        return 0
    fi
    ...
}
```

The `while read -r agent_id; do ... done` runs in a subshell (created by the pipe). The `return 0` outside the pipe is always executed regardless of whether the while loop succeeded. This is the intended fail-safe behavior (release is best-effort), but it means a failed release leaves active agents in the DB indefinitely.

The next `sprint_claim` call will see stale active agents and apply the 60-minute staleness check. This is acceptable, but the plan should explicitly document that release failure is recoverable via the staleness TTL (60 minutes), so operators understand the worst-case hold time after a crash.

### Severity

Low-medium. The staleness fallback handles it. Add a comment to make this explicit.

---

## Finding 9 — MEDIUM: ic events tail used with `todate` filter — may fail if timestamp is a string

**Location:** Task 2, `sprint_read_state` (lines 357–361 of the plan)

### What the code does

```bash
events_json=$("$INTERCORE_BIN" events tail "$run_id" --json 2>/dev/null) || events_json=""
if [[ -n "$events_json" ]]; then
    history=$(echo "$events_json" | jq -s '
        [.[] | select(.source == "phase" and .type == "advance") |
         {((.to_state // "") + "_at"): (.timestamp // "" | todate)}] | add // {}' 2>/dev/null) || history="{}"
fi
```

The `jq` `todate` filter expects a Unix epoch number. If `timestamp` in ic events is stored as an ISO-8601 string (which is what intercore typically stores per the schema conventions in AGENTS.md — "first_seen TEXT NOT NULL DEFAULT (datetime('now'))"), then `todate` will fail with a runtime error.

The `2>/dev/null` suppresses the error and `|| history="{}"` catches it, so `history` will be `{}` rather than the actual history. This silently loses phase completion timestamps in `sprint_read_state`.

### Fix

Check the ic event schema for the `timestamp` field type. If it is a string, use it directly without `todate`:

```bash
{((.to_state // "") + "_at"): (.timestamp // "")}
```

If it is a Unix epoch integer, `todate` is correct.

---

## Finding 10 — LOW: intercore_state_set calling convention mismatch

**Location:** Task 5, `checkpoint_write` and `sprint_finalize_init` (lines 870, 213 of the plan)

### What the plan does

```bash
# sprint_finalize_init:
echo "{\"bead_id\":\"$sprint_id\",\"run_id\":\"$run_id\"}" | \
    intercore_state_set "sprint_link" "$sprint_id" 2>/dev/null || true

# checkpoint_write:
echo "$checkpoint_json" | intercore_state_set "checkpoint" "$run_id" 2>/dev/null || true
```

### What the existing wrapper expects

From `/root/projects/Interverse/hub/clavain/hooks/lib-intercore.sh` (line 36-40):

```bash
intercore_state_set() {
    local key="$1" scope_id="$2" json="$3"
    if ! intercore_available; then return 0; fi
    printf '%s\n' "$json" | "$INTERCORE_BIN" state set "$key" "$scope_id" || return 0
}
```

The existing wrapper accepts `json` as `$3` (a positional argument) and internally pipes it to ic. The plan's callers pipe JSON via stdin instead (`echo "$json" | intercore_state_set ...`). With the current wrapper, this works because stdin is inherited by the pipeline, but `$3` will be empty. The wrapper pipes `printf '%s\n' ""` which writes an empty string — but the pipe from the caller provides the actual JSON on stdin which ic reads directly.

This works now due to stdin propagation through pipes, but is fragile. If the wrapper is ever changed to be non-pipe-based, the callers will silently write empty JSON.

### Fix

Pick one calling convention. The cleanest is to pass JSON as positional argument `$3` and call normally:

```bash
intercore_state_set "checkpoint" "$run_id" "$checkpoint_json" 2>/dev/null || true
```

---

## Finding 11 — LOW: Migration script dry-run count semantics differ from real-run

**Location:** Task 10, migration script (lines 1328–1331 of the plan)

In dry-run mode, `MIGRATED` counts beads that would be migrated (including those that might fail `ic run create`). In real-run mode, `MIGRATED` counts beads that were successfully migrated. The summary output looks identical but has different semantics. Document this in the script.

---

## Finding 12 — LOW: sprint_advance fallback lock ordering comment is not preserved

**Location:** Task 4, `sprint_advance` fallback path (lines 755–757 of the plan)

The existing `lib-sprint.sh` (line 489) has an important lock ordering comment:

```bash
# NOTE: sprint_record_phase_completion acquires "sprint" lock inside this "sprint-advance" lock.
# Lock ordering: sprint-advance > sprint. Do not reverse.
```

The plan's rewrite of `sprint_advance` preserves the behavior (fallback path still calls `sprint_record_phase_completion` under the sprint-advance lock) but drops this comment. Preserve it to prevent future deadlocks from lock-order reversal.

---

## Summary Table

| # | Finding | Severity | Invariant | Fix Required |
|---|---------|----------|-----------|--------------|
| 1 | sprint_claim ic-path: no lock around check-then-register | CRITICAL | Claim exclusion | Add `intercore_lock "sprint-claim"` around full check-register sequence |
| 2 | sprint_advance: JSON error parsing unreliable if ic outputs nothing on failure | HIGH | Phase monotonicity | Verify `ic run advance --json` emits JSON on all exit codes |
| 3 | sprint_find_active: bead cancelled after ic list read; zombie sprint appears resumable | HIGH | Consistency | Cancel ic run when sprint bead is cancelled |
| 4 | checkpoint_read: project-scoped run_id lookup returns wrong run when multiple ic runs exist | HIGH | Checkpoint currency | Accept optional bead_id; use bead-scoped lookup first |
| 5 | Migration script triggers SpawnHandler on advance through "executing" phase | HIGH | No side effects during migration | Use `ic run skip` for historical phases; verify skip bypasses SpawnHandler |
| 6 | `intercore_run_list` uses unquoted `$@` — word-splitting hazard | MEDIUM | Robustness | Change to `"$@"` |
| 7 | sprint_create crash window: ic run created but ic_run_id not written to bead | MEDIUM | Bead/run link integrity | Add orphan cleanup before creating new ic run |
| 8 | sprint_release: silently swallows agent update failures; 60-min staleness fallback undocumented | MEDIUM | Claim exclusion (degraded) | Document 60-min staleness fallback in code comments |
| 9 | sprint_read_state: `todate` jq filter fails if timestamp is ISO-8601 string | MEDIUM | History integrity | Verify ic timestamp format; remove `todate` if string |
| 10 | intercore_state_set: pipe-based call convention inconsistent with wrapper positional-arg design | LOW | Maintainability | Pick one calling convention and document it |
| 11 | Migration dry-run count semantics differ from real-run count | LOW | Observability | Document the distinction |
| 12 | Lock ordering comment (sprint-advance > sprint) dropped in plan rewrite | LOW | Deadlock prevention | Restore comment in new code |

---

## Recommended Action Order

1. **Fix Finding 1 (CRITICAL) before any other change.** The claim race will cause concurrent state mutation in production whenever two sessions resume the same sprint simultaneously. This wakes someone at 3 AM when artifact paths are overwritten and phase history diverges. Add the `intercore_lock` wrapper around the entire check-register block in the ic path.

2. **Fix Finding 5 before running the migration script.** If the migration fires SpawnHandler on historical sprints at `executing` phase, it will launch real agent dispatches. Verify with `ic run skip` or add an environment guard before running against production beads.

3. **Fix Finding 4 before enabling `checkpoint_write` on ic.** The asymmetric `checkpoint_read` lookup will return the wrong checkpoint whenever multiple ic runs exist for a project directory — a common state during active development.

4. **Fix Finding 2 (JSON parse on ic advance failure)** by confirming with the intercore implementation that `--json` applies to all exit-code paths, including block and pause.

5. **Fix Finding 3 (sprint cancellation)** by adding `ic run cancel` to the sprint cancellation flow.

6. **Findings 6–12** are low/medium and can be addressed in follow-up tasks before the plan is declared complete.
