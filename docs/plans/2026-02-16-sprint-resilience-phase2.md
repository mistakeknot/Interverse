# Sprint Resilience Phase 2: Autonomy Layer

> **For Claude:** REQUIRED SUB-SKILL: Use clavain:executing-plans to implement this plan task-by-task.

**Bead:** iv-h0dr (anchor), related: iv-5si3, iv-cu5w, iv-jv5f, iv-glxa
**Phase:** executing (as of 2026-02-16T02:31:55Z)
**PRD:** docs/prds/2026-02-15-sprint-resilience.md
**Phase 1 Plan:** docs/plans/2026-02-15-sprint-resilience-phase1.md
**Goal:** Make sprints autonomous — auto-advance between phases without user prompts, classify complexity to adjust brainstorm depth, and close remaining F1/F4/F5 gaps.

**Architecture:** New functions in existing `lib-sprint.sh`. Modified skill markdown files (sprint.md, brainstorm.md, strategy.md). No new files except tests.

**Tech Stack:** Bash (lib-sprint.sh), Markdown (commands), jq (JSON), BATS (tests)

**Review fixes applied:** Architecture (3 issues), Correctness (3 blockers), Quality (3 blockers) — see docs/research/

**Fixes incorporated:**
1. Added `mkdir` lock to `sprint_advance()` for atomic read-check-write (correctness)
2. Replaced bash ternary `$((x > 2 ? 1 : 0))` with explicit if/else (correctness)
3. Replaced `grep -E '\b'` with POSIX `awk` in complexity classifier (quality/portability)
4. Added 5-word minimum guard to complexity classifier (quality)
5. Structured pause reasons as `type|phase|detail` (architecture)
6. Status messages to stderr, data to stdout in `sprint_advance()` (correctness)
7. Handoff sections check `sprint=true` state, not just `CLAVAIN_BEAD_ID` set (architecture)
8. Refactored `sprint_next_step()` to derive from `_sprint_transition_table()` (architecture/dedup)
9. Added stale-phase guard in `sprint_advance()` (correctness)
10. Added sprint bead validation before auto-advance in sprint.md (architecture)

**What Phase 1 Already Shipped:**
- `lib-sprint.sh`: sprint_create, sprint_finalize_init, sprint_find_active, sprint_read_state, sprint_set_artifact, sprint_record_phase_completion, sprint_claim, sprint_release, enforce_gate, sprint_next_step, sprint_invalidate_caches
- `sprint.md`: Sprint Resume section, sprint bead creation after brainstorm, phase tracking calls
- `strategy.md`: Sprint-aware bead creation (uses sprint bead as epic)
- `session-start.sh`: Sprint resume hint injection
- `sprint-scan.sh`: Sprint progress bars in full and brief scans
- 23 BATS tests for lib-sprint.sh

**What Phase 2 Adds:**
- F2: `sprint_should_pause()` and `sprint_advance()` in lib-sprint.sh + remove "what next?" prompts from brainstorm.md, strategy.md
- F3: `sprint_classify_complexity()` in lib-sprint.sh + tiered routing in brainstorm.md
- F1/F4/F5 gaps: Minor wiring (strategy uses sprint bead as epic already; validate remaining ACs)

---

### Task 1: Add Auto-Advance Functions to lib-sprint.sh

**Files:**
- Modify: `hub/clavain/hooks/lib-sprint.sh`

**Step 1: Add strict phase transition table**

After the existing `sprint_next_step()` function, add:

```bash
# ─── Auto-Advance (Phase 2) ──────────────────────────────────────

# Strict phase transition table. Returns the NEXT phase given the CURRENT phase.
# Every phase has exactly one successor. No skip paths.
_sprint_transition_table() {
    local current="$1"
    case "$current" in
        brainstorm)          echo "brainstorm-reviewed" ;;
        brainstorm-reviewed) echo "strategized" ;;
        strategized)         echo "planned" ;;
        planned)             echo "plan-reviewed" ;;
        plan-reviewed)       echo "executing" ;;
        executing)           echo "shipping" ;;
        shipping)            echo "done" ;;
        done)                echo "done" ;;
        *)                   echo "" ;;
    esac
}
```

**Step 2: Add `sprint_should_pause()`**

```bash
# Check if sprint should pause before advancing to target_phase.
# RETURN CONVENTION (intentionally inverted for ergonomic reason-reporting):
#   Returns 0 WITH PAUSE REASON ON STDOUT if pause trigger found.
#   Returns 1 (no output) if should continue.
# Usage: pause_reason=$(sprint_should_pause ...) && { handle pause }
# Pause triggers: manual override (auto_advance=false), gate failure.
sprint_should_pause() {
    local sprint_id="$1"
    local target_phase="$2"

    [[ -z "$sprint_id" || -z "$target_phase" ]] && return 1

    # Manual override: auto_advance=false pauses at every transition
    local auto_advance
    auto_advance=$(bd state "$sprint_id" auto_advance 2>/dev/null) || auto_advance="true"
    if [[ "$auto_advance" == "false" ]]; then
        echo "manual_pause|$target_phase|auto_advance=false"
        return 0
    fi

    # Gate failure check: if enforce_gate would block, pause
    if ! enforce_gate "$sprint_id" "$target_phase" "" 2>/dev/null; then
        echo "gate_blocked|$target_phase|Gate prerequisites not met"
        return 0
    fi

    # No pause trigger — continue
    return 1
}
```

**Step 3: Add `sprint_advance()`**

```bash
# Advance sprint to the next phase. Uses strict transition table.
# If should_pause triggers, returns 1 with pause reason on stdout.
# Otherwise advances and returns 0. Status messages go to stderr.
# CORRECTNESS: Uses mkdir lock to serialize concurrent advance attempts.
sprint_advance() {
    local sprint_id="$1"
    local current_phase="$2"
    local artifact_path="${3:-}"

    [[ -z "$sprint_id" || -z "$current_phase" ]] && return 1

    local next_phase
    next_phase=$(_sprint_transition_table "$current_phase")
    [[ -z "$next_phase" || "$next_phase" == "$current_phase" ]] && return 1

    # Acquire lock for atomic read-check-write (same pattern as sprint_set_artifact)
    local lock_dir="/tmp/sprint-advance-lock-${sprint_id}"
    local retries=0
    while ! mkdir "$lock_dir" 2>/dev/null; do
        retries=$((retries + 1))
        [[ $retries -gt 10 ]] && {
            # Force-break stale lock (>5s old)
            local lock_mtime
            lock_mtime=$(stat -c %Y "$lock_dir" 2>/dev/null) || { rmdir "$lock_dir" 2>/dev/null; return 1; }
            local now; now=$(date +%s)
            if [[ $((now - lock_mtime)) -gt 5 ]]; then
                rmdir "$lock_dir" 2>/dev/null || rm -rf "$lock_dir" 2>/dev/null || true
                mkdir "$lock_dir" 2>/dev/null || return 1
                break
            fi
            return 1
        }
        sleep 0.1
    done

    # Check pause triggers (under lock)
    local pause_reason
    pause_reason=$(sprint_should_pause "$sprint_id" "$next_phase" 2>/dev/null) && {
        rmdir "$lock_dir" 2>/dev/null || true
        echo "$pause_reason"
        return 1
    }

    # Verify current phase hasn't changed (guard against concurrent advance)
    local actual_phase
    actual_phase=$(bd state "$sprint_id" phase 2>/dev/null) || actual_phase=""
    if [[ -n "$actual_phase" && "$actual_phase" != "$current_phase" ]]; then
        rmdir "$lock_dir" 2>/dev/null || true
        echo "stale_phase|$current_phase|Phase already advanced to $actual_phase"
        return 1
    fi

    # Advance: set phase on bead, record completion, invalidate caches
    bd set-state "$sprint_id" "phase=$next_phase" 2>/dev/null || true
    sprint_record_phase_completion "$sprint_id" "$next_phase"

    rmdir "$lock_dir" 2>/dev/null || true

    # Log transition (stderr — stdout reserved for data/error reasons)
    echo "Phase: $current_phase → $next_phase (auto-advancing)" >&2
    return 0
}
```

**Step 4: Refactor sprint_next_step to use transition table**

Replace the existing `sprint_next_step()` function (lines ~386-400) with a version derived from the transition table. This eliminates the duplication where both functions encode the phase sequence independently.

```bash
# Determine the next command for a sprint based on its current phase.
# Output: command name (e.g., "brainstorm", "write-plan", "work")
# CORRECTNESS: This derives from _sprint_transition_table so the phase
# sequence is defined in one place. If phases change, update only the table.
sprint_next_step() {
    local phase="$1"
    local next_phase
    next_phase=$(_sprint_transition_table "$phase")

    # Map next-phase to command name
    case "$next_phase" in
        brainstorm-reviewed) echo "strategy" ;;
        strategized)         echo "write-plan" ;;
        planned)             echo "flux-drive" ;;
        plan-reviewed|executing) echo "work" ;;
        shipping)            echo "ship" ;;
        done)                echo "done" ;;
        "")                  echo "brainstorm" ;;  # Unknown → start from beginning
        *)                   echo "brainstorm" ;;
    esac
}
```

Note: `sprint_next_step` must be defined AFTER `_sprint_transition_table` in the file. Move it after the transition table function.

**Step 5: Add jq stubs for new functions**

In the `if ! command -v jq` block at the top, add stubs:

```bash
    sprint_should_pause() { return 1; }
    sprint_advance() { return 1; }
    sprint_classify_complexity() { echo "medium"; }
```

**Step 5: Syntax check**

Run: `bash -n hub/clavain/hooks/lib-sprint.sh`

---

### Task 2: Add Tiered Brainstorming Classification to lib-sprint.sh

**Files:**
- Modify: `hub/clavain/hooks/lib-sprint.sh`

**Step 1: Add `sprint_classify_complexity()`**

After the auto-advance functions, add:

```bash
# ─── Tiered Brainstorming (Phase 3 of PRD, but implemented here) ──

# Classify feature complexity from description text.
# Output: "simple" | "medium" | "complex"
# Heuristics:
#   - Word count: <30 = simple, 30-100 = medium, >100 = complex
#   - Ambiguity signals: "or", "vs", "alternative", "tradeoff" → bump up
#   - Pattern references: "like X", "similar to", "existing" → bump down
#   - Override: if sprint has complexity state set, use that
sprint_classify_complexity() {
    local sprint_id="${1:-}"
    local description="${2:-}"

    # Check for manual override on sprint bead
    if [[ -n "$sprint_id" ]]; then
        local override
        override=$(bd state "$sprint_id" complexity 2>/dev/null) || override=""
        if [[ -n "$override" && "$override" != "null" ]]; then
            echo "$override"
            return 0
        fi
    fi

    [[ -z "$description" ]] && { echo "medium"; return 0; }

    # Word count
    local word_count
    word_count=$(echo "$description" | wc -w | tr -d ' ')

    # Vacuous descriptions (<5 words) are too short to classify
    if [[ $word_count -lt 5 ]]; then
        echo "medium"
        return 0
    fi

    # Ambiguity signals (awk for POSIX portability — no GNU grep \b needed)
    local ambiguity_count
    ambiguity_count=$(echo "$description" | awk -v IGNORECASE=1 '
        BEGIN { count=0 }
        {
            for (i=1; i<=NF; i++) {
                word = $i
                gsub(/[^a-zA-Z-]/, "", word)
                if (word ~ /^(or|vs|versus|alternative|tradeoff|trade-off|either|approach|option)$/) count++
            }
        }
        END { print count }
    ')

    # Simplicity signals
    local simplicity_count
    simplicity_count=$(echo "$description" | awk -v IGNORECASE=1 '
        BEGIN { count=0 }
        {
            for (i=1; i<=NF; i++) {
                word = $i
                gsub(/[^a-zA-Z-]/, "", word)
                if (word ~ /^(like|similar|existing|just|simple|straightforward)$/) count++
            }
        }
        END { print count }
    ')

    # Score: start with word-count tier, adjust with signals
    local score=0
    if [[ $word_count -lt 30 ]]; then
        score=1  # simple
    elif [[ $word_count -lt 100 ]]; then
        score=2  # medium
    else
        score=3  # complex
    fi

    # Adjust (explicit if/else — bash doesn't support ternary in arithmetic)
    if [[ $ambiguity_count -gt 2 ]]; then
        score=$((score + 1))
    fi
    if [[ $simplicity_count -gt 2 ]]; then
        score=$((score - 1))
    fi

    # Clamp and map
    [[ $score -le 1 ]] && { echo "simple"; return 0; }
    [[ $score -ge 3 ]] && { echo "complex"; return 0; }
    echo "medium"
}
```

**Step 2: Syntax check**

Run: `bash -n hub/clavain/hooks/lib-sprint.sh`

---

### Task 3: Remove "What Next?" Prompts from brainstorm.md

**Files:**
- Modify: `hub/clavain/commands/brainstorm.md`

**Step 1: Remove Phase 4 handoff question**

Replace the Phase 4 section with an auto-advance note. The brainstorm command should NOT ask "what next?" when inside a sprint — it should just complete and let sprint.md handle the flow.

Find the Phase 4 section (lines ~91-101 of brainstorm.md) that says:
```markdown
### Phase 4: Handoff

Use **AskUserQuestion tool** to present next steps:

**Question:** "Brainstorm captured. What would you like to do next?"

**Options:**
1. **Proceed to planning** - Run `/clavain:write-plan` (will auto-detect this brainstorm)
2. **Refine design further** - Continue exploring
3. **Done for now** - Return later
```

Replace with:
```markdown
### Phase 4: Handoff

**If inside a sprint** (check: `bd state "$CLAVAIN_BEAD_ID" sprint` returns `"true"`):
- Skip the handoff question. Sprint auto-advance handles the next step.
- Display the output summary (below) and return to the caller.

**If standalone** (no sprint context):
Use **AskUserQuestion tool** to present next steps:

**Question:** "Brainstorm captured. What would you like to do next?"

**Options:**
1. **Proceed to planning** - Run `/clavain:write-plan` (will auto-detect this brainstorm)
2. **Refine design further** - Continue exploring
3. **Done for now** - Return later
```

---

### Task 4: Remove "What Next?" Prompt from strategy.md

**Files:**
- Modify: `hub/clavain/commands/strategy.md`

**Step 1: Make Phase 5 sprint-aware**

Find the Phase 5 section (~line 132-143) that asks "Strategy complete. What's next?"

Replace with:
```markdown
## Phase 5: Handoff

**If inside a sprint** (check: `bd state "$CLAVAIN_BEAD_ID" sprint` returns `"true"`):
- Skip the handoff question. Sprint auto-advance handles the next step.
- Display the output summary (below) and return to the caller.

**If standalone** (no sprint context):
Present next steps with AskUserQuestion:

> "Strategy complete. What's next?"

Options:
1. **Plan the first feature** — Run `/clavain:write-plan` for the highest-priority unblocked bead
2. **Plan all features** — Run `/clavain:write-plan` for each feature sequentially
3. **Refine PRD** — Address flux-drive findings first
4. **Done for now** — Come back later
```

---

### Task 5: Add Tiered Brainstorming to brainstorm.md

**Files:**
- Modify: `hub/clavain/commands/brainstorm.md`

**Step 1: Add complexity classification before Phase 1**

After Phase 0 (Assess Requirements Clarity) and before Phase 1 (Understand the Idea), add:

```markdown
### Phase 0.5: Complexity Classification (Sprint Only)

If inside a sprint (`CLAVAIN_BEAD_ID` is set):

```bash
export SPRINT_LIB_PROJECT_DIR="."; source "${CLAUDE_PLUGIN_ROOT}/hooks/lib-sprint.sh"
complexity=$(sprint_classify_complexity "$CLAVAIN_BEAD_ID" "<feature_description>")
```

Route based on complexity:

- **Simple** (`complexity == "simple"`): Skip Phase 1 collaborative dialogue. Do a brief repo scan, then present ONE consolidated AskUserQuestion confirming the approach. Proceed directly to Phase 3 (Capture).
- **Medium** (`complexity == "medium"`): Do Phase 1 repo scan, propose 2-3 approaches (Phase 2), ask ONE question to choose. Proceed to Phase 3.
- **Complex** (`complexity == "complex"`): Full dialogue — run all phases as normal.

**Invariant:** Even simple features get exactly one question. Never zero.

If NOT inside a sprint: skip classification, run all phases as normal (existing behavior).
```

---

### Task 6: Update sprint.md Auto-Advance Integration

**Files:**
- Modify: `hub/clavain/commands/sprint.md`

**Step 1: Add auto-advance between steps**

After the Phase Tracking section (~line 114-126), add an auto-advance preamble:

```markdown
### Auto-Advance Protocol

When transitioning between steps, use auto-advance instead of manual routing:

```bash
export SPRINT_LIB_PROJECT_DIR="."; source "${CLAUDE_PLUGIN_ROOT}/hooks/lib-sprint.sh"
# Validate sprint bead before advancing
is_sprint=$(bd state "$CLAVAIN_BEAD_ID" sprint 2>/dev/null) || is_sprint=""
if [[ "$is_sprint" != "true" ]]; then
    echo "Warning: CLAVAIN_BEAD_ID is not a sprint bead. Skipping auto-advance."
    # Fall back to manual handoff
fi

pause_reason=$(sprint_advance "$CLAVAIN_BEAD_ID" "<current_phase>" "<artifact_path>")
if [[ $? -ne 0 ]]; then
    # Parse structured pause reason: type|phase|detail
    reason_type="${pause_reason%%|*}"
    case "$reason_type" in
        gate_blocked)
            # AskUserQuestion: "Gate blocked for <phase>. Options: Fix issues first, Skip gate (override), Stop sprint"
            ;;
        manual_pause)
            # AskUserQuestion: "Sprint paused (auto_advance=false). Options: Continue, Stop sprint"
            ;;
        stale_phase)
            # Another session already advanced — re-read state and continue from new phase
            ;;
    esac
fi
```

**Status messages:** At each auto-advance, display:
`Phase: <current> → <next> (auto-advancing)`

**No "what next?" prompts between steps.** Sprint proceeds automatically unless:
1. `sprint_should_pause()` returns a pause trigger
2. A step fails (test failure, gate block)
3. User set `auto_advance=false` on the sprint bead
```

**Step 2: Remove implicit "proceed?" pauses**

Review each step boundary (Step 1→2, 2→3, etc.) and ensure there's no implicit "should I continue?" — the sprint auto-advances. The individual skill commands (brainstorm, strategy) handle their own handoff questions only when NOT in a sprint (per Tasks 3-4).

---

### Task 7: Write Tests for Phase 2 Functions

**Files:**
- Modify: `hub/clavain/tests/shell/test_lib_sprint.bats`

**Step 1: Add tests for new functions**

Append these test cases to the existing test file:

1. `_sprint_transition_table maps all phases correctly` — verify each phase→next mapping
2. `_sprint_transition_table returns empty for unknown phase` — returns ""
3. `_sprint_transition_table done→done (terminal)` — done maps to done
4. `sprint_should_pause returns 1 when auto_advance=true` — no pause
5. `sprint_should_pause returns 0 when auto_advance=false` — manual pause
6. `sprint_should_pause returns 0 when gate blocks` — gate failure pause
7. `sprint_advance succeeds and advances phase` — happy path
8. `sprint_advance pauses on manual override` — returns 1 + reason
9. `sprint_advance returns 1 for unknown phase` — no transition available
10. `sprint_classify_complexity returns simple for short descriptions`
11. `sprint_classify_complexity returns complex for long descriptions with ambiguity`
12. `sprint_classify_complexity respects manual override on bead`
13. `sprint_classify_complexity returns medium for empty description`
14. `sprint_classify_complexity respects simplicity signals`
15. `sprint_classify_complexity vacuous (<5 words) returns medium`
16. `sprint_classify_complexity boundary: exactly 30 words = medium`
17. `sprint_advance rejects terminal→terminal (done→done)`

Mock `bd` as per existing test patterns. Use the same `_source_sprint_lib` helper.

**Step 2: Run tests**

Run: `bats hub/clavain/tests/shell/test_lib_sprint.bats`
Expected: All 40 tests pass (23 existing + 17 new)

---

### Task 8: Validate F1/F4/F5 Acceptance Criteria (Gap Check)

**Files:**
- No modifications expected — this is a validation task

**Step 1: Audit F1 (Sprint Bead Lifecycle) ACs**

Check each criterion from PRD lines 55-63 against existing code:
- [x] `/sprint "feature desc"` creates a sprint bead → sprint.md "Create Sprint Bead" section
- [x] Sprint bead state includes all fields → sprint_create() sets them
- [x] `sprint_artifacts` updated via `sprint_set_artifact()` → existing function
- [x] `/sprint` with existing sprint resumes → sprint.md "Sprint Resume" section
- [x] `/strategy` inside sprint adds features to sprint bead → strategy.md Phase 3
- [x] Session claim with 60-min TTL → sprint_claim() implemented
- [ ] Legacy beads reparented → **Not implemented. Create separate task if needed.**
- [x] Sprint logic in lib-sprint.sh → existing file

**Step 2: Audit F4 (Session-Resilient Resume) ACs**

Check PRD lines 69-78:
- [x] `sprint_find_active()` → implemented
- [x] SessionStart injects resume hint → session-start.sh lines 186-203
- [x] `/sprint` with no args auto-resumes single active sprint → sprint.md Sprint Resume
- [x] Multiple sprints → AskUserQuestion → sprint.md Sprint Resume
- [x] `/sprint <bead-id>` resumes from phase → sprint.md argument handling
- [x] `sprint_read_state()` → implemented
- [x] Artifact paths from bead state → sprint_read_state().artifacts
- [x] Discovery cache invalidated on advance_phase → sprint_invalidate_caches
- [x] CLAVAIN_BEAD_ID for backward compat → sprint.md sets it

**Step 3: Audit F5 (Sprint Status Visibility) ACs**

Check PRD lines 83-88:
- [x] Statusline shows sprint context → session-start.sh sprint_resume_hint
- [x] `/sprint-status` shows sprint section → sprint-scan.sh sprint_full_scan
- [x] Progress bar → sprint-scan.sh (✓/▶/○ symbols)
- [x] Artifact links shown → sprint_read_state in sprint-scan.sh
- [x] Active session shown → sprint-scan.sh

**Step 4: Report gaps**

If any acceptance criteria are NOT met, note them. The only expected gap is the "legacy beads reparented" criterion from F1, which is a separate task (low priority).

---

### Task 9: Final Validation

**Files:**
- No modifications

**Step 1: Run all Clavain tests**

```bash
bats hub/clavain/tests/shell/
```

Expected: All tests pass (including the 17 new ones from Task 7).

**Step 2: Syntax check all modified files**

```bash
bash -n hub/clavain/hooks/lib-sprint.sh
```

**Step 3: Run the full test suite**

```bash
bats hub/clavain/tests/shell/test_lib_sprint.bats
```

Expected: 40 tests, 0 failures.

---

### Verification Checklist

- [ ] `bash -n hub/clavain/hooks/lib-sprint.sh` — clean parse
- [ ] `bats hub/clavain/tests/shell/test_lib_sprint.bats` — 40 tests pass
- [ ] `bats hub/clavain/tests/shell/` — all Clavain tests pass
- [ ] brainstorm.md Phase 4 is sprint-aware (no prompt in sprint context)
- [ ] strategy.md Phase 5 is sprint-aware (no prompt in sprint context)
- [ ] brainstorm.md has complexity classification routing
- [ ] sprint.md has auto-advance protocol section
- [ ] F1/F4/F5 acceptance criteria verified (only legacy reparenting deferred)
