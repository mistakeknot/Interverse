# Intercore E3: Hook Cutover — Big-Bang Clavain Migration to ic

> **For Claude:** REQUIRED SUB-SKILL: Use clavain:executing-plans to implement this plan task-by-task.

**Goal:** Migrate all Clavain sprint runtime state from beads (`bd set-state`) and temp files to intercore's `ic` CLI, establishing `ic run` as the single source of truth for sprint lifecycle.

**Architecture:** Each sprint creates a bead (issue tracking: title, priority, deps) AND an `ic run` (runtime state: phase, artifacts, agents, claims). Linked via `--scope-id=<bead_id>` on `ic run create`. Custom 8-phase chain: `brainstorm → brainstorm-reviewed → strategized → planned → plan-reviewed → executing → shipping → done`. Sprint phases advance explicitly via `ic run advance`; agent dispatch lifecycle is reactive via SpawnHandler.

**Tech Stack:** Bash (lib-sprint.sh, lib-intercore.sh, session-start.sh), Go (`ic` CLI — read-only, no modifications needed), jq, SQLite (intercore DB)

**PRD:** docs/prds/2026-02-19-intercore-e3-hook-cutover.md
**Bead:** iv-ngvy (epic) / iv-2kv8 (sprint)
**Phase:** plan-reviewed (as of 2026-02-20T02:10:00Z)

---

## Task 1: Extend lib-intercore.sh with ic run wrappers

**Bead:** iv-s6zo (F1)
**Phase:** plan-reviewed (as of 2026-02-20T02:10:00Z)
**Files:**
- Modify: `hub/clavain/hooks/lib-intercore.sh`
- Test: manual via `bash -n` syntax check + integration

This task adds the missing wrappers that lib-sprint.sh will call in Task 2. Some wrappers already exist (`intercore_run_current`, `intercore_run_phase`, etc.); we need a few more for the full cutover.

**Step 1: Add intercore_run_create wrapper**

Add after the existing `intercore_run_phase` function (around line 248):

```bash
# intercore_run_create — Create a new run.
# Args: $1=project_dir, $2=goal, $3=phases_json (optional), $4=scope_id (optional), $5=complexity (optional)
# Prints: run ID to stdout
# Returns: 0 on success, 1 on failure
intercore_run_create() {
    local project="$1" goal="$2" phases="${3:-}" scope_id="${4:-}" complexity="${5:-3}"
    if ! intercore_available; then return 1; fi
    local args=(run create --project="$project" --goal="$goal" --complexity="$complexity")
    if [[ -n "$phases" ]]; then
        args+=(--phases="$phases")
    fi
    if [[ -n "$scope_id" ]]; then
        args+=(--scope-id="$scope_id")
    fi
    "$INTERCORE_BIN" "${args[@]}" 2>/dev/null
}
```

**Step 2: Add intercore_run_advance wrapper**

```bash
# intercore_run_advance — Advance run to next phase.
# Args: $1=run_id, $2=priority (optional, default 4=no gates), $3=skip_reason (optional)
# Prints: JSON result to stdout (with --json)
# Returns: 0=advanced, 1=blocked/not-found, 2+=error
intercore_run_advance() {
    local run_id="$1" priority="${2:-4}" skip_reason="${3:-}"
    if ! intercore_available; then return 1; fi
    local args=(run advance "$run_id" --priority="$priority" --json)
    if [[ -n "$skip_reason" ]]; then
        args+=(--skip-reason="$skip_reason")
    fi
    "$INTERCORE_BIN" "${args[@]}" 2>/dev/null
}
```

**Step 3: Add intercore_run_status wrapper**

```bash
# intercore_run_status — Get full run details as JSON.
# Args: $1=run_id
# Prints: JSON run object to stdout
# Returns: 0 on success, 1 on not found
intercore_run_status() {
    local run_id="$1"
    if ! intercore_available; then return 1; fi
    "$INTERCORE_BIN" run status "$run_id" --json 2>/dev/null
}
```

**Step 4: Add intercore_run_list wrapper**

```bash
# intercore_run_list — List runs with optional filtering.
# Args: flags (e.g., "--active", "--active" "--scope=<id>")
# Prints: JSON array of run objects to stdout
# Returns: 0 always
intercore_run_list() {
    if ! intercore_available; then echo "[]"; return 0; fi
    "$INTERCORE_BIN" run list --json "$@" 2>/dev/null || echo "[]"
}
```

**Step 4b: Add intercore_run_agent_list and intercore_run_agent_update wrappers**

These are needed by sprint_claim (Task 3) to stay within the lib-intercore.sh boundary:

```bash
# intercore_run_agent_list — List agents for a run.
# Args: $1=run_id
# Prints: JSON array to stdout
intercore_run_agent_list() {
    local run_id="$1"
    if ! intercore_available; then echo "[]"; return 0; fi
    "$INTERCORE_BIN" run agent list "$run_id" --json 2>/dev/null || echo "[]"
}

# intercore_run_agent_update — Update an agent's status.
# Args: $1=agent_id, $2=status
intercore_run_agent_update() {
    local agent_id="$1" status="$2"
    if ! intercore_available; then return 1; fi
    "$INTERCORE_BIN" run agent update "$agent_id" --status="$status" 2>/dev/null
}
```

**Step 5: Add intercore_run_set wrapper**

```bash
# intercore_run_set — Update run settings.
# Args: $1=run_id, rest=flags (e.g., --complexity=4, --force-full=true)
# Returns: 0 on success, 1 on failure
intercore_run_set() {
    local run_id="$1"; shift
    if ! intercore_available; then return 1; fi
    "$INTERCORE_BIN" run set "$run_id" "$@" 2>/dev/null
}
```

**Step 6: Syntax check**

Run: `bash -n hub/clavain/hooks/lib-intercore.sh`
Expected: No output (clean parse)

**Step 7: Commit**

```bash
git add hub/clavain/hooks/lib-intercore.sh
git commit -m "feat(intercore): add ic run wrappers to lib-intercore.sh for E3 cutover"
```

---

## Task 2: Rewrite lib-sprint.sh — Core CRUD (sprint_create, sprint_finalize_init, sprint_find_active, sprint_read_state)

**Bead:** iv-s6zo (F1)
**Phase:** plan-reviewed (as of 2026-02-20T02:10:00Z)
**Files:**
- Modify: `hub/clavain/hooks/lib-sprint.sh`

The biggest change. We rewrite the 4 core CRUD functions to use `ic run` instead of `bd set-state`. Key design: `--scope-id=<bead_id>` links the ic run to the bead. Sprint discovery uses `ic run list --active --scope=<bead_id>` instead of iterating all beads.

**Step 1: Rewrite sprint_create**

Replace the existing `sprint_create` function (lines 50-95) with:

```bash
# Create a sprint bead + ic run. Returns bead ID to stdout.
# The ic run is linked to the bead via --scope-id.
# Caller MUST call sprint_finalize_init() after all setup.
sprint_create() {
    local title="${1:-Sprint}"

    if ! command -v bd &>/dev/null; then
        echo ""
        return 0
    fi

    # Create tracking bead (issue tracking stays in beads)
    local sprint_id
    sprint_id=$(bd create --title="$title" --type=epic --priority=2 2>/dev/null \
        | awk 'match($0, /[A-Za-z]+-[a-z0-9]+/) { print substr($0, RSTART, RLENGTH); exit }') || {
        echo ""
        return 0
    }

    if [[ -z "$sprint_id" ]]; then
        echo ""
        return 0
    fi

    bd set-state "$sprint_id" "sprint=true" 2>/dev/null || {
        bd update "$sprint_id" --status=cancelled 2>/dev/null || true
        echo ""; return 0
    }
    bd update "$sprint_id" --status=in_progress 2>/dev/null || true

    # Create ic run linked to bead via scope-id
    local phases_json='["brainstorm","brainstorm-reviewed","strategized","planned","plan-reviewed","executing","shipping","done"]'
    local run_id
    run_id=$(intercore_run_create "$(pwd)" "$title" "$phases_json" "$sprint_id") || run_id=""

    if [[ -z "$run_id" ]]; then
        echo "sprint_create: ic run create failed, cancelling bead $sprint_id" >&2
        bd update "$sprint_id" --status=cancelled 2>/dev/null || true
        echo ""
        return 0
    fi

    # Store run_id on bead — CRITICAL: this is the join key that makes ic path work.
    # If this write fails, the ic run is unreachable through sprint API.
    bd set-state "$sprint_id" "ic_run_id=$run_id" 2>/dev/null || {
        echo "sprint_create: failed to write ic_run_id to bead, cancelling" >&2
        "$INTERCORE_BIN" run cancel "$run_id" 2>/dev/null || true
        bd update "$sprint_id" --status=cancelled 2>/dev/null || true
        echo ""
        return 0
    }

    # Verify ic run was created and is at brainstorm phase
    local verify_phase
    verify_phase=$(intercore_run_phase "$run_id") || verify_phase=""
    if [[ "$verify_phase" != "brainstorm" ]]; then
        echo "sprint_create: ic run verification failed, cancelling bead $sprint_id" >&2
        bd update "$sprint_id" --status=cancelled 2>/dev/null || true
        echo ""
        return 0
    fi

    echo "$sprint_id"
}
```

**Step 2: Rewrite sprint_finalize_init**

Replace existing (lines 98-102):

```bash
# Mark sprint as fully initialized. Discovery skips uninitialized sprints.
# Sets sprint_initialized on bead (beads discovery compat) and stores
# the bead-run link in ic state for fast lookup.
sprint_finalize_init() {
    local sprint_id="$1"
    [[ -z "$sprint_id" ]] && return 0
    bd set-state "$sprint_id" "sprint_initialized=true" 2>/dev/null || true
    # NOTE: bead→run link is already stored via ic_run_id on bead + scope_id on run.
    # No redundant sprint_link ic state write needed (YAGNI — removed per arch review).
}
```

**Step 3: Rewrite sprint_find_active**

Replace existing (lines 108-173). The new version uses `ic run list --active` instead of iterating beads:

```bash
# Find active sprint runs. Output: JSON array [{id, title, phase, run_id}] or "[]"
# Primary path: ic run list --active (single DB query, no N+1)
# Fallback: beads-based scan (for environments without ic)
sprint_find_active() {
    # Try ic-based discovery first (fast path)
    if intercore_available; then
        local runs_json
        runs_json=$(intercore_run_list "--active") || runs_json="[]"

        # Filter to runs with a scope_id (scope_id = bead_id for sprints)
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

            # Only include runs with a scope_id (bead-linked sprints).
            # A run with scope_id was created by sprint_create → by construction it's a sprint.
            # No per-run bd state checks needed (eliminates N+1 reads — per arch review).
            if [[ -n "$scope_id" ]]; then
                # Use goal from ic run for title (avoids bd show call).
                # Fall back to bd show only if goal is empty.
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
        return 0
    fi

    # Fallback: beads-based scan (no ic available)
    if ! command -v bd &>/dev/null; then
        echo "[]"
        return 0
    fi

    if [[ ! -d "${SPRINT_LIB_PROJECT_DIR}/.beads" ]]; then
        echo "[]"
        return 0
    fi

    local ip_list
    ip_list=$(bd list --status=in_progress --json 2>/dev/null) || {
        echo "[]"
        return 0
    }
    echo "$ip_list" | jq 'if type != "array" then error("expected array") else . end' >/dev/null 2>&1 || {
        echo "[]"
        return 0
    }

    local count results="[]" i=0
    count=$(echo "$ip_list" | jq 'length' 2>/dev/null) || count=0
    while [[ $i -lt $count && $i -lt 100 ]]; do
        local bead_id
        bead_id=$(echo "$ip_list" | jq -r ".[$i].id // empty")
        [[ -z "$bead_id" ]] && { i=$((i + 1)); continue; }
        local is_sprint
        is_sprint=$(bd state "$bead_id" sprint 2>/dev/null) || is_sprint=""
        if [[ "$is_sprint" == "true" ]]; then
            local initialized
            initialized=$(bd state "$bead_id" sprint_initialized 2>/dev/null) || initialized=""
            if [[ "$initialized" == "true" ]]; then
                local title phase
                title=$(echo "$ip_list" | jq -r ".[$i].title // \"Untitled\"")
                phase=$(bd state "$bead_id" phase 2>/dev/null) || phase=""
                results=$(echo "$results" | jq \
                    --arg id "$bead_id" --arg title "$title" --arg phase "$phase" \
                    '. + [{id: $id, title: $title, phase: $phase}]')
            fi
        fi
        i=$((i + 1))
    done
    echo "$results"
}
```

**Step 4: Rewrite sprint_read_state**

Replace existing (lines 178-204). Reads from ic run status instead of 6x `bd state`:

```bash
# Read all sprint state fields at once. Output: JSON object.
# Primary: ic run status (single call). Fallback: beads.
sprint_read_state() {
    local sprint_id="$1"
    [[ -z "$sprint_id" ]] && { echo "{}"; return 0; }

    # Resolve run_id from bead
    local run_id
    run_id=$(bd state "$sprint_id" ic_run_id 2>/dev/null) || run_id=""

    if [[ -n "$run_id" ]] && intercore_available; then
        local run_json
        run_json=$(intercore_run_status "$run_id") || run_json=""

        if [[ -n "$run_json" ]]; then
            # Map ic run fields to sprint state format
            local phase complexity auto_advance
            phase=$(echo "$run_json" | jq -r '.phase // ""')
            complexity=$(echo "$run_json" | jq -r '.complexity // 3')
            auto_advance=$(echo "$run_json" | jq -r '.auto_advance // true')

            # Artifacts from ic run artifact list
            local artifacts="{}"
            local artifact_json
            artifact_json=$("$INTERCORE_BIN" run artifact list "$run_id" --json 2>/dev/null) || artifact_json="[]"
            if [[ "$artifact_json" != "[]" ]]; then
                artifacts=$(echo "$artifact_json" | jq '[.[] | {(.type): .path}] | add // {}')
            fi

            # Phase history from ic run events (bounded, phase-events only)
            local history="{}"
            local events_json
            events_json=$("$INTERCORE_BIN" run events "$run_id" --json 2>/dev/null) || events_json=""
            if [[ -n "$events_json" ]]; then
                # NOTE: timestamp may be ISO-8601 string — use directly, not todate
                history=$(echo "$events_json" | jq -s '
                    [.[] | select(.source == "phase" and .type == "advance") |
                     {((.to_state // "") + "_at"): (.timestamp // "")}] | add // {}' 2>/dev/null) || history="{}"
            fi

            # Active session (agent tracking)
            local active_session=""
            local agents_json
            agents_json=$("$INTERCORE_BIN" run agent list "$run_id" --json 2>/dev/null) || agents_json="[]"
            if [[ "$agents_json" != "[]" ]]; then
                active_session=$(echo "$agents_json" | jq -r '[.[] | select(.status == "active")] | .[0].name // ""')
            fi

            jq -n -c \
                --arg id "$sprint_id" \
                --arg phase "$phase" \
                --argjson artifacts "$artifacts" \
                --argjson history "$history" \
                --arg complexity "$complexity" \
                --arg auto_advance "$auto_advance" \
                --arg active_session "$active_session" \
                '{id: $id, phase: $phase, artifacts: $artifacts, history: $history,
                  complexity: $complexity, auto_advance: $auto_advance, active_session: $active_session}'
            return 0
        fi
    fi

    # Fallback: beads-based read
    local phase sprint_artifacts phase_history complexity auto_advance active_session
    phase=$(bd state "$sprint_id" phase 2>/dev/null) || phase=""
    sprint_artifacts=$(bd state "$sprint_id" sprint_artifacts 2>/dev/null) || sprint_artifacts="{}"
    phase_history=$(bd state "$sprint_id" phase_history 2>/dev/null) || phase_history="{}"
    complexity=$(bd state "$sprint_id" complexity 2>/dev/null) || complexity=""
    auto_advance=$(bd state "$sprint_id" auto_advance 2>/dev/null) || auto_advance="true"
    active_session=$(bd state "$sprint_id" active_session 2>/dev/null) || active_session=""
    echo "$sprint_artifacts" | jq empty 2>/dev/null || sprint_artifacts="{}"
    echo "$phase_history" | jq empty 2>/dev/null || phase_history="{}"
    jq -n -c \
        --arg id "$sprint_id" --arg phase "$phase" \
        --argjson artifacts "$sprint_artifacts" --argjson history "$phase_history" \
        --arg complexity "$complexity" --arg auto_advance "$auto_advance" \
        --arg active_session "$active_session" \
        '{id: $id, phase: $phase, artifacts: $artifacts, history: $history,
          complexity: $complexity, auto_advance: $auto_advance, active_session: $active_session}'
}
```

**Step 5: Syntax check**

Run: `bash -n hub/clavain/hooks/lib-sprint.sh`
Expected: No output (clean parse)

**Step 6: Commit**

```bash
git add hub/clavain/hooks/lib-sprint.sh
git commit -m "feat(sprint): rewrite core CRUD to use ic run (create, find, read)"
```

---

## Task 3: Rewrite lib-sprint.sh — State Mutation (sprint_set_artifact, sprint_record_phase_completion, sprint_claim, sprint_release)

**Bead:** iv-s6zo (F1)
**Phase:** plan-reviewed (as of 2026-02-20T02:10:00Z)
**Files:**
- Modify: `hub/clavain/hooks/lib-sprint.sh`

**Step 1: Rewrite sprint_set_artifact**

Replace existing (lines 210-233). Uses `ic run artifact add` — atomic, no manual locking:

```bash
# Record an artifact for the current phase. Uses ic run artifact add (atomic).
sprint_set_artifact() {
    local sprint_id="$1"
    local artifact_type="$2"
    local artifact_path="$3"

    [[ -z "$sprint_id" || -z "$artifact_type" || -z "$artifact_path" ]] && return 0

    local run_id
    run_id=$(bd state "$sprint_id" ic_run_id 2>/dev/null) || run_id=""

    if [[ -n "$run_id" ]] && intercore_available; then
        local phase
        phase=$(intercore_run_phase "$run_id") || phase="unknown"
        intercore_run_artifact_add "$run_id" "$phase" "$artifact_path" "$artifact_type" 2>/dev/null || true
        return 0
    fi

    # Fallback: beads-based (legacy sprints)
    intercore_lock "sprint" "$sprint_id" "1s" || return 0
    local current
    current=$(bd state "$sprint_id" sprint_artifacts 2>/dev/null) || current="{}"
    echo "$current" | jq empty 2>/dev/null || current="{}"
    local updated
    updated=$(echo "$current" | jq --arg type "$artifact_type" --arg path "$artifact_path" '.[$type] = $path')
    bd set-state "$sprint_id" "sprint_artifacts=$updated" 2>/dev/null || true
    intercore_unlock "sprint" "$sprint_id"
}
```

**Step 2: Rewrite sprint_record_phase_completion**

Replace existing (lines 237-262). Phase transitions are tracked by ic events automatically:

```bash
# Record phase completion. With ic, this is a no-op (events are auto-recorded).
# Still invalidates discovery caches.
sprint_record_phase_completion() {
    local sprint_id="$1"
    local phase="$2"

    [[ -z "$sprint_id" || -z "$phase" ]] && return 0

    local run_id
    run_id=$(bd state "$sprint_id" ic_run_id 2>/dev/null) || run_id=""

    if [[ -n "$run_id" ]] && intercore_available; then
        # Phase events are auto-recorded by ic run advance — no manual write needed
        sprint_invalidate_caches
        return 0
    fi

    # Fallback: beads-based
    intercore_lock "sprint" "$sprint_id" "1s" || return 0
    local current
    current=$(bd state "$sprint_id" phase_history 2>/dev/null) || current="{}"
    echo "$current" | jq empty 2>/dev/null || current="{}"
    local ts key updated
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    key="${phase}_at"
    updated=$(echo "$current" | jq --arg key "$key" --arg ts "$ts" '.[$key] = $ts')
    bd set-state "$sprint_id" "phase_history=$updated" 2>/dev/null || true
    intercore_unlock "sprint" "$sprint_id"
    sprint_invalidate_caches
}
```

**Step 3: Rewrite sprint_claim and sprint_release**

Replace existing sprint_claim (lines 272-334) and sprint_release (lines 337-342).
Session claims use `ic run agent add` — the claiming session registers as an agent:

```bash
# Claim a sprint for this session. Returns 0 if claimed, 1 if conflict.
sprint_claim() {
    local sprint_id="$1"
    local session_id="$2"

    [[ -z "$sprint_id" || -z "$session_id" ]] && return 0

    local run_id
    run_id=$(bd state "$sprint_id" ic_run_id 2>/dev/null) || run_id=""

    if [[ -n "$run_id" ]] && intercore_available; then
        # CRITICAL: Serialize the check-then-register sequence to prevent TOCTOU race.
        # Two sessions evaluating simultaneously could both see zero agents and both claim.
        # (Per correctness review Finding 1)
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
            # Check staleness (created >60 min ago)
            # NOTE: created_at may be ISO-8601 string — convert via date -d
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
            # Stale — mark old agent as failed, then claim
            local old_agent_id
            old_agent_id=$(echo "$active_agents" | jq -r '.[0].id')
            intercore_run_agent_update "$old_agent_id" "failed" 2>/dev/null || true
        fi

        # Register this session as an agent
        intercore_run_agent_add "$run_id" "session" "$session_id" 2>/dev/null || true
        intercore_unlock "sprint-claim" "$sprint_id"
        return 0
    fi

    # Fallback: beads-based claim (legacy)
    if ! intercore_lock "sprint-claim" "$sprint_id" "500ms"; then
        sleep 0.3
        local current_claim
        current_claim=$(bd state "$sprint_id" active_session 2>/dev/null) || current_claim=""
        if [[ "$current_claim" == "$session_id" ]]; then return 0; fi
        echo "Sprint $sprint_id is being claimed by another session" >&2
        return 1
    fi
    local current_claim claim_ts
    current_claim=$(bd state "$sprint_id" active_session 2>/dev/null) || current_claim=""
    claim_ts=$(bd state "$sprint_id" claim_timestamp 2>/dev/null) || claim_ts=""
    if [[ -n "$current_claim" && "$current_claim" != "$session_id" ]]; then
        if [[ -n "$claim_ts" && "$claim_ts" != "null" ]]; then
            local claim_epoch now_epoch age_minutes
            claim_epoch=$(date -d "$claim_ts" +%s 2>/dev/null) || claim_epoch=0
            if [[ $claim_epoch -gt 0 ]]; then
                now_epoch=$(date +%s)
                age_minutes=$(( (now_epoch - claim_epoch) / 60 ))
                if [[ $age_minutes -lt 60 ]]; then
                    echo "Sprint $sprint_id is active in session ${current_claim:0:8} (${age_minutes}m ago)" >&2
                    intercore_unlock "sprint-claim" "$sprint_id"
                    return 1
                fi
            fi
        fi
    fi
    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    bd set-state "$sprint_id" "active_session=$session_id" 2>/dev/null || true
    bd set-state "$sprint_id" "claim_timestamp=$ts" 2>/dev/null || true
    local verify
    verify=$(bd state "$sprint_id" active_session 2>/dev/null) || verify=""
    intercore_unlock "sprint-claim" "$sprint_id"
    if [[ "$verify" != "$session_id" ]]; then
        echo "Failed to claim sprint $sprint_id (write verification failed)" >&2
        return 1
    fi
    return 0
}

# Release sprint claim.
sprint_release() {
    local sprint_id="$1"
    [[ -z "$sprint_id" ]] && return 0

    local run_id
    run_id=$(bd state "$sprint_id" ic_run_id 2>/dev/null) || run_id=""

    if [[ -n "$run_id" ]] && intercore_available; then
        # Mark all active session agents as completed.
        # NOTE: release failure is recoverable via the 60-minute staleness TTL in sprint_claim.
        local agents_json
        agents_json=$(intercore_run_agent_list "$run_id") || agents_json="[]"
        echo "$agents_json" | jq -r '.[] | select(.status == "active" and .agent_type == "session") | .id' | \
            while read -r agent_id; do
                intercore_run_agent_update "$agent_id" "completed" 2>/dev/null || true
            done
        return 0
    fi

    # Fallback: beads-based
    bd set-state "$sprint_id" "active_session=" 2>/dev/null || true
    bd set-state "$sprint_id" "claim_timestamp=" 2>/dev/null || true
}
```

**Step 4: Syntax check**

Run: `bash -n hub/clavain/hooks/lib-sprint.sh`
Expected: No output (clean parse)

**Step 5: Commit**

```bash
git add hub/clavain/hooks/lib-sprint.sh
git commit -m "feat(sprint): rewrite state mutation to use ic run (artifacts, claims, releases)"
```

---

## Task 4: Rewrite lib-sprint.sh — Phase Advancement (enforce_gate, sprint_advance, sprint_should_pause)

**Bead:** iv-s6zo (F1), iv-idc4 (F6)
**Phase:** plan-reviewed (as of 2026-02-20T02:10:00Z)
**Files:**
- Modify: `hub/clavain/hooks/lib-sprint.sh`

**Step 1: Rewrite enforce_gate**

Replace existing (lines 348-357). Now uses `ic gate check` via run_id:

```bash
# Gate enforcement. Returns 0 if gate passes, 1 if blocked.
# Primary: ic gate check on run. Fallback: interphase shim.
enforce_gate() {
    local bead_id="$1"
    local target_phase="$2"
    local artifact_path="${3:-}"

    # Resolve run_id
    local run_id
    run_id=$(bd state "$bead_id" ic_run_id 2>/dev/null) || run_id=""

    if [[ -n "$run_id" ]] && intercore_available; then
        # ic gate check evaluates the run's current next transition internally.
        # target_phase is used only by the beads fallback; ic determines the applicable
        # phase transition from the run's state machine.
        intercore_gate_check "$run_id"
        return $?
    fi

    # Fallback: interphase shim
    if type check_phase_gate &>/dev/null; then
        check_phase_gate "$bead_id" "$target_phase" "$artifact_path"
    else
        return 0
    fi
}
```

**Step 2: Rewrite sprint_advance**

Replace existing (lines 443-499). The core is now `ic run advance`:

```bash
# Advance sprint to the next phase.
# Returns 0 on success, 1 on pause/error (structured reason on stdout).
sprint_advance() {
    local sprint_id="$1"
    local current_phase="$2"
    local artifact_path="${3:-}"

    [[ -z "$sprint_id" || -z "$current_phase" ]] && return 1

    local run_id
    run_id=$(bd state "$sprint_id" ic_run_id 2>/dev/null) || run_id=""

    if [[ -n "$run_id" ]] && intercore_available; then
        # ic run advance handles: phase chain, gate checks, optimistic concurrency,
        # auto_advance, phase skipping (via force_full + complexity on run)
        local result
        result=$(intercore_run_advance "$run_id") || {
            local rc=$?
            # Parse JSON error for structured pause reason
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
                    # JSON parse failed or unknown event type — log raw result for debugging
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

        # Success — parse result
        local from_phase to_phase
        from_phase=$(echo "$result" | jq -r '.from_phase // ""' 2>/dev/null) || from_phase="$current_phase"
        to_phase=$(echo "$result" | jq -r '.to_phase // ""' 2>/dev/null) || to_phase=""

        sprint_invalidate_caches
        echo "Phase: $from_phase → $to_phase (auto-advancing)" >&2
        return 0
    fi

    # Fallback: beads-based advance (original logic)
    local next_phase
    next_phase=$(_sprint_transition_table "$current_phase")
    [[ -z "$next_phase" || "$next_phase" == "$current_phase" ]] && return 1

    local complexity
    complexity=$(bd state "$sprint_id" complexity 2>/dev/null) || complexity="3"
    [[ -z "$complexity" || "$complexity" == "null" ]] && complexity="3"
    local force_full
    force_full=$(bd state "$sprint_id" force_full_chain 2>/dev/null) || force_full="false"
    if [[ "$force_full" != "true" ]] && sprint_should_skip "$next_phase" "$complexity"; then
        next_phase=$(sprint_next_required_phase "$current_phase" "$complexity")
        [[ -z "$next_phase" ]] && next_phase="done"
        echo "Phase: skipping to $next_phase (complexity $complexity)" >&2
    fi

    intercore_lock "sprint-advance" "$sprint_id" "1s" || return 1
    local pause_reason
    pause_reason=$(sprint_should_pause "$sprint_id" "$next_phase" 2>/dev/null) && {
        intercore_unlock "sprint-advance" "$sprint_id"
        echo "$pause_reason"
        return 1
    }
    local actual_phase
    actual_phase=$(bd state "$sprint_id" phase 2>/dev/null) || actual_phase=""
    if [[ -n "$actual_phase" && "$actual_phase" != "$current_phase" ]]; then
        intercore_unlock "sprint-advance" "$sprint_id"
        echo "stale_phase|$current_phase|Phase already advanced to $actual_phase"
        return 1
    fi
    bd set-state "$sprint_id" "phase=$next_phase" 2>/dev/null || true
    sprint_record_phase_completion "$sprint_id" "$next_phase"
    intercore_unlock "sprint-advance" "$sprint_id"
    echo "Phase: $current_phase → $next_phase (auto-advancing)" >&2
    return 0
}
```

**Step 3: Update sprint_should_pause**

Replace existing (lines 411-433). When ic is available, reads auto_advance from the run:

```bash
# Check if sprint should pause before advancing.
# Returns 0 WITH STRUCTURED PAUSE REASON ON STDOUT if pause trigger found.
# Returns 1 (no output) if should continue.
sprint_should_pause() {
    local sprint_id="$1"
    local target_phase="$2"

    [[ -z "$sprint_id" || -z "$target_phase" ]] && return 1

    local run_id
    run_id=$(bd state "$sprint_id" ic_run_id 2>/dev/null) || run_id=""

    if [[ -n "$run_id" ]] && intercore_available; then
        # ic run advance handles pause internally (auto_advance field on run)
        # But we still check here for pre-flight gate validation
        if ! intercore_gate_check "$run_id" 2>/dev/null; then
            echo "gate_blocked|$target_phase|Gate prerequisites not met"
            return 0
        fi
        return 1
    fi

    # Fallback: beads-based
    local auto_advance
    auto_advance=$(bd state "$sprint_id" auto_advance 2>/dev/null) || auto_advance="true"
    if [[ "$auto_advance" == "false" ]]; then
        echo "manual_pause|$target_phase|auto_advance=false"
        return 0
    fi
    if ! enforce_gate "$sprint_id" "$target_phase" "" 2>/dev/null; then
        echo "gate_blocked|$target_phase|Gate prerequisites not met"
        return 0
    fi
    return 1
}
```

**Step 4: Syntax check**

Run: `bash -n hub/clavain/hooks/lib-sprint.sh`
Expected: No output

**Step 5: Commit**

```bash
git add hub/clavain/hooks/lib-sprint.sh
git commit -m "feat(sprint): rewrite phase advancement to use ic run advance + ic gate check"
```

---

## Task 5: Rewrite lib-sprint.sh — Checkpoints and Complexity

**Bead:** iv-s6zo (F1)
**Phase:** plan-reviewed (as of 2026-02-20T02:10:00Z)
**Files:**
- Modify: `hub/clavain/hooks/lib-sprint.sh`

**Step 1: Rewrite checkpoint functions to use ic state**

Replace the checkpoint section (lines 720-823). Checkpoints move from `.clavain/checkpoint.json` to `ic state set`:

```bash
# ─── Checkpointing ───────────────────────────────────────────────

CHECKPOINT_FILE="${CLAVAIN_CHECKPOINT_FILE:-.clavain/checkpoint.json}"

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
    run_id=$(bd state "$bead" ic_run_id 2>/dev/null) || run_id=""

    if [[ -n "$run_id" ]] && intercore_available; then
        # Read existing checkpoint from ic state
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
        return 0
    fi

    # Fallback: file-based checkpoint
    mkdir -p "$(dirname "$CHECKPOINT_FILE")" 2>/dev/null || true
    local _ckpt_scope
    _ckpt_scope=$(echo "$CHECKPOINT_FILE" | tr '/' '-')
    intercore_lock "checkpoint" "$_ckpt_scope" "1s" || return 0
    local existing="{}"
    [[ -f "$CHECKPOINT_FILE" ]] && existing=$(cat "$CHECKPOINT_FILE" 2>/dev/null) || existing="{}"
    local tmp="${CHECKPOINT_FILE}.tmp"
    echo "$existing" | jq \
        --arg bead "$bead" --arg phase "$phase" --arg step "$step" \
        --arg plan_path "$plan_path" --arg git_sha "$git_sha" \
        --arg timestamp "$timestamp" --arg key_decision "$key_decision" \
        '
        .bead = $bead | .phase = $phase |
        .plan_path = (if $plan_path != "" then $plan_path else (.plan_path // "") end) |
        .git_sha = $git_sha | .updated_at = $timestamp |
        .completed_steps = ((.completed_steps // []) + [$step] | unique) |
        .key_decisions = (if $key_decision != "" then ((.key_decisions // []) + [$key_decision] | unique | .[-5:]) else (.key_decisions // []) end)
        ' > "$tmp" 2>/dev/null && mv "$tmp" "$CHECKPOINT_FILE" 2>/dev/null || true
    intercore_unlock "checkpoint" "$_ckpt_scope"
}

# Read the current checkpoint. Output: JSON or "{}"
# Args: $1=bead_id (optional — used to resolve the correct run_id)
# When bead_id is provided, resolves run via bead's ic_run_id (sprint-scoped).
# Without bead_id, falls back to ic run current (project-scoped, may be wrong
# with multiple active runs — per arch/correctness review).
checkpoint_read() {
    local bead_id="${1:-}"
    if intercore_available; then
        local run_id=""
        # Prefer bead-scoped lookup when available
        if [[ -n "$bead_id" ]]; then
            run_id=$(bd state "$bead_id" ic_run_id 2>/dev/null) || run_id=""
        fi
        # Fall back to project-scoped lookup
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
    # Fallback: file-based
    [[ -f "$CHECKPOINT_FILE" ]] && cat "$CHECKPOINT_FILE" 2>/dev/null || echo "{}"
}

# The remaining checkpoint functions (checkpoint_validate, checkpoint_completed_steps,
# checkpoint_step_done, checkpoint_clear) operate on the JSON returned by checkpoint_read
# and do not need changes — they work on the JSON structure regardless of source.
```

**Step 2: Rewrite sprint_classify_complexity to read from ic run**

Only the override check needs updating (lines 520-527). Replace:

```bash
    # Check for manual override — try ic run first, then beads
    if [[ -n "$sprint_id" ]]; then
        local override=""
        local run_id
        run_id=$(bd state "$sprint_id" ic_run_id 2>/dev/null) || run_id=""
        if [[ -n "$run_id" ]] && intercore_available; then
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

**Step 3: Syntax check**

Run: `bash -n hub/clavain/hooks/lib-sprint.sh`
Expected: No output

**Step 4: Commit**

```bash
git add hub/clavain/hooks/lib-sprint.sh
git commit -m "feat(sprint): migrate checkpoints to ic state, update complexity reads"
```

---

## Task 6: Sentinel Cleanup — Remove Temp-File Fallback

**Bead:** iv-ca06 (F2)
**Phase:** plan-reviewed (as of 2026-02-20T02:10:00Z)
**Files:**
- Modify: `hub/clavain/hooks/lib-intercore.sh`

**Step 1: Simplify intercore_sentinel_check_or_legacy**

Replace existing (lines 58-87). Remove the temp-file fallback:

```bash
# intercore_sentinel_check_or_legacy — check sentinel via ic.
# LEGACY NAME PRESERVED for backward compat at call sites.
# Args: $1=name, $2=scope_id, $3=interval, $4=legacy_file (ignored)
# Returns: 0 if allowed, 1 if throttled
intercore_sentinel_check_or_legacy() {
    local name="$1" scope_id="$2" interval="$3"
    if ! intercore_available; then
        # No ic = no throttle (fail-open for non-critical hooks)
        return 0
    fi
    local rc=0
    "$INTERCORE_BIN" sentinel check "$name" "$scope_id" --interval="$interval" >/dev/null || rc=$?
    if [[ $rc -eq 0 ]]; then return 0; fi  # allowed
    if [[ $rc -eq 1 ]]; then return 1; fi  # throttled
    return 0  # error → fail-open
}
```

**Step 2: Simplify intercore_check_or_die**

Replace existing (lines 93-113):

```bash
# intercore_check_or_die — check sentinel, exit 0 if throttled.
# Args: $1=name, $2=scope_id, $3=interval, $4=legacy_path (ignored)
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

**Step 3: Simplify intercore_sentinel_reset_or_legacy**

Replace existing (lines 117-126):

```bash
# intercore_sentinel_reset_or_legacy — reset sentinel via ic.
# Args: $1=name, $2=scope_id, $3=legacy_glob (ignored)
intercore_sentinel_reset_or_legacy() {
    local name="$1" scope_id="$2"
    if ! intercore_available; then return 0; fi
    "$INTERCORE_BIN" sentinel reset "$name" "$scope_id" >/dev/null 2>&1 || true
}
```

**Step 4: Simplify intercore_sentinel_reset_all**

Replace existing (lines 132-145):

```bash
# intercore_sentinel_reset_all — reset all scopes for a sentinel name.
intercore_sentinel_reset_all() {
    local name="$1"
    if ! intercore_available; then return 0; fi
    local _name scope _fired
    while IFS=$'\t' read -r _name scope _fired; do
        [[ "$_name" == "$name" ]] || continue
        "$INTERCORE_BIN" sentinel reset "$name" "$scope" >/dev/null 2>&1 || true
    done < <("$INTERCORE_BIN" sentinel list 2>/dev/null || true)
}
```

**Step 5: Simplify intercore_state_delete_all and intercore_cleanup_stale**

Replace existing (lines 150-173):

```bash
# intercore_state_delete_all — delete all scopes for a state key.
intercore_state_delete_all() {
    local key="$1"
    if ! intercore_available; then return 0; fi
    local scope
    while read -r scope; do
        "$INTERCORE_BIN" state delete "$key" "$scope" 2>/dev/null || true
    done < <("$INTERCORE_BIN" state list "$key" 2>/dev/null || true)
}

# intercore_cleanup_stale — prune old sentinels.
intercore_cleanup_stale() {
    if ! intercore_available; then return 0; fi
    "$INTERCORE_BIN" sentinel prune --older-than=1h >/dev/null 2>&1 || true
}
```

**Step 6: Update version string**

Change line 9:
```bash
INTERCORE_WRAPPER_VERSION="1.0.0"
```

**Step 7: Syntax check and commit**

Run: `bash -n hub/clavain/hooks/lib-intercore.sh`

```bash
git add hub/clavain/hooks/lib-intercore.sh
git commit -m "feat(intercore): remove temp-file fallback from sentinels (v1.0.0)"
```

---

## Task 7: Session State Migration (session-start.sh)

**Bead:** iv-2hos (F3)
**Phase:** plan-reviewed (as of 2026-02-20T02:10:00Z)
**Files:**
- Modify: `hub/clavain/hooks/session-start.sh`

**Step 1: Update sprint detection block**

The sprint detection in session-start.sh (lines 187-204) already calls `sprint_find_active` — which we rewrote in Task 2 to use `ic run list --active`. The session-start.sh code doesn't need structural changes because it calls the function, not the implementation.

However, the `sprint_find_active` output now includes a `run_id` field. Update the hint generation (around line 196) to pass this through:

Replace lines 196-201:
```bash
    if [[ "$sprint_count" -gt 0 ]]; then
        top_sprint=$(echo "$active_sprints" | jq '.[0]')
        top_id=$(echo "$top_sprint" | jq -r '.id')
        top_title=$(echo "$top_sprint" | jq -r '.title')
        top_phase=$(echo "$top_sprint" | jq -r '.phase')
        next_step=$(sprint_next_step "$top_phase" 2>/dev/null) || next_step="unknown"
        sprint_resume_hint="\\n• Active sprint: ${top_id} — ${top_title} (phase: ${top_phase}, next: ${next_step}). Resume with /sprint or /sprint ${top_id}"
        sprint_resume_hint=$(escape_for_json "$sprint_resume_hint")
    fi
```

This is unchanged because `sprint_find_active` returns the same JSON shape (with an optional `run_id` field). The hint format stays the same.

**Step 2: Verify no direct bd state calls exist in session-start.sh for sprint detection**

Run: `grep -n 'bd state.*sprint\|bd state.*phase\|bd set-state' hub/clavain/hooks/session-start.sh`
Expected: No matches (all sprint state access goes through lib-sprint.sh functions)

**Step 3: Commit**

```bash
git add hub/clavain/hooks/session-start.sh
git commit -m "docs(session): verify sprint detection uses ic-backed sprint_find_active"
```

---

## Task 8: Event Reactor Hooks

**Bead:** iv-rmx0 (F4)
**Phase:** plan-reviewed (as of 2026-02-20T02:10:00Z)
**Files:**
- Create: `hub/clavain/.clavain/hooks/on-phase-advance`
- Create: `hub/clavain/.clavain/hooks/on-dispatch-change`

Intercore's HookHandler fires these scripts when events occur. Both are observability-only.

**Step 1: Create on-phase-advance hook**

```bash
#!/usr/bin/env bash
# Intercore event reactor: on-phase-advance
# Receives Event JSON on stdin from ic's HookHandler.
# Logs phase transitions for observability. Does NOT drive workflow.
set -euo pipefail

event=$(cat 2>/dev/null) || exit 0
[[ -z "$event" ]] && exit 0

run_id=$(echo "$event" | jq -r '.run_id // empty' 2>/dev/null) || exit 0
from=$(echo "$event" | jq -r '.from_state // "?"' 2>/dev/null) || from="?"
to=$(echo "$event" | jq -r '.to_state // "?"' 2>/dev/null) || to="?"
reason=$(echo "$event" | jq -r '.reason // ""' 2>/dev/null) || reason=""

printf '[ic-event] phase: %s → %s (run: %s)\n' "$from" "$to" "${run_id:0:12}" >&2
if [[ -n "$reason" ]]; then
    printf '[ic-event]   reason: %s\n' "$reason" >&2
fi

exit 0
```

**Step 2: Create on-dispatch-change hook**

```bash
#!/usr/bin/env bash
# Intercore event reactor: on-dispatch-change
# Receives Event JSON on stdin from ic's HookHandler.
# Logs dispatch lifecycle events for observability.
set -euo pipefail

event=$(cat 2>/dev/null) || exit 0
[[ -z "$event" ]] && exit 0

run_id=$(echo "$event" | jq -r '.run_id // empty' 2>/dev/null) || exit 0
from=$(echo "$event" | jq -r '.from_state // "?"' 2>/dev/null) || from="?"
to=$(echo "$event" | jq -r '.to_state // "?"' 2>/dev/null) || to="?"

printf '[ic-event] dispatch: %s → %s (run: %s)\n' "$from" "$to" "${run_id:0:12}" >&2

exit 0
```

**Step 3: Make executable**

```bash
chmod +x hub/clavain/.clavain/hooks/on-phase-advance hub/clavain/.clavain/hooks/on-dispatch-change
```

**Step 4: Commit**

```bash
git add hub/clavain/.clavain/hooks/on-phase-advance hub/clavain/.clavain/hooks/on-dispatch-change
git commit -m "feat(intercore): add event reactor hooks for phase/dispatch observability"
```

---

## Task 9: Agent Tracking Wiring

**Bead:** iv-pb68 (F5)
**Phase:** plan-reviewed (as of 2026-02-20T02:10:00Z)
**Files:**
- Modify: `hub/clavain/hooks/lib-sprint.sh` (add helper)

Agent tracking needs a helper that skills can call when dispatching subagents. The actual `ic run agent add` wrapper already exists in lib-intercore.sh.

**Step 1: Add sprint_track_agent helper to lib-sprint.sh**

Add after the sprint_release function:

```bash
# ─── Agent Tracking ──────────────────────────────────────────────

# Track an agent dispatch against the current sprint run.
# Called by skills when spawning subagents (work, quality-gates).
# Args: $1=sprint_id, $2=agent_name, $3=agent_type (default "claude"), $4=dispatch_id (optional)
# Returns: agent_id on stdout, or empty on failure
sprint_track_agent() {
    local sprint_id="$1"
    local agent_name="$2"
    local agent_type="${3:-claude}"
    local dispatch_id="${4:-}"

    [[ -z "$sprint_id" || -z "$agent_name" ]] && return 0

    local run_id
    run_id=$(bd state "$sprint_id" ic_run_id 2>/dev/null) || run_id=""

    if [[ -n "$run_id" ]] && intercore_available; then
        intercore_run_agent_add "$run_id" "$agent_type" "$agent_name" "$dispatch_id"
        return $?
    fi

    return 0
}

# Mark an agent as completed.
# Args: $1=agent_id, $2=status (default "completed")
sprint_complete_agent() {
    local agent_id="$1"
    local status="${2:-completed}"

    [[ -z "$agent_id" ]] && return 0

    if intercore_available; then
        intercore_run_agent_update "$agent_id" "$status" 2>/dev/null || true
    fi
}
```

**Step 2: Syntax check and commit**

Run: `bash -n hub/clavain/hooks/lib-sprint.sh`

```bash
git add hub/clavain/hooks/lib-sprint.sh
git commit -m "feat(sprint): add agent tracking helpers (sprint_track_agent, sprint_complete_agent)"
```

---

## Task 10: Migration Script

**Bead:** iv-japn (F7)
**Phase:** plan-reviewed (as of 2026-02-20T02:10:00Z)
**Files:**
- Create: `hub/clavain/scripts/migrate-sprints-to-ic.sh`

One-time idempotent script to migrate existing in-progress sprint beads to ic runs.

**Step 1: Write migration script**

```bash
#!/usr/bin/env bash
# One-time migration: existing sprint beads → ic runs
# Idempotent: skips beads that already have an ic_run_id.
# Usage: bash hub/clavain/scripts/migrate-sprints-to-ic.sh [--dry-run]
set -euo pipefail

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

if ! command -v bd &>/dev/null; then
    echo "Error: bd (beads) not found" >&2
    exit 1
fi

if ! command -v ic &>/dev/null; then
    echo "Error: ic (intercore) not found" >&2
    exit 1
fi

if ! command -v jq &>/dev/null; then
    echo "Error: jq not found" >&2
    exit 1
fi

MIGRATED=0
SKIPPED=0
ERRORS=0

PHASES_JSON='["brainstorm","brainstorm-reviewed","strategized","planned","plan-reviewed","executing","shipping","done"]'

echo "=== Sprint Migration: beads → ic runs ==="
echo "Dry run: $DRY_RUN"
echo ""

# Find all in-progress beads
ip_list=$(bd list --status=in_progress --json 2>/dev/null) || ip_list="[]"
count=$(echo "$ip_list" | jq 'length' 2>/dev/null) || count=0

for (( i=0; i<count; i++ )); do
    bead_id=$(echo "$ip_list" | jq -r ".[$i].id // empty")
    [[ -z "$bead_id" ]] && continue

    # Check if it's a sprint
    is_sprint=$(bd state "$bead_id" sprint 2>/dev/null) || is_sprint=""
    [[ "$is_sprint" != "true" ]] && continue

    title=$(echo "$ip_list" | jq -r ".[$i].title // \"Untitled\"")

    # Check if already migrated
    existing_run=$(bd state "$bead_id" ic_run_id 2>/dev/null) || existing_run=""
    if [[ -n "$existing_run" && "$existing_run" != "null" ]]; then
        echo "SKIP $bead_id — already has ic_run_id=$existing_run"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    # Read current phase
    phase=$(bd state "$bead_id" phase 2>/dev/null) || phase="brainstorm"
    [[ -z "$phase" || "$phase" == "null" ]] && phase="brainstorm"

    echo "MIGRATE $bead_id — $title (phase: $phase)"

    if [[ "$DRY_RUN" == "true" ]]; then
        MIGRATED=$((MIGRATED + 1))
        continue
    fi

    # Crash recovery: cancel any orphaned ic runs for this bead from a previous failed migration
    existing_json=$(ic run list --active --scope="$bead_id" --json 2>/dev/null) || existing_json="[]"
    orphan_count=$(echo "$existing_json" | jq 'length' 2>/dev/null) || orphan_count=0
    if [[ "$orphan_count" -gt 0 ]]; then
        echo "  WARN: Found $orphan_count orphaned ic run(s) for $bead_id, cancelling"
        echo "$existing_json" | jq -r '.[].id' | while read -r orphan_id; do
            ic run cancel "$orphan_id" 2>/dev/null || true
        done
    fi

    # Create ic run
    run_id=$(ic run create --project="$(pwd)" --goal="$title" --phases="$PHASES_JSON" --scope-id="$bead_id" 2>/dev/null) || run_id=""
    if [[ -z "$run_id" ]]; then
        echo "  ERROR: ic run create failed"
        ERRORS=$((ERRORS + 1))
        continue
    fi

    # Align ic run to match current phase using skip (NOT advance).
    # CRITICAL: ic run advance triggers SpawnHandler on "executing" phase,
    # which would launch real agents for historical sprints. ic run skip
    # writes to the audit trail without firing phase callbacks.
    # (Per correctness review Finding 5)
    current_ic_phase="brainstorm"
    phases_array=("brainstorm" "brainstorm-reviewed" "strategized" "planned" "plan-reviewed" "executing" "shipping" "done")
    skip_failed=false
    for p in "${phases_array[@]}"; do
        [[ "$p" == "$phase" ]] && break
        [[ "$p" == "$current_ic_phase" ]] || continue
        ic run skip "$run_id" "$p" --reason="historical-migration" 2>/dev/null || { skip_failed=true; break; }
        # Find the next phase in the array
        for (( j=0; j<${#phases_array[@]}; j++ )); do
            if [[ "${phases_array[$j]}" == "$p" ]]; then
                current_ic_phase="${phases_array[$((j+1))]}"
                break
            fi
        done
    done

    # Verify phase alignment BEFORE writing ic_run_id to bead.
    # If alignment failed, cancel the run — don't leave a misaligned run linked.
    # (Per safety review Finding 3 + architecture review Finding 1d)
    actual_ic_phase=$(ic run phase "$run_id" 2>/dev/null) || actual_ic_phase=""
    if [[ "$actual_ic_phase" != "$phase" ]] || [[ "$skip_failed" == "true" ]]; then
        echo "  ERROR: Phase alignment failed (ic at '${actual_ic_phase}', target: '$phase')"
        ic run cancel "$run_id" 2>/dev/null || true
        ERRORS=$((ERRORS + 1))
        continue
    fi

    # Store run_id on bead — only after verified alignment
    bd set-state "$bead_id" "ic_run_id=$run_id" 2>/dev/null || true

    # Migrate artifacts
    artifacts_json=$(bd state "$bead_id" sprint_artifacts 2>/dev/null) || artifacts_json="{}"
    echo "$artifacts_json" | jq empty 2>/dev/null || artifacts_json="{}"
    if [[ "$artifacts_json" != "{}" ]]; then
        echo "$artifacts_json" | jq -r 'to_entries[] | "\(.key)\t\(.value)"' | \
            while IFS=$'\t' read -r art_type art_path; do
                ic run artifact add "$run_id" --phase="$phase" --path="$art_path" --type="$art_type" 2>/dev/null || true
            done
    fi

    echo "  → Created run $run_id (phase: $current_ic_phase)"
    MIGRATED=$((MIGRATED + 1))
done

echo ""
echo "=== Results ==="
echo "Migrated: $MIGRATED"
echo "Skipped:  $SKIPPED"
echo "Errors:   $ERRORS"

# Exit non-zero if any errors occurred so callers can detect partial failure
if [[ "$ERRORS" -gt 0 ]]; then
    echo "WARNING: $ERRORS sprint(s) failed migration. Re-run after fixing." >&2
    exit 1
fi
```

**Step 2: Make executable and commit**

```bash
chmod +x hub/clavain/scripts/migrate-sprints-to-ic.sh
git add hub/clavain/scripts/migrate-sprints-to-ic.sh
git commit -m "feat(intercore): add one-time sprint migration script (beads → ic runs)"
```

---

## Task 11: Integration Test — Full Sprint Lifecycle

**Files:**
- Test script (run manually, not committed)

**Step 1: Run end-to-end test**

```bash
# Initialize ic in the project (if not already done)
ic init 2>/dev/null || true

# Source the rewritten library
source hub/clavain/hooks/lib-sprint.sh

# Create a sprint
export SPRINT_LIB_PROJECT_DIR="."
SPRINT_ID=$(sprint_create "E3 Test Sprint")
echo "Created: $SPRINT_ID"

# Finalize
sprint_finalize_init "$SPRINT_ID"

# Verify ic run exists
RUN_ID=$(bd state "$SPRINT_ID" ic_run_id)
echo "Run ID: $RUN_ID"
ic run status "$RUN_ID"
ic run phase "$RUN_ID"  # Should be "brainstorm"

# Test artifact tracking
sprint_set_artifact "$SPRINT_ID" "brainstorm" "docs/test-brainstorm.md"
ic run artifact list "$RUN_ID"

# Test sprint discovery
ACTIVE=$(sprint_find_active)
echo "Active sprints: $ACTIVE"

# Test claim
sprint_claim "$SPRINT_ID" "test-session-123"
ic run agent list "$RUN_ID"

# Test advance
sprint_advance "$SPRINT_ID" "brainstorm"
ic run phase "$RUN_ID"  # Should be "brainstorm-reviewed"

# Test read state
sprint_read_state "$SPRINT_ID" | jq .

# Test checkpoint
checkpoint_write "$SPRINT_ID" "brainstorm-reviewed" "strategy"
checkpoint_read "$SPRINT_ID" | jq .

# Release and clean up
sprint_release "$SPRINT_ID"
checkpoint_clear

# Close the test sprint
bd close "$SPRINT_ID" --reason="E3 integration test" 2>/dev/null || true
```

**Step 2: Run syntax checks on all modified files**

```bash
bash -n hub/clavain/hooks/lib-sprint.sh
bash -n hub/clavain/hooks/lib-intercore.sh
bash -n hub/clavain/hooks/session-start.sh
bash -n hub/clavain/.clavain/hooks/on-phase-advance
bash -n hub/clavain/.clavain/hooks/on-dispatch-change
bash -n hub/clavain/scripts/migrate-sprints-to-ic.sh
```

**Step 3: Commit integration test results**

```bash
git add -A
git commit -m "feat(intercore): E3 hook cutover complete — sprint state on ic run"
```

---

## Task 12: Update lib-gates.sh Deprecation Notice

**Bead:** iv-idc4 (F6)
**Phase:** plan-reviewed (as of 2026-02-20T02:10:00Z)
**Files:**
- Modify: `hub/clavain/hooks/lib-gates.sh`

**Step 1: Add deprecation comment**

Add at the top of lib-gates.sh (after line 1):

```bash
# DEPRECATED: Gate enforcement now uses ic gate check/override via lib-intercore.sh.
# This shim is retained for backward compatibility with non-sprint code that
# still calls check_phase_gate or advance_phase directly.
# Sprint gate enforcement goes through enforce_gate() in lib-sprint.sh → intercore_gate_check.
```

**Step 2: Remove source line from lib-sprint.sh**

Remove the `source lib-gates.sh` line from lib-sprint.sh (line 22). The ic gate path in `enforce_gate` (Task 4) is the primary path now. The fallback still calls `check_phase_gate` if the function exists (it's defined inline by interphase, not by lib-gates.sh sourcing).

```bash
# In lib-sprint.sh, remove or comment out:
# source "${_SPRINT_LIB_DIR}/lib-gates.sh"
```

**Step 3: Commit**

```bash
git add hub/clavain/hooks/lib-gates.sh hub/clavain/hooks/lib-sprint.sh
git commit -m "chore(gates): deprecate lib-gates.sh shim, remove source from lib-sprint.sh"
```

---

## Appendix A: Deployment Sequencing

**Phase 1 — Prepare (no user impact):**
1. Deploy Task 1 (lib-intercore.sh wrappers) — additive, no behavior change
2. Deploy Task 8 (event reactor hooks) — new files, no existing code changed
3. Deploy Task 12 (lib-gates.sh deprecation) — documentation only
4. Verify `ic` binary and DB health: `ic health` passes in `hub/clavain/`

**Phase 2 — Core cutover (deploy atomically):**
5. Deploy Tasks 2, 3, 4, 5, 9 (lib-sprint.sh rewrites) — fallback paths still work for unmigrated beads
6. Deploy Task 7 (session-start.sh) — now calls rewritten sprint_find_active

**Phase 3 — Migration (run once, verify before proceeding):**
7. `bash hub/clavain/scripts/migrate-sprints-to-ic.sh --dry-run` — verify zero errors
8. `bash hub/clavain/scripts/migrate-sprints-to-ic.sh` — run live migration
9. Verify: `ic run list --active` count matches `bd list --status=in_progress` sprint count
10. Restart all active Claude Code sessions

**Phase 4 — Cleanup (only after Phase 3 verified clean):**
11. Deploy Task 6 (sentinel cleanup) — removes temp-file fallback permanently
12. Run Task 11 integration test

## Appendix B: Rollback Procedure

```bash
# Before migration: take snapshot
bd list --status=in_progress --json > /tmp/sprint-state-pre-migration.json

# To rollback:
# 1. Revert Tasks 2-9 code (git revert commits)
# 2. Clear ic_run_id from all migrated beads:
for id in $(bd list --status=in_progress --json | jq -r '.[].id'); do
    run_id=$(bd state "$id" ic_run_id 2>/dev/null) || continue
    [[ -z "$run_id" || "$run_id" == "null" ]] && continue
    bd set-state "$id" "ic_run_id=" 2>/dev/null || true
    echo "Cleared ic_run_id from $id"
done
# 3. Cancel orphaned ic runs:
ic run list --active --json | jq -r '.[].id' | while read -r run_id; do
    ic run cancel "$run_id" 2>/dev/null || true
done
```

## Appendix C: Review Findings Incorporated

Findings from three parallel review agents (architecture, safety, correctness):

| Finding | Severity | Fix Applied |
|---------|----------|-------------|
| sprint_claim TOCTOU — no lock around check-register | CRITICAL | Added intercore_lock serialization (Task 3) |
| ic_run_id write is `\|\| true` — orphans ic run | HIGH | Cancel ic run + bead on write failure (Task 2) |
| Migration triggers SpawnHandler on "executing" advance | HIGH | Use `ic run skip` instead of advance (Task 10) |
| Migration writes ic_run_id before phase alignment verified | HIGH | Gate write on alignment check (Task 10) |
| checkpoint_read uses CWD-scoped run lookup | HIGH | Accept optional bead_id parameter (Task 5) |
| sprint_find_active still has N+1 bead reads | MEDIUM | Trust scope_id presence; removed per-run bd state calls (Task 2) |
| Unquoted `$@` in intercore_run_list | MEDIUM | Changed to `"$@"` (Task 1) |
| sprint_claim bypasses lib-intercore.sh wrappers | MEDIUM | Added intercore_run_agent_list/update wrappers (Task 1) |
| events tail unbounded in sprint_read_state | MEDIUM | Use `ic run events` (bounded, phase-only) (Task 2) |
| todate jq filter assumes epoch format | MEDIUM | Use timestamp directly (Task 2) |
| sprint_finalize_init writes redundant sprint_link | LOW | Removed YAGNI write (Task 2) |
| No rollback path | HIGH | Added Appendix B |
| No deployment ordering | HIGH | Added Appendix A |
