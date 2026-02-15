### Findings Index

- SAFE | F0 | "Boundaries & Coupling" | Linsenkasten move follows monorepo pattern without introducing coupling
- NEEDS-CHANGES | F1 | "Pattern Analysis" | Agent files deviate from fd-* naming convention and pre-filter pattern
- SAFE | F2 | "Pattern Analysis" | Triage integration extends scoring algorithm cleanly
- SAFE | F3 | "Boundaries & Coupling" | MCP wiring preserves enrichment-not-gating principle
- YAGNI | F5 | "Simplicity & YAGNI" | Domain profile redundant when agents exist directly
- NEEDS-CHANGES | F1 | "Simplicity & YAGNI" | Five lens agents may be too granular for initial iteration
- SAFE | F4 | "Pattern Analysis" | Severity system maps cleanly to synthesis phase

Verdict: needs-changes

---

## Summary

The PRD proposes a sound architectural integration of Linsenkasten analytical lenses into the flux-drive review pipeline. The monorepo migration (F0) follows established patterns. The MCP wiring (F3) correctly treats lens data as enrichment rather than hard dependency. The triage integration (F2) extends the existing scoring algorithm without requiring structural changes. The severity system (F4) maps cleanly to existing synthesis patterns.

However, two structural concerns require changes before implementation:

1. **Agent naming and pre-filtering** (F1): The proposed `fd-lens-*` agents blur the line between domain-specific agents (like `fd-game-design`) and core agents. The PRD lacks pre-filter rules to prevent lens agents from running on code reviews, which will cause slot ceiling violations.

2. **Agent granularity** (F1): Five lens agents may be too many for the first iteration. The brainstorm consolidation from 8→5 was a step in the right direction, but further consolidation to 3 agents would reduce triage complexity and prevent overwhelming document reviews.

One feature (F5 domain profile) is likely YAGNI — the domain profile duplicates the same review criteria already present in the agent files.

---

## 1. Boundaries & Coupling

### F0: Linsenkasten Move into Interverse (SAFE)

**Assessment:** The proposed migration follows the exact pattern used by other Interverse subprojects. Linsenkasten would live at `plugins/linsenkasten/` with its own `.git`, matching the structure of `plugins/interflux/`, `plugins/interdoc/`, etc. The compat symlink at `/root/projects/Linsenkasten` preserves existing tooling paths. No coupling is introduced — interflux would consume Linsenkasten's MCP server as a separate service, not as a hard dependency.

**Evidence from codebase:**
- Interverse CLAUDE.md line 14-15: "Each subproject has its own `.git`. When working in a subproject, those take precedence."
- Interverse CLAUDE.md line 23: "Clavain is the hub; everything else is a module"
- Existing pattern: `plugins/interflux/.git`, `plugins/interdoc/.git` — all subprojects maintain their own git history

**Coupling analysis:**
- Linsenkasten MCP server runs as separate process (stdio MCP)
- Lens agents call MCP tools via Claude Code's MCP infrastructure (not direct imports)
- Failure isolation: If Linsenkasten MCP is unavailable, lens agents degrade to hardcoded lens lists (F3 acceptance criterion: "Graceful degradation")
- No shared code between interflux agents and Linsenkasten packages — clean service boundary

**Recommendation:** Proceed with F0 as specified. The monorepo structure is correct.

### F3: Linsenkasten MCP Wiring (SAFE)

**Assessment:** F3 correctly treats MCP integration as enrichment rather than gating. The acceptance criteria explicitly require "No hard dependency — MCP enriches but doesn't gate the review." This aligns with interflux's existing MCP pattern for Exa.

**Evidence from interflux codebase:**
- `CLAUDE.md` line 37-38: "Exa MCP server is a progressive enhancement — if `EXA_API_KEY` not set, agents fall back to Context7 + WebSearch"
- `AGENTS.md` line 144: "Exa requires API key — set `EXA_API_KEY` env var; agents degrade gracefully without it"

The PRD follows the same pattern: MCP tools (`search_lenses`, `detect_thinking_gaps`) are called opportunistically, but each lens agent has a hardcoded list of 8-12 key lenses in its agent file (F1 acceptance criterion). If MCP is unavailable, the agent uses the static list.

**Boundary preservation:**
- MCP tools are discovery aids, not the review logic itself
- Agent files contain the analytical framework (the "mission" + decision lens)
- Linsenkasten remains a standalone service — can be updated/deployed independently
- No version coupling: agents don't depend on specific lens IDs or frame structures

**Recommendation:** Proceed with F3 as specified. The MCP integration preserves the enrichment-not-gating principle.

---

## 2. Pattern Analysis

### F1: Agent File Structure (NEEDS-CHANGES)

**Problem 1: Naming convention deviation**

The PRD proposes `fd-lens-systems.md`, `fd-lens-decisions.md`, etc. This creates a naming inconsistency with existing domain-specific agents. Compare:

- **Existing domain agent:** `fd-game-design.md` (line 32 of interflux CLAUDE.md)
- **Proposed lens agents:** `fd-lens-systems.md`, `fd-lens-decisions.md`, `fd-lens-people.md`, `fd-lens-resilience.md`, `fd-lens-perception.md`

The existing domain agent doesn't use a prefix — it's `fd-game-design`, not `fd-game-lens` or `fd-domain-game-design`. This suggests lens agents should drop the `lens-` infix:

- `fd-systems` (not `fd-lens-systems`)
- `fd-decisions` (not `fd-lens-decisions`)
- `fd-people` (not `fd-lens-people`)
- `fd-resilience` (not `fd-lens-resilience`)
- `fd-perception` (not `fd-lens-perception`)

**Counterargument:** The `lens-` prefix clarifies that these agents review thinking quality, not technical artifacts. Without it, `fd-systems` could be confused with "system-level architecture" (which overlaps with `fd-architecture`).

**Rebuttal:** The agent description in YAML frontmatter already disambiguates: `description: "Reviews documents for systems thinking blind spots..."`. The frontmatter is the primary routing signal, not the filename. The `lens-` prefix is redundant and creates special-case naming.

**Recommendation:** Use `fd-systems`, `fd-decisions`, `fd-people`, `fd-resilience`, `fd-perception` to match the existing `fd-game-design` pattern. Update acceptance criteria in F1 to reflect this.

**Problem 2: Missing pre-filter rules**

The PRD's F1 acceptance criterion states: "Each agent includes 'What NOT to Flag' section deferring technical concerns to core fd-* agents." This is necessary but not sufficient. The agents also need **pre-filter rules** in the triage scoring algorithm to prevent them from running on code/diff inputs.

**Evidence from existing pre-filters:**

From `docs/spec/core/scoring.md` lines 87-97:

```
#### File/Directory Inputs
| Agent | Filter Condition | Passes If |
|-------|------------------|-----------|
| correctness | Skip unless data-related keywords present | Document mentions: databases, migrations, data models, concurrency, async, transactions, consistency |
| user-product | Skip unless product-related | Document is PRD, proposal, strategy, or mentions: user flows, UX, UI, customer, product requirements |
| safety | Skip unless deploy-related | Document mentions: security, credentials, auth, deployments, infrastructure, permissions, secrets |
| game-design | Skip unless game-related | game-simulation domain detected OR keywords: gameplay, mechanics, balance, player, NPC, quest, combat, level design |
```

Lens agents need similar pre-filters. F2 says "Lens agents score 0 (excluded) when input is code/diff", but this is specified as a triage scoring change, not a pre-filter. The distinction matters:

- **Pre-filter:** Agent is removed from candidate pool before scoring (never appears in triage roster)
- **Score 0:** Agent appears in roster but gets excluded by slot ceiling

Lens agents should be **pre-filtered** for diff inputs, not just scored to 0. Otherwise they consume triage presentation space and create user confusion ("Why is fd-lens-systems listed if it's not relevant to my Go PR?").

**Recommendation:** Add pre-filter rules to F2 acceptance criteria:

```
Pre-filter rules (applied before scoring):
- INPUT_TYPE=diff → exclude all fd-lens-* agents (pre-filter out)
- INPUT_TYPE=file AND file extension in {.go, .py, .ts, .rs, .sh, .c, .java} → exclude all fd-lens-* agents
- INPUT_TYPE=file AND file extension in {.md, .txt} AND filename matches (README, CLAUDE, AGENTS) → score normally
- INPUT_TYPE=file AND content starts with "# PRD" or "# Plan" or "# Brainstorm" → score normally
- INPUT_TYPE=directory → score normally (may be doc repo)
```

This prevents lens agents from appearing in code review triage rosters entirely.

**Problem 3: "What NOT to Flag" section insufficient**

The F1 acceptance criterion requires a "What NOT to Flag" section. Looking at existing agents, this section exists in `fd-quality.md` (lines 78-83):

```markdown
## What NOT to Flag

- Pure style preferences not established by project conventions
- Missing patterns the repository does not use (for example docstrings, strict typing, or logging frameworks)
- Tooling recommendations that conflict with project defaults unless there is concrete risk
- Cosmetic churn that does not improve correctness, readability, or maintainability
```

Lens agents need an analogous section, but the PRD doesn't specify what it should contain. Based on the brainstorm, lens agents should NOT flag:

- Technical correctness issues (deferred to fd-correctness)
- Code style issues (deferred to fd-quality)
- Architecture patterns (deferred to fd-architecture)
- Missing lenses that are not applicable to the document type (e.g., don't flag "missing Hormesis analysis" in a README)

**Recommendation:** Add specific "What NOT to Flag" bullets to F1 acceptance criteria:

```
Each agent's "What NOT to Flag" section must include:
- Technical implementation details (code structure, algorithms, data structures)
- Language-specific idioms and style (deferred to fd-quality)
- Architecture and coupling concerns (deferred to fd-architecture)
- Lenses from other lens agents' domains (strict separation to prevent overlap)
- Lenses that don't apply to the document's purpose (e.g., don't flag missing risk analysis in a brainstorm)
```

### F2: Triage Integration (SAFE)

**Assessment:** The triage integration extends the existing scoring algorithm without requiring structural changes. The key components are:

1. **Pre-filters** (as noted above, these need to be added to the PRD)
2. **Document-type detection** (already supported — flux-drive detects file vs directory vs diff in `INPUT_TYPE`)
3. **Keyword triggers** (standard base_score logic from scoring.md)
4. **Slot ceiling cap** (F2: "At most 3 lens agents activate for any single document review")

The slot ceiling cap is a new constraint. Existing flux-drive has a dynamic slot ceiling based on review scope (from `SKILL.md` Step 1.2, not shown in the snippets I read, but referenced in `docs/spec/core/scoring.md`). The cap is typically 12 agents max. F2 proposes a **sub-ceiling** of 3 lens agents.

**How to implement sub-ceilings:**

Option A: After scoring all agents, apply a category filter: "Take top 12 overall, but no more than 3 from the `fd-lens-*` category."

Option B: Score lens agents separately, select top 3, then score core agents and select top 9, ensuring total ≤ 12.

Option A is simpler and doesn't require architectural changes — it's a post-processing filter in the triage phase. Option B requires bifurcating the scoring algorithm.

**Recommendation:** Use Option A (post-processing filter). Add to F2 acceptance criteria:

```
After scoring and slot ceiling application, enforce lens agent sub-ceiling:
- Count agents in final roster where name starts with "fd-lens-" (or matches lens agent list)
- If count > 3, keep only the top 3 by final_score, drop the rest
- Report to user: "Lens agents capped at 3 (N candidates, 3 selected)"
```

This integrates cleanly without changing the core scoring algorithm.

### F4: Severity System (SAFE)

**Assessment:** The proposed severity mapping is:

- "Blind Spot" → P1-equivalent
- "Missed Lens" → P2-equivalent
- "Consider Also" → P3-equivalent

This maps cleanly to the existing synthesis phase. From `docs/spec/core/synthesis.md` lines 18-26, findings are collected with severity labels, deduplicated, and used for verdict computation. The synthesis phase doesn't care about the specific severity labels — it treats them as ordinal rankings (higher severity = higher priority).

**Evidence from synthesis.md:**

Line 84-86: "If agents disagree on severity for the same issue: Use most severe rating for verdict computation."

This means "Blind Spot" vs "P1" is purely a labeling difference. The synthesis logic works identically whether findings are tagged P1/P2/P3 or Blind Spot/Missed Lens/Consider Also.

**Deduplication for lens findings:**

F4 acceptance criterion: "Synthesis phase deduplicates lens findings across agents (same lens flagged by 2 agents → one finding with convergence noted)."

This is already how synthesis works (lines 54-89 of synthesis.md). When `fd-systems` and `fd-resilience` both flag "missing feedback loop analysis", deduplication will:

1. Match by section + title fuzzy match
2. Merge metadata: `"agents": ["fd-systems", "fd-resilience"]`
3. Set `"convergence": 2`
4. Use the most specific description

**Recommendation:** Proceed with F4 as specified. The severity system requires no changes to synthesis logic — just different labels for the same ordinal levels.

### F5: Domain Profile (YAGNI)

**Assessment:** F5 proposes creating `config/flux-drive/domains/linsenkasten.md` with:

- Detection signals (lens data files, `linsenkasten-mcp` in config)
- Injection criteria for core agents (bullets added to fd-architecture, fd-quality, etc.)
- Agent specifications for the 5 lens agents

**Problem 1: Detection signals are circular**

The detection signals include "FLUX/lens-related keywords" and "lens data files". But lens agents are meant to review **any strategy document**, not just Linsenkasten-related documents. The domain detection would trigger only for Linsenkasten's own documentation, which is not the intent.

Compare to existing domain profiles: `web-api.md` detects web API projects (lines 131-176 of `index.yaml`). It doesn't detect "documents about web APIs" — it detects "projects that ARE web APIs."

Lens agents are cross-domain — they should review strategy documents in **all** projects, not just projects detected as "linsenkasten domain."

**Problem 2: Injection criteria redundant with agent files**

The PRD says F5 should include "Injection criteria: domain-specific review bullets for each core fd-* agent (e.g., fd-architecture gets 'Check for systems thinking blind spots in module design')."

But this creates duplication:
- `fd-systems.md` agent file already contains "Check for systems thinking blind spots"
- `linsenkasten.md` domain profile would inject the same bullet into fd-architecture

This violates DRY and creates maintenance burden: updating a lens check requires changing both the agent file and the domain profile.

**Problem 3: Agent specifications redundant with agent files**

F5 acceptance criterion: "Agent specifications section defines all 5 lens agents with Focus, Persona, Decision Lens, Key Review Areas."

But F1 already creates the full agent files with YAML frontmatter, review approach sections, and key lenses. Why duplicate this in the domain profile?

Looking at existing domain profiles (e.g., `claude-code-plugin.md` lines 69-80), the "Agent Specifications" section is a **template** for `/flux-gen` to generate project-specific agents. It's not a duplicate of the agent file — it's a **generator template**.

But lens agents are **plugin agents** (they live in `interflux/agents/review/`), not project-specific agents (which would live in `{PROJECT_ROOT}/.claude/agents/`). Domain profiles generate project-specific agents, not plugin agents.

**Use case for F5:**

The only valid use case for a linsenkasten domain profile is if you want to **inject lens thinking into core agents** when reviewing Linsenkasten's own codebase. For example:

- When `fd-architecture` reviews Linsenkasten MCP server code, inject: "Check that lens search algorithms handle graph edge cases (orphan lenses, circular references)"
- When `fd-correctness` reviews Linsenkasten API, inject: "Verify lens data consistency between JSON files and database"

But this is a narrow use case (Linsenkasten self-review) and doesn't justify F5 for the broader lens agent feature.

**Recommendation:** Drop F5 entirely. Lens agents are plugin agents that apply to all document reviews, not domain-specific agents triggered by project detection. If later you want a linsenkasten domain profile for self-review, create it then (YAGNI).

---

## 3. Simplicity & YAGNI

### F1: Five Lens Agents May Be Too Granular (NEEDS-CHANGES)

**Assessment:** The brainstorm consolidated 8 proposed agents down to 5:

1. `fd-lens-systems` — systems thinking + emergence
2. `fd-lens-decisions` — decision quality + uncertainty + paradox
3. `fd-lens-people` — trust + power + communication + leadership
4. `fd-lens-resilience` — resilience + innovation + constraints
5. `fd-lens-perception` — perception + sensemaking + time + transformation

This consolidation reduced agent count but created uneven scopes. Compare lens counts from brainstorm:

- `fd-lens-systems`: ~28 lenses
- `fd-lens-decisions`: ~35 lenses
- `fd-lens-people`: ~45 lenses (merged groups 3+4)
- `fd-lens-resilience`: ~35 lenses (merged groups 5+6)
- `fd-lens-perception`: ~55 lenses (merged groups 7+8)

`fd-lens-perception` has 55 lenses — nearly 2x the smallest agent. This suggests the consolidation didn't go far enough.

**Slot ceiling impact:**

From F2: "At most 3 lens agents activate for any single document review." This is sensible — 5 lens agents + 7 core agents = 12 total, which hits the slot ceiling. But if only 3 lens agents can run, why create 5?

Consider the triage signals from the brainstorm (lines 132-141):

| Agent | Trigger keywords |
|-------|-----------------|
| fd-lens-systems | "architecture", "design", "system", "feedback", "loop", "emergent" |
| fd-lens-decisions | "decision", "plan", "strategy", "risk", "options", "trade-off" |
| fd-lens-people | "team", "collaboration", "stakeholder", "communication", "culture" |
| fd-lens-resilience | "risk", "failure", "recovery", "dependencies", "constraints" |
| fd-lens-perception | "assumption", "perspective", "bias", "framing", "understanding" |

Notice the overlap:
- "risk" triggers both `fd-lens-decisions` and `fd-lens-resilience`
- "stakeholder" triggers both `fd-lens-people` and implicitly `fd-lens-decisions` (stakeholder analysis is a decision input)
- "system" triggers `fd-lens-systems` but systems thinking also involves perception (how you frame the system) and resilience (system failure modes)

**Most strategy documents will trigger 4-5 agents, but only 3 can run.** This creates triage noise — users see 5 agents, 2 get dropped, they wonder why.

**Alternative consolidation to 3 agents:**

1. **`fd-systems-thinking`** — Merge `fd-lens-systems` + `fd-lens-resilience`
   - Systems dynamics, emergence, feedback loops, resilience, adaptation, constraints
   - ~63 lenses
   - Triggers: "system", "architecture", "design", "resilience", "risk", "failure", "recovery", "constraints"

2. **`fd-decision-quality`** — Keep `fd-lens-decisions`
   - Decision quality, uncertainty, scenario planning, paradox, trade-offs
   - ~35 lenses
   - Triggers: "decision", "plan", "strategy", "options", "trade-off", "uncertainty"

3. **`fd-human-dynamics`** — Merge `fd-lens-people` + `fd-lens-perception`
   - Trust, power, communication, collaboration, cognitive bias, assumptions, framing, sensemaking
   - ~100 lenses (large but coherent)
   - Triggers: "team", "stakeholder", "communication", "culture", "assumption", "perspective", "bias", "framing"

**Rationale for this grouping:**

- **Systems thinking** naturally includes resilience — both are about understanding system behavior over time
- **Human dynamics** combines interpersonal dynamics (trust, power) with cognitive dynamics (bias, perception) — both are about "how humans see and interact"
- **Decision quality** stands alone as the strategic/analytical lens (how to make better choices)

With 3 agents, the sub-ceiling constraint becomes moot — all 3 can run if relevant. The triage is simpler: "Does this document involve systems, decisions, or human dynamics?"

**Counterargument:** 3 agents with ~35-100 lenses each are too broad. Each agent's prompt would be enormous, and findings would be vague ("consider trust dynamics" instead of specific lens recommendations).

**Rebuttal:** The agent prompt doesn't list all 100 lenses — it lists 8-12 **key lenses** (per F1 acceptance criterion). The full lens catalog is accessed via MCP tools (`search_lenses` for dynamic retrieval). The agent file defines the **analytical mission**, not the exhaustive lens list.

Compare to `fd-quality.md`: it covers 5 languages (Go, Python, TypeScript, Shell, Rust), each with 5-8 checks. That's ~35 total checks, but the agent is coherent because it has a unified mission: "quality and style."

Similarly, `fd-human-dynamics` with 100 lenses is coherent because it has a unified mission: "how humans perceive, communicate, and collaborate."

**Recommendation:** Reduce from 5 agents to 3 agents as outlined above. Update F1 acceptance criteria to reflect the new agent list. This simplifies triage, reduces slot ceiling pressure, and removes the need for the sub-ceiling cap in F2.

### Alternative: Start with 1 Agent (Most Conservative)

**Most YAGNI approach:** Start with a single `fd-lens-analyst` agent that:
- Has access to all Linsenkasten MCP tools
- Uses `search_lenses` to dynamically find 5-10 relevant lenses for the document
- Applies those lenses and reports findings

This is the "Option C" from the brainstorm (line 156). The brainstorm dismissed it as "less specialized — one agent doing 8 jobs", but for an MVP this might be the right call.

**Pros:**
- Single agent = single slot, no sub-ceiling needed
- Simplest triage logic (always include for document reviews, exclude for code reviews)
- Validates the MCP integration before investing in 3-5 specialized agents
- Easy to expand later (split the one agent into 3 once usage patterns emerge)

**Cons:**
- Less specialized findings (generic "consider systems thinking" instead of targeted "missing feedback loop analysis")
- Agent prompt must teach the general analytical framework, not specific lens domains

**Recommendation:** If this is the first iteration of lens agents, consider starting with 1 agent. Validate the MCP integration and user value before expanding to 3. The PRD can be phased:

- **Phase 1 (MVP):** 1 lens agent (`fd-lens-analyst`) + MCP integration + triage pre-filters
- **Phase 2 (Specialization):** Split into 3 agents (`fd-systems-thinking`, `fd-decision-quality`, `fd-human-dynamics`) based on Phase 1 learnings

This reduces upfront complexity and defers specialization until usage patterns are known.

---

## 4. Dependency Analysis

The PRD lists dependencies (lines 76-82):

- Linsenkasten MCP server (`packages/mcp`) must be runnable (for F3)
- Flux-drive spec 1.0.0 scoring algorithm (for F2 triage changes)
- Interflux plugin structure and agent format conventions
- Thematic frames data (`lens_frames_thematic.json`) for agent lens assignments

**Hidden dependency:** The PRD doesn't mention where the "8-12 key lenses per agent" (F1) come from. Who curates this list? The brainstorm suggests lens lists (e.g., "fd-lens-systems" gets "Systems Thinking, Compounding Loops, Behavior Over Time Graph..." — line 72), but these are examples, not a complete specification.

**Recommendation:** Add to F1 acceptance criteria:

```
Key lens selection process:
- For each agent, identify 8-12 representative lenses from the consolidated frames
- Prefer lenses with broad applicability (avoid niche/esoteric lenses)
- Include both diagnostic lenses ("what's wrong") and generative lenses ("what's possible")
- Document lens selection rationale in agent file comments (why these 12 out of 288)
```

This makes the curation process explicit and ensures lens selection is intentional, not arbitrary.

---

## 5. Open Questions from PRD (Resolved)

The PRD lists 3 open questions (lines 84-88). Architectural answers:

**Q1: Model choice for lens agents: sonnet or haiku?**

**Answer:** Sonnet. Lens agents perform qualitative analysis (detecting assumptions, finding blind spots, recommending alternative framings). This requires nuanced reasoning and context synthesis — haiku would produce shallow findings. All existing review agents use `model: sonnet` (see `fd-architecture.md` line 4, `fd-quality.md` line 4).

**Q2: Where do lens agents live long-term? In interflux or in Linsenkasten?**

**Answer:** Interflux. Lens agents are part of the review pipeline (they're review agents, not MCP tools). Linsenkasten provides the lens data and search tools; interflux orchestrates the review. This separation of concerns is clean: Linsenkasten = knowledge base, interflux = review orchestration.

If lens agents lived in Linsenkasten, every Linsenkasten update would require republishing the interflux plugin (tight coupling). Keeping them in interflux allows independent evolution.

**Q3: Should lens agents produce "questions to ask" in addition to findings?**

**Answer:** Optional enhancement, not required for F1. The Findings Index format (from `contracts/findings-index.md`) is:

```
- SEVERITY | ID | "Section" | Title
```

Each finding also has a prose body (the detailed analysis). Lens agents can include questions in the prose body without changing the findings format:

```markdown
### Blind Spot: Missing Feedback Loop Analysis

**Section:** Architecture Design
**Lenses:** Compounding Loops, Behavior Over Time Graph

The document describes a growth system but doesn't analyze second-order effects...

**Questions to consider:**
- What happens when resource X becomes scarce?
- How do player strategies adapt over time?
- What feedback loops could create runaway effects?
```

This is stylistic, not structural. F1 doesn't need to specify it — let agents evolve their output format based on user feedback.

---

## Summary of Recommendations

### Must Fix (Blocks Implementation)

1. **F1: Add pre-filter rules** — Lens agents must be pre-filtered out for code/diff inputs, not just scored to 0. Update F2 to include explicit pre-filter logic.

2. **F1: Specify "What NOT to Flag" content** — Current acceptance criterion is too vague. Add specific bullets (no technical issues, no overlap with core agents, no irrelevant lenses).

3. **F1: Reduce agent count to 3 (or 1 for MVP)** — Five agents create triage complexity and require a sub-ceiling cap. Consolidate to 3 agents (`fd-systems-thinking`, `fd-decision-quality`, `fd-human-dynamics`) or start with 1 agent (`fd-lens-analyst`) for MVP.

### Should Fix (Simplification)

4. **F5: Drop domain profile entirely** — It's YAGNI for cross-domain lens agents. Domain profiles are for project-specific agent generation, not plugin agent definitions.

5. **F1: Clarify lens curation process** — Add acceptance criterion for how the "8-12 key lenses" are selected per agent. Document rationale in agent files.

### Optional Improvements

6. **F1: Consider dropping `lens-` prefix** — Use `fd-systems`, `fd-decisions` to match existing `fd-game-design` pattern. The frontmatter description already disambiguates purpose.

7. **F2: Simplify sub-ceiling if agent count reduced** — If F1 reduces to 3 agents, the "max 3 lens agents" cap becomes redundant.

---

## Verdict Reasoning

**Needs-Changes** verdict is based on two blocking issues:

1. Missing pre-filter specification (F2) — Without this, lens agents will appear in code review triage rosters and confuse users. This is a must-fix for correct integration with existing triage logic.

2. Agent granularity (F1) — Five agents with a 3-agent sub-ceiling creates unnecessary complexity. Either reduce to 3 agents (no cap needed) or start with 1 agent (MVP), then expand based on learnings.

The other findings (F5 YAGNI, naming convention, lens curation process) are simplifications that improve the design but don't block implementation.

If the PRD is updated to address the two blocking issues (pre-filters + agent count reduction), the architectural risk drops to **safe** and implementation can proceed.

<!-- flux-drive:complete -->
