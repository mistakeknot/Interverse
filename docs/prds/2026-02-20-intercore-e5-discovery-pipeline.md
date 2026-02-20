# PRD: Intercore E5 — Discovery Pipeline

**Bead:** iv-fra3
**Date:** 2026-02-20
**Status:** Draft
**Brainstorm:** [brainstorm](../brainstorms/2026-02-20-intercore-e5-discovery-pipeline-brainstorm.md)

---

## Problem

Discovery and research intake live entirely in Interject (Python plugin, its own SQLite DB). The kernel has no visibility into what's being discovered, no ability to gate promotions by confidence, and no event trail for Interspect to learn from. This blocks the autonomy ladder: the system can execute work (L2) and self-improve (L3) but can't autonomously find new work (L-1).

## Solution

Add discovery as a first-class kernel subsystem — tables, CRUD, events, feedback, gates, and search — following the same patterns as runs and dispatches. Interject becomes a scanner that writes to the kernel; the kernel owns the durable record.

## Resolved Decisions

| Question | Decision | Rationale |
|----------|----------|-----------|
| Storage ownership | Kernel owns discovery records (Approach A) | "Kernel owns state" invariant; enables gate enforcement |
| Embedding format | Pre-computed, caller-provided | Keeps kernel ML-free; Interject/intersearch own the model |
| Embedding storage | BLOB in `discoveries` table | 4KB/row at 1024-dim float32; acceptable up to ~10K rows |
| Vector search | Brute-force cosine in Go (v1) | No C dependency; sufficient for <10K; sqlite-vec deferred to v2 |
| Schema version | v9 (current is v8) | Single migration adds all three tables |
| Event integration | Third `UNION ALL` leg in event queries | Matches existing phase/dispatch dual-cursor pattern |
| Migration from Interject | External script calling `ic discovery submit` | Keeps kernel's single-ingestion-path invariant; no Interject schema coupling |
| Decay model | Apply decay directly to `relevance_score` (no separate `decay_score`) | Avoids dual-score arithmetic; tier is always derived from one number |
| Dedup atomicity | `BEGIN IMMEDIATE` for similarity check + insert | Prevents TOCTOU between concurrent `ic discovery submit` processes |
| Promote atomicity | `UPDATE ... WHERE relevance_score >= ?` | Prevents gate bypass from concurrent score updates |

## Features

### F1: Discovery Schema + Migration

**What:** Add `discoveries`, `feedback_signals`, and `interest_profile` tables to the kernel database at schema version 9.

**Acceptance criteria:**
- [ ] `ic init` migrates from v8 → v9, creating all three tables with indexes
- [ ] Schema uses integer timestamps (kernel convention), TEXT id with generated short IDs
- [ ] `UNIQUE(source, source_id)` constraint prevents duplicate source entries
- [ ] Pre-migration backup created automatically (existing behavior)
- [ ] `ic health` reports schema v9
- [ ] `ic version` shows updated schema version
- [ ] Existing v8 databases open successfully after migration
- [ ] All existing integration tests pass unchanged

### F2: Discovery CRUD CLI

**What:** `ic discovery submit/status/list/score/promote/dismiss` commands for managing discovery lifecycle.

**Acceptance criteria:**
- [ ] `ic discovery submit --source=<s> --source-id=<sid> --title=<t>` creates record, prints ID
- [ ] `ic discovery submit` accepts `--summary`, `--url`, `--embedding=@file`, `--score=N`, `--metadata=@file`
- [ ] `ic discovery status <id>` prints discovery details (JSON with `--json`)
- [ ] `ic discovery list` filters by `--source`, `--status`, `--tier`, `--limit`
- [ ] `ic discovery score <id> --score=<0.0-1.0>` updates relevance score and recomputes tier
- [ ] `ic discovery promote <id> --bead-id=<bid>` sets status=promoted, records bead link
- [ ] `ic discovery dismiss <id>` sets status=dismissed
- [ ] Tier auto-computed from score: high (>=0.8), medium (0.5-0.8), low (0.3-0.5), discard (<0.3)
- [ ] Tier boundaries are constants in the store (kernel mechanism) — OS can override via score manipulation
- [ ] Exit codes: 0=success, 1=not found, 2=error (matches existing convention)
- [ ] 10+ integration tests covering CRUD operations

### F3: Discovery Events

**What:** Discovery lifecycle events flow through the kernel event bus alongside phase and dispatch events.

**Acceptance criteria:**
- [ ] `discovery_events` table with: id, discovery_id, event_type, from_status, to_status, payload (JSON), created_at
- [ ] Events emitted on: submit, score, promote, propose, dismiss, decay
- [ ] Event types: `discovery.submitted`, `discovery.scored`, `discovery.promoted`, `discovery.proposed`, `discovery.dismissed`, `discovery.decayed`
- [ ] `ListEvents` and `ListAllEvents` include discovery events via third `UNION ALL` leg
- [ ] `ic events tail` shows discovery events alongside phase/dispatch events
- [ ] Third cursor (`--since-discovery=N`) for consumer-based consumption
- [ ] `ic events cursor list` shows discovery cursor alongside phase/dispatch cursors
- [ ] Events visible to Interspect as durable consumer
- [ ] 8+ integration tests covering event emission and consumption

### F4: Feedback + Interest Profile

**What:** Record feedback signals (promote, dismiss, adjust) and maintain an interest profile for closed-loop learning.

**Acceptance criteria:**
- [ ] `ic discovery feedback <id> --signal=<type> --actor=<name>` records signal
- [ ] Signal types: promote, dismiss, adjust_priority, boost, penalize
- [ ] `--data=@file` accepts JSON payload for signal metadata
- [ ] `feedback.recorded` event emitted on each feedback signal
- [ ] `ic discovery profile` shows current interest profile (keyword weights, source weights)
- [ ] `ic discovery profile update --keyword-weights=@file --source-weights=@file` updates profile
- [ ] Profile stored as single row (id=1 constraint) with BLOB topic vector + JSON weights
- [ ] 6+ integration tests

### F5: Tier Gates + Dedup + Decay

**What:** Kernel-enforced confidence gates on promotion, embedding-based dedup on submit, and lazy staleness decay.

**Acceptance criteria:**
- [ ] `ic discovery promote` rejects if tier < configurable minimum (default: medium, score >= 0.5)
- [ ] Rejection prints: `gate blocked: confidence <score> below promotion threshold <threshold>`
- [ ] `--force` flag overrides gate with audit trail (like `ic gate override`)
- [ ] On submit with `--dedup-threshold=<0.0-1.0>`: cosine similarity check against same-source discoveries
- [ ] If similarity > threshold: returns existing discovery ID instead of creating new, emits `discovery.deduped`
- [ ] `ic discovery decay --rate=<0.0-1.0> --min-age=<dur>` applies multiplicative decay directly to `relevance_score`
- [ ] Decay updates `relevance_score` in-place and recomputes tier; no separate decay column
- [ ] `ic discovery list` sorts by `relevance_score` by default
- [ ] `ic discovery rollback --source=<s> --since=<ts>` proposes cleanup of discoveries (closes E6 gap)
- [ ] 10+ integration tests covering gates, dedup, decay, rollback

### F6: Embedding Search

**What:** `ic discovery search` with brute-force cosine similarity for finding related discoveries.

**Acceptance criteria:**
- [ ] `ic discovery search --embedding=@file` finds top-N similar discoveries by cosine distance
- [ ] `--limit=N` controls result count (default 10)
- [ ] `--source`, `--tier`, `--status` filters apply before similarity ranking
- [ ] `--min-score=<0.0-1.0>` filters out low-similarity results
- [ ] Results include: id, title, source, score, similarity, tier
- [ ] Cosine similarity computed in Go (no C dependency)
- [ ] Handles missing embeddings gracefully (skips rows with NULL embedding)
- [ ] Performance acceptable for <10K rows (brute-force scan)
- [ ] 5+ integration tests

## Non-goals

- Scan scheduling or trigger modes (OS/Interject policy)
- Scoring algorithms beyond tier assignment (OS/Interject policy)
- Autonomy tier actions (what to do at each tier — Clavain policy)
- Background decay daemon (decay is explicit, not automatic)
- sqlite-vec or other native vector extensions (v2 optimization)
- Web UI for discovery browsing (Autarch concern)
- Embedding model selection or Ollama integration (intersearch/Interject concern)

## Dependencies

- Intercore schema v8 (current) — migration builds on top
- Existing event bus pattern (phase_events + dispatch_events UNION)
- Existing gate evaluation pattern (for tier enforcement)
- `modernc.org/sqlite` v1.29.0 (BLOB support for embeddings)

## Open Questions

None — all resolved in brainstorm and above decisions table.
