# Autarch Status Tool — Implementation Plan

**Bead:** iv-qloe
**Phase:** executing (as of 2026-02-20T17:15:35Z)
**Date:** 2026-02-20
**PRD:** [prd](../prds/2026-02-20-autarch-status-tool.md)

---

## Overview

Add an `autarch status` subcommand — a standalone Bubble Tea TUI that displays Intercore kernel state. Reads data exclusively via `ic` CLI JSON output. Uses `pkg/tui` for theming.

## Tasks

### Task 1: Data layer — `internal/status/data.go`

Create the data layer that shells out to `ic` and parses JSON responses.

**Types:**
```go
type Run struct {
    ID         string   `json:"id"`
    Goal       string   `json:"goal"`
    Phase      string   `json:"phase"`
    Phases     []string `json:"phases"`
    Status     string   `json:"status"`
    ScopeID    string   `json:"scope_id"`
    Complexity int      `json:"complexity"`
    CreatedAt  int64    `json:"created_at"`
    UpdatedAt  int64    `json:"updated_at"`
}

type Dispatch struct {
    ID        string `json:"id"`
    RunID     string `json:"run_id"`
    AgentName string `json:"agent_name"`
    Status    string `json:"status"`
    Model     string `json:"model"`
    CreatedAt int64  `json:"created_at"`
    UpdatedAt int64  `json:"updated_at"`
}

type Event struct {
    ID        int    `json:"id"`
    RunID     string `json:"run_id"`
    Type      string `json:"type"`
    EntityID  string `json:"entity_id"`
    Payload   string `json:"payload"`
    CreatedAt int64  `json:"created_at"`
}

type TokenSummary struct {
    RunID        string `json:"run_id"`
    InputTokens  int64  `json:"input_tokens"`
    OutputTokens int64  `json:"output_tokens"`
    TotalTokens  int64  `json:"total_tokens"`
    CacheHits    int64  `json:"cache_hits"`
}
```

**Functions:**
```go
func FetchRuns(ctx context.Context, projectDir string) ([]Run, error)
func FetchDispatches(ctx context.Context, projectDir string, runID string) ([]Dispatch, error)
func FetchEvents(ctx context.Context, projectDir string, runID string, limit int) ([]Event, error)
func FetchTokens(ctx context.Context, projectDir string, runID string) (TokenSummary, error)
```

Each function: `exec.CommandContext(ctx, "ic", args...)`, set `cmd.Dir = projectDir`, parse JSON from stdout, handle errors (ic not found, no DB, empty output).

**Files:** `internal/status/data.go`

### Task 2: Run list pane — `internal/status/runs.go`

Renders the run list with phase progress bars.

**Components:**
- Cursor-navigable list of runs (up/down arrows, wrapping)
- Each row: status symbol + run ID (8 chars) + goal (truncated) + phase name + progress bar
- Progress bar: `indexOf(phase, phases) / len(phases)` → filled/empty blocks
- Selected row highlighted with `pkg/tui.SelectedStyle`
- Section header: "RUNS" in `pkg/tui.HeaderStyle`

**Interface:**
```go
type RunsPane struct {
    runs     []Run
    cursor   int
    width    int
    height   int
}

func NewRunsPane() *RunsPane
func (p *RunsPane) SetRuns(runs []Run)
func (p *RunsPane) SelectedRun() *Run
func (p *RunsPane) Update(msg tea.KeyMsg) bool  // returns true if consumed
func (p *RunsPane) View() string
func (p *RunsPane) SetSize(w, h int)
```

**Files:** `internal/status/runs.go`

### Task 3: Dispatch pane — `internal/status/dispatches.go`

Renders dispatches for the selected run.

**Components:**
- List of dispatches for current run
- Each row: dispatch ID + agent name + status indicator + duration + model
- Duration: `time.Since(createdAt)` for running, `updatedAt - createdAt` for completed
- Section header: "DISPATCHES (run-id)" or "NO ACTIVE RUN" if none selected
- Empty state: "No dispatches" in muted style

**Interface:**
```go
type DispatchPane struct {
    dispatches []Dispatch
    runID      string
    width      int
    height     int
}

func NewDispatchPane() *DispatchPane
func (p *DispatchPane) SetDispatches(runID string, dispatches []Dispatch)
func (p *DispatchPane) View() string
func (p *DispatchPane) SetSize(w, h int)
```

**Files:** `internal/status/dispatches.go`

### Task 4: Events pane — `internal/status/events.go`

Renders the event stream for the selected run.

**Components:**
- Last N events, newest at bottom
- Each row: timestamp (HH:MM:SS) + event type + entity ID + payload summary
- Section header: "EVENTS (last N)"
- Auto-scrolls to bottom on new data
- Empty state: "No events" in muted style

**Interface:**
```go
type EventsPane struct {
    events []Event
    width  int
    height int
}

func NewEventsPane() *EventsPane
func (p *EventsPane) SetEvents(events []Event)
func (p *EventsPane) View() string
func (p *EventsPane) SetSize(w, h int)
```

**Files:** `internal/status/events.go`

### Task 5: Main model — `internal/status/model.go`

The `tea.Model` that orchestrates the panes, handles polling, and composes the layout.

**Structure:**
```go
type Model struct {
    runs       *RunsPane
    dispatches *DispatchPane
    events     *EventsPane

    projectDir string
    width      int
    height     int

    // Polling
    lastFetch  time.Time
    fetching   bool
    err        error

    // Token summary for footer
    tokens     TokenSummary
}
```

**Messages:**
```go
type tickMsg struct{}
type dataMsg struct {
    Runs       []Run
    Dispatches []Dispatch
    Events     []Event
    Tokens     TokenSummary
    Err        error
}
```

**Flow:**
1. `Init()`: Return `tea.Batch(fetchData(projectDir), tickEvery(3*time.Second))`
2. `Update(tickMsg)`: If not already fetching, start `fetchData` command
3. `Update(dataMsg)`: Update all panes with new data, clear `fetching` flag
4. `Update(tea.KeyMsg)`: Route to runs pane for navigation, handle `q`/`ctrl+c` quit, `r` for force refresh
5. `View()`: Compose vertically: header + runs pane + dispatch pane + events pane + footer (tokens + help)

**Layout allocation** (for an 80-row terminal):
- Header: 1 line
- Runs: 30% of remaining height
- Dispatches: 30%
- Events: 30%
- Footer: 2 lines (tokens + keybindings)

When a different run is selected (cursor changes), immediately re-fetch dispatches/events for the new run.

**Files:** `internal/status/model.go`

### Task 6: Cobra subcommand — `cmd/autarch/status.go`

Wire the `status` subcommand into the existing Cobra root.

**Flags:**
- `--project` (string): Project directory path (default: CWD, auto-discover `.clavain/` walking up)
- `--once` (bool): Print status once and exit (no TUI, JSON output for scripting)

**Flow:**
1. Resolve project dir (flag or CWD walk-up)
2. Verify `ic` is in PATH
3. Verify `.clavain/intercore.db` exists in project dir
4. If `--once`: fetch + print JSON + exit
5. Else: create `status.Model`, run `tea.NewProgram(model, tea.WithAltScreen())`

**Registration:** Add `root.AddCommand(statusCmd())` in main.go.

**Files:** `cmd/autarch/status.go`, edit `cmd/autarch/main.go` (one line)

### Task 7: Build and test

1. `go build ./cmd/autarch` — verify compilation
2. Run `autarch status` from `/root/projects/Interverse` — verify it shows the active runs
3. Test with `--once` flag for non-interactive output
4. Test from a dir with no `.clavain/` — verify clean error message
5. Test with `ic` not in PATH — verify clean error message

## Dependencies Between Tasks

```
Task 1 (data) ─┬─→ Task 2 (runs)
               ├─→ Task 3 (dispatches)
               └─→ Task 4 (events)
                        │
Tasks 2-4 ────────→ Task 5 (model)
                        │
Task 5 ───────────→ Task 6 (cobra)
                        │
Task 6 ───────────→ Task 7 (build+test)
```

Tasks 2, 3, 4 can be written in parallel once Task 1 is done.

## Risk Assessment

- **Low risk:** This is a read-only tool with no state mutations, no external dependencies beyond `ic`, and no persistence.
- **Dependency risk:** `ic` CLI output format may differ from what we observed. Mitigation: defensive JSON parsing with zero-value fallbacks.
- **Layout risk:** Fixed height allocation may not work well on very small terminals. Mitigation: minimum height check, degrade gracefully (hide events pane below 30 rows).
