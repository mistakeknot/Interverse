# Intercore Run Tracking Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use clavain:executing-plans to implement this plan task-by-task.

**Bead:** iv-qt5m
**Phase:** executing (as of 2026-02-18T23:18:31Z)

**Goal:** Add agent tracking, artifact tracking, and `ic run current` to intercore — the missing pieces that turn it from a sentinel store into an orchestration kernel.

**Architecture:** Schema v4 adds two new tables (`run_agents`, `run_artifacts`) and one new subcommand (`ic run current`). Both tables reference `runs(id)` with foreign keys. A new `internal/runtrack` package provides the store for agents and artifacts — following the precedent set by `internal/dispatch` (run-scoped entities get their own package, keeping `internal/phase` focused on the state machine).

**Tech Stack:** Go 1.22, modernc.org/sqlite (no CGO), bash (lib-intercore.sh wrappers)

**Key Conventions (from existing codebase):**
- 8-char alphanumeric IDs via `crypto/rand`
- `New(db *sql.DB) *Store` pattern
- `sql.NullString`/`sql.NullInt64` for nullable columns, converted via `nullStr()`/`nullInt64()` helpers
- Exit codes: 0=success/found, 1=expected negative/not found, 2=error, 3=usage
- `--flag=value` manual arg parsing in CLI
- Integration tests in `test-integration.sh`, unit tests in `*_test.go`
- `SetMaxOpenConns(1)` mandatory, PRAGMAs set explicitly after `sql.Open`
- No CTE + UPDATE RETURNING (modernc.org/sqlite limitation)

---

## What Already Exists

All `ic run` subcommands are implemented: `create`, `status`, `advance`, `phase`, `list`, `events`, `cancel`, `set`. The `runs` and `phase_events` tables exist (schema v3). The phase state machine with complexity-based skip is fully working.

## What's Missing (This Plan)

1. `run_agents` table — track individual agents within a run
2. `run_artifacts` table — track files produced during a run
3. `ic run current` — print the active run ID for the current project (most common scripting use case)
4. `ic run agent add/list` — CLI for agent tracking
5. `ic run artifact add/list` — CLI for artifact tracking
6. Bash wrappers in `lib-intercore.sh` for run commands
7. Integration tests for all new commands

---

## Review Fixes Applied

The following findings from the flux-drive review (fd-correctness, fd-architecture, fd-quality) have been incorporated:

1. **P0 (correctness):** Added `PRAGMA foreign_keys = ON` to `db.Open()` — without it, all `REFERENCES` clauses are decorative and FK tests pass vacuously.
2. **P0 (correctness):** Added v3→v4 migration test to Task 1 acceptance criteria to catch DDL/version constant desync.
3. **P1 (correctness):** Documented multi-run-per-project as intentional (no unique index on `project_dir WHERE active`). `ic run current` returns most recent; callers must cancel stale runs explicitly.
4. **P1 (architecture):** Moved agents/artifacts from `internal/phase` to new `internal/runtrack` package — phase owns state machine, runtrack owns tracking data. Follows `internal/dispatch` precedent.
5. **P1 (quality):** Dropped `AgentActive`/`AgentCompleted`/`AgentFailed` — reuse existing `StatusActive`/etc. from phase package via import.
6. **P1 (quality):** Added `ErrAgentNotFound` sentinel — phase's `ErrNotFound` says "run not found" which is misleading for agent operations.
7. **P1 (architecture):** Split CLI into `cmd/ic/run.go` and `cmd/ic/dispatch.go` (same package main, no API change) — main.go at 1726 lines is too large.
8. **P2 (architecture):** Merged Task 7 (`Store.Current()`) into Task 2 — it's a simple runs query, not a separate concern.
9. **P2 (quality):** Helper duplication (`generateID`, `nullStr`, etc.) documented as intentional in this version. Extract `internal/sqlutil` in a future refactor if a third package needs them.
10. **P3 (quality):** Reuse existing `setupTestStore` from `store_test.go` in agent tests — do not redefine it.

---

### Task 0: Enable foreign key enforcement + migration test

**File:** `internal/db/db.go`

Add after the WAL PRAGMA:
```go
if _, err := sqlDB.Exec("PRAGMA foreign_keys = ON"); err != nil {
    sqlDB.Close()
    return nil, fmt.Errorf("open: set foreign_keys: %w", err)
}
```

**File:** `internal/db/db_test.go` (or create if needed)

Add `TestMigrate_V3ToV4` — creates a v3 DB (with runs + phase_events but no run_agents/run_artifacts), runs `Migrate()`, verifies:
- `PRAGMA user_version` returns 4
- `SELECT 1 FROM run_agents LIMIT 0` succeeds (table exists)
- `SELECT 1 FROM run_artifacts LIMIT 0` succeeds (table exists)

**Acceptance:** Foreign key violations are actually rejected. Migration from v3 to v4 is tested.

---

### Task 1: Schema v4 — add run_agents and run_artifacts tables

**File:** `internal/db/schema.sql`

Append after the `phase_events` table:

```sql
-- v4: run tracking (agents + artifacts)
CREATE TABLE IF NOT EXISTS run_agents (
    id          TEXT NOT NULL PRIMARY KEY,
    run_id      TEXT NOT NULL REFERENCES runs(id),
    agent_type  TEXT NOT NULL DEFAULT 'claude',
    name        TEXT,
    status      TEXT NOT NULL DEFAULT 'active',
    dispatch_id TEXT,
    created_at  INTEGER NOT NULL DEFAULT (unixepoch()),
    updated_at  INTEGER NOT NULL DEFAULT (unixepoch())
);
CREATE INDEX IF NOT EXISTS idx_run_agents_run ON run_agents(run_id);
CREATE INDEX IF NOT EXISTS idx_run_agents_status ON run_agents(status) WHERE status = 'active';

CREATE TABLE IF NOT EXISTS run_artifacts (
    id          TEXT NOT NULL PRIMARY KEY,
    run_id      TEXT NOT NULL REFERENCES runs(id),
    phase       TEXT NOT NULL,
    path        TEXT NOT NULL,
    type        TEXT NOT NULL DEFAULT 'file',
    created_at  INTEGER NOT NULL DEFAULT (unixepoch())
);
CREATE INDEX IF NOT EXISTS idx_run_artifacts_run ON run_artifacts(run_id);
CREATE INDEX IF NOT EXISTS idx_run_artifacts_phase ON run_artifacts(run_id, phase);
```

**File:** `internal/db/db.go`

Update constants:
```go
const (
    currentSchemaVersion = 4
    maxSchemaVersion     = 4
)
```

**Acceptance:** `ic init` on an existing v3 DB migrates to v4. `ic version` shows schema v4. New tables exist with correct indexes.

---

### Task 2: Runtrack package — agent + artifact store + Current()

**New package:** `internal/runtrack/`

Create `internal/runtrack/runtrack.go` with types:

```go
package runtrack

// Agent status constants — reuse phase.StatusActive/StatusCompleted/StatusFailed values.
// Defined here as string constants to avoid circular imports.
const (
    StatusActive    = "active"
    StatusCompleted = "completed"
    StatusFailed    = "failed"
)

// Agent represents an agent instance within a run.
type Agent struct {
    ID         string
    RunID      string
    AgentType  string
    Name       *string
    Status     string
    DispatchID *string
    CreatedAt  int64
    UpdatedAt  int64
}

// Artifact represents a file produced during a run.
type Artifact struct {
    ID        string
    RunID     string
    Phase     string
    Path      string
    Type      string
    CreatedAt int64
}
```

Create `internal/runtrack/errors.go`:
```go
var (
    ErrAgentNotFound    = errors.New("agent not found")
    ErrArtifactNotFound = errors.New("artifact not found")
)
```

Create `internal/runtrack/store.go` with Store and methods (follow dispatch package patterns — copy `generateID`, `nullStr`, `nullInt64` helpers locally):

```go
func New(db *sql.DB) *Store

func (s *Store) AddAgent(ctx context.Context, a *Agent) (string, error)
func (s *Store) UpdateAgent(ctx context.Context, id, status string) error
func (s *Store) GetAgent(ctx context.Context, id string) (*Agent, error)
func (s *Store) ListAgents(ctx context.Context, runID string) ([]*Agent, error)

func (s *Store) AddArtifact(ctx context.Context, a *Artifact) (string, error)
func (s *Store) ListArtifacts(ctx context.Context, runID string, phase *string) ([]*Artifact, error)
```

**Also in `internal/phase/store.go`** — add `Current()` method (simple runs query, belongs with run CRUD):

```go
// Current returns the most recent active run for a project directory.
// Multiple active runs per project are allowed (no uniqueness constraint).
// Returns ErrNotFound if no active run exists.
func (s *Store) Current(ctx context.Context, projectDir string) (*Run, error)
```

Query: `SELECT <runCols> FROM runs WHERE status = 'active' AND project_dir = ? ORDER BY created_at DESC LIMIT 1`

Each method follows the established patterns:
- `generateID()` for new records
- `time.Now().Unix()` for timestamps (not SQL `unixepoch()`)
- `sql.NullString` for nullable columns
- `ErrAgentNotFound` / `ErrArtifactNotFound` on missing rows
- Error format: `"agent add: %w"` / `"artifact add: %w"`

**Acceptance:** Unit tests pass for all store methods.

---

### Task 3: Unit tests for runtrack store + Current()

**File:** `internal/runtrack/store_test.go` (new file)

Create `setupTestStore(t)` following the same pattern as phase's: `t.TempDir()` + `db.Open` + `Migrate` + `New(d.SqlDB())`. Also create a helper run in the `runs` table for FK tests (insert directly via `phase.New(d.SqlDB()).Create()`).

Test functions:

- `TestStore_AddAgent` — create agent, verify ID returned, verify fields via GetAgent
- `TestStore_AddAgent_BadRunID` — add agent for non-existent run (FK rejection — requires Task 0's `PRAGMA foreign_keys = ON`)
- `TestStore_UpdateAgent` — add agent, update to completed, verify
- `TestStore_UpdateAgent_NotFound` — update non-existent agent returns ErrAgentNotFound
- `TestStore_ListAgents_Empty` — list for run with no agents returns empty slice
- `TestStore_ListAgents_Multiple` — add 3 agents, list returns all
- `TestStore_AddArtifact` — create artifact, verify fields
- `TestStore_ListArtifacts_ByPhase` — add artifacts in different phases, filter by one phase
- `TestStore_ListArtifacts_All` — list all artifacts for a run

**File:** `internal/phase/store_test.go` (append to existing)

- `TestStore_Current` — create run, verify Current() returns it
- `TestStore_Current_NoActiveRun` — returns ErrNotFound when no active run
- `TestStore_Current_MostRecent` — with multiple active runs, returns newest

**Acceptance:** `go test ./internal/runtrack/... ./internal/phase/... -v` passes all new tests.

---

### Task 4: Split main.go + CLI — ic run current

**First:** Split `cmd/ic/main.go` into files (same `package main`, no API change):
- `cmd/ic/main.go` — global flags, subcommand dispatch, `openDB()`, `printUsage()`
- `cmd/ic/run.go` — all `cmdRun*` functions + run output helpers (`runToMap`, `printRun`, `eventToMap`)
- `cmd/ic/dispatch.go` — all `cmdDispatch*` functions + dispatch output helpers

This is a pure file split — no logic changes. Commit separately before adding new code.

**Then** add `"current"` case to `cmdRun()` switch in `cmd/ic/run.go`:

```go
case "current":
    return cmdRunCurrent(ctx, args[1:])
```

Implement `cmdRunCurrent` using `phase.Store.Current()`:
- If found: print the ID (or JSON `{"id":"xxx","phase":"yyy"}` with `--json`)
- If no active run: exit 1 (expected negative — no active run)
- Accepts `--project=<dir>` flag (defaults to CWD)

Update `printUsage()` in `main.go` to include `run current`.

**Acceptance:** `ic run current` returns the most recent active run ID for the project. Returns exit 1 when no run exists.

---

### Task 5: CLI commands — ic run agent add/list/update

**File:** `cmd/ic/run.go`

Add `"agent"` case to `cmdRun()` switch:

```go
case "agent":
    return cmdRunAgent(ctx, args[1:])
```

Implement `cmdRunAgent` with subcommands:

**`ic run agent add <run_id> --type=<type> --name=<name> [--dispatch-id=<id>]`**
- Validates run_id exists (via phase store.Get)
- Creates agent record (via runtrack store.AddAgent)
- Prints agent ID (or JSON with `--json`)

**`ic run agent list <run_id>`**
- Lists all agents for the run
- Text output: `<id>\t<type>\t<status>\t<name>`
- JSON output: array of agent objects

**`ic run agent update <run_id> <agent_id> --status=<status>`**
- Updates agent status
- Prints "updated"

Update `printUsage()` to include agent subcommands.

**Acceptance:** Can add agents to a run, list them, and update their status via CLI.

---

### Task 6: CLI commands — ic run artifact add/list

**File:** `cmd/ic/run.go`

Add `"artifact"` case to `cmdRun()` switch.

**`ic run artifact add <run_id> --phase=<phase> --path=<path> [--type=<type>]`**
- Validates run_id exists
- Creates artifact record
- Prints artifact ID

**`ic run artifact list <run_id> [--phase=<phase>]`**
- Lists artifacts, optionally filtered by phase
- Text output: `<id>\t<phase>\t<type>\t<path>`
- JSON output: array of artifact objects

Update `printUsage()` to include artifact subcommands.

**Acceptance:** Can add artifacts to a run and list them via CLI.

---

### Task 7: Bash wrappers in lib-intercore.sh

**File:** `infra/intercore/lib-intercore.sh`

Add wrappers for the most common scripting operations:

```bash
# intercore_run_current [project_dir]
# Returns the active run ID for the project. Exit 0=found, 1=none.
intercore_run_current() { ... }

# intercore_run_phase <run_id>
# Returns the current phase of a run.
intercore_run_phase() { ... }

# intercore_run_agent_add <run_id> <type> <name> [dispatch_id]
# Adds an agent to a run. Prints agent ID.
intercore_run_agent_add() { ... }

# intercore_run_artifact_add <run_id> <phase> <path> [type]
# Adds an artifact to a run. Prints artifact ID.
intercore_run_artifact_add() { ... }
```

Each wrapper follows the existing pattern:
- Check `INTERCORE_BIN` or find `ic` in PATH
- Pass `--db` if `INTERCORE_DB` is set
- Fail safe (return 1) if `ic` is unavailable

Bump `lib-intercore.sh` version header to v0.3.0.

**Acceptance:** Wrappers work when `ic` is available, fail safe when it's not.

---

### Task 8: Integration tests

**File:** `infra/intercore/test-integration.sh`

Add new test sections:

```bash
echo "=== Run Current ==="
# ic run current finds the active run
# ic run current returns exit 1 when no active run

echo "=== Run Agents ==="
# Add agent to run, verify it appears in list
# Update agent status, verify change
# List agents returns correct count

echo "=== Run Artifacts ==="
# Add artifact to run, verify it appears in list
# Filter artifacts by phase
# Add artifacts in different phases, list all
```

**Acceptance:** `bash test-integration.sh` passes with all new tests.

---

### Task 9: Update AGENTS.md

**File:** `infra/intercore/AGENTS.md`

Add the new CLI commands to the CLI Commands section:

```
ic run current [--project=<dir>]         Print active run ID for project
ic run agent add <run> --type=<t> --name=<n>   Add agent to run
ic run agent list <run>                  List agents for run
ic run agent update <run> <agent> --status=<s>  Update agent status
ic run artifact add <run> --phase=<p> --path=<f> [--type=<t>]  Add artifact
ic run artifact list <run> [--phase=<p>]  List artifacts for run
```

Add the new tables to the Architecture section. Update schema version references to v4.

**Acceptance:** AGENTS.md accurately reflects the current CLI commands and schema.

---

## Dependency Graph

```
Task 0 (FK pragma + migration test)
  → Task 1 (schema v4)
    → Task 2 (runtrack store + Current())
      → Task 3 (unit tests)
      → Task 4 (CLI split + current)
      → Task 5 (CLI agent)
      → Task 6 (CLI artifact)
        → Task 7 (bash wrappers)
        → Task 8 (integration tests)
          → Task 9 (docs)
```

**Parallelizable:** Tasks 3, 4, 5, 6 are independent after Task 2.

## Design Decisions

- **Multi-run per project is intentional.** No unique index on `(project_dir) WHERE status = 'active'`. `ic run current` returns most recent; callers cancel stale runs explicitly. This mirrors how sprint beads work — a project can have overlapping work streams.
- **Helper duplication is intentional (for now).** `generateID`, `nullStr`, etc. are copied in dispatch, phase, and now runtrack. Extract to `internal/sqlutil` when a fourth package would need them.

## Estimated Effort

- Tasks 0-3: ~1.5 hours (FK fix + schema + store + unit tests)
- Tasks 4-6: ~1.5 hours (CLI split + new commands)
- Tasks 7-9: ~30 min (wrappers + integration tests + docs)
- **Total:** ~3.5 hours
