# Research: pi-mono-rust and the Pi Ecosystem

**Date:** 2026-02-19
**Researcher:** Claude (claude-sonnet-4-6)
**Purpose:** Analyze the pi-mono-rust repo and related Pi ecosystem for architectural patterns that could inspire Autarch — a Go Bubble Tea TUI suite for multi-agent orchestration monitoring.

---

## 1. What Is pi-mono-rust?

### Primary Repository: `madhavajay/pi-mono-rust`

GitHub: https://github.com/madhavajay/pi-mono-rust

`pi-mono-rust` is a **Rust port of the Pi coding agent** from Mario Zechner's TypeScript monorepo (`badlogic/pi-mono`). It is not a fork — it is a **ground-up rewrite** in Rust, with `pi-mono` (the TypeScript original) included as a git submodule.

The repo produces a single `pi` binary that:
- Runs an interactive AI coding agent in the terminal
- Supports multiple LLM providers (Anthropic, OpenAI, Google Gemini CLI, OpenAI Codex)
- Has a custom-built TUI layer using `crossterm` (not ratatui or bubbletea)
- Implements an agent runtime with tool calling, steering/follow-up queues, session persistence
- Supports extensions (the Pi plugin system), OAuth authentication, and a JSONL session tree

### Related Repos in the Ecosystem

| Repo | Description |
|---|---|
| `badlogic/pi-mono` | The original TypeScript monorepo — AI toolkit: coding agent CLI, unified LLM API, TUI library, Slack bot, vLLM pod manager |
| `TrapedCircuit/pi-agent-rs` | Another Rust rewrite (lighter), focuses on core crates: pi-ai, pi-agent, pi-coding-agent |
| `Dicklesworthstone/pi_agent_rust` | Third Rust port, uses purpose-built libs: `asupersync` (async runtime) + `rich_rust` (Rich/Python-style TUI). Emphasizes performance benchmarks and security. |

---

## 2. Technology Stack

### `madhavajay/pi-mono-rust`

**Language:** Rust (edition 2021), single binary

**Key dependencies:**
- `crossterm 0.27` — terminal raw mode, alternate screen, cursor control, keyboard events
- `serde` + `serde_json` — all types serialized with `camelCase` for JSON compat with TypeScript version
- `reqwest 0.12` (blocking + rustls-tls) — synchronous HTTP for LLM provider calls
- `uuid` — session IDs
- `chrono` — timestamps
- `unicode-segmentation` + `unicode-width` — correct terminal column-width calculation
- `regex` — provider error detection
- `base64` — image encoding
- `notify` (macos_kqueue) — filesystem watching
- `glob` — skills/file matching

**Notable absence:** No `tokio`, no `ratatui`. All async is handled with blocking reqwest. The TUI is hand-rolled on top of crossterm.

### `badlogic/pi-mono` (TypeScript original)

**Language:** TypeScript, Node.js monorepo (npm workspaces)

**Packages:**
- `@mariozechner/pi-ai` — unified multi-provider LLM API
- `@mariozechner/pi-agent-core` — agent runtime with tool calling and state management
- `@mariozechner/pi-coding-agent` — interactive coding agent CLI
- `@mariozechner/pi-tui` — terminal UI library with **differential rendering**
- `@mariozechner/pi-web-ui` — web components for AI chat interfaces
- `@mariozechner/pi-mom` — Slack bot that delegates to the coding agent
- `@mariozechner/pi-pods` — CLI for managing vLLM deployments on GPU pods

### `TrapedCircuit/pi-agent-rs`

**Language:** Rust (edition 2024), Rust 1.93+ stable

**Crates:**
- `pi-ai` — unified LLM streaming API, SSE parsing, JSON Schema validation, model registry (20+ providers)
- `pi-agent` — agent loop, tool execution, steering/follow-up queues, `Arc<dyn Trait>` shared state
- `pi-coding-agent` — `pi` binary, clap CLI, built-in tools (read/write/edit/bash), session compaction

**Key dependencies:** `tokio` (full async), `reqwest`, `clap`, `thiserror` + `anyhow`, `tokio_util::sync::CancellationToken`

---

## 3. Architectural Patterns

### 3.1 Component-Based TUI with Differential Rendering

The Pi TUI (both TypeScript original and Rust port) uses a **component model** that is functionally similar to Bubble Tea but implemented from scratch:

**TypeScript (pi-tui) Component interface:**
```typescript
interface Component {
    render(width: number): string[];
    handleInput?(data: string): void;
    wantsKeyRelease?: boolean;
    invalidate(): void;
}
```

**Rust port Component trait:**
```rust
pub trait Component {
    fn render(&self, width: usize) -> Vec<String>;
    fn as_any_mut(&mut self) -> &mut dyn Any;
}
```

Each component renders to a `Vec<String>` — one string per line. The TUI framework diffs the rendered output against the previous frame and only repaints changed lines. This is the **differential rendering** technique.

**Container pattern:** A `Container` holds `Vec<Box<dyn Component>>` and delegates rendering. Layout is implicit (vertical stack of components, each fills full width).

**Components shipped:**
- `Editor` — multi-line input with cursor, undo stack, kill-ring (emacs-style)
- `Markdown` — streaming markdown renderer with theming
- `ExpandableText` — collapsible content (default collapsed at N lines, expand on key)
- `SelectList` — scrollable selection list with fuzzy filtering
- `TreeSelector` — file/directory tree picker
- `SessionSelector` — list of saved sessions
- `ModelSelector` — LLM model picker
- `SettingsSelector` — key-value settings editor
- `Spacer` — layout spacer
- `TruncatedText` — text capped at width
- `LoginDialog` — OAuth login UI
- `Image` — inline terminal image (iTerm2 + Kitty protocol)

**Modal overlays:** The TypeScript TUI has a formal overlay system with anchor positions (`center`, `top-left`, `bottom-center`, etc.) and percentage-based sizing (`"50%"`). Overlays are shown/hidden via handles.

### 3.2 Agent Event Model

The agent emits fine-grained lifecycle events that the TUI subscribes to:

```typescript
type AgentEvent =
  | { type: "agent_start" }
  | { type: "agent_end"; messages: AgentMessage[] }
  | { type: "turn_start" }
  | { type: "turn_end"; message: AgentMessage; toolResults: ToolResultMessage[] }
  | { type: "message_start"; message: AgentMessage }
  | { type: "message_update"; message: AgentMessage; assistantMessageEvent: AssistantMessageEvent }
  | { type: "message_end"; message: AgentMessage }
  | { type: "tool_execution_start"; toolCallId: string; toolName: string; args: any }
  | { type: "tool_execution_update"; toolCallId: string; toolName: string; args: any; partialResult: any }
  | { type: "tool_execution_end"; toolCallId: string; toolName: string; result: any; isError: boolean };
```

The streaming event chain for an assistant response:
```
AssistantMessageEvent.Start
→ TextStart | ThinkingStart | ToolCallStart
→ TextDelta | ThinkingDelta | ToolCallDelta   (streaming chunks)
→ TextEnd   | ThinkingEnd   | ToolCallEnd
→ AssistantMessageEvent.Done
```

This granular event stream powers real-time rendering: text appears as it streams, tool calls animate their argument accumulation, and tool results arrive after execution.

### 3.3 Agent Loop Pattern

The core agent execution pattern (`agent_loop`) is a **tight iteration cycle**:

```
while true:
  1. transformContext(messages)        → prune/inject context
  2. convertToLlm(messages)           → filter to LLM-compatible messages
  3. stream(model, context)           → emit streaming events, get AssistantMessage
  4. for each tool_call in message:
     a. getSteeringMessages()         → check for user interruption
     b. if steering: inject + break   → abort remaining tool calls
     c. execute(tool_call)            → run tool, get result
     d. onUpdate(partialResult)       → streaming tool updates
  5. if no tool_calls:
     a. getFollowUpMessages()         → check for queued follow-up work
     b. if follow-up: inject + continue
     c. else: break                   → agent done
```

The **steering queue** allows injecting user messages mid-run (interrupt the agent). The **follow-up queue** allows queuing messages that should wait until the current turn completes.

### 3.4 Session Persistence (JSONL Tree)

Sessions are stored as append-only JSONL files with a **tree structure** (branching conversation history):

```rust
pub struct SessionHeader {
    pub id: String,
    pub timestamp: String,
    pub cwd: String,
    pub version: Option<i64>,
    pub parent_session: Option<String>,  // branching
}

pub struct SessionMessageEntry {
    pub id: String,
    pub parent_id: Option<String>,       // tree nodes
    pub timestamp: String,
    pub message: AgentMessage,
}
```

Sessions support:
- **Branching** — `parent_session` creates a fork of a conversation
- **Compaction** — LLM-summarizes old messages when context window fills, creating a `CompactionEntry` with `tokens_before`, `summary`, and `first_kept_entry_id`
- **Export** — sessions can be exported to HTML

### 3.5 Extension/Hook System

The coding agent supports **extensions** (Pi's plugin system):

```rust
pub struct HookAPI;
impl HookAPI {
    pub fn on_session_before_compact<F>(&self, handler: F) { ... }
    pub fn on_session_compact<F>(&self, handler: F) { ... }
}
```

Hooks fire at key lifecycle events (before compaction, after compaction). Extensions can:
- Provide additional tools
- Inject custom flags (parsed by the extension's own flag schema)
- Intercept compaction to provide custom summaries
- Send UI requests back to the host (for rendering custom dialogs)

Extensions run in a subprocess (`extension_runner.rs`) with a JSON RPC protocol over stdin/stdout.

### 3.6 Multi-Mode Operation

The Pi agent supports three operation modes:

| Mode | Description |
|---|---|
| **Interactive** (default) | Full TUI: editor, streaming markdown, tool output, modal overlays |
| **Print** | Stream text to stdout in plain/JSON/markdown format |
| **RPC** | JSON-RPC protocol over stdin/stdout — powers IDE integrations and sub-agent use |

The RPC mode is critical for **multi-agent orchestration**: agents can call other agents as tools via the RPC protocol. This enables a master agent to spawn sub-agents and receive structured results.

### 3.7 Thinking Level Control

Models with extended reasoning (Claude, o-series) expose thinking budget control:

```rust
pub enum ThinkingLevel {
    Off, Minimal, Low, Medium, High, XHigh,
}
```

The `XHigh` level is restricted to specific OpenAI models (`gpt-5.1-codex-max`). This maps to a token budget setting passed to the provider.

### 3.8 Model Registry and Provider Abstraction

The `ModelRegistry` is a structured lookup table:
- Models grouped by provider
- Each model has: `id`, `api` (which API protocol to use), `max_tokens`, `provider`
- Cost calculation per model
- API key resolution from environment variables

Supported API protocols: `anthropic-messages`, `openai-responses`, `openai-codex-responses`, `google-gemini-cli`

The provider abstraction decouples the model from the wire protocol — you can point at a different provider with the same conversation format.

### 3.9 Autocomplete and Slash Commands

The editor has a rich autocomplete system:
- **Slash commands** (`/compact`, `/branch`, `/settings`, `/model`, etc.) — modal actions
- **@file** completion — fuzzy file tree picker
- **Combined provider** — layered autocomplete sources with priority

### 3.10 Terminal Image Rendering

Two image protocols supported:
- **iTerm2 protocol** — base64 encoded image inline
- **Kitty protocol** — chunked terminal graphics
- **Cell dimension detection** — queries terminal for pixel dimensions to size images correctly
- **Fallback** — ASCII art for terminals without image support

---

## 4. What Could Inspire Autarch

Autarch is described as a set of Go Bubble Tea TUI apps for multi-agent orchestration monitoring:
- Mission control
- PRD generation
- Task orchestration
- Research intelligence

The Pi ecosystem offers direct, battle-tested patterns for each of these.

### 4.1 The Component Model Maps Directly to Bubble Tea

Pi's `Component` trait (`render(width) → []string`) is nearly identical to Bubble Tea's `Model` interface (`View() string`). The key insight from Pi:

**Differential rendering saves CPU on real-time dashboards.** Pi diffs `[]string` line-by-line and only repaints changed lines. For Autarch's mission control dashboard (many agents streaming simultaneously), this is essential. Bubble Tea does not do this natively — you'd need to implement it or use a library like `lipgloss` + a frame buffer.

**Takeaway for Autarch:** Build a `DiffRenderer` wrapper around Bubble Tea that maintains a previous-frame line buffer and emits only changed rows. This prevents full-screen redraws on every tick when only one agent's status changed.

### 4.2 The AgentEvent Stream Is the Right Model for Mission Control

Pi's `AgentEvent` taxonomy is a complete model for what a mission control dashboard needs to display:

```
agent_start / agent_end          → agent lifecycle indicator (spinner, done icon)
turn_start / turn_end            → per-turn timing
message_update                   → streaming text (render incrementally)
tool_execution_start/update/end  → tool call timeline with live progress
```

**Takeaway for Autarch:** Define a canonical `AgentEvent` type in Go that all Autarch-managed agents emit over a channel or SSE stream. The mission control app subscribes to events from N agents and renders a panel per agent.

```go
type AgentEvent struct {
    AgentID   string
    Type      string  // "agent_start" | "turn_start" | "message_update" | "tool_execution_start" | ...
    Timestamp time.Time
    Payload   json.RawMessage
}
```

### 4.3 The Steering/Follow-up Queue Pattern Is Multi-Agent Coordination

Pi's **steering queue** (interrupt mid-run) and **follow-up queue** (queue after completion) are the primitives for multi-agent orchestration:

- An orchestrator agent can **steer** a sub-agent by injecting a message while it's executing tools
- A PRD generator can **follow-up** a research agent when its research turn completes

**Takeaway for Autarch:** Model each agent as a goroutine with two channels:
```go
type AgentChannels struct {
    SteeringCh  chan AgentMessage  // injected mid-run (interrupt)
    FollowUpCh  chan AgentMessage  // queued post-completion
    EventCh     <-chan AgentEvent  // outbound event stream for UI
}
```
The orchestration task manager routes messages through these channels.

### 4.4 RPC Mode Is How Autarch Talks to Agents

Pi's `rpc` mode (JSON-RPC over stdin/stdout) is exactly the interface Autarch needs to spawn and control agents as subprocesses:

```
autarch → stdin JSON RPC → pi agent subprocess
autarch ← stdout JSON events ← pi agent subprocess
```

**Takeaway for Autarch:** The task orchestrator spawns agent binaries (Pi, or Autarch-native agents) in RPC mode. The TUI subscribes to their event streams. This enables Autarch to be **agent-agnostic** — it can orchestrate any process that speaks the RPC protocol.

### 4.5 Session Branching Is a PRD Generation Pattern

Pi's session tree (JSONL with `parent_session` for branching) maps well to PRD generation workflows:

- **Main session** — initial requirements gathering
- **Branch 1** — explore architecture option A
- **Branch 2** — explore architecture option B
- **Merge** — synthesize branches into final PRD

**Takeaway for Autarch PRD app:** Use a branching session store where each alternative is a branch. The TUI shows a session tree with branch comparison. The user picks branches to merge or discard.

### 4.6 The ExpandableText Pattern for Tool Output

Pi's `ExpandableText` component (collapsed to N lines by default, expand on keypress) is the right UX for mission control:

- Tool calls produce large outputs (file contents, bash output, search results)
- By default show first 5 lines + "... (N more lines)"
- Press Enter or Space to expand inline

**Takeaway for Autarch:** Implement an `ExpandablePanel` Bubble Tea component for tool outputs. Each tool call card shows: tool name, execution time, status (running/done/error), and a collapsible output section.

### 4.7 The SelectList + Fuzzy Pattern for Task Dispatch

Pi's `SelectList` + fuzzy filtering (also used in `TreeSelector`) is the interaction pattern for:
- Selecting which agent to assign a task to
- Picking which session to branch from
- Choosing which model for a specific task

**Takeaway for Autarch task orchestrator:** The task dispatch UI is a `SelectList` with fuzzy search over: available agents, current agent states (idle/busy/error), capabilities, and cost estimate.

### 4.8 The Model Registry Pattern for Agent Registry

Pi's `ModelRegistry` (provider → model → api/cost/max_tokens) maps directly to an **agent registry** for Autarch:

```go
type AgentSpec struct {
    ID           string
    Label        string
    Capabilities []string   // "coding", "research", "prd", "planning"
    ModelID      string
    CostPerTurn  float64
    MaxContext   int
    Status       AgentStatus
}
```

The task orchestrator uses the registry to route tasks to capable agents and estimate costs.

### 4.9 Thinking Level for Research Intelligence

Pi's `ThinkingLevel` (Off → XHigh) maps to research intelligence depth modes:

- **Off** — quick factual lookup, no chain-of-thought
- **Low/Medium** — exploratory research with light reasoning
- **High/XHigh** — deep synthesis, hypothesis generation, contradiction detection

**Takeaway for Autarch research app:** Expose thinking level as a first-class control in the research UI. Show the reasoning trace in an expandable section. Track token cost by thinking level.

### 4.10 The Differential Render Loop Pattern

The Pi TUI main loop:
1. Read terminal size
2. Render all components to `[][]string` (lines per component)
3. Diff against previous frame
4. Write only changed lines with cursor positioning
5. Flush
6. Wait for input event → update state → goto 1

This loop runs in a tight synchronous cycle. Events from the agent (streaming tokens) trigger `update()` calls which mark components dirty → next render cycle picks them up.

**Takeaway for Autarch:** Bubble Tea's `Update() → Cmd` model already handles this, but for mission control with many concurrent agents, you need a **fan-in event multiplexer**:

```go
// Multiplex events from N agent processes into single Bubble Tea msg channel
func AgentEventMultiplexer(agents []*AgentProcess) tea.Cmd {
    return func() tea.Msg {
        // select over all agent event channels
        // return first event as tea.Msg with agent ID tagged
    }
}
```

---

## 5. Concrete Architecture Recommendations for Autarch

Based on the Pi ecosystem analysis:

### 5.1 Core Shared Library: `autarch-agent`

A Go package defining:
- `AgentEvent` — canonical event type
- `AgentProcess` — wraps a subprocess running in RPC mode
- `AgentRegistry` — available agents with capabilities and status
- `SteeringChannel` + `FollowUpChannel` — coordination primitives

### 5.2 App: Mission Control (`autarch-mc`)

**Layout (Bubble Tea):**
```
┌─────────────────────────────────────────────┐
│ AUTARCH MISSION CONTROL          [status bar]│
├──────────┬──────────────────────────────────┤
│ Agents   │  Agent Panel (focused agent)      │
│ [list]   │  ┌─ message stream (markdown)    │
│ > coding │  │  streaming text...             │
│   research│  ├─ tool: bash (running) [expand]│
│   prd    │  │  $ git log --oneline...        │
│           │  └─ tool: read (done) [expand]   │
├──────────┴──────────────────────────────────┤
│ Orchestrator Input                           │
│ > [editor]                                  │
└─────────────────────────────────────────────┘
```

Key patterns to borrow:
- `SelectList` for the agent list (left panel)
- `ExpandableText` for tool outputs (right panel)
- `Markdown` renderer for streaming agent text
- Differential rendering to handle N agents updating simultaneously
- `AgentEvent` fan-in multiplexer

### 5.3 App: Task Orchestrator (`autarch-tasks`)

**Core model:**
- Tasks as a DAG (directed acyclic graph) — dependencies between tasks
- Each task has: type (research/code/review/prd), assigned agent, status, steering messages
- Dispatch: fuzzy select agent → assign task → monitor via event stream
- Session branching: fork current conversation to explore alternatives

**Session tree view:** Renders the JSONL branch structure as a tree widget showing:
- Session ID, agent, creation time
- Branch relationships
- Compaction events (context window filled → summarized)

### 5.4 App: PRD Generator (`autarch-prd`)

**Workflow:**
1. **Requirements intake** — structured form (Bubble Tea form component) captures: goal, constraints, timeline, stakeholders
2. **Research phase** — dispatch research agent with requirements; monitor event stream
3. **Draft phase** — PRD agent generates sections; each section expandable/editable
4. **Review phase** — dispatch review agent on draft; comments shown inline
5. **Export** — HTML export (mirrors Pi's `export_html.rs`)

### 5.5 App: Research Intelligence (`autarch-research`)

**Thinking level control panel:**
```
Model: claude-opus-4   Thinking: [Low | Medium | High | XHigh]
Depth: [Surface | Exploratory | Deep | Comprehensive]
```

**Research session:**
- Query input → dispatches to research agent in High/XHigh thinking mode
- Streams thinking blocks (expandable, dim color)
- Streams answer (full bright color)
- Sources panel: lists cited references
- Follow-up queue: auto-dispatches follow-up questions when current turn completes

---

## 6. Key Technical Takeaways

| Pattern | Source | Autarch Application |
|---|---|---|
| `Component.render(width) → []string` | pi-tui | Base Bubble Tea model (already compatible) |
| Differential line rendering | pi-tui | DiffRenderer for mission control (N agents) |
| `AgentEvent` typed stream | pi-agent-core | Canonical event bus for all Autarch apps |
| Steering + follow-up queues | pi-agent | Multi-agent coordination channels in Go |
| RPC mode (JSON over stdin/stdout) | pi-coding-agent | How Autarch spawns and controls agent subprocesses |
| Session tree (JSONL, parent_id branching) | pi-coding-agent | PRD generator branching, session history |
| `ExpandableText` collapse/expand | pi-mono-rust TUI | Tool output cards in mission control |
| `SelectList` + fuzzy | pi-mono-rust TUI | Agent dispatch, model selection, session picker |
| `ModelRegistry` | pi-coding-agent | `AgentRegistry` — capability-based task routing |
| `ThinkingLevel` enum | pi-agent | Research intelligence depth control |
| Compaction (LLM summarize) | pi-coding-agent | Context window management for long sessions |
| Extension RPC host | pi-coding-agent | Autarch plugin/extension model |
| Modal overlays with anchor+size | pi-tui (TypeScript) | Settings, model picker, session picker dialogs |

---

## 7. What Pi Does Not Cover (Autarch Gaps)

Pi is fundamentally a **single-agent** tool. It does not address:
- **Multi-agent topologies** — no orchestrator/sub-agent routing built-in (RPC mode is the primitive, but no higher-level coordination)
- **Agent health monitoring** — no watchdog, no restart-on-failure
- **Cost attribution** — no per-task cost tracking across agents
- **Task DAG** — no dependency graph between tasks
- **Cross-agent context sharing** — no shared memory or knowledge base between agents
- **Audit trail** — no structured log of all agent decisions across a session

These are the areas where Autarch adds unique value on top of Pi's patterns.

---

## 8. References

- `madhavajay/pi-mono-rust` — https://github.com/madhavajay/pi-mono-rust
- `badlogic/pi-mono` — https://github.com/badlogic/pi-mono
- `TrapedCircuit/pi-agent-rs` — https://github.com/TrapedCircuit/pi-agent-rs
- `Dicklesworthstone/pi_agent_rust` — https://github.com/Dicklesworthstone/pi_agent_rust
- Pi website — https://shittycodingagent.ai
