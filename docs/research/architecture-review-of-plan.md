# Architecture Review: Interlock Reservation Negotiation Protocol

**Date:** 2026-02-15
**Target:** `/root/projects/Interverse/docs/plans/2026-02-15-interlock-reservation-negotiation.md`
**Reviewer:** Flux-drive Architecture & Design Reviewer
**Review Focus:** Structure, boundaries, coupling, complexity management, YAGNI

---

## Executive Summary

**Verdict:** Architecture is SOUND with THREE boundary violations to fix before implementation.

The plan successfully layers a structured protocol on existing Intermute infrastructure without leaking abstractions. Client extension pattern is clean, hook piggyback is correct, and task dependencies are properly ordered. However:

**MUST FIX BEFORE IMPLEMENTATION:**
1. **Response tool creates circular dependency** — `respondToRelease` duplicates client logic (pattern overlap, reservation deletion) in tools.go, bypassing client boundary
2. **Timeout enforcement violates tool/client separation** — `checkNegotiationTimeouts` implements business logic (thread parsing, force-release) in tools.go instead of client.go
3. **Pre-edit hook auto-release has missing fail-open circuit breaker** — 2-second timeout on inbox check prevents read failures from blocking edits, but missing on subsequent reservation/message API calls

**Structural health:**
- 11 tools is approaching sub-package threshold but not yet justified — wait for 15-20 tools
- Client extension (MessageOptions, SendMessageFull) follows existing option pattern correctly
- Hook extension reuses existing inbox check infrastructure (throttle flag, lib.sh helpers)

**Recommended fix sequence:**
1. Move `patternsOverlap`, `ReleaseByPattern`, `checkNegotiationTimeouts`, `FetchThread` to client.go (Task 1-3 changes)
2. Add fail-open wrappers to pre-edit hook API calls (Task 4 adjustment)
3. Proceed with implementation as planned

---

## 1. Boundaries & Coupling

### 1.1 Layer Architecture — CORRECT

**Current boundaries:**
- **MCP tools layer** (tools.go) — validation, argument parsing, result formatting
- **Client layer** (client.go) — HTTP API calls, error wrapping, domain types
- **Hook layer** (bash) — pre-edit timing, inbox polling, advisory context injection
- **Structural tests** (Python) — integration contracts, MCP schema validation

**Negotiation protocol respects layers:**
- Tools layer: argument validation (urgency values, required fields), blocking wait loop, result formatting
- Client layer: HTTP requests (SendMessageFull, FetchThread), message/thread types
- Hook layer: throttled inbox check, auto-release decision (git status for dirty files), context emission

**Data flow end-to-end (request path):**
```
Agent → negotiate_release(file, urgency, wait_seconds)
  → Validate args (urgency ∈ {normal, urgent})
  → Client.CheckConflicts(file) [validate holder exists]
  → Client.SendMessageFull(to, body, MessageOptions{ThreadID, Importance, AckRequired})
    → POST /api/messages with thread_id/subject/importance fields
  → IF wait_seconds > 0: poll Client.FetchThread(threadID)
    → GET /api/threads/{threadID}
    → Parse messages for release-ack / release-defer
  → Return {status, thread_id, ...}
```

**Data flow (response path):**
```
Holder agent inbox → release-request message
  → respond_to_release(thread_id, action, file)
    → IF action=release:
      → Client.ListReservations → DELETE /api/reservations/{id}
      → Client.SendMessageFull(release-ack, ThreadID)
    → IF action=defer:
      → Client.SendMessageFull(release-defer, ThreadID)
```

**Boundary crossing analysis:**
- ✅ Tools never construct HTTP requests directly — all via client methods
- ✅ Client never parses tool arguments — tools layer owns validation
- ✅ Hooks never call Go code — use intermute_curl bash helper (lib.sh)
- ⚠️ **VIOLATION:** `respondToRelease` duplicates reservation logic (pattern overlap check, deletion) instead of delegating to client
- ⚠️ **VIOLATION:** `checkNegotiationTimeouts` in tools.go implements complex business logic (thread parsing, time calculations, force-release orchestration) that belongs in client.go

**API contract stability:**
- New MessageOptions fields are additive (backward compatible) — old SendMessage still works
- FetchThread returns Message[] (reuses existing type, adds ThreadID/Subject fields already in plan)
- Intermute API unchanged (uses existing message/thread endpoints, no new routes)

### 1.2 Integration Seams — MOSTLY CORRECT

**Failure isolation:**
- ✅ Pre-edit hook inbox check has 30-second throttle (fail-open if Intermute down)
- ✅ Pre-edit hook has --max-time 2 on inbox fetch (circuit breaker for network hangs)
- ⚠️ **MISSING:** Pre-edit hook auto-release calls `intermute_curl DELETE /api/reservations` and `POST /api/messages` without timeout/fail-open — network hang could block all edits
- ✅ negotiate_release blocking wait uses deadline + sleep loop (won't hang forever)
- ✅ Client methods already return errors for HTTP failures (503, timeout, etc.)

**Recommendation:** Add `|| true` fail-open to ALL intermute_curl calls in Task 4 auto-release block (reservation delete, message send, message ack).

### 1.3 Dependency Direction — CORRECT

**Dependency graph (Go packages):**
```
cmd/interlock-mcp → internal/tools → internal/client
                                    ↓
                              Intermute HTTP API
```

No circular dependencies. Tools depend on client, client has no awareness of tools layer.

**Hook dependency graph:**
```
pre-edit.sh → lib.sh → intermute_curl (bash function)
            → scripts/interlock-check.sh → intermute API
```

No dependency on Go code (hooks are bash, binary is separate MCP server process).

**Cross-module boundaries:**
- Interlock client → Intermute service (HTTP API, versioned via Accept header)
- Interlock hooks → Intermute service (same HTTP API, uses curl)
- No dependency on other plugins (interlock is standalone)

**Ownership of negotiation state:**
- Thread state: Intermute owns (messages, thread_id, ack tracking)
- Reservation state: Intermute owns (reservations table, expiry, conflicts)
- Timeout enforcement: **AMBIGUOUS** — plan puts it in tools.go (fetch_inbox handler), but this creates leaky abstraction (tools layer shouldn't parse threads/timestamps)

**Recommendation:** Move timeout enforcement to client.go as `CheckExpiredNegotiations(ctx) ([]ForceReleaseResult, error)`. Tools layer calls it, client layer owns thread parsing logic.

---

## 2. Pattern Analysis

### 2.1 Extension Patterns — CORRECT

**Client extension via MessageOptions:**
```go
// Existing: SendMessage(ctx, to, body string)
// New: SendMessageFull(ctx, to, body string, opts MessageOptions)
```

This follows the **option struct pattern** already present in client.go:
- `NewClient(opts ...Option)` uses functional options for construction
- `ListReservations(ctx, filters map[string]string)` uses map for optional filters
- MessageOptions is a **named struct** (more explicit than map, easier to extend)

**Consistency check:**
- ✅ MessageOptions is a value type (not pointer) — matches mcp.CallToolRequest pattern
- ✅ Optional fields use zero-value defaults (empty string = omit from JSON)
- ✅ Client methods always take context.Context as first param

**Alternative not considered:**
- Variadic functional options: `SendMessage(ctx, to, body string, opts ...MessageOption)`
- **Why current approach is better:** MessageOptions is simpler (4 fields), no builder pattern overhead, easier to test

### 2.2 Hook Extension Pattern — CORRECT

**Pre-edit.sh extension strategy:**
- Lines 24-63: existing commit notification check (throttled, 30s cache)
- Lines 65-137: existing conflict check + auto-reserve
- **NEW (Task 4):** Insert after line 63, before line 65 — release-request auto-release check

**Pattern reuse:**
- ✅ Uses same throttle flag pattern: `negotiation_check_path` helper in lib.sh (matches `inbox_check_path`)
- ✅ Uses same intermute_curl wrapper (fail-open on network errors)
- ✅ Uses same advisory context emission: `{"additionalContext": "INTERLOCK: ..."}` JSON to stdout
- ✅ Feature-flagged: `INTERLOCK_AUTO_RELEASE=1` (default off for staged rollout)

**Separation of concerns:**
- Commit notification: "Pull if another agent committed"
- Conflict check: "Block edit if file reserved by someone else"
- **NEW** Auto-release: "Release my reservation if someone asks and file is clean"

These are orthogonal — no shared state, can be toggled independently.

**Why NOT a separate hook:**
- PreToolUse:Edit fires once per edit — same timing window as commit check
- New hook would duplicate stdin parsing, session ID extraction, project root detection
- Overhead: adding hook requires hooks.json update, plugin reinstall, more hook processes

**Tradeoff:** Pre-edit.sh is now 137 → ~210 lines (54% increase). Still reasonable for bash (not yet justifying a lib-negotiation.sh split).

### 2.3 Naming Consistency — CORRECT

**Tool naming pattern:**
- Existing: `reserve_files`, `release_files`, `check_conflicts`, `my_reservations`, `send_message`, `fetch_inbox`, `request_release`
- New: `negotiate_release`, `respond_to_release`

All tools use **snake_case** (MCP convention), **verb-noun** structure.

**Message type naming:**
- `release-request`, `release-ack`, `release-defer` (kebab-case, matches existing `commit:hash` subject pattern)

**JSON field naming:**
- `thread_id`, `ack_required`, `eta_minutes` (snake_case, matches Intermute API convention)

**State field naming (bead JSON):**
- `auto_advance`, `complexity` (existing sprint fields, snake_case)

No naming drift detected.

### 2.4 Anti-Pattern Detection

**God module risk:** tools.go is 408 lines → ~600 lines after Task 2-3. Still acceptable for flat structure (all tools in one file).

**When to split:**
- Current: 9 tools, 408 lines
- After plan: 11 tools, ~600 lines
- Threshold: 15+ tools OR 1000+ lines
- **Recommendation:** Monitor tool count. At 15 tools, split into `tools/reservation.go`, `tools/messaging.go`, `tools/coordination.go`

**Circular dependency risk:** NONE. Client has no imports of tools package.

**Leaky abstraction — DETECTED:**

**VIOLATION 1:** `respondToRelease` duplicates pattern overlap logic:
```go
// Task 3 implementation has this in tools.go:
for _, r := range reservations {
    if r.IsActive && patternsOverlap(r.PathPattern, file) {
        if err := c.DeleteReservation(ctx, r.ID); err == nil {
            released = true
        }
    }
}
```

This is business logic (which reservations match a file pattern) that belongs in client.go. Tools layer should call `c.ReleaseByPattern(ctx, file)` (added in Task 6 but not used in Task 3).

**Fix:** Task 3 should use `c.ReleaseByPattern(ctx, c.AgentID(), file)` instead of inlining the loop.

**VIOLATION 2:** `checkNegotiationTimeouts` (Task 6) parses thread messages, calculates timeouts, orchestrates force-release:
```go
// This is 100+ lines of business logic in tools.go
for _, m := range msgs {
    var body map[string]any
    json.Unmarshal(...)
    msgType := body["type"]
    urgency := body["urgency"]
    ts := time.Parse(m.CreatedAt)
    timeoutMinutes := urgency == "urgent" ? 5 : 10
    // ... check thread for ack ...
    c.ReleaseByPattern(ctx, holder, file)
    c.SendMessageFull(ctx, holder, ackBody, opts)
}
```

This violates **single responsibility** — tools.go should orchestrate, client.go should contain negotiation logic.

**Fix:** Move to `client.CheckExpiredNegotiations(ctx) ([]NegotiationTimeout, error)`. Tools layer calls it and formats results.

---

## 3. Simplicity & YAGNI

### 3.1 Abstraction Necessity

**MessageOptions struct — JUSTIFIED:**
- Solves current need: thread_id, subject, importance, ack_required are all used in Task 2-3
- Not speculative: every field has a concrete consumer (negotiate_release sets all 4)

**FetchThread method — JUSTIFIED:**
- Blocking wait mode (Task 2) needs thread polling
- Timeout enforcement (Task 6) needs thread scanning for ack messages
- 2 real callers, not premature

**ReleaseByPattern client method — JUSTIFIED:**
- Used by respondToRelease (Task 3) and checkNegotiationTimeouts (Task 6)
- Idempotent semantics (returns 0 if no matches) prevent double-release bugs

**Feature flags — JUSTIFIED:**
- `INTERLOCK_AUTO_RELEASE=1` gates Task 4 (staged rollout, can disable if buggy)
- NOT a permanent toggle — remove flag after 2-week soak period

### 3.2 Premature Extensibility — DETECTED

**urgency levels:**
- Plan drops `low` urgency (originally 3 levels: low/normal/urgent)
- Current: 2 levels (normal=10min, urgent=5min)
- **YAGNI check:** Are 2 levels sufficient?
  - Yes: 2 levels cover "routine request" vs "blocking my work now"
  - Future: if 3rd level needed, additive change (no breaking API)

**wait_seconds blocking mode:**
- Added per flux-drive recommendation (originally fire-and-forget only)
- **YAGNI check:** When would agent use this?
  - Scenario: Agent needs file NOW, wants to wait 30 seconds for response before escalating
  - Concrete: Clavain sprint execution blocked on file reservation
- **Alternative:** Agent calls negotiate_release, then polls fetch_inbox manually
- **Verdict:** Blocking mode reduces chattiness (1 tool call vs 5+ poll loops), JUSTIFIED

**no-force flag — REMOVED (correct):**
- Originally proposed: `no_force` flag on negotiate_release to prevent timeout escalation
- Flux-drive finding: "no enforcement layer" (agent can't prevent timeout, only Intermute can)
- Plan correctly drops this flag (YAGNI applied)

**child bead hierarchy — NOT IN THIS PLAN (good):**
- Flux-drive review flagged sprint bead hierarchy as over-complex (7 beads per sprint)
- This plan does NOT add bead fields to negotiation protocol
- Negotiation state lives in Intermute messages (thread_id, subject, importance)
- **Verdict:** Correctly avoids premature state management

### 3.3 Complexity Budget

**New concepts introduced:**
- Thread-based negotiation (thread_id as correlation ID)
- Urgency levels (normal/urgent → importance + timeout)
- Blocking wait mode (wait_seconds parameter)
- Auto-release on clean files (pre-edit hook feature)
- Timeout escalation (force-release after 5-10min)

**Complexity justified by:**
- Current pain: `request_release` is fire-and-forget (requester never knows if holder saw message)
- Thread support: enables "did they respond?" queries (concrete UX improvement)
- Urgency: enables timeout differentiation (urgent = blocking work, normal = nice-to-have)

**Complexity NOT added:**
- New Intermute API routes (reuses /api/messages, /api/threads)
- New reservation types (reuses existing exclusive reservations)
- New hook types (reuses PreToolUse:Edit)

**LOC impact:**
- tools.go: 408 → ~600 lines (+192, +47%)
- client.go: 364 → ~450 lines (+86, +24%)
- pre-edit.sh: 137 → ~210 lines (+73, +53%)
- Total: +351 lines across 3 files

**Comparison to alternative:**
- Without negotiation: agents must manually poll fetch_inbox every 10-20 seconds, parse messages, track thread state in memory (lost on session restart)
- With negotiation: tools handle threading, hooks auto-release clean files, timeout enforcement is lazy (piggybacks on inbox checks)

**Verdict:** Complexity proportional to problem scope. No simpler solution available without degrading UX.

---

## 4. Task Dependencies — CORRECT

**Proposed order:**
1. Task 1 (F1): Client extension (SendMessageFull, FetchThread, MessageOptions)
2. Task 2 (F3): negotiate_release tool (depends on Task 1 client methods)
3. Task 3 (F1): respond_to_release tool (depends on Task 1 client methods)
4. Task 4 (F2): Auto-release in pre-edit hook (depends on Task 3 response protocol)
5. Task 5 (F4): Status visibility (depends on Task 1-3 for thread/subject queries)
6. Task 6 (F5): Timeout escalation (depends on Task 1 FetchThread, Task 2 negotiate_release)
7. Task 7: Documentation update

**Dependency graph:**
```
Task 1 (Client)
  ├─→ Task 2 (negotiate_release) ─→ Task 6 (Timeout)
  ├─→ Task 3 (respond_to_release) ─→ Task 4 (Auto-release)
  └─→ Task 5 (Status)
       ↓
Task 7 (Docs)
```

**Validation:**
- ✅ Task 2 requires SendMessageFull (Task 1)
- ✅ Task 2 blocking wait requires FetchThread (Task 1)
- ✅ Task 3 requires SendMessageFull (Task 1)
- ✅ Task 4 auto-release requires respond_to_release protocol (Task 3) — hook needs to send release-ack on correct thread
- ✅ Task 6 timeout requires FetchThread (Task 1) to check for ack messages

**Testing order:**
- Task 1: Go unit tests (client_test.go with httptest)
- Task 2-3: Go unit tests + structural test update (tool count 9→11)
- Task 4: Manual integration test (2 sessions, one requests release while other edits)
- Task 5: Structural test (status.md command validation)
- Task 6: Manual timeout test (send negotiate_release, wait 6 min, check force-release)

**Rollout risk:**
- Tasks 1-3: Low risk (additive, no behavior change for existing tools)
- Task 4: Medium risk (auto-release could fire incorrectly) — mitigated by feature flag
- Task 6: Low risk (lazy enforcement, only fires on existing inbox checks)

**Alternative sequence considered:**
- F1 → F2 → F3 (response before request tool) — rejected because auto-release (F2) needs response protocol (F1) fully defined
- Current F1 → F3 → F2 is correct: define protocol, implement request tool, implement response tool, then auto-release uses both

**Verdict:** Task order is optimal. No reordering needed.

---

## 5. Tool Count Growth — MONITOR BUT NOT YET ACTIONABLE

**Current state:**
- 9 tools in tools.go (408 lines, flat structure)
- All tools use client.Client (injected dependency)
- No sub-packages (internal/tools/ is a single package)

**After this plan:**
- 11 tools (9 + negotiate_release + respond_to_release)
- ~600 lines (408 + 192 new)
- Still flat structure

**Sub-package threshold analysis:**

**Package cohesion:**
- Reservation tools: `reserve_files`, `release_files`, `release_all`, `check_conflicts`, `my_reservations`
- Messaging tools: `send_message`, `fetch_inbox`
- Coordination tools: `request_release`, `negotiate_release`, `respond_to_release`, `list_agents`

**Potential split:**
```go
internal/tools/
  reservation.go  // 5 tools, ~200 lines
  messaging.go    // 2 tools, ~100 lines
  coordination.go // 4 tools, ~300 lines
  tools.go        // RegisterAll only
```

**When to split:**
- **Line count trigger:** 1000+ lines (currently 600, 40% headroom)
- **Tool count trigger:** 15+ tools (currently 11, 27% below threshold)
- **Cohesion trigger:** Tools with no shared client methods (not yet true — all use client.Client)

**Recommendation:** DO NOT split now. Wait until:
- 15+ tools OR
- 1000+ lines OR
- 3rd tool category emerges (e.g., "audit tools", "policy tools")

**Why NOT split now:**
- All tools share client.Client, jsonResult, emitSignal helpers
- RegisterAll is 11 lines (manageable, not a god function)
- No import cycles possible (all tools in same package)
- File navigation: single file easier than 4 files for 11 tools

**Future growth scenarios:**
- Add `list_negotiations`, `cancel_negotiation`, `negotiate_timeout_override` → 14 tools (still under threshold)
- Add audit tools (`list_reservations_all`, `audit_conflicts`, `reservation_history`) → 17 tools (SPLIT RECOMMENDED)

---

## 6. Critical Fixes Required

### Fix 1: Move Pattern Overlap Logic to Client (Task 3)

**Current plan (Task 3):**
```go
// tools.go:respondToRelease
reservations, _ := c.ListReservations(ctx, ...)
for _, r := range reservations {
    if r.IsActive && patternsOverlap(r.PathPattern, file) {
        c.DeleteReservation(ctx, r.ID)
    }
}
```

**Problem:** `patternsOverlap` is client logic (already exists in client.go), tools.go shouldn't duplicate it.

**Fix:**
```go
// client.go (Task 1, already in plan for Task 6)
func (c *Client) ReleaseByPattern(ctx context.Context, agentID, pattern string) (int, error)

// tools.go:respondToRelease (Task 3, UPDATED)
count, err := c.ReleaseByPattern(ctx, c.AgentID(), file)
if err != nil {
    return mcp.NewToolResultError(fmt.Sprintf("release: %v", err)), nil
}
```

**Impact:** Task 6 already adds ReleaseByPattern. Move it to Task 1 instead, use in Task 3.

### Fix 2: Move Timeout Logic to Client (Task 6)

**Current plan (Task 6):**
```go
// tools.go:checkNegotiationTimeouts (100+ lines)
func checkNegotiationTimeouts(ctx context.Context, c *client.Client) []map[string]any {
    msgs, _, _ := c.FetchInbox(ctx, "")
    for _, m := range msgs {
        // Parse message body JSON
        // Calculate timeout based on urgency
        // Check thread for ack
        // Force-release via c.ReleaseByPattern
        // Send timeout ack
    }
}
```

**Problem:** Business logic (timeout calculation, thread parsing, orchestration) in tools layer.

**Fix:**
```go
// client.go (Task 6, NEW)
type NegotiationTimeout struct {
    ThreadID    string
    File        string
    Holder      string
    Urgency     string
    AgeMinutes  int
    Released    int // count of reservations released
}

func (c *Client) CheckExpiredNegotiations(ctx context.Context) ([]NegotiationTimeout, error) {
    // Fetch inbox
    // Parse release-request messages
    // Calculate timeouts (5min urgent, 10min normal)
    // Check threads for ack (skip if already resolved)
    // Force-release via ReleaseByPattern
    // Send timeout ack
    return timeouts, nil
}

// tools.go:fetchInbox handler (Task 6, UPDATED)
timeouts, _ := c.CheckExpiredNegotiations(ctx)
if len(timeouts) > 0 {
    result["expired_negotiations"] = timeouts
}
```

**Impact:** tools.go stays at ~450 lines (not 600), client.go owns all thread/negotiation logic.

### Fix 3: Add Fail-Open to Pre-Edit Hook API Calls (Task 4)

**Current plan (Task 4, line 751-771):**
```bash
# Delete reservation
intermute_curl DELETE "/api/reservations/${res_id}" 2>/dev/null || true  # ✅ HAS fail-open

# Send release_ack
intermute_curl POST "/api/messages" ... 2>/dev/null || true  # ✅ HAS fail-open

# Ack original message
intermute_curl POST "/api/messages/${REQ_MSG_ID}/ack" 2>/dev/null || true  # ✅ HAS fail-open
```

**Check:** All calls already have `|| true`. NO FIX NEEDED.

**But:** Missing `--max-time 2` on these calls (only inbox fetch has it).

**Fix:**
```bash
# Add helper to lib.sh
intermute_curl_fast() {
    intermute_curl --max-time 2 "$@"
}

# Replace Task 4 calls:
intermute_curl_fast DELETE "/api/reservations/${res_id}" 2>/dev/null || true
intermute_curl_fast POST "/api/messages" ... 2>/dev/null || true
intermute_curl_fast POST "/api/messages/${REQ_MSG_ID}/ack" 2>/dev/null || true
```

---

## Recommendations Summary

### MUST FIX (before Task 1):
1. **Move ReleaseByPattern to Task 1** (currently in Task 6) so Task 3 can use it
2. **Add CheckExpiredNegotiations to client.go** (Task 6) instead of checkNegotiationTimeouts in tools.go
3. **Add intermute_curl_fast helper** (Task 4) with --max-time 2 for fail-fast on hook API calls

### SHOULD MONITOR:
4. **Tool count growth** — split tools.go at 15 tools or 1000 lines (currently 11/600, safe)
5. **Pre-edit.sh length** — consider lib-negotiation.sh at 300+ lines (currently ~210, acceptable)

### OPTIONAL (future iterations):
6. **Remove INTERLOCK_AUTO_RELEASE flag** after 2-week soak period (make auto-release default)
7. **Add negotiate_timeout_override tool** if users report false-positive force-releases (not in current plan, YAGNI)

### APPROVED AS-IS:
- Client extension pattern (MessageOptions, SendMessageFull, FetchThread) — clean, follows existing conventions
- Hook piggyback strategy — correct reuse of existing infrastructure
- Task dependency order — optimal sequence, no changes needed
- Feature scope — urgency levels, blocking wait, auto-release all justified by concrete use cases

---

## Conclusion

This plan demonstrates **strong architectural discipline**:
- Layers are respected (tools → client → HTTP API)
- Patterns are reused (MessageOptions matches existing option pattern)
- Complexity is justified (negotiation protocol solves real coordination pain)
- YAGNI is applied (no-force flag removed, low urgency removed, bead hierarchy avoided)

**Three boundary violations require fixing** before implementation begins, but these are straightforward refactors (move logic to correct layer). Once fixed, the plan is structurally sound and ready for execution.

**Estimated impact of fixes:**
- Fix 1: 5 lines changed in Task 3 (use c.ReleaseByPattern instead of inline loop)
- Fix 2: Move 120 lines from tools.go to client.go, simplify tools.go to 3-line call
- Fix 3: Add 4-line helper to lib.sh, update 3 intermute_curl calls in pre-edit.sh

**Net result:** Cleaner separation of concerns, easier testing (client methods testable via httptest), and reduced tools.go complexity (450 lines instead of 600).

**Final verdict:** APPROVE with mandatory fixes applied before Task 1 implementation.
