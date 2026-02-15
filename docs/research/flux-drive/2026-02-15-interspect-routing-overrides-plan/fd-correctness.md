# Correctness Review: Interspect Routing Overrides Implementation Plan

**Reviewer:** Julik (flux-drive correctness)
**Date:** 2026-02-15
**Document:** `docs/plans/2026-02-15-interspect-routing-overrides.md`

---

## Findings Index

- P0 | RACE-01 | Task 4, Step 1 | TOCTOU race after dedup check — flock released before git commit
- P0 | DATA-01 | Task 4, Step 1 | Rollback failure leaves inconsistent state (git vs DB)
- P1 | RACE-02 | Task 1, Step 5 | Read racing with concurrent writes — no lock acquisition
- P1 | DATA-02 | Task 4, Step 1 | DB inserts run even if override had no effect (dedup branch)
- P1 | SHELL-01 | Task 4, Step 1 | Unquoted variable substitution in nested bash -c
- P2 | SHELL-02 | Task 7, Step 1 | Hardcoded path assumes Interverse monorepo layout
- P2 | DATA-03 | Task 1, Step 4 | Missing blacklist unique constraint allows duplicates
- P2 | DATA-04 | Task 4, Step 1 | Missing agent roster validation (commented as required)

**Verdict:** Needs changes

---

## Summary

The plan implements a cross-plugin producer-consumer system for routing overrides with strong intentions around atomicity and locking, but contains three critical correctness failures that would lead to data corruption or race conditions in production.

The most severe issue (P0 RACE-01) is a fundamental misunderstanding of how flock scope works in bash. The flock is acquired via a subshell `( ... ) 9>"$lockfile"`, but the DB inserts run AFTER the flock block exits. This means the git commit happens under lock, but the DB writes that record the commit SHA run without synchronization, creating a TOCTOU window where two concurrent sessions can both commit different overrides for the same agent, then both write conflicting DB records referencing different SHAs. The plan explicitly states "DB inserts AFTER successful commit" (line 471-486) as if this were safe, but it breaks the entire atomicity guarantee.

The second P0 issue (DATA-01) is that the compensating-action rollback uses `git restore` which restores the working tree but does NOT roll back the index if the commit fails after `git add`. This leaves the file staged but not committed, causing the next git operation (possibly from the user) to accidentally commit the failed override. The rollback must use `git reset HEAD <file>` to unstage.

The architecture otherwise demonstrates good defensive patterns: jq for JSON (not sed), SQL escaping via double-quoting, validation before writes, and a clear separation between producer and consumer. However, the execution-level bugs undermine these intentions.

---

## Issues Found

### P0 | RACE-01 | Task 4, Step 1 | TOCTOU race after dedup check — flock released before git commit

**Location:** Task 4, Step 1, lines 396-489

**Evidence:**

The plan shows this structure:

```bash
_interspect_flock_git bash -c '
    set -e
    # ... read, dedup check, write, git add, git commit ...
    git rev-parse HEAD
'

local exit_code=$?
# ... capture commit_sha ...
commit_sha=$(git rev-parse HEAD)

# DB inserts AFTER successful commit
local db="${_INTERSPECT_DB:-$(_interspect_db_path)}"
sqlite3 "$db" "INSERT INTO modifications ..."
sqlite3 "$db" "INSERT INTO canary ..."
```

The flock is released when the `bash -c` subshell exits. The DB inserts run AFTER the flock is released.

**Failure narrative:**

1. Session A acquires flock, reads routing-overrides.json (empty), writes override for agent=fd-safety, runs git commit, releases flock, captures commit SHA1
2. Session B acquires flock (A released it), reads routing-overrides.json (still contains A's override from working tree but not yet pushed), writes override for agent=fd-correctness, runs git commit, releases flock, captures SHA2
3. Session A inserts modification record with commit_sha=SHA1, group_id=fd-safety
4. Session B inserts modification record with commit_sha=SHA2, group_id=fd-correctness
5. Both commits exist in git history, but if there's a merge conflict or rebase later, one override may be lost silently
6. More critically: if both sessions target the SAME agent (dedup check passed for both because reads happened at same instant), the file will contain only one override (last write wins), but TWO modification records will reference different SHAs, creating an orphaned canary for the lost override

The PRD explicitly requires "DB inserts after commit" (line 64) but this is unsafe without extending the flock scope.

**Impact:**

- High-probability race when multiple Claude sessions run `/interspect:propose` concurrently
- Can produce orphaned DB records referencing non-existent or overwritten overrides
- Canary monitoring fails because group_id in DB doesn't match the actual override in the file
- Revert operations fail because commit SHA in DB may not match the SHA that introduced the override

**Fix:**

Move DB inserts inside the flock block BEFORE releasing the lock:

```bash
_interspect_flock_git bash -c '
    set -e
    # ... read, write, git add, git commit ...
    COMMIT_SHA=$(git rev-parse HEAD)
    TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # DB inserts INSIDE flock, using commit SHA from this session
    sqlite3 "$DB" "INSERT INTO modifications ..."
    sqlite3 "$DB" "INSERT INTO canary ..."

    echo "$COMMIT_SHA"  # Output for caller
'
```

Pass `DB` path and other variables into the bash -c environment, and output the commit SHA on the last line. Caller captures it via command substitution.

**Alternative fix (if DB writes must be outside flock):**

Use a second lock for DB writes, or use SQLite's built-in row-level locking with `BEGIN IMMEDIATE` to serialize modifications table writes. But this is more complex and still vulnerable to git/DB inconsistency if the process crashes between commit and DB insert.

---

### P0 | DATA-01 | Task 4, Step 1 | Rollback failure leaves inconsistent state (git vs DB)

**Location:** Task 4, Step 1, lines 451-455

**Evidence:**

```bash
if ! git commit -m "[interspect] ..."; then
    # Rollback on commit failure
    git restore "$FILEPATH" 2>/dev/null || git checkout -- "$FILEPATH" 2>/dev/null || true
    echo "ERROR: Git commit failed. Override not applied." >&2
    exit 1
fi
```

**Failure narrative:**

1. Write succeeds, writes routing-overrides.json to working tree
2. `git add .claude/routing-overrides.json` stages the file
3. `git commit` fails (pre-commit hook rejects it, disk full, process killed)
4. Compensating action runs `git restore .claude/routing-overrides.json`
5. `git restore` restores the WORKING TREE from the index, but the file is ALREADY STAGED
6. Result: working tree matches HEAD (looks clean), but `git status` shows `.claude/routing-overrides.json` staged for commit
7. User's next `git commit` (unrelated work) accidentally commits the failed override

**Additional failure mode:**

The plan says "DB inserts AFTER successful commit" (line 471), so in this failure scenario, the DB is clean (no modification record). But if the rollback is incomplete, the file might be partially written or staged. The next session's `_interspect_read_routing_overrides` will read the staged version if the working tree is clean but index is dirty.

**Impact:**

- Staged changes leak into unrelated commits
- User confusion when routing override "appears" in a commit they didn't intend
- Violates the atomicity guarantee promised in F3 acceptance criteria

**Fix:**

Use `git reset HEAD -- "$FILEPATH"` to unstage, THEN restore working tree:

```bash
if ! git commit -m "[interspect] ..."; then
    # Rollback: unstage AND restore working tree
    git reset HEAD -- "$FILEPATH" 2>/dev/null || true
    git restore "$FILEPATH" 2>/dev/null || git checkout -- "$FILEPATH" 2>/dev/null || true
    echo "ERROR: Git commit failed. Override not applied." >&2
    exit 1
fi
```

Or use `git reset --hard HEAD` if no other uncommitted work is expected in the interspect flow (more aggressive but safer).

---

### P1 | RACE-02 | Task 1, Step 5 | Read racing with concurrent writes — no lock acquisition

**Location:** Task 1, Step 5, lines 114-134 (`_interspect_read_routing_overrides`)

**Evidence:**

```bash
_interspect_read_routing_overrides() {
    local root
    root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
    local filepath="${FLUX_ROUTING_OVERRIDES_PATH:-.claude/routing-overrides.json}"
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
```

No lock acquisition. Used in:
- `_interspect_override_exists` (Task 1, line 159-164) — called from propose flow to check dedup
- Consumer (flux-drive) reads it during triage (Task 2)

**Failure narrative:**

1. Session A (propose flow) calls `_interspect_override_exists("fd-safety")` → reads file, sees no override, returns 1
2. Session B (apply flow) acquires flock, writes override for fd-safety, commits, releases flock
3. Session A proceeds to propose exclusion for fd-safety (dedup check passed)
4. User accepts proposal
5. Session A acquires flock, reads file (now contains fd-safety from B), writes DUPLICATE entry, uses `unique_by(.agent)` to dedup at write time → no error, but creates confusing "updated metadata" log for a proposal that should never have been offered

This is less severe than RACE-01 because the `unique_by` dedup at write time (line 431) acts as a safety net. But it's still a correctness bug: the user is shown a stale proposal.

**Impact:**

- Medium: Stale proposals shown to user (UX bug)
- Wasted tokens asking user about already-applied overrides
- Confusing "updated metadata" logs when user accepts a stale proposal

**Fix:**

Option 1 (conservative): Acquire flock for ALL reads. Wrap `_interspect_read_routing_overrides` body in `_interspect_flock_git bash -c '...'`.

Option 2 (optimistic): Accept this race and rely on dedup-at-write-time. Add a comment explaining the race is tolerated. Before showing proposal, re-check `_interspect_override_exists` AFTER user clicks "Accept" but BEFORE entering the flock block. Show "Override was applied by another session, skipping."

---

### P1 | DATA-02 | Task 4, Step 1 | DB inserts run even if override had no effect (dedup branch)

**Location:** Task 4, Step 1, lines 414-417 and 471-486

**Evidence:**

```bash
# Dedup check inside lock (TOCTOU protection)
if echo "$CURRENT" | jq -e --arg agent "$AGENT" ".overrides[] | select(.agent == \$agent)" >/dev/null 2>&1; then
    echo "INFO: Override for ${AGENT} already exists, updating metadata."
fi
```

The code logs "updating metadata" but does NOT skip the subsequent write or commit. The `unique_by(.agent)` merge (line 431) will overwrite the existing entry.

Later (lines 471-486), the plan unconditionally inserts a modification record and canary record AFTER the commit, regardless of whether the commit introduced a NEW override or just updated metadata of an existing one.

**Failure narrative:**

1. Override for fd-safety exists in file with `created: 2026-02-01, created_by: interspect`
2. Another session proposes excluding fd-safety again (maybe evidence grew)
3. User accepts
4. Apply flow runs, dedup check detects existing override, logs "updating metadata", merges with `unique_by(.agent)` (last write wins for `created`, `reason`, `evidence_ids`)
5. Git commit succeeds (file changed, metadata updated)
6. DB insert creates a SECOND modification record with new commit_sha and new canary
7. Result: Two canary records monitoring the same agent, two modification records for the same override

**Impact:**

- Canary table accumulates duplicate monitoring records
- Modification history is confusing (multiple "applied" records for same agent)
- Revert logic may hit the wrong record if targeting by agent name
- Status display shows duplicate entries or inconsistent canary state

**Fix:**

Before running DB inserts, check if the override is new or updated:

```bash
# Inside flock block, after reading CURRENT
EXISTING=$(echo "$CURRENT" | jq --arg agent "$AGENT" '.overrides[] | select(.agent == $agent)')
IS_NEW=0
if [[ -z "$EXISTING" ]]; then
    IS_NEW=1
fi

# ... merge and write ...

# Only insert DB records for NEW overrides
if (( IS_NEW == 1 )); then
    sqlite3 "$db" "INSERT INTO modifications ..."
    sqlite3 "$db" "INSERT INTO canary ..."
else
    echo "INFO: Override for ${AGENT} already exists. Metadata updated, no new canary."
fi
```

---

### P1 | SHELL-01 | Task 4, Step 1 | Unquoted variable substitution in nested bash -c

**Location:** Task 4, Step 1, lines 396-459

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
    ...
'
```

The EVIDENCE_IDS assignment uses triple-nested single quotes to inject the JSON array value. This is fragile and error-prone.

Later in the script (line 424):

```bash
NEW_OVERRIDE=$(jq -n \
    --arg agent "$AGENT" \
    --arg action "exclude" \
    --arg reason "$REASON" \
    --argjson evidence_ids "$EVIDENCE_IDS" \
    ...
```

If `$evidence_ids` from the outer scope contains shell metacharacters, the triple-quote nesting may break. Example: if `evidence_ids='[1,2,3]"$(rm -rf /)"'`, the nested string becomes:

```bash
EVIDENCE_IDS='[1,2,3]"$(rm -rf /)"'
```

Inside the bash -c, `$EVIDENCE_IDS` expands to the malicious string, which jq may interpret or reject. More critically, if the nesting is wrong, the `$(...)` could execute.

**Impact:**

- Low probability in practice (evidence_ids is constructed from interspect DB integer IDs)
- But violates defense-in-depth: user-controlled evidence context could pollute IDs
- If evidence IDs are ever sourced from user input, this becomes a shell injection vector

**Fix:**

Pass variables via environment, not inline string substitution:

```bash
_interspect_flock_git env \
    ROOT="$root" \
    FILEPATH="$filepath" \
    FULLPATH="$fullpath" \
    AGENT="$agent" \
    REASON="$reason" \
    EVIDENCE_IDS="$evidence_ids" \
    CREATED_BY="$created_by" \
    bash -c '
    set -e
    CREATED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    # ... rest of script uses $ROOT, $AGENT, etc directly ...
    NEW_OVERRIDE=$(jq -n \
        --arg agent "$AGENT" \
        --argjson evidence_ids "$EVIDENCE_IDS" \
        ...)
'
```

This avoids quote hell and uses the shell's native environment passing.

---

### P2 | SHELL-02 | Task 7, Step 1 | Hardcoded path assumes Interverse monorepo layout

**Location:** Task 7, Step 1, line 774

**Evidence:**

```bash
INTERSPECT_LIB="$(find /root/projects/Interverse/hub/clavain -name lib-interspect.sh -type f | head -1)"
source "$INTERSPECT_LIB"
```

This bats test setup hardcodes the Interverse monorepo path. If the test runs in CI, on a different developer machine, or after clavain is installed via the plugin cache, the path won't exist.

**Impact:**

- Tests fail outside the exact development environment layout
- CI must replicate `/root/projects/Interverse/` structure
- Not portable to other contributors

**Fix:**

Use the same discovery pattern as the commands (Task 3, lines 251-257):

```bash
INTERSPECT_LIB=$(find ~/.claude/plugins/cache -path '*/clavain/*/hooks/lib-interspect.sh' 2>/dev/null | head -1)
[[ -z "$INTERSPECT_LIB" ]] && INTERSPECT_LIB=$(find ~/projects -path '*/hub/clavain/hooks/lib-interspect.sh' 2>/dev/null | head -1)
if [[ -z "$INTERSPECT_LIB" ]]; then
    echo "Error: Could not locate hooks/lib-interspect.sh" >&2
    skip "lib-interspect.sh not found in plugin cache or projects/"
fi
source "$INTERSPECT_LIB"
```

Or allow `INTERSPECT_LIB` to be set via environment variable for test isolation.

---

### P2 | DATA-03 | Task 1, Step 1 | Missing UNIQUE constraint on blacklist.pattern_key

**Location:** Task 1, Step 1, lines 28-35

**Evidence:**

```sql
CREATE TABLE IF NOT EXISTS blacklist (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    pattern_key TEXT NOT NULL UNIQUE,
    blacklisted_at TEXT NOT NULL,
    reason TEXT
);
CREATE INDEX IF NOT EXISTS idx_blacklist_key ON blacklist(pattern_key);
```

The schema shows `UNIQUE` on `pattern_key` (line 30), which is correct. However, the revert command (Task 5, Step 2, lines 628-629) uses:

```bash
sqlite3 "$DB" "INSERT OR REPLACE INTO blacklist (pattern_key, blacklisted_at, reason) VALUES ('${AGENT}', '${TS}', 'User reverted via /interspect:revert');"
```

The `INSERT OR REPLACE` syntax will UPDATE the row if pattern_key exists, which is fine. But if the UNIQUE constraint were missing, concurrent reverts of the same agent could create duplicate blacklist entries.

**Impact:**

- Low: The schema is correct as written
- Risk: If the UNIQUE constraint is accidentally omitted during schema migration or manual DB repair, duplicate blacklist entries accumulate
- Unblock command (Task 5, Step 3, line 671) uses `DELETE FROM blacklist WHERE pattern_key = '${AGENT}'`, which would delete all duplicates, so the inconsistency is somewhat self-healing

**Fix:**

No code change needed. Add a comment in the schema explaining the UNIQUE constraint is load-bearing for the INSERT OR REPLACE pattern in revert.

---

### P2 | DATA-04 | Task 4, Step 1 | Missing agent roster validation

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

This validation runs BEFORE entering the flock block. If the agent roster changes (agent file deleted, plugin upgraded) between validation and write, the override may reference a nonexistent agent.

More critically: the validation uses a hardcoded glob pattern that assumes:
1. Interflux is installed from the interagency-marketplace
2. The marketplace cache path matches `~/.claude/plugins/cache/interagency-marketplace/interflux/*/`
3. Agents live in `agents/review/`

If the marketplace structure changes, or if agents move to a different directory, the validation silently fails (returns 0 false negatives).

**Failure narrative:**

1. Interflux is installed from a different marketplace or checked out locally
2. Agent roster path is `~/.claude/plugins/cache/my-marketplace/interflux/v1.2.3/agents/review/`
3. Validation glob doesn't match → `agent_found=0`
4. Function returns error even though agent exists
5. User cannot create routing overrides (false rejection)

Alternatively:

1. Agent fd-game-design exists at validation time
2. Between validation and flock acquisition, interflux plugin is upgraded and fd-game-design is removed
3. Validation passed, override is written
4. Flux-drive reads override, logs "WARNING: Routing override for unknown agent fd-game-design"
5. Override is ignored, but remains in file (orphaned)

**Impact:**

- Medium: False rejections if marketplace structure doesn't match expectations
- Low: TOCTOU window for agent deletion is small (seconds)
- Status command (Task 5) handles orphaned agents via the "agent removed from roster" flag (line 79), so the inconsistency is detectable

**Fix:**

Move validation inside the flock block, after reading the current overrides but before writing. Or make the validation failure non-fatal (log warning) and rely on flux-drive's "unknown agent" handling.

Better long-term fix: Query flux-drive's agent roster dynamically via an MCP tool or CLI command, rather than hardcoding filesystem paths.

---

## Improvements

### 1. Atomic file writes using temp + rename

The plan uses direct writes to routing-overrides.json (Task 1, Step 3, line 146):

```bash
echo "$content" | jq '.' > "$fullpath"
```

This is not atomic. If the process crashes mid-write, the file is corrupted. Standard pattern:

```bash
local tmpfile="${fullpath}.tmp.$$"
echo "$content" | jq '.' > "$tmpfile"
if ! jq -e '.' "$tmpfile" >/dev/null 2>&1; then
    rm -f "$tmpfile"
    echo "ERROR: Write produced invalid JSON" >&2
    return 1
fi
mv "$tmpfile" "$fullpath"
```

The plan includes validation (line 148-153) but doesn't use a temp file. Add atomic write.

### 2. WAL mode for concurrent reads

The existing interspect DB already uses `PRAGMA journal_mode=WAL;` (lib-interspect.sh line 58). The plan doesn't mention this for routing-overrides.json reads, but it's irrelevant because routing-overrides.json is a plain JSON file.

However, the SQLite modifications and canary tables WILL have concurrent reads (status command) and writes (apply flow). Verify that all SQLite connections use WAL mode (already done in lib-interspect.sh, so no change needed).

### 3. Add retry logic for flock timeout

The `_interspect_flock_git` function (lib-interspect.sh lines 327-342) uses `flock -w 30` with a 30-second timeout. If the lock times out, the operation fails hard.

For propose/apply flows (user-facing), consider a retry with exponential backoff:

```bash
for attempt in 1 2 3; do
    if _interspect_flock_git bash -c '...'; then
        break
    fi
    if (( attempt < 3 )); then
        echo "Retrying in $((attempt * 2))s..." >&2
        sleep $((attempt * 2))
    fi
done
```

This reduces false failures when two sessions race for the lock.

### 4. Explicit session isolation for tests

The bats tests (Task 7) create a tmpdir per test but use the current user's git config. If tests run concurrently (bats --jobs), they may conflict on the tmpdir or shared git config. Use `GIT_CONFIG_GLOBAL` and `GIT_CONFIG_SYSTEM` overrides:

```bash
setup() {
    export TEST_DIR=$(mktemp -d)
    export HOME="$TEST_DIR"
    export GIT_CONFIG_GLOBAL="$TEST_DIR/.gitconfig"
    export GIT_CONFIG_SYSTEM=/dev/null
    # ... rest of setup ...
}
```

This isolates tests fully.

### 5. Canary expiry uses GNU/BSD date incompatibility

Task 4, line 481-482:

```bash
expires_at=$(date -u -d "+14 days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v+14d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
```

This tries GNU `date -d` then BSD `date -v`. The fallback `echo ""` silently accepts missing expiry. Better to fail hard if neither works:

```bash
if date -u -d "+14 days" +%Y-%m-%dT%H:%M:%SZ >/dev/null 2>&1; then
    expires_at=$(date -u -d "+14 days" +%Y-%m-%dT%H:%M:%SZ)
elif date -u -v+14d +%Y-%m-%dT%H:%M:%SZ >/dev/null 2>&1; then
    expires_at=$(date -u -v+14d +%Y-%m-%dT%H:%M:%SZ)
else
    echo "ERROR: date command does not support relative dates" >&2
    return 1
fi
```

Or use Python/jq for portable date arithmetic.

### 6. Validate FLUX_ROUTING_OVERRIDES_PATH is relative

The consumer (Task 2) and producer (Task 4) both use:

```bash
local filepath="${FLUX_ROUTING_OVERRIDES_PATH:-.claude/routing-overrides.json}"
local fullpath="${root}/${filepath}"
```

If `FLUX_ROUTING_OVERRIDES_PATH` is set to an absolute path (e.g., `/tmp/overrides.json`), the concatenation produces `$root//tmp/overrides.json`, which may resolve to `/tmp/overrides.json` (leading slashes collapse).

This could allow an attacker to write overrides outside the repo. Add validation:

```bash
if [[ "$filepath" =~ ^/ ]]; then
    echo "ERROR: FLUX_ROUTING_OVERRIDES_PATH must be relative, got: $filepath" >&2
    return 1
fi
```

Or normalize with `realpath --relative-to="$root"`.

---

## Recommendations Summary

### Must fix before merge (P0)

1. **RACE-01:** Move DB inserts inside flock block or use separate DB-level transaction lock
2. **DATA-01:** Use `git reset HEAD` to unstage file in rollback path

### Should fix before merge (P1)

3. **RACE-02:** Either acquire flock for reads, or add re-check after user accepts stale proposal
4. **DATA-02:** Track whether override is new vs updated, skip DB insert for updates
5. **SHELL-01:** Use `env` to pass variables into bash -c subshell

### Nice to have (P2, can defer to follow-up)

6. **SHELL-02:** Use portable lib discovery in bats tests
7. **DATA-03:** Add comment documenting UNIQUE constraint importance
8. **DATA-04:** Move agent validation inside flock or make non-fatal

### Defense in depth (non-blocking)

9. Atomic file writes via temp + rename
10. Add retry logic for flock timeout in user-facing flows
11. Explicit git config isolation in tests
12. Fail hard on missing date command portability
13. Validate FLUX_ROUTING_OVERRIDES_PATH is relative path

---

## Closing Note

This plan demonstrates good architectural instincts (jq not sed, SQL escaping, validation gates, compensating actions) but the execution-level locking and rollback bugs would cause silent data corruption in multi-session scenarios. The flock scope bug (RACE-01) is especially subtle because it LOOKS correct at first glance (the git operations are under flock), but the DB consistency depends on writes that happen AFTER the lock is released.

Fix the P0 issues and the plan becomes production-ready. The P1/P2 issues are reliability/UX bugs that should be addressed but won't cause data loss.
