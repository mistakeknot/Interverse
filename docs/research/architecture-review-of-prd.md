# Architecture Review: Interstat Token Benchmarking Framework

**Date:** 2026-02-16
**Reviewer:** Flux-Drive Architecture Agent
**Document:** `/root/projects/Interverse/docs/prds/2026-02-16-interstat-token-benchmarking.md`
**Bead:** iv-jq5b

---

## Executive Summary

**Verdict:** The PRD is architecturally sound with one critical blocker and three major coupling risks that need resolution before implementation.

**Critical Blocker:**
- **JSONL format assumption is invalid** — Claude Code conversation JSONL files do NOT contain token usage metadata. The entire F2 (JSONL parser backfill) feature is built on a false premise.

**Major Coupling Risks:**
1. Hybrid collection architecture creates unnecessary complexity when real-time hook alone could work
2. Missing validation that PostToolUse:Task hook actually receives necessary data fields
3. Plugin boundary is correct but SQLite schema is over-engineered for the measurement goal

**Recommendation:** PAUSE implementation. Validate JSONL format empirically first, then redesign F2 or pivot to alternative token collection strategy.

---

## 1. Plugin Boundary Assessment

### Finding: Plugin boundary is CORRECT

**Rationale:**
- `interstat` is appropriately separated from `tool-time` — different concerns (token economics vs tool usage events)
- `tool-time` uses JSONL storage with no SQLite; `interstat` needs relational queries for percentile calculations
- Independence from Clavain is correct — token benchmarking is a foundational measurement that should work without Clavain's multi-agent orchestration
- Follows Interverse naming convention (lowercase, `inter-` prefix)

**Evidence:**
- `tool-time` (plugins/tool-time/): event capture, no SQLite, community upload pipeline
- `interkasten` (plugins/interkasten/): SQLite for entity mapping, TypeScript MCP server
- `intermute` (services/intermute/): SQLite for coordination state, Go service
- Pattern: SQLite is common for relational data needs (entity maps, coordination state, metrics)

**No structural changes recommended.**

---

## 2. Storage Choice Review

### Finding: SQLite is APPROPRIATE but schema is over-engineered

**SQLite justification (CORRECT):**
- Percentile queries (p50/p90/p99) require SQL window functions or ORDER BY with OFFSET
- JSONL (tool-time pattern) would require loading all records into memory for sorting
- Existing precedent: `intermute`, `interkasten`, `tldr-swinton` all use SQLite for structured queries
- Local-only requirement (no server needed) matches SQLite's strengths

**Schema over-engineering (CONCERN):**

The `agent_runs` table has 17 columns with 3-level hierarchy (workflow → invocation → agent), but the PRD's decision gate only needs:
- Agent name
- Input tokens
- Total tokens
- Timestamp

**Unnecessary complexity:**
1. `scope` column with 3 levels ('workflow' | 'invocation' | 'agent') — query patterns show only 'agent' level is used
2. `findings_count` and `findings_severity` — these are outcome metrics, not token measurements; adds coupling to review workflow structure
3. `target_file` — not mentioned in any query or analysis requirement
4. `workflow_id` — no queries group by workflow; sprint context is not needed for the decision gate

**Impact:**
- Violates YAGNI — columns exist for speculative future use cases (Galiana integration, workflow analysis)
- Collection complexity propagates to hooks (must extract findings, detect workflow boundaries)
- Schema migrations become riskier with more columns

**Recommendation:**
Simplify to 8 columns for v1:
```sql
CREATE TABLE agent_runs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp TEXT NOT NULL,
    session_id TEXT NOT NULL,
    agent_name TEXT NOT NULL,
    input_tokens INTEGER,
    output_tokens INTEGER,
    cache_hit_tokens INTEGER,
    total_tokens INTEGER GENERATED ALWAYS AS (input_tokens + output_tokens) STORED,
    model TEXT,
    parsed_at TEXT  -- NULL = real-time, non-NULL = backfilled
);
```

Defer `findings_count`, `workflow_id`, `scope`, `target_file` until there's a concrete use case post-baseline.

---

## 3. Hybrid Collection Architecture

### Finding: CRITICAL BLOCKER — JSONL format does not contain token usage metadata

**Claimed architecture (from PRD F2):**
> "Conversation JSONL files (`~/.claude/projects/*/conversations/*.jsonl`) contain full API response metadata including usage fields"

**Empirical evidence (from investigation):**

1. **JSONL files exist but NOT at documented path:**
   - PRD claims: `~/.claude/projects/*/conversations/*.jsonl`
   - Actual location: `~/.claude/projects/-root-projects-Interverse/{session-id}.jsonl`
   - No `/conversations/` subdirectory exists

2. **JSONL entry types found:**
   ```
   3 "file-history-snapshot"
   4 "progress"
   7 "user"
   ```

3. **Entry structure (user type):**
   ```json
   {
     "type": "user",
     "message": { "role": "user", "content": "..." },
     "sessionId": "...",
     "timestamp": "...",
     "uuid": "...",
     "parentUuid": "...",
     "cwd": "...",
     "gitBranch": "..."
   }
   ```

4. **NO usage metadata found:**
   - Searched all JSONL files for `.usage`, `.data.usage`, `.message.usage` — zero matches
   - `progress` entries have structure: `{type, data: {command, hookEvent, hookName, type}}` — no token counts
   - No `api_response` or `response` type entries

**Conclusion:**
The conversation JSONL format is **NOT an API response log**. It appears to be a user message + hook event log, not a Claude API request/response transcript. Token usage metadata is NOT present.

**Impact:**
- **F2 (JSONL parser) is unimplementable as specified** — there is no token data to backfill
- The entire "hybrid collection" justification collapses
- SessionEnd hook (F2 acceptance criteria) triggers a parser with no valid input

**Why this matters:**
The PRD's central measurement strategy depends on backfilling real token counts from JSONL. Without this, the system can only capture:
- Real-time: wall_clock_ms, result_length (proxy metrics, not actual tokens)
- Post-session: nothing (no JSONL data source)

This is a **BLOCKING architecture failure**.

---

### Alternative Token Collection Strategies

Since JSONL backfill is not viable, here are 3 alternative approaches:

#### Option A: Hook-only with result_length proxy
- PostToolUse:Task hook captures `result_length` (available in hook JSON)
- Estimate tokens via `result_length / 4` heuristic
- **Pro:** Simplest, no new data dependencies
- **Con:** Inaccurate (ignores input tokens, cache hits, prompt context); cannot answer "are we hitting 120K limits?"

#### Option B: Direct Claude Code API integration (if available)
- Check if Claude Code exposes a session API or debug log with token counts
- **Pro:** Accurate, real-time
- **Con:** Requires discovering undocumented APIs; fragile to Claude Code updates

#### Option C: Instrumented wrapper around Task tool
- Create a custom MCP tool `interstat_task` that wraps the built-in Task tool
- Log inputs before calling Task, parse outputs for token info
- **Pro:** Full control over data capture
- **Con:** Requires modifying Clavain to use custom tool; breaks if Task tool changes

#### Option D: Defer token measurement, focus on cost proxies
- Track: agent count per invocation, wall clock time, result size
- Build decision gate on operational metrics: "do 4-agent reviews complete in <2min?"
- **Pro:** Achievable with current hook data
- **Con:** Doesn't answer the token efficiency question; optimizations still speculative

**Recommendation:** Before proceeding, **validate what data is actually available in PostToolUse:Task hook JSON**. If input/output token counts are present in hook payloads, the hybrid architecture is unnecessary — real-time hook collection is sufficient.

---

## 4. Dependency Relationships

### Finding: Dependencies are APPROPRIATE but one is fragile

**Declared dependencies (PRD §Dependencies):**
1. Claude Code conversation JSONL format — **FRAGILE** (see §3)
2. SQLite3 — **SOUND** (verified present, used by 3+ modules)
3. Python + uv — **SOUND** (existing pattern in tool-time)
4. jq — **SOUND** (used in all hook scripts)

**Undeclared dependencies:**
1. **PostToolUse hook API stability** — hooks receive JSON on stdin, but the schema is undocumented
2. **Task tool invocation signature** — F1 assumes `subagent_type` or prompt contains agent name; needs validation
3. **Session ID stability** — correlation between hook events and JSONL files depends on session_id format staying consistent

**Coupling to Claude Code internals:**

The PRD acknowledges this risk:
> "JSONL correlation — when flux-drive dispatches 4 agents in parallel, how do we match JSONL entries to specific agents?"

But understates it. The actual coupling points:
1. **Hook JSON schema** — if Claude Code changes `.tool_input` structure, F1 breaks
2. **Session file naming** — if `{session-id}.jsonl` path changes, F2 breaks
3. **Task tool semantics** — if `subagent_type` field is renamed or removed, agent name extraction breaks

**Mitigation strategies (NOT in PRD):**
- Version-pin expectations: document the Claude Code version tested against
- Defensive parsing: handle missing fields gracefully
- Schema validation on startup: check that a sample hook JSON has expected structure

**Recommendation:** Add F0.5: Hook API validation script that:
1. Triggers a test Task tool call
2. Captures the hook JSON payload
3. Validates presence of: `.session_id`, `.tool_input.subagent_type`, `.result`
4. Fails with clear error if schema is unexpected

---

## 5. Open Questions Analysis

### PRD lists 3 open questions; 2 are unresolved, 1 is underspecified

**Q1: JSONL correlation (parallel agents)**
> "When flux-drive dispatches 4 agents in parallel, how do we match JSONL entries to specific agents?"

**Status:** UNRESOLVED (and now moot due to §3 JSONL blocker)

**Q2: Invocation grouping (timestamp clustering)**
> "How to detect that 4 Task calls are part of the same /flux-drive invocation?"

**Status:** UNDERSPECIFIED

PRD suggests: "Timestamp clustering (within 2s) + same session"

**Concern:** This is heuristic-based and will false-positive on:
- Sequential agent invocations in a long session
- Parallel agents with staggered start times (>2s apart)

**Better approach:** Use `parentToolUseID` or `parentUuid` from JSONL (if available in hooks) to detect hierarchical tool calls. Needs empirical validation of hook JSON structure.

**Q3: JSONL format stability**
> "Need to inspect actual conversation JSONL structure before writing the parser."

**Status:** PARTIALLY RESOLVED (by this review)

The JSONL structure has been inspected (§3). Result: it does NOT contain token usage data, invalidating F2.

---

## 6. Feature Dependency Graph

### Finding: Dependencies are CORRECT but F2 is blocked

```
F0 (Plugin scaffold + schema)
  ↓
F1 (PostToolUse:Task hook) ← works independently
  ↓
F2 (JSONL parser) ← BLOCKED (no token data in JSONL)
  ↓
F3 (interstat report) ← depends on token data from F2
  ↓
F4 (interstat status) ← depends on F1 only (works without F2)
```

**Correct sequencing:**
- F0 → F1 is sound (hook needs schema to write to)
- F1 → F2 is correct IF F2 were viable
- F2 → F3 is correct (reports need data)
- F4 is independent of F2 (only checks collection progress)

**Issue:** F3's decision gate queries require `input_tokens`, `total_tokens` — these come from F2, which is unimplementable.

**Impact on milestone plan:**
- F0 + F1 + F4 can ship as "collection infrastructure" without token data
- F3 cannot deliver decision gate without solving token collection

**Recommendation:**
1. Ship F0 + F1 + F4 as v0.1 "event capture"
2. Block F2 + F3 until token data source is validated
3. Add spike task: "Investigate Claude Code token usage APIs"

---

## 7. Coupling Concerns Summary

### Claude Code Internal Coupling (HIGH RISK)

| Component | Couples to | Fragility | Mitigation |
|-----------|------------|-----------|------------|
| F1 hook | PostToolUse JSON schema | Medium | Schema validation in F0.5 |
| F2 parser | JSONL file path | High | **BLOCKED** — path exists but no token data |
| F2 parser | JSONL entry structure | Critical | **BLOCKED** — no `usage` field exists |
| Agent name extraction | `subagent_type` field | Medium | Defensive parsing + fallback to prompt |
| Session correlation | `session_id` format | Low | Stable across observed samples |

**Critical path:** F2 (JSONL parser) has **CRITICAL coupling** to an undocumented internal format that does not contain the required data.

---

## 8. Recommendations

### Immediate (block implementation until resolved):

1. **Validate PostToolUse:Task hook payload** — empirically test what data is available in the hook JSON. If token counts are present, hybrid architecture is unnecessary.

2. **Resolve JSONL token data blocker** — either:
   - Find alternative Claude Code API/log that exposes token usage
   - Redesign F2 to use a different data source
   - Pivot to proxy metrics (wall clock, result size) and adjust decision gate

3. **Simplify schema** — remove speculative columns (workflow_id, findings_count, scope, target_file). Add them later with concrete use cases.

### Design improvements:

4. **Add hook API validation (F0.5)** — script that validates expected hook JSON structure before collection starts.

5. **Document coupling boundaries** — README section listing:
   - Claude Code version tested against
   - Hook JSON schema expectations
   - Known fragility points

6. **Decouple findings tracking** — move `findings_count` to a separate table or future feature; don't couple token measurement to review workflow structure.

### Feature sequencing:

7. **Ship F0 + F1 + F4 as v0.1** — proves event capture works, unblocks learning about hook data availability.

8. **Spike: Token data discovery** — 1-2 day investigation into:
   - What's in PostToolUse hook JSON payload (full sample)
   - Alternative Claude Code APIs (debug logs, internal endpoints)
   - Whether Task tool results include token metadata

9. **Re-plan F2 + F3** — once token data source is confirmed, redesign parser and queries.

---

## 9. Correctness of Architectural Patterns

### PostToolUse hook pattern: SOUND

**Precedent:** `tool-time`, `intercheck`, `interlock` all use PostToolUse hooks successfully.

**Pattern:**
```bash
#!/usr/bin/env bash
PAYLOAD=$(cat)  # read JSON from stdin
SESSION_ID=$(echo "$PAYLOAD" | jq -r '.session_id')
TOOL_NAME=$(echo "$PAYLOAD" | jq -r '.tool_name')
# ... extract fields, INSERT into SQLite
```

**Correctness:** This is the established pattern in Interverse plugins. No issues.

### SQLite from bash hooks: SOUND

**Precedent:** Multiple plugins write to SQLite from bash hooks without issues.

**Concern:** The PRD specifies `<50ms` overhead for INSERT (F1 acceptance criteria). This is achievable if:
- Database is on local SSD (not NFS)
- No complex triggers or FK checks on hot path
- Write-ahead logging (WAL) enabled

**Recommendation:** Add `PRAGMA journal_mode=WAL;` to init-db.sh.

### Timestamp-based correlation: WEAK

**Pattern (from PRD Open Questions):**
> "Timestamp clustering (within 2s) + same session is the likely heuristic."

**Issue:** This is fragile for parallel agents with staggered starts or long-running agents.

**Better approach:** Use structural identifiers if available (`invocation_id` from parent tool call, or `parentUuid` chain).

**Recommendation:** Validate that PostToolUse hook JSON includes parent tool call references before relying on timestamp heuristics.

---

## 10. Summary of Findings

| Concern | Severity | Status | Recommendation |
|---------|----------|--------|----------------|
| JSONL token data missing | CRITICAL | Blocker | Validate alternative data source before F2 |
| Hook JSON schema undocumented | HIGH | Risk | Add F0.5 validation script |
| Schema over-engineered | MEDIUM | Defer | Simplify to 8 columns, add others later |
| Timestamp correlation fragile | MEDIUM | Underspecified | Use structural IDs if available |
| Plugin boundary | LOW | Correct | No change |
| SQLite choice | LOW | Correct | Add WAL pragma |
| Dependency graph | LOW | Correct | Sequence F0→F1→F4, block F2/F3 |

---

## Final Verdict

**The PRD is architecturally sound in principle but unimplementable as written due to invalid JSONL format assumptions.**

**Recommended next steps:**
1. **STOP** — do not implement F2 (JSONL parser) until token data source is validated
2. **SPIKE** — 1-day investigation: capture real PostToolUse:Task hook payload, check for token fields
3. **PIVOT** — if no token data available, redesign around proxy metrics OR find alternative Claude Code API
4. **SIMPLIFY** — reduce schema to 8 columns, defer speculative fields
5. **VALIDATE** — add hook API validation (F0.5) before F1 implementation

**Plugin boundary, SQLite choice, and dependency relationships are correct.** The blocker is purely the token data collection strategy.
