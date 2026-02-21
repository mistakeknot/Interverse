# Thematic Work Lanes Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use clavain:executing-plans to implement this plan task-by-task.

**Bead:** iv-jj97
**Phase:** planned (as of 2026-02-21T05:46:48Z)
**Goal:** Add thematic work lanes as a first-class kernel entity with auto-discovery, sprint integration, Pollard scoping, and Autarch dashboard support.

**Architecture:** New `lanes` table in intercore's SQLite schema. Beads are associated to lanes via `bd label lane:<name>`. The kernel maintains lane state (type, membership snapshots, velocity). CLI via `ic lane` subcommands. Sprint and discovery gain `--lane` filtering. Pollard hunters are lane-scoped with starvation-weighted scheduling.

**Tech Stack:** Go (intercore kernel), Bash (lib-discovery.sh, lib-sprint.sh, Clavain skills), Go (Autarch TUI)

**Brainstorm:** [docs/brainstorms/2026-02-21-thematic-work-lanes-brainstorm.md](../brainstorms/2026-02-21-thematic-work-lanes-brainstorm.md)

---

### Task 1: Kernel schema — `lanes` table + migration

**Files:**
- Modify: `infra/intercore/internal/db/schema.sql` (append after v10 block)
- Modify: `infra/intercore/internal/db/db.go` (add v11 migration)

**Step 1: Write the failing test**

Create a test that opens a DB, runs migrations, and verifies the `lanes` table exists with correct columns.

```go
// infra/intercore/internal/db/db_test.go
func TestMigrateV11LanesTable(t *testing.T) {
    db := openTestDB(t)
    defer db.Close()

    rows, err := db.Query("SELECT name, type, lane_type, status, created_at, updated_at FROM lanes LIMIT 0")
    if err != nil {
        t.Fatalf("lanes table missing or wrong schema: %v", err)
    }
    rows.Close()

    // Verify lane_events table
    rows, err = db.Query("SELECT id, lane_id, event_type, payload, created_at FROM lane_events LIMIT 0")
    if err != nil {
        t.Fatalf("lane_events table missing: %v", err)
    }
    rows.Close()
}
```

**Step 2: Run test to verify it fails**

Run: `cd infra/intercore && go test ./internal/db/ -run TestMigrateV11 -v`
Expected: FAIL with "lanes table missing"

**Step 3: Write the schema and migration**

Append to `schema.sql`:
```sql
-- v11: thematic work lanes
CREATE TABLE IF NOT EXISTS lanes (
    id          TEXT NOT NULL PRIMARY KEY,
    name        TEXT NOT NULL UNIQUE,
    lane_type   TEXT NOT NULL DEFAULT 'standing',  -- 'standing' or 'arc'
    status      TEXT NOT NULL DEFAULT 'active',    -- 'active', 'closed', 'archived'
    description TEXT NOT NULL DEFAULT '',
    metadata    TEXT NOT NULL DEFAULT '{}',         -- JSON: pollard config, starvation weights
    created_at  INTEGER NOT NULL DEFAULT (unixepoch()),
    updated_at  INTEGER NOT NULL DEFAULT (unixepoch()),
    closed_at   INTEGER
);
CREATE INDEX IF NOT EXISTS idx_lanes_status ON lanes(status) WHERE status = 'active';
CREATE INDEX IF NOT EXISTS idx_lanes_type ON lanes(lane_type);

CREATE TABLE IF NOT EXISTS lane_events (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    lane_id     TEXT NOT NULL REFERENCES lanes(id),
    event_type  TEXT NOT NULL,  -- 'created', 'bead_added', 'bead_removed', 'snapshot', 'closed'
    payload     TEXT NOT NULL DEFAULT '{}',
    created_at  INTEGER NOT NULL DEFAULT (unixepoch())
);
CREATE INDEX IF NOT EXISTS idx_lane_events_lane ON lane_events(lane_id);
CREATE INDEX IF NOT EXISTS idx_lane_events_created ON lane_events(created_at);
```

Add v11 migration block in `db.go` following the existing v10 pattern (check `PRAGMA user_version`, run DDL in transaction, set version to 11).

**Step 4: Run test to verify it passes**

Run: `cd infra/intercore && go test ./internal/db/ -run TestMigrateV11 -v`
Expected: PASS

**Step 5: Commit**

```bash
cd infra/intercore && git add internal/db/schema.sql internal/db/db.go internal/db/db_test.go
git commit -m "feat(kernel): add lanes table + lane_events (schema v11)"
```

---

### Task 2: Lane store — CRUD operations

**Files:**
- Create: `infra/intercore/internal/lane/store.go`
- Create: `infra/intercore/internal/lane/store_test.go`

**Step 1: Write the failing tests**

```go
// internal/lane/store_test.go
func TestLaneStore_CreateAndGet(t *testing.T) {
    db := testDB(t)
    s := lane.NewStore(db)

    id, err := s.Create(ctx, "interop", "standing", "Plugin interoperability")
    require.NoError(t, err)
    require.NotEmpty(t, id)

    l, err := s.Get(ctx, id)
    require.NoError(t, err)
    assert.Equal(t, "interop", l.Name)
    assert.Equal(t, "standing", l.LaneType)
    assert.Equal(t, "active", l.Status)
}

func TestLaneStore_ListActive(t *testing.T) { ... }
func TestLaneStore_Close(t *testing.T) { ... }
func TestLaneStore_DuplicateNameFails(t *testing.T) { ... }
func TestLaneStore_RecordEvent(t *testing.T) { ... }
```

**Step 2: Run tests to verify they fail**

Run: `cd infra/intercore && go test ./internal/lane/ -v`
Expected: FAIL (package doesn't exist)

**Step 3: Implement the store**

```go
// internal/lane/store.go
package lane

type Lane struct {
    ID          string
    Name        string
    LaneType    string // "standing" or "arc"
    Status      string // "active", "closed", "archived"
    Description string
    Metadata    string // JSON
    CreatedAt   int64
    UpdatedAt   int64
    ClosedAt    *int64
}

type Store struct { db *sql.DB }

func NewStore(db *sql.DB) *Store { return &Store{db: db} }

func (s *Store) Create(ctx context.Context, name, laneType, description string) (string, error) { ... }
func (s *Store) Get(ctx context.Context, id string) (*Lane, error) { ... }
func (s *Store) GetByName(ctx context.Context, name string) (*Lane, error) { ... }
func (s *Store) List(ctx context.Context, status string) ([]*Lane, error) { ... }
func (s *Store) Close(ctx context.Context, id string) error { ... }
func (s *Store) RecordEvent(ctx context.Context, laneID, eventType, payload string) error { ... }
```

Use 8-char random IDs (same pattern as runs: `internal/phase/id.go`).

**Step 4: Run tests to verify they pass**

Run: `cd infra/intercore && go test ./internal/lane/ -v`
Expected: PASS

**Step 5: Commit**

```bash
cd infra/intercore && git add internal/lane/
git commit -m "feat(kernel): lane store — CRUD + events"
```

---

### Task 3: CLI — `ic lane` subcommands

**Files:**
- Create: `infra/intercore/cmd/ic/lane.go`
- Modify: `infra/intercore/cmd/ic/main.go` (add `case "lane":` at line ~101)

**Step 1: Write integration test**

Add to `infra/intercore/test-integration.sh`:
```bash
# Lane commands
echo "=== Lane ==="
LANE_ID=$($IC lane create --name=interop --type=standing --description="Plugin interop" --json | jq -r '.id')
test -n "$LANE_ID" || fail "lane create"
$IC lane list --json | jq -e '.[0].name == "interop"' || fail "lane list"
$IC lane status "$LANE_ID" --json | jq -e '.name == "interop"' || fail "lane status"
$IC lane close "$LANE_ID" || fail "lane close"
```

**Step 2: Run integration tests to verify they fail**

Run: `cd infra/intercore && bash test-integration.sh`
Expected: FAIL at "Lane" section

**Step 3: Implement CLI**

Create `lane.go` following the `portfolio.go` pattern (switch on subcommands):

Subcommands:
- `ic lane create --name=<n> --type=standing|arc --description=<d>` → prints JSON `{id, name, lane_type}`
- `ic lane list [--active]` → prints JSON array of lanes
- `ic lane status <id> --json` → prints lane details + membership count + recent events
- `ic lane close <id>` → sets status=closed, records event
- `ic lane events <id>` → prints lane_events for this lane

Register in `main.go`:
```go
case "lane":
    exitCode = cmdLane(ctx, subArgs)
```

**Step 4: Run integration tests to verify they pass**

Run: `cd infra/intercore && bash test-integration.sh`
Expected: PASS

**Step 5: Commit**

```bash
cd infra/intercore && git add cmd/ic/lane.go cmd/ic/main.go test-integration.sh
git commit -m "feat(kernel): ic lane CLI — create, list, status, close, events"
```

---

### Task 4: Lane membership via beads labels

**Files:**
- Create: `infra/intercore/cmd/ic/lane.go` (add `sync` subcommand)
- Modify: `infra/intercore/internal/lane/store.go` (add membership snapshot)

**Step 1: Write the failing test**

```go
func TestLaneStore_SnapshotMembers(t *testing.T) {
    db := testDB(t)
    s := lane.NewStore(db)

    id, _ := s.Create(ctx, "interop", "standing", "")
    err := s.SnapshotMembers(ctx, id, []string{"iv-rzt0", "iv-sk8t", "iv-sprh"})
    require.NoError(t, err)

    members, err := s.GetMembers(ctx, id)
    require.NoError(t, err)
    assert.Len(t, members, 3)
}
```

**Step 2: Run test to verify it fails**

Run: `cd infra/intercore && go test ./internal/lane/ -run TestLaneStore_Snapshot -v`
Expected: FAIL

**Step 3: Implement membership**

Add `lane_members` table to schema (v11 block — add it in the same migration since we haven't released v11 yet):

```sql
CREATE TABLE IF NOT EXISTS lane_members (
    lane_id     TEXT NOT NULL REFERENCES lanes(id),
    bead_id     TEXT NOT NULL,
    added_at    INTEGER NOT NULL DEFAULT (unixepoch()),
    PRIMARY KEY (lane_id, bead_id)
);
CREATE INDEX IF NOT EXISTS idx_lane_members_bead ON lane_members(bead_id);
```

Add store methods:
- `SnapshotMembers(ctx, laneID, beadIDs []string)` — upserts members, removes stale ones
- `GetMembers(ctx, laneID)` — returns bead IDs
- `GetLanesForBead(ctx, beadID)` — returns lane IDs (supports multi-lane)

Add CLI subcommand:
- `ic lane sync <id>` — calls `bd list --label=lane:<name> --json`, extracts IDs, calls `SnapshotMembers`
- `ic lane members <id>` — lists current members

**Step 4: Run test to verify it passes**

Run: `cd infra/intercore && go test ./internal/lane/ -run TestLaneStore_Snapshot -v`
Expected: PASS

**Step 5: Commit**

```bash
cd infra/intercore && git add internal/db/schema.sql internal/lane/ cmd/ic/lane.go
git commit -m "feat(kernel): lane membership sync from bd labels"
```

---

### Task 5: Lane velocity and starvation detection

**Files:**
- Modify: `infra/intercore/internal/lane/store.go` (add velocity query)
- Create: `infra/intercore/internal/lane/velocity.go`
- Create: `infra/intercore/internal/lane/velocity_test.go`

**Step 1: Write the failing test**

```go
func TestLaneVelocity_RelativeStarvation(t *testing.T) {
    // Create two lanes: "interop" with 10 open P2 beads, "kernel" with 3 open P2 beads
    // Close 5 beads in kernel over last 7 days, 0 in interop
    // interop should be flagged as starved (high backlog, zero throughput)
    v := lane.NewVelocityCalculator(store)
    scores, err := v.ComputeStarvation(ctx, 7) // 7-day window
    require.NoError(t, err)
    assert.Greater(t, scores["interop"], scores["kernel"])
}
```

**Step 2: Run test to verify it fails**

Run: `cd infra/intercore && go test ./internal/lane/ -run TestLaneVelocity -v`
Expected: FAIL

**Step 3: Implement velocity**

Starvation score = `(priority_weighted_open_beads) / max(throughput_last_N_days, 0.1)`

- `priority_weighted_open_beads`: Sum of (5-priority) for each open bead in the lane (P0=5, P1=4, P2=3, P3=2, P4=1)
- `throughput_last_N_days`: Count of beads closed in the lane within the window

Higher score = more starved. The formula naturally balances: a lane with many high-priority open beads and low throughput scores highest.

Add CLI: `ic lane velocity [--days=7] --json` — outputs starvation scores per lane, sorted descending.

**Step 4: Run test to verify it passes**

Run: `cd infra/intercore && go test ./internal/lane/ -run TestLaneVelocity -v`
Expected: PASS

**Step 5: Commit**

```bash
cd infra/intercore && git add internal/lane/
git commit -m "feat(kernel): lane velocity + starvation scoring"
```

---

### Task 6: Discovery integration — `--lane` filter

**Files:**
- Modify: `plugins/interphase/hooks/lib-discovery.sh` (add `DISCOVERY_LANE` filter)

**Step 1: Write the failing test**

Add to interphase test suite:
```bash
# Test: discovery_scan_beads respects DISCOVERY_LANE
bd label add "$TEST_BEAD_1" "lane:interop"
DISCOVERY_LANE=interop discovery_scan_beads | jq -e 'length == 1'
DISCOVERY_LANE=kernel discovery_scan_beads | jq -e 'length == 0'
```

**Step 2: Run test to verify it fails**

Run the interphase test that exercises discovery.
Expected: FAIL (DISCOVERY_LANE not implemented)

**Step 3: Implement the filter**

In `discovery_scan_beads()`, after `bd list --status=open --json`:
```bash
# Lane filter: if DISCOVERY_LANE is set, filter to beads with lane:<name> label
if [[ -n "${DISCOVERY_LANE:-}" && "$DISCOVERY_LANE" != "*" ]]; then
    open_list=$(echo "$open_list" | jq --arg lane "lane:${DISCOVERY_LANE}" \
        '[.[] | select(.labels // [] | any(. == $lane))]')
    ip_list=$(echo "$ip_list" | jq --arg lane "lane:${DISCOVERY_LANE}" \
        '[.[] | select(.labels // [] | any(. == $lane))]')
fi
```

Also update `discovery_brief_scan()` with the same filter so session-start summaries are lane-scoped.

**Step 4: Run test to verify it passes**

Expected: PASS

**Step 5: Commit**

```bash
cd plugins/interphase && git add hooks/lib-discovery.sh
git commit -m "feat(discovery): DISCOVERY_LANE filter for lane-scoped work discovery"
```

---

### Task 7: Sprint integration — `--lane` flag

**Files:**
- Modify: `hub/clavain/hooks/lib-sprint.sh` (pass lane to discovery)
- Modify: `hub/clavain/skills/sprint/sprint.md` (add `--lane` argument handling)

**Step 1: Identify the integration points**

Read `hub/clavain/skills/sprint/sprint.md` to find where discovery is invoked and where `--lane` argument parsing should go.

**Step 2: Add `--lane` argument parsing**

In sprint.md's "Work Discovery" section, parse `--lane=<name>` from arguments:
```
If arguments contain `--lane=<name>`:
  - Set DISCOVERY_LANE=<name> before calling discovery_scan_beads
  - Display: "Lane: <name> — filtering to lane-scoped beads"
```

**Step 3: Pass lane to sprint_create**

When creating a new sprint bead, add `lane:<name>` label:
```bash
bd label add "$SPRINT_ID" "lane:${SPRINT_LANE}"
```

**Step 4: Test manually**

Run: `/clavain:sprint --lane=interop` — verify only interop-labeled beads appear in discovery.

**Step 5: Commit**

```bash
cd hub/clavain && git add hooks/lib-sprint.sh skills/sprint/sprint.md
git commit -m "feat(sprint): --lane flag scopes discovery to a thematic lane"
```

---

### Task 8: Auto-discovery — lane candidate proposal

**Files:**
- Create: `hub/clavain/skills/lane/SKILL.md`
- Create: `hub/clavain/skills/lane/` directory
- Modify: `hub/clavain/.claude-plugin/plugin.json` (register skill)

**Step 1: Design the `/clavain:lane` skill**

The skill has these subcommands:
- `/clavain:lane` (no args) — show lane status dashboard
- `/clavain:lane discover` — auto-discover lane candidates from bead graph
- `/clavain:lane create <name> --type=standing|arc` — create a lane
- `/clavain:lane add <lane> <bead-ids...>` — tag beads into a lane
- `/clavain:lane status` — show all lanes with velocity and starvation scores

**Step 2: Write SKILL.md**

The discover subcommand analyzes:
1. Module tags in bead titles (`[interflux]`, `[clavain]`, etc.)
2. Dependency clusters (connected components in the blocks graph)
3. Companion graph edges from `companion-graph.json`
4. Existing roadmap groupings

Proposes lanes via AskUserQuestion, user confirms/edits, then creates kernel lanes and applies `bd label lane:<name>` to member beads.

**Step 3: Register in plugin.json**

Add `"./skills/lane"` to the skills array.

**Step 4: Test manually**

Run: `/clavain:lane discover` — verify it proposes reasonable lane groupings.

**Step 5: Commit**

```bash
cd hub/clavain && git add skills/lane/ .claude-plugin/plugin.json
git commit -m "feat(clavain): /clavain:lane skill — discover, create, add, status"
```

---

### Task 9: Autarch lane dashboard view

**Files:**
- Modify: `hub/autarch/pkg/tui/model.go` (add lane pane)
- Create: `hub/autarch/pkg/tui/lane_pane.go`
- Modify: `hub/autarch/internal/aggregator/state.go` (add lane state)

**Step 1: Add lane state to aggregator**

In the aggregator's state struct, add:
```go
type LaneState struct {
    ID          string
    Name        string
    LaneType    string
    BeadCount   int
    OpenCount   int
    ClosedCount int
    Velocity    float64 // beads/week
    Starvation  float64
    LastUpdated time.Time
}
```

The aggregator periodically calls `ic lane list --json` and `ic lane velocity --json` to refresh.

**Step 2: Create lane_pane.go**

Renders lane progress bars in a table:
```
 Lane          Type      Open  Done  Vel/wk  Starv
─────────────────────────────────────────────────
 interop       standing    10     4    2.1   ██░░ 3.2
 kernel        standing     6     8    3.5   █░░░ 1.7
 e7-bigend     arc         12     3    1.0   ███░ 4.8
```

Bind to a function key (e.g., F8 or a new tab).

**Step 3: Test with tuivision**

Spawn the TUI, verify the lane pane renders with mock data.

**Step 4: Commit**

```bash
cd hub/autarch && git add pkg/tui/lane_pane.go pkg/tui/model.go internal/aggregator/state.go
git commit -m "feat(autarch): lane dashboard pane with velocity + starvation bars"
```

---

### Task 10: Pollard lane-scoped hunting

**Files:**
- Modify: `hub/autarch/pkg/discovery/pollard.go` (add lane scope field)
- Modify: `hub/autarch/cmd/pollard/` (add `--lane` flag)

**Step 1: Add lane scope to Pollard dispatch**

When dispatching a Pollard hunter, pass `--lane=<name>` to scope its research:
- Hunter queries `bd list --label=lane:<name>` to understand the lane's beads
- Research is scoped to modules/topics relevant to the lane
- Findings are tagged with `lane:<name>` when promoted to beads

**Step 2: Add starvation-weighted scheduling**

When Pollard has multiple lane assignments:
```go
func (p *Pollard) ChooseNextLane(lanes []LaneAssignment) string {
    // Call ic lane velocity --json to get starvation scores
    // Weight by starvation score with small random jitter to avoid lock-step
    // Return lane name with highest weighted score
}
```

**Step 3: Test manually**

Configure Pollard with two lane assignments, verify it preferentially hunts in the more-starved lane.

**Step 4: Commit**

```bash
cd hub/autarch && git add pkg/discovery/pollard.go cmd/pollard/
git commit -m "feat(pollard): lane-scoped hunting with starvation-weighted scheduling"
```

---

## Testing Strategy

- **Unit tests:** Go tests for store (Task 2), velocity (Task 5), schema migration (Task 1)
- **Integration test:** `test-integration.sh` additions for CLI (Task 3)
- **Manual tests:** Skill discovery (Task 8), sprint --lane (Task 7), Autarch pane (Task 9)
- **End-to-end:** Create lanes, tag beads, run `/clavain:sprint --lane=interop`, verify scoping works

## Dependency Order

```
Task 1 (schema) → Task 2 (store) → Task 3 (CLI)
                                  → Task 4 (membership) → Task 5 (velocity)
                                                        → Task 6 (discovery filter)
                                                        → Task 7 (sprint --lane)
Task 3 + Task 5 → Task 8 (skill)
Task 5 → Task 9 (autarch pane)
Task 5 → Task 10 (pollard)
```

Tasks 6, 7, 8 can run in parallel once Task 4 is done.
Tasks 9, 10 can run in parallel once Task 5 is done.
