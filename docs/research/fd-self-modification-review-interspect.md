# Self-Modification Safety Review: Interspect Design Document

**Reviewer:** fd-self-modification specialist
**Date:** 2026-02-15
**Document under review:** `/root/projects/Interverse/hub/clavain/docs/plans/2026-02-15-interspect-design.md`
**Project context:** Clavain CLAUDE.md, AGENTS.md, hooks/hooks.json, hooks/auto-compound.sh, hooks/lib-signals.sh, galiana/lib-galiana.sh, docs/roadmap.md

---

## Executive Summary

The interspect design is thoughtful about safety fundamentals: meta-rules are declared human-owned (Section 2), every modification is an atomic git commit (Section 5.3), and confidence thresholds gate premature action (Section 3.2, Cadence 4). However, the design has several gaps where stated safety properties are not mechanically enforced. The most critical: the document declares interspect "cannot modify its own safety gates" but provides no mechanism to prevent it -- no file-level ACLs, no pre-commit hooks, no path exclusion lists. Additional concerns involve the >0.9 confidence bypass of shadow testing, inter-dependent modifications where reverts cascade, and context injection classified as "low risk" despite its ability to alter all downstream agent behavior.

Seven findings below, prioritized P0 through P3.

---

## Finding 1: Safety Gate Protection Is Declarative, Not Mechanical

**Priority:** P0
**Section:** 2 (Autonomy Model), line 18-19
**Type:** Unbounded self-modification risk

The design states:

> "Interspect cannot modify its own safety gates, canary thresholds, revert logic, or autonomy mode flag. These meta-rules are human-owned."

And reaffirms in Section 5, decision 5:

> "Meta-rules are human-owned. Interspect cannot modify its own safety gates or autonomy mode."

**Problem:** This is a policy statement, not an enforcement mechanism. The document describes interspect as having full write access to Clavain's files and committing changes autonomously. There is no specification of:

1. **Which files contain the safety gates, canary thresholds, revert logic, and autonomy mode flag.** Without an explicit enumeration, enforcement is impossible. Will these be in a single `interspect-config.yaml`? Spread across multiple files? Embedded in the interspect code itself?

2. **How write protection is enforced.** Options include:
   - A path exclusion list checked in the modification pipeline's "Classify" step (Section 3.3, step 1)
   - Git pre-commit hooks that reject commits touching protected files when the author is interspect
   - File-system ACLs or read-only permissions
   - A hardcoded allowlist of modifiable file patterns per modification type

3. **Who checks the checker.** If interspect's own code contains the exclusion logic, then modifying its own code IS modifying its safety gates. The design acknowledges this in Section 3.7 (Meta-Learning Loop) where it says "interspect improves its own improvement process" -- but this creates a direct tension with the safety gate protection claim.

**Concrete failure scenario:** Interspect's meta-learning loop (Section 3.7) observes that a modification was reverted 3 times. It raises the risk classification for that file. But the code that decides risk classifications IS interspect code. If interspect can modify its own classification logic (which is part of "improving its own improvement process"), it could lower a risk classification from "high" to "low", bypassing shadow testing.

**Recommendation:**
- Enumerate all protected files/paths in a manifest file that is itself protected (e.g., checked by a git pre-commit hook external to interspect)
- The modification pipeline's "Classify" step must check a hardcoded allowlist, not a dynamically computed one
- The meta-learning loop (Section 3.7) must be explicitly excluded from modifying: the confidence threshold function, the canary revert logic, the risk classification table, and the propose-mode flag

---

## Finding 2: High Confidence (>0.9) Bypasses Shadow Testing

**Priority:** P1
**Section:** 3.2 (Cadence 4 -- Confidence Filter), line 114
**Type:** Safety gate bypass

The confidence filter specifies:

```
> 0.9  -> persistent, skip shadow test (Cadence 2/3)
```

**Problem:** Shadow testing is the primary safety mechanism for medium and high-risk changes (Section 3.4 risk classification table). Allowing ANY confidence score to bypass shadow testing means the safety gate can be circumvented through evidence accumulation alone.

Consider the attack path:
1. Interspect observes the same override pattern 20 times across 10 sessions
2. Confidence exceeds 0.9
3. A "Skill SKILL.md rewrite" (classified Medium, normally requires shadow test) proceeds without shadow testing
4. The rewrite introduces a subtle regression that would have been caught by shadow testing

The risk is amplified by Finding 4 (measurement validity) -- if the confidence function is miscalibrated (and the document provides no calibration methodology), high-confidence scores may be routinely assigned to modifications that don't warrant them.

**Concrete failure scenario:** An agent prompt has a high false-positive rate for Go projects specifically. Interspect accumulates enough evidence from Go projects to hit >0.9 confidence. It rewrites the prompt without shadow testing. The rewrite fixes Go false positives but introduces false negatives for Python projects that were never in the evidence sample.

**Recommendation:**
- Remove the >0.9 shadow test bypass entirely, or
- Restrict the bypass to Type 1 (context injection) and Type 2 (routing adjustment) only -- the two lowest-risk modification types
- High-risk modifications (Types 5-6, hook logic) should NEVER skip shadow testing regardless of confidence

---

## Finding 3: Inter-Dependent Modifications Create Non-Atomic Revert Chains

**Priority:** P1
**Section:** 3.3 (Modification Pipeline), 4 (Six Modification Types)
**Type:** Rollback failure

The design states every modification is "an atomic git commit that can be cleanly reverted" (Section 5.3). However, the six modification types can create semantic dependencies between separately-committed changes:

**Dependency chain example:**
1. Commit A: Type 2 -- routing adjustment removes `fd-safety` from project X's triage
2. Commit B: Type 3 -- prompt tuning of `fd-architecture` adds safety-related checks to compensate for fd-safety's absence
3. Commit C: Type 1 -- context injection adds "this project has architectural safety gates" to project X's sidecar

Now the canary monitor detects that Commit A degraded safety coverage. It auto-reverts Commit A, restoring fd-safety to triage. But Commit B's prompt changes are still in place -- fd-architecture now duplicates fd-safety's work, increasing token cost and creating conflicting findings. Commit C's context is now misleading.

**The document does not address:**
- Tracking dependencies between interspect commits
- Reverting a commit chain atomically (reverting A + B + C together)
- Detecting when reverting one change invalidates another

**Concrete failure scenario:** The canary auto-revert mechanism (Section 3.6) reverses a routing change, but the prompt modifications that were tuned to match the new routing remain. The system enters a state that was never tested -- the old routing with the new prompts.

**Recommendation:**
- Add a "modification group" concept where related changes across Types 1-6 are linked by a group ID
- Canary monitoring and auto-revert should operate on the group, not individual commits
- The revert mechanism should check for dependent modifications before reverting any single commit

---

## Finding 4: Context Injection Classified as Low Risk Despite Downstream Amplification

**Priority:** P2
**Section:** 3.4 (Risk Classification), 4.1 (Type 1: Context Injection)
**Type:** Wrong risk classification

The risk classification table assigns context injection the lowest risk:

| Change Type | Risk | Safety Gate |
|------------|------|-------------|
| Context injection (sidecar append) | Low | Apply directly |

The document justifies this: "Worst case: irrelevant context wastes tokens" (Section 4.1).

**Problem:** This worst-case analysis is incorrect. Context injection modifies the input to every downstream agent that reads the sidecar. The actual worst case is not wasted tokens but misdirected agent behavior:

1. **Context that suppresses findings:** Injecting "This project uses parameterized queries throughout" into a safety sidecar could cause fd-safety to skip SQL injection checks. If the statement is wrong (interspect generalized from 3 sessions where it happened to be true), the project loses safety coverage.

2. **Context that creates false confidence:** Injecting "Architecture has been reviewed and approved" could cause fd-architecture to reduce scrutiny on genuine architectural problems.

3. **Context that cascades through the meta-learning loop:** Bad context -> agents produce fewer findings -> lower override rate -> interspect interprets this as "agents are performing well" -> increases confidence -> injects more context. This is a positive feedback loop.

The design says context injection is "additive only" but additive context in an LLM prompt can have subtractive effects on behavior.

**Recommendation:**
- Reclassify context injection as Medium risk with Canary monitoring (not "Apply directly")
- Alternatively, add a length/growth limit to sidecar files (e.g., max 500 tokens per sidecar, max 2 new lines per session) to bound the blast radius
- Add context injection to the canary monitoring system so bad context can be detected and reverted
- Explicitly document the distinction between "additive to the file" and "effect on agent behavior" -- the latter is not guaranteed to be additive

---

## Finding 5: Shadow Testing Validity Gaps

**Priority:** P2
**Section:** 3.5 (Shadow Testing)
**Type:** Weak testing / false confidence

The shadow testing protocol:

1. Pick 3-5 recent real inputs from evidence store
2. Run old prompt/skill -> capture output
3. Run new prompt/skill -> capture output
4. Compare via LLM-as-judge
5. Score and decide

**Multiple validity concerns:**

### 5a. Sample size is insufficient for statistical confidence

3-5 inputs is not a representative sample for skills/agents that handle diverse input types. The design document's own evidence schema (Section 3.1) shows events span multiple projects and event types. A prompt change for fd-safety might behave identically on 5 easy inputs but catastrophically on an edge case.

**Question:** Is 3-5 a hard minimum, or will the system scale the sample based on the modification's blast radius? For Type 6 (companion extraction), 3-5 inputs seems particularly inadequate.

### 5b. LLM-as-judge criteria are unspecified

The judge must evaluate "same correct findings? Fewer false positives? Missed catches?" (Section 3.5, step 4). But:
- What constitutes a "correct" finding? Who defines the ground truth?
- How is the judge's own prompt protected from interspect modification? (Connects to Finding 1)
- The judge's evaluation is itself subject to prompt sensitivity -- the same findings may be scored differently based on judge prompt wording

### 5c. Selection bias in "recent real inputs"

Recent inputs may not represent the full distribution. If the last 5 sessions were all Go projects, shadow testing a prompt change on those inputs tells you nothing about Python, TypeScript, or Rust projects. The modification might be approved based on unrepresentative data.

### 5d. Temporal confounding

Running old and new prompts against the same inputs at the same time does not reproduce the original context. The original output may have depended on conversation history, tool state, or project state that no longer exists. Shadow testing in isolation may show improvement, but the improvement may not hold in context.

**Recommendation:**
- Scale sample size with blast radius: 3-5 for Low/Medium, 10+ for High
- Require cross-project diversity in the sample (at least 2 different projects)
- Define explicit scoring rubric for the LLM-as-judge (not just "compare")
- Protect the judge prompt from interspect modification (add to the protected paths in Finding 1)

---

## Finding 6: Propose Mode Has No Specified Atomicity Guarantee

**Priority:** P2
**Section:** 2 (Autonomy Model)
**Type:** Propose mode bypass path

The design states:

> "Optional: Propose mode. A flag that switches the pipeline to present diffs via AskUserQuestion instead of committing directly."

**Concerns:**

### 6a. Mode switch timing

What happens to in-flight modifications when the mode switches from autonomy to propose? The design has three cadences that can operate concurrently:
- Cadence 1 (within-session) makes in-memory changes immediately
- Cadence 2 (end-of-session) runs during Stop hooks
- Cadence 3 (periodic batch) can be triggered by command

If a human switches to propose mode while a Cadence 2 sweep is running, does the sweep halt? Does it complete with the old mode? Does it queue its pending changes for review?

**Question:** Is propose mode checked once at pipeline entry, or at each step? The modification pipeline (Section 3.3) has 6 steps -- if mode is checked only at step 4 (Apply), steps 1-3 still execute, which means the classification, generation, and safety gate steps ran in autonomous mode before the mode switch took effect.

### 6b. Cadence 1 bypasses propose mode by design

Cadence 1 changes are "in-memory" and "die with the session" (Section 3.2). But in-memory prompt modifications during a session affect real review outputs. If propose mode is meant to give the human control over all modifications, Cadence 1 defeats this intent -- the human sees the diffs for Cadence 2/3 but never sees the in-memory Cadence 1 changes that already affected their session.

### 6c. The flag's storage location is unspecified

Where does the autonomy/propose mode flag live? If it's in a config file that interspect can modify (violating the Section 2 claim), that's a P0. If it's in a file protected by the same mechanism as Finding 1, the protection mechanism's absence applies here too.

**Recommendation:**
- Specify that propose mode is checked at the Apply step AND that in-flight modifications are queued (not dropped) when mode switches
- Log Cadence 1 in-memory modifications to a visible location even in autonomy mode, so they can be audited
- Explicitly place the mode flag in the protected paths manifest (Finding 1)

---

## Finding 7: Canary Monitoring Uses Rate-Based Metrics Vulnerable to Goodhart's Law

**Priority:** P3
**Section:** 3.6 (Canary Monitoring)
**Type:** Measurement validity (connects to fd-measurement-validity agent's concerns)

The canary monitoring measures:
- Override rate (relative to baseline)
- False positive rate (relative to baseline)
- Revert threshold: >50% relative increase

**Concerns:**

### 7a. Rate metrics can improve by reducing volume

A prompt modification that causes an agent to flag fewer things will reduce the false positive count (numerator) but also reduce the total findings count (denominator). The false positive RATE might stay the same or even improve, while the agent is now missing real issues.

The design does not specify whether canary monitoring checks that the total findings count remains in a reasonable range. A modification that reduces findings from 10 to 1 while maintaining the same false positive rate of 30% (0.3/1 vs 3/10) looks identical by rate metrics but represents a 90% reduction in coverage.

### 7b. Canary window of 5 uses may be insufficient

The document flags this as an open question (Section 6), and rightly so. With 5 uses:
- A modification to a rarely-triggered agent might take weeks to complete the canary window
- During that time, the modification is live and potentially causing harm
- 5 data points provide very weak statistical power for detecting a 50% relative change in rates

### 7c. Baseline measurements are snapshots

The canary metadata stores `baseline_override_rate` and `baseline_false_positive_rate` at the time of modification. But these rates naturally fluctuate session to session. A modification applied during a period of unusually high override rate will have an inflated baseline, making it harder to trigger the 50% revert threshold. Conversely, a modification applied during an unusually low baseline period will trigger false reverts.

**Recommendation:**
- Add total findings count as a canary metric alongside rates (revert if findings drop >50%)
- Use a rolling baseline window (last N uses before modification) rather than a point-in-time snapshot
- Consider adaptive canary windows: extend the window if the modification hasn't been exercised enough for statistical significance

---

## Questions for the Design Author

These are items I could not resolve from the document alone:

1. **Interaction with auto-compound hook:** The design mentions interspect's Cadence 2 triggers on Stop events alongside auto-compound (Section 3.2). The existing `auto-compound.sh` uses a shared stop sentinel (`/tmp/clavain-stop-${SESSION_ID}`) -- only one Stop hook can return "block" per cycle. Does interspect get its own hook, or does it extend auto-compound? If separate, how do they coordinate sentinel access?

2. **Interaction with Galiana analytics:** The existing `galiana/lib-galiana.sh` writes to `~/.clavain/telemetry.jsonl`. The interspect evidence store writes to `.clavain/interspect/evidence/`. Are these complementary or overlapping? Will interspect consume Galiana events as input, or will they be unified?

3. **Cross-project evidence isolation:** The evidence schema includes a `project` field (Section 3.1). When interspect aggregates evidence across projects, does it account for project-specific context? A pattern that's a false positive in intermute (Go, parameterized queries) might be a true positive in a different project.

4. **Companion extraction (Type 6) and propose mode:** Open question from Section 6 -- "Should companion extraction be fully autonomous or always propose-mode regardless of flag?" From a self-modification safety perspective, the answer should be always-propose. Companion extraction creates new modules with their own lifecycle; this is the highest blast radius modification type and should never be fully autonomous.

5. **Evidence store integrity:** The evidence store is append-only and git-tracked (Section 3.1). But interspect commits to git. Could interspect fabricate evidence events by appending to its own evidence store before committing? This would be an evidence poisoning attack that undermines all downstream confidence calculations.

---

## Summary of Findings

| # | Priority | Finding | Risk Type |
|---|----------|---------|-----------|
| 1 | P0 | Safety gate protection is declarative, not mechanical | Unbounded self-modification |
| 2 | P1 | >0.9 confidence bypasses shadow testing | Safety gate bypass |
| 3 | P1 | Inter-dependent modifications create non-atomic revert chains | Rollback failure |
| 4 | P2 | Context injection misclassified as low risk | Wrong risk classification |
| 5 | P2 | Shadow testing has multiple validity gaps | Weak testing |
| 6 | P2 | Propose mode has no atomicity guarantee | Propose mode bypass |
| 7 | P3 | Canary monitoring vulnerable to Goodhart's Law | Measurement validity |

**Overall assessment:** The design demonstrates genuine safety thinking -- the OODA loop structure, confidence thresholds, canary monitoring, and meta-learning are sound architectural choices. The primary gap is that safety properties are stated as design principles but not specified as enforcement mechanisms. Before implementation, Findings 1-3 should be resolved at the design level; implementing without mechanical enforcement of safety gates would create a system that believes it is safe but cannot prove it.
