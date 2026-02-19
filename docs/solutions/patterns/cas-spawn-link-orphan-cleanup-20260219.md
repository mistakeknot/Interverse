---
module: intercore
date: 2026-02-19
problem_type: concurrency_pattern
component: event/spawn, runtrack, dispatch
symptoms:
  - "Two concurrent ic run advance invocations spawn duplicate agent processes"
  - "Failed UpdateAgentDispatch leaves orphan OS process running with no DB record linking"
  - "Agent appears unlinked (dispatch_id NULL) after spawn, triggers re-spawn on retry"
root_cause: toctou_race_and_orphan_resource
resolution_type: pattern
severity: medium
tags: [sqlite, concurrency, cas, spawn, orphan-cleanup, single-connection, go]
---

# CAS Dispatch Linking with Orphan Process Cleanup

## Problem

When wiring a spawn handler into an event notifier, a two-step operation is needed:
1. `dispatch.Spawn()` — starts an OS process and creates a dispatch DB record
2. `rtStore.UpdateAgentDispatch()` — links the dispatch ID back to the agent record

Two failure modes emerge:

**TOCTOU double-spawn:** Two concurrent `ic run advance` invocations both read `dispatch_id = NULL` on the same agent, both call `Spawn`, and two child processes start for the same agent.

**Orphan spawn:** `dispatch.Spawn` succeeds (process is running) but `UpdateAgentDispatch` fails (DB error, constraint violation). The process consumes resources but has no linkage in `run_agents`, so it appears unlinked on retry and gets spawned again.

## Root Cause

The read-check-write on `dispatch_id` is not atomic. With SQLite `SetMaxOpenConns(1)`, there's no open transaction spanning the read-spawn-write sequence (each statement auto-commits), so concurrent callers interleave freely.

## Solution

### 1. CAS guard on UpdateAgentDispatch

Add `AND dispatch_id IS NULL` to the UPDATE WHERE clause. This makes the link operation atomic — if another caller already set `dispatch_id`, the UPDATE affects 0 rows.

```go
func (s *Store) UpdateAgentDispatch(ctx context.Context, agentID, dispatchID string) error {
    result, err := s.db.ExecContext(ctx, `
        UPDATE run_agents SET dispatch_id = ?, updated_at = ?
        WHERE id = ? AND dispatch_id IS NULL`,
        dispatchID, now, agentID,
    )
    // ...
    if n == 0 {
        // Distinguish: agent not found vs. already linked
        _, err := s.GetAgent(ctx, agentID)
        if err != nil {
            return ErrAgentNotFound
        }
        return ErrDispatchIDConflict
    }
    return nil
}
```

### 2. Kill orphan on link failure

In the spawn adapter, if the CAS link fails, immediately kill the process that was just started:

```go
if err := rtStore.UpdateAgentDispatch(ctx, agentID, spawnResult.ID); err != nil {
    if spawnResult.Cmd != nil && spawnResult.Cmd.Process != nil {
        _ = spawnResult.Cmd.Process.Kill()
    }
    return fmt.Errorf("spawn: link dispatch to agent %s: %w", agentID, err)
}
```

### 3. Don't silently swallow lookup errors

When looking up a prior dispatch for re-spawn config, return the error explicitly rather than falling through to a convention-based fallback. Silent fallback masks persistent DB failures.

## Why This Pattern Recurs

Any "create resource then link ID" operation in a single-connection SQLite setup has this shape:
- Create (side effect: resource now exists)
- Link (side effect: DB records connected)
- If link fails, resource is orphaned

The general fix is always: **CAS on the link step + cleanup on failure**.

## Verification

Three tests cover the CAS behavior:
- `TestStore_UpdateAgentDispatch` — happy path (NULL → set)
- `TestStore_UpdateAgentDispatch_NotFound` — agent doesn't exist
- `TestStore_UpdateAgentDispatch_Conflict` — second set returns `ErrDispatchIDConflict`, original value preserved

## Cross-References

- `infra/intercore/internal/runtrack/store.go:UpdateAgentDispatch` — CAS implementation
- `infra/intercore/cmd/ic/run.go:cmdRunAdvance` — orphan cleanup in spawn adapter closure
- `docs/guides/data-integrity-patterns.md` — WAL protocol (related atomicity pattern)
