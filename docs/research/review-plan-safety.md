# Safety Review: Intercore E3 Hook Cutover Plan
**Plan file:** `docs/plans/2026-02-19-intercore-e3-hook-cutover.md`
**Reviewer:** Flux-drive Safety Reviewer
**Date:** 2026-02-19
**Classification:** High Risk — irreversible state migration, hard dependency introduction, sprint workflow breakage on failure

---

## Architecture Context

This plan migrates Clavain's sprint runtime state from two fragile backing stores (beads `bd set-state` + temp files) to intercore's `ic` CLI, which is backed by a single SQLite WAL database at `.clavain/intercore.db`. The migration is described as "big-bang" — all 12 tasks implement new code, then a migration script backfills existing sprint records, and new sessions after cutover depend exclusively on `ic`.

The threat model here is not external adversaries. The relevant failure modes are:

- `ic` binary absent or DB uninitialized on a live sprint session
- Partial task deployment leaving sprint CRUD in a split-brain state
- Migration script producing incorrect phase state for existing sprints
- Session spanning the cutover moment seeing neither old nor new state
- Rollback leaving orphaned `ic run` records with no corresponding bead data

---

## Finding 1 — CRITICAL: No Rollback Path Defined (Irreversible Cutover)

**Risk level:** High
**Impact:** Sprint workflow completely broken, no recovery without manual intervention

The plan has twelve tasks, none of which includes a rollback procedure. Task 6 (sentinel cleanup) removes the temp-file fallback from `intercore_sentinel_check_or_legacy`. Once Task 6 is deployed, any environment where `ic` is unavailable (binary missing, DB uninitialized, DB corrupted) will lose sentinel throttling entirely rather than degrading to temp-file behavior. That is acceptable per the PRD — but there is a more serious problem.

After Tasks 2-5 complete, `sprint_find_active`, `sprint_read_state`, `sprint_advance`, `sprint_claim`, and `sprint_set_artifact` all follow this pattern:

```bash
run_id=$(bd state "$sprint_id" ic_run_id 2>/dev/null) || run_id=""

if [[ -n "$run_id" ]] && intercore_available; then
    # PRIMARY PATH: all meaningful work happens here
    ...
    return 0
fi

# FALLBACK: beads-based (legacy sprints)
```

The fallback only fires when `run_id` is empty (bead has no `ic_run_id`) OR when `ic` is unavailable. For sprints migrated by Task 10, `run_id` is stored on the bead. If `ic` is subsequently unavailable (DB deleted, binary removed, schema migration failure), `intercore_available()` returns 1, and execution falls to the beads-based fallback — but the beads-based data for those sprints was never maintained after migration. The `phase`, `sprint_artifacts`, `phase_history`, and `active_session` fields in beads are now stale or missing.

This means: **after successful migration, removing or breaking `ic` silently produces stale state reads, not errors**. The fallback path gives false data rather than an honest failure.

**Specific gap — rollback scenario:**

1. Migration runs successfully, all sprints get `ic_run_id` written to bead state.
2. User decides to roll back to previous code (reverts Tasks 2-5 commits).
3. Old `sprint_find_active` still reads beads. Old `sprint_read_state` still reads beads. Those fields were last updated before migration.
4. Any phase advancement, artifact recording, or claims done via `ic` after migration are invisible to old code.
5. No data loss in `ic`, but old code cannot see it.

Rolling back code does NOT roll back the `ic run` records or the `ic_run_id` bead state. The two systems diverge permanently.

**Required mitigations:**

a. Before running the migration script (Task 10), take a snapshot of all sprint bead states that will be migrated:
```bash
bd list --status=in_progress --json > /tmp/sprint-state-pre-migration-$(date +%s).json
for id in $(bd list --status=in_progress --json | jq -r '.[].id'); do
    bd state "$id" phase
    bd state "$id" sprint_artifacts
    bd state "$id" phase_history
done > /tmp/sprint-detail-pre-migration-$(date +%s).txt
```

b. Write an explicit rollback script that: reads each `ic_run_id` from beads, reads current `ic run status` for each, writes phase, artifacts, and phase_history back to beads, and clears `ic_run_id` from the bead state. This restores the invariant that old code needs.

c. Define the rollback decision window explicitly — for example, rollback is feasible within 24 hours if no sprint advances past the phase recorded at migration time. After that, rolling back requires the snapshot to avoid data loss.

---

## Finding 2 — HIGH: Hard Failure Mode After Task 6 with Missing or Broken ic

**Risk level:** High
**Impact:** All sprint operations silently return wrong data; sessions appear to work but sprint state is stale

After Task 6, `intercore_check_or_die` becomes:

```bash
intercore_check_or_die() {
    local name="$1" scope_id="$2" interval="$3"
    if intercore_available; then
        intercore_sentinel_check "$name" "$scope_id" "$interval" || exit 0
        return 0
    fi
    # No ic available — allow (fail-open)
    return 0
}
```

This is fail-open for the sentinel (non-sprint hooks can fire unrestricted if `ic` is absent). That is acceptable for observability hooks. The PRD calls this out for catalog-reminder and auto-publish.

However, the sprint functions that depend on `ic` after migration do NOT fail-open with an error. They silently fall through to the beads fallback, which returns stale data. From the session's perspective, the sprint appears to be in an old phase and has no artifacts — there is no error surfaced.

The `intercore_available()` function already handles the DB-not-initialized case:

```bash
if ! "$INTERCORE_BIN" health >/dev/null 2>&1; then
    printf 'ic: DB health check failed — run ic init or ic health\n' >&2
    INTERCORE_BIN=""
    return 1
fi
```

The stderr message is written, but the calling sprint functions suppress stderr and return stale beads data. The sprint skill would continue working from old phase state without any user-visible error.

**Fresh clone scenario (concrete):**

1. Developer clones the repo, does not run `ic init`.
2. `.clavain/intercore.db` does not exist.
3. `intercore_available()` returns 1 (binary found but `ic health` fails).
4. `sprint_find_active()` returns `[]` (ic path skipped, beads fallback runs, finds beads with `sprint=true` but no `ic_run_id` since they were not migrated on this clone — so fallback works for unmigrated beads).
5. For migrated beads (those with `ic_run_id` set): `sprint_read_state()` falls to beads path, which has stale phase data.

The fresh-clone case is recoverable only if the developer runs `ic init && bash hub/clavain/scripts/migrate-sprints-to-ic.sh`. This is not documented in the plan.

**Required mitigations:**

a. When `run_id` is non-empty but `intercore_available()` returns false, the sprint functions should log a visible warning rather than silently falling back:
```bash
if [[ -n "$run_id" ]] && ! intercore_available; then
    echo "WARNING: sprint $sprint_id has ic_run_id=$run_id but ic is unavailable. State may be stale." >&2
fi
```

b. Add an explicit setup requirement to `hub/clavain/AGENTS.md` and `hub/clavain/CLAUDE.md`: "After initial clone or after E3 cutover, run `ic init && bash hub/clavain/scripts/migrate-sprints-to-ic.sh`."

c. Consider adding a health gate in `session-start.sh` that checks `intercore_available()` and, if sprints with `ic_run_id` are found but `ic` is unavailable, emits a session-start warning rather than a silent hint with stale phase data.

---

## Finding 3 — HIGH: Migration Script Phase Advancement Is Not Idempotent Under Failure

**Risk level:** High
**Impact:** Duplicate `ic run` records, or run at wrong phase after partial failure

The migration script (Task 10) advances each new `ic run` to match the existing bead phase via a while loop:

```bash
run_id=$(ic run create --project="$(pwd)" --goal="$title" --phases="$PHASES_JSON" --scope-id="$bead_id" 2>/dev/null) || run_id=""

# Advance ic run to match current phase
current_ic_phase="brainstorm"
while [[ "$current_ic_phase" != "$phase" && "$current_ic_phase" != "done" ]]; do
    result=$(ic run advance "$run_id" --priority=4 --json 2>/dev/null) || break
    current_ic_phase=$(echo "$result" | jq -r '.to_phase // ""' 2>/dev/null) || break
done

# Store run_id on bead
bd set-state "$bead_id" "ic_run_id=$run_id" 2>/dev/null || true
```

The script is described as idempotent (skips beads that already have `ic_run_id`). However, consider this partial failure sequence:

1. `ic run create` succeeds — run created in DB.
2. Phase advancement loop runs — advances 3 of 5 steps, then `ic run advance` returns non-zero.
3. The `|| break` exits the loop early.
4. `bd set-state "$bead_id" "ic_run_id=$run_id"` succeeds — bead now has `ic_run_id`.
5. Migration reports the sprint as migrated (MIGRATED counter increments after the while loop, regardless of whether phase advancement succeeded).

On a re-run: the script sees `ic_run_id` on the bead, logs "SKIP", and moves on. The `ic run` exists at the wrong phase. Sprint code will read the wrong phase from `ic run status`.

**Secondary issue: gate interference during advancement.**

`ic run advance --priority=4` sets priority 4 (described in the AGENTS.md as "no gates"). However, the AGENTS.md does not confirm that priority=4 disables ALL gate checks or only some. If a gate blocks advancement during migration (e.g., a required artifact gate that the migrated sprint genuinely didn't satisfy), the loop breaks early and the ERRORS counter is not incremented — the sprint is still counted as MIGRATED.

**Required mitigations:**

a. Move `bd set-state "$bead_id" "ic_run_id=$run_id"` to AFTER verifying that `current_ic_phase == "$phase"`. If the loop exits before reaching the target phase, record the sprint as an ERROR and do not write `ic_run_id`:

```bash
if [[ "$current_ic_phase" == "$phase" ]]; then
    bd set-state "$bead_id" "ic_run_id=$run_id" 2>/dev/null || true
    echo "  -> Created run $run_id (phase: $current_ic_phase)"
    MIGRATED=$((MIGRATED + 1))
else
    echo "  ERROR: Phase advancement stalled at $current_ic_phase (target: $phase). Run id $run_id left unclaimed."
    ERRORS=$((ERRORS + 1))
fi
```

b. The migration script should emit a distinct exit code (non-zero) if ERRORS > 0, so callers can detect partial failure.

c. Add `--disable-gates` to the advancement calls during migration (if supported), or explicitly confirm that `--priority=4` bypasses all gate checks. The AGENTS.md shows `ic run advance <id> [--priority=N] [--disable-gates]` exists — use `--disable-gates` in the migration script to prevent gate interference with historical sprint state reconstruction.

---

## Finding 4 — MEDIUM: Session-Spanning-Cutover Race (Sprint Started Before, Session Resumed After)

**Risk level:** Medium
**Impact:** Session sees sprint in old state; any phase advance or artifact write goes to wrong backing store

The plan addresses this in Task 7 (session-start.sh) and relies on the migration script (Task 10) to backfill existing sprints. The critical window is this sequence:

1. Session A starts before cutover. Sprint `iv-abc` is created. Bead state: `phase=brainstorm`, no `ic_run_id`.
2. Cutover deploys Tasks 1-9 (new code in place, migration not yet run).
3. Session A is suspended (Claude Code session paused, user away).
4. Migration script runs — finds `iv-abc` with `sprint=true`, no `ic_run_id`. Creates `ic run`, advances to `brainstorm`, writes `ic_run_id` to bead.
5. Session A resumes. `lib-sprint.sh` is re-sourced (it is sourced on session-start).

In this case, Session A should pick up the new `ic_run_id` because lib-sprint.sh reads `bd state "$sprint_id" ic_run_id` dynamically at function call time, not at source time. The sourcing is not the issue.

The actual problem is the reverse: a session that started AFTER cutover (Task 10 run) but before the bead was migrated (migration failed or was not run yet). In that case:

1. `sprint_find_active()` runs via ic path (`intercore_available()` returns true).
2. Queries `ic run list --active` — returns nothing (no ic runs exist yet).
3. Returns `[]`.
4. Session sees no active sprints, shows no resume hint.
5. User types `/sprint iv-abc` — sprint skill must look up the sprint another way.

The plan does not specify what happens when a user manually resumes a sprint that has not yet been migrated. The sprint skill presumably calls `sprint_read_state("iv-abc")` which would hit `bd state "iv-abc" ic_run_id`, get nothing, fall to beads path, and return the old phase. This is actually fine for read operations — the fallback works correctly for unmigrated beads.

The dangerous case is write operations. If the user advances the sprint via the sprint skill before migration, `sprint_advance("iv-abc", "brainstorm")` falls to the beads path (since `ic_run_id` is absent) and writes `phase=brainstorm-reviewed` to beads. When migration later runs, it reads `phase=brainstorm-reviewed` from beads and tries to advance the new `ic run` two steps. This is correct behavior — migration is designed for this.

However, if the user then runs the sprint skill again immediately, `sprint_find_active()` finds no ic runs and returns `[]` — the sprint is invisible. This is a confusing UX gap, not a data integrity problem.

**The one genuine data integrity gap:** If the migration script ran for sprint `iv-abc` (creating `ic run` at `brainstorm`), then the user advances the sprint via beads fallback before the migration could write `ic_run_id` (i.e., between `ic run create` and `bd set-state ic_run_id`), the migration writes `ic_run_id` but the bead's phase was advanced further than what the ic run reflects. The `ic run` phase and bead phase diverge permanently until another advance occurs.

This window is tiny and only occurs if the migration script is interrupted between those two lines. It is low probability but non-zero.

**Required mitigations:**

a. Order the deployment so migration script runs BEFORE any sessions that might start new sprints see the new `sprint_find_active` code. In practice: deploy Tasks 1-9, run migration, then restart active sessions.

b. Document the recommended deployment sequence explicitly (see Finding 5 below).

c. For the migration script, the `ic run create` + `bd set-state ic_run_id` pair should be wrapped in an `intercore_lock` to prevent a concurrent sprint skill call from operating on the bead between those two writes. This is a narrow race but worth closing given the sprint session context.

---

## Finding 5 — HIGH: No Deployment Ordering or Pre-Deploy Checklist

**Risk level:** High
**Impact:** Partial deployment leaves sprint CRUD in a split-brain state; no measurable pass/fail criteria

The plan has 12 tasks but no deployment sequencing guidance. The tasks have implicit ordering constraints that are not called out:

**Dependency chain (must deploy in this order):**

```
Task 1 (lib-intercore.sh wrappers)
  -> Task 2 (sprint_create, sprint_find_active, sprint_read_state) — calls new wrappers
  -> Task 3 (sprint_set_artifact, sprint_claim, sprint_release) — calls new wrappers
  -> Task 4 (enforce_gate, sprint_advance, sprint_should_pause) — calls new wrappers
  -> Task 5 (checkpoint, complexity) — calls new wrappers
  -> Task 9 (sprint_track_agent) — calls new wrappers
  -> Task 10 (migration script) — MUST run before sessions restart
  -> Task 6 (sentinel cleanup) — MUST be last; removes last temp-file fallback
Task 7 (session-start.sh) — safe at any point after Task 2
Task 8 (event reactor hooks) — safe at any point after ic binary is present
Task 12 (lib-gates.sh deprecation) — safe at any point
```

**Breakage window analysis (partial deploy):**

- Tasks 2-5 committed but NOT Task 10 (migration not run): New sessions use ic path. Old sprints have no `ic_run_id`. `sprint_find_active()` via ic path returns `[]`. Old sprints invisible to users. DATA NOT LOST (beads still accurate), but UX is broken.
- Task 10 run but Tasks 2-5 NOT committed: Migration writes `ic_run_id` to beads, but old code never reads it. No user-visible breakage. Safe order to avoid breakage.
- Tasks 2-5 committed AND Task 10 run, but ic binary missing: Finding 2 applies.
- Task 6 committed before Task 10: Temp-file sentinels removed. Any hook that relied on temp-file fallback because ic was unhealthy now gets no sentinel at all (fail-open). For Stop hook dedup this matters: multiple Stop hooks could fire in the same cycle.

**Pre-deploy checklist (missing from plan, must be added):**

```
[ ] ic binary is installed and on PATH for all hook execution environments
[ ] ic health passes in hub/clavain/ directory
[ ] ic init has been run (or health check confirms DB initialized)
[ ] No active sprint sessions are running (ideally coordinate deployment with session boundaries)
[ ] bd list --status=in_progress | grep sprint returns a known set of sprints (document count)
[ ] Dry-run migration: bash hub/clavain/scripts/migrate-sprints-to-ic.sh --dry-run (zero errors expected)
```

**Post-deploy verification (missing from plan, must be added):**

```
[ ] bash -n on all modified files (plan includes this per-task but not as a final gate)
[ ] sprint_find_active returns the expected sprints (check count matches pre-deploy)
[ ] ic run list --active returns same count as bd list --status=in_progress for sprint beads
[ ] For each migrated sprint: ic run phase matches the phase previously in beads
[ ] Session-start sprint resume hint appears correctly in a new session
[ ] sprint_advance works end-to-end on a test sprint (run Task 11's integration test)
```

---

## Finding 6 — MEDIUM: sprint_find_active Has N+1 Reads Against Beads After ic Query

**Risk level:** Medium
**Impact:** Performance regression and TOCTOU gap — the "fast path" is not as fast as claimed

The new `sprint_find_active` uses `ic run list --active` to get runs, then for each run, calls `bd state "$scope_id" sprint` and `bd state "$scope_id" sprint_initialized` to validate the bead:

```bash
while [[ $i -lt $count && $i -lt 100 ]]; do
    ...
    if [[ -n "$scope_id" ]]; then
        local is_sprint
        is_sprint=$(bd state "$scope_id" sprint 2>/dev/null) || is_sprint=""
        if [[ "$is_sprint" == "true" ]]; then
            local initialized
            initialized=$(bd state "$scope_id" sprint_initialized 2>/dev/null) || initialized=""
            if [[ "$initialized" == "true" ]]; then
                local title
                title=$(bd show "$scope_id" 2>/dev/null | head -1 | sed ... )
```

That is 3 beads reads per active run. If there are 10 active runs, this is 30 `bd state` calls plus 10 `bd show` calls — the same N+1 problem the plan claims to solve. The only difference is that the outer query is now `ic run list --active` (one SQLite query) instead of `bd list --status=in_progress` (one beads query).

The PRD acceptance criterion for F1 is: "sprint_find_active calls `ic run list --active --project=.` (single query, no N+1)". The implementation does NOT satisfy this criterion. It has moved one query to ic but kept N+1 beads reads for validation.

This is a correctness-of-intent issue as much as a performance issue. The design intent was to eliminate N+1 reads. The implementation still has them. In practice, for the expected sprint count (1-3 active sprints at a time), this is acceptable performance but represents technical debt.

**Required mitigation:**

The `sprint_initialized` check could be skipped entirely for runs discovered via ic — if an ic run exists with a scope_id, it was created by `sprint_create()` which already set `sprint_initialized` on the bead. The `sprint_initialized` check exists to filter out half-initialized beads from the old beads-only path. For ic-backed runs, the ic run's existence IS the initialization proof.

Remove the `bd state "$scope_id" sprint_initialized` check from the ic fast-path. Keep only `bd state "$scope_id" sprint` and `bd show "$scope_id"` for title retrieval (2 calls instead of 3). Or better: store the title in the `ic run` goal field and read from there.

---

## Finding 7 — MEDIUM: sprint_advance Error Handling Has a Logic Inversion

**Risk level:** Medium
**Impact:** Gate-blocked and pause events are lost when ic run advance exits non-zero without JSON output

In `sprint_advance` (Task 4):

```bash
result=$(intercore_run_advance "$run_id") || {
    local rc=$?
    local event_type from_phase to_phase
    event_type=$(echo "$result" | jq -r '.event_type // ""' 2>/dev/null) || event_type=""
```

`intercore_run_advance` pipes stderr through `2>/dev/null`. When `ic run advance` returns non-zero (gate blocked, auto_advance pause), the output goes to stdout (with `--json`). The `|| { }` block captures `$?` but `$result` already holds the output because it was captured in the command substitution BEFORE the `||` is evaluated.

This is actually correct — `result` holds whatever stdout was printed before the non-zero exit. However, there is a subtle issue: `$rc` is set inside `local rc=$?`, but `local` itself always returns 0, so `$rc` is correctly set only if `local` is declared before `rc=$?`. In this code, `local rc=0` is declared before the command, and `rc=$?` is set via `local rc=$?` inline. Actually the code says:

```bash
result=$(intercore_run_advance "$run_id") || {
    local rc=$?
```

In bash, `local rc=$?` inside a `||` compound statement sets `rc` to the exit code of `intercore_run_advance`. This IS correct in bash — `$?` inside the compound command after `||` holds the exit code of the left side.

The actual concern: `intercore_run_advance` wraps `ic run advance --json 2>/dev/null`. If `ic run advance` exits 1 (gate blocked) AND writes structured JSON to stdout, the `result` variable contains that JSON and the error-case parsing works. But if `ic` exits 2 (unexpected error) and writes nothing to stdout, `result` is empty, `jq` gets empty input, and all three variables (`event_type`, `from_phase`, `to_phase`) come up empty. The `case "$event_type"` statement hits `*)`, then calls `intercore_run_phase` to detect phase staleness. This is a reasonable fallback but the original error is swallowed.

**Required mitigation (low-urgency):**

When `event_type` is empty AND `from_phase`/`to_phase` are both empty, log the raw `$result` to stderr so the error is not completely silent:
```bash
*)
    if [[ -z "$event_type" && -z "$from_phase" ]]; then
        echo "sprint_advance: ic run advance returned unexpected result: ${result:-<empty>}" >&2
    fi
```

---

## Finding 8 — MEDIUM: sprint_claim Staleness Check Uses Unix Epoch from ic, Not a Timestamp

**Risk level:** Medium
**Impact:** Stale claim detection may misfire on agents with epoch 0

In `sprint_claim` (Task 3):

```bash
created_at=$(echo "$active_agents" | jq -r '.[0].created_at // 0')
now_epoch=$(date +%s)
age_minutes=$(( (now_epoch - created_at) / 60 ))
if [[ $age_minutes -lt 60 ]]; then
    echo "Sprint $sprint_id is active in session ${existing_name:0:8} (${age_minutes}m ago)" >&2
    return 1
fi
```

If `ic run agent list` returns `created_at` as a Unix timestamp (integer) this works correctly. But the AGENTS.md and schema do not explicitly confirm the field name or format for `run_agents.created_at`. If `created_at` comes back as a RFC3339 string (common in Go APIs using `time.Time`), then `(now_epoch - "2026-02-19T00:00:00Z") / 60` evaluates as `(now_epoch - 0) / 60` due to bash integer arithmetic treating a non-numeric string as 0. This would make `age_minutes` equal to `now_epoch / 60` — approximately 35 years — which is always >= 60, so every stale check would evict the existing claim.

The result is that concurrent session claims could silently evict each other's claims if the `created_at` field is not a Unix integer.

**Required mitigation:**

Verify the `created_at` field format from `ic run agent list --json` before writing this code. If it is RFC3339, convert it using `date -d`:
```bash
created_at_str=$(echo "$active_agents" | jq -r '.[0].created_at // "1970-01-01T00:00:00Z"')
created_at=$(date -d "$created_at_str" +%s 2>/dev/null) || created_at=0
```

---

## Finding 9 — LOW: intercore_run_list Uses Unquoted $@ (ShellCheck Disable Comment Is Needed)

**Risk level:** Low
**Impact:** Flags containing spaces would split incorrectly; harmless for current callers

In Task 1, `intercore_run_list`:

```bash
intercore_run_list() {
    if ! intercore_available; then echo "[]"; return 0; fi
    # shellcheck disable=SC2086
    "$INTERCORE_BIN" run list --json $@ 2>/dev/null || echo "[]"
}
```

The `$@` without quotes is used intentionally (the comment disables SC2086). However, `$@` should be `"$@"` — `$@` is only equivalent to `"$@"` inside double quotes. With `$@` unquoted, flags containing spaces (e.g., `"--scope=some id with spaces"`) would split into multiple arguments. The `# shellcheck disable=SC2086` comment suppresses the wrong warning — SC2086 is for unquoted `$variable`, not `$@` — and the correct form `"$@"` does not need a disable comment.

Replace `$@` with `"$@"` and remove the disable comment.

---

## Finding 10 — LOW: Task 2 sprint_find_active Has Unvalidated bd show Output Parsing

**Risk level:** Low
**Impact:** Title extraction silently returns empty string on unexpected bd show output format

```bash
title=$(bd show "$scope_id" 2>/dev/null | head -1 | sed 's/^[^·]*· //' | sed 's/ *\[.*$//' || echo "$goal")
```

The `|| echo "$goal"` fallback only fires if the entire pipeline exits non-zero. `sed` always exits 0, so even if `bd show` returns unexpected output, `goal` is never used as the fallback. The `|| echo "$goal"` is dead code.

This is a cosmetic issue (wrong title displayed, not wrong state), but worth noting because the PRD requires the title to map back to the bead.

---

## Finding 11 — LOW: Task 5 checkpoint_read Finds Run by CWD, Not by Sprint ID

**Risk level:** Low
**Impact:** checkpoint_read may return wrong checkpoint when multiple projects/sprints exist

`checkpoint_read` uses `intercore_run_current("$(pwd)")` which returns the active run for the current working directory — not necessarily the run for the sprint the caller has in mind. If two sprints are active for the same project directory (unlikely but possible), `checkpoint_read` returns the "current" run's checkpoint, not a specific sprint's checkpoint.

The `checkpoint_write` function writes to `ic state set "checkpoint" "$run_id"` using the specific `run_id` looked up from the bead. But `checkpoint_read` uses `intercore_run_current` which may return a different run. This is an asymmetry that could cause one sprint's checkpoint to be read when working in another sprint's context.

The fix: `checkpoint_read` should accept a `run_id` parameter (or derive it from the bead ID the caller knows), rather than querying `ic run current`. Alternatively, scope checkpoint keys to `"checkpoint:$run_id"` to avoid collisions.

---

## Deployment Sequencing Recommendation

The plan lacks a safe deployment order. The following sequence minimizes breakage windows:

**Phase 1 — Prepare (no user impact):**
1. Deploy Task 1 (lib-intercore.sh wrappers) — additive, no behavior change
2. Deploy Task 8 (event reactor hooks) — new files, no existing code changed
3. Deploy Task 12 (lib-gates.sh deprecation comment) — documentation only
4. Verify ic binary and DB health: `ic health` passes in hub/clavain/

**Phase 2 — Core cutover (deploy atomically or in rapid sequence):**
5. Deploy Tasks 2, 3, 4, 5, 9 (lib-sprint.sh rewrites) — fallback paths still work for unmigrated beads
6. Deploy Task 7 (session-start.sh) — now calls rewritten sprint_find_active

**Phase 3 — Migration (run once, verify before proceeding):**
7. Run `bash hub/clavain/scripts/migrate-sprints-to-ic.sh --dry-run` — verify zero errors
8. Run `bash hub/clavain/scripts/migrate-sprints-to-ic.sh` — run live migration
9. Verify: `ic run list --active | wc -l` matches `bd list --status=in_progress --json | jq '[.[] | select(.state.sprint == "true")] | length'`
10. Restart all active Claude Code sessions (so session-start.sh re-sources lib-sprint.sh and picks up ic-backed sprint_find_active)

**Phase 4 — Cleanup (only after Phase 3 verified clean):**
11. Deploy Task 6 (sentinel cleanup) — removes temp-file fallback permanently
12. Run Task 11 integration test — verify end-to-end lifecycle works

**Rollback procedure (add to plan):**
```bash
# Step 1: Restore pre-migration bead state from snapshot
# (requires snapshot taken before Phase 3, step 7)

# Step 2: Revert Tasks 2-9 code (git revert commits)

# Step 3: For each migrated sprint, clear ic_run_id from bead
for id in $(bd list --status=in_progress --json | jq -r '[.[] | select(.id)] | .[].id'); do
    run_id=$(bd state "$id" ic_run_id 2>/dev/null) || continue
    [[ -z "$run_id" ]] && continue
    bd set-state "$id" "ic_run_id=" 2>/dev/null || true
    echo "Cleared ic_run_id from $id (was $run_id)"
done

# Step 4: Optionally cancel orphaned ic runs
ic run list --active --json | jq -r '.[].id' | while read -r run_id; do
    ic run cancel "$run_id" 2>/dev/null || true
done
```

---

## Summary Table

| # | Finding | Risk | Must Fix Before Deploy |
|---|---------|------|----------------------|
| 1 | No rollback path defined | Critical | Yes |
| 2 | Hard failure mode with missing ic, silent stale reads | High | Yes |
| 3 | Migration script phase advancement not idempotent under failure | High | Yes |
| 4 | Session-spanning-cutover data integrity gap | Medium | Document |
| 5 | No deployment ordering or pre/post checklist | High | Yes |
| 6 | sprint_find_active N+1 reads not eliminated | Medium | No (tech debt) |
| 7 | sprint_advance error handling swallows ic errors | Medium | No (low impact) |
| 8 | sprint_claim staleness check assumes Unix epoch format | Medium | Verify field format |
| 9 | intercore_run_list uses unquoted $@ | Low | Yes (trivial fix) |
| 10 | sprint_find_active title fallback is dead code | Low | No |
| 11 | checkpoint_read uses CWD-based run, not sprint-specific run | Low | Consider |

---

## Go/No-Go Assessment

**Current state: NO-GO**

Three blockers must be resolved before deployment:

1. A snapshot-and-rollback procedure must be written (Finding 1). Without it, any deployment problem that requires reverting code leaves sprint state in an unrecoverable split-brain.

2. The migration script must be made failure-safe (Finding 3): write `ic_run_id` to the bead ONLY after successful phase advancement, count failed advancements as ERRORS, and exit non-zero if ERRORS > 0.

3. A pre/post deploy checklist with measurable pass/fail criteria must be added (Finding 5). This is a procedural requirement, not a code change, but it gates safe execution.

Finding 2 (fresh-clone warning) is strongly recommended but is a degradation-of-experience issue, not a data-loss issue. Finding 8 (epoch format) requires one `ic run agent list --json` call to verify before implementation is correct — this is a verification step, not necessarily a code change.

The overall design of the migration is sound: dual-write during transition, beads as fallback for unmigrated sprints, ic as primary for migrated sprints. The risks are operational (deployment sequencing) and implementation details (migration idempotency), not architectural.
