# Autarch Status Tool — PRD

**Bead:** iv-qloe
**Date:** 2026-02-20
**Status:** Draft
**Brainstorm:** [brainstorm](../brainstorms/2026-02-20-autarch-status-tool-brainstorm.md)

---

## Problem Statement

Engineers running Intercore-backed sprints need a quick way to see "what's running right now?" without parsing raw JSON from multiple `ic` commands. The full Bigend migration to Intercore is a large effort (`iv-ishl`). A minimal status tool serves as both an immediate utility and a validation wedge for the kernel's query APIs + `pkg/tui` component library.

## Solution

A standalone Bubble Tea TUI — `autarch status` — that reads Intercore kernel state via `ic` CLI and renders:
- Active runs with phase progress bars
- Dispatches for the selected run
- Recent event stream
- Token consumption per run

## Features

### F1: Run List with Phase Progress

Display all active runs from `ic run list --active --json`. Each row shows:
- Run ID (short)
- Goal (truncated to fit)
- Current phase name
- Phase progress bar: `██░░░░░░` computed from `indexOf(phase, phases) / len(phases)`
- Complexity badge (1-5)

Navigation: arrow keys move cursor, Enter selects a run to show detail in the lower panes.

### F2: Dispatch List

For the selected run, display active dispatches from `ic dispatch list --active --json` filtered by `run_id`. Each row shows:
- Dispatch ID
- Agent name
- Status (running/completed/failed)
- Duration (computed from timestamps)
- Model name (if available)

Uses `pkg/tui.StatusIndicator` for status badges.

### F3: Event Stream

For the selected run, display the last 20 events from `ic events tail <run> --limit=20`. Each row shows:
- Timestamp (HH:MM:SS)
- Event type
- Entity ID
- Summary from payload

Auto-scrolls to bottom. Refreshes on each poll cycle.

### F4: Token Summary

Footer bar showing per-run token totals from `ic run tokens <id> --json`:
- Input tokens (formatted with commas)
- Output tokens (formatted with commas)
- Total

### F5: Polling and Refresh

- Automatic poll every 3 seconds via `tea.Tick`
- Manual refresh with `r` key
- Poll executes `ic` commands in background goroutine, sends results as `tea.Msg`
- No blocking the main TUI loop during data fetch

## Resolved Decisions

| Question | Decision | Rationale |
|----------|----------|-----------|
| Binary name | `autarch status` subcommand | Extends existing `cmd/autarch/main.go` Cobra root; avoids another binary in PATH |
| Architecture | Standalone tea.Model, not UnifiedApp tab | Minimal footprint; validates ic+pkg/tui in isolation |
| Multi-project | Current project only (v1) | CWD-based auto-discovery of `.clavain/intercore.db` |
| DB path | Auto-discover from CWD + `--project` flag override | Matches `ic` behavior; `--project` for running from anywhere |
| Layering | Lives in Autarch (Layer 3), not Intercore (Layer 1) | Preserves architecture: kernel has no TUI deps |

## File Structure

```
cmd/autarch/status.go       — Cobra `status` subcommand wiring
internal/status/
  model.go                   — Main tea.Model (Init, Update, View)
  runs.go                    — Run list rendering + phase progress
  dispatches.go              — Dispatch list rendering
  events.go                  — Event stream rendering
  data.go                    — ic CLI exec, JSON parse, data types
```

## Non-Goals (v1)

- Intermute integration
- Agent discovery via tmux
- Write operations (creating runs, advancing phases)
- Web interface
- Signal broker / WebSocket
- Multi-project aggregation
- Follow mode (`ic events tail --follow`) — defer to v2

## Success Criteria

1. `autarch status` launches from any project with a `.clavain/intercore.db` and shows active runs
2. Selecting a run shows dispatches and recent events
3. Data refreshes every 3 seconds without UI jank
4. Token totals visible per run
5. All data via `ic` CLI — zero filesystem scanning or tmux scraping
6. Tokyo Night theming via `pkg/tui` styles
7. Clean exit on `q` or `ctrl+c`
