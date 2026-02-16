# Correctness Review: Interlock Reservation Negotiation Protocol

**Reviewed by:** Julik (Flux-drive Correctness Reviewer)
**Date:** 2026-02-15
**Plan:** `/root/projects/Interverse/docs/plans/2026-02-15-interlock-reservation-negotiation.md`

## Executive Summary

The negotiation protocol plan has **5 high-priority correctness failures** that can cause data corruption, lost reservations, and deadlocks. The core issues are:

1. **Race in blocking poll loop (Task 2)** — lost wakeup between poll and sleep
2. **Timeout enforcement is probabilistic** — depends on agents calling `fetch_inbox`, fails if nobody calls
3. **Auto-release is non-atomic** — TOCTOU between dirty-check and release
4. **Thread ID collisions** — millisecond timestamp can collide under concurrent requests
5. **Pre-edit hook race** — two agents can simultaneously auto-release the same reservation

All five failures can occur in production with realistic timing and are not recoverable without external intervention.

---

## Finding 1: Lost Wakeup in Blocking Poll Loop (CRITICAL)

**Location:** Task 2, lines 333-364 (negotiate_release blocking mode)
**Severity:** CRITICAL — can deadlock agents indefinitely
**Failure Mode:** Lost wakeup between FetchThread and Sleep

### Failure Narrative

**Setup:**
- Agent A holds reservation on `router.go`
- Agent B calls `negotiate_release` with `wait_seconds: 30`
- Agent A's pre-edit hook processes the release-request at **T+2 seconds** and sends `release-ack`

**Interleaving:**

```
T+0s:  Agent B: sends release-request, starts blocking wait loop
T+1.5s: Agent B: calls FetchThread(threadID) → returns [], no ack yet
T+1.9s: Agent A: pre-edit hook checks inbox, finds release-request
T+2.0s: Agent A: auto-releases reservation, sends release-ack to threadID
T+2.1s: Agent B: enters time.Sleep(2s) — misses the ack entirely
T+4.1s: Agent B: wakes, calls FetchThread → ack is now visible
```

**Problem:** If the interleaving is tighter:

```
T+1.5s: Agent B: calls FetchThread(threadID) → returns []
T+1.9s: Agent A: sends release-ack
T+2.0s: Agent B: enters time.Sleep(2s) without checking for new messages
```

The `release-ack` arrives **after** `FetchThread` but **before** `time.Sleep`. Agent B now sleeps for 2 seconds even though the response is available. This is not a correctness failure per se, but demonstrates the race.

**Actual Critical Scenario — Timeout Race:**

```
T+28s: Agent B: FetchThread returns [] (no ack yet)
T+28.5s: Agent A: sends release-ack
T+29s: Agent B: enters Sleep(2s)
T+30s: TIMEOUT — Agent B returns {"status": "timeout"} even though ack arrived at T+28.5s
```

Agent B reports timeout when the holder responded within the deadline. The requester now believes the holder is unresponsive and may escalate (force-release via Task 6 timeout mechanism), but the holder has already released. This creates a zombie state where both agents think they have control.

### Root Cause

The loop structure is:

```go
for time.Now().Before(deadline) {
    msgs, err := c.FetchThread(ctx, threadID)  // ← Check
    if err == nil {
        // ... parse messages ...
    }
    time.Sleep(pollInterval)  // ← Sleep (unconditional)
}
```

**Problem:** `Sleep` happens regardless of whether a new message arrived between the `FetchThread` call and the `Sleep` call. Classic TOCTOU race: **Check-Then-Sleep** is not atomic.

### Correct Fix

Use event-driven wakeup or at minimum, check immediately before timeout:

```go
for {
    msgs, err := c.FetchThread(ctx, threadID)
    if err == nil {
        for _, m := range msgs {
            var parsed map[string]any
            if json.Unmarshal([]byte(m.Body), &parsed) == nil {
                msgType, _ := parsed["type"].(string)
                if msgType == "release-ack" {
                    return jsonResult(map[string]any{"status": "released", ...})
                }
                if msgType == "release-defer" {
                    return jsonResult(map[string]any{"status": "deferred", ...})
                }
            }
        }
    }

    // Check deadline BEFORE sleeping
    remaining := time.Until(deadline)
    if remaining <= 0 {
        // Final check to avoid lost wakeup race at boundary
        msgs, err := c.FetchThread(ctx, threadID)
        if err == nil {
            for _, m := range msgs {
                var parsed map[string]any
                if json.Unmarshal([]byte(m.Body), &parsed) == nil {
                    msgType, _ := parsed["type"].(string)
                    if msgType == "release-ack" {
                        return jsonResult(map[string]any{"status": "released", ...})
                    }
                    if msgType == "release-defer" {
                        return jsonResult(map[string]any{"status": "deferred", ...})
                    }
                }
            }
        }
        return jsonResult(map[string]any{"status": "timeout", ...})
    }

    sleepDuration := pollInterval
    if remaining < sleepDuration {
        sleepDuration = remaining
    }
    time.Sleep(sleepDuration)
}
```

**Better:** Use context deadline + long-poll if Intermute supports it, or SSE/websocket for push notifications.

---

## Finding 2: Timeout Enforcement is Probabilistic (HIGH)

**Location:** Task 6, lines 902-1000 (checkNegotiationTimeouts)
**Severity:** HIGH — timeouts may never fire, holders can squat indefinitely
**Failure Mode:** Lazy evaluation depends on agent calling fetch_inbox

### Failure Narrative

**Setup:**
- Agent B sends urgent `release-request` to Agent A at T+0 (5-minute timeout)
- Agent A ignores the request (busy, crashed, or malicious)
- Agent B uses `wait_seconds: 0` (non-blocking mode), returns immediately with `thread_id`
- Agent B then **never calls `fetch_inbox` again** (working on other tasks, or blocked on unrelated work)

**Timeline:**

```
T+0m:   Agent B: negotiate_release (urgent, wait_seconds: 0) → returns thread_id
T+0m:   Agent B: continues other work, does not poll inbox
T+5m:   TIMEOUT DEADLINE — but checkNegotiationTimeouts never runs
T+10m:  Agent B: still waiting, reservation still held by Agent A
T+60m:  Agent B: finally calls fetch_inbox → timeout check fires, force-releases
```

**Problem:** Timeout is enforced **only when an agent calls `fetch_inbox`**. If Agent B never calls `fetch_inbox`, the timeout never fires. The reservation remains held by Agent A indefinitely.

**Worse Scenario — No Agent Polls:**

```
T+0m:   Agent B: negotiate_release (urgent) to Agent A
T+0m:   Agent B: crashes or exits session
T+5m:   TIMEOUT — no enforcement, reservation persists
T+60m:  New Agent C: tries to reserve same file → conflict with Agent A's stale reservation
T+61m:  Agent C: calls negotiate_release to Agent A → timeout check STILL doesn't fire because Agent C's inbox doesn't contain the original expired request (it was sent TO Agent B's inbox, not Agent C's)
```

The expired negotiation is orphaned. Agent A's reservation will only be released when:
1. Agent A calls `fetch_inbox` (unlikely, A is the holder, not the requester)
2. The reservation's TTL expires (could be 15 minutes, unrelated to negotiation timeout)
3. Manual intervention

### Root Cause

Lazy timeout enforcement via `checkNegotiationTimeouts` is called from:
- `fetchInbox` tool (line 1008-1009)
- Nowhere else

**Problem:** If no agent calls `fetch_inbox`, timeout checks never run. The plan assumes agents will poll their inbox regularly, but:
- Non-blocking `negotiate_release` callers may not poll again
- Background agents may be idle
- Agents may crash after sending the request

### Correct Fix

**Option 1: Active Timeout Enforcement (Server-Side)**

Move timeout logic to Intermute service:
- Track negotiations in the database with deadline timestamps
- Run a background goroutine that scans for expired negotiations every 30 seconds
- Force-release and send timeout acks automatically

**Option 2: Timeout Goroutine in MCP Server**

Start a background goroutine in the MCP server on first `negotiate_release` call:

```go
var timeoutCheckerOnce sync.Once

func negotiateRelease(c *client.Client) server.ServerTool {
    return server.ServerTool{
        Handler: func(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
            // Start timeout checker on first use
            timeoutCheckerOnce.Do(func() {
                go func() {
                    ticker := time.NewTicker(30 * time.Second)
                    defer ticker.Stop()
                    for range ticker.C {
                        checkNegotiationTimeouts(context.Background(), c)
                    }
                }()
            })
            // ... rest of negotiate_release logic ...
        },
    }
}
```

**Option 3: Hybrid — Requester Polls Its Own Thread**

Non-blocking mode returns `thread_id`. Require the requester to poll that specific thread via a new tool `check_negotiation_status(thread_id)` which:
1. Calls `FetchThread(threadID)`
2. Runs timeout check logic **for that thread only**
3. Force-releases if expired

This keeps timeout enforcement client-side but makes it explicit (agent must call the tool).

**Recommendation:** Option 1 (server-side) is most robust. Option 2 works but ties timeout enforcement to MCP server uptime. Option 3 is acceptable if documented clearly.

---

## Finding 3: Auto-Release TOCTOU Race (HIGH)

**Location:** Task 4, lines 727-754 (pre-edit.sh auto-release logic)
**Severity:** HIGH — can leak reservations or release dirty files
**Failure Mode:** File becomes dirty between check and release

### Failure Narrative

**Setup:**
- Agent A holds reservation on `router.go`
- Agent B sends `release-request` for `router.go`
- Agent A's pre-edit hook checks inbox

**Interleaving:**

```
T+0s:   Agent A: pre-edit hook reads inbox, finds release-request for router.go
T+1s:   Agent A: runs git diff → router.go is clean (no uncommitted changes)
T+2s:   [RACE WINDOW] Agent A: starts editing router.go (Edit tool proceeds)
T+2.5s: Agent A: Edit tool writes changes to router.go (file is now dirty)
T+3s:   Agent A: pre-edit hook sends release_ack, deletes reservation
T+4s:   Agent B: receives ack, reserves router.go, starts editing
```

**Result:** Both Agent A and Agent B are now editing `router.go` concurrently. Agent A has uncommitted changes, Agent B just acquired the reservation. The pre-commit hook will catch the conflict when Agent A commits, but Agent A has lost their reservation and cannot make further edits.

**Worse Scenario — Edit Hook Runs Twice:**

The pre-edit hook runs **before every Edit call**. If Agent A edits `router.go` twice in quick succession:

```
T+0s:   Agent A: Edit(router.go) #1 → pre-edit hook checks inbox, sees release-request
T+0.5s: Agent A: pre-edit hook checks dirty files → router.go is clean (first edit not written yet)
T+1s:   Agent A: pre-edit hook auto-releases router.go, sends ack
T+1.5s: Agent A: Edit tool writes changes from call #1
T+2s:   Agent A: Edit(router.go) #2 → pre-edit hook runs again
T+2.5s: Agent A: pre-edit hook checks conflicts → no reservation! (already released)
T+3s:   Agent A: pre-edit hook tries to auto-reserve → CONFLICT (Agent B now holds it)
T+3.5s: Agent A: Edit #2 BLOCKS
```

Agent A's second edit is blocked even though they had a valid reservation at T+0.

### Root Cause

The dirty-check and release are not atomic:

```bash
DIRTY_FILES=$(git diff --name-only 2>/dev/null; git diff --cached --name-only 2>/dev/null)

# ... later ...

if [[ "$HAS_DIRTY" == "false" ]]; then
    # ← RACE WINDOW: file can become dirty here
    intermute_curl DELETE "/api/reservations/${res_id}" 2>/dev/null || true
fi
```

**Problem:** `git diff` reads the working tree state at T+0, but the reservation is deleted at T+1. If the Edit tool modifies the file between T+0 and T+1, the check is stale.

**Additional Issue — Glob Expansion:**

The plan says "all-or-nothing auto-release for glob reservations" (line 17), but the implementation checks `path_pattern == "$REQ_FILE"` (line 751). If the reservation pattern is `internal/http/*.go` and the request is for `internal/http/server.go`, the pattern match may succeed, but the dirty check only looks at the specific file requested, not all files matching the glob.

Example:

```
Reservation: internal/http/*.go (holds server.go, client.go, router.go)
Request: internal/http/server.go
Dirty check: git diff → internal/http/client.go is dirty
Auto-release: Releases internal/http/*.go reservation
Result: Agent A loses reservation even though client.go has uncommitted changes
```

### Correct Fix

**Option 1: Lock File Before Check (Pre-Edit Hook Cannot Do This)**

The pre-edit hook runs **before** the Edit tool modifies the file, so we can't lock the working tree. This fix is not viable in the hook context.

**Option 2: Re-Check After Edit Completes (Post-Edit Hook)**

Move auto-release to a **PostToolUse:Edit** hook:

```bash
# PostToolUse:Edit hook
INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

# Check if file was actually modified
if git diff --quiet "$FILE_PATH" 2>/dev/null; then
    # File is clean after edit → safe to auto-release
    # Check inbox for release-requests for this file
    # ... auto-release logic ...
fi
```

**Problem:** This changes the semantics. The holder only releases **after completing an edit**, not before. If the holder is working on a different file, they never check the inbox.

**Option 3: Advisory Context Only (No Auto-Release)**

Remove auto-release from the pre-edit hook entirely. Instead, emit advisory context:

```bash
if [[ -n "$RELEASE_REQS" ]]; then
    cat <<ENDJSON
{"additionalContext": "INTERLOCK: ${REQ_FROM} requests release of ${REQ_FILE}. Use respond_to_release to ack or defer."}
ENDJSON
fi
```

Agent A must manually call `respond_to_release` after checking the file state. This is safer but requires agent cooperation.

**Option 4: Pre-Edit Hook Blocks If Release-Request Present (Strict)**

If a release-request is pending and the file is clean, **block the edit** and instruct the agent to release:

```bash
if [[ "$HAS_DIRTY" == "false" ]]; then
    cat <<ENDJSON
{"decision": "block", "reason": "INTERLOCK: ${REQ_FROM} requests ${REQ_FILE}. File is clean. Call respond_to_release(action='release') to release, then retry edit."}
ENDJSON
    exit 0
fi
```

This prevents the TOCTOU race by refusing to proceed until the agent explicitly releases.

**Recommendation:** Option 4 (block) is safest for exclusive reservations. Option 3 (advisory) is acceptable if auto-release is deemed non-critical.

---

## Finding 4: Thread ID Collisions (MEDIUM)

**Location:** Task 2, line 294 (thread ID generation)
**Severity:** MEDIUM — can cause cross-talk between negotiations
**Failure Mode:** Millisecond timestamp collides under concurrent requests

### Failure Narrative

**Setup:**
- Agent B and Agent C both request the same file from Agent A simultaneously

**Interleaving:**

```
T+0.000s: Agent B: negotiate_release(file="router.go") → threadID = "negotiate-router.go-1697654321000"
T+0.000s: Agent C: negotiate_release(file="router.go") → threadID = "negotiate-router.go-1697654321000"
T+0.001s: Agent A: receives both requests with same thread_id
T+0.002s: Agent A: responds with release_ack on thread "negotiate-router.go-1697654321000"
T+0.003s: Both Agent B and Agent C poll FetchThread(threadID) → both see the ack
T+0.004s: Both agents believe they have the reservation
```

**Result:** Both agents proceed to reserve the file. The first reservation succeeds, the second gets a conflict error, but both agents already burned their blocking wait time and may have made decisions based on the false positive.

**Probability:** Millisecond-level collisions are rare but possible:
- If two agents call `negotiate_release` in the same millisecond for the same file
- On a fast machine, multiple goroutines in the same MCP server can call `time.Now().UnixMilli()` within the same millisecond

Likelihood increases with:
- High-frequency negotiation patterns (e.g., automated agents retrying every second)
- Same file being contested by multiple agents (hot file)

### Root Cause

Thread ID generation:

```go
threadID := fmt.Sprintf("negotiate-%s-%d", file, time.Now().UnixMilli())
```

**Problem:** `UnixMilli()` provides millisecond precision. If two negotiate_release calls happen within the same millisecond for the same file, they generate identical thread IDs.

### Correct Fix

Use a globally unique ID with sufficient entropy:

```go
import "github.com/google/uuid"

threadID := fmt.Sprintf("negotiate-%s-%s", file, uuid.New().String())
// Example: "negotiate-router.go-a1b2c3d4-e5f6-7890-abcd-ef1234567890"
```

Or use atomic counter + agent ID:

```go
var negotiationCounter atomic.Uint64

func negotiateRelease(...) {
    seq := negotiationCounter.Add(1)
    threadID := fmt.Sprintf("negotiate-%s-%s-%d", file, c.AgentID(), seq)
    // Example: "negotiate-router.go-agent-b-42"
}
```

**Recommendation:** UUID is simplest and collision-proof. Atomic counter requires shared state across tool calls, which works in Go but needs careful lifecycle management.

---

## Finding 5: Pre-Edit Hook Race — Concurrent Auto-Release (MEDIUM)

**Location:** Task 4, lines 706-785 (pre-edit.sh inbox check)
**Severity:** MEDIUM — can cause double-release and lost reservations
**Failure Mode:** Two agents editing simultaneously, both check inbox and auto-release

### Failure Narrative

**Setup:**
- Agent A holds reservation on `router.go` and `server.go`
- Agent A has two Claude Code sessions open (Session 1 and Session 2), same `INTERMUTE_AGENT_ID`
- Agent B sends `release-request` for `router.go`

**Interleaving:**

```
T+0s:   Agent A Session 1: Edit(server.go) → pre-edit hook runs
T+0s:   Agent A Session 2: Edit(utils.go) → pre-edit hook runs (parallel)
T+0.5s: Session 1: checks inbox, finds release-request for router.go
T+0.5s: Session 2: checks inbox, finds release-request for router.go
T+1s:   Session 1: git diff → router.go is clean
T+1s:   Session 2: git diff → router.go is clean
T+1.5s: Session 1: deletes reservation for router.go, sends release_ack
T+1.5s: Session 2: deletes reservation for router.go, sends release_ack (DELETE is idempotent, returns 404)
T+2s:   Agent B: receives TWO release_ack messages for the same thread
```

**Result:** Agent B sees duplicate acks (harmless but confusing). More critically:

**Worse Scenario — Auto-Reserve Race:**

```
T+0s:   Session 1: pre-edit hook auto-releases router.go
T+0s:   Session 2: pre-edit hook auto-releases router.go (404, already deleted)
T+0.5s: Session 1: continues, does NOT auto-reserve router.go (editing server.go, not router.go)
T+1s:   Session 2: continues, does NOT auto-reserve router.go (editing utils.go, not router.go)
T+2s:   Agent B: reserves router.go
T+3s:   Session 1: Edit(router.go) → pre-edit hook sees conflict with Agent B
T+4s:   Session 1: BLOCKED
```

Agent A lost their reservation even though they intended to keep working on `router.go`. The auto-release logic assumes only one session per agent, but the plan does not enforce this.

### Root Cause

The inbox check throttle is per-session (line 707-710):

```bash
NEG_FLAG=$(negotiation_check_path "$SESSION_ID")
if [[ ! -f "$NEG_FLAG" ]] || ! find "$NEG_FLAG" -mmin -0.5 -print -quit; then
    touch "$NEG_FLAG"
    # ... fetch inbox, auto-release ...
fi
```

**Problem:** Two sessions with different `SESSION_ID` values bypass each other's throttle. Both sessions can fetch the inbox and auto-release within the same 30-second window.

**Additional Issue — Reservation is Agent-Wide, Not Session-Wide:**

Reservations are keyed by `agent_id` (not `session_id`). If Agent A has two sessions, both sessions share the same set of reservations. When Session 1 auto-releases `router.go`, Session 2 also loses the reservation, even if Session 2 is actively editing `router.go`.

### Correct Fix

**Option 1: Global Lock Across Sessions (Same Agent)**

Use a shared lock file based on `INTERMUTE_AGENT_ID`, not `SESSION_ID`:

```bash
NEG_FLAG="/tmp/interlock-negotiate-${INTERMUTE_AGENT_ID}.lock"
(
    flock -n 200 || exit 0  # Another session is already checking inbox, skip
    # ... fetch inbox, auto-release ...
) 200>"$NEG_FLAG"
```

**Problem:** Requires `flock` (not POSIX, but available on Linux). Also, this only prevents concurrent inbox checks, not the underlying TOCTOU race from Finding 3.

**Option 2: Disable Auto-Release for Multi-Session Agents**

Detect if multiple sessions exist for this agent:

```bash
ACTIVE_SESSIONS=$(find /tmp -name "interlock-agent-${INTERMUTE_AGENT_ID}-*.json" | wc -l)
if [[ $ACTIVE_SESSIONS -gt 1 ]]; then
    # Multiple sessions active, disable auto-release (advisory only)
    cat <<ENDJSON
{"additionalContext": "INTERLOCK: Multiple sessions detected. Auto-release disabled. Use respond_to_release manually."}
ENDJSON
    exit 0
fi
```

**Option 3: Move Auto-Release to MCP Tool (Explicit Call)**

Remove auto-release from the pre-edit hook entirely. Add a new MCP tool `process_inbox_requests` that agents call explicitly:

```go
func processInboxRequests(c *client.Client) server.ServerTool {
    // Fetch inbox, check for release-requests, auto-release clean files
    // Return summary of actions taken
}
```

Agents call this tool periodically (e.g., before starting a new task). This avoids hook concurrency issues.

**Recommendation:** Option 3 (explicit tool) is cleanest. Option 2 (disable for multi-session) is a reasonable safeguard if auto-release is kept in the hook.

---

## Additional Observations

### 1. Message Struct Field Mismatch (Low Priority)

**Location:** Task 1, lines 138-151 (Message struct)

The plan updates the `Message` struct to include `ThreadID`, `Subject`, `Importance`, `AckRequired`. But the current `Message` struct (client.go:106-113) uses:

```go
type Message struct {
    ID        string `json:"message_id"`  // ← Note: json tag is "message_id"
    From      string `json:"from"`
    Body      string `json:"body"`
    Timestamp string `json:"timestamp"`
    Read      bool   `json:"read"`
}
```

The plan's version adds fields but changes `ID` json tag to `id,omitempty` and adds `MessageID` as an alias. This is fine, but the plan should explicitly call out that **existing Intermute API responses may use either `message_id` or `id`**, and the struct needs to handle both.

**Recommendation:** Document this aliasing explicitly, or add a test that verifies both field names unmarshal correctly.

### 2. No Validation of Thread Ownership (Low Priority)

**Location:** Task 3, lines 535-616 (respond_to_release)

The `respond_to_release` tool accepts `thread_id` and `requester` as strings but does not verify that:
1. The thread exists
2. The calling agent is actually the holder in that thread
3. The requester is actually the original requester

**Scenario:**

```
Agent B: negotiate_release to Agent A → thread "negotiate-file-123"
Agent C: respond_to_release(thread_id="negotiate-file-123", action="release")
```

Agent C can send a fake `release_ack` on Agent B's thread. Agent B will see the ack and proceed, but Agent A still holds the reservation.

**Recommendation:** Add validation:
- Fetch the thread via `FetchThread(threadID)`
- Verify the first message is a `release-request` from `requester` to `c.AgentID()`
- Verify `c.AgentID()` matches the holder in the original request

Alternatively, require the tool to accept the original `release-request` message ID, fetch that message, extract the thread ID, and validate ownership.

### 3. FetchThread API Endpoint Not Validated (Medium Priority)

**Location:** Task 1, lines 181-197 (FetchThread method)

The plan assumes Intermute has a `GET /api/threads/{threadID}` endpoint. This endpoint is not present in the current Intermute codebase (based on the existing client.go methods, which only use `/api/reservations`, `/api/agents`, `/api/messages`, `/api/inbox`).

**Impact:** If Intermute does not implement thread support, the entire negotiation protocol fails at runtime.

**Recommendation:** Verify the Intermute API surface. If `/api/threads/{threadID}` does not exist, either:
1. Add it to Intermute (server-side change, out of scope for this plan)
2. Implement client-side thread filtering: `FetchInbox` with filter on `thread_id` field
3. Use the `subject` field as a quasi-thread-ID (fragile, but works if thread IDs are unique)

**Suggested Implementation (Client-Side Fallback):**

```go
func (c *Client) FetchThread(ctx context.Context, threadID string) ([]Message, error) {
    // Try the threads endpoint first
    q := url.Values{}
    q.Set("project", c.project)
    path := "/api/threads/" + url.PathEscape(threadID) + "?" + q.Encode()
    var result struct {
        Messages []Message `json:"messages"`
    }
    if err := c.doJSON(ctx, "GET", path, nil, &result); err != nil {
        // Fallback: fetch inbox and filter by thread_id
        if isNotFound(err) {
            return c.fetchThreadFallback(ctx, threadID)
        }
        return nil, err
    }
    return result.Messages, nil
}

func (c *Client) fetchThreadFallback(ctx context.Context, threadID string) ([]Message, error) {
    msgs, _, err := c.FetchInbox(ctx, "")
    if err != nil {
        return nil, err
    }
    var thread []Message
    for _, m := range msgs {
        if m.ThreadID == threadID {
            thread = append(thread, m)
        }
    }
    return thread, nil
}
```

---

## Priority Ranking

| Finding | Severity | Impact | Fix Complexity | Recommendation |
|---------|----------|--------|----------------|----------------|
| 1. Lost wakeup in poll loop | CRITICAL | Deadlock, false timeouts | Low (add final check before timeout) | Fix before merge |
| 2. Timeout enforcement is lazy | HIGH | Indefinite squatting | Medium (background goroutine or server-side) | Fix before merge |
| 3. Auto-release TOCTOU | HIGH | Lost reservations, dirty release | Medium (block on release-request or remove auto-release) | Fix before merge |
| 4. Thread ID collisions | MEDIUM | Cross-talk | Low (use UUID) | Fix before merge |
| 5. Pre-edit concurrent auto-release | MEDIUM | Double-release | Medium (global lock or disable for multi-session) | Fix before merge |
| 6. FetchThread endpoint missing | MEDIUM | Runtime failure | Low (verify API or add fallback) | Verify before Task 1 |
| 7. respond_to_release no validation | LOW | Spoofing | Low (validate thread ownership) | Fix in Task 3 or defer to hardening |
| 8. Message struct aliasing | LOW | Unmarshal fragility | Low (document or test) | Document in Task 1 |

---

## Recommended Changes to Plan

### Task 2 (negotiate_release)

**Add final check before timeout:**

```go
// Blocking mode: poll for response
deadline := time.Now().Add(time.Duration(waitSec) * time.Second)
pollInterval := 2 * time.Second
for {
    msgs, err := c.FetchThread(ctx, threadID)
    if err == nil {
        for _, m := range msgs {
            var parsed map[string]any
            if json.Unmarshal([]byte(m.Body), &parsed) == nil {
                msgType, _ := parsed["type"].(string)
                if msgType == "release-ack" {
                    return jsonResult(map[string]any{
                        "status":      "released",
                        "thread_id":   threadID,
                        "released_by": m.From,
                        "reason":      parsed["reason"],
                    })
                }
                if msgType == "release-defer" {
                    return jsonResult(map[string]any{
                        "status":      "deferred",
                        "thread_id":   threadID,
                        "eta_minutes": parsed["eta_minutes"],
                        "reason":      parsed["reason"],
                    })
                }
            }
        }
    }

    remaining := time.Until(deadline)
    if remaining <= 0 {
        // Final check to avoid lost wakeup
        msgs, err := c.FetchThread(ctx, threadID)
        if err == nil {
            for _, m := range msgs {
                var parsed map[string]any
                if json.Unmarshal([]byte(m.Body), &parsed) == nil {
                    msgType, _ := parsed["type"].(string)
                    if msgType == "release-ack" {
                        return jsonResult(map[string]any{"status": "released", ...})
                    }
                    if msgType == "release-defer" {
                        return jsonResult(map[string]any{"status": "deferred", ...})
                    }
                }
            }
        }
        return jsonResult(map[string]any{"status": "timeout", "thread_id": threadID, "waited": waitSec})
    }

    sleepDuration := pollInterval
    if remaining < sleepDuration {
        sleepDuration = remaining
    }
    time.Sleep(sleepDuration)
}
```

**Use UUID for thread IDs:**

```go
import "github.com/google/uuid"

threadID := fmt.Sprintf("negotiate-%s", uuid.New().String())
```

### Task 4 (Auto-Release)

**Option A: Block edit if release-request present and file is clean**

Replace auto-release logic (lines 749-774) with:

```bash
if [[ "$HAS_DIRTY" == "false" ]]; then
    # File is clean and release requested — block edit, instruct agent to release manually
    cat <<ENDJSON
{"decision": "block", "reason": "INTERLOCK: ${REQ_FROM} requests ${REQ_FILE}. File is clean. Call respond_to_release(thread_id='${REQ_THREAD}', action='release') to release, then retry edit."}
ENDJSON
    exit 0
fi
```

**Option B: Remove auto-release, advisory only**

Replace auto-release logic with:

```bash
PULL_CONTEXT="${PULL_CONTEXT:-}INTERLOCK: ${REQ_FROM} requests ${REQ_FILE} (${REQ_THREAD}). Use respond_to_release to ack or defer. "
```

### Task 6 (Timeout Enforcement)

**Add background goroutine for active timeout checks:**

```go
var timeoutCheckerOnce sync.Once
var timeoutCheckerStop chan struct{}

func startTimeoutChecker(c *client.Client) {
    timeoutCheckerOnce.Do(func() {
        timeoutCheckerStop = make(chan struct{})
        go func() {
            ticker := time.NewTicker(30 * time.Second)
            defer ticker.Stop()
            for {
                select {
                case <-ticker.C:
                    checkNegotiationTimeouts(context.Background(), c)
                case <-timeoutCheckerStop:
                    return
                }
            }
        }()
    })
}

func negotiateRelease(c *client.Client) server.ServerTool {
    startTimeoutChecker(c)  // Ensure checker is running
    return server.ServerTool{
        // ... existing implementation ...
    }
}
```

---

## Conclusion

The negotiation protocol is a well-structured design, but the implementation plan has **5 critical race conditions** that must be fixed before deployment:

1. **Blocking poll loop** needs a final check before timeout to avoid lost wakeups
2. **Timeout enforcement** must be active (background goroutine or server-side), not lazy
3. **Auto-release** must be atomic or removed (prefer blocking edit + manual release)
4. **Thread IDs** must use UUIDs to prevent collisions
5. **Pre-edit concurrency** must use global locks or disable auto-release for multi-session agents

**Recommended Approach:**

1. Fix Findings 1 and 4 in Task 2 (low effort, high impact)
2. Fix Finding 2 in Task 6 (medium effort, critical for correctness)
3. Choose Option A or B for Finding 3 in Task 4 (decision: auto-release or manual?)
4. Add global lock or disable auto-release for Finding 5 in Task 4
5. Verify FetchThread API exists before implementing Task 1

With these fixes, the protocol will be robust against timing races and safe for production multi-agent use.

---

**Review completed:** 2026-02-15
**Reviewer:** Julik (Flux-drive Correctness Reviewer)
**Next Steps:** Address Findings 1-5 before implementation begins. Verify Intermute thread API surface.
