# Plan: Fix TOCTOU Bugs in Intercore

**Beads:** iv-ibdc (gate check), iv-mokx (dispatch CAS)
**Sprint Bead:** iv-6an0
**Phase:** planned

## Overview

Two P1 TOCTOU bugs in intercore's Go codebase. Both have documented solutions in `docs/research/research-sqlite-event-sourcing-bugs.md`. Both are surgical fixes — no new schema, no API changes.

## Task 1: Add CAS Guard to Dispatch UpdateStatus (iv-mokx)

**File:** `internal/dispatch/dispatch.go` (lines 200-259)
**Effort:** Small (one-line SQL change + error sentinel + tests)

### Current Problem

`UpdateStatus` reads `prevStatus` (line 210-211) but the UPDATE at line 232 uses `WHERE id = ?` without checking prior status. A concurrent goroutine can overwrite a terminal status (e.g., completed → failed).

### Fix

1. **Add `AND status = ?` to the UPDATE WHERE clause** (line 232):
   - Change: `"UPDATE dispatches SET " + ... + " WHERE id = ?"` → `"UPDATE dispatches SET " + ... + " WHERE id = ? AND status = ?"`
   - Add `prevStatus` to args (after `id`)
   - The existing `RowsAffected() == 0` check at line 241 now catches concurrent status changes

2. **Add `ErrStaleStatus` sentinel** for the concurrent-change case:
   - When `RowsAffected() == 0`, re-read to distinguish "not found" from "status changed"
   - Pattern: same as `store.go:UpdatePhase` (lines 157-163)

3. **Add tests:**
   - `TestUpdateStatus_CAS_RejectsTerminalOverwrite` — create dispatch, set to completed, attempt set to failed → expect error
   - `TestUpdateStatus_CAS_AllowsValidTransition` — spawned → running → completed works normally

### Files Changed
- `internal/dispatch/dispatch.go` — UpdateStatus method

## Task 2: Wrap Gate Check + Phase Update in Transaction (iv-ibdc)

**File:** `internal/phase/machine.go` (lines 46-205), `internal/phase/store.go`, `internal/phase/gate.go`
**Effort:** Medium (interface refactoring + transaction wrapping)

### Current Problem

`Advance()` calls `evaluateGate()` (line 117) which runs multiple SELECTs across `rt`, `vq`, `pq`, `dq` queriers, then calls `store.UpdatePhase()` (line 167) — no enclosing transaction. State can change between gate evaluation and phase update.

### Fix

The key challenge: `evaluateGate` uses 4 querier interfaces (`RuntrackQuerier`, `VerdictQuerier`, `PortfolioQuerier`, `DepQuerier`) that currently operate on `*sql.DB`. To run gate checks inside a transaction, these must accept a `Querier` interface that works with both `*sql.DB` and `*sql.Tx`.

**Step 1: Add `Querier` interface to phase package** (gate.go)

```go
// Querier is satisfied by both *sql.DB and *sql.Tx.
type Querier interface {
    ExecContext(ctx context.Context, query string, args ...interface{}) (sql.Result, error)
    QueryContext(ctx context.Context, query string, args ...interface{}) (*sql.Rows, error)
    QueryRowContext(ctx context.Context, query string, args ...interface{}) *sql.Row
}
```

**Step 2: Add tx-aware methods to Store** (store.go)

Add `UpdatePhaseQ(ctx, q Querier, ...)` and `GetQ(ctx, q Querier, ...)` and `AddEventQ(ctx, q Querier, ...)` — same logic, parameterized by querier. The original methods delegate to these with `s.db`.

**Step 3: Add tx-aware gate querier interfaces** (gate.go)

Add `RuntrackTxQuerier`, `VerdictTxQuerier`, etc. — same methods but accepting a `Querier` parameter. Or: make the existing interfaces optionally tx-aware by adding a `WithQuerier(q Querier) T` method.

**Simpler approach (preferred):** Since `evaluateGate` already receives the querier interfaces as parameters, we can pass tx-wrapped implementations. Add `RuntrackQuerier.WithTx(*sql.Tx)` method that returns a tx-scoped implementation.

**Actually simplest approach:** Wrap the entire advance sequence in a transaction at the `Store` level. Add `Store.AdvanceAtomic()` that:
1. `BeginTx`
2. Read run state on tx
3. Pass tx to gate evaluation
4. UpdatePhase on tx
5. AddEvent on tx
6. UpdateStatus on tx (if terminal)
7. Commit
8. Fire callback outside tx

This requires making gate queries work with a tx. The querier interfaces need a `Q` variant:

```go
type RuntrackQuerier interface {
    CountArtifacts(ctx context.Context, runID, phase string) (int, error)
    CountActiveAgents(ctx context.Context, runID string) (int, error)
}
```

These methods currently run on `*sql.DB` internally. To make them work on a tx, the implementations (in `runtrack.Store` and `dispatch.Store`) need variants that accept a querier.

**Practical approach — minimize interface changes:**

The 4 querier interfaces have methods like `CountArtifacts(ctx, runID, phase)`. These implementations in `runtrack.Store` and `dispatch.Store` use `s.db.QueryRowContext(...)` internally. The fix:

1. Add a `DB() *sql.DB` method to both `runtrack.Store` and `dispatch.Store` (they already expose the db)
2. In `Advance`, `BeginTx` on the phase store's db
3. Create tx-scoped wrappers for the querier interfaces
4. These wrappers call the same SQL but on the tx instead of s.db

**Step 3: Transaction-scoped querier wrappers** (new file: `internal/phase/tx_queriers.go`)

```go
// txRuntrackQuerier wraps runtrack queries to run on a transaction.
type txRuntrackQuerier struct{ q Querier }
func (t *txRuntrackQuerier) CountArtifacts(ctx context.Context, runID, phase string) (int, error) { ... }
func (t *txRuntrackQuerier) CountActiveAgents(ctx context.Context, runID string) (int, error) { ... }

// txVerdictQuerier wraps verdict queries to run on a transaction.
type txVerdictQuerier struct{ q Querier }
func (t *txVerdictQuerier) HasVerdict(ctx context.Context, scopeID string) (bool, error) { ... }
```

The SQL for these is simple (already known from gate.go and runtrack/dispatch stores):
- `CountArtifacts`: `SELECT COUNT(*) FROM run_artifacts WHERE run_id = ? AND phase = ? AND status = 'active'`
- `CountActiveAgents`: `SELECT COUNT(*) FROM run_agents WHERE run_id = ? AND status = 'active'`
- `HasVerdict`: `SELECT COUNT(*) FROM dispatches WHERE scope_id = ? AND verdict_status IS NOT NULL AND verdict_status != 'reject'`
- `GetChildren`: `SELECT ... FROM runs WHERE parent_run_id = ?`
- `GetUpstream`: already uses `dq.GetUpstream` — the dep store's SQL

**Step 4: Refactor `Advance` to use transaction** (machine.go)

Wrap lines 47-193 in a BeginTx/Commit:

```go
func Advance(ctx, store, runID, cfg, rt, vq, pq, dq, callback) (*AdvanceResult, error) {
    tx, err := store.db.BeginTx(ctx, nil)
    if err != nil { return nil, ... }
    defer tx.Rollback()

    run, err := store.GetQ(ctx, tx, runID)       // read on tx
    // ... terminal checks, chain resolution ...

    // Gate evaluation uses tx-scoped queriers
    txRT := &txRuntrackQuerier{q: tx}
    txVQ := &txVerdictQuerier{q: tx}
    txPQ := &txPortfolioQuerier{q: tx}
    txDQ := ... // DepQuerier needs access to portfolio.deps table

    gateResult, ... := evaluateGate(ctx, run, cfg, from, to, txRT, txVQ, txPQ, txDQ)

    // Phase update on tx
    store.UpdatePhaseQ(ctx, tx, runID, fromPhase, toPhase)

    // Event recording on tx
    store.AddEventQ(ctx, tx, &PhaseEvent{...})

    // Terminal completion on tx
    if ChainIsTerminal(...) {
        store.UpdateStatusQ(ctx, tx, runID, StatusCompleted)
    }

    tx.Commit()

    // Callback fires outside tx
    if callback != nil { callback(...) }
}
```

**Step 5: Expose `store.db` for tx creation** — Add `Store.BeginTx()` method (store.go)

The `Advance` function needs to create a transaction on `store.db`, but `db` is unexported. Add:
```go
func (s *Store) BeginTx(ctx context.Context) (*sql.Tx, error) {
    return s.db.BeginTx(ctx, nil)
}
```

**Step 6: Tests**
- `TestAdvance_Atomic_GateAndPhaseUpdate` — verify that gate check and phase update happen atomically (hard to test concurrency in unit tests, but verify the transaction path works)
- Existing tests must still pass (they use `nil` queriers with Priority 4, which bypasses gates entirely — no change needed)

### Files Changed
- `internal/phase/gate.go` — add `Querier` interface
- `internal/phase/store.go` — add `BeginTx`, `GetQ`, `UpdatePhaseQ`, `AddEventQ`, `UpdateStatusQ`
- `internal/phase/machine.go` — refactor `Advance` to use transaction
- `internal/phase/tx_queriers.go` (new) — tx-scoped querier wrappers

## Task 3: Run Tests and Verify

```bash
cd /root/projects/Interverse/infra/intercore
go test ./...
go test -race ./...
```

Verify all existing tests pass. Run integration tests:
```bash
bash test-integration.sh
```

## Execution Order

1. Task 1 first (dispatch CAS) — smaller, self-contained, no interface changes
2. Task 2 second (gate atomicity) — larger refactoring, builds on established patterns
3. Task 3 — verify everything

## Risk Assessment

- **Task 1:** Risk 1/5. One-line SQL change + error handling. Can't break anything.
- **Task 2:** Risk 2/5. Interface refactoring touches multiple files but follows existing patterns (see `CreatePortfolio` and `CancelPortfolio` in store.go — both use transactions correctly). The tx-scoped querier wrappers duplicate SQL from runtrack/dispatch stores, but this is intentional (keeps the interface clean without coupling packages).
- **Overall:** Both fixes are defense-in-depth. With `SetMaxOpenConns(1)`, the races are unlikely in practice, but the fixes prevent future problems if concurrency increases.
