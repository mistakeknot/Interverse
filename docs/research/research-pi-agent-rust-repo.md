# Research: pi_agent_rust — Analysis for Autarch Inspiration

**Date:** 2026-02-19
**Source:** https://github.com/Dicklesworthstone/pi_agent_rust
**Author:** Jeffrey Emanuel
**Stars:** 182 | **Forks:** 16 | **Language:** Rust (2024 edition)
**Description:** High-performance AI coding agent CLI written in Rust with zero unsafe code

---

## 1. What It Is

`pi_agent_rust` is a Rust port of the [Pi Agent](https://github.com/badlogic/pi) TypeScript CLI by Mario Zechner. It is a single-binary, interactive terminal AI coding assistant that wraps LLM API calls (primarily Anthropic Claude), executes built-in tools, manages persistent session history, and supports a JavaScript/TypeScript extension system embedded via QuickJS (no Node/Bun required).

**Three execution modes:**
- **Interactive:** Full TUI with streaming, tools, session branching, autocomplete, keybindings
- **Print:** Single-shot stdout mode for scripting
- **RPC:** Headless line-delimited JSON protocol over stdin/stdout for IDE/toolchain integration

The project is a port-with-significant-additions: it keeps pi-mono's session format and UX but adds a capability-gated extension runtime, deterministic hostcall reactor mesh, security audit ledgers, advanced math-driven adaptive controls (CUSUM, BOCPD, conformal prediction), and aggressive performance engineering throughout.

---

## 2. Technology Stack

### Core Runtime
- **Rust 2024 edition**, `#![forbid(unsafe_code)]` enforced project-wide
- **`asupersync`** — purpose-built structured concurrency async runtime with built-in HTTP, TLS, and SQLite. Replaces Tokio/async-std as the runtime substrate. Provides explicit `Cx` capability-scoped context threading.
- **`rquickjs`** — embedded QuickJS JavaScript runtime for extensions (JS/TS without Node/Bun)
- **`jemalloc`** (optional, default on) — ~10-20% improvement on allocation-heavy paths

### TUI / Terminal
- **`charmed-bubbletea`** — Rust port of the Go Bubble Tea framework (Elm Architecture TUI)
- **`charmed-lipgloss`** — Rust port of Go's lipgloss (style/layout)
- **`charmed-bubbles`** — Rust port of Go's bubbles components (spinner, textarea, viewport, list)
- **`charmed-glamour`** — Rust port of Go's glamour (markdown rendering)
- **`rich_rust`** — Rust port of Python's Rich library for markup-based terminal output
- **`crossterm`** — low-level terminal control (raw mode, alternate screen, cursor)

### Data / Storage
- **`serde_json`** — JSONL session format (v3 tree with branching)
- **`sqlmodel-sqlite`** / **`asupersync` SQLite** — session index sidecar, optional SQLite session backend
- **`fs4`** — cross-platform file locking for multi-instance coordination
- **WAL** (SQLite write-ahead log) — crash-resilient session indexing

### Parsing / Analysis
- **`ast-grep-core`** + language grammars (bash, python, js, ts, ruby) — AST-level analysis for dangerous shell pattern detection in extensions
- **`swc_ecma_parser`** — TypeScript/JS parsing for extension preflight static analysis
- **`regex`** (OnceLock-cached) — hot-path pattern matching in extension bridge
- Custom SSE parser in `src/sse.rs` — handles real network chunking, UTF-8 tail buffering, CR/LF normalization

### Infrastructure
- **`clap`** with derive macros — CLI argument parsing
- **`thiserror`** / **`anyhow`** — error handling
- **`tracing`** + `tracing-subscriber` — structured logging
- **`sysinfo`** — process tree management (no orphaned processes after bash tool execution)
- **`sha2`** / hash chains — tamper-evident security ledgers
- **`wasmtime`** (optional) — WASM extension host
- **Criterion** — benchmark harness with CI performance gates

---

## 3. Architectural Patterns

### 3.1 Elm Architecture for TUI

The interactive TUI uses the Elm Architecture (Model-View-Update) via `charmed-bubbletea`:

```
PiApp (Model) → view() → terminal output
                ↑
           Cmd/Message update loop
                ↑
           Input events (keyboard, agent events)
```

`PiApp` is the central state struct holding:
- `agent_state: AgentState` (Idle / Processing / ToolRunning)
- `messages: Vec<ConversationMessage>` — finalized conversation
- `current_response: String` — in-flight streaming buffer
- `current_thinking: String` — in-flight thinking block buffer
- `conversation_viewport: Viewport` — scrollable display
- `input: TextArea` — multi-line input with history
- Overlay states: `AutocompleteState`, `SessionPickerOverlay`, `BranchPickerOverlay`, `ThemePickerOverlay`, `TreeUiState`

The `view()` method renders the entire frame into a `String` on every update — pre-allocated from the previous frame's capacity for zero-grow performance.

### 3.2 Agent Loop as an Async Event Emitter

The `Agent` struct in `src/agent.rs` runs a loop that emits typed lifecycle events to any registered handler:

```
AgentStart
  TurnStart (turn_index)
    MessageStart / MessageUpdate / MessageEnd  (streaming)
    ToolExecutionStart / ToolExecutionUpdate / ToolExecutionEnd
    AutoCompactionStart / AutoCompactionEnd
    AutoRetryStart / AutoRetryEnd
  TurnEnd (message + tool_results)
AgentEnd (messages, optional error)
```

The TUI, RPC, and print modes all subscribe to the same `AgentEvent` enum by passing an `on_event` callback. This decouples rendering from agent logic entirely.

**Tool iteration bound:** `max_tool_iterations: usize` (default 50) prevents unbounded self-tool loops.

**Abort mechanism:** `AbortHandle` / `AbortSignal` pair using `AtomicBool` + async `Notify`. Abort checks occur at turn boundaries and around tool execution.

### 3.3 Message Queue with Steering / Follow-Up Separation

The agent has two distinct message queues:
- **Steering queue:** Messages that interrupt the current response (processed at next turn boundary). Used for course corrections.
- **Follow-up queue:** Messages processed when the agent becomes idle. Used for sequential instructions.

Each queue supports `QueueMode::All` (batch all pending) or `QueueMode::OneAtATime`. This is exposed in RPC mode and the interactive TUI for IDE extensions.

### 3.4 Provider Trait Abstraction

All LLM providers implement a shared `Provider` trait returning streaming `StreamEvent` futures. Built-in providers: Anthropic, OpenAI, OpenAI Responses, Gemini, Cohere, Azure, Bedrock, Vertex, GitHub Copilot, GitLab. Extensions can register additional providers routed through the same agent loop.

Provider context is built as `Context { system_prompt, messages: Cow<[Message]>, tools: Cow<[ToolDef]> }` — zero-copy on the hot path when no image filtering is needed.

### 3.5 Tool Registry with Read-Only Parallelism

Tools implement the `Tool` trait with an `is_read_only() -> bool` method. The agent loop can execute multiple read-only tool calls concurrently (up to `MAX_CONCURRENT_TOOLS: usize = 8`) while serializing write tools. Tool definitions are cached in `cached_tool_defs` and invalidated only when the registry changes.

### 3.6 Capability-Gated Extension Runtime

Extensions (JS/TS via embedded QuickJS, or native Rust descriptors) run in a capability-gated environment:
- Six capability classes: `tool`, `exec`, `http`, `session`, `ui`, `events`
- Resolution order: per-extension deny → global deny → per-extension allow → default caps → mode fallback (fail-closed)
- Three policy profiles: `safe`, `balanced`, `permissive`
- Trust lifecycle: `pending → acknowledged → trusted → killed` with audit trail
- Shell mediation: AST-level analysis (tree-sitter grammars for bash, python, js, ts, ruby) classifies dangerous shell patterns before spawn

The `ExtensionDispatcher` is the core routing struct, managing:
- Fast-lane dispatch for common hostcall patterns
- Compatibility-lane fallback for unusual shapes
- Shadow dual-execution sampling (sampled comparison of fast and compat paths)
- AMAC batch executor for interleaved concurrent hostcall dispatch

### 3.7 Deterministic Hostcall Scheduler

The JS extension event loop in `src/scheduler.rs` is a deterministic single-threaded scheduler:
- **Macrotask queue:** `VecDeque<Macrotask>` with monotonic `Seq` counter
- **Timer heap:** `BinaryHeap<TimerEntry>` (min-heap by deadline then seq)
- **Invariants:** single macrotask per tick (I1), microtask fixpoint after any macrotask (I2), stable timer ordering by seq (I3), no reentrancy from hostcall completions (I4), total observable order by seq (I5)

This is the same event loop model as Node.js but implemented as deterministic Rust with testable replay.

### 3.8 Adaptive Regime Detection

The `ExtensionDispatcher` uses math-driven adaptive controls:
- **CUSUM** (Cumulative Sum control chart) — detects persistent drift in hostcall latency
- **BOCPD** (Bayesian Online Change Point Detection) — detects sudden regime shifts
- **Conformal Prediction Envelope** — adapts anomaly thresholds from recent nonconformity scores

These are used to switch dispatch lanes automatically when workload characteristics change (e.g., hostcall traffic spikes) without brittle fixed thresholds.

### 3.9 Session Persistence — JSONL Tree with SQLite Index

Sessions are JSONL files (v3 format) with a tree structure enabling branching. The index is maintained as a SQLite sidecar (`session-index.sqlite`) with WAL + file locking for multi-instance safety.

**Session Store V2** adds a segmented log + offset index for O(index+tail) resume on large histories (avoids full-file scans).

Write path: temp file → atomic rename — crash-resilient, avoids partial writes.

Autosave uses a write-behind queue with three durability modes (`strict`, `balanced`, `throughput`).

### 3.10 Context Compaction

When estimated context tokens exceed `context_window - reserve_tokens`:
1. Choose a cut-point at a user-turn boundary preserving `keep_recent_tokens`
2. Summarize discarded history using the LLM (cumulative summaries, not one-shot)
3. Persist a `compaction` session entry with `first_kept_entry_id`
4. Context rebuilds insert summary before the kept region

Token accounting prefers actual API-reported usage, falls back to character-based heuristic (3 chars/token, conservative).

### 3.11 RPC Protocol (Headless JSON)

RPC mode exposes a line-delimited JSON protocol:
- **stdin (client → agent):** `prompt`, `steer`, `follow-up`, `abort`, `get-state`, `compact`, `set-model`, `set-steering-mode`, etc.
- **stdout (agent → client):** `event` (streaming), `response` (per-request acknowledgement)
- Two dedicated threads for stdin reading and stdout writing, bridged via async channels
- Extension UI requests (capability prompts, selection dialogs) round-trip over the same protocol

### 3.12 Performance Discipline

CI-enforced performance governance:
- Binary size gate: `<22MB` for release binary
- Scenario matrix benchmarks with strict artifact contracts
- Fail-closed perf gates catch regressions before release
- Benchmark evidence bundles with provenance (`correlation_id`, `build_profile`) separate from shipping artifacts
- Shadow dual-execution sampling prevents fast-path optimizations from silently diverging semantically

---

## 4. Agent Lifecycle Management Patterns

### Turn-Scoped Lifecycle

```
AgentStart
  [loop until done or aborted]
    TurnStart(turn_index)
    [drain steering queue messages]
    stream_assistant_response()
      [stream events: MessageStart → MessageUpdate* → MessageEnd]
    if tool_calls:
      [execute tools, emit ToolExecutionStart/Update/End]
      [push ToolResultMessage back into messages]
      [re-enter loop for next turn]
    else:
      break
  TurnEnd(message, tool_results)
AgentEnd(all_new_messages, optional_error)
```

**Key insight for Autarch:** This is a clean audit trail. Every stage of agent execution emits a typed event that can be displayed, logged, or persisted. The turn index is a natural unit for multi-agent orchestration visibility — you can see "agent X is on turn 3, running tool Y."

### Abort at Turn Boundaries

Abort is checked before each turn starts and before each tool execution. This means the agent drains its current tool call before honoring an abort, which prevents half-written file operations. For Autarch, this is the right model for "graceful stop" vs "emergency kill."

### Message Queue Separation (Steering vs Follow-Up)

The distinction between steering (interrupt-style) and follow-up (sequential) queues is architecturally significant. In a multi-agent context:
- Steering = high-priority directive (orchestrator says "change direction")
- Follow-up = next task in the pipeline (orchestrator queues next step)

This maps naturally to an Autarch kernel that dispatches high-priority interrupts vs. normal task enqueue.

---

## 5. Multiple Concurrent Agents

`pi_agent_rust` is a single-agent system, but its architecture reveals how multi-agent composition would work:

1. **RPC protocol is the integration point.** Each agent instance runs `pi --mode rpc` and is controlled via stdin/stdout. An orchestrator spawns multiple `pi` processes and fans out work.

2. **Session isolation per process.** Each agent instance manages its own JSONL session file. No shared mutable state between agents.

3. **The hostcall reactor mesh models concurrent work within one agent.** The SPSC lane design (per-shard queues, S3-FIFO admission) and AMAC batch executor show how to handle many in-flight operations without head-of-line blocking. This is applicable to Autarch's kernel if it dispatches to multiple agents and receives concurrent responses.

4. **The steering/follow-up queue distinction could be the multi-agent communication model.** Agent A sends a steering message to Agent B's queue (interrupt), or enqueues a follow-up (sequential handoff).

---

## 6. Monitoring / Observability Approaches

### Runtime State Introspection

`get-state` RPC command returns a snapshot:
```json
{
  "model": "...",
  "thinkingLevel": "medium",
  "durabilityMode": "balanced",
  "isStreaming": true,
  "isCompacting": false,
  "steeringMode": "one-at-a-time",
  "followUpMode": "one-at-a-time",
  "sessionId": "...",
  "messageCount": 42,
  "pendingMessageCount": 3
}
```

**For Autarch:** This is exactly the "kernel state" panel model. Each agent should expose this snapshot as a struct that the TUI polls.

### Performance Footer

The TUI renders a persistent footer line with:
- Persistence mode + pending mutations + flush-fail count + backpressure indicator
- Token count + cost estimate (real-time)
- Git branch
- Keybinding hints

### Tool Progress Streaming

`ToolUpdate` events carry `details` (line count, byte count) that the TUI renders as a live progress indicator:
```
[Running bash... (12s, 3,421 lines)]
```

### Session Metrics

`AutosaveQueueMetrics` tracks pending_mutations, flush_failed, and max_pending_mutations. Backpressure is surfaced when pending >= max.

### Hostcall Telemetry

The `ExtensionDispatcher` tracks:
- Queue pressure per shard
- Fast-lane vs compat-lane routing decisions
- CUSUM/BOCPD regime state
- Shadow dual-execution divergence events
- AMAC batch executor stall events

These are structured observability signals, not just logs — they feed the adaptive control loops.

### `pi doctor`

Diagnostic subcommand outputting JSON/markdown with per-check pass/fail + `--fix` for safe auto-repair. CI can gate on non-zero exit codes. For Autarch, an equivalent "kernel health check" command that validates agent state is directly applicable.

---

## 7. Task Decomposition and Coordination

### Tool Iteration as Task Steps

The agent loop treats each round of tool calls as one "step" in a plan. The LLM decides the tool calls; the runtime executes them and re-enters the loop. The `max_tool_iterations` bound prevents runaway.

**For Autarch:** Each "phase" in Clavain's phase chain is analogous to a tool iteration. The agent loop with bounded iterations is the right model for phase-gated orchestration.

### Session Branching

Sessions support tree-structured branching: `/tree` shows the conversation tree, and users can navigate between branches. This enables exploration of alternative plans without losing history.

**For Autarch:** Kernel "runs" could have a branching history showing which direction the orchestrator took, with the ability to replay from any checkpoint.

### Compaction as "Context Budget Manager"

Compaction is threshold-triggered and boundary-aware. It produces cumulative summaries (not one-shot resets), preserving semantic continuity while freeing token budget.

**For Autarch:** Long-running agent sessions need the same mechanism. Each agent in the kernel should track its context utilization and trigger compaction automatically.

---

## 8. CLI / TUI Patterns Relevant to Autarch

### Elm Architecture is the Right Model

The `PiApp` struct + `view()` pure rendering + `Cmd`/`Message` event loop is a proven pattern for terminal applications with complex state. `charmed-bubbletea` brings this to Rust. Autarch already uses Bubble Tea in Go — the same pattern applies identically.

### Viewport + Streaming Buffer Split

Key insight: streaming text goes into `current_response: String` (cleared on turn end), finalized text goes into `messages: Vec<ConversationMessage>` (never mutated). The `view()` function renders both, with the streaming buffer appearing at the bottom. This prevents rendered content from jumping or flickering.

**For Autarch:** Each agent panel should have a "live streaming" buffer and a "history" list, rendered separately.

### Auto-Collapse for Tool Output

Tool output blocks over `TOOL_AUTO_COLLAPSE_THRESHOLD = 20` lines auto-collapse to `TOOL_COLLAPSE_PREVIEW_LINES = 5` lines. Users toggle with a key. For Autarch's agent output panels, this is essential — raw tool output can be enormous.

### Scroll Anchoring

The TUI tracks `follow_stream_tail: bool` — if true, the viewport automatically scrolls to follow new streaming content. If the user scrolls up, `follow_stream_tail` becomes false; scrolling to the bottom re-enables it.

**For Autarch:** Every agent panel that shows streaming output needs this scroll-anchor behavior.

### Performance-First View Rendering

- `view()` pre-allocates from previous frame's capacity (`render_buffers.view_capacity_hint()`)
- Line counting uses `memchr::memchr_iter` (O(n) byte scan, no Vec alloc)
- Conversation content string is returned for buffer reuse between frames
- `clamp_to_terminal_height()` prevents overflow into non-alternate-screen regions

These micro-optimizations matter when rendering multiple concurrent agent panels.

### `@file` References and Autocomplete

Typing `@path/fragment` in the input triggers file completion via a background-indexed walk (respecting `.gitignore`, capped at 5000 entries, refreshed every 30s). For Autarch, `@agent-name` completion to address a specific agent could use the same pattern.

### Modal Overlays as Separate State Machines

Each overlay (session picker, branch picker, theme picker, capability prompt, tree view) has its own state struct and is rendered by `view()` when active, completely replacing the main conversation area. The main application state holds `Option<OverlayState>`. This is clean and avoids complex conditional rendering.

### Keybinding Registry

`AppAction` enum + `KeyBindings` map allows all keybindings to be configured and displayed consistently in the header hint row. For Autarch, a keybinding registry lets power users customize agent-panel focus keys, etc.

---

## 9. Event-Driven Architecture Patterns

### Typed Event Enum

`AgentEvent` is a `#[serde(tag = "type", rename_all = "snake_case")]` enum. Every event is serializable to JSON, enabling:
- TUI handlers consume events via callback
- RPC mode serializes events to stdout
- Tests can assert event sequences

**For Autarch:** Define a `KernelEvent` enum with all observable state changes. Every consumer (TUI panels, persistence, audit log) subscribes to the same stream.

### Fan-Out via Callback

The `on_event: impl Fn(AgentEvent) + Send + Sync + 'static` pattern is simple but effective. For multiple consumers, wrap it in `Arc<dyn Fn(AgentEvent)>` and clone the arc for each consumer. The RPC + TUI can both receive events simultaneously this way.

### Channel-Based TUI/Agent Bridge

The TUI runs on the main thread (Bubble Tea event loop). The agent runs on async runtime threads. They communicate via `mpsc` channels: agent sends `PiMsg` to the TUI's message queue, TUI posts `Cmd`s back.

```
Agent async task ──mpsc─→ PiMsg ──→ TUI update loop
TUI update loop ──oneshot─→ AbortSignal ──→ Agent
```

**For Autarch:** This is the exact bridge pattern needed. Each agent gets its own channel pair. The kernel TUI polls all agent channels in a single `select!` or fan-in.

### Inbound Event Queue for Extensions

Extensions emit events (input hooks, lifecycle callbacks) via a typed `ExtensionEventName` enum dispatched through the `ExtensionManager`. This is an internal event bus within a single agent. For Autarch's inter-agent communication, a similar event bus at the kernel level would route messages between agents.

### Macrotask/Microtask Distinction

The `scheduler.rs` `Scheduler` struct implements the full JavaScript event loop model (macrotasks, microtasks, timer heap) in deterministic Rust. This is overkill for Autarch but the key pattern — **separating priority queues by class** — is valuable. High-priority kernel control messages should not be blocked by long-running agent operations.

---

## 10. Concrete Takeaways for Autarch

### Pattern 1: Kernel State Struct as the Single Source of Truth

Define an `AutarchKernelState` struct analogous to `PiApp`. Each agent has a typed `AgentPanelState` sub-struct. The kernel renders all panels from this one struct. State changes come via `KernelMsg` variants dispatched through Bubble Tea's `Update()` method.

### Pattern 2: Typed Event Enum for All Observable State

```go
type KernelEvent struct {
    Type      string // "agent_start", "agent_turn", "tool_start", etc.
    AgentID   string
    TurnIndex int
    // ...
}
```

All kernel consumers (TUI, audit log, persistence) receive the same event stream. Serialize to JSON for external observers (Interverse plugins, `intermux`).

### Pattern 3: Streaming Buffer / History Split per Agent Panel

Each agent panel maintains:
- `currentOutput: string` — cleared when agent turn ends
- `messages: []AgentMessage` — finalized history
- `agentState: AgentState` — Idle / Processing / ToolRunning
- `followTail: bool` — scroll-anchoring flag

The panel's `View()` renders both, with streaming buffer at bottom.

### Pattern 4: Tool/Task Progress with Auto-Collapse

Show tool name + elapsed seconds + line count inline during execution. Auto-collapse tool outputs beyond a threshold in the panel history. Toggle with a key. This keeps the TUI readable during heavy tool activity.

### Pattern 5: Steering vs Follow-Up Message Queues per Agent

Each agent maintained by the kernel has two input channels:
- **Steering:** High-priority directives from orchestrator (interrupt current task)
- **Follow-up:** Queued next tasks (sequential pipeline)

The kernel exposes this in the TUI as queue depth indicators per agent.

### Pattern 6: Bounded Tool Iterations as Phase Gates

Each agent run has a configurable `maxIterations` bound. When reached, the kernel emits a `PhaseLimitReached` event. The orchestrator decides: retry, advance to next phase, or escalate.

### Pattern 7: `get-state` Snapshot Protocol

Any agent in the kernel can respond to a `get-state` request with a JSON snapshot of its current state. The kernel TUI polls all agents periodically and renders the snapshots as panels. This is also how external tools (intermap, intermux) can observe kernel state.

### Pattern 8: Elm Architecture Modal Overlays

Each overlay (agent detail, session history, run log, settings) is a separate `Option[OverlayState]` in the kernel state. Active overlay replaces main view. This avoids complex nested conditional rendering and is idiomatic Bubble Tea.

### Pattern 9: Deterministic Scheduler for Kernel Operations

The kernel's operation scheduling (which agent gets its turn, which inter-agent message is dispatched next) should use a deterministic ordered queue with monotonic sequence numbers. This makes behavior reproducible and debuggable. Same pattern as `scheduler.rs`.

### Pattern 10: Fail-Closed Policy with Explicit Resolution Order

Security decisions (which agent can call which tool, which agent can read/write which paths) should follow a precedence-defined policy:
```
per-agent deny → global deny → per-agent allow → default → mode fallback
```
This is the `ExtensionDispatcher` capability policy pattern applied at the kernel level.

---

## 11. What pi_agent_rust Does Not Do (Gaps for Autarch)

1. **No multi-agent orchestration.** Each process is one agent. Autarch's kernel is the missing layer.
2. **No shared state between agents.** Autarch's kernel needs a shared state bus (Beads/SQLite) for cross-agent visibility.
3. **No agent-to-agent messaging.** The steering/follow-up queues operate within one agent. Autarch needs a routing layer.
4. **No work assignment / scheduling.** Pi responds to user prompts. Autarch needs a task planner that assigns work to agents.
5. **No agent lifecycle management at fleet level.** Pi starts and stops based on user invocation. Autarch needs "spawn agent for task X, reap when done, restart on failure."
6. **No cross-agent context sharing.** Each agent has its own session. Autarch could share a "kernel context" (project state, shared files) across agents.
7. **TUI is single-agent focused.** The viewport shows one conversation. Autarch needs a multi-panel TUI with one pane per agent.

---

## 12. Summary of Key Architectural Inspirations

| Pattern | pi_agent_rust Source | Autarch Application |
|---------|---------------------|---------------------|
| Elm Architecture TUI | `PiApp` / `bubbletea` | KernelApp / Bubble Tea (already in use) |
| Typed lifecycle events | `AgentEvent` enum | `KernelEvent` enum |
| Streaming buffer / history split | `current_response` + `messages` | Per-agent panel state |
| Steering vs follow-up queues | `MessageQueue` | Kernel → agent message routing |
| Tool auto-collapse | `TOOL_AUTO_COLLAPSE_THRESHOLD` | Agent output panels |
| Scroll anchoring | `follow_stream_tail` | Per-panel tail-follow |
| Modal overlays | `Option<OverlayState>` variants | Kernel overlays (agent detail, run log) |
| Bounded iteration | `max_tool_iterations` | Phase gates |
| Provider trait abstraction | `Provider` trait | Agent adapter trait |
| RPC protocol | `pi --mode rpc` | Kernel ↔ agent IPC |
| `get-state` snapshot | RPC `get-state` | Agent health polling |
| Deterministic scheduler | `scheduler.rs` `Scheduler` | Kernel operation order |
| Fail-closed capability policy | `ExtensionDispatcher` | Kernel agent permissions |
| Compaction | `compaction.rs` | Long-session agent context management |
| Session index + WAL | SQLite sidecar | Kernel run history |
| CUSUM/BOCPD regime detection | `ExtensionDispatcher` | Kernel load balancing |

---

## References

- Repo: https://github.com/Dicklesworthstone/pi_agent_rust
- Original Pi Agent (TypeScript): https://github.com/badlogic/pi
- `asupersync` runtime: https://github.com/Dicklesworthstone/asupersync
- `rich_rust` terminal UI: https://github.com/Dicklesworthstone/rich_rust
- Key source files analyzed:
  - `src/agent.rs` — Agent struct, AgentEvent enum, main loop
  - `src/interactive.rs` — TUI entry point (imports PiApp)
  - `src/interactive/state.rs` — AgentState, ConversationMessage, overlay structs
  - `src/interactive/agent.rs` — TUI ↔ agent bridge (PiMsg handling)
  - `src/interactive/view.rs` — Elm view() render function
  - `src/rpc.rs` — Headless JSON protocol
  - `src/tools.rs` — Tool trait, ToolOutput, ToolUpdate
  - `src/session.rs` — JSONL session persistence
  - `src/compaction.rs` — Context budget management
  - `src/extension_dispatcher.rs` — Capability-gated hostcall routing
  - `src/scheduler.rs` — Deterministic event loop
  - `src/tui.rs` — PiConsole rich output rendering
  - `Cargo.toml` — Full dependency manifest
  - `PROPOSED_ARCHITECTURE.md` — Architecture overview
  - `AGENTS.md` — Developer guidelines
  - `README.md` — Full feature documentation
