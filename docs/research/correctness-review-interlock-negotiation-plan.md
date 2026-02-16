# Correctness Review: Interlock Reservation Negotiation Protocol

**Reviewer:** Julik (Flux-Drive Correctness)
**Plan:** `/root/projects/Interverse/docs/plans/2026-02-15-interlock-reservation-negotiation.md`
**Date:** 2026-02-16
**Severity Scale:** Critical (data corruption/silent failure), High (lost updates/race-induced bugs), Medium (resource leak/stall), Low (inefficiency)

---

## Executive Summary

**Four high-severity correctness failures identified:**

1. **Double-release race in timeout enforcement** — Multiple concurrent timeout checkers send duplicate ack messages
2. **Message ordering assumption unverified** — Intermute may not guarantee read-after-write consistency
3. **Goroutine lifecycle leak** — Background timeout checker has no shutdown path
4. **Idempotency violation in force-release** — 404 errors treated as failures instead of success

**Plan correctness: 6/10** | **Production readiness: Not ready**

All four must be fixed before v1 launch. Amendment A3 correctly eliminates TOCTOU race but introduces liveness failure mode.

---

## C1: Timeout Checker Double-Release Race (High Severity)

**Location:** `tools.go:379-392`, `client.go:368-481`

**Race Narrative:**
```
T0: Agent A holds reservation R for file.go
T1: Agent B sends urgent release-request (5min timeout)
T6min: B's fetch_inbox lazy check → finds expired → releases R → sends ack #1
T6min+10ms: B's background goroutine → finds SAME expired → releases (noop) → sends ack #2
T6min+20ms: Second B session goroutine → sends ack #3

Result: A receives 3 duplicate release-ack messages. No data corruption but violates message invariants.
```

**Root Cause:**
- `CheckExpiredNegotiations` has no deduplication
- Background goroutine (30s ticker) + lazy check (fetch_inbox) + multi-session overlaps
- Ack sent unconditionally even when `released=0`

**Fix:** Skip ack if `released=0`:
```go
released, err := c.ReleaseByPattern(ctx, c.agentID, file)
if err != nil {
    return nil, fmt.Errorf("force release: %w", err)
}
// Only send ack if we actually released something
if released > 0 {
    ackBody, _ := json.Marshal(...)
    c.SendMessageFull(ctx, msg.From, string(ackBody), opts)
}
```

---

## C2: Message Ordering Assumption Unverified (High Severity)

**Location:** Entire protocol
**Assumption:** SendMessageFull → immediate visibility in FetchThread

**Failure Scenario:**
```
T0: Agent A calls respond_to_release → SendMessageFull(release-ack)
T0.1: Intermute writes to primary DB
T0.2: Agent B's FetchThread hits read replica (replication lag 100ms)
T0.2: Returns stale thread (no ack visible yet)
T2: B polls again → NOW sees ack (saved by A2 final check)

BUT: If lag > wait_seconds, B times out despite A releasing on time
```

**Plan Evidence:**
- `client.go:257` sends POST, waits for 200
- `client.go:298` sends separate GET on different connection
- No causal ordering token, session affinity, or sequence numbers

**Amendment A2 Mitigation:** Final check after deadline catches network delays but NOT replication lag > timeout window.

**Must Verify:**
1. Does Intermute guarantee read-your-own-writes for same HTTP client?
2. Single DB or replicated?
3. Can we add sequence numbers or server-side blocking poll?

**Integration Test Required:** Write message → immediate read → assert visibility

---

## H1: Background Goroutine Leak (High Severity)

**Location:** `tools.go:379-392`
**Amendment:** A5 adds `StopTimeoutChecker` but NO CALLER

**Leak Path:**
```go
timeoutCheckerOnce.Do(func() {
    timeoutCheckerStop = make(chan struct{})
    go func() {
        ticker := time.NewTicker(30 * time.Second)
        defer ticker.Stop()
        for {
            select {
            case <-ticker.C:
                c.CheckExpiredNegotiations(context.Background())
            case <-timeoutCheckerStop:
                return  // NEVER CALLED
            }
        }
    }()
})
```

**Leak Trigger:** Session ends → MCP server process survives → goroutine orphaned

**Impact:**
- 100 sessions/day = 100 leaked goroutines
- Each goroutine calls HTTP every 30s (may panic if client closed)
- Memory leak (2-8KB per goroutine)

**Fix Options:**
1. **Recommended:** Drop background goroutine entirely, rely on lazy enforcement in fetch_inbox
2. Add MCP shutdown hook: `server.OnShutdown(StopTimeoutChecker)`
3. Move timeout enforcement to Intermute service (centralized)

---

## H2: Idempotency Violation in ReleaseByPattern (Medium Severity)

**Location:** `client.go:344-364`

**Current Code:**
```go
if err := c.DeleteReservation(ctx, r.ID); err != nil {
    return released, fmt.Errorf("delete reservation %q: %w", r.ID, err)  // BUG
}
released++
```

**Race:**
```
Goroutine A: Lists [R1, R2] → Deletes R1 → success
Goroutine B: Lists [R1, R2] → Deletes R1 → 404 → ERROR (aborts, R2 never released)
```

**Fix:** Treat 404 as success:
```go
if err := c.DeleteReservation(ctx, r.ID); err != nil {
    if !isNotFound(err) {
        return released, fmt.Errorf("delete reservation %q: %w", r.ID, err)
    }
    // 404 = already deleted, continue
}
released++
```

---

## Amendment A3 Analysis: Advisory vs Auto-Release

**Plan:** Task 4 switches to advisory-only mode (eliminates TOCTOU race)

**Trade-off:**
- **Before A3:** Hook auto-releases → race between `git diff` check and delete
- **After A3:** Hook emits advisory → agent must manually call `respond_to_release`

**New Failure Mode:**
```
T0: Requester sends release-request
T5: Holder's pre-edit hook emits advisory
T6-60: Requester polls, holder IGNORES advisory (context-exhausted)
T60: Requester timeout → "holder unresponsive"
Result: File stays reserved despite holder being willing to release
```

**Recommendation:** Support both modes:
- **Default:** Advisory (safe, no races)
- **Optional:** `INTERLOCK_AUTO_RELEASE_STRICT=1` with repo-wide dirty check + lock file

---

## Priority Fix List

### P0: Blockers for v1
1. **C1:** Add `if released > 0` check before sending ack
2. **C2:** Verify Intermute ordering guarantees + add integration test
3. **H1:** Remove background goroutine OR add shutdown hook
4. **H2:** Treat 404 as success in ReleaseByPattern

### P1: Phase 2
5. **C4 (Pagination):** Add inbox pagination loop in pre-edit hook
6. **M2 (Observability):** Emit warning on circuit breaker timeout

---

## Final Verdict

**Blocking issues:** 4 (all fixable, low complexity)
**After fixes:** 8/10 — safe for controlled rollout with monitoring
**Rollout strategy:** Deploy with advisory mode, enable auto-release after 2 weeks stable operation

**Test Coverage Required:**
- Round-trip negotiation (A reserves → B requests → A responds → B receives)
- Timeout enforcement (verify 5min/10min windows)
- Concurrent timeout checkers (assert single ack)
- ReleaseByPattern idempotency (mock 404 on second delete)

**File:** `/root/projects/Interverse/docs/research/correctness-review-interlock-negotiation-plan.md`
