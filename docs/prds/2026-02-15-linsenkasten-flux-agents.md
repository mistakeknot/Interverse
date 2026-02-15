# PRD: Linsenkasten Flux-Drive Lens Agents

> **Revision 2** (post flux-drive review). Changes: phased delivery, renamed agents, fixed severity system, dropped F5, decoupled F0. See `docs/research/flux-drive/2026-02-15-linsenkasten-flux-agents/` for full review.

## Problem

Flux-drive reviews code and technical artifacts but has no capability for reviewing **thinking quality** in strategy documents, PRDs, brainstorms, and plans. The Linsenkasten project contains 288 analytical lenses organized into a knowledge graph — a rich cognitive toolkit that's currently only accessible through direct MCP tool calls, not through the structured review pipeline.

## Solution

Create specialized "lens agents" for flux-drive that review documents through FLUX analytical frameworks. Deliver in phases: Phase 0 validates the concept with 1 agent, Phase 1 scales to all agents with MCP integration. Separately, move Linsenkasten into the Interverse monorepo.

## Phased Delivery

### Phase 0: Prove It (MVP)
**Goal:** Validate that lens-based cognitive review produces actionable findings.
- F0: Move Linsenkasten into Interverse (independent, can happen first)
- F1: Create ONE agent (`fd-systems`) with hardcoded lenses (no MCP dependency)
- F2: Add basic triage pre-filter (exclude lens agents from code/diff reviews)
- Test on 3 recent Interverse documents (PRD, brainstorm, architecture doc)
- **Success gate:** At least 2/3 test runs produce findings the author says they'd act on

### Phase 1: Scale It (if Phase 0 succeeds)
- F1b: Add remaining 4 agents (`fd-decisions`, `fd-people`, `fd-resilience`, `fd-perception`)
- F3: Wire Linsenkasten MCP integration for dynamic lens retrieval
- F4: Define severity mapping and synthesis deduplication

### Phase 2: Systematize It (future)
- Full triage keyword scoring (not just pre-filter)
- Synthesis split sections (cognitive vs technical findings)
- Conflict detection between lens agents and core agents

## Features

### F0: Move Linsenkasten into Interverse
**What:** Migrate the Linsenkasten monorepo (`apps/api`, `apps/web`, `packages/mcp`) into `Interverse/plugins/linsenkasten/` with its own `.git`, following the same pattern as other subprojects.
**Phase:** Independent (can be done in parallel with F1)
**Acceptance criteria:**
- [ ] Linsenkasten lives at `plugins/linsenkasten/` with its own `.git`
- [ ] Compat symlink at `/root/projects/Linsenkasten` points into Interverse
- [ ] `CLAUDE.md` updated with linsenkasten entry in structure table
- [ ] All existing Linsenkasten functionality works (MCP server, API, web)
- [ ] GitHub remote preserved (origin → `mistakeknot/Linsenkasten`)

### F1: Create fd-systems Agent (Phase 0 MVP)
**What:** Create `fd-systems.md` in `plugins/interflux/agents/review/`, following the standard flux-drive agent format. This is the first lens agent — validates the concept before building the other 4.
**Acceptance criteria:**
- [ ] YAML frontmatter with `name: fd-systems`, `description` (one-sentence summary + 2-3 `<example>` blocks with Context/user/assistant/`<commentary>` structure matching existing agent format), `model: sonnet`
- [ ] Mandatory First Step (read CLAUDE.md/AGENTS.md for codebase-aware mode)
- [ ] 3-5 Review Approach sections covering: feedback loops, emergence patterns, systems dynamics, causal reasoning, unintended consequences
- [ ] 8-12 key lenses listed with 1-sentence definitions (curated from Systems Dynamics + Emergence + Resilience frames: Systems Thinking, Compounding Loops, Behavior Over Time Graph, Simple Rules, Bullwhip Effect, Hysteresis, Causal Graph, Schelling Traps, Crumple Zones, Pace Layers, Hormesis, Over-adaptation)
- [ ] Uses standard P0-P3 severities in findings output (NOT custom labels). Agent prompt includes cognitive severity guidance: "Blind Spot" (frame entirely absent, critical gap → P1), "Missed Lens" (relevant frame underexplored → P2), "Consider Also" (enrichment opportunity → P3)
- [ ] "What NOT to Flag" section: no technical implementation details (defer to fd-architecture/fd-correctness), no code style (defer to fd-quality), no lenses from other cognitive domains (strict separation)
- [ ] Structural validation: agent file has `---` frontmatter delimiters, `## First Step`, `## Review Approach`, and `## What NOT to Flag` sections
- [ ] Key lens selection documented in agent file comment: rationale for why these 12 out of 288

### F1b: Create Remaining 4 Agents (Phase 1)
**What:** Create `fd-decisions.md`, `fd-people.md`, `fd-resilience.md`, `fd-perception.md` — same format as fd-systems.
**Blocked by:** Phase 0 success gate
**Acceptance criteria:**
- [ ] Same structural requirements as F1
- [ ] Each agent covers its consolidated frame domain:
  - `fd-decisions`: Decision quality + uncertainty + paradox + strategic thinking
  - `fd-people`: Trust + power + communication + leadership + collaboration
  - `fd-resilience`: Resilience + innovation + constraints + creative problem solving
  - `fd-perception`: Perception + sensemaking + time + transformation + information ecology
- [ ] `ls agents/review/*.md | wc -l` returns 12 (7 existing + 5 new)
- [ ] No lens overlap between agents (each lens appears in exactly one agent's key list)

### F2: Triage Pre-filter (Phase 0)
**What:** Add pre-filter rules to flux-drive triage that exclude lens agents from code/diff reviews and include them for document reviews.
**Acceptance criteria:**
- [ ] Pre-filter rules (applied before scoring, agent never appears in roster):
  - `INPUT_TYPE=diff` → exclude all `fd-systems`/`fd-decisions`/etc. agents
  - `INPUT_TYPE=file` AND file extension in `.go .py .ts .tsx .rs .sh .c .java .rb` → exclude lens agents
  - `INPUT_TYPE=file` AND file extension in `.md .txt` → score lens agents normally
  - `INPUT_TYPE=directory` → score lens agents normally
- [ ] When lens agents pass pre-filter, score using standard base_score (2 for documents mentioning systems/feedback/loops, 3 for architecture docs and strategy docs)
- [ ] Lens agents report as category "cognitive" in triage table (distinct from technical agents)

### F3: Linsenkasten MCP Wiring (Phase 1)
**What:** Configure interflux to reference Linsenkasten MCP tools so lens agents can call `search_lenses`, `detect_thinking_gaps`, `find_contrasting_lenses` during review.
**Blocked by:** Phase 0 success gate
**Acceptance criteria:**
- [ ] Lens agent prompts include conditional instructions: "If linsenkasten-mcp tools are available (check via ToolSearch), call search_lenses/detect_thinking_gaps; otherwise use the hardcoded key lenses listed above"
- [ ] `search_lenses` used to find relevant lenses for each section of the document
- [ ] `detect_thinking_gaps` used at end of review to identify uncovered frames
- [ ] When MCP is unavailable, agent includes a NOTE finding: "MCP server unavailable — review used fallback lens subset (12/288 lenses). Install linsenkasten-mcp for full coverage."
- [ ] No hard dependency — MCP enriches but doesn't gate the review

### F4: Severity Guidance and Deduplication (Phase 1)
**What:** Formalize the cognitive severity mapping in agent prompts and add lens-aware deduplication to synthesis.
**Blocked by:** Phase 0 success gate + F1b (multiple agents needed for deduplication)
**Acceptance criteria:**
- [ ] Agents use standard P0-P3 in output. Cognitive severity guidance (Blind Spot/Missed Lens/Consider Also) is a prompt-level heuristic, NOT an output format
- [ ] Synthesis deduplicates lens findings across agents by `(lens_name, section, reasoning_category)` — same lens but different concerns kept as separate findings
- [ ] Verdict computation treats cognitive P1/P2/P3 identically to technical P1/P2/P3

## Design Decisions (Resolved)

1. **Model choice:** Sonnet for all lens agents. Cognitive gap detection requires nuanced interpretation — haiku would produce shallow findings.
2. **Agent location:** Lens agents live in `interflux/agents/review/`, not linsenkasten. They are review pipeline components, not MCP tools. Linsenkasten provides the knowledge base; interflux orchestrates the review.
3. **Naming convention:** `fd-systems`, `fd-decisions`, `fd-people`, `fd-resilience`, `fd-perception` — following the `fd-{domain}` pattern (no `lens-` prefix). The frontmatter description disambiguates purpose.

## Non-goals

- **Modifying the Linsenkasten API or web app** — we're consumers, not changing the source
- **Replacing core fd-* agents** — lens agents complement, not replace, technical review
- **Auto-generating agents from frames** — we manually curate agents based on frame consolidation analysis
- **Making lens agents work on code** — they review documents only
- **Domain profile for linsenkasten** — lens agents are cross-domain (apply to all document reviews), not project-domain-specific. Domain profiles are for project-specific agent generation.
- **"Questions to ask" field** — deferred to post-Phase 1 feedback. Lens findings use standard prose sections for now.

## Dependencies

- Linsenkasten MCP server (`packages/mcp`) must be runnable (for Phase 1 F3)
- Flux-drive spec 1.0.0 scoring algorithm (for F2 triage changes)
- Interflux plugin structure and agent format conventions
- Thematic frames data (`lens_frames_thematic.json`) for key lens curation

## Risks

1. **Demand risk (Phase 0 mitigates):** No validated user demand for cognitive review. Phase 0's success gate catches this before scaling.
2. **Actionability risk:** FLUX lenses are descriptive frameworks — findings could be "interesting but not actionable." Agent prompts must include concrete questions, not just "consider this lens."
3. **Cognitive overload risk (Phase 2 addresses):** Mixing technical and cognitive findings in synthesis may overwhelm users. Phase 2 adds synthesis split sections.
