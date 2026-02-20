# Cost-Aware Agent Scheduling — Implementation Plan
**Bead:** iv-pbmc | **Sprint:** iv-suzr
**Phase:** planned (as of 2026-02-20T17:05:55Z)

> **For Claude:** REQUIRED SUB-SKILL: Use clavain:executing-plans to implement this plan task-by-task.

**Goal:** Make token spend a first-class sprint resource — trackable at phase granularity, enforceable at sprint advance, visible to flux-drive triage.

**Architecture:** Extend 3 existing systems: lib-sprint.sh (budget parameter + advance check + writeback), lib-intercore.sh (pass --token-budget to ic run create), flux-drive SKILL-compact.md (read sprint budget via env var). No new modules, hooks, or databases.

**Tech Stack:** Bash (lib-sprint.sh, lib-intercore.sh, sprint.md), Markdown (flux-drive skill, docs)

---

## Sequencing

```
Task 1-3 (F1: sprint budget parameter) → Task 4-5 (F4: token writeback) → Task 6-7 (F2: advance check) → Task 8-9 (F3: flux-drive integration) → Task 10-11 (docs)
```

F1 is the foundation — sprint_read_state must surface budget before anything else can use it. F4 (writeback) feeds F2 (advance check uses `ic run budget` which needs token data). F3 depends on F2 (sprint.md reads remaining budget from sprint_read_state). Docs are last.

---

### Task 1: Add --token-budget to intercore_run_create (F1)

**Files:**
- Modify: `hub/clavain/hooks/lib-intercore.sh:225-236`

**Step 1: Add token_budget parameter to intercore_run_create**

Current signature: `intercore_run_create(project, goal, phases, scope_id, complexity)`

Add optional 6th parameter `token_budget`:

```bash
intercore_run_create() {
    local project="$1" goal="$2" _phases="${3:-}" scope_id="${4:-}" complexity="${5:-3}" token_budget="${6:-}"
    if ! intercore_available; then return 1; fi
    local args=(run create --project="$project" --goal="$goal" --complexity="$complexity")
    if [[ -n "$_phases" ]]; then
        args+=(--phases="$_phases")
    fi
    if [[ -n "$scope_id" ]]; then
        args+=(--scope-id="$scope_id")
    fi
    if [[ -n "$token_budget" && "$token_budget" != "0" ]]; then
        args+=(--token-budget="$token_budget" --budget-warn-pct=80)
    fi
    "$INTERCORE_BIN" "${args[@]}" 2>/dev/null
}
```

**Step 2: Syntax check**

Run: `bash -n hub/clavain/hooks/lib-intercore.sh && echo "OK"`

---

### Task 2: Add budget defaults and pass budget to ic run create (F1)

**Files:**
- Modify: `hub/clavain/hooks/lib-sprint.sh` (near sprint_create, around line 50)

**Step 1: Add budget defaults lookup function**

Insert before `sprint_create()` (around line 48):

```bash
# Default token budgets by complexity tier (billing tokens: input + output).
# Calibrated from interstat session data 2026-02.
# Override per-sprint with: bd set-state <sprint> token_budget=N
_sprint_default_budget() {
    local complexity="${1:-3}"
    case "$complexity" in
        1) echo "50000" ;;
        2) echo "100000" ;;
        3) echo "250000" ;;
        4) echo "500000" ;;
        5|*) echo "1000000" ;;
    esac
}
```

**Step 2: Pass budget to intercore_run_create**

In `sprint_create()`, after the phases_json line (around line 78), read complexity and compute budget:

After `local phases_json='...'`, add:
```bash
    # Budget defaults by complexity (set after sprint_classify, before ic run)
    local complexity
    complexity=$(bd state "$sprint_id" complexity 2>/dev/null) || complexity="3"
    [[ -z "$complexity" || "$complexity" == "null" ]] && complexity="3"
    local token_budget
    token_budget=$(_sprint_default_budget "$complexity")
```

Then change the `intercore_run_create` call to pass the budget as 6th arg:
```bash
    run_id=$(intercore_run_create "$(pwd)" "$title" "$phases_json" "$sprint_id" "$complexity" "$token_budget") || run_id=""
```

Note: The current call passes 4 args. We need to also pass complexity (5th) and token_budget (6th). The existing signature already had complexity as 5th param but sprint_create wasn't passing it.

**Step 3: Store budget on bead (beads fallback)**

After the `bd set-state "ic_run_id=$run_id"` line, add:
```bash
    bd set-state "$sprint_id" "token_budget=$token_budget" >/dev/null 2>&1 || true
```

**Step 4: Syntax check**

Run: `bash -n hub/clavain/hooks/lib-sprint.sh && echo "OK"`

---

### Task 3: Add budget fields to sprint_read_state (F1)

**Files:**
- Modify: `hub/clavain/hooks/lib-sprint.sh:222-299` (sprint_read_state)

**Step 1: Add token_budget and tokens_spent to ic run path**

In the ic run path (around line 236-277), after the `auto_advance` extraction, add:

```bash
            # Token budget and spend
            local token_budget tokens_spent
            token_budget=$(echo "$run_json" | jq -r '.token_budget // 0')
            # tokens_spent requires aggregation from dispatch records
            local token_agg
            token_agg=$("$INTERCORE_BIN" run tokens "$run_id" --json 2>/dev/null) || token_agg=""
            if [[ -n "$token_agg" ]]; then
                tokens_spent=$(echo "$token_agg" | jq -r '(.total_in // 0) + (.total_out // 0)')
            else
                tokens_spent="0"
            fi
```

Then add `--arg token_budget "$token_budget" --arg tokens_spent "$tokens_spent"` to the jq output, and add `token_budget: ($token_budget | tonumber), tokens_spent: ($tokens_spent | tonumber)` to the JSON template.

**Step 2: Add token_budget and tokens_spent to beads fallback path**

In the beads fallback (around line 283-298), add:
```bash
    token_budget=$(bd state "$sprint_id" token_budget 2>/dev/null) || token_budget="0"
    tokens_spent=$(bd state "$sprint_id" tokens_spent 2>/dev/null) || tokens_spent="0"
```

And add these to the jq output template.

**Step 3: Syntax check**

Run: `bash -n hub/clavain/hooks/lib-sprint.sh && echo "OK"`

---

### Task 4: Add sprint_record_phase_tokens for post-phase writeback (F4)

**Files:**
- Modify: `hub/clavain/hooks/lib-sprint.sh` (add new function after sprint_record_phase_completion)

**Step 1: Add phase cost estimate lookup**

```bash
# Estimated billing tokens per phase (used when actual data unavailable).
# Source: interstat session aggregates 2026-02. Rough calibration.
_sprint_phase_cost_estimate() {
    local phase="${1:-}"
    case "$phase" in
        brainstorm)          echo "30000" ;;
        brainstorm-reviewed) echo "15000" ;;
        strategized)         echo "25000" ;;
        planned)             echo "35000" ;;
        plan-reviewed)       echo "50000" ;;
        executing)           echo "150000" ;;
        shipping)            echo "100000" ;;
        reflect)             echo "10000" ;;
        done)                echo "5000" ;;
        *)                   echo "30000" ;;
    esac
}
```

**Step 2: Add sprint_record_phase_tokens function**

```bash
# Write token usage for a completed phase to intercore dispatch records.
# Tries interstat for actual data first, falls back to estimates.
# Args: $1=sprint_id, $2=phase_name
sprint_record_phase_tokens() {
    local sprint_id="$1" phase="$2"
    [[ -z "$sprint_id" || -z "$phase" ]] && return 0

    local run_id
    run_id=$(bd state "$sprint_id" ic_run_id 2>/dev/null) || run_id=""
    [[ -z "$run_id" ]] && return 0
    intercore_available || return 0

    # Try actual data from interstat (session-scoped agent_runs)
    local actual_tokens=""
    if command -v sqlite3 &>/dev/null; then
        local db_path="${HOME}/.claude/interstat/metrics.db"
        if [[ -f "$db_path" ]]; then
            actual_tokens=$(sqlite3 "$db_path" \
                "SELECT COALESCE(SUM(COALESCE(input_tokens,0) + COALESCE(output_tokens,0)), 0) FROM agent_runs WHERE session_id='${CLAUDE_SESSION_ID:-}'" 2>/dev/null) || actual_tokens=""
        fi
    fi

    local in_tokens out_tokens
    if [[ -n "$actual_tokens" && "$actual_tokens" != "0" ]]; then
        # Use actuals, split roughly 60/40 input/output
        in_tokens=$(( actual_tokens * 60 / 100 ))
        out_tokens=$(( actual_tokens - in_tokens ))
    else
        # Fall back to estimate
        local estimate
        estimate=$(_sprint_phase_cost_estimate "$phase")
        in_tokens=$(( estimate * 60 / 100 ))
        out_tokens=$(( estimate - in_tokens ))
    fi

    # Create a synthetic dispatch for this phase and set tokens
    local dispatch_id
    dispatch_id=$("$INTERCORE_BIN" dispatch create "$run_id" --agent="phase-${phase}" --json 2>/dev/null \
        | jq -r '.id // ""' 2>/dev/null) || dispatch_id=""
    if [[ -n "$dispatch_id" ]]; then
        "$INTERCORE_BIN" dispatch tokens "$dispatch_id" --set --in="$in_tokens" --out="$out_tokens" 2>/dev/null || true
        "$INTERCORE_BIN" dispatch update "$dispatch_id" --status=completed 2>/dev/null || true
    fi

    # Also update beads fallback running total
    local current_spent
    current_spent=$(bd state "$sprint_id" tokens_spent 2>/dev/null) || current_spent="0"
    [[ -z "$current_spent" || "$current_spent" == "null" ]] && current_spent="0"
    local new_total=$(( current_spent + in_tokens + out_tokens ))
    bd set-state "$sprint_id" "tokens_spent=$new_total" >/dev/null 2>&1 || true
}
```

**Step 3: Syntax check**

Run: `bash -n hub/clavain/hooks/lib-sprint.sh && echo "OK"`

---

### Task 5: Wire sprint_record_phase_tokens into sprint_advance (F4)

**Files:**
- Modify: `hub/clavain/hooks/lib-sprint.sh:650-739` (sprint_advance)

**Step 1: Add token writeback call after successful advance**

In the ic run path, after the success block (around line 700, after `sprint_invalidate_caches`), add:
```bash
        # Write token usage for the phase we just left
        sprint_record_phase_tokens "$sprint_id" "$current_phase" 2>/dev/null || true
```

In the beads fallback path, after the phase set (around line 735, after `sprint_record_phase_completion`), add:
```bash
    sprint_record_phase_tokens "$sprint_id" "$current_phase" 2>/dev/null || true
```

**Step 2: Syntax check**

Run: `bash -n hub/clavain/hooks/lib-sprint.sh && echo "OK"`

---

### Task 6: Add budget check to sprint_advance (F2)

**Files:**
- Modify: `hub/clavain/hooks/lib-sprint.sh:650-739` (sprint_advance)

**Step 1: Add budget check before advancing (ic run path)**

In the ic run path, BEFORE the `intercore_run_advance` call (around line 663), insert:

```bash
        # Budget check: warn or pause if budget exceeded
        if [[ -z "${CLAVAIN_SKIP_BUDGET:-}" ]]; then
            "$INTERCORE_BIN" run budget "$run_id" 2>/dev/null
            local budget_rc=$?
            if [[ $budget_rc -eq 1 ]]; then
                # Budget exceeded — return structured pause reason
                local spent budget
                local token_json
                token_json=$("$INTERCORE_BIN" run tokens "$run_id" --json 2>/dev/null) || token_json="{}"
                spent=$(echo "$token_json" | jq -r '(.total_in // 0) + (.total_out // 0)' 2>/dev/null) || spent="?"
                budget=$("$INTERCORE_BIN" run show "$run_id" --json 2>/dev/null | jq -r '.token_budget // "?"' 2>/dev/null) || budget="?"
                echo "budget_exceeded|$current_phase|${spent}/${budget} billing tokens"
                return 1
            fi
        fi
```

**Step 2: Add budget_exceeded handling to sprint.md auto-advance protocol**

In `hub/clavain/commands/sprint.md`, find the auto-advance case statement (around line 164), and add:
```
            budget_exceeded)
                # AskUserQuestion: "Budget exceeded (<detail>). Options: Continue (override), Stop sprint, Adjust budget"
                ;;
```

**Step 3: Syntax check**

Run: `bash -n hub/clavain/hooks/lib-sprint.sh && echo "OK"`

---

### Task 7: Add sprint_budget_remaining helper (F2)

**Files:**
- Modify: `hub/clavain/hooks/lib-sprint.sh` (add after sprint_read_state)

**Step 1: Add helper function**

```bash
# Get remaining token budget for a sprint.
# Output: integer (0 if no budget set or beads-only)
sprint_budget_remaining() {
    local sprint_id="$1"
    [[ -z "$sprint_id" ]] && { echo "0"; return 0; }

    local state
    state=$(sprint_read_state "$sprint_id") || { echo "0"; return 0; }

    local budget spent
    budget=$(echo "$state" | jq -r '.token_budget // 0' 2>/dev/null) || budget="0"
    spent=$(echo "$state" | jq -r '.tokens_spent // 0' 2>/dev/null) || spent="0"
    [[ "$budget" == "0" || "$budget" == "null" ]] && { echo "0"; return 0; }

    local remaining=$(( budget - spent ))
    [[ $remaining -lt 0 ]] && remaining=0
    echo "$remaining"
}
```

**Step 2: Syntax check**

Run: `bash -n hub/clavain/hooks/lib-sprint.sh && echo "OK"`

---

### Task 8: Pass remaining budget to flux-drive (F3)

**Files:**
- Modify: `hub/clavain/commands/sprint.md`

**Step 1: Add budget env var before flux-drive invocations**

In sprint.md, before Step 4 (Review Plan — flux-drive invocation, around line 264) and before Step 7 (Quality Gates — quality-gates also uses flux-drive), add a budget context block:

Before the `/interflux:flux-drive` line, add:
```markdown
**Budget context:** Before invoking flux-drive, compute remaining budget:
```bash
export SPRINT_LIB_PROJECT_DIR="."; source "${CLAUDE_PLUGIN_ROOT}/hooks/lib-sprint.sh"
remaining=$(sprint_budget_remaining "$CLAVAIN_BEAD_ID")
if [[ "$remaining" -gt 0 ]]; then
    export FLUX_BUDGET_REMAINING="$remaining"
fi
```
```

Do the same before quality-gates invocation (Step 7).

---

### Task 9: Read FLUX_BUDGET_REMAINING in flux-drive triage (F3)

**Files:**
- Modify: `plugins/interflux/skills/flux-drive/SKILL-compact.md`

**Step 1: Find the budget loading section**

In SKILL-compact.md, Step 1.2c loads budget from `budget.yaml`. After loading the budget from yaml, add:

```markdown
**Sprint budget override:** If `FLUX_BUDGET_REMAINING` env var is set and non-zero:
- effective_budget = min(yaml_budget, FLUX_BUDGET_REMAINING)
- Note in triage summary: `Budget: Xk / Yk (Z%) [sprint-constrained]`
```

This is a markdown instruction, not code — the LLM executing flux-drive reads this and applies the logic.

**Step 2: No syntax check needed (markdown skill file)**

---

### Task 10: Add sprint budget display to sprint summary (docs)

**Files:**
- Modify: `hub/clavain/commands/sprint.md`

**Step 1: Update sprint summary at Step 10 (Ship)**

In the sprint summary block (around line 360), add budget line:

After `- Steps completed: <n>/10`:
```markdown
- Budget: <tokens_spent>k / <token_budget>k (<percentage>%)
```

---

### Task 11: Update glossary and AGENTS.md (docs)

**Files:**
- Modify: `docs/glossary.md`
- Modify: `hub/clavain/AGENTS.md`

**Step 1: Add token budget term to glossary**

In the Kernel (L1) table, the "Token budget" entry already exists at line 19. Verify it's accurate.

**Step 2: Update AGENTS.md with budget workflow**

Search `hub/clavain/AGENTS.md` for sprint-related sections and add a brief note about token budgets:
- Default budgets by complexity tier
- `sprint_budget_remaining()` helper
- `FLUX_BUDGET_REMAINING` env var for flux-drive

---

## Verification Checklist

After all tasks are complete:

1. `bash -n hub/clavain/hooks/lib-sprint.sh` — passes
2. `bash -n hub/clavain/hooks/lib-intercore.sh` — passes
3. `sprint_read_state` output includes `token_budget` and `tokens_spent` fields
4. `_sprint_default_budget 3` returns `250000`
5. `sprint_budget_remaining` returns integer for a sprint with budget
6. `grep -c 'budget' hub/clavain/hooks/lib-sprint.sh` — at least 15 occurrences
7. `grep -c 'FLUX_BUDGET_REMAINING' hub/clavain/commands/sprint.md` — at least 2
8. `grep -c 'budget_exceeded' hub/clavain/hooks/lib-sprint.sh` — at least 1
