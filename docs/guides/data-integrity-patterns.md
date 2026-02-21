# Data Integrity Patterns Guide

Consolidated reference for WAL protocol, guard clauses, and null safety in TypeScript. Read this before writing sync code, validation logic, or crash recovery paths.

## WAL Protocol Completeness

When a system uses Write-Ahead Logging for crash recovery, **every write path** must participate — not just the "happy path."

### Correct WAL Sequence

```typescript
const walEntry = walCreatePending(db, { entityId, operation, newContent });
writeFileSync(entity.localPath, content, "utf-8");
walMarkTargetWritten(db, walEntry.id);
updateEntityAfterSync(db, entity.id, { ... });
walMarkCommitted(db, walEntry.id);
// All side effects (e.g., remote push) BEFORE delete
await pushUpdate(entity.id, notionId, content, hash);
walDelete(db, walEntry.id);  // Only after ALL effects complete
```

### WAL Delete Placement

**Rule: WAL entry lifetime = first mutation → last side effect.**

If a remote push fails after WAL delete, there's no record that the push is pending. On restart, the entity looks fully synced but the remote has stale content — silent divergence.

### Common places WAL gets skipped

- **Conflict resolution handlers** — added later, copy-pasted without WAL
- **Error recovery paths** — ironically, the recovery code lacks its own recovery
- **Migration/upgrade paths** — one-time writes assumed safe
- **Cleanup/GC paths** — deletion without journaling

**Audit technique:** Grep for all `writeFileSync` / `fs.write` / `UPDATE` calls and verify each has a corresponding WAL entry.

## Guard Fallthrough: Validation That Silently Skips on Null

When a validation depends on a lookup that can return null, the null case must **abort the operation**, not skip the validation.

### Anti-Pattern

```typescript
const projectDir = this.findProjectDir(entity.localPath);
if (projectDir) {
  // Validation only runs here
  const resolved = resolve(projectDir, basename(entity.localPath));
  if (!resolved.startsWith(projectDir + "/")) {
    return; // Abort on traversal
  }
}
// Falls through when projectDir is null — NO validation
```

### Correct Pattern

```typescript
const projectDir = this.findProjectDir(entity.localPath);
if (!projectDir) {
  // Fail closed: no context means we can't validate
  appendSyncLog(db, { entityMapId: entity.id, operation: "error",
    detail: { error: "No project directory found — aborting" } });
  return;
}
// Now projectDir is guaranteed non-null
const resolved = resolve(projectDir, basename(entity.localPath));
if (!resolved.startsWith(projectDir + "/")) {
  return;
}
```

### General Rule

**Fail closed on missing context.** The guard clause should invert: check for the *absence* of the prerequisite first. This applies to:
- Path validation requiring a project root
- Permission checks requiring a user context
- Rate limiting requiring a client identifier
- Input sanitization requiring a schema definition

### Detection Signal

Look for this code shape:
```
const context = lookup();
if (context) { validate(input, context); }
// input used here without validation when context is null
```

Fix: flip to `if (!context) { abort; }` then validate unconditionally.

## Silent JSON Errors in Go

Never use `_ = json.Marshal/Unmarshal`. Write paths: fail hard (return error). Read paths: log warning with entity ID, continue with zero value. Grep for `_ = json.` as a CI check. Wrap multi-table materializations in transactions.

```go
// WRONG: silent data corruption
_ = json.Unmarshal(row, &entity)

// RIGHT: fail on writes, log on reads
if err := json.Unmarshal(row, &entity); err != nil {
    log.Printf("warning: corrupt JSON for entity %s: %v", id, err)
    // continue with zero value on reads; return err on writes
}
```

## Detailed Solution Docs

- `docs/solutions/patterns/wal-protocol-completeness-20260216.md`
- `docs/solutions/patterns/guard-fallthrough-null-validation-20260216.md`
- `core/intermute/docs/solutions/database-issues/silent-json-errors-sqlite-storage-20260211.md`
