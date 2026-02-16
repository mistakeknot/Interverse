# Flux-Drive Document Slicing — Correctness Review

**Reviewer:** fd-correctness (Julik)
**Date:** 2026-02-16
**Document:** `/root/projects/Interverse/docs/prds/2026-02-16-flux-drive-document-slicing.md`

## Summary

This PRD describes a 3-component pipeline: classification (via Codex spark MCP server) → temp file generation → agent dispatch (Task tool). The correctness risks concentrate at component boundaries and error paths. Five high-consequence failure modes identified, plus edge cases in classification logic that can produce inconsistent section assignments.

**Priority findings:** Classification fallback inconsistency (P1), temp file race on hash collisions (P1), context section truncation failure mode (P2), 80% threshold edge case (P2).

---

## Invariants

The system must preserve these invariants:

1. **Content completeness**: Every line of the original document appears in EITHER priority OR context sections for every agent (no dropped content)
2. **Cross-cutting exemption**: fd-architecture and fd-quality ALWAYS receive the unsliced original document
3. **Fallback transparency**: If classification fails, ALL agents receive the full document (equivalent to <200-line behavior)
4. **Path uniqueness**: Per-agent temp file paths never collide within a single review run
5. **Section boundary integrity**: Sections split by `##` headings preserve markdown structure (no split code blocks, no orphaned content)

---

## P1: Classification Fallback Inconsistency

**Location:** F2 acceptance criteria, F3 integration

**Issue:**
F2 states: "If classification fails (MCP error), falls back to writing full document for all agents (no slicing)."
F3 states: Step 2.1c Case 2 (docs >=200 lines) invokes `classify_sections` MCP tool.

**Failure narrative:**
1. Orchestrator detects 300-line document → triggers Case 2 slicing
2. Invokes `classify_sections` MCP tool → Codex spark is unreachable (network timeout)
3. MCP server returns error (F0: "graceful degradation" returns error)
4. Orchestrator fallback logic writes full document for all agents
5. BUT: fd-architecture and fd-quality expect the original file path, domain agents expect per-agent sliced file paths
6. If fallback writes to the SLICED file paths (one file per agent), the cross-cutting agents receive sliced content, violating invariant #2
7. If fallback writes to the SHARED file path (like Case 1), domain agents fail to find their per-agent files

**Root cause:** Fallback path decision is ambiguous. Does fallback mean "behave like Case 1 (shared file)" or "write full content to Case 2 file paths (per-agent files, but unsliced)"?

**Corrective action:**
Specify fallback file path strategy explicitly:

**Option A (recommended):** Fallback behaves like Case 1 (shared file for all agents). Orchestrator writes to `/tmp/flux-drive-{hash}-{ts}.md`, updates all agent dispatch paths to reference this shared file. Cross-cutting agents see correct path, domain agents see correct path (just happens to be shared).

**Option B:** Fallback writes full document to EVERY per-agent file path. Cross-cutting agents reference original path, domain agents reference per-agent paths. File duplication, but path contracts preserved.

Add to F2 acceptance criteria:
- [ ] Fallback file strategy documented: shared file (Case 1 pattern) OR per-agent duplicated files (Case 2 pattern with full content)
- [ ] Agent dispatch paths updated correctly when fallback is triggered

Add to F3:
- [ ] launch.md Step 2.1c: if `classify_sections` returns error, write full document to shared temp file and update all agent paths to reference it (Case 1 behavior)

---

## P1: Temp File Hash Collision Race

**Location:** F2 acceptance criteria

**Issue:**
Per-agent temp file path: `/tmp/flux-drive-{hash}-fd-{agent}.md`

The PRD does not specify what `{hash}` is. If it's a hash of document content, two reviews of the same document in parallel (e.g., two Claude Code sessions) produce the same hash.

**Failure narrative:**
1. User A runs flux-drive on `docs/architecture.md` (400 lines) at 14:30:00
2. User B runs flux-drive on the same file at 14:30:02 (2 seconds later)
3. Both compute hash = `a3f9b2c1` (same content)
4. Session A writes `/tmp/flux-drive-a3f9b2c1-fd-safety.md` with sections {Security, Deployment}
5. Session B writes `/tmp/flux-drive-a3f9b2c1-fd-safety.md` with sections {Security, Auth} (document changed between runs, or B's classification differs)
6. Session A's fd-safety agent starts reading → gets B's file content mid-read
7. Agent receives inconsistent content: starts with A's sections, ends with B's sections

**Root cause:** Hash alone is not unique across concurrent reviews. Need session or timestamp disambiguation.

**Corrective action:**
Change file path to include timestamp: `/tmp/flux-drive-{hash}-{ts}-fd-{agent}.md` where `{ts}` is the timestamp already generated in Step 2.1c.

Update F2 acceptance criteria:
- [ ] Writes to `/tmp/flux-drive-{hash}-{ts}-fd-{agent}.md` (hash = first 8 chars of document SHA256, ts = Unix epoch seconds from Step 2.1c)
- [ ] Cross-cutting agents get `/tmp/flux-drive-{hash}-{ts}.md` (no agent suffix)

This matches the existing Case 1/Case 3 pattern in launch.md which already uses `${INPUT_STEM}-${TS}.md`.

---

## P2: Context Section Truncation Failure Mode

**Location:** F1 acceptance criteria, F2

**Issue:**
F1: "Each section has: heading text, line count, first 50 lines of body (for classification context)"
F2: "Context sections appear as: `- **{heading}**: {first_sentence} ({line_count} lines)`"

**Failure narrative:**
1. Document has a 150-line section "Security Architecture"
2. Classification uses first 50 lines → section body contains keyword "authentication" → marked `priority` for fd-safety
3. BUT: Lines 51-150 contain a different security topic (certificate rotation) that fd-safety should review
4. Lines 51-150 are marked `context` because classification only saw first 50 lines
5. fd-safety receives priority section with lines 1-50, and a 1-line context summary for lines 51-150
6. Critical certificate rotation logic is summarized as "Certificate management details (100 lines)" → fd-safety misses it

Actually, wait. The PRD says "Each section has: heading text, line count, first 50 lines of body". A section is defined as "Split document by `##` headings. Each section = heading + content until next heading." So the 150-line section is ONE section. It's not split into sub-sections for classification.

Let me re-read...

F1: "Splits markdown by `##` headings, correctly skipping `##` inside fenced code blocks"
F1: "Each section has: heading text, line count, first 50 lines of body (for classification context)"

So if a section is 150 lines, the classifier sees:
- heading: "Security Architecture"
- line_count: 150
- body preview: first 50 lines

Then classification outputs:
```json
{section_id, heading: "Security Architecture", line_count: 150, assignments: [{agent: "fd-safety", relevance: "priority"}]}
```

If the section is marked `priority`, the FULL 150 lines are included in the per-agent file. If it's marked `context`, the 1-line summary is used.

So the failure mode is:
1. Section is 150 lines
2. First 50 lines are boilerplate introduction, no keywords
3. Lines 51-150 contain critical security logic
4. Classification sees only first 50 lines → no keywords → marks as `context` for fd-safety
5. fd-safety receives 1-line summary, misses the critical content in lines 51-150

**Corrective action:**
Add to F1 acceptance criteria:
- [ ] For sections >100 lines, sample BOTH first 25 lines AND last 25 lines (or first 25 + middle 25 + last 25 for >150-line sections) to avoid keyword concentration bias

Alternatively, increase classification sample size for large sections:
- [ ] Classification body preview: first 50 lines for sections <=100 lines, first 100 lines for sections >100 lines (adaptive sampling)

This prevents the "keywords at end of section" failure mode without sending the entire section body to the classifier.

Update Open Question #1: "How much section body to include?" should recommend adaptive sampling based on section length, not fixed 50 lines.

---

## P2: 80% Threshold Edge Case — Off-by-One or Rounding Error

**Location:** F1 acceptance criteria

**Issue:**
F1: "80% threshold: if an agent's priority sections cover >=80% of total lines, mark all sections as priority for that agent"

This is a line-count calculation. Edge case: what happens at exactly 80%?

**Example:**
- Document: 500 lines total
- fd-safety priority sections: 400 lines (exactly 80%)
- Threshold check: `400 / 500 >= 0.80` → TRUE → mark all sections as priority
- Result: fd-safety receives full document

But what if:
- Document: 499 lines total (odd number)
- fd-safety priority sections: 399 lines
- Threshold: `399 / 499 = 0.799599...` → FALSE → slicing remains active
- Result: fd-safety receives sliced content (399 priority + 100 context summary)

Is this the intended behavior? The 80% threshold is meant to avoid "overhead of compressed summaries is not worth it when almost everything is priority" (slicing.md line 113). A 0.04% difference (79.96% vs 80%) should not change behavior.

**Root cause:** Floating-point threshold boundary. Off-by-one in line counting or rounding can flip the decision.

**Corrective action:**
Add to F1 acceptance criteria:
- [ ] 80% threshold uses integer arithmetic: `(priority_lines * 100) >= (total_lines * 80)` to avoid floating-point rounding errors
- [ ] Document the boundary: exactly 80% triggers full-document mode (threshold is inclusive)

Alternative: Use 79% threshold to provide a 1% buffer zone, so near-boundary cases consistently trigger full-document mode.

---

## P2: Section Extraction Code Block Edge Case

**Location:** F1 acceptance criteria

**Issue:**
F1: "Splits markdown by `##` headings, correctly skipping `##` inside fenced code blocks"

The brainstorm (line 42) mentions "Python script (Variant D): fails on `##` inside code blocks" as a known edge case. The MCP server using Codex spark is expected to handle this semantically.

**But:** What if the MCP server's section extraction logic is implemented as a simple regex or line-by-line parser (not using Codex spark for parsing, only for classification)?

**Failure narrative:**
1. Document contains:
   ````markdown
   ## Security

   Our auth flow:
   ```python
   def check_permissions():
       ## TODO: Add role checks
       return True
   ```

   ## Performance
   ````
2. Naive parser splits on every `##` line → creates 3 sections: "Security", "TODO: Add role checks", "Performance"
3. Classification assigns "TODO: Add role checks" as a separate section
4. Per-agent file generation includes "TODO: Add role checks" as a standalone section with heading `## TODO: Add role checks`
5. Markdown structure is broken (heading inside a code block is now outside)

**Corrective action:**
Clarify in F1 acceptance criteria that section extraction must track fenced code block state:
- [ ] Section extraction maintains `in_code_block` boolean state (toggled by triple-backtick lines)
- [ ] `##` lines inside code blocks do NOT start new sections
- [ ] Test case: document with `##` inside fenced code block should produce correct section boundaries

This is a classic TOCTOU pattern: "check for `##`" then "act on it as a heading" without checking "am I inside a code block?"

---

## P3: Classification Confidence Threshold Ambiguity

**Location:** F0 acceptance criteria, Open Question #4

**Issue:**
F0: "Returns structured JSON (section assignments per agent, confidence scores)"
Open Question #4: "Should low-confidence classifications trigger fallback to full document?"

The PRD does not specify:
1. What confidence score range is returned (0-1? 0-100? low/medium/high enum?)
2. What the orchestrator does with confidence scores
3. Whether low confidence triggers fallback or is just logged

**Potential failure mode:**
1. MCP server returns confidence scores: `{agent: "fd-safety", relevance: "priority", confidence: 0.3}` (low)
2. Orchestrator has no threshold logic → accepts the classification
3. Section is incorrectly classified → agent misses critical content
4. No fallback, no warning, no observability

**Corrective action:**
Add to F0 acceptance criteria:
- [ ] Confidence scores are floats 0.0-1.0 (0.0 = no confidence, 1.0 = certain)
- [ ] If ANY section assignment has confidence <0.5, log a warning with section name and agent
- [ ] If >50% of sections have confidence <0.5 for a particular agent, trigger full-document fallback for that agent only

Alternative (simpler): confidence scores are for observability only, no fallback logic in v1. Add threshold-based fallback in a future iteration after real-world confidence distribution is observed.

Update Open Question #4 → recommend "confidence is observability-only in v1, logged but not used for fallback decisions."

---

## P3: Cross-Cutting Agent Exemption Inconsistency

**Location:** F1 acceptance criteria, slicing.md

**Issue:**
F1: "Cross-cutting exemption: fd-architecture and fd-quality always get full document"
slicing.md line 193: "Cross-cutting agents (fd-architecture, fd-quality) — always receive the full document. Skip classification for these agents."

BUT: F1 also says "Classification prompt includes: agent domain descriptions, section headings + previews, expected JSON output format"

Does the classification prompt include fd-architecture and fd-quality domain descriptions, even though they don't need classification?

**Two interpretations:**

**Interpretation A:** Classification prompt includes ALL agents (including cross-cutting), classifier returns assignments for all agents, but orchestrator ignores assignments for cross-cutting agents and always gives them full document.

**Interpretation B:** Classification prompt includes ONLY domain-specific agents, classifier returns assignments for domain agents only, orchestrator separately handles cross-cutting agents.

**Why this matters:**
Interpretation A wastes Codex spark tokens on classifying content for agents that will ignore the classification.
Interpretation B is more efficient but requires the orchestrator to know which agents are cross-cutting BEFORE building the prompt.

**Corrective action:**
Add to F1 acceptance criteria:
- [ ] Classification prompt includes ONLY domain-specific agents (fd-safety, fd-correctness, fd-performance, fd-user-product, fd-game-design)
- [ ] fd-architecture and fd-quality are NOT sent to the classifier
- [ ] Cross-cutting agents are handled separately in temp file generation (always reference the original unsliced file)

This matches the slicing.md line 193 guidance: "Skip classification for these agents."

---

## P3: Synthesis Phase "Request Full Section" Handling Undefined

**Location:** F3 acceptance criteria

**Issue:**
F3: "Synthesis phase (Phase 3) handles `"Request full section"` annotations in agent outputs"

The PRD does not specify WHAT the synthesis phase does with these annotations. Options:

**Option A:** Synthesis phase re-runs the agent with the full section included (requires agent re-dispatch, adds latency and cost)

**Option B:** Synthesis phase notes the request as a "routing improvement suggestion" (existing slicing.md line 323 behavior) but does NOT re-run the agent

**Option C:** Synthesis phase manually reads the full section and includes it in the final report, but agent does NOT re-review it

**Why this matters:**
If Option A, the orchestrator needs to:
1. Parse agent output for "Request full section: {name}" strings
2. Regenerate the per-agent temp file with that section upgraded from context to priority
3. Re-dispatch the agent with the updated file
4. Merge the new findings with the original findings

This is a complex multi-step workflow with failure modes:
- What if re-dispatch times out?
- What if the agent's second run contradicts the first run?
- What if multiple agents request the same section (deduplicate re-runs)?

**Corrective action:**
Clarify in F3 acceptance criteria:
- [ ] Synthesis phase logs "Request full section" annotations as routing improvement suggestions (no agent re-dispatch in v1)
- [ ] Future iteration (not in scope): auto-expansion where synthesis re-dispatches agents with upgraded section assignments

Update slicing.md synthesis rules (line 323) to confirm this is the v1 behavior: "note it as a routing improvement suggestion in the synthesis report" (already correct, just confirm PRD matches).

---

## Edge Case: Section With No Body

**Location:** F1, F2

**Issue:**
What happens if a section has a heading but no body (next heading immediately follows)?

```markdown
## Security

## Performance

Some content here.
```

Section extraction produces:
- Section 1: heading="Security", body="", line_count=0
- Section 2: heading="Performance", body="Some content here.", line_count=1

Classification receives:
- Section 1: heading="Security", line_count=0, body preview: "" (empty)

Does this section get classified? Possible outcomes:
1. Classifier returns `relevance: "context"` (no body to analyze)
2. Classifier returns `relevance: "priority"` for fd-safety (heading keyword match)
3. Classifier errors (unexpected empty body)

**Recommendation:**
Add to F1 acceptance criteria:
- [ ] Empty sections (line_count=0) are classified based on heading text only (no body preview)
- [ ] Empty sections default to `context` if heading contains no keywords
- [ ] Test case: document with empty section should not error

---

## Edge Case: Code Block Without Closing Backticks

**Location:** F1

**Issue:**
Unclosed code block (user error in markdown):

```markdown
## Security

```python
def authenticate():
    # code here

## Performance
```

The code block is never closed (missing closing triple-backticks). The section extraction logic that tracks `in_code_block` state will mark everything after the opening backticks as inside a code block, including the "Performance" heading.

Result: The document appears as ONE section ("Security") with a very long body.

**Is this a problem?**
Yes, if the document is malformed, the section extraction silently produces incorrect sections. The classification will treat "Security + Performance" as a single section, and the per-agent files will have incorrect structure.

**Recommendation:**
Add to F1 acceptance criteria:
- [ ] If code block is unclosed at end of document, log a warning: "Malformed markdown: unclosed code block in section {name}"
- [ ] Treat unclosed code block as closed at document end (so final `##` headings are still recognized)

Alternative: Fail fast and return error if markdown is malformed, triggering full-document fallback.

---

## Edge Case: 80% Threshold With Zero-Length Document

**Location:** F1

**Issue:**
What if the document has 0 lines? (Empty file, or all lines are whitespace)

Threshold calculation: `priority_lines / total_lines` → `0 / 0` → division by zero.

**Recommendation:**
Add to F1 acceptance criteria:
- [ ] Documents with 0 non-whitespace lines skip slicing (treat as <200 lines, send to all agents)
- [ ] Division-by-zero check: if `total_lines == 0`, skip 80% threshold logic

---

## Edge Case: Agent Receives Zero Priority Sections

**Location:** F1, F2

**Issue:**
Classification result: fd-performance has zero priority sections (entire document is context).

Per-agent temp file structure (F2):
```markdown
[Document slicing active: 0 priority sections (0 lines), 8 context sections (420 lines summarized)]

## Priority Sections (full content)

(empty)

## Context Sections (summaries)

- **Architecture**: System design overview (50 lines)
- **Security**: Auth flow details (60 lines)
...
```

Is this valid? The agent receives ONLY summaries, no full content.

**Implication:**
The agent has zero context to work with. It can only see section titles and 1-line summaries. It likely produces a finding: "All content was marked as context — I cannot perform a meaningful review. Request full sections: Architecture, Security, ..."

**Recommendation:**
Add to F1 acceptance criteria:
- [ ] If an agent has zero priority sections, trigger full-document fallback for that agent (cannot perform meaningful review with only summaries)
- [ ] Alternative: if an agent has zero priority sections, do NOT dispatch that agent (skip it entirely)

The second option is more efficient (why dispatch an agent that has no relevant content?). This aligns with the triage system's goal of routing only relevant agents.

Update slicing.md line 195: "If an agent's priority sections cover 0% of total document lines, skip that agent entirely (do not dispatch)."

---

## Data Flow Summary

```
Input: Document (500 lines)
  ↓
Step 2.1c Case 2: Document >= 200 lines
  ↓
Invoke classify_sections MCP tool
  ↓ (if MCP error, fallback: shared file, all agents)
Codex spark classification
  ↓
Returns JSON: {section_id, heading, assignments: [{agent, relevance}]}
  ↓
Temp file generation (F2)
  ↓
Per-agent files written: /tmp/flux-drive-{hash}-{ts}-fd-{agent}.md
  ↓
Agent dispatch (Task tool, references per-agent file path)
  ↓
Agent reads file, produces findings
  ↓
Synthesis Phase 3: parses "Request full section" annotations
  ↓
Output: Final report with slicing metadata + routing suggestions
```

**Correctness checkpoints:**
1. MCP error handling → fallback path (P1 finding)
2. Temp file path uniqueness → hash collision prevention (P1 finding)
3. Section boundary integrity → code block handling (P2 finding)
4. 80% threshold edge case → rounding/division-by-zero (P2 finding)
5. Zero priority sections → agent skip logic (edge case)

---

## Recommendations

### Critical (P1) — Block PRD Approval

1. **Specify classification fallback file path strategy** (shared file OR per-agent duplicated files)
2. **Add timestamp to temp file paths** to prevent hash collision race: `/tmp/flux-drive-{hash}-{ts}-fd-{agent}.md`

### High Priority (P2) — Address Before Implementation

3. **Adaptive section sampling** for classification (first 50 lines insufficient for long sections)
4. **80% threshold integer arithmetic** to avoid floating-point rounding errors
5. **Section extraction code block handling** (track `in_code_block` state, test case for `##` inside code blocks)

### Medium Priority (P3) — Clarify in PRD

6. **Confidence score semantics** (observability-only OR threshold-based fallback)
7. **Cross-cutting agent exclusion** from classification prompt (efficiency improvement)
8. **Synthesis "Request full section" behavior** (log-only OR agent re-dispatch)

### Edge Cases — Add Test Coverage

9. **Empty sections** (heading with no body)
10. **Unclosed code blocks** (malformed markdown)
11. **Zero-length documents** (division-by-zero in 80% threshold)
12. **Zero priority sections for an agent** (skip dispatch OR fallback to full document)

---

## Conclusion

The document slicing pipeline has clear correctness risks at the MCP error boundary (fallback behavior) and temp file generation (hash collision race). The classification logic edge cases (code blocks, empty sections, long sections) are lower severity but will cause silent mis-classification in production if not addressed.

The 80% threshold calculation is a common source of off-by-one errors and should use integer arithmetic.

Overall assessment: The architecture is sound (clear separation of concerns, external MCP server, fallback-first design). The specification gaps are addressable with targeted acceptance criteria additions. Recommend addressing P1 findings before PRD approval, P2 findings before implementation start.
