# Interject Integration Sweep

**Date:** 2026-02-15
**Status:** Brainstorm complete — ready for strategy

## What We're Building

A comprehensive integration layer connecting interject's ambient discovery engine to the rest of the Interverse ecosystem. Four workstreams:

1. **intersearch** — Extract shared search/adapter infrastructure (Exa, embeddings) into a reusable library
2. **Discovery → Action pipeline** — Route discoveries into the Clavain sprint workflow by confidence tier
3. **Feedback loop** — Close the learning loop with tool-time analytics, bead lifecycle tracking, and cross-session signals
4. **Internal awareness** — Connect interject to what's happening inside sessions (plans, active work, topics under discussion)

## Why This Approach

Interject currently operates as an island — it scans externally, creates beads and docs, but has no awareness of what happens next. The recommendation engine learns only from explicit promotion/dismissal. This leaves massive signal on the table:

- A discovered MCP server that gets installed and used in 5 sessions → no feedback
- A bead that goes from discovery → plan → execution → shipped → no feedback
- Two agents independently researching a topic that interject already found → no connection
- Both interject and interflux maintaining separate Exa adapters → duplicated infrastructure

The integration sweep turns interject from a standalone scanner into a **connected intelligence layer** for the ecosystem.

## Key Decisions

### 1. intersearch (shared adapter library)

- **Name:** `intersearch` (new Python package under `plugins/`)
- **What moves there:** Exa adapter (used by both interject and interflux), shared embedding client (used by interject and tldr-swinton)
- **Architecture:** Thin Python library, importable by any module. Not a plugin itself — no skills, hooks, or MCP server. Just a `pip install`-able package.
- **API surface:** `intersearch.exa.search()`, `intersearch.embeddings.embed()`, `intersearch.embeddings.cosine_similarity()`

### 2. Discovery → Action pipeline (tiered routing)

Three confidence tiers, three routing strategies:

| Tier | Score | Action |
|------|-------|--------|
| **High** | ≥ adaptive threshold | Auto-create brainstorm doc pre-seeded with discovery context, create bead, ready for `/clavain:sprint` |
| **Medium** | ≥ medium threshold | Accumulate into periodic digest. Surface in `/internext:next-work` triage alongside beads |
| **Low** | ≥ low threshold | Context injection only — when session topic overlaps, mention the discovery inline |

**High-tier auto-routing:** The output pipeline currently writes a generic plan template. Instead, it should write a brainstorm doc in the Clavain format (`docs/brainstorms/`) with the discovery pre-analyzed, so `/clavain:sprint` can pick it up directly.

**Medium-tier digest:** interject already creates briefings in `docs/research/`. Add a digest aggregation — weekly summary of medium-tier discoveries grouped by capability category, surfaced via internext.

**Low-tier context injection:** The session hook currently shows top discoveries. Enhance it to match discoveries against the *current session's topic* (inferred from recent tool calls or conversation context) rather than just showing highest-scoring items globally.

### 3. Feedback loop (closed-loop learning)

Three new signal sources:

**a) tool-time integration:**
- tool-time already tracks tool usage per session
- When a tool/library mentioned in an interject discovery appears in tool-time usage data → strong positive signal
- Implementation: periodic scan of tool-time's analytics output, match against discovery metadata

**b) Bead lifecycle tracking:**
- Currently: interject creates bead, records promotion. End of tracking.
- New: subscribe to bead state changes (via `bd` CLI queries or interphase phase tracking)
- Track full funnel: discovered → promoted → planned → executing → shipped
- Weight future scoring by conversion rate per source (e.g., "arXiv papers convert to shipped work 12% of the time vs HN at 3%")

**c) Cross-session pattern detection:**
- When interject's MCP tools are queried for a topic, record the query
- When multiple sessions query similar topics within a window → boost those topics in the interest profile
- Implementation: query log in SQLite, periodic clustering via embeddings

### 4. Internal awareness

Connect interject to internal ecosystem signals:

- **Active plans:** Read `docs/plans/` to know what's being worked on — avoid surfacing discoveries for already-solved problems
- **Beads state:** Query `bd list` to understand current work priorities — boost discoveries aligned with active P0/P1 beads
- **Plugin capabilities:** Already done (gap detection), but extend to track *requested* capabilities (from brainstorm docs, PRDs) not just *installed* capabilities
- **interwatch signals:** When interwatch detects doc drift, that's a signal about what changed — interject can use change vectors to adjust its scanning focus

## Open Questions

1. **intersearch scope:** Should intersearch include all 5 source adapters, or just the shared ones (Exa, embeddings)? Starting with just the shared infrastructure seems cleaner.
2. **Digest frequency:** Weekly? After every scan? On-demand only?
3. **Cross-session detection:** How to access tool-time data and session queries without coupling too tightly? MCP tool calls vs file-based data sharing?
4. **internext integration depth:** Should internext directly query interject's DB, or should interject push summaries to a shared format?

## Original Intent

The user identified four pain points, all selected:
- **Discovery → Action gap:** Briefings sit in docs/, beads need hand-triage
- **No feedback loop:** No signal when discovered tools get used or integrated
- **Siloed scanning:** No awareness of internal session activity
- **Duplicate infrastructure:** Exa and embedding code duplicated across modules

Trigger-to-feature mapping for future iterations:
- intersearch extraction → eliminates duplicate infrastructure
- Clavain sprint routing → closes discovery-to-action gap
- tool-time + bead lifecycle signals → closes feedback loop
- Plan/bead/session awareness → breaks scanning silo

---
*Generated during brainstorm session on 2026-02-15*
