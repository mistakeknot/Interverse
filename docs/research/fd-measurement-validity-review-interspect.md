# Measurement Validity Review: Interspect Design Document

**Reviewer role:** Measurement validity specialist
**Document reviewed:** `/root/projects/Interverse/hub/clavain/docs/plans/2026-02-15-interspect-design.md`
**Context reviewed:** Clavain CLAUDE.md, AGENTS.md, roadmap.md, galiana/analyze.py, lib-signals.sh, auto-compound.sh, compounding false-positive best-practice doc
**Date:** 2026-02-15
**Focus:** Whether metrics measure what they claim, evidence collection biases, statistical soundness, confounding variables, Goodhart's Law resistance

---

## Executive Summary

The interspect design is ambitious and architecturally thoughtful. Its OODA loop, four-cadence model, and meta-learning concept are well-structured. However, the measurement infrastructure has several validity threats that, if left unaddressed, could cause the system to make wrong self-modifications with high confidence. The most critical finding is that the core metrics (override rate, false-positive rate) are unreliable proxies for agent quality, and the confidence function operates on arbitrary thresholds without calibration data. There is also a self-reinforcing feedback loop risk that the project's own best-practice document (the provenance-tracking solution for flux-drive) explicitly warns about -- but the interspect design does not incorporate that lesson.

**Finding count by severity:**
- P0 (invalid measurement triggering wrong self-modifications): 3
- P1 (high risk of incorrect decisions): 4
- P2 (missing coverage, coarse thresholds): 5
- P3 (polish): 3

---

## 1. Metric Validity

### F-1 [P0]: Override Rate Does Not Measure Agent Wrongness

**Section:** 3.1 (Evidence Store), 3.6 (Canary Monitoring)

The design treats "human override" as the primary signal that an agent recommendation was wrong. This is a proxy measure with at least three confounding interpretations:

1. **Human disagrees but agent was correct.** Humans override correct security findings because fixing them is inconvenient. A high override rate for fd-safety may indicate the agent catches things humans would rather ignore -- which is exactly when the agent is most valuable.

2. **Human agrees by default.** A low override rate may mean the human isn't actually reviewing, just rubber-stamping. This is particularly likely in the "full autonomy" mode (Section 2) where the human "reviews commits after the fact."

3. **Override rate is context-dependent.** An agent reviewing security in a prototype has a legitimately different override profile than the same agent reviewing a production system. The design stores `project` in the event schema but doesn't account for project-type confounding when aggregating override rates.

**Impact:** Interspect uses override rate as input to canary monitoring (Section 3.6: "If override/false-positive rate increases > 50% relative to baseline within the canary window -> auto-revert"). If the metric doesn't measure what it claims, the system will revert correct improvements and keep broken prompts.

**Recommendation:** Classify overrides by reason. At minimum: "finding was wrong" (agent error), "finding was right but not worth fixing" (priority disagreement), "finding was right but already addressed" (stale context). Only the first category is evidence of agent quality problems. This taxonomy should be part of the event schema, not derived after the fact.

### F-2 [P0]: False-Positive Rate Is Measured at the Wrong Point

**Section:** 3.1 (Collection Points table)

The design collects false positives from "Dismissed findings in `/resolve`." This creates selection bias: only findings that reach `/resolve` are measured. Findings that the agent produces but that get lost in synthesis, truncated by token limits, or filtered by triage never enter the measurement pipeline.

Additionally, "dismissed" is not the same as "false positive." A finding can be dismissed because:
- It's actually false (true false positive)
- It's true but low priority (triage decision, not quality signal)
- The user doesn't understand it (UX problem, not agent problem)
- The user already addressed it (stale finding)

The false-positive rate as defined will systematically overcount by conflating all dismissal reasons with agent error.

**Impact:** Prompt tuning (Type 3) and agent demotion decisions are based on this metric. Overcounting false positives leads to over-tuning agents to be less aggressive, reducing their catch rate for real issues. This is the classic precision-recall tradeoff being driven by a one-sided metric.

**Recommendation:** Track dismissal reason in the `/resolve` hook. Separately report "agent wrong" vs "finding deprioritized" vs "already fixed." Only "agent wrong" should feed into false-positive rate for prompt tuning. Consider also measuring false negatives (issues found later that the agent should have caught) to balance the signal.

### F-3 [P1]: Human Correction Evidence Is Unmeasurable as Described

**Section:** 3.1 (Collection Points: "Diff between agent output and final committed version")

This is acknowledged as an open question (Section 6: "How to collect 'human correction' evidence without invasive diff tracking?") but the collection point is still listed in the architecture. The problem is deeper than invasiveness:

1. **Attribution is impossible.** A diff between agent output and the committed version may reflect human correction, additional features, unrelated refactoring, or merge conflict resolution. The system cannot distinguish "human fixed agent's mistake" from "human continued working after agent finished."

2. **Survivor bias.** This only measures corrections to work that was committed. Abandoned agent output (user discards and rewrites from scratch) is invisible -- and those are the most informative failure cases.

**Impact:** If this metric is implemented naively, it will generate noise that dilutes the evidence store. Every unrelated edit will look like a "correction," creating phantom evidence of agent underperformance.

**Recommendation:** Drop this as an automatic collection point. Replace with an explicit `/correction` command that the human invokes when they specifically want to record that the agent got something wrong. Explicit signals are lower volume but higher quality than inferred signals.

### F-4 [P1]: Extraction Signal Lacks a Quality Dimension

**Section:** 3.1 (Collection Points: "Capability used across N projects without modification")

"Used across N projects" measures adoption, not quality. A capability can be widely used but mediocre -- or worse, widely used because it's the only option. The extraction signal as defined would recommend extracting a companion for capabilities that are stable because nobody bothers to improve them, not because they're well-designed.

**Impact:** Companion extraction (Type 6) is one of the highest-risk modification types (Section 3.4). Basing it on a stability metric alone -- without quality evidence -- risks extracting and ossifying mediocre capabilities.

**Recommendation:** Add a quality dimension to the extraction signal. At minimum: the capability's findings should have a low false-positive rate and the capability should have a below-average override rate. Stability + quality together are the extraction signal; stability alone is not.

---

## 2. Evidence Collection Bias

### F-5 [P0]: Self-Reinforcing Feedback Loop in Meta-Learning

**Section:** 3.7 (Meta-Learning Loop)

The meta-learning loop ("Interspect's own modification failures become evidence") is vulnerable to exactly the feedback loop that Clavain's own best-practice document warns about (`docs/solutions/best-practices/compounding-false-positive-feedback-loop-flux-drive-20260210.md`).

The scenario:
1. Interspect modifies agent prompt A based on override evidence
2. The modification is reverted (canary detected regression)
3. This failure is logged: "prompt tightening for A reverted"
4. Next time override evidence accumulates for A, interspect sees the failure and raises the risk classification
5. But the original override evidence may have been noisy (see F-1). The revert was correct -- not because prompt tightening is risky for A, but because the evidence was wrong
6. The meta-learning loop now permanently classifies A as hard-to-modify, blocking legitimate improvements

This is the provenance problem: the meta-learning loop conflates "modification failed because the evidence was bad" with "modification failed because the target is fragile." Without distinguishing these, the system learns the wrong lesson.

**Impact:** The meta-learning loop, intended as a safety mechanism, can create learned helplessness -- the system stops trying to improve agents that have noisy evidence, which may be the agents that most need improvement.

**Recommendation:** Apply the provenance pattern from the existing best-practice doc. Tag modification failures with a root cause: "evidence-quality" (the modification was based on noisy evidence), "target-fragility" (the modification was based on good evidence but the target broke anyway), or "evaluation-error" (the canary gave a false alarm). Only "target-fragility" should raise risk classification. This requires the canary monitoring to record why it triggered, not just that it triggered.

### F-6 [P1]: Survivorship Bias in Evidence Store

**Section:** 3.1 (Evidence Store), 3.2 (Cadences)

The evidence store only captures events from completed workflow runs. Sessions that crash, are abandoned, or are killed by token exhaustion leave no evidence. These are non-random omissions:

- Sessions killed by token limits are likely the ones with the most complex/problematic agent behavior
- Abandoned sessions may indicate the worst agent failures (user gave up)
- Crash sessions may reveal agent interaction bugs

The "last 5 sessions" window in Cadence 2 only counts completed sessions. If 3 of 5 sessions were abandoned due to agent problems, Cadence 2 sees only 2 sessions of data and may not trigger.

**Impact:** The evidence store systematically underrepresents the worst agent failures, creating an optimistic bias in all metrics.

**Recommendation:** Add a SessionStart event to the evidence store. At minimum, log the session ID, project, and timestamp at session open. At sweep time (Cadence 2), count sessions that started but have no corresponding events -- these are "dark sessions" that should be flagged as unmeasured, not ignored.

### F-7 [P2]: Observer Effect in Timing Metrics

**Section:** 3.1 (Collection Points: "Timestamps in signal engine")

The design adds timing instrumentation to every workflow step. In a system where agent dispatch is token-bounded and latency-sensitive, the instrumentation overhead is not zero:

1. JSON serialization and file I/O for every event
2. The `jq` invocations in `lib-galiana.sh` fork a subprocess per event
3. Append-only JSONL means no batching; each event is a separate write

For timing metrics specifically, the measurement adds latency to the thing being measured. The existing `lib-galiana.sh` is fail-safe (returns 0 on error), but it still consumes wall-clock time that contaminates timing data.

**Impact:** Timing metrics will be systematically inflated. This matters most for "time-to-first-signal" (roadmap KPI #4), which is a latency-sensitive metric.

**Recommendation:** Either (a) buffer events in memory and flush at session end, or (b) record timestamps at measurement points but defer serialization. The current pattern of synchronous-write-per-event is appropriate for correctness signals but not for timing signals.

### F-8 [P2]: Selection Bias in Shadow Testing

**Section:** 3.5 (Shadow Testing)

Shadow testing "picks 3-5 recent real inputs from evidence store." The evidence store is not a representative sample of all inputs -- it only contains inputs where something notable happened (override, false positive, correction, etc.). This creates selection bias:

- Inputs that were processed correctly and uneventfully are not in the evidence store
- Shadow testing therefore only tests on edge cases and problem cases
- A prompt change that improves edge-case handling but degrades common-case handling would pass shadow testing

**Impact:** Shadow testing validates changes against the tail of the distribution, not the body. A modification could pass shadow testing and then fail on common inputs.

**Recommendation:** Maintain a separate "shadow corpus" of representative inputs, not drawn from the evidence store. The eval corpus described in roadmap P1.2 ("10+ tasks with expected properties") is the right foundation. Shadow testing should draw from this corpus, not from the evidence store.

---

## 3. Statistical Reasoning

### F-9 [P1]: Confidence Thresholds Are Arbitrary and Uncalibrated

**Section:** 3.2 Cadence 4 (Confidence Filter)

```
< 0.3  -> log only
0.3-0.7 -> session-only (Cadence 1)
0.7-0.9 -> persistent with canary (Cadence 2)
> 0.9  -> persistent, skip shadow test (Cadence 2/3)
```

These thresholds are not derived from any calibration data. The function `f(evidence_count, cross_session_count, cross_project_count, recency)` is not defined -- the document gives the output ranges but not the formula. Critical questions:

1. **What is the unit of confidence?** Is 0.7 a probability that the modification is correct? A weighted score? An arbitrary index? Without a defined semantics, the thresholds cannot be evaluated.

2. **Why these specific values?** 0.3/0.7/0.9 are round numbers that suggest they were chosen for readability, not empirical validity. There's no analysis showing that the false-modification rate is acceptable at confidence 0.3 for session-only changes.

3. **The 0.9 threshold skips shadow testing.** This is the highest-risk threshold decision in the entire system. What evidence count produces confidence > 0.9? If it's achievable with 5 overrides across 3 sessions, that may be far too low for skipping the primary safety gate.

**Impact:** The confidence filter is the gatekeeper for all self-modifications. If its thresholds are wrong, modifications are either too aggressive (wrong changes applied) or too conservative (correct changes delayed indefinitely). Without calibration, there's no way to know which failure mode is active.

**Recommendation:** Start with a single threshold (persistent vs. session-only) and calibrate it empirically against the first few months of evidence data. Only introduce additional thresholds when there's data to calibrate them against. Document the confidence function explicitly, including its range and interpretation. Never skip shadow testing based on confidence alone -- the cost of shadow testing is low relative to the cost of a bad persistent modification.

### F-10 [P1]: Canary Window Too Small for Statistical Significance

**Section:** 3.6 (Canary Monitoring)

The default canary window is 5 uses. The revert threshold is "override/false-positive rate increases > 50% relative to baseline."

With a baseline override rate of 0.4 and a canary window of 5 uses:
- Baseline expected overrides: 2 out of 5
- 50% increase threshold: 0.6, meaning 3 out of 5
- Going from 2/5 to 3/5 is a single additional override
- With n=5, a single event changes the rate by 20 percentage points

A binomial test shows that observing 3/5 overrides when the true rate is 0.4 has p-value ~0.317 (one-tailed). This is nowhere near statistical significance. The canary monitor would be making revert/keep decisions based on noise.

**Impact:** At n=5, the canary monitor is essentially a coin flip. It will revert good changes and keep bad ones with roughly equal probability for any meaningful baseline rate.

**Recommendation:** Either (a) increase the canary window substantially (20+ uses) to achieve reasonable statistical power, or (b) use a sequential testing framework (e.g., sequential probability ratio test) that accumulates evidence until a decision threshold is reached rather than using a fixed window. The document's own open question ("5 uses may be too small for rarely-triggered agents") is correct -- but the problem is worse than stated. Even for frequently-triggered agents, n=5 is inadequate.

### F-11 [P2]: "Two Sessions Showing Same Pattern" Is an Arbitrary Minimum

**Section:** 3.2 Cadence 2

"Requires >= 2 sessions showing same pattern" for persistent modifications. Two sessions is a very low bar:

- If a user has a particular coding style that consistently triggers a certain override pattern, two sessions is one day of work
- Two sessions provides no protection against systematic bias in a single user's behavior
- The "same pattern" matching is undefined -- how similar do two overrides need to be to count as "the same pattern"?

**Impact:** Two-session persistence requirements are low enough to allow individual user preferences to drive system-wide prompt modifications. In a single-user system this may be acceptable; in a multi-user system it would be dangerous.

**Recommendation:** Define "same pattern" explicitly (same agent, same finding category, same project type?). For single-user systems, 2 sessions may be acceptable but should be documented as a known limitation. Consider requiring cross-project evidence for persistent modifications, not just cross-session.

---

## 4. Confounding Variables

### F-12 [P2]: Cross-Project Evidence Ignores Project Differences

**Section:** 3.2 Cadence 4 (confidence function includes cross_project_count)

The confidence function rewards cross-project evidence, but projects differ in:
- Language and framework (Go project vs. Python project)
- Maturity (prototype vs. production)
- Domain (security-critical vs. internal tool)
- Code style and conventions

An override pattern seen in 3 different projects has higher confidence, but if all 3 projects are Go services, the evidence may be language-specific rather than universal. Interspect would modify the agent prompt globally based on language-specific evidence.

**Impact:** Cross-project evidence that doesn't account for project type creates over-generalized prompt modifications. An agent tuned for Go patterns will underperform on Python code.

**Recommendation:** Include project metadata (language, framework, maturity level) in the evidence schema. The confidence function should weight cross-project evidence by project diversity, not just project count. Evidence from 3 Go projects is weaker than evidence from 1 Go project + 1 Python project + 1 TypeScript project.

### F-13 [P2]: Token Usage Attribution Is Ambiguous

**Section:** 3.1 (Collection Points: "Wrap subagent calls with cost tracking")

Token usage is attributed per agent, but token costs depend on:
- Input context size (varies by project and session state)
- Model used (varies by routing decisions)
- Retries due to rate limits or errors
- Context window packing by the Claude Code framework

The same agent processing the same input can have wildly different token costs depending on factors outside the agent's control. Attributing cost to the agent without controlling for these factors will produce misleading cost metrics.

**Impact:** Workflow pipeline optimization (Type 5) uses timing and token metrics to identify low-value steps. Without proper attribution, the system may cut agents that are efficient but happen to run in expensive contexts, and keep agents that are wasteful but happen to run in cheap contexts.

**Recommendation:** Normalize token costs by input size and model. Report cost-per-finding rather than absolute cost, to separate agent value from context cost. At minimum, record model and input token count alongside output token count so that normalization is possible after the fact.

### F-14 [P3]: Recency Weighting in Confidence Function Is Undefined

**Section:** 3.2 Cadence 4

The confidence function includes `recency` as an input but doesn't define the decay function. This matters because:
- Too fast decay: system forgets valid evidence and never reaches persistent-modification thresholds
- Too slow decay: system acts on stale evidence that no longer applies (e.g., after a major refactor)

Without defining the recency function, the confidence behavior is unpredictable.

**Recommendation:** Define the half-life explicitly. A reasonable starting point: evidence older than 30 days receives 50% weight, evidence older than 90 days receives 10% weight. But this should be calibrated against observed evidence patterns, not chosen arbitrarily.

---

## 5. Goodhart's Law Resistance

### F-15 [P2]: No Cross-Check Metrics for Prompt Tuning

**Section:** 4 Type 3 (Prompt Tuning)

Prompt tuning is driven by override rate and false-positive rate. These are both precision-oriented metrics. There is no recall metric ("did we miss something we should have caught?").

Goodhart's Law prediction: Interspect will learn to make agents less aggressive over time, reducing overrides and false positives. The agents will converge toward saying nothing controversial, which minimizes measured error but maximizes real error (missed findings).

This is the same dynamic that makes customer satisfaction surveys converge toward "don't bother the customer" rather than "provide valuable service."

**Impact:** Over multiple interspect cycles, agent catch rates will silently degrade as prompts are tuned to minimize human friction rather than maximize finding quality.

**Recommendation:** Track a recall proxy. Options:
1. Log escaped defects (`galiana_log_defect` already exists) and correlate with agent activity
2. Periodically inject known-bad inputs and verify agents catch them (red-teaming)
3. Track the ratio of "finding was right but deprioritized" overrides -- a healthy agent should generate some of these

The existing Galiana `defect_escape_rate` KPI is the right counterbalance, but the interspect design doesn't reference it. Interspect's modification decisions should be required to check both precision (override/FP rate) AND recall (defect escape rate) before applying changes.

### F-16 [P3]: LLM-as-Judge in Shadow Testing Is Not Validated

**Section:** 3.5 (Shadow Testing), 5 Decision #6

The design acknowledges that LLM-as-judge is "not perfect but sufficient for a confidence gate." However, the research roadmap (Section: Medium-Term) notes that "LLM judges show 40-57% systematic bias." Using an unvalidated biased judge as a safety gate undermines the shadow testing mechanism.

Specific risks:
- LLMs tend to prefer longer, more detailed outputs (verbosity bias)
- LLMs tend to agree with the last option presented (position bias)
- LLMs may not reliably detect subtle regressions in domain-specific analysis

**Impact:** Shadow testing provides a false sense of safety if the judge systematically approves changes that degrade quality in ways the judge can't detect.

**Recommendation:** At minimum, randomize presentation order in LLM-as-judge comparisons. Better: use multiple judge prompts and require consensus. Best: calibrate the LLM judge against human judgments on a held-out set before trusting it for safety decisions.

### F-17 [P3]: Context Injection Has No Size Bound

**Section:** 4 Type 1 (Context Injection)

Context injection is classified as "Low" risk with "Worst case: irrelevant context wastes tokens." But there's a second-order Goodhart's Law risk: if interspect measures agent performance and attributes improvements to context injections, it will accumulate context indefinitely. Each injection is individually low-risk, but the aggregate can:

1. Push useful context out of the model's attention window
2. Increase token costs monotonically
3. Create contradictory injections when evidence changes

**Impact:** Context injection becomes the "junk drawer" -- the safe, low-risk modification type that interspect defaults to, gradually degrading agent performance through context bloat.

**Recommendation:** Add a maximum sidecar file size (e.g., 2000 tokens). Require interspect to prune or consolidate context injections when the limit is approached. Track context-injection-count as a metric and alert when it grows monotonically.

---

## 6. Missing Coverage

### F-18 [P2]: No Baseline Establishment Protocol

**Sections:** 3.6 (Canary Monitoring), 3.2 (Cadences)

The canary monitoring references `baseline_override_rate` and `baseline_false_positive_rate` but doesn't define how baselines are established. Without a baseline protocol:

- What's the measurement window for establishing a baseline? (Last 5 uses? Last 20? All-time?)
- How are baselines updated as the system evolves?
- What if the baseline was established during an atypical period?

A baseline computed from 5 observations has a 95% confidence interval of roughly +/- 40 percentage points (for a rate around 0.4). This baseline is so uncertain that the 50% relative increase threshold (F-10) is meaningless.

**Recommendation:** Define baseline computation explicitly: minimum 20 observations, rolling window of last 50 observations, updated weekly. Don't allow canary monitoring to start until the baseline meets a minimum sample size.

---

## Summary Table

| ID | Severity | Category | Title |
|----|----------|----------|-------|
| F-1 | P0 | Metric Validity | Override rate does not measure agent wrongness |
| F-2 | P0 | Metric Validity | False-positive rate measured at wrong point with wrong definition |
| F-5 | P0 | Evidence Bias | Self-reinforcing feedback loop in meta-learning (provenance not applied) |
| F-3 | P1 | Metric Validity | Human correction evidence is unmeasurable as described |
| F-4 | P1 | Metric Validity | Extraction signal lacks quality dimension |
| F-9 | P1 | Statistical Reasoning | Confidence thresholds arbitrary and uncalibrated |
| F-10 | P1 | Statistical Reasoning | Canary window too small for statistical significance (n=5, p=0.317) |
| F-6 | P2 | Evidence Bias | Survivorship bias in evidence store (abandoned sessions invisible) |
| F-7 | P2 | Evidence Bias | Observer effect in timing metrics |
| F-8 | P2 | Evidence Bias | Selection bias in shadow testing corpus |
| F-11 | P2 | Statistical Reasoning | Two-session minimum is arbitrary; "same pattern" undefined |
| F-12 | P2 | Confounding | Cross-project evidence ignores project-type differences |
| F-13 | P2 | Confounding | Token cost attribution ambiguous without normalization |
| F-15 | P2 | Goodhart's Law | No recall metric cross-checks precision-oriented prompt tuning |
| F-18 | P2 | Missing Coverage | No baseline establishment protocol (minimum sample size, window) |
| F-14 | P3 | Confounding | Recency weighting in confidence function undefined |
| F-16 | P3 | Goodhart's Law | LLM-as-judge unvalidated against known systematic biases |
| F-17 | P3 | Goodhart's Law | Context injection has no size bound; junk-drawer risk |

---

## Recommended Implementation Order

1. **Before building anything:** Define the confidence function explicitly, including units, formula, and threshold rationale. Define "same pattern." This is design work, not implementation.

2. **Phase 1 (with P1.1 analytics):** Implement override-reason taxonomy (F-1), dismissal-reason taxonomy (F-2), and provenance tagging on meta-learning events (F-5). These are schema decisions that must be made before evidence collection begins.

3. **Phase 1 (with P1.2 evals):** Build the shadow testing corpus from eval data, not the evidence store (F-8). Calibrate the LLM judge against human judgments (F-16).

4. **After first data collection:** Calibrate confidence thresholds against real evidence distributions (F-9). Increase canary window or implement sequential testing (F-10). Establish baseline protocol (F-18).

5. **Ongoing:** Add defect-escape-rate as a required cross-check for any prompt tuning (F-15). Add context injection size bounds (F-17). Normalize token costs (F-13).

---

## Relationship to Existing Infrastructure

The review found that Clavain already has relevant infrastructure that the interspect design should build on:

1. **Galiana analytics** (`galiana/analyze.py`, `galiana/lib-galiana.sh`) already implements 4 of the 5 roadmap KPIs. Interspect should consume Galiana outputs rather than building parallel measurement.

2. **The provenance best-practice** (`docs/solutions/best-practices/compounding-false-positive-feedback-loop-flux-drive-20260210.md`) directly addresses the meta-learning feedback loop (F-5). The interspect design should cite this document and implement its recommendations.

3. **lib-signals.sh** provides the signal detection infrastructure. Its weight-based thresholds (weight >= 3 to trigger) are the same kind of arbitrary thresholds flagged in F-9. When interspect subsumes or complements auto-compound, the threshold calibration concern applies to both systems.

4. **The roadmap's P1.2 (Agent Evals as CI)** is the natural source for shadow testing corpora (F-8) and LLM judge calibration (F-16). These should be designed together, not independently.
