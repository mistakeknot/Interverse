# Quality Review: fd-systems.md

**Reviewed**: 2026-02-16
**Reviewer**: Flux-drive Quality & Style Reviewer
**Subject**: `/root/projects/Interverse/plugins/interflux/agents/review/fd-systems.md`
**Context**: New cognitive review agent for systems thinking analysis

## Executive Summary

The fd-systems.md agent file is **structurally sound and stylistically consistent** with the existing flux-drive review agent family. It follows established naming conventions, frontmatter structure, and organizational patterns. However, it introduces **one unique section** ("Cognitive Severity Guidance") that creates a precedent divergence from technical review agents, and includes **minor inconsistencies** in section ordering and naming compared to peer agents.

**Status**: Ready for use with minor consistency improvements recommended.

---

## Universal Quality Review

### Naming Consistency ✓

- **Agent name**: `fd-systems` follows the established `fd-<domain>` pattern
- **Filename**: `fd-systems.md` matches the 8 existing agents exactly
- **Section headers**: Uses established patterns (`## First Step (MANDATORY)`, `## Review Approach`, `## Focus Rules`, `## What NOT to Flag`)
- **Terminology**: Consistently uses "systems thinking", "feedback loops", "emergence", "causal reasoning" throughout

### File Organization ✓

- **Location**: Correctly placed in `agents/review/` alongside 7 peer agents
- **Frontmatter**: Follows the 3-field YAML structure (name, description, model) used by all fd-* agents
- **Section ordering**: Generally follows peer patterns but with one novel section insertion (see "Structural Patterns" below)

### Error Handling Patterns N/A

- This is a strategic/analysis agent, not executable code — no error handling to review

### Test Strategy N/A

- Agent definitions are declarative prompts, not tested code

### API Design Consistency ✓

- **Description field structure**: Matches peer format with domain summary + 2 usage examples with context/commentary
- **Model specification**: Uses `model: sonnet` like all 7 existing fd-* agents
- **Example structure**: `<example>Context: ... user: ... assistant: ... <commentary>...</commentary></example>` matches established pattern

### Complexity Budget ✓

- **Line count**: 108 lines (vs 81-88 for most technical agents, 110 for fd-game-design)
- **Justification**: Longer due to "Key Lenses" section (12 annotated lenses, lines 60-81), which provides domain-specific scaffolding comparable to fd-quality's language sections or fd-game-design's game system taxonomy
- **Complexity**: Appropriate for the cognitive domain scope

### Dependency Discipline ✓

- No external dependencies introduced
- References to "Linsenkasten" knowledge base in comment (line 62-65) is documentation, not a runtime dependency

---

## Structural Patterns vs Peer Agents

### Common Section Structure (all 8 agents)

All fd-* agents share these core sections:

1. **Frontmatter** (YAML: name, description, model)
2. **Opening statement** (1-2 sentences defining the agent's role)
3. **`## First Step (MANDATORY)`** - doc discovery protocol
4. **`## Review Approach`** - domain-specific analysis framework
5. **`## What NOT to Flag`** - boundary clarification with other agents
6. **`## Focus Rules`** - prioritization and output guidance

### fd-systems Unique Sections

**New section**: `## Cognitive Severity Guidance` (lines 82-91)

- **Purpose**: Maps abstract cognitive gaps to P0-P3 severity levels
- **Precedent**: No other agent has this section
- **Justification**: Cognitive review findings ("missing a lens") are harder to severity-rank than technical findings ("this race causes data loss"), so explicit guidance is valuable
- **Assessment**: **Positive addition**, but creates divergence

**Novel subsection**: `## Key Lenses` (lines 60-81)

- **Purpose**: Provides a curated toolkit of 12 systems-thinking frames with 1-line definitions
- **Precedent**: fd-quality has `## Language-Specific Checks`, fd-game-design has numbered subsections under Review Approach
- **Justification**: Cognitive analysis needs shared vocabulary; analogous to fd-quality's Go/Python/TypeScript sections
- **Assessment**: **Appropriate domain scaffolding**, well-integrated

### Section Ordering Divergence

**fd-systems ordering** (post-Review Approach):
1. Key Lenses
2. Cognitive Severity Guidance
3. What NOT to Flag
4. Focus Rules

**Most common ordering** (fd-architecture, fd-quality, fd-user-product, fd-performance, fd-safety):
1. Review Approach
2. What NOT to Flag (or domain-specific closing section)
3. Focus Rules
4. Decision Lens (optional)

**fd-game-design ordering** (closest peer):
1. Review Approach (6 numbered subsections)
2. Focus Rules
3. What NOT to Flag
4. Decision Lens

**Recommendation**: Move "Cognitive Severity Guidance" to immediately before "Focus Rules" to cluster all output-guidance sections together, matching the peer pattern.

---

## Agent-Specific Idiom Alignment

### Frontmatter Structure ✓

All 8 agents use identical YAML structure:

```yaml
---
name: fd-<domain>
description: "<summary> — <details>. <context note>. Examples: <example>...</example> <example>...</example>"
model: sonnet
---
```

fd-systems **conforms perfectly**.

### Opening Statement Voice

**fd-systems** (line 7):
> "Your job is to evaluate whether documents adequately consider feedback loops, emergence, causal chains, and systems dynamics — catching cognitive blind spots that domain-specific reviewers miss because they focus on implementation rather than systemic behavior."

**Comparison**:
- **fd-architecture** (line 7): "Your job is to evaluate structure first, then complexity, so teams can deliver changes that fit the codebase instead of fighting it."
- **fd-correctness** (line 7): "You are Julik, the Flux-drive Correctness Reviewer: half data-integrity guardian, half concurrency bloodhound. You care about facts, invariants, and what happens when timing turns hostile."
- **fd-quality** (line 7): "You apply universal quality checks first, then language-specific idioms for the languages actually present in the change."

**Assessment**: fd-systems uses a **longer, more explanatory** opening compared to most peers. fd-correctness is the only other agent with personality ("Julik"). fd-systems' opening is **informative but verbose** — consider shortening to match the terse style of fd-architecture/fd-quality.

**Suggested rewrite**:
> "You evaluate whether documents adequately consider feedback loops, emergence, causal chains, and systems dynamics — catching cognitive blind spots domain reviewers miss."

### "First Step" Protocol ✓

All agents use the **3-doc discovery order**:
1. `CLAUDE.md` in project root
2. `AGENTS.md` in project root
3. Domain-specific docs (architecture, design docs, game design docs, etc.)

fd-systems **follows this exactly** (lines 11-14), with appropriate domain twist (line 14: "docs/ARCHITECTURE.md and any architecture/design docs").

### Review Approach Formatting

**fd-systems**: Uses **4 numbered subsections** (lines 28-59) + separate "Key Lenses" section

**Peer patterns**:
- **fd-architecture**: 3 numbered subsections (Boundaries & Coupling, Pattern Analysis, Simplicity & YAGNI)
- **fd-correctness**: 2 numbered subsections (Data Integrity, Concurrency) + special "Failure Narrative Method" and "Communication Style" sections
- **fd-quality**: 2 top-level sections (Universal Review, Language-Specific Checks)
- **fd-game-design**: 6 numbered subsections (Balance, Pacing, Psychology, Feedback Loops, Emergence, Procedural Content)
- **fd-user-product**: 4 named subsections (User Experience, Product Validation, User Impact, Flow Analysis)

**Assessment**: fd-systems' 4-subsection structure is **within normal range**. However, the subsections are **not numbered** in the source (lines 28-59 use `###` headers without explicit numbering), unlike fd-game-design which uses `### 1. Balance & Tuning`, etc.

**Inconsistency**: The review description at line 28 says "### 1. Feedback Loops & Causal Reasoning" but the actual heading format varies across agents. fd-systems does NOT number its subsections in the markdown, while fd-game-design DOES.

**Recommendation**: Add explicit numbering to match fd-game-design's clarity:
```markdown
### 1. Feedback Loops & Causal Reasoning
### 2. Emergence & Complexity
### 3. Systems Dynamics & Temporal Patterns
### 4. Unintended Consequences & Traps
```

---

## Language-Specific Idioms N/A

fd-systems is a **document review agent** (PRDs, strategy docs, brainstorms), not a code review agent. It correctly does NOT include language-specific sections. This matches fd-user-product's approach (also doc-focused).

---

## Precision and Correctness

### Terminology Accuracy ✓

The 12 lenses referenced in lines 67-81 are **well-defined systems thinking concepts**:
- Systems Thinking, Compounding Loops, BOTG, Simple Rules → standard systems dynamics
- Bullwhip Effect, Hysteresis, Causal Graph → operations research / supply chain theory
- Schelling Traps, Crumple Zones, Pace Layers → modern complexity science (Brand, Schelling)
- Hormesis, Over-Adaptation → resilience engineering

**Source attribution** (lines 62-65): References Linsenkasten's 288-lens corpus, noting that 12 were selected from Systems Dynamics, Emergence & Complexity, and Resilience frames. This is **appropriately scoped** — other cognitive domains (decisions, people, perception) are reserved for future agents (noted in line 99).

### Boundary Clarity ✓

**What NOT to Flag section** (lines 93-101) correctly defers to 6 other fd-* agents and explicitly carves out its niche as the **only cognitive review agent** in the current lineup.

**Explicit exclusions**:
- Technical implementation → fd-architecture, fd-correctness
- Code quality/style → fd-quality
- Security/deployment → fd-safety
- Performance → fd-performance
- User experience → fd-user-product
- Documents that are purely technical (code, configs, API specs) → line 100

**Subtle boundary**: Line 100 says "Documents that are purely technical (code, configs, API specs) — cognitive review adds no value there." This is correct — systems thinking applies to **strategic/planning documents**, not implementation artifacts.

---

## Consistency Findings Summary

### ✓ Fully Consistent
- Naming convention (fd-systems)
- Frontmatter structure (YAML with name/description/model)
- Model selection (sonnet)
- First Step protocol (3-doc discovery order)
- What NOT to Flag boundary definitions
- Focus Rules structure

### ⚠️ Minor Inconsistencies
1. **Section ordering**: "Cognitive Severity Guidance" appears between "Key Lenses" and "What NOT to Flag", breaking the common pattern of ending with Focus Rules
2. **Subsection numbering**: Review Approach subsections are not explicitly numbered (fd-game-design uses `### 1.`, fd-systems uses `### Feedback Loops`)
3. **Opening statement length**: More verbose than fd-architecture/fd-quality's terse style
4. **Novel section**: "Cognitive Severity Guidance" has no precedent in other agents (but this is justified)

### ➕ Positive Divergences
1. **Cognitive Severity Guidance**: Unique and valuable for cognitive review domain
2. **Key Lenses section**: Well-curated, well-documented, analogous to fd-quality's language sections
3. **Lens provenance**: Inline comment citing source corpus and selection rationale (transparency)

---

## Recommendations

### Must-Fix (Consistency)
None — the file is production-ready as-is.

### Should-Fix (Alignment)

1. **Reorder sections** to match peer pattern:
   ```markdown
   ## Review Approach
   ### 1. Feedback Loops & Causal Reasoning
   ### 2. Emergence & Complexity
   ### 3. Systems Dynamics & Temporal Patterns
   ### 4. Unintended Consequences & Traps

   ## Key Lenses
   [current content]

   ## What NOT to Flag
   [current content]

   ## Cognitive Severity Guidance
   [current content]

   ## Focus Rules
   [current content]
   ```
   **Rationale**: Groups output-guidance sections (Cognitive Severity + Focus Rules) together, matching fd-game-design's "Focus Rules → What NOT to Flag" pattern

2. **Number subsections** explicitly:
   ```markdown
   ### 1. Feedback Loops & Causal Reasoning
   ### 2. Emergence & Complexity
   ### 3. Systems Dynamics & Temporal Patterns
   ### 4. Unintended Consequences & Traps
   ```
   **Rationale**: Matches fd-game-design's numbered subsection style, improves scannability

3. **Shorten opening statement**:
   ```markdown
   You are a Flux-drive Systems Thinking Reviewer. You evaluate whether documents adequately consider feedback loops, emergence, causal chains, and systems dynamics.
   ```
   **Rationale**: Matches the terse, directive style of fd-architecture and fd-quality

### Could-Fix (Optional)

4. **Add a "Decision Lens" section** (like fd-architecture, fd-game-design, fd-user-product have):
   ```markdown
   ## Decision Lens

   - Favor analyses that reveal non-obvious feedback dynamics over exhaustive lens coverage
   - If two interpretations are equally plausible, choose the one that surfaces testable second-order effects
   ```
   **Rationale**: 3 out of 8 agents have this section; it's a useful closing frame for decision-making

---

## Comparative Analysis: fd-systems vs Technical Peers

| Dimension | fd-systems | fd-architecture | fd-quality | fd-correctness | fd-game-design |
|-----------|-----------|----------------|-----------|---------------|---------------|
| **Domain** | Cognitive (docs) | Technical (code) | Technical (code) | Technical (code) | Technical (code+design) |
| **Line count** | 108 | 81 | 88 | 83 | 110 |
| **Subsections** | 4 (unnumbered) | 3 (numbered) | 2 (named) | 2 (named) | 6 (numbered) |
| **Special sections** | Key Lenses, Cognitive Severity | Decision Lens | Language Checks | Failure Narrative, Comm Style | Decision Lens |
| **Opening style** | Explanatory (long) | Directive (short) | Directive (short) | Persona (Julik) | Directive (short) |
| **Section order** | RA → KL → CSG → WNF → FR | RA → WNF → FR → DL | RA → LS → WNF → FR | RA → FN → CS → P | RA → FR → WNF → DL |

**Key**: RA = Review Approach, KL = Key Lenses, CSG = Cognitive Severity Guidance, WNF = What NOT to Flag, FR = Focus Rules, DL = Decision Lens, LS = Language Sections, FN = Failure Narrative, CS = Communication Style, P = Prioritization

**Findings**:
- fd-systems is **most similar** to fd-game-design in length, complexity, and use of a specialized taxonomy section
- fd-systems' section ordering is **unique** but not problematic
- The addition of "Cognitive Severity Guidance" is a **positive innovation** that may be worth backporting to other agents (especially fd-architecture, fd-user-product) where finding severity is also nuanced

---

## Conclusion

**Overall assessment**: fd-systems.md is a **high-quality addition** to the flux-drive agent family. It correctly adapts the established technical review template to the cognitive review domain, introduces useful new scaffolding (Key Lenses, Cognitive Severity Guidance), and maintains boundary clarity with peer agents.

**Consistency score**: 8.5/10
- Deductions for minor section ordering divergence and missing subsection numbering
- Credit for justified domain-specific adaptations

**Production readiness**: ✓ Ready to use
- The file is fully functional as-is
- Recommended improvements are stylistic alignment, not correctness fixes

**Impact on agent family**:
- Establishes the **cognitive review pattern** alongside technical review
- "Cognitive Severity Guidance" section could be a useful template for other agents where severity ranking is subjective (fd-user-product, fd-architecture)
- The "Key Lenses" approach could inspire similar domain taxonomies in other agents (e.g., fd-performance could have "Performance Lenses": latency/throughput/memory/startup)

---

## Appendix: Cross-Agent Patterns Reference

### Established Conventions (all 8 agents follow)
1. Filename: `fd-<domain>.md`
2. Frontmatter: 3-field YAML (name, description, model)
3. Opening: 1-2 sentence role definition
4. First Step: 3-doc discovery protocol (CLAUDE.md → AGENTS.md → domain docs)
5. Review Approach: Primary analytical framework
6. What NOT to Flag: Boundary definition with peer agents
7. Focus Rules: Output guidance and prioritization

### Common Optional Sections
- **Decision Lens** (3/8 agents: fd-architecture, fd-game-design, fd-user-product)
- **Specialized guidance** (varies by domain):
  - fd-quality: Language-Specific Checks
  - fd-correctness: Failure Narrative Method, Communication Style
  - fd-performance: Measurement Discipline
  - fd-safety: Risk Prioritization
  - fd-game-design: (embedded in Review Approach)
  - **fd-systems: Cognitive Severity Guidance, Key Lenses**

### Section Ordering Patterns
- **Most common**: Review Approach → [domain sections] → What NOT to Flag → Focus Rules → [Decision Lens]
- **fd-systems**: Review Approach → Key Lenses → Cognitive Severity → What NOT to Flag → Focus Rules
- **Recommendation**: Review Approach → Key Lenses → What NOT to Flag → Cognitive Severity → Focus Rules (groups output guidance together)

---

**End of Review**
