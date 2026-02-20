# Research: OpenClaw Repository Analysis

**Date:** 2026-02-18
**Repo:** https://github.com/openclaw/openclaw
**License:** MIT
**Language:** TypeScript (ESM), with Swift (macOS/iOS), Kotlin (Android)
**Files:** ~5,990 files
**Author:** Peter Steinberger and community

---

## 1. What Is OpenClaw? What Problem Does It Solve?

OpenClaw is a **personal AI assistant** that you self-host on your own devices. It is not a coding agent or an orchestration framework in the traditional sense -- it is a **full-stack conversational AI gateway** that connects to the messaging channels you already use (WhatsApp, Telegram, Slack, Discord, Google Chat, Signal, iMessage, Microsoft Teams, WebChat, Matrix, Zalo) and lets you interact with LLMs through them.

### Core Problem

The core problem it solves: **bridging the gap between powerful LLM capabilities and the messy reality of real-world messaging surfaces.** Rather than requiring users to use a dedicated chat UI or CLI, OpenClaw lets you talk to Claude/GPT/etc. through WhatsApp, Telegram, or any other channel you already use daily.

### Key Value Propositions

- **Local-first, privacy-respecting**: Runs on your devices, no cloud relay
- **Multi-channel inbox**: Single brain accessible from 15+ messaging platforms
- **Multi-agent routing**: Multiple isolated AI personas in one gateway process
- **Tool execution**: Browser control, canvas, camera, cron, webhooks, exec
- **Voice interaction**: Wake word + talk mode on macOS/iOS/Android
- **Plugin architecture**: Extensible via TypeScript plugins loaded at runtime

### What It Is NOT

OpenClaw is **not** a coding agent framework (like Claude Code, Cursor, or Codex). It is not an agent orchestration platform (like LangGraph, CrewAI, or AutoGen). It is a **personal assistant runtime** -- closer to an AI-powered replacement for Siri/Google Assistant that happens to be deeply programmable.

---

## 2. Agent Orchestration

OpenClaw handles orchestration in a surprisingly sophisticated way, though the framing is "personal assistant routing" rather than "enterprise agent orchestration."

### Multi-Agent Routing Model

OpenClaw supports **multiple isolated agents** running in a single Gateway process. Each agent has:

- Its own **workspace** (files, AGENTS.md/SOUL.md, persona rules)
- Its own **state directory** (auth profiles, model registry, config)
- Its own **session store** (chat history, routing state)
- Its own **skills** (per-agent `skills/` folder)

Agents are connected to channels via **bindings** -- deterministic routing rules that map inbound messages to agents based on channel, account, peer, guild, team, or other metadata.

### Binding Resolution (Most-Specific Wins)

The routing precedence is:

1. `peer` match (exact DM/group/channel ID)
2. `parentPeer` match (thread inheritance)
3. `guildId + roles` (Discord role routing)
4. `guildId` (Discord guild)
5. `teamId` (Slack team)
6. `accountId` match for a channel
7. Channel-level match (`accountId: "*"`)
8. Fallback to default agent

This is a **deterministic, config-driven router** -- not an LLM-based router. Multiple bindings at the same tier resolve by config order (first wins). Multiple match fields use AND semantics.

### Sub-Agent Spawning

OpenClaw supports `sessions_spawn` -- a tool that creates an isolated sub-agent session:

- Sub-agents get their own `agent:<agentId>:subagent:<uuid>` session key
- They can run under a different agent ID if allowlisted
- Depth is limited (`maxSpawnDepth`, default 1)
- Active children are capped (`maxChildrenPerAgent`, default 5)
- Sub-agents cannot spawn their own sub-agents (no recursive spawning)
- After completion, an **announce step** posts results back to the requester
- Sub-agent sessions auto-archive after configurable timeout (default 60 min)

### Agent-to-Agent Messaging

The `sessions_send` tool enables inter-session communication with a **reply-back loop** (ping-pong pattern, max 5 turns). This is OpenClaw's answer to agent coordination without a centralized orchestrator.

### Session Visibility Controls

Visibility is scoped to prevent cross-agent information leakage:

- `self`: only current session
- `tree`: current session + spawned children
- `agent`: any session belonging to current agent ID
- `all`: cross-agent access (requires explicit `tools.agentToAgent` config)

**Relevance to Interverse:** The binding-based routing and sub-agent spawn pattern are directly relevant to an orchestration kernel. The deterministic routing (not LLM-based) is a pragmatic choice that avoids the overhead and unpredictability of routing via inference.

---

## 3. Multi-Tenancy, Sandboxing, and Resource Scheduling

### Docker-Based Sandboxing

OpenClaw has a mature sandboxing system using Docker containers:

**Modes:**
- `off`: no sandboxing (default)
- `non-main`: sandbox only non-main sessions (groups/channels run in containers)
- `all`: every session runs in a sandbox

**Scope (container sharing):**
- `session`: one container per session (maximum isolation)
- `agent`: one container per agent (moderate isolation)
- `shared`: one container for all sandboxed sessions (minimum isolation)

**Workspace Access:**
- `none`: sandbox sees its own filesystem only
- `ro`: agent workspace mounted read-only at `/agent`
- `rw`: agent workspace mounted read/write at `/workspace`

**Security features:**
- Default `docker.network` is `"none"` (no network egress)
- Dangerous bind sources are blocked (`docker.sock`, `/etc`, `/proc`, `/sys`, `/dev`)
- `setupCommand` runs once on container creation (one-time provisioning)
- Custom bind mounts for specific directories
- Per-agent sandbox and tool configuration overrides

### Tool Policy (Three-Layer Control)

OpenClaw separates three concerns cleanly:

1. **Sandbox** -- where tools run (Docker vs host)
2. **Tool Policy** -- which tools are available (allow/deny lists)
3. **Elevated** -- escape hatch for exec-on-host when sandboxed

Tool policies support **groups** for ergonomic config:
- `group:runtime` (exec, bash, process)
- `group:fs` (read, write, edit, apply_patch)
- `group:sessions` (session tools)
- `group:memory` (memory tools)

Deny always wins over allow. Tool policy is the hard stop.

### Multi-Tenancy

True multi-tenancy is supported through the multi-agent routing system:
- Multiple people can share one Gateway with isolated agents
- Per-agent workspace, auth profiles, session stores
- Per-agent sandbox and tool restrictions
- DM scoping (`per-peer`, `per-channel-peer`, `per-account-channel-peer`) prevents cross-user context leakage

### Resource Scheduling: Lane-Based Queue

OpenClaw uses a **lane-aware FIFO queue** for resource scheduling:

**Lanes:**
- `main`: inbound auto-reply runs (default concurrency 4)
- `cron`: background cron jobs
- `subagent`: sub-agent runs (default concurrency 8)
- `nested`: nested agent runs
- `session:<key>`: per-session serialization

**How it works:**
- Each inbound message is enqueued by session key (`session:<key>`) guaranteeing only one active run per session
- Session runs are then queued into a global lane (`main`) capping overall parallelism
- Lane concurrency is configurable via `agents.defaults.maxConcurrent`
- No external dependencies -- pure TypeScript promises
- Typing indicators fire immediately on enqueue (UX optimization)
- Queue warns if wait exceeds 2 seconds

**Queue modes per channel:**
- `collect`: coalesce queued messages into a single followup turn (default)
- `steer`: inject into current run, cancel pending tool calls
- `followup`: enqueue for next turn
- `steer-backlog`: steer now AND preserve for followup
- `interrupt`: abort active run, run newest message

**Queue overflow policies:**
- `old`: drop oldest
- `new`: drop newest
- `summarize`: keep bullet-point summary of dropped messages

**Relevance to Interverse:** The lane-based queue is an elegant and lightweight scheduling primitive. It solves session-level serialization and global concurrency without external dependencies. The `collect` mode (coalescing multiple inbound messages) is a clever pattern for high-throughput scenarios. The generation-based task tracking (`state.generation`) for handling in-process restarts is a robust pattern worth studying.

---

## 4. Architectural Patterns Relevant to an Orchestration Kernel

### Pattern 1: Gateway as Single Control Plane

Everything routes through one WebSocket server. The Gateway is the **single source of truth** for:
- Session state
- Agent routing
- Tool execution
- Channel connections
- Presence/health

This is a hub-and-spoke architecture where the Gateway is the hub. Clients, nodes, and agents are all spokes that connect via the same WS protocol.

**Lesson:** A centralized control plane simplifies state management, routing, and observability. The tradeoff is that the Gateway is a single point of failure, but for a personal/team tool this is acceptable.

### Pattern 2: Deterministic Binding Resolution

Rather than using LLM inference for routing, OpenClaw uses a **config-driven, deterministic** binding resolver with tiered precedence. This is:
- Predictable (no prompt injection can redirect messages)
- Fast (no model call needed)
- Debuggable (use `openclaw agents list --bindings` to see effective routing)

**Lesson:** For an orchestration kernel, deterministic routing with override tiers is superior to LLM-based routing for reliability-critical paths.

### Pattern 3: Session-as-Unit-of-Isolation

The session key is the fundamental unit of isolation. Everything is scoped to a session:
- One active run per session (serialized via lanes)
- Session-scoped sandbox containers
- Session-scoped tool policies
- Session-scoped state (JSONL transcripts)

**Lesson:** Making the session (not the agent, not the user) the isolation boundary simplifies concurrency and state management. Multiple agents can share a Gateway, but within a session, only one thing runs at a time.

### Pattern 4: Lane-Based Concurrency Without External Dependencies

The `CommandQueue` is a pure-TypeScript, in-process FIFO with:
- Named lanes for logical isolation
- Configurable per-lane concurrency
- Generation-based stale task detection (for in-process restarts)
- Warning thresholds for queue wait times
- `waitForActiveTasks()` for graceful shutdown

This avoids Redis, RabbitMQ, or any external queue system. For a single-process architecture, this is the right tradeoff.

**Lesson:** In-process lane queues are sufficient for single-host orchestration. The generation counter pattern for handling restarts without dropping queued work is particularly elegant.

### Pattern 5: Plugin-as-In-Process-Extension

Plugins are TypeScript modules loaded via `jiti` at runtime. They run **in-process** with the Gateway. They can register:
- Gateway RPC methods
- HTTP handlers
- Agent tools
- CLI commands
- Background services
- Skills
- Auto-reply commands

This is a deliberate choice: plugins are trusted code with full process access. There is no plugin sandbox.

**Lesson:** For a personal tool, in-process plugins are the right tradeoff (performance + simplicity). For a multi-tenant platform, you'd need plugin isolation (WASM, separate processes, or containers).

### Pattern 6: Three-Layer Security Model

OpenClaw's security model separates three independent concerns:
1. **Sandbox** (where code runs -- host vs container)
2. **Tool Policy** (what tools are available -- allow/deny)
3. **Elevated** (escape hatch for specific operations)

Each layer has independent config keys, and they compose cleanly. Deny always wins.

**Lesson:** Separating "where" from "what" from "escape hatch" is a clean security decomposition. The `sandbox explain` CLI command for debugging effective security posture is a great UX pattern.

### Pattern 7: Hook-Based Lifecycle Extensibility

OpenClaw has two hook systems:
- **Internal hooks** (Gateway hooks): event-driven scripts for commands and lifecycle
- **Plugin hooks**: extension points in the agent/tool lifecycle

Plugin hooks include:
- `before_model_resolve` / `before_prompt_build`
- `before_agent_start` / `agent_end`
- `before_compaction` / `after_compaction`
- `before_tool_call` / `after_tool_call`
- `tool_result_persist`
- `message_received` / `message_sending` / `message_sent`
- `session_start` / `session_end`
- `gateway_start` / `gateway_stop`

**Lesson:** A comprehensive lifecycle hook system enables extensibility without modifying core. The distinction between "internal hooks" (config-driven scripts) and "plugin hooks" (code-level extension points) is a useful separation.

### Pattern 8: Compaction and Context Window Management

OpenClaw handles context window limits through:
- Session pruning (trimming old tool results from in-memory context before LLM calls)
- Auto-compaction (summarizing older context to free window space)
- Pre-compaction memory flush (reminding the model to write durable notes before compaction)
- Context window guard (preventing overflows)

**Lesson:** For long-lived agent sessions, context management is critical infrastructure. The "pre-compaction memory flush" pattern -- giving the agent a chance to persist important state before context is compressed -- is a novel idea worth adopting.

---

## 5. Novel Ideas About Agent Lifecycle, State Management, and Workflow

### 5.1 Session Lifecycle: Reset-on-Schedule

Sessions reset based on configurable policies:
- **Daily reset**: at a specific hour (default 4:00 AM local time)
- **Idle reset**: after N minutes of inactivity
- **Per-type overrides**: different policies for direct/group/thread sessions
- **Per-channel overrides**: different policies per channel

Whichever expires first forces a new session. This creates natural "fresh starts" without manual intervention.

**Novel aspect:** The combination of daily + idle reset with per-type/per-channel overrides is more sophisticated than most agent frameworks, which either never reset or require manual reset.

### 5.2 Agent-to-Agent Reply-Back Loop

When `sessions_send` is used, OpenClaw runs a **ping-pong reply loop**:
1. Requester sends message to target session
2. Target responds
3. Response goes back to requester
4. Requester can respond back
5. Loop continues up to `maxPingPongTurns` (default 5)
6. Either side can break the loop with `REPLY_SKIP`
7. After loop ends, an **announce step** optionally posts results to the target's channel

**Novel aspect:** The reply-back loop with explicit `REPLY_SKIP` termination and the separate announce step create a structured conversational protocol between agents. The sentinel-based termination (`REPLY_SKIP`, `ANNOUNCE_SKIP`) is simple but effective.

### 5.3 Queue Mode: Collect/Steer/Followup

The queue mode system is sophisticated:
- **Collect** coalesces multiple inbound messages into a single followup turn, reducing LLM calls
- **Steer** injects messages into the current run, canceling pending tool calls at the next tool boundary
- **Steer-backlog** steers AND preserves for a followup, ensuring nothing is lost
- **Summarize overflow** keeps a bullet-point summary of dropped messages when the queue hits capacity

**Novel aspect:** The `steer` concept -- injecting new context into an actively running agent turn and canceling pending tool calls -- is a pragmatic solution to the "user changed their mind mid-execution" problem. The `summarize` overflow policy is clever for high-throughput scenarios.

### 5.4 Per-Agent Model + Auth Profile Isolation

Each agent can use different:
- LLM models (e.g., Sonnet for chat, Opus for deep work)
- Auth profiles (separate API keys/OAuth tokens per agent)
- Auth profile rotation with failover
- Cooldown-based rate limit recovery

**Novel aspect:** Auth profile rotation with failover and cooldown is production infrastructure that most agent frameworks ignore entirely.

### 5.5 Sub-Agent Announce Pattern

When a sub-agent completes:
1. OpenClaw runs an announce step in the sub-agent's context
2. The announce includes the original request + round-1 reply
3. Sub-agent can reply `ANNOUNCE_SKIP` to stay silent
4. Any other reply is normalized to `Status`/`Result`/`Notes` and sent to the requester's channel
5. Stats are included (runtime, tokens, session key, transcript path, cost)

**Novel aspect:** The structured announce pattern with normalized output format and automatic stats creates a consistent experience regardless of what the sub-agent actually did. This is a UX pattern worth adopting.

### 5.6 Identity Links for Cross-Channel DM Continuity

`session.identityLinks` maps provider-prefixed peer IDs to canonical identities:

```json5
{
  identityLinks: {
    alice: ["telegram:123456789", "discord:987654321012345678"],
  },
}
```

This ensures the same person shares a DM session across channels.

**Novel aspect:** Cross-channel identity resolution at the session layer, without requiring a centralized user database.

### 5.7 Skills Architecture (Bundled + Managed + Workspace)

Skills load from three locations with workspace winning on name conflict:
1. Bundled (shipped with install)
2. Managed/local (`~/.openclaw/skills`)
3. Workspace (`<workspace>/skills`)

Skills are gated by config/env and can be installed from ClawHub (a minimal skill registry).

**Novel aspect:** The three-tier skill loading with conflict resolution and registry integration is a mature skills architecture.

---

## 6. Summary: What's Most Relevant for an Interverse Orchestration Kernel

### Immediately Applicable Patterns

| Pattern | OpenClaw Implementation | Interverse Application |
|---------|------------------------|----------------------|
| Lane-based scheduling | `CommandQueue` with named lanes, per-lane concurrency, generation tracking | intercore event bus, agent run serialization |
| Deterministic routing | Config-driven binding resolution with tiered precedence | Agent-to-session routing in intermute/interlock |
| Session-as-isolation-boundary | Session key scopes sandbox, tools, state, concurrency | Agent session isolation in multi-agent coordination |
| Three-layer security | Sandbox (where) + Tool Policy (what) + Elevated (escape) | Plugin permission model |
| Lifecycle hooks | Comprehensive before/after hooks for every lifecycle phase | Clavain hook system, intercore hooks |
| Sub-agent spawn with depth limits | `maxSpawnDepth`, `maxChildrenPerAgent`, structured announce | Managed sub-agent spawning in coordinated workflows |
| Queue coalescing (collect mode) | Multiple inbound messages coalesced into one agent turn | Token efficiency in multi-agent message passing |
| Pre-compaction memory flush | Agent writes durable notes before context compression | intermem integration with compaction |

### Architecture Decisions Worth Noting

1. **Single-process, in-process everything** -- OpenClaw deliberately avoids distributed systems complexity. For a personal tool, this is the right call. For Interverse (multi-agent on one host), this model also works well.

2. **Config-driven, not LLM-driven routing** -- Agent routing is deterministic. This is more reliable and faster than asking an LLM "which agent should handle this?"

3. **JSONL transcripts over database** -- Session state is stored as JSONL files, not in SQLite or Postgres. This is simple, human-readable, and git-friendly, but loses query capability.

4. **No recursive sub-agents** -- Sub-agents cannot spawn their own sub-agents (hard limit). This prevents runaway agent proliferation.

5. **Plugin trust model** -- Plugins run in-process with full access. This is fast but means plugins must be trusted code.

6. **Sentinel-based protocol** -- `REPLY_SKIP`, `ANNOUNCE_SKIP`, `NO_REPLY` are magic strings in agent output that control flow. Simple but brittle.

### What OpenClaw Does NOT Have (Gaps for Orchestration Kernel)

- **No task decomposition** -- No built-in ability to break a complex task into subtasks and assign them to agents
- **No consensus/voting** -- No mechanism for multiple agents to vote on or synthesize answers
- **No shared state beyond sessions** -- No blackboard, event bus, or shared knowledge base across agents
- **No agent lifecycle management** -- Agents are configured, not dynamically created/destroyed
- **No resource budgeting** -- No token budgets, cost caps, or resource quotas per agent
- **No structured workflows** -- No DAG execution, pipeline stages, or state machines
- **No agent capability discovery** -- Routing is config-driven, not based on what agents can do

These gaps are exactly where an orchestration kernel like intercore would add value.

---

## 7. Technical Details

### Tech Stack
- **Runtime:** Node 22+
- **Language:** TypeScript (ESM), compiled via `tsc`/`tsx`
- **Build:** pnpm monorepo (bun supported for dev)
- **Test:** Vitest with V8 coverage (70% threshold)
- **Lint/Format:** Oxlint + Oxfmt
- **Gateway protocol:** WebSocket (JSON frames)
- **Schema:** TypeBox (JSON Schema generation)
- **Agent runtime:** Embedded pi-mono (forked/derived)
- **Sandbox:** Docker containers (Debian bookworm-slim base)
- **Apps:** SwiftUI (macOS/iOS), Kotlin (Android)

### Repo Structure
```
src/
  agents/          # Agent runtime, tools, sandbox, spawning
  process/         # Command queue, lanes, exec, supervisor
  routing/         # Binding resolution, session keys
  channels/        # Channel integrations
  config/          # Config loading and types
  gateway/         # Gateway RPC server
  cli/             # CLI commands
  media/           # Media pipeline
  web/             # WebChat
extensions/        # Plugin packages
apps/
  macos/           # SwiftUI macOS app
  ios/             # SwiftUI iOS app
  android/         # Kotlin Android app
docs/              # Mintlify documentation
Swabble/           # Swift speech pipeline (macOS/iOS)
```

### Key Files for Architecture Study
- `src/process/command-queue.ts` -- Lane-based queue implementation (simple, well-structured)
- `src/process/lanes.ts` -- Lane enum definition
- `src/agents/subagent-spawn.ts` -- Sub-agent lifecycle and spawning
- `src/routing/bindings.ts` -- Deterministic binding resolution
- `src/routing/session-key.ts` -- Session key construction and parsing
- `src/agents/sandbox/` -- Full sandbox implementation (Docker management, security validation)
- `src/agents/lanes.ts` + `src/agents/pi-embedded-runner/lanes.ts` -- Session-to-lane mapping
