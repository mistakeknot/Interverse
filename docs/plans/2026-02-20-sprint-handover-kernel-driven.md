# Sprint Handover — Kernel-Driven Sprint Skill

> **For Claude:** REQUIRED SUB-SKILL: Use clavain:executing-plans to implement this plan task-by-task.

**Goal:** Make lib-sprint.sh fully kernel-driven — remove all beads fallback code, cache run ID at claim time, add ic availability guard.

**Architecture:** Sprint functions currently have ic-primary + beads-fallback branches (~50% of 1276 lines). After this: ic is the only path. Bead stays as user-facing identity (CLAVAIN_BEAD_ID), run ID is resolved once and cached. Hard-fail when ic unavailable.

**Tech Stack:** Bash (lib-sprint.sh), Markdown (commands/sprint.md), Bats-core (tests)

**PRD:** [docs/prds/2026-02-20-sprint-handover-kernel-driven.md](../prds/2026-02-20-sprint-handover-kernel-driven.md)
**Bead:** iv-kj6w

---

## Flux-Drive Review Amendments (2026-02-20)

**Review agents:** fd-correctness, fd-architecture, fd-quality, kernel-contract-verifier
**Verdict:** 5 P0 + 5 P1 findings. All addressed below as plan amendments.

### Amendment A: Add Task 0 — Create missing intercore wrapper functions

**Prerequisite for ALL other tasks.** Add 6 missing wrappers to `hub/clavain/hooks/lib-intercore.sh`:
- `intercore_run_create()` — wraps `ic run create --project= --goal= --phases= --scope-id= --complexity= --token-budget= --json`
- `intercore_run_list()` — wraps `ic run list "$@" --json`
- `intercore_run_status()` — wraps `ic run status "$id" --json`
- `intercore_run_advance()` — wraps `ic run advance "$id" --json`
- `intercore_run_agent_list()` — wraps `ic run agent list "$run_id" --json`
- `intercore_run_agent_update()` — wraps `ic run agent update "$agent_id" --status="$status"`

All must pass `--json` where JSON output is needed for jq parsing.

### Amendment B: Use associative array for run ID cache

Replace `_SPRINT_RUN_ID=""` (singleton) in Task 1 with:
```bash
declare -A _SPRINT_RUN_ID_CACHE  # bead_id → run_id

_sprint_resolve_run_id() {
    local bead_id="$1"
    [[ -z "$bead_id" ]] && { echo ""; return 1; }
    if [[ -n "${_SPRINT_RUN_ID_CACHE[$bead_id]:-}" ]]; then
        echo "${_SPRINT_RUN_ID_CACHE[$bead_id]}"
        return 0
    fi
    local run_id
    run_id=$(bd state "$bead_id" ic_run_id 2>/dev/null) || run_id=""
    if [[ -z "$run_id" || "$run_id" == "null" ]]; then
        echo ""
        return 1
    fi
    _SPRINT_RUN_ID_CACHE["$bead_id"]="$run_id"
    echo "$run_id"
}
```

Update all `_SPRINT_RUN_ID="$run_id"` references to `_SPRINT_RUN_ID_CACHE["$sprint_id"]="$run_id"`.

### Amendment C: Make bead creation fatal (when bd available)

In Task 2 `sprint_create`: if `bd` is available but `bd create` fails → abort the sprint (don't create the ic run). Only skip bead if `bd` is not installed at all.

### Amendment D: Reorder ic_run_id write in sprint_create

Move `bd set-state "$sprint_id" "ic_run_id=$run_id"` AFTER the phase verification check, not before.

### Amendment E: Fix JSON field names in sprint_read_state

- Events: `.event_type` (not `.type`), `.to_phase` (not `.to_state`), `.created_at` (not `.timestamp`). Remove `.source` filter. Remove `jq -s` (already an array).
- Tokens: `.input_tokens`/`.output_tokens` or `.total_tokens` (not `.total_in`/`.total_out`).

### Amendment F: Fix sprint_advance error handling

Replace the `result=$(intercore_run_advance ...) || { ... }` pattern with:
```bash
result=$("$INTERCORE_BIN" run advance "$run_id" --json 2>/dev/null) || true
local advanced
advanced=$(echo "$result" | jq -r '.advanced // false' 2>/dev/null) || advanced="false"
```
Also replace `ic run show` with `ic run status`.

### Amendment G: Fix sprint_record_phase_tokens

`dispatch create` and `dispatch update` don't exist. Use `dispatch spawn` + `dispatch tokens` pattern, or use `ic state set` for phase token records. Remove `--set` from `dispatch tokens` call.

### Amendment H: Fix task ordering

Move sprint.md cleanup of `sprint_finalize_init` call to same commit as function deletion (Task 2), not deferred to Task 13.

### Amendment I: Fix jq stubs and test expectations

- Add `sprint_budget_remaining` and `checkpoint_write` to jq stub block
- Include complexity tests in Task 14 scope (tests expect strings but function returns integers)
- Fix cache test to account for subshell variable isolation

---

### Task 1: Add ic guard and run ID cache infrastructure (F1: iv-s80p)

**Files:**
- Modify: `hub/clavain/hooks/lib-sprint.sh:1-23` (top of file, after guards)

**Step 1: Add sprint_require_ic() guard and _sprint_resolve_run_id() cache**

After the `_SPRINT_LOADED=1` guard (line 9) and before the jq check (line 26), add:

```bash
# ─── ic availability guard ──────────────────────────────────────
# Sprint operations require intercore. Non-sprint beads workflows are unaffected.
_SPRINT_RUN_ID=""  # Session-scoped cache: resolved once at claim time

sprint_require_ic() {
    if ! intercore_available; then
        echo "Sprint requires intercore (ic). Install ic or use beads directly for task tracking." >&2
        return 1
    fi
    return 0
}

# Resolve bead_id → ic run_id. Caches result in _SPRINT_RUN_ID.
# Call once at sprint_claim or sprint_create. All subsequent functions use the cache.
# Args: $1=bead_id
# Output: run_id on stdout, or "" on failure
_sprint_resolve_run_id() {
    local bead_id="$1"
    [[ -z "$bead_id" ]] && { echo ""; return 1; }

    # Cache hit
    if [[ -n "$_SPRINT_RUN_ID" ]]; then
        echo "$_SPRINT_RUN_ID"
        return 0
    fi

    # Resolve from bead
    local run_id
    run_id=$(bd state "$bead_id" ic_run_id 2>/dev/null) || run_id=""
    if [[ -z "$run_id" || "$run_id" == "null" ]]; then
        echo ""
        return 1
    fi

    _SPRINT_RUN_ID="$run_id"
    echo "$run_id"
}
```

**Step 2: Verify syntax**

Run: `bash -n hub/clavain/hooks/lib-sprint.sh`
Expected: No output (clean syntax)

**Step 3: Commit**

```bash
git add hub/clavain/hooks/lib-sprint.sh
git commit -m "feat(sprint): add sprint_require_ic guard and run ID cache (A2/F1)"
```

---

### Task 2: Rewrite sprint_create — ic-only, bead non-fatal (F1 + F2: iv-s80p, iv-smqm)

**Files:**
- Modify: `hub/clavain/hooks/lib-sprint.sh:58-143` (sprint_create + sprint_finalize_init)

**Step 1: Replace sprint_create and delete sprint_finalize_init**

Replace lines 58-143 (from `# Create a sprint bead` through end of `sprint_finalize_init`) with:

```bash
# Create a sprint: ic run (required) + bead (optional tracking).
# Returns bead ID to stdout (for CLAVAIN_BEAD_ID).
# REQUIRES: intercore available. Bead creation failure is non-fatal (warning only).
sprint_create() {
    local title="${1:-Sprint}"

    sprint_require_ic || { echo ""; return 1; }

    # Create ic run first (required — this is the state backend)
    local phases_json='["brainstorm","brainstorm-reviewed","strategized","planned","plan-reviewed","executing","shipping","reflect","done"]'
    local complexity="${2:-3}"
    local token_budget
    token_budget=$(_sprint_default_budget "$complexity")

    # Create bead for tracking (optional — failure is non-fatal)
    local sprint_id=""
    if command -v bd &>/dev/null; then
        sprint_id=$(bd create --title="$title" --type=epic --priority=2 2>/dev/null \
            | awk 'match($0, /[A-Za-z]+-[a-z0-9]+/) { print substr($0, RSTART, RLENGTH); exit }') || sprint_id=""
        if [[ -n "$sprint_id" ]]; then
            bd set-state "$sprint_id" "sprint=true" >/dev/null 2>&1 || true
            bd update "$sprint_id" --status=in_progress >/dev/null 2>&1 || true
        else
            echo "sprint_create: bead creation failed (non-fatal), sprint will lack backlog entry" >&2
        fi
    fi

    # Use bead ID as scope_id if available, otherwise generate a placeholder
    local scope_id="${sprint_id:-sprint-$(date +%s)}"

    local run_id
    run_id=$(intercore_run_create "$(pwd)" "$title" "$phases_json" "$scope_id" "$complexity" "$token_budget") || run_id=""

    if [[ -z "$run_id" ]]; then
        echo "sprint_create: ic run create failed" >&2
        # Cancel bead if we created one
        [[ -n "$sprint_id" ]] && bd update "$sprint_id" --status=cancelled >/dev/null 2>&1 || true
        echo ""
        return 1
    fi

    # Store run_id on bead (join key for future sessions)
    if [[ -n "$sprint_id" ]]; then
        bd set-state "$sprint_id" "ic_run_id=$run_id" >/dev/null 2>&1 || {
            echo "sprint_create: failed to write ic_run_id to bead (non-fatal)" >&2
        }
        bd set-state "$sprint_id" "token_budget=$token_budget" >/dev/null 2>&1 || true
    fi

    # Verify ic run is at brainstorm phase
    local verify_phase
    verify_phase=$(intercore_run_phase "$run_id") || verify_phase=""
    if [[ "$verify_phase" != "brainstorm" ]]; then
        echo "sprint_create: ic run verification failed (phase=$verify_phase)" >&2
        "$INTERCORE_BIN" run cancel "$run_id" 2>/dev/null || true
        [[ -n "$sprint_id" ]] && bd update "$sprint_id" --status=cancelled >/dev/null 2>&1 || true
        echo ""
        return 1
    fi

    # Cache the run ID for this session
    _SPRINT_RUN_ID="$run_id"

    echo "$sprint_id"
}

# sprint_finalize_init: DELETED (A2 — beads-only concept, not needed under kernel-driven)
```

**Step 2: Verify syntax**

Run: `bash -n hub/clavain/hooks/lib-sprint.sh`
Expected: No output

**Step 3: Commit**

```bash
git add hub/clavain/hooks/lib-sprint.sh
git commit -m "feat(sprint): rewrite sprint_create for ic-only, delete sprint_finalize_init (A2/F2)"
```

---

### Task 3: Rewrite sprint_find_active — remove beads fallback (F2: iv-smqm)

**Files:**
- Modify: `hub/clavain/hooks/lib-sprint.sh` (sprint_find_active function, lines 145-237)

**Step 1: Replace sprint_find_active**

Replace the entire function (lines 150-237) with the ic-only path. Remove the beads fallback (lines 192-237):

```bash
# Find active sprint runs. Output: JSON array [{id, title, phase, run_id}] or "[]"
# REQUIRES: intercore available.
sprint_find_active() {
    sprint_require_ic || { echo "[]"; return 0; }

    local runs_json
    runs_json=$(intercore_run_list "--active") || { echo "[]"; return 0; }

    local results="[]"
    local count
    count=$(echo "$runs_json" | jq 'length' 2>/dev/null) || count=0

    local i=0
    while [[ $i -lt $count && $i -lt 100 ]]; do
        local run_id scope_id phase goal
        run_id=$(echo "$runs_json" | jq -r ".[$i].id // empty")
        scope_id=$(echo "$runs_json" | jq -r ".[$i].scope_id // empty")
        phase=$(echo "$runs_json" | jq -r ".[$i].phase // empty")
        goal=$(echo "$runs_json" | jq -r ".[$i].goal // empty")

        if [[ -n "$scope_id" ]]; then
            local title="$goal"
            if [[ -z "$title" ]]; then
                title=$(bd show "$scope_id" 2>/dev/null | head -1 | sed 's/^[^·]*· //' | sed 's/ *\[.*$//' 2>/dev/null) || title="Untitled"
            fi
            results=$(echo "$results" | jq \
                --arg id "$scope_id" \
                --arg title "$title" \
                --arg phase "$phase" \
                --arg run_id "$run_id" \
                '. + [{id: $id, title: $title, phase: $phase, run_id: $run_id}]')
        fi
        i=$((i + 1))
    done

    echo "$results"
}
```

**Step 2: Verify syntax**

Run: `bash -n hub/clavain/hooks/lib-sprint.sh`
Expected: No output

**Step 3: Commit**

```bash
git add hub/clavain/hooks/lib-sprint.sh
git commit -m "feat(sprint): sprint_find_active ic-only, remove beads N+1 fallback (A2/F2)"
```

---

### Task 4: Rewrite sprint_read_state, sprint_set_artifact, sprint_record_phase_completion — remove fallback (F2: iv-smqm)

**Files:**
- Modify: `hub/clavain/hooks/lib-sprint.sh` (lines 239-401)

**Step 1: Replace sprint_read_state (remove beads fallback at lines 317-341)**

Replace the entire function body. Keep the ic-primary path (lines 243-314), remove the fallback (lines 317-341). Add `_sprint_resolve_run_id` usage instead of inline `bd state ic_run_id`:

```bash
# Read all sprint state fields at once. Output: JSON object.
# REQUIRES: intercore available + run ID cached.
sprint_read_state() {
    local sprint_id="$1"
    [[ -z "$sprint_id" ]] && { echo "{}"; return 0; }

    local run_id
    run_id=$(_sprint_resolve_run_id "$sprint_id") || { echo "{}"; return 0; }

    local run_json
    run_json=$(intercore_run_status "$run_id") || { echo "{}"; return 0; }

    local phase complexity auto_advance
    phase=$(echo "$run_json" | jq -r '.phase // ""')
    complexity=$(echo "$run_json" | jq -r '.complexity // 3')
    auto_advance=$(echo "$run_json" | jq -r '.auto_advance // true')

    local artifacts="{}"
    local artifact_json
    artifact_json=$("$INTERCORE_BIN" run artifact list "$run_id" --json 2>/dev/null) || artifact_json="[]"
    if [[ "$artifact_json" != "[]" ]]; then
        artifacts=$(echo "$artifact_json" | jq '[.[] | {(.type): .path}] | add // {}')
    fi

    local history="{}"
    local events_json
    events_json=$("$INTERCORE_BIN" run events "$run_id" --json 2>/dev/null) || events_json=""
    if [[ -n "$events_json" ]]; then
        history=$(echo "$events_json" | jq -s '
            [.[] | select(.source == "phase" and .type == "advance") |
             {((.to_state // "") + "_at"): (.timestamp // "")}] | add // {}' 2>/dev/null) || history="{}"
    fi

    local active_session=""
    local agents_json
    agents_json=$("$INTERCORE_BIN" run agent list "$run_id" --json 2>/dev/null) || agents_json="[]"
    if [[ "$agents_json" != "[]" ]]; then
        active_session=$(echo "$agents_json" | jq -r '[.[] | select(.status == "active")] | .[0].name // ""')
    fi

    local token_budget tokens_spent
    token_budget=$(echo "$run_json" | jq -r '.token_budget // 0')
    local token_agg
    token_agg=$("$INTERCORE_BIN" run tokens "$run_id" --json 2>/dev/null) || token_agg=""
    if [[ -n "$token_agg" ]]; then
        tokens_spent=$(echo "$token_agg" | jq -r '(.total_in // 0) + (.total_out // 0)')
    else
        tokens_spent="0"
    fi

    jq -n -c \
        --arg id "$sprint_id" \
        --arg phase "$phase" \
        --argjson artifacts "$artifacts" \
        --argjson history "$history" \
        --arg complexity "$complexity" \
        --arg auto_advance "$auto_advance" \
        --arg active_session "$active_session" \
        --arg token_budget "$token_budget" \
        --arg tokens_spent "$tokens_spent" \
        '{id: $id, phase: $phase, artifacts: $artifacts, history: $history,
          complexity: $complexity, auto_advance: $auto_advance, active_session: $active_session,
          token_budget: ($token_budget | tonumber), tokens_spent: ($tokens_spent | tonumber)}'
}
```

**Step 2: Replace sprint_set_artifact (remove beads fallback at lines 361-369)**

```bash
# Record an artifact for the current phase.
sprint_set_artifact() {
    local sprint_id="$1"
    local artifact_type="$2"
    local artifact_path="$3"
    [[ -z "$sprint_id" || -z "$artifact_type" || -z "$artifact_path" ]] && return 0

    local run_id
    run_id=$(_sprint_resolve_run_id "$sprint_id") || return 0

    local phase
    phase=$(intercore_run_phase "$run_id") || phase="unknown"
    intercore_run_artifact_add "$run_id" "$phase" "$artifact_path" "$artifact_type" >/dev/null 2>&1 || true
}
```

**Step 3: Replace sprint_record_phase_completion (simplify — just invalidate caches)**

```bash
# Record phase completion. With ic, events are auto-recorded.
# Just invalidate discovery caches.
sprint_record_phase_completion() {
    local sprint_id="$1"
    local phase="$2"
    [[ -z "$sprint_id" || -z "$phase" ]] && return 0
    sprint_invalidate_caches
}
```

**Step 4: Verify syntax**

Run: `bash -n hub/clavain/hooks/lib-sprint.sh`
Expected: No output

**Step 5: Commit**

```bash
git add hub/clavain/hooks/lib-sprint.sh
git commit -m "feat(sprint): ic-only sprint_read_state, sprint_set_artifact, sprint_record_phase_completion (A2/F2)"
```

---

### Task 5: Rewrite sprint_record_phase_tokens — remove beads dual-write (F2: iv-smqm)

**Files:**
- Modify: `hub/clavain/hooks/lib-sprint.sh` (lines 422-498, sprint_record_phase_tokens + sprint_budget_remaining)

**Step 1: Replace sprint_record_phase_tokens (remove beads-only path lines 430-439, remove beads dual-write lines 473-478)**

```bash
# Write token usage for a completed phase to intercore dispatch records.
sprint_record_phase_tokens() {
    local sprint_id="$1" phase="$2"
    [[ -z "$sprint_id" || -z "$phase" ]] && return 0

    local run_id
    run_id=$(_sprint_resolve_run_id "$sprint_id") || return 0

    # Try actual data from interstat (session-scoped billing tokens)
    local actual_tokens=""
    if command -v sqlite3 &>/dev/null; then
        local db_path="${HOME}/.claude/interstat/metrics.db"
        if [[ -f "$db_path" ]]; then
            actual_tokens=$(sqlite3 "$db_path" \
                "SELECT COALESCE(SUM(COALESCE(input_tokens,0) + COALESCE(output_tokens,0)), 0) FROM agent_runs WHERE session_id='${CLAUDE_SESSION_ID:-none}'" 2>/dev/null) || actual_tokens=""
        fi
    fi

    local in_tokens out_tokens
    if [[ -n "$actual_tokens" && "$actual_tokens" != "0" ]]; then
        in_tokens=$(( actual_tokens * 60 / 100 ))
        out_tokens=$(( actual_tokens - in_tokens ))
    else
        local estimate
        estimate=$(_sprint_phase_cost_estimate "$phase")
        in_tokens=$(( estimate * 60 / 100 ))
        out_tokens=$(( estimate - in_tokens ))
    fi

    local dispatch_id
    dispatch_id=$("$INTERCORE_BIN" dispatch create "$run_id" --agent="phase-${phase}" --json 2>/dev/null \
        | jq -r '.id // ""' 2>/dev/null) || dispatch_id=""
    if [[ -n "$dispatch_id" ]]; then
        "$INTERCORE_BIN" dispatch tokens "$dispatch_id" --set --in="$in_tokens" --out="$out_tokens" 2>/dev/null || true
        "$INTERCORE_BIN" dispatch update "$dispatch_id" --status=completed 2>/dev/null || true
    fi
}
```

**Step 2: sprint_budget_remaining stays as-is** — it already reads from `sprint_read_state` which is now ic-only. No changes needed.

**Step 3: Verify syntax**

Run: `bash -n hub/clavain/hooks/lib-sprint.sh`
Expected: No output

**Step 4: Commit**

```bash
git add hub/clavain/hooks/lib-sprint.sh
git commit -m "feat(sprint): sprint_record_phase_tokens ic-only, remove beads dual-write (A2/F2)"
```

---

### Task 6: Rewrite sprint_claim + sprint_release — remove beads fallback (F2: iv-smqm)

**Files:**
- Modify: `hub/clavain/hooks/lib-sprint.sh` (lines 500-627)

**Step 1: Replace sprint_claim (remove beads fallback lines 562-600, use cached run ID)**

```bash
# Claim a sprint for this session. Returns 0 if claimed, 1 if conflict.
# REQUIRES: intercore available.
sprint_claim() {
    local sprint_id="$1"
    local session_id="$2"
    [[ -z "$sprint_id" || -z "$session_id" ]] && return 0

    sprint_require_ic || return 1

    local run_id
    run_id=$(_sprint_resolve_run_id "$sprint_id") || {
        echo "sprint_claim: no ic run found for $sprint_id" >&2
        return 1
    }

    intercore_lock "sprint-claim" "$sprint_id" "500ms" || return 1

    local agents_json
    agents_json=$(intercore_run_agent_list "$run_id") || agents_json="[]"
    local active_agents
    active_agents=$(echo "$agents_json" | jq '[.[] | select(.status == "active" and .agent_type == "session")]')
    local active_count
    active_count=$(echo "$active_agents" | jq 'length')

    if [[ "$active_count" -gt 0 ]]; then
        local existing_name
        existing_name=$(echo "$active_agents" | jq -r '.[0].name // "unknown"')
        if [[ "$existing_name" == "$session_id" ]]; then
            intercore_unlock "sprint-claim" "$sprint_id"
            return 0  # Already claimed by us
        fi
        local created_at_str now_epoch created_at age_minutes
        created_at_str=$(echo "$active_agents" | jq -r '.[0].created_at // "1970-01-01T00:00:00Z"')
        created_at=$(date -d "$created_at_str" +%s 2>/dev/null) || created_at=0
        now_epoch=$(date +%s)
        age_minutes=$(( (now_epoch - created_at) / 60 ))
        if [[ $age_minutes -lt 60 ]]; then
            echo "Sprint $sprint_id is active in session ${existing_name:0:8} (${age_minutes}m ago)" >&2
            intercore_unlock "sprint-claim" "$sprint_id"
            return 1
        fi
        local old_agent_id
        old_agent_id=$(echo "$active_agents" | jq -r '.[0].id')
        intercore_run_agent_update "$old_agent_id" "failed" >/dev/null 2>&1 || true
    fi

    if ! intercore_run_agent_add "$run_id" "session" "$session_id" >/dev/null 2>&1; then
        echo "sprint_claim: failed to register session agent for $sprint_id" >&2
        intercore_unlock "sprint-claim" "$sprint_id"
        return 1
    fi
    intercore_unlock "sprint-claim" "$sprint_id"
    return 0
}

# Release sprint claim.
sprint_release() {
    local sprint_id="$1"
    [[ -z "$sprint_id" ]] && return 0

    local run_id
    run_id=$(_sprint_resolve_run_id "$sprint_id") || return 0

    local agents_json agent_ids
    agents_json=$(intercore_run_agent_list "$run_id") || agents_json="[]"
    agent_ids=$(echo "$agents_json" | jq -r '.[] | select(.status == "active" and .agent_type == "session") | .id' 2>/dev/null) || agent_ids=""
    while read -r agent_id; do
        [[ -z "$agent_id" ]] && continue
        intercore_run_agent_update "$agent_id" "completed" >/dev/null 2>&1 || true
    done <<< "$agent_ids"
}
```

**Step 2: Verify syntax**

Run: `bash -n hub/clavain/hooks/lib-sprint.sh`
Expected: No output

**Step 3: Commit**

```bash
git add hub/clavain/hooks/lib-sprint.sh
git commit -m "feat(sprint): sprint_claim/release ic-only, remove beads fallback (A2/F2)"
```

---

### Task 7: Rewrite enforce_gate, sprint_should_pause, sprint_track_agent — remove fallback (F2: iv-smqm)

**Files:**
- Modify: `hub/clavain/hooks/lib-sprint.sh` (lines 629-785)

**Step 1: Replace sprint_track_agent (remove empty fallback)**

```bash
sprint_track_agent() {
    local sprint_id="$1"
    local agent_name="$2"
    local agent_type="${3:-claude}"
    local dispatch_id="${4:-}"
    [[ -z "$sprint_id" || -z "$agent_name" ]] && return 0

    local run_id
    run_id=$(_sprint_resolve_run_id "$sprint_id") || return 0
    intercore_run_agent_add "$run_id" "$agent_type" "$agent_name" "$dispatch_id"
}
```

**Step 2: Replace enforce_gate (remove interphase shim fallback)**

```bash
# Gate enforcement. Returns 0 if gate passes, 1 if blocked.
enforce_gate() {
    local bead_id="$1"
    local target_phase="$2"
    local artifact_path="${3:-}"

    local run_id
    run_id=$(_sprint_resolve_run_id "$bead_id") || return 0
    intercore_gate_check "$run_id"
}
```

**Step 3: Replace sprint_should_pause (remove beads fallback)**

```bash
sprint_should_pause() {
    local sprint_id="$1"
    local target_phase="$2"
    [[ -z "$sprint_id" || -z "$target_phase" ]] && return 1

    local run_id
    run_id=$(_sprint_resolve_run_id "$sprint_id") || return 1
    if ! intercore_gate_check "$run_id" 2>/dev/null; then
        echo "gate_blocked|$target_phase|Gate prerequisites not met"
        return 0
    fi
    return 1
}
```

**Step 4: Verify syntax**

Run: `bash -n hub/clavain/hooks/lib-sprint.sh`
Expected: No output

**Step 5: Commit**

```bash
git add hub/clavain/hooks/lib-sprint.sh
git commit -m "feat(sprint): enforce_gate/sprint_should_pause/sprint_track_agent ic-only (A2/F2)"
```

---

### Task 8: Rewrite sprint_advance — remove beads state machine (F2 + F3: iv-smqm, iv-sl2z)

**Files:**
- Modify: `hub/clavain/hooks/lib-sprint.sh` (lines 787-894, sprint_advance)

**Step 1: Replace sprint_advance (remove beads fallback lines 858-893)**

```bash
sprint_advance() {
    local sprint_id="$1"
    local current_phase="$2"
    local artifact_path="${3:-}"
    [[ -z "$sprint_id" || -z "$current_phase" ]] && return 1

    local run_id
    run_id=$(_sprint_resolve_run_id "$sprint_id") || return 1

    # Budget check
    if [[ -z "${CLAVAIN_SKIP_BUDGET:-}" ]]; then
        "$INTERCORE_BIN" run budget "$run_id" 2>/dev/null
        local budget_rc=$?
        if [[ $budget_rc -eq 1 ]]; then
            local token_json spent budget_val
            token_json=$("$INTERCORE_BIN" run tokens "$run_id" --json 2>/dev/null) || token_json="{}"
            spent=$(echo "$token_json" | jq -r '(.total_in // 0) + (.total_out // 0)' 2>/dev/null) || spent="?"
            budget_val=$("$INTERCORE_BIN" run show "$run_id" --json 2>/dev/null | jq -r '.token_budget // "?"' 2>/dev/null) || budget_val="?"
            echo "budget_exceeded|$current_phase|${spent}/${budget_val} billing tokens"
            return 1
        fi
    fi

    local result
    result=$(intercore_run_advance "$run_id") || {
        local rc=$?
        local event_type from_phase to_phase
        event_type=$(echo "$result" | jq -r '.event_type // ""' 2>/dev/null) || event_type=""
        from_phase=$(echo "$result" | jq -r '.from_phase // ""' 2>/dev/null) || from_phase=""
        to_phase=$(echo "$result" | jq -r '.to_phase // ""' 2>/dev/null) || to_phase=""

        case "$event_type" in
            block)
                echo "gate_blocked|$to_phase|Gate prerequisites not met"
                ;;
            pause)
                echo "manual_pause|$to_phase|auto_advance=false"
                ;;
            *)
                if [[ -z "$event_type" && -z "$from_phase" ]]; then
                    echo "sprint_advance: ic run advance returned unexpected result: ${result:-<empty>}" >&2
                fi
                local actual_phase
                actual_phase=$(intercore_run_phase "$run_id") || actual_phase=""
                if [[ -n "$actual_phase" && "$actual_phase" != "$current_phase" ]]; then
                    echo "stale_phase|$current_phase|Phase already advanced to $actual_phase"
                fi
                ;;
        esac
        return 1
    }

    local from_phase to_phase
    from_phase=$(echo "$result" | jq -r '.from_phase // ""' 2>/dev/null) || from_phase="$current_phase"
    to_phase=$(echo "$result" | jq -r '.to_phase // ""' 2>/dev/null) || to_phase=""

    sprint_invalidate_caches
    sprint_record_phase_tokens "$sprint_id" "$current_phase" 2>/dev/null || true
    echo "Phase: $from_phase → $to_phase (auto-advancing)" >&2
    return 0
}
```

**Step 2: Verify syntax**

Run: `bash -n hub/clavain/hooks/lib-sprint.sh`
Expected: No output

**Step 3: Commit**

```bash
git add hub/clavain/hooks/lib-sprint.sh
git commit -m "feat(sprint): sprint_advance ic-only, remove beads state machine (A2/F2)"
```

---

### Task 9: Delete transition table + rewrite sprint_next_step to read chain from ic (F3: iv-sl2z)

**Files:**
- Modify: `hub/clavain/hooks/lib-sprint.sh` (lines 696-745 for transition table + sprint_next_step, lines 1059-1121 for phase skipping)

**Step 1: Delete _sprint_transition_table, sprint_phase_whitelist, sprint_should_skip, sprint_next_required_phase**

Delete lines 696-720 (`_sprint_transition_table`), lines 1059-1121 (phase skipping functions — all depend on the transition table). These are beads-only fallback concepts.

**Step 2: Rewrite sprint_next_step to use a static phase→command map (no transition table)**

The phase chain lives in ic (passed at creation). `sprint_next_step` just needs to map the *current* phase to the command that handles the *next* action:

```bash
# Determine the next command for a sprint based on its current phase.
# Output: command name (e.g., "brainstorm", "write-plan", "work")
# Maps current phase → command that produces the next phase.
sprint_next_step() {
    local phase="$1"
    case "$phase" in
        brainstorm)          echo "strategy" ;;
        brainstorm-reviewed) echo "strategy" ;;
        strategized)         echo "write-plan" ;;
        planned)             echo "flux-drive" ;;
        plan-reviewed)       echo "work" ;;
        executing)           echo "ship" ;;
        shipping)            echo "reflect" ;;
        reflect)             echo "done" ;;
        done)                echo "done" ;;
        *)                   echo "brainstorm" ;;
    esac
}
```

**Step 3: Verify syntax**

Run: `bash -n hub/clavain/hooks/lib-sprint.sh`
Expected: No output

**Step 4: Commit**

```bash
git add hub/clavain/hooks/lib-sprint.sh
git commit -m "feat(sprint): delete transition table + phase skipping, simplify sprint_next_step (A2/F3)"
```

---

### Task 10: Rewrite checkpointing — remove file-based fallback (F2: iv-smqm)

**Files:**
- Modify: `hub/clavain/hooks/lib-sprint.sh` (lines 1123-1264)

**Step 1: Replace checkpoint_write (remove file-based fallback lines 1168-1187)**

```bash
# Write or update a checkpoint after a sprint step completes.
checkpoint_write() {
    local bead="${1:?bead_id required}"
    local phase="${2:?phase required}"
    local step="${3:?step_name required}"
    local plan_path="${4:-}"
    local key_decision="${5:-}"

    local git_sha
    git_sha=$(git rev-parse HEAD 2>/dev/null) || git_sha="unknown"
    local timestamp
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    local run_id
    run_id=$(_sprint_resolve_run_id "$bead") || return 0

    local existing
    existing=$(intercore_state_get "checkpoint" "$run_id") || existing="{}"
    [[ -z "$existing" ]] && existing="{}"

    local checkpoint_json
    checkpoint_json=$(echo "$existing" | jq \
        --arg bead "$bead" --arg phase "$phase" --arg step "$step" \
        --arg plan_path "$plan_path" --arg git_sha "$git_sha" \
        --arg timestamp "$timestamp" --arg key_decision "$key_decision" \
        '
        .bead = $bead | .phase = $phase |
        .plan_path = (if $plan_path != "" then $plan_path else (.plan_path // "") end) |
        .git_sha = $git_sha | .updated_at = $timestamp |
        .completed_steps = ((.completed_steps // []) + [$step] | unique) |
        .key_decisions = (if $key_decision != "" then ((.key_decisions // []) + [$key_decision] | unique | .[-5:]) else (.key_decisions // []) end)
        ')

    intercore_state_set "checkpoint" "$run_id" "$checkpoint_json" 2>/dev/null || true
}
```

**Step 2: Replace checkpoint_read (remove file-based fallback)**

```bash
# Read the current checkpoint. Output: JSON or "{}"
checkpoint_read() {
    local bead_id="${1:-}"

    if ! intercore_available; then
        echo "{}"
        return 0
    fi

    local run_id=""
    if [[ -n "$bead_id" ]]; then
        run_id=$(_sprint_resolve_run_id "$bead_id") || run_id=""
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
    echo "{}"
}
```

**Step 3: Remove CHECKPOINT_FILE constant and checkpoint_clear's file operations**

Replace `checkpoint_clear`:
```bash
# Clear checkpoint (at sprint start or after shipping).
checkpoint_clear() {
    # File-based checkpoint no longer used, but clean up legacy files if present
    rm -f "${CLAVAIN_CHECKPOINT_FILE:-.clavain/checkpoint.json}" 2>/dev/null || true
}
```

Remove the line: `CHECKPOINT_FILE="${CLAVAIN_CHECKPOINT_FILE:-.clavain/checkpoint.json}"`

**Step 4: Verify syntax**

Run: `bash -n hub/clavain/hooks/lib-sprint.sh`
Expected: No output

**Step 5: Commit**

```bash
git add hub/clavain/hooks/lib-sprint.sh
git commit -m "feat(sprint): checkpointing ic-only, remove file-based fallback (A2/F2)"
```

---

### Task 11: Rewrite sprint_classify_complexity — use cached run ID (F2: iv-smqm)

**Files:**
- Modify: `hub/clavain/hooks/lib-sprint.sh` (lines 909-929, complexity override section)

**Step 1: Replace the override lookup**

In `sprint_classify_complexity`, replace the current override block (lines 914-929) with:

```bash
    if [[ -n "$sprint_id" ]]; then
        local override=""
        local run_id
        run_id=$(_sprint_resolve_run_id "$sprint_id") || run_id=""
        if [[ -n "$run_id" ]]; then
            override=$(intercore_run_status "$run_id" | jq -r '.complexity // empty' 2>/dev/null) || override=""
        fi
        if [[ -z "$override" || "$override" == "null" ]]; then
            override=$(bd state "$sprint_id" complexity 2>/dev/null) || override=""
        fi
        if [[ -n "$override" && "$override" != "null" ]]; then
            echo "$override"
            return 0
        fi
    fi
```

This is nearly identical but uses `_sprint_resolve_run_id` instead of inline `bd state ic_run_id`. The `bd state complexity` fallback stays because complexity can be set on the bead before a run exists.

**Step 2: Verify syntax**

Run: `bash -n hub/clavain/hooks/lib-sprint.sh`
Expected: No output

**Step 3: Commit**

```bash
git add hub/clavain/hooks/lib-sprint.sh
git commit -m "feat(sprint): sprint_classify_complexity uses cached run ID (A2/F2)"
```

---

### Task 12: Update jq stub section to match new function signatures (F2: iv-smqm)

**Files:**
- Modify: `hub/clavain/hooks/lib-sprint.sh:24-41` (jq check stubs)

**Step 1: Remove sprint_finalize_init stub, add sprint_require_ic stub**

Replace lines 26-41 with:

```bash
if ! command -v jq &>/dev/null; then
    sprint_require_ic() { return 1; }
    sprint_create() { echo ""; return 1; }
    sprint_find_active() { echo "[]"; }
    sprint_read_state() { echo "{}"; }
    sprint_set_artifact() { return 0; }
    sprint_record_phase_completion() { return 0; }
    sprint_claim() { return 0; }
    sprint_release() { return 0; }
    sprint_next_step() { echo "brainstorm"; }
    sprint_invalidate_caches() { return 0; }
    sprint_should_pause() { return 1; }
    sprint_advance() { return 1; }
    sprint_classify_complexity() { echo "3"; }
    return 0
fi
```

Note: `sprint_classify_complexity` returns `"3"` (integer) instead of `"medium"` (string) — aligns with the function's actual output.

**Step 2: Verify syntax**

Run: `bash -n hub/clavain/hooks/lib-sprint.sh`
Expected: No output

**Step 3: Commit**

```bash
git add hub/clavain/hooks/lib-sprint.sh
git commit -m "feat(sprint): update jq stubs for A2 function signatures"
```

---

### Task 13: Update commands/sprint.md — remove lib-gates.sh and dead calls (F4: iv-o1qz)

**Files:**
- Modify: `hub/clavain/commands/sprint.md`

**Step 1: Remove all lib-gates.sh sourcing and advance_phase calls**

Search for and remove/replace these patterns in sprint.md:

1. Lines 192-193 (`export GATES_PROJECT_DIR="."; source "${CLAUDE_PLUGIN_ROOT}/hooks/lib-gates.sh" && advance_phase ...`) — delete these lines. Phase tracking already happens via `sprint_advance()`.

2. Lines 347-348 (`export GATES_PROJECT_DIR="."; source "${CLAUDE_PLUGIN_ROOT}/hooks/lib-gates.sh"` and `advance_phase "$CLAVAIN_BEAD_ID" "shipping" ...`) — delete these lines. Phase tracking via `sprint_advance()`.

3. Line 349 (`sprint_record_phase_completion "$CLAVAIN_BEAD_ID" "shipping"`) — keep (it invalidates caches, which is useful).

4. Lines 240-241 (`sprint_finalize_init "$SPRINT_ID"` and `sprint_record_phase_completion "$SPRINT_ID" "brainstorm"`) — delete `sprint_finalize_init` line. Keep `sprint_record_phase_completion`.

**Step 2: Verify the sprint skill only sources lib-sprint.sh**

Run: `grep -c 'lib-gates' hub/clavain/commands/sprint.md`
Expected: `0`

Run: `grep -c 'advance_phase' hub/clavain/commands/sprint.md`
Expected: `0`

Run: `grep -c 'sprint_finalize_init' hub/clavain/commands/sprint.md`
Expected: `0`

**Step 3: Commit**

```bash
git add hub/clavain/commands/sprint.md
git commit -m "feat(sprint): sprint skill no longer sources lib-gates.sh (A2/F4)"
```

---

### Task 14: Update bats-core tests for ic-only sprint path (F5: iv-pfe5)

**Files:**
- Modify: `hub/clavain/tests/shell/test_lib_sprint.bats`

**Step 1: Delete tests for removed functions**

Delete these tests:
- Test 3 (`sprint_finalize_init sets sprint_initialized=true`, lines 100-115) — function deleted
- Test 24 (`_sprint_transition_table maps all phases correctly`, lines 689-716) — function deleted
- Test 25 (`_sprint_transition_table returns empty for unknown phase`, lines 718-727) — function deleted
- Test 26 (`_sprint_transition_table done→done`, lines 729-738) — function deleted

**Step 2: Update tests that use beads fallback paths**

Tests 4, 5, 6, 7, 8, 9, 10, 11, 13, 14, 15, 16, 17 all mock `bd()` for the beads fallback. These need to be rewritten to mock `intercore_available`, `intercore_run_list`, etc. instead.

For each test, add this preamble after `_source_sprint_lib`:
```bash
    # Mock intercore as available
    intercore_available() { return 0; }
    export -f intercore_available
```

And mock the specific `intercore_*` function the test exercises.

Example rewrite for Test 4 (`sprint_find_active returns only initialized sprint beads`):
```bash
@test "sprint_find_active returns active runs with scope_id" {
    intercore_available() { return 0; }
    intercore_run_list() {
        echo '[{"id":"run-1","scope_id":"iv-s1","phase":"brainstorm","goal":"Sprint 1"},{"id":"run-2","scope_id":"","phase":"executing","goal":"No scope"}]'
    }
    export -f intercore_available intercore_run_list
    bd() { return 1; }  # bd not needed
    export -f bd

    _source_sprint_lib
    run sprint_find_active
    assert_success
    echo "$output" | jq -e 'length == 1'
    echo "$output" | jq -e '.[0].id == "iv-s1"'
}
```

**Step 3: Add tests for sprint_require_ic**

```bash
@test "sprint_require_ic succeeds when ic available" {
    intercore_available() { return 0; }
    export -f intercore_available
    bd() { return 0; }
    export -f bd
    _source_sprint_lib
    run sprint_require_ic
    assert_success
}

@test "sprint_require_ic fails when ic unavailable" {
    intercore_available() { return 1; }
    export -f intercore_available
    bd() { return 0; }
    export -f bd
    _source_sprint_lib
    run sprint_require_ic
    assert_failure
}
```

**Step 4: Add test for _sprint_resolve_run_id caching**

```bash
@test "_sprint_resolve_run_id caches after first call" {
    local call_count=0
    bd() {
        case "$1" in
            state)
                call_count=$((call_count + 1))
                echo "run-cached-123"
                ;;
        esac
    }
    export -f bd
    _source_sprint_lib

    local first second
    first=$(_sprint_resolve_run_id "iv-test1")
    second=$(_sprint_resolve_run_id "iv-test1")
    [[ "$first" == "run-cached-123" ]]
    [[ "$second" == "run-cached-123" ]]
    # bd should only be called once (cached on second call)
    # Note: can't easily verify call count with export -f, but the cache variable check works:
    [[ -n "$_SPRINT_RUN_ID" ]]
}
```

**Step 5: Run full test suite**

Run: `cd hub/clavain && bats tests/shell/test_lib_sprint.bats`
Expected: All tests pass

**Step 6: Verify syntax check**

Run: `bash -n hub/clavain/hooks/lib-sprint.sh`
Expected: No output

**Step 7: Commit**

```bash
git add hub/clavain/tests/shell/test_lib_sprint.bats
git commit -m "test(sprint): update bats tests for ic-only sprint path (A2/F5)"
```

---

### Task 15: Final verification and line count audit

**Step 1: Verify no bd set-state calls remain for sprint state**

Run: `grep -n 'bd set-state' hub/clavain/hooks/lib-sprint.sh`
Expected: Only calls for `sprint=true`, `ic_run_id=`, and `token_budget=` in `sprint_create` (bead metadata, not sprint state). Zero calls for `phase=`, `sprint_artifacts=`, `active_session=`, `claim_timestamp=`, `tokens_spent=`, `sprint_initialized=`, `phase_history=`.

**Step 2: Verify no lib-gates.sh in sprint skill**

Run: `grep -c 'lib-gates' hub/clavain/commands/sprint.md`
Expected: `0`

**Step 3: Line count audit**

Run: `wc -l hub/clavain/hooks/lib-sprint.sh`
Expected: ~650-750 lines (down from 1276)

**Step 4: Full syntax check**

Run: `bash -n hub/clavain/hooks/lib-sprint.sh && bash -n hub/clavain/hooks/lib-gates.sh && bash -n hub/clavain/hooks/session-start.sh`
Expected: No output from any

**Step 5: Run full test suite**

Run: `cd hub/clavain && bats tests/shell/test_lib_sprint.bats`
Expected: All tests pass

**Step 6: Final commit**

```bash
git add -A hub/clavain/hooks/lib-sprint.sh hub/clavain/commands/sprint.md hub/clavain/tests/
git commit -m "feat(sprint): A2 sprint handover complete — kernel-driven, ~600 lines removed

Sprint skill now fully kernel-driven (ic-only):
- sprint_require_ic() guard at entry points
- Run ID cached at claim time (_sprint_resolve_run_id)
- All beads fallback branches removed (~600 lines)
- _sprint_transition_table deleted (phases from ic)
- sprint_finalize_init deleted (beads-only concept)
- Sprint skill no longer sources lib-gates.sh
- Tests updated for ic-only path

Bead stays as user-facing identity. Non-sprint beads
workflows unaffected.

Closes iv-kj6w, iv-s80p, iv-smqm, iv-sl2z, iv-o1qz, iv-pfe5"
```
