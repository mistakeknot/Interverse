# Flux-Drive User & Product Review: Linsenkasten Flux Agents PRD

## Primary User

**User:** Developers and AI agent operators working in the Interverse ecosystem who currently use `/interflux:flux-drive` to review code, PRDs, designs, and strategy documents.

**Job to be Done:** Get multi-agent review that catches both technical issues (correctness, security, performance) AND cognitive blind spots (missing perspectives, unexamined assumptions, analytical gaps).

## Findings Index

- P2 | UX-1 | "User Experience" | Cognitive vs technical findings will blend confusingly in synthesis
- P2 | UX-2 | "User Experience" | No clear trigger mechanism for when lens agents activate
- P2 | UX-3 | "User Experience" | MCP failure modes are undefined — user doesn't know what they're missing
- P3 | SCOPE-1 | "Scope & Value" | F0 (moving Linsenkasten) is unrelated scope creep bundled with feature
- P1 | SCOPE-2 | "Scope & Value" | 5 agents + MCP + domain profile + triage in one release is too large
- P2 | PROBLEM-1 | "Problem Validation" | No evidence of user demand for cognitive review of documents
- P3 | PROBLEM-2 | "Problem Validation" | Lens specificity untested — will findings be actionable or philosophical?
- P2 | FLOW-1 | "Missing Edge Cases" | Conflicting recommendations between lens agents and core agents
- P2 | FLOW-2 | "Missing Edge Cases" | Synthesis deduplication strategy vague when lenses overlap
- P3 | VALUE-1 | "User Impact" | Time-to-value unclear — do users act on lens findings immediately?

Verdict: needs-changes

---

## Problem Validation

### Is the stated problem real? (P2 | PROBLEM-1)

The PRD claims flux-drive "has no capability for reviewing thinking quality in strategy documents, PRDs, brainstorms, and plans." This is true — flux-drive currently focuses on code correctness, architecture, performance, and security. The question is: **does anyone want cognitive review?**

**Evidence quality: WEAK**
- No user interviews cited
- No support tickets or feature requests referenced
- No examples of "I ran flux-drive on a PRD and wished it caught X cognitive blind spot"
- The brainstorm is author-driven exploration, not user research

**What would validate this:**
- Track current flux-drive invocations: how many are on `.md` files vs code?
- Survey 5-10 Interverse contributors: "When you review a PRD, what do you wish an AI caught?"
- Benchmark: run existing fd-user-product agent on 3 strategy docs and see if users found the output valuable

**Assumption risk:** Building 5 agents + MCP integration without validating that users want this type of review. If the demand doesn't exist, this is infrastructure for a feature nobody uses.

**Recommendation:** Before building all 5 agents, create ONE lens agent (fd-lens-systems) as a proof-of-concept. Run it on 5 recent Interverse PRDs/brainstorms. If users say "this caught something I missed", scale to the other 4. If they say "interesting but not actionable", pivot.

### Will FLUX lenses produce actionable findings? (P3 | PROBLEM-2)

The FLUX podcast lenses are **descriptive frameworks** ("Systems Thinking", "Pace Layers", "Trust Thermoclines"). The PRD assumes these translate into **prescriptive review findings**. Unproven.

**Example concern:** A lens agent flags "This roadmap doesn't consider Pace Layers." Does the user know what to DO with that? Is the finding:
- "Add a Pace Layers analysis section" (mechanical)
- "Reconsider your 6-month timeline because fast layers can't change slow layers quickly" (strategic)
- "Here's a question to ask: which parts of your system operate on decade timescales?" (Socratic)

The PRD's severity system ("Blind Spot", "Missed Lens", "Consider Also") doesn't clarify **what action the user should take**. The brainstorm suggested findings could include "questions to ask" — that's in Open Question #4 but not committed to in the features.

**Recommendation:** Define the finding format before building agents. Each finding should include:
1. The missing lens (e.g., "Pace Layers")
2. Why it matters for this document (context-specific, not generic)
3. A concrete question or action (not just "consider this lens")

Test this format on 2-3 sample documents manually before automating.

---

## User Experience Review

### Discovery and invocation (P2 | UX-2)

**How do users discover lens agents?**
The PRD says triage will activate lens agents "when input is a document (.md, PRD, brainstorm, plan)" but doesn't define the UX flow:

1. User runs `/interflux:flux-drive path/to/prd.md`
2. Triage scores all agents (7 core + 5 lens = 12 total)
3. User sees a roster with both technical and cognitive agents mixed together
4. User approves, agents run in parallel
5. Synthesis returns findings from both categories

**Friction points:**
- **Information overload:** 12 agents listed in the roster. New users won't understand the difference between "fd-architecture" (code structure) and "fd-lens-systems" (systems thinking). No UI affordance distinguishes them.
- **Unclear value proposition:** Why are there suddenly 5 new agents I've never seen before? What do they do that fd-user-product doesn't already do?
- **Pre-filtering opacity:** The PRD says lens agents "score 0 (excluded) when input is code/diff" but the user never sees this. They just see fewer agents in the roster. No explanation why.

**Missing UX elements:**
- Agent descriptions in the roster should clarify "reviews code structure" vs "reviews thinking quality"
- First-time lens agent activation could show a one-line explainer: "New: cognitive review agents now available for documents (powered by Linsenkasten)"
- Triage output should GROUP agents: "Technical Review (4 agents)" vs "Cognitive Review (3 agents)"

**Recommendation:** Add a `category` field to agent YAML frontmatter (`category: technical | cognitive`) and update the roster display to show agents in labeled groups. This makes the two review types visible and understandable.

### Output clarity (P2 | UX-1)

**What does the user see after synthesis?**

Currently, flux-drive produces:
- `findings.json` — structured findings from all agents
- `summary.md` — prose synthesis + verdict (safe/needs-changes/risky)

With lens agents, the synthesis will contain both technical findings ("Missing error handling in line 47") and cognitive findings ("Missing feedback loop analysis in system design"). These are **different kinds of problems requiring different responses:**

| Finding Type | User Action |
|--------------|-------------|
| Technical | Fix code immediately, create issue, refactor |
| Cognitive | Reconsider strategy, ask stakeholders, revise framing |

**Problem:** The current synthesis format doesn't distinguish these. A user scanning findings.json will see:
```
P2 | ARCH-3 | "Database Module" | Missing connection pooling
P2 | LENS-SYS-2 | "Database Module" | Missing feedback loop for connection saturation
```

Both are P2. Both mention the database. One is a missing feature. One is a missing analytical perspective. **The user must context-switch between "fix this code" and "rethink this design" constantly.**

**Worse:** What if they conflict? fd-performance says "cache aggressively" but fd-lens-resilience says "this system is over-optimized and brittle." Which wins?

**Recommendation:**
1. Synthesis should have TWO sections: "Technical Findings" and "Cognitive Findings"
2. Verdict should be split: "Technical Verdict: safe" + "Cognitive Verdict: needs-changes"
3. When findings conflict, synthesis must explicitly call out the tension and defer to the user

This requires changes to `skills/flux-drive/phases/synthesize.md` which are NOT in the PRD's scope.

### MCP failure transparency (P2 | UX-3)

F3 says lens agents should have "graceful degradation" when the Linsenkasten MCP server is unavailable — they fall back to "hardcoded key lenses from the agent file."

**User mental model problem:** The user invokes flux-drive the same way whether MCP is available or not. They see the same roster, approve the same agents, get findings back. But the **quality of findings secretly varies** based on whether MCP was reachable.

**What the user doesn't know:**
- Did the agent search all 288 lenses or only the 8-12 hardcoded ones?
- Did `detect_thinking_gaps` run, or was that skipped?
- Is this degraded output or full-fidelity output?

**Recommendation:** If MCP is unavailable, the agent should include a note in its findings:
```
NOTE | LENS-SYS-0 | "Meta" | MCP server unavailable — review used fallback lens subset (12/288 lenses). Install linsenkasten-mcp for full coverage.
```

This makes degradation **visible** instead of invisible. Users can decide if they trust the partial review or want to re-run after fixing MCP.

---

## Scope & Value

### F0 is unrelated scope creep (P3 | SCOPE-1)

**F0: Move Linsenkasten into Interverse** has nothing to do with creating lens agents. You could build lens agents without moving Linsenkasten (symlink stays, MCP server works from `/root/projects/Linsenkasten`). You could move Linsenkasten without building lens agents (just a directory migration).

**Why is it bundled?**
The PRD doesn't explain. Likely reasoning: "We're integrating Linsenkasten tightly with interflux, so it should live in the monorepo." But that's an **infrastructure preference**, not a user-facing feature.

**Risk:** F0 is a 30-minute migration task that could fail (git history corruption, symlink breakage, MCP path reconfiguration). It has no user value on its own. If F0 fails, do F1-F5 get blocked?

**Recommendation:** Decouple F0. Either:
1. Move it to a separate "infra" issue (not a feature in this PRD)
2. Make it F5.5 (nice-to-have cleanup after lens agents are validated)
3. Skip it entirely (Linsenkasten stays at `/root/projects/Linsenkasten`, symlink remains)

Bundling unrelated work is classic scope creep. Separate decisions that can be made independently.

### Release is too large (P1 | SCOPE-2)

**F1-F5 in one release:**
- F1: Write 5 agent files (~500 lines of prompt engineering each = 2500 lines)
- F2: Modify triage scoring algorithm (flux-drive spec 1.0.0 changes)
- F3: Configure MCP wiring + graceful degradation
- F4: Define severity mapping + synthesis deduplication
- F5: Write domain profile with detection signals + injection criteria

**Estimated work:** 3-5 days for an experienced interflux contributor. **Risk:** If ANY piece doesn't work (triage scoring breaks, MCP wiring fails, synthesis can't deduplicate), the whole feature is unusable.

**What's the MVP?**

Start with the smallest test that validates the concept:

**Phase 0 (1 day):**
- F1: Create ONE agent (`fd-lens-systems.md`) with hardcoded lenses (no MCP)
- F2: Add basic triage keyword matching (if `.md` file, score lens agent at 2)
- Manually invoke on 3 Interverse PRDs
- Collect user feedback: actionable? valuable? confusing?

**Phase 1 (if Phase 0 succeeds):**
- F1: Add remaining 4 agents
- F3: Wire MCP integration
- F4: Define severity system

**Phase 2 (if Phase 1 proves valuable):**
- F5: Domain profile for injection into core agents
- F2: Full triage scoring overhaul

This breaks the risk into testable increments. If users don't find fd-lens-systems valuable, you've spent 1 day instead of 5.

**Recommendation:** Rewrite the PRD with phased delivery. Phase 0 is the "prove it" release. Phase 1 is "scale it". Phase 2 is "systematize it".

---

## Missing Edge Cases

### Conflicting recommendations (P2 | FLOW-1)

**Scenario:** User reviews a caching design.

- **fd-performance** says: "Aggressive caching needed — current hit rate is 60%, should be 95%"
- **fd-lens-resilience** says: "Over-optimization risk — this design has no crumple zones, will fail catastrophically under load spikes"

Both are correct from their lens. The synthesis must somehow reconcile them. The PRD says synthesis will "deduplicate findings" but doesn't address **contradictory findings**.

**Current synthesis logic (from interflux/skills/flux-drive/phases/synthesize.md):**
1. Validate all agent outputs have completion signals
2. Deduplicate findings (same section + similar title → convergence note)
3. Compute verdict based on severity distribution
4. Generate summary

**Missing:** Conflict detection and resolution. Does synthesis:
- Flag both findings and say "trade-off needed"?
- Elevate to a higher severity because contradiction signals complexity?
- Defer to one agent based on domain relevance?
- Fail and ask the user to clarify priorities?

**Recommendation:** Add F6 (Conflict Resolution Protocol):
- Synthesis detects when findings recommend opposite actions
- Flags them with `CONFLICT |` severity prefix
- Verdict becomes "needs-discussion" (new verdict level) when conflicts exist
- Summary includes: "Contradictory recommendations found — requires strategic trade-off decision"

### Deduplication strategy is vague (P2 | FLOW-2)

F4 says "synthesis phase deduplicates lens findings across agents (same lens flagged by 2 agents → one finding with convergence noted)."

**Problem:** Lenses appear in multiple frames. Example from the brainstorm: "Systems Thinking" appears in Core Systems Dynamics, Emergence & Complexity, and Transformation & Change. If the user's document lacks systems thinking:

- **fd-lens-systems** flags: "Missing Systems Thinking lens"
- **fd-lens-perception** flags: "Missing Systems Thinking lens"

Are these the SAME finding (deduplicate) or DIFFERENT findings (convergence signal)? The current spec doesn't clarify.

**Worse edge case:** What if agents flag the same lens for different reasons?

- **fd-lens-systems** flags: "Missing Systems Thinking — no feedback loops identified in architecture"
- **fd-lens-decisions** flags: "Missing Systems Thinking — decision criteria assume linear causality"

Same lens, different manifestations. Deduplicating these would LOSE information.

**Recommendation:** Deduplication should key on `(lens_name, reasoning_category)` not just `lens_name`. If two agents flag the same lens but point to different sections or different failure modes, keep both. Only deduplicate if the lens AND the specific concern are identical.

Requires changes to synthesis logic (not currently scoped in F4).

---

## User Impact

### Value proposition clarity (P3 | VALUE-1)

**In plain language, what does this feature give users?**

PRD's value prop (implied, not stated): "When you review a document with flux-drive, you'll catch cognitive blind spots in addition to technical issues."

**Questions:**
1. Do users currently feel they're missing cognitive blind spots? (No evidence in PRD)
2. When lens agents flag a blind spot, can users act on it immediately or is it a "think about this later" note? (Unclear from severity system)
3. Is this a "ship-blocker" kind of finding or a "nice to consider" kind of finding? (Severity system suggests both, which is confusing)

**Time-to-value:**
- **Immediate:** User reads "Missing Pace Layers analysis" → adds a section → ships
- **Delayed:** User reads "Missing Systems Thinking" → thinks about it → discusses with team → maybe revises strategy in 3 weeks

If most findings are "delayed" value, users will start ignoring lens agents the same way people ignore linters with philosophical warnings.

**Recommendation:** Before building all 5 agents, define success metrics:
- **Actionability rate:** What % of lens findings lead to immediate document edits?
- **Discovery rate:** What % of lens findings surface something the user genuinely missed (vs. "I already knew this")?
- **Annoyance rate:** What % of lens findings are marked "not applicable" or "too abstract"?

Run Phase 0 (one agent, 3 documents) and measure these. If actionability < 50%, the feature needs design changes before scaling.

---

## Recommendations

### Minimum Viable Version (Phase 0)

**Goal:** Prove lens review is valuable before building the full system.

**Scope:**
1. Create ONE agent: `fd-lens-systems.md`
   - Hardcoded 8-12 key lenses (no MCP dependency)
   - Simple severity system: "Blind Spot" (P1), "Consider" (P3)
   - Output includes concrete questions, not just "missing lens X"

2. Triage: If file is `.md`, score fd-lens-systems at 2 (keyword matching not needed for Phase 0)

3. Manually invoke on 3 recent Interverse documents:
   - A PRD (e.g., this Linsenkasten PRD)
   - A brainstorm
   - An architecture doc

4. Collect feedback from 3 users:
   - Did you learn something new?
   - Did you act on any finding?
   - Was the output confusing or helpful?

**Success criteria:** 2/3 users say "I made a change based on a lens finding" → proceed to Phase 1.

**Failure criteria:** Users say "interesting but not actionable" → pause and redesign finding format before scaling.

### If Phase 0 Succeeds: Phase 1 Scope

1. Add remaining 4 agents (fd-lens-decisions, fd-lens-people, fd-lens-resilience, fd-lens-perception)
2. Wire Linsenkasten MCP integration (F3)
3. Implement severity mapping and synthesis changes (F4)
4. Add conflict detection to synthesis (NEW: F6)

**Hold F5 (domain profile) for Phase 2.** It's valuable but not blocking. Core lens agents should prove their value before injecting lens thinking into existing agents.

### Long-Term: Unanswered Strategic Questions

1. **Who maintains lens agent prompts?** The FLUX podcast publishes new lenses monthly. Do agents get updated? Who decides which lenses are "key" vs "consider also"?

2. **What happens when lens agents conflict with core agents?** This needs a design decision, not just synthesis deduplication.

3. **Should lens agents be invocable standalone?** E.g., `/interflux:lens-review path/to/doc.md` runs ONLY cognitive agents, not technical agents? Might reduce cognitive load.

4. **Can non-Interverse users use this?** If someone outside the ecosystem installs interflux, do lens agents work (via MCP) or do they need the full Linsenkasten setup?

---

## Final Verdict: needs-changes

**Summary:**

The PRD proposes a valuable extension to flux-drive — cognitive review alongside technical review. However:

1. **No user demand validated** (P2 | PROBLEM-1) — assumption that users want this
2. **Scope too large for first release** (P1 | SCOPE-2) — 5 agents + MCP + triage + domain profile is 3-5 days of work with high integration risk
3. **UX gaps** (P2 | UX-1, UX-2, UX-3) — users won't understand cognitive vs technical findings, MCP degradation is invisible
4. **Missing edge case handling** (P2 | FLOW-1, FLOW-2) — conflicting recommendations and deduplication strategy undefined
5. **Unrelated scope creep** (P3 | SCOPE-1) — moving Linsenkasten is bundled unnecessarily

**What needs to change:**

1. **Start with Phase 0:** Build ONE lens agent, test on 3 documents, validate user demand before scaling
2. **Define finding format:** Lens findings must include concrete questions/actions, not just "consider this lens"
3. **Separate F0:** Moving Linsenkasten is unrelated — decouple from this feature
4. **Add conflict resolution:** Synthesis must detect when lens agents and core agents recommend opposite actions
5. **Make MCP degradation visible:** Users should know when they're getting partial lens coverage

**This is a promising idea that needs de-risking before committing to the full build.**

<!-- flux-drive:complete -->
