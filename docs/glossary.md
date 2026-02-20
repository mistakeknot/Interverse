# Interverse Glossary

> Canonical terminology for the Interverse ecosystem. When terms are used differently across documents, this glossary defines the correct usage. See [architecture.md](architecture.md) for the 3-layer model diagram.

## Kernel (L1 — Intercore)

| Term | Definition |
|------|------------|
| **Run** | A kernel lifecycle primitive — a named execution with a phase chain, gate rules, event trail, and token budget. The atomic unit of orchestrated work. |
| **Phase** | A named stage within a run. The kernel enforces ordering and gate checks; the OS defines phase names and semantics. |
| **Phase chain** | The ordered sequence of phases a run advances through (e.g., `brainstorm → plan → execute → done`). Custom chains are supported. |
| **Gate** | An enforcement point between phases. The kernel evaluates pass/fail based on rules; the OS defines what evidence is required. Gates can be `hard` (blocking) or `soft` (advisory). |
| **Dispatch** | A kernel record tracking an agent spawn — PID, status, token usage, artifacts. One run may have many dispatches. |
| **Event** | A typed, immutable record of a state change in the kernel. Append-only log with consumer cursors for at-least-once delivery. |
| **State** | Key-value storage scoped by (key, scope_id). Used for session context, configuration, and workflow metadata. Supports TTL for auto-expiration. |
| **Lock** | A filesystem-based named mutex with owner tracking and stale detection. Works even when the database is unavailable. |
| **Sentinel** | A rate-limiting primitive — tracks "last seen" timestamps to throttle repeated operations. |
| **Artifact** | A file produced during a run phase (brainstorm doc, plan file, test output). Tracked with content hashes for integrity. |
| **Token budget** | Per-run or per-dispatch limits on LLM token consumption, with warning thresholds. |

## OS (L2 — Clavain + Drivers)

| Term | Definition |
|------|------------|
| **Sprint** | An OS-level run template with preset phases (brainstorm → strategize → plan → review → execute → ship → reflect). The full development lifecycle. |
| **Bead** | Clavain's work-tracking primitive — adds priority (P0-P4), type (epic/feature/task/bug), dependencies, and sprint association on top of kernel runs. Managed via the `bd` CLI. |
| **Macro-stage** | OS-level workflow grouping: Discover, Design, Build, Ship, Reflect. Each maps to sub-phases in the kernel. |
| **Skill** | A reusable prompt template that defines a specific capability (brainstorming, plan writing, code review). Invoked via `/clavain:<name>`. |
| **Command** | A user-invocable slash command (e.g., `/sprint`, `/work`). May invoke one or more skills. |
| **Hook** | A shell script triggered by Claude Code lifecycle events (SessionStart, PostToolUse, etc.). Used for state injection, validation, and telemetry. |
| **Driver** | A companion plugin that extends the OS layer with a specific capability. Not a separate architectural layer. Also called "companion plugin." |
| **Companion plugin** | An `inter-*` capability module (interflux, interlock, interject, etc.) — wraps one capability as an OS extension. Synonym for "driver." |
| **Quality gates** | The review step before shipping — auto-selects reviewer agents based on what changed, runs them in parallel, synthesizes findings. |
| **Flux-drive** | Multi-agent document/code review workflow — triages relevant review perspectives, dispatches specialist agents. |
| **Day-1 workflow** | The core loop a new user experiences: brainstorm → plan → review plan → execute → test → gates → ship. |
| **Safety posture** | The level of caution enforced at each macro-stage (low for Discover, highest for Ship). |

## Apps (L3 — Autarch)

| Term | Definition |
|------|------------|
| **Autarch** | The application layer — four TUI tools (Bigend, Gurgeh, Coldwine, Pollard) plus shared `pkg/tui` library. |
| **Bigend** | Multi-project agent mission control (web + TUI dashboard). |
| **Gurgeh** | TUI-first PRD generation and validation tool. |
| **Coldwine** | Task orchestration for human-AI collaboration. |
| **Pollard** | General-purpose research intelligence (tech, medicine, law, economics). |
| **Intent** | A high-level action request from L3 to L2 (e.g., start-run, advance-run, override-gate, submit-artifact). Apps express intents; the OS translates them to kernel operations. |

## Cross-Cutting

| Term | Definition |
|------|------------|
| **Interspect** | Adaptive profiler that consumes kernel events and proposes OS configuration changes. Read-only — never writes to the kernel. Cross-cutting, not a layer. |
| **Write-path contract** | The invariant that all durable state flows through the kernel (L1). Higher layers call `ic` CLI commands — they never write to the database directly. |
| **Host adapter** | Platform integration layer (Claude Code plugin interface, Codex CLI, bare shell). Not a companion plugin. |
| **Dispatch driver** | Agent execution backend (Claude CLI, Codex CLI, container runtime) — the runtime that executes a dispatch. |

## Sprint Phase Mapping (OS ↔ Kernel)

The OS (Clavain) and kernel (Intercore) both use 9-phase chains, but with different phase names. This table shows the canonical mapping.

| # | OS Phase (`PHASES_JSON`) | Kernel Phase (`DefaultPhaseChain`) | Notes |
|---|---|---|---|
| 1 | `brainstorm` | `brainstorm` | Same |
| 2 | `brainstorm-reviewed` | `brainstorm-reviewed` | Same |
| 3 | `strategized` | `strategized` | Same |
| 4 | `planned` | `planned` | Same |
| 5 | `plan-reviewed` | *(no equivalent)* | OS-only — flux-drive plan review gate. Kernel has no `plan-reviewed` phase. |
| 6 | `executing` | `executing` | Same |
| 7 | `shipping` | `polish` | Historical divergence. OS rename deferred (see iv-52om). |
| 8 | `reflect` | `reflect` | Same. Gate rule `CheckArtifactExists` fires for both chains. |
| 9 | `done` | `done` | Same. Terminal phase — sets `status=completed`. |

**Kernel gate rule coverage:** Only `{reflect, done}: CheckArtifactExists` fires for OS-created sprints, because the OS uses different phase names for earlier phases. This is a known pre-existing condition.

**Why divergent:** `plan-reviewed` exists in the OS because flux-drive plan review is an OS-level gate with no kernel equivalent. `shipping` was the original name for the quality-gates/ship step; renaming it to `polish` requires migration of all existing sprints (deferred to iv-52om).

## Terms to Avoid

| Don't say | Say instead | Why |
|-----------|-------------|-----|
| L4, L5 | Driver, Cross-cutting | The 3-layer model has L1-L3 only; drivers are L2 extensions, Interspect is cross-cutting |
| "interphase" (for new code) | `ic gate`, `ic run` | interphase is a legacy compatibility shim; new code should call intercore directly |
| "workflow engine" | kernel, orchestration kernel | Intercore provides primitives, not a workflow DSL |
| "API" (for intercore v1) | CLI surface | There is no Go library API in v1; the CLI is the contract |
