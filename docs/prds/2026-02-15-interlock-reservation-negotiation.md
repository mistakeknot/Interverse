# PRD: Interlock Reservation Negotiation Protocol

**Bead:** iv-2vup
**Date:** 2026-02-15
**Predecessor:** Phases 1-3 of multi-session coordination

## Problem

When Agent B needs a file that Agent A holds, the only options are "fire-and-forget `request_release`" (which Agent A may never process) or "wait for TTL expiry" (15 minutes). This creates unnecessary delays in multi-agent workflows and leaves agents with no structured way to negotiate file ownership handoff.

## Solution

Add a reservation negotiation protocol to interlock: structured request/response message types, automatic release of clean files, a new `negotiate_release` MCP tool with response tracking, sprint-visible negotiation state, and escalation timeouts for unresponsive agents.

## Features

### F1: Release Response Protocol
**What:** Add `release_ack` and `release_defer` message types so agents can respond to release requests with structured data instead of free-text messages.

**Acceptance criteria:**
- [ ] `release_ack` message type includes `{file, released: true, released_by}` — sent when Agent A releases the file
- [ ] `release_defer` message type includes `{file, released: false, eta_minutes: N, reason}` — sent when Agent A needs more time
- [ ] Messages use Intermute threading (same `thread_id` as the original `release-request`) so the conversation is trackable
- [ ] Existing `request_release` tool's message body includes a `thread_id` for response threading
- [ ] Both message types are parseable by the `fetch_inbox` consumer without special handling (standard JSON body)

**Implementation notes:**
- These are conventions on Intermute's existing message infrastructure, not new server endpoints
- The interlock MCP server enforces the message format; Intermute just delivers messages

### F2: Auto-Release on Clean Files
**What:** When the pre-edit hook runs and detects a pending `request_release` message for a file this agent holds, auto-release the reservation if the file has no uncommitted changes.

**Acceptance criteria:**
- [ ] Pre-edit hook (`pre-edit.sh`) checks inbox for `release-request` messages targeting files this agent holds
- [ ] If the held file has no uncommitted changes (`git diff --name-only` doesn't include it), auto-release via Intermute API
- [ ] After auto-release, send a `release_ack` response on the same thread
- [ ] If the file has uncommitted changes, do NOT auto-release — the agent retains the reservation
- [ ] Auto-release is logged in hook `additionalContext` so the agent knows what happened
- [ ] Performance: inbox check adds <200ms to pre-edit hook execution (cached or batched)

**Implementation notes:**
- The pre-edit hook already calls Intermute for reservation checks — piggyback on the same connection
- Only check inbox when the hook fires (not a polling loop) to avoid performance overhead
- Use `since_cursor` to avoid re-processing old messages

### F3: Structured Negotiate Tool
**What:** New MCP tool `negotiate_release` that replaces fire-and-forget `request_release` with a structured request/response flow including urgency levels and response tracking.

**Acceptance criteria:**
- [ ] New tool `negotiate_release(file, urgency, reason)` with urgency enum: `low`, `normal`, `urgent`
- [ ] Tool sends a `release-request` message with a generated `thread_id` and sets `importance` field based on urgency
- [ ] Tool returns the `thread_id` so the caller can later check for responses via `fetch_inbox`
- [ ] Existing `request_release` tool remains as a simpler alias (backward compatible)
- [ ] `urgent` requests set `ack_required: true` on the message so Intermute tracks acknowledgment
- [ ] Tool validates the target agent exists and holds the specified file before sending

**Implementation notes:**
- Implement in `internal/tools/tools.go` alongside existing tools
- Use Intermute's existing `importance` and `ack_required` fields (already in the message schema)
- Validate reservation state via the same check_conflicts call path

### F4: Sprint Scan Release Visibility
**What:** Show pending release requests in the sprint status scan (`/interlock:status`) so humans and agents can see negotiation state at a glance.

**Acceptance criteria:**
- [ ] `/interlock:status` output includes a "Pending Negotiations" section
- [ ] Each negotiation shows: requester, holder, file pattern, urgency, age (minutes since request)
- [ ] Resolved negotiations (with `release_ack`) are not shown (or shown as "resolved" if recent)
- [ ] Deferred negotiations (with `release_defer`) show the ETA
- [ ] Output is parseable by both humans (table format) and agents (structured when consumed via MCP)

**Implementation notes:**
- The status command already queries Intermute for agent state — extend the query
- Filter inbox messages by `type: "release-request"` body prefix, join with thread responses
- Keep it lightweight: only scan recent messages (last hour), not full history

### F5: Escalation Timeout
**What:** If Agent A doesn't respond to a release request within a configurable timeout, auto-release the reservation.

**Acceptance criteria:**
- [ ] Configurable timeout (default: 5 minutes for `urgent`, 10 minutes for `normal`, no timeout for `low`)
- [ ] Timeout is enforced by the requesting agent's next `negotiate_release` or `fetch_inbox` call (not a background process)
- [ ] When timeout fires: interlock force-releases the reservation via Intermute API, sends `release_ack` with `reason: "timeout"`
- [ ] The holding agent is notified via message that their reservation was force-released
- [ ] Timeout is only active for `negotiate_release` requests (not legacy `request_release`)
- [ ] Force-release respects a "no-force" flag that agents can set on critical reservations

**Implementation notes:**
- No background daemon needed — check timeout on next interaction (lazy evaluation)
- Store request timestamps in the message body (already have `created_at`)
- Force-release calls the same `release_files` API path used by voluntary release

## Non-goals

- **Merge agent (Phase 4b)** — deferred until negotiation proves insufficient
- **Automatic conflict resolution** — this PRD is about preventing conflicts through handoff, not resolving them
- **Multi-file atomic negotiation** — negotiate one file pattern at a time (simplicity)
- **Priority inheritance** — if Agent B urgently needs a file Agent A holds, we don't auto-escalate Agent A's other work
- **Persistent negotiation state** — negotiations live in Intermute messages; no new database tables

## Dependencies

- **Intermute service** — must be running (existing dependency, no changes to Intermute needed)
- **Interlock MCP server** — new tools added to existing binary
- **Pre-edit hook** — extended with inbox check (existing hook, additive change)
- **Intermute client library** (`plugins/interlock/client/` or Go client) — may need new helper methods

## Open Questions

1. **Should auto-release (F2) happen in pre-edit hook or as a separate periodic check?** Current design: pre-edit hook only (lazy). Risk: if agent stops editing, auto-release never fires. Mitigation: F5 escalation timeout covers this case.
2. **Should `negotiate_release` block until response or return immediately?** Current design: return immediately with thread_id. Blocking would be simpler for the caller but could stall the agent.
3. **What happens if both agents claim `urgent`?** Current design: first-come-first-served on timeout. Consider: human escalation flag for deadlock scenarios.
