# Safety Review: Interlock Reservation Negotiation Protocol

**Plan:** `docs/plans/2026-02-15-interlock-reservation-negotiation.md`
**Reviewer:** Flux-drive Safety Review
**Date:** 2026-02-16
**Context:** Local-only multi-agent coordination system on single developer workstation

## Threat Model

**System Architecture:**
- **Deployment:** Local development environment, single machine, no network exposure beyond Tailscale
- **Trust boundary:** Local user (root) vs. multiple Claude Code agent sessions (same UID via claude-user)
- **Untrusted inputs:** None — all agents are authorized sessions launched by the same human operator
- **Attack surface:** Malicious/buggy agent sessions within the same project (accidental or emergent behavior)
- **Credentials:** Intermute HTTP API on loopback/Unix socket (127.0.0.1:7338 or socket), no authentication layer
- **Data sensitivity:** Source code, git state, reservation metadata (all local, non-secret)

**Risk Classification:** **Medium** — auth flow and permission model updates with potential for agent conflict escalation, but no reversible data corruption (git-backed) and no credential/secret exposure.

## Security Findings

### SAFE: Trust Boundary Analysis

**Finding:** All agents run as the same user (claude-user) with shared filesystem access and no authentication to Intermute. This is **intentional and acceptable** for the local-only threat model.

**Rationale:**
- The system is designed for single-developer use on a trusted workstation
- Agent sessions are all launched by the same human operator
- Filesystem permissions (ACLs) already grant all agents RW access to project files
- Intermute API has no auth layer because all clients are trusted sessions from the same user

**No action required.** Flagging agent spoofing or force-release as "attacks" misunderstands the threat model — there is no adversarial agent in this context. All agents are cooperative, and conflicts arise from race conditions or logical errors, not malice.

---

### SAFE: Thread ID Predictability

**User concern:** "If thread IDs are predictable, can an agent inject fake ack/defer messages?"

**Finding:** Already mitigated by Amendment A1 (UUID-based thread IDs). Even with predictable IDs, **no exploitable risk** in this threat model.

**Rationale:**
- Current implementation (Amendment A1): `crypto/rand` UUID with fallback to `time.Now().UnixNano()` + PID + counter
- Collision risk: negligible (16 bytes of entropy from crypto/rand)
- Even if an agent guesses a thread ID, they can only send messages **to themselves or other agents**, which is already permitted behavior
- Message integrity: JSON deserialization in Go/bash is not a privilege escalation vector (no code execution)
- The system has no concept of "unauthorized message injection" — agents are **allowed** to communicate freely

**Verification:**
- `tools.go:710-717` uses `crypto/rand.Read` for 16 bytes, formats as UUID-style hex
- Fallback is atomic counter + nanosecond timestamp + PID (sufficient entropy for local process isolation)

**No action required.** Thread ID generation is sound. User concern reflects a non-existent threat model (adversarial agents).

---

### MEDIUM: Bash Injection in Pre-Edit Hook (Task 4) — MITIGATED BY PLAN

**User concern:** "jq variable injection, shell expansion in pattern matching"

**Finding:** Plan already includes Amendment A8 (bash safety) with `jq --arg` for variable injection and `intermute_curl_fast` wrapper. **Current implementation (pre-edit.sh:66-107) already follows safe patterns.**

**Analysis:**
- **jq variable injection:** All user-controlled variables passed via `jq --arg` (line 102: `jq -nc --arg ctx "INTERLOCK: ${ADVISORY}" '{"additionalContext": $ctx}'`)
- **Shell expansion in file pattern matching:** Pattern matching uses bash `case` with glob patterns, which is safe for trusted input (agent-provided filenames from git-tracked files)
- **API call timeouts:** `intermute_curl_fast` uses `--max-time 2` (circuit breaker, fail-open on timeout)

**Verification of current code (pre-edit.sh):**
- Line 88: `REQ_FILE=$(echo "$REQ_BODY" | jq -r 'try fromjson | .file // .pattern // empty')` — safe (jq output)
- Line 95: `ADVISORY="${ADVISORY}${REQ_FROM} requests release of ${REQ_FILE}"` — bash string concatenation, NOT passed to shell eval
- Line 97: `Use respond_to_release(thread_id='${REQ_THREAD}'` — bash string interpolation in advisory text, never executed
- Line 102: Uses `jq -nc --arg ctx` for final JSON emission — **safe, no injection risk**

**Residual risk:** Bash case-match on `$REL_PATH` (line 113) in the conflict-check section (not shown in negotiation code). If an agent can create a file with a name containing shell metacharacters (e.g., `$(whoami).go`), the `case` pattern could execute code.

**Mitigation verification:**
- `$REL_PATH` comes from Claude Code's Edit tool input, validated by `git rev-parse --show-toplevel`
- Git does not allow filenames with newlines or most shell metacharacters in standard configurations
- Bash `case` with glob patterns does NOT execute commands in the match string (unlike `eval` or `[ ]` with `==`)

**No action required.** Amendment A8's guidance is already followed. The residual risk (malicious filename creation) is blocked by git filename validation and bash `case` semantics.

---

### CRITICAL: Force-Release Without Consent (Task 6) — INCOMPLETE MITIGATION

**User concern:** "Timeout mechanism auto-deletes reservations — can a malicious agent exploit this?"

**Finding:** Amendment A3 changed auto-release in Task 4 to **advisory-only**, but Task 6 (timeout force-release) still **deletes reservations without consent**. This creates an exploitable DOS vector.

**Attack scenario (non-malicious but realistic):**
1. Agent A reserves `src/router.go` for refactoring (estimated 20 min work)
2. Agent B requests release with `urgency=urgent` (5 min timeout)
3. Agent A does not poll inbox within 5 minutes (working offline, context-heavy task)
4. Agent B's next `fetch_inbox` call triggers `checkNegotiationTimeouts`, force-releases A's reservation
5. Agent A's next edit attempt auto-re-reserves the file (pre-edit hook), **but Agent A lost their manual reservation reason and may not realize the reservation was yanked**

**Impact:**
- **Correctness risk:** Agent A may assume they still have exclusive access after a manual `reserve_files` call, leading to edit conflicts
- **Operational disruption:** Urgent requests can force-release long-running work without explicit consent
- **No data loss:** Git-backed, reversible via merge conflict resolution

**Root cause:** The timeout enforcement conflates two use cases:
1. **Abandoned reservations** (agent crashed, network loss) — timeout is appropriate
2. **Active work in progress** (agent busy, hasn't polled inbox) — timeout violates agent intent

**Mitigation options:**

**Option 1 (Safe, aligns with Amendment A3): Advisory timeout escalation**
- `checkNegotiationTimeouts` does NOT delete reservations
- Instead, returns a result flag: `{status: "timeout-eligible", file: "...", holder: "..."}`
- Requester agent can then:
  - Call `respond_to_release` manually (requires agent decision)
  - Or call a new tool `force_release_by_pattern(agent, pattern, reason)` that emits a high-signal warning
- Pre-edit hook can inject `additionalContext` for timeout-eligible negotiations: "INTERLOCK: Your reservation for X is past urgent timeout (requested by Y). Release via respond_to_release or continue work."

**Option 2 (Current plan, acceptable for low-risk local dev):**
- Keep force-release as-is, but add safeguards:
  - Check holder's last-active timestamp (via Intermute agent heartbeat) — only force-release if agent inactive >2x timeout
  - Emit high-signal notification to holder's inbox: "INTERLOCK FORCE-RELEASE: $file was yanked due to $urgency timeout from $requester"
  - Require force-release audit log (append to project `.interlock/force-release.log`)

**Option 3 (Hybrid): Tiered escalation**
- At timeout: send a **second** message to holder with `importance=urgent`, subject `release-escalation`
- At 1.5x timeout: emit advisory context on holder's next edit (pre-edit hook injection)
- At 2x timeout: force-release with audit log

**Recommendation:** **Option 1** (advisory-only) aligns with Amendment A3's philosophy and eliminates the trust/consent concern. Agents remain in control of their reservations; the timeout is a **signal**, not **enforcement**.

If the plan keeps Option 2 (force-release), add these mandatory safeguards:
1. Holder notification (high-importance message to inbox)
2. Audit log (`.interlock/force-release.log` with timestamp, requester, holder, file, reason)
3. Holder's next edit attempt gets `additionalContext` warning about past force-release

**Action required:** Revise Task 6 to implement Option 1 (advisory) OR add safeguards for Option 2.

---

### LOW: Message Body Parsing (JSON from Untrusted Agents)

**User concern:** "JSON from untrusted agent messages deserialized in both Go and bash"

**Finding:** Deserialization is safe. **No code execution risk** from malformed JSON in this implementation.

**Analysis:**
- **Go:** `json.Unmarshal` into `map[string]any` (tools.go:729) — safe, no `interface{}` type assertion exploits in Go
- **Bash:** `jq 'try fromjson'` (pre-edit.sh:79, 88) — safe, `try` catches malformed JSON and returns `null`
- **Type coercion:** `stringOr`, `intOr` helpers use type switches (tools.go:701-706) — safe, returns default on type mismatch

**Potential edge cases:**
- **Large JSON payload:** Could cause memory exhaustion if an agent sends a multi-MB message body
  - Mitigated by: Intermute API likely has request size limits (not verified in plan)
  - Residual risk: Local DOS (agent runs out of memory), not a security issue
- **Null/undefined confusion:** `jq -r 'try fromjson | .file // .pattern // empty'` correctly handles missing keys
- **Shell injection via jq output:** Already covered in Bash Injection finding — all jq outputs are safely interpolated

**No action required.** Deserialization is robust. If memory exhaustion is a concern, add a client-side message size limit (e.g., reject bodies >100KB).

---

### SAFE: Feature Flag (INTERLOCK_AUTO_RELEASE) Environment Variable

**User concern:** "Can it be set/unset by other agents?"

**Finding:** Each agent session has independent environment variables. **No cross-session manipulation risk.**

**Rationale:**
- Claude Code sessions run as separate processes with isolated environments
- `INTERLOCK_AUTO_RELEASE=1` is set per-session via user shell config or session launch flags
- Agents cannot modify each other's environment (no shared env via Intermute API)
- The flag only affects **advisory context injection** (Amendment A3), not enforcement

**Verification:**
- Pre-edit hook reads `${INTERLOCK_AUTO_RELEASE:-0}` (bash default substitution)
- Hook runs in subprocess spawned by Claude Code with inherited env from session
- No Intermute API endpoint for setting other agents' environment variables

**No action required.** Standard OS process isolation applies.

---

### LOW: API Calls Without Authentication Context

**User concern:** "intermute_curl in hooks lacks authentication"

**Finding:** This is **by design**. Intermute has no authentication layer for local-only deployment.

**Rationale:**
- Intermute binds to `127.0.0.1:7338` or Unix socket (local-only)
- All agents run as `claude-user` with RW access to Intermute socket/port
- Adding authentication would require:
  - Secret generation/distribution (where to store? filesystem → same ACL risk)
  - Session identity verification (already implicit via agent_id)
  - No security benefit in single-user threat model

**If authentication were added (future hardening):**
- Use session-scoped JWT tokens issued by Intermute on agent join
- Store in `~/.config/clavain/intermute-session-$SESSION_ID.token`
- Include in `Authorization: Bearer $TOKEN` header
- Validate agent_id matches token claim

**No action required for current plan.** Authentication is not needed for local-only coordination.

---

## Deployment Risk Analysis

### HIGH: Auto-Release TOCTOU Race (Task 4) — FULLY MITIGATED

**Finding:** Amendment A3 eliminated the TOCTOU race by converting auto-release to **advisory-only mode**.

**Original risk (pre-A3):**
1. Pre-edit hook checks `git diff` → file is clean
2. Agent edits file (dirty)
3. Hook deletes reservation and sends `release_ack`
4. Requester edits the file → conflict

**Mitigation (Amendment A3, implemented in pre-edit.sh:66-107):**
- Hook does NOT delete reservations
- Hook does NOT send `release_ack` automatically
- Hook emits `additionalContext` with advisory text: "Use respond_to_release(...) to release or defer"
- Agent makes explicit decision via MCP tool call

**Verification:**
- pre-edit.sh:95-98 builds advisory string, does not call `/api/reservations` DELETE
- Line 102: Only action is `jq -nc` to emit context, not mutation

**Resolved.** No further action required.

---

### MEDIUM: Lost Wakeup in Blocking Poll (Task 2) — FULLY MITIGATED

**Finding:** Amendment A2 added a final check after deadline expiry to avoid false timeouts.

**Original risk:**
- Response arrives during `time.Sleep` → requester times out despite successful release

**Mitigation (tools.go:503-516):**
- After poll loop exits, perform one final `pollNegotiationThread` before returning `status: timeout`
- Also caps sleep to `min(pollInterval, remaining)` to reduce wakeup latency

**Verification:**
- tools.go:504: `status, payload, err := pollNegotiationThread(ctx, c, threadID)` — final check
- Line 508-516: Returns resolved status if found, else timeout
- Line 497: `sleepFor := negotiationPollInterval; if remaining < sleepFor { sleepFor = remaining }` — caps sleep

**Resolved.** No further action required.

---

### MEDIUM: Negotiation Timeout Enforcement Gaps (Task 6)

**Finding:** Plan relies on **lazy timeout enforcement** (triggered by `fetch_inbox`) + **background goroutine** (Amendment A5). Gaps remain for inactive projects.

**Gap 1: No agents polling inbox**
- If all agents stop before any calls `fetch_inbox`, timeouts never fire
- Mitigated by: Amendment A5 background goroutine (30s tick, starts on first `negotiate_release`)
- Residual risk: If Intermute service restarts, goroutine dies (not persisted)

**Gap 2: MCP server process exit**
- Background goroutine lives in MCP server process (Go)
- If process exits (Claude Code session ends), goroutine stops
- New session starts fresh, background goroutine restarts on first `negotiate_release`
- Pending negotiations from previous session are **not checked** until next fetch_inbox/negotiate_release

**Gap 3: Long-idle projects**
- If no agent is active (no MCP server running), timeouts don't fire
- Stale reservations accumulate until next agent joins

**Mitigation options:**

**Option A (Current plan):** Accept lazy enforcement as sufficient
- Rationale: Reservations have TTL (15 min default), auto-expire via Intermute's own cleanup
- Timeout is an **accelerator** for urgent requests, not a mandatory cleanup mechanism

**Option B (Robust):** Intermute service-side timeout enforcement
- Add timeout tracking to Intermute's reservation table (schema: `negotiation_timeout_at TIMESTAMP`)
- Intermute background worker checks every 30s, auto-releases expired negotiations
- Eliminates dependency on agent-side polling

**Option C (Hybrid):** MCP server persistence
- On shutdown, write active negotiations to `~/.config/clavain/interlock-pending-negotiations.json`
- On startup, load and resume timeout checks

**Recommendation:** **Option A** is acceptable for MVP. Reservations already have TTL-based expiry. If timeout enforcement gaps are problematic in practice, upgrade to Option B (Intermute-side enforcement) in a future iteration.

**No action required for current plan.** Document the limitation in AGENTS.md: "Timeout enforcement is best-effort; reservation TTLs provide hard expiry."

---

### LOW: Idempotency in Force-Release (Task 6)

**Finding:** `ReleaseByPattern` is idempotent (checks `IsActive` before delete), but **lacks verification test** (Amendment A9).

**Verification (client.go, not shown but inferred from plan):**
- Calls `ListReservations` with `agent` filter
- Iterates, checks `r.IsActive && patternsOverlap(r.PathPattern, pattern)`
- Only calls `DeleteReservation(r.ID)` if match found
- Returns `count` of deleted reservations

**Edge case:** If `DeleteReservation` is called twice concurrently (race), second call gets 404 → error?
- If error is propagated: force-release reports failure even though reservation is gone (false negative)
- If error is ignored (`err == nil` check): correct behavior (count remains accurate)

**Recommendation:** Verify `DeleteReservation` treats 404 as success (idempotent delete). Add test case per Amendment A9.

**Action required (low priority):** Add `TestReleaseByPattern_Idempotent` with mock server that returns 404 on second DELETE.

---

### HIGH: Concurrent Reservation Mutation During Force-Release

**Finding:** `checkNegotiationTimeouts` calls `ReleaseByPattern`, which is a read-modify-write operation. **Race condition if holder agent simultaneously edits the file (auto-reserves).**

**Attack scenario (non-malicious):**
1. Agent A holds `src/router.go` (reservation R1)
2. Agent B requests urgent release, timeout clock starts
3. 5 min pass, Agent B calls `fetch_inbox` → triggers `checkNegotiationTimeouts`
4. `checkNegotiationTimeouts` fetches A's reservations, sees R1, prepares to delete
5. **Simultaneously:** Agent A edits `src/router.go` → pre-edit hook creates new reservation R2 (auto-reserve)
6. `checkNegotiationTimeouts` deletes R1 (success)
7. Agent A still holds R2 → force-release **failed to release the file**

**Impact:**
- Requester believes file is released (received `release-ack`)
- Holder still has active reservation (R2, created milliseconds before R1 deletion)
- Requester's next edit triggers conflict again

**Root cause:** No atomic "release all reservations for agent+pattern" operation in Intermute API.

**Mitigation options:**

**Option 1 (Best):** Add `DELETE /api/reservations?agent={agent}&pattern={pattern}` endpoint to Intermute
- Atomic server-side deletion of all matching reservations
- Returns count of deleted reservations
- Eliminates TOCTOU race

**Option 2 (Client-side retry):** `ReleaseByPattern` loops until stable
- Call `ListReservations`, delete all matches
- Re-call `ListReservations`, verify count is 0
- If new reservations appeared, repeat (max 3 retries)
- Requester only receives `release-ack` after stable deletion

**Option 3 (Probabilistic):** Accept the race as low-probability
- Requires agent to edit **during the exact millisecond** of force-release
- Pre-edit auto-reserve only fires once per edit (throttled by hook call frequency)
- If race occurs, holder gets `additionalContext` on next edit about conflict

**Recommendation:** **Option 2** (client-side retry) is sufficient for local-only coordination. The race is rare and self-correcting (holder's next edit triggers conflict-check).

**Action required (medium priority):** Add retry loop to `ReleaseByPattern` with max 3 attempts and 100ms backoff. Add test case for race scenario.

---

### MEDIUM: Background Goroutine Lifecycle (Amendment A5)

**Finding:** `sync.Once` ensures goroutine starts exactly once per process, but **no clean shutdown on session end**.

**Analysis (tools.go:379-393):**
- `timeoutCheckerOnce.Do(...)` starts goroutine on first `negotiate_release` call
- Goroutine ticks every 30s, calls `c.CheckExpiredNegotiations(context.Background())`
- `timeoutCheckerStop` channel signals shutdown, but **no caller invokes `StopTimeoutChecker()`**

**Impact:**
- Goroutine runs until process exit (Claude Code session end)
- If process is long-lived (user never ends session), goroutine runs indefinitely → acceptable
- If `CheckExpiredNegotiations` errors repeatedly (Intermute unreachable), goroutine logs spam → **no error handling or backoff in current plan**

**Missing safeguards:**
1. Error backoff: If `CheckExpiredNegotiations` fails 3x consecutively, slow tick to 5min
2. Context cancellation: Pass session-scoped context to goroutine, cancel on MCP server shutdown
3. Panic recovery: Wrap ticker loop in `defer recover()` to prevent process crash

**Recommendation:**

```go
go func() {
    defer func() {
        if r := recover(); r != nil {
            // Log panic, do not crash process
        }
    }()
    ticker := time.NewTicker(30 * time.Second)
    defer ticker.Stop()
    consecutiveErrors := 0
    for {
        select {
        case <-ticker.C:
            _, err := c.CheckExpiredNegotiations(context.Background())
            if err != nil {
                consecutiveErrors++
                if consecutiveErrors >= 3 {
                    ticker.Reset(5 * time.Minute) // Slow down on repeated errors
                }
            } else {
                if consecutiveErrors >= 3 {
                    ticker.Reset(30 * time.Second) // Restore normal tick
                }
                consecutiveErrors = 0
            }
        case <-timeoutCheckerStop:
            return
        }
    }
}()
```

**Action required (medium priority):** Add error backoff and panic recovery to background goroutine.

---

### LOW: FetchThread API Existence (Amendment A6)

**Finding:** Plan assumes `GET /api/threads/{threadID}` exists in Intermute. **Not verified in plan.**

**Recommendation (from Amendment A6):**
- Try endpoint first
- If 404, fallback to `FetchInbox` filtered client-side by `thread_id`

**Verification needed:** Check Intermute's `/services/intermute/internal/http/handlers.go` for thread endpoint. If missing, implement client-side fallback per Amendment A6.

**Action required (pre-Task 1):** Verify Intermute API or implement fallback.

---

## Rollback Analysis

**Rollback feasibility:** High

**Reversible changes:**
- New MCP tools (`negotiate_release`, `respond_to_release`) — removing tools is backward-compatible (agents stop calling them)
- Client API additions (`SendMessageFull`, `FetchThread`) — no schema changes to Intermute database
- Pre-edit hook changes (advisory mode) — disabling `INTERLOCK_AUTO_RELEASE` restores original behavior
- Go code changes — rolling back Git commit restores previous binary

**Irreversible changes:**
- Negotiation message history in Intermute inbox (persisted in SQLite) — but messages are append-only, not destructive

**Data migration:**
- None required (no schema changes)

**Rollback procedure:**
1. Disable feature flag: `unset INTERLOCK_AUTO_RELEASE` in session env
2. Rebuild interlock binary from previous commit: `cd plugins/interlock && git checkout <prev-commit> && bash scripts/build.sh`
3. Restart Claude Code sessions to reload plugin
4. Optional: Clear negotiation message history via Intermute API `DELETE /api/messages?project=...&subject=release-request` (if needed)

**Rollback risk:** Low — no data loss, all changes are code-only (no persistent state beyond append-only messages)

---

## Pre-Deploy Checklist

**MANDATORY:**

1. **Verify Intermute `/api/threads/{threadID}` endpoint exists** (Amendment A6) or implement client fallback
2. **Add idempotency test for `ReleaseByPattern`** (Amendment A9: `TestReleaseByPattern_Idempotent`)
3. **Add retry loop to `ReleaseByPattern`** to mitigate force-release race (Option 2 above)
4. **Add error backoff to background goroutine** (prevent log spam on Intermute outage)
5. **Update Task 6 to advisory timeout OR add force-release safeguards** (holder notification + audit log)

**RECOMMENDED:**

1. Add integration test: full round-trip `negotiate_release` → `respond_to_release` → verify ack (Amendment A9)
2. Add bash unit test for `INTERLOCK_AUTO_RELEASE` feature flag parsing (Amendment A9)
3. Document timeout enforcement gaps in AGENTS.md ("best-effort, TTL provides hard expiry")
4. Add message size limit (100KB) to prevent memory exhaustion from large JSON payloads

**OPTIONAL (future hardening):**

1. Implement Option 1 (advisory timeout) instead of force-release for better agent autonomy
2. Add Intermute-side timeout enforcement (background worker) to eliminate agent-polling dependency
3. Add `DELETE /api/reservations?agent=X&pattern=Y` atomic endpoint to Intermute

---

## Post-Deploy Monitoring

**First-hour checks (manual):**
1. Tail interlock logs for panic/error in background goroutine: `journalctl -u intermute -f | grep -i timeout`
2. Test manual `negotiate_release` between two sessions, verify blocking wait resolves
3. Test advisory mode: `INTERLOCK_AUTO_RELEASE=1`, edit file, verify context injection (not auto-release)
4. Test timeout enforcement: request urgent release, wait 5 min, verify force-release fires

**First-day monitoring:**
1. Check for orphaned reservations (timeout enforcement gaps): `curl localhost:7338/api/reservations | jq '.reservations | group_by(.agent_id) | map({agent: .[0].agent_id, count: length})'`
2. Verify no pre-edit hook hangs (circuit breaker working): check for Edit tool calls >5s latency
3. Check for negotiation message spam (agents retrying on error): `curl localhost:7338/api/messages/inbox?agent=X | jq '[.messages[] | select(.subject=="release-request")] | length'`

**Failure signatures:**

| Symptom | Root Cause | Immediate Mitigation |
|---------|-----------|---------------------|
| Edit hangs >5s | Intermute unreachable, circuit breaker failed | Kill `intermute_curl_fast` subprocess, disable `INTERLOCK_AUTO_RELEASE` |
| Force-release didn't clear reservation | Concurrent auto-reserve race | Manual `release_files` call, then retry edit |
| Background goroutine panic | Nil pointer in `CheckExpiredNegotiations` | Restart MCP server (end Claude session, restart) |
| Thread not found (404) | `/api/threads` endpoint missing | Implement client-side fallback, rebuild binary |

---

## Risk Summary

| Risk | Severity | Status | Mitigation |
|------|----------|--------|-----------|
| Bash injection in pre-edit.sh | Low | Mitigated | Amendment A8 (jq --arg), already implemented |
| TOCTOU race in auto-release | High | Resolved | Amendment A3 (advisory-only mode) |
| Lost wakeup in blocking poll | Medium | Resolved | Amendment A2 (final check after deadline) |
| Force-release without consent | **Critical** | **Open** | **Task 6 needs revision: advisory OR safeguards** |
| Force-release concurrent mutation | High | **Open** | **Add retry loop to ReleaseByPattern** |
| Background goroutine errors | Medium | **Open** | **Add error backoff + panic recovery** |
| FetchThread API missing | Medium | Unknown | Verify or implement fallback (Amendment A6) |
| Negotiation timeout enforcement gaps | Medium | Accepted | Document as known limitation (TTL provides hard expiry) |
| Message deserialization exploits | Low | Mitigated | Go/jq safe deserialization, no code exec risk |
| Thread ID collision | Low | Mitigated | Amendment A1 (crypto/rand UUID) |
| Authentication missing | Informational | By design | Local-only threat model, no auth needed |
| Feature flag cross-session manipulation | Informational | Not possible | OS process isolation |

**Blocker issues (must fix before deploy):**
1. Task 6 force-release design (advisory vs. enforcement with safeguards)
2. `ReleaseByPattern` retry loop for race mitigation
3. Background goroutine error handling

**Go/no-go decision:**
- **No-go** until Task 6 revised and `ReleaseByPattern` race mitigated
- **Go** for Tasks 1-5 (negotiation protocol foundation) after FetchThread API verification

---

## Recommendations

### Immediate (Block Deploy)

1. **Revise Task 6 (force-release):**
   - Preferred: Convert to advisory-only (align with Amendment A3 philosophy)
   - Acceptable: Keep enforcement but add:
     - Holder notification (high-importance inbox message)
     - Audit log (`.interlock/force-release.log`)
     - Context injection on holder's next edit

2. **Add retry loop to `ReleaseByPattern`:**
   ```go
   for attempt := 0; attempt < 3; attempt++ {
       count, err := c.deleteMatchingReservations(ctx, agentID, pattern)
       if err != nil { return 0, err }
       // Verify no new reservations appeared
       verify, _ := c.ListReservations(ctx, ...)
       if len(verify) == 0 { return count, nil }
       time.Sleep(100 * time.Millisecond)
   }
   ```

3. **Add error backoff to background goroutine** (see code sample above)

### Pre-Deploy Verification

1. Verify Intermute `/api/threads/{threadID}` endpoint or implement fallback
2. Run full test suite including new Amendment A9 tests
3. Manual smoke test: negotiate + respond + timeout scenarios

### Documentation

1. Update AGENTS.md with timeout enforcement limitations
2. Add runbook section for force-release failure recovery
3. Document rollback procedure (4 steps above)

### Future Hardening (Post-MVP)

1. Migrate timeout enforcement to Intermute service (server-side background worker)
2. Add atomic `DELETE /api/reservations` endpoint to Intermute
3. Add MCP server graceful shutdown hook for `StopTimeoutChecker()`
