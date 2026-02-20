# Intercore E5: Discovery Pipeline — Kernel Primitives for Research Intake

**Bead:** iv-fra3
**Phase:** brainstorm (as of 2026-02-20T19:53:42Z)
**Date:** 2026-02-20
**Status:** Draft

---

## Problem

The kernel (Intercore) tracks workflow state — runs, phases, gates, dispatches, tokens — but has no concept of *where work comes from*. Discovery and research intake currently live entirely in Interject (a Python MCP plugin) with its own SQLite database, its own schema, and no kernel events. This creates three problems:

1. **No auditability.** When Interject promotes a discovery to a bead, there's no kernel event. Interspect can't see it. The decision trail is invisible to the durable event bus.
2. **No enforcement.** Confidence tiers (high/medium/low/discard) are Interject-internal. Nothing stops a low-confidence discovery from being promoted. The kernel can't gate promotions.
3. **No closed loop.** Feedback signals (promote/dismiss) update Interject's interest profile but don't flow through the kernel event bus. Interspect can't learn from discovery outcomes.

E5 builds the kernel primitives that Interject (and future scanners) write to, so discovery becomes a first-class kernel concern with events, gates, and feedback — the same treatment runs and dispatches already get.

## Current State

### What Interject Already Has (Python, its own DB)

| Table | Purpose |
|-------|---------|
| `discoveries` | source, title, summary, url, embedding (BLOB), relevance_score, confidence_tier, status |
| `promotions` | discovery_id → bead_id mapping with priority |
| `interest_profile` | topic_vector (BLOB), keyword_weights, source_weights |
| `scan_log` | source, items_found, items_above_threshold |
| `feedback_signals` | discovery_id, signal_type, signal_data, session_id |
| `query_log` | query_text, query_embedding, session_id |

Schema v2, WAL mode, 1024-dim embeddings via Ollama (all-MiniLM-L6-v2 re-exported from intersearch).

### What the Kernel Needs to Provide (Go, intercore.db)

The vision doc specifies:
- **Discovery records** with embeddings, source metadata, confidence scores, lifecycle state
- **Confidence-tiered action gates** (auto-execute, propose-to-human, log-only, discard)
- **Discovery events** (scanned, scored, promoted, proposed, dismissed)
- **Backlog events** (refined, merged, submitted, prioritized)
- **Feedback ingestion** that updates interest profile
- **Dedup threshold enforcement** (embedding similarity at scan time)
- **Staleness decay** (lazy computation at query time)

## Key Design Question: Mirror vs. Ingest

Two approaches to getting Interject data into the kernel:

### Approach A: Kernel Owns Discovery Storage (Recommended)

Interject calls `ic discovery submit` to write discoveries directly to the kernel DB. Interject becomes a scanner that *produces* discoveries; the kernel *stores, scores tiers, and emits events* for them.

**Pros:**
- Single source of truth for discovery state
- All events flow through the kernel bus (Interspect sees everything)
- Gate enforcement is kernel-native (can't bypass)
- Interject's own DB becomes a cache/staging area, not the record of truth

**Cons:**
- Embedding storage in SQLite (BLOBs) is large — need to consider DB size
- Interject must shell out to `ic` (Python → Go CLI) for writes
- Migration path: Interject's existing DB has historical data to import

### Approach B: Interject Owns Storage, Kernel Gets Events

Interject keeps its own DB. It calls `ic discovery event` to emit events (scanned, promoted, etc.) to the kernel bus without the kernel storing the full discovery record.

**Pros:**
- No embedding storage in kernel DB
- Interject's Python stack handles vector operations natively
- Simpler kernel scope — just events, no BLOB management

**Cons:**
- Split source of truth — discovery data in Interject's DB, events in kernel DB
- Gate enforcement requires Interject cooperation (kernel can't see the data)
- Dedup and decay need Interject's DB, not kernel's

**Decision: Approach A.** The kernel must be the durable system of record. "The kernel owns state" is the foundational invariant — discovery state is no different from run state. Interject can keep a local cache for fast embedding lookups, but promotions, tier changes, and lifecycle transitions must go through the kernel.

## What to Build

### Kernel Schema: `discoveries` Table

```sql
CREATE TABLE IF NOT EXISTS discoveries (
    id              TEXT PRIMARY KEY,
    source          TEXT NOT NULL,
    source_id       TEXT NOT NULL,
    title           TEXT NOT NULL,
    summary         TEXT NOT NULL DEFAULT '',
    url             TEXT NOT NULL DEFAULT '',
    raw_metadata    TEXT NOT NULL DEFAULT '{}',
    embedding       BLOB,
    relevance_score REAL NOT NULL DEFAULT 0.0,
    confidence_tier TEXT NOT NULL DEFAULT 'low',
    status          TEXT NOT NULL DEFAULT 'new',
    run_id          TEXT,
    bead_id         TEXT,
    discovered_at   INTEGER NOT NULL DEFAULT (unixepoch()),
    promoted_at     INTEGER,
    reviewed_at     INTEGER,
    UNIQUE(source, source_id)
);
```

Key differences from Interject's schema:
- `run_id` — links to a kernel run (when discovery triggers work)
- `bead_id` — links to a bead (when promoted to backlog)
- No separate `decay_score` — decay applies directly to `relevance_score` (avoids dual-score arithmetic)
- Integer timestamps (kernel convention) vs datetime strings

### Kernel Schema: `feedback_signals` Table

```sql
CREATE TABLE IF NOT EXISTS feedback_signals (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    discovery_id    TEXT NOT NULL REFERENCES discoveries(id),
    signal_type     TEXT NOT NULL,
    signal_data     TEXT NOT NULL DEFAULT '{}',
    actor           TEXT NOT NULL DEFAULT 'system',
    created_at      INTEGER NOT NULL DEFAULT (unixepoch())
);
```

### Kernel Schema: `interest_profile` Table

```sql
CREATE TABLE IF NOT EXISTS interest_profile (
    id              INTEGER PRIMARY KEY CHECK (id = 1),
    topic_vector    BLOB,
    keyword_weights TEXT NOT NULL DEFAULT '{}',
    source_weights  TEXT NOT NULL DEFAULT '{}',
    updated_at      INTEGER NOT NULL DEFAULT (unixepoch())
);
```

### CLI Surface: `ic discovery`

```
ic discovery submit   --source=<s> --source-id=<sid> --title=<t> [--summary] [--url] [--embedding=@file] [--score=N] [--metadata=@file]
ic discovery score    <id> --score=<0.0-1.0> [--reason=<text>]
ic discovery promote  <id> --bead-id=<bid> [--priority=N]
ic discovery dismiss  <id> [--reason=<text>]
ic discovery search   --query=<text> [--embedding=@file] [--source=<s>] [--tier=<high|medium|low>] [--limit=N]
ic discovery list     [--source=<s>] [--status=<s>] [--tier=<t>] [--limit=N]
ic discovery status   <id>
ic discovery decay    --rate=<0.0-1.0> [--min-age=<dur>]
ic discovery rollback --source=<s> --since=<ts>    (E6 deferred item)
ic discovery feedback <id> --signal=<type> [--data=@file] [--actor=<name>]
ic discovery profile  [--json]                     (show current interest profile)
ic discovery profile  update --keyword-weights=@file --source-weights=@file
```

### Events (through existing event bus)

| Event | When | Payload |
|-------|------|---------|
| `discovery.submitted` | New discovery written | id, source, title, score |
| `discovery.scored` | Confidence score updated | id, old_score, new_score, tier |
| `discovery.promoted` | Promoted to bead | id, bead_id, priority |
| `discovery.proposed` | Medium-tier, needs human review | id, title, summary |
| `discovery.dismissed` | Dismissed by human or decay | id, reason |
| `discovery.decayed` | Decay operation ran | count, rate |
| `feedback.recorded` | Feedback signal recorded | discovery_id, signal_type |

### Gate Integration

New gate type: `discovery_tier_gate` — checks that a discovery's confidence tier meets the minimum for the requested action (promote, auto-execute, etc.). Tier boundaries are configuration, not kernel defaults.

```
ic gate check <run_id>  # existing — unchanged
# New: promotion gate
ic discovery promote <id> --bead-id=<bid>
# → kernel checks: tier >= 'medium' (configurable) before allowing promotion
# → if tier too low: exit 1 + "gate blocked: confidence 0.35 below promotion threshold 0.50"
```

### Dedup Enforcement

On `ic discovery submit`, the kernel checks embedding similarity against existing discoveries for the same source:
- If similarity > threshold: link as evidence to existing, emit `discovery.deduped` event
- If no match: create new record

Threshold is provided by the caller (OS policy), not hardcoded in the kernel.

## What NOT to Build (v1)

- **Scan scheduling** — OS policy (Interject/Clavain decide when to scan)
- **Scoring algorithms** — OS policy (Interject computes scores, kernel stores them)
- **Autonomy tier actions** — OS policy (what happens at each tier is Clavain's decision)
- **Embedding model** — Interject/intersearch own the embedding model choice
- **Background decay process** — decay is lazy (computed at query time), not a daemon
- **Web UI for discovery** — Autarch concern, not kernel

## Implementation Phases

### Phase 1: Schema + CRUD (foundation)
- `discoveries` table + migration
- `ic discovery submit/status/list` commands
- Integration tests

### Phase 2: Events + Feedback
- Discovery events through event bus
- `feedback_signals` table + `ic discovery feedback`
- `interest_profile` table + `ic discovery profile`

### Phase 3: Gates + Dedup + Decay
- Confidence tier gate enforcement on promote
- Embedding similarity dedup on submit
- Lazy decay at query time
- `ic discovery rollback` (closes E6 gap)

### Phase 4: Search
- `ic discovery search` with embedding similarity
- Source and tier filtering

## Open Questions

1. **Embedding storage size:** 1024-dim float32 = 4KB per discovery. At 1000 discoveries, that's 4MB of BLOBs. At 10K, 40MB. Is this acceptable for a SQLite WAL DB that's also handling runs/dispatches/events?

2. **Embedding computation:** Should the kernel accept pre-computed embeddings (from Interject) or compute them itself? Pre-computed keeps the kernel simpler (no ML dependency) but requires the caller to provide them.

3. **Search implementation:** SQLite doesn't have native vector search. Options: (a) brute-force cosine similarity in Go (fine for <10K), (b) sqlite-vec extension (maintained, but adds a C dependency), (c) defer search to Interject (keeps kernel simple).

4. **Migration path:** How do we move Interject's existing ~59 discoveries into the kernel DB? One-time `ic discovery import --from=<interject-db-path>`?

## Success Criteria

1. `ic discovery submit` writes a discovery record and emits `discovery.submitted` event
2. `ic discovery promote` enforces tier gate and emits `discovery.promoted` event
3. `ic discovery dismiss` records dismissal and emits `discovery.dismissed` event
4. `ic discovery feedback` records signal and emits `feedback.recorded` event
5. `ic discovery list` filters by source, status, tier
6. Events visible via `ic events tail --all` alongside phase/dispatch events
7. Interspect can consume discovery events as a durable consumer
8. Dedup prevents duplicate discoveries from same source
9. Decay reduces relevance of stale discoveries at query time
10. All existing integration tests pass, 20+ new tests cover discovery
