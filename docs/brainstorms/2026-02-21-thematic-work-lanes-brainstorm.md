# Thematic Work Lanes

**Bead:** iv-jj97
**Phase:** brainstorm (as of 2026-02-21T05:34:09Z)
**Date:** 2026-02-21

## What We're Building

A lane system for organizing, tracking, and autonomously progressing thematic streams of work across the Interverse ecosystem. Lanes group beads by theme (e.g., interop, kernel, ux) and provide:

1. **Session focus** — pick a lane at sprint start to scope which beads get surfaced
2. **Parallel agents** — multiple agents each claim a lane and work simultaneously
3. **Strategic tracking** — dashboard view showing progress, velocity, and investment per lane
4. **Autonomous research** — Pollard hunters discover new lanes from bead graph clustering and hunt within assigned lanes for opportunities

## Why This Approach

**Architecture: Lane as first-class kernel entity with label bridge**

Lanes are a new kernel concept in intercore (alongside runs, dispatches, and events). Beads are associated to lanes via `bd label lane:<name>`. The kernel reads labels to compute membership and maintains runtime state (progress snapshots, velocity, events). This gives us:

- Schema-validated lane definitions with typed fields (name, type, budget, owner, Pollard config)
- Native queries for cross-lane analytics without client-side recomputation
- Event integration so Autarch's aggregator can subscribe to lane state changes
- Pollard dispatch scoping via `scope_lane` field on dispatches
- Lane-level claiming for multi-agent coordination

**Why not beads-only:** Labels + bd state work for tagging but provide no runtime state machine. Cross-lane analytics require N queries + client-side computation. No event integration for Autarch.

**Why not specialized run type:** Runs have lifecycle semantics (phases, end states) that don't fit standing lanes. Overloading runs would confuse the mental model.

**Why not config file hybrid:** Adds sync complexity for marginal benefit. Auto-discovery + label tagging is sufficient for definitions; if manual definition becomes important, config can be added later.

## Key Decisions

- **Lane types:** Standing lanes (permanent themes like "interop", "kernel") and arcs (goal-driven temporary lanes like "ship interop v1" that close when all beads are done)
- **Lane definitions:** Auto-discovered from bead graph clustering (dependency chains, module tags, companion-graph edges) + user-curated via agent dialogue. Not purely manual.
- **State store:** Intercore kernel — new `lanes` table with schema-validated fields. Labels remain the bead↔lane association mechanism.
- **Pollard integration:** Two modes — (1) discover lane candidates by analyzing the full bead graph for clusters, (2) hunt within assigned lanes for research, opportunities, and missing beads
- **Autarch integration:** Lane progress bars on dashboard, lane-scoped views, event subscription via existing aggregator pattern
- **Sprint integration:** `/clavain:sprint` gains `--lane` flag to scope discovery to a lane. `/clavain:lane` command for lane management.

## Lane Lifecycle

### Standing Lanes
- Created once, persist indefinitely
- Beads flow in and out via labels
- Progress is measured as throughput (beads closed per week) not completion percentage
- Examples: interop, kernel, ux, research, infrastructure

### Arc Lanes
- Created for a specific goal with defined scope
- Has a target set of beads (can grow but has a "done when" condition)
- Progress is measured as completion percentage
- Closes when all member beads are closed (or manually retired)
- Examples: "ship interop v1", "E7 bigend migration", "tldrs compression sprint"

## Auto-Discovery

Pollard (or an on-demand discovery command) analyzes the bead graph to propose lane groupings:

1. **Module clustering** — beads sharing `[module]` tags in titles
2. **Dependency chains** — beads connected by blocks/blocked-by relationships
3. **Companion graph edges** — plugins with declared companions likely share a lane
4. **Roadmap groupings** — the NEXT_GROUPINGS from the roadmap already clusters P2 items thematically
5. **Label co-occurrence** — beads sharing existing labels suggest a theme

The agent proposes lane definitions, the user refines (add/remove beads, rename, set type). Once confirmed, labels are applied and the kernel lane is created.

## Resolved Questions

- **Budget semantics:** No lane-level budgets. Budgets stay at sprint level. Interstat can report per-lane spend for visibility without enforcement. Lanes are organizational, not fiscal.
- **Lane overlap:** Yes, multi-lane. A bead can carry multiple `lane:` labels. Progress counts toward all lanes it belongs to. Cross-cutting work is real and shouldn't be forced into a single category.
- **Starvation detection:** Relative velocity comparison. Compare each lane's recent throughput (beads closed per week) against other lanes, weighted by priority distribution. A lane with many high-priority unblocked beads but low throughput is starved. No manual targets needed.
- **Pollard scheduling:** Starvation-weighted. Pollard preferentially hunts in the most-starved lane, creating a natural balancing force — the less a lane gets worked, the more Pollard scouts for it. Falls back to round-robin when lanes are balanced.
