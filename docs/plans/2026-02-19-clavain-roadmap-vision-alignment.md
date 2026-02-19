# Clavain Roadmap Vision Alignment — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use clavain:executing-plans to implement this plan task-by-task.

**Bead:** iv-yeka
**Phase:** executing (as of 2026-02-19T19:27:47Z)

**Goal:** Rewrite `hub/clavain/docs/roadmap.md` to replace the old Phase-based roadmap (Now/Next/Later with CV-N* items) with three parallel tracks (A: Kernel Integration, B: Model Routing, C: Agency Architecture) aligned to the new vision.md.

**Architecture:** Single-file documentation rewrite. The vision.md already contains the canonical roadmap structure (three tracks, convergence diagram, research agenda, companion constellation). The task is to translate that into a roadmap-format document with current bead counts, accurate companion versions, and concrete status markers.

**Tech Stack:** Markdown, beads CLI for statistics

---

### Task 1: Rewrite roadmap header and "Where We Are" section

**Files:**
- Modify: `hub/clavain/docs/roadmap.md:1-36`

**Step 1: Write the new header and "Where We Are"**

Replace the entire file with the new content. The header should:
- Update version to 0.6.42
- Update date to 2026-02-19
- Reference new vision.md identity (autonomous software agency, not "self-improving multi-agent rig")
- Update component counts: 15 skills, 4 agents, 52 commands, 21 hooks, 1 MCP server
- Update companion count: 31 companions (not 19)
- Update bead stats: 925 total, 590 closed, 334 open, 1 in_progress
- Add "What's Working" reflecting the three-layer architecture (Kernel/OS/Drivers)
- Update "What's Not Working Yet" to reference Intercore being in active development rather than the old analytics gaps

```markdown
# Clavain Roadmap

**Version:** 0.6.42
**Last updated:** 2026-02-19
**Vision:** [`docs/vision.md`](vision.md)
**PRD:** [`docs/PRD.md`](PRD.md)

---

## Where We Are

Clavain is an autonomous software agency — 15 skills, 4 agents, 52 commands, 21 hooks, 1 MCP server. 31 companion plugins in the inter-* constellation. 925 beads tracked, 590 closed, 334 open. Runs on its own TUI (Autarch), backed by Intercore kernel and Interspect profiler.

### What's Working

- Full product lifecycle: Discover → Design → Build → Ship, each a sub-agency with model routing
- Three-layer architecture: Kernel (Intercore) → OS (Clavain) → Drivers (companion plugins)
- Multi-agent review engine (interflux) with 7 fd-* review agents + 5 research agents
- Phase-gated `/sprint` pipeline with work discovery, bead lifecycle, session claim atomicity
- Cross-AI peer review via Oracle (GPT-5.2 Pro) with quick/deep/council/mine modes
- Parallel dispatch to Codex CLI via `/clodex` with mode switching
- Structural test suite: 165 tests (pytest + bats-core)
- Multi-agent file coordination via interlock (MCP server wrapping intermute Go service)
- Signal-based drift detection via interwatch
- Interspect analytics: SQLite evidence store, 3-tier analysis, confidence thresholds
- Intercore kernel: Go CLI + SQLite, runs/phases/gates/dispatches/events as durable state

### What's Not Working Yet

- **Intercore integration incomplete.** Kernel primitives are built (E1-E2 done), but Clavain still uses shell-based state management. Hook cutover (E3) is the critical next step.
- **No adaptive model routing.** Static routing exists (stage→model mapping), but no complexity-aware or outcome-driven selection.
- **Agency architecture is implicit.** Sub-agencies (Discover/Design/Build/Ship) are encoded in skills and hooks, not in declarative specs or a fleet registry.
- **Outcome measurement limited.** Interspect collects evidence but no override has been applied. Cost-per-change and quality metrics are unquantified.
```

**Step 2: Verify the header renders correctly**

Run: `head -40 hub/clavain/docs/roadmap.md`
Expected: New header with updated version, date, and identity

**Step 3: Commit**

```bash
git add hub/clavain/docs/roadmap.md
git commit -m "docs(clavain): update roadmap header for vision alignment"
```

---

### Task 2: Replace old Now/Next/Later roadmap with three parallel tracks

**Files:**
- Modify: `hub/clavain/docs/roadmap.md` (replace "Roadmap" section)

**Step 1: Write the three parallel tracks section**

Replace the old `## Roadmap` with `## Shipped Since Last Roadmap` and `## Roadmap: Three Parallel Tracks`. Content should mirror vision.md's Track A/B/C structure but add:
- Bead IDs for each step (from existing beads)
- Current status markers (done/in-progress/open)
- Intercore epoch references (E1-E7)

```markdown
---

## Shipped Since Last Roadmap

Major features that landed since the 0.6.22 roadmap:

| Feature | Description |
|---------|-------------|
| **Intercore kernel (E1-E2)** | Go CLI + SQLite — runs, phases, gates, dispatches, events as durable state. Kernel primitives and event reactor shipped. |
| **Vision rewrite** | New identity: autonomous software agency with three-layer architecture (Kernel/OS/Drivers) |
| **12 new companions** | intermap, intermem, intersynth, interlens, interleave, interserve, interpeer, intertest, interkasten, interphase v2, interstat, interfluence |
| **Monorepo consolidation** | Physical monorepo at /root/projects/Interverse with 31 companion plugins |
| **Hierarchical dispatch plan** | Meta-agent for N-agent fan-out (planned, iv-quk4) |
| **tldrs LongCodeZip** | Block-level compression for token-efficient code context (planned, iv-2izz) |
| **Version 0.6.22 → 0.6.42** | 20 version bumps |

---

## Roadmap: Three Parallel Tracks

The roadmap progresses on three independent tracks that converge toward autonomous self-building sprints.

### Track A: Kernel Integration

Migrate Clavain from ephemeral state management to durable kernel-backed orchestration.

| Step | What | Bead | Status | Depends On |
|------|------|------|--------|------------|
| A1 | **Hook cutover** — all Clavain hooks call `ic` instead of temp files | iv-ngvy | Open (P1) | Intercore E1-E2 (done) |
| A2 | **Sprint handover** — sprint skill becomes kernel-driven (hybrid → handover → kernel-driven) | — | Not yet created | A1 |
| A3 | **Event-driven advancement** — phase transitions trigger automatic agent dispatch | — | Not yet created | A2 |

### Track B: Model Routing

Build the multi-model routing infrastructure from static to adaptive.

| Step | What | Bead | Status | Depends On |
|------|------|------|--------|------------|
| B1 | **Static routing table** — phase→model mapping declared in config, applied at dispatch | — | Not yet created | — |
| B2 | **Complexity-aware routing** — task complexity drives model selection within phases | — | Not yet created | Intercore token tracking (E1) |
| B3 | **Adaptive routing** — Interspect outcome data drives model/agent selection | — | Not yet created | Interspect kernel integration (iv-thp7) |

### Track C: Agency Architecture

Build the agency composition layer that makes Clavain a fleet of specialized sub-agencies.

| Step | What | Bead | Status | Depends On |
|------|------|------|--------|------------|
| C1 | **Agency specs** — declarative per-stage config: agents, models, tools, artifacts, gates | — | Not yet created | — |
| C2 | **Agent fleet registry** — capability + cost profiles per agent×model combination | — | Not yet created | B1 |
| C3 | **Composer** — matches agency specs to fleet registry within budget constraints | — | Not yet created | C1, C2 |
| C4 | **Cross-phase handoff** — structured protocol for how Discover's output becomes Design's input | — | Not yet created | C1 |
| C5 | **Self-building loop** — Clavain uses its own agency specs to run its own development sprints | — | Not yet created | C3, C4, A3 |

### Convergence

The three tracks converge at C5: a self-building Clavain that autonomously orchestrates its own development sprints using kernel-backed state, multi-model routing, and fleet-optimized agent dispatch.

```
Track A (Kernel)      Track B (Routing)     Track C (Agency)
    A1                    B1                    C1
    │                     │                     │
    A2                    B2───────────────→    C2
    │                     │                     │
    A3                    B3                    C3
    │                                           │
    └───────────────────────────────────────→   C4
                                                │
                                               C5 ← convergence
                                          (self-building)
```

### Supporting Epics (Intercore)

These Intercore epics are prerequisites for the tracks above:

| Epic | What | Bead | Status |
|------|------|------|--------|
| E3 | Hook cutover — big-bang Clavain migration | iv-ngvy | Open (P1) |
| E4 | Level 3 Adapt — Interspect kernel event integration | iv-thp7 | Open (P2) |
| E5 | Discovery pipeline — kernel primitives for research intake | iv-fra3 | Open (P2) |
| E6 | Rollback and recovery — three-layer revert | iv-0k8s | Open (P2) |
| E7 | Autarch Phase 1 — Bigend migration + `ic tui` | iv-ishl | Open (P2) |
```

**Step 2: Verify track tables render correctly**

Run: `grep -c "^|" hub/clavain/docs/roadmap.md`
Expected: Table row count matching the plan

**Step 3: Commit**

```bash
git add hub/clavain/docs/roadmap.md
git commit -m "docs(clavain): replace Now/Next/Later with three parallel tracks"
```

---

### Task 3: Update Research Agenda to align with vision.md

**Files:**
- Modify: `hub/clavain/docs/roadmap.md` (replace "Research Agenda" section)

**Step 1: Write the aligned research agenda**

Replace the old research agenda with the one from vision.md, organized by proximity to current capabilities. Add the "Deprioritized" section and reference the structured frontier compass.

```markdown
---

## Research Agenda

Research areas organized by proximity to current capabilities and aligned with the [Frontier Compass](vision.md#frontier-compass-structured). These are open questions, not deliverables.

### Near-Term (informed by current work)

| Area | Key question | Frontier axes |
|------|-------------|---------------|
| Multi-model composition theory | Principled framework for which model to use when | Token efficiency, Orchestration |
| Agent measurement & analytics | What metrics predict human override? What signals indicate token waste? | Reasoning quality |
| Multi-agent failure taxonomy | How do hallucination cascades, coordination tax, and model mismatch propagate? | Orchestration |
| Cognitive load budgets | How to present multi-agent output for fast, confident review? | Reasoning quality |
| Agent regression testing | Evals as CI — did this prompt change degrade bug-catching? | Reasoning quality |

### Medium-Term (informed by Track B data)

| Area | Key question | Frontier axes |
|------|-------------|---------------|
| Optimal human-in-the-loop frequency | How much attention per sprint produces the best outcomes? | Orchestration |
| Bias-aware product decisions | LLM judges show systematic bias — how to mitigate in brainstorm/strategy? | Reasoning quality |
| Plan-aware context compression | Give each agent domain-specific context via tldrs, not everything | Token efficiency |
| Transactional orchestration | Idempotency, rollback, conflict resolution across distributed agent execution | Orchestration |
| Fleet topology optimization | How many agents per phase? Which combinations produce the best outcomes? | Orchestration, Token efficiency |

### Long-Term (informed by Track C data)

| Area | Key question | Frontier axes |
|------|-------------|---------------|
| Knowledge compounding dynamics | Does cross-project learning improve outcomes or add noise? | Reasoning quality |
| Emergent multi-agent behavior | Can you predict interactions in 7+ agent constellations across multiple models? | Orchestration |
| Guardian agent patterns | Can quality-gates be formalized with instruction adherence metrics? | Reasoning quality |
| Self-improvement feedback loops | How to prevent reward hacking ("skip reviews because it speeds runs")? | Orchestration |
| Security model for autonomous agents | Capability boundaries, prompt injection, supply chain risk, sandbox compliance | All axes |
| Latency budgets | Time-to-feedback as first-class constraint alongside token cost | Token efficiency |

### Deprioritized

- Speculative decoding (can't control inference stack from outside)
- Vision-centric token compression (overkill for code-centric workflows)
- Theoretical minimum token cost (empirical cost-quality curves are more useful)
- Full marketplace/recommendation engine (not where Clavain wins)
```

**Step 2: Commit**

```bash
git add hub/clavain/docs/roadmap.md
git commit -m "docs(clavain): align research agenda with vision frontier compass"
```

---

### Task 4: Update Companion Constellation table

**Files:**
- Modify: `hub/clavain/docs/roadmap.md` (replace "Companion Constellation" section)

**Step 1: Write the updated companion constellation**

Update with all 31 current companions, accurate versions, and proper "crystallized insight" descriptions matching vision.md's framing.

```markdown
---

## Companion Constellation

| Companion | Version | What it crystallized | Status |
|-----------|---------|---------------------|--------|
| **intercore** | — | Orchestration state is a kernel concern | Active development |
| **interspect** | — | Self-improvement needs a profiler, not ad-hoc scripts | Active development |
| **interflux** | 0.2.16 | Multi-agent review + research engine | Shipped |
| **interphase** | 0.3.2 | Phase tracking + gate validation | Shipped |
| **interline** | 0.2.4 | Statusline rendering | Shipped |
| **interpath** | 0.2.2 | Product artifact generation | Shipped |
| **interwatch** | 0.1.2 | Doc freshness monitoring | Shipped |
| **interlock** | 0.2.1 | Multi-agent file coordination (MCP) | Shipped |
| **interject** | 0.1.6 | Ambient discovery + research engine (MCP) | Shipped |
| **interdoc** | 5.1.1 | AGENTS.md generator + Oracle critique | Shipped |
| **intermux** | 0.1.1 | Agent visibility (MCP) | Shipped |
| **interslack** | 0.1.0 | Slack integration | Shipped |
| **interform** | 0.1.0 | Design patterns + visual quality | Shipped |
| **intercraft** | 0.1.0 | Agent-native architecture patterns | Shipped |
| **interdev** | 0.2.0 | MCP CLI + developer tooling | Shipped |
| **intercheck** | 0.1.4 | Code quality guards + session health | Shipped |
| **internext** | 0.1.2 | Work prioritization + tradeoff analysis | Shipped |
| **interpub** | 0.1.2 | Plugin publishing | Shipped |
| **intersearch** | 0.1.1 | Shared embedding + Exa search | Shipped |
| **interstat** | 0.2.2 | Token efficiency benchmarking | Shipped |
| **intersynth** | 0.1.2 | Multi-agent synthesis engine | Shipped |
| **intermap** | 0.1.3 | Project-level code mapping (MCP) | Shipped |
| **intermem** | 0.2.1 | Memory synthesis + tiered promotion | Shipped |
| **interkasten** | 0.4.2 | Notion sync + documentation | Shipped |
| **interfluence** | 0.2.3 | Voice profile + style adaptation | Shipped |
| **interlens** | 2.2.4 | Cognitive augmentation lenses | Shipped |
| **interleave** | 0.1.1 | Deterministic skeleton + LLM islands | Shipped |
| **interserve** | 0.1.1 | Codex spark classifier + context compression (MCP) | Shipped |
| **interpeer** | 0.1.0 | Cross-AI peer review (Oracle/GPT escalation) | Shipped |
| **intertest** | 0.1.1 | Engineering quality disciplines | Shipped |
| **tldr-swinton** | 0.7.14 | Token-efficient code context (MCP) | Shipped |
| **tool-time** | 0.3.2 | Tool usage analytics | Shipped |
| **tuivision** | 0.1.4 | TUI automation + visual testing (MCP) | Shipped |
| **intershift** | — | Cross-AI dispatch engine | Planned |
| **interscribe** | — | Knowledge compounding | Planned |
```

**Step 2: Commit**

```bash
git add hub/clavain/docs/roadmap.md
git commit -m "docs(clavain): update companion constellation (31 shipped)"
```

---

### Task 5: Update bead summary and footer

**Files:**
- Modify: `hub/clavain/docs/roadmap.md` (replace bead summary + footer sections)

**Step 1: Write the updated bead summary and footer**

Replace the old "All 364 beads are closed" with current stats and update the "Keeping This Roadmap Current" triggers.

```markdown
---

## Bead Summary

| Metric | Value |
|--------|-------|
| Total beads | 925 |
| Closed | 590 |
| Open | 334 |
| In progress | 1 |

Key active epics:
- **iv-66so** — Vision refresh: autonomous software agency (P1, in progress)
- **iv-ngvy** — E3: Hook cutover — big-bang Clavain migration to `ic` (P1)
- **iv-yeka** — Update roadmap.md for new vision + parallel tracks (P1)

---

## Keeping This Roadmap Current

Run `/interpath:roadmap` to regenerate from current project state.

| Trigger | What to update |
|---------|---------------|
| Track step completed | Update status in track table |
| New bead created for a track step | Add bead ID to track table |
| Companion extraction completed | Update Constellation table |
| Research insight changes direction | Add/modify items, document rationale |
| Vision doc updated | Re-align tracks and research agenda |

---

*Synthesized from: [`docs/vision.md`](vision.md), [`docs/PRD.md`](PRD.md), 925 beads, 31 companion plugins, and the Intercore kernel vision. Sources linked throughout.*

## From Interverse Roadmap

Items from the [Interverse roadmap](../../../docs/roadmap.json) that involve this module:

- **iv-zyym** [Next] Evaluate Claude Hub for event-driven GitHub agent dispatch
- **iv-wrae** [Next] Evaluate Container Use (Dagger) for sandboxed agent dispatch
- **iv-quk4** [Next] Hierarchical dispatch — meta-agent for N-agent fan-out
```

**Step 2: Run a final verification**

Run: `wc -l hub/clavain/docs/roadmap.md`
Expected: ~200-250 lines (down from 183, but more information-dense)

**Step 3: Commit all remaining changes**

```bash
git add hub/clavain/docs/roadmap.md
git commit -m "docs(clavain): complete roadmap vision alignment (iv-yeka)"
```

---

### Task 6: Validate cross-references and mark bead complete

**Files:**
- Verify: `hub/clavain/docs/roadmap.md` (all internal links)
- Verify: `hub/clavain/docs/vision.md` (referenced from roadmap)

**Step 1: Verify all links resolve**

Run: `grep -o '\[.*\](.*\.md)' hub/clavain/docs/roadmap.md`
Expected: Links to vision.md and PRD.md that exist

**Step 2: Verify track content matches vision.md**

Manually compare:
- Track A/B/C steps match vision.md § "Roadmap: Three Parallel Tracks"
- Research agenda matches vision.md § "Research Areas"
- Companion table includes all vision.md entries + additional shipped companions

**Step 3: Close the bead**

```bash
bd close iv-yeka --reason="Roadmap rewritten with three parallel tracks, updated constellation, aligned research agenda"
```
