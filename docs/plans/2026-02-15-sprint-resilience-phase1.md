# Sprint Resilience Phase 1: Resume & Tracking

> **For Claude:** REQUIRED SUB-SKILL: Use clavain:executing-plans to implement this plan task-by-task.

**Bead:** iv-ty1f
**Phase:** executing (as of 2026-02-15T21:23:02Z)
**Review fixes applied:** Architecture (4 critical) + Correctness (5 issues) — see docs/research/
**Goal:** Make the sprint workflow resilient to session restarts by storing all state on beads and enabling zero-setup resume.

**Architecture:** New `lib-sprint.sh` library in Clavain provides sprint-specific CRUD, resume, and state accessors. Sprint beads are regular `type=epic` beads with `sprint=true` state. SessionStart hook detects active sprints and injects resume context. `/sprint` command rewritten to check for active sprint first.

**Tech Stack:** Bash (hook libraries), Markdown (commands), jq (JSON manipulation), bd CLI (beads)

**Scope:** F1 (Sprint Bead Lifecycle), F4 (Session-Resilient Resume), F5 (Sprint Status Visibility). Excludes auto-advance (Phase 2) and tiered brainstorming (Phase 3).

---

### Task 1: Create lib-sprint.sh — Sprint State Library

**Files:**
- Create: `hub/clavain/hooks/lib-sprint.sh`

**Step 1: Write the library**

```bash
#!/usr/bin/env bash
# Sprint-specific state library for Clavain.
# Sprint beads are type=epic beads with sprint=true state.
# All functions are fail-safe (return 0 on error, never block workflow)
# EXCEPT sprint_claim() which returns 1 on conflict (callers must handle).

# Guard against double-sourcing
[[ -n "${_SPRINT_LOADED:-}" ]] && return 0
_SPRINT_LOADED=1

SPRINT_LIB_PROJECT_DIR="${SPRINT_LIB_PROJECT_DIR:-.}"

# Source interphase phase primitives (via Clavain shim)
_SPRINT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_SPRINT_LIB_DIR}/lib.sh" 2>/dev/null || true

# Source gates for advance_phase (via shim → interphase)
export GATES_PROJECT_DIR="$SPRINT_LIB_PROJECT_DIR"
source "${_SPRINT_LIB_DIR}/lib-gates.sh" 2>/dev/null || true

# ─── jq dependency check ─────────────────────────────────────────
# jq is required for all JSON operations. Stub out functions if missing.
if ! command -v jq &>/dev/null; then
    sprint_create() { echo ""; }
    sprint_finalize_init() { return 0; }
    sprint_find_active() { echo "[]"; }
    sprint_read_state() { echo "{}"; }
    sprint_set_artifact() { return 0; }
    sprint_record_phase_completion() { return 0; }
    sprint_claim() { return 0; }
    sprint_release() { return 0; }
    sprint_next_step() { echo "brainstorm"; }
    sprint_invalidate_caches() { return 0; }
    return 0
fi

# ─── Sprint CRUD ────────────────────────────────────────────────────

# Create a sprint bead. Returns bead ID to stdout.
# Sets sprint=true, phase=brainstorm, sprint_initialized=false.
# Caller MUST call sprint_finalize_init() after all setup.
# CORRECTNESS: If any set-state call fails after bd create succeeds, the bead
# is cancelled to prevent zombie state. Callers receive "".
sprint_create() {
    local title="${1:-Sprint}"

    if ! command -v bd &>/dev/null; then
        echo ""
        return 0
    fi

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

    # Initialize critical state fields (fail early if any write fails)
    bd set-state "$sprint_id" "sprint=true" 2>/dev/null || {
        bd update "$sprint_id" --status=cancelled 2>/dev/null || true
        echo ""; return 0
    }
    bd set-state "$sprint_id" "phase=brainstorm" 2>/dev/null || {
        bd update "$sprint_id" --status=cancelled 2>/dev/null || true
        echo ""; return 0
    }
    bd set-state "$sprint_id" "sprint_artifacts={}" 2>/dev/null || true
    bd set-state "$sprint_id" "sprint_initialized=false" 2>/dev/null || true
    bd set-state "$sprint_id" "phase_history={}" 2>/dev/null || true
    bd update "$sprint_id" --status=in_progress 2>/dev/null || true

    # Verify critical state was written
    local verify_phase
    verify_phase=$(bd state "$sprint_id" phase 2>/dev/null)
    if [[ "$verify_phase" != "brainstorm" ]]; then
        echo "sprint_create: initialization failed, cancelling bead $sprint_id" >&2
        bd update "$sprint_id" --status=cancelled 2>/dev/null || true
        echo ""
        return 0
    fi

    echo "$sprint_id"
}

# Mark sprint as fully initialized. Discovery skips uninitialized sprints.
sprint_finalize_init() {
    local sprint_id="$1"
    [[ -z "$sprint_id" ]] && return 0
    bd set-state "$sprint_id" "sprint_initialized=true" 2>/dev/null || true
}

# ─── Sprint Discovery ──────────────────────────────────────────────

# Find active sprint beads (in_progress with sprint=true).
# Output: JSON array [{id, title, phase, ...}] or "[]"
sprint_find_active() {
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

    # Validate JSON — must be an array
    echo "$ip_list" | jq 'if type != "array" then error("expected array") else . end' >/dev/null 2>&1 || {
        echo "[]"
        return 0
    }

    # Filter for sprint=true beads that are initialized
    local count
    count=$(echo "$ip_list" | jq 'length' 2>/dev/null) || count=0

    local results="[]"
    local i=0
    local max_iterations=100  # Safety limit
    while [[ $i -lt $count && $i -lt $max_iterations ]]; do
        local bead_id
        bead_id=$(echo "$ip_list" | jq -r ".[$i].id // empty")
        [[ -z "$bead_id" ]] && { i=$((i + 1)); continue; }

        # Check sprint=true state
        local is_sprint
        is_sprint=$(bd state "$bead_id" sprint 2>/dev/null) || is_sprint=""
        if [[ "$is_sprint" != "true" ]]; then
            i=$((i + 1))
            continue
        fi

        # Check initialized
        local initialized
        initialized=$(bd state "$bead_id" sprint_initialized 2>/dev/null) || initialized=""
        if [[ "$initialized" != "true" ]]; then
            i=$((i + 1))
            continue
        fi

        local title phase
        title=$(echo "$ip_list" | jq -r ".[$i].title // \"Untitled\"")
        phase=$(bd state "$bead_id" phase 2>/dev/null) || phase=""

        results=$(echo "$results" | jq \
            --arg id "$bead_id" \
            --arg title "$title" \
            --arg phase "$phase" \
            '. + [{id: $id, title: $title, phase: $phase}]')

        i=$((i + 1))
    done

    echo "$results"
}

# ─── Sprint State ──────────────────────────────────────────────────

# Read all sprint state fields at once. Output: JSON object.
sprint_read_state() {
    local sprint_id="$1"
    [[ -z "$sprint_id" ]] && { echo "{}"; return 0; }

    local phase sprint_artifacts phase_history complexity auto_advance active_session
    phase=$(bd state "$sprint_id" phase 2>/dev/null) || phase=""
    sprint_artifacts=$(bd state "$sprint_id" sprint_artifacts 2>/dev/null) || sprint_artifacts="{}"
    phase_history=$(bd state "$sprint_id" phase_history 2>/dev/null) || phase_history="{}"
    complexity=$(bd state "$sprint_id" complexity 2>/dev/null) || complexity=""
    auto_advance=$(bd state "$sprint_id" auto_advance 2>/dev/null) || auto_advance="true"
    active_session=$(bd state "$sprint_id" active_session 2>/dev/null) || active_session=""

    # Validate JSON fields (fall back to defaults if corrupt)
    echo "$sprint_artifacts" | jq empty 2>/dev/null || sprint_artifacts="{}"
    echo "$phase_history" | jq empty 2>/dev/null || phase_history="{}"

    jq -n -c \
        --arg id "$sprint_id" \
        --arg phase "$phase" \
        --argjson artifacts "$sprint_artifacts" \
        --argjson history "$phase_history" \
        --arg complexity "$complexity" \
        --arg auto_advance "$auto_advance" \
        --arg active_session "$active_session" \
        '{id: $id, phase: $phase, artifacts: $artifacts, history: $history,
          complexity: $complexity, auto_advance: $auto_advance, active_session: $active_session}'
}

# Update a single artifact path with filesystem locking.
# CORRECTNESS: ALL updates to sprint_artifacts MUST go through this function.
# Direct `bd set-state` calls bypass the lock and cause lost-update races.
# Lock cleanup: Stale locks (>5s old) are force-broken. If process is killed
# while holding lock, next caller after timeout will take over. During timeout
# window, updates fail silently (fail-safe design).
sprint_set_artifact() {
    local sprint_id="$1"
    local artifact_type="$2"
    local artifact_path="$3"

    [[ -z "$sprint_id" || -z "$artifact_type" || -z "$artifact_path" ]] && return 0

    local lock_dir="/tmp/sprint-lock-${sprint_id}"

    # Acquire lock (mkdir is atomic on all POSIX systems)
    local retries=0
    while ! mkdir "$lock_dir" 2>/dev/null; do
        retries=$((retries + 1))
        [[ $retries -gt 10 ]] && {
            # Force-break stale lock (older than 5 seconds — artifact updates are <1s)
            local lock_mtime
            lock_mtime=$(stat -c %Y "$lock_dir" 2>/dev/null)
            if [[ -z "$lock_mtime" ]]; then
                echo "sprint_set_artifact: lock stat failed for $lock_dir" >&2
                return 0
            fi
            local now
            now=$(date +%s)
            if [[ $((now - lock_mtime)) -gt 5 ]]; then
                rmdir "$lock_dir" 2>/dev/null || rm -rf "$lock_dir" 2>/dev/null || true
                mkdir "$lock_dir" 2>/dev/null || return 0
                break
            fi
            return 0  # Give up — fail-safe
        }
        sleep 0.1
    done

    # Read-modify-write under lock
    local current
    current=$(bd state "$sprint_id" sprint_artifacts 2>/dev/null) || current="{}"
    echo "$current" | jq empty 2>/dev/null || current="{}"

    local updated
    updated=$(echo "$current" | jq --arg type "$artifact_type" --arg path "$artifact_path" \
        '.[$type] = $path')

    bd set-state "$sprint_id" "sprint_artifacts=$updated" 2>/dev/null || true

    # Release lock
    rmdir "$lock_dir" 2>/dev/null || true
}

# Record phase completion timestamp in phase_history.
# Also invalidates discovery caches so session-start picks up the new phase.
sprint_record_phase_completion() {
    local sprint_id="$1"
    local phase="$2"

    [[ -z "$sprint_id" || -z "$phase" ]] && return 0

    local lock_dir="/tmp/sprint-lock-${sprint_id}"
    local retries=0
    while ! mkdir "$lock_dir" 2>/dev/null; do
        retries=$((retries + 1))
        [[ $retries -gt 10 ]] && return 0
        sleep 0.1
    done

    local current
    current=$(bd state "$sprint_id" phase_history 2>/dev/null) || current="{}"
    echo "$current" | jq empty 2>/dev/null || current="{}"

    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local key="${phase}_at"
    local updated
    updated=$(echo "$current" | jq --arg key "$key" --arg ts "$ts" '.[$key] = $ts')

    bd set-state "$sprint_id" "phase_history=$updated" 2>/dev/null || true

    rmdir "$lock_dir" 2>/dev/null || true

    # Invalidate discovery caches so session-start picks up the new phase
    sprint_invalidate_caches
}

# ─── Session Claim ─────────────────────────────────────────────────

# Claim a sprint for this session. Prevents concurrent resume.
# Returns 0 if claimed, 1 if another session holds it.
# NOT fail-safe — returns 1 on conflict so callers can handle gracefully.
# CORRECTNESS: This uses mkdir lock + write-then-verify to serialize claims.
# Two sessions can pass the TTL check simultaneously and race on the write.
# The lock + verify detects the loser, but callers MUST handle claim failure.
sprint_claim() {
    local sprint_id="$1"
    local session_id="$2"

    [[ -z "$sprint_id" || -z "$session_id" ]] && return 0

    # Acquire claim lock to serialize concurrent claim attempts
    local claim_lock="/tmp/sprint-claim-lock-${sprint_id}"
    if ! mkdir "$claim_lock" 2>/dev/null; then
        # Another session is claiming right now — wait briefly then check
        sleep 0.3
        local current_claim
        current_claim=$(bd state "$sprint_id" active_session 2>/dev/null) || current_claim=""
        if [[ "$current_claim" == "$session_id" ]]; then
            return 0  # We already own it
        fi
        echo "Sprint $sprint_id is being claimed by another session" >&2
        return 1
    fi

    # Check for existing claim (under lock)
    local current_claim claim_ts
    current_claim=$(bd state "$sprint_id" active_session 2>/dev/null) || current_claim=""
    claim_ts=$(bd state "$sprint_id" claim_timestamp 2>/dev/null) || claim_ts=""

    if [[ -n "$current_claim" && "$current_claim" != "$session_id" ]]; then
        # Check TTL (60 minutes)
        if [[ -n "$claim_ts" ]]; then
            local claim_epoch now_epoch age_minutes
            claim_epoch=$(date -d "$claim_ts" +%s 2>/dev/null || echo 0)
            now_epoch=$(date +%s)
            age_minutes=$(( (now_epoch - claim_epoch) / 60 ))
            if [[ $age_minutes -lt 60 ]]; then
                echo "Sprint $sprint_id is active in session ${current_claim:0:8} (${age_minutes}m ago)" >&2
                rmdir "$claim_lock" 2>/dev/null || true
                return 1
            fi
            # Expired — take over
        else
            # No timestamp — might be stale. Allow takeover.
            true
        fi
    fi

    # Write claim (under lock — no race possible now)
    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    bd set-state "$sprint_id" "active_session=$session_id" 2>/dev/null || true
    bd set-state "$sprint_id" "claim_timestamp=$ts" 2>/dev/null || true

    # Verify claim
    local verify
    verify=$(bd state "$sprint_id" active_session 2>/dev/null) || verify=""
    rmdir "$claim_lock" 2>/dev/null || true

    if [[ "$verify" != "$session_id" ]]; then
        echo "Failed to claim sprint $sprint_id (write verification failed)" >&2
        return 1
    fi

    return 0
}

# Release sprint claim. Used for manual cleanup or session-end hooks.
sprint_release() {
    local sprint_id="$1"
    [[ -z "$sprint_id" ]] && return 0
    bd set-state "$sprint_id" "active_session=" 2>/dev/null || true
    bd set-state "$sprint_id" "claim_timestamp=" 2>/dev/null || true
}

# ─── Gate Wrapper ──────────────────────────────────────────────────

# Wrapper for check_phase_gate (interphase). Provides enforce_gate API
# that sprint.md references. Returns 0 if gate passes, 1 if blocked.
enforce_gate() {
    local bead_id="$1"
    local target_phase="$2"
    local artifact_path="${3:-}"
    if type check_phase_gate &>/dev/null; then
        check_phase_gate "$bead_id" "$target_phase" "$artifact_path"
    else
        return 0  # No gate library — pass through
    fi
}

# ─── Phase Routing ─────────────────────────────────────────────────

# Determine the next command for a sprint based on its current phase.
# Output: command name (e.g., "brainstorm", "write-plan", "work")
sprint_next_step() {
    local phase="$1"

    case "$phase" in
        ""|brainstorm)           echo "brainstorm" ;;
        brainstorm-reviewed)     echo "strategy" ;;
        strategized)             echo "write-plan" ;;
        planned)                 echo "flux-drive" ;;
        plan-reviewed)           echo "work" ;;
        executing)               echo "work" ;;
        shipping)                echo "ship" ;;
        done)                    echo "done" ;;
        *)                       echo "brainstorm" ;;
    esac
}

# ─── Invalidation ─────────────────────────────────────────────────

# Invalidate discovery caches. Called automatically by sprint_record_phase_completion.
sprint_invalidate_caches() {
    rm -f /tmp/clavain-discovery-brief-*.cache 2>/dev/null || true
}
```

**Step 2: Syntax check**

Run: `bash -n hub/clavain/hooks/lib-sprint.sh`
Expected: No output (clean parse)

**Step 3: Commit**

```bash
git add hub/clavain/hooks/lib-sprint.sh
git commit -m "feat(clavain): add lib-sprint.sh — sprint state library"
```

---

### Task 2: Write lib-sprint.sh Tests

**Files:**
- Create: `hub/clavain/tests/shell/test-lib-sprint.bats`

**Step 1: Write the test file**

Create a BATS test suite covering sprint CRUD, state management, session claims, and phase routing. Key test cases:

1. `sprint_create` returns a valid bead ID
2. `sprint_create` partial init failure cancels bead (mock `bd set-state` to fail on phase=brainstorm)
3. `sprint_finalize_init` sets sprint_initialized=true
4. `sprint_find_active` returns only initialized sprint beads
5. `sprint_find_active` excludes non-sprint beads
6. `sprint_read_state` returns all fields as valid JSON
7. `sprint_read_state` recovers from corrupt JSON (returns defaults)
8. `sprint_set_artifact` updates artifact path under lock
9. `sprint_set_artifact` handles concurrent calls (no data loss — run two in background, verify both keys)
10. `sprint_set_artifact` stale lock cleanup after 5s (create lock dir, backdate mtime via touch -d, verify next call breaks lock)
11. `sprint_record_phase_completion` adds timestamp to history
12. `sprint_record_phase_completion` invalidates discovery caches
13. `sprint_claim` succeeds for first claimer
14. `sprint_claim` blocks second claimer
15. `sprint_claim` allows takeover after TTL expiry (mock timestamp to 61 minutes ago)
16. `sprint_claim` blocks at 59 minutes (not yet expired)
17. `sprint_release` clears claim
18. `sprint_next_step` maps all phases correctly (returns command only, no step number)
19. `sprint_next_step` returns "brainstorm" for unknown phase input
20. `sprint_invalidate_caches` removes cache files
21. `sprint_find_active` returns "[]" when bd not available
22. `sprint_create` returns "" when bd fails
23. `enforce_gate` wrapper delegates to check_phase_gate

Use mock `bd` functions (override in test setup) to avoid requiring a real beads database. Pattern: define `bd()` shell function that records calls and returns test data.

**Step 2: Run tests**

Run: `bats hub/clavain/tests/shell/test-lib-sprint.bats`
Expected: All 16 tests pass

**Step 3: Commit**

```bash
git add hub/clavain/tests/shell/test-lib-sprint.bats
git commit -m "test(clavain): add lib-sprint.sh test suite"
```

---

### Task 3: Modify sprint.md — Sprint Bead Resume

**Files:**
- Modify: `hub/clavain/commands/sprint.md`

**Step 1: Rewrite the "Before Starting" section**

Replace the current discovery flow with sprint-first detection:

```markdown
## Before Starting — Sprint Resume

Before running discovery, check for an active sprint:

1. Source sprint library:
   ```bash
   export SPRINT_LIB_PROJECT_DIR="."; source "${CLAUDE_PLUGIN_ROOT}/hooks/lib-sprint.sh"
   ```

2. Find active sprints:
   ```bash
   sprint_find_active
   ```

3. Parse the result:
   - `[]` → no active sprint, fall through to Work Discovery (below)
   - Single sprint → auto-resume:
     a. Read state: `sprint_read_state "<sprint_id>"`
     b. Claim session: `sprint_claim "<sprint_id>" "$CLAUDE_SESSION_ID"`
        - If claim fails: tell user another session has this sprint, offer to force-claim or start fresh
     c. Set `CLAVAIN_BEAD_ID` for backward compat
     d. Determine next step: `sprint_next_step "<phase>"`
     e. Route to the appropriate command based on the step
     f. Display: `Resuming sprint <id> — <title> (phase: <phase>, next: <step>)`
   - Multiple sprints → AskUserQuestion to choose which to resume, plus "Start fresh" option

4. If starting fresh (no active sprint or user chose "Start fresh"):
   Proceed to existing Work Discovery logic below.
```

**Step 2: Add sprint bead creation to Step 1 (Brainstorm)**

After the brainstorm command, if no sprint bead exists yet:

```markdown
### Create Sprint Bead

If `CLAVAIN_BEAD_ID` is not set after brainstorm:

```bash
export SPRINT_LIB_PROJECT_DIR="."; source "${CLAUDE_PLUGIN_ROOT}/hooks/lib-sprint.sh"
SPRINT_ID=$(sprint_create "<feature title>")
if [[ -n "$SPRINT_ID" ]]; then
    sprint_set_artifact "$SPRINT_ID" "brainstorm" "<brainstorm_doc_path>"
    sprint_finalize_init "$SPRINT_ID"
    sprint_record_phase_completion "$SPRINT_ID" "brainstorm"
    CLAVAIN_BEAD_ID="$SPRINT_ID"
fi
```
```

**Step 3: Update phase tracking calls**

Each step that records a phase transition should also:
1. Call `sprint_set_artifact()` when an artifact is created
2. Call `sprint_record_phase_completion()` after phase advances
3. Call `sprint_invalidate_caches()` after phase advances

**Step 4: Verify syntax**

Read the modified sprint.md and verify all bash code blocks have matching ``` delimiters and reference the correct function names from lib-sprint.sh.

**Step 5: Commit**

```bash
git add hub/clavain/commands/sprint.md
git commit -m "feat(clavain): rewrite sprint.md for bead-first resume"
```

---

### Task 4: Modify strategy.md — Sprint-Aware Feature Beads

**Files:**
- Modify: `hub/clavain/commands/strategy.md`

**Step 1: Add sprint detection**

At the top of Phase 3 (Create Beads), add sprint awareness:

```markdown
### Phase 3: Create Beads

**Sprint-aware bead creation:**

If `CLAVAIN_BEAD_ID` is set (we're inside a sprint):
- Do NOT create a separate epic. The sprint bead IS the epic.
- Create feature beads as children of the sprint bead:
  ```bash
  bd create --title="F1: <feature name>" --type=feature --priority=2
  bd dep add <feature-id> <CLAVAIN_BEAD_ID>
  ```
- Update sprint state:
  ```bash
  source "${CLAUDE_PLUGIN_ROOT}/hooks/lib-sprint.sh"
  sprint_set_artifact "$CLAVAIN_BEAD_ID" "prd" "<prd_path>"
  ```

If `CLAVAIN_BEAD_ID` is NOT set (standalone strategy):
- Create epic and feature beads as before (existing behavior).
```

**Step 2: Record phase on sprint bead**

Update Phase 3b to use the sprint bead ID (not a separate epic):

```markdown
### Phase 3b: Record Phase

After creating beads, record the phase transition:
```bash
export GATES_PROJECT_DIR="."; source "${CLAUDE_PLUGIN_ROOT}/hooks/lib-gates.sh"
if [[ -n "${CLAVAIN_BEAD_ID:-}" ]]; then
    advance_phase "$CLAVAIN_BEAD_ID" "strategized" "PRD: <prd_path>" ""
    source "${CLAUDE_PLUGIN_ROOT}/hooks/lib-sprint.sh"
    sprint_record_phase_completion "$CLAVAIN_BEAD_ID" "strategized"
    sprint_invalidate_caches
else
    # Standalone strategy — use the epic bead
    advance_phase "<epic_bead_id>" "strategized" "PRD: <prd_path>" ""
fi
```
```

**Step 3: Commit**

```bash
git add hub/clavain/commands/strategy.md
git commit -m "feat(clavain): make strategy.md sprint-aware (use sprint bead as epic)"
```

---

### Task 5: Modify session-start.sh — Sprint Resume Hint

**Files:**
- Modify: `hub/clavain/hooks/session-start.sh`

**Step 1: Add sprint detection after discovery scan**

After the existing `discovery_brief_scan` block (line ~184), add sprint detection:

```bash
# Sprint bead detection (active sprint resume hint)
sprint_resume_hint=""
source "${SCRIPT_DIR}/lib-sprint.sh" 2>/dev/null || true
if type sprint_find_active &>/dev/null; then
    export SPRINT_LIB_PROJECT_DIR="."
    active_sprints=$(sprint_find_active 2>/dev/null) || active_sprints="[]"
    sprint_count=$(echo "$active_sprints" | jq 'length' 2>/dev/null) || sprint_count=0
    if [[ "$sprint_count" -gt 0 ]]; then
        top_sprint=$(echo "$active_sprints" | jq '.[0]')
        top_id=$(echo "$top_sprint" | jq -r '.id')
        top_title=$(echo "$top_sprint" | jq -r '.title')
        top_phase=$(echo "$top_sprint" | jq -r '.phase')
        next_step=$(sprint_next_step "$top_phase" 2>/dev/null) || next_step="unknown"
        sprint_resume_hint="\\n• Active sprint: ${top_id} — ${top_title} (phase: ${top_phase}, next: ${next_step}). Resume with /sprint or /sprint ${top_id}"
        sprint_resume_hint=$(escape_for_json "$sprint_resume_hint")
    fi
fi
```

**Step 2: Include sprint hint in additionalContext**

Add `${sprint_resume_hint}` to the output JSON template, after `${discovery_context}`:

```bash
"additionalContext": "...${discovery_context}${sprint_resume_hint}${handoff_context}..."
```

**Step 3: Syntax check**

Run: `bash -n hub/clavain/hooks/session-start.sh`
Expected: No output (clean parse)

**Step 4: Commit**

```bash
git add hub/clavain/hooks/session-start.sh
git commit -m "feat(clavain): add sprint resume hint to SessionStart hook"
```

---

### Task 6: Modify sprint-scan.sh — Sprint Progress Section

**Files:**
- Modify: `hub/clavain/hooks/sprint-scan.sh`

**Step 1: Add sprint progress to sprint_full_scan**

After the "Session Continuity" section, add a new "Active Sprints" section:

```bash
# 1.5. Active Sprints
echo "## Active Sprints"
source "${SCRIPT_DIR}/lib-sprint.sh" 2>/dev/null || true
if type sprint_find_active &>/dev/null; then
    export SPRINT_LIB_PROJECT_DIR="$SPRINT_PROJECT_DIR"
    local active_sprints
    active_sprints=$(sprint_find_active 2>/dev/null) || active_sprints="[]"
    local sprint_count
    sprint_count=$(echo "$active_sprints" | jq 'length' 2>/dev/null) || sprint_count=0

    if [[ "$sprint_count" -gt 0 ]]; then
        local s=0
        while [[ $s -lt $sprint_count ]]; do
            local sid stitle sphase
            sid=$(echo "$active_sprints" | jq -r ".[$s].id")
            stitle=$(echo "$active_sprints" | jq -r ".[$s].title")
            sphase=$(echo "$active_sprints" | jq -r ".[$s].phase")

            # Build progress bar
            local phases=("brainstorm" "strategized" "planned" "plan-reviewed" "executing" "shipping" "done")
            local bar=""
            local found_current=0
            for p in "${phases[@]}"; do
                if [[ $found_current -eq 1 ]]; then
                    bar="${bar} [${p} ○]"
                elif [[ "$p" == "$sphase" ]]; then
                    bar="${bar} [${p} ▶]"
                    found_current=1
                else
                    bar="${bar} [${p} ✓]"
                fi
            done

            # Read artifacts
            local state
            state=$(sprint_read_state "$sid" 2>/dev/null) || state="{}"
            local brainstorm_path prd_path plan_path
            brainstorm_path=$(echo "$state" | jq -r '.artifacts.brainstorm // ""')
            prd_path=$(echo "$state" | jq -r '.artifacts.prd // ""')
            plan_path=$(echo "$state" | jq -r '.artifacts.plan // ""')
            local active_session
            active_session=$(echo "$state" | jq -r '.active_session // ""')

            echo "${sid}: ${stitle}"
            echo "  Progress:${bar}"
            [[ -n "$brainstorm_path" ]] && echo "  Brainstorm: ${brainstorm_path}"
            [[ -n "$prd_path" ]] && echo "  PRD: ${prd_path}"
            [[ -n "$plan_path" ]] && echo "  Plan: ${plan_path}"
            [[ -n "$active_session" ]] && echo "  Claimed by session: ${active_session:0:8}"

            s=$((s + 1))
        done
    else
        echo "No active sprints"
    fi
else
    echo "Sprint library not available"
fi
echo ""
```

**Step 2: Add sprint hint to sprint_brief_scan**

After the coordination check, add:

```bash
# Active sprint resume hint
if type sprint_find_active &>/dev/null; then
    export SPRINT_LIB_PROJECT_DIR="$SPRINT_PROJECT_DIR"
    local active_sprints
    active_sprints=$(sprint_find_active 2>/dev/null) || active_sprints="[]"
    local sprint_count
    sprint_count=$(echo "$active_sprints" | jq 'length' 2>/dev/null) || sprint_count=0
    if [[ "$sprint_count" -gt 0 ]]; then
        local top_id top_title top_phase
        top_id=$(echo "$active_sprints" | jq -r '.[0].id')
        top_title=$(echo "$active_sprints" | jq -r '.[0].title')
        top_phase=$(echo "$active_sprints" | jq -r '.[0].phase')
        local next_step
        next_step=$(sprint_next_step "$top_phase" 2>/dev/null) || next_step="unknown"
        signals="${signals}• Active sprint: ${top_id} — ${top_title} (phase: ${top_phase}, next: ${next_step})\n"
    fi
fi
```

**Step 3: Syntax check**

Run: `bash -n hub/clavain/hooks/sprint-scan.sh`
Expected: Clean parse

**Step 4: Commit**

```bash
git add hub/clavain/hooks/sprint-scan.sh
git commit -m "feat(clavain): add sprint progress to sprint-scan.sh"
```

---

### Task 7: Update sprint-status.md — Sprint-Aware Output

**Files:**
- Modify: `hub/clavain/commands/sprint-status.md`

**Step 1: Add sprint section reference**

The sprint-status command delegates to `sprint_full_scan()` in sprint-scan.sh. Since we modified that function in Task 6, the sprint status output is already enhanced. However, update the SKILL.md to document the new "Active Sprints" section:

Add after "### 1. Session Continuity":

```markdown
### 1.5. Active Sprints
Shows sprint beads in progress with progress bars, artifact links, and session claims. Uses `lib-sprint.sh` to read sprint state from beads.
```

**Step 2: Commit**

```bash
git add hub/clavain/commands/sprint-status.md
git commit -m "docs(clavain): document Active Sprints section in sprint-status"
```

---

### Task 8: Update CLAUDE.md — Add lib-sprint.sh to Quick Commands

**Files:**
- Modify: `hub/clavain/CLAUDE.md`

**Step 1: Add syntax check**

Add to the Quick Commands section:

```bash
bash -n hooks/lib-sprint.sh             # Syntax check (sprint state library)
```

**Step 2: Commit**

```bash
git add hub/clavain/CLAUDE.md
git commit -m "docs(clavain): add lib-sprint.sh to quick commands"
```

---

### Task 9: Integration Test — End-to-End Sprint Resume

**Files:**
- Create: `hub/clavain/tests/shell/test-sprint-resume.bats`

**Step 1: Write integration test**

Test the full flow:

1. `sprint_create "Test Feature"` → returns valid ID
2. `sprint_finalize_init` → sets initialized
3. `sprint_set_artifact $id brainstorm "docs/brainstorms/test.md"` → updates state
4. `sprint_find_active` → returns the sprint
5. `sprint_read_state $id` → returns all fields correctly
6. `sprint_claim $id session1` → succeeds
7. `sprint_claim $id session2` → fails (another session holds it)
8. `sprint_release $id` → clears claim
9. `sprint_claim $id session2` → now succeeds
10. `sprint_next_step brainstorm` → returns "brainstorm"
11. `sprint_next_step strategized` → returns "write-plan"
12. `sprint_next_step plan-reviewed` → returns "work"

**Step 2: Run tests**

Run: `bats hub/clavain/tests/shell/test-sprint-resume.bats`
Expected: All pass

**Step 3: Commit**

```bash
git add hub/clavain/tests/shell/test-sprint-resume.bats
git commit -m "test(clavain): add sprint resume integration tests"
```

---

### Task 10: Interline Statusline Update

**Files:**
- Modify: `hub/clavain/hooks/lib-sprint.sh` (add statusline update)

**Step 1: Update statusline state on phase advance**

The interphase `_gate_update_statusline()` already writes `/tmp/clavain-bead-${session_id}.json` for the statusline. Ensure `sprint_record_phase_completion()` also calls `sprint_invalidate_caches()` and triggers the statusline update by calling `advance_phase()` (which already does this).

Verify that the existing interline statusline renderer reads the bead state file and can display sprint context. The interphase `_gate_update_statusline()` writes `{id, phase, reason, ts}` — this is sufficient for the statusline to show `[sprint: <id> | <phase>]`.

**Step 2: Commit (if changes needed)**

```bash
git add hub/clavain/hooks/lib-sprint.sh
git commit -m "feat(clavain): ensure statusline updates on sprint phase changes"
```

---

### Verification Checklist

After all tasks are complete:

- [ ] `bash -n hub/clavain/hooks/lib-sprint.sh` — clean parse
- [ ] `bash -n hub/clavain/hooks/session-start.sh` — clean parse
- [ ] `bash -n hub/clavain/hooks/sprint-scan.sh` — clean parse
- [ ] `bats hub/clavain/tests/shell/test-lib-sprint.bats` — all pass
- [ ] `bats hub/clavain/tests/shell/test-sprint-resume.bats` — all pass
- [ ] `python3 -c "import json; json.load(open('.claude-plugin/plugin.json'))"` — manifest valid
- [ ] Manually test: `source hooks/lib-sprint.sh && sprint_create "test" && sprint_find_active`
