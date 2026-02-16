# Clavain Hub: SessionStart Hooks & Intermute Integration Analysis

**Date:** 2026-02-15  
**Scope:** /root/projects/Interverse/hub/clavain/

---

## Executive Summary

Clavain's SessionStart hook (session-start.sh) is highly sophisticated with extensive companion plugin detection, sprint context injection, handoff recovery, and in-flight agent tracking. **There is NO existing Intermute integration in the hooks.** Interlock is discovered and announced, but not auto-joined. Sprint/work context is injected via sprint-scan.sh, and work discovery is delegated to interphase. The hook exports CLAUDE_SESSION_ID to CLAUDE_ENV_FILE for downstream state tracking.

---

## 1. SessionStart Hooks: What Exists

### Hook Registration
File: /root/projects/Interverse/hub/clavain/hooks/hooks.json (lines 1-14)

**Trigger:** Fires on startup, resume, clear, or compact events.
**Async:** Yes (non-blocking)

SessionStart hook runs session-start.sh via command matcher for startup/resume/clear/compact.

### Main Hook Implementation
File: /root/projects/Interverse/hub/clavain/hooks/session-start.sh (370 lines)

**Key sections:**

1. **CLAUDE_ENV_FILE Export (lines 16-23)** - Persists CLAUDE_SESSION_ID for interphase statusline gate
2. **Plugin Cache Cleanup (lines 25-45)** - Replaces stale versions with symlinks
3. **Using-Clavain Skill Injection (lines 47-51)** - Embeds skill content in context
4. **Companion Discovery (lines 52-99)** - Discovers interflux, interpath, interwatch, interlock
5. **INTERSERVE Mode Detection (lines 101-105)** - Checks for interserve-toggle.flag
6. **Sprint Context Injection (lines 132-139)** - Calls sprint_brief_scan()
7. **Work Discovery (lines 141-152)** - Delegates to interphase via lib-discovery.sh
8. **Handoff Recovery (lines 154-163)** - Reads .clavain/scratch/handoff.md
9. **In-Flight Agent Detection (lines 165-210)** - Finds agents still running from previous sessions
10. **Output (lines 213-220)** - Injects all context into hookSpecificOutput.additionalContext

---

## 2. Sprint & Work Skills: Interlock References

### Search Results
Interlock appears in 2 key command files:

#### commands/setup.md (line 38)
```
claude plugin install interlock@interagency-marketplace
```
Listed as required companion plugin.

#### commands/doctor.md (lines 115-137)
Complete integration check for interlock:
- Detects interlock installation via marker file ~/.claude/plugins/cache/*/interlock/*/scripts/interlock-register.sh
- Checks intermute health at http://127.0.0.1:7338/health
- Checks agent registration via /tmp/interlock-agent-*.json files
- Offers /interlock:join command to participate
- Offers /interlock:setup to install intermute

#### hooks/session-start.sh (lines 95-99)
Interlock discovery and announcement in companion context - but NO auto-join logic.

#### hooks/lib.sh (lines 80-97)
Function _discover_interlock_plugin() searches for interlock root directory.

### Key Finding: NO Auto-Join
The doctor command offers guidance to join (/interlock:join) but SessionStart hook does NOT auto-join. Session must manually run /interlock:join or rely on skill prompts.

---

## 3. CLAUDE_ENV_FILE Exports in SessionStart

### Current Exports
File: /root/projects/Interverse/hub/clavain/hooks/session-start.sh (lines 18-22)

Single export:
```bash
export CLAUDE_SESSION_ID=${_session_id}
```

**Purpose:** Downstream tools (e.g., interphase's _gate_update_statusline) use this to write bead state for statusline.

### Helper Functions
lib.sh provides _claude_project_dir() to encode CWD to session dir path for agent JSONL location tracking.

---

## 4. Intermute Integration: What Doesn't Exist

### No SessionStart Intermute Integration
- NO auto-join logic in SessionStart hook
- NO intermute health check on session start
- NO /tmp/interlock-agent-*.json creation in hook
- NO intermute socket/TCP registration in hook

### What EXISTS Instead
- Doctor command checks intermute health at http://127.0.0.1:7338/health
- Doctor offers setup guidance (/interlock:setup to start intermute)
- Doctor offers join guidance (/interlock:join to register)
- Setup command lists interlock installation
- Interlock plugin discovered & announced in companion context

### Interlock Plugin Architecture
File: /root/projects/Interverse/hub/clavain/docs/prds/2026-02-14-interlock-multi-agent-coordination.md

**Components:**
1. **intermute** (Go service) - SQLite-backed coordination server on TCP 127.0.0.1:7338
2. **interlock companion** - MCP wrapper with 9 tools exposed
3. **Pre-commit hooks** - Git enforcement for file conflicts

---

## 5. Hook Dependencies & Library Structure

### lib.sh: Shared Utilities
File: /root/projects/Interverse/hub/clavain/hooks/lib.sh (233 lines)

**Key functions:**
- _discover_*_plugin() x5 - Find companion plugins in cache
- _claude_project_dir() - Encode CWD to project dir path
- _extract_agent_task() - Parse JSONL for task description
- _detect_inflight_agents() - Find live agents from previous sessions
- _write_inflight_manifest() - Write .clavain/scratch/inflight-agents.json (called by Stop hook)
- escape_for_json() - Safe JSON string escaping

### sprint-scan.sh: Sprint Context Library
File: /root/projects/Interverse/hub/clavain/hooks/sprint-scan.sh (350+ lines)

**sprint_brief_scan()** (used by SessionStart) checks:
- HANDOFF.md presence
- Orphaned brainstorms (>= 2)
- Incomplete plans (< 50%, > 1 day old)
- Stale beads
- Strategy gaps (brainstorms exist but no PRDs)

**sprint_full_scan()** - Detailed report for /clavain:sprint-status command

---

## 6. Stop Hook: Session Handoff

File: /root/projects/Interverse/hub/clavain/hooks/session-handoff.sh (100+ lines)

**Triggers on incomplete work:**
- Uncommitted git changes
- In-progress beads (via bd list --status=in_progress)
- In-flight agents (from inflight-agents.json)

**Actions:**
1. Writes .clavain/scratch/inflight-agents.json (via _write_inflight_manifest())
2. Creates sentinel /tmp/clavain-handoff-{SESSION_ID}
3. Asks Claude to write HANDOFF.md or .clavain/scratch/handoff.md before stopping

---

## 7. Hook Call Graph

```
session-start.sh (entry point)
├── source lib.sh
├── source sprint-scan.sh
│   └── sprint_brief_scan() → outputs signals
├── source lib-discovery.sh (shim to interphase)
├── _discover_interflux_plugin() → announces
├── _discover_interpath_plugin() → announces
├── _discover_interwatch_plugin() → announces
├── _discover_interlock_plugin() → announces (NO JOIN LOGIC)
└── Output JSON to stdout

session-handoff.sh (Stop hook)
├── source lib.sh
├── _write_inflight_manifest()
└── Prompt for HANDOFF.md if signals detected
```

---

## 8. File Paths: Where to Add Auto-Join Logic

### Option A: SessionStart Hook (RECOMMENDED)
File: /root/projects/Interverse/hub/clavain/hooks/session-start.sh

**Insert after line 99** (after interlock discovery):
```bash
# Auto-join intermute coordination if interlock is installed
if [[ -n "$interlock_root" ]]; then
    if curl -s --connect-timeout 1 http://127.0.0.1:7338/health >/dev/null 2>&1; then
        _session_id=$(echo "$HOOK_INPUT" | jq -r '.session_id // empty' 2>/dev/null) || _session_id=""
        if [[ -n "$_session_id" ]]; then
            bash "${interlock_root}/scripts/interlock-register.sh" \
                --session "${_session_id}" \
                --project "$(pwd)" 2>/dev/null || true
        fi
    fi
fi
```

**Benefits:**
- Runs once per session automatically
- Uses existing interlock discovery
- Graceful failure if intermute not running

### Option B: Sprint Pre-Flight Context
File: /root/projects/Interverse/hub/clavain/hooks/sprint-scan.sh

Add function sprint_coordination_check() to detect interlock+intermute readiness and inject status into SessionStart context.

### Option C: New Coordination Skill
Create /root/projects/Interverse/hub/clavain/skills/multi-agent-sprint-startup/SKILL.md for /clavain:multi-agent-sprint-startup command.

---

## 9. Discovery Function Details

### _discover_interlock_plugin() Implementation
File: /root/projects/Interverse/hub/clavain/hooks/lib.sh (lines 83-97)

**Returns:** Interlock plugin root directory, or empty if not found.

**Pattern used by all _discover_*_plugin() functions:**
1. Check ${PLUGIN_NAME_ROOT} env var first
2. Search plugin cache for marker file
3. Return plugin root directory (2 levels up from marker)
4. Empty string if not found

---

## 10. Related Files

### Key Documents
1. docs/prds/2026-02-14-interlock-multi-agent-coordination.md - Full vision & spec
2. commands/setup.md - Installation instructions for companions
3. commands/doctor.md - Health checks for intermute + interlock
4. AGENTS.md - Comprehensive Clavain dev guide
5. CLAUDE.md - Quick reference

### Companion Plugins Discovered
1. interflux - Multi-agent review engine
2. interphase - Phase tracking, gates, work discovery
3. interpath - Product artifact generation
4. interwatch - Doc freshness monitoring
5. interlock - Multi-agent file coordination (MCP wrapper around intermute)

---

## 11. CLAUDE_ENV_FILE Extension Point

### Current Usage
Only CLAUDE_SESSION_ID exported for interphase statusline gate.

### Recommended Extensions
Could add to session-start.sh line 21:
```bash
echo "export INTERLOCK_AGENT_JSON=/tmp/interlock-agent-${_session_id}.json" >> "$CLAUDE_ENV_FILE"
echo "export INTERMUTE_URL=http://127.0.0.1:7338" >> "$CLAUDE_ENV_FILE"
```

So downstream tools have instant access to agent registration file and intermute endpoint.

---

## 12. Testing Recommendations

1. **Verify SessionStart auto-join:**
   - Check /tmp/interlock-agent-{SESSION_ID}.json exists after SessionStart
   - Verify agent appears in intermute's agent list

2. **Verify Pre-flight context:**
   - Verify coordination status included in SessionStart additionalContext

3. **Verify integration across resume:**
   - Stop session with in-progress beads + interlock join
   - Resume session and verify agent re-joins automatically

---

## Conclusion

Clavain's SessionStart hook is a sophisticated context injection system. **Intermute integration is missing** — the hook announces interlock availability but doesn't auto-join. The doctor command provides all health checks and guidance; SessionStart should call the same auto-join logic.

**Key integration points for implementation:**
1. **Line 95-99** in session-start.sh - After interlock discovery
2. **Environment export** - Add INTERLOCK_AGENT_JSON and INTERMUTE_URL to CLAUDE_ENV_FILE
3. **Sprint pre-flight** - Extend sprint-scan.sh with sprint_coordination_check() function
