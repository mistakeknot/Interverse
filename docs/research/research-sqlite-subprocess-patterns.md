# Research: SQLite + External Subprocess Transaction Coordination

## Problem Statement

Our system (Go + SQLite + Git) needs to perform a multi-step operation:

1. Acquire a merge lock
2. Run `git apply --3way` (external subprocess, 100ms-5s)
3. Create a git commit (external subprocess)
4. Update SQLite (`run.head_commit = new_commit_sha`)
5. Emit a `DispatchCommitted` event to SQLite

**The dilemma:** wrapping steps 1-5 in `BEGIN IMMEDIATE` holds the SQLite write lock for the full duration of git operations, blocking all other writers (and with `SetMaxOpenConns(1)`, all readers too). Our `busy_timeout` is 100ms, which is far too short for git operations that can take seconds.

But *not* wrapping them means steps 3 and 4 aren't atomic -- a crash between git commit and SQLite update leaves the two substrates (Git and SQLite) diverged with no recovery path.

---

## 1. The "Intent Record" Pattern (a.k.a. Transactional Outbox)

### What It Is

This is a well-established pattern in distributed systems, most commonly known as the **Transactional Outbox Pattern**. The core idea: write an intent record to the database *before* performing the external operation, then update the record *after* the operation completes. On crash recovery, scan for intents without completions.

The pattern has several names depending on context:
- **Transactional Outbox** (microservices literature)
- **Staged Jobs** (Brandur Leach's terminology, used at Stripe)
- **Idempotency Keys with Recovery Points** (Stripe's API design)
- **Write-Ahead Intent** (database internals terminology, by analogy with WAL)
- **Saga with Orchestration** (when there are compensating transactions)

### Who Uses It

- **Stripe**: Their idempotency key system uses "atomic phases" separated by "foreign state mutations." Each atomic phase is a database transaction. Between phases, external API calls happen. Recovery points are stored in the database so retries can resume from the last successful checkpoint. See [Brandur's detailed writeup](https://brandur.org/idempotency-keys).

- **River Queue** (Go job queue): River's transactional enqueueing pattern writes job records atomically with business data, then a separate worker processes them. Their [SQLite documentation](https://riverqueue.com/docs/sqlite) explicitly recommends this for coordinating database changes with external effects.

- **Outbox implementations in Go**: Libraries like [github.com/oagudo/outbox](https://pkg.go.dev/github.com/oagudo/outbox) (supports SQLite) and [github.com/pkritiotis/go-outbox](https://github.com/pkritiotis/go-outbox) implement the pattern generically.

- **Three Dots Labs** (Go consultancy): Their [distributed transactions guide](https://threedots.tech/post/distributed-transactions-in-go/) recommends the outbox pattern as the primary solution for coordinating database changes with external effects in Go.

### How It Applies to Our System

```
Phase 1: Record Intent (short SQLite transaction)
  BEGIN IMMEDIATE
    INSERT INTO merge_intents (dispatch_id, base_commit, patch_path, status)
    VALUES (?, ?, ?, 'pending')
  COMMIT

Phase 2: External Work (no SQLite lock held)
  git apply --3way <patch>
  git commit -m "..."
  -> produces new_commit_sha

Phase 3: Record Completion (short SQLite transaction)
  BEGIN IMMEDIATE
    UPDATE runs SET head_commit = ? WHERE id = ?
    INSERT INTO events (type, ...) VALUES ('DispatchCommitted', ...)
    UPDATE merge_intents SET status = 'completed', result_commit = ?
      WHERE dispatch_id = ?
  COMMIT
```

**Recovery on crash:**
```go
// At startup or periodically:
rows := db.Query("SELECT * FROM merge_intents WHERE status = 'pending'")
for rows.Next() {
    intent := scanIntent(rows)
    // Check if git commit actually happened
    if commitExists(intent.ResultCommit) {
        // External work succeeded, just update SQLite
        completeIntent(intent)
    } else {
        // External work didn't complete -- either retry or mark failed
        // git apply is idempotent if worktree is clean
        retryOrFail(intent)
    }
}
```

### Strengths
- SQLite write lock held for milliseconds, not seconds
- Crash-safe: intent records survive crashes and enable recovery
- Well-proven pattern with extensive production use
- Natural fit for our event-sourced kernel design

### Weaknesses
- More complex than a single transaction
- Recovery logic must be correct and tested
- Requires idempotent external operations (or at least detection of prior completion)

---

## 2. The "External-First, Then Short Transaction" Pattern

### What It Is

Do all external work first (git apply + commit), then open a brief SQLite transaction to record the result and verify no conflicts. This is sometimes called "optimistic execution with pessimistic commit."

```
Step 1: Acquire application-level merge lock (sync.Mutex)
Step 2: git apply --3way <patch>   (external, no DB lock)
Step 3: git commit -m "..."        (external, no DB lock)
         -> produces new_commit_sha
Step 4: BEGIN IMMEDIATE
          -- Verify no one else merged while we were working
          SELECT head_commit FROM runs WHERE id = ?
          -- If head_commit changed, ROLLBACK and retry
          UPDATE runs SET head_commit = new_commit_sha WHERE id = ?
          INSERT INTO events (...)
        COMMIT
Step 5: Release merge lock
```

### Risks

1. **Crash between step 3 and step 4**: Git commit exists but SQLite doesn't know about it. The substrates are diverged.

2. **Mitigation via git inspection**: On recovery, compare `git log --oneline -1` with `runs.head_commit`. If they differ, the last git commit was "orphaned" -- the system can either adopt it into SQLite or reset git to match SQLite.

3. **Requires application-level lock**: The `sync.Mutex` serializes merge operations at the Go level, preventing concurrent merges. This is fine since merges should be serialized anyway (they modify HEAD).

### Strengths
- Simpler than the intent-record pattern
- SQLite write lock held for only the final atomic update
- Natural fit with single-writer merge queue

### Weaknesses
- Crash recovery is ad-hoc (inspect git state vs. SQLite state)
- No explicit audit trail of "what was attempted"
- Relies on application-level mutex surviving process restarts (it doesn't -- the mutex is in-memory)

### When to Choose This
When the system already has a single-writer merge queue with an application-level lock, and crash recovery can be handled by comparing git HEAD with SQLite's recorded `head_commit` at startup.

---

## 3. Separate Connections: Read Pool + Write Pool

### What It Is

The standard Go+SQLite pattern recommended by [modernc.org/sqlite documentation](https://theitsolutions.io/blog/modernc.org-sqlite-with-go), [River Queue](https://riverqueue.com/docs/sqlite), and [High Performance SQLite](https://highperformancesqlite.com/watch/busy-timeout).

Create two `*sql.DB` instances:

```go
type DB struct {
    // Writer: single connection, IMMEDIATE transactions
    writer *sql.DB
    // Reader: multiple connections for concurrent reads
    reader *sql.DB
}

func NewDB(path string) (*DB, error) {
    connStr := fmt.Sprintf("file:%s?_pragma=journal_mode(WAL)&_pragma=busy_timeout(5000)&_txlock=immediate", path)

    writer, _ := sql.Open("sqlite", connStr)
    writer.SetMaxOpenConns(1)  // Single writer

    reader, _ := sql.Open("sqlite", connStr)
    reader.SetMaxOpenConns(4)  // Multiple readers

    return &DB{writer: writer, reader: reader}, nil
}
```

### WAL Mode Implications

In WAL mode:
- **Readers never block writers** and vice versa
- Multiple readers can run concurrently, each seeing a consistent snapshot
- Only one writer can be active at a time (SQLite's fundamental constraint)
- The WAL file grows during write activity; checkpointing compacts it

With separate connections:
- Reader connections use the reader pool (concurrent, never blocked by writes)
- Writer connections use the single-connection writer pool
- Even if the writer holds a long transaction, readers continue unblocked

### Impact on Our Problem

Separate connections **help with read availability** during merges but **don't solve the core problem** of holding the write lock during git operations. The writer is still blocked. However, they ensure that other parts of the system (status queries, event reads, dispatch polling) continue to function even during long merge operations.

**This should be adopted regardless of which coordination pattern we choose.** It's orthogonal and universally beneficial.

### Current State in Our Codebase

The `intermute` service's race test (`services/intermute/internal/storage/sqlite/race_test.go`) already uses `SetMaxOpenConns(1)` with WAL mode for write serialization. The production `New()` function in `sqlite.go` does *not* currently configure WAL mode, busy_timeout, or separate read/write pools -- this is a gap.

---

## 4. busy_timeout Tuning

### The Problem with 100ms

Our current `busy_timeout` of 100ms is far too low for production use. Research consistently shows:

- **5000ms (5 seconds)** is the standard production recommendation ([High Performance SQLite](https://highperformancesqlite.com/watch/busy-timeout), [River Queue](https://riverqueue.com/docs/sqlite), [OneUptime](https://oneuptime.com/blog/post/2026-02-02-sqlite-production-setup/view))
- Some production systems use **60 seconds** for workloads with occasional long writes
- The [10,000 meters blog](https://tenthousandmeters.com/blog/sqlite-concurrent-writes-and-database-is-locked-errors/) found that "anything below 5 seconds led to occasional errors given enough concurrent write transactions"

### The BEGIN IMMEDIATE Requirement

A critical subtlety explained by [Bert Hubert](https://berthub.eu/articles/posts/a-brief-post-on-sqlite3-database-locked-despite-timeout/): when a transaction starts with plain `BEGIN` (deferred) and later tries to upgrade from read to write, **SQLite returns SQLITE_BUSY immediately without respecting busy_timeout**. This happens because:

1. Connection A starts `BEGIN` (deferred), does a SELECT (gets SHARED lock)
2. Connection B starts `BEGIN IMMEDIATE` (gets RESERVED lock), does writes
3. Connection A tries INSERT/UPDATE -- SQLite must upgrade SHARED -> RESERVED
4. **Immediate SQLITE_BUSY** -- busy_timeout is NOT consulted

The fix: **always use `BEGIN IMMEDIATE`** for transactions that will write. In Go with modernc.org/sqlite, set this via the connection string:

```
file:path.db?_txlock=immediate
```

### Recommendation for Our System

```go
connStr := fmt.Sprintf(
    "file:%s?_pragma=journal_mode(WAL)&_pragma=busy_timeout(5000)&_txlock=immediate&_pragma=synchronous(NORMAL)",
    path,
)
```

- `busy_timeout=5000`: 5-second wait before SQLITE_BUSY
- `_txlock=immediate`: All transactions start as write transactions (no upgrade failures)
- `journal_mode=WAL`: Concurrent reads during writes
- `synchronous=NORMAL`: Balanced durability/performance (WAL mode already provides crash safety)

Even with a 5-second busy_timeout, we should NOT hold the write lock during git operations (which can take 1-5 seconds). The busy_timeout is a safety net for brief contention, not a license to hold locks for seconds.

---

## 5. Prior Art: How Existing Systems Handle This

### Fossil SCM

Fossil (SQLite's own VCS, created by the same author) takes the approach of **keeping everything inside SQLite**. Artifacts (file blobs, manifests, etc.) are stored as compressed BLOBs in the `blob` table. Since there's no external filesystem state to coordinate with, the problem doesn't arise -- everything is a single SQLite transaction.

Key insight from [Fossil's technical overview](https://fossil-scm.org/home/doc/tip/www/tech_overview.wiki): "SQLite updates are atomic, so even in the event of a system crash or power failure the repository content is protected." Fossil avoids the coordination problem by eliminating external state entirely.

Fossil does hold write transactions during hook execution (before-commit, after-receive), and the documentation notes that WAL mode is required for hooks that need to read the database while the write transaction is held.

**Lesson for us:** We can't eliminate git as an external substrate, but we should minimize the window where both substrates need to be consistent. The intent-record pattern achieves this.

### Litestream

[Litestream](https://litestream.io/how-it-works/) takes over SQLite's checkpointing process. It holds a long-running read transaction to prevent other processes from checkpointing, then copies WAL pages to a "shadow WAL" and manages checkpointing itself.

Litestream's approach to coordination: it doesn't need to coordinate SQLite transactions with external effects. Instead, it asynchronously replicates committed transactions. The replication is eventually consistent -- a crash during replication loses only uncommitted WAL pages, and recovery replays from the last successful replica position.

**Lesson for us:** Asynchronous reconciliation (rather than synchronous two-phase commit) is the pragmatic approach for single-node systems.

### rqlite

[rqlite](https://rqlite.io/docs/faq/) wraps SQLite behind Raft consensus for distributed replication. Each write is proposed via Raft, and only after a quorum agrees is the SQLite statement executed. This is a two-phase approach: propose-then-commit.

**Lesson for us:** rqlite serializes all writes through a single leader, similar to our merge queue design. The key difference is that rqlite's external coordination is purely network I/O (Raft RPCs), not subprocess calls.

### LiteFS

[LiteFS](https://fly.io/docs/litefs/how-it-works/) is a FUSE filesystem that intercepts SQLite writes at the VFS level, capturing transactions as LTX page sets for replication. It manages external state (replication to replicas) outside the SQLite transaction boundary.

LiteFS uses a TXID (transaction ID) cookie pattern for consistency tracking. When a write completes on the primary, the response includes the TXID. Subsequent reads on replicas check whether they've replicated up to that TXID before serving the request.

**Lesson for us:** The TXID/cursor pattern is analogous to our `head_commit` field -- a version marker that external systems can use to verify they're seeing the right state.

### River Queue (Go)

[River](https://riverqueue.com/docs/sqlite) implements the transactional outbox pattern natively. Jobs are enqueued within the same database transaction as business data changes. A separate worker process polls for enqueued jobs and executes them. Their SQLite configuration:

- `SetMaxOpenConns(1)` for the write pool
- `_txlock=immediate` for all transactions
- Keep transactions short (single-digit milliseconds)
- `busy_timeout=5000` as a safety net

River's [reliable workers documentation](https://riverqueue.com/docs/reliable-workers) explicitly addresses external side effects: "A work function may have called out to external systems... These changes will not roll back with a transaction." Their recommendation: design external calls to be idempotent.

**Lesson for us:** River validates our instinct that short transactions + idempotent external calls is the right pattern for Go+SQLite.

### Brandur Leach's Idempotency Keys (Stripe)

[Brandur's article](https://brandur.org/idempotency-keys) describes Stripe's pattern for coordinating database transactions with external API calls:

1. Each operation has a state machine with named "recovery points"
2. An "atomic phase" is a database transaction between two external calls
3. Before each external call, the recovery point is saved in the database
4. On retry, the state machine jumps to the last saved recovery point
5. Each external call carries its own idempotency key to prevent double-execution

The state machine looks like:

```
loop do
  case key.recovery_point
  when RECOVERY_POINT_STARTED
    atomic_phase(key) { create_ride_record }
  when RECOVERY_POINT_RIDE_CREATED
    # External API call (outside any DB transaction)
    call_stripe_api(idempotency_key: key.id)
  when RECOVERY_POINT_CHARGE_CREATED
    atomic_phase(key) { update_ride_as_charged }
  when RECOVERY_POINT_FINISHED
    break
  end
end
```

**Lesson for us:** This is the most rigorous version of the intent-record pattern. For our simpler case (one external operation: git apply + commit), we don't need the full state machine -- just a pending/completed intent record.

---

## 6. Go-Specific Patterns with modernc.org/sqlite

### Connection String Configuration

```go
import (
    "database/sql"
    _ "modernc.org/sqlite"
)

func openDB(path string) (*sql.DB, *sql.DB, error) {
    base := fmt.Sprintf("file:%s?_pragma=journal_mode(WAL)&_pragma=busy_timeout(5000)&_pragma=synchronous(NORMAL)", path)

    // Writer: single connection, immediate transactions
    writer, err := sql.Open("sqlite", base+"&_txlock=immediate")
    if err != nil {
        return nil, nil, err
    }
    writer.SetMaxOpenConns(1)

    // Reader: multiple connections, no txlock needed
    reader, err := sql.Open("sqlite", base)
    if err != nil {
        return nil, nil, err
    }
    reader.SetMaxOpenConns(4)

    return writer, reader, nil
}
```

### Application-Level Merge Lock

Since Go's `sync.Mutex` doesn't survive process restarts, and since we need the merge lock to also protect the git working tree (an external resource), use a combination:

```go
type MergeQueue struct {
    mu     sync.Mutex      // In-process serialization
    writer *sql.DB          // SQLite writer pool (MaxOpenConns=1)
}

func (mq *MergeQueue) Merge(ctx context.Context, dispatchID string, patch []byte) error {
    mq.mu.Lock()
    defer mq.mu.Unlock()

    // Phase 1: Record intent (short transaction)
    intentID, err := mq.recordIntent(ctx, dispatchID, patch)
    if err != nil {
        return fmt.Errorf("record intent: %w", err)
    }

    // Phase 2: External work (no SQLite lock)
    commitSHA, err := mq.applyAndCommit(ctx, patch)
    if err != nil {
        mq.failIntent(ctx, intentID, err)
        return fmt.Errorf("git operations: %w", err)
    }

    // Phase 3: Record completion (short transaction)
    if err := mq.completeIntent(ctx, intentID, dispatchID, commitSHA); err != nil {
        // CRITICAL: git commit exists but SQLite doesn't know
        // Log prominently; recovery will fix on next startup
        log.Printf("CRITICAL: merge intent %s committed as %s but SQLite update failed: %v",
            intentID, commitSHA, err)
        return fmt.Errorf("record completion: %w", err)
    }

    return nil
}
```

### Recovery on Startup

```go
func (mq *MergeQueue) RecoverPendingIntents(ctx context.Context) error {
    rows, err := mq.writer.QueryContext(ctx,
        "SELECT id, dispatch_id, expected_commit FROM merge_intents WHERE status = 'pending'")
    if err != nil {
        return err
    }
    defer rows.Close()

    for rows.Next() {
        var id, dispatchID, expectedCommit string
        rows.Scan(&id, &dispatchID, &expectedCommit)

        // Check if the git commit actually landed
        actualHead := getGitHead()

        if expectedCommit != "" && commitExists(expectedCommit) {
            // Phase 2 succeeded, Phase 3 didn't -- complete it now
            mq.completeIntent(ctx, id, dispatchID, expectedCommit)
        } else {
            // Phase 2 didn't complete -- mark as failed
            // The git working tree may be dirty; reset it
            resetGitToLastKnownGood(ctx)
            mq.failIntent(ctx, id, fmt.Errorf("incomplete after crash"))
        }
    }
    return rows.Err()
}
```

### The `merge_intents` Table

```sql
CREATE TABLE IF NOT EXISTS merge_intents (
    id            TEXT PRIMARY KEY,
    dispatch_id   TEXT NOT NULL,
    base_commit   TEXT NOT NULL,        -- HEAD at time of intent
    patch_hash    TEXT,                 -- SHA256 of the patch (for dedup)
    status        TEXT NOT NULL DEFAULT 'pending',  -- pending | completed | failed
    result_commit TEXT,                -- SHA of the git commit, if created
    error_message TEXT,
    created_at    TEXT NOT NULL DEFAULT (datetime('now')),
    completed_at  TEXT
);

CREATE INDEX IF NOT EXISTS idx_merge_intents_status ON merge_intents(status);
```

---

## 7. Concrete Recommendations for Our System

### Recommendation 1: Adopt the Intent-Record (Outbox) Pattern

**Priority: High**

This is the correct pattern for our use case. The merge operation becomes three short SQLite transactions with external work in between:

1. **Record intent** (SQLite transaction, ~1ms)
2. **Git apply + commit** (external, 100ms-5s, no SQLite lock)
3. **Record completion + emit event** (SQLite transaction, ~1ms)

Each SQLite transaction holds the write lock for milliseconds, not seconds. The intent record provides crash recovery. The `sync.Mutex` serializes concurrent merge attempts at the application level.

### Recommendation 2: Separate Read and Write Connection Pools

**Priority: High**

```go
writer.SetMaxOpenConns(1)   // Single writer
reader.SetMaxOpenConns(4)   // Multiple concurrent readers
```

This ensures that status queries, event reads, and dispatch polling continue to function even during merge operations. In WAL mode, readers never block writers and vice versa.

### Recommendation 3: Increase busy_timeout to 5000ms

**Priority: High**

Our current 100ms is far too low. Every production SQLite guide recommends 5000ms as the minimum. Even with the intent-record pattern (where write transactions are short), brief contention is normal and 100ms doesn't provide enough headroom.

### Recommendation 4: Use BEGIN IMMEDIATE Everywhere

**Priority: High**

Set `_txlock=immediate` on the writer connection string. This prevents the silent SQLITE_BUSY failure that occurs when a deferred transaction tries to upgrade from SHARED to RESERVED lock. See [Bert Hubert's explanation](https://berthub.eu/articles/posts/a-brief-post-on-sqlite3-database-locked-despite-timeout/).

### Recommendation 5: Make Git Operations Idempotent

**Priority: Medium**

For crash recovery to work, the git operations should be idempotent or at least detectable:

- **Detection**: After a crash, check if the git commit exists by inspecting `git log --oneline -1`. Compare with the `merge_intents.result_commit` field.
- **Idempotency**: If the working tree is dirty from an incomplete `git apply`, `git reset --hard` to the last known good commit before retrying.
- **Dedup**: Store a `patch_hash` in the intent record. If the same patch is submitted again, check whether a completed intent with that hash already exists.

### Recommendation 6: Recovery at Startup

**Priority: Medium**

On service startup, scan `merge_intents` for `status = 'pending'` records. For each:
- If the git commit exists: complete the intent (Phase 3 only)
- If the git commit doesn't exist: reset the worktree and mark the intent as failed

This handles the crash-between-Phase-2-and-Phase-3 scenario.

### Recommendation 7: WAL Mode + synchronous=NORMAL

**Priority: Medium**

```
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
```

WAL mode enables concurrent reads during writes. `synchronous=NORMAL` provides a balanced durability/performance tradeoff -- in WAL mode, committed transactions are durable even with `NORMAL` synchronous (the WAL is always synced on commit; `NORMAL` just means the main database file isn't synced on every checkpoint).

---

## 8. Pattern Comparison Matrix

| Criterion | Single Long Transaction | External-First + Short Tx | Intent Record (Outbox) |
|-----------|------------------------|--------------------------|----------------------|
| Write lock duration | Seconds (bad) | Milliseconds (good) | Milliseconds (good) |
| Crash safety | Full ACID (good) | Ad-hoc recovery (fair) | Intent-based recovery (good) |
| Complexity | Simple (good) | Moderate | Moderate |
| Audit trail | None | None | Full intent history (good) |
| Reader availability | Blocked (bad*) | Good | Good |
| Recovery automation | Automatic (rollback) | Manual inspection | Automatic (scan intents) |
| Concurrent merge safety | SQLite-level (good) | Requires sync.Mutex | Requires sync.Mutex |

*With `SetMaxOpenConns(1)`, readers are also blocked. With separate read/write pools in WAL mode, readers are not blocked even during long write transactions -- but the writer pool is still monopolized.

---

## 9. Anti-Patterns to Avoid

### Anti-Pattern 1: Holding SQLite Write Lock During Subprocesses

Never do this:

```go
tx, _ := db.BeginTx(ctx, nil)
exec.Command("git", "apply", "--3way", patchFile).Run()  // 100ms-5s with lock held!
exec.Command("git", "commit", "-m", msg).Run()           // more seconds with lock held!
tx.Exec("UPDATE runs SET head_commit = ?", sha)
tx.Commit()
```

This blocks all other writers (and with `MaxOpenConns(1)`, all readers) for the full duration of the git operations. With `busy_timeout=100ms`, other operations will fail with SQLITE_BUSY.

### Anti-Pattern 2: Using Deferred Transactions for Write Operations

```go
tx, _ := db.Begin()                    // Deferred -- starts as read-only
rows, _ := tx.Query("SELECT ...")      // Gets SHARED lock
tx.Exec("UPDATE ...")                  // IMMEDIATE SQLITE_BUSY (busy_timeout ignored!)
```

Always use `BEGIN IMMEDIATE` (via `_txlock=immediate` in the connection string) for transactions that will write.

### Anti-Pattern 3: Ignoring the Crash Window

```go
sha := gitCommit(patch)              // Git commit created
db.Exec("UPDATE runs SET head_commit = ?", sha)  // Crash here = diverged state
```

Without an intent record, a crash between these two lines leaves git and SQLite diverged with no automated recovery path.

### Anti-Pattern 4: Using a Single Connection Pool for Everything

```go
db.SetMaxOpenConns(1)  // Everything goes through one connection
// Now ALL reads are serialized behind ALL writes
```

Use separate read and write pools. Reads should never block on writes in WAL mode.

---

## 10. References

### Primary Sources

- [SQLite WAL Documentation](https://sqlite.org/wal.html)
- [SQLite Atomic Commit](https://sqlite.org/atomiccommit.html)
- [SQLite busy_timeout API](https://sqlite.org/c3ref/busy_timeout.html)
- [SQLite File Locking](https://sqlite.org/lockingv3.html)

### Production Configuration Guides

- [High Performance SQLite: Busy Timeout](https://highperformancesqlite.com/watch/busy-timeout)
- [River Queue: Using with SQLite](https://riverqueue.com/docs/sqlite)
- [OneUptime: SQLite Production Setup](https://oneuptime.com/blog/post/2026-02-02-sqlite-production-setup/view)
- [Forward Email: SQLite Performance Optimization](https://forwardemail.net/en/blog/docs/sqlite-performance-optimization-pragma-chacha20-production-guide)
- [SQLite in Production (Sophisticated Simplicity)](https://shivekkhurana.com/blog/sqlite-in-production/)

### Pattern Descriptions

- [Brandur Leach: Implementing Stripe-like Idempotency Keys](https://brandur.org/idempotency-keys)
- [Brandur Leach: Using Atomic Transactions to Power an Idempotent API](https://brandur.org/http-transactions)
- [Transactional Outbox Pattern (microservices.io)](https://microservices.io/patterns/data/transactional-outbox.html)
- [Three Dots Labs: Distributed Transactions in Go](https://threedots.tech/post/distributed-transactions-in-go/)

### SQLite Concurrency Deep Dives

- [Bert Hubert: SQLITE_BUSY Despite Setting a Timeout](https://berthub.eu/articles/posts/a-brief-post-on-sqlite3-database-locked-despite-timeout/)
- [10,000 Meters: SQLite Concurrent Writes](https://tenthousandmeters.com/blog/sqlite-concurrent-writes-and-database-is-locked-errors/)
- [Fly.io: SQLite Internals (Rollback Journal)](https://fly.io/blog/sqlite-internals-rollback-journal/)
- [Simon Willison on SQLite Busy](https://simonwillison.net/tags/sqlite-busy/)

### Prior Art Systems

- [Fossil SCM Technical Overview](https://fossil-scm.org/home/doc/tip/www/tech_overview.wiki)
- [Litestream: How It Works](https://litestream.io/how-it-works/)
- [LiteFS: How It Works](https://fly.io/docs/litefs/how-it-works/)
- [River Queue: Reliable Workers](https://riverqueue.com/docs/reliable-workers)

### Go + SQLite

- [modernc.org/sqlite Documentation](https://pkg.go.dev/modernc.org/sqlite)
- [modernc.org/sqlite with Go](https://theitsolutions.io/blog/modernc.org-sqlite-with-go)
- [Go SQLite: Managing Connections](https://go.dev/doc/database/manage-connections)
- [go-sqlite3 Concurrency Issues](https://gist.github.com/mrnugget/0eda3b2b53a70fa4a894)

### Internal References

- [TOCTOU Analysis: Git+Kernel Snapshot Transactions](/root/projects/Interverse/docs/research/toctou-analysis.md)
- [Intermute SQLite Race Test](/root/projects/Interverse/services/intermute/internal/storage/sqlite/race_test.go)
- [Intermute SQLite Store](/root/projects/Interverse/services/intermute/internal/storage/sqlite/sqlite.go)
