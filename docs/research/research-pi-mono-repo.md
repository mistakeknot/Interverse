# Research: badlogic/pi-mono

**Date:** 2026-02-18
**Source:** https://github.com/badlogic/pi-mono
**Author:** Mario Zechner (badlogic)
**Stars:** 13.6k | **Forks:** 1.4k | **License:** MIT
**Language:** 96.5% TypeScript | **Latest:** v0.53.0 (Feb 17, 2026)
**Description:** "AI agent toolkit: coding agent CLI, unified LLM API, TUI & web UI libraries, Slack bot, vLLM pods"

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
