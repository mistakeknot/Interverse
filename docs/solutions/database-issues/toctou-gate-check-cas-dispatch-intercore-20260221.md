---
module: intercore
date: 2026-02-21
problem_type: database_issue
component: database
symptoms:
  - "Gate evaluation reads (CountArtifacts, CountActiveAgents, HasVerdict) are not transactional with the subsequent UpdatePhase write"
  - "Dispatch UpdateStatus can overwrite a terminal status (e.g., completed → failed) because WHERE clause lacks prior-status guard"
  - "Concurrent goroutines can interleave between gate check and phase update, allowing invalid phase transitions"
root_cause: thread_violation
framework_version: 1.22.0
resolution_type: code_fix
severity: high
tags: [sqlite, toctou, cas, optimistic-concurrency, transaction, go, begintx, querier-interface]
---

# Troubleshooting: TOCTOU in Gate-Phase Advance + Missing CAS on Dispatch Status

## Problem

Two P1 TOCTOU bugs in intercore's Go+SQLite orchestration kernel. Bug 1: `Advance()` runs gate evaluation (multiple SELECTs across 4 querier interfaces) and then `UpdatePhase()` as separate operations with no enclosing transaction — state can change between check and write. Bug 2: `UpdateStatus()` on dispatches reads `prevStatus` but the UPDATE WHERE clause only matches on `id`, not `status`, allowing concurrent overwrites of terminal states.

## Environment
- Module: intercore (Go + SQLite orchestration kernel)
- Framework Version: Go 1.22 with modernc.org/sqlite
- Affected Component: `internal/phase/machine.go:Advance()`, `internal/dispatch/dispatch.go:UpdateStatus()`
- Date: 2026-02-21

## Symptoms
- Gate evaluation reads happen outside the transaction that updates the phase, creating a TOCTOU window
- Dispatch status can be overwritten from terminal → non-terminal (e.g., `completed → failed`)
- With `SetMaxOpenConns(1)`, the race is unlikely in practice but becomes real under portfolio relay or concurrent agent completions

## What Didn't Work

**CAS guard alone (Bug 2 initial attempt):** Adding `AND status = ?` to the UPDATE WHERE clause prevents a *different* goroutine from racing, but doesn't prevent a goroutine from legitimately reading `prevStatus=completed` and then writing `status=failed` with `WHERE status='completed'` — which matches. The CAS guard is necessary but not sufficient; terminal-state rejection must be added separately.

## Solution

### Bug 1: Tx-Scoped Querier Wrappers for Atomic Gate+Phase

The challenge: `evaluateGate()` uses 4 querier interfaces (`RuntrackQuerier`, `VerdictQuerier`, `PortfolioQuerier`, `DepQuerier`) whose implementations live in different packages and operate on `*sql.DB`. To run gate checks inside the same transaction as the phase update, we need tx-aware variants.

**Pattern: Tx-scoped querier wrappers that duplicate SQL**

```go
// Querier is satisfied by both *sql.DB and *sql.Tx.
type Querier interface {
    ExecContext(ctx context.Context, query string, args ...interface{}) (sql.Result, error)
    QueryContext(ctx context.Context, query string, args ...interface{}) (*sql.Rows, error)
    QueryRowContext(ctx context.Context, query string, args ...interface{}) *sql.Row
}

// txRuntrackQuerier runs runtrack queries on a transaction.
type txRuntrackQuerier struct{ q Querier }

func (t *txRuntrackQuerier) CountArtifacts(ctx context.Context, runID, phase string) (int, error) {
    var count int
    err := t.q.QueryRowContext(ctx,
        `SELECT COUNT(*) FROM run_artifacts WHERE run_id = ? AND phase = ? AND status = 'active'`,
        runID, phase).Scan(&count)
    return count, err
}
```

**Advance() now wraps everything in BeginTx/Commit:**

```go
func Advance(ctx, store, runID, cfg, rt, vq, pq, dq, callback) (*AdvanceResult, error) {
    tx, err := store.BeginTx(ctx)
    defer tx.Rollback()

    run, err := store.GetQ(ctx, tx, runID)         // read on tx
    txRT := &txRuntrackQuerier{q: tx}               // gate checks on tx
    gateResult, ... := evaluateGate(ctx, run, ..., txRT, txVQ, txPQ, txDQ)
    store.UpdatePhaseQ(ctx, tx, runID, from, to)    // write on tx
    store.AddEventQ(ctx, tx, &PhaseEvent{...})      // event on tx
    tx.Commit()                                      // atomic unit

    callback(...)                                    // OUTSIDE tx
}
```

**Key design decision:** The tx-scoped wrappers duplicate SQL from `runtrack.Store` and `dispatch.Store`. This is intentional — it avoids circular package dependencies (`phase → runtrack → phase`) and keeps the querier interfaces unchanged. The SQL is simple COUNT/SELECT queries unlikely to drift.

### Bug 2: Terminal-State Rejection + CAS Guard

Two-layer defense:

```go
// Layer 1: Reject transitions from terminal states (Go-level)
if isTerminalStatus(prevStatus) {
    return ErrStaleStatus
}

// Layer 2: CAS guard in SQL (prevents concurrent races)
query := "UPDATE dispatches SET " + sets + " WHERE id = ? AND status = ?"
args = append(args, id, prevStatus)
// If RowsAffected() == 0, distinguish not-found from stale
```

The CAS guard alone is NOT sufficient because a goroutine that reads `prevStatus=completed` will match `WHERE status='completed'` — the transition succeeds. Terminal-state rejection must be checked at the application level before the UPDATE.

## Why This Works

1. **Bug 1 root cause:** SQLite provides serializable isolation *within a transaction*, but separate statements outside a transaction each see independent snapshots. Wrapping gate checks + phase update in one `BeginTx` eliminates the TOCTOU window entirely.

2. **Bug 2 root cause:** The UPDATE WHERE clause only matched on `id`, allowing any status overwrite. Adding `AND status = ?` makes the UPDATE conditional on expected state (optimistic concurrency). The terminal-state rejection adds a Go-level guard that prevents even "valid-looking" transitions out of final states.

3. **Why `SetMaxOpenConns(1)` doesn't fully protect:** It serializes connection access at the Go level, but between releasing and re-acquiring the connection (between separate SQL statements), another goroutine can interleave. Only a transaction boundary prevents this.

## Prevention

- **Always wrap check-then-act database patterns in a transaction.** If you SELECT to make a decision and then UPDATE based on that decision, both must be in the same `BeginTx`/`Commit` block.
- **Status columns with terminal states need CAS guards.** Any `UPDATE ... SET status = ?` should include `AND status = ?` with the expected prior status, plus check `RowsAffected()`.
- **Terminal-state rejection is separate from CAS.** CAS prevents concurrent races; terminal-state rejection prevents legitimate-looking but invalid transitions. You need both.
- **When querier interfaces cross package boundaries**, use tx-scoped wrappers that duplicate SQL rather than adding transaction parameters to the interface (avoids coupling).
- **Callbacks/side-effects fire OUTSIDE the transaction.** The `eventRecorder` and `PhaseEventCallback` are fire-and-forget and must not hold the transaction open.

## Related Issues

- See also: [CAS Dispatch Linking with Orphan Process Cleanup](../patterns/cas-spawn-link-orphan-cleanup-20260219.md) — related CAS pattern for dispatch linking
- Research: `docs/research/research-sqlite-event-sourcing-bugs.md` — full literature review of SQLite concurrency patterns
- Research: `docs/research/research-toctou-in-multi-agent-coding.md` — industry evidence for TOCTOU failures in multi-agent systems
