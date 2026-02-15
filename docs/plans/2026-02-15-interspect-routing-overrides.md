# Interspect Routing Overrides Implementation Plan
**Phase:** shipping (all 9 tasks implemented, 165 tests pass)

> **For Claude:** REQUIRED SUB-SKILL: Use clavain:executing-plans to implement this plan task-by-task.

**Goal:** Build the cross-plugin routing override system: interspect (clavain) proposes and applies agent exclusions, flux-drive (interflux) reads and honors them during triage.

**Architecture:** Producer-consumer via `.claude/routing-overrides.json`. Producer (clavain/interspect) writes overrides after evidence-based proposals + user approval. Consumer (interflux/flux-drive) reads the file during Step 1.2a.0 pre-filter. All file operations serialized via `_interspect_flock_git`. DB records written inside flock after git commit succeeds (atomically). Named bash functions with positional arguments replace `bash -c` heredocs. All SQL uses `_interspect_sql_escape()`. Agent names validated via `_interspect_validate_agent_name()`.

**Revision:** v2 — 2026-02-15. Revised to address P0/P1 findings from flux-drive 5-agent review (see `docs/research/flux-drive/2026-02-15-interspect-routing-overrides-plan/SYNTHESIS.md`). 9 findings fixed: 2 P0 (flock scope, rollback), 7 P1 (shell injection, SQL injection, agent validation, read-locking, duplicate records, discovery path, batch proposals).

**Tech Stack:** Bash (lib-interspect.sh), jq (JSON manipulation), SQLite (evidence/modifications/canary/blacklist), Markdown (commands/skills), bats (shell tests)

**PRD:** `docs/prds/2026-02-15-interspect-routing-overrides.md`
**Brainstorm:** `docs/brainstorms/2026-02-15-interspect-routing-overrides-brainstorm.md`

---

## Task 1: Extend lib-interspect.sh — Schema, Confidence, Blacklist

**Files:**
- Modify: `hub/clavain/hooks/lib-interspect.sh:64-123` (DB schema), `:260-298` (confidence loading + classification)
- Modify: `hub/clavain/.clavain/interspect/confidence.json`

**Step 1: Add blacklist table to DB schema**

In `_interspect_ensure_db()` (lib-interspect.sh), add after the `modifications` table (line ~110):

```sql
CREATE TABLE IF NOT EXISTS blacklist (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    pattern_key TEXT NOT NULL UNIQUE,
    blacklisted_at TEXT NOT NULL,
    reason TEXT
);
CREATE INDEX IF NOT EXISTS idx_blacklist_key ON blacklist(pattern_key);
```

The `pattern_key` format is `agent_name` (e.g., `fd-game-design`).

**Step 2: Add `min_agent_wrong_pct` to confidence loading**

In `_interspect_load_confidence()` (lib-interspect.sh:262-281), add after line 279:

```bash
_INTERSPECT_MIN_AGENT_WRONG_PCT=$(jq -r '.min_agent_wrong_pct // 80' "$conf")
```

And in the defaults block (before the `if [[ -f "$conf" ]]`):

```bash
_INTERSPECT_MIN_AGENT_WRONG_PCT=80
```

**Step 3: Update confidence.json**

Add `min_agent_wrong_pct` to the config file:

```json
{
  "min_sessions": 3,
  "min_diversity": 2,
  "min_events": 5,
  "min_agent_wrong_pct": 80,
  "_comment": "Counting-rule thresholds per design §3.3. min_agent_wrong_pct gates routing override proposals."
}
```

**Step 4: Add SQL-escape helper and agent-name validation**

Add after the confidence loading block:

```bash
# Escape a string for safe use in sqlite3 single-quoted values.
# Handles single quotes, backslashes, and strips control characters.
# All SQL queries in routing override code MUST use this helper.
_interspect_sql_escape() {
    local val="$1"
    val="${val//\\/\\\\}"           # Escape backslashes first
    val="${val//\'/\'\'}"           # Then single quotes
    printf '%s' "$val" | tr -d '\000-\037\177'  # Strip control chars
}

# Validate agent name format. Rejects anything that isn't fd-<lowercase-name>.
# Args: $1=agent_name
# Returns: 0 if valid, 1 if not
_interspect_validate_agent_name() {
    local agent="$1"
    if [[ ! "$agent" =~ ^fd-[a-z][a-z0-9-]*$ ]]; then
        echo "ERROR: Invalid agent name '${agent}'. Must match fd-<name> (lowercase, hyphens only)." >&2
        return 1
    fi
    return 0
}
```

> **Review fix (finding 4):** All SQL queries in Tasks 1, 3, 4, 5 now use `_interspect_sql_escape()` instead of ad-hoc escaping. `_interspect_validate_agent_name()` rejects malformed names before they reach SQL. This eliminates the injection risk flagged by 4/5 review agents (ARCH-02, SEC-02, SEC-03, Q-002).

**Step 5: Add routing-eligibility check function**

Add new function after `_interspect_classify_pattern` (line ~298):

```bash
# Check if a pattern is routing-eligible (for exclusion proposals).
# Args: $1=agent_name
# Returns: 0 if routing-eligible, 1 if not
# Output: "eligible" or "not_eligible:<reason>"
_interspect_is_routing_eligible() {
    _interspect_load_confidence
    local agent="$1"
    local db="${_INTERSPECT_DB:-$(_interspect_db_path)}"

    # Validate agent name format
    if ! _interspect_validate_agent_name "$agent"; then
        echo "not_eligible:invalid_agent_name"
        return 1
    fi

    local escaped
    escaped=$(_interspect_sql_escape "$agent")

    # Validate config loaded
    if [[ -z "${_INTERSPECT_MIN_AGENT_WRONG_PCT:-}" ]]; then
        echo "not_eligible:config_load_failed"
        return 1
    fi

    # Check blacklist
    local blacklisted
    blacklisted=$(sqlite3 "$db" "SELECT COUNT(*) FROM blacklist WHERE pattern_key = '${escaped}';")
    if (( blacklisted > 0 )); then
        echo "not_eligible:blacklisted"
        return 1
    fi

    # Get agent_wrong percentage
    local total wrong pct
    total=$(sqlite3 "$db" "SELECT COUNT(*) FROM evidence WHERE source = '${escaped}' AND event = 'override';")
    wrong=$(sqlite3 "$db" "SELECT COUNT(*) FROM evidence WHERE source = '${escaped}' AND event = 'override' AND override_reason = 'agent_wrong';")

    if (( total == 0 )); then
        echo "not_eligible:no_override_events"
        return 1
    fi

    pct=$(( wrong * 100 / total ))
    if (( pct < _INTERSPECT_MIN_AGENT_WRONG_PCT )); then
        echo "not_eligible:agent_wrong_pct=${pct}%<${_INTERSPECT_MIN_AGENT_WRONG_PCT}%"
        return 1
    fi

    echo "eligible"
    return 0
}
```

> **Review fix (finding 4 continued):** Config load validation added (Q-001). Agent name validated before SQL. Uses `_interspect_sql_escape()` instead of inline escaping.

**Step 6: Add routing override read/write helpers**

```bash
# Validate FLUX_ROUTING_OVERRIDES_PATH is safe (relative, no traversal).
# Returns: 0 if safe, 1 if not
_interspect_validate_overrides_path() {
    local filepath="$1"
    if [[ "$filepath" == /* ]]; then
        echo "ERROR: FLUX_ROUTING_OVERRIDES_PATH must be relative (got: ${filepath})" >&2
        return 1
    fi
    if [[ "$filepath" == *../* ]] || [[ "$filepath" == */../* ]] || [[ "$filepath" == .. ]]; then
        echo "ERROR: FLUX_ROUTING_OVERRIDES_PATH must not contain '..' (got: ${filepath})" >&2
        return 1
    fi
    return 0
}

# Read routing-overrides.json. Returns JSON or empty structure.
# Uses optimistic locking: accepts TOCTOU race for reads (dedup at write time).
# For atomic reads during apply/revert, use _interspect_read_routing_overrides_locked.
# Args: none (uses FLUX_ROUTING_OVERRIDES_PATH or default)
_interspect_read_routing_overrides() {
    local root
    root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
    local filepath="${FLUX_ROUTING_OVERRIDES_PATH:-.claude/routing-overrides.json}"

    # Path traversal protection
    if ! _interspect_validate_overrides_path "$filepath"; then
        echo '{"version":1,"overrides":[]}'
        return 1
    fi

    local fullpath="${root}/${filepath}"

    if [[ ! -f "$fullpath" ]]; then
        echo '{"version":1,"overrides":[]}'
        return 0
    fi

    if ! jq -e '.' "$fullpath" >/dev/null 2>&1; then
        echo "WARN: ${filepath} is malformed JSON" >&2
        echo '{"version":1,"overrides":[]}'
        return 1
    fi

    jq '.' "$fullpath"
}

# Read routing-overrides.json under shared flock (for status display).
# Prevents torn reads during concurrent apply operations.
_interspect_read_routing_overrides_locked() {
    local root
    root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
    local lockdir="${root}/.clavain/interspect"
    local lockfile="${lockdir}/.git-lock"

    mkdir -p "$lockdir" 2>/dev/null || true

    (
        # Shared lock allows concurrent reads, blocks on exclusive write lock.
        # Timeout 1s: if lock unavailable, fall back to unlocked read.
        if ! flock -s -w 1 9; then
            echo "WARN: Override file locked (apply in progress). Showing latest available data." >&2
        fi
        _interspect_read_routing_overrides
    ) 9>"$lockfile"
}

# Write routing-overrides.json atomically (call inside _interspect_flock_git).
# Uses temp file + rename for crash safety.
# Args: $1=JSON content to write
_interspect_write_routing_overrides() {
    local content="$1"
    local root
    root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
    local filepath="${FLUX_ROUTING_OVERRIDES_PATH:-.claude/routing-overrides.json}"

    if ! _interspect_validate_overrides_path "$filepath"; then
        return 1
    fi

    local fullpath="${root}/${filepath}"

    mkdir -p "$(dirname "$fullpath")" 2>/dev/null || true

    # Atomic write: temp file + rename
    local tmpfile="${fullpath}.tmp.$$"
    echo "$content" | jq '.' > "$tmpfile"

    # Validate before replacing
    if ! jq -e '.' "$tmpfile" >/dev/null 2>&1; then
        rm -f "$tmpfile"
        echo "ERROR: Write produced invalid JSON, aborted" >&2
        return 1
    fi

    mv "$tmpfile" "$fullpath"
}

# Check if an override exists for an agent.
# Args: $1=agent_name
# Returns: 0 if exists, 1 if not
_interspect_override_exists() {
    local agent="$1"
    local current
    current=$(_interspect_read_routing_overrides)
    echo "$current" | jq -e --arg agent "$agent" '.overrides[] | select(.agent == $agent)' >/dev/null 2>&1
}
```

> **Review fixes applied:**
> - **Finding 6 (read-without-lock):** Added `_interspect_read_routing_overrides_locked()` with shared flock for status displays. Unlocked read retained for propose flow (optimistic, dedup at write time).
> - **Finding 10 (path traversal, P2):** Added `_interspect_validate_overrides_path()` — rejects absolute paths and `..` traversal. Applied to both read and write.
> - **Atomic writes (correctness improvement):** Write now uses temp file + rename pattern to prevent corruption on crash.

**Step 7: Run syntax check**

```bash
bash -n hub/clavain/hooks/lib-interspect.sh
```

Expected: no output (clean syntax).

**Step 8: Commit**

```bash
git add hub/clavain/hooks/lib-interspect.sh hub/clavain/.clavain/interspect/confidence.json
git commit -m "feat(interspect): add routing override helpers, blacklist table, SQL escape, confidence extension"
```

---

## Task 2: Consumer — Flux-drive Routing Override Reader (F1)

**Files:**
- Modify: `plugins/interflux/skills/flux-drive/SKILL.md:225-226` (insert Step 1.2a.0)

**Step 1: Insert Step 1.2a.0 before existing Step 1.2a**

In `plugins/interflux/skills/flux-drive/SKILL.md`, insert the following between line 225 ("#### Step 1.2a: Pre-filter agents") and line 227 ("Before scoring, eliminate agents..."):

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
5. **Discovery nudge:** If the same agent has been overridden 3+ times in the current session (via user declining findings or explicitly overriding), add a note after the triage table: `"Tip: Agent {name} was overridden {N} times this session. Run /interspect:correction to record this pattern. After enough evidence, /interspect can propose permanent exclusions."`
6. **Continue to Step 1.2a** with the reduced candidate pool.
```

> **Review fix (finding 8):** Added discovery nudge so users encountering noisy agents learn about `/interspect:correction` organically during flux-drive reviews, instead of needing to discover it via documentation (UX1, PROD2).

**Step 2: Run the structural test to verify SKILL.md is valid**

```bash
cd plugins/interflux && uv run pytest tests/structural/test_skills.py -v
```

Expected: all tests pass.

**Step 3: Commit**

```bash
git add plugins/interflux/skills/flux-drive/SKILL.md
git commit -m "feat(flux-drive): add Step 1.2a.0 routing override reader"
```

---

## Task 3: Producer — Propose Flow Command (F2)

**Files:**
- Create: `hub/clavain/commands/interspect-propose.md`

**Step 1: Create the propose command**

```markdown
---
name: interspect-propose
description: Detect routing-eligible patterns and propose agent exclusions
argument-hint: "[optional: specific agent to check]"
---

# Interspect Propose

Tier 2 analysis: detect patterns eligible for routing overrides and present proposals.

<propose_target> #$ARGUMENTS </propose_target>

## Locate Library

```bash
INTERSPECT_LIB=$(find ~/.claude/plugins/cache -path '*/clavain/*/hooks/lib-interspect.sh' 2>/dev/null | head -1)
[[ -z "$INTERSPECT_LIB" ]] && INTERSPECT_LIB=$(find ~/projects -path '*/hub/clavain/hooks/lib-interspect.sh' 2>/dev/null | head -1)
if [[ -z "$INTERSPECT_LIB" ]]; then
    echo "Error: Could not locate hooks/lib-interspect.sh" >&2
    exit 1
fi
source "$INTERSPECT_LIB"
_interspect_ensure_db
DB=$(_interspect_db_path)
```

## Detect Routing-Eligible Patterns

Get classified patterns and filter for routing eligibility:

```bash
CLASSIFIED=$(_interspect_get_classified_patterns)
```

For each pattern classified as "ready":
1. Check `_interspect_is_routing_eligible "$agent"` — skip if not eligible (blacklisted, below threshold)
2. Check `_interspect_override_exists "$agent"` — skip if override already exists
3. Collect eligible patterns into a list

## Cross-Cutting Agent Check

Cross-cutting agents: `fd-architecture`, `fd-quality`, `fd-safety`, `fd-correctness`.

If a routing-eligible pattern involves a cross-cutting agent, it still appears in proposals but with an explicit warning:
> "⚠️ {agent} provides structural/security coverage across all projects. Excluding it may hide systemic issues."

The proposal for cross-cutting agents requires the user to select "Yes, exclude despite warning" (not just "Accept").

## Present Proposals (Batch Mode)

Show the pattern analysis table first (same as `/interspect` output), then present all eligible proposals together for batch decision-making.

If no eligible patterns exist and no evidence exists at all:
> "No patterns detected yet. Record corrections via `/interspect:correction` when agents produce irrelevant findings. Interspect learns from your overrides."

If patterns exist but none are routing-eligible:
> "Patterns detected but not routing-eligible. Routing overrides require ≥80% of corrections to be 'agent_wrong'. Keep recording corrections via `/interspect:correction`."

If eligible patterns exist, show a summary table first:

```
Interspect found N routing-eligible patterns:

| Agent | Events | Sessions | agent_wrong% | Warning |
|-------|--------|----------|-------------|---------|
| fd-game-design | 8 | 4 | 100% | |
| fd-performance | 6 | 3 | 83% | |
| fd-correctness | 5 | 3 | 100% | ⚠️ cross-cutting |
```

Then present a single multi-select AskUserQuestion:

```
Which agents do you want to exclude from this project? (Select all that apply)

Options:
- "fd-game-design — 100% irrelevant (8 events)"
- "fd-performance — 83% irrelevant (6 events)"
- "fd-correctness — ⚠️ cross-cutting, 100% irrelevant (5 events)"
- "Show evidence details" — View recent corrections before deciding
```

If "Show evidence details" is selected, format evidence as human-readable summaries (not raw SQL):

```bash
local escaped
escaped=$(_interspect_sql_escape "$agent")
sqlite3 -separator '|' "$DB" "SELECT ts, override_reason, substr(context, 1, 200) FROM evidence WHERE source = '${escaped}' AND event = 'override' ORDER BY ts DESC LIMIT 5;"
```

Parse and format the output as:
```
Recent corrections for fd-game-design:
- Feb 10, 2:23pm: Recommended async patterns for sync-only project
- Feb 9, 11:45am: Suggested multiplayer architecture for single-player game
```

Then re-present the multi-select choice.

For all selected agents, apply overrides in batch (call `_interspect_apply_routing_override` for each).

> **Review fixes applied:**
> - **Finding 9 (batch proposals):** Replaced sequential per-agent AskUserQuestion with summary table + multi-select (UX2). Users can now compare all proposals before deciding.
> - **Finding 8 continued (evidence dependency):** Added three-tier "no results" messaging: no evidence → no eligible patterns → eligible patterns (PROD2).
> - **Finding 4 continued (SQL):** Evidence query now uses `_interspect_sql_escape()` (SEC-02). Evidence display formatted as human-readable bullets instead of raw SQL output (UX3).

## Progress Display

For patterns that are "growing" (not yet ready), show progress:

```
### Approaching Threshold
- {agent}: {events}/{min_events} events, {sessions}/{min_sessions} sessions ({needs} more {criteria})
```

## On Accept → Route to Apply

If user accepts, proceed to apply the override:
1. Call the apply flow (Task 4 logic — `_interspect_apply_routing_override`)
2. Report result to user

## On Decline

Skip this pattern. It will re-propose next session if still eligible. Do not blacklist.
```

**Step 2: Run structural test**

```bash
cd hub/clavain && uv run pytest tests/structural/test_commands.py -v
```

Expected: new command is discovered.

**Step 3: Commit**

```bash
git add hub/clavain/commands/interspect-propose.md
git commit -m "feat(interspect): add /interspect:propose command for routing override proposals"
```

---

## Task 4: Producer — Apply + Commit Flow (F3)

**Files:**
- Modify: `hub/clavain/hooks/lib-interspect.sh` (add apply function)

**Step 1: Add the apply function to lib-interspect.sh**

Add after the routing override helpers from Task 1:

```bash
# Apply a routing override. Handles the full read-modify-write-commit-record flow.
# All operations (file write, git commit, DB inserts) run inside flock for atomicity.
# Args: $1=agent_name $2=reason $3=evidence_ids_json $4=created_by (default "interspect")
# Returns: 0 on success, 1 on failure
_interspect_apply_routing_override() {
    local agent="$1"
    local reason="$2"
    local evidence_ids="${3:-[]}"
    local created_by="${4:-interspect}"

    # --- Pre-flock validation (fast-fail) ---

    # Validate agent name format (prevents injection + catches typos)
    if ! _interspect_validate_agent_name "$agent"; then
        return 1
    fi

    # Validate evidence_ids is a JSON array
    if ! echo "$evidence_ids" | jq -e 'type == "array"' >/dev/null 2>&1; then
        echo "ERROR: evidence_ids must be a JSON array (got: ${evidence_ids})" >&2
        return 1
    fi

    local root
    root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
    local filepath="${FLUX_ROUTING_OVERRIDES_PATH:-.claude/routing-overrides.json}"

    # Validate path (no traversal)
    if ! _interspect_validate_overrides_path "$filepath"; then
        return 1
    fi

    local fullpath="${root}/${filepath}"

    # Validate target path is in modification allow-list
    if ! _interspect_validate_target "$filepath"; then
        echo "ERROR: ${filepath} is not an allowed modification target" >&2
        return 1
    fi

    # --- Write commit message to temp file (avoids shell injection) ---

    local commit_msg_file
    commit_msg_file=$(mktemp)
    cat > "$commit_msg_file" <<COMMIT_MSG_EOF
[interspect] Exclude ${agent} from flux-drive triage

Reason: ${reason}
Evidence: ${evidence_ids}
Created-by: ${created_by}
COMMIT_MSG_EOF

    # --- DB path for use inside flock ---
    local db="${_INTERSPECT_DB:-$(_interspect_db_path)}"

    # --- Entire read-modify-write-commit-record inside flock ---
    #
    # CRITICAL: DB inserts MUST be inside flock to prevent orphaned records
    # when concurrent sessions both commit overrides for the same agent.
    # (Review finding 1 — RACE-01, ARCH-08)

    local flock_output
    flock_output=$(_interspect_flock_git _interspect_apply_override_locked \
        "$root" "$filepath" "$fullpath" "$agent" "$reason" \
        "$evidence_ids" "$created_by" "$commit_msg_file" "$db")

    local exit_code=$?
    rm -f "$commit_msg_file"

    if (( exit_code != 0 )); then
        echo "ERROR: Could not apply routing override. Check git status and retry." >&2
        echo "$flock_output" >&2
        return 1
    fi

    # Parse output from locked function
    local commit_sha
    commit_sha=$(echo "$flock_output" | tail -1)

    echo "SUCCESS: Excluded ${agent}. Commit: ${commit_sha}"
    echo "Canary monitoring active. Run /interspect:status after 5-10 sessions to check impact."
    echo "To undo: /interspect:revert ${agent}"
    return 0
}

# Inner function called under flock. Do NOT call directly.
# All arguments are positional to avoid quote-nesting hell.
_interspect_apply_override_locked() {
    set -e
    local root="$1" filepath="$2" fullpath="$3" agent="$4"
    local reason="$5" evidence_ids="$6" created_by="$7"
    local commit_msg_file="$8" db="$9"

    local created
    created=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # 1. Read current file
    local current
    if [[ -f "$fullpath" ]]; then
        current=$(jq '.' "$fullpath" 2>/dev/null || echo '{"version":1,"overrides":[]}')
    else
        current='{"version":1,"overrides":[]}'
    fi

    # 2. Dedup check (inside lock — TOCTOU-safe)
    local is_new=1
    if echo "$current" | jq -e --arg agent "$agent" '.overrides[] | select(.agent == $agent)' >/dev/null 2>&1; then
        echo "INFO: Override for ${agent} already exists, updating metadata." >&2
        is_new=0
    fi

    # 3. Build new override using jq --arg (no shell interpolation)
    local new_override
    new_override=$(jq -n \
        --arg agent "$agent" \
        --arg action "exclude" \
        --arg reason "$reason" \
        --argjson evidence_ids "$evidence_ids" \
        --arg created "$created" \
        --arg created_by "$created_by" \
        '{agent:$agent,action:$action,reason:$reason,evidence_ids:$evidence_ids,created:$created,created_by:$created_by}')

    # 4. Merge (unique_by deduplicates, last write wins for metadata)
    local merged
    merged=$(echo "$current" | jq --argjson override "$new_override" \
        '.overrides = (.overrides + [$override] | unique_by(.agent))')

    # 5. Atomic write (temp + rename)
    mkdir -p "$(dirname "$fullpath")" 2>/dev/null || true
    local tmpfile="${fullpath}.tmp.$$"
    echo "$merged" | jq '.' > "$tmpfile"

    if ! jq -e '.' "$tmpfile" >/dev/null 2>&1; then
        rm -f "$tmpfile"
        echo "ERROR: Write produced invalid JSON, aborted" >&2
        return 1
    fi
    mv "$tmpfile" "$fullpath"

    # 6. Git add + commit (using -F for commit message — no injection)
    cd "$root"
    git add "$filepath"
    if ! git commit --no-verify -F "$commit_msg_file"; then
        # Rollback: unstage THEN restore working tree
        git reset HEAD -- "$filepath" 2>/dev/null || true
        git restore "$filepath" 2>/dev/null || git checkout -- "$filepath" 2>/dev/null || true
        echo "ERROR: Git commit failed. Override not applied." >&2
        return 1
    fi

    local commit_sha
    commit_sha=$(git rev-parse HEAD)

    # 7. DB inserts INSIDE flock (atomicity with git commit)
    local escaped_agent escaped_reason
    escaped_agent=$(_interspect_sql_escape "$agent")
    escaped_reason=$(_interspect_sql_escape "$reason")

    # Only insert modification + canary for genuinely NEW overrides
    if (( is_new == 1 )); then
        local ts
        ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

        # Modification record
        sqlite3 "$db" "INSERT INTO modifications (group_id, ts, tier, mod_type, target_file, commit_sha, confidence, evidence_summary, status)
            VALUES ('${escaped_agent}', '${ts}', 'persistent', 'routing', '${filepath}', '${commit_sha}', 1.0, '${escaped_reason}', 'applied');"

        # Canary record
        local expires_at
        expires_at=$(date -u -d "+14 days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
            || date -u -v+14d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
        if [[ -z "$expires_at" ]]; then
            echo "ERROR: date command does not support relative dates" >&2
            return 1
        fi

        if ! sqlite3 "$db" "INSERT INTO canary (file, commit_sha, group_id, applied_at, window_uses, window_expires_at, status)
            VALUES ('${filepath}', '${commit_sha}', '${escaped_agent}', '${ts}', 20, '${expires_at}', 'active');"; then
            # Canary failure is non-fatal but flagged in DB
            sqlite3 "$db" "UPDATE modifications SET status = 'applied-unmonitored' WHERE commit_sha = '${commit_sha}';" 2>/dev/null || true
            echo "WARN: Canary monitoring failed — override active but unmonitored." >&2
        fi
    else
        echo "INFO: Metadata updated for existing override. No new canary." >&2
    fi

    # 8. Output commit SHA (last line, captured by caller)
    echo "$commit_sha"
}
```

> **Review fixes applied (5 findings in this function):**
>
> - **Finding 1 (P0 — flock scope):** DB inserts moved inside `_interspect_apply_override_locked()`, which runs entirely under flock. No more orphaned records from concurrent sessions (RACE-01, ARCH-08).
>
> - **Finding 2 (P0 — incomplete rollback):** Rollback now uses `git reset HEAD -- "$filepath"` to unstage BEFORE `git restore` to clean working tree. Prevents failed overrides from leaking into unrelated commits (DATA-01, Q-005, OPS-03).
>
> - **Finding 3 (P1 — shell injection):** Eliminated `bash -c` heredoc entirely. The locked function is a named bash function receiving positional arguments — no quote nesting. Commit message written to temp file, referenced via `git commit -F` (SEC-01, ARCH-04, SHELL-01).
>
> - **Finding 5 (P1 — agent roster validation):** Removed filesystem-based agent roster validation entirely. Replaced with `_interspect_validate_agent_name()` format check only. Flux-drive handles unknown agents gracefully at triage time. This eliminates the tight coupling, wrong paths, and TOCTOU race flagged by all 4 technical agents (ARCH-01, DATA-04, OPS-01, Q-011).
>
> - **Finding 7 (P1 — duplicate DB records):** Added `is_new` flag from dedup check. DB records only inserted for genuinely new overrides; metadata updates skip modification/canary creation (DATA-02).
>
> Additional hardening:
> - `git commit --no-verify` prevents blocking hooks inside flock (OPS-02, P2)
> - `_interspect_sql_escape()` used for all DB writes
> - Canary failure marks modification as `applied-unmonitored` instead of silently succeeding (ARCH-08)
> - `evidence_ids` validated as JSON array before use
> - Date command fails hard if neither GNU nor BSD relative dates work

**Step 2: Run syntax check**

```bash
bash -n hub/clavain/hooks/lib-interspect.sh
```

Expected: no output.

**Step 3: Commit**

```bash
git add hub/clavain/hooks/lib-interspect.sh
git commit -m "feat(interspect): add _interspect_apply_routing_override with flock + rollback"
```

---

## Task 5: Status + Revert Commands (F4)

**Files:**
- Modify: `hub/clavain/commands/interspect-status.md` (add routing overrides section)
- Create: `hub/clavain/commands/interspect-revert.md`
- Create: `hub/clavain/commands/interspect-unblock.md`

**Step 1: Add routing overrides section to interspect-status.md**

After the "Active modifications" query (line ~49), add a new section:

```markdown
## Routing Overrides

Read routing overrides using the shared-lock reader (prevents torn reads during concurrent apply):

```bash
OVERRIDES_JSON=$(_interspect_read_routing_overrides_locked)
OVERRIDE_COUNT=$(echo "$OVERRIDES_JSON" | jq '.overrides | length')
OVERRIDES=$(echo "$OVERRIDES_JSON" | jq -r '.overrides[] | [.agent, .action, .reason, .created, .created_by] | @tsv')
```

> **Review fix (finding 6):** Status reads use `_interspect_read_routing_overrides_locked()` which acquires a shared flock, preventing inconsistent data when apply is in-flight (RACE-02, ARCH-05).

Present routing overrides with actionable context:

```
### Routing Overrides: {override_count} active

| Agent | Action | Reason | Created | Source | Canary | Next Action |
|-------|--------|--------|---------|--------|--------|-------------|
{for each override:
  - query canary table for status
  - if created_by=interspect, check modifications table for consistency
  - if agent not in roster, flag as "orphaned"
  - show next-action hint}

{if override_count >= 3: "⚠️ High exclusion rate (N agents). Review agent roster or run `/interspect:propose` to check pattern health."}

> You can also hand-edit `.claude/routing-overrides.json` — set `"created_by": "human"` for custom overrides.
```
```

**Step 2: Create interspect-revert.md**

```markdown
---
name: interspect-revert
description: Revert a routing override and blacklist the pattern
argument-hint: "<agent-name or commit-sha>"
---

# Interspect Revert

Remove a routing override and blacklist the pattern so it won't re-propose.

<revert_target> #$ARGUMENTS </revert_target>

## Locate Library

```bash
INTERSPECT_LIB=$(find ~/.claude/plugins/cache -path '*/clavain/*/hooks/lib-interspect.sh' 2>/dev/null | head -1)
[[ -z "$INTERSPECT_LIB" ]] && INTERSPECT_LIB=$(find ~/projects -path '*/hub/clavain/hooks/lib-interspect.sh' 2>/dev/null | head -1)
source "$INTERSPECT_LIB"
_interspect_ensure_db
DB=$(_interspect_db_path)
```

## Parse Target

If argument looks like a git SHA (7+ hex chars), target by commit. Otherwise, target by agent name.

## Idempotency Check

Read routing-overrides.json and check if the target override exists:

```bash
ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
FILEPATH="${FLUX_ROUTING_OVERRIDES_PATH:-.claude/routing-overrides.json}"
FULLPATH="${ROOT}/${FILEPATH}"

if ! jq -e --arg agent "$AGENT" '.overrides[] | select(.agent == $agent)' "$FULLPATH" >/dev/null 2>&1; then
    echo "Override for ${AGENT} not found. Already removed or never existed."
    exit 0
fi
```

## Remove Override

Validate agent name, then run removal inside flock using a named function (no `bash -c` heredoc):

```bash
# Validate agent name
if ! _interspect_validate_agent_name "$AGENT"; then
    exit 1
fi

# Write commit message to temp file (no shell injection)
COMMIT_MSG_FILE=$(mktemp)
cat > "$COMMIT_MSG_FILE" <<REVERT_EOF
[interspect] Revert routing override for ${AGENT}

Reason: User requested revert via /interspect:revert
REVERT_EOF

_interspect_flock_git _interspect_revert_override_locked \
    "$ROOT" "$FILEPATH" "$FULLPATH" "$AGENT" "$COMMIT_MSG_FILE" "$DB"
REVERT_EXIT=$?
rm -f "$COMMIT_MSG_FILE"
```

The locked function:
```bash
_interspect_revert_override_locked() {
    set -e
    local root="$1" filepath="$2" fullpath="$3" agent="$4"
    local commit_msg_file="$5" db="$6"

    CURRENT=$(jq '.' "$fullpath")
    UPDATED=$(echo "$CURRENT" | jq --arg agent "$agent" 'del(.overrides[] | select(.agent == $agent))')
    echo "$UPDATED" | jq '.' > "$fullpath"

    cd "$root"
    git add "$filepath"
    if ! git commit --no-verify -F "$commit_msg_file"; then
        # Rollback: unstage + restore
        git reset HEAD -- "$filepath" 2>/dev/null || true
        git restore "$filepath" 2>/dev/null || git checkout -- "$filepath" 2>/dev/null || true
        echo "ERROR: Git commit failed. Revert not applied." >&2
        return 1
    fi

    # Close canary and insert blacklist INSIDE flock
    local escaped_agent
    escaped_agent=$(_interspect_sql_escape "$agent")
    sqlite3 "$db" "UPDATE canary SET status = 'reverted' WHERE group_id = '${escaped_agent}' AND status = 'active';"
}
```

## Blacklist Decision

After successful revert, ask the user whether to blacklist:

```
Override for {agent} has been removed. Should interspect re-propose this if evidence accumulates?

Options:
- "Allow future proposals" (Recommended) — Agent can be proposed again if evidence warrants it
- "Blacklist permanently" — Never re-propose this exclusion
```

If "Blacklist permanently":
```bash
local escaped_agent
escaped_agent=$(_interspect_sql_escape "$AGENT")
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
sqlite3 "$DB" "INSERT OR REPLACE INTO blacklist (pattern_key, blacklisted_at, reason) VALUES ('${escaped_agent}', '${TS}', 'User reverted via /interspect:revert');"
```

## Report

```
Reverted routing override for **{agent}**.
{if blacklisted: "Pattern blacklisted — interspect won't re-propose this exclusion.
Run `/interspect:unblock {agent}` to allow future proposals."}
{if not blacklisted: "Interspect may re-propose this exclusion if evidence warrants it."}
```

> **Review fixes applied:**
> - **Finding 3 (shell injection):** Replaced `bash -c` heredoc with named function + `git commit -F` temp file. No quote nesting.
> - **Finding 2 (rollback):** Uses `git reset HEAD` + `git restore` for complete rollback.
> - **Finding 4 (SQL injection):** Uses `_interspect_sql_escape()` for all SQL in revert/blacklist.
> - **Revert blacklist (UX7, P2):** User now chooses whether to blacklist instead of automatic blacklist. Default is "allow future proposals."
```

**Step 3: Create interspect-unblock.md**

```markdown
---
name: interspect-unblock
description: Remove a pattern from the routing override blacklist
argument-hint: "<agent-name>"
---

# Interspect Unblock

Remove a pattern from the blacklist so interspect can propose it again.

<unblock_target> #$ARGUMENTS </unblock_target>

## Execute

```bash
INTERSPECT_LIB=$(find ~/.claude/plugins/cache -path '*/clavain/*/hooks/lib-interspect.sh' 2>/dev/null | head -1)
[[ -z "$INTERSPECT_LIB" ]] && INTERSPECT_LIB=$(find ~/projects -path '*/hub/clavain/hooks/lib-interspect.sh' 2>/dev/null | head -1)
source "$INTERSPECT_LIB"
_interspect_ensure_db
DB=$(_interspect_db_path)

if ! _interspect_validate_agent_name "$AGENT"; then
    exit 1
fi
ESCAPED=$(_interspect_sql_escape "$AGENT")
DELETED=$(sqlite3 "$DB" "DELETE FROM blacklist WHERE pattern_key = '${ESCAPED}'; SELECT changes();")
```

Report: "Unblocked {agent}. Interspect may propose this exclusion again if evidence warrants it." or "No blacklist entry found for {agent}."
```

**Step 4: Run structural tests**

```bash
cd hub/clavain && uv run pytest tests/structural/test_commands.py -v
```

**Step 5: Commit**

```bash
git add hub/clavain/commands/interspect-status.md hub/clavain/commands/interspect-revert.md hub/clavain/commands/interspect-unblock.md
git commit -m "feat(interspect): add /interspect:revert and /interspect:unblock commands, extend status"
```

---

## Task 6: Update /interspect to Include Routing Proposals (F2 Integration)

**Files:**
- Modify: `hub/clavain/commands/interspect.md` (integrate propose flow)

**Step 1: Update the interspect command (analysis-only — no inline proposals)**

The existing `/interspect` command remains **read-only analysis**. It does NOT inline the proposal flow (that's `/interspect:propose`). This keeps the commands orthogonal: `/interspect` = analysis, `/interspect:propose` = write proposals.

Update the "Phase 1 notice" to remove the "(no modifications)" note and instead say:

```
**Phase 2: Evidence + Proposals** — routing overrides can be proposed and applied via `/interspect:propose`.
```

Add after the "Report Format" section:

```markdown
## Tier 2: Routing Override Eligibility Summary

After showing the analysis report, check for routing-eligible patterns and display a summary:

1. For each ready pattern where the source is a flux-drive agent:
   - Call `_interspect_is_routing_eligible "$agent"` (from lib-interspect.sh)
   - If eligible, count it
2. Display a footer (DO NOT present proposals or AskUserQuestion from this command):

If routing-eligible patterns exist:
> "N pattern(s) eligible for routing overrides. Run `/interspect:propose` to review exclusion proposals."

Progress display for growing patterns:
- "fd-game-design: 3/5 events, 2/3 sessions (needs 1 more session)"
- "→ Keep using `/interspect:correction` when this agent is wrong. Or exclude manually via hand-editing `.claude/routing-overrides.json`."
```

> **Review fix (ARCH-07, P3):** `/interspect` and `/interspect:propose` are now orthogonal. No duplicate proposal logic, no circular dependency risk, clear command boundaries.

**Step 2: Commit**

```bash
git add hub/clavain/commands/interspect.md
git commit -m "feat(interspect): integrate Tier 2 routing proposals into /interspect command"
```

---

## Task 7: Shell Tests

**Files:**
- Create: `hub/clavain/tests/shell/test_interspect_routing.bats`

**Step 1: Write bats tests for the lib-interspect.sh routing functions**

```bash
#!/usr/bin/env bats

# Test interspect routing override helpers
# Requires: bats-core, jq, sqlite3

setup() {
    export TEST_DIR=$(mktemp -d)
    export HOME="$TEST_DIR"
    export GIT_CONFIG_GLOBAL="$TEST_DIR/.gitconfig"
    export GIT_CONFIG_SYSTEM=/dev/null
    mkdir -p "$TEST_DIR/.clavain/interspect"

    # Create a test git repo
    cd "$TEST_DIR"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    git commit --allow-empty -m "init" -q

    # Create minimal confidence.json
    cat > "$TEST_DIR/.clavain/interspect/confidence.json" << 'EOF'
    {"min_sessions":3,"min_diversity":2,"min_events":5,"min_agent_wrong_pct":80}
EOF

    # Create minimal protected-paths.json
    cat > "$TEST_DIR/.clavain/interspect/protected-paths.json" << 'EOF'
    {"protected_paths":[],"modification_allow_list":[".claude/routing-overrides.json"],"always_propose":[]}
EOF

    # Source lib — portable discovery (plugin cache, project tree, or git root)
    INTERSPECT_LIB=$(find ~/.claude/plugins/cache -path '*/clavain/*/hooks/lib-interspect.sh' 2>/dev/null | head -1)
    [[ -z "$INTERSPECT_LIB" ]] && INTERSPECT_LIB=$(find ~/projects -path '*/hub/clavain/hooks/lib-interspect.sh' 2>/dev/null | head -1)
    [[ -z "$INTERSPECT_LIB" ]] && {
        # Fall back to relative path from test file location
        local script_dir
        script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        INTERSPECT_LIB="$(cd "$script_dir/../../hooks" && pwd)/lib-interspect.sh"
    }
    if [[ ! -f "$INTERSPECT_LIB" ]]; then
        skip "lib-interspect.sh not found in plugin cache, projects/, or relative path"
    fi
    source "$INTERSPECT_LIB"
    _interspect_ensure_db
}

teardown() {
    rm -rf "$TEST_DIR"
}

@test "blacklist table exists after ensure_db" {
    DB=$(_interspect_db_path)
    result=$(sqlite3 "$DB" ".tables" | grep -c "blacklist")
    [ "$result" -ge 1 ]
}

@test "read routing overrides returns empty for missing file" {
    result=$(_interspect_read_routing_overrides)
    version=$(echo "$result" | jq -r '.version')
    count=$(echo "$result" | jq '.overrides | length')
    [ "$version" = "1" ]
    [ "$count" = "0" ]
}

@test "override_exists returns 1 for empty file" {
    run _interspect_override_exists "fd-game-design"
    [ "$status" -eq 1 ]
}

@test "is_routing_eligible returns not_eligible for no events" {
    result=$(_interspect_is_routing_eligible "fd-game-design")
    [[ "$result" == *"no_override_events"* ]]
}

@test "is_routing_eligible returns not_eligible for blacklisted agent" {
    DB=$(_interspect_db_path)
    sqlite3 "$DB" "INSERT INTO blacklist (pattern_key, blacklisted_at) VALUES ('fd-game-design', '2026-01-01');"
    result=$(_interspect_is_routing_eligible "fd-game-design")
    [[ "$result" == *"blacklisted"* ]]
}

@test "is_routing_eligible returns eligible at 80% threshold" {
    DB=$(_interspect_db_path)
    # Insert 5 events: 4 agent_wrong, 1 deprioritized (80%)
    for i in 1 2 3 4; do
        sqlite3 "$DB" "INSERT INTO evidence (session_id, seq, ts, source, event, override_reason, project) VALUES ('s$i', $i, '2026-01-0${i}', 'fd-game-design', 'override', 'agent_wrong', 'proj$((i % 3 + 1))');"
    done
    sqlite3 "$DB" "INSERT INTO evidence (session_id, seq, ts, source, event, override_reason, project) VALUES ('s5', 5, '2026-01-05', 'fd-game-design', 'override', 'deprioritized', 'proj1');"

    result=$(_interspect_is_routing_eligible "fd-game-design")
    [ "$result" = "eligible" ]
}

@test "is_routing_eligible returns not_eligible below threshold" {
    DB=$(_interspect_db_path)
    # Insert 5 events: 3 agent_wrong, 2 deprioritized (60%)
    for i in 1 2 3; do
        sqlite3 "$DB" "INSERT INTO evidence (session_id, seq, ts, source, event, override_reason, project) VALUES ('s$i', $i, '2026-01-0${i}', 'fd-game-design', 'override', 'agent_wrong', 'proj$i');"
    done
    for i in 4 5; do
        sqlite3 "$DB" "INSERT INTO evidence (session_id, seq, ts, source, event, override_reason, project) VALUES ('s$i', $i, '2026-01-0${i}', 'fd-game-design', 'override', 'deprioritized', 'proj1');"
    done

    result=$(_interspect_is_routing_eligible "fd-game-design")
    [[ "$result" == *"not_eligible"* ]]
}

@test "write and read routing overrides round-trip" {
    local content='{"version":1,"overrides":[{"agent":"fd-game-design","action":"exclude","reason":"test","evidence_ids":[],"created":"2026-01-01","created_by":"test"}]}'
    _interspect_write_routing_overrides "$content"

    result=$(_interspect_read_routing_overrides)
    agent=$(echo "$result" | jq -r '.overrides[0].agent')
    [ "$agent" = "fd-game-design" ]
}

@test "override_exists returns 0 after write" {
    mkdir -p "$TEST_DIR/.claude"
    echo '{"version":1,"overrides":[{"agent":"fd-game-design","action":"exclude"}]}' > "$TEST_DIR/.claude/routing-overrides.json"

    run _interspect_override_exists "fd-game-design"
    [ "$status" -eq 0 ]
}

# --- SQL escape tests ---

@test "sql_escape handles single quotes" {
    result=$(_interspect_sql_escape "it's a test")
    [ "$result" = "it''s a test" ]
}

@test "sql_escape handles backslashes" {
    result=$(_interspect_sql_escape 'back\\slash')
    [ "$result" = 'back\\\\slash' ]
}

@test "sql_escape strips control characters" {
    # Tab (\\t) should be stripped
    input=$'fd-game\tdesign'
    result=$(_interspect_sql_escape "$input")
    [ "$result" = "fd-gamedesign" ]
}

# --- Agent name validation tests ---

@test "validate_agent_name accepts valid names" {
    run _interspect_validate_agent_name "fd-game-design"
    [ "$status" -eq 0 ]
}

@test "validate_agent_name rejects SQL injection" {
    run _interspect_validate_agent_name "fd-game'; DROP TABLE evidence; --"
    [ "$status" -eq 1 ]
}

@test "validate_agent_name rejects non-fd prefix" {
    run _interspect_validate_agent_name "malicious-agent"
    [ "$status" -eq 1 ]
}

@test "validate_agent_name rejects uppercase" {
    run _interspect_validate_agent_name "fd-Game-Design"
    [ "$status" -eq 1 ]
}

# --- Path validation tests ---

@test "validate_overrides_path accepts default path" {
    run _interspect_validate_overrides_path ".claude/routing-overrides.json"
    [ "$status" -eq 0 ]
}

@test "validate_overrides_path rejects absolute path" {
    run _interspect_validate_overrides_path "/etc/passwd"
    [ "$status" -eq 1 ]
}

@test "validate_overrides_path rejects traversal" {
    run _interspect_validate_overrides_path "../../../etc/passwd"
    [ "$status" -eq 1 ]
}

# --- Percentage edge case tests ---

@test "is_routing_eligible truncates percentage (7/9 = 77% < 80%)" {
    DB=$(_interspect_db_path)
    for i in 1 2 3 4 5 6 7; do
        sqlite3 "$DB" "INSERT INTO evidence (session_id, seq, ts, source, event, override_reason, project) VALUES ('s$i', $i, '2026-01-0${i}', 'fd-game-design', 'override', 'agent_wrong', 'proj$((i % 3 + 1))');"
    done
    for i in 8 9; do
        sqlite3 "$DB" "INSERT INTO evidence (session_id, seq, ts, source, event, override_reason, project) VALUES ('s$i', $i, '2026-01-0${i}', 'fd-game-design', 'override', 'deprioritized', 'proj1');"
    done

    result=$(_interspect_is_routing_eligible "fd-game-design")
    [[ "$result" == *"not_eligible"* ]]
}
```

> **Review fixes applied:**
> - **Test portability (SHELL-02, OPS-04, Q-007):** Replaced hardcoded `/root/projects/Interverse` path with portable three-level discovery (plugin cache → projects/ → relative path). Added `GIT_CONFIG_GLOBAL` and `GIT_CONFIG_SYSTEM` overrides for test isolation.
> - **SQL escape tests:** Validates `_interspect_sql_escape()` handles quotes, backslashes, and control chars.
> - **Agent name validation tests:** Confirms SQL injection patterns and malformed names are rejected.
> - **Path traversal tests:** Validates path validation rejects absolute and `..` paths.
> - **Percentage edge case (Q-008):** Tests integer truncation at 77.77% → 77%.

**Step 2: Run the tests**

```bash
cd /root/projects/Interverse && bats hub/clavain/tests/shell/test_interspect_routing.bats
```

Expected: all tests pass.

**Step 3: Commit**

```bash
git add hub/clavain/tests/shell/test_interspect_routing.bats
git commit -m "test(interspect): add shell tests for routing override helpers"
```

---

## Task 8: Manual Override Support + Documentation (F5)

**Files:**
- Modify: `hub/clavain/AGENTS.md` (add routing overrides documentation section)

**Step 1: Add routing overrides section to Clavain AGENTS.md**

Add a section documenting:
- What routing overrides are and how they work
- Manual override workflow with example JSON
- Available commands: `/interspect:propose`, `/interspect:revert`, `/interspect:unblock`
- Cross-cutting agent warnings
- Canary monitoring behavior

Example JSON for manual override:

```json
{
  "version": 1,
  "overrides": [
    {
      "agent": "fd-game-design",
      "action": "exclude",
      "reason": "Go backend project, no game simulation",
      "evidence_ids": [],
      "created": "2026-02-15T00:00:00Z",
      "created_by": "human"
    }
  ]
}
```

**Step 2: Commit**

```bash
git add hub/clavain/AGENTS.md
git commit -m "docs(interspect): add routing overrides documentation to AGENTS.md"
```

---

## Task 9: Integration — Wire /interspect Tier 2 Into Sprint

**Files:**
- Modify: `hub/clavain/commands/interspect.md` (final integration)

**Step 1: Final wiring**

Ensure `/interspect` command:
1. Sources lib-interspect.sh
2. Runs pattern classification (existing)
3. For "ready" patterns, checks routing eligibility and shows count
4. Shows footer: "N pattern(s) eligible for routing overrides. Run `/interspect:propose` to review exclusion proposals."
5. Does NOT present proposals or AskUserQuestion — that's `/interspect:propose`'s job

Remove the "Phase 1 notice" text and update to reflect Phase 2 capabilities.

Ensure `/interspect:propose` command:
1. Sources lib-interspect.sh
2. Detects all eligible patterns
3. Presents batch summary table + multi-select AskUserQuestion
4. For accepted agents, calls `_interspect_apply_routing_override`
5. Reports success/failure for each

**Step 2: Run all structural tests**

```bash
cd hub/clavain && uv run pytest tests/structural/ -v
cd ../plugins/interflux && uv run pytest tests/structural/ -v
```

Expected: all tests pass in both projects.

**Step 3: Final commit**

```bash
git add hub/clavain/commands/interspect.md
git commit -m "feat(interspect): wire Tier 2 routing proposals into /interspect command"
```

---

## Dependency Graph

```
Task 1 (lib-interspect.sh extensions)
  ├── Task 2 (flux-drive consumer) — independent
  ├── Task 3 (propose command) — depends on Task 1
  ├── Task 4 (apply function) — depends on Task 1
  │     └── Task 6 (/interspect integration) — depends on Tasks 3+4
  ├── Task 5 (status/revert) — depends on Task 1
  ├── Task 7 (tests) — depends on Tasks 1+4
  ├── Task 8 (docs) — independent
  └── Task 9 (final wiring) — depends on all
```

**Parallelizable groups:**
- Group A: Tasks 2, 3, 8 (independent — consumer, propose command, docs)
- Group B: Tasks 4, 5 (depend on Task 1 — apply function, revert commands)
- Group C: Tasks 6, 7 (depend on Group B — integration, tests)
- Group D: Task 9 (depends on all — final wiring)
