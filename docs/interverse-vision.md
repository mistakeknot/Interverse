# Interverse — Vision Document

**Version:** 1.0
**Date:** 2026-02-19
**Status:** Draft

---

## The Core Idea

Interverse is the infrastructure for autonomous software development. It provides a layered system — kernel, operating system, profiler, drivers, and applications — that together make it possible for AI agents to build software with the durability, discipline, and observability that production work demands.

The thesis is simple: agents that forget, skip steps, and operate without accountability will never produce software you'd trust to ship. The fix is not better prompts. It's architecture — a system of record beneath the agents that persists what happened, enforces what must happen next, and learns from what went wrong.

## Why This Exists

LLM-based agents have a fundamental problem: nothing survives. Context windows compress. Sessions end. Networks drop. Processes crash. An agent that ran for an hour, produced three artifacts, dispatched two sub-agents, and advanced through four workflow phases leaves behind... a chat transcript. The state, the decisions, the evidence, the coordination signals — all gone.

This is not a prompting problem. It's an infrastructure problem.

Every serious software development workflow has the same needs: lifecycle management (what phase are we in?), quality gates (can we advance?), dispatch tracking (who's working on what?), event history (what happened?), and coordination (who holds the lock?). Today, most agent systems handle these with temp files, environment variables, in-memory state, and hope. Interverse handles them with a durable kernel backed by SQLite, an opinionated OS that encodes development discipline, a profiler that learns from outcomes, and a fleet of companion drivers that extend the system's capabilities.

The bet: if you build the right infrastructure beneath agents, they become capable of the full development lifecycle — not just code generation, but discovery, design, review, testing, shipping, and compounding what was learned.

## The Stack

Interverse is five layers. Each has a clear owner, a clear boundary, and a clear survival property.

```
Layer 5: Apps (Autarch)
├── Interactive TUI surfaces for kernel state
├── Swappable — one realization of the application layer
└── If Autarch is replaced, everything beneath survives

Layer 4: Profiler (Interspect)
├── Reads kernel events, correlates with human corrections
├── Proposes changes to OS configuration
├── Never modifies the kernel — only the OS layer
└── If Interspect is removed, the system works; it just doesn't learn

Layer 3: Drivers (Companion Plugins)
├── Each wraps one capability (review, coordination, research, etc.)
├── Call the kernel directly for shared state
└── If any driver is removed, that capability is lost; everything else works

Layer 2: OS (Clavain)
├── The opinionated workflow — phases, gates, model routing, dispatch policies
├── Configures the kernel at run creation time
├── Provides the developer experience (slash commands, hooks, skills)
└── If the host platform changes, opinions survive; UX adapters are rewritten

Layer 1: Kernel (Intercore)
├── Host-agnostic Go CLI + SQLite WAL database
├── Runs, phases, gates, dispatches, events — the durable system of record
├── Mechanism, not policy — doesn't know what "brainstorm" means
└── If everything above disappears, the kernel and all its data survive
```

The survival properties are the point. Each layer can be replaced, rewritten, or removed without destroying the layers beneath it. The kernel outlives the OS. The OS outlives its host platform. The drivers outlive any particular capability need. The apps outlive any particular rendering choice. This is not defensive architecture — it's practical architecture for a system that must survive the agent platform wars.

### What Each Layer Owns

**The kernel (Intercore)** provides mechanism: runs, phases, gates, dispatches, events, state, locks, sentinels. It is a Go CLI binary with no daemon, no server, no background process. Every `ic` invocation opens the database, performs its operation, and exits. The SQLite database is the system of record. The kernel says "a gate can block a transition" — it doesn't say "brainstorm requires an artifact." That's policy.

**The OS (Clavain)** provides policy: which phases make up a development sprint, what conditions must be met at each gate, which model to route each agent to, when to advance automatically. Clavain is an autonomous software agency — it orchestrates the full lifecycle from problem discovery through shipped code. It's opinionated about what "good" looks like at every phase, and those opinions are encoded in gates, review agents, and quality disciplines.

**The profiler (Interspect)** provides learning: it reads the kernel's event stream, correlates dispatch outcomes with human corrections, and proposes changes to OS configuration. Override rate, false positive rate, finding density — signals that compound over time. Interspect never modifies the kernel. It modifies the OS layer through safe, reversible overlays.

**The drivers (companion plugins)** provide capabilities: multi-agent review (interflux), file coordination (interlock), ambient research (interject), token-efficient code context (tldr-swinton), agent visibility (intermux), and two dozen more. Each wraps one capability and extends the system through kernel primitives. Drivers are Claude Code plugins today, but the capabilities they wrap are not Claude Code-specific.

**The apps (Autarch)** provide surfaces: Bigend (monitoring), Gurgeh (PRD generation), Coldwine (task orchestration), Pollard (research intelligence). Each renders kernel state into interactive TUI experiences. The apps are a convenience layer — everything they do can be done via CLI.

## Design Principles

### 1. Mechanism over policy

The kernel provides primitives. The OS provides opinions. A phase chain is a mechanism — an ordered sequence with transition rules. The decision that software development should flow through eight phases is a policy that Clavain configures at run creation time.

This separation is what makes the system extensible without modification. A documentation project uses `draft → review → publish`. A hotfix uses `triage → fix → verify`. A research spike uses `explore → synthesize`. The kernel doesn't care — it walks a chain, evaluates gates, and records events. New workflows don't require new kernel code.

### 2. Durable over ephemeral

If it matters, it's in the database. Phase transitions, gate evidence, dispatch outcomes, event history — all persisted atomically in SQLite. Temp files, environment variables, and in-memory state are never acceptable for the system of record.

This principle has a cost: write latency. And a benefit: any session, any agent, any process can query the true state of the system at any time. When a session crashes mid-sprint, the run state is intact and resumable. When a new agent joins, it reads the same truth everyone else reads.

### 3. Compose through contracts

Small, focused tools composed through explicit interfaces beat large integrated platforms. The inter-\* constellation follows Unix philosophy: each companion does one thing well. Composition works because boundaries are explicit — typed interfaces, schemas, manifests, and declarative specs rather than prompt sorcery.

The naming convention reflects this: each companion occupies the space *between* two things. interphase (between phases), interflux (between flows), interlock (between locks), interpath (between paths). They are bridges and boundary layers, not monoliths.

### 4. Human attention is the bottleneck

Agents are cheap. Human focus is scarce. The system optimizes for the human's time, not the agent's. Token efficiency is not the same as attention efficiency — multi-agent output must be presented so humans can review quickly and confidently, not just cheaply.

This means the human drives strategy (what to build, which tradeoffs to accept, when to ship) while the agency drives execution (which model, which agents, what sequence, when to advance, what to review). The human is above the loop, not in it.

### 5. Discipline before speed

Quality gates matter more than velocity. Agents without discipline ship slop. The system resolves all open questions before execution — ambiguity costs more during building than during planning. The review phases are not overhead; they are the product.

Gates are kernel-enforced invariants, not prompt suggestions. An agent cannot bypass a gate regardless of what the LLM requests. This is the difference between "please check for a plan artifact" and "the system will not advance without a plan artifact."

### 6. Self-building as proof

Every capability must survive contact with its own development process. Clavain builds Clavain. The agency runs its own sprints — research, brainstorm, plan, execute, review, compound. This is the credibility engine: a system that autonomously builds itself is a more convincing proof than any benchmark.

### 7. Right model, right task

No one model is best at everything. The agency's intelligence includes knowing *which* intelligence to apply. Gemini for long-context exploration. Opus for reasoning and design. Codex for parallel implementation. Haiku for quick checks. Oracle (GPT-5.2 Pro) for cross-validation. Model routing is a first-class architectural decision, not an afterthought.

## The Autonomy Ladder

The system enables increasing levels of autonomous operation. Each level builds on the one below, and each level has been earned through the previous level's evidence.

**Level 0 — Record.** The kernel records what happened. Runs, phases, dispatches, artifacts — all tracked. A human drives everything. The kernel is a logbook. *(Shipped.)*

**Level 1 — Enforce.** Gates evaluate real conditions. A run cannot advance without meeting preconditions. The kernel says "no" when evidence is insufficient. *(Shipped.)*

**Level 2 — React.** Events trigger automatic reactions. Phase transitions spawn agents. Completed dispatches advance phases. The human observes and intervenes on exceptions. *(Shipped — SpawnHandler wiring complete.)*

**Level 3 — Adapt.** Interspect reads kernel events, correlates with outcomes, and proposes configuration changes. Agents that produce false positives get downweighted. Phases that never produce useful artifacts get skipped by default. Gate rules evolve based on evidence. *(In progress.)*

**Level 4 — Orchestrate.** The kernel manages a portfolio of concurrent runs across multiple projects. An urgent hotfix preempts a routine refactor. Token budgets prevent runaway costs. Changes in one project trigger verification in dependents. *(Planned.)*

**Level -1 — Discover.** Before work can be recorded, it must be found. The discovery pipeline scans sources, scores relevance against a learned interest profile, and routes findings through confidence-tiered autonomy gates. High-confidence discoveries auto-create work items. Low-confidence discoveries are logged for later retrieval. *(Planned.)*

## The Constellation

The inter-\* ecosystem has 34 modules organized by architectural role.

### Infrastructure

| Module | What It Does |
|--------|-------------|
| **intercore** | Orchestration kernel — runs, phases, gates, dispatches, events, state, locks |
| **interspect** | Adaptive profiler — reads kernel events, proposes OS configuration changes |
| **intermute** | Multi-agent coordination service (Go) — message routing between agents |

### Operating System

| Module | What It Does |
|--------|-------------|
| **clavain** | Autonomous software agency — the opinionated workflow, skills, hooks, routing |

### Drivers (Companion Plugins)

| Module | Crystallized Insight |
|--------|---------------------|
| **interflux** | Multi-agent review and research are generalizable |
| **interphase** | Phase tracking and gate enforcement are generalizable |
| **interlock** | Multi-agent file coordination is generalizable |
| **interject** | Ambient research and discovery are generalizable |
| **tldr-swinton** | Token-efficient code context is generalizable |
| **intermux** | Agent visibility and session monitoring are generalizable |
| **interline** | Status rendering is generalizable |
| **interpath** | Product artifact generation is generalizable |
| **interwatch** | Document freshness monitoring is generalizable |
| **interdoc** | Documentation generation is generalizable |
| **interfluence** | Voice and style adaptation are generalizable |
| **interpub** | Plugin publishing is generalizable |
| **interdev** | Developer tooling workflows are generalizable |
| **interform** | Design patterns and visual quality are generalizable |
| **intercraft** | Agent-native architecture patterns are generalizable |
| **intertest** | Engineering quality disciplines are generalizable |
| **intercheck** | Code quality guards are generalizable |
| **interstat** | Token efficiency benchmarking is generalizable |
| **internext** | Work prioritization and tradeoff analysis are generalizable |
| **intersynth** | Multi-agent synthesis is generalizable |
| **interkasten** | Notion sync and offline-first documentation are generalizable |
| **interpeer** | Cross-AI peer review is generalizable |
| **interslack** | Workflow-to-Slack integration is generalizable |
| **intermap** | Project-level code mapping is generalizable |
| **intermem** | Memory promotion and knowledge curation are generalizable |
| **interlens** | Cognitive augmentation lenses are generalizable |
| **interserve** | Codex dispatch and context compression are generalizable |
| **intersearch** | Shared embedding and search are generalizable |
| **interleave** | Deterministic skeleton + LLM islands pattern is generalizable |
| **tuivision** | TUI automation and visual testing are generalizable |
| **tool-time** | Tool usage analytics are generalizable |

### Applications

| Module | What It Does |
|--------|-------------|
| **autarch** | Interactive TUI surfaces — Bigend, Gurgeh, Coldwine, Pollard |

Each companion started as a tightly-coupled feature inside Clavain. Tight coupling is a feature during the research phase. Capabilities are built integrated, tested under real use, and extracted when the pattern stabilizes enough to stand alone. The constellation represents crystallized research outputs — each companion earned its independence through repeated, successful use.

## Development Model

### Clavain-first, then generalize out

Capabilities are built too-tightly-coupled on purpose. Clavain discovers the natural seams through practice, and only then extracts. This inverts the typical "design the API first" approach. Each companion has been validated by production use before becoming a standalone module.

### Monorepo, separate histories

The Interverse monorepo contains all modules in one filesystem tree, but each module keeps its own `.git` history. This gives the organizational benefits of co-location (shared scripts, cross-module changes in one workspace) without the operational costs of git monorepo tooling. Projects live here; old standalone locations are backward-compatibility symlinks.

### Self-building as eval

The system builds itself. When a capability is added, the first test is whether Clavain can use it in its own development process. This is not a marketing exercise — it's the highest-fidelity eval. A system that autonomously builds itself under real conditions with real stakes is a stronger proof than any benchmark.

## What "Done" Looks Like

The convergence target is a self-building autonomous software agency. Specifically:

1. **Kernel integration complete.** All workflow state flows through `ic`. No temp files. No in-memory state management. Phase transitions, gate enforcement, dispatch tracking, and event history are durable and crash-safe.

2. **Model routing is adaptive.** The system selects the right model for each task based on outcome data, not static rules. Cost and quality are jointly optimized within explicit budgets.

3. **The profiler closes the loop.** Interspect reads kernel events, detects agent performance patterns, proposes OS configuration changes, and validates them via shadow evaluation before applying. The system improves its agents through evidence, not intuition.

4. **The agency runs its own sprints.** From discovery ("what should we build next?") through design, build, review, ship, and compound — the full lifecycle runs with the human above the loop, not in it. The human decides where; the agency decides how.

5. **Portfolio orchestration.** Multiple concurrent runs across multiple projects, with cross-project dependency awareness, resource scheduling, and budget enforcement. The kernel manages a fleet.

This is not AGI. This is infrastructure — purpose-built for the specific problem of building software with heterogeneous AI agents, with the discipline, durability, and observability that production work demands.

## Audience

Three concentric circles, in priority order.

1. **Inner circle.** A personal rig, optimized for one product-minded engineer's workflow. The primary goal is to make a single person as effective as a full team.

2. **Proof by demonstration.** Build the system with the system. Every capability must survive contact with its own development process. This is the credibility engine.

3. **Platform play.** Once dogfooding proves the model, open Intercore as infrastructure for anyone building autonomous coding agents. Clavain becomes the reference OS. AI labs get the kernel. Developers get the agency. Both are open source.

## What This Is Not

- **Not an LLM framework.** Interverse doesn't call LLMs, manage context windows, or process natural language. That's what the dispatched agents do.
- **Not a general AI gateway.** It doesn't route arbitrary messages to arbitrary agents. It orchestrates software development specifically.
- **Not a coding assistant.** It doesn't help you write code; it *builds software* — the full lifecycle. The coding is one phase of four.
- **Not a no-code tool.** It's for people who build software with agents. Full stop.
- **Not self-modifying.** Interspect can modify OS-level configuration. It cannot modify the kernel. This is a deliberate safety boundary.

## Origins

Clavain is named after a protagonist from Alastair Reynolds's *Revelation Space* series. The inter-\* naming convention describes what each component does in the system — the space *between* things. Interverse is the universe that contains them all.

The project began by merging [superpowers](https://github.com/obra/superpowers), [superpowers-lab](https://github.com/obra/superpowers-lab), [superpowers-developing-for-claude-code](https://github.com/obra/superpowers-developing-for-claude-code), and [compound-engineering](https://github.com/EveryInc/compound-engineering-plugin). It has since grown beyond those roots into an autonomous agency with its own kernel, profiler, TUI suite, and companion ecosystem of 34 modules.

---

*For layer-specific details, see the vision docs for [Intercore](infra/intercore/docs/product/intercore-vision.md) (kernel), [Clavain](hub/clavain/docs/clavain-vision.md) (OS), [Autarch](infra/intercore/docs/product/autarch-vision.md) (apps), and [Interspect](infra/intercore/docs/product/interspect-vision.md) (profiler).*
