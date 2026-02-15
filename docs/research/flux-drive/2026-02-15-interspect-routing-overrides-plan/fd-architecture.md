# Architecture Review: Interspect Routing Overrides Implementation Plan

**Reviewer:** fd-architecture (Flux-drive architecture agent)
**Document:** `docs/plans/2026-02-15-interspect-routing-overrides.md`
**Review Date:** 2026-02-15
**Review Goal:** Find architectural issues, boundary violations, coupling risks, and missing steps in the implementation plan

---

## Findings Index

- P1 | ARCH-01 | Task 4:373-393 | Agent roster validation searches wrong paths for project-specific agents
- P2 | ARCH-02 | Task 1:Step 4:67-108 | Routing eligibility function has SQL injection vulnerability
- P2 | ARCH-03 | Task 2:Step 1:189-209 | Consumer reads file path from unvalidated env var without sanitization
- P2 | ARCH-04 | Task 4:396-460 | Apply function executes bash heredoc inside flock with insufficient error isolation
- P3 | ARCH-05 | Task 5:521-557 | Status command reads routing-overrides.json outside flock creating TOCTOU race
- P3 | ARCH-06 | Task 1:111-154, Task 4:373-393 | Duplicate agent existence check logic violates DRY
- P3 | ARCH-07 | Task 6:692-734 | Integration between /interspect and /interspect:propose creates circular dependency risk
- P3 | ARCH-08 | Global | Missing rollback logic for DB inserts when git operations succeed but DB writes fail

**Verdict:** needs-changes

---

## Summary

The plan implements a well-structured producer-consumer pattern between clavain (interspect) and interflux (flux-drive) via a shared `.claude/routing-overrides.json` file. The flock-based git serialization in Task 4 correctly prevents concurrent modification races. The blacklist table and confidence threshold extensions properly separate routing eligibility from general pattern classification.

However, the plan has several architectural defects that create reliability and security risks:

1. **Cross-module path coupling** — Task 4's agent roster validation hardcodes paths to interflux's agent directories, creating tight coupling and failing to handle project-specific agents in `.claude/agents/`. The plan searches `~/.claude/plugins/cache/interagency-marketplace/interflux/*/agents/review` which only finds marketplace-installed agents, missing git-dev installations and project agents.

2. **Security gaps** — The routing eligibility check (Task 1) builds SQL queries via string interpolation with manual escaping, but the escaping happens AFTER the agent name is used in the query template. Task 2's env var read has no validation. Task 4's bash heredoc in flock has complex quoting with insufficient error trapping.

3. **TOCTOU races outside flock** — Task 5's status command reads the routing-overrides.json file without acquiring the git lock, creating a time-of-check-time-of-use race with concurrent apply operations.

4. **Missing error recovery** — The plan documents git rollback on commit failure but has no corresponding DB rollback if the modification/canary inserts fail after a successful commit.

The core abstraction (file-based cross-plugin contract) is sound, but the implementation footprint is unnecessarily complex due to path discovery logic that should delegate to flux-drive's agent roster loader.

---

## Issues Found

### P1 | ARCH-01 | Task 4:373-393 | Agent roster validation searches wrong paths for project-specific agents

**Location:** Task 4, Step 1, lines 373-393 (apply function agent validation)

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
```

**Issue:** This path discovery logic has multiple defects:

1. **Wrong marketplace path** — The path `~/.claude/plugins/cache/interagency-marketplace/interflux/*/agents/review` assumes a specific directory structure that doesn't match Claude Code's actual marketplace cache layout. The marketplace cache uses `~/.claude/plugins/cache/<org>/<repo>/<version>/` (e.g., `~/.claude/plugins/cache/mistakeknot/interflux/0.3.1/agents/review`), NOT `interagency-marketplace/interflux/`.

2. **Missing git development installs** — If interflux is installed via `--plugin-dir` for local development, agents live at `/root/projects/Interverse/plugins/interflux/agents/review`, which is checked. But the plan checks `${root}/plugins/interflux/agents/review` where `${root}` is the TARGET PROJECT root (e.g., `/root/projects/myapp`), not the Interverse monorepo. This fails unless the target project happens to have an `interflux/` subdir.

3. **Incomplete project agent support** — Project-specific agents can live in `.claude/agents/` (correctly checked) OR in a project-local `agents/review/` directory (not checked). The plan misses the latter.

4. **Module boundary violation** — This validation duplicates flux-drive's agent roster loading logic. Interspect (clavain) now has hardcoded knowledge of interflux's directory structure, creating tight coupling. If interflux changes its agent directory layout or adds a new agent category, this code breaks.

**Impact:**
- Agent validation incorrectly rejects valid routing overrides for project-specific agents or git-dev installations
- Tight coupling between clavain and interflux means changes in either module require coordinated updates
- The validation is a false positive — flux-drive will correctly load the agent at runtime even if interspect rejects it here

**Fix:**
Remove the agent existence check entirely from the apply function. This validation is aspirational but unnecessary:

1. **Unknown agents are harmless** — If a routing override references a non-existent agent, flux-drive's triage step will simply not find the agent in its roster, log a warning (per PRD F1 requirement), and continue. No runtime failure.

2. **Validation responsibility** — Agent roster validation is flux-drive's concern, not interspect's. Interspect's job is to write a syntactically valid JSON file, not enforce semantic constraints on flux-drive's agent namespace.

3. **Simpler alternative** — If validation is required, check only that the agent name matches the pattern `fd-[a-z-]+` (avoids injection) and log a warning if the name looks suspicious. Let flux-drive handle unknown agents.

Remove lines 380-393 from Task 4 Step 1. Replace with:
```bash
# Basic validation: agent name should match expected pattern (fd-*)
if [[ ! "$agent" =~ ^fd-[a-z-]+$ ]]; then
    echo "ERROR: Invalid agent name format: ${agent}. Expected fd-<name>." >&2
    return 1
fi
# Note: Actual agent existence validated by flux-drive at triage time.
```

This removes the cross-module coupling and reduces the code footprint by 15 lines.

---

### P2 | ARCH-02 | Task 1:Step 4:67-108 | Routing eligibility function has SQL injection vulnerability

**Location:** Task 1, Step 4, lines 80-93 (routing eligibility check)

**Evidence:**
```bash
local agent="$1"
local db="${_INTERSPECT_DB:-$(_interspect_db_path)}"
local escaped="${agent//\'/\'\'}"

# Check blacklist
local blacklisted
blacklisted=$(sqlite3 "$db" "SELECT COUNT(*) FROM blacklist WHERE pattern_key = '${escaped}';")

# ...

total=$(sqlite3 "$db" "SELECT COUNT(*) FROM evidence WHERE source = '${escaped}' AND event = 'override';")
wrong=$(sqlite3 "$db" "SELECT COUNT(*) FROM evidence WHERE source = '${escaped}' AND event = 'override' AND override_reason = 'agent_wrong';")
```

**Issue:** The function uses manual SQL escaping (`${agent//\'/\'\'}`) but passes the escaped value via string interpolation. This creates two problems:

1. **Incomplete escaping** — The escaping only handles single quotes. If `$agent` contains backslashes, double quotes, or control characters, they pass through unescaped. While `_interspect_insert_evidence` sanitizes inputs at write time, this function reads from the DB and assumes all stored values are safe. A compromised DB (or bug in sanitization) could inject SQL.

2. **Pattern inconsistency** — Existing code in `lib-interspect.sh` uses the same manual escaping pattern (lines 84, 93, 254, 468-474), but this is an anti-pattern. The codebase has no parameterized query abstraction, so SQL injection risk is present everywhere user-controlled strings enter queries.

**Impact:**
- Low exploitability (requires writing malicious data to the evidence table first), but HIGH severity if triggered (arbitrary SQL execution in the interspect DB)
- The sanitization at write time (`_interspect_sanitize`) provides defense-in-depth, but this is not a guarantee — bugs in sanitization or direct DB manipulation bypass it

**Fix:**
The existing codebase already uses manual escaping consistently, so the immediate fix is to **extend the escaping to handle all SQL metacharacters**, not just single quotes. Add after line 80:

```bash
# SQL-escape all metacharacters (single quote, backslash, control chars)
local escaped="${agent//\\/\\\\}"  # Escape backslashes first
escaped="${escaped//\'/\'\'}"      # Then single quotes
escaped="${escaped//\"/\\\"}"      # Then double quotes (defense-in-depth)
escaped=$(printf '%s' "$escaped" | tr -d '\000-\037\177')  # Strip control chars
```

This matches the sanitization layer's guarantees (line 390 strips control chars) and prevents injection via backslash escaping.

**Longer-term improvement:** Add a `_interspect_sql_escape()` helper to centralize this logic and replace all 6+ manual escaping sites.

---

### P2 | ARCH-03 | Task 2:Step 1:189-209 | Consumer reads file path from unvalidated env var without sanitization

**Location:** Task 2, Step 1, lines 198-209 (flux-drive routing override reader)

**Evidence:**
```markdown
1. **Read file:** Check if `$FLUX_ROUTING_OVERRIDES_PATH` (default: `.claude/routing-overrides.json`) exists in the project root.
```

**Issue:** The plan references `$FLUX_ROUTING_OVERRIDES_PATH` as an environment variable but provides no validation of its contents. If a user sets `FLUX_ROUTING_OVERRIDES_PATH=/etc/passwd` or `FLUX_ROUTING_OVERRIDES_PATH=../../sensitive-file.json`, flux-drive will attempt to read it.

This is a **path traversal vulnerability**. The env var is concatenated with the git root:
```bash
local filepath="${FLUX_ROUTING_OVERRIDES_PATH:-.claude/routing-overrides.json}"
local fullpath="${root}/${filepath}"
```

If `filepath` contains `../`, this escapes the repo root. Example:
```bash
FLUX_ROUTING_OVERRIDES_PATH="../../../etc/passwd"
fullpath="/root/projects/myapp/../../../etc/passwd"  # resolves to /root/etc/passwd
```

**Impact:**
- Information disclosure — flux-drive could read arbitrary files on the system
- No write risk (flux-drive is read-only consumer), but the malformed JSON check would log file contents to triage output
- Low exploitability (requires user to set malicious env var), but MEDIUM severity (breaks confidentiality boundary)

**Fix:**
Add path validation in Task 1's `_interspect_read_routing_overrides()` function (lines 114-134):

```bash
_interspect_read_routing_overrides() {
    local root
    root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
    local filepath="${FLUX_ROUTING_OVERRIDES_PATH:-.claude/routing-overrides.json}"

    # Validate: reject absolute paths and parent traversal
    if [[ "$filepath" == /* ]] || [[ "$filepath" == *../* ]]; then
        echo "ERROR: FLUX_ROUTING_OVERRIDES_PATH must be a relative path without '..' (got: ${filepath})" >&2
        echo '{"version":1,"overrides":[]}'
        return 1
    fi

    local fullpath="${root}/${filepath}"
    # ... rest of function
}
```

This enforcement belongs in the producer (interspect), not the consumer (flux-drive), because interspect writes the path to the DB. Add the same check to Task 4's `_interspect_apply_routing_override()` at line 370.

---

### P2 | ARCH-04 | Task 4:396-460 | Apply function executes bash heredoc inside flock with insufficient error isolation

**Location:** Task 4, Step 1, lines 396-460 (apply routing override)

**Evidence:**
```bash
_interspect_flock_git bash -c '
    set -e
    ROOT="'"$root"'"
    FILEPATH="'"$filepath"'"
    FULLPATH="'"$fullpath"'"
    AGENT="'"$agent"'"
    REASON="'"$reason"'"
    EVIDENCE_IDS='"'"'"$evidence_ids"'"'"'
    CREATED_BY="'"$created_by"'"
    # ...
    git commit -m "[interspect] Exclude ${AGENT} from flux-drive triage
Reason: ${REASON}
Evidence: ${EVIDENCE_IDS}
Created-by: ${CREATED_BY}";
'
```

**Issue:** This heredoc injects shell variables via quote-escaping (`'"$var"'`), which is fragile and error-prone:

1. **Complex quoting** — The pattern `EVIDENCE_IDS='"'"'"$evidence_ids"'"'"'` is nearly unreadable. This is three layers of quote escaping: outer single quotes (heredoc), double quotes (bash -c), and embedded single quotes (for the JSON value). A single typo breaks the entire flow.

2. **Insufficient error trapping** — The heredoc has `set -e`, so any command failure exits. BUT the final step is `git rev-parse HEAD` (line 458) to capture the commit SHA. If this succeeds but is never read (because the flock subprocess exited), the parent function at line 467 reads the wrong SHA (leftover from a previous commit or empty).

3. **Exit code ambiguity** — The heredoc returns the exit code of `git rev-parse HEAD`. If the commit succeeds but `rev-parse` fails (e.g., detached HEAD edge case), the function reports failure even though the commit landed. The rollback at line 453 would try to restore a file that was already committed.

4. **Missing separation of concerns** — The heredoc does too much: read file, merge JSON, write file, git add, git commit, and capture SHA. Each step should be a separate function with its own error path.

**Impact:**
- If the quoting is wrong, the entire apply flow breaks (high risk during maintenance)
- If git commit succeeds but rev-parse fails, the modification record gets written with an empty or stale commit SHA, breaking canary tracking
- Error recovery is incomplete — rollback assumes commit failure, not partial success

**Fix:**
Replace the heredoc with a sequence of simple bash functions:

```bash
_interspect_flock_git _interspect_apply_override_locked \
    "$root" "$filepath" "$fullpath" "$agent" "$reason" "$evidence_ids" "$created_by"

_interspect_apply_override_locked() {
    local root="$1" filepath="$2" fullpath="$3" agent="$4"
    local reason="$5" evidence_ids="$6" created_by="$7"
    local created
    created=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # 1. Read current file
    local current
    if [[ -f "$fullpath" ]]; then
        current=$(jq '.' "$fullpath" 2>/dev/null || echo '{"version":1,"overrides":[]}')
    else
        current='{"version":1,"overrides":[]}'
    fi

    # 2. Dedup check
    if echo "$current" | jq -e --arg agent "$agent" '.overrides[] | select(.agent == $agent)' >/dev/null 2>&1; then
        echo "INFO: Override for ${agent} already exists, updating metadata."
    fi

    # 3. Build and merge override
    local new_override
    new_override=$(jq -n \
        --arg agent "$agent" --arg action "exclude" --arg reason "$reason" \
        --argjson evidence_ids "$evidence_ids" --arg created "$created" \
        --arg created_by "$created_by" \
        '{agent:$agent,action:$action,reason:$reason,evidence_ids:$evidence_ids,created:$created,created_by:$created_by}')

    local merged
    merged=$(echo "$current" | jq --argjson override "$new_override" \
        '.overrides = (.overrides + [$override] | unique_by(.agent))')

    # 4. Write
    mkdir -p "$(dirname "$fullpath")" 2>/dev/null || true
    echo "$merged" | jq '.' > "$fullpath" || return 1

    # 5. Validate write
    jq -e '.' "$fullpath" >/dev/null 2>&1 || {
        rm -f "$fullpath"
        echo "ERROR: Write produced invalid JSON, aborted" >&2
        return 1
    }

    # 6. Git add + commit
    cd "$root" || return 1
    git add "$filepath" || return 1
    git commit -m "[interspect] Exclude ${agent} from flux-drive triage

Reason: ${reason}
Evidence: ${evidence_ids}
Created-by: ${created_by}" || {
        git restore "$filepath" 2>/dev/null || git checkout -- "$filepath" 2>/dev/null || true
        echo "ERROR: Git commit failed. Override not applied." >&2
        return 1
    }

    # 7. Capture SHA AFTER successful commit
    git rev-parse HEAD
}
```

This separates the steps, eliminates complex quoting, and ensures the SHA is only captured after commit success.

---

### P3 | ARCH-05 | Task 5:521-557 | Status command reads routing-overrides.json outside flock creating TOCTOU race

**Location:** Task 5, Step 1, lines 521-557 (status command routing overrides section)

**Evidence:**
```markdown
Read and display routing overrides:

```bash
FILEPATH="${FLUX_ROUTING_OVERRIDES_PATH:-.claude/routing-overrides.json}"
ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
FULLPATH="${ROOT}/${FILEPATH}"

if [[ -f "$FULLPATH" ]] && jq -e '.' "$FULLPATH" >/dev/null 2>&1; then
    OVERRIDE_COUNT=$(jq '.overrides | length' "$FULLPATH")
    OVERRIDES=$(jq -r '.overrides[] | [.agent, .action, .reason, .created, .created_by] | @tsv' "$FULLPATH")
```

**Issue:** The status command reads the routing-overrides.json file multiple times (line-by-line for the table) without acquiring the git lock. This creates a time-of-check-time-of-use race:

1. Thread A (status command) reads the file at line 532 → sees 2 overrides
2. Thread B (apply command) acquires lock, adds a 3rd override, commits
3. Thread A reads the file again at line 533 → now sees 3 overrides
4. Thread A displays inconsistent data (count says 2, table shows 3 rows)

Worse, if apply is in-flight during status's read, the file might be in an intermediate state (write started but not committed). The `jq -e '.' check at line 532 would catch malformed JSON, but the status output would be stale/inconsistent.

**Impact:**
- Status output is non-atomic and can show inconsistent state
- Low severity (status is read-only), but violates the flock contract — if apply uses flock, status should too
- Inconsistent status reports confuse users ("I just added an override but status doesn't show it")

**Fix:**
Wrap the file read in a shared flock (read lock). Add to Task 1 (lib-interspect.sh extensions):

```bash
# Read routing-overrides.json under shared lock (non-blocking).
# Returns JSON or empty structure if locked.
_interspect_read_routing_overrides_locked() {
    local root
    root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
    local lockdir="${root}/.clavain/interspect"
    local lockfile="${lockdir}/.git-lock"

    mkdir -p "$lockdir" 2>/dev/null || true

    (
        # Shared lock (flock -s) allows concurrent reads, blocks on exclusive write lock
        if ! flock -s -w 1 9; then
            echo "WARN: Routing overrides file locked (apply in progress). Showing stale data." >&2
            # Fall back to unlocked read
            _interspect_read_routing_overrides
            return 0
        fi
        _interspect_read_routing_overrides
    ) 9>"$lockfile"
}
```

Update Task 5's status command to use `_interspect_read_routing_overrides_locked` instead of direct file reads. This ensures status sees a consistent snapshot.

---

### P3 | ARCH-06 | Task 1:111-154, Task 4:373-393 | Duplicate agent existence check logic violates DRY

**Location:** Task 1 Step 5 (lines 111-154, routing override helpers) and Task 4 Step 1 (lines 373-393, apply function)

**Evidence:**
Task 1 provides `_interspect_override_exists()` which checks if an override is already present (lines 156-164).

Task 4 duplicates this logic with a different implementation — it searches the filesystem for agent `.md` files (lines 380-393) rather than querying the routing-overrides.json file.

**Issue:** These are two different "existence" checks with different semantics:

1. **`_interspect_override_exists()`** — checks if an override entry exists in routing-overrides.json for a given agent
2. **Agent roster validation** (Task 4) — checks if the agent's `.md` file exists in flux-drive's agent directories

The plan provides both but doesn't clarify when to use which. The apply function (Task 4) does BOTH checks:
- Line 415: checks if override exists (dedup)
- Lines 380-393: checks if agent `.md` file exists (validation)

But the propose flow (Task 3) only uses `_interspect_override_exists()` (line 272: "skip if override already exists").

**Impact:**
- Code duplication increases maintenance burden (two places to update when agent discovery logic changes)
- The agent validation check in Task 4 is redundant (see ARCH-01) — flux-drive already validates agents at triage time
- The two checks have different failure modes (override exists → skip, agent not found → error), creating confusion

**Fix:**
Remove the agent roster validation from Task 4 entirely (see ARCH-01 fix). Keep only `_interspect_override_exists()` for deduplication. This eliminates the duplication and simplifies the apply flow.

---

### P3 | ARCH-07 | Task 6:692-734 | Integration between /interspect and /interspect:propose creates circular dependency risk

**Location:** Task 6 (update /interspect to include routing proposals)

**Evidence:**
```markdown
The existing `/interspect` command (Phase 1 analysis) needs to invoke Tier 2 proposal logic when patterns are "ready". Modify the command to:

1. After the pattern classification report, check for routing-eligible patterns
2. If any exist, present proposals using the AskUserQuestion flow from Task 3
3. If accepted, call `_interspect_apply_routing_override` from Task 4
```

**Issue:** The plan proposes that `/interspect` (the base command) should inline the logic from `/interspect:propose` (the specialized command). This creates three problems:

1. **Code duplication** — The proposal flow is implemented twice: once in `/interspect:propose` (Task 3) and again in `/interspect` (Task 6). Changes to the proposal UX require updating both commands.

2. **Unclear command boundaries** — Users now have two ways to trigger proposals: run `/interspect` (which auto-proposes) or run `/interspect:propose` (which explicitly proposes). When should they use which? The plan doesn't clarify.

3. **Circular dependency risk** — If `/interspect` calls the logic from `/interspect:propose`, and both commands source the same library functions, there's a risk of circular invocation. Example: if `/interspect:propose` later wants to show the pattern analysis table, it might invoke `/interspect`, creating a loop.

**Impact:**
- Unclear separation of concerns — `/interspect` becomes a "do everything" command
- Duplication increases maintenance burden (two places to update proposal logic)
- User confusion — when to use `/interspect` vs `/interspect:propose`?

**Fix:**
Keep `/interspect` (Task 6) as the analysis-only command. Do NOT inline proposals. Instead:

1. After showing the pattern analysis table, `/interspect` displays a footer: "N patterns are routing-eligible. Run `/interspect:propose` to review exclusion proposals."
2. `/interspect:propose` (Task 3) remains the single entry point for proposals
3. This keeps the commands orthogonal: `/interspect` = read-only analysis, `/interspect:propose` = write proposals

Remove Task 6's Step 1 (lines 700-724) and replace with:

```markdown
**Step 1: Add routing-eligible count to analysis footer**

After the pattern classification table in `/interspect`, add:

```bash
ELIGIBLE_COUNT=$(... | grep 'eligible$' | wc -l)
if (( ELIGIBLE_COUNT > 0 )); then
    echo "---"
    echo "${ELIGIBLE_COUNT} pattern(s) eligible for routing overrides."
    echo "Run \`/interspect:propose\` to review exclusion proposals."
fi
```
```

This preserves separation of concerns and keeps each command focused.

---

### P3 | ARCH-08 | Global | Missing rollback logic for DB inserts when git operations succeed but DB writes fail

**Location:** Task 4, lines 472-486 (modification and canary record inserts)

**Evidence:**
```bash
# DB inserts AFTER successful commit
local db="${_INTERSPECT_DB:-$(_interspect_db_path)}"
local ts
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Modification record
sqlite3 "$db" "INSERT INTO modifications (group_id, ts, tier, mod_type, target_file, commit_sha, confidence, evidence_summary, status)
    VALUES ('${agent}', '${ts}', 'persistent', 'routing', '${filepath}', '${commit_sha}', 1.0, '${reason}', 'applied');"

# Canary record
local expires_at
expires_at=$(date -u -d "+14 days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || ...)
if ! sqlite3 "$db" "INSERT INTO canary (...) VALUES (...);"; then
    echo "WARN: Canary monitoring failed — override active but unmonitored." >&2
fi
```

**Issue:** The apply flow has rollback for git commit failures (line 453: `git restore`), but NO rollback for DB failures after commit success. The sequence is:

1. Git commit succeeds (override is now active in the repo)
2. Modification record insert succeeds
3. Canary record insert FAILS (line 483 has an `if !` guard that logs a warning)

Now the system is in an inconsistent state:
- The override is active (committed to git)
- The modification record exists (canary query will find it)
- The canary record is missing (monitoring won't happen)

The plan documents this at line 484 ("override active but unmonitored"), but provides no recovery path. Worse, if the modification insert fails (line 477), there's no warning at all — the function just returns success.

**Impact:**
- Inconsistent state between git (source of truth) and DB (metadata store)
- Canary monitoring silently disabled on insert failure
- No way to detect or repair the inconsistency (status command won't flag it)

**Fix:**
The plan should document a compensating action for DB failure:

1. **Add an `[inconsistent]` status** to the modifications table. If canary insert fails, update the modification record: `UPDATE modifications SET status = 'applied-unmonitored' WHERE commit_sha = '${commit_sha}';`

2. **Status command flags inconsistent state** — In Task 5, query for `status = 'applied-unmonitored'` and display: "⚠️ Override for {agent} is active but canary monitoring failed. Manual check recommended."

3. **Optional: git revert on DB failure** — If the modification insert fails (more critical than canary), revert the commit:
   ```bash
   if ! sqlite3 "$db" "INSERT INTO modifications ..."; then
       git revert --no-edit HEAD
       echo "ERROR: Could not record modification metadata. Commit reverted." >&2
       return 1
   fi
   ```

This maintains consistency: either both git and DB succeed, or both roll back.

Add this to Task 4, Step 1, after line 478.

---

## Improvements

### 1. Simplify agent discovery by delegating to flux-drive

The plan's agent roster validation (ARCH-01) duplicates flux-drive's agent loading logic. Instead of hardcoding paths in interspect, **add an MCP tool to flux-drive** that exposes the agent roster:

```json
{
  "name": "flux_drive_list_agents",
  "description": "List all available review agents in the flux-drive roster",
  "parameters": {},
  "returns": ["fd-architecture", "fd-safety", ...]
}
```

Then interspect's validation becomes:
```bash
local agents
agents=$(mcp_call flux_drive_list_agents)
if ! echo "$agents" | jq -e --arg agent "$agent" '.[] | select(. == $agent)' >/dev/null; then
    echo "WARN: Agent ${agent} not in flux-drive roster. Override will be ignored at triage." >&2
fi
```

This delegates roster knowledge to flux-drive (where it belongs) and eliminates cross-module path coupling.

**Alternative:** Skip agent validation entirely (see ARCH-01 fix). Flux-drive already handles unknown agents gracefully.

### 2. Add integration tests for the cross-plugin contract

The plan includes shell tests for interspect helpers (Task 7) but no tests for the flux-drive consumer (Task 2). Add to Task 7:

```bash
@test "flux-drive reads routing-overrides.json and excludes agents" {
    # Write a routing override
    mkdir -p "$TEST_DIR/.claude"
    echo '{"version":1,"overrides":[{"agent":"fd-game-design","action":"exclude"}]}' \
        > "$TEST_DIR/.claude/routing-overrides.json"

    # Invoke flux-drive triage (via skill or mock)
    # Assert: fd-game-design does not appear in triage table
    # Assert: triage output includes "1 agent excluded by routing overrides"
}

@test "flux-drive warns on malformed routing-overrides.json" {
    echo '{"version":1,"overrides":[{bad json}' > "$TEST_DIR/.claude/routing-overrides.json"
    # Assert: triage output includes "routing-overrides.json malformed"
    # Assert: file moved to .corrupted
    # Assert: triage completes without error
}
```

These tests validate the producer-consumer contract and catch regressions in flux-drive's reader.

### 3. Consolidate confidence threshold loading

The plan adds `min_agent_wrong_pct` to `confidence.json` (Task 1 Step 2), but this threshold is only used by routing eligibility (Task 1 Step 4). If confidence.json is extended again in the future (e.g., for other Tier 2 features), the `_interspect_load_confidence()` function will grow.

**Improvement:** Rename `_interspect_load_confidence()` to `_interspect_load_config()` and make it load ALL interspect config files (confidence.json, protected-paths.json) in a single pass. This centralizes config loading and reduces the number of jq invocations.

### 4. Use JSON for evidence_ids parameter instead of string

Task 4's `_interspect_apply_routing_override()` accepts `$3=evidence_ids_json` as a JSON-encoded array (line 366). But the function immediately passes this to jq via `--argjson evidence_ids "$evidence_ids"` (line 424).

If `$evidence_ids` is NOT valid JSON (e.g., user passes a string instead of an array), jq will fail silently and write `"evidence_ids": null` to the file. This breaks canary tracking (evidence linkage is lost).

**Fix:** Validate the parameter at function entry:
```bash
_interspect_apply_routing_override() {
    local agent="$1"
    local reason="$2"
    local evidence_ids="${3:-[]}"
    local created_by="${4:-interspect}"

    # Validate evidence_ids is valid JSON array
    if ! echo "$evidence_ids" | jq -e 'type == "array"' >/dev/null 2>&1; then
        echo "ERROR: evidence_ids must be a JSON array (got: ${evidence_ids})" >&2
        return 1
    fi
    # ...
}
```

Add this to Task 4, Step 1, after line 367.

### 5. Document the file format contract explicitly

The plan specifies the routing-overrides.json schema in the PRD (F1) but doesn't add a reference schema file. Add to Task 8 (documentation):

**Create `hub/clavain/.clavain/interspect/routing-overrides.schema.json`:**
```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "type": "object",
  "required": ["version", "overrides"],
  "properties": {
    "version": {
      "type": "integer",
      "const": 1,
      "description": "Schema version. Must be 1."
    },
    "overrides": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["agent", "action", "created", "created_by"],
        "properties": {
          "agent": {"type": "string", "pattern": "^fd-[a-z-]+$"},
          "action": {"type": "string", "enum": ["exclude"]},
          "reason": {"type": "string"},
          "evidence_ids": {"type": "array", "items": {"type": "integer"}},
          "created": {"type": "string", "format": "date-time"},
          "created_by": {"type": "string", "enum": ["interspect", "human"]}
        }
      }
    }
  }
}
```

Reference this schema in AGENTS.md documentation (Task 8) and optionally validate files against it in the status command.

---

## Conclusion

The plan's core architecture is sound: a file-based producer-consumer contract with flock-based serialization correctly prevents races. The separation of routing eligibility (agent_wrong_pct threshold) from general pattern classification (counting rules) is clean.

However, the implementation has several defects:

1. **Cross-module coupling** (ARCH-01) — Agent roster validation hardcodes interflux paths
2. **Security gaps** (ARCH-02, ARCH-03, ARCH-04) — SQL injection risk, path traversal, complex heredoc quoting
3. **Inconsistent locking** (ARCH-05) — Status reads outside flock
4. **Incomplete error recovery** (ARCH-08) — No rollback for DB failures after git success
5. **Duplication** (ARCH-06, ARCH-07) — Agent existence check, proposal logic inlined twice

The P1 and P2 issues should be fixed before implementation. The P3 issues are lower-risk but reduce maintainability.

The plan's complexity footprint could be reduced by:
- Removing agent validation (ARCH-01 fix) — saves 15 lines, removes coupling
- Delegating to flux-drive's roster loader (Improvement #1) — better separation of concerns
- Keeping /interspect and /interspect:propose orthogonal (ARCH-07 fix) — clearer command boundaries

With these fixes, the plan delivers a robust cross-plugin feedback loop for agent relevance learning.
