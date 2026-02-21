# Research: Non-Atomic Gate Checks and Missing CAS Guards in SQLite Event-Sourced Systems

**Date:** 2026-02-20
**Context:** Correctness review of intercore (Go + SQLite orchestration kernel)
**Scope:** Two bugs — non-atomic gate check + phase update, and missing CAS on dispatch status transitions

---

## Table of Contents

1. [Bug Descriptions and Root Causes](#1-bug-descriptions-and-root-causes)
2. [Are These Recognized Anti-Patterns?](#2-are-these-recognized-anti-patterns)
3. [Standard Go Patterns for Atomic Read-Write Transactions in SQLite WAL Mode](#3-standard-go-patterns-for-atomic-read-write-transactions-in-sqlite-wal-mode)
4. [How Event-Sourced Systems Handle Optimistic Concurrency](#4-how-event-sourced-systems-handle-optimistic-concurrency)
5. [BEGIN IMMEDIATE vs BEGIN DEFERRED with SetMaxOpenConns(1)](#5-begin-immediate-vs-begin-deferred-with-setmaxopenconns1)
6. [Community Evidence: Blog Posts, GitHub Issues, and StackOverflow](#6-community-evidence)
7. [Concrete Fix Patterns for Intercore](#7-concrete-fix-patterns-for-intercore)
8. [Severity Assessment](#8-severity-assessment)
9. [Sources](#9-sources)

---

## 1. Bug Descriptions and Root Causes

### Bug 1: Non-Atomic Gate Check + Phase Update (TOCTOU)

**Location:** `internal/phase/machine.go:Advance()` calling `evaluateGate()` then `UpdatePhase()`

**Current flow (machine.go lines 46-204):**
1. `store.Get(ctx, runID)` — reads current run state (line 47)
2. `evaluateGate(ctx, run, cfg, fromPhase, toPhase, rt, vq, pq, dq)` — runs multiple SELECT queries across different tables: `CountArtifacts`, `CountActiveAgents`, `HasVerdict`, `GetChildren`, `GetUpstream` (line 117)
3. `store.UpdatePhase(ctx, runID, fromPhase, toPhase)` — runs `UPDATE runs SET phase = ? WHERE id = ? AND phase = ?` with a CAS guard on the phase column (line 167)

**The gap:** Between steps 2 and 3, no transaction encloses the entire operation. An agent could complete (changing `CountActiveAgents` from 1 to 0), causing the gate to pass, but then another concurrent `Advance()` could also see 0 active agents and attempt to advance. The CAS on `UpdatePhase` only guards against concurrent phase writes, not against stale gate reads.

**Classification:** This is a classic **check-then-act TOCTOU** (Time-of-Check Time-of-Use). The "check" (gate evaluation) is separated from the "act" (phase update) by an unprotected gap. While SQLite's serializable isolation prevents write skew *within a single transaction*, the multi-statement sequence here is NOT wrapped in a transaction, so each SQL statement sees a potentially different snapshot.

### Bug 2: Missing CAS on Dispatch Status Transitions

**Location:** `internal/dispatch/dispatch.go:UpdateStatus()` (lines 200-259)

**Current flow:**
1. Begins a transaction (`BeginTx`)
2. Reads `prevStatus` via SELECT (line 210-211)
3. Runs `UPDATE dispatches SET status = ? WHERE id = ?` — no `AND status = ?` guard (line 232)
4. Commits

**The problem:** The UPDATE at line 232 has no prior-status guard. Although `UpdateStatus` reads `prevStatus` (line 210), it does NOT include it in the WHERE clause. With `SetMaxOpenConns(1)`, the Go connection pool serializes access, but the `eventRecorder` callback fires OUTSIDE the transaction (line 250-256), and concurrent goroutines waiting for the single connection can interleave:

- Goroutine A reads status="running", begins UPDATE to "completed"
- Goroutine A commits, fires eventRecorder
- Goroutine B reads status="completed", begins UPDATE to "failed" (overwriting terminal state)

Status transitions should be **monotone toward terminal states** — once a dispatch is "completed", it should never become "failed" or vice versa. The `Outcome` type in `outcome.go` already defines a severity ordering (Success < Error < Cancelled < Timeout), but this ordering is not enforced at the SQL level.

---

## 2. Are These Recognized Anti-Patterns?

### Yes, both are well-documented anti-patterns.

**Check-then-act / TOCTOU in databases:**
The SQLite documentation itself warns about the vulnerability window in DEFERRED transactions: "if some other database connection has already modified the database... upgrading to a write transaction is not possible and the write statement will fail with SQLITE_BUSY" ([SQLite Transaction docs](https://www.sqlite.org/lang_transaction.html)). While SQLite provides serializable isolation, this only applies *within* a transaction. Multiple separate statements executed outside a transaction boundary each see independent snapshots.

**Missing CAS on status transitions:**
The SkyPilot blog post "[Abusing SQLite to Handle Concurrency](https://blog.skypilot.co/abusing-sqlite-to-handle-concurrency/)" documents nearly identical problems in their managed jobs system. They describe status transitions where "ANY status can legally transition to FAILED_CONTROLLER, even another terminal status" — a deliberate design choice that highlights how the default (no CAS) allows arbitrary overwrites. Lawrence Jones' "[Use your database to power state machines](https://blog.lawrencejones.dev/state-machines/)" at incident.io explicitly recommends encoding transition rules in SQL constraints with unique indexes on transition tables, preventing concurrent actors from creating conflicting transitions.

**SQLite-specific context:**
SQLite achieves serializable isolation "by actually serializing the writes, with only a single writer at a time" ([SQLite Isolation docs](https://sqlite.org/isolation.html)). However, this serialization applies at the *transaction* level. If you perform a read, release the transaction (or never start one), and then perform a write in a new transaction, the read is stale. With `SetMaxOpenConns(1)` in Go, individual SQL statements are serialized at the connection pool level, but this is a Go-level queue, not a database-level transaction boundary — the gap between statements still exists.

**The optimistic locking pattern (`UPDATE ... WHERE version = ?` + check RowsAffected):**
This is the universally recommended solution for databases that lack `SELECT FOR UPDATE` (which SQLite does not support). The pattern is described in:
- [Optimistic Locking: Concurrency Control with a Version Column](https://medium.com/@sumit-s/optimistic-locking-concurrency-control-with-a-version-column-2e3db2a8120d)
- [Optimistic Locking in Peewee ORM](https://charlesleifer.com/blog/optimistic-locking-in-peewee-orm/)
- [Optimistic concurrency control (Wikipedia)](https://en.wikipedia.org/wiki/Optimistic_concurrency_control)
- [Event Sourcing in Go (Victor Martinez)](https://victoramartinez.com/posts/event-sourcing-in-go/)

---

## 3. Standard Go Patterns for Atomic Read-Write Transactions in SQLite WAL Mode

### Pattern A: Transaction-Wrapped Check-Then-Act

The standard pattern wraps all reads and the conditional write in a single transaction:

```go
func (s *Store) AdvanceAtomic(ctx context.Context, runID, expectedPhase, newPhase string, gateCheck func(tx *sql.Tx) (bool, error)) error {
    tx, err := s.db.BeginTx(ctx, nil)
    if err != nil {
        return fmt.Errorf("advance: begin: %w", err)
    }
    defer tx.Rollback()

    // All reads happen inside the transaction
    pass, err := gateCheck(tx)
    if err != nil {
        return fmt.Errorf("advance: gate check: %w", err)
    }
    if !pass {
        return ErrGateFailed
    }

    // CAS write — still protected by phase guard
    now := time.Now().Unix()
    result, err := tx.ExecContext(ctx,
        `UPDATE runs SET phase = ?, updated_at = ?
         WHERE id = ? AND phase = ?`,
        newPhase, now, runID, expectedPhase,
    )
    if err != nil {
        return fmt.Errorf("advance: update: %w", err)
    }
    n, err := result.RowsAffected()
    if err != nil {
        return fmt.Errorf("advance: rows affected: %w", err)
    }
    if n == 0 {
        return ErrStalePhase
    }

    return tx.Commit()
}
```

### Pattern B: Using `_txlock=immediate` DSN Parameter (modernc.org/sqlite)

With modernc.org/sqlite, you can configure all transactions to be IMMEDIATE via the connection string:

```go
dsn := fmt.Sprintf(
    "file:%s?_pragma=journal_mode%%3DWAL&_pragma=busy_timeout%%3D%d&_txlock=immediate",
    path, busyTimeout.Milliseconds(),
)
sqlDB, err := sql.Open("sqlite", dsn)
```

This ensures that `BeginTx` issues `BEGIN IMMEDIATE` instead of `BEGIN DEFERRED`. The write lock is acquired at transaction start, preventing another connection from modifying data between the read and write phases.

**Important:** With `SetMaxOpenConns(1)`, `_txlock=immediate` is technically redundant because only one goroutine can hold the connection at a time. However, it provides defense-in-depth — if the connection pool configuration ever changes, the transaction isolation is still correct.

### Pattern C: Manual `BEGIN IMMEDIATE` via Exec (Workaround for BeginTx Limitation)

Go's `database/sql.BeginTx` does not expose SQLite-specific transaction modes. The `_txlock` DSN parameter (Pattern B) is the preferred workaround. If per-transaction control is needed:

```go
// Workaround: use Exec to start an IMMEDIATE transaction manually
conn, err := s.db.Conn(ctx)
if err != nil {
    return err
}
defer conn.Close()

if _, err := conn.ExecContext(ctx, "BEGIN IMMEDIATE"); err != nil {
    return err
}

// Perform reads and writes on the same conn
// ...

if _, err := conn.ExecContext(ctx, "COMMIT"); err != nil {
    conn.ExecContext(ctx, "ROLLBACK")
    return err
}
```

**Caveat:** This bypasses `database/sql`'s transaction management. The `_txlock` parameter approach (Pattern B) is cleaner and recommended by the [River Queue documentation](https://riverqueue.com/docs/sqlite) and [modernc.org/sqlite docs](https://pkg.go.dev/modernc.org/sqlite).

### Pattern D: Interface Abstraction for Transaction-Aware Queries

To let gate evaluation work both inside and outside a transaction, define a querier interface:

```go
// Querier is satisfied by both *sql.DB and *sql.Tx
type Querier interface {
    ExecContext(ctx context.Context, query string, args ...interface{}) (sql.Result, error)
    QueryContext(ctx context.Context, query string, args ...interface{}) (*sql.Rows, error)
    QueryRowContext(ctx context.Context, query string, args ...interface{}) *sql.Row
}

// CountArtifacts works with either *sql.DB or *sql.Tx
func CountArtifacts(ctx context.Context, q Querier, runID, phase string) (int, error) {
    var count int
    err := q.QueryRowContext(ctx,
        `SELECT COUNT(*) FROM run_artifacts
         WHERE run_id = ? AND phase = ? AND status = 'active'`,
        runID, phase,
    ).Scan(&count)
    return count, err
}
```

This is the pattern already noted in MEMORY.md: "Use a `queryCtx` interface to let DFS code work with `*sql.DB` or `*sql.Tx`."

---

## 4. How Event-Sourced Systems Handle Optimistic Concurrency

### EventStoreDB Pattern (Expected Version)

EventStoreDB's canonical approach checks the stream version before appending:

```
AppendToStream(streamName, expectedVersion, events)
```

If `expectedVersion` doesn't match the current stream position, a `WrongExpectedVersionException` is raised. The caller must reload the aggregate and retry. This is the exact same concept as the `WHERE phase = ?` CAS guard in `UpdatePhase`, extended to cover the *entire* command processing pipeline.

Reference: [Event Sourcing and Concurrent Updates (Teiva Harsanyi)](https://teivah.medium.com/event-sourcing-and-concurrent-updates-32354ec26a4c)

### hallgren/eventsourcing (Go Library)

The [hallgren/eventsourcing](https://github.com/hallgren/eventsourcing) library uses version numbers on aggregates:

```go
for i := range records {
    expectedVersion := i + p.Version()
    records[i].Version = expectedVersion
}
```

The event store's `Save()` method validates versions before persisting, returning `ErrConcurrency` on mismatch. This is implemented at the storage layer, not the business logic layer.

### SQLite-Specific Event Sourcing Pattern

From "[Building Event Sourcing Systems with SQLite](https://www.sqliteforum.com/p/building-event-sourcing-systems-with)":

```sql
-- Check expected version
SELECT MAX(event_version)
FROM events
WHERE aggregate_id = 'ACC-101';

-- If version matches, append event
BEGIN IMMEDIATE;
INSERT INTO events (aggregate_type, aggregate_id, event_type, event_data, event_version)
VALUES ('account', 'ACC-101', 'MoneyDeposited', '{"amount":200}', 2);
COMMIT;
```

The article explicitly states: "If the version has changed, reject or retry the command. This prevents conflicting updates without heavy locking."

### incident.io's Transition Table Pattern (Lawrence Jones)

Rather than a mutable `status` column, incident.io stores state transitions in a separate table with unique constraints:

```sql
CREATE TABLE payment_transitions (
    id SERIAL PRIMARY KEY,
    payment_id INTEGER REFERENCES payments(id),
    to_state TEXT NOT NULL,
    most_recent BOOLEAN NOT NULL DEFAULT true,
    sort_key INTEGER NOT NULL
);

-- Only one "most recent" transition per payment
CREATE UNIQUE INDEX ON payment_transitions (payment_id, most_recent)
    WHERE most_recent = true;

-- Sort keys must be unique per payment (prevents concurrent inserts)
CREATE UNIQUE INDEX ON payment_transitions (payment_id, sort_key);
```

The transition execution uses a three-step process within a transaction:
1. `UPDATE` the current `most_recent` row (acquires a lock)
2. Validate the transition is legal
3. `INSERT` the new transition row

If two concurrent processes race, the unique index on `sort_key` causes one to fail. This is the gold standard for database-backed state machines.

Reference: [Use your database to power state machines](https://blog.lawrencejones.dev/state-machines/)

---

## 5. BEGIN IMMEDIATE vs BEGIN DEFERRED with SetMaxOpenConns(1)

### The Short Answer

With `SetMaxOpenConns(1)`, **BEGIN IMMEDIATE is unnecessary but still recommended as defense-in-depth**.

### Detailed Analysis

**How SetMaxOpenConns(1) protects you:**
- Go's `database/sql` connection pool has exactly one connection
- All goroutines queue for that single connection
- A goroutine holding the connection (in a transaction or executing a statement) blocks all others
- This effectively serializes all database access at the Go level
- Result: No concurrent transactions can overlap, so DEFERRED vs IMMEDIATE is moot

**When SetMaxOpenConns(1) does NOT protect you:**
- When the check and act are performed as **separate statements outside a transaction** (which is exactly Bug 1)
- Statement 1 (gate check SELECT) acquires the connection, executes, releases back to pool
- Statement 2 (UPDATE phase) acquires the connection again
- Between releases, another goroutine can acquire the connection and execute its own statements

**What BEGIN IMMEDIATE adds:**
- Acquires the write lock at `BEGIN` time, not at first write statement time
- Prevents `SQLITE_BUSY` errors that can occur when upgrading from a read lock to a write lock mid-transaction
- With `SetMaxOpenConns(1)`, the lock upgrade can't fail (no concurrent connection), but BEGIN IMMEDIATE makes the intent explicit

**The River Queue documentation confirms this:**
> "When configured to limit the connection pool to a single connection via `SetMaxOpenConns(1)`, [BEGIN IMMEDIATE] becomes unnecessary, since no other goroutine can lock the database while another is holding the only available connection."
>
> — [River Queue: Using with SQLite](https://riverqueue.com/docs/sqlite)

**Recommendation for intercore:** Even with `SetMaxOpenConns(1)`, use `_txlock=immediate` in the DSN. Cost is negligible. Benefit: if someone removes the MaxOpenConns limit (or adds a read-only connection pool), the system doesn't silently develop races.

### BEGIN IMMEDIATE Transaction Semantics in WAL Mode

In WAL mode, `BEGIN IMMEDIATE` and `BEGIN EXCLUSIVE` are functionally identical:

| Transaction Type | Lock Acquired | When | SQLite_BUSY Possible |
|-----------------|---------------|------|---------------------|
| DEFERRED (default) | None → SHARED → RESERVED → EXCLUSIVE | Lazy, on first read/write | Yes, on upgrade |
| IMMEDIATE | RESERVED immediately | At BEGIN | Only if another writer is active |
| EXCLUSIVE (=IMMEDIATE in WAL) | RESERVED immediately | At BEGIN | Only if another writer is active |

Reference: [SQLite Transaction Documentation](https://www.sqlite.org/lang_transaction.html)

---

## 6. Community Evidence

### GitHub Issues

1. **[golang/go #19981: database/sql: add option to customize Begin statement](https://github.com/golang/go/issues/19981)** — Long-standing request (since 2017) to allow SQLite-specific transaction modes via `BeginTx`. Still open. The workaround is driver-level DSN parameters (`_txlock`).

2. **[mattn/go-sqlite3 #400: Feature: BEGIN immediate/exclusive per transaction](https://github.com/mattn/go-sqlite3/issues/400)** — Same request for the go-sqlite3 driver. Discussion confirms `_txlock` connection parameter as the workaround.

3. **[mattn/go-sqlite3 #1179: Possible solutions to the concurrency problems](https://github.com/mattn/go-sqlite3/issues/1179)** — Documents the full spectrum of concurrency issues: SQLITE_BUSY, lock starvation, and check-then-act races.

4. **[mattn/go-sqlite3 #1238: Race conditions during unit tests despite workarounds](https://github.com/mattn/go-sqlite3/issues/1238)** — Demonstrates that even with WAL mode and busy_timeout, races exist when transactions aren't properly scoped.

### Blog Posts

5. **[SkyPilot: Abusing SQLite to Handle Concurrency](https://blog.skypilot.co/abusing-sqlite-to-handle-concurrency/)** — Production war story about SQLite state machine problems at scale (1000+ concurrent jobs). Their `set_cancelling()` function crashed due to concurrent status overwrites — essentially the same as Bug 2.

6. **[Ten Thousand Meters: SQLite concurrent writes and "database is locked" errors](https://tenthousandmeters.com/blog/sqlite-concurrent-writes-and-database-is-locked-errors/)** — Deep dive into SQLite's lock acquisition mechanism and why FIFO ordering is not guaranteed.

7. **[Lawrence Jones: Use your database to power state machines](https://blog.lawrencejones.dev/state-machines/)** — Gold standard reference for database-backed state machines with concurrent safety.

8. **[Victor Martinez: Event Sourcing in Go](https://victoramartinez.com/posts/event-sourcing-in-go/)** — Complete Go implementation with version-based optimistic concurrency.

9. **[Building Event Sourcing Systems with SQLite: CQRS Guide](https://www.sqliteforum.com/p/building-event-sourcing-systems-with)** — SQLite-specific event sourcing patterns including version checking.

---

## 7. Concrete Fix Patterns for Intercore

### Fix for Bug 1: Wrap Gate Evaluation + Phase Update in a Transaction

**Approach:** Make `evaluateGate` and `UpdatePhase` operate on the same `*sql.Tx`.

**Step 1: Define a Querier interface (already partially exists)**

```go
// Querier is satisfied by both *sql.DB and *sql.Tx.
// This allows gate checks and phase updates to run atomically.
type Querier interface {
    ExecContext(ctx context.Context, query string, args ...interface{}) (sql.Result, error)
    QueryContext(ctx context.Context, query string, args ...interface{}) (*sql.Rows, error)
    QueryRowContext(ctx context.Context, query string, args ...interface{}) *sql.Row
}
```

**Step 2: Make store methods accept Querier instead of using s.db directly**

```go
// countArtifacts operates on any Querier (DB or Tx)
func countArtifacts(ctx context.Context, q Querier, runID, phase string) (int, error) {
    var count int
    err := q.QueryRowContext(ctx,
        `SELECT COUNT(*) FROM run_artifacts
         WHERE run_id = ? AND phase = ? AND status = 'active'`,
        runID, phase,
    ).Scan(&count)
    return count, err
}
```

**Step 3: Wrap the entire Advance sequence in a transaction**

```go
func Advance(ctx context.Context, store *Store, runID string, cfg GateConfig,
    rt RuntrackQuerier, vq VerdictQuerier, pq PortfolioQuerier, dq DepQuerier,
    callback PhaseEventCallback) (*AdvanceResult, error) {

    tx, err := store.db.BeginTx(ctx, nil)
    if err != nil {
        return nil, fmt.Errorf("advance: begin: %w", err)
    }
    defer tx.Rollback()

    // 1. Read run state INSIDE transaction
    run, err := getRun(ctx, tx, runID) // uses tx, not s.db
    if err != nil {
        return nil, err
    }

    // 2. All gate checks on the SAME transaction snapshot
    //    (rt, vq, pq, dq implementations need tx-aware variants)
    gateResult, gateTier, evidence, gateErr := evaluateGateInTx(ctx, tx, run, cfg, fromPhase, toPhase)
    if gateErr != nil {
        return nil, fmt.Errorf("advance: %w", gateErr)
    }

    // 3. Guard: gate failed hard — abort without writing
    if gateResult == GateFail && gateTier == TierHard {
        // Record block event inside the same transaction
        addEventInTx(ctx, tx, &PhaseEvent{...})
        tx.Commit() // commit the event, not the phase change
        return blockResult, nil
    }

    // 4. CAS phase update — INSIDE the same transaction
    now := time.Now().Unix()
    result, err := tx.ExecContext(ctx,
        `UPDATE runs SET phase = ?, updated_at = ?
         WHERE id = ? AND phase = ?`,
        toPhase, now, runID, fromPhase,
    )
    if err != nil {
        return nil, fmt.Errorf("advance: update: %w", err)
    }
    n, _ := result.RowsAffected()
    if n == 0 {
        return nil, ErrStalePhase // concurrent advance won
    }

    // 5. Record advance event — INSIDE the same transaction
    addEventInTx(ctx, tx, &PhaseEvent{...})

    // 6. If terminal, update status — INSIDE the same transaction
    if ChainIsTerminal(chain, toPhase) {
        tx.ExecContext(ctx,
            `UPDATE runs SET status = ?, completed_at = ? WHERE id = ?`,
            StatusCompleted, now, runID,
        )
    }

    // 7. Commit the entire atomic unit
    if err := tx.Commit(); err != nil {
        return nil, fmt.Errorf("advance: commit: %w", err)
    }

    // 8. Fire callback OUTSIDE transaction (fire-and-forget)
    if callback != nil {
        callback(runID, eventType, fromPhase, toPhase, reason)
    }

    return advanceResult, nil
}
```

**Refactoring cost:** Medium. The querier interfaces (`RuntrackQuerier`, `VerdictQuerier`, etc.) need tx-aware variants or must accept a `Querier` parameter. This is a structural change but follows the existing pattern noted in MEMORY.md.

**Alternative (minimal change):** If the querier interface refactoring is too large, wrap just the gate evaluation reads + phase update in a single transaction using `BEGIN IMMEDIATE`:

```go
// Minimal fix: use a dedicated connection for the atomic sequence
conn, err := store.db.Conn(ctx)
if err != nil {
    return nil, err
}
defer conn.Close()

conn.ExecContext(ctx, "BEGIN IMMEDIATE")
// ... gate checks and phase update on conn ...
conn.ExecContext(ctx, "COMMIT")
```

### Fix for Bug 2: Add CAS Guard to Dispatch Status Transitions

**Approach:** Add `AND status = ?` to the UPDATE WHERE clause, and enforce monotonicity.

**Step 1: Define valid transitions**

```go
// validTransitions maps each status to its allowed next statuses.
var validTransitions = map[string]map[string]bool{
    StatusSpawned: {
        StatusRunning:   true,
        StatusFailed:    true,
        StatusCancelled: true,
        StatusTimeout:   true,
    },
    StatusRunning: {
        StatusCompleted: true,
        StatusFailed:    true,
        StatusCancelled: true,
        StatusTimeout:   true,
    },
    // Terminal states: no outgoing transitions
    StatusCompleted: {},
    StatusFailed:    {},
    StatusCancelled: {},
    StatusTimeout:   {},
}
```

**Step 2: Add CAS to the UPDATE**

```go
func (s *Store) UpdateStatus(ctx context.Context, id, newStatus string, fields UpdateFields) error {
    tx, err := s.db.BeginTx(ctx, nil)
    if err != nil {
        return fmt.Errorf("dispatch update: begin: %w", err)
    }
    defer tx.Rollback()

    // Read current status
    var prevStatus string
    var scopeID sql.NullString
    err = tx.QueryRowContext(ctx,
        "SELECT status, scope_id FROM dispatches WHERE id = ?", id,
    ).Scan(&prevStatus, &scopeID)
    if err != nil {
        if errors.Is(err, sql.ErrNoRows) {
            return ErrNotFound
        }
        return fmt.Errorf("dispatch update: read prev: %w", err)
    }

    // Validate transition
    allowed, ok := validTransitions[prevStatus]
    if !ok || !allowed[newStatus] {
        return fmt.Errorf("dispatch update: invalid transition %s -> %s", prevStatus, newStatus)
    }

    // CAS update — include prior status in WHERE clause
    sets := []string{"status = ?"}
    args := []interface{}{newStatus}

    for col, val := range fields {
        if !allowedUpdateCols[col] {
            return fmt.Errorf("dispatch update: disallowed column: %q", col)
        }
        sets = append(sets, col+" = ?")
        args = append(args, val)
    }
    args = append(args, id, prevStatus) // CAS: AND status = prevStatus

    query := "UPDATE dispatches SET " + joinStrings(sets, ", ") +
        " WHERE id = ? AND status = ?"
    result, err := tx.ExecContext(ctx, query, args...)
    if err != nil {
        return fmt.Errorf("dispatch update: %w", err)
    }
    n, err := result.RowsAffected()
    if err != nil {
        return fmt.Errorf("dispatch update: %w", err)
    }
    if n == 0 {
        return fmt.Errorf("dispatch update: concurrent status change (expected %s)", prevStatus)
    }

    if err := tx.Commit(); err != nil {
        return fmt.Errorf("dispatch update: commit: %w", err)
    }

    // Fire event recorder outside transaction
    if s.eventRecorder != nil && newStatus != prevStatus {
        runID := ""
        if scopeID.Valid {
            runID = scopeID.String
        }
        s.eventRecorder(id, runID, prevStatus, newStatus)
    }

    return nil
}
```

**Step 3: Also guard terminal-to-terminal transitions at SQL level**

For belt-and-suspenders safety, add a CHECK constraint:

```sql
-- This can't be enforced via CHECK constraint on the status column alone
-- because CHECK constraints only validate the new row value, not the old one.
-- The CAS WHERE clause is the enforcement mechanism.
```

The CAS pattern (`WHERE id = ? AND status = ?`) combined with `RowsAffected() == 0` check is the standard enforcement. A TRIGGER could provide additional SQL-level protection:

```sql
CREATE TRIGGER IF NOT EXISTS guard_terminal_dispatch_status
BEFORE UPDATE OF status ON dispatches
WHEN OLD.status IN ('completed', 'failed', 'cancelled', 'timeout')
BEGIN
    SELECT RAISE(ABORT, 'cannot transition from terminal dispatch status');
END;
```

This trigger prevents ANY update to the `status` column once the dispatch reaches a terminal state, regardless of whether the CAS guard is present in the application code.

### Fix for Bug 2 (Minimal): Just Add WHERE Guard

If the full transition validation is overkill for now, the minimal fix is:

```go
// Change line 232 from:
query := "UPDATE dispatches SET " + joinStrings(sets, ", ") + " WHERE id = ?"

// To:
query := "UPDATE dispatches SET " + joinStrings(sets, ", ") +
    " WHERE id = ? AND status NOT IN ('completed', 'failed', 'cancelled', 'timeout')"
```

This prevents overwriting terminal states. Combined with checking `RowsAffected`, the caller knows a concurrent transition happened.

---

## 8. Severity Assessment

### Bug 1: Non-Atomic Gate Check + Phase Update

**Theoretical severity:** HIGH — gate checks can pass on stale data, allowing invalid phase transitions.

**Practical severity with current architecture:** MEDIUM-LOW. Because:
1. `SetMaxOpenConns(1)` serializes all database access through Go's connection pool
2. The CLI is single-command (`ic run advance`), so concurrent Advance calls from the CLI are rare
3. The Clavain hub dispatches agents sequentially, not in parallel

**However:** The portfolio relay (`internal/portfolio/relay.go`) polls and advances child runs, and multiple agents can complete simultaneously. As the system scales to more concurrent dispatches, this becomes a real race.

**Recommendation:** Fix proactively. The transaction-wrapping approach is clean and matches existing patterns in the codebase (see `CreatePortfolio`, `CancelPortfolio`, and `Migrate` — all use transactions correctly).

### Bug 2: Missing CAS on Dispatch Status

**Theoretical severity:** MEDIUM — terminal status can be overwritten, corrupting the dispatch lifecycle.

**Practical severity:** MEDIUM. The `collect.go` and `spawn.go` files orchestrate dispatch lifecycle, and it's plausible for a timeout goroutine and a completion callback to race on status updates. The outcome aggregation (`outcome.go`) depends on accurate terminal statuses.

**Recommendation:** Fix immediately — the minimal fix (adding `AND status NOT IN (...)` to the WHERE clause) is a one-line change with no structural cost.

---

## 9. Sources

### Official Documentation
- [SQLite Transaction Documentation](https://www.sqlite.org/lang_transaction.html)
- [SQLite Isolation Documentation](https://sqlite.org/isolation.html)
- [SQLite Write-Ahead Logging](https://sqlite.org/wal.html)
- [SQLite File Locking and Concurrency](https://sqlite.org/lockingv3.html)
- [Go: Executing transactions](https://go.dev/doc/database/execute-transactions)
- [modernc.org/sqlite package docs](https://pkg.go.dev/modernc.org/sqlite)

### GitHub Issues
- [golang/go #19981: database/sql: add option to customize Begin statement](https://github.com/golang/go/issues/19981)
- [mattn/go-sqlite3 #400: Feature: BEGIN immediate/exclusive per transaction](https://github.com/mattn/go-sqlite3/issues/400)
- [mattn/go-sqlite3 #1179: Possible solutions to the concurrency problems](https://github.com/mattn/go-sqlite3/issues/1179)
- [mattn/go-sqlite3 #1238: Race conditions during unit tests](https://github.com/mattn/go-sqlite3/issues/1238)

### Blog Posts and Articles
- [SkyPilot: Abusing SQLite to Handle Concurrency](https://blog.skypilot.co/abusing-sqlite-to-handle-concurrency/)
- [Lawrence Jones: Use your database to power state machines](https://blog.lawrencejones.dev/state-machines/)
- [Victor Martinez: Event Sourcing in Go](https://victoramartinez.com/posts/event-sourcing-in-go/)
- [Building Event Sourcing Systems with SQLite: CQRS Guide](https://www.sqliteforum.com/p/building-event-sourcing-systems-with)
- [Ten Thousand Meters: SQLite concurrent writes and "database is locked" errors](https://tenthousandmeters.com/blog/sqlite-concurrent-writes-and-database-is-locked-errors/)
- [River Queue: Using with SQLite](https://riverqueue.com/docs/sqlite)
- [Optimistic Locking: Concurrency Control with a Version Column](https://medium.com/@sumit-s/optimistic-locking-concurrency-control-with-a-version-column-2e3db2a8120d)
- [Optimistic concurrency control (Wikipedia)](https://en.wikipedia.org/wiki/Optimistic_concurrency_control)
- [Concurrent commands in event sourcing (Michiel Rook)](https://www.michielrook.nl/2016/09/concurrent-commands-event-sourcing/)

### Go Libraries
- [hallgren/eventsourcing](https://github.com/hallgren/eventsourcing) — Go event sourcing with version-based optimistic concurrency
- [BenjaminPritchard/sql_state_machine](https://github.com/BenjaminPritchard/sql_state_machine) — SQLite as a state machine with append-only log
