# dmux Repository Analysis for Autarch

**Date:** 2026-02-19
**Source:** https://github.com/standardagents/dmux (canonical: https://github.com/formkit/dmux)
**Repo Stats:** 394 stars, 32 forks, created Aug 2025, primary language HTML (frontend docs), logic is TypeScript
**Version:** 5.1.0

---

## 1. What Does It Do?

dmux is a **dev agent multiplexer** built on top of tmux. Its core purpose: let developers run multiple AI coding agents (Claude Code, Codex, OpenCode) in parallel, each in a completely isolated git worktree, managed from a single TUI sidebar.

Key capabilities:
- Creates a new tmux pane + git worktree + branch per task ("pane")
- Monitors agent status in real-time (working / analyzing / waiting / idle)
- Detects when agents need user input (option dialogs) — can autopilot-accept safe options
- Merges worktrees back to main when tasks complete (with AI-assisted conflict resolution)
- Exposes an HTTP API for programmatic control
- Streams live terminal output to a web dashboard via SSE

It is **not** an orchestration layer in the Intercore/Autarch sense. It is closer to a "parallel worktree manager with agent awareness." It has no concept of phases, gates, sprints, or structured task decomposition.

---

## 2. Technology Stack

| Layer | Technology |
|-------|-----------|
| TUI framework | **Ink** (React for terminals, v5) + React 18 |
| Language | TypeScript (ESM modules, Node 18+) |
| HTTP server | **h3** (lightweight, Vite-compatible) |
| Frontend dashboard | Vue 3 + Vite (separate package in monorepo) |
| tmux integration | Direct `execSync`/`spawn` shell calls via `TmuxService` |
| Worker threads | Node.js `worker_threads` — one worker per pane |
| LLM for status detection | OpenRouter API (Gemini 2.5 Flash, Grok-4-fast, GPT-4o-mini in parallel fallback) |
| File watching | chokidar |
| Testing | Vitest, Playwright (e2e) |
| Build | tsc + tsx (dev watch) |
| Package manager | pnpm |

**Important**: The TUI is Ink/React, not Bubble Tea. The patterns are architecturally instructive but must be translated to Go/Bubble Tea idioms.

---

## 3. Architectural Patterns

### 3.1 Sidebar + Content Split

```
┌──────────────────┬────────────────────────────────┐
│  dmux TUI (Ink)  │  tmux pane 1 (agent 1)          │
│  Left sidebar    │                                  │
│  40 chars wide   ├────────────────────────────────┤
│                  │  tmux pane 2 (agent 2)          │
│  Pane list:      │                                  │
│  ✻ fix-auth-bug  ├────────────────────────────────┤
│  ◌ add-feature   │  tmux pane 3 (agent 3)          │
│  ⟳ refactor-api  │                                  │
└──────────────────┴────────────────────────────────┘
```

The TUI itself is one tmux pane (the "control pane") occupying a fixed 40-character sidebar. All actual agent activity happens in adjacent tmux panes that dmux creates/destroys. The Ink TUI just renders the sidebar list — it does not render the agent output.

**Autarch relevance:** Bigend should follow the exact same pattern. The Bubble Tea TUI is the sidebar/dashboard; Intercore agent runs happen in adjacent tmux panes or tracked separately.

### 3.2 Worker-Per-Pane Polling Architecture

Each pane gets a dedicated Node.js **worker thread** (`PaneWorker.ts`) that polls tmux every 1 second:

```
Main thread (Ink TUI)
    │
    ├─ StatusDetector (EventEmitter singleton)
    │       │
    │       ├─ PaneWorkerManager
    │       │       ├─ Worker thread: pane-1 (polls tmux %3 every 1s)
    │       │       ├─ Worker thread: pane-2 (polls tmux %5 every 1s)
    │       │       └─ Worker thread: pane-N ...
    │       │
    │       └─ PaneAnalyzer (LLM calls via OpenRouter)
    │
    └─ StateManager (singleton, pub/sub)
```

Worker detection logic:
1. Capture last 30 lines from tmux pane content
2. Look for **deterministic indicators** first (fast path, no LLM):
   - `(esc to interrupt)` → `working`
   - Progress symbols + "-ing..." words → `working`
3. If no deterministic indicators and content stopped changing for 3 captures → emit `analysis-needed`
4. Main thread receives `analysis-needed`, calls LLM (OpenRouter) to classify:
   - `in_progress` → keep as `working`
   - `option_dialog` → `waiting` (extract options for display)
   - `open_prompt` → `idle` (extract summary of what agent completed)

**Autarch relevance for Bigend/Coldwine:** Intercore already tracks phase/event state in SQLite. The pattern of "worker per agent run, polling for state changes, reporting up to a coordinator" maps directly. For Autarch:
- Worker = `ic` event stream or SQLite polling goroutine per active run
- Deterministic indicators = phase gate status, event type
- LLM analysis = not needed (Intercore has structured state)

### 3.3 Singleton StateManager with Pub/Sub

```typescript
StateManager.getInstance()
  .subscribe(callback)   // React component hooks subscribe here
  .updatePanes(panes)    // Any service can push updates
  .getPaneById(id)
```

The StateManager is a central event bus that bridges:
- File-based persistence (JSON config file, watched with chokidar)
- Worker thread updates
- HTTP API state
- Ink/React component re-renders

**Autarch relevance:** Bubble Tea's model/update/view pattern is the equivalent. The StateManager pattern is a Singleton + EventEmitter — in Bubble Tea, this is the `Model` struct + `tea.Cmd` message pipeline. Keep state centralized. Use `tea.Batch` for concurrent state updates from multiple goroutines (run goroutines, send `tea.Msg` on update).

### 3.4 Pane Lifecycle with Explicit Locking

`PaneLifecycleManager` prevents race conditions when a pane is being closed:

```
beginClose(paneId, reason)
  → sets closingPanes lock
  → emits "pane-closing"
  → [close operation happens]
completeClose(paneId)
  → clears lock
  → emits "pane-closed"

isClosing(paneId)  // workers check this before reporting missing panes
```

The `withLock()` method uses a Promise chain (not mutex) to serialize operations on a single pane.

**Autarch relevance:** For Coldwine managing agent dispatch/lifecycle, use a similar guard. When a Coldwine task is being cancelled, set a "closing" flag before modifying Intercore state so the polling goroutine doesn't mis-report it as a failure.

### 3.5 Dual Detection Mode: Hooks vs. Polling

dmux offers two pane-change detection strategies:
- **tmux hooks** (low CPU): installs tmux `after-new-window`, `pane-exited` etc. hooks that call back to dmux via a named pipe. 100ms debounce.
- **Worker polling** (fallback): dedicated worker thread, 1s intervals.

Asks user on first run, saves preference. Auto-detects if hooks already installed.

**Autarch relevance:** For Bigend monitoring Intercore runs, prefer the hooks/event pattern. SQLite `NOTIFY`-equivalent or a file-based event tail rather than constant polling. Intercore emits events — subscribe to those rather than polling.

### 3.6 Actions System (Composable UI Flows)

All user-triggered operations return `ActionResult`:

```typescript
type ActionResult =
  | { type: 'confirm'; title; message; onConfirm; onCancel }
  | { type: 'choice'; title; choices; onChoice }
  | { type: 'input'; title; placeholder; onSubmit }
  | { type: 'progress'; title; steps; onComplete }
  | { type: 'done'; message? }
```

The TUI renders dialogs based on what the current action returns — it doesn't contain dialog logic. Multi-step flows chain these: merge → confirm dialog → progress dialog → done.

**Autarch relevance:** This is the correct pattern for Bubble Tea too. Define `tea.Msg` types for each dialog/step result. Keep the UI model thin — actions are pure functions returning the next dialog state, not mixed into the view.

### 3.7 Multi-Repository Mode

dmux supports multiple git repos in one session. Panes are grouped by `projectRoot`:

```
─────────────────────
 Project: api
◌ fix-auth
✻ add-logging
─────────────────────
 Project: frontend
◌ redesign-nav
```

Navigation (`selectedIndex`) is flat (indexes across all groups). Display is grouped.

**Autarch relevance:** Bigend's "multi-project mission control" is exactly this. Group runs by project/repo, but keep selectedIndex flat for keyboard navigation.

### 3.8 Layout Algorithm

`LayoutCalculator` scores all possible column counts (1..N) for N content panes:

```
Score = balanceFactor * heightScore * widthScore
balanceFactor = 0.5 if last row has single pane, else 1.0
heightScore = paneHeight / terminalHeight
widthScore = 1.0 if within MAX_COMFORTABLE_WIDTH, else 0.8
```

Constants: `SIDEBAR_WIDTH=40`, `MIN_COMFORTABLE_WIDTH=60`, `MAX_COMFORTABLE_WIDTH=120`, `MIN_COMFORTABLE_HEIGHT=15`.

Window is capped at `SIDEBAR_WIDTH + cols * MAX_COMFORTABLE_WIDTH`, preventing panes from stretching beyond readable width on wide terminals.

**Autarch relevance:** For Bigend, the tmux layout math is directly reusable. When opening sub-panes for an active run, calculate optimal column count using the same scoring algorithm. Port the constants to Go.

---

## 4. Key UI/UX Patterns

### 4.1 Status Icon System

Five status states with consistent iconography:

| Status | Icon | Color |
|--------|------|-------|
| `working` | `✻` | cyan |
| `analyzing` | `⟳` | magenta |
| `waiting` (needs input) | `⚠` | yellow |
| `idle` | `◌` | gray |
| Test passing | `✓` | green |
| Test failing | `✗` | red |
| Dev running | `▶` | green |

The `analyzing` state is a brief intermediate: the worker knows the agent stopped but before the LLM classifies whether it's idle or waiting. This prevents the UI from flickering between `working` and `idle`.

**Autarch relevance:** Adopt this 4-state status model for Intercore runs. Map to Intercore phases:
- `working` → run in active phase, events flowing
- `analyzing` → phase gate evaluating
- `waiting` → gate blocked, needs intervention
- `idle` → run complete or not started

### 4.2 Card-Based Pane List with Box Drawing

Each pane card uses Unicode box drawing with context-sensitive borders:
- Top card: `╭─────╮`
- Middle cards: `├─────┤`
- Bottom card: `╰─────╯`
- Selected card border color changes to accent (orange)
- The border between a selected card and its neighbor also uses accent color

Content within each card (36 chars max):
```
│ ✻ fix-auth-bug [cc] (ap) │
```
- Status icon + pane slug + agent abbreviation + autopilot indicator

**Autarch relevance for Bigend:** Use the same card pattern for run/phase display. Each "run" card shows: status icon, run name, current phase, elapsed time. The selected card should highlight its separator borders too.

### 4.3 Footer Help Bar

A persistent `FooterHelp` component at the bottom renders available keyboard shortcuts. Dynamically adapts based on current selected item (merge option only appears if worktree pane selected).

**Autarch relevance:** Standard Bubble Tea footer. Render context-sensitive help. For Bigend, the available actions change based on selected item type (run vs. phase vs. dispatch).

### 4.4 Toast Notifications

`ToastService` (singleton) manages a queue of toast messages. Only one is visible at a time; others queue. Toast has position indicator ("2/4" in queue). Displayed as overlay in the TUI.

**Autarch relevance:** Use toast-style notifications for async events (agent spawned, phase completed, gate failed). Queued toasts prevent information loss when multiple events fire simultaneously.

### 4.5 Autopilot Mode (Risk-Gated Auto-Accept)

When a pane is in `waiting` state and autopilot is enabled:
1. LLM extracts `potentialHarm: { hasRisk: boolean, description }`
2. If `hasRisk = false`: automatically send the first option's key
3. If `hasRisk = true`: show the options dialog to user, do not auto-accept

**Autarch relevance for Coldwine:** This is the "supervised automation" pattern. Coldwine coordinates agents — when an agent hits a decision point, Coldwine's autopilot checks if the decision is safe before auto-proceeding. Unsafe decisions surface to the Bigend operator dashboard.

### 4.6 LLM Caching and Request Deduplication

`PaneAnalyzer` uses content-hash-based caching:
- Cache key: MD5 hash of captured terminal content
- TTL: 5 seconds
- Max size: 100 entries (LRU eviction)
- Pending request deduplication: if same pane+content hash is already being analyzed, return the same promise

Parallel model fallback: races all models with `Promise.any()` — first success wins. Previously sequential (could take 6s), now typically <1s.

**Autarch relevance for Gurgeh/Pollard:** When running LLM-based analysis (confidence scoring in Gurgeh, insight synthesis in Pollard), use the same content-hash cache and `Promise.any` parallel model race. For Go: goroutines + `errgroup` or channel select for parallel model race.

### 4.7 A/B Launch (Parallel Agent Comparison)

dmux can launch two different agents on the same prompt simultaneously, creating two panes side by side. The slug gets an agent-suffix appended (`fix-auth-bug-claude-code` and `fix-auth-bug-opencode`).

**Autarch relevance for Pollard:** Pollard's "multi-domain hunters" are exactly this — multiple agents researching the same question with different approaches, results synthesized. Use A/B naming convention: `hunt-{slug}-{hunter-id}`.

### 4.8 Hooks System (Lifecycle Integration)

10 hook points covering the full pane lifecycle:
- `before_pane_create`, `pane_created`
- `worktree_created`, `before_worktree_remove`, `worktree_removed`
- `before_pane_close`, `pane_closed`
- `pre_merge`, `post_merge`
- `run_test`, `run_dev` (HTTP callback hooks)

Hooks receive environment variables (`DMUX_PANE_ID`, `DMUX_SLUG`, `DMUX_WORKTREE_PATH`, `DMUX_SERVER_PORT`, etc.). `run_test`/`run_dev` hooks call back to the dmux HTTP API to report status.

**Autarch relevance for Intercore:** This is the Intercore event/hook system. Map to Intercore's run lifecycle events:
- `before_pane_create` → `run.created`
- `worktree_created` → `phase.started`
- `run_test` → `gate.evaluating` → HTTP callback to ic API with result
- `post_merge` → `run.completed`

### 4.9 HTTP API with SSE Streaming

REST API at `localhost:{auto-port}`:
- `GET /api/health` — health check
- `GET /api/session` — session info
- `GET /api/panes` — list all panes with status
- `GET /api/panes-stream` — SSE stream, pushes `init`/`update`/`heartbeat` events
- `POST /api/panes` — create pane programmatically
- `GET /api/panes/:id` — get specific pane
- `GET /api/panes/:id/snapshot` — capture terminal content
- `PUT /api/panes/:id/test` — update test status (from hook)
- `PUT /api/panes/:id/dev` — update dev server status (from hook)

SSE stream eliminates polling — clients get pushed updates as state changes.

**Autarch relevance for Bigend:** Intercore (`ic`) should expose a similar HTTP API. Bigend subscribes to the SSE stream from Intercore for real-time phase/event updates rather than polling. This is a direct architecture recommendation.

### 4.10 Terminal Streaming to Web Dashboard

`TerminalStreamer` pipes live tmux pane content to browser clients via Node.js `Readable` streams:
1. On client connect: send `InitMessage` (full content + cursor position + dimensions)
2. Start `tail -f` process on a named pipe fed by tmux `pipe-pane`
3. Diff content changes, send `PatchMessage` with delta
4. Resize: detect terminal resize, send `ResizeMessage`
5. Heartbeat every 30s to prevent timeout

Clients receive raw ANSI content and render it with a terminal emulator (xterm.js presumably).

**Autarch relevance for Bigend:** The web dashboard pattern is worth noting for a future Bigend web companion. For TUI, use the same approach: display summary/status in the sidebar, let the user jump to the actual tmux pane for full terminal view. Don't try to render terminal output inside Bubble Tea.

---

## 5. Patterns Autarch Should Adopt

### 5.1 ADOPT: Fixed Sidebar + Adjacent tmux Panes

- Autarch TUI = narrow sidebar (40-60 cols), full-terminal Ink/BubbleTea
- Agent runs = adjacent tmux panes, not rendered inside the TUI
- The TUI never tries to display raw agent output — only structured status/metadata

### 5.2 ADOPT: Worker-Per-Run Polling with Deterministic Fast Path

For Bigend/Coldwine monitoring Intercore runs:
```go
// Per-run goroutine
go func(runID string) {
    ticker := time.NewTicker(1 * time.Second)
    for range ticker.C {
        status := ic.GetRunStatus(runID)
        if isDeterministic(status) {  // phase gate passed/failed = no LLM needed
            updateChan <- StatusUpdate{runID, status}
        } else if contentChanged(runID) {
            // Request analysis (if needed — Intercore usually doesn't need LLM here)
        }
    }
}()
```

For Gurgeh/Pollard where LLM analysis is needed, use the parallel model race pattern.

### 5.3 ADOPT: 4-State Status Model

Map Intercore run states to the working/analyzing/waiting/idle model with consistent icons. Keep these the same across all Autarch apps.

```go
type RunStatus string
const (
    StatusWorking  RunStatus = "working"   // icon: ✻, color: cyan
    StatusGating   RunStatus = "analyzing" // icon: ⟳, color: magenta
    StatusBlocked  RunStatus = "waiting"   // icon: ⚠, color: yellow
    StatusIdle     RunStatus = "idle"      // icon: ◌, color: gray
    StatusDone     RunStatus = "done"      // icon: ✓, color: green
    StatusFailed   RunStatus = "failed"    // icon: ✗, color: red
)
```

### 5.4 ADOPT: ActionResult Chaining for Multi-Step Flows

In Bubble Tea, define a discriminated union of `tea.Msg` types for dialog steps. Each action returns the next `tea.Cmd`. Merge/resolve flows chain confirm → progress → done without mixing logic into the view.

```go
type ActionMsg interface{ isActionMsg() }
type ConfirmMsg struct{ Title, Body string; OnConfirm, OnCancel tea.Cmd }
type ProgressMsg struct{ Steps []string; OnComplete tea.Cmd }
type DoneMsg struct{ Message string }
```

### 5.5 ADOPT: Content-Hash Cache for LLM Analysis (Gurgeh/Pollard)

```go
type AnalysisCache struct {
    mu      sync.RWMutex
    entries map[string]CacheEntry  // MD5(content) → result
    ttl     time.Duration
}
```

Use `golang.org/x/sync/errgroup` for parallel model race (first success wins).

### 5.6 ADOPT: Risk-Gated Autopilot (Coldwine)

Before auto-accepting any agent decision:
1. Classify the decision: safe / risky / destructive
2. If safe: auto-proceed, log to Intercore event stream
3. If risky: surface to Bigend operator panel, wait for human confirmation
4. Never auto-accept destructive operations

### 5.7 ADOPT: Lifecycle Hook System

Intercore already has events. Map them to Autarch hook invocations. The hook script receives env vars and can call back to the Autarch HTTP API with results (same as dmux's `run_test`/`run_dev` hooks).

### 5.8 ADOPT: SSE for Real-Time Updates

Expose `GET /api/runs-stream` from Intercore/Autarch backend. Bigend TUI subscribes on startup and receives push events instead of polling. Event types: `run.started`, `phase.advanced`, `gate.blocked`, `dispatch.spawned`, `run.completed`.

### 5.9 ADOPT: Multi-Project Grouping with Flat Index Navigation

For Bigend displaying multiple projects:
- Group run cards by project in display
- Keep `selectedIndex` flat (not nested per-project)
- Show project separator headers only when >1 project active

### 5.10 SKIP: Git Worktree Management

dmux's worktree isolation is specific to its use case (parallel code edits). Autarch agents don't need worktree isolation — they work through Intercore's structured run/phase/dispatch model. Skip the worktree machinery entirely.

### 5.11 SKIP: LLM-Based Terminal Content Analysis for Status

dmux needs LLM analysis because agents emit free-form terminal output with no structured status. Intercore has structured SQLite state. Use Intercore's event stream directly for run status — no LLM needed for Bigend/Coldwine monitoring.

---

## 6. Architecture Gaps in dmux (What Autarch Adds)

| Capability | dmux | Autarch |
|-----------|------|---------|
| Task decomposition | None — user writes prompts manually | Coldwine: PRD → epics → stories → tasks |
| Phase tracking | None | Intercore: 8-phase sprint model with gates |
| Confidence scoring | None | Gurgeh: per-artifact confidence scores |
| Multi-domain research | None | Pollard: parallel hunters + synthesis |
| Structured event log | None (just file config) | Intercore SQLite: runs, phases, events, dispatches |
| Cross-run coordination | None | Coldwine: dependency graph, sequential/parallel |
| Operator dashboard | Basic (sidebar list) | Bigend: full mission control across projects |

dmux is a solid reference for the **UI interaction layer** but has no model for the structured orchestration that Autarch provides. The key insight: adopt dmux's UI patterns (sidebar, cards, status icons, actions system, SSE) and build on top of Intercore's structured model rather than free-form terminal monitoring.

---

## 7. File Structure Reference

Key source paths in dmux (for cross-reference):

- `src/types.ts` — Core types: `DmuxPane`, `AgentStatus`, `DmuxConfig`
- `src/DmuxApp.tsx` — Root TUI component, composes all hooks
- `src/shared/StateManager.ts` — Singleton pub/sub state
- `src/services/StatusDetector.ts` — Orchestrates worker + LLM analysis
- `src/services/PaneLifecycleManager.ts` — Locking for pane close race conditions
- `src/services/PaneWorkerManager.ts` — Spawns/restarts worker threads
- `src/workers/PaneWorker.ts` — Per-pane polling worker
- `src/workers/WorkerMessages.ts` — Worker message protocol types
- `src/services/PaneAnalyzer.ts` — LLM analysis with caching, parallel model race
- `src/services/TmuxService.ts` — Tmux shell command wrapper with retry logic
- `src/services/TerminalStreamer.ts` — SSE streaming of tmux pane to browser
- `src/layout/LayoutCalculator.ts` — Optimal grid column scoring algorithm
- `src/components/panes/PaneCard.tsx` — Card with box-drawing borders
- `src/components/panes/PanesGrid.tsx` — Multi-project grouped pane list
- `src/theme/colors.ts` — Centralized color theme
- `src/actions/types.ts` — ActionResult discriminated union
- `src/server/routes/streamRoutes.ts` — SSE stream endpoint
- `context/HOOKS.md` — Full lifecycle hooks documentation
- `context/API.md` — HTTP API reference
- `context/LAYOUT.md` — Layout system architecture notes
