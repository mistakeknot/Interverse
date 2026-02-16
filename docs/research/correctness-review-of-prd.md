# Correctness Review: Interstat PRD (2026-02-16)

**Reviewer:** Julik (Flux-drive Correctness Reviewer)
**Date:** 2026-02-15
**Source:** `/root/projects/Interverse/docs/prds/2026-02-16-interstat-token-benchmarking.md`

## Summary

**Critical Issues:** 2 race conditions, 1 correlation failure mode, 1 grouping heuristic weakness
**Moderate Issues:** 1 idempotency gap, 1 SQL approximation error
**Severity:** HIGH — data corruption and silent data loss are both possible under documented usage patterns

---

## 1. Race Conditions: Concurrent SQLite Writers

### Issue 1.1: PostToolUse Hook vs. JSONL Parser (CRITICAL)

**Problem:** The PRD specifies two writers to the same SQLite database:
- **F1 (PostToolUse hook):** Fires on every Task invocation, INSERTs row into `agent_runs`
- **F2 (JSONL parser):** Backfills token data via UPDATE on same rows

Additionally, F2 has two trigger modes:
- SessionEnd hook (lightweight, current session only)
- `interstat analyze` skill (full historical parse)

**Race timeline:**
```
T0: User dispatches 4 parallel agents via /flux-drive
T1: PostToolUse hooks fire concurrently (4 processes, 4 INSERTs)
T2: First agent finishes, SessionEnd hook triggers JSONL parser
T3: Parser runs UPDATE on agent_runs for session_id=X
T4: Remaining 3 agents still running, may finish and trigger PostToolUse
T5: If user runs `interstat analyze` while agents are active → concurrent UPDATE/INSERT
```

**SQLite WAL Implications:**
- WAL mode allows concurrent readers with one writer
- BUT: each process must acquire the write lock sequentially
- BUSY timeout (default 0ms) → immediate `SQLITE_BUSY` if another writer holds lock
- PRD says "graceful degradation: if SQLite is locked or missing, log warning and exit 0"
- **This is data loss**: if PostToolUse fails silently, we never INSERT the row. JSONL parser can't backfill what doesn't exist.

**Failure Narrative:**
1. Flux-drive launches 4 agents in parallel
2. All 4 PostToolUse hooks fire within ~50ms window
3. First hook acquires write lock, begins INSERT
4. Hooks 2-4 get SQLITE_BUSY, log warning, exit 0 (per "graceful degradation")
5. Only 1 of 4 runs recorded in database
6. SessionEnd parser finds JSONL entries for 4 agents, only 1 matching row
7. 3 agents silently dropped from metrics
8. Decision gate query runs on 25% of actual data → incorrect verdict

**Why this matters:**
The PRD explicitly targets parallel dispatch scenarios (flux-drive with 4 agents). Silent data loss on the happy path invalidates the entire measurement system.

### Issue 1.2: Concurrent JSONL Parser Invocations (MODERATE)

**Problem:** If user runs `interstat analyze` (full parse) while SessionEnd hook also triggers parser:
- Both processes may scan same conversation JSONL
- Both may attempt UPDATE on same `agent_runs` rows
- Idempotency check (F2: "re-running on already-parsed sessions is a no-op") relies on checking `parsed_at IS NOT NULL`
- Race: both processes read `parsed_at=NULL`, both decide to parse, both UPDATE

**Consequence:**
Not data corruption (final state is correct), but wasted work and potential lock contention that cascades back to Issue 1.1.

### Recommended Fix:

**For Issue 1.1 (CRITICAL):**
- **Never fail silently on SQLITE_BUSY in PostToolUse hook.**
- Set `PRAGMA busy_timeout = 5000;` (5s) at connection time.
- If timeout expires, log error AND create a fallback record:
  ```bash
  # F1 hook fallback
  echo "$HOOK_INPUT" >> ~/.claude/interstat/failed_inserts.jsonl
  ```
- JSONL parser (F2) MUST read `failed_inserts.jsonl` on every run and reconstruct missing rows.
- This ensures no data loss even under extreme lock contention.

**For Issue 1.2 (MODERATE):**
- Use a PID-based lock file for JSONL parser:
  ```bash
  lock_file="$DB_DIR/parser.lock"
  if ! mkdir "$lock_file" 2>/dev/null; then
    echo "Parser already running ($(cat "$lock_file/pid" 2>/dev/null || echo "unknown")), skipping"
    exit 0
  fi
  trap "rm -rf '$lock_file'" EXIT
  echo $$ > "$lock_file/pid"
  ```
- This prevents concurrent parser runs (SessionEnd vs. manual analyze).
- Combine with `parsed_at` check for idempotency within a single parser run.

---

## 2. Data Correlation: Matching JSONL to agent_runs Rows

### Issue 2.1: Correlation Key Fragility (HIGH)

**PRD states:**
> "Correlates JSONL entries to `agent_runs` rows by session_id + agent_name + timestamp proximity"

**Problem:** "timestamp proximity" is not defined. How close is "proximate"?

**JSONL vs. Hook Timing:**
- PostToolUse hook records `wall_clock_ms` when Task completes (T_complete)
- JSONL API response entries are timestamped when API call finishes (T_api_response)
- For long-running agents, T_api_response can be minutes after T_complete
- For streaming responses, multiple JSONL entries per agent run

**Failure Narrative:**
```
Session X, agent "correctness-reviewer":
- T0 (10:00:00): Task dispatched
- T1 (10:05:30): First API response (5.5min later) → JSONL entry 1
- T2 (10:07:45): Second API response (streaming continuation) → JSONL entry 2
- T3 (10:08:00): Tool use complete → PostToolUse hook fires

Hook records: session_id=X, agent_name="correctness-reviewer", wall_clock_ms=480000
JSONL entries: timestamps 10:05:30, 10:07:45
Proximity matcher: looking for JSONL entries "near" 10:08:00
Result: no match if proximity window <2min, or wrong match if another agent finishes nearby
```

**Additional complication:** If flux-drive runs 4 agents, JSONL will interleave responses from all 4. Without `subagent_type` field in the JSONL (Open Question 1), correlation is impossible.

### Issue 2.2: Streaming Responses and Token Aggregation (MODERATE)

**Problem:** Long agent runs may have multiple API requests (continuation, tool use loops). Each generates a separate JSONL entry with `usage` metadata. How do we aggregate?

**Example:**
```
Agent "architecture-review" makes 3 API calls:
- Call 1: 15K input, 8K output, 12K cache_hit
- Call 2: 20K input, 10K output, 15K cache_hit
- Call 3: 18K input, 6K output, 18K cache_hit

Total: 53K input, 24K output, 45K cache_hit

But if correlation only matches Call 3 (latest timestamp), we record 18K input instead of 53K.
```

**Decision gate impact:**
If we systematically under-count multi-turn agents, p99 calculation is wrong. If p99 actual is 140K but we measure 90K due to missing early turns, we skip hierarchical dispatch incorrectly.

### Recommended Fix:

**For Issue 2.1:**
- **Stop using timestamp proximity.** Instead:
  1. PostToolUse hook generates a UUID (`invocation_id`) and stores it in `agent_runs`.
  2. Hook also writes the UUID to a session-scoped temp file:
     ```bash
     echo "$invocation_id" >> ~/.claude/sessions/$session_id/interstat_pending.txt
     ```
  3. JSONL parser reads `interstat_pending.txt` for the session, knows which UUIDs need backfill.
  4. Match by: session_id + agent_name + pending UUID + JSONL timestamp after hook timestamp.
  5. Clear UUID from `pending.txt` after successful backfill.

**For Issue 2.2:**
- **Sum all API calls for the same agent invocation.**
- JSONL parser must:
  1. Read all JSONL entries for session_id=X, agent_name=Y, timestamp >= T_hook
  2. Stop at next Task dispatch or session end
  3. SUM(input_tokens), SUM(output_tokens), SUM(cache_hit_tokens)
  4. UPDATE single agent_runs row with totals

- Add explicit test case: multi-turn agent with 3+ API calls, verify total_tokens matches sum.

---

## 3. Invocation Grouping: Timestamp Clustering Heuristic

### Issue 3.1: 2-Second Window is Too Narrow (MODERATE)

**PRD Open Question 2:**
> "how to detect that 4 Task calls are part of the same `/flux-drive` invocation vs. independent calls? Timestamp clustering (within 2s) + same session is the likely heuristic."

**Problem:** Task dispatch timestamp != hook fire timestamp.

**Scenario:**
```
User runs `/flux-drive` with 4 agents at 10:00:00.
- Agent 1 (quick): finishes at 10:00:30 → PostToolUse at T+30s
- Agent 2 (medium): finishes at 10:02:15 → PostToolUse at T+135s
- Agent 3 (slow): finishes at 10:05:00 → PostToolUse at T+300s
- Agent 4 (slowest): finishes at 10:08:00 → PostToolUse at T+480s

Clustering window = 2s:
- Group 1: Agent 1 (solo)
- Group 2: Agent 2 (solo)
- Group 3: Agent 3 (solo)
- Group 4: Agent 4 (solo)

Result: 1 flux-drive invocation fragmented into 4 separate groups.
```

**Impact on F1 acceptance criteria:**
> "Generates `workflow_id` from session + workflow context (sprint bead ID if available)"

If workflow_id is derived from timestamp clustering, it will be wrong for parallel dispatches with variable runtime.

### Issue 3.2: Parallel Agents Starting at Different Times (HIGH)

**Problem:** The heuristic assumes all agents start within 2s. This is false.

**Reality:** Claude Code's Task tool dispatches agents sequentially (observed in tool-time plugin). If each dispatch takes 200ms (subprocess spawn, JSON parsing, hook fire), 4 agents start across 800ms. If we cluster by start time, this works. But PRD says PostToolUse hook (fires on *completion*), so clustering by completion time is wrong (Issue 3.1).

**Worse scenario:** User runs `/flux-drive`, then manually runs another agent 30s later. Both in same session. Timestamp clustering can't distinguish.

### Recommended Fix:

**Stop inferring workflow_id from timestamps.** Use explicit invocation context:

1. **Skill-level UUID injection:**
   - When `/flux-drive` skill fires, generate a workflow UUID.
   - Pass UUID to each Task dispatch via environment variable or temp file.
   - PostToolUse hook reads UUID, stores in `workflow_id` column.

2. **Fallback for skills that don't inject UUID:**
   - Use session_id + bead_id (if available from .beads context).
   - If no bead context, workflow_id = session_id + task_invocation_uuid.

3. **Schema change:**
   ```sql
   ALTER TABLE agent_runs ADD COLUMN workflow_id TEXT;
   CREATE INDEX idx_workflow ON agent_runs(workflow_id);
   ```

4. **View for invocation grouping:**
   ```sql
   CREATE VIEW v_invocation_summary AS
   SELECT workflow_id,
          COUNT(*) as agent_count,
          SUM(total_tokens) as total_tokens,
          MAX(wall_clock_ms) as longest_runtime_ms
   FROM agent_runs
   WHERE workflow_id IS NOT NULL
   GROUP BY workflow_id;
   ```

**If explicit UUID is too invasive for F0, at minimum:**
- Document that grouping is unreliable for parallel agents with >2s runtime variance.
- Add a configuration knob for clustering window (default 30s, not 2s).
- Use *start time* (task dispatch) not *completion time* (PostToolUse) for clustering.

---

## 4. SQL Correctness: Decision Gate Percentile Calculation

### Issue 4.1: Approximate Percentile is Undefined (MODERATE)

**F3 acceptance criteria:**
> "Decision gate query: if p99 < 120K → SKIP hierarchical dispatch"

**Problem:** PRD doesn't include the actual SQL. "Approximate percentile calculation" could mean:

**Option A: SQLite NTILE (requires window functions, SQLite 3.25+):**
```sql
WITH ranked AS (
  SELECT total_tokens,
         NTILE(100) OVER (ORDER BY total_tokens) as percentile
  FROM agent_runs
  WHERE total_tokens IS NOT NULL
)
SELECT AVG(total_tokens) as p99
FROM ranked
WHERE percentile = 99;
```

**Bug:** NTILE(100) on <100 rows creates buckets smaller than 1%. With 50 rows, NTILE(100) creates 50 buckets of size 1, percentiles 51-100 are empty. Query returns NULL.

**Option B: Offset-based percentile:**
```sql
SELECT total_tokens as p99
FROM agent_runs
WHERE total_tokens IS NOT NULL
ORDER BY total_tokens DESC
LIMIT 1 OFFSET (
  SELECT CAST(COUNT(*) * 0.01 AS INTEGER)
  FROM agent_runs
  WHERE total_tokens IS NOT NULL
);
```

**Bug:** `COUNT(*) * 0.01` rounds down. With 50 rows, offset = 0, returns max value (p100 not p99). With 99 rows, offset = 0, same bug. Need 100+ rows for correct p99.

**Option C: Interpolated percentile (correct but complex):**
```sql
WITH counts AS (
  SELECT COUNT(*) as n FROM agent_runs WHERE total_tokens IS NOT NULL
),
position AS (
  SELECT n, CAST((n - 1) * 0.99 AS REAL) as p99_pos FROM counts
),
bounds AS (
  SELECT p99_pos,
         CAST(p99_pos AS INTEGER) as lower_idx,
         CAST(p99_pos AS INTEGER) + 1 as upper_idx,
         p99_pos - CAST(p99_pos AS INTEGER) as frac
  FROM position
)
SELECT (
  (SELECT total_tokens FROM (
    SELECT total_tokens, ROW_NUMBER() OVER (ORDER BY total_tokens) as rn
    FROM agent_runs WHERE total_tokens IS NOT NULL
  ) WHERE rn = (SELECT lower_idx FROM bounds) + 1) * (1 - (SELECT frac FROM bounds))
  +
  (SELECT total_tokens FROM (
    SELECT total_tokens, ROW_NUMBER() OVER (ORDER BY total_tokens) as rn
    FROM agent_runs WHERE total_tokens IS NOT NULL
  ) WHERE rn = (SELECT upper_idx FROM bounds) + 1) * (SELECT frac FROM bounds)
) as p99;
```

This is correct but unmaintainable.

### Recommended Fix:

**For <100 samples, use simple percentile approximation and document the error:**

```sql
-- Approximation: use 98th percentile for <100 samples
-- Error: reports p98 as p99, which is conservative (overestimates token usage)
SELECT total_tokens as p99_approx
FROM agent_runs
WHERE total_tokens IS NOT NULL
ORDER BY total_tokens DESC
LIMIT 1 OFFSET MAX(0, (
  SELECT CAST(COUNT(*) * 0.01 AS INTEGER)
  FROM agent_runs
  WHERE total_tokens IS NOT NULL
) - 1);
```

**For >=100 samples, use correct calculation:**

```sql
SELECT total_tokens as p99
FROM agent_runs
WHERE total_tokens IS NOT NULL
ORDER BY total_tokens DESC
LIMIT 1 OFFSET (
  SELECT CAST(COUNT(*) * 0.01 AS INTEGER)
  FROM agent_runs
  WHERE total_tokens IS NOT NULL
);
```

**Decision gate logic:**
```
if sample_count < 100:
  warn "p99 approximation unreliable below 100 samples (currently using p98)"
  if p99_approx < 120K: recommend SKIP
else:
  if p99 < 120K: recommend SKIP
```

**Alternative:** Use p95 until 100 samples collected. Document the threshold clearly.

---

## 5. Idempotency: JSONL Parser Edge Cases

### Issue 5.1: Partial Parse Failure Leaves Inconsistent State (HIGH)

**F2 acceptance criteria:**
> "Idempotent: re-running on already-parsed sessions is a no-op"

**Idempotency check (inferred):**
```sql
UPDATE agent_runs
SET input_tokens = ?, output_tokens = ?, parsed_at = CURRENT_TIMESTAMP
WHERE session_id = ? AND agent_name = ? AND parsed_at IS NULL;
```

**Problem:** If parser crashes mid-session (e.g., malformed JSONL, OOM, disk full), partial results persist.

**Failure Narrative:**
```
Session X has 4 agents.
Parser starts, processes agents 1-2 successfully (UPDATE sets parsed_at).
Agent 3: JSONL has malformed JSON line → parser crashes.
Result: agents 1-2 have token data, 3-4 are NULL.
Re-run parser: "parsed_at IS NOT NULL" for agents 1-2, skips them.
Parser tries agent 3 again, crashes again.
Infinite loop: agents 3-4 never backfilled.
```

**Root cause:** Idempotency marker (`parsed_at`) is set per-row, but parsing is per-session. If session parsing is not atomic, partial failure creates permanent gaps.

### Issue 5.2: JSONL Append and Re-Parse (MODERATE)

**Problem:** Claude Code appends to conversation JSONL files as the session progresses. If parser runs mid-session (via SessionEnd of a *different* session), it may parse incomplete data.

**Scenario:**
```
Session A (long-running): agent dispatched at 10:00, still running at 10:30.
Session B (quick): finishes at 10:15, triggers SessionEnd hook.
SessionEnd parser scans all sessions, finds Session A JSONL.
Parses 15 minutes of JSONL, only 2 of 5 API calls complete.
Updates agent_runs with partial token count, sets parsed_at.
Session A finishes at 10:45, calls 3-5 complete, appended to JSONL.
Re-run parser: parsed_at already set, skips Session A.
Final data: missing 60% of token usage.
```

**Root cause:** Parser assumes JSONL files are immutable (session complete). But SessionEnd hook can trigger while other sessions are active.

### Recommended Fix:

**For Issue 5.1 (partial parse crash):**
- Use transaction boundaries per session:
  ```python
  for session_id in pending_sessions:
      try:
          conn.execute("BEGIN TRANSACTION")
          parse_session(session_id)  # all UPDATEs for this session
          conn.execute("COMMIT")
      except Exception as e:
          conn.execute("ROLLBACK")
          log_error(session_id, e)
  ```
- Add `last_parse_attempt` timestamp (separate from `parsed_at`).
- Retry failed sessions with exponential backoff (don't block on permanently malformed JSONL).
- Expose failed sessions in `interstat status` output.

**For Issue 5.2 (mid-session parse):**
- **SessionEnd hook MUST only parse the ending session, not all sessions.**
  ```python
  # SessionEnd hook input
  session_id = hook_input["session_id"]
  parse_single_session(session_id)  # only this session
  ```
- **Full `interstat analyze` skill MUST skip active sessions.**
  - Check for lock files: `~/.claude/sessions/$session_id/` directory existence.
  - Or maintain an `active_sessions` table written by SessionStart, cleared by SessionEnd.

- **Alternative:** Only parse sessions older than 1 hour (time-based staleness check).

**Idempotency guarantee:**
"Re-parsing a completed session is a no-op. Re-parsing an active session is prohibited."

---

## 6. Additional Correctness Concerns

### Issue 6.1: Schema Migration and Plugin Updates (LOW)

**Problem:** PRD says "idempotent schema creation" but doesn't specify how schema changes are handled during plugin updates.

**Scenario:**
- v1.0.0: `agent_runs` has 10 columns.
- User collects 500 rows of data.
- v1.1.0: adds `workflow_id` column.
- `init-db.sh` runs on plugin update.
- If init script is naive (`CREATE TABLE IF NOT EXISTS`), new column is missing.
- All queries referencing `workflow_id` fail.

**Fix:**
Use SQLite's `PRAGMA user_version` for schema versioning:
```sql
PRAGMA user_version;  -- returns 0 for new DB

-- Migration logic
current_version=$(sqlite3 "$DB" "PRAGMA user_version")
if [ "$current_version" -lt 2 ]; then
  sqlite3 "$DB" "ALTER TABLE agent_runs ADD COLUMN workflow_id TEXT"
  sqlite3 "$DB" "PRAGMA user_version = 2"
fi
```

### Issue 6.2: SQLite Database Corruption (LOW)

**Problem:** If process crashes mid-write or disk is full, SQLite database can corrupt.

**Mitigation:**
- Enable WAL mode: `PRAGMA journal_mode=WAL;` (already implied by concurrent writer discussion).
- Enable auto-checkpoint: `PRAGMA wal_autocheckpoint=1000;`.
- Add `interstat repair` skill that runs `PRAGMA integrity_check;` and provides recovery steps.

### Issue 6.3: JSONL Format Dependency (MODERATE)

**PRD Dependencies:**
> "Claude Code conversation JSONL format — internal, undocumented, may change. Parser must be defensively coded."

**Problem:** "Defensively coded" is not an acceptance criterion. What happens when format changes?

**Failure modes:**
- Field renamed: `usage` → `token_usage` → parser extracts null, data loss silent.
- Nested structure change: `usage.input_tokens` → `usage.prompt.tokens` → parser crashes or returns wrong value.
- New message types added: parser doesn't skip unknown types, crashes.

**Fix:**
- Add schema validation: check for expected fields before parsing.
  ```python
  required_fields = ["usage", "input_tokens", "output_tokens"]
  if not all(field in entry for field in required_fields):
      log_warning(f"Skipping entry, missing fields: {entry}")
      continue
  ```
- Version detection: if JSONL has a version marker, log it. If version changes, warn user.
- Graceful degradation: if >10% of JSONL entries fail to parse, abort and alert user (don't silently drop 90% of data).

---

## Summary of Findings

| Issue | Severity | Impact | Recommended Fix |
|-------|----------|--------|----------------|
| 1.1: Silent data loss on SQLITE_BUSY | CRITICAL | 75% data loss in parallel dispatch scenarios | Fallback to JSONL on lock failure, add busy_timeout |
| 2.1: Timestamp proximity correlation is fragile | HIGH | Wrong token counts, wrong agent attribution | Use UUID-based correlation |
| 2.2: Multi-turn agents under-counted | MODERATE | p99 under-estimated by 20-40% | Aggregate all API calls per invocation |
| 3.1: 2s clustering window too narrow | MODERATE | Workflow grouping fails for slow agents | Use 30s window or explicit UUIDs |
| 4.1: Percentile SQL undefined/wrong | MODERATE | Decision gate verdict incorrect for <100 samples | Use p98 approximation, document error |
| 5.1: Partial parse leaves inconsistent state | HIGH | Permanent gaps in token data | Use per-session transactions |
| 5.2: Mid-session parse corrupts data | MODERATE | 60% token data missing | Only parse completed sessions |
| 6.3: JSONL format change breaks parser | MODERATE | Silent data loss on Claude Code updates | Add schema validation, version detection |

**Overall Assessment:**
The PRD has a viable architecture but **5 of 8 failure modes result in silent data loss**, which is unacceptable for a measurement system. The decision gate query is invalid for small samples, and the parallel dispatch scenario (the primary use case) triggers the worst race condition.

**Minimum viable fixes for F0:**
1. Add `busy_timeout` and fallback JSONL for PostToolUse hook (Issue 1.1).
2. Replace timestamp proximity with UUID correlation (Issue 2.1).
3. Add per-session transaction boundaries (Issue 5.1).
4. Restrict SessionEnd parser to current session only (Issue 5.2).

**Defer to F1+ (but document as known issues):**
- Multi-turn aggregation (Issue 2.2) — accept under-counting for now, fix in F2.
- Workflow grouping (Issue 3.1) — document unreliability, fix in F3.
- Percentile calculation (Issue 4.1) — use p95 for <100 samples, document.

**Do not ship without fixing Issues 1.1, 2.1, 5.1, 5.2.** These are data integrity violations that invalidate the measurement framework.
