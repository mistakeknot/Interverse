# Research: badlogic/pi-mono

**Date:** 2026-02-19 (updated — deep source analysis)
**Original:** 2026-02-18
**Source:** https://github.com/badlogic/pi-mono
**Author:** Mario Zechner (badlogic)
**Stars:** ~14,001 | **Forks:** ~1,427 | **License:** MIT
**Language:** TypeScript (primary) | **Updated:** 2026-02-20
**Description:** "AI agent toolkit: coding agent CLI, unified LLM API, TUI & web UI libraries, Slack bot, vLLM pods"

---

## UPDATED ANALYSIS (2026-02-19): Deep Source Code Investigation

This section expands on the original research below with direct source-file analysis of the TUI framework, agent loop, session manager, extension system, and monorepo structure. It focuses on specific patterns applicable to Autarch (Bubble Tea Go TUI + Intercore kernel).

---

### A. Technology Stack (Confirmed from Source)

| Layer | Technology |
|-------|-----------|
| Language | TypeScript (ESM modules throughout) |
| Runtime | Node.js >= 20 |
| Monorepo tooling | npm workspaces — no Nx, Turborepo, or Lerna |
| Linting/formatting | Biome (`biome.json` at root) |
| Type checking | `tsgo` (TypeScript native preview binary) for root; `tsc` for web-ui |
| Testing | Vitest |
| Build | `tsc` per package; ordered in root `scripts.build` |
| Terminal I/O | Raw mode stdin/stdout; Kitty keyboard protocol; CSI 2026 synchronized output |
| Key binding detection | Custom `matchesKey()` + `Key` helper over raw escape sequences |
| Markdown rendering | `marked` library, rendered to ANSI terminal strings |
| Image display | Kitty graphics protocol + iTerm2 inline images, `koffi` for native calls |
| Git hooks | Husky at repo root |
| Versioning | Custom `scripts/release.mjs` — lockstep versioning, all packages move together |

---

### B. Monorepo Structure and Tooling Patterns

```
pi-mono/
  packages/
    ai/           → @mariozechner/pi-ai          — Unified LLM API
    agent/        → @mariozechner/pi-agent-core   — Agent runtime
    coding-agent/ → @mariozechner/pi-coding-agent — Interactive CLI
    tui/          → @mariozechner/pi-tui           — Terminal UI library
    web-ui/       → @mariozechner/pi-web-ui        — Web chat components
    mom/          → @mariozechner/pi-mom           — Slack bot
    pods/         → @mariozechner/pi-pods          — vLLM GPU pod CLI
```

**Dependency order (enforced manually in root build script):**
`tui` and `ai` (no internal deps) → `agent` → `coding-agent` → `mom`, `web-ui`, `pods`

**Lockstep versioning:** `scripts/sync-versions.js` bumps all packages to same version, then `rm -rf node_modules packages/*/node_modules package-lock.json && npm install` regenerates from scratch. Every release touches every package.

**`biome.json` at root** — one formatter/linter config for all packages.
**`tsconfig.base.json` at root** — shared TypeScript config extended per package.
**`pi-mono.code-workspace`** — VS Code multi-root workspace config.
**Husky at root** — one git hook config for all packages.

---

### C. TUI Architecture: The pi-tui Library

The TUI library is a purpose-built custom engine — NOT Bubble Tea or any third-party TUI framework.

#### C.1 Component Interface

```typescript
interface Component {
  render(width: number): string[];    // Returns array of lines; each MUST be <= width
  handleInput?(data: string): void;   // Raw terminal input (ANSI escape sequences)
  wantsKeyRelease?: boolean;          // Receive Kitty key release events (rare)
  invalidate(): void;                 // Clear render cache
}
```

Critical constraint: `render()` returns `string[]` with ANSI codes. Lines exceeding `width` cause a hard crash with debug log written to `~/.pi/agent/pi-crash.log`. The TUI owns the display loop; components never write to terminal directly.

**`Container`** — Composite component. Renders children in sequence, concatenates lines.

**`Focusable` interface** — For components needing hardware cursor (IME support):
```typescript
interface Focusable {
  focused: boolean;  // Set by TUI when focus changes
}
// Component emits CURSOR_MARKER (APC escape sequence) at cursor position
// TUI finds marker, strips it, positions real hardware cursor there
export const CURSOR_MARKER = "\x1b_pi:c\x07";
```

#### C.2 Differential Rendering (Three Strategies)

1. **First render** — output all lines without clearing (assumes clean screen)
2. **Width change or change above viewport** — full clear + re-render
3. **Normal update** — compute `firstChanged`/`lastChanged`, move cursor to `firstChanged`, rewrite only changed lines

All writes wrapped in CSI 2026 synchronized output (`\x1b[?2026h` ... `\x1b[?2026l`) for atomic screen updates (no flicker).

**Line-level diff algorithm:**
```typescript
for (let i = 0; i < maxLines; i++) {
  const oldLine = i < previousLines.length ? previousLines[i] : "";
  const newLine = i < newLines.length ? newLines[i] : "";
  if (oldLine !== newLine) {
    if (firstChanged === -1) firstChanged = i;
    lastChanged = i;
  }
}
// Only render from firstChanged to lastChanged
```

Renders only the dirty range, not the full output. Spinner updates (single line change) cost one line rewrite.

**Performance caching pattern** (from `Box` component):
```typescript
private matchCache(width: number, childLines: string[], bgSample: string | undefined): boolean {
  return !!cache &&
    cache.width === width &&
    cache.bgSample === bgSample &&
    cache.childLines.every((line, i) => line === childLines[i]);
}
```
Cache keyed on `(width, childLines[], bgFn sample output)`. Invalidated by `invalidate()` or tree mutation.

#### C.3 Overlay System

Overlays render on top of existing content. Used for model selectors, settings panels, session pickers, extension dialogs.

```typescript
const handle = tui.showOverlay(component, {
  width: "80%",           // Absolute or percentage string
  anchor: "center",       // 9 anchor positions
  offsetX: 0, offsetY: 0,// Offset from anchor
  margin: 2,              // Clamp to terminal edges
  visible: (w, h) => w >= 100,  // Responsive hiding
});
handle.hide();            // Remove permanently
handle.setHidden(true/false);   // Toggle temporarily
tui.hasOverlay();         // Check if any overlay active
```

#### C.4 Built-in Components

| Component | Key Details |
|-----------|-------------|
| `Container` | Groups children, concatenates lines |
| `Box` | Container + padding + background color function |
| `Text` | Multi-line, word wrap, padding, optional background |
| `TruncatedText` | Single-line, truncates to width (status bars) |
| `Input` | Single-line with horizontal scroll |
| `Editor` | Multi-line editor: autocomplete, paste handling, vertical scroll, Kitty protocol |
| `Markdown` | Renders markdown to ANSI via `marked` with caching; supports syntax highlighting |
| `Loader` | Animated spinner — requests TUI re-render on each tick |
| `CancellableLoader` | Loader + `AbortSignal` + Escape key handling |
| `SelectList` | Arrow-key navigable with filter, scroll, descriptions |
| `SettingsList` | Settings with value cycling and submenu support |
| `Spacer` | N empty lines |
| `Image` | Inline images via Kitty/iTerm2 with text fallback |

#### C.5 Input Handling

- Raw stdin mode via `ProcessTerminal`
- `StdinBuffer` — splits batched escape sequences into individual events (critical for paste, rapid keypresses over SSH)
- **Kitty keyboard protocol** — auto-detected via capability query. When active: disambiguated escape codes, key release events, modifier combos that were previously impossible in xterm encoding
- **Bracketed paste mode** — `StdinBuffer` emits `paste` events for large pastes; wraps with markers for existing editor handling

#### C.6 Layout: InteractiveMode Structure

```
┌─────────────────────────────────────────────────┐
│ headerContainer  (logo + hints, or custom)       │
├─────────────────────────────────────────────────┤
│ chatContainer                                    │
│   UserMessageComponent                           │
│   AssistantMessageComponent (streaming partial)  │
│   ToolExecutionComponent (per tool call)         │
│   BashExecutionComponent (! commands)            │
│   CompactionSummaryMessageComponent              │
│   BranchSummaryMessageComponent                  │
│   SkillInvocationMessageComponent                │
│   CustomMessageComponent (from extensions)       │
├─────────────────────────────────────────────────┤
│ statusContainer (loaders, status texts)          │
├─────────────────────────────────────────────────┤
│ pendingMessagesContainer                         │
├─────────────────────────────────────────────────┤
│ widgetContainerAbove (extension widgets)         │
├─────────────────────────────────────────────────┤
│ editorContainer (CustomEditor or extension-set)  │
├─────────────────────────────────────────────────┤
│ widgetContainerBelow (extension widgets)         │
├─────────────────────────────────────────────────┤
│ footer (cwd + branch + tokens + cost + context%) │
│   extension statuses (one additional line)       │
└─────────────────────────────────────────────────┘
```

Extensions can replace `headerContainer`, `editorContainer`, `footer`, add to widget containers, or show overlays.

---

### D. Agent Architecture (Deep)

#### D.1 Agent Loop (Confirmed from `agent-loop.ts`)

```typescript
// Outer loop: continues when follow-up messages arrive after agent stops
while (true) {
  let hasMoreToolCalls = true;
  let steeringAfterTools: AgentMessage[] | null = null;

  // Inner loop: tool calls and steering messages
  while (hasMoreToolCalls || pendingMessages.length > 0) {
    // 1. Process pending steering messages (inject before next LLM call)
    // 2. Stream assistant response from LLM
    // 3. Execute all tool calls; collect steering interrupts between each
    // 4. Emit turn_start/turn_end events
  }

  // Agent would stop here. Check follow-up queue.
  const followUp = await config.getFollowUpMessages?.() || [];
  if (followUp.length > 0) { pendingMessages = followUp; continue; }
  break;
}
```

**Dual interrupt channels:**
- **Steering** (`getSteeringMessages`): injected mid-run after current tool finishes. Skips remaining tools. Called after each tool execution.
- **Follow-up** (`getFollowUpMessages`): queued and delivered only after agent fully stops. Called at outer loop exit point.

Both have `"one-at-a-time"` or `"all"` delivery modes.

#### D.2 Agent State

```typescript
interface AgentState {
  systemPrompt: string;
  model: Model<any>;
  thinkingLevel: "off" | "minimal" | "low" | "medium" | "high" | "xhigh";
  tools: AgentTool<any>[];
  messages: AgentMessage[];
  isStreaming: boolean;
  streamMessage: AgentMessage | null;
  pendingToolCalls: Set<string>;    // toolCallIds executing now
  error?: string;
}
```

Event system uses a plain `Set<listener>` — no EventEmitter:
```typescript
type AgentEvent =
  | { type: "agent_start" } | { type: "agent_end"; messages: AgentMessage[] }
  | { type: "turn_start" } | { type: "turn_end"; message: AgentMessage; toolResults: ToolResultMessage[] }
  | { type: "message_start"; message: AgentMessage } | { type: "message_update"; ... } | { type: "message_end"; ... }
  | { type: "tool_execution_start"; toolCallId: string; toolName: string; args: any }
  | { type: "tool_execution_update"; toolCallId: string; toolName: string; args: any; partialResult: any }
  | { type: "tool_execution_end"; toolCallId: string; toolName: string; result: any; isError: boolean };
```

**Auto-retry and auto-compaction** are added at `AgentSession` layer, not in `agent-core`. Extended events:
```
auto_compaction_start / auto_compaction_end
auto_retry_start / auto_retry_end
```

#### D.3 Custom Message Types (TypeScript Declaration Merging)

```typescript
// packages/agent/src/types.ts — empty interface, apps extend via declaration merging
export interface CustomAgentMessages {}
export type AgentMessage = Message | CustomAgentMessages[keyof CustomAgentMessages];

// In application code:
declare module "@mariozechner/pi-agent-core" {
  interface CustomAgentMessages {
    artifact: ArtifactMessage;
    notification: NotificationMessage;
  }
}
```

Compile-time safe, no runtime registration. Custom messages flow through the pipeline; `convertToLlm` filters/converts them.

#### D.4 Context Transform Pipeline

Before each LLM call, two transforms run in sequence:

```
AgentMessage[]
  → transformContext(messages, signal)  — prune, inject external context (AgentMessage level)
  → convertToLlm(messages)             — filter UI-only, translate custom types (LLM API level)
  → Message[]
  → LLM
```

Separation of concerns: `transformContext` works at app-message level. `convertToLlm` works at LLM-compatibility level. Both async and pluggable.

---

### E. Session Persistence (JSONL Tree)

**Location:** `~/.pi/agent/sessions/<encoded-cwd>/<timestamp>_<uuid>.jsonl`

**Entry types:**
```
session         (header — one per file, no id)
message         { id, parentId, message: AgentMessage }
compaction      { id, parentId, summary, firstKeptEntryId, tokensBefore, details?, fromHook? }
branch_summary  { id, parentId, fromId, summary, details?, fromHook? }
custom          { id, parentId, customType, data? }    — extension state, NOT in LLM context
custom_message  { id, parentId, customType, content, details?, display }  — DOES go to LLM
label           { id, parentId, targetId, label }
session_info    { id, parentId, name? }
model_change, thinking_level_change
```

**Key design decisions:**
- Append-only: never mutates existing entries
- Tree, not linear: `id/parentId` enables branching without copying files
- Compaction as entry: `firstKeptEntryId` points to where history starts; full history always preserved
- Extension state (`custom`) vs. LLM context (`custom_message`) are distinct entry types
- `CURRENT_SESSION_VERSION = 3`; auto-migrated on load

**Compaction details** stored in `CompactionEntry.details`:
```typescript
interface CompactionDetails {
  readFiles: string[];
  modifiedFiles: string[];
}
```
File lists accumulate across multiple compactions — each compaction reads the previous compaction's file lists and appends new operations.

---

### F. Extension System (Confirmed Types)

Extensions are TypeScript modules loaded at runtime. The `ExtensionRunner` manages lifecycle.

**Extension hooks (selected):**
```
session_start / session_switch / session_fork / session_shutdown
agent_start / agent_end / before_agent_start (can veto/modify prompt)
turn_start / turn_end
message_start / message_update / message_end
tool_execution_start / tool_execution_update / tool_execution_end
context (runs before each LLM call — receives deep copy for non-destructive modification)
input (intercept user input)
resources_discover (add skills, prompts, themes dynamically)
session_before_compact / session_compact (custom compaction logic)
session_before_fork / session_before_switch / session_before_tree
get_active_tools / get_all_tools / get_commands / get_thinking_level
append_entry / send_message / send_user_message / model_select
```

**`ExtensionUIContext` interface** — implemented differently per mode:
```typescript
interface ExtensionUIContext {
  select(title, options, opts?): Promise<string | undefined>;
  confirm(title, message, opts?): Promise<boolean>;
  input(title, placeholder?, opts?): Promise<string | undefined>;
  notify(message, type?): void;
  // Interactive mode only:
  addInputListener(handler: TerminalInputHandler): () => void;
  showOverlay(component, options?): OverlayHandle;
  addWidget(id, component, opts?): void;
  removeWidget(id): void;
  setEditor(component): void;
  setFooter(component): void;
  setHeader(component): void;
}
```

`ExtensionUIDialogOptions` supports `signal?: AbortSignal` and `timeout?: number` (live countdown display).

**EventBus for cross-extension communication:**
```typescript
const bus = createEventBus();
bus.emit("channel", data);
const unsub = bus.on("channel", handler);
```

---

### G. Footer Implementation (Concrete Pattern)

`FooterComponent` is a pure render-only component. It reads from `AgentSession` and `ReadonlyFooterDataProvider` at render time:

```typescript
render(width: number): string[] {
  // Compute cumulative usage by iterating ALL session entries
  for (const entry of this.session.sessionManager.getEntries()) {
    if (entry.type === "message" && entry.message.role === "assistant") {
      totalInput += entry.message.usage.input;
      // ...
    }
  }
  // Context %
  const contextUsage = this.session.getContextUsage();
  // > 90% → error color, > 70% → warning color
  // Build two-line output: [path + branch, stats + model]
  // Extension statuses below (sorted by key)
}
```

Stats aggregated at render time from source of truth — not cached counters.

---

### H. ToolExecutionComponent Pattern

Shows tool execution with streaming partial state:

1. Created when `tool_execution_start` fires — args preview shown immediately
2. `updateArgs(args)` called as streaming args arrive
3. `setArgsComplete()` triggers eager diff computation (for `edit` tool)
4. Result updated via `updateResult()` as partial content streams in
5. Final result rendered with expand/collapse (`Ctrl+O` globally)

Edit diffs computed from args alone before tool executes — user sees the planned change before it runs.

---

### I. Run Modes

| Mode | I/O | Use Case |
|------|-----|---------|
| Interactive | stdin/stdout terminal | Full TUI with rendering, overlays |
| Print | stdin prompt, stdout JSON/text | Single-shot, no TUI |
| RPC | JSON-lines stdin commands, JSON-lines stdout events | Subprocess integration from any language |
| SDK | `createAgentSession()` programmatic API | Embedded in another app |

**RPC mode command types** (typed discriminated union):
```typescript
type RpcCommand =
  | { type: "prompt"; message: string; streamingBehavior?: "steer" | "followUp" }
  | { type: "steer"; message: string }
  | { type: "follow_up"; message: string }
  | { type: "abort" }
  | { type: "set_model"; provider: string; modelId: string }
  | { type: "compact"; customInstructions?: string }
  | { type: "switch_session"; sessionPath: string }
  | { type: "fork"; entryId: string }
  | { type: "get_session_stats" }
  // ... etc.
```

---

### J. Autarch-Specific Takeaways (Updated Deep Analysis)

#### J.1 Differential Rendering with Synchronized Output

Pi-tui computes `firstChanged`/`lastChanged` line indices and rewrites only the dirty range, wrapped in CSI 2026 synchronized output. Spinner updates cost one line rewrite instead of a full screen repaint.

**Autarch/Bubble Tea:** Bubble Tea handles synchronized output via its renderer. For Bigend (multi-project mission control with 8+ project cards), explicitly splitting view output into independently-refreshable regions — each with its own render function and cache key — avoids full-screen re-renders when only one project card changes.

#### J.2 Steering vs. Follow-Up Queue at Protocol Level

Pi separates "redirect now" (steering, after current tool) from "queue for later" (follow-up, after agent stops) at the protocol level. This is cleaner than polling a shared queue.

**Autarch/Coldwine:** Add `steer_run(run_id, message)` and `queue_followup(run_id, message)` as distinct event types in Intercore's SQLite event log. Separate columns or entry types, not a single "pending messages" queue.

#### J.3 Compaction as a Named Persistent Event

Pi's `CompactionEntry` stores `firstKeptEntryId` in the session. Full history always preserved. Compaction = overlay on history, not destructive rewrite.

**Autarch/Intercore:** Add a `compaction_marker` event type to the events table. Fields: `first_kept_event_id`, `summary` (LLM-generated), `tokens_before`, `details` (file lists). Context window replay starts from `first_kept_event_id`.

#### J.4 JSONL Tree with id/parentId for Run Branching

Append-only tree enables in-place branching without file copies.

**Autarch/Intercore:** Apply the tree model to the event log. An event's `parent_event_id` pointing to the branching event allows phase retries and alternative paths to coexist in the same event log. Bigend's session browser shows run trees naturally.

#### J.5 Mode-Agnostic `AgentSession` Core

`AgentSession` is shared across interactive, print, RPC, SDK. Each mode implements only I/O layer.

**Autarch:** Each app (Bigend, Gurgeh, Coldwine, Pollard) wraps an `InterCoreSession` holding the DB connection, run/phase/event state, extension hooks, retry logic. The Bubble Tea app provides only the view and message handling. `ic run execute` uses the same `InterCoreSession` headlessly.

#### J.6 Extension UIContext as Mode Adapter

Same extension code works across interactive (TUI overlays), RPC (JSON responses), and print (no-op) modes because each provides its own `ExtensionUIContext` implementation.

**Autarch:** Define `UIContext` interface in Intercore's Go runtime. Each Bubble Tea app implements it. Agent skills written once work headlessly (via `ic run execute`) or with full TUI (via Autarch apps).

#### J.7 RPC Mode for Headless Integration

JSON-lines stdin/stdout drives the agent from any language without spawning a terminal.

**Autarch:** `--rpc` flag on each Autarch app switches to JSON-line protocol. Allows `ic dispatch` to programmatically drive a running Autarch app without reimplementing interaction logic. This is the bridge between Intercore CLI and TUI worlds.

#### J.8 Footer as Live Aggregation from Event Log

Stats computed at render time by iterating all session entries — not cached counters. Correct-by-construction on retries and model switches.

**Autarch/Bigend:** Status bar computes cumulative stats via `SELECT SUM(tokens) FROM events WHERE run_id = ?` on each frame render. No separate counter state to synchronize.

#### J.9 Keybindings as Configurable Named Actions

Never `matchesKey(data, "ctrl+x")` inline. All bindings go through `KeybindingsManager` loaded from JSON. Default object + JSON override pattern.

**Autarch:** `Keybindings` struct in each Bubble Tea app; load from `~/.autarch/keybindings.json`. Key help overlay = iterate the struct.

#### J.10 ToolExecutionComponent — Eager Preview + Streaming Partial

Edit diffs computed from args before tool executes (preview). Result mutated in-place as streaming arrives. Expand/collapse globally with `Ctrl+O`.

**Autarch/Coldwine:** `PhaseCard` component shows:
- Phase name + args (always visible)
- Streaming event log during execution (last 5 lines, expand for full)
- Final status + summary when done
- Pre-execution output prediction computed eagerly from phase args

---

## ORIGINAL ANALYSIS (2026-02-18)



---

## 1. What Is It? What Problem Does It Solve?

pi-mono is a monorepo implementing a complete AI coding agent stack — from unified LLM API abstraction through agent runtime to end-user interfaces (CLI TUI, web UI, Slack bot). It solves the problem of building a production-grade, provider-agnostic coding agent with a rich extension system.

### Package Architecture

| Package | Purpose |
|---------|---------|
| `pi-ai` | Unified LLM API: OpenAI (completions + responses), Anthropic, Google (Gemini + Vertex), Azure, AWS Bedrock, GitHub Copilot. Provider-agnostic streaming, tool calling, token counting. |
| `pi-agent-core` | Agent runtime: tool execution loop, event streaming, steering/follow-up message queues, abort, retry, custom message types via declaration merging. |
| `pi-coding-agent` | Full coding agent CLI with TUI, session management, extensions, skills, compaction, RPC mode, SDK. The main user-facing product. |
| `pi-mom` | Slack bot that bridges Slack messages to the coding agent, with Docker sandbox isolation. |
| `pi-tui` | Terminal UI library with differential rendering, used by the coding agent. |
| `pi-web-ui` | Web components for AI chat interfaces (artifact rendering, model selection, etc.). |
| `pi-pods` | CLI for managing vLLM deployments on GPU pods (self-hosted inference). |

The layering is clean: `pi-ai` (LLM abstraction) -> `pi-agent-core` (runtime) -> `pi-coding-agent` (product). Each layer is independently usable.

---

## 2. Agent Orchestration

### 2.1 Core Agent Loop (Single-Agent, Not Multi-Agent)

pi-mono does NOT do multi-agent orchestration in the traditional sense. It implements a single-agent loop with sophisticated control flow. The core loop in `packages/agent/src/agent-loop.ts` is:

```
while (true) {
    while (hasMoreToolCalls || pendingMessages.length > 0) {
        // Process pending steering messages
        // Stream assistant response from LLM
        // Execute tool calls sequentially
        // Check for steering interrupts after each tool
        // Emit turn_start/turn_end events
    }
    // Check for follow-up messages
    if (followUpMessages.length > 0) { continue; }
    break;
}
```

**Key orchestration primitives:**

1. **Steering Messages** — Interrupt the agent mid-tool-execution. After the current tool finishes, remaining tools are skipped and the steering message is injected. Two modes: `one-at-a-time` (single message per interrupt) or `all` (drain queue).

2. **Follow-Up Messages** — Queue work for after the agent stops. Checked only when there are no more tool calls and no steering messages. Enables "do X, then do Y" patterns without blocking.

3. **Context Transform Pipeline** — Before each LLM call:
   ```
   AgentMessage[] -> transformContext() -> AgentMessage[] -> convertToLlm() -> Message[] -> LLM
   ```
   The `transformContext` hook handles pruning, injection of external context, compaction summaries. The `convertToLlm` hook filters out UI-only messages and converts custom types to LLM-compatible format.

4. **Custom Message Types** — Via TypeScript declaration merging, apps can extend `AgentMessage` with custom roles (e.g., `BashExecutionMessage`, `CustomMessage`, `BranchSummaryMessage`, `CompactionSummaryMessage`). These flow through the message pipeline and can be selectively included/excluded from LLM context.

### 2.2 Extension System (The Real Orchestration Layer)

The coding agent's extension system (`packages/coding-agent/docs/extensions.md`) is where orchestration-like behavior emerges. Extensions are TypeScript modules that:

- **Subscribe to lifecycle events** — `session_start`, `agent_start`, `turn_start`, `tool_call`, `tool_result`, `agent_end`, `session_shutdown`, etc. Full lifecycle coverage.
- **Block or modify tool calls** — `tool_call` handlers can return `{ block: true, reason: "..." }` to prevent tool execution (permission gates, path protection).
- **Modify tool results** — `tool_result` handlers chain like middleware, each seeing the latest result.
- **Inject context** — `before_agent_start` can inject messages and modify the system prompt per-turn. `context` event provides a deep copy of messages for non-destructive modification before each LLM call.
- **Register custom tools** — Extensions can add tools the LLM can call, with custom rendering.
- **Inter-extension communication** — `pi.events` shared event bus for cross-extension messaging.
- **Send messages programmatically** — `pi.sendMessage()` and `pi.sendUserMessage()` can inject messages with different delivery modes (steer, followUp, nextTurn).

This is effectively a plugin-based orchestration model where the "orchestrator" is the event dispatch system rather than a central coordinator.

### 2.3 Sub-Agent Pattern

There is a `subagent/` extension example that spawns sub-agents via process execution. This is process-level composition, not in-process multi-agent. The coding agent can also run in RPC mode (`--mode rpc`) with a JSON protocol over stdin/stdout, enabling subprocess integration from any language.

### 2.4 Slack Bot Multi-Channel (pi-mom)

`pi-mom` handles multiple Slack channels with a channel-based queue system:
- Each channel gets its own working directory, message log (`log.jsonl`), attachments, skills, and memory (`MEMORY.md`)
- A `ChannelQueue` serializes requests per channel (one agent run at a time)
- User mentions are rejected with "Already working" if agent is busy
- Events (immediate, one-shot, periodic cron) can queue up to 5 per channel

This is multi-tenancy at the channel level, not multi-agent orchestration.

---

## 3. Multi-Tenancy, Sandboxing, and Resource Scheduling

### 3.1 Docker Sandbox (pi-mom)

The mom package has a clean sandboxing model:

```
Host
  mom process (Node.js)
  - Slack connection
  - LLM API calls
  - Tool execution --> Docker Container
                       - bash, git, gh
                       - /workspace (mount)
```

- Mom process runs on host (handles Slack, LLM calls)
- All tool execution (bash, read, write, edit) runs inside a Docker container
- Only `/workspace` (data dir) is accessible
- Container persists across restarts (installed tools, configs survive)
- The `Executor` interface abstracts host vs. Docker execution:
  ```typescript
  interface Executor {
    exec(command, options?): Promise<ExecResult>;
    getWorkspacePath(hostPath): string;
  }
  ```

### 3.2 Remote Execution (Extensions)

The coding agent's tool system supports pluggable "operations" for remote execution:

```typescript
const remoteRead = createReadTool(cwd, {
  operations: {
    readFile: (path) => sshRead(remote, path),
    access: (path) => sshAccess(remote, path),
  }
});
```

Operations interfaces: `ReadOperations`, `WriteOperations`, `EditOperations`, `BashOperations`, `LsOperations`, `GrepOperations`, `FindOperations`. This enables SSH, container, or any custom execution backend.

The bash tool also has a `spawnHook` for adjusting command, cwd, and env before execution.

### 3.3 Resource Scheduling

There is no explicit resource scheduler. Concurrency control is:
- Single-threaded agent loop (one LLM call at a time)
- Tool calls execute sequentially within a turn
- Channel queue in pi-mom serializes per channel
- AbortController for cancellation
- Timeout support on tool execution

### 3.4 LLM Proxy

The `proxy.ts` in the agent package provides a server-side proxy pattern:
- Client sends model + context + options to `POST /api/stream`
- Server handles auth, routes to LLM providers
- Server strips `partial` field from delta events to reduce bandwidth
- Client reconstructs partial message from deltas

This enables centralized API key management and provider routing but is not a multi-tenant scheduler.

---

## 4. Architectural Patterns Relevant to an Orchestration Kernel

### 4.1 EventStream as Core Primitive

The entire agent runtime is built on `EventStream<AgentEvent, AgentMessage[]>` — a typed async iterable that:
- Pushes events (`agent_start`, `message_update`, `tool_execution_end`, etc.)
- Has a terminal event detector (`agent_end`)
- Returns a final result via `stream.result()`

This is the fundamental composition primitive. Everything observes or produces EventStreams.

### 4.2 Message-Type Extensibility via Declaration Merging

```typescript
// Apps extend the AgentMessage union:
declare module "pi-agent-core" {
  interface CustomAgentMessages {
    notification: { role: "notification"; text: string; timestamp: number };
  }
}
```

This lets the message pipeline carry arbitrary payloads while maintaining type safety. Custom messages flow through the pipeline and are filtered by `convertToLlm`.

### 4.3 Two-Phase Context Transform

```
AgentMessage[] -> transformContext(prune, inject) -> convertToLlm(filter, translate) -> Message[]
```

Separation of concerns: `transformContext` works at the app-message level (pruning old messages, injecting external context). `convertToLlm` works at the LLM-compatibility level (filtering UI-only messages, converting custom types). Both are async and pluggable.

### 4.4 Session as Append-Only Tree (JSONL)

Sessions are stored as JSONL files where entries form a tree via `id`/`parentId`:

```
SessionHeader (no id)
SessionMessageEntry { id, parentId, message: AgentMessage }
CompactionEntry { id, parentId, summary, firstKeptEntryId }
BranchSummaryEntry { id, parentId, fromId, summary }
CustomEntry { id, parentId, customType, data }  // Extension state, NOT in LLM context
LabelEntry { id, parentId, targetId, label }
ModelChangeEntry, ThinkingLevelChangeEntry, SessionInfoEntry
```

Key design decisions:
- **Append-only**: Never mutates existing entries. Branching creates new children from earlier entries.
- **Tree, not linear**: Enables `/tree` navigation, `/fork`, and branch summarization.
- **Compaction as entry type**: Compaction summaries are entries in the tree, not destructive rewrites.
- **Extension state separated from LLM context**: `CustomEntry` persists state but never goes to the LLM. `CustomMessageEntry` (with `role: "custom"`) DOES go to LLM context.
- **Version migration**: v1 (linear) -> v2 (tree) -> v3 (renamed hookMessage to custom). Auto-migrated on load.

### 4.5 Compaction (Context Window Management)

Two-tier summarization system:
1. **Auto-compaction**: Triggers when `contextTokens > contextWindow - reserveTokens`. Keeps recent tokens (default 20k), summarizes the rest. Handles "split turns" where a single turn exceeds the keep budget.
2. **Branch summarization**: When navigating `/tree` to a different branch, summarizes the abandoned branch and injects context into the new branch.

Both use structured summaries with:
- Goal, Constraints, Progress (done/in-progress/blocked), Key Decisions, Next Steps, Critical Context
- Cumulative file tracking (readFiles, modifiedFiles) across multiple compactions

### 4.6 Tool Execution Model

Tools are defined with:
- TypeBox schemas for parameter validation (validated before execute)
- Streaming progress via `onUpdate` callback
- AbortSignal for cancellation
- Pluggable operations for remote/sandboxed execution
- Output truncation (50KB / 2000 lines, utilities provided)
- Overridable built-in tools (register a tool with the same name to replace read, bash, etc.)

### 4.7 Extension Lifecycle Events

Comprehensive lifecycle coverage:

```
session_start -> input -> before_agent_start -> agent_start ->
  turn_start -> context -> tool_call -> tool_execution_* -> tool_result -> turn_end ->
agent_end -> session_shutdown

session_before_switch / session_switch
session_before_fork / session_fork
session_before_compact / session_compact
session_before_tree / session_tree
model_select
user_bash
```

Every event can cancel, modify, or inject behavior. This is essentially an aspect-oriented programming model for agent behavior.

### 4.8 SDK and Embedding

The `createAgentSession()` factory enables programmatic embedding:

```typescript
const { session } = await createAgentSession({
  model, tools, sessionManager, authStorage, modelRegistry,
  settingsManager, resourceLoader,
});
session.subscribe((event) => { ... });
await session.prompt("...");
```

Three run modes:
- **Interactive**: Full TUI
- **Print**: Single-shot, output result, exit
- **RPC**: JSON protocol over stdin/stdout for subprocess integration

### 4.9 Events System (pi-mom)

File-system-based event scheduling for the Slack bot:
- **Immediate**: Execute on file creation (webhooks, triggers)
- **One-shot**: Execute at specific datetime (reminders)
- **Periodic**: Cron schedule with timezone (recurring tasks)

Watched via fs.watch with debounce. Events are JSON files in `workspace/events/`. This is a simple but effective job scheduler pattern.

### 4.10 ResourceLoader Pattern

A clean abstraction for discovering and loading agent resources:

```typescript
interface ResourceLoader {
  getExtensions(): Extension[];
  getSkills(): Skill[];
  getPrompts(): PromptTemplate[];
  getThemes(): Theme[];
  getAgentsFiles(): AgentsFiles;
  getSystemPrompt(): string;
  reload(): Promise<void>;
}
```

`DefaultResourceLoader` discovers from conventional locations with override hooks:
- `systemPromptOverride`
- `skillsOverride`
- `promptsOverride`
- `agentsFilesOverride`
- `additionalExtensionPaths`
- `extensionFactories`

---

## 5. Novel Ideas

### 5.1 Steering vs. Follow-Up Message Queues

The two-queue model (steering interrupts vs. follow-up waits) is a clean abstraction for human-agent interaction during execution:
- **Steering**: "Stop what you're doing and do this instead" — delivered after current tool, skips remaining
- **Follow-Up**: "After you're done, also do this" — delivered only when agent stops

Both support `one-at-a-time` vs. `all` delivery modes. This is more nuanced than simple abort/queue patterns.

### 5.2 Session Tree with Branch Summarization

The append-only tree session format enables:
- Non-destructive branching (explore alternatives without losing work)
- Fork to create new session files from branches
- Branch summarization that preserves context when switching paths
- Labels for bookmarking entries in the tree

The branch summarization is particularly interesting — when you navigate to a different branch, the abandoned branch is summarized and injected as context. This means the agent can leverage work from abandoned paths.

### 5.3 Extension-Driven State Reconstruction

Extensions store state via `pi.appendEntry()` (persisted in session, NOT in LLM context). On `session_start`, extensions replay entries to reconstruct state. This survives restarts and respects branching — different branches can have different extension states.

### 5.4 Custom Message Types via Declaration Merging

Using TypeScript's declaration merging to extend the `AgentMessage` union is elegant — it is compile-time safe, requires no runtime registration, and the `convertToLlm` pipeline naturally filters/converts custom types.

### 5.5 Container as "Agent's Computer"

pi-mom's Docker sandbox treats the container as the agent's personal computer: it can install tools, configure credentials, create files. This persists across restarts. The agent manages its own environment rather than being given a fixed one. This is a different philosophy from providing a pre-configured sandbox.

### 5.6 Context Transform as Middleware

The `transformContext` + `convertToLlm` two-stage pipeline before each LLM call is a clean middleware pattern. Extensions hook into `context` events to modify messages non-destructively (they receive deep copies). Multiple extensions chain.

### 5.7 Skills as Progressive Disclosure

Skills provide descriptions in the system prompt but full instructions only on demand (via `read` tool or `/skill:name`). This keeps the context small while advertising capabilities. Follows the Agent Skills standard (agentskills.io).

---

## 6. What pi-mono Does NOT Do (Gaps Relevant to an Orchestration Kernel)

1. **No multi-agent orchestration** — Single agent loop, no agent-to-agent communication, no role-based routing, no consensus/synthesis across agents.

2. **No resource scheduling** — No token budget allocation across concurrent agents, no priority queues, no fairness policies.

3. **No centralized state** — Each session is a standalone JSONL file. No shared state database across agents/sessions.

4. **No policy engine** — Extension-based permission gates are ad-hoc. No declarative policy language for access control, rate limiting, or resource allocation.

5. **No agent identity/registry** — No concept of named agents with different capabilities, models, or tool sets running concurrently.

6. **No event bus across agents** — The `pi.events` bus is per-session. No cross-session or cross-agent event propagation.

7. **No workflow/DAG engine** — No declarative workflow definitions, no dependency resolution between tasks, no parallel task execution.

---

## 7. Relevance to Interverse Orchestration Kernel

### Patterns to Adopt

| Pattern | pi-mono Implementation | Interverse Application |
|---------|----------------------|----------------------|
| EventStream primitive | Typed async iterable with terminal detection | intercore event bus could use similar typed streams |
| Two-phase context transform | `transformContext` + `convertToLlm` | Context pipeline for multi-agent routing |
| Append-only session tree | JSONL with id/parentId branching | Session persistence for agent runs |
| Steering/follow-up queues | Two-queue message delivery | Human override patterns in multi-agent |
| Extension lifecycle events | Comprehensive hook points | Plugin system for intercore |
| Pluggable tool operations | ReadOperations, BashOperations, etc. | Sandboxed tool execution |
| ResourceLoader pattern | Discovery + override hooks | Plugin/skill loading for Clavain |

### Patterns to Build Beyond

| Gap in pi-mono | Interverse Already Has / Needs |
|---------------|-------------------------------|
| No multi-agent orchestration | interflux synthesis, intermute coordination |
| No shared state across agents | intercore SQLite database |
| No resource scheduling | intercore token budgets, priority queues |
| No agent registry | intermux agent visibility |
| No cross-agent events | intercore event bus (in progress) |
| No policy engine | intercore policy/gate system |
| No workflow DAG | Clavain dispatch patterns |

### Key Takeaway

pi-mono is a best-in-class single-agent runtime with an excellent extension model, but it is explicitly not a multi-agent orchestration system. Its value to Interverse is in the *primitives* — EventStream, context transform pipeline, session tree, tool execution model, extension lifecycle — rather than the orchestration architecture. Interverse needs to build the coordination, scheduling, and multi-agent layers on top of similar primitives.
