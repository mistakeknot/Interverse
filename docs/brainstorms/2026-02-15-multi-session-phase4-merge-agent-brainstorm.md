# Phase 4: Merge Review Agent & Reservation Negotiation
**Phase:** brainstorm (as of 2026-02-15T16:41:51Z)

**Date:** 2026-02-15
**Status:** Brainstorm
**Predecessor:** Phases 1-3 of multi-session coordination (commits `8009474`, `6a5f794`, `e6afb46`)
**Question:** When two agents hit a merge conflict or need to hand off file ownership, how should resolution work?

---

## Problem Statement

Phase 3 shipped auto-pull with fail-open abort: when Agent B tries to pull Agent A's commit and hits a rebase conflict, it aborts the rebase, warns the agent, and proceeds with the edit. The conflict is surfaced but **not resolved**. Two gaps remain:

1. **Conflict resolution** — who resolves the conflict, how, and when?
2. **Reservation negotiation** — Agent B needs a file Agent A holds; currently the only option is "wait for TTL expiry" or `request_release` (which Agent A may never see)

## Current State (After Phase 3)

| Capability | Status | Notes |
|-----------|--------|-------|
| Conflict prevention | Strong | Exclusive reservations, blocking edit hook, per-session index |
| Conflict detection | Done | Auto-pull detects rebase failure, warns via `additionalContext` |
| Conflict resolution | Missing | Abort + warn is the only path |
| Reservation negotiation | Minimal | `request_release` MCP tool exists but is fire-and-forget |
| Work overlap detection | Done | Bead-agent-bind warns on duplicate claims |

## Idea 1: Dedicated Merge Review Agent

A persistent long-running session (or Intermute-triggered on-demand agent) that watches for conflict signals and resolves them autonomously.

### How It Would Work

1. Agent B's pre-edit hook detects rebase failure, aborts, sends `conflict:<details>` message to a well-known `merge-agent` Intermute agent
2. Merge agent receives the message, checks out a temporary branch from the conflicting state
3. Merge agent reads both sides' changes, understands intent, produces resolution
4. Merge agent commits the merge, broadcasts `merge-resolved:<hash>` to both original agents
5. Original agents auto-pull the resolution on their next edit

### Challenges

- **Semantic correctness** — merge conflicts in code require understanding intent, not just textual reconciliation. An LLM is better than `git merge -X theirs` but can still introduce subtle bugs.
- **Scope creep** — the merge agent needs to understand the codebase well enough to produce correct merges. This is essentially a code review + authoring task.
- **Timing** — by the time the merge agent resolves the conflict, both original agents may have moved on, making the merge resolution stale.
- **Trust** — both agents need to accept the merge agent's resolution without re-reviewing it, or the overhead of review cancels the benefit.
- **Resource cost** — a persistent session consumes a context window slot. On-demand is cheaper but slower.

### When This Makes Sense

- Large parallel sessions (3+ agents) where conflict probability is higher
- Long-running sessions (hours) where TTL-based reservation release is too slow
- Projects with high file coupling where agents inevitably touch shared files

## Idea 2: Reservation Negotiation Protocol

Instead of automated merge resolution, make reservation handoff a first-class protocol.

### How It Would Work

1. Agent B needs `config.ts` which Agent A holds
2. Agent B sends `request_release` with a `priority` and `reason`
3. Agent A's next pre-edit hook sees the request, evaluates:
   - If Agent A is done with the file: release immediately
   - If Agent A has uncommitted changes: finish current edit, commit, then release
   - If Agent A is mid-feature: reply with estimated completion time
4. Agent B gets the response and either waits, works on something else, or escalates

### Protocol Messages

```
request_release  → {file, requester, priority, reason}
release_ack      → {file, released: true}
release_defer    → {file, released: false, eta_minutes: N, reason}
release_escalate → {file, requester, priority: "urgent"}
```

### Advantages Over Merge Agent

- **Simpler** — no conflict resolution logic, just coordination
- **Correct by construction** — Agent A commits clean work before releasing; no merge needed
- **Already partially built** — `request_release` MCP tool exists, just needs protocol on the response side
- **Lower overhead** — no extra session required

## Idea 3: Hybrid — Negotiation Default, Merge Agent Escalation

Use reservation negotiation (Idea 2) as the primary mechanism. Only spin up a merge agent when:

- Negotiation fails (both agents claim urgency)
- A rebase conflict actually occurs (auto-pull failure)
- Human requests conflict resolution (`/interlock:resolve-conflict`)

This keeps the common path lightweight and reserves heavy machinery for rare cases.

## Recommendation

**Start with Idea 2 (Reservation Negotiation Protocol).** Reasons:

1. **Conflicts are rare** — Phase 1-3's reservation system prevents most conflicts. The remaining gap is *handoff*, not *resolution*.
2. **Negotiation is the 80% solution** — most "conflicts" are really "I need a file someone else is holding." Clean handoff avoids the conflict entirely.
3. **Merge agent can come later** — once negotiation is proven, the escalation path (Idea 3) naturally leads to a merge agent if needed.
4. **Low implementation cost** — mostly wire-up of existing primitives (intermute messaging + pre-edit hook response handling).

## Implementation Sketch (If Pursued)

### Phase 4a: Reservation Negotiation
- Add `release_ack` / `release_defer` message types to Intermute
- Pre-edit hook checks for `request_release` messages, auto-releases if file is clean
- New MCP tool: `negotiate_release(file, urgency, reason)` — structured request with callback
- Sprint scan shows pending release requests

### Phase 4b: Merge Agent (If Needed)
- New Clavain agent: `merge-resolver`
- Triggered by `conflict:` messages or `/interlock:resolve-conflict` command
- Uses tldr-swinton for efficient context gathering on conflicting files
- Posts resolution as a commit with `Merge-Agent: <details>` trailer
- Both original agents auto-pull on next edit (Phase 3 infrastructure)

## Open Questions

1. Should the merge agent be a persistent session or on-demand? Persistent is faster but wastes resources when idle.
2. Should reservation negotiation be automatic (pre-edit hook handles it) or manual (agent decides via MCP tool)?
3. What's the right escalation timeout? If Agent A doesn't respond to `request_release` in N minutes, should we auto-release?
4. Should the merge agent have authority to force-release reservations, or only resolve textual conflicts?
