# Quality Review: Interlock Reservation Negotiation Protocol Implementation Plan

**Reviewer:** Flux-drive Quality & Style Reviewer
**Date:** 2026-02-15
**Plan:** `/root/projects/Interverse/docs/plans/2026-02-15-interlock-reservation-negotiation.md`
**Context:** Go 1.24 MCP server, bash hooks, structural Python tests

---

## Executive Summary

**Overall Assessment:** High quality with 3 critical Go issues, 2 bash safety gaps, 1 API design inconsistency, and multiple test coverage gaps. The plan demonstrates strong command of Go idioms and existing patterns but needs fixes before implementation.

**Recommendation:** Fix critical issues (blocking). Suggested enhancements improve production readiness but are non-blocking.

---

## Critical Issues (Must Fix)

### 1. Go Error Handling — Missing Context Wrapping (Task 2, 6)

**Issue:** `negotiateRelease` and `checkNegotiationTimeouts` use `%v` formatting for errors instead of `%w`. This breaks error chain propagation.

**Example (Task 2, line 279):**
```go
if err != nil {
    return mcp.NewToolResultError(fmt.Sprintf("check conflicts: %v", err)), nil
}
```

**Fix:** Use `%w` for all error wrapping in client method calls:
```go
if err != nil {
    return mcp.NewToolResultError(fmt.Sprintf("check conflicts: %w", err)), nil
}
```

**Locations to fix:**
- Task 2: lines 279, 287, 320
- Task 3: lines 559, 581
- Task 6: lines 882-898 (entire `ReleaseByPattern`)

**Impact:** Without `%w`, upstream error context (like HTTP status codes from `IntermuteError`) is lost, breaking debugging.

---

### 2. Go Missing Import and Helper Function (Task 2)

**Issue:** Task 2 Step 4 mentions adding `stringOr` helper but doesn't show the implementation. The existing `tools.go` has `intOr` and `boolOr` but not `stringOr`.

**Fix:** Add this after `boolOr` (around line 379 in tools.go):
```go
func stringOr(v any, def string) string {
    if s, ok := v.(string); ok && s != "" {
        return s
    }
    return def
}
```

**Also add missing import:** Task 2 mentions adding `"time"` but `url` package is also needed for `FetchThread` in Task 1. Update imports to:
```go
import (
    "context"
    "encoding/json"
    "fmt"
    "os/exec"
    "time"
    "net/url"
    // ... rest
)
```

---

### 3. Bash Quoting Violation — Unquoted Variable Expansion (Task 4)

**Issue:** Lines 717, 732, 751 use unquoted variables in loops/case statements, risking word splitting.

**Example (line 717):**
```bash
echo "$RELEASE_REQS" | jq -c '.[]' 2>/dev/null | while IFS= read -r req_msg; do
```

This is safe (within a pipeline), but line 751 is NOT:

```bash
echo "$MY_RES" | jq -r ".reservations[]? | select(.path_pattern == \"$REQ_FILE\" or .is_active == true) | .id"
```

**Problem:** `$REQ_FILE` is injected into a jq query string without escaping. If `$REQ_FILE` contains double quotes or backslashes, the jq query breaks.

**Fix:** Use jq's `--arg` for safe variable injection:
```bash
echo "$MY_RES" | jq -r --arg pattern "$REQ_FILE" \
    '.reservations[]? | select(.path_pattern == $pattern or .is_active == true) | .id'
```

---

### 4. Go API Design Inconsistency — `patternsOverlap` Visibility (Task 3)

**Issue:** Step 1 of Task 3 (line 620) says:
> "Note: `patternsOverlap` is in `client.go` — export it or duplicate the logic."

Looking at `client.go:340-345`, `patternsOverlap` is package-private (lowercase). The plan suggests **duplicating** logic in `tools.go`, which violates DRY and creates drift risk.

**Fix:** Export it in `client.go` by renaming to `PatternsOverlap` (uppercase):
```go
// PatternsOverlap does a simple prefix/glob overlap check.
func PatternsOverlap(existing, candidate string) bool {
    e := strings.TrimSuffix(existing, "*")
    c := strings.TrimSuffix(candidate, "*")
    return strings.HasPrefix(e, c) || strings.HasPrefix(c, e)
}
```

Then update the internal call at line 328 in `client.go`:
```go
if patternsOverlap(r.PathPattern, pattern) {  // lowercase is fine for internal calls
```

And use it in `tools.go` (Task 3):
```go
if r.IsActive && client.PatternsOverlap(r.PathPattern, file) {
```

**Alternative:** If the function is deliberately private (design decision), move it to a shared `internal/util` package. Duplication is the worst option.

---

## High-Priority Issues (Strongly Recommend)

### 5. Bash Missing Circuit Breaker on Critical Path (Task 4)

**Issue:** Line 726 calls `intermute_curl GET "/api/reservations?agent=..."` without a timeout circuit breaker. The existing commit-check block (line 33) uses the default `lib.sh` timeout (`--max-time 5`), but the reservation fetch at line 726 can block for 5 seconds **per edit** if intermute is slow.

**Context:** Line 713 already adds a circuit breaker for the inbox fetch:
```bash
NEG_INBOX=$(intermute_curl GET "/api/messages/inbox?..." 2>/dev/null) || NEG_INBOX=""
```

This uses the existing `--max-time 5` from `lib.sh:26`. But if intermute is hanging (not down, just slow), a 5-second delay per edit is unacceptable UX.

**Fix:** Reduce timeout for reservation fetch or add a short-circuit on first failure:
```bash
MY_RES=$(timeout 2 intermute_curl GET "/api/reservations?agent=${INTERMUTE_AGENT_ID}&project=${PROJECT:-}" 2>/dev/null) || MY_RES=""
if [[ -z "$MY_RES" ]]; then
    # intermute slow/unreachable — skip auto-release this time
    continue  # or exit the negotiation block entirely
fi
```

**Why this matters:** The plan says "2s timeout circuit breaker" in line 16, but the implementation doesn't enforce it for the reservation fetch. The `lib.sh` default is 5s, and the plan's own comment at line 712 says `--max-time 2` but doesn't show it in the actual curl call.

---

### 6. Go Missing Nil Check — Thread Fetch Can Panic (Task 2, 6)

**Issue:** `negotiateRelease` blocking mode (line 338) and `checkNegotiationTimeouts` (line 948) call `FetchThread` but don't handle nil messages slice. The existing pattern in `tools.go` (line 260) shows nil-guarding:
```go
if messages == nil {
    messages = make([]client.Message, 0)
}
```

**Example (Task 2, line 338):**
```go
msgs, err := c.FetchThread(ctx, threadID)
if err == nil {
    for _, m := range msgs {  // PANIC if msgs == nil
```

**Fix:** Add nil guard after fetch:
```go
msgs, err := c.FetchThread(ctx, threadID)
if err == nil && msgs != nil {
    for _, m := range msgs {
```

**Or:** Update `FetchThread` in Task 1 (client.go) to never return nil:
```go
func (c *Client) FetchThread(ctx context.Context, threadID string) ([]Message, error) {
    // ... existing code ...
    if result.Messages == nil {
        result.Messages = make([]Message, 0)
    }
    return result.Messages, nil
}
```

The second option is better (fail-safe at the source).

---

### 7. Test Coverage Gaps — Missing Edge Cases

**a) Task 1 — No timeout test for `FetchThread`**

The test at line 90-113 only validates happy path. Missing:
- Empty messages array
- Network timeout
- 404 (thread not found)

**Fix:** Add to `client_test.go`:
```go
func TestFetchThread_NotFound(t *testing.T) {
    srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        w.WriteHeader(404)
    }))
    defer srv.Close()
    c := NewClient(WithBaseURL(srv.URL))
    _, err := c.FetchThread(context.Background(), "missing")
    if err == nil {
        t.Fatal("expected error for 404, got nil")
    }
}
```

**b) Task 2 — No test for blocking wait timeout**

The plan has no test for `wait_seconds` > 0. Add a structural test or Go unit test:
```python
# In test_structure.py
def test_negotiate_release_has_wait_param(self, project_root):
    content = (project_root / "internal" / "tools" / "tools.go").read_text()
    assert 'wait_seconds' in content
    assert 'time.Sleep(pollInterval)' in content
```

**c) Task 4 — No test for auto-release**

Manual testing (Task 4 Step 3) is insufficient. The structural tests don't cover:
- Auto-release logic presence
- Feature flag check (`INTERLOCK_AUTO_RELEASE`)
- Throttle flag usage

**Fix:** Add to `test_structure.py`:
```python
def test_pre_edit_has_auto_release(self, project_root):
    content = (project_root / "hooks" / "pre-edit.sh").read_text()
    assert "INTERLOCK_AUTO_RELEASE" in content
    assert "release-request" in content
    assert "release-ack" in content
```

**d) Task 6 — No test for force-release idempotency**

The plan claims "idempotent" at line 875 but provides no test. Add:
```go
func TestReleaseByPattern_Idempotent(t *testing.T) {
    // ... setup mock server with empty reservations list ...
    c := NewClient(...)
    count, err := c.ReleaseByPattern(ctx, "agent1", "*.go")
    if err != nil { t.Fatal(err) }
    if count != 0 { t.Errorf("expected 0 releases, got %d", count) }
}
```

---

## Medium-Priority Issues (Consider Fixing)

### 8. Go Naming — `intOr` vs Idiomatic `getIntOr`

The existing helpers `intOr`, `boolOr`, `stringOr` are terse but not idiomatic Go. Standard library uses `GetXOrDefault` pattern (e.g., `http.Request.FormValue`). Consider renaming for consistency with existing codebase conventions, but only if the project has no established preference for short helpers.

**Current pattern check:** The existing code uses `intOr` (line 56, 364), so this is a project convention. **No change needed.**

---

### 9. Bash Missing Strict Mode Validation (Task 4)

The added code block (lines 706-785) is **inside an if block**, so `set -euo pipefail` (line 4) applies, but there's a subtle risk: if any command in the jq pipeline fails, the while loop silently continues.

**Example (line 730):**
```bash
echo "$RELEASE_REQS" | jq -c '.[]' 2>/dev/null | while IFS= read -r req_msg; do
```

If `jq` fails (e.g., due to invalid JSON), the loop just doesn't run. This is **intended behavior** (fail-open), but the plan should document it.

**Fix:** Add a comment:
```bash
# Fail-open: if jq fails (malformed JSON), skip auto-release
echo "$RELEASE_REQS" | jq -c '.[]' 2>/dev/null | while IFS= read -r req_msg; do
```

---

### 10. Go Magic Numbers — Timeout Constants Should Be Named (Task 2, 6)

**Example (Task 2, line 336):**
```go
pollInterval := 2 * time.Second
```

**Example (Task 6, line 935):**
```go
timeoutMinutes := 10 // normal
if urgency == "urgent" {
    timeoutMinutes = 5
}
```

**Fix:** Extract to package-level constants at top of `tools.go`:
```go
const (
    normalTimeoutMinutes = 10
    urgentTimeoutMinutes = 5
    negotiationPollInterval = 2 * time.Second
)
```

This also makes Task 6 clearer:
```go
timeoutMinutes := normalTimeoutMinutes
if urgency == "urgent" {
    timeoutMinutes = urgentTimeoutMinutes
}
```

---

### 11. Bash DRY Violation — Duplicate Message Ack Logic (Task 4)

Lines 52 and 771 both ack messages using the same pattern:
```bash
[[ -n "$msg_id" ]] && intermute_curl POST "/api/messages/${msg_id}/ack" 2>/dev/null || true
```

**Fix:** Extract to `lib.sh`:
```bash
# ack_message marks a message as read (best-effort, never fails)
ack_message() {
    local msg_id="${1:-}"
    [[ -n "$msg_id" ]] && intermute_curl POST "/api/messages/${msg_id}/ack" 2>/dev/null || true
}
```

Then use:
```bash
ack_message "$REQ_MSG_ID"
```

---

### 12. Go Thread ID Collision Risk (Task 2)

Line 294 generates thread IDs:
```go
threadID := fmt.Sprintf("negotiate-%s-%d", file, time.Now().UnixMilli())
```

**Problem:** If the same agent requests the same file twice within the same millisecond (unlikely but possible in tests), the thread IDs collide.

**Fix:** Add agent ID to make it unique:
```go
threadID := fmt.Sprintf("negotiate-%s-%s-%d", c.AgentID(), file, time.Now().UnixMilli())
```

**Or:** Use UUID (requires `github.com/google/uuid` import):
```go
threadID := fmt.Sprintf("negotiate-%s", uuid.New().String())
```

The first option (add agent ID) is simpler and avoids a new dependency.

---

## Low-Priority / Nitpicks

### 13. Go Inconsistent Comment Style

Task 3 (line 552) uses multi-line comment:
```go
// Release the reservation first
reservations, err := c.ListReservations(...)
```

Existing code (line 127, 137) uses single-line comments. Adopt existing style.

---

### 14. Bash Redundant Empty Check (Task 4)

Line 721:
```bash
if [[ -n "$RELEASE_REQS" && "$RELEASE_REQS" != "null" ]]; then
```

The `jq` output at line 717 uses `| if length > 0 then . else empty end`, which already prevents `null`. The `!= "null"` check is redundant.

**Fix:** Simplify to:
```bash
if [[ -n "$RELEASE_REQS" ]]; then
```

---

### 15. Go Missing Godoc Comments

The plan adds 3 new exported client methods but only `ReleaseByPattern` (Task 6, line 879) has a godoc. `SendMessageFull` and `FetchThread` (Task 1) are missing.

**Fix:** Add to Task 1:
```go
// SendMessageFull sends a message with full Intermute protocol support:
// threading, subject classification, importance levels, and ack tracking.
func (c *Client) SendMessageFull(...)

// FetchThread retrieves all messages in a conversation thread.
func (c *Client) FetchThread(...)
```

---

## Consistency with Existing Patterns

✅ **Good:**
- Uses existing `jsonResult` helper (Task 2, 3)
- Follows `doJSON` error handling pattern (Task 1)
- Matches existing test structure (pytest for structural, Go for unit)
- Uses existing `emitSignal` pattern (Task 3, line 582)
- Follows bash `intermute_curl` wrapper pattern (Task 4)

⚠️ **Inconsistent:**
- `Message` struct field naming (Task 1, lines 139-150): uses both `ID` and `MessageID` for the same field. The existing struct (client.go:108) only has `ID`. The new fields (`ThreadID`, `Subject`, etc.) should match existing `json:` tag style.

**Fix:** In Task 1, update the struct to:
```go
type Message struct {
    ID          string   `json:"id,omitempty"`
    MessageID   string   `json:"message_id,omitempty"` // API sometimes uses this alias
    From        string   `json:"from"`
    To          []string `json:"to,omitempty"`
    Body        string   `json:"body"`
    ThreadID    string   `json:"thread_id,omitempty"`
    Subject     string   `json:"subject,omitempty"`
    Importance  string   `json:"importance,omitempty"`
    AckRequired bool     `json:"ack_required,omitempty"`
    Timestamp   string   `json:"timestamp,omitempty"`
    CreatedAt   string   `json:"created_at,omitempty"`  // <-- CRITICAL: Task 6 uses this at line 927
    Read        bool     `json:"read,omitempty"`
}
```

The existing struct at client.go:106-113 doesn't have `CreatedAt`, but Task 6 (line 927) uses `m.CreatedAt`. **Add this field in Task 1 or Task 6 will fail.**

---

## Language-Specific Deep Dive

### Go (Tasks 1, 2, 3, 6)

**Error Handling:** ✅ Generally good (uses typed errors, checks nil), ❌ Missing `%w` (critical issue #1)

**Naming:** ✅ Follows 5-second rule for exported symbols (`NegotiateRelease`, `RespondToRelease`), ✅ Uses Go conventions (camelCase, exported = uppercase)

**Interface usage:** ✅ Accepts `context.Context` universally, ✅ Returns concrete types (no over-abstraction)

**Imports:** ⚠️ Task 1 adds `url` but Task 2 also needs it — clarify in Task 1 Step 4

**Testing:** ❌ Missing edge cases (issue #7)

**Complexity budget:** ✅ No unnecessary abstractions, ✅ Functions are single-purpose

**Dependency discipline:** ✅ No new dependencies (uses existing `mcp-go`, stdlib)

---

### Bash (Task 4)

**Strict mode:** ✅ Uses `set -euo pipefail` (line 4)

**Quoting:** ❌ Critical issue #3 (jq injection risk)

**Error handling:** ✅ Fail-open pattern (`|| true`, `2>/dev/null`) is appropriate for hooks

**Portability:** ✅ Bash-specific (shebang is `#!/usr/bin/env bash`), no POSIX requirements

**Cleanup:** N/A (no temp files, locks, or background jobs in this task)

**Injection risk:** ❌ Line 751 jq query injection (issue #3)

---

### Python (Test Updates)

**Test structure:** ✅ Follows existing pytest conventions

**Assertions:** ✅ Clear failure messages

**Coverage:** ❌ Missing structural tests for new features (issue #7c)

---

## Test Strategy Analysis

**Planned coverage:**
- Unit tests: Task 1 (client methods), implied for Tasks 2-3 (MCP tools)
- Structural tests: Updated counts in Tasks 2, 3
- Manual tests: Task 4 (auto-release), Task 5 (status output)

**Gaps:**
1. No integration test for full negotiation round-trip (request → auto-release → ack received)
2. No concurrency test (two agents negotiate same file simultaneously)
3. No test for timeout escalation (Task 6) — only checked in `fetch_inbox`, no proof it works
4. No test for blocking wait actual behavior (does it retry? how often?)

**Recommendation:** Add integration test script in `tests/integration/` that:
1. Starts two mock agents
2. Agent A reserves file X
3. Agent B calls `negotiate_release(wait_seconds=10)`
4. Agent A receives request, sends `release-ack`
5. Agent B's blocking call returns `status: released` in <5s

---

## API Design Review

### New MCP Tools

**`negotiate_release`:**
- ✅ Parameter names consistent with existing tools (`agent_name`, `file`, `reason`)
- ✅ Return format matches existing tools (JSON with `status`, `thread_id`)
- ⚠️ `wait_seconds` is a number, but existing tools use `ttl_minutes` (also number) — consistent
- ✅ Validates inputs before API calls

**`respond_to_release`:**
- ✅ Action-oriented naming (`action: "release" | "defer"`)
- ✅ Return format includes `action` field for clarity
- ⚠️ `eta_minutes` capped at 60 but no error returned when capped — should warn user
- ✅ Deletes reservation before sending ack (correct order)

**New Client Methods:**

**`SendMessageFull`:**
- ✅ Naming follows "Full" suffix pattern for extended versions
- ✅ `MessageOptions` struct is clean (all optional fields)
- ⚠️ No validation on `importance` values — should accept enum? Existing code doesn't validate either, so consistent.

**`FetchThread`:**
- ✅ Returns `[]Message`, nil instead of `([]Message, error)` with non-nil empty slice — wait, it returns `([]Message, error)`. Should match existing pattern (nil guard in caller or at source). See issue #6.

**`ReleaseByPattern`:**
- ✅ Returns count for visibility
- ✅ Idempotent (returns 0 if nothing to release)
- ❌ Doesn't return list of released IDs — count is less useful for debugging. Consider `([]string, error)` instead of `(int, error)`.

**Fix for `ReleaseByPattern`:**
```go
func (c *Client) ReleaseByPattern(ctx context.Context, agentID, pattern string) ([]string, error) {
    // ... existing logic ...
    var released []string
    for _, r := range reservations {
        if r.IsActive && client.PatternsOverlap(r.PathPattern, pattern) {
            if err := c.DeleteReservation(ctx, r.ID); err == nil {
                released = append(released, r.ID)
            }
        }
    }
    return released, nil
}
```

Then in `checkNegotiationTimeouts` (Task 6, line 975):
```go
released, _ := c.ReleaseByPattern(ctx, holder, file)
// Include released IDs in result
results = append(results, map[string]any{
    "file":           file,
    "holder":         holder,
    "released_count": len(released),
    "released_ids":   released,
    // ...
})
```

---

## Structural Concerns

### Layering

✅ Tools layer cleanly over client methods
✅ Client methods wrap HTTP API directly (no extra abstraction)
✅ Hooks use scripts (not Go) for bash-native tasks

### Coupling

⚠️ `tools.go` duplicates `patternsOverlap` logic from `client.go` (issue #4)
✅ Otherwise, dependencies flow one direction (tools → client → HTTP)

---

## Suggested Task Ordering Improvements

The plan orders tasks as: 1 (client) → 2 (negotiate) → 3 (respond) → 4 (auto-release) → 5 (status) → 6 (timeout).

**Issue:** Task 4 (bash hook) is tested manually, but the Go tools (Tasks 2-3) it depends on aren't integration-tested. If the Go tools have bugs, manual testing of Task 4 will fail for the wrong reasons.

**Recommendation:** Add an integration checkpoint:
- **Task 3.5:** Integration test — run `negotiate_release` + `respond_to_release` in two real sessions against a local intermute instance. Verify thread messages appear correctly.
- Then proceed to Task 4 (hook integration).

---

## Missing Documentation

The plan updates docs in Task 7 but misses:

1. **Error handling guide** for agents using `negotiate_release` — what does `status: timeout` mean? Can they retry?
2. **Auto-release behavior** — when exactly does it trigger? (Answer: on next edit by the holder, if file is clean)
3. **Urgency level semantics** — what's the user-facing difference between normal and urgent besides timeout?

**Fix:** Add to Task 7 Step 3 (AGENTS.md update):
```markdown
### Negotiation Protocol

**Requesting a release:**
```
negotiate_release(agent_name="alice", file="main.go", urgency="urgent", wait_seconds=30)
```

Returns:
- `status: released` — file is yours, proceed
- `status: deferred` — holder needs more time, check `eta_minutes`
- `status: timeout` — no response after urgency timeout (5m urgent, 10m normal), reservation force-released
- `status: pending` — request sent, check `fetch_inbox` later (if `wait_seconds=0`)

**Auto-release behavior:**
If `INTERLOCK_AUTO_RELEASE=1`, the holder's next edit attempt triggers an inbox check. If your request is found and the file has no uncommitted changes, the reservation is released and you receive a `release-ack` message.

**Urgency levels:**
- `normal`: 10-minute timeout, polite request
- `urgent`: 5-minute timeout, `ack_required=true` (higher visibility in inbox)
```

---

## Final Checklist Before Implementation

- [ ] Fix critical issue #1 (error wrapping)
- [ ] Fix critical issue #2 (missing helper + imports)
- [ ] Fix critical issue #3 (bash jq injection)
- [ ] Fix critical issue #4 (`patternsOverlap` export)
- [ ] Add `CreatedAt` field to `Message` struct (Task 1)
- [ ] Add nil guard to `FetchThread` or callsites (issue #6)
- [ ] Add timeout circuit breaker to reservation fetch (issue #5)
- [ ] Add edge case tests (issue #7)
- [ ] Extract timeout constants (issue #10)
- [ ] Add thread ID uniqueness (issue #12)
- [ ] Update structural tests to expect 11 tools
- [ ] Add integration test checkpoint (Task 3.5)

---

## Summary of Key Risks

| Risk | Impact | Mitigation |
|------|--------|------------|
| jq injection in auto-release (issue #3) | Data corruption, hook failure | Use `--arg` for safe variable passing |
| Missing `%w` error wrapping (issue #1) | Lost debugging context | Add `%w` to all error fmt.Sprintf calls |
| `patternsOverlap` duplication (issue #4) | Logic drift between client/tools | Export from client.go, reuse in tools |
| No integration test (issue #7 + task ordering) | Broken protocol undetected until prod | Add Task 3.5 integration checkpoint |
| Timeout not enforced (issue #5) | UX degradation on slow intermute | Add explicit 2s timeout to reservation fetch |

---

## Conclusion

The plan is **production-ready after critical fixes**. The Go code demonstrates solid understanding of idiomatic patterns, error handling, and the existing codebase. Bash code follows interlock's fail-open philosophy but needs quoting fixes. Test coverage is adequate for structural validation but needs edge case and integration tests for production confidence.

**Estimated fix effort:** 2-3 hours (critical issues) + 4-5 hours (high-priority tests and integration checkpoint).

**Risk level after fixes:** Low (protocol is well-architected, layered correctly, and degrades gracefully on failure).
