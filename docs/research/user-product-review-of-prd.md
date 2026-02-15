# User & Product Review: Interlock Reservation Negotiation Protocol

**PRD:** `/root/projects/Interverse/docs/prds/2026-02-15-interlock-reservation-negotiation.md`
**Reviewer:** Flux-drive User & Product Reviewer
**Date:** 2026-02-15

## Primary Users & Job to Be Done

**Primary users:**
1. **AI agents** (Claude Code sessions) — need to programmatically coordinate file ownership with other active agents without blocking their workflows
2. **Human operators** — need visibility into multi-agent coordination state to diagnose delays, resolve deadlocks, and understand who's working on what

**Job to be done:** When Agent B needs a file that Agent A currently holds, efficiently negotiate ownership handoff without unnecessary waiting, stalls, or lost requests, while maintaining visibility for human operators.

---

## Executive Summary: Key Issues

### Critical UX Problems
1. **Poll-instead-of-notify creates cognitive burden** — agents must poll `fetch_inbox` to check for responses instead of receiving notifications
2. **Missing failure modes** — no handling for network failures, crashed agents holding reservations, or inbox overflow
3. **Auto-release invisibility creates confusion** — holding agent learns about auto-release only via `additionalContext` in an unrelated edit operation
4. **Escalation timeout is invisible until it fires** — requesting agent has no countdown or warning before force-release

### Product Validation Gaps
1. **Problem severity unclear** — how often does file contention actually occur in real workflows? Is this solving a 1% edge case or a 50% blocker?
2. **Success metrics missing** — no measurable definition of "negotiation worked" vs "negotiation failed"
3. **Alternative not explored** — could simpler solutions (e.g., advisory warnings + faster TTL) solve 80% of the pain?

---

## User Experience Review

### Agent Workflow Friction

#### Critical: Poll-Based Response Checking (F3)
**Problem:** The negotiate→poll pattern forces agents to:
1. Call `negotiate_release` and store the returned `thread_id`
2. Periodically call `fetch_inbox` to check for responses
3. Parse inbox messages to find the matching thread
4. Decide whether to retry, wait, or escalate

**Why this is bad for AI agents:**
- AI agents are session-based and stateless between tool calls — storing and tracking `thread_id` across multiple turns is fragile
- Claude Code's tool call pattern expects immediate actionable responses, not "here's an ID, poll for results later"
- No clear signal for when to stop polling — agent might poll forever or give up too soon
- Creates unnecessary round-trips and latency in agent workflows

**Alternative pattern:** Return a handle that can be used in a blocking wait: `negotiate_release_and_wait(file, urgency, timeout_seconds)` that internally polls and returns the final outcome. Agents that need async behavior can use the existing `request_release`.

**Mitigation:** Add a convenience wrapper tool `await_release(thread_id, timeout_seconds)` that encapsulates the polling loop and returns success/defer/timeout.

#### Major: Auto-Release Invisibility (F2)
**Problem:** When the pre-edit hook auto-releases a file, the holding agent learns about it via `additionalContext` in the hook response. This is:
- **Passive discovery** — agent only finds out when they make their next edit, not when the release happens
- **Non-actionable** — by the time they see the message, the file is already released and potentially claimed by another agent
- **Easy to miss** — `additionalContext` is typically not surfaced in agent UI/logs unless something goes wrong

**User impact:** Agent A releases a file without knowing they released it. Agent B gets the file without knowing if it was voluntary or auto. This creates confusion when debugging multi-agent coordination issues.

**Fix:** Send a `release_notification` message to the holding agent when auto-release fires, separate from the `release_ack` sent to the requester. This way the holder learns about the release proactively.

#### Moderate: Urgency Levels Lack Semantics (F3)
**Problem:** The urgency enum (`low`, `normal`, `urgent`) only affects timeout durations. It doesn't change:
- How the holding agent is notified (no priority queue)
- Whether the request interrupts active work (all requests are passive)
- What information the requesting agent must provide (same `reason` field for all levels)

**Result:** Urgency feels like metadata for timeout tuning, not a meaningful signal. Agents have no way to know whether `urgent` means "I'm blocked" vs "I want this soon" vs "user is waiting."

**Fix:** Either remove urgency and use a single timeout, OR make urgency change the notification mechanism (e.g., `urgent` requests trigger a warning in the holder's next tool call response, not just inbox messages).

#### Minor: thread_id Leaks Implementation Detail (F1, F3)
**Problem:** Exposing `thread_id` as part of the agent-facing API leaks Intermute's threading model into the interlock abstraction. Agents now need to understand:
- That negotiations are threaded conversations
- How to correlate thread_id across tools
- What to do if they lose the thread_id

**Better abstraction:** Return a negotiation handle: `{negotiation_id, status, file, holder}`. Agent can later call `check_negotiation(negotiation_id)` instead of manually searching inbox for thread_id matches.

---

### Missing Edge Cases

#### Critical: Network Partition / Crashed Agent
**Problem:** If Agent A crashes or loses network connectivity, their reservations persist until TTL expiry (15 minutes). The negotiation protocol doesn't detect this.

**Scenario:**
1. Agent B sends `negotiate_release` to Agent A
2. Agent A is crashed (not running)
3. Timeout fires after 5-10 minutes → force-release
4. Agent A restarts 3 minutes later, expects to still hold the file, continues working

**Missing:** Health checks, heartbeat detection, or faster TTL decay for unresponsive agents.

**Fix:** Add an agent heartbeat mechanism (Intermute already tracks last_seen). If agent hasn't sent a message in N minutes, auto-release their reservations regardless of negotiation state.

#### Major: Inbox Overflow / Message Loss
**Problem:** If an agent generates many negotiations or receives many requests, inbox messages could be dropped or paginated. The PRD assumes:
- `fetch_inbox` always returns all relevant messages
- Messages are delivered reliably

**Missing:** Retry logic, message expiry, inbox size limits.

**Fix:** Document inbox retention policy. Add a `missed_messages` flag to `fetch_inbox` response if cursor skipped messages.

#### Moderate: Concurrent Negotiation for Same File
**Problem:** Agent B and Agent C both send `negotiate_release` to Agent A for the same file. What happens?

**Current design (inferred):** Both negotiations proceed independently. Agent A might respond to both, or only the first, or neither. If Agent A releases, only one agent can claim the reservation.

**Missing:** First-come-first-served queue, or notification to losing agents that the file is no longer available.

**Fix:** When Agent A releases in response to Agent B's request, auto-send `release_defer` to Agent C: "File released to another agent."

#### Moderate: Requesting Agent Disappears Before Response
**Problem:**
1. Agent B sends `negotiate_release` to Agent A
2. Agent A releases the file and sends `release_ack`
3. Agent B has exited / crashed / timed out
4. File is now unclaimed but Agent A thinks it's been handed off

**Missing:** Acknowledgment that the requester successfully claimed the file.

**Fix:** Require the requesting agent to send a `claim_reservation` message after receiving `release_ack`, or auto-expire the negotiation if no claim happens within 60 seconds.

---

### Flow Analysis

#### Happy Path: Auto-Release
1. Agent B calls `negotiate_release(file, urgency=normal, reason="need to refactor")`
2. Returns `{thread_id: "123"}`
3. Agent A's next edit triggers pre-edit hook
4. Hook checks inbox, finds request for file A holds
5. File has no uncommitted changes → auto-release
6. Hook sends `release_ack` on thread 123
7. Agent B calls `fetch_inbox`, finds `release_ack`, claims file

**Friction points:**
- Step 2→7: Agent B must poll until response arrives (no notification)
- Step 5: Agent A learns about release passively via `additionalContext`

#### Happy Path: Deferred Release
1. Agent B calls `negotiate_release(file, urgency=urgent, reason="blocked on this")`
2. Agent A's next edit triggers pre-edit hook
3. File has uncommitted changes → no auto-release
4. Hook does NOT notify Agent A about the request (just logs to `additionalContext`)
5. Agent A eventually commits and manually releases OR timeout fires (5 min for urgent)
6. Force-release happens, `release_ack` sent with `reason: "timeout"`

**Friction points:**
- Step 4: Agent A never sees the request unless they check `additionalContext` or sprint status
- Step 5: Requesting agent has no visibility into whether holder is working toward release or ignoring the request
- Timeout is the only forcing function — no collaborative handoff

#### Error Path: Timeout Force-Release
1. Agent B negotiates, waits 5 minutes
2. Agent B calls `fetch_inbox` (or `negotiate_release` again?) → timeout fires
3. Interlock force-releases Agent A's reservation
4. Sends `release_ack(reason=timeout)` to Agent B
5. Sends `release_notification` to Agent A (not in PRD — should be added)

**Missing states:**
- What if Agent A was 30 seconds away from committing? They discover their reservation was yanked mid-edit.
- What if force-release happens while Agent A is actively editing? Pre-commit hook will fail their commit.

**Fix:** Add a "soft timeout warning" — send a message to Agent A at 50% of timeout: "Agent B urgently needs file X, please release soon."

#### Error Path: Both Agents Claim Urgent
1. Agent A holds file X
2. Agent B sends `negotiate_release(file=X, urgency=urgent)` at T+0
3. Agent A sends `negotiate_release(file=Y, urgency=urgent)` to Agent B at T+30s
4. Both timeouts are 5 minutes
5. At T+5min: Agent B's timeout fires, force-releases X
6. At T+5:30min: Agent A's timeout fires, force-releases Y

**Problem:** No deadlock detection, no prioritization. First-come-first-served on timeout.

**Open question 3 in PRD is correct** — this needs a resolution strategy (human escalation, priority levels, or round-robin fairness).

---

### Sprint Status Visibility (F4)

**What it does well:**
- Shows pending negotiations in structured format
- Includes age and urgency for triage
- Parseable by both humans and agents

**Missing:**
- **Outcome history:** Recent resolutions (who released to whom, when) to understand flow
- **Escalation indicators:** Visual flag for negotiations approaching timeout
- **Holder awareness:** Does the holder even know about the request? (Flag if they haven't acked/deferred yet)
- **Deadlock detection:** Highlight circular dependencies (A waits for B, B waits for A)

**Suggested additions:**
```
Pending Negotiations:
  [URGENT, 4m ago] agent-charlie → agent-alice: src/**/*.go
    Status: No response yet (timeout in 1 minute)

  [normal, 12m ago] agent-bob → agent-charlie: docs/*.md
    Status: Deferred (eta: 5 minutes, reason: "finishing commit")

Recent Resolutions (last 15 min):
  agent-alice released internal/**/*.ts to agent-bob (auto-release, 3m ago)
  agent-charlie released README.md to agent-bob (timeout, 8m ago)
```

---

## Product Validation

### Problem Severity: Unproven

**Question:** How often does file contention actually block agents in real workflows?

**Evidence needed:**
- Frequency of `request_release` usage today (if any)
- Time agents spend waiting for TTL expiry
- User-reported incidents of "agent X blocked agent Y"

**If low frequency (< 5% of multi-agent sessions):** This is premature optimization. Better to improve TTL (drop from 15min to 5min) and add better logging.

**If high frequency (> 30% of multi-agent sessions):** Negotiation is justified, but the polling UX needs rework.

### Success Metrics: Missing

**What does success look like?**
- Average negotiation resolution time (target: < 30 seconds?)
- % of negotiations resolved via auto-release vs timeout vs voluntary release
- % of force-releases that caused commit conflicts
- Agent satisfaction: "negotiation reduced my blocked time" (qualitative)

**Failure modes to track:**
- Negotiations that timed out despite holder being active
- Files force-released while holder was mid-edit
- Inbox messages lost or delayed > 1 minute

### Alternative Solutions Not Explored

#### Alternative 1: Advisory Warnings (Simpler)
Instead of structured negotiation, just make conflicts visible:
- When Agent B tries to edit a file Agent A holds, show: "Agent A is working on this file (last edit 2m ago). Continue anyway?"
- When Agent A commits, show: "Agent B requested this file 5m ago. Release reservation?"

**Pros:** No polling, no threading, no timeout logic. Agents stay in control.
**Cons:** Requires human intervention for conflict resolution.

#### Alternative 2: Faster TTL + Auto-Refresh (Cheaper)
- Drop TTL from 15min to 2min
- Auto-renew reservation on every edit (already happens via pre-edit hook)
- If agent goes idle (no edits for 2min), reservation auto-expires

**Pros:** Solves 80% of "agent stopped working but held the file" cases. No new protocols.
**Cons:** Doesn't help if both agents are actively working on conflicting files.

#### Alternative 3: Optimistic Concurrency (Riskier but Faster)
- Let both agents edit simultaneously
- Detect conflicts at commit time (already done by git)
- Use a merge agent (Phase 4b) to auto-resolve simple conflicts

**Pros:** No blocking, no negotiation, maximum parallelism.
**Cons:** Increases conflict rate, depends on merge agent quality.

**Recommendation:** Prototype Alternative 2 first. It's a 10-line config change. If TTL=2min still causes pain, then build negotiation.

---

## Findings by Category

### Must Fix Before Implementation

1. **Replace poll-based response checking with a blocking wait tool** — `await_release(thread_id, timeout)` or make `negotiate_release` optionally blocking
2. **Add health check / heartbeat to detect crashed agents** — don't wait 5-10 minutes for timeout if agent is provably dead
3. **Send proactive notification to holding agent when auto-release fires** — don't bury it in `additionalContext`
4. **Define behavior for concurrent negotiations on same file** — queue or notify losing agents

### Should Fix for Complete UX

5. **Add soft timeout warnings** — notify holder at 50% of timeout so they can respond before force-release
6. **Add outcome history to sprint status** — show recent resolutions for debugging
7. **Add escalation indicators to sprint status** — flag negotiations approaching timeout
8. **Replace `thread_id` with opaque `negotiation_id`** — abstract away Intermute threading

### Product Direction Questions

9. **Measure problem frequency first** — instrument current system to count `request_release` usage and TTL wait times before building full negotiation
10. **Define success metrics** — avg resolution time, auto-release %, force-release conflict rate
11. **Prototype simpler alternative (TTL=2min + auto-renew)** — validate that negotiation is necessary

---

## Open Questions from PRD: Answers

### Q1: Pre-edit hook vs periodic check?
**Answer:** Pre-edit hook is correct. Periodic check would require a background daemon (complexity, resource cost). The escalation timeout (F5) already covers the "agent went idle" case by force-releasing.

**BUT:** This assumes agents edit frequently. If an agent reads for 10 minutes without editing, auto-release never fires. Mitigation: add heartbeat (see "Must Fix #2" above).

### Q2: Block until response or return immediately?
**Answer:** Offer both. Default `negotiate_release` returns immediately (non-blocking for agent workflows). Add `negotiate_release_and_wait` for agents that want to block.

**Rationale:** Agents that are blocked on the file (can't proceed without it) should block. Agents that can work on something else while waiting should not block.

### Q3: Both agents claim urgent?
**Answer:** First-come-first-served is acceptable for MVP, but add deadlock detection to sprint status.

**Future:** Add priority levels (user-driven workflows get priority over background tasks), or require human escalation for `urgent` → `urgent` conflicts.

---

## Recommendation

**Green-light with conditions:**

1. **Instrument current system first** — add logging to measure how often agents hit file contention and how long they wait. This validates the problem scope.

2. **Prototype TTL=2min alternative** — before building negotiation, try the simpler fix. If it solves 80% of cases, negotiation becomes a nice-to-have, not a must-have.

3. **Fix critical UX issues** — blocking wait tool, health checks, proactive notifications, concurrent negotiation handling. The poll-based UX as written will frustrate both agents and humans.

4. **Define success metrics** — commit to measurable outcomes so you can validate whether negotiation actually improved workflows.

5. **Phase the rollout:**
   - **Phase 1:** F2 (auto-release) + F4 (sprint visibility) — this alone solves the "clean file held unnecessarily" case
   - **Phase 2:** F1+F3 (negotiate tool) — only if Phase 1 shows frequent deferred releases
   - **Phase 3:** F5 (escalation timeout) — only if Phase 2 shows slow response times

**Do not build all five features at once.** Auto-release (F2) delivers immediate value. The rest are speculative until proven necessary by real usage data.
