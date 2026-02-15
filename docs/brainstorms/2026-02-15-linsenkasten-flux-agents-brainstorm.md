# Brainstorm: Linsenkasten Lenses as Flux-Drive Agents

**Date:** 2026-02-15
**Prompt:** Analyze the lenses in Linsenkasten to see if we can group them into flux-drive agents
**Status:** Draft

## Context

### What Linsenkasten Is
Linsenkasten is a cognitive augmentation system built around **288 analytical lenses** from the FLUX podcast. Each lens is a named perspective for viewing problems differently (e.g., "Kobayashi Maru" — rewriting constraints, "Steelmanning" — arguing the other side's best case). Lenses are organized into:

- **28 thematic frames** (overlapping clusters like "Balance & Paradox", "Systems Dynamics", "Trust & Collaboration")
- **A relationship graph** with weighted edges (contrast, synthesis, concept overlap, temporal adjacency)
- **15 MCP tools** for search, analysis, combination, path-finding, and gap detection

### What Flux-Drive Agents Are
Flux-drive is a multi-agent review system with 3 phases (Triage → Launch → Synthesize). Each agent is a Markdown file with YAML frontmatter defining a specialized reviewer. Currently 7 core review agents (architecture, safety, correctness, quality, user-product, performance, game-design) + 5 research agents. Agents are domain-aware and auto-detect language.

### The Question
Can the 28 thematic frames (or some grouping of them) become flux-drive agents that review documents/decisions through the lens of FLUX concepts?

## Analysis

### Frame Statistics

| Frame | Lens Count | Natural Agent? |
|-------|-----------|----------------|
| Transformation & Change | 44 | Yes — massive, could be 2 agents |
| Perception & Reality | 43 | Yes — cognitive bias / assumption review |
| Information Ecology | 37 | Yes — information flow / knowledge mgmt |
| Creative Problem Solving | 33 | Merge with Innovation |
| Learning & Adaptation | 29 | Yes — feedback loops / learning systems |
| Trust & Collaboration | 28 | Yes — team dynamics / trust review |
| Resilience & Adaptation | 25 | Yes — risk / resilience review |
| Leadership Dynamics | 23 | Merge with Power & Agency |
| Power & Agency | 21 | See above |
| Innovation & Creation | 20 | Merge with Creative Problem Solving |
| Balance & Paradox | 19 | Yes — tension / trade-off review |
| Boundaries & Constraints | 19 | Merge with Resource Dynamics |
| Communication & Dialogue | 19 | Yes — communication review |
| Time & Evolution | 19 | Merge with Temporal Dynamics |
| Navigating Uncertainty | 17 | Yes — uncertainty / decision review |
| Emergence & Complexity | 16 | Merge with Systems Dynamics |
| Knowledge & Sensemaking | 15 | Merge with Information Ecology |
| Digital Transformation | 14 | Too narrow for standalone |
| Crisis & Opportunity | 13 | Merge with Resilience |
| Core Systems Dynamics | 12 | See above |
| Strategic Decision Making | 11 | Merge with Navigating Uncertainty |
| Influence & Persuasion | 11 | Merge with Communication |
| Innovation & Creative Destruction | 10 | Merge with Innovation |
| Organizational Culture & Teams | 10 | Merge with Trust |
| Network & Social Systems | 9 | Merge with Influence |
| Resource Dynamics & Constraints | 8 | See above |
| Temporal Dynamics & Evolution | 7 | See above |
| Design & Detail | 4 | Too small for standalone |

### Key Insight: Frames ≠ Agents (but they inform agents)

The 28 frames have massive overlap (239 of 258 lenses appear in 2+ frames). Direct 1:1 mapping would create:
- Too many agents (28 exceeds flux-drive's slot ceiling of 12)
- Redundant analysis (same lens reviewed by 3-4 agents)
- Weak agents (some frames have only 4-8 lenses)

**Better approach:** Consolidate frames into **6-8 "lens agents"** — each with a distinct analytical mission that draws from multiple frames.

## Proposed Agent Groupings

### Group 1: `fd-lens-systems` — Systems Thinking & Dynamics
**Frames merged:** Core Systems Dynamics + Emergence & Complexity + part of Transformation
**Mission:** Review documents for systems thinking blind spots — missing feedback loops, ignored emergence, linear thinking where systems thinking is needed.
**Key lenses:** Systems Thinking, Compounding Loops, Behavior Over Time Graph, Simple Rules, Bullwhip Effect, Hysteresis, Causal Graph, Schelling Traps
**~28 lenses**

### Group 2: `fd-lens-decisions` — Decision Quality & Uncertainty
**Frames merged:** Strategic Decision Making + Navigating Uncertainty + Balance & Paradox
**Mission:** Review decisions and plans for cognitive traps — false certainty, missing scenario planning, unexamined paradoxes, premature commitment.
**Key lenses:** OODA Loop, Kobayashi Maru, Cone of Uncertainty, Scenario Planning, Sour Spots, Explore vs. Exploit, Dissolving the Problem, N-ply Thinking
**~35 lenses**

### Group 3: `fd-lens-trust` — Trust, Teams & Collaboration
**Frames merged:** Trust & Collaboration + Organizational Culture + Communication & Dialogue + part of Leadership
**Mission:** Review plans/docs for trust dynamics — fragile trust assumptions, missing psychological safety, communication breakdowns, collaboration anti-patterns.
**Key lenses:** Trust Thermoclines, Steelmanning, Trading Zones, Nemawashi, Super-Chicken, Tamagotchi Quality, Commitment Device, Conceptual Integrity
**~45 lenses**

### Group 4: `fd-lens-power` — Power, Agency & Influence
**Frames merged:** Power & Agency + Influence & Persuasion + Network & Social Systems + part of Leadership
**Mission:** Review for hidden power dynamics — who benefits, who loses agency, where are the chokepoints, what narratives are shaping the framing.
**Key lenses:** Eye of Sauron, Vetocracy, Controlling the Chokepoints, Reality Distortion Fields, Snarl Slogans, NPCs and Live Players, Memetic Hosting, Revealed Specialist
**~30 lenses**

### Group 5: `fd-lens-resilience` — Resilience, Risk & Adaptation
**Frames merged:** Resilience & Adaptation + Crisis & Opportunity + Resource Dynamics
**Mission:** Review for fragility and adaptability — missing crumple zones, over-optimization, unexamined dependencies, absent recovery paths.
**Key lenses:** Hormesis, Crumple Zones, Pace Layers, Hedgehog and Fox, Reversibility, Over-adaptation, Forest Debris, Dandelions and Elephants
**~35 lenses**

### Group 6: `fd-lens-innovation` — Innovation & Creative Problem Solving
**Frames merged:** Creative Problem Solving + Innovation & Creation + Innovation Ecosystems + Digital Transformation
**Mission:** Review for innovation health — whether the approach is genuinely novel or recycled, whether constraints are being used creatively, whether the adjacent possible is being explored.
**Key lenses:** Adjacent Possible, Composable Alphabets, Stepping Stones, Safe-to-Fail Experiments, Rock Tumbler, Crystallized Imagination, Whale Fall, Ruderal Species
**~45 lenses**

### Group 7: `fd-lens-perception` — Perception, Bias & Sensemaking
**Frames merged:** Perception & Reality + Knowledge & Sensemaking + Information Ecology
**Mission:** Review for perceptual blind spots — unexamined assumptions, missing perspectives, information asymmetry, confabulation, watermelon status reporting.
**Key lenses:** Blind Spots, Watermelon Status, Confabulation, Subject-Object Shift, Thinking Hat, Balcony and Dance Floor, Dowsing Rods, Activity Trap
**~55 lenses**

### Group 8: `fd-lens-evolution` — Time, Change & Transformation
**Frames merged:** Time & Evolution + Temporal Dynamics + Transformation & Change
**Mission:** Review for temporal blind spots — ignoring pace layers, assuming static equilibrium, missing path dependencies, underestimating transformation costs.
**Key lenses:** Pace Layers, Palimpsest, Fleet of Theseus, Kintsugi, Developmental Stages, Becoming a Butterfly Sucks, Theory of Change, Commitment
**~45 lenses**

## How This Differs from Standard Flux-Drive

Standard flux-drive agents review **code and technical artifacts**. These lens agents would review **strategy documents, PRDs, brainstorms, plans, and decisions** through analytical frameworks.

| Dimension | Standard fd-* agents | Proposed fd-lens-* agents |
|-----------|---------------------|--------------------------|
| Input | Code, configs, schemas | Documents, plans, strategies |
| Checks | Technical correctness | Thinking quality |
| Findings | "Missing error handling" | "Missing feedback loop analysis" |
| Severity | P0-P4 (bugs/risks) | "Blind spot" / "Missed lens" / "Assumption risk" |
| Output | Fix recommendations | Lens recommendations + questions to ask |

## Triage Strategy for Lens Agents

Not all 8 agents should run on every document. Triage signals:

| Agent | Trigger keywords/signals |
|-------|------------------------|
| fd-lens-systems | "architecture", "design", "system", "feedback", "loop", "emergent" |
| fd-lens-decisions | "decision", "plan", "strategy", "risk", "options", "trade-off" |
| fd-lens-trust | "team", "collaboration", "stakeholder", "communication", "culture" |
| fd-lens-power | "governance", "stakeholder", "authority", "influence", "narrative" |
| fd-lens-resilience | "risk", "failure", "recovery", "dependencies", "constraints" |
| fd-lens-innovation | "innovation", "creative", "novel", "disruption", "technology" |
| fd-lens-perception | "assumption", "perspective", "bias", "framing", "understanding" |
| fd-lens-evolution | "roadmap", "timeline", "migration", "transformation", "legacy" |

## Integration Options

### Option A: Domain Profile (lightest touch)
Create a `linsenkasten` domain profile in `config/flux-drive/domains/`. This injects lens-based review bullets into existing core agents. No new agents needed — existing fd-architecture gets "Check for systems thinking blind spots", fd-user-product gets "Check for trust dynamics in stakeholder analysis", etc.

**Pro:** Zero new agents, works with existing triage. **Con:** Shallow — bolting lens thinking onto code reviewers doesn't capture the depth of lens analysis.

### Option B: 8 New Agent Files (moderate)
Create 8 `fd-lens-*.md` agent files in `agents/review/`. Each follows the standard agent format. They'd be scored alongside existing agents during triage.

**Pro:** Deep lens analysis per domain. **Con:** 8 new agents could overwhelm the slot ceiling (max 12 total). Needs careful triage pre-filtering.

### Option C: Single Meta-Agent + Lens Router (creative)
One `fd-lens-analyst.md` agent that receives the document + a subset of relevant lenses (selected by keyword matching on the document). The agent applies 5-10 relevant lenses rather than all 288.

**Pro:** One slot, dynamic lens selection. **Con:** Less specialized — one agent doing 8 jobs. Prompt would be enormous.

### Option D: Parallel MCP Integration (most powerful)
Agents call Linsenkasten MCP tools during review — `search_lenses` to find relevant lenses for each finding, `detect_thinking_gaps` to find uncovered frames, `find_contrasting_lenses` for dialectical analysis.

**Pro:** Dynamic, draws from the full 288-lens catalog in real-time. **Con:** Requires MCP server running, adds latency, agents need MCP tool access.

### Recommended: Option B + D Hybrid
Create 4-5 focused agents (not all 8 — consolidate further), and give each agent access to Linsenkasten MCP tools for dynamic lens retrieval. The agent file defines the analytical mission; the MCP tools provide the specific lenses on demand.

**Consolidate to 5 agents:**
1. `fd-lens-systems` — systems thinking + emergence
2. `fd-lens-decisions` — decision quality + uncertainty + paradox
3. `fd-lens-people` — trust + power + communication + leadership (merge groups 3+4)
4. `fd-lens-resilience` — resilience + innovation + constraints (merge groups 5+6)
5. `fd-lens-perception` — perception + sensemaking + time + transformation (merge groups 7+8)

## Open Questions

1. **Should lens agents replace or complement existing fd-* agents for non-code documents?** Currently flux-drive is code-focused. Lens agents would extend it to strategy/planning documents.

2. **Should lens agents be in interflux or in Linsenkasten?** If they're generic thinking-quality reviewers, they belong in interflux. If they're tightly coupled to the Linsenkasten knowledge base, they belong there.

3. **MCP dependency:** If we go with Option D, the agents need the Linsenkasten MCP server running. Should there be a graceful fallback (hardcoded lens subsets) for when MCP is unavailable?

4. **Severity system:** Standard fd-* agents use P0-P4 for bugs. What's the equivalent for "you didn't consider this analytical perspective"? Options: "Blind Spot" (high), "Missed Lens" (medium), "Consider Also" (low).

5. **Frame overlap handling:** Since lenses appear in multiple frames, how do we prevent 3 agents all flagging the same lens? Deduplication in synthesis phase? Or strict frame-to-agent exclusion?

## Summary

The 28 Linsenkasten frames can be consolidated into **5 flux-drive agents** that review documents for thinking quality rather than code correctness. Combined with MCP tool access for dynamic lens retrieval, this creates a "cognitive review" capability alongside the existing technical review pipeline.

The recommended approach is **Option B+D (5 agent files + MCP integration)**, which gives each agent a focused analytical mission while leveraging the full 288-lens knowledge graph for specific recommendations.
