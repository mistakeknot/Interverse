# Flux-drive Quality Review: Interspect Routing Overrides Plan

**Reviewer:** fd-quality (Flux-drive Quality & Style Reviewer)
**Document:** `docs/plans/2026-02-15-interspect-routing-overrides.md`
**Date:** 2026-02-15
**Scope:** Implementation plan for cross-plugin routing override system

---

### Findings Index

- P2 | Q-001 | Task 1 Step 2 | Missing export keyword for shell variable
- P2 | Q-002 | Task 1 Step 4 | SQL injection via unvalidated variable interpolation
- P2 | Q-003 | Task 2 Step 1 | Markdown indentation inconsistency in SKILL.md insertion
- P3 | Q-004 | Task 3 | Missing error handling for AskUserQuestion rejection
- P2 | Q-005 | Task 4 | Git restore fallback chain uses deprecated syntax
- P3 | Q-006 | Task 5 Step 1 | Incomplete canary query integration in status display
- P2 | Q-007 | Task 7 | Hardcoded path breaks test portability
- P3 | Q-008 | Task 7 | Missing test for percentage calculation edge case
- P3 | Q-009 | Task 8 | Documentation placement contradicts routing override scope
- P3 | Q-010 | Global | Inconsistent command description format
- P2 | Q-011 | Task 4 | TOCTOU race condition in agent roster validation
- P3 | Q-012 | Task 3 | Proposal flow lacks retry mechanism after transient failure

**Verdict:** needs-changes

---

### Summary

This implementation plan is well-structured and technically sound in its overall architecture. The dependency graph is clear, the task breakdown follows logical boundaries, and the integration between clavain (producer) and interflux (consumer) is cleanly separated via the routing-overrides.json contract.

However, the plan contains multiple quality issues that would introduce bugs or maintenance debt if implemented as written. The most critical issues involve SQL injection vulnerabilities in shell functions (Q-002), missing exports for configuration variables (Q-001), and deprecated git syntax that will fail on modern git versions (Q-005). The bats test suite also has portability issues with hardcoded paths (Q-007).

Several lower-priority issues involve incomplete error handling (Q-004, Q-012), missing test coverage for edge cases (Q-008), and inconsistencies in documentation placement and command descriptions (Q-009, Q-010). While these won't break core functionality, they will create maintenance friction and make the codebase harder to extend.

---

### Issues Found

#### P2 | Q-001 | Task 1 Step 2 | Missing export keyword for shell variable

**Location:** Task 1, Step 2, lines 44-50

**Evidence:**
```bash
_INTERSPECT_MIN_AGENT_WRONG_PCT=$(jq -r '.min_agent_wrong_pct // 80' "$conf")
```

**Problem:**
The variable `_INTERSPECT_MIN_AGENT_WRONG_PCT` is set but never exported. Shell variables prefixed with `_` are conventionally private to the current shell, but this variable is used in a subshell context in Step 4's `_interspect_is_routing_eligible` function (line 101). Without export, the variable will be empty in subshells or functions sourced from different contexts.

Existing pattern in `lib-interspect.sh` shows global configuration variables are not exported, but are accessed via function calls in the same shell context. However, the usage pattern here (setting in `_interspect_load_confidence`, reading in `_interspect_is_routing_eligible`) crosses function boundaries without a return value mechanism.

**Impact:**
The routing eligibility check will always compare against an empty threshold (`pct < ""`), which will evaluate to false, causing all patterns to fail the `min_agent_wrong_pct` check regardless of actual percentage.

**Fix:**
Follow the existing pattern in `lib-interspect.sh` where configuration variables are set as globals within the same script scope. The plan is correct, but needs clarification that both functions must be in the same sourced context. Add validation:

```bash
_interspect_is_routing_eligible() {
    _interspect_load_confidence
    local agent="$1"
    local db="${_INTERSPECT_DB:-$(_interspect_db_path)}"
    local escaped="${agent//\'/\'\'}"

    # Validate config loaded
    if [[ -z "${_INTERSPECT_MIN_AGENT_WRONG_PCT:-}" ]]; then
        echo "not_eligible:config_load_failed"
        return 1
    fi
    # ... rest of function
```

---

#### P2 | Q-002 | Task 1 Step 4 | SQL injection via unvalidated variable interpolation

**Location:** Task 1, Step 4, lines 84, 92-93

**Evidence:**
```bash
blacklisted=$(sqlite3 "$db" "SELECT COUNT(*) FROM blacklist WHERE pattern_key = '${escaped}';")
total=$(sqlite3 "$db" "SELECT COUNT(*) FROM evidence WHERE source = '${escaped}' AND event = 'override';")
wrong=$(sqlite3 "$db" "SELECT COUNT(*) FROM evidence WHERE source = '${escaped}' AND event = 'override' AND override_reason = 'agent_wrong';")
```

**Problem:**
The variable `${escaped}` uses shell escaping (`${agent//\'/\'\'}`) to double single quotes, which is correct for preventing SQL injection via quote breakout. However, the plan does not show validation of the input `$1` before this escaping. If `$1` contains SQL keywords, operators, or Unicode characters that bypass shell escaping, this could still result in malformed queries.

Additionally, the `event = 'override'` literal is hardcoded without validation that this event type exists in the schema, creating a coupling to the evidence emission contract that isn't documented in this plan.

**Impact:**
Low probability of exploitation (requires malicious agent name), but high severity if triggered. Malformed queries will cause sqlite3 to return errors, which the script treats as "0" via empty string coercion, leading to incorrect eligibility decisions.

More likely: legitimate agent names with special characters (e.g., `fd-quality-v2.0`) could break queries if the escaping doesn't handle dots, hyphens, or version strings.

**Fix:**
Add input validation before SQL query construction:

```bash
_interspect_is_routing_eligible() {
    _interspect_load_confidence
    local agent="$1"

    # Validate agent name format (alphanumeric, dash, underscore only)
    if ! [[ "$agent" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        echo "not_eligible:invalid_agent_name"
        return 1
    fi

    local db="${_INTERSPECT_DB:-$(_interspect_db_path)}"
    local escaped="${agent//\'/\'\'}"
    # ... rest of function
```

Alternatively, use parameterized queries via `sqlite3 -cmd` if available, or rely on `_interspect_sanitize` from existing lib-interspect.sh for consistent validation.

---

#### P2 | Q-003 | Task 2 Step 1 | Markdown indentation inconsistency in SKILL.md insertion

**Location:** Task 2, Step 1, lines 192-210

**Evidence:**
The plan instructs inserting a new Step 1.2a.0 between line 225 ("#### Step 1.2a: Pre-filter agents") and line 227. The insertion shows:

```markdown
#### Step 1.2a.0: Apply routing overrides

Before pre-filtering by content, check for project-level routing overrides:

1. **Read file:** Check if `$FLUX_ROUTING_OVERRIDES_PATH` ...
```

**Problem:**
SKILL.md files in the interflux agent roster use 4-level heading hierarchy (`####`) for numbered steps. The plan correctly uses `####` for the step heading, but the sub-instructions use numbered lists (`1.`, `2.`, `3.`) without specifying indentation level.

Existing flux-drive SKILL.md uses nested lists with 3-space indentation for sub-steps (visible in Step 1.2a structure). The plan's insertion uses 0-space indentation for the numbered list, which will break the visual hierarchy and make the step look like a separate section.

**Impact:**
The SKILL.md will render with incorrect nesting, making the step appear as a peer to `#### Step 1.2a` instead of a sub-step. This breaks the logical flow and makes the skill harder to follow.

**Fix:**
Indent the numbered list by 3 spaces (or match the existing SKILL.md indentation pattern):

```markdown
#### Step 1.2a.0: Apply routing overrides

Before pre-filtering by content, check for project-level routing overrides:

   1. **Read file:** Check if `$FLUX_ROUTING_OVERRIDES_PATH` (default: `.claude/routing-overrides.json`) exists in the project root.
   2. **If missing:** Continue to Step 1.2a with no exclusions.
   3. **If present:**
      a. Parse JSON. If malformed, log `"WARNING: routing-overrides.json malformed, ignoring overrides"` in triage output, move file to `.claude/routing-overrides.json.corrupted`, and continue with no exclusions.
      b. Check `version` field. If `version > 1`, log `"WARNING: Routing overrides version N not supported (max 1). Ignoring file."` and continue with no exclusions.
      c. Read `.overrides[]` array. For each entry with `"action": "exclude"`:
         - Remove the agent from the candidate pool (they will not appear in pre-filter or scoring)
         - If the agent is not in the roster (unknown name), log: `"WARNING: Routing override for unknown agent {name} — check spelling or remove entry."`
         - If the excluded agent is cross-cutting (fd-architecture, fd-quality, fd-safety, fd-correctness), add a **prominent warning** to triage output: `"⚠️ Routing override excludes cross-cutting agent {name}. This removes structural/security coverage."`
   4. **Triage table note:** After the scoring table, add: `"N agents excluded by routing overrides: [agent1, agent2, ...]"`
   5. **Continue to Step 1.2a** with the reduced candidate pool.
```

Verify the indentation against the existing SKILL.md before inserting.

---

#### P3 | Q-004 | Task 3 | Missing error handling for AskUserQuestion rejection

**Location:** Task 3, Propose Flow Command, lines 289-330

**Evidence:**
The plan describes presenting proposals via AskUserQuestion with three options: "Accept", "Decline", "Show evidence details". However, there is no specification for what happens if:
- User dismisses the question without selecting an option
- Claude Code session is interrupted during proposal presentation
- Multiple proposals are queued and user declines all of them

**Problem:**
AskUserQuestion in Claude Code can be dismissed without a selection. The plan does not specify whether this should be treated as "Decline" or logged as a separate event. Without explicit handling, the command may hang waiting for user input, or proceed with undefined behavior.

Additionally, the plan states "failed proposals are not re-offered in the same session" (PRD F3) but does not define what constitutes a "failed" proposal vs. a "declined" proposal.

**Impact:**
Low severity (user can retry `/interspect`), but creates poor UX. If the question is dismissed, the command should log the event and treat it as "Decline" for consistency.

**Fix:**
Add to the Propose Flow Command after the AskUserQuestion section:

```markdown
## Error Handling

If AskUserQuestion is dismissed without a response:
- Treat as "Decline" for this session
- Do NOT re-propose in the same session
- Log event: "Routing proposal for {agent} dismissed by user"

If the session is interrupted during proposal presentation:
- Next session will re-propose (eligibility check runs fresh)
- No persistent state needed for partial proposals
```

---

#### P2 | Q-005 | Task 4 | Git restore fallback chain uses deprecated syntax

**Location:** Task 4, Step 1, lines 453, 619

**Evidence:**
```bash
git restore "$FILEPATH" 2>/dev/null || git checkout -- "$FILEPATH" 2>/dev/null || true
```

**Problem:**
The fallback chain attempts to use `git restore` (Git 2.23+) and falls back to `git checkout --` (deprecated in Git 2.23, removed in Git 3.0). The plan assumes the environment has at least one of these, but does not check git version.

Additionally, the `|| true` at the end swallows all errors, including legitimate failures like "file is locked" or "repository is corrupted". This makes debugging impossible if the rollback fails.

**Impact:**
On systems with Git 3.0+, the fallback to `git checkout --` will fail, and the `|| true` will hide the failure. The routing override will remain staged but uncommitted, leaving git in a dirty state.

**Fix:**
Use `git reset HEAD <file>` (stable across all git versions) instead of the restore/checkout chain:

```bash
# Rollback on commit failure
if ! git commit -m "[interspect] Exclude ${AGENT} from flux-drive triage
..."; then
    git reset HEAD "$FILEPATH" 2>/dev/null || true
    rm -f "$FULLPATH"  # Remove the uncommitted file
    echo "ERROR: Git commit failed. Override not applied." >&2
    exit 1
fi
```

Alternative: Check git version and use appropriate command:

```bash
if git restore --help >/dev/null 2>&1; then
    git restore "$FILEPATH"
else
    git reset HEAD "$FILEPATH"
fi
```

---

#### P3 | Q-006 | Task 5 Step 1 | Incomplete canary query integration in status display

**Location:** Task 5, Step 1, lines 520-557

**Evidence:**
The plan adds a routing overrides section to `interspect-status.md` with a table showing "Canary" and "Next Action" columns. The spec says:

```
{for each override:
  - query canary table for status
  - if created_by=interspect, check modifications table for consistency
  - if agent not in roster, flag as "orphaned"
  - show next-action hint}
```

**Problem:**
The plan does not provide the actual SQL queries or bash logic to populate these columns. The spec is written in pseudocode without implementation details, unlike other tasks which show complete bash snippets.

This leaves ambiguity about:
- How to join `canary` table with `routing-overrides.json` (canary uses `group_id`, file uses `agent` name)
- What "consistency check" means for modifications table
- How to detect roster membership (path to agents/review/*.md?)

**Impact:**
Implementer will need to reverse-engineer the canary schema and joining logic, increasing risk of bugs. The status display may show incomplete or incorrect canary information.

**Fix:**
Add explicit bash implementation after the table spec:

```bash
# For each override, augment with canary status
OVERRIDES_WITH_CANARY=$(jq -r '.overrides[] | [.agent, .action, .reason, .created, .created_by] | @tsv' "$FULLPATH" | while IFS=$'\t' read -r agent action reason created created_by; do
    # Query canary
    canary_status=$(sqlite3 "$DB" "SELECT status, uses_so_far, window_uses FROM canary WHERE group_id = '${agent//\'/\'\'}' AND status = 'active' ORDER BY applied_at DESC LIMIT 1;" 2>/dev/null || echo "||")

    # Parse canary fields
    IFS='|' read -r c_status c_uses c_window <<< "$canary_status"

    # Canary display
    if [[ -n "$c_status" ]]; then
        canary_display="monitoring: ${c_uses}/${c_window} uses"
    else
        canary_display="none"
    fi

    # Next action hint
    if [[ "$created_by" == "interspect" ]]; then
        next_action="/interspect:revert $agent to undo"
    else
        next_action="manual override (edit file or use /interspect:revert)"
    fi

    # Roster check
    roster_found=0
    for roster_dir in ~/.claude/plugins/cache/interagency-marketplace/interflux/*/agents/review \
                      plugins/interflux/agents/review \
                      .claude/agents; do
        [[ -f "${roster_dir}/${agent}.md" ]] && roster_found=1 && break
    done

    orphan_flag=""
    [[ $roster_found -eq 0 ]] && orphan_flag="⚠️ ORPHANED"

    echo -e "${agent}\t${action}\t${reason}\t${created}\t${created_by}\t${canary_display}\t${next_action}\t${orphan_flag}"
done)
```

---

#### P2 | Q-007 | Task 7 | Hardcoded path breaks test portability

**Location:** Task 7, Step 1, line 774

**Evidence:**
```bash
INTERSPECT_LIB="$(find /root/projects/Interverse/hub/clavain -name lib-interspect.sh -type f | head -1)"
```

**Problem:**
The test suite hardcodes the absolute path `/root/projects/Interverse/hub/clavain`, which assumes the test is running on the ethics-gradient server with the monorepo at this exact location. This breaks:
- CI/CD environments (GitHub Actions, etc.)
- Local development on other machines
- Isolated test environments (Docker, etc.)

Existing Clavain commands (like `interspect-status.md`, line 16-17) use a dynamic search pattern that works in both installed (cache) and development (source) contexts.

**Impact:**
The test suite will fail on any machine where the monorepo is not at `/root/projects/Interverse`. This prevents contributors from running tests locally and blocks CI adoption.

**Fix:**
Use the same dynamic discovery pattern as the commands:

```bash
INTERSPECT_LIB=$(find ~/.claude/plugins/cache -path '*/clavain/*/hooks/lib-interspect.sh' 2>/dev/null | head -1)
[[ -z "$INTERSPECT_LIB" ]] && INTERSPECT_LIB=$(find ~/projects -path '*/hub/clavain/hooks/lib-interspect.sh' 2>/dev/null | head -1)
[[ -z "$INTERSPECT_LIB" ]] && INTERSPECT_LIB=$(find "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" -path '*/hooks/lib-interspect.sh' -type f | head -1)
if [[ -z "$INTERSPECT_LIB" ]]; then
    echo "Error: Could not locate hooks/lib-interspect.sh" >&2
    exit 1
fi
source "$INTERSPECT_LIB"
```

Alternatively, if bats tests are always run from the repo root, use a relative path:

```bash
INTERSPECT_LIB="../../hooks/lib-interspect.sh"  # Relative to tests/shell/
```

---

#### P3 | Q-008 | Task 7 | Missing test for percentage calculation edge case

**Location:** Task 7, Step 1, test suite

**Evidence:**
The test suite includes:
- `@test "is_routing_eligible returns eligible at 80% threshold"` (4 agent_wrong, 1 other = 80%)
- `@test "is_routing_eligible returns not_eligible below threshold"` (3 agent_wrong, 2 other = 60%)

**Problem:**
The test suite does not cover the edge case where `total = 1` (single event), which would compute `pct = 100` and pass the threshold. This is a valid scenario (first override for an agent) but might have unintended consequences if the counting-rule gate (min_sessions, min_events) is bypassed.

Additionally, the percentage calculation `pct=$(( wrong * 100 / total ))` uses integer division, which truncates. The test at 80% boundary (4/5 = 80.0%) works, but 8/10 = 80% and 7/9 = 77.77% → 77% (fails threshold). This truncation behavior is not tested.

**Impact:**
Low severity (counting rules prevent single-event proposals), but the integer truncation could cause confusion. For example, 79.9% rounds down to 79%, failing the 80% threshold even though it's close.

**Fix:**
Add edge case tests:

```bash
@test "is_routing_eligible truncates percentage (7/9 = 77% < 80%)" {
    DB=$(_interspect_db_path)
    # Insert 9 events: 7 agent_wrong, 2 deprioritized (77.77% → 77%)
    for i in 1 2 3 4 5 6 7; do
        sqlite3 "$DB" "INSERT INTO evidence (session_id, seq, ts, source, event, override_reason, project) VALUES ('s$i', $i, '2026-01-0${i}', 'fd-game-design', 'override', 'agent_wrong', 'proj1');"
    done
    for i in 8 9; do
        sqlite3 "$DB" "INSERT INTO evidence (session_id, seq, ts, source, event, override_reason, project) VALUES ('s$i', $i, '2026-01-0${i}', 'fd-game-design', 'override', 'deprioritized', 'proj1');"
    done

    result=$(_interspect_is_routing_eligible "fd-game-design")
    [[ "$result" == *"not_eligible"* ]]
}

@test "is_routing_eligible allows 100% on single event (but counting rules block)" {
    DB=$(_interspect_db_path)
    sqlite3 "$DB" "INSERT INTO evidence (session_id, seq, ts, source, event, override_reason, project) VALUES ('s1', 1, '2026-01-01', 'fd-game-design', 'override', 'agent_wrong', 'proj1');"

    # Should fail due to min_events=5, not percentage
    result=$(_interspect_is_routing_eligible "fd-game-design")
    [[ "$result" == *"no_override_events"* ]] || [[ "$result" == *"not_eligible"* ]]
}
```

Note: The second test exposes that the function checks percentage before counting rules, which is inefficient. The order should be: counting rules → blacklist → percentage.

---

#### P3 | Q-009 | Task 8 | Documentation placement contradicts routing override scope

**Location:** Task 8, Step 1, lines 876-913

**Evidence:**
The plan instructs adding routing overrides documentation to `hub/clavain/AGENTS.md`, including "what routing overrides are and how they work", "manual override workflow", and "available commands".

**Problem:**
Routing overrides are a cross-plugin feature with consumer in `interflux` (flux-drive) and producer in `clavain` (interspect). Documenting the entire feature in Clavain's AGENTS.md creates a single source of truth issue:

1. Flux-drive users who don't have Clavain installed won't find the documentation
2. The file format (consumer contract) should be documented where flux-drive users look
3. The producer workflow (interspect commands) belongs in Clavain, but the schema belongs in interflux or shared docs

The Interverse monorepo has a `docs/` directory for shared documentation (per `AGENTS.md` line 35). This is the appropriate place for cross-plugin contracts.

**Impact:**
Low severity (users can find docs via search), but creates documentation drift. If flux-drive changes the schema (adds version 2), the Clavain docs may not be updated, leading to stale instructions.

**Fix:**
Split the documentation:

1. **Create `docs/routing-overrides.md` in Interverse root** — Schema definition, version evolution, consumer behavior, examples
2. **Link from Clavain AGENTS.md** — "Routing override workflow (producer side)" with link to shared docs: "See `docs/routing-overrides.md` for schema and consumer behavior."
3. **Link from interflux flux-drive SKILL.md** — Add a reference to `docs/routing-overrides.md` in Step 1.2a.0 for users who want to create overrides manually

This follows the existing pattern where shared infrastructure (intersearch, intermute) is documented in the monorepo `docs/` directory.

---

#### P3 | Q-010 | Global | Inconsistent command description format

**Location:** Multiple tasks (Task 3, Task 5 Step 2, Task 5 Step 3)

**Evidence:**
- Task 3: `description: Detect routing-eligible patterns and propose agent exclusions`
- Task 5 Step 2: `description: Revert a routing override and blacklist the pattern`
- Task 5 Step 3: `description: Remove a pattern from the routing override blacklist`

**Problem:**
The command descriptions are inconsistent in voice and verb choice:
- Task 3 uses imperative mood without subject ("Detect ... and propose ...")
- Task 5 Step 2 uses imperative with article ("Revert a routing override ...")
- Task 5 Step 3 uses imperative without article ("Remove a pattern ...")

Existing Clavain commands (checked via `hub/clavain/commands/interspect-status.md`) use descriptive noun phrases:

```yaml
description: Interspect overview — session counts, evidence stats, active canaries, and modifications
```

Existing interspect-correction.md uses imperative without articles:

```yaml
description: Record flux-drive review override (agent wrong, deprioritized, too late)
```

**Impact:**
Low severity (cosmetic), but inconsistent help text makes the command catalog harder to scan. The `/help` output will mix styles.

**Fix:**
Standardize on the existing pattern (imperative without articles, or descriptive noun phrase):

- **Task 3 (propose):** `description: Detect and propose agent exclusions based on routing-eligible patterns`
- **Task 5 Step 2 (revert):** `description: Revert routing override and blacklist pattern from future proposals`
- **Task 5 Step 3 (unblock):** `description: Remove pattern from routing override blacklist`

Or use noun phrases consistently:

- **Task 3:** `description: Routing override proposal workflow — detect eligible patterns and present exclusions`
- **Task 5 Step 2:** `description: Routing override revert — remove exclusion and blacklist pattern`
- **Task 5 Step 3:** `description: Routing override blacklist removal — allow future proposals for pattern`

Choose one style and apply to all three commands.

---

#### P2 | Q-011 | Task 4 | TOCTOU race condition in agent roster validation

**Location:** Task 4, Step 1, lines 380-393

**Evidence:**
```bash
# Validate agent exists in roster
local agent_found=0
local interflux_root
for d in ~/.claude/plugins/cache/interagency-marketplace/interflux/*/agents/review \
         "${root}/plugins/interflux/agents/review" \
         "${root}/.claude/agents"; do
    if [[ -f "${d}/${agent}.md" ]]; then
        agent_found=1
        break
    fi
done
if (( agent_found == 0 )); then
    echo "ERROR: Agent ${agent} not found in flux-drive roster. Cannot create override." >&2
    return 1
fi
```

**Problem:**
The agent roster validation happens **outside** the `_interspect_flock_git` critical section. The check happens at line 380-393, but the flock begins at line 396. This creates a time-of-check-to-time-of-use (TOCTOU) race:

1. Thread A checks roster, finds `fd-game-design.md`
2. Thread B (or user) deletes `fd-game-design.md` (plugin update, manual removal)
3. Thread A enters flock and writes override for deleted agent
4. Result: orphaned override in `routing-overrides.json`

While the plan includes orphan detection in `/interspect:status` (Q-006), creating orphaned overrides is a data quality issue that should be prevented at write time.

**Impact:**
Low probability (roster changes are rare during a session), but high annoyance. The override will be created successfully, then immediately flagged as orphaned in status output. This wastes a git commit and creates confusion.

**Fix:**
Move the roster validation inside the flock:

```bash
# Entire read-modify-write-commit inside flock
_interspect_flock_git bash -c '
    set -e
    ROOT="'"$root"'"
    FILEPATH="'"$filepath"'"
    FULLPATH="'"$fullpath"'"
    AGENT="'"$agent"'"
    REASON="'"$reason"'"
    EVIDENCE_IDS='"'"'"$evidence_ids"'"'"'
    CREATED_BY="'"$created_by"'"
    CREATED=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # ROSTER VALIDATION (inside lock)
    agent_found=0
    for d in ~/.claude/plugins/cache/interagency-marketplace/interflux/*/agents/review \
             "${ROOT}/plugins/interflux/agents/review" \
             "${ROOT}/.claude/agents"; do
        if [[ -f "${d}/${AGENT}.md" ]]; then
            agent_found=1
            break
        fi
    done
    if (( agent_found == 0 )); then
        echo "ERROR: Agent ${AGENT} not found in flux-drive roster. Cannot create override." >&2
        exit 1
    fi

    # Read current file
    if [[ -f "$FULLPATH" ]]; then
        CURRENT=$(jq "." "$FULLPATH" 2>/dev/null || echo "{\"version\":1,\"overrides\":[]}")
    # ... rest of flock block
```

This ensures the roster check is atomic with the file write.

---

#### P3 | Q-012 | Task 3 | Proposal flow lacks retry mechanism after transient failure

**Location:** Task 3, Propose Flow Command, lines 322-330

**Evidence:**
```markdown
## On Accept → Route to Apply

If user accepts, proceed to apply the override:
1. Call the apply flow (Task 4 logic — `_interspect_apply_routing_override`)
2. Report result to user
```

**Problem:**
The plan does not specify error handling if `_interspect_apply_routing_override` fails due to transient errors:
- Git lock held by another process (flock timeout)
- Network failure during `git pull --rebase` (inside flock)
- Disk full when writing routing-overrides.json
- Permission denied on `.claude/` directory (ACL drift)

The apply function returns error codes (line 461-465 in Task 4), but the propose command does not specify whether to:
- Retry the application
- Re-present the proposal
- Mark the pattern as "failed" and skip for this session
- Log the failure and continue to next proposal

**Impact:**
Low severity (user can manually run `/interspect:propose` again), but creates poor UX. If a transient failure occurs (e.g., git lock), the user may not know whether to retry immediately or wait.

**Fix:**
Add error handling to the propose command after the apply call:

```markdown
## On Accept → Route to Apply

If user accepts, proceed to apply the override:
1. Call the apply flow (Task 4 logic — `_interspect_apply_routing_override`)
2. **On success:** Report result to user: "Routing override applied. Agent {name} will be excluded from future flux-drive reviews."
3. **On failure:**
   - If failure is due to git lock (exit code 1, "flock timeout" in stderr), offer retry: "Git lock held by another process. Retry now? (Yes/No)"
   - If failure is due to git commit failure (exit code 1, "Git commit failed" in stderr), show error: "Could not commit routing override. Check git status and re-run `/interspect:propose`."
   - If failure is unknown, log error and continue to next proposal: "Application failed for {agent}. See stderr for details. Continuing to next proposal..."
   - Failed proposals are logged but do NOT re-propose in this session (prevent infinite retry loop)
```

Alternatively, simplify to: "On failure, report error and continue to next proposal. User can re-run `/interspect:propose` to retry."

---

### Improvements

#### 1. Test Coverage for Concurrent Apply Attempts

**Suggestion:**
Add a bats test that simulates concurrent calls to `_interspect_apply_routing_override` to verify the flock prevents race conditions:

```bash
@test "concurrent apply attempts serialize via flock" {
    # Create two background processes that apply overrides simultaneously
    (_interspect_apply_routing_override "fd-game-design" "test-1" "[]" "test" &)
    (_interspect_apply_routing_override "fd-performance" "test-2" "[]" "test" &)
    wait

    # Both should succeed, commits should be sequential
    commit_count=$(git rev-list --count HEAD)
    [ "$commit_count" -ge 2 ]

    # Both overrides should exist
    overrides=$(_interspect_read_routing_overrides)
    [ "$(echo "$overrides" | jq '.overrides | length')" -eq 2 ]
}
```

This ensures the locking mechanism works as intended.

---

#### 2. Dry-Run Mode for Propose Command

**Suggestion:**
Add an optional `--dry-run` flag to `/interspect:propose` that shows what would be proposed without requiring user interaction. This is useful for:
- Debugging eligibility logic
- Batch processing (scripting)
- Preview before committing to the workflow

Implementation:

```markdown
## Dry-Run Mode

If `--dry-run` flag is present in arguments:
1. Show all routing-eligible patterns with full details (event counts, sessions, percentage)
2. Do NOT present AskUserQuestion prompts
3. Report: "Dry-run complete. Run `/interspect:propose` without --dry-run to apply overrides."
```

This follows the existing pattern in `bump-version.sh --dry-run` (line 101 in Interverse AGENTS.md).

---

#### 3. Canary Window Configuration

**Suggestion:**
The canary monitoring window is hardcoded to 20 uses or 14 days (Task 4, lines 481-486). Consider making this configurable in `confidence.json`:

```json
{
  "min_sessions": 3,
  "min_diversity": 2,
  "min_events": 5,
  "min_agent_wrong_pct": 80,
  "canary_window_uses": 20,
  "canary_window_days": 14,
  "_comment": "Canary monitoring thresholds for routing overrides"
}
```

This allows projects with different review cadences (daily vs weekly) to tune the monitoring window.

---

#### 4. JSON Schema Validation for routing-overrides.json

**Suggestion:**
The plan validates JSON syntax via `jq -e`, but does not validate schema (required fields, data types). Consider adding schema validation using `jq` schemas or a dedicated validator:

```bash
# In _interspect_read_routing_overrides
SCHEMA_VALID=$(echo "$CURRENT" | jq -e '
    .version == 1 and
    (.overrides | type == "array") and
    (.overrides[] |
        has("agent") and has("action") and has("reason") and
        .agent != "" and .action == "exclude"
    )
' >/dev/null 2>&1 && echo "valid" || echo "invalid")

if [[ "$SCHEMA_VALID" != "valid" ]]; then
    echo "ERROR: routing-overrides.json schema invalid. Moving to .corrupted" >&2
    mv "$fullpath" "${fullpath}.corrupted"
    return 1
fi
```

This prevents malformed overrides from being silently ignored.

---

#### 5. Audit Log for Override Lifecycle

**Suggestion:**
The plan creates modification records and canary records, but does not log the full lifecycle (proposed → accepted → applied → monitored → reverted). Consider adding lifecycle events to the evidence table:

```bash
# On proposal presentation
_interspect_insert_evidence "$session_id" "$agent" "routing_proposal_shown" "" "{\"reason\":\"$reason\"}" "interspect"

# On user accept
_interspect_insert_evidence "$session_id" "$agent" "routing_accepted" "" "{\"reason\":\"$reason\"}" "interspect"

# On user decline
_interspect_insert_evidence "$session_id" "$agent" "routing_declined" "" "{\"reason\":\"$reason\"}" "interspect"
```

This provides a complete audit trail for debugging and analytics ("how many proposals were declined before one was accepted?").

---

#### 6. Progress Display Consistency

**Suggestion:**
Task 3 (lines 315-320) and Task 6 (line 726) both mention showing progress toward threshold for "growing" patterns, but the format is specified in Task 3 only. Ensure Task 6 references Task 3's format to avoid duplication:

```markdown
Progress display for growing patterns:
- Use the same format as `/interspect:propose` (see Task 3 line 318)
```

This prevents divergence if the format is updated.

---

#### 7. Environment Variable Validation

**Suggestion:**
The plan uses `FLUX_ROUTING_OVERRIDES_PATH` environment variable (lines 119, 370, 593, etc.) but does not validate the value. If a user sets this to an absolute path outside the git repo, the flock and git operations will fail. Add validation:

```bash
# In _interspect_apply_routing_override and _interspect_read_routing_overrides
local filepath="${FLUX_ROUTING_OVERRIDES_PATH:-.claude/routing-overrides.json}"

# Validate path is relative
if [[ "$filepath" =~ ^/ ]]; then
    echo "ERROR: FLUX_ROUTING_OVERRIDES_PATH must be relative to git root, got: ${filepath}" >&2
    return 1
fi

# Validate path is under git root
local fullpath="${root}/${filepath}"
if [[ ! "$fullpath" =~ ^"${root}" ]]; then
    echo "ERROR: FLUX_ROUTING_OVERRIDES_PATH escapes git root: ${filepath}" >&2
    return 1
fi
```

This prevents accidental misconfiguration.

---

### Meta-Review: Plan Quality

**Strengths:**
- Clear separation of producer/consumer concerns
- Comprehensive acceptance criteria tied back to PRD features
- Dependency graph makes parallelization explicit
- Commit messages follow conventional format
- Structural test validation at each task

**Weaknesses:**
- Shell safety issues (SQL injection, missing exports, deprecated git syntax)
- Incomplete specifications for error handling paths
- Test portability assumptions (hardcoded paths)
- Documentation placement doesn't align with cross-plugin scope

**Overall Assessment:**
This is a well-structured plan with good architectural decisions, but needs a quality pass on the bash implementations before execution. The issues found are typical of complex shell scripting (quoting, escaping, error handling) and can be fixed with targeted changes. The plan is ready for implementation after addressing the P2 issues (Q-001, Q-002, Q-005, Q-007, Q-011).
