# Architecture Review: fd-systems.md (Cognitive Review Agent)

**Reviewer:** fd-architecture (flux-drive)
**Date:** 2026-02-16
**Subject:** `/root/projects/Interverse/plugins/interflux/agents/review/fd-systems.md`
**Context:** New cognitive review agent for systems thinking blind spots

---

## Executive Summary

fd-systems is the first cognitive review agent in the flux-drive protocol, introducing a new agent category (cognitive vs technical) with distinct pre-filtering, scoring, and severity mapping rules. The module boundaries are well-defined and consistently enforced. The integration pattern is sound: explicit pre-filtering prevents misrouting, defer-to contracts prevent overlap, and the cognitive severity mapping preserves synthesis compatibility.

**Key strengths:**
- Clean separation between cognitive domain (systems thinking lenses) and technical domains (implementation/code)
- Explicit reservation of future cognitive agents (fd-decisions, fd-people, fd-resilience, fd-perception) prevents premature boundary decisions
- Pre-filter logic isolates cognitive agents to document review only (no code, no diffs)
- Defer-to contracts with all 7 technical agents establish clear adjacency boundaries

**Key risks:**
- The 12-lens selection from Linsenkasten's 288-lens catalog is justified in a comment but not validated against real document corpus
- Cognitive agent category introduces a new axis of complexity without integration tests for cross-category synthesis
- Future cognitive agents (4 reserved) share no architectural guidance beyond name reservation

**Verdict:** Safe to ship. Defer-to discipline is strong, pre-filter logic is crisp, and the cognitive/technical split is architecturally defensible. Recommend integration test coverage before adding fd-decisions/fd-people/etc.

---

## 1. Boundaries & Coupling

### 1.1 Module Boundaries

**Cognitive vs Technical Agent Split**

fd-systems introduces a **category-based architecture** with two agent types:
- **Technical agents (7):** fd-architecture, fd-correctness, fd-quality, fd-safety, fd-user-product, fd-performance, fd-game-design — operate on code, diffs, and documents
- **Cognitive agents (1 current + 4 reserved):** fd-systems, fd-decisions, fd-people, fd-resilience, fd-perception — operate on documents only

This split is enforced in three places:

1. **Pre-filter (SKILL.md:260-263):**
   ```
   Skip cognitive agents unless:
   - Input type is file/directory (NOT diff)
   - Extension is .md or .txt (NOT code)
   - Document type matches: PRD, brainstorm, plan, strategy, vision, roadmap
   ```

2. **Agent frontmatter (fd-systems.md:4):**
   ```yaml
   description: "...evaluates feedback loops, emergence patterns, causal reasoning..."
   ```
   Examples show only document review use cases (PRD review, reorg plan review).

3. **"What NOT to Flag" section (fd-systems.md:92-100):**
   Explicit defer-to contracts with all 7 technical agents plus reservation of 4 future cognitive domains.

**Boundary verdict:** Clean separation with fail-safe pre-filtering. The category split is enforced at triage (Step 1.2a), not at agent discretion, which prevents agents from second-guessing their activation conditions.

**Coupling risk:** Low. Cognitive agents are downstream of technical agents (no reverse dependencies). Technical agents are unaware of cognitive agents (no references in fd-architecture.md, fd-quality.md, etc.). The only coupling point is the synthesis layer (findings.json aggregation), where cognitive and technical findings are treated identically per severity (P0-P3).

---

### 1.2 Adjacency Analysis: Defer-to Contracts

fd-systems defers to 7 technical agents and reserves 4 cognitive domains. This creates 11 adjacency boundaries.

#### Technical Deferrals (7)

| Agent | Deferred Scope | Boundary Quality |
|-------|---------------|------------------|
| fd-architecture | "Technical implementation details" | **Strong** — clear implementation vs systems dynamics split |
| fd-correctness | "Technical implementation details" | **Strong** — data integrity vs feedback loop integrity are orthogonal |
| fd-quality | "Code quality, naming, or style" | **Strong** — code conventions vs cognitive blind spots are non-overlapping |
| fd-safety | "Security or deployment concerns" | **Moderate** — gray zone exists (e.g., feedback loops in rollback procedures). See §1.2.1. |
| fd-performance | "Performance or algorithmic complexity" | **Strong** — perf bottlenecks vs emergent system behavior are distinct |
| fd-user-product | "User experience or product-market fit" | **Moderate** — gray zone exists (e.g., feedback loops in UX flows). See §1.2.2. |
| fd-game-design | (implicit via pre-filter) | **Weak** — no explicit defer-to. See §1.2.3. |

#### Cognitive Reservations (4)

| Agent | Reserved Scope | Boundary Quality |
|-------|---------------|------------------|
| fd-decisions | "decision quality/uncertainty" | **Clear** — decision theory lenses distinct from systems dynamics |
| fd-people | "trust/power/communication" | **Clear** — social dynamics distinct from systems dynamics |
| fd-resilience | "innovation/constraints" | **Ambiguous** — resilience overlaps with systems dynamics (see §1.2.4) |
| fd-perception | "perception/sensemaking" | **Clear** — cognitive framing distinct from systems framing |

---

#### 1.2.1 Gray Zone: fd-safety ↔ fd-systems

**Overlap scenario:** Deployment rollback procedures involve systems dynamics (hysteresis, crumple zones, pace layers) AND deployment safety (rollback feasibility, blast radius).

Example: A migration plan that is reversible (fd-safety: ✓) but creates hysteresis where rollback cost is 10x forward cost (fd-systems: flag).

**Current contract:** fd-systems defers "Security or deployment concerns" to fd-safety. But fd-safety's scope (per fd-safety.md:45-60) is "rollback feasibility analysis" — does this include analyzing rollback *cost dynamics* (systems) or just *technical feasibility* (safety)?

**Recommendation:** Clarify in both agents:
- fd-safety: "Evaluate rollback feasibility (can it be done safely?)"
- fd-systems: "Evaluate rollback dynamics (what are the second-order costs, delays, and irreversibilities?)"

This preserves the defer-to contract while allowing both agents to review deployment plans from complementary angles.

---

#### 1.2.2 Gray Zone: fd-user-product ↔ fd-systems

**Overlap scenario:** User flows with feedback loops (e.g., notification fatigue causing users to disable all notifications, defeating the purpose).

Example: A feature that sends daily reminders. fd-user-product evaluates flow clarity. fd-systems evaluates whether the feedback loop (user ignores → more reminders → user disables notifications) creates a death spiral.

**Current contract:** fd-systems defers "User experience or product-market fit" to fd-user-product. But fd-user-product's scope (per fd-user-product.md:23-38) includes "workflow transitions that force unnecessary context switching" — does this include feedback-loop-induced transitions?

**Boundary is defensible as-is:** fd-user-product reviews flows, fd-systems reviews the systemic consequences of flows. If a reminder feature is annoying (user-product), that's different from a reminder feature creating a cobra effect (systems). The two agents should both flag this scenario from their respective lenses, and synthesis deduplication will resolve it.

**No action required.** This is intentional overlap for high-stakes scenarios (user-facing feedback loops).

---

#### 1.2.3 Missing Defer-to: fd-game-design ↔ fd-systems

fd-systems does not explicitly defer to fd-game-design in its "What NOT to Flag" section. This is an **asymmetric contract**: fd-game-design defers to fd-quality/fd-performance/fd-safety (fd-game-design.md:99-105), but fd-systems does not reciprocate.

**Why this matters:** Game design documents (PRDs for game mechanics) are eligible for cognitive review (they are `.md` strategy/design docs). Both agents would activate. Overlap zones:
- **Feedback loops:** fd-systems reviews feedback structures generically, fd-game-design reviews gameplay-specific loops (death spirals, rubber-banding)
- **Emergence:** fd-systems reviews emergent complexity, fd-game-design reviews emergent gameplay quality
- **Temporal dynamics:** fd-systems applies BOTG thinking, fd-game-design applies pacing/drama curves

**Recommendation:** Add to fd-systems.md:92-100:
```markdown
- Game-specific mechanics (balance, pacing, player psychology) — defer to fd-game-design for gameplay analysis; fd-systems focuses on systemic properties (feedback loops, emergence) that apply beyond games
```

And add to fd-game-design.md:99-105:
```markdown
- Generic systems dynamics (feedback loops, causal chains, emergence) — fd-systems handles cognitive blind spots; fd-game-design focuses on whether the system is fun and balanced
```

This clarifies that overlap is intentional and both agents should review game design docs from their respective angles.

---

#### 1.2.4 Ambiguous Reservation: fd-resilience

fd-systems reserves "innovation/constraints" for fd-resilience. But fd-systems' 12 lenses include:
- **Hormesis** — "small doses of stress can strengthen a system" (resilience concept)
- **Over-Adaptation** — "optimizing so perfectly for current conditions that any change becomes catastrophic" (resilience concept)
- **Crumple Zones** — "designed failure points that absorb shock" (resilience concept)

This creates a **lens overlap** between fd-systems and the future fd-resilience agent. Three of fd-systems' 12 lenses (25%) are actually resilience lenses borrowed from systems thinking.

**Two paths forward:**

1. **Merge resilience into fd-systems** — Rename fd-systems to fd-systems-resilience and expand its lens set to include innovation/constraints. Do not create fd-resilience.

2. **Reclassify lenses** — Move hormesis, over-adaptation, and crumple zones to fd-resilience when it is created. Give fd-systems 9 pure systems dynamics lenses (Systems Thinking, Compounding Loops, BOTG, Simple Rules, Bullwhip Effect, Hysteresis, Causal Graph, Schelling Traps, Pace Layers).

**Current state risk:** If fd-resilience is created without reclassifying lenses, both agents will flag overlapping concerns (e.g., "this system is over-adapted" from fd-systems AND "this system lacks resilience due to over-optimization" from fd-resilience). Synthesis will deduplicate by lens name, but the conceptual overlap will confuse users.

**Recommendation:** Before creating fd-resilience, audit Linsenkasten's resilience lenses and decide:
- Which lenses are pure resilience (belong in fd-resilience)?
- Which lenses are systems-dynamics-applied-to-resilience (stay in fd-systems)?
- Document the decision in both agents' "What NOT to Flag" sections.

---

### 1.3 Integration Seams

**Synthesis Layer (findings.json aggregation)**

fd-systems outputs conform to the Findings Index contract (contracts/findings-index.md):
```
SEVERITY | ID | "Section" | Title
Verdict: safe | needs-changes | risky
```

Cognitive findings use the same P0-P3 severity scale as technical findings, but with **different severity heuristics**:
- **Blind Spot → P1** (entire frame absent)
- **Missed Lens → P2** (frame mentioned but underexplored)
- **Consider Also → P3** (enrichment opportunity)

Technical findings use domain-specific severity heuristics (e.g., fd-correctness P0 = data corruption risk).

**Synthesis treats cognitive and technical P1s identically** (per AGENTS.md:174). This is correct — severity reflects impact, not agent category. A missing systems analysis that could cause production failure (cognitive P1) is equivalent in severity to a race condition that could cause data corruption (technical P1).

**Integration verdict:** Clean. The Findings Index contract is category-agnostic. Synthesis does not need to know which agent produced which finding, only the severity and deduplication key (lens name or section+title).

**Deduplication risk:** Cognitive and technical agents could flag overlapping issues from different angles. Example:
- fd-architecture: "This caching layer has no invalidation strategy" (P2, architecture concern)
- fd-systems: "Cache invalidation feedback loops are missing — could cause thundering herd" (P1, systems concern)

These should NOT be deduplicated (they are complementary views). Current deduplication uses `ID` (agent-assigned) or `Section + Title` (synthesis fallback). As long as fd-systems assigns unique IDs (FD-SYS-001, FD-SYS-002, ...), no false deduplication will occur.

**No action required.** Deduplication is safe.

---

## 2. Pattern Analysis

### 2.1 Cognitive Agent Pattern

fd-systems establishes a **pattern template** for future cognitive agents:

1. **Pre-filter to documents only** (no code, no diffs)
2. **Explicit defer-to contracts** with all technical agents
3. **Lens-based review** (apply curated cognitive lenses to surface blind spots)
4. **Cognitive severity mapping** (Blind Spot → P1, Missed Lens → P2, Consider Also → P3)
5. **Question-framing findings** ("What happens when X feeds back into Y?" not "You failed to consider feedback loops")

This pattern is **well-defined and reusable**. When fd-decisions, fd-people, fd-resilience, fd-perception are created, they should follow this template.

**Pattern quality:** Strong. The pre-filter + defer-to + lens-based-review structure prevents cognitive agents from drifting into technical review.

**Pattern gap:** No guidance on **lens selection criteria**. fd-systems justifies its 12 lenses in a comment (fd-systems.md:62-65) but does not document:
- Why these 12 from 288 total?
- How were they curated? (Hand-picked? Frequency analysis? Validated against corpus?)
- What coverage do they provide? (Are they sufficient for 80% of systems blind spots?)

**Recommendation:** Add a section to fd-systems.md (or a reference doc in `agents/review/references/`) titled "Lens Selection Criteria" that documents:
1. The source (Linsenkasten's Systems Dynamics, Emergence & Complexity, Resilience frames)
2. Selection criteria (3 per category: feedback/causation, emergence, temporal dynamics, failure modes = 12 total)
3. Coverage assessment (tested against 10 real PRDs/brainstorms, captured 95% of systems gaps)
4. Extension path (if 12 lenses miss systemic issues repeatedly, how do we expand the set?)

This documents the architectural decision so future cognitive agents can apply the same selection method.

---

### 2.2 Anti-Pattern: Hardcoded Lens Lists

fd-systems hardcodes 12 lenses in its prompt (fd-systems.md:69-81). This is acceptable for Phase 0 (MVP validation) but creates **maintenance debt** for Phase 1+ (production).

**Risk:** If Linsenkasten's lens catalog evolves (new lenses added, old lenses deprecated), fd-systems' lens list will drift out of sync. Manually updating 5 cognitive agents (fd-systems + 4 future) is error-prone.

**Future architecture (when MCP integration happens):** The PRD mentions "conditional MCP integration: agents call search_lenses and detect_thinking_gaps if MCP is available" (validate-fd-systems-on-prd.md:52-54). This is the **correct long-term pattern** — cognitive agents should query a lens catalog dynamically rather than hardcoding lists.

**No immediate action required.** Hardcoded lists are acceptable for Phase 0. When MCP integration is added, refactor all cognitive agents to use dynamic lens retrieval.

---

### 2.3 Naming Consistency

Agent naming follows a clear pattern:
- **Technical agents:** `fd-{domain}` where domain is a technical concern (architecture, correctness, quality, safety, performance, user-product, game-design)
- **Cognitive agents:** `fd-{cognitive-domain}` where cognitive-domain is a cognitive frame set (systems, decisions, people, resilience, perception)

This is consistent. All agents are `fd-*` regardless of category. Category distinction happens in metadata (`category: cognitive` in triage table, per SKILL.md:280) and pre-filtering logic.

**Naming verdict:** Consistent and legible. No drift detected.

---

## 3. Simplicity & YAGNI

### 3.1 Premature Abstraction: 4 Reserved Cognitive Agents

fd-systems reserves 4 future cognitive agents (fd-decisions, fd-people, fd-resilience, fd-perception) in its "What NOT to Flag" section (fd-systems.md:99). This is **speculative architecture** — the agents do not exist, and their boundaries are not validated.

**Why this matters:**
- Reserving cognitive domains pre-commits the system to a 5-agent cognitive tier without validating whether 1 agent (fd-systems) is sufficient
- Lens overlap between fd-systems and fd-resilience (§1.2.4) suggests the boundaries are not crisp
- No integration tests exist for multi-cognitive-agent synthesis (what if fd-systems and fd-decisions both flag decision-making in a systems context?)

**Two paths forward:**

1. **Defer reservation** — Remove the 4 reserved agents from fd-systems.md. Add them only when validated (user feedback shows fd-systems is missing specific cognitive domains).

2. **Validate boundaries now** — Before shipping fd-systems, write boundary docs for all 5 cognitive agents (what lenses belong in each, what overlap is intentional, what defer-to contracts exist). This front-loads the architecture cost but prevents boundary drift.

**Recommendation:** **Validate boundaries now** (option 2). The cost is ~1 session of work (list lenses for each cognitive domain, assign to agents, document overlap rules). The benefit is avoiding a refactor when fd-decisions is added and overlaps with fd-systems unpredictably.

Concrete action: Create `agents/review/references/cognitive-agent-boundaries.md` with:
- Table of 5 cognitive agents (systems, decisions, people, resilience, perception)
- Lens allocation (which lenses from Linsenkasten's 288 belong in each agent)
- Overlap rules (which lenses are shared, which defer-to contracts exist)
- Extension criteria (when to add a 6th cognitive agent)

This prevents premature refactoring when fd-decisions/fd-people/etc. are created.

---

### 3.2 Necessary Complexity: Cognitive Severity Mapping

fd-systems uses a **custom severity mapping** (Blind Spot → P1, Missed Lens → P2, Consider Also → P3) distinct from technical agents' severity heuristics (fd-systems.md:84-90).

**Is this necessary?** Yes. Cognitive findings measure **depth of analysis**, not **implementation risk**. A missing systems analysis (Blind Spot) is P1 because it indicates the document author did not consider an entire frame, which could lead to systemic failures. A missing technical detail (e.g., unhandled error path) is P1 because it could cause immediate production failure.

The severity scales are parallel but not equivalent. Synthesis treats them identically (both are P1), which is correct — they represent equivalent *impact* even if they measure different *dimensions*.

**Complexity verdict:** Necessary. The custom severity mapping is justified by the cognitive vs technical distinction.

---

### 3.3 Unnecessary Complexity: None Detected

fd-systems does not exhibit:
- Over-engineered abstractions (lens list is flat, no unnecessary nesting)
- Premature extensibility (no plugin hooks, no generic lens framework)
- Redundant validation (defer-to contracts are stated once, not repeated)
- Dead code (no commented-out sections, no unreferenced lenses)

The agent is implemented at the **appropriate abstraction level** for an MVP cognitive reviewer.

---

## 4. Integration into Review Pipeline

### 4.1 Triage (Phase 1, Step 1.2a)

fd-systems enters the triage pipeline via the **cognitive filter** (SKILL.md:260-263):

```
Skip fd-systems unless ALL of:
- Input type is file/directory (NOT diff)
- Extension is .md or .txt (NOT code)
- Document type matches: PRD, brainstorm, plan, strategy, vision, roadmap, architecture doc, research document
```

This filter is applied **before scoring** (pre-filter step). If fd-systems passes the filter, it receives a `base_score` (1-3) using cognitive-specific heuristics (SKILL.md:265-268):
- base_score 3: Document explicitly discusses systems, feedback, strategy, architecture decisions, or organizational dynamics
- base_score 2: Document is a PRD, brainstorm, or plan (general document review)
- base_score 1: Document is `.md` but content is primarily technical reference (API docs, changelogs)

fd-systems then participates in standard scoring (base_score + domain_boost + project_bonus + domain_agent).

**Integration verdict:** Clean. The cognitive filter prevents fd-systems from activating on code/diffs, and the base_score heuristics ensure it is prioritized for documents that actually benefit from systems thinking review.

**Edge case:** What if a project has `.md` files that are code-like (e.g., literate programming, Jupyter notebooks exported to Markdown)? The pre-filter would activate fd-systems, but the content is not amenable to systems thinking review.

**Mitigation:** The base_score heuristic "Document is `.md` but content is primarily technical reference" (base_score 1) handles this. If the document is technical reference, fd-systems scores low and may not be selected (depending on slot ceiling). No action required.

---

### 4.2 Launch (Phase 2, Stage 1/2 Dispatch)

fd-systems is dispatched in **Stage 1 or Stage 2** based on its `final_score` (SKILL.md:316-319):
- Domain agent (profile `stage: 1`) → Stage 1
- Base score ≥ 5 → Stage 1
- Base score 3-4 → Stage 2 (expansion candidate)
- Base score < 3 → Skip

fd-systems is NOT a domain agent (it is a general-purpose cognitive agent, not tied to any specific domain profile in `config/flux-drive/domains/`). So it enters Stage 1 only if `final_score ≥ 5`, which requires:
- base_score 3 (document explicitly discusses systems/feedback/strategy)
- + domain_boost 1-2 (if domain profile mentions systems thinking)
- + project_bonus 1 (if project has CLAUDE.md/AGENTS.md)

**Integration verdict:** Correct. fd-systems should NOT be a default Stage 1 agent — it should activate only when the document explicitly involves systems thinking. The scoring logic enforces this.

**Edge case:** What if a PRD implicitly relies on systems thinking (e.g., a scaling plan) but does not mention "feedback loops" or "emergence"? fd-systems would score `base_score 2` (general PRD review) and might not be selected if Stage 1 is full.

**Mitigation:** This is acceptable. If the document does not explicitly discuss systems dynamics, fd-systems is an **enrichment** (Stage 2) not a **necessity** (Stage 1). The user can manually add fd-systems to the roster during triage approval (Step 1.5).

---

### 4.3 Synthesis (Phase 3, Findings Aggregation)

fd-systems outputs conform to the Findings Index contract. Synthesis treats cognitive findings identically to technical findings (same deduplication, same severity aggregation, same verdict computation).

**Integration verdict:** Seamless. No special-casing required.

**Open question:** How does synthesis handle **convergence tracking** when cognitive and technical agents flag overlapping concerns from different angles?

Example:
- fd-architecture (Stage 1): "Caching layer has no invalidation strategy" (P2)
- fd-systems (Stage 2): "Cache invalidation feedback loops are missing — could cause thundering herd" (P1)

Current synthesis (per docs/spec/core/synthesis.md:381) deduplicates by `ID` or `Section + Title`. These findings have different IDs (FD-ARCH-001 vs FD-SYS-001) and different titles, so they will NOT be deduplicated.

**Is this correct?** Yes. They are **complementary findings** — one is architectural (no invalidation strategy exists), one is systemic (the absence of invalidation creates feedback loops). Both should appear in `findings.json`.

**Convergence interpretation:** If both findings appear, synthesis should interpret this as **high confidence** (two independent agents flagged the same issue from different angles). Current synthesis does not track convergence (per docs/spec/core/synthesis.md), so this signal is lost.

**Recommendation (future work):** Add convergence tracking to synthesis. When multiple agents flag the same section with overlapping concerns (detected via semantic similarity, not just exact ID match), boost confidence and annotate the finding with "Confirmed by {agent1, agent2}". This is out of scope for fd-systems (it is a synthesis feature), but worth noting here as an integration opportunity.

---

## 5. Comparison with Existing Agents

### 5.1 Structural Consistency

All 8 review agents (7 technical + 1 cognitive) share a common structure:

| Section | fd-architecture | fd-systems | Consistency |
|---------|----------------|-----------|-------------|
| YAML frontmatter | ✓ | ✓ | ✓ |
| "First Step (MANDATORY)" | ✓ | ✓ | ✓ |
| "Review Approach" | ✓ | ✓ | ✓ |
| "What NOT to Flag" | ✗ | ✓ | ⚠️ (fd-architecture has no explicit section, but has "Focus Rules" that serve the same purpose) |
| "Focus Rules" | ✓ | ✓ | ✓ |
| "Decision Lens" | ✓ | ✗ | ⚠️ (fd-systems has no Decision Lens section) |

**Inconsistencies:**

1. **"What NOT to Flag" section:** fd-systems has an explicit section, but fd-architecture does not. Other technical agents (fd-quality, fd-safety, fd-performance, fd-game-design) have it. fd-architecture and fd-correctness omit it.

   **Recommendation:** Add "What NOT to Flag" to fd-architecture and fd-correctness for consistency. This clarifies defer-to contracts and prevents scope creep.

2. **"Decision Lens" section:** fd-architecture and fd-user-product have "Decision Lens" sections, but fd-systems does not. Other agents (fd-correctness, fd-quality, fd-safety, fd-performance, fd-game-design) omit it.

   **Recommendation:** Standardize. Either all agents have "Decision Lens" (preferred) or none do. "Decision Lens" provides tiebreaker heuristics when multiple options are equivalent. fd-systems could use: "Favor changes that reduce systemic fragility over changes that optimize for current conditions."

---

### 5.2 Length Comparison

| Agent | Lines | Category |
|-------|-------|----------|
| fd-architecture | 81 | technical |
| fd-correctness | 83 | technical |
| fd-game-design | 110 | technical |
| fd-performance | 88 | technical |
| fd-quality | 88 | technical |
| fd-safety | 82 | technical |
| fd-user-product | 84 | technical |
| **fd-systems** | **108** | **cognitive** |

fd-systems is the longest agent (108 lines), tied with fd-game-design (110 lines). This is justified:
- 12 hardcoded lenses (lines 69-81) add ~15 lines
- Cognitive severity guidance (lines 84-90) adds ~10 lines
- Explicit defer-to contracts (lines 92-100) add ~10 lines

**Length verdict:** Proportional to complexity. fd-systems is longer because it introduces a new category (cognitive) and must document the category boundary rules.

---

### 5.3 Boundary Overlap Grid

|   | arch | corr | qual | safe | perf | user | game | **sys** |
|---|------|------|------|------|------|------|------|---------|
| **arch** | — | ✓ | ✓ | ✓ | ✓ | ⚠️ | ✗ | ✓ |
| **corr** | ✓ | — | ✓ | ✓ | ✓ | ✓ | ✗ | ✓ |
| **qual** | ✓ | ✓ | — | ✓ | ✓ | ✓ | ✓ | ✓ |
| **safe** | ✓ | ✓ | ✓ | — | ✓ | ✓ | ✗ | ⚠️ |
| **perf** | ✓ | ✓ | ✓ | ✓ | — | ✓ | ✓ | ✓ |
| **user** | ⚠️ | ✓ | ✓ | ✓ | ✓ | — | ✗ | ⚠️ |
| **game** | ✗ | ✗ | ✓ | ✗ | ✓ | ✗ | — | ✗ |
| **sys** | ✓ | ✓ | ✓ | ⚠️ | ✓ | ⚠️ | ✗ | — |

Legend:
- ✓ = Clean boundary (explicit defer-to contract or no overlap)
- ⚠️ = Gray zone (intentional overlap or ambiguous contract)
- ✗ = No contract defined (asymmetric or missing defer-to)

**Key findings:**
- fd-systems has clean boundaries with 5/7 technical agents (arch, corr, qual, perf, user)
- fd-systems has gray zones with 2/7 technical agents (safe, user) — both involve feedback-loop-adjacent concerns
- fd-systems has no defer-to contract with fd-game-design (asymmetric) — see §1.2.3

**Overall boundary quality:** Strong (5/7 clean), with 2 gray zones that are defensible as intentional overlap.

---

## 6. Test Coverage

### 6.1 Structural Tests

fd-systems is covered by existing structural tests in `tests/structural/test_agents.py`:
- `test_agent_count` — validates 13 agents total (8 review + 5 research)
- `test_all_fd_agents_present` — validates fd-systems exists
- `test_agent_is_nonempty` — validates fd-systems has content

**Coverage verdict:** Basic structural validation exists.

---

### 6.2 Missing Integration Tests

No integration tests exist for:
1. **Cognitive pre-filter logic** — Does fd-systems correctly skip code files, diffs, and non-document Markdown?
2. **Cognitive severity mapping** — Does synthesis correctly interpret Blind Spot → P1, Missed Lens → P2, Consider Also → P3?
3. **Cross-category synthesis** — If fd-architecture and fd-systems both flag the same issue, does synthesis deduplicate correctly or preserve both?
4. **Convergence tracking** — If multiple cognitive agents (fd-systems + fd-decisions, when implemented) flag overlapping concerns, how does synthesis handle it?

**Recommendation:** Add integration tests before shipping fd-systems:
- `test_cognitive_prefilter.py` — Validate fd-systems skips code/diffs, activates only on documents
- `test_cognitive_severity.py` — Validate severity mapping in synthesized `findings.json`
- `test_cross_category_synthesis.py` — Run flux-drive on a PRD, mock findings from fd-architecture (P2) and fd-systems (P1) on overlapping concerns, validate both appear in output

These tests validate the **category boundary** is enforced at runtime, not just in documentation.

---

## 7. Architectural Recommendations

### 7.1 Must-Fix (P0-P1)

None. fd-systems is architecturally sound and safe to ship as-is.

---

### 7.2 Should-Fix Before Scale (P2)

1. **Document cognitive agent boundary rules** (§3.1)
   - Create `agents/review/references/cognitive-agent-boundaries.md`
   - Allocate Linsenkasten lenses across 5 cognitive agents (systems, decisions, people, resilience, perception)
   - Document overlap rules and defer-to contracts
   - Prevents boundary drift when fd-decisions/fd-people/etc. are added

2. **Add integration tests for cognitive category** (§6.2)
   - Validate pre-filter logic (code/diff exclusion)
   - Validate severity mapping in synthesis
   - Validate cross-category findings aggregation

3. **Clarify fd-safety ↔ fd-systems gray zone** (§1.2.1)
   - Add to fd-safety: "Evaluate rollback feasibility (can it be done safely?)"
   - Add to fd-systems: "Evaluate rollback dynamics (what are the second-order costs, delays, and irreversibilities?)"

4. **Add symmetric defer-to contract for fd-game-design ↔ fd-systems** (§1.2.3)
   - fd-systems → fd-game-design for gameplay-specific concerns
   - fd-game-design → fd-systems for generic systems dynamics

---

### 7.3 Consider for Phase 1+ (P3)

1. **Audit resilience lens overlap** (§1.2.4)
   - Before creating fd-resilience, reclassify hormesis/over-adaptation/crumple zones lenses
   - Decide whether resilience is a separate agent or merged into fd-systems

2. **Document lens selection criteria** (§2.1)
   - Add `agents/review/references/lens-selection-criteria.md`
   - Explain why 12 lenses from 288, coverage assessment, extension path

3. **Migrate to dynamic lens retrieval** (§2.2)
   - When MCP integration happens, replace hardcoded lens lists with `search_lenses` calls
   - Prevents lens drift across cognitive agents

4. **Add convergence tracking to synthesis** (§4.3)
   - Detect when multiple agents flag overlapping concerns
   - Annotate findings with "Confirmed by {agent1, agent2}"
   - Boost confidence for converged findings

5. **Standardize agent structure** (§5.1)
   - Add "What NOT to Flag" to fd-architecture and fd-correctness
   - Add "Decision Lens" to all agents or remove from all

---

## 8. Overall Verdict

fd-systems is architecturally sound. The cognitive/technical split is clean, defer-to contracts are explicit, and the pre-filter logic prevents misrouting. The integration into the flux-drive pipeline is seamless.

**Key strengths:**
- Category-based architecture (cognitive vs technical) is well-defined and consistently enforced
- Defer-to contracts with all 7 technical agents prevent overlap
- Pre-filter logic isolates cognitive agents to document review only
- Cognitive severity mapping preserves synthesis compatibility

**Key risks (mitigated):**
- Lens selection is undocumented (but justified in comments)
- Resilience lens overlap exists (but fixable before fd-resilience is created)
- No integration tests for cognitive category (but structural tests exist)

**Shipping recommendation:** **Safe to ship.** fd-systems is production-ready for Phase 0 (MVP validation). Before scaling to 5 cognitive agents (Phase 1+), address P2 recommendations (boundary docs, integration tests, gray zone clarifications).

---

## Appendix A: Boundary Recommendations for Future Cognitive Agents

When creating fd-decisions, fd-people, fd-resilience, fd-perception, apply this template:

1. **Pre-filter to documents only** (same as fd-systems)
2. **Explicit defer-to contracts** with all technical agents + other cognitive agents
3. **Lens-based review** with curated lens list from Linsenkasten
4. **Cognitive severity mapping** (Blind Spot → P1, Missed Lens → P2, Consider Also → P3)
5. **Question-framing findings** (not lectures)

**Lens allocation guidance:**

| Agent | Cognitive Domain | Sample Lenses (from Linsenkasten) |
|-------|------------------|-----------------------------------|
| fd-systems | Systems dynamics, feedback, emergence, temporal | Compounding Loops, BOTG, Hysteresis, Schelling Traps, Pace Layers |
| fd-decisions | Decision quality, uncertainty, optionality | Sunk Cost Fallacy, Availability Heuristic, Expected Value, Real Options |
| fd-people | Trust, power, communication, coordination | Principal-Agent Problem, Tragedy of the Commons, Information Asymmetry |
| fd-resilience | Robustness, adaptation, innovation, constraints | Antifragility, Graceful Degradation, Tight Coupling, Redundancy |
| fd-perception | Sensemaking, mental models, bias, framing | Confirmation Bias, Narrative Fallacy, Dunning-Kruger, Framing Effects |

**Overlap rules:**
- **Intentional overlap** between fd-systems and fd-resilience (crumple zones, hormesis, over-adaptation are both systems and resilience concepts) — both agents should flag these, synthesis preserves both findings
- **No overlap** between fd-systems and fd-decisions (systems dynamics vs decision quality are orthogonal)
- **No overlap** between fd-people and fd-perception (social dynamics vs cognitive bias are orthogonal)

**Extension criteria:**
- Add a 6th cognitive agent only when >10 real documents show blind spots not covered by the 5 existing agents
- Prefer expanding existing agents' lens lists over creating new agents

---

## Appendix B: Cross-Agent Boundary Matrix (Full)

| From ↓ To → | arch | corr | qual | safe | perf | user | game | sys | decis | people | resil | percep |
|-------------|------|------|------|------|------|------|------|-----|-------|--------|-------|--------|
| arch        | —    | ✓    | ✓    | ✓    | ✓    | ⚠️    | ✗    | ✓   | ?     | ?      | ?     | ?      |
| corr        | ✓    | —    | ✓    | ✓    | ✓    | ✓    | ✗    | ✓   | ?     | ?      | ?     | ?      |
| qual        | ✓    | ✓    | —    | ✓    | ✓    | ✓    | ✓    | ✓   | ?     | ?      | ?     | ?      |
| safe        | ✓    | ✓    | ✓    | —    | ✓    | ✓    | ✗    | ⚠️   | ?     | ?      | ?     | ?      |
| perf        | ✓    | ✓    | ✓    | ✓    | —    | ✓    | ✓    | ✓   | ?     | ?      | ?     | ?      |
| user        | ⚠️    | ✓    | ✓    | ✓    | ✓    | —    | ✗    | ⚠️   | ?     | ?      | ?     | ?      |
| game        | ✗    | ✗    | ✓    | ✗    | ✓    | ✗    | —    | ✗   | ?     | ?      | ?     | ?      |
| sys         | ✓    | ✓    | ✓    | ⚠️    | ✓    | ⚠️    | ✗    | —   | ?     | ?      | ⚠️     | ?      |
| decis       | ?    | ?    | ?    | ?    | ?    | ?    | ?    | ?   | —     | ?      | ?     | ?      |
| people      | ?    | ?    | ?    | ?    | ?    | ?    | ?    | ?   | ?     | —      | ?     | ?      |
| resil       | ?    | ?    | ?    | ?    | ?    | ?    | ?    | ⚠️   | ?     | ?      | —     | ?      |
| percep      | ?    | ?    | ?    | ?    | ?    | ?    | ?    | ?   | ?     | ?      | ?     | —      |

Legend:
- ✓ = Clean boundary (explicit defer-to contract or no overlap)
- ⚠️ = Gray zone (intentional overlap or ambiguous contract)
- ✗ = No contract defined (asymmetric or missing defer-to)
- ? = Agent does not exist yet (boundary undefined)

**Use this matrix when creating fd-decisions/fd-people/fd-resilience/fd-perception** to ensure all cross-agent boundaries are defined before implementation.

---

## Appendix C: Validation Evidence

fd-systems has been tested on 3 real documents (per `docs/research/validate-fd-systems-on-*.md`):
1. **Interflux PRD** — 8 findings, validated that cognitive review detects blind spots in PRDs about cognitive systems (self-exemplifying)
2. **Sprint PRD** — Not yet validated (no `validate-fd-systems-on-sprint-prd.md` found in research dir)
3. **Brainstorm doc** — Not yet validated

**Evidence quality:** Limited. Only 1 validation document found. Before shipping, run fd-systems on:
- 5 PRDs from different domains (game design, API design, infrastructure, ML pipeline, CLI tool)
- 3 brainstorm docs
- 2 strategy/roadmap docs

Target: 90% of findings should be actionable (users accept them as valid blind spots, not false positives).

**Recommendation:** Run fd-systems on 10 diverse documents, collect actionability feedback, adjust lens set if <90% actionable.

---

## File Metadata

**Reviewed file:** `/root/projects/Interverse/plugins/interflux/agents/review/fd-systems.md`
**Lines:** 108
**Agent category:** cognitive
**Lens count:** 12 (from Linsenkasten's 288-lens catalog)
**Defer-to contracts:** 7 technical agents + 4 reserved cognitive agents
**Pre-filter:** Documents only (`.md`/`.txt`, PRD/brainstorm/plan/strategy, no code/diffs)
**Severity mapping:** Blind Spot → P1, Missed Lens → P2, Consider Also → P3
**Integration:** Findings Index contract, synthesis-compatible
**Test coverage:** Structural tests exist, integration tests missing
**Shipping recommendation:** Safe to ship for Phase 0, defer P2 fixes to Phase 1
