# Plan: interstat — verify scaffold, fix agent names, build report skill

**Bead:** iv-3gfm
**Phase:** executing (as of 2026-02-18T23:20:15Z)
**Parent beads:** iv-dyyy (scaffold), iv-qi8j (hook), iv-dkg8 (report)

## Problem

interstat has a working scaffold (plugin.json, hooks, scripts, skills, SQLite DB with 3,715 rows). But:

1. **iv-dyyy may be closeable** — the scaffold exists and works, need to verify completeness
2. **Agent names are IDs not types** — post-task.sh captures `tool_input.subagent_type` but the JSONL parser (`analyze.py`) derives agent names from filenames (`agent-<hash>`), so all subagent rows end up with hash IDs like `a76c7a5` instead of `Explore`, `Plan`, `fd-architecture`, etc.
3. **Report skill is non-functional** — `report.sh` exists and works BUT shows agent IDs, making it impossible to identify which *kinds* of agents are expensive

## Tasks

### Task 1: Verify iv-dyyy scaffold completeness
- [x] plugin.json valid with name, version, hooks, skills
- [x] hooks.json with PostToolUse:Task matcher and SessionEnd
- [x] init-db.sh creates schema with WAL, indexes, views
- [x] post-task.sh captures events and inserts into SQLite
- [x] session-end.sh triggers JSONL backfill
- [x] analyze.py parses JSONL and upserts token data
- [x] report.sh, status.sh exist and produce output
- [x] Skills: report.md, status.md, analyze.md
- [x] DB exists at ~/.claude/interstat/metrics.db with data
- **Action:** Close iv-dyyy — scaffold is complete and functional

### Task 2: Fix agent name capture (two-pronged)

**Problem analysis:** There are two data paths:
- **Real-time path** (post-task.sh): Gets `tool_input.subagent_type` from hook input → inserts as `agent_name`. This DOES have the correct type... but looking at the data, all names are hashes. The hook extracts `.tool_input.subagent_type` but the actual JSON key in the hook payload may differ.
- **Backfill path** (analyze.py): Derives agent name from filename `agent-<hash>.jsonl` → always produces hash IDs. The JSONL content has `agentId` (hash) but NOT the subagent_type.

**Fix A — post-task.sh:** Verify the hook input JSON structure. The `subagent_type` field should be at `.tool_input.subagent_type`. If the hook is already capturing it correctly, the real-time rows should have good names. Check if the issue is that the backfill OVERWRITES the real-time row's good agent_name with the hash from the JSONL filename.

**Fix B — analyze.py `agent_name_for_path`:** The function `agent_name_for_path()` strips `agent-` prefix from filename, producing a hash. It cannot recover the type from the JSONL because it's not stored there. Fix: when upserting, if the existing row already has a non-hash `agent_name` (from the real-time hook), DON'T overwrite it with the hash from the JSONL filename.

**Fix C — Add `subagent_type` column:** Add a dedicated `subagent_type` column to distinguish the semantic type from the agent ID. The hook writes both; the parser only writes the ID. Views and reports use `COALESCE(subagent_type, agent_name)` as the display name.

**Chosen approach: Fix B + C** (minimal, backward-compatible)

Files to modify:
- `scripts/init-db.sh` — add `subagent_type` column (schema v2, ALTER TABLE)
- `hooks/post-task.sh` — write subagent_type from `.tool_input.subagent_type`
- `scripts/analyze.py` — in upsert, preserve existing subagent_type if present
- `scripts/init-db.sh` — update views to use `COALESCE(subagent_type, agent_name)`

### Task 3: Build working report skill

The report.sh script already exists and is functional. The main issue is that agent names are hashes (fixed in Task 2). After Task 2, the existing report.sh and views will show meaningful names.

Additional improvements to report.sh:
- Add a "Top token consumers" section showing the 10 most expensive individual agent runs
- Add a "Subagent type breakdown" section using the new `subagent_type` column
- Add date range filtering (last 7 days default)

Files to modify:
- `scripts/report.sh` — enhance with type breakdown, top consumers, date filter

### Task 4: Backfill existing data

After schema migration, backfill the 3,715 existing rows by re-extracting subagent_type from the hook's real-time data where possible. For rows where no real-time capture exists, they stay as hash IDs (we can't recover what we never captured).

Actually — looking at analyze.py's upsert logic, it matches by `session_id + agent_name`. The real-time rows from post-task.sh have `agent_name` set to whatever `.tool_input.subagent_type` produced. The JSONL backfill then tries to match `session_id + agent_name` but uses the hash... so it creates a NEW row instead of updating. This means we likely have **duplicate rows**: one from the hook (with correct type or "unknown"), one from the parser (with hash ID).

**Action:** After schema migration, deduplicate by matching on `session_id + invocation_id` or `session_id + timestamp` proximity.

## Execution Order

1. Close iv-dyyy (no code changes needed)
2. Schema migration: add subagent_type column, update views
3. Fix post-task.sh to write subagent_type
4. Fix analyze.py to preserve subagent_type on upsert
5. Enhance report.sh
6. Test the full pipeline
7. Close iv-dkg8 if report skill meets requirements

## Risk

- Schema migration on a live DB — use ALTER TABLE ADD COLUMN (safe, no data loss)
- Existing data won't have subagent_type — COALESCE handles this gracefully
- The deduplication in Task 4 might be complex — defer if not blocking reports
