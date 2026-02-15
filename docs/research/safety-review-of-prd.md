# Security & Deployment Safety Review: Interlock Reservation Negotiation Protocol

**PRD:** `/root/projects/Interverse/docs/prds/2026-02-15-interlock-reservation-negotiation.md`
**Reviewer:** Flux-drive Safety Reviewer
**Date:** 2026-02-15
**Risk Classification:** **Medium-High** (authorization boundaries, hook performance, force-release abuse potential)

---

## Executive Summary

The reservation negotiation protocol adds structured request/response messaging and auto-release mechanisms to interlock's multi-agent file coordination system. The proposal introduces **three critical trust boundary decisions**: F2's auto-release in pre-edit hook, F5's force-release with "no-force" flag, and F3's urgency-based escalation. All three rely on **agent self-declaration without external authority verification**, creating exploitable attack surfaces even within the semi-trusted threat model.

**Primary concerns:**
1. **Auto-release (F2) performance risk**: Inbox check on every file edit adds HTTP roundtrip to pre-edit hook's critical path, no circuit breaker documented
2. **Force-release authorization gap (F5)**: "no-force" flag is agent-declared metadata with no enforcement layer; malicious/buggy agent can ignore it
3. **Escalation DoS surface (F3)**: Urgent requests with 5min timeout enable reservation denial attacks; no rate limiting specified
4. **Hook deployment risk**: Pre-edit hook is blocking hook in critical path; buggy inbox logic can lock all agents out of editing

**Recommended mitigations:**
- Add timeout/circuit-breaker to F2 inbox check with fail-open semantics
- Require human confirmation or Intermute-enforced `no-force` flag validation before force-release
- Add per-agent rate limiting for urgent requests
- Stage rollout with feature flag controlling auto-release behavior
- Create pre-deploy health check validating inbox API response time

---

## Threat Model Context

**Architecture:**
- Multiple Claude Code sessions (agents) share a git repo
- Coordination via Intermute HTTP service on localhost:7338 (Unix socket preferred)
- Reservations stored in Intermute SQLite DB with TTL-based expiry
- Trust boundary: **semi-trusted agents** (all sessions run as same user, no malicious intent assumed, but bugs/races possible)

**Attack surface:**
- **Entry points:** MCP tools (9 existing + 1 new), pre-edit bash hook (runs on every Edit call), Intermute HTTP API
- **Untrusted inputs:** Agent-declared urgency levels, "no-force" flags, message thread_ids, reservation reasons/ETAs
- **Sensitive operations:** Force-releasing another agent's reservation, auto-releasing files with uncommitted changes (risk: silent data loss)

**Existing safety layers:**
- Pre-edit hook blocks edits to exclusively reserved files (with fail-open on Intermute unreachable)
- Git pre-commit hook enforces reservation checks at commit time (with `--no-verify` escape hatch)
- 15min TTL on reservations (auto-renewed on subsequent edits)
- Background sweeper cleans expired reservations from dead agents

---

## Security Findings

### S1: Force-Release Authorization Bypass [HIGH]

**F5 states:** "Force-release respects a 'no-force' flag that agents can set on critical reservations."

**Problem:** Who validates the flag?
- If the **requesting agent** checks the flag before force-releasing → trivial bypass (agent just skips the check)
- If **Intermute** enforces the flag → requires new authorization logic in `ReleaseReservation()` to check `requester_id != holder_id` AND `no_force=true` → fail
- PRD does not specify which layer enforces the flag

**Exploit scenario (semi-trusted model):**
1. Agent A reserves `internal/storage/sqlite.go` with `no_force: true` (critical migration code)
2. Agent B sends urgent `negotiate_release`, timeout fires after 5min
3. Agent B calls Intermute `DELETE /api/reservations/{id}` directly (bypassing interlock MCP layer)
4. Intermute deletes the reservation (current `ReleaseReservation()` only checks `agent_id` matches holder, not force-release policy)
5. Agent B edits file, Agent A's uncommitted migration changes are lost in merge conflict

**Current `ReleaseReservation()` code (from grep results):**
```go
// handlers_reservations_test.go line 14:
func TestReleaseReservationOwnershipEnforced(t *testing.T)
```
Existing enforcement only validates **holder ownership** (agent can't release other agent's reservation via normal DELETE). But force-release path is not shown in PRD — does it use the same DELETE endpoint with a special header? A separate endpoint? MCP tool only?

**Recommended mitigation:**
- **Option A (Intermute enforcement, RECOMMENDED):** Add `no_force` boolean field to `file_reservations` table. Modify `ReleaseReservation()` to accept optional `force bool` parameter. If `force=true` AND reservation has `no_force=true` → return 403 Forbidden. Log force-release attempts for audit.
- **Option B (Human confirmation):** Force-release requires human approval in Claude Code UI (similar to `--dangerously-skip-permissions` gate). Not scalable for multi-agent workflows.
- **Option C (Time-based override):** `no_force` only applies for first N minutes; after that, timeout can override. Document this in F5 acceptance criteria.

**Rollback impact:** If we ship F5 without enforcement and later discover abuse, rolling back requires reverting both interlock MCP tools AND Intermute API changes. Data migration needed if we later add `no_force` column.

---

### S2: Auto-Release Race Condition (Uncommitted Changes) [MEDIUM]

**F2 acceptance criteria:** "If the held file has no uncommitted changes (`git diff --name-only` doesn't include it), auto-release the reservation."

**Problem:** TOCTOU race between diff check and auto-release.

**Race scenario:**
1. Agent A holds `router.go`, has uncommitted changes
2. Agent B sends `release-request`
3. **Agent A's pre-edit hook fires** for a *different file* (`handler.go`)
4. Hook checks: `git diff --name-only` does NOT include `handler.go` → clean ✓
5. Hook reads inbox: sees release-request for `router.go`
6. Hook checks: `git diff --name-only` **DOES** include `router.go` → has changes ✗ → should NOT auto-release
7. **BUT:** between step 6 and the auto-release call, Agent A calls `git add router.go` from *another tool* (not Edit)
8. Hook calls auto-release (based on stale check) → reservation released
9. Agent B immediately reserves `router.go` and starts editing
10. Agent A's staged changes in index create merge conflict on next pull

**Recommended mitigation:**
- Re-check `git diff --name-only` immediately before calling Intermute release API (double-check pattern)
- OR: Only auto-release files that have been **committed since reservation** (check `git diff HEAD^ --name-only` if file is in last commit)
- Add hook logging: "Auto-released {file} (no uncommitted changes at check time)" so agents can see what happened

**Edge case:** What if file has *staged* changes but not *unstaged* changes? `git diff --name-only` shows unstaged; `git diff --cached --name-only` shows staged. PRD should specify which diff to check.

---

### S3: Urgent Request Denial-of-Service [MEDIUM]

**F3/F5 design:** Urgent requests set 5min timeout; normal requests 10min; low requests no timeout.

**Attack vector:**
1. Buggy/malicious Agent B sends 100 urgent `negotiate_release` requests for different files Agent A holds
2. Each request starts a 5min countdown
3. Agent A's inbox is flooded; pre-edit hook spends 200ms checking inbox on every edit (F2 acceptance: <200ms)
4. Agent A cannot process requests fast enough (human in the loop, or agent context full)
5. All 100 timeouts fire simultaneously after 5min
6. All reservations force-released at once
7. Agent A's multi-file coordinated changes (e.g., refactor across 20 files) are interrupted mid-stream

**No rate limiting specified in PRD.** Intermute has no per-agent message quota documented.

**Recommended mitigation:**
- Add per-agent rate limit for `release-request` messages: max 5 urgent requests per 10min window
- F5 timeout check should enforce "max 3 concurrent force-releases per agent per project" to prevent bulk release
- Emit warning to sending agent if request is rate-limited: "You have 5 pending urgent requests; new requests will be downgraded to normal priority"

---

### S4: Inbox Check Performance Regression [HIGH - DEPLOYMENT RISK]

**F2 acceptance:** "Performance: inbox check adds <200ms to pre-edit hook execution (cached or batched)"

**Current pre-edit hook:** Already does inbox check for commit notifications (lines 24-63 in `pre-edit.sh`), **throttled to 30-second cache** (`-mmin -0.5`). Adds auto-pull on commit message receipt.

**New F2 requirement:** Check inbox for `release-request` messages **on every pre-edit hook fire** (not just every 30sec).

**Performance math:**
- Intermute HTTP call via Unix socket: ~10-30ms (localhost)
- Intermute SQLite query for inbox: ~5-20ms (indexed, <1000 messages expected)
- jq parsing in bash: ~5-10ms
- git diff check per file: ~10ms
- **Total per-edit overhead: 30-70ms** (within 200ms budget if Intermute healthy)

**Failure mode:** If Intermute is under load (multiple agents, 10+ messages/sec), inbox query can spike to 200ms+. Pre-edit hook has **no timeout, no circuit breaker documented**. One slow Intermute query blocks all edits across all sessions.

**Current resilience:** Existing inbox check has `2>/dev/null` redirect and `|| true` fallbacks — fails open if Intermute unreachable. **BUT F2 auto-release requires success response** to parse release-request messages, so failure path must be explicit.

**Recommended mitigation:**
- Add **timeout flag to intermute_curl**: `--max-time 2` (fail-open after 2sec)
- Add **circuit breaker**: If inbox check fails 3 times in a row, disable F2 auto-release for this session (emit warning, agent can manually call `release_files`)
- Keep 30sec throttle for inbox check (same flag file as commit notifications), only check on *first edit in 30sec window*
- Log slow queries: if inbox check takes >100ms, emit `additionalContext` warning so agent knows coordination is degraded

**Pre-deploy health check:** Before shipping F2, add test: "Intermute inbox query with 1000 messages should respond <50ms on target hardware"

---

### S5: Thread ID Collision / Spoofing [LOW]

**F1 acceptance:** "Messages use Intermute threading (same `thread_id` as the original `release-request`)"

**F3 states:** "Tool sends a `release-request` message with a generated `thread_id`"

**Threat:** Agent B can guess/reuse Agent A's thread_id and inject fake `release_ack` responses.

**Exploit scenario:**
1. Agent A sends `negotiate_release(file=router.go, urgency=urgent)` → generates `thread_id=abc123`
2. Agent B (malicious) guesses common UUID format, sends message with `thread_id=abc123`, `type=release_ack`, `released=true`
3. Agent A's next `fetch_inbox` sees fake ack, assumes file is released
4. Agent A tries to reserve `router.go` → conflicts with Agent C's existing reservation (not Agent B's)
5. Coordination breaks, Agent A wastes time debugging

**Low risk because:**
- Agents are semi-trusted (same user's sessions)
- UUIDs have 122 bits entropy (collision probability negligible)
- Intermute message schema includes `from` field (can validate sender)

**Recommended mitigation:**
- Document in F3 implementation: "Validate `release_ack.from` matches the original reservation holder before acting on ack"
- OR: Store thread_id -> expected_responder mapping in interlock client, reject mismatched responses

---

### S6: Deferred Response ETA Inflation [LOW]

**F1 acceptance:** "`release_defer` includes `{eta_minutes: N, reason}`"

**Exploit:** Agent A defers with `eta_minutes: 999999` to effectively block Agent B forever.

**Not a real threat because:**
- Agent B can still force-release after timeout (F5)
- Human agents can use `/interlock:status` to see unreasonable ETAs and escalate manually
- Semi-trusted model assumes agents don't intentionally grief each other

**Recommended mitigation:**
- Cap `eta_minutes` at some reasonable max (e.g., 60min) in F1 validation
- OR: Treat ETA as advisory only, don't extend timeout based on ETA (timeout is fixed by urgency level, not ETA)

---

## Deployment & Migration Risks

### D1: Pre-Edit Hook Modification (Blocking Path) [HIGH]

**What's changing:** Add inbox check + auto-release logic to `pre-edit.sh` (lines 24-63 expanded).

**Risk:** Pre-edit hook is **blocking** hook (`decision: block` on conflict). Bugs in F2 inbox parsing can:
- Block all edits with jq parse error
- Hang on slow Intermute query (no timeout)
- Accidentally release wrong files (glob matching bug)
- Auto-release files with uncommitted changes (TOCTOU race from S2)

**Current safety net:**
- Hook fails open if `INTERMUTE_AGENT_ID` not set (line 16: `exit 0`)
- Hook fails open if Intermute unreachable (line 86: `exit 0` on curl failure)
- **BUT:** Hook does NOT fail open if jq parsing fails (missing `|| true` in some jq pipelines)

**Rollback path:**
- Rolling back interlock plugin → requires all agents to reinstall plugin from previous marketplace version
- Git hook installed in `.git/hooks/` is **not auto-updated** by plugin reinstall (user must run `/interlock:setup` again)
- If F2 ships with a bug, agents can bypass with `INTERMUTE_AGENT_ID='' claude ...` (disables coordination entirely, loses reservation safety)

**Recommended pre-deploy checks:**
1. **Syntax validation:** `bash -n hooks/pre-edit.sh` on all changes
2. **Shellcheck pass:** Catch missing error handling
3. **Simulated failure test:** Mock Intermute returning malformed JSON, verify hook fails open
4. **Performance test:** Mock Intermute with 200ms delay, verify hook doesn't hang
5. **TOCTOU test:** Concurrent `git add` while auto-release check runs, verify no race

**Recommended rollout strategy:**
- **Phase 1 (week 1):** Ship F1+F3 (message types + negotiate tool) WITHOUT F2 auto-release → agents can test request/response flow manually
- **Phase 2 (week 2):** Ship F2 with **feature flag** (`INTERLOCK_AUTOLEASE=1` env var) → opt-in testing
- **Phase 3 (week 3):** Enable F2 by default if no escalations from phase 2
- **Phase 4 (week 4):** Ship F5 escalation timeout (most dangerous feature, requires F2 working smoothly first)

---

### D2: Intermute Schema Changes (If F5 Requires no-force Column) [MEDIUM]

**Scenario:** If we implement S1 mitigation Option A, need new column in `file_reservations` table.

**Migration:**
```sql
ALTER TABLE file_reservations ADD COLUMN no_force BOOLEAN DEFAULT 0;
```

**Deployment risk:**
- Intermute is running as systemd service; schema migration requires restart
- If migration fails halfway (SQLite `database is locked` error), service won't start
- Agents will lose coordination until Intermute recovers

**Rollback path:**
- Downgrade Intermute binary → old code doesn't know about `no_force` column → forward-compatible (ignores unknown column)
- If we later want to remove the column → requires another migration

**Recommended deployment:**
1. Stop Intermute service: `systemctl stop intermute`
2. Backup DB: `cp intermute.db intermute.db.backup-$(date +%s)`
3. Run migration: `sqlite3 intermute.db < migrations/007_add_no_force.sql`
4. Start Intermute: `systemctl start intermute`
5. Verify health: `curl -sf http://localhost:7338/health` (if health endpoint exists)
6. If migration failed: `systemctl stop intermute && mv intermute.db.backup-* intermute.db && systemctl start intermute`

**Irreversibility:** Once agents start setting `no_force=true` on reservations, rolling back the schema loses that data (column dropped). **Not catastrophic** because reservations are ephemeral (15min TTL), but agents relying on no-force protection will lose it.

---

### D3: Message Schema Evolution (thread_id Field) [LOW]

**F1 acceptance:** "Existing `request_release` tool's message body includes a `thread_id` for response threading"

**Current `request_release` implementation (from tools.go lines 274-300):**
```go
body, _ := json.Marshal(map[string]string{
    "type": "release-request",
    // ... other fields
})
```

**Change:** Add `thread_id` field to message body.

**Backward compatibility:**
- Old interlock clients reading messages with `thread_id` → ignore unknown field (Go JSON unmarshaling is forward-compatible)
- New interlock clients reading old messages without `thread_id` → treat as legacy fire-and-forget request (no response expected)

**Rollback safety:** Fully reversible. If F1 has bugs, rolling back interlock plugin doesn't break old messages (they never had thread_id anyway).

---

### D4: Timeout State Management (F5 Lazy Evaluation) [MEDIUM]

**F5 design:** "Timeout is enforced by the requesting agent's next `negotiate_release` or `fetch_inbox` call (not a background process)"

**Problem:** Timeout enforcement is lazy → unpredictable timing.

**Scenario:**
1. Agent B sends urgent request at T=0
2. Timeout should fire at T=5min
3. Agent B doesn't call `fetch_inbox` or `negotiate_release` again until T=20min (busy with other work)
4. At T=20min, Agent B's tool call sees "request sent at T=0, timeout=5min, now=T=20min" → 15min late
5. Force-releases reservation that Agent A may have already released voluntarily at T=7min
6. Intermute DELETE returns 404 (reservation doesn't exist) → false alarm

**Edge case:** If Agent A released voluntarily and Agent B force-released "late", does Agent B send duplicate `release_ack` message? PRD doesn't specify idempotency.

**Recommended mitigation:**
- Timeout check should query reservation status BEFORE force-releasing: if reservation already released → send informational message "Agent {A} released {file} before timeout", skip force-release
- Log all force-release attempts (even 404s) for debugging

---

## Operational & Rollback Feasibility

### Invariants That Must Hold

**Before deploy:**
1. All agents have interlock 0.1.x installed (check via `/interlock:status` version header)
2. Intermute is healthy and responsive (<50ms avg inbox query time)
3. Pre-edit hook performance baseline: <30ms per edit (measure with `time` wrapper)

**After deploy:**
1. Pre-edit hook performance: <100ms per edit (allows 3x headroom from baseline)
2. No increase in "Intermute unreachable" warnings (tracked via interlock signal emissions)
3. No false-positive force-releases (agent reports "my reservation was force-released but I was still editing" → S1 enforcement failure)

**Post-deploy verification (first 24h):**
- Monitor interlock signal files for `release` events with `reason: "timeout"` → count should be low (<5% of total releases)
- Check Intermute DB for expired reservations not cleaned by sweeper → indicates timeout logic not firing
- Grep pre-edit hook logs for "auto-pulled after commit" AND "auto-released {file}" in same hook execution → validates F2 working

### Rollback Decision Tree

| Symptom | Root Cause Hypothesis | Immediate Mitigation | Rollback Needed? |
|---------|----------------------|---------------------|------------------|
| Pre-edit hook hangs (>5sec) | S4: Intermute slow query, no timeout | Kill Intermute, restart → clears query queue | No (operational fix) |
| All edits blocked with jq error | D1: Malformed inbox JSON from Intermute | Patch hook to add `|| true` to jq pipeline | No (hotfix hook script) |
| Agent reports "file force-released while editing" | S1: No-force bypass | Disable F5 via interlock config flag | **YES** (revert to 0.1.x) |
| Inbox flooded with urgent requests | S3: No rate limiting | Manually delete spam messages from Intermute DB | No (add rate limit in hotfix) |
| Auto-release race: uncommitted changes lost | S2: TOCTOU between diff and release | Disable F2 auto-release via env flag | Partial (F2 only) |

**Full rollback procedure (if F5 force-release abuse detected):**
1. All agents: `cd ~/.claude/plugins/cache/interlock-* && git pull origin v0.1.1 && bash scripts/build.sh`
2. All agents: `/interlock:setup` (reinstall pre-edit hook without F2 logic)
3. Intermute admin: `sqlite3 intermute.db "DELETE FROM messages WHERE subject LIKE 'release-%' AND created_at > '2026-02-15'"` (purge negotiation messages)
4. Verify: `/interlock:status` shows no pending negotiations

**Irreversible changes:**
- Messages sent during F1-F5 operation remain in Intermute DB (can be purged manually, but thread history is lost)
- If S1 mitigation Option A was deployed (no-force column), rolling back doesn't remove column (harmless but pollutes schema)

---

## Risk-Severity Matrix

| Finding | Exploitability | Blast Radius | Mitigation Complexity | Recommended Action |
|---------|---------------|--------------|----------------------|-------------------|
| **S1: Force-release authorization bypass** | Medium (requires intentional API call) | High (data loss from force-released uncommitted work) | Medium (Intermute schema + enforcement logic) | BLOCK until mitigation Option A implemented |
| **S2: Auto-release race condition** | Low (requires precise timing) | Medium (merge conflict, not data loss) | Low (add double-check in hook) | Accept risk + monitor, fix in v2 if frequent |
| **S4: Inbox check performance** | High (any Intermute slowdown) | High (all agents blocked from editing) | Low (add timeout to curl call) | BLOCK until timeout + circuit breaker added |
| **S3: Urgent request DoS** | Medium (requires buggy/malicious agent) | Medium (interrupts multi-file work, no data loss) | Medium (add rate limiting to Intermute) | Ship with monitoring, add rate limit in v2 if abused |
| **D1: Pre-edit hook deployment risk** | High (any hook bug affects all sessions) | High (blocks all edits until reverted) | Low (staged rollout with feature flag) | REQUIRE staged rollout (D1 mitigation) |
| **S5: Thread ID spoofing** | Low (UUIDs are hard to guess) | Low (coordination confusion, no data loss) | Low (validate sender in ack handler) | Document in code review, defer to v2 |
| **S6: ETA inflation** | Low (semi-trusted agents) | Low (timeout overrides anyway) | Low (cap ETA at 60min) | Ship as-is, add cap if abused |

---

## Go / No-Go Recommendation

**CONDITIONAL GO** with the following **mandatory pre-deploy fixes:**

### Blocking Issues (Must Fix Before Ship)
1. **S1 mitigation:** Implement "no-force" enforcement in Intermute `ReleaseReservation()` (Option A) OR remove F5 from v1 scope (defer force-release to v2)
2. **S4 mitigation:** Add `--max-time 2` to inbox check curl call + circuit breaker after 3 failures
3. **D1 mitigation:** Staged rollout with feature flag (`INTERLOCK_NEGOTIATION_ENABLED=1` env var, default off for week 1)

### Recommended Improvements (Nice-to-Have, Not Blocking)
4. **S2 mitigation:** Double-check git diff immediately before auto-release call
5. **S3 mitigation:** Document rate limiting as future work, add telemetry to detect abuse
6. **D4 mitigation:** Add idempotency check before force-release (query reservation status first)

### Post-Deploy Monitoring (First 48 Hours)
- Alert on: pre-edit hook execution time >200ms (P2 incident)
- Alert on: force-release events >10/hour across all agents (P3 investigation)
- Alert on: Intermute unavailable errors >5% of hook calls (P1 incident)
- Daily review: interlock signal files for anomalous release patterns

---

## Additional Secure Design Recommendations

### For Future Iterations (Phase 5+)

1. **Audit log for force-releases:** Every force-release should append to a project-level audit log (`{project}/.interlock/force-release.log`) with timestamp, requester, holder, file, reason. Human-readable for post-incident review.

2. **Cooperative timeout (not unilateral):** Instead of Agent B unilaterally force-releasing after timeout, Intermute could enforce: "If request is >5min old AND holder hasn't sent `release_defer` → Intermute auto-releases reservation AND notifies holder." This removes force-release privilege from requesting agent.

3. **Conflict resolution priority:** If two agents both claim "urgent" for the same file, use tie-breaker: (a) oldest reservation wins, (b) agent with most commits in file's history wins, (c) human escalation. PRD currently has "first-come-first-served" which is underspecified.

4. **Health check endpoint:** Add `/api/health` to Intermute that returns `{inbox_query_p95_ms, active_reservations_count, messages_last_hour}`. Pre-edit hook can check this before doing expensive inbox queries.

5. **Dead agent cleanup:** F5 timeout assumes "unresponsive agent" but doesn't distinguish "busy agent" from "crashed agent". Integrate with Intermute heartbeat: if holder hasn't heartbeat in 2min, auto-release without waiting for timeout.

---

## Conclusion

The reservation negotiation protocol is **architecturally sound** for the semi-trusted multi-agent threat model, but has **three exploitable gaps** (S1, S4, S3) that must be addressed before production use. The most critical risk is **S4 (inbox performance)** because it can lock all agents out of editing, and **S1 (force-release authorization)** because it can cause data loss from uncommitted work.

The **staged rollout strategy** (D1 mitigation) is essential because pre-edit hook bugs have high blast radius. Shipping F1+F3 first (request/response protocol) without F2 (auto-release) or F5 (force-release) reduces risk while allowing iterative validation.

**Recommended ship sequence:**
1. **v0.2.0-alpha (week 1):** F1+F3 only, feature-flagged, opt-in testing
2. **v0.2.0-beta (week 2):** Add F2 auto-release with timeout+circuit-breaker, still feature-flagged
3. **v0.2.0-rc (week 3):** Add F4 status visibility, enable by default for internal testing
4. **v0.2.0 (week 4):** Add F5 force-release with Intermute-enforced no-force validation, full release
5. **v0.2.1 (week 5):** Hotfix window for any issues found in production

With the blocking mitigations implemented and staged rollout enforced, this PRD can proceed to implementation.
