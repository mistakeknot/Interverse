# Autarch Status Tool — Brainstorm

**Bead:** iv-qloe
**Phase:** brainstorm (as of 2026-02-20T17:13:01Z)
**Date:** 2026-02-20
**Status:** Draft

---

## Problem

The most common question during a sprint is "what's running right now?" Currently, answering this requires:
- `ic run list --active` (raw JSON)
- `ic dispatch list --active` (raw JSON)
- `ic events tail <run>` (raw JSON lines)
- Multiple commands, no unified view, no live update

Bigend provides a dashboard but it discovers data via filesystem scanning and tmux scraping — it doesn't read kernel state yet. The full Bigend migration (Phase 1 epic `iv-ishl`) is a large body of work. We need a smaller wedge that validates the kernel APIs are sufficient for TUI rendering.

## Goal

Build a minimal, standalone TUI that shows Intercore kernel state in real-time. It answers "what's running?" in one command: `autarch-status` (or `ic tui` — name TBD).

## Data Sources

All data comes from `ic` CLI with `--json` flag:

| Display | Command | Key Fields |
|---------|---------|------------|
| Run list | `ic run list --active --json` | id, goal, phase, phases[], status, scope_id, complexity |
| Run detail | `ic run status <id> --json` | Same + completed_at |
| Dispatches | `ic dispatch list --active --json` | id, agent_name, status, model, run_id, duration |
| Events | `ic events tail <run> --limit=20` | timestamp, event_type, entity_id, payload |
| Tokens | `ic run tokens <id> --json` | input_tokens, output_tokens, total_tokens |
| Gate status | `ic gate check <id>` | exit code 0=pass, 1=blocked |

**DB path gotcha:** The `ic` binary auto-discovers `.clavain/intercore.db` by walking up from CWD. The Interverse root DB is the canonical one. The tool should either: (a) run from the project dir, or (b) accept `--db` or `--project` flag.

## Architecture Options

### Option A: Standalone binary (Recommended)

New `cmd/status/main.go` entry point. Standalone `tea.Model` using `pkg/tui` styles and components. Runs independently — no Intermute, no UnifiedApp, no sidebar.

**Pros:** Minimal footprint, fast startup, can run from any project dir, validates `ic` + `pkg/tui` in isolation.
**Cons:** Can't share state with other Autarch tools.

### Option B: UnifiedApp tab

New 5th tab in UnifiedApp alongside Bigend/Gurgeh/Coldwine/Pollard.

**Pros:** Integrated experience, shares Intermute/signals.
**Cons:** Requires full Autarch startup, heavier, couples to existing data pipeline.

### Option C: `ic tui` subcommand in Intercore

Status tool lives in the kernel repo.

**Pros:** Single binary, no Autarch dependency.
**Cons:** Violates layering — apps (Layer 3) shouldn't live in kernel (Layer 1). Adds TUI dependencies (Bubble Tea, lipgloss) to the kernel binary.

**Decision:** Option A. It's the simplest, fastest, and cleanest validation of the kernel→app data flow. Can always be promoted to a UnifiedApp tab later.

## Layout Design

Three-pane vertical layout:

```
┌─ Autarch Status ──────────────────────────────────────┐
│                                                        │
│  RUNS                                                  │
│  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━  │
│  ● tkjd6vhn  Cost-aware scheduling    brainstorm ██░░  │
│  ● 6m0lbold  Skip Test                strategized ███░  │
│                                                        │
│  DISPATCHES (tkjd6vhn)                                 │
│  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━  │
│  D12  reviewer-arch   running  2m14s  Opus             │
│  D13  reviewer-qual   running  1m48s  Haiku            │
│  D14  reviewer-safe   done     3m02s  Sonnet           │
│                                                        │
│  EVENTS (last 10)                                      │
│  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━  │
│  14:23:01  dispatch.completed  D14  reviewer-safe      │
│  14:22:58  gate.passed         R42  plan-review        │
│  14:22:45  phase.advanced      R42  executing          │
│                                                        │
│  ─────────────────────────────────────────────────     │
│  Tokens: 12,450 in / 3,200 out  │  q: quit  ↑↓: nav  │
└────────────────────────────────────────────────────────┘
```

### Interaction Model

- **Arrow up/down:** Navigate run list (cursor highlights a run)
- **Enter:** Toggle expanded view for selected run (shows dispatches + events inline)
- **Tab:** Cycle focus between runs/dispatches/events panes
- **f:** Toggle follow mode for events (live tail)
- **r:** Force refresh
- **q:** Quit

### Phase Progress Bar

Calculate from the `phases[]` array and current `phase`:
```
index = indexOf(current_phase, phases)
total = len(phases)
filled = (index * bar_width) / total
```

Display: `brainstorm ██░░░░░░` (2/9 phases)

## Polling Strategy

- **Default:** Poll `ic` every 3 seconds (shelling out to `ic run list --active --json` etc.)
- **Follow mode:** Poll `ic events tail --follow` as a subprocess, stream JSON lines into the TUI
- **No WebSocket/signal broker needed** — the tool is lightweight; polling is fine for v1

### Future: Direct SQLite

When performance matters, bypass `ic` CLI and read `.clavain/intercore.db` directly via `modernc.org/sqlite` (already in go.mod). This eliminates exec overhead but couples to DB schema. Defer to v2.

## Component Reuse from pkg/tui

| Component | Usage |
|-----------|-------|
| Tokyo Night colors | All styling |
| `StatusIndicator` | Run/dispatch status badges |
| `LogPane` | Event stream display |
| Styles (`HeaderStyle`, `CardStyle`, etc.) | Section headers, borders |
| `CommonKeys` + `HandleCommon` | Quit, help bindings |

**Not needed:** ChatPanel, Composer, CommandPicker, AgentSelector, ShellLayout, SplitLayout, Sidebar. The status tool is simpler than those — just stacked sections with a list.

## File Structure

```
cmd/status/main.go         — Entry point, Cobra root command, tea.NewProgram
internal/status/
  model.go                  — Main tea.Model (Init, Update, View)
  runs.go                   — Run list pane + phase progress rendering
  dispatches.go             — Dispatch list pane
  events.go                 — Event stream pane
  data.go                   — ic CLI exec + JSON parsing
  styles.go                 — Local style overrides (if any beyond pkg/tui)
```

## Open Questions

1. **Binary name:** `autarch-status`, `ic-status`, or just a flag on the main `autarch` binary (`autarch status`)?
   - Leaning toward `cmd/status/` → compiles to `status` → renamed to `autarch-status` in Makefile
   - Or: add `status` subcommand to existing `cmd/autarch/main.go`

2. **Multi-project:** Should it show runs across all project DBs, or just the current project?
   - v1: Current project only (CWD-based auto-discovery)
   - v2: `--all` flag that scans known project dirs

3. **Dispatch detail:** The `ic dispatch list` output may not include model name and duration in v1. Need to verify.

## Non-Goals (v1)

- No Intermute integration
- No agent discovery via tmux
- No write operations (no creating runs, advancing phases)
- No web interface
- No signal broker / WebSocket
- No multi-project aggregation

## Success Criteria

1. `autarch-status` (or `autarch status`) launches and shows active runs with phase progress
2. Selecting a run shows its dispatches and recent events
3. Event stream updates on each poll cycle (3s default)
4. Token totals shown per run
5. All data comes from `ic` CLI — no filesystem scanning, no tmux scraping
6. Uses `pkg/tui` styles for consistent Tokyo Night theming
