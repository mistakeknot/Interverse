# Architecture Review: Intercore E5 — Discovery Pipeline PRD

**Reviewed:** 2026-02-20
**PRD:** `/root/projects/Interverse/docs/prds/2026-02-20-intercore-e5-discovery-pipeline.md`
**Reviewer role:** Flux-drive Architecture & Design Reviewer
**Mode:** Codebase-aware (grounded in `/root/projects/Interverse/infra/intercore`)

---

## Summary Verdict

The PRD is architecturally sound at the broad level. The "kernel owns state" invariant is correctly applied, and the schema design follows established conventions. However, there are five structural issues that need to be addressed before implementation begins. Three are must-fix (they will create ongoing maintenance debt or correctness problems); two are worth addressing but can be sequenced later.

---

## 1. Boundaries and Coupling

### 1a. Event Bus Extension: Third Leg is Structurally Sound But Implementation Has a Hidden Trap (must-fix)

The PRD proposes adding a third `UNION ALL` leg for `discovery_events` in `ListEvents` and `ListAllEvents` in `/root/projects/Interverse/infra/intercore/internal/event/store.go`.

The current UNION query signature is:

```go
// store.go:36-62
rows, err := s.db.QueryContext(ctx, `
    SELECT id, run_id, 'phase' AS source, event_type, from_phase, to_phase,
        COALESCE(reason, '') AS reason, created_at
    FROM phase_events
    WHERE run_id = ? AND id > ?
    UNION ALL
    SELECT id, COALESCE(run_id, '') AS run_id, 'dispatch' AS source, event_type,
        from_status, to_status, COALESCE(reason, '') AS reason, created_at
    FROM dispatch_events
    WHERE (run_id = ? OR ? = '') AND id > ?
    ORDER BY created_at ASC, source ASC, id ASC
    LIMIT ?`,
    runID, sincePhaseID,
    runID, runID, sinceDispatchID,
    limit,
)
```

The Event struct shape is:

```go
// event.go:26-35
type Event struct {
    ID        int64
    RunID     string
    Source    string     // "phase" or "dispatch"
    Type      string     // event_type
    FromState string     // from_phase or from_status
    ToState   string     // to_phase or to_status
    Reason    string
    Timestamp time.Time
}
```

The discovery events table proposed in F3 has `discovery_id` and `from_status/to_status` fields but **no `run_id`**. The current Event struct uses `RunID` as the join anchor for filtering in `ListEvents`. A discovery event has no run context — it is a different entity class.

**The trap:** If the discovery leg is force-fit into the same `Event` struct by setting `RunID = ''`, then `ListEvents(ctx, runID, ...)` will include discovery events for all users of that run ID (none, since discovery events have no run), but `ListAllEvents` will return discovery events interleaved with phase/dispatch events using the same `id` namespace for cursor tracking. Since `discovery_events.id` is an independent AUTOINCREMENT sequence, cursor advancement (`sinceDiscoveryID`) cannot use the same `sincePhaseID` or `sinceDispatchID` values — they are separate ID spaces.

The PRD acknowledges this with a third cursor flag `--since-discovery=N`, but the `loadCursor` and `saveCursor` functions in `/root/projects/Interverse/infra/intercore/cmd/ic/events.go` currently only persist `phase` and `dispatch` fields:

```go
// events.go:284-303
var cursor struct {
    Phase      int64 `json:"phase"`
    Dispatch   int64 `json:"dispatch"`
    Interspect int64 `json:"interspect"`
}
```

Note that `Interspect` is already in the cursor struct but is always written as `0` in `saveCursor` (line 310: `{"phase":%d,"dispatch":%d,"interspect":0}`). The `interspect` field is dead code. The PRD proposes a fourth cursor for discovery, but the cursor storage schema is already inconsistent.

**Resolution:** Before adding a discovery cursor, fix the interspect cursor dead code first. The cursor JSON struct and `saveCursor` should be made extensible with a map or version field, not a sequence of hard-coded named integers. Otherwise each new event source requires a breaking cursor format change and every consumer that stored `{"phase":N,"dispatch":M,"interspect":0}` will silently drop discovery events on first run after upgrade (the field will not exist and zero-value will be used, causing event replay from the beginning or a silent skip, depending on how the missing field is handled).

**Smallest fix:** Add `"discovery": 0` to the `cmdEventsCursorRegister` default payload and to `loadCursor`/`saveCursor`. Codify the cursor struct as the authoritative shape for all future sources. The existing `interspect` field should either be wired to real data or removed.

---

### 1b. Effective Score Computation: Kernel-Computed Derived Value Breaks Layer Boundary (must-fix)

F5 specifies:

> `decay_score` column; effective score = `relevance_score * decay_score`
> `ic discovery list` sorts by effective score by default

The `discoveries` table stores both `relevance_score` and `decay_score` as separate columns. The `effective_score` is a derived value computed at query time. The brainstorm describes it as "lazy decay computed at query time."

This is correct and aligns with existing patterns (e.g., `runs.phases` is decoded in Go at read time, not stored pre-decoded). However, the PRD does not specify where effective score is computed: in SQL (`relevance_score * decay_score`) or in Go. This matters because:

1. If computed in SQL: the `ORDER BY relevance_score * decay_score DESC` expression is correct but cannot use a simple index. Since the PRD explicitly plans for <10K rows this is acceptable, but it should be documented explicitly to prevent a future "optimization" that adds a computed effective_score column and creates update anomalies (two columns must always be updated together).

2. If computed in Go: the `ORDER BY` cannot be done in the database for the `list` command without fetching all rows and sorting in memory, which is acceptable at <10K but must be explicitly scoped as v1-only.

**The boundary issue:** The tier constants (`high >= 0.8`, `medium 0.5-0.8`, etc.) are called "constants in the store (kernel mechanism)" in F2. If tier is auto-computed from score and stored as a column (as the schema in the brainstorm shows `confidence_tier TEXT NOT NULL DEFAULT 'low'`), then tier and effective score must be kept consistent. The `ic discovery decay` command updates `decay_score` but there is no mention of whether tier gets re-evaluated after decay. A discovery that decays below its tier boundary is misleadingly labeled.

**Resolution:** Either (a) tier is always derived on read (remove `confidence_tier` column, compute in Go from effective score), or (b) `ic discovery decay` must re-evaluate and update `confidence_tier` alongside `decay_score`. Option (a) is simpler and eliminates the consistency hazard. The stored tier column is premature — it saves one multiplication per read at the cost of a persistent consistency obligation.

---

### 1c. Import Command Couples Kernel to Interject's Schema (must-fix)

F1 acceptance criteria include:

> `ic discovery import` one-time command — reads Interject SQLite, translates schema, emits events

This command, as described in the Resolved Decisions table, requires the kernel binary to open and read Interject's SQLite database. This directly couples the kernel (Go, `modernc.org/sqlite`, schema-versioned) to Interject's schema (Python, its own versioning). If Interject's schema changes, the import command either silently misreads data or fails hard.

This coupling also violates the existing design principle visible throughout the codebase: the kernel CLI is the only writer to the kernel DB, and external systems write to it via `ic` subcommands. The import command inverts this — the kernel reaches out to read another system's DB.

The brainstorm mentions "~59 discoveries" as the migration scope. This is a one-time operation over a small dataset.

**Resolution:** Remove `ic discovery import` from the kernel. Instead, provide a migration script in shell or Python that reads Interject's DB and calls `ic discovery submit` for each record. This preserves the kernel's single-ingestion-path invariant, keeps the import logic outside the kernel binary, and does not add Interject schema knowledge to kernel code. The script lives in `infra/intercore/scripts/` or in the Interject plugin itself. The kernel does not need to know Interject's schema exists.

---

### 1d. Feedback/Profile Tables Overlap With State Table (optional cleanup)

The `interest_profile` table stores a single row (id=1 constraint) with `topic_vector BLOB` and JSON weight fields. The `state` table already supports single-value storage with namespace-scoped keys, expiration, and JSON payload validation.

The interest profile is a logical fit for `state` with key `discovery.profile` and no expiration. The only thing `state` cannot currently hold is a BLOB (the topic vector). If the topic vector is omitted from the interest profile (Interject already owns the vector model; the kernel only needs the scalar weight maps), the `interest_profile` table is redundant with `state`.

This is marked optional because the single-row table pattern is established in the codebase (interspect uses a similar pattern) and the BLOB requirement is genuinely different from the state table's JSON-only payload.

**However**, if the topic vector is included, there is a second concern: the `state.ValidatePayload` function enforces a 1MB limit and full JSON validation on all state writes. A BLOB stored as base64 in JSON would consume roughly 4KB for a 1024-dim float32 vector and would pass the JSON validator — but this is an unusual use of the state table and may confuse future maintainers.

---

## 2. Pattern Analysis

### 2a. Gate Integration: Discovery Tier Gate Does Not Fit Existing Gate Mechanism (must-fix)

The existing gate mechanism in `/root/projects/Interverse/infra/intercore/internal/phase/gate.go` is structured around `(from_phase, to_phase)` transitions on a run. The `gateRules` map takes a `[2]string{from, to}` key and returns a list of checks (`CheckArtifactExists`, `CheckAgentsComplete`, `CheckVerdictExists`).

The discovery promotion gate is a different kind of gate: it is a precondition on a `discovery` operation, not on a `run` phase transition. Specifically:

```
ic discovery promote <id> --bead-id=<bid>
→ kernel checks: tier >= 'medium' before allowing promotion
```

This is an entity-level precondition (does this discovery meet minimum confidence?) rather than a workflow gate (has this run completed the required prior phase?). Forcing this into the existing `gateRules` map would require either:
- Fake phase names like `"discovery.new"` → `"discovery.promoted"` in the map, which pollutes the phase namespace
- A new parallel gate mechanism only for discoveries

The PRD proposes a "new gate type: `discovery_tier_gate`" but does not specify where it lives. The brainstorm references it as `GateConfig`-based, which is the existing phase gate config struct.

**The pattern issue:** The existing `GateConfig` and `evaluateGate` function operate in the `phase` package, which is about run phase transitions. Adding discovery gates to the `phase` package would violate the package's single responsibility. Adding them to a new `discovery` package is correct, but then the gate override mechanism (`--force` flag with audit trail) needs to be implemented twice, once per gate type.

**Resolution:** Define the discovery confidence gate as a standalone precondition check inside the discovery store/command layer, not as an extension of the phase gate mechanism. It is a simple numeric comparison: `if discovery.EffectiveScore() < threshold { return ErrGateBlocked }`. The gate override (`--force` + audit event) follows the same pattern as `ic gate override` but is local to the discovery subcommand. Do not reuse or extend `GateConfig` for this. The phase gate mechanism should remain focused on phase transitions.

---

### 2b. `ic discovery rollback` Belongs to E6, Not E5 (scope creep)

F5 acceptance criteria includes:

> `ic discovery rollback --source=<s> --since=<ts>` proposes cleanup of discoveries (closes E6 gap)

The PRD notes this "closes E6 gap." The E6 rollback PRD exists separately at `/root/projects/Interverse/docs/plans/2026-02-20-intercore-rollback-recovery.md`. Including rollback functionality in E5 means the E5 implementation must anticipate E6's rollback semantics before E6 is designed in detail. Rollback for discoveries is meaningfully different from rollback for runs (a run rollback rewinds a phase pointer; a discovery rollback proposes cleanup of records — a much softer operation).

The `--force` flag with audit trail on `ic discovery promote` is also borrowed from the gate override pattern, but the existing `ic gate override` command (`/root/projects/Interverse/infra/intercore/cmd/ic/gate.go`) writes an event to `phase_events` with event_type `override`. The discovery override audit trail goes to `discovery_events`, which is not yet defined. This is consistent, but it needs to be explicit in the acceptance criteria.

**Resolution:** Remove `ic discovery rollback` from F5. Mark it as a deferred item for E6 with a note explaining what information the discovery schema should preserve to enable a future rollback command. The discovery schema already has enough (source, timestamp, status) for E6 to build on without pre-implementing rollback semantics in E5.

---

### 2c. `generateID` Duplication Across Packages

The `generateID()` function is duplicated in:
- `/root/projects/Interverse/infra/intercore/internal/phase/store.go` (line 28)
- `/root/projects/Interverse/infra/intercore/internal/dispatch/dispatch.go` (line 85)

A new `discovery` package would add a third copy. This is the established pattern in this codebase and appears to be an intentional choice (each package is self-contained). This review notes it as a pattern observation: if a `discovery` store package is added, it should follow the same convention rather than importing from another package, unless the team decides this is the inflection point to extract a shared `id` utility.

This is not a must-fix: the duplication is bounded, and the function is trivially small. Extracting it is optional cleanup.

---

## 3. Simplicity and YAGNI

### 3a. `feedback_signals` Table Is Premature Without a Consumer

F4 defines `feedback_signals` with five signal types (`promote`, `dismiss`, `adjust_priority`, `boost`, `penalize`) and a `--data=@file` JSON payload. The table also emits `feedback.recorded` events.

The stated purpose is "closed-loop learning" — the interest profile updates based on feedback. However:

- The interest profile update logic (which keywords to boost, which sources to penalize) is explicitly a non-goal: "Scoring algorithms beyond tier assignment (OS/Interject policy)"
- The only concrete action for feedback signals is updating `keyword_weights` and `source_weights` via `ic discovery profile update`

This means `feedback_signals` is an event log for a learning process that the kernel does not implement. The kernel stores feedback but does not act on it. The feedback consumer (Interject) would need to poll for feedback events, apply its own scoring logic, and call `ic discovery profile update` with the result.

This is a viable design, but the `feedback_signals` table with five signal types and a JSON payload field is overengineered for what the kernel actually does: emit a `feedback.recorded` event and store a row. The same result could be achieved with `ic discovery feedback <id> --signal=promote` writing directly to `discovery_events` as a `discovery.feedback` event, without a separate table.

A separate `feedback_signals` table is justified if:
- The kernel queries feedback signals to make decisions (it does not, per the non-goals)
- Feedback signals need independent indexing beyond what events provide (no such query pattern is defined)
- The signal history needs to outlive discovery events (no such retention difference is specified)

**Resolution:** Collapse `feedback_signals` into `discovery_events`. Add `feedback.recorded` as a new event type. Store the signal type in `event_type` (e.g., `feedback.promote`, `feedback.dismiss`) and the signal data in `payload`. Remove the `feedback_signals` table and `ic discovery feedback` command; replace with a discovery event write. This reduces the schema by one table and one CLI subcommand with no loss of capability.

---

### 3b. Two-Score Design Adds Permanent Arithmetic to Every Query

The `relevance_score * decay_score` effective score model means every list, search, and gate evaluation must multiply two floats. This is not a performance concern — it is a cognitive load concern. Every future developer working on discovery queries must remember to use `relevance_score * decay_score`, not `relevance_score`. The column name `decay_score` does not make this multiplication obvious.

An alternative: when `ic discovery decay` runs, it updates `relevance_score` directly (multiplicative update) and removes `decay_score` entirely. This makes `relevance_score` always mean "current relevance" without a separate multiplier. The decay operation would be:

```sql
UPDATE discoveries
SET relevance_score = relevance_score * ?
WHERE discovered_at < ? AND status NOT IN ('promoted', 'dismissed')
```

The argument against this is loss of the original score. But the brainstorm and PRD do not describe any use case that requires recovering the pre-decay original score. The `discovery_events` table already provides an audit trail of score changes via `discovery.scored` and `discovery.decayed` events.

This is a simplification that reduces one column, eliminates the derived-value consistency problem from issue 1b, and makes queries and gates unambiguous. It is not a must-fix, but it directly resolves the consistency issue raised in 1b.

---

## Issues Summary

| # | Severity | Finding |
|---|----------|---------|
| 1a | Must-fix | Third cursor leg will silently break consumer delivery because `interspect` cursor is already dead code; all cursor fields must be wired before adding a fourth |
| 1b | Must-fix | `confidence_tier` stored column is inconsistent with lazy decay; tier must be derived-on-read or re-evaluated on every decay run |
| 1c | Must-fix | `ic discovery import` couples kernel binary to Interject's schema; replace with external migration script calling `ic discovery submit` |
| 2a | Must-fix | Discovery confidence gate must not extend the phase gate mechanism; implement as a standalone precondition in the discovery command layer |
| 1d | Optional | `interest_profile` table overlaps with `state` table if BLOB is removed; evaluate whether the kernel needs the topic vector at all |
| 2b | Optional | `ic discovery rollback` belongs to E6, not E5; remove from F5 acceptance criteria |
| 2c | Note | `generateID` duplication is consistent with existing pattern; no action required unless team wants to extract at this point |
| 3a | Optional | `feedback_signals` table is premature; collapse into `discovery_events` to reduce schema surface |
| 3b | Optional | Two-score design adds permanent query arithmetic; simplify by applying decay directly to `relevance_score` |

---

## Migration Path (v8 to v9)

The existing migration code in `/root/projects/Interverse/infra/intercore/internal/db/db.go` uses incremental `ALTER TABLE` stmts for column additions and a full DDL apply for new tables. For v9, three new tables are created in a single migration block. This follows the established pattern and has no structural issues.

One note: the `_migrate_lock` table used for exclusive migration lock is never cleaned up (it is created with `CREATE TABLE IF NOT EXISTS` and never dropped). This is intentional as a migration guard and matches the existing code. The v9 migration should not change this behavior.

The pre-migration backup (timestamped copy of the DB file) already fires automatically via `Migrate()` for any non-empty DB. This is confirmed by the existing code at line 106-111 in `db.go` and requires no changes for v9.

---

## Contract with Interject

The PRD states "Interject becomes a scanner that writes to the kernel." This requires Interject (Python) to shell out to `ic discovery submit` for each discovery write. This is consistent with how other plugins interact with the kernel (the shell-based lib-intercore.sh wrappers do exactly this).

The contract boundary is clean: Interject is responsible for embedding computation, scoring, and scan scheduling. The kernel is responsible for storage, event emission, gate enforcement, and dedup. No changes to this boundary are needed.

The one risk is embedding size. At 1024-dim float32, each embedding is 4096 bytes. Passing embeddings to `ic discovery submit` via `--embedding=@file` (a temp file path) is the correct approach and avoids command-line argument length limits. This pattern should be explicitly required in the CLI spec, not left as an option alongside passing embeddings directly as a flag value.
