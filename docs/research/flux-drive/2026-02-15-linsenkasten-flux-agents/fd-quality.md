### Findings Index
- P1 | QS-001 | "F1 Acceptance Criteria" | Inconsistent severity system reference
- P2 | QS-002 | "Naming Convention" | fd-lens-* namespace conflicts with established fd-{domain} pattern
- P2 | QS-003 | "F1 Acceptance Criteria" | YAML frontmatter description format underspecified
- P3 | QS-004 | "F1 Acceptance Criteria" | Validation check too weak to catch structural issues
- P3 | QS-005 | "Open Questions" | Deferrable questions mixed with blocking decisions
Verdict: needs-changes

## Summary

The PRD establishes a clear direction for integrating Linsenkasten into flux-drive, but has one critical inconsistency (severity system) and two moderate quality issues (naming convention, frontmatter spec). The acceptance criteria are testable but rely on weak validation methods. Open questions are well-framed but not all require pre-planning resolution.

## Issues Found

### 1. **P1 | QS-001 | "F1 Acceptance Criteria" | Inconsistent severity system reference**

**Evidence:**

F1 acceptance criteria line 5 states:
```
- [ ] Each agent uses the "Blind Spot / Missed Lens / Consider Also" severity system
```

But F4 (Lens Severity System) defines:
```
Three severity levels defined: "Blind Spot" (P1-equivalent), "Missed Lens" (P2-equivalent), "Consider Also" (P3-equivalent)
```

The flux-drive spec 1.0.0 findings format contract (`docs/spec/contracts/findings-index.md`) mandates:
```
SEVERITY | ID | "Section Name" | Title
```
Where SEVERITY is `P0|P1|P2|P3`.

**Problem:**

F1 implies lens agents output severity levels as "Blind Spot", "Missed Lens", "Consider Also" (domain-specific names), while F4 defines these as **equivalents** to P1/P2/P3. The spec requires actual `P0|P1|P2|P3` severity markers in findings output.

If agents output `Blind Spot | LS-001 | "Systems Thinking" | Missing feedback loop analysis`, the synthesizer will fail to parse it — it expects `P1 | LS-001 | ...`.

**Fix:**

1. **In F1 (agent file acceptance criteria):** Change line 5 to:
   ```
   - [ ] Each agent uses standard P0-P3 severities and includes "Cognitive Severity" guidance mapping lens findings to priorities (Blind Spot → P1, Missed Lens → P2, Consider Also → P3)
   ```

2. **In F4 (severity system):** Clarify that Blind Spot/Missed Lens/Consider Also are **conceptual mappings** used in agent prompts to guide severity assignment, not output format replacements:
   ```
   - [ ] Agent prompts include cognitive severity guidance: "Blind Spot" (frame entirely absent, critical gap → P1), "Missed Lens" (relevant frame underexplored → P2), "Consider Also" (enrichment opportunity → P3)
   - [ ] Findings format follows spec: `SEVERITY | ID | "Section" | Title` with P0-P3 severity levels
   ```

3. **Add to F5 (domain profile):** Include this mapping in the linsenkasten domain profile's agent specifications so it's documented for future reference.

---

### 2. **P2 | QS-002 | "Naming Convention" | fd-lens-* namespace conflicts with established fd-{domain} pattern**

**Evidence:**

F1 introduces:
- `fd-lens-systems.md`
- `fd-lens-decisions.md`
- `fd-lens-people.md`
- `fd-lens-resilience.md`
- `fd-lens-perception.md`

Existing review agents follow `fd-{domain}` pattern with domain as the noun:
- `fd-architecture` (not `fd-arch-review`)
- `fd-safety` (not `fd-safe-checks`)
- `fd-correctness` (not `fd-correct-analysis`)
- `fd-quality` (not `fd-quality-style`)

The `fd-` prefix establishes namespace. The existing pattern uses domain **nouns** directly: `architecture`, `safety`, `game-design`.

**Problem:**

`fd-lens-systems` introduces **two** levels of categorization: `lens` (the meta-category) + `systems` (the specific domain). This breaks naming consistency.

Possible interpretations:
1. `lens` is the domain, and `systems`/`decisions`/etc. are sub-domains → violates existing single-level pattern
2. `lens-systems` is a compound domain → inconsistent with existing single-word/hyphenated-compound pattern (`game-design` is hyphenated compound, but `lens-systems` implies hierarchy)

**Impact:**

- Mixed naming reduces discoverability (are there `fd-lens-*` and `fd-{domain}` namespaces now?)
- Triage scoring and domain detection logic may need special-casing for `lens` sub-domains
- Agent ID prefixes (`LS`, `LD`, `LP`, `LR`, `LC`?) become ambiguous if multiple `lens-*` agents exist

**Fix:**

**Option A (recommended):** Drop the `lens` prefix, use domain names directly:
- `fd-systems.md` (systems thinking)
- `fd-decisions.md` (decision quality)
- `fd-people.md` (people/team dynamics)
- `fd-resilience.md` (resilience engineering)
- `fd-perception.md` (perception/framing)

Rationale: These are distinct review domains, same as `architecture` or `game-design`. The fact that they use Linsenkasten lenses as their mechanism is an implementation detail, not a namespace concern.

**Option B:** Keep `fd-lens-*` but document it as the canonical **domain name** in the domain profile:
- Domain name: `lens-systems` (not `systems` with `lens` as a modifier)
- Accept that flux-drive now has two naming patterns (original `fd-{noun}` + new `fd-{category}-{noun}`)
- Update domain detection to recognize `lens-systems`, `lens-decisions`, etc. as top-level domains

**Recommendation:** Use Option A. The domains are `systems`, `decisions`, `people`, `resilience`, `perception` — the fact that they're powered by Linsenkasten lenses is stated in the agent prompt, not the filename.

---

### 3. **P2 | QS-003 | "F1 Acceptance Criteria" | YAML frontmatter description format underspecified**

**Evidence:**

F1 line 1:
```
- [ ] Each agent has YAML frontmatter (name, description with examples, model)
```

From existing agents (`fd-architecture.md`, `fd-quality.md`), the `description` field is not just "description with examples" — it's a **structured instruction** with:
1. One-sentence agent summary
2. Multiple `<example>` blocks with `Context`, `user`, `assistant`, and `<commentary>` tags
3. Inline explanation of when to route to this agent

Example from `fd-architecture`:
```yaml
description: "Flux-drive Architecture & Design reviewer — evaluates module boundaries, coupling, design patterns, anti-patterns, code duplication, and unnecessary complexity. Reads project docs when available for codebase-aware analysis. Examples: <example>Context: User is restructuring a monolithic module into separate packages. user: \"I've split the data layer into three packages — can you review the module boundaries?\" assistant: \"I'll use the fd-architecture agent to evaluate the module boundaries and coupling.\" <commentary>Module restructuring directly involves architecture boundaries and coupling — fd-architecture's core domain.</commentary></example> ..."
```

**Problem:**

"description with examples" is too vague. A contributor could write:
```yaml
description: "Reviews systems thinking. Examples: feedback loops, emergence patterns."
```

This satisfies the literal acceptance criterion but is not the structured format the flux-drive routing system expects.

**Fix:**

Update F1 line 1 to:
```
- [ ] Each agent has YAML frontmatter with required fields: `name` (agent identifier), `description` (one-sentence summary + 2-3 <example> blocks with Context/user/assistant/<commentary> structure, following existing agent format), `model` (sonnet or haiku)
```

Add to F1 as a new criterion:
```
- [ ] Each agent's description field includes at least 2 example routing scenarios with commentary explaining why this agent is the right choice (matching format from fd-architecture, fd-quality)
```

---

### 4. **P3 | QS-004 | "F1 Acceptance Criteria" | Validation check too weak to catch structural issues**

**Evidence:**

F1 last line:
```
- [ ] `ls agents/review/*.md | wc -l` returns 12 (7 existing + 5 new)
```

**Problem:**

This validation only checks **file count**. It doesn't verify:
- Files have valid YAML frontmatter
- Files follow the required section structure (First Step, Review Approach, Focus Rules)
- Files contain the lens listings and severity guidance from line 4-5 of F1
- Files don't have broken cross-references or syntax errors

**Impact:**

A file with completely broken frontmatter or missing required sections would still pass this validation.

**Fix:**

Replace or supplement the `wc -l` check with:
```
- [ ] All 5 new agent files pass structural validation: `for f in agents/review/fd-lens-*.md; do grep -q "^---$" "$f" && grep -q "^## First Step" "$f" && grep -q "^## Review Approach" "$f" || echo "FAIL: $f"; done` produces no FAIL output
```

Or define a validation script:
```
- [ ] `scripts/validate-agent-structure.sh agents/review/fd-lens-*.md` passes for all 5 new agents
```

This is a P3 (not P2) because the weak validation is **detectable at review time** — a human reviewer will catch broken agent files immediately. But automated pre-merge validation would be better.

---

### 5. **P3 | QS-005 | "Open Questions" | Deferrable questions mixed with blocking decisions**

**Evidence:**

Open Questions section lists three questions:
1. Model choice (sonnet vs haiku)
2. Where lens agents live long-term (interflux vs linsenkasten)
3. Should agents produce "questions to ask" in addition to findings

**Problem:**

Questions 1 and 2 have **proposed answers** in the question text itself:
- Q1: "Sonnet recommended for nuanced cognitive analysis"
- Q2: "Proposed: interflux, since they're part of the review pipeline"

These aren't open questions — they're **documented decisions with a request for confirmation**. Treating them as open questions implies they must be resolved before planning, which delays F1-F5 work unnecessarily.

Q3 is a genuine open question (no proposed answer), but it's a **feature extension** (adding a "Question" field to findings) that can be deferred to a future iteration.

**Impact:**

- Q1/Q2 block F1 work if interpreted as "must resolve before starting"
- Q3 is scope creep if answered "yes" during this iteration (adds complexity to F4 findings format)

**Fix:**

Move Q1 and Q2 to a "Design Decisions" section:
```markdown
## Design Decisions

1. **Model choice:** Sonnet for all lens agents. Rationale: Cognitive gap detection requires nuanced interpretation of implicit assumptions and frame applicability — haiku's speed advantage is outweighed by analysis depth needs.

2. **Agent location:** Lens agents live in `interflux/agents/review/`, not `linsenkasten/`. Rationale: They are part of the flux-drive review pipeline, not Linsenkasten MCP functionality. Linsenkasten is a **data source** (lens graph + MCP tools), not an agent runner.
```

Reframe Q3 as a future iteration note:
```markdown
## Open Questions (Deferred to Future Iterations)

1. **"Questions to ask" field:** Should lens findings include a "Question" field prompting the author to reconsider? Example: `P2 | LS-001 | "Assumptions" | No second-order effects analysis` → Question: "What happens when your users' behavior changes in response to this feature?" This would make findings more actionable but adds complexity to the findings format. Defer to post-v1 feedback.
```

---

## Improvements

### 1. Add cross-reference integrity check to F1

**Current:** F1 doesn't validate that agents reference **real** Linsenkasten lenses.

**Suggestion:** Add to F1:
```
- [ ] Each agent's lens listing (8-12 lenses) references lenses that exist in `linsenkasten/data/lenses/` or the consolidated frames data (no broken references to non-existent lenses)
```

This prevents agents from listing "Systems Dynamics Lens" when the actual lens name is "Dynamic Systems Thinking" (broken reference).

---

### 2. Clarify F3 MCP wiring dependencies

**Current:** F3 says "interflux to reference Linsenkasten MCP tools" but doesn't specify **how** — is this a plugin.json `mcpServers` entry? A runtime discovery mechanism? Hardcoded in agent prompts?

**Suggestion:** Add to F3:
```
- [ ] `linsenkasten-mcp` added to interflux's `.claude-plugin/plugin.json` mcpServers section with stdio transport pointing to `linsenkasten/packages/mcp/build/index.js`
- [ ] Agent prompts include conditional instructions: "If linsenkasten-mcp tools are available (check via ToolSearch), call search_lenses/detect_thinking_gaps; otherwise use the hardcoded key lenses listed above"
```

---

### 3. Define F2 triage keyword list explicitly

**Current:** F2 says "pre-filter keywords match the triage signals table from the brainstorm" but doesn't inline the list.

**Suggestion:** Add to F2:
```
- [ ] Pre-filter keywords documented in triage config: ["PRD", "brainstorm", "plan", "strategy", "vision", "roadmap", "decision", "framing", "lens", "cognitive", "thinking", ".md file with YAML frontmatter"]
- [ ] File extension filter: lens agents excluded when input extension is [".go", ".py", ".ts", ".tsx", ".rs", ".sh"] (code files)
```

This makes the acceptance criterion **testable** — a reviewer can check the triage config file against this list.

<!-- flux-drive:complete -->
