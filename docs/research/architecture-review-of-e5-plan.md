# Architecture Review: Intercore E5 Discovery Pipeline Implementation Plan

**Date:** 2026-02-20
**Plan file:** `docs/plans/2026-02-20-intercore-e5-discovery-pipeline.md`
**Reviewer:** Flux Architecture & Design Reviewer
**Codebase context:** Codebase-aware mode — grounded in `internal/db/db.go`, `internal/event/store.go`, `internal/phase/gate.go`, `cmd/ic/main.go`, and the existing findings format from `infra/intercore/.clavain/quality-gates/`

---

## Verdict: needs-changes

The plan is structurally sound at the macro level. The package layout, migration strategy, and CRUD lifecycle align cleanly with what the kernel already does. However there are four issues that, if not corrected before implementation, will produce structural debt or runtime correctness failures. Two are architectural blockers; two are significant but correctable during execution.

---

## 1. Boundaries & Coupling

### B1 — CRITICAL: Promote gate enforcement is implemented in the store, not as a transaction-safe atomic SQL predicate, creating a TOCTOU window

**Task 4, "Step 3: Implement Score, Promote, Dismiss"** describes `Promote` as:

> `UPDATE discoveries SET status='promoted', bead_id=?, promoted_at=? WHERE id=? AND relevance_score >= ?` (atomic gate)

This is the correct pattern for atomicity — the WHERE clause on `relevance_score` is the gate. However, the `force=true` path described around the same step breaks out of this pattern entirely: the plan says "if force=true, skip the score check." The natural implementation of this is a conditional — either the parameterized `WHERE relevance_score >= ?` update, or an unconditional update. The PRD's resolved decisions table notes "Promote atomicity: UPDATE ... WHERE relevance_score >= ?" but does not address what the force path looks like at the SQL level.

The risk is that a concurrent `Score` operation between the gate-check read and the forced-promote write can push `relevance_score` below a threshold that the force was bypassing. More concretely: if the store reads the current score, checks it, then issues the forced UPDATE without re-checking, a concurrent decay or score-down can fire in between. The test `TestPromoteForceOverride` submits a low-score paper and immediately promotes with `--force`, which will always pass in a sequential test but misses the concurrent hazard.

**Minimum fix:** The `force=true` path must still issue a single UPDATE with no WHERE clause on relevance_score but within the same transaction that reads the current status first. The gate is bypassed for the score, but not for the status (a dismissed discovery should not be re-promoted by force). The plan's description conflates "skip the score check" with "skip all atomicity," which is not the intent stated in the PRD.

---

### B2 — SIGNIFICANT: Discovery events are appended to `discovery_events` inside the `discovery.Store` methods, but the plan also routes them through `event.Store`'s UNION ALL leg — this creates two separate write paths for the same logical event stream

The plan places event writes entirely in `discovery.Store` (Task 3 Step 3, Task 4 Step 3, Task 8 Step 4). Task 6 then wires `discovery_events` into `event.store.go`'s `ListEvents` and `ListAllEvents` via a third UNION ALL leg that reads from `discovery_events`. This read path is appropriate.

However, consider the existing architecture: `phase.Store` writes to `phase_events`, and `event.Store` reads `phase_events`. `dispatch.Store` writes to `dispatch_events`, and `event.Store` reads `dispatch_events`. Discovery events written by `discovery.Store` to `discovery_events` follow the same write/read split — that is correct.

The boundary issue is subtler: Task 6 adds `MaxDiscoveryEventID` to `event.Store`, but the analogous methods (`MaxPhaseEventID`, `MaxDispatchEventID`) already live in `event.Store` because the cursors for those sources are managed by `cmd/ic/events.go`. Adding `MaxDiscoveryEventID` to `event.Store` is correct; the concern is whether `event.Store` now needs to import `discovery` types to satisfy the UNION ALL column projection.

Looking at the existing UNION ALL queries in `event/store.go`, the SELECT projects a fixed 8-column shape: `id, run_id, source, event_type, from_phase/from_status, to_phase/to_status, reason, created_at`. The plan's third leg projects:
```sql
id, discovery_id AS run_id, 'discovery' AS source, event_type,
from_status, to_status, COALESCE(payload, '') AS reason, created_at
```

This aliases `discovery_id` as `run_id` — a semantic squash that loses the actual run association. If a discovery is linked to a run (via `run_id` column in the `discoveries` table), that FK is not surfaced here. Consumers reading `Event.RunID` for discovery events will receive the discovery_id, not the run_id, and cannot correlate discovery events with the run that generated them. This is a boundary correctness problem: the `Event` type's field is named `RunID` and is expected to hold a run identifier.

**Minimum fix:** Either (a) project `COALESCE(run_id_from_join, discovery_id)` by joining `discovery_events` to `discoveries` to pick up the run_id, or (b) project `discovery_id` into a dedicated field and document that discovery events do not carry run_id (but this changes the `Event` type contract). Option (a) is a single LEFT JOIN and stays within the existing column shape.

---

### B3 — SIGNIFICANT: The cursor extension in Task 6 and Task 10 breaks backward compatibility for registered cursors and has a state-loss risk

The existing cursor JSON is `{"phase":N,"dispatch":N,"interspect":0}`. The plan changes this to `{"phase":N,"dispatch":N,"discovery":N}` and in Task 10 says "Backward-compatible: if existing cursor JSON lacks `discovery` field, default to 0."

The backward compatibility for missing `discovery` is handled. The forward problem is not handled: existing registered cursors have an `interspect` field. The plan removes `interspect` from cursor JSON. When an existing consumer's cursor is loaded, the `interspect` field is silently dropped — this is fine for a field that was never read or saved anyway (the AGENTS.md notes in MEMORY.md call it dead code). But `cmdEventsCursorRegister` currently writes `{"phase":0,"dispatch":0,"interspect":0}` (events.go line 268). Under the plan, it would write `{"phase":0,"dispatch":0,"discovery":0}`. Any cursor registered with the old format and re-read with the new format will silently get `discovery=0` — which is the correct default.

The real risk is Task 10's claim that `interspect` field was "never used." Looking at `events.go`:
- Line 300: `loadCursor` deserializes `Interspect int64 \`json:"interspect"\`` but line 302 returns only `cursor.Phase, cursor.Dispatch` — the interspect value is read and discarded.
- Line 310: `saveCursor` writes `interspect:0` hardcoded.

So `interspect` is truly dead: loaded but not returned; saved as 0 always. Removing it is correct and the plan's removal is safe.

However: Task 6 adds `sinceDiscoveryID int64` as a new parameter to `ListEvents` and `ListAllEvents`. These methods are called from `cmd/ic/events.go`. Adding a parameter to both methods is an API-breaking change within the same package boundary. The existing call sites in `events.go` must be updated simultaneously or they will not compile. The plan does not flag this as a required simultaneous change: Task 6 touches `event/store.go` and `cmd/ic/events.go` in the same commit, which is correct, but implementors must understand that adding the `sinceDiscoveryID` parameter to the store methods without updating `events.go` will break the build. The plan is silent on this compilation dependency.

**Minimum fix:** Add a note in Task 6 that `ListEvents` and `ListAllEvents` signature changes must be applied atomically with all call sites. This is already structurally implied by the single commit, but the plan's step-by-step format should make it explicit so an automated implementor does not apply the store change before the CLI change.

---

### B4 — INFORMATIONAL: `discovery.Store` embeds event writes inline rather than delegating to `event.Store`

Every `discovery.Store` method that mutates state also inserts into `discovery_events` directly (Task 3 shows raw INSERT INTO discovery_events inside Submit's transaction). This follows the pattern used by `phase.Store` and `dispatch.Store` — those stores also write their own event tables directly. So this is consistent with existing conventions.

No change needed — noted for awareness.

---

## 2. Pattern Analysis

### P1 — CRITICAL: `SubmitWithDedup` uses `BEGIN IMMEDIATE` to prevent TOCTOU but the existing `db.go` pattern enforces `SetMaxOpenConns(1)` — these two mechanisms must not conflict

Task 8 describes `SubmitWithDedup` as:
> 1. `BEGIN IMMEDIATE` (prevents TOCTOU between similarity check and insert)

`BEGIN IMMEDIATE` acquires a reserved lock on the WAL file immediately, before any reads. This is the correct choice for a check-then-insert operation. However, the intercore codebase enforces `SetMaxOpenConns(1)` (db.go line 56) specifically to prevent WAL checkpoint TOCTOU. With a single connection, `BEGIN IMMEDIATE` provides no additional isolation guarantee beyond what `BEGIN` already provides on a single-connection pool — SQLite's WAL mode with one connection serializes all transactions.

More critically, if any caller of `SubmitWithDedup` already holds an open transaction (e.g., a wrapping `BeginTx` in a CLI command), then calling `BEGIN IMMEDIATE` inside will return `SQLITE_BUSY` because the outer transaction already holds the connection. The plan does not show `SubmitWithDedup` being called from within a transaction context, so this is safe in the described integration test flows. But it is an invisible constraint: any future caller wrapping `SubmitWithDedup` in a broader transaction will get a silent runtime failure.

The existing `Migrate` function shows the correct pattern for obtaining an exclusive-equivalent lock on a single-connection pool: it uses `CREATE TABLE IF NOT EXISTS _migrate_lock` to force the deferred transaction to upgrade to a write lock. `SubmitWithDedup` should use the same approach: start a regular transaction and do a write operation (insert into `discovery_events` or write a sentinel row) before the similarity read, rather than `BEGIN IMMEDIATE`.

**Minimum fix:** Replace `BEGIN IMMEDIATE` in `SubmitWithDedup` with a standard `BeginTx(ctx, nil)` and perform the first write (or lock promotion via `INSERT INTO _migrate_lock ... ON CONFLICT IGNORE`) before the scan, consistent with the existing migration pattern. Document the single-connection constraint in the `Store` struct's comment.

---

### P2 — SIGNIFICANT: `Decay` uses a multi-bind CASE expression in SQL with the rate parameter repeated three times — the plan does not show this is a `*sql.Tx` operation, leaving decay without atomicity

Task 8 Step 4 describes `Decay` as:
```sql
UPDATE discoveries SET relevance_score = relevance_score * (1.0 - ?),
confidence_tier = CASE
  WHEN relevance_score * (1.0 - ?) >= 0.8 THEN 'high'
  ...
END
WHERE discovered_at < ? AND status NOT IN ('dismissed', 'promoted')
```

Two problems:

First, the CASE expression evaluates `relevance_score * (1.0 - ?)` against the *pre-update* value of `relevance_score`, but the SET clause sets `relevance_score = relevance_score * (1.0 - ?)`. In SQLite, a single UPDATE statement evaluates the WHERE clause and new column values against the row's pre-update state. This means the CASE expression correctly computes the tier for the *new* score — but only if `relevance_score` in the CASE expression refers to the original row value. Testing this edge case: if original score is 0.9 and rate is 0.2, new score = 0.72. The CASE evaluates `0.9 * (1.0 - 0.2) = 0.72 >= 0.5`, tier = medium. This is correct because SQLite evaluates CASE expressions against the pre-update row. This is safe but the plan should document this assumption explicitly.

Second, the decay emits a single `discovery.decayed` event with count and rate, after the bulk UPDATE. This is outside any transaction in the plan's description. If the process crashes after the UPDATE but before the event INSERT, the score has changed but no event was recorded. The existing `Score()` method wraps both UPDATE and INSERT in a transaction; `Decay` should do the same. The plan describes `Decay` step-by-step without specifying transaction wrapping, unlike `Submit` which explicitly shows `tx, err := s.db.BeginTx(ctx, nil)`.

**Minimum fix:** The `Decay` implementation plan must explicitly wrap the UPDATE + event INSERT in a transaction. Add a test that verifies the event count after decay equals the affected rows count.

---

### P3 — SIGNIFICANT: The `DiscoveryEvent` type in Task 1 has a duplicated time representation

The plan defines:
```go
type DiscoveryEvent struct {
    ...
    CreatedAt    int64     `json:"created_at"`
    Timestamp    time.Time `json:"timestamp"` // populated from CreatedAt
}
```

This is the same dual-field pattern used by `event.Event` (`Timestamp time.Time`) and `InterspectEvent` (`Timestamp time.Time`). In the existing store, `scanEvents` populates `Timestamp` from `createdAt` via `time.Unix(createdAt, 0)` and the `created_at` field is not exposed in the `Event` type at all. The existing `Event` type only has `Timestamp time.Time`, not a separate `CreatedAt int64`.

`DiscoveryEvent` in the plan exposes *both* `created_at int64` and `timestamp time.Time`, which means JSON output will contain both fields. This is inconsistent with `Event` and `InterspectEvent` which only expose `timestamp`. Callers consuming discovery events via the unified event bus see `Event.Timestamp`; callers consuming raw `DiscoveryEvent` via a hypothetical future list endpoint would see both. The duplication also means a future refactor could desync them.

**Minimum fix:** Remove `CreatedAt int64` from the exported `DiscoveryEvent` struct. Keep it as a local scan variable inside the store method (the same pattern used in `scanEvents` and `ListInterspectEvents`). Only export `Timestamp time.Time`.

---

### P4 — INFORMATIONAL: `ListFilter` in Task 3 and `SearchFilter` in Task 9 are parallel structs with overlapping fields

`ListFilter{Source, Status, Tier, Limit}` and `SearchFilter{Source, Tier, Status, MinScore, Limit}` share four of five fields. The existing `event.Store` does not use filter structs — it uses explicit parameters. The filter struct pattern is not established elsewhere in the codebase, but it is a reasonable addition for a new package with multiple filter axes.

However, the `SearchFilter` is a superset of `ListFilter` plus `MinScore`. If these two structs grow independently they will diverge. A single `DiscoveryFilter{Source, Status, Tier, MinScore, Limit}` used by both `List` and `Search` would keep the filtering logic in one place. This also means a future `ic discovery search --source=arxiv --tier=high` could reuse the same filter validation.

This is optional since it is new code with no external callers yet, but the merge cost grows with each test that references the separate types.

---

### P5 — INFORMATIONAL: The plan introduces `nowUnix()` as a local helper in `discovery/store.go` but the same helper exists by convention in every other store

Looking at `event/store.go` — it does not define `nowUnix()`. Looking at the schema, `created_at INTEGER NOT NULL DEFAULT (unixepoch())` — timestamps are set by SQL default. However, `phase/gate.go` and `runtrack` stores use `time.Now().Unix()` inline. The CLAUDE.md design decision says "TTL computation in Go (time.Now().Unix()) not SQL (unixepoch()) to avoid float promotion."

The plan proposes a private `nowUnix()` helper in `store.go`. This is fine if confined to that package, but the comment in Task 3 Step 3 shows `__import_time__.Now().Unix()` with a note that it is illustrative. The implementor should use `time.Now().Unix()` directly (inline) rather than defining a helper that adds one indirection and can drift from the design decision note. Looking at the existing stores, none define a `nowUnix()` function — they inline `time.Now().Unix()`. Introducing a named helper only in the discovery package creates inconsistency.

---

## 3. Simplicity & YAGNI

### Y1 — SIGNIFICANT: `interest_profile` is a singleton table with three fields and no defined consumer — it is premature for this sprint

The `interest_profile` table (Task 7) stores `topic_vector BLOB`, `keyword_weights TEXT`, `source_weights TEXT`. The PRD Feature F4 description says "feedback and interest profile." Looking at the full plan, no code path *reads* the interest profile to influence scoring, filtering, or decay. `UpdateProfile` writes it and `GetProfile` reads it. The CLI provides `ic discovery profile update` and `ic discovery profile`. But neither `Decay`, `Search`, nor `Score` consults the profile.

This is a data container with no current consumer. The profile would only become useful when a scoring or decay algorithm reads `keyword_weights` to adjust scores. That algorithm is not in this plan. The `interest_profile` table, `InterestProfile` type, `GetProfile`, `UpdateProfile`, `RecordFeedback`, and the `profile` CLI subcommand can all be deferred to the sprint that actually consumes them.

The `feedback_signals` table is marginally more justified because feedback emission is a natural side-effect of `Promote` and `Dismiss` (the signal records the human action). But even there, `RecordFeedback` as a separate CLI-callable path is speculative without a consumer.

**Minimum fix:** Defer `interest_profile` table, `InterestProfile` type, `GetProfile`, `UpdateProfile`, and the `ic discovery profile` CLI subcommand to a follow-on sprint. Keep `feedback_signals` only if `RecordFeedback` is called internally by `Promote`/`Dismiss` rather than as a standalone CLI path. If feedback writing is wanted for observability, inline the INSERT into `Promote`/`Dismiss` transactions rather than creating a separate method.

---

### Y2 — INFORMATIONAL: The `rollback` subcommand (Task 10) partially overlaps with `dismiss` for the stated use case

`Rollback(ctx, source, sinceTimestamp)` bulk-dismisses discoveries from a given source since a timestamp. This is a convenience wrapper that could be expressed as: `List --source=X` followed by `Dismiss` for each result filtered by `discovered_at >= since`. The PRD does not list rollback as a feature — it appears in the plan as Task 10 alongside cursor cleanup.

If the primary use case is "a scanner submitted bad data and needs a do-over," this is adequately served by `ic discovery dismiss` in a shell loop. The `rollback` subcommand adds a CLI surface and a new store method for a use case that has one identified scenario (the integration test creates 3 items from `rollback-test` source). Given the existing rollback plan from E6 (prior review) already creates a high-footprint rollback pattern, adding another rollback concept in E5 for a different entity should be evaluated carefully.

This is low risk to include, but it is the kind of "it might be useful" addition the plan should flag as optional rather than core.

---

### Y3 — INFORMATIONAL: The `SearchResult` embedding by value creates a large allocation per result for datasets with embeddings

Task 9 defines:
```go
type SearchResult struct {
    Discovery       // embedded by value
    Similarity float64
}
```

`Discovery` contains `Embedding []byte` which for a 1024-dim float32 vector is 4096 bytes. Embedding all rows by value in `SearchResult` copies the blob for every result. The search function already loads all embeddings from the database to compute cosine similarity — copying them again into results adds no value.

**Minimum fix:** Zero out `Embedding` in each `SearchResult` before returning, or exclude `Embedding` from the `Discovery` struct when it is embedded in `SearchResult`. The plan's `List` method already demonstrates this pattern: it does not SELECT `embedding` in the list query. The `Search` method should set `d.Embedding = nil` before appending to results.

---

### Y4 — INFORMATIONAL: The `TestDecay` test directly accesses `s.db` to backdoor the timestamp

Task 8 Step 1 shows:
```go
s.db.ExecContext(ctx, "UPDATE discoveries SET discovered_at = ? WHERE id = ?", nowUnix()-86400*30, id)
```

This access pattern bypasses the store's encapsulation by reaching into the unexported `db` field from within the package. This works because the test is `package discovery` (same package, white-box test), which is consistent with the existing `store_test.go` pattern used in other packages. This is intentional and acceptable for white-box tests. No change needed.

---

## Cross-Cutting Observations

### Migration approach is correctly additive

The plan's decision to add all three tables in a single v8→v9 migration step with `CREATE TABLE IF NOT EXISTS` (no ALTER TABLE) is the right choice. The existing migration code in `db.go` shows ALTER TABLE is used only for columns added to existing tables. New tables need no ALTER path. The plan correctly notes "No v8→v9 ALTER TABLE migration step needed." This is sound.

### Event bus third leg column projection alignment

The existing event bus normalizes all events into an 8-column shape. The plan's proposed third leg correctly maps `discovery_id AS run_id` for the `run_id` position — this is the same aliasing approach `dispatch_events` uses for `COALESCE(run_id, '') AS run_id`. The column shape will compile cleanly. The semantic squash issue (B2 above) is a separate correctness concern.

### The `--metadata=@file` convention in Task 5 matches the existing `@filepath` pattern

`state set` already accepts `@filepath` to read JSON from a file (main.go lines 530-557). The plan's `--metadata=@file` and `--embedding=@file` flags follow this convention. The validation logic (path under CWD, no `..`) should be copied from `cmdStateSet`, not reimplemented.

### `ic discovery submit` printing the raw ID to stdout is the correct output contract

Existing `ic dispatch spawn` prints the dispatch ID to stdout. `ic run create` prints the run ID. The plan's `ic discovery submit` printing the discovery ID follows this convention exactly. Integration tests using `DID=$(ic discovery submit ...)` capture stdout correctly.

---

## Summary of Issues

| Severity | ID | Description |
|---|---|---|
| CRITICAL | B1 | `Promote --force` path lacks atomic status guard; concurrent decay can cause incorrect state |
| CRITICAL | P1 | `BEGIN IMMEDIATE` in `SubmitWithDedup` conflicts with single-connection pool pattern; should use write-lock promotion instead |
| SIGNIFICANT | B2 | Discovery event UNION ALL leg aliases `discovery_id AS run_id`, losing actual run association for linked discoveries |
| SIGNIFICANT | B3 | `ListEvents`/`ListAllEvents` signature change in Task 6 must be flagged as a simultaneous call-site update |
| SIGNIFICANT | P2 | `Decay` must be wrapped in a transaction; plan description omits this, unlike `Submit` which shows it explicitly |
| SIGNIFICANT | P3 | `DiscoveryEvent.CreatedAt int64` duplicates `Timestamp time.Time`; inconsistent with existing `Event` and `InterspectEvent` types |
| SIGNIFICANT | Y1 | `interest_profile` table and profile CLI have no current consumer; should be deferred |
| INFORMATIONAL | P4 | `ListFilter` and `SearchFilter` can be merged into one `DiscoveryFilter` struct |
| INFORMATIONAL | P5 | `nowUnix()` helper inconsistent with existing inline `time.Now().Unix()` pattern |
| INFORMATIONAL | Y2 | `rollback` subcommand replicates `dismiss` behavior for one scenario; marginal value |
| INFORMATIONAL | Y3 | `SearchResult` embeds `Discovery` by value, copying 4KB embedding blob per result |

---

## Recommended Implementation Order Change

The plan's dependency graph is correct. The recommended changes to the plan before implementation:

1. In Task 4, rewrite the `Promote` force path spec to use a single unconditional UPDATE inside a `BeginTx`/`Commit` wrapping the status guard.
2. In Task 6, add an explicit note: "ListEvents and ListAllEvents signature change must be applied in the same commit as all call sites in events.go."
3. In Task 6, fix the UNION ALL leg projection to include run_id from a LEFT JOIN on `discoveries`.
4. In Task 7, mark `interest_profile` and `ic discovery profile` as deferred (cut from sprint scope).
5. In Task 8, rewrite `SubmitWithDedup` spec to use standard `BeginTx` with write-lock promotion instead of `BEGIN IMMEDIATE`. Add transaction wrapping spec to `Decay`.
6. In Task 1, remove `CreatedAt int64` from `DiscoveryEvent` exported struct.
