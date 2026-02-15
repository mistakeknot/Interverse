# Interspect + Flux-Drive Routing Override Integration — Implementation Points

**Date:** 2026-02-15  
**Purpose:** Exact code locations for implementing Step 1.2a.0 (routing override reader) in flux-drive and overlay writer in interspect  
**PRD:** `/root/projects/Interverse/docs/prds/2026-02-15-interspect-routing-overrides.md`

---

## 1. Flux-Drive Consumer Integration Point

### 1.1 Exact Location for Step 1.2a.0

**File:** `/root/projects/Interverse/plugins/interflux/skills/flux-drive/SKILL.md`  
**Line:** Between line 224 and line 251 (insert new Step 1.2a.0 before Step 1.2a)

**Current structure:**
```
Line 224: ### Step 1.2: Select Agents from Roster
Line 225: #### Step 1.2a: Pre-filter agents
Line 226: (Pre-filtering logic starts here)
```

**New structure needed:**
```
Line 224: ### Step 1.2: Select Agents from Roster
Line 225: #### Step 1.2a.0: Read routing overrides
Line 226+: [NEW CONTENT — routing override reader]

Line XXX: #### Step 1.2a: Pre-filter agents  
Line XXX+1: (Existing pre-filtering logic, now runs AFTER routing exclusions)
```

### 1.2 Implementation Pattern

Insert this content at line 225 (pushing existing 1.2a down):

```markdown
#### Step 1.2a.0: Read routing overrides

Before agent pre-filtering, check for project routing overrides created by interspect.

**Path:** `${FLUX_ROUTING_OVERRIDES_PATH:-${PROJECT_ROOT}/.claude/routing-overrides.json}`

**Read logic:**
1. Check if file exists. If not, skip this step (no exclusions).
2. Read and parse JSON. On parse error:
   - Log warning: "routing-overrides.json malformed, ignoring overrides"
   - Move file to `.claude/routing-overrides.json.corrupted`
   - Continue without exclusions (graceful degradation)
3. Version check:
   - If `version > 1`: log warning "Routing overrides version N not supported (max 1). Ignoring file." and skip
   - If `version < 1`: log error and skip
4. Extract `overrides[]` array
5. For each override:
   - If agent not in roster, log: "WARNING: Routing override for unknown agent {name} — check spelling or remove entry."
   - If agent is cross-cutting (fd-architecture, fd-quality, fd-safety, fd-correctness), log prominent warning in triage output
   - Add agent to exclusion list
6. Remove excluded agents from the roster before Step 1.2a

**Triage table note:** Add footer: "N agents excluded by routing overrides (see .claude/routing-overrides.json)"

**Cross-cutting warning format:**
```
⚠️  WARNING: Cross-cutting agent fd-architecture excluded by routing override.
    This removes structural analysis coverage for all reviews.
    Review override with /interspect:status
```

**Excluded agents:** Never appear in the scoring table or triage output. Not scored, not launched.
```

### 1.3 Phase File Reference

The flux-drive SKILL.md references phase files for detailed logic:
- **Main logic:** `phases/launch.md` (lines 1-454)
- **Slicing logic:** `phases/slicing.md` (lines 1-366)

No changes needed to phase files for routing override reading — all logic goes in the main SKILL.md Step 1.2a.0.

---

## 2. Interspect Modification Pipeline

### 2.1 Key Functions in lib-interspect.sh

**File:** `/root/projects/Interverse/hub/clavain/hooks/lib-interspect.sh`

#### _interspect_validate_target
**Lines:** 224-245  
**Purpose:** Check if a file path is allowed for interspect modification  
**Parameters:** `$1` = file path (relative to repo root)  
**Returns:** 0 if valid, 1 if rejected  
**Side effects:** Prints rejection reason to stderr

**Logic:**
1. Line 227-230: Load protected-paths manifest
2. Line 233-236: Check if path matches any protected pattern (hard block)
3. Line 239-242: Check if path matches modification allow-list
4. Returns 0 only if: NOT protected AND in allow-list

**Routing override validation:**
`.claude/routing-overrides.json` is already in the allow-list (line 12 of protected-paths.json), so it will pass validation.

#### _interspect_flock_git
**Lines:** 327-342  
**Purpose:** Serialize git operations under an advisory lock  
**Usage:** `_interspect_flock_git git add <file>` or `_interspect_flock_git git commit -m "..."`  
**Parameters:** `$@` = command to run under lock  
**Lock file:** `.clavain/interspect/.git-lock`  
**Timeout:** 30 seconds (line 322: `_INTERSPECT_GIT_LOCK_TIMEOUT=30`)

**Implementation:**
- Line 329: Get repo root
- Line 330-331: Define lock directory and lockfile
- Line 333: Create lock directory
- Line 335-341: Open FD 9 on lockfile, acquire exclusive lock with timeout, run command, release on close

**Critical for routing overrides:** All read-modify-write operations on routing-overrides.json MUST wrap the entire sequence in `_interspect_flock_git`:
```bash
_interspect_flock_git bash -c '
  OVERRIDES=$(cat .claude/routing-overrides.json)
  NEW_OVERRIDES=$(echo "$OVERRIDES" | jq "...")
  echo "$NEW_OVERRIDES" > .claude/routing-overrides.json
  git add .claude/routing-overrides.json
  git commit -m "[interspect] ..."
'
```

#### _interspect_classify_pattern
**Lines:** 285-298  
**Purpose:** Apply counting-rule thresholds to classify a pattern  
**Parameters:** `$1` = event_count, `$2` = session_count, `$3` = project_count  
**Returns:** "ready" | "growing" | "emerging" (stdout)

**Logic:**
1. Line 286: Load confidence thresholds (`min_sessions=3, min_diversity=2, min_events=5`)
2. Line 288-292: Count how many thresholds are met
3. Line 294-296: Return classification based on count

**Counting rules:**
- **ready**: ALL 3 thresholds met → eligible for proposal
- **growing**: 1-2 thresholds met → log as approaching
- **emerging**: 0 thresholds met → log as watching

**Routing eligibility:** A pattern must be "ready" AND meet the `min_agent_wrong_pct` threshold (80% of events for the pattern have `override_reason: agent_wrong`). This is a NEW check not in the existing function — it will need to be added in the routing proposal logic.

### 2.2 Database Schema

**Schema creation:** Lines 57-123 of lib-interspect.sh (`_interspect_ensure_db`)

**Existing tables:**

#### evidence
```sql
CREATE TABLE IF NOT EXISTS evidence (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts TEXT NOT NULL,
    session_id TEXT NOT NULL,
    seq INTEGER NOT NULL,
    source TEXT NOT NULL,           -- agent name (e.g., "fd-safety")
    source_version TEXT,            -- commit SHA
    event TEXT NOT NULL,            -- "override", "agent_dispatch", etc.
    override_reason TEXT,           -- "agent_wrong", "deprioritized", "already_fixed"
    context TEXT NOT NULL,          -- JSON blob
    project TEXT NOT NULL,
    project_lang TEXT,
    project_type TEXT
);
```

**Key for routing:** Filter by `source`, `event = 'override'`, `override_reason = 'agent_wrong'` to find routing-eligible patterns.

#### sessions
```sql
CREATE TABLE IF NOT EXISTS sessions (
    session_id TEXT PRIMARY KEY,
    start_ts TEXT NOT NULL,
    end_ts TEXT,                    -- NULL = dark session
    project TEXT
);
```

**Not used for routing proposals.**

#### canary
```sql
CREATE TABLE IF NOT EXISTS canary (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    file TEXT NOT NULL,             -- target file (e.g., ".claude/routing-overrides.json")
    commit_sha TEXT NOT NULL,
    group_id TEXT,
    applied_at TEXT NOT NULL,
    window_uses INTEGER NOT NULL DEFAULT 20,
    uses_so_far INTEGER NOT NULL DEFAULT 0,
    window_expires_at TEXT,
    baseline_override_rate REAL,
    baseline_fp_rate REAL,
    baseline_finding_density REAL,
    baseline_window TEXT,           -- JSON metadata
    status TEXT NOT NULL DEFAULT 'active',  -- active, passed, reverted, expired_human_edit
    verdict_reason TEXT
);
```

**Routing canary:** After applying a routing override, insert a canary record with:
- `file = ".claude/routing-overrides.json"`
- `window_uses = 20`
- `window_expires_at` = now + 14 days
- `status = 'active'`

#### modifications
```sql
CREATE TABLE IF NOT EXISTS modifications (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    group_id TEXT NOT NULL,
    ts TEXT NOT NULL,
    tier TEXT NOT NULL DEFAULT 'persistent',
    mod_type TEXT NOT NULL,         -- "context_injection", "routing", "prompt_tuning"
    target_file TEXT NOT NULL,
    commit_sha TEXT,
    confidence REAL NOT NULL,
    evidence_summary TEXT,
    status TEXT NOT NULL DEFAULT 'applied'  -- applied, reverted, superseded
);
```

**Routing modification:** After applying a routing override, insert:
- `mod_type = "routing"`
- `target_file = ".claude/routing-overrides.json"`
- `commit_sha` = the commit SHA
- `confidence` = computed from counting rules (not a weighted score in v1)
- `status = "applied"`

**MISSING TABLE for PRD F4 (blacklist):**  
Not yet in schema. Needs to be added:
```sql
CREATE TABLE IF NOT EXISTS blacklist (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    pattern_key TEXT NOT NULL,      -- e.g., "fd-game-design|override|agent_wrong"
    blacklisted_at TEXT NOT NULL,
    reason TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_blacklist_pattern ON blacklist(pattern_key);
```

---

## 3. Confidence.json Schema

**File:** `/root/projects/Interverse/hub/clavain/.clavain/interspect/confidence.json`

**Current schema:**
```json
{
  "min_sessions": 3,
  "min_diversity": 2,
  "min_events": 5,
  "_comment": "Counting-rule thresholds per design §3.3. In protected-paths.json — interspect cannot modify."
}
```

**Required addition for routing (PRD dependency):**
```json
{
  "min_sessions": 3,
  "min_diversity": 2,
  "min_events": 5,
  "min_agent_wrong_pct": 80,
  "_comment": "..."
}
```

**Purpose:** `min_agent_wrong_pct` = minimum percentage of override events that must be `agent_wrong` (vs `deprioritized` or `already_fixed`) for a pattern to be routing-eligible. Default 80%.

---

## 4. Protected Paths Manifest

**File:** `/root/projects/Interverse/hub/clavain/.clavain/interspect/protected-paths.json`

**Current allow-list (line 11-13):**
```json
"modification_allow_list": [
  ".clavain/interspect/overlays/**/*.md",
  ".claude/routing-overrides.json"
]
```

**Status:** `.claude/routing-overrides.json` is already whitelisted. No changes needed.

**Always-propose list (line 14-16):**
```json
"always_propose": [
  ".clavain/interspect/overlays/**/*.md"
]
```

**Does NOT include routing-overrides.json.** This means routing overrides can be autonomous (if autonomy mode is enabled). Per PRD F3, routing overrides follow the same propose/autonomous mode as overlays.

**Open question:** Should routing-overrides.json also be in `always_propose`? PRD does not specify. Design doc §3.2 says all modifications go through modification pipeline with risk-based gates, but doesn't explicitly force propose mode for routing.

---

## 5. Existing Interspect Commands

### 5.1 /interspect (main analysis)
**File:** `/root/projects/Interverse/hub/clavain/commands/interspect.md`  
**Lines:** 1-106

**Flow:**
1. Locate lib-interspect.sh and source it
2. Call `_interspect_ensure_db`
3. Call `_interspect_get_classified_patterns` to query all patterns
4. Parse results and bucket by classification (ready/growing/emerging)
5. Present report

**For routing:** This is where routing proposals would be presented. After showing the pattern classification table (line 59-88), add a new section:

```markdown
### Routing Proposals

{For each ready pattern where source is an agent and >= min_agent_wrong_pct of events are agent_wrong:}

Agent: {source}
Evidence: {event_count} overrides ({agent_wrong_pct}% agent_wrong) across {session_count} sessions, {project_count} projects
Recommendation: Exclude {source} from future flux-drive reviews in this project

[AskUserQuestion with Accept/Decline/Show Evidence options]
```

### 5.2 /interspect:status
**File:** `/root/projects/Interverse/hub/clavain/commands/interspect-status.md`  
**Lines:** 1-116

**Current output:**
- Session counts (line 33-36)
- Evidence counts (line 38-41)
- Top agents by evidence (line 43-45)
- Canaries (line 75)
- Modifications (line 76)

**For routing:** Add a new section after line 76:

```markdown
### Routing Overrides: {count} active

{Read .claude/routing-overrides.json, display per override:}
- {agent}: {reason} (created {date} by {created_by})
  Canary: {canary_status if created_by=interspect}
  [Next action hint]
```

**Cross-cutting warning:** If override excludes fd-architecture, fd-quality, fd-safety, or fd-correctness, show warning inline.

### 5.3 /interspect:evidence
**File:** `/root/projects/Interverse/hub/clavain/commands/interspect-evidence.md`  
**Lines:** 1-138

**No changes needed.** This shows evidence for a specific agent. Routing logic queries this data but doesn't modify the display.

### 5.4 /interspect:correction
**File:** `/root/projects/Interverse/hub/clavain/commands/interspect-correction.md`  
**Lines:** 1-80

**No changes needed.** This is the primary evidence collection mechanism. It already writes to the evidence table with `override_reason` (line 57), which routing proposals query.

---

## 6. Test Infrastructure

**No existing interspect tests found.**

Search results:
- `/root/projects/Interverse/hub/clavain/tests/run-tests.sh` (general test runner)
- `/root/projects/Interverse/hub/clavain/tests/smoke/run-smoke-tests.sh` (smoke tests)

**No dedicated interspect test suite.** Tests will need to be created from scratch.

**Test coverage needed (per PRD acceptance criteria):**
1. **F1 (reader):**
   - Malformed JSON handling (move to .corrupted)
   - Version check (>1, <1, missing)
   - Unknown agent warning
   - Cross-cutting exclusion warning
   - Graceful degradation on file missing
2. **F2 (proposal):**
   - Pattern detection with min_agent_wrong_pct threshold
   - Dedup check (override already exists)
   - Cross-cutting confirmation dialog
   - AskUserQuestion format
3. **F3 (apply):**
   - Flock serialization (concurrent write test)
   - Dedup at write time (unique_by agent)
   - Atomicity via compensating action (commit failure rollback)
   - DB insert after commit
4. **F4 (status/revert):**
   - Status display with canary status
   - Idempotent revert
   - Blacklist table insert
   - Orphan agent detection

---

## 7. Implementation Sequence

### Phase 1: Consumer (Flux-Drive)
1. Add Step 1.2a.0 to SKILL.md (line 225 insertion point)
2. Test routing override reader with sample .json file
3. Verify exclusions work (excluded agents don't appear in triage)
4. Test cross-cutting warning display
5. Test graceful degradation (malformed JSON, missing file)

### Phase 2: Producer Setup (Interspect)
1. Add `min_agent_wrong_pct: 80` to confidence.json
2. Add blacklist table to schema (update `_interspect_ensure_db`)
3. Test schema migration (existing DB upgrades correctly)

### Phase 3: Producer Detection (Interspect)
1. Add routing pattern detection to `/interspect` command
2. Query for patterns meeting counting rules + agent_wrong_pct threshold
3. Present proposals via AskUserQuestion
4. Test dedup (don't propose if override exists)

### Phase 4: Producer Apply (Interspect)
1. Implement routing override writer with flock serialization
2. Read-modify-write wrapper with compensating action on commit failure
3. Insert modification + canary records AFTER commit
4. Test concurrent write protection (two sessions proposing same override)
5. Test atomicity (commit failure rolls back file write)

### Phase 5: Status + Revert (Interspect)
1. Add routing section to `/interspect:status`
2. Implement `/interspect:revert` for routing overrides
3. Blacklist pattern on revert
4. Close canary on revert

### Phase 6: Testing
1. End-to-end test: evidence → proposal → apply → flux-drive exclusion → revert
2. Cross-cutting agent exclusion with confirmation
3. Concurrent modification test (two sessions, one lock)
4. Malformed JSON recovery test

---

## 8. Key Code Snippets

### 8.1 Routing Override Reader (Flux-Drive Step 1.2a.0)

```bash
# In SKILL.md, insert at line 225

ROUTING_OVERRIDES_PATH="${FLUX_ROUTING_OVERRIDES_PATH:-${PROJECT_ROOT}/.claude/routing-overrides.json}"
EXCLUDED_AGENTS=()

if [[ -f "$ROUTING_OVERRIDES_PATH" ]]; then
    # Parse JSON
    OVERRIDES_JSON=$(cat "$ROUTING_OVERRIDES_PATH" 2>/dev/null)
    if ! echo "$OVERRIDES_JSON" | jq empty 2>/dev/null; then
        echo "⚠️  WARNING: routing-overrides.json malformed, ignoring overrides"
        mv "$ROUTING_OVERRIDES_PATH" "${ROUTING_OVERRIDES_PATH}.corrupted"
    else
        # Version check
        VERSION=$(echo "$OVERRIDES_JSON" | jq -r '.version // 0')
        if (( VERSION > 1 )); then
            echo "⚠️  WARNING: Routing overrides version $VERSION not supported (max 1). Ignoring file."
        elif (( VERSION < 1 )); then
            echo "ERROR: Invalid routing overrides version $VERSION. Ignoring file."
        else
            # Extract overrides
            while IFS= read -r agent; do
                [[ -z "$agent" ]] && continue
                EXCLUDED_AGENTS+=("$agent")
                
                # Cross-cutting check
                case "$agent" in
                    fd-architecture|fd-quality|fd-safety|fd-correctness)
                        echo "⚠️  WARNING: Cross-cutting agent $agent excluded by routing override."
                        echo "    This removes ${agent#fd-} coverage for all reviews."
                        echo "    Review override with /interspect:status"
                        ;;
                esac
            done < <(echo "$OVERRIDES_JSON" | jq -r '.overrides[]?.agent // empty')
        fi
    fi
fi

# Apply exclusions to roster before Step 1.2a
# (Remove excluded agents from the selection pool)
```

### 8.2 Routing Proposal Logic (Interspect /interspect command)

```bash
# After pattern classification table, add:

# Query routing-eligible patterns
ROUTING_PATTERNS=$(sqlite3 -separator '|' "$DB" "
    SELECT 
        source,
        COUNT(*) as total,
        SUM(CASE WHEN override_reason = 'agent_wrong' THEN 1 ELSE 0 END) as agent_wrong_count,
        COUNT(DISTINCT session_id) as sessions,
        COUNT(DISTINCT project) as projects
    FROM evidence
    WHERE event = 'override' AND source LIKE 'fd-%'
    GROUP BY source
    HAVING sessions >= ${MIN_SESSIONS}
        AND projects >= ${MIN_DIVERSITY}
        AND total >= ${MIN_EVENTS}
        AND (agent_wrong_count * 100.0 / total) >= ${MIN_AGENT_WRONG_PCT}
")

# For each routing-eligible pattern:
while IFS='|' read -r agent total wrong sessions projects; do
    # Check if override already exists
    if jq -e ".overrides[] | select(.agent == \"$agent\")" .claude/routing-overrides.json &>/dev/null; then
        echo "Override for $agent already exists, skipping proposal"
        continue
    fi
    
    # Present proposal via AskUserQuestion
    PCT=$((wrong * 100 / total))
    echo "Agent: $agent"
    echo "Evidence: $total overrides (${PCT}% agent_wrong) across $sessions sessions, $projects projects"
    echo "Recommendation: Exclude $agent from future flux-drive reviews in this project"
    
    # AskUserQuestion with Accept/Decline/Show Evidence
    # ...
done <<< "$ROUTING_PATTERNS"
```

### 8.3 Routing Override Writer (Interspect apply logic)

```bash
# Entire read-modify-write wrapped in flock
_interspect_flock_git bash -c "
    set -e
    
    # Validate target
    if ! _interspect_validate_target '.claude/routing-overrides.json'; then
        echo 'ERROR: routing-overrides.json not in allow-list'
        exit 1
    fi
    
    # Read current overrides
    if [[ -f .claude/routing-overrides.json ]]; then
        CURRENT=\$(cat .claude/routing-overrides.json)
    else
        CURRENT='{\"version\": 1, \"overrides\": []}'
    fi
    
    # Merge new override (dedup by agent)
    NEW_OVERRIDE='{\"agent\": \"$AGENT\", \"action\": \"exclude\", \"reason\": \"$REASON\", \"created\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\", \"created_by\": \"interspect\", \"evidence_ids\": []}'
    MERGED=\$(echo \"\$CURRENT\" | jq \".overrides |= (. + [$NEW_OVERRIDE] | unique_by(.agent))\")
    
    # Write + validate
    echo \"\$MERGED\" > .claude/routing-overrides.json
    if ! jq empty .claude/routing-overrides.json 2>/dev/null; then
        rm .claude/routing-overrides.json
        git restore .claude/routing-overrides.json
        echo 'ERROR: Invalid JSON after merge, rollback'
        exit 1
    fi
    
    # Git add + commit
    git add .claude/routing-overrides.json
    if ! git commit -m '[interspect] Exclude $AGENT from flux-drive reviews'; then
        git restore .claude/routing-overrides.json
        echo 'ERROR: Commit failed, rollback'
        exit 1
    fi
    
    COMMIT_SHA=\$(git rev-parse HEAD)
    
    # Insert modification + canary records AFTER commit
    sqlite3 \"\$DB\" \"INSERT INTO modifications (group_id, ts, mod_type, target_file, commit_sha, confidence, status) VALUES ('grp-\$RANDOM', '\$(date -u +%Y-%m-%dT%H:%M:%SZ)', 'routing', '.claude/routing-overrides.json', '\$COMMIT_SHA', 1.0, 'applied');\"
    
    sqlite3 \"\$DB\" \"INSERT INTO canary (file, commit_sha, applied_at, window_uses, status) VALUES ('.claude/routing-overrides.json', '\$COMMIT_SHA', '\$(date -u +%Y-%m-%dT%H:%M:%SZ)', 20, 'active');\"
"
```

---

## Summary

**Flux-Drive Integration:**
- **Insertion point:** Line 225 of SKILL.md (new Step 1.2a.0)
- **Logic:** Read routing-overrides.json, parse, validate, exclude agents before scoring
- **Error handling:** Graceful degradation (move malformed file to .corrupted, log warnings)

**Interspect Modification Pipeline:**
- **Validation:** `_interspect_validate_target()` (lines 224-245) — already whitelists .claude/routing-overrides.json
- **Serialization:** `_interspect_flock_git()` (lines 327-342) — wrap all read-modify-write operations
- **Classification:** `_interspect_classify_pattern()` (lines 285-298) — counting rules, needs agent_wrong_pct filter added
- **Schema:** Existing tables support routing (evidence, modifications, canary). Need to add blacklist table.

**Confidence.json:**
- **Current:** 3 thresholds (min_sessions, min_diversity, min_events)
- **Required:** Add `min_agent_wrong_pct: 80`

**Commands:**
- **/interspect:** Add routing proposal section after pattern analysis
- **/interspect:status:** Add routing overrides display with canary status
- **/interspect:revert:** Support routing override revert + blacklist

**Test Infrastructure:**
- **Current:** None for interspect
- **Needed:** Full test suite for F1-F4 acceptance criteria

