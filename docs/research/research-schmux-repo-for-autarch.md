# Research: schmux Repo for Autarch Inspiration

**Date:** 2026-02-19
**Source:** https://github.com/sergeknystautas/schmux
**Purpose:** Extract patterns and ideas for Autarch — the Bubble Tea TUI suite (Bigend, Gurgeh, Coldwine, Pollard) that renders Intercore kernel state via `ic` CLI.

---

## 1. What Is schmux?

schmux (Smart Cognitive Hub on tmux) is a **multi-agent AI orchestration system** that runs multiple AI coding agents (Claude Code, Codex, Gemini CLI, or any custom CLI) simultaneously in isolated tmux sessions, each working on a separate git clone of the same repository. It provides:

- A **Go daemon** that manages session and workspace lifecycle
- A **React/TypeScript web dashboard** served over HTTP (port 7337) with WebSocket-streamed terminal output (xterm.js)
- A **CLI** for spawning, listing, attaching, and disposing sessions
- A feature called **NudgeNik** that uses an LLM to classify agent state from raw terminal output

Key self-description from the README: "Multi-Agent Orchestration on tmux — orchestrate multiple run targets across tmux sessions with a web dashboard for monitoring and management."

It was built by its own agents ("schmux is built by schmux"). Status as of Feb 2026: v1.1.1, actively developed.

---

## 2. Technology Stack

### Backend (Go)

```
Go 1.24.0
github.com/creack/pty v1.1.24         — PTY attachment for tmux sessions
github.com/gorilla/websocket v1.5.3   — WebSocket server
github.com/fsnotify/fsnotify v1.9.0   — Filesystem signal watching
github.com/google/uuid v1.6.0         — Session/workspace IDs
github.com/charmbracelet/huh v0.8.0   — TUI forms (for daemon setup wizard)
github.com/charmbracelet/bubbletea    — (indirect dep, via huh)
github.com/charmbracelet/lipgloss     — (indirect dep, via huh)
golang.org/x/term                     — Terminal utilities
```

**Note:** schmux uses Bubble Tea only indirectly (via the `huh` forms library for the initial config wizard). The main UI is a web dashboard, not a TUI. This is the key architectural difference from Autarch.

### Frontend (React/TypeScript)

```
React 18 + React Router
@xterm/xterm + @xterm/addon-unicode11 + @xterm/addon-web-links
TypeScript + CSS Modules
```

### Data Storage

- `~/.schmux/config.json` — user-editable config (repos, agents, workspace paths)
- `~/.schmux/state.json` — daemon-managed runtime state (workspaces, sessions)
- File-based signals — agents write to `$SCHMUX_STATUS_FILE` for status updates

### Infrastructure

- tmux as the process supervisor for all agent sessions
- Git worktrees/clones for workspace isolation
- Optional Cloudflare tunnel for remote access
- Optional Linear sync integration

---

## 3. Architectural Patterns

### 3.1 Daemon + Thin Clients

The daemon (`internal/daemon/daemon.go`) is a long-running background process that owns all state. Both the web dashboard and the CLI communicate with it via HTTP. This matches Autarch's relationship with `ic` — Autarch apps should be read-only consumers of kernel state, not state owners.

```
CLI commands → daemon HTTP API → session/workspace managers → tmux
Web dashboard → daemon HTTP API + WebSocket → session/workspace managers → tmux
```

### 3.2 Session as the Central Entity

A `Session` maps to exactly one tmux session and one workspace. Multiple sessions can share a workspace (multi-agent per directory). The session state machine is:

```
provisioning → running → stopped/failed
```

Sessions are never deleted immediately — they persist in "stopped" state for review. Disposal is a deliberate explicit action.

**Session data model:**
```go
type Session struct {
    ID           string
    WorkspaceID  string
    Target       string       // which agent (claude, codex, etc.)
    Nickname     string
    TmuxSession  string       // tmux session name
    CreatedAt    time.Time
    Pid          int
    LastOutputAt time.Time    // in-memory only
    LastSignalAt time.Time    // in-memory only
    // nudge/signal fields...
}
```

### 3.3 Workspace as Isolation Unit

Each workspace is a git clone/worktree. Workspaces track:
- Git dirty state, ahead/behind, lines added/removed, files changed
- Overlay manifest (local files like `.env` auto-copied to clones)
- Optional remote host ID (for SSH-based remote workspaces)

### 3.4 Separation of Signal Sources

schmux distinguishes two signal paths for knowing what an agent is doing:

1. **Direct file signals** — agents write `completed Done` to `$SCHMUX_STATUS_FILE`; a `FileWatcher` (inotify) detects changes within seconds
2. **NudgeNik LLM classification** — periodic polling of last 100 lines of tmux output, classified by an LLM into states (Needs Authorization / Needs Feature Clarification / Needs User Testing / Completed / Working)

The fallback from direct signals to NudgeNik kicks in if no signal is received for 5+ minutes.

**State mapping:**
```go
func MapStateToNudge(state string) string {
    switch state {
    case "needs_input":   return "Needs Authorization"
    case "needs_testing": return "Needs User Testing"
    case "completed":     return "Completed"
    case "error":         return "Error"
    case "working":       return "Working"
    }
}
```

### 3.5 PTY Attachment for Real-Time Streaming

The key real-time pattern in schmux is attaching a PTY to an existing tmux session:

```go
// SessionTracker maintains a long-lived PTY attachment for a tmux session.
type SessionTracker struct {
    sessionID      string
    tmuxSession    string
    clientCh       chan []byte    // buffered channel to websocket client
    ptmx           *os.File      // PTY file descriptor
    attachCmd      *exec.Cmd     // tmux attach-session process
    lastEvent      time.Time
    stopCh         chan struct{}
}

func (t *SessionTracker) attachAndRead() error {
    // Attach via: tmux attach-session -t =<name>
    attachCmd := exec.CommandContext(ctx, "tmux", "attach-session", "-t", "="+target)
    ptmx, err := pty.StartWithSize(attachCmd, &pty.Winsize{...})
    // Then read from ptmx in a loop, forward chunks to clientCh
}
```

The hybrid streaming architecture (chosen design):
- **Output**: PTY-attached tmux client reads real-time terminal data, forwards via channel to WebSocket
- **Input**: Sent via `tmux send-keys` command (not written to PTY)
- **Resize**: `tmux resize-window` + `pty.Setsize()`
- **Bootstrap**: On WebSocket connect, `tmux capture-pane -e -p -S -` sends last 1000 lines as a "full" snapshot, then live "append" chunks follow

**WebSocket message protocol:**
```json
// Server → Client
{ "type": "full", "content": "<initial scrollback>" }
{ "type": "append", "content": "<live chunk>" }

// Client → Server
{ "type": "input", "data": "<keystrokes>" }
{ "type": "resize", "data": "{\"cols\": 120, \"rows\": 40}" }
```

### 3.6 Compound Overlays (Multi-Agent Config Sync)

The `Compounder` watches overlay files (`.env`, local configs) across workspace clones. When one workspace's overlay file changes, the compounder uses an LLM to merge the change and propagates it to sibling workspaces. This uses `fsnotify` for inotify-based watching with debouncing.

### 3.7 NudgeNik: LLM-as-State-Machine

The most architecturally interesting feature. NudgeNik uses a structured prompt with JSON schema enforcement to parse agent state:

```go
const Prompt = `
You are analyzing the last response from a coding agent.
Choose exactly ONE state from the list below:
- Needs Authorization
- Needs Feature Clarification
- Needs User Testing
- Completed
...
Here is the agent's last response:
<<<
{{AGENT_LAST_RESPONSE}}
>>>
`

type Result struct {
    State      string   `json:"state"`
    Confidence string   `json:"confidence"`
    Evidence   []string `json:"evidence"`
    Summary    string   `json:"summary"`
    Source     string   `json:"source"`  // "agent" or "llm"
}
```

Terminal output is extracted by scanning for prompt lines, separator lines, choice lines, and agent status lines, stripping ANSI, then sending the last meaningful response to the LLM.

### 3.8 Lore (Persistent AI Memory)

The `Lore` system reads raw observation entries from workspace directories, calls an LLM curator to merge them into structured instruction files (CLAUDE.md, etc.), and writes the proposals back. This is a "memory compaction" loop for agents working in the same repo over time.

---

## 4. tmux Integration Patterns

### 4.1 Core tmux CLI Wrapper

schmux wraps tmux as a set of pure functions in `internal/tmux/tmux.go`:

```go
// Creation
CreateSession(ctx, name, dir, command)     // tmux new-session -d -s <name> -c <dir> <cmd>

// Inspection
SessionExists(ctx, name)                   // tmux has-session -t =<name>
GetPanePID(ctx, name)                      // tmux display-message -p "#{pane_pid}"
GetWindowSize(ctx, name)                   // tmux display-message -p "#{window_width} #{window_height}"
CaptureOutput(ctx, name)                   // tmux capture-pane -e -p -S - -t <name>
CaptureLastLines(ctx, name, lines, escapes)
IsPaneDead(ctx, name)                      // tmux display-message "#{pane_dead}"
GetCursorPosition(ctx, name)               // tmux display-message "#{cursor_x} #{cursor_y}"

// Control
SendKeys(ctx, name, keys)                  // tmux send-keys -t <name> <keys>
SendLiteral(ctx, name, text)               // tmux send-keys -l -t <name> <text>
KillSession(ctx, name)                     // tmux kill-session -t =<name>
RenameSession(ctx, old, new)               // tmux rename-session -t =<old> <new>
ResizeWindow(ctx, name, w, h)              // tmux resize-window -t =<name>:0.0 -x -y
SetWindowSizeManual(ctx, name)             // tmux set-option window-size manual
ConfigureStatusBar(ctx, name)              // Sets status-left to process name, clears rest
ListSessions(ctx)                          // tmux list-sessions -F "#{session_name}"
```

### 4.2 Session Naming

Sessions are named with a nickname pattern. The rename operation uses `=` prefix (exact match) to avoid ambiguous target errors:
```bash
tmux rename-session -t =<oldName> <newName>
tmux has-session -t =<name>       # exact match
tmux kill-session -t =<name>      # exact match
# BUT: tmux send-keys does NOT support = prefix
tmux send-keys -t <name> <keys>   # no = prefix
```

### 4.3 Status Bar Customization

schmux configures a minimal status bar on each session:
```go
func ConfigureStatusBar(ctx, sessionName) {
    SetOption(ctx, sessionName, "status-left", "#{pane_current_command} ")
    SetOption(ctx, sessionName, "window-status-format", "")
    SetOption(ctx, sessionName, "window-status-current-format", "")
    SetOption(ctx, sessionName, "status-right", "")
}
```

### 4.4 ANSI Stripping State Machine

schmux implements a full ANSI escape sequence parser to extract meaningful text from terminal output:
- CSI sequences (`\x1b[...`): cursor forward → spaces, cursor down → newlines, others stripped
- OSC sequences (`\x1b]...`): stripped entirely
- DCS/APC sequences: stripped entirely

Key heuristics for "meaningful" output:
```go
func IsPromptLine(text) bool // starts with ❯ or ›
func IsChoiceLine(text) bool // starts with number followed by . or )
func IsSeparatorLine(text) bool // 80%+ same character, len >= 10
func IsAgentStatusLine(text) bool // starts with ⎿ (Claude Code status lines)
```

### 4.5 Session Bootstrap Pattern

On WebSocket connect, schmux sends a "bootstrap" of the last 1000 lines from `capture-pane`, then switches to live streaming. This prevents blank terminal on connect:

```go
const bootstrapCaptureLines = 1000
bootstrap, err := tmux.CaptureLastLines(capCtx, sess.TmuxSession, bootstrapCaptureLines, true)
sendOutput("full", filteredBootstrap)
// then flush any queued chunks, then enter live loop
```

---

## 5. UI/UX Patterns (Web Dashboard)

While schmux's main UI is a web dashboard (not TUI), several patterns are worth extracting for Autarch:

### 5.1 Session Status Rendering

Sessions show:
- **NudgeNik state badge**: "Needs Authorization" / "Needs User Testing" / "Working" / "Completed"
- **Last activity timestamp**: "when did the terminal last produce output" (formatted as relative: "2m ago", "1h ago")
- **Last viewed timestamp**: "when did the user last look at this session"
- **Working spinner**: animated indicator for active sessions
- **Git status inline**: dirty indicator, branch, ahead/behind count, diff stats (lines +/-/files)

### 5.2 Workspace-First Navigation

The homepage groups sessions under their workspace. Each workspace is a card with:
- Repo + branch header
- Git status summary
- Tab bar: [Session 1] [Session 2] [+Spawn] [Diff] [Git History]
- Currently-selected session's terminal

This "workspace-as-container, sessions-as-tabs" pattern is interesting for Autarch's Bigend view (which could use Intercore `run` as container, `phases`/`dispatches` as tabs).

### 5.3 Session Tabs with Context

`SessionTabs` component renders:
- One tab per running session (with nickname + nudge state emoji)
- A spawn dropdown with quick-launch presets
- Diff tab (shows if any git changes exist)
- Git history DAG tab
- Preview tab (if a web server is detected in the session)

The tab bar intelligently shows/hides specialized tabs based on workspace state.

### 5.4 Real-Time Connection Indicator

A persistent connection status indicator (`HostStatusIndicator`) shows daemon connectivity. Dashboard shows "Disconnected" banner and reconnection progress when WebSocket drops.

### 5.5 Keyboard Mode System

A `KeyboardContext` manages keyboard capture state. The TUI has two modes:
- Normal: React shortcuts work (navigate, spawn, etc.)
- Terminal: keyboard captured for tmux input

### 5.6 Follow-Tail Mode

Terminal has "follow tail" mode (auto-scroll to bottom when new output arrives). Users can scroll up to review history, and a "Resume" button appears to jump back to bottom.

### 5.7 Attention Sound

When an agent signals completion or needs input, a notification sound plays. Can be disabled in config. Triggered by `NudgeSeq` monotonic counter increments (only on direct agent signals, not LLM polls).

### 5.8 Quick Launch Presets

Config stores reusable `{name, target, prompt}` combinations. The spawn dropdown shows these presets for one-click session creation with a pre-filled prompt.

---

## 6. Agent Monitoring Approaches

### 6.1 Dual-Signal Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│ Direct Signals (primary)                                        │
│  Agent writes: echo "completed Done" > $SCHMUX_STATUS_FILE      │
│  FileWatcher (inotify) detects → dashboard update in < 1s       │
├─────────────────────────────────────────────────────────────────┤
│ NudgeNik (fallback after 5+ min silence)                        │
│  Capture last 100 tmux lines                                    │
│  Extract latest agent response                                  │
│  LLM classifies state → structured JSON response                │
└─────────────────────────────────────────────────────────────────┘
```

### 6.2 Signal File Protocol

Agents write a signal file at a path injected via env var `$SCHMUX_STATUS_FILE`. Format: `STATE [message]` on first line.

Valid states: `needs_input`, `needs_testing`, `completed`, `error`, `working`

```bash
echo "completed All tests pass, ready for review" > "$SCHMUX_STATUS_FILE"
echo "needs_input Please approve database migration" > "$SCHMUX_STATUS_FILE"
```

schmux auto-provisions this via workspace CLAUDE.md injection before launching agents.

### 6.3 PID Monitoring Loop

```go
// Background goroutine polls session liveness
ticker := time.NewTicker(500 * time.Millisecond)
running := s.session.IsRunning(ctx, sessionID) // checks tmux has-session + pane_dead
if !running {
    close(sessionDead)
    return
}
```

### 6.4 Inactivity Threshold

Sessions are considered "inactive" if no terminal output for `nudgeInactivityThreshold = 15 seconds`. After 15s of inactivity, NudgeNik is triggered to classify the last output.

---

## 7. Patterns Relevant to Autarch

### 7.1 Intercore State as the "Workspace"

In Autarch's model, an Intercore `run` is analogous to a schmux `workspace`:
- Multiple `dispatches` within a run ≈ multiple `sessions` within a workspace
- `phases` are a linear progression (unlike schmux sessions which are parallel)
- `events` stream continuously (analogous to terminal output)

| schmux concept | Autarch equivalent |
|---|---|
| Workspace | Intercore Run |
| Session | Dispatch |
| Agent terminal output | Event stream from `ic events --run <id>` |
| NudgeNik state | Phase gate status from `ic run status` |
| tmux session | `ic dispatch show <id>` subprocess or shell |
| Signal file | Intercore dispatch exit code / audit trail |

### 7.2 Bootstrap + Stream Pattern for Bigend/Coldwine

The "full snapshot then live append" pattern from schmux's WebSocket design maps directly to Bubble Tea:

```go
// Autarch approach using ic CLI
// 1. Bootstrap: ic events --run <id> --last 1000  → load into viewport model
// 2. Stream: poll ic events --run <id> --since <cursor> periodically
// 3. On phase advance: ic run status → refresh phase strip at top
```

The key insight: capture initial state, then apply incremental deltas. Avoid full re-render on every tick.

### 7.3 Tracker Pattern for Event Polling

schmux's `SessionTracker` (one per session, background goroutine, channel to consumer) maps to what Autarch needs for each active run:

```go
// Autarch RunTracker pattern
type RunTracker struct {
    runID       string
    outputCh    chan []EventRow    // buffered
    stopCh      chan struct{}
    lastCursor  int               // ic events cursor
}

func (t *RunTracker) poll() {
    // call ic events --run <id> --since <cursor>
    // send new events to outputCh
    // update lastCursor
}
```

One tracker per visible run in Bigend. Stop tracker when run is disposed or scrolled off-screen.

### 7.4 Status Extraction from CLI Output

schmux's ANSI-stripping + heuristic extraction is needed when terminal output is raw. For Autarch, `ic` CLI output is structured (JSON or line-oriented), so extraction is simpler. But the **prompt/separator heuristics** are useful if Autarch ever needs to parse raw dispatch output.

### 7.5 Meaningful Output Debouncing

```go
const trackerActivityDebounce = 500 * time.Millisecond

// Only update "lastEvent" if content is meaningful
// "Small chunks (≤8 bytes without newline) are always meaningful"
// "Larger chunks need ANSI stripping to check for printable content"
```

For Autarch's event stream, debounce rapid event bursts before re-rendering the viewport (Bubble Tea tick aggregation).

### 7.6 Run State Lifecycle Display

schmux's session status display pattern for Autarch's run/phase view:

```
[Run ID: abc-123]  Repo: myproject  Branch: feature/auth
Phase: ████████░░░░░░  [3/5] Running: unit-tests
Last event: 2m ago  |  Status: Working  |  Agent: claude-opus-4-6

Dispatches:
  [claude]  ● Running   "Implement auth middleware"      2m ago
  [codex]   ✓ Completed "Write unit tests"              15m ago
  [gemini]  ! Needs Review  "Update API docs"            1h ago
```

Key display elements from schmux to adopt:
- **Relative timestamps** ("2m ago", "1h ago") for last activity
- **Status emoji/icon + text** (not just color, for accessibility)
- **Inline diff stats** (+42 -15 in 3 files) as a density indicator
- **Last-viewed vs last-active** separation (for "did I already check this?")

### 7.7 Workspace-as-Container Navigation Model

For Bigend (multi-project mission control), the schmux model suggests:

```
┌─────────────────────────────────────────────────┐
│  Run: abc-123   [Overview] [Phase 2] [Phase 3]  │ ← tab bar per run
├─────────────────────────────────────────────────┤
│  [Run: def-456] [Phase 1 ●] [Phase 2] [Events]  │
├─────────────────────────────────────────────────┤
│  [Run: ghi-789] [Completed ✓]                   │
└─────────────────────────────────────────────────┘
```

Navigation: vertical list of runs, horizontal tabs for phases/dispatches within each run.

### 7.8 NudgeNik → Intercore Phase Gate Analogy

schmux's NudgeNik (LLM state classifier) is Autarch's gate evaluator:
- NudgeNik: "is this agent done or blocked?" (retrospective analysis)
- Intercore phase gate: "did this phase succeed?" (pass/fail from ic CLI)

For Pollard (research intelligence), a NudgeNik-style LLM classifier on dispatch output could extract structured research findings from raw agent output.

### 7.9 Quick Launch → Autarch Spawn Wizard

schmux's quick-launch presets (stored config, one-click spawn) maps to Gurgeh (PRD generation):
- Pre-fill target, branch, prompt template
- Store as named presets in Intercore config
- One shortcut key to spawn a new research or PRD session

### 7.10 Compound Overlay → Multi-Run Config Sync

The Compounder's pattern (watch a file, LLM-merge changes, propagate to siblings) is relevant if Autarch needs to keep shared context files synchronized across parallel runs working on the same repo.

---

## 8. Key Architectural Insights for Autarch

### 8.1 "Human as Coordinator" Philosophy

schmux explicitly rejects agent-to-agent coordination. The human is always the central coordinator. From the philosophy doc:

> "Sessions are interactive by design. If you want fully autonomous pipelines, use CI/CD."

Autarch should adopt this: the TUI apps are observability and dispatch tools, not autonomous orchestrators. Intercore is the kernel; Autarch surfaces its state for human decision-making.

### 8.2 Avoid Rube Goldberg Scaffolding

From schmux's philosophy:
> "Don't overcomplicate the dev environment. Every script, harness, and loop you add is a 'feature' that requires maintenance."

For Autarch: each TUI app should do one thing well. Bigend observes runs. Gurgeh generates PRDs. Coldwine orchestrates tasks. Pollard researches. No cross-app coordination at the TUI layer.

### 8.3 State File vs Real-Time Streaming

schmux uses two persistence layers:
- `config.json` (user-owned, rarely changes)
- `state.json` (daemon-owned, frequently changes via atomic writes)

For Autarch, `ic` CLI is the state authority. TUI apps should read state via `ic` commands, not maintain their own state files. The Intercore DB is the single source of truth.

### 8.4 Bubble Tea Concurrency Model

schmux uses goroutines + channels extensively. For Bubble Tea, the equivalent is:
- `tea.Cmd` for async operations (ic CLI calls)
- `tea.Msg` for delivering results back to the update loop
- Background `tea.Tick` for periodic polling

The `SessionTracker` pattern (goroutine + buffered channel) should be adapted to Bubble Tea's message-passing model — not shared state + mutexes.

### 8.5 What schmux Does That Autarch Doesn't Need

- tmux session management (Autarch is a TUI, not a process supervisor)
- Git clone/checkout/workspace management (Intercore handles this)
- WebSocket terminal streaming (Autarch renders in terminal, not browser)
- React frontend (Autarch is Bubble Tea)
- Remote SSH workspace support
- Cloudflare tunnel integration
- Overlay file compounding

### 8.6 What schmux Does That Autarch Should Adopt

- Dual-signal status detection (direct + LLM fallback)
- Bootstrap-then-stream for event viewports
- Relative timestamp display with "last viewed" separation
- Session-as-tab navigation within a workspace/run
- Meaningful output debouncing before re-render
- Status emoji/badges (Needs Auth / Working / Completed / Error)
- Sound/notification on agent state change
- Quick-launch preset system
- Confirm-before-dispose for destructive actions

---

## 9. Structural Reference: schmux vs Autarch

| schmux Component | Autarch App | Role |
|---|---|---|
| Web Dashboard (HomePage) | **Bigend** | Multi-project mission control, run overview |
| Session terminal view | **Coldwine** | Per-dispatch event stream + task orchestration |
| Spawn wizard | **Gurgeh** | PRD generation wizard |
| NudgeNik classifier | **Pollard** | Research intelligence + status classification |
| Session tabs per workspace | Bigend run tabs | Per-run phase/dispatch tabs |
| Quick launch presets | Gurgeh templates | PRD/research prompt templates |
| Git history DAG | Bigend git view | Per-run commit graph |
| Diff viewer | Bigend diff panel | Per-run code changes |
| Config page | (ic config) | Handled by ic CLI, not Autarch |

---

## 10. Notable Code Patterns Worth Copying

### 10.1 UTF-8 Boundary Preservation

```go
func findValidUTF8Boundary(data []byte) int {
    // Walk backwards to find incomplete multi-byte sequences
    // Returns last complete UTF-8 character boundary
    // Prevents sending partial Unicode sequences over WebSocket
}
```

For Autarch: when streaming ic event text into a Bubble Tea viewport, apply the same boundary check to prevent partial rune rendering.

### 10.2 ANSI Filter for Mouse Sequences

```go
var filterSequences = [][]byte{
    []byte("\x1b[?1000h"), // X11 mouse tracking
    []byte("\x1b[?1049h"), // Enable alternate screen
    // etc.
}
func filterMouseMode(data []byte) []byte { ... }
```

For Autarch: if rendering raw subprocess output in a Bubble Tea viewport, filter alternate-screen and mouse-mode escape sequences to prevent corrupting the TUI.

### 10.3 Chunked Channel with Default Drop

```go
select {
case clientCh <- chunk:
default:
    // drop if consumer is too slow — never block the producer
}
```

For Autarch: event stream → Bubble Tea program channel. Use buffered channel + non-blocking send to prevent slow renders from blocking the ic event poller.

### 10.4 Heuristic State Extraction from Terminal Lines

```go
func IsPromptLine(text) bool  // ❯ or ›
func IsAgentStatusLine(text) bool  // ⎿ (Claude Code status bar)
func IsSeparatorLine(text) bool    // 80%+ repeated char
func ExtractLatestResponse(lines) string  // scan backwards from last prompt
```

For Pollard (research intelligence): use similar heuristics to extract structured findings from raw Claude Code or Codex output in dispatch event streams.

### 10.5 Inactivity-Based LLM Trigger

```go
const nudgeInactivityThreshold = 15 * time.Second
// After 15s without terminal activity, ask LLM to classify state
```

For Autarch: after N seconds without new ic events, show a "phase may be stalled" indicator and optionally run a classification.

---

## Summary

schmux is a mature (v1.1.1), Go-based multi-agent orchestration system that manages multiple AI coding agents running in tmux sessions. Its core value is human-centric observability over autonomous coordination.

**Most directly useful for Autarch:**
1. The dual-signal status system (direct file signals + LLM fallback classification)
2. The bootstrap-then-stream event viewport pattern
3. The SessionTracker goroutine + buffered channel model (adapt to tea.Cmd)
4. The workspace-as-container, sessions-as-tabs navigation model (for Bigend's run/dispatch view)
5. The status display conventions (relative timestamps, nudge state badges, last-viewed tracking)
6. The NudgeNik prompt design (LLM structured JSON classifier from raw text)
7. The "human as coordinator" philosophy — TUI as observability surface, not autonomous orchestrator
