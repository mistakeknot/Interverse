# Feedback Loops Review — Interspect Design Document

**Reviewer:** fd-feedback-loops (feedback loop correctness specialist)
**Target:** `/root/projects/Interverse/hub/clavain/docs/plans/2026-02-15-interspect-design.md`
**Date:** 2026-02-15
**Context:** Clavain CLAUDE.md, AGENTS.md, hooks/auto-compound.sh, hooks/auto-drift-check.sh, hooks/lib-signals.sh, galiana/lib-galiana.sh, docs/roadmap.md

---

## Summary

The interspect design describes an OODA-based self-improvement engine with four cadences, six modification types, a confidence filter, canary monitoring, shadow testing, and a meta-learning loop. The architecture is thoughtful and the safety rails (meta-rules are human-owned, git-based undo, confidence thresholds) address many obvious risks. However, the review identified several feedback loop correctness issues ranging from potential runaway amplification to dead loops and measurement gaps.

**Finding count:** 3 P1, 5 P2, 4 P3

---

## 1. Loop Completeness

### 1.1 Cadence 1 (Within-Session): Incomplete Act-to-Observe Loop — P2

**Reference:** Section 3.2, Cadence 1 (lines 67-77)

Cadence 1 catches patterns and makes in-memory adjustments (act), but the document does not specify how the *effect* of those adjustments is observed within the same session. If an agent prompt is adjusted in-memory after two overrides, what verifies the adjustment helped?

**Specific concern:** "Same override pattern twice -> adjust agent prompt in-memory" (line 73). After adjustment, the agent might be invoked again during the same session. If the adjustment made things worse, the override rate increases, but there is no stated mechanism to detect that the *adjustment itself* caused the increase vs. the inputs being harder. The OODA loop is O-O-D-A without a second O to close it.

**Question:** Is there a plan for within-session canary monitoring of in-memory changes, or is the assumption that session-scoped changes are low-enough risk that monitoring can wait for Cadence 2?

### 1.2 Cadence 3 (Periodic Batch): Observe and Orient Are Defined, But Decide/Act Are Vague — P2

**Reference:** Section 3.2, Cadence 3 (lines 96-102)

Cadence 3 lists what it *catches* (observe/orient) — companion extraction candidates, workflow optimization, agent topology changes — but does not describe the decision criteria or action mechanism with the same precision as Cadences 1 and 2. The safety note says "Shadow testing required. Report generated before applying" but the decide step is implicit.

**Specific gap:** For "agent topology changes (agents never producing actionable findings for a project)" (line 101), what threshold defines "never"? How many sessions with zero actionable findings before removing an agent? The confidence filter (Section 3.2, Cadence 4) provides thresholds for the confidence *score* but the scoring function `f(evidence_count, cross_session_count, cross_project_count, recency)` is unspecified.

**Recommendation:** Define the scoring function explicitly, or at minimum define boundary cases — what evidence_count and cross_session_count produce confidence 0.3 vs 0.7 vs 0.9?

### 1.3 Cadence 2 Act Does Feed Back to Cadence 2 Observe (Good) — Positive Note

The design explicitly states that modifications are tagged with canary metadata (Section 3.6) and outcomes are logged as evidence (Section 3.3, step 6: "Log outcome as evidence"). This closes the act-to-observe loop at the end-of-session cadence. This is the strongest loop in the design.

---

## 2. Amplification Prevention

### 2.1 Meta-Learning Loop Can Amplify Risk Classification Without Bound — P1

**Reference:** Section 3.7 (lines 168-171)

> "Prompt tightening for fd-safety reverted 3 times -> interspect raises risk classification for fd-safety modifications -> requires shadow testing instead of canary"

This is a one-way ratchet: risk classification only goes *up*. The document does not describe a mechanism for risk classification to go back *down*. Over time, every target that experiences any difficulty will be promoted to high-risk, requiring shadow testing for all modifications. The system will converge to maximum caution — effectively disabling autonomous improvement for battle-scarred targets.

**Amplification path:**
1. Attempt prompt tuning on fd-safety (medium risk, canary gate)
2. First attempt fails (canary revert). Risk stays medium.
3. Second attempt fails. Risk still medium.
4. Third attempt fails. Meta-learning promotes fd-safety to high risk (shadow testing required).
5. Shadow testing is expensive and harder to pass. Future legitimate improvements are blocked.
6. fd-safety becomes effectively frozen — a dead zone that accumulates technical debt.

**Risk:** This is a *negative* feedback loop that is too aggressive. It's not runaway amplification in the traditional sense (errors compounding), but it's a convergence failure — the system converges to paralysis rather than improvement.

**Recommendation:** Add a decay mechanism. After N successful sessions where fd-safety performs well (low override rate, low false positive rate), allow risk classification to decay back toward its base level. The meta-learning loop should learn from *successes* too, not only failures.

### 2.2 Single Bad Session Can Inflate Confidence for Persistent Changes — P1

**Reference:** Section 3.2, Cadence 2 (lines 79-90) and Cadence 4 (lines 104-115)

The confidence filter requires `>= 2 sessions showing same pattern` for persistent modifications. But the design does not address *adversarial sessions* — a session working on unusually difficult code that generates many overrides for legitimate reasons (e.g., a security-sensitive module where the human correctly overrides fd-safety's false positives).

**Amplification path:**
1. Two sessions work on a security-heavy codebase. Both sessions override fd-safety findings (correctly — they're false positives for this specific pattern).
2. Cadence 2 sees the pattern: "fd-safety overridden 4 times across 2 sessions."
3. Confidence is high enough for persistent prompt modification.
4. Interspect adds "Do NOT flag X when Y" to fd-safety prompt.
5. The modification is correct for security-heavy code but now fd-safety misses X in non-security code.
6. The canary monitors override rate and false positive rate — but the *miss rate* (true negatives that became false negatives) is not monitored (see Finding 5.1).

**Risk:** A single code domain can bias the evidence store and cause modifications that degrade performance in other domains.

**Recommendation:** Evidence should carry project/domain context (the schema already has a `"project"` field — good). Confidence calculation should weight cross-*project* evidence much higher than within-project evidence. A pattern seen across 3 projects is much stronger evidence than the same pattern seen 6 times in 1 project.

### 2.3 Canary Revert Threshold Is Relative, Not Absolute — P2

**Reference:** Section 3.6 (line 165)

> "If override/false-positive rate increases > 50% relative to baseline within the canary window -> auto-revert"

A 50% *relative* increase is very different depending on the baseline:
- Baseline 0.4 override rate -> threshold 0.6 (an increase of 0.2 absolute)
- Baseline 0.05 override rate -> threshold 0.075 (an increase of 0.025 absolute)

For agents with very low baseline rates, a single additional override could trigger a revert (0.05 baseline with 5-use canary window: 1 override = 0.2 rate = 300% increase). For agents with high baseline rates, substantial degradation could go undetected (0.4 baseline: rate must reach 0.6 before revert, which allows many bad outcomes).

**Recommendation:** Use a combined threshold: revert if relative increase > 50% AND absolute increase > some minimum (e.g., 0.1), OR if the rate exceeds some hard ceiling regardless of baseline.

---

## 3. Evidence Flow Integrity

### 3.1 Double-Counting Between Cadence 1 and Cadence 2 — P1

**Reference:** Section 3.2, Cadence 1 (line 69) and Cadence 2 (lines 87-88)

Cadence 1: "Changes are in-memory. Promoted to persistent by Cadence 2 if pattern persists."
Cadence 2: "Session evidence + last 5 sessions' evidence -> persistent modifications" and "Within-session demotions -> checked for cross-session consistency."

**The problem:** If Cadence 1 observes two overrides and adjusts a prompt in-memory, then Cadence 2 observes the same session's evidence *including the overrides that Cadence 1 already acted on*, the same evidence is used twice — once to trigger the in-memory change and again to justify the persistent change. The evidence doesn't indicate whether the overrides happened *before* or *after* the Cadence 1 adjustment.

**Amplification path:**
1. Cadence 1 sees 2 overrides, adjusts prompt in-memory.
2. The adjustment works — remaining invocations have 0 overrides.
3. Cadence 2 sees the 2 overrides from early in the session and the 0 from late in the session.
4. Without timestamps correlating overrides to the adjustment, Cadence 2 may see "2 overrides total" and combine with prior sessions to justify a persistent change — even though the in-memory change *already fixed the problem*.
5. Now the persistent change is applied *on top of* the in-memory fix, potentially over-correcting.

**Recommendation:** Evidence events must carry a monotonic sequence number within the session. Cadence 2 must distinguish evidence from before and after Cadence 1 adjustments. The evidence schema (Section 3.1) has `ts` but no indicator of whether the event occurred pre- or post-adjustment.

### 3.2 Evidence Store Growth Creates Stale Evidence Bias — P3

**Reference:** Section 6, Open Questions (line 206)

The document acknowledges this as an open question: "How to handle evidence store growth over time?" The concern from a feedback loop perspective is that stale evidence doesn't just waste space — it biases the confidence calculation. If the system keeps all evidence forever, patterns from the project's early days (when code was different, agents were different, the human was learning the system) will continue to influence modifications months later.

**Recommendation:** When this is resolved, include a recency decay in the confidence function. Evidence older than N sessions should have reduced weight. This also partially addresses the convergence concern in 2.1.

### 3.3 Meta-Learning Circular Reasoning Risk — P3

**Reference:** Section 3.7 (lines 168-171)

The meta-learning loop feeds modification *outcomes* (success/failure) back as evidence for future modifications. This creates a potential circularity:

1. Interspect modifies prompt A based on evidence E1.
2. The modification fails (reverted). Failure logged as evidence E2.
3. Interspect raises the risk classification for A.
4. Future attempts to modify A require shadow testing.
5. Shadow testing uses historical inputs — which may include inputs from the period when A was in its pre-modification state.
6. The shadow test compares "old A" vs "new A" using inputs where "old A" may have already been suboptimal (that's why modification was attempted).

The circularity: the system learns "modifications to A are risky" from outcomes that may be contaminated by the pre-modification state of A. This is a form of survivorship bias in the meta-learning loop.

**Risk:** Low in practice (the design already limits this by raising risk classification rather than learning wrong patterns), but worth documenting as a known limitation.

---

## 4. Convergence Properties

### 4.1 Cadence 2 and Cadence 3 Can Produce Contradictory Modifications — P2

**Reference:** Section 3.2, Cadence 2 (lines 79-90) and Cadence 3 (lines 96-102)

Cadence 2 operates at session boundaries with evidence from the last 5 sessions. Cadence 3 operates periodically with broader structural analysis. There is no coordination mechanism between them.

**Scenario:**
1. Cadence 2, after 5 sessions of fd-architecture overrides, adds "Do NOT flag microservice boundary violations when services share a database" to fd-architecture's prompt.
2. Cadence 3, analyzing cross-project topology, determines fd-architecture should be *strengthened* because it's missing important findings. It rewrites the SKILL.md to be more aggressive about microservice boundaries.
3. These changes conflict. The system oscillates: Cadence 2 weakens, Cadence 3 strengthens, Cadence 2 weakens again.

**Damping mechanism needed:** The design has canary monitoring (which would catch the oscillation's *symptoms*) but no mechanism to detect that two cadences are fighting. After canary-reverting the same target twice within N sessions (once from Cadence 2, once from Cadence 3), the system should flag the conflict for human review.

**Recommendation:** Add a "conflict counter" per target file. If the same file is modified and reverted by different cadences within a window, escalate to human review regardless of confidence score.

### 4.2 No Maximum Modification Frequency per Target — P2

**Reference:** Section 3.3 (Modification Pipeline) and Section 3.6 (Canary Monitoring)

The canary window is 5 uses (Section 3.6, line 159). There is no stated limit on how many modifications can be *queued* for the same target. If Cadence 2 identifies a modification and applies it (entering canary window), then the next session also identifies a modification for the same target, what happens?

**Question:** Does the system queue modifications and wait for the canary window to complete, or can a second modification apply before the first canary period ends? If the latter, the baseline for the second canary is the first modification (which is itself untested), creating stacked modifications where a revert of the second doesn't revert the first.

**Recommendation:** Enforce a "one active canary per target file" rule. If a file is currently in a canary window, new modifications for that file are deferred until the window closes.

---

## 5. Degradation Detection

### 5.1 Canary Monitoring Measures Override Rate and False Positive Rate — But Not Miss Rate — P1 (addressed above in 2.2, restated for degradation detection)

**Reference:** Section 3.6 (lines 162-165)

The canary monitors two metrics:
1. `baseline_override_rate` — did the human override more after the change?
2. `baseline_false_positive_rate` — did the agent produce more false positives?

**Missing metric:** Miss rate (true negatives that should have been flagged). If a prompt modification adds "Do NOT flag X when Y" and Y is too broad, the agent will miss legitimate findings. The override rate will *decrease* (fewer findings = fewer overrides) and the false positive rate will *decrease* (the things it does flag are more accurate). Both metrics improve, but the agent is actually worse — it's just quieter.

This is the Goodhart's Law trap identified by the fd-measurement-validity agent spec (which exists at `/root/projects/Interverse/hub/clavain/.claude/agents/fd-measurement-validity.md`). The design acknowledges LLM-as-judge for shadow testing (Section 5, Decision 6: "Not perfect but sufficient") but doesn't address the canary monitoring gap.

**Recommendation:** Add a third canary metric: *finding density* (findings per review invocation). If finding density drops significantly after a modification (especially a prompt-tightening modification), it's a signal that the modification may be suppressing legitimate findings, not just false positives. This isn't perfect (lower density could be correct for a cleaner codebase) but it provides a cross-check.

### 5.2 Canary Window of 5 Uses May Be Statistically Insufficient — P3

**Reference:** Section 3.6 (line 159) and Section 6, Open Questions (line 205)

The document asks: "What's the right canary window size? 5 uses may be too small for rarely-triggered agents."

From a feedback loop perspective: with 5 uses and a 50% relative increase threshold, the minimum detectable change is 1 additional override (for agents with >0 baseline). For agents with 0 baseline overrides, *any* override triggers a revert — which is actually correct for those agents. But for agents with variable baseline rates (e.g., 0.2-0.4 override rate across sessions), 5 observations cannot distinguish a real degradation from noise.

**Recommendation:** Use a dynamic canary window based on the baseline rate's variance. Agents with high variance need larger windows. As a heuristic: `canary_window = max(5, ceil(1 / (baseline_rate * 0.5)))` ensures at least enough observations to detect a 50% relative increase with one additional event.

### 5.3 No Monitoring of Interspect's Own Activity Rate — P3

**Reference:** Entire document

The design monitors the *effect* of modifications (canary monitoring) and the *outcomes* of modifications (meta-learning) but not the *rate* of modifications themselves. If interspect starts making modifications at an increasing rate (perhaps due to a bug in evidence collection that floods the store), there is no circuit breaker based on modification frequency.

**Recommendation:** Add a global rate limiter: maximum N modifications per M sessions. If exceeded, interspect pauses and generates a report for human review. This is different from per-target frequency (Finding 4.2) — this is a system-wide health check.

---

## 6. Integration with Existing Infrastructure

### 6.1 Relationship to Galiana Analytics — Question

**Reference:** `galiana/lib-galiana.sh` and design Section 3.1

The existing galiana analytics library (`/root/projects/Interverse/hub/clavain/galiana/lib-galiana.sh`) already writes structured telemetry events to `~/.clavain/telemetry.jsonl` with event types: `signal_persist`, `workflow_start`, `workflow_end`, `defect_report`. The interspect evidence store is planned at `.clavain/interspect/evidence/` with JSONL files per event type.

**Question:** Will interspect consume galiana telemetry as evidence input, or are these parallel systems? If parallel, there's a risk of divergent data (galiana records one version of events, interspect records another). If interspect consumes galiana, the evidence store format should be unified.

The roadmap (Phase 1, P1.1) describes "Outcome-Based Agent Analytics" with a `per-agent trace` and `per-gate trace` system. Is interspect's evidence store the *same* system as P1.1, or a separate one that reads from P1.1?

### 6.2 Relationship to Auto-Compound Hook — Question

**Reference:** Section 6, Open Questions (line 209) and `hooks/auto-compound.sh`

The document asks: "How does interspect interact with the existing auto-compound hook? Complement or subsume?"

From a feedback loop perspective, the auto-compound hook (`/root/projects/Interverse/hub/clavain/hooks/auto-compound.sh`) uses the same signal-weight engine (`lib-signals.sh`) that Cadence 2 will use (both trigger on `weight >= 3`). If interspect's Cadence 2 also runs on the Stop event with the same threshold, there's a risk of:

1. **Race condition:** Both hooks fire on the same Stop event. The shared sentinel (`/tmp/clavain-stop-${SESSION_ID}`) prevents this for the *current* hooks (auto-compound and auto-drift-check), but interspect would need to participate in the same sentinel protocol.

2. **Semantic conflict:** Auto-compound captures knowledge for humans. Interspect Cadence 2 modifies agent behavior. If both trigger on the same signals, the same evidence drives two different actions — knowledge capture AND behavioral modification. These should be coordinated: knowledge capture first (it's reversible and informative), then behavioral modification (which depends on the captured knowledge being accurate).

**Recommendation:** Interspect Cadence 2 should run *after* auto-compound completes, not in parallel. The knowledge captured by auto-compound could be an evidence input to interspect (closing the loop between human-curated knowledge and autonomous improvement).

### 6.3 Stop Hook Sentinel Protocol — P2

**Reference:** `hooks/auto-compound.sh` lines 48-53, `hooks/auto-drift-check.sh` lines 41-46

The existing sentinel protocol (`/tmp/clavain-stop-${SESSION_ID}`) ensures only one Stop hook returns `"block"` per cycle. Whichever hook fires first wins; the other silently exits. This is a race condition that depends on hook execution order in `hooks.json`.

If interspect's Cadence 2 is added as a third Stop hook, the probability that the *most important* action fires decreases. On a session with shipped code changes, auto-drift-check (weight >= 2) will often fire before auto-compound (weight >= 3) or interspect-sweep (weight >= 3), because auto-drift-check has a lower threshold.

**This means interspect Cadence 2 could be blocked from ever firing** in sessions where auto-drift-check claims the sentinel first. That's a dead loop: evidence is collected but the sweep never runs.

**Recommendation:** Either (a) allow multiple Stop hooks to return `"block"` with Claude handling them sequentially, or (b) implement a priority-based sentinel where higher-priority hooks can preempt lower-priority ones, or (c) have interspect's sweep run as part of the auto-compound flow rather than as a separate Stop hook.

---

## 7. Summary of Findings

| # | Finding | Priority | Category |
|---|---------|----------|----------|
| 2.1 | Meta-learning risk ratchet has no decay mechanism — converges to paralysis | P1 | Amplification |
| 2.2 | Domain-biased evidence can cause modifications that degrade other domains | P1 | Amplification |
| 3.1 | Cadence 1 and Cadence 2 can double-count the same evidence | P1 | Evidence Integrity |
| 5.1 | Canary monitoring doesn't measure miss rate (Goodhart's Law) | P1 | Degradation |
| 1.1 | Cadence 1 has no intra-session verification of adjustments | P2 | Loop Completeness |
| 1.2 | Cadence 3 decide/act steps are underspecified | P2 | Loop Completeness |
| 2.3 | Canary revert threshold uses relative-only comparison | P2 | Amplification |
| 4.1 | No coordination between Cadence 2 and Cadence 3 modifications | P2 | Convergence |
| 4.2 | No maximum modification frequency per target file | P2 | Convergence |
| 6.3 | Stop hook sentinel protocol could permanently block Cadence 2 | P2 | Integration |
| 3.2 | No evidence recency decay (stale evidence bias) | P3 | Evidence Integrity |
| 5.2 | Fixed canary window of 5 uses may be statistically insufficient | P3 | Degradation |
| 5.3 | No monitoring of interspect's own modification rate | P3 | Degradation |
| 3.3 | Meta-learning loop has potential (low-risk) circularity | P3 | Evidence Integrity |

---

## 8. Recommendations (Prioritized)

### Must Address Before Implementation

1. **Add evidence sequencing within sessions** (addresses 3.1). Each evidence event gets a monotonic sequence number. Cadence 2 only counts events *after* the last Cadence 1 adjustment as fresh evidence.

2. **Add miss rate proxy to canary monitoring** (addresses 5.1). Track finding density alongside override rate and false positive rate. A modification that reduces all three is suppressing findings, not improving accuracy.

3. **Add risk classification decay** (addresses 2.1). After N successful sessions without modification attempts, risk classification decays one level toward base. The meta-learning loop should be bidirectional — learning from successes, not only failures.

4. **Weight cross-project evidence higher** (addresses 2.2). A pattern confirmed across 3 projects should have much higher confidence than the same pattern seen 6 times in 1 project. The confidence function should include a cross-project multiplier.

### Should Address Before v1 Ship

5. **One active canary per target** (addresses 4.2). If a file is in a canary window, defer new modifications until the window closes.

6. **Cadence conflict detection** (addresses 4.1). Track which cadence modified each target. If the same target is modified-then-reverted by different cadences within N sessions, escalate to human review.

7. **Resolve Stop hook sentinel collision** (addresses 6.3). Interspect's sweep needs to either participate in the existing sentinel protocol with priority, or run outside the Stop hook mechanism entirely.

8. **Specify the confidence scoring function** (addresses 1.2). Even a rough formula with documented assumptions is better than "TBD."

### Nice to Have

9. **Dynamic canary windows** (addresses 5.2). Scale window size inversely with baseline rate variance.

10. **Global modification rate limiter** (addresses 5.3). Circuit breaker if total modifications exceed threshold.

11. **Evidence recency decay** (addresses 3.2). Reduce weight of evidence older than N sessions.

12. **Unify with galiana telemetry** (addresses 6.1). One evidence stream, not two parallel ones.
