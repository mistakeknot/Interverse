# Flux-drive User & Product Review: Intermap Extraction PRD

**Reviewer:** flux-drive User & Product Reviewer
**Date:** 2026-02-16
**PRD:** `/root/projects/Interverse/docs/prds/2026-02-16-intermap-extraction.md`
**Bead:** iv-aose

---

## Executive Summary

**Primary User:** Claude Code agents (AI coding assistants) working across multi-project workspaces
**Job to Complete:** Understand project structure and relationships without reading 1.4 MB of monolith docs or trial-and-error tooling

**Product Decision:** Do NOT ship intermap as currently scoped. The value proposition is weak, scope is unbounded, and the migration creates adoption barriers that outweigh benefits.

**Recommendation:** Either (1) radically simplify to a project registry only (F4 alone, no extraction), or (2) defer until a clear user demand signal emerges with measurable success criteria.

---

## Problem Validation

### Evidence Quality: Weak

**What the PRD claims:**
> "tldr-swinton is a 1.4 MB monolith conflating two concerns: file-level code context (its identity) and project-level architecture analysis (call graphs, dead code, impact analysis)."

**Questions the PRD doesn't answer:**
1. How often do agents actually use the 6 project-level tools (`arch`, `calls`, `dead`, `impact`, `change_impact`, `diagnostics`)? No usage frequency data.
2. What user pain does the 1.4 MB size cause? The PRD assumes "monolith = bad" without evidence of load time issues, memory problems, or confusion.
3. Who complained about conflation? No user quotes, no observed workflow failures.

**Missing baselines:**
- Token efficiency delta: How much do the 6 tools contribute to context size vs signal? If they're rarely used, extraction won't improve anything.
- Load time: Does the 1.4 MB size actually slow down Claude Code sessions? (MCP servers load once per session.)
- Tool discovery: Are agents failing to find the right tool because tldr-swinton's surface area is too large?

**Risk:** This is a solution looking for a problem. The PRD starts from "monolith = bad" architecture preference, not observed user pain.

---

## User Flow Analysis

### Discovery: Undefined

**The PRD never explains how agents will discover intermap exists.**

Current state (tldr-swinton):
- SessionStart hook provides project summary automatically
- `/tldrs-*` commands are prefixed and namespaced
- Skills auto-trigger on relevant tasks ("Before reading code for bugs...")

Proposed state (intermap + tldr-swinton):
- Two plugins with overlapping domains
- No guidance on when to use `intermap` vs `tldr-swinton`
- No discoverability mechanism (no SessionStart hook mentioned in F6)

**Critical gap:** F6 mentions "Skills directory with `/intermap:status` skill" but provides no trigger conditions. When would an agent invoke this skill instead of `/tldrs-diff`?

### Decision Flow: Ambiguous

**Agent needs to understand a multi-project codebase. Which tool?**

| Scenario | Current (tldr-swinton) | Proposed (split) | Decision Clarity |
|----------|------------------------|------------------|------------------|
| "What files changed recently?" | `tldrs diff-context` | `tldrs diff-context` (unchanged) | Clear |
| "Show me function X" | `tldrs context X` | `tldrs context X` (unchanged) | Clear |
| "What calls function X?" | `tldrs calls X` | `intermap ???` | **Broken** |
| "Is this function dead code?" | `tldrs dead` | `intermap ???` | **Broken** |
| "Show project structure" | `tldrs structure` | ??? | **Ambiguous** |
| "Which projects exist?" | Trial and error | `intermap project_registry` | **Better, but...**  |

**The split creates tool-choice paralysis:**
- 4 scenarios above degrade from "clear" to "broken/ambiguous"
- Only 1 scenario improves (project discovery)
- Agents must now know two plugins, two command sets, two mental models

**Missing from PRD:** How will agents learn the boundary between intermap and tldr-swinton?

---

## Migration Risk: High

### Coexistence Period

F3 says "Remove moved tools from tldr-swinton" — but the PRD doesn't address the transition:

1. Machines with only tldr-swinton installed (most agents currently): Tools disappear with no replacement.
2. Machines with both plugins: Which one takes precedence? Do commands conflict?
3. Machines with only intermap: Can't do file-level analysis anymore.

**No rollout plan.** The PRD treats this as a single-step cutover, but the ecosystem has:
- 22 plugins that may depend on tldr-swinton tools
- Unknown number of agent workflows using `tldrs calls` or `tldrs impact`
- No deprecation warnings, no migration guide

**User-facing failure mode:** Agent tries `/tldrs-calls` → "command not found" → workflow stalls → user must manually install intermap and re-learn tooling.

### Backward Compatibility

**Open Question 2 is a red flag:**
> "project_index.py dependencies: It imports ast_cache, ast_extractor, hybrid_extractor. These are 300+ KB. Options: (a) vendor minimal stubs, (b) simplify ProjectIndex to not need them, (c) call tldr-swinton's daemon for extraction."

This means the extraction creates a **hard dependency loop** if option (c) is chosen:
- intermap calls tldr-swinton for AST extraction
- But intermap is supposed to be "independent"
- If tldr-swinton isn't installed, intermap's call graph tools break

**The PRD punts on this:** "Leaning: simplify" — but simplification wasn't scoped in any feature. F2 acceptance criteria say "dependency resolved" but don't define how.

---

## Value Proposition: Unclear

### Who Benefits and How Much?

**The PRD claims three benefits:**

1. **Smaller tldr-swinton:** From 1.4 MB to ~1.19 MB (209 KB removed).
   - **Impact:** Negligible. MCP servers load once per session. A 15% size reduction doesn't improve load time, memory, or UX in any measurable way.

2. **Focused identity for tldr-swinton:** "file/symbol-level context only"
   - **Impact:** Unclear. Does this improve tool discoverability? Usage data would be needed. The PRD provides none.

3. **New capabilities:** project registry + agent overlay
   - **Impact:** F4 and F5 are genuinely new. But they could be added to tldr-swinton without extracting anything.

**Net value:** The extraction (F2, F3) creates cost with no proven benefit. The new features (F4, F5) could ship independently.

### Opportunity Cost

**What could agents be doing instead?**
- Improving tldr-swinton's token efficiency (the core value prop)
- Building agent-facing diagnostics for context budget exhaustion
- Creating workflows for cross-project refactoring (the pain F4/F5 hint at)

**This PRD spends 6 features on plumbing (F1-F3, F6) to unlock 2 features (F4, F5) that don't require the plumbing.**

---

## Scope Analysis

### Bounded vs Unbounded

**Well-bounded (good):**
- F1: Go MCP scaffold — clear acceptance criteria, follows existing patterns (interlock)
- F4: Project registry — pure Go, no Python dependencies, clear deliverable
- F6: Marketplace packaging — checklist-driven

**Unbounded (risky):**
- F2: "Resolve dependencies" — 3 open questions, no concrete plan
- F3: "Clean up dead imports" — scope creep magnet (what counts as "dead"?)
- F5: Agent overlay — "graceful degradation if intermux unavailable" is underspecified

**Open Questions reveal scope uncertainty:**
- OQ1: "Vendor or extract to shared package?" — architectural decision, not implementation detail
- OQ2: "Simplify, vendor, or call tldr-swinton?" — three different designs with different trade-offs
- OQ3: "Daemon or one-shot?" — performance vs complexity tradeoff, punted to v0.2

**Red flag:** A "v0.1" PRD with 3 unresolved design questions is not actually v0.1. It's a sketch.

---

## Edge Cases and Missing Flows

### What Happens During Migration?

**Scenario 1: Agent has tldr-swinton 0.6.x (pre-split)**
- User: "Show me what calls this function"
- Agent: Runs `/tldrs-calls` successfully
- *One week later, tldr-swinton auto-updates to 0.7.0 (post-split)*
- User: "Show me what calls this function"
- Agent: `/tldrs-calls` → command not found
- **Recovery path:** None defined in PRD. User must manually discover intermap exists and install it.

**Scenario 2: Agent has both plugins installed**
- Command namespace collision? No — PRD assumes `/intermap:*` prefix. But...
- Which plugin owns "project-level analysis"? Documentation will diverge.
- SessionStart hook in tldr-swinton still references removed tools? Not addressed.

**Scenario 3: Agent has only intermap (new install)**
- Can't do file-level symbol context → must also install tldr-swinton
- But intermap is marketed as "project-level analysis" → why does it need a second plugin?
- **User confusion:** "I installed the project map plugin, why can't it show me function definitions?"

### What About Cross-Plugin Workflows?

**F5 (agent overlay) depends on intermux being available.** The PRD says "graceful degradation" but doesn't define:
- What does degraded output look like?
- How does an agent know it's degraded?
- Should the agent retry with a different tool?

**Example workflow gap:**
1. Agent runs `intermap agent_map` to see which agents are working on which projects
2. intermux is unreachable (network issue, service restart)
3. `agent_map` returns project list with no agent data
4. **What should the agent do?** Fall back to manual file inspection? Notify the user? The PRD is silent.

---

## User Segmentation

### Who Gets Helped vs Harmed?

**New users (net negative):**
- Must now install two plugins for full code analysis
- Command surface area increased (intermap + tldr-swinton)
- No clear mental model of the split

**Power users (neutral to negative):**
- Familiar workflows break (`/tldrs-calls` disappears)
- Must re-learn tool boundaries
- No new capabilities they couldn't get by extending tldr-swinton

**Clavain hub agents (slight positive):**
- F5 agent overlay could improve multi-agent coordination
- But Clavain already has interlock for file-level coordination — does project-level matter?

**Solo agents (negative):**
- Overhead of two plugins for basic project navigation
- No benefit from F5 (agent overlay) if working alone

---

## Terminal/UX Considerations

### Discoverability

**tldr-swinton has strong discoverability:**
- Prefixed commands (`/tldrs-*`)
- SessionStart hook provides automatic context
- Skills auto-trigger on task types

**intermap has weak discoverability (as spec'd):**
- F6 mentions `/intermap:status` skill but no trigger conditions
- No SessionStart hook
- No guidance on when agents should invoke it

**Result:** Most agents will never discover intermap exists unless explicitly told by users.

### Help Text and Affordances

**Missing from PRD:**
- What does `/intermap:status` output look like?
- How do agents know when to use `project_registry` vs `resolve_project`?
- What error messages guide agents to install intermap if they try a removed tldr-swinton command?

**Without these, agents will:**
1. Try `/tldrs-calls` (muscle memory)
2. Get "command not found"
3. Stall and ask the user what to do

**No self-service recovery path.**

---

## Product Validation Failures

### Problem Definition

**PRD claim:** "tldr-swinton is a monolith conflating two concerns"

**Counter-evidence from documentation:**
- tldr-swinton's AGENTS.md shows clear tool categorization (extract, structure, find, calls, impact, etc.)
- Usage patterns suggest agents understand the boundaries
- No evidence agents are confused by "monolith" status

**The real problem (unstated):** No central project registry for multi-project workspaces. F4 solves this directly without requiring extraction.

### Solution Fit

**Does the 6-feature extraction solve the stated problem?**

- F1 (Go scaffold): Plumbing, not user value
- F2 (extract Python): Increases maintenance burden, no user benefit
- F3 (remove tools): Breaks existing workflows
- F4 (project registry): **YES — directly solves multi-project navigation**
- F5 (agent overlay): **MAYBE — nice-to-have for multi-agent workflows**
- F6 (packaging): Plumbing, not user value

**3 features are plumbing, 1 breaks things, 2 add value.** The PRD is 67% overhead.

### Alternative: Ship F4 and F5 as tldr-swinton Features

**Why not add project_registry and agent_map to tldr-swinton directly?**

Pros:
- No migration pain
- No namespace fragmentation
- Same Go MCP server pattern (F1 still applies)
- Same new capabilities (F4, F5)

Cons:
- tldr-swinton grows from 1.4 MB to ~1.6 MB
- Slightly broader scope (but already handles "code context" at all levels)

**The PRD never evaluates this alternative.** It assumes extraction is the only path.

---

## Success Metrics: Missing

**The PRD provides zero measurable success criteria.**

How will we know if intermap is successful?
- Adoption rate? (No target)
- Usage frequency of F4/F5 tools? (No baseline)
- Reduction in "command not found" errors? (No tracking)
- Agent workflow completion rate? (No before/after comparison)

**Without metrics, this is a hope-driven feature.**

---

## Recommendations

### Option 1: Radically Simplify (Recommended)

**Ship only F4 (project registry) as a standalone plugin.**

Scope:
- Pure Go, no Python dependencies
- `project_registry` and `resolve_project` MCP tools
- No extraction from tldr-swinton (leave it intact)
- Lightweight (< 100 KB), fast, zero migration pain

Benefits:
- Solves the real user pain (multi-project navigation)
- No breaking changes
- Can be built and validated in 1-2 days
- Clear value proposition

Defer:
- F5 (agent overlay) until there's evidence agents need it
- Extraction (F2, F3) unless usage data shows the 6 tools are rarely used

### Option 2: Defer Until Demand Signal Emerges

**Wait for concrete user pain before building.**

Success gate before resuming:
- 3+ agent workflows documented where project-level tools are critical
- Usage telemetry showing `tldrs calls/impact/dead` are high-frequency
- User complaints about tldr-swinton size or scope

**This avoids speculative architecture.**

### Option 3: Ship as Scoped with Major Revisions

**If extraction is still desired, address these gaps:**

1. **Add migration plan:**
   - Deprecation warnings in tldr-swinton 0.6.x
   - Compatibility shim (redirect `/tldrs-calls` → `intermap calls`)
   - 2-release deprecation cycle before removal

2. **Resolve open questions before starting:**
   - OQ1, OQ2, OQ3 must have concrete answers in PRD
   - Dependency resolution (F2) must be fully designed

3. **Define success metrics:**
   - Target: 80% of agents with tldr-swinton also install intermap within 1 month
   - Measure: Zero increase in "command not found" errors post-migration
   - Abort criterion: If adoption < 50% after 2 months, revert extraction

4. **Add discoverability:**
   - SessionStart hook in intermap (like tldr-swinton's)
   - Clear trigger conditions for `/intermap:status` skill
   - Error messages in tldr-swinton guiding to intermap

5. **Scope out F5 agent overlay:**
   - Define degraded output format
   - Document fallback workflows
   - Test without intermux available

---

## Product Decision Checklist

| Criterion | Status | Notes |
|-----------|--------|-------|
| **Problem validated with evidence** | ❌ FAIL | No usage data, no user complaints, assumed pain |
| **Solution directly addresses problem** | ⚠️ PARTIAL | F4 does, but requires 5 other features as tax |
| **Alternatives evaluated** | ❌ FAIL | Never considered adding F4/F5 to tldr-swinton |
| **Migration plan exists** | ❌ FAIL | No deprecation, no compatibility layer |
| **Success metrics defined** | ❌ FAIL | No adoption targets, no usage baselines |
| **Scope is minimal** | ❌ FAIL | 67% plumbing overhead for 2 features |
| **User flows documented** | ⚠️ PARTIAL | Happy path only, no error/degraded states |
| **Edge cases handled** | ❌ FAIL | Coexistence, dependency loops, graceful degradation undefined |

**Overall: NOT READY TO SHIP**

---

## Final Verdict

**Do not proceed with this PRD as written.**

The extraction solves an unvalidated problem (monolith size) while creating real user pain (broken workflows, fragmented tooling, discovery burden). The valuable parts (F4, F5) can ship without the extraction.

**Path forward:**
1. Ship F4 (project registry) as a lightweight standalone plugin
2. Gather 3 months of usage data on tldr-swinton's 6 project-level tools
3. If data shows high usage + user complaints about size, revisit extraction with a real migration plan

**Until then, this is a solution looking for a problem.**
