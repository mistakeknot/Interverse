---
title: "User & Product Review: Flux-Drive Document Slicing"
date: 2026-02-16
reviewer: fd-user-product
document: docs/prds/2026-02-16-flux-drive-document-slicing.md
status: complete
---

# User & Product Review: Flux-Drive Document Slicing

## Primary User & Job-to-be-Done

**Primary users:**
1. **AI review agents (fd-*)** — consume sliced documents to produce domain-specific findings
2. **Human developer** — triggers flux-drive review, waits for results, reads synthesis

**Job-to-be-done:**
- AI agents: "Review this document for issues in my domain without wading through irrelevant sections"
- Human: "Get high-quality multi-agent review results faster and cheaper"

## UX Review

### For AI Agents (Document Consumers)

#### Information Hierarchy
**GOOD:** Priority vs context section distinction is clear — full content where relevant, 1-line summaries elsewhere.

**CONCERN:** The metadata header format is information-dense but lacks progressive disclosure:
```
[Document slicing active: X priority sections (Y lines), Z context sections (W lines summarized)]
```

This is stats-first, not orientation-first. Agent sees numbers before understanding what's been filtered. Better:
```
[You are reviewing: X priority sections relevant to {agent-domain}]
[Other sections summarized: Z context sections (W lines)]
```

**MEDIUM PRIORITY** — current format works but requires agents to parse stats before understanding scope.

#### Error Recovery & Confidence

**GOOD:** Footer includes explicit escape hatch:
> If you need full content for a context section, note it as "Request full section: {name}" in your findings.

**GAP:** No guidance on WHEN to request full sections. Agents may:
- Over-request (defeating slicing efficiency)
- Under-request (missing issues because summary was insufficient)

**MISSING USER FLOW:** What happens after an agent requests a section?
- Does synthesis phase retrieve it automatically?
- Does human see the request and manually re-run?
- Is there a Phase 3.5 "fulfillment" step?

PRD says "Synthesis phase (Phase 3) handles `Request full section` annotations" but provides zero detail on the mechanism or user-visible outcome.

**HIGH PRIORITY** — This is a critical recovery path with no implementation spec.

#### Classification Transparency

**CONCERN:** Agents have no visibility into WHY a section was classified as context vs priority. If misclassification occurs, agents can't diagnose whether it's:
- A legitimate edge case
- A classification prompt tuning issue
- A confidence threshold problem

**RECOMMENDATION:** Include confidence scores in section metadata:
```
- **Architecture Overview**: Discusses module boundaries (confidence: 0.42) (150 lines)
```

Low-confidence context sections are prime candidates for "Request full section" — but agents don't know which ones are borderline.

**MEDIUM PRIORITY** — Improves agent decision-making on when to request full sections.

#### Cross-Cutting Agent Experience

**DESIGN CHOICE:** fd-architecture and fd-quality always get full document.

**QUESTION:** Is this evidence-based or assumption-based?
- If these agents consistently need full context, this is correct
- If they only occasionally need cross-cutting view, they're paying 100% cost for 20% need

**DATA NEEDED:** After 5-10 reviews, check if cross-cutting agents ever flag issues in sections that domain agents marked as context. If <10% of their findings come from "context" sections, the exemption is correct. If >30%, the blanket exemption is wasteful.

**LOW PRIORITY** — Requires post-launch data to validate.

### For Human Developer (Review Trigger)

#### Discoverability & Mental Model

**CONCERN:** Document slicing activates silently at 200-line threshold. Human developer has no visibility into:
- Which agents got sliced content vs full document
- Whether classification succeeded or fell back to full document
- What percentage of content each agent saw

**CURRENT STATE:** Developer triggers `/flux-drive`, waits, reads synthesis. Slicing is invisible infrastructure.

**TRADE-OFF:**
- **Pro:** Simplicity — user doesn't need to understand slicing internals
- **Con:** User can't diagnose quality issues caused by over-aggressive slicing

**RECOMMENDATION:** Add one line to synthesis report header:
```
[Slicing: 3/5 agents received targeted content (avg 35% of document), 2/5 full document]
```

This gives users a confidence signal without requiring them to understand mechanics.

**MEDIUM PRIORITY** — Helps users build mental model of what happened.

#### Adoption Barrier

**GOOD:** Zero adoption barrier — slicing activates automatically at 200-line threshold.

**RISK:** If slicing degrades quality, users have no way to disable it per-review. No escape hatch like `--no-slicing` flag.

**RECOMMENDATION:** Add environment variable override:
```bash
FLUX_DRIVE_NO_SLICING=1 /flux-drive path/to/doc.md
```

This provides safety valve for debugging without adding CLI complexity.

**LOW PRIORITY** — Likely rare, but critical for trust recovery if slicing misfires.

#### Time-to-Value

**QUESTION:** Does slicing make reviews FASTER or just CHEAPER?

PRD claims 50-70% token reduction but says nothing about latency. If agents run in parallel (as launch.md suggests), slicing saves cost but NOT time — bottleneck is slowest agent, not total tokens.

**CLARIFY:** Is the value prop "cheaper reviews" or "faster reviews"? If just cheaper, state it explicitly. If faster, prove it (e.g., "Smaller context → faster model inference → 20% faster results").

**MEDIUM PRIORITY** — Value prop clarity affects how users perceive success.

## Product Validation

### Problem Definition

**EVIDENCE QUALITY:** Strong (data-backed).
- Token flow audit identifies this as P0 optimization
- Brainstorm shows 5-variant experiment with concrete savings measurements
- "50-75k tokens for typical 5-agent review" is specific and measurable

**USER PAIN:** Indirect.
- Direct pain: High token cost (felt by system operator, not individual developer)
- Indirect pain: Slower reviews if token bloat causes rate limits

**SEGMENT CLARITY:** Slightly confused.
- PRD says "users are AI agents and human developer"
- But human developer doesn't feel token cost directly — it's an infrastructure/ops concern
- Real user is: "Developer who wants fast, cheap, high-quality reviews"

**RECOMMENDATION:** Reframe problem as "Enable more frequent reviews by reducing cost per review" — this makes the user benefit explicit.

**MEDIUM PRIORITY** — Problem is real, but user-facing value prop could be sharper.

### Solution Fit

**DOES IT SOLVE THE PROBLEM?** Yes — 50-70% token reduction directly addresses "each agent gets full document" waste.

**ALTERNATIVES CONSIDERED:** Yes — 5 variants tested:
- Python script (0 tokens, fragile)
- Inline LLM (4.7k overhead, marginal savings)
- Codex spark (chosen — semantic + near-zero cost)

**SCOPE CREEP CHECK:** Clean.
- F0: MCP server (reusable infra)
- F1: Classification (core logic)
- F2: File generation (output)
- F3: Integration (wiring)

No feature bundling. Non-goals are clear.

**HIDDEN SCOPE:** Open Question #1 (classification prompt tuning) is NECESSARY, not optional. Prompt engineering is always 30-50% of classifier implementation effort. Should be explicit in F1 acceptance criteria, not tucked in "Open Questions."

**MEDIUM PRIORITY** — Prevents underestimation of F1 effort.

### Opportunity Cost

**EFFORT ESTIMATE:** Implicit "days" but no breakdown.
- F0 (MCP server): 1-2 days (Go boilerplate + systemd)
- F1 (classification): 2-3 days (includes prompt tuning — see above)
- F2 (file gen): 0.5 day (templating)
- F3 (integration): 0.5 day (wiring)
- **Total: 4-6 days**

**PRIORITY VALIDATION:** This is bead iv-7o7n (P0 from token efficiency review). No higher-priority items on roadmap.

**TRADE-OFF:** Building always-on interserve MCP server (F0) is infrastructure investment that unlocks future beads (iv-hyza, iv-kmyj). This is 30% of total effort but benefits multiple beads.

**RECOMMENDATION:** Explicitly call out F0 as "infrastructure bet with multi-bead ROI" to justify the overhead.

**LOW PRIORITY** — Opportunity cost is sound, just make it explicit.

### Success Validation

**MEASURABLE OUTCOME:** Yes — "50-70% reduction in Claude tokens per review."

**HOW TO MEASURE:**
1. Instrument Phase 2 launch to log per-agent token counts
2. Run 5 reviews with slicing
3. Run same 5 reviews with `FLUX_DRIVE_NO_SLICING=1`
4. Compare

**MISSING:** Quality validation. Token reduction means nothing if finding quality degrades.

**RECOMMENDATION:** Add success criterion:
> After 10 sliced reviews, synthesis phase reports ≤5% increase in "Request full section" annotations compared to full-document baseline.

If agents constantly request full sections, slicing is creating friction without saving net tokens.

**HIGH PRIORITY** — Prevents shipping a feature that optimizes the wrong metric.

## User Impact

### Value Proposition Clarity

**CURRENT:** "Reduce token cost by 50-70% via per-agent document slicing."

**FOR WHOM:**
- Infrastructure operator: Clear win (lower costs)
- Developer triggering review: Unclear — do they get results faster? Cheaper? Same quality?

**RECOMMENDATION:** User-facing value prop should be:
> "Enable more frequent, higher-quality reviews by reducing cost per review by 50-70%."

This frames cost reduction as enabler for MORE reviews, not just CHEAPER reviews.

**MEDIUM PRIORITY** — Affects how feature is perceived and adopted.

### Segmentation & Harm

**NEW USERS:** No change — they have no baseline to compare against.

**EXISTING USERS:** Potential quality regression if slicing is too aggressive. Mitigation: fallback to full document on classification failure + "Request full section" escape hatch.

**ADVANCED USERS:** May want finer control (per-agent thresholds, custom domain keywords). Not in scope for v1 — correct decision.

**WHO COULD BE HARMED:**
- Users with documents that don't fit fd-* domain model (e.g., legal contracts, academic papers) — domain agents may all score low → no priority sections → all context summaries → garbage output
- Users who review highly interconnected documents where "context" sections are actually critical

**MITIGATION:** 80% threshold rule (if priority sections cover ≥80% of doc, send full doc) handles interconnected-document case. But "non-domain-fit" case has no guard rail.

**RECOMMENDATION:** Add F1 acceptance criterion:
> If no agent's priority sections exceed 10% of total doc lines, classification MUST fall back to full document for all agents (likely a domain mismatch).

**HIGH PRIORITY** — Prevents catastrophic misclassification.

### Discoverability & Adoption Barriers

**DISCOVERABILITY:** Automatic at 200-line threshold — perfect. No user action required.

**ADOPTION BARRIERS:** None for greenfield. For existing users, risk is silent quality change.

**RECOMMENDATION:** Add one-time notification on first sliced review:
```
[flux-drive] Document slicing active (200+ lines detected). Agents receive targeted content.
Set FLUX_DRIVE_NO_SLICING=1 to disable. See docs/flux-drive/slicing.md for details.
```

This makes the activation visible without adding permanent noise.

**LOW PRIORITY** — Nice-to-have, not critical.

### User-Side Failure Modes

| Failure | User Experience | Recovery Path | Missing in PRD? |
|---------|----------------|---------------|-----------------|
| Classification fails | All agents get full doc (fallback) | Automatic | No — covered in F2 |
| Misclassification (section wrongly marked context) | Agent output quality degrades | Agent notes "Request full section" | **YES — no Phase 3 fulfillment spec** |
| Codex spark unavailable | Falls back to full document | Automatic | No — covered in F0 |
| Agent requests 5+ sections | Slicing created friction, not savings | ??? | **YES — no threshold for "slicing failed" signal** |

**CRITICAL GAP:** What happens if an agent requests 3+ full sections in a single review? This suggests classification was bad. Does synthesis phase:
- Surface this to user as "slicing may have degraded quality"?
- Track it for prompt tuning?
- Ignore it?

**HIGH PRIORITY** — Without this, users can't distinguish "good slicing" from "bad slicing that agents worked around."

## Flow Analysis

### Happy Path: Document >200 Lines, Classification Succeeds

1. User: `/flux-drive path/to/doc.md`
2. Phase 1 (triage): Detects 500 lines → `slicing_eligible: yes`
3. Phase 2 (launch):
   - Step 2.1c Case 2 triggers `classify_sections` MCP tool
   - Codex spark returns section assignments
   - Per-agent temp files written (3 sliced, 2 full)
   - Agents dispatched in parallel
4. Agents: Review priority sections, note any "Request full section: X"
5. Phase 3 (synthesis): Merges findings, handles section requests (HOW?)
6. User: Reads synthesis

**UNDEFINED TRANSITION:** Step 5 → "handles section requests" has no implementation spec. Options:
- **A.** Synthesis includes agent's request verbatim in output (user manually re-runs if needed)
- **B.** Synthesis auto-retrieves requested sections and re-prompts agent
- **C.** Synthesis notes the request as metadata for future runs (knowledge layer input)

PRD says nothing. This is a critical flow gap.

**HIGH PRIORITY.**

### Error Path: Classification Fails (MCP Timeout)

1. User: `/flux-drive path/to/doc.md`
2. Phase 2 (launch): `classify_sections` MCP call times out
3. Fallback: Writes full document for all agents
4. Agents: Review as if slicing never happened
5. User: No visible indication that slicing was attempted and failed

**MISSING STATE:** User has no way to know slicing failed. Synthesis report should note:
```
[Slicing: Attempted but failed (MCP timeout). All agents received full document.]
```

**MEDIUM PRIORITY** — Helps users understand why token costs were higher than expected.

### Edge Case: 80% Threshold Triggered for All Agents

1. Classification: All agents have ≥80% priority sections
2. Fallback: All agents get full document (no slicing)
3. User: No visible indication that slicing was bypassed

**QUESTION:** Is this a failure or a success?
- If doc is genuinely dense/cross-cutting, bypassing slicing is correct
- If classification is too generous (marking everything priority), it's a bug

**RECOMMENDATION:** Track and surface this:
```
[Slicing: Bypassed — all agents required ≥80% of content (doc is highly cross-cutting)]
```

**LOW PRIORITY** — Rare edge case, but useful diagnostic.

### Missing Flow: Agent Onboarding (First Sliced Review)

**CONCERN:** fd-* agents have never seen sliced documents before. Their prompts assume full documents. Do they need:
- Explicit instruction on how to interpret `[Document slicing active: ...]` header?
- Guidance on when to use "Request full section" vs. infer from summaries?
- Examples of well-formed section requests?

**CURRENT STATE:** F3 updates launch.md but says nothing about updating agent prompts (in interflux plugin).

**RECOMMENDATION:** Add F3 acceptance criterion:
> Agent prompts (agents/review/fd-*.md) updated to acknowledge sliced content format and instruct on section request syntax.

**MEDIUM PRIORITY** — Agents may already handle this fine, but it's undefined.

### Missing Flow: Synthesis Aggregation Across Slicing Modes

**SCENARIO:**
- fd-architecture sees full document, flags issue in Section X
- fd-safety sees Section X as context summary, does NOT flag issue
- fd-correctness sees Section X as priority, flags same issue

**SYNTHESIS CHALLENGE:** Is this 2/5 convergence or 2/3 convergence?

Existing slicing.md (lines 319-324) says:
> When counting how many agents flagged the same issue, do NOT count agents that only received context summaries for the section in question. A finding from 2/3 agents that saw the content in full is higher confidence than 2/6 total agents.

**GOOD:** This rule exists in slicing.md.

**GAP:** PRD doesn't mention it. If F3 integration doesn't update synthesize.md to use this rule, the feature will ship incomplete.

**RECOMMENDATION:** Add F3 acceptance criterion:
> synthesize.md updated to adjust convergence scoring per slicing_map (ignore agents that only saw context summaries).

**HIGH PRIORITY** — Convergence scoring is core to synthesis quality.

## Evidence Standards

### Data-Backed Findings

✅ "50-75k tokens per review" — from token flow audit
✅ "50-70% reduction" — from 5-variant experiment
✅ "Codex spark cheapest" — comparative testing across 5 approaches

### Assumption-Based Reasoning

⚠️ "80% threshold is correct" — inherited from existing slicing.md, not validated for document slicing
⚠️ "Cross-cutting agents need full document" — no evidence, just design assumption
⚠️ "First 50 lines sufficient for classification" — Open Question #1, not tested

**RECOMMENDATION:** Flag these as "to be validated in first 10 reviews" rather than treating as settled.

## Unresolved Questions That Could Invalidate Direction

### 1. What if classification quality is bad?

**SCENARIO:** Codex spark marks 60% of sections as "priority" for every agent → no savings, just overhead.

**IMPACT:** Feature ships, burns classification tokens, saves nothing.

**MITIGATION:** Add F1 acceptance criterion:
> Classification prompt tested on 5 real flux-drive documents (200-1000 lines). Avg priority sections per agent must be 20-50% of total. If >60%, prompt is too permissive.

**HIGH PRIORITY.**

### 2. What if "Request full section" becomes the norm?

**SCENARIO:** Agents request 2-3 full sections per review because 1-line summaries are insufficient.

**IMPACT:** Net token cost increases (classification overhead + section retrieval > original full document).

**MITIGATION:** Track section request rate in synthesis. If >20% of context sections are requested, surface to user as "slicing may not be beneficial for this document type."

**HIGH PRIORITY.**

### 3. What if Phase 3 "handling" of section requests is prohibitively expensive?

**SCENARIO:** Auto-retrieval and re-prompting agents adds 10k tokens per requested section.

**IMPACT:** Feature works but costs more than it saves.

**MITIGATION:** Spec the Phase 3 handling flow BEFORE implementing F2-F3. Options:
- **Cheap:** Include request in synthesis output verbatim (0 tokens, user manually re-runs if critical)
- **Moderate:** Append full section to agent's existing output (agent re-reads, 2k tokens)
- **Expensive:** Re-dispatch agent with full section (full agent prompt repeat, 10k+ tokens)

**CRITICAL.** This is the biggest unspecified dependency.

## Focus Issues

### Priorities Out of Order

**IN SCOPE (correctly):**
- F0-F3: Core slicing infrastructure

**SHOULD BE IN SCOPE (currently missing):**
- Phase 3 section request handling
- Convergence scoring adjustment for slicing_map
- Agent prompt updates for sliced content
- Success metrics (quality validation, not just token reduction)

**CORRECTLY OUT OF SCOPE:**
- Diff slicing changes
- Knowledge layer integration
- Multi-document reviews

**RECOMMENDATION:** Move the 4 "should be in scope" items from implicit to explicit in F3 acceptance criteria.

**HIGH PRIORITY.**

### Missing User-Facing Value

PRD is engineering-centric (MCP server, JSON formats, temp files) with minimal user-facing outcomes.

**USER WANTS TO KNOW:**
- Will my reviews be faster, cheaper, or higher quality?
- How do I know if slicing worked or failed?
- What do I do if an agent's output seems incomplete?

**RECOMMENDATION:** Add "User-Visible Outcomes" section to PRD:
1. Synthesis header shows slicing stats
2. Agent requests for full sections surface in synthesis
3. Fallback to full document is logged and visible

**MEDIUM PRIORITY** — Helps validate that technical work delivers user value.

## Decision Lens

### Clear Value for Defined Segment?

**YES** — 50-70% token reduction for documents >200 lines is measurable and significant.

**BUT** — Value is invisible to end user (developer). This is an infrastructure optimization with indirect user benefit (cheaper → more reviews).

**RECOMMENDATION:** Frame as enabler for higher-frequency reviews, not just cost optimization.

### Trade-Offs Made Explicit?

**MOSTLY** — PRD acknowledges:
- Codex spark dependency (adds external service risk)
- 80% threshold (may bypass slicing for dense docs)
- Cross-cutting exemption (2/5 agents always get full doc)

**MISSING:**
- Quality vs. cost trade-off (what if slicing degrades findings?)
- Phase 3 handling complexity (cheap verbatim vs. expensive re-dispatch)
- Classification prompt tuning effort (hidden in Open Questions)

**RECOMMENDATION:** Add "Trade-Offs" section to PRD.

### Smallest Change Set for Outcome Confidence?

**NOT QUITE** — F0 (interserve MCP server) is reusable infrastructure but adds 30% to scope. Could prototype with inline Codex CLI call first, then extract to MCP server if proven valuable.

**COUNTER-ARGUMENT:** MCP server is needed for iv-hyza and iv-kmyj anyway. Building it now avoids rework.

**VERDICT:** Scope is reasonable IF other beads are confirmed. If those are deferred, F0 is premature optimization.

**LOW PRIORITY** — Accept as-is, but note the dependency.

## Summary of Findings

### Critical (Must Fix Before Implementation)

1. **Phase 3 section request handling is unspecified** — No flow for what happens when agent notes "Request full section: X"
2. **Quality validation missing** — Success measured only by token reduction, not finding quality
3. **Convergence scoring not updated** — Synthesis must adjust for slicing_map (agents that only saw context summaries don't count toward convergence)
4. **Classification quality threshold missing** — No guard rail for "classifier marks everything priority" failure mode
5. **Harm mitigation for domain mismatch** — Documents that don't fit fd-* domains may get over-sliced (all context summaries)

### High Priority (Should Address Before Ship)

1. **Agent prompt updates** — fd-* agents need guidance on sliced content format and section request syntax
2. **User visibility into slicing outcomes** — Synthesis should show which agents got sliced content and whether fallback occurred
3. **Section request rate tracking** — If >20% of context sections requested, slicing may be net-negative
4. **Metadata header orientation** — Reframe stats-first to orientation-first

### Medium Priority (Improve Post-Launch)

1. **Confidence scores in summaries** — Help agents decide which context sections to request
2. **Cross-cutting exemption validation** — Check if fd-architecture/fd-quality actually need full document every time
3. **Time-to-value clarity** — Clarify if benefit is "faster" or just "cheaper"
4. **Error path visibility** — Surface classification failures and 80% threshold bypasses to user

### Low Priority (Nice-to-Have)

1. **Environment variable override** — `FLUX_DRIVE_NO_SLICING=1` safety valve
2. **First-use notification** — One-time message on slicing activation
3. **80% threshold bypass logging** — Diagnostic for dense documents

## Recommendation

**VERDICT:** Strong product direction with critical implementation gaps.

**BLOCK SHIP UNTIL:**
1. Phase 3 section request flow is specified (cheap verbatim vs. expensive re-dispatch decision)
2. Quality validation metrics added to success criteria (not just token reduction)
3. Convergence scoring and agent prompts updated for sliced content
4. Classification quality guard rails added (all-priority and all-context failure modes)

**SHIP WITH CAVEATS:**
- Cross-cutting exemption (fd-architecture, fd-quality always full doc) is assumption-based, validate in first 10 reviews
- 80% threshold inherited from diff slicing, may need tuning for document slicing
- Time-to-value claim ("faster reviews") unproven if agents run in parallel

**ITERATION PLAN:**
- v1: Ship with verbatim section requests (cheap, manual user follow-up)
- v2: Auto-retrieval if <20% request rate observed
- v3: Per-agent threshold tuning based on domain fit data
