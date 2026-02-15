# UX & Product Review: Interspect Design
**Date:** 2026-02-15
**Reviewer:** fd-user-product (Flux-drive User & Product Reviewer)
**Target:** `/root/projects/Interverse/hub/clavain/docs/plans/2026-02-15-interspect-design.md`

---

## Primary User & Job

**Primary user:** The Claude Code operator using Clavain as their engineering rig — developers who work in long-form sessions across multiple projects, accumulating evidence about what works and what produces noise.

**Job to complete:** Continuously improve the effectiveness of their engineering rig (agents, skills, workflows) without manual maintenance work — reduce false positives, eliminate unnecessary steps, adapt agents to project-specific patterns, and capture learnings automatically.

**Secondary user:** Future operators discovering a Clavain instance that has already adapted to its environment — they inherit a self-tuned rig rather than starting from scratch.

---

## Critical UX Failures

### 1. Zero Visibility Into What Changed and Why (BLOCKING ISSUE)

**Problem:** The design document states "the human reviews commits after the fact" but provides no UX for actually doing this review in a meaningful way.

**Evidence gaps:**
- Commit message format is mentioned once (`[interspect]` prefix) with no specification of what goes in the message body
- No mention of how the human discovers which commits are interspect-generated in a busy repo with many commits
- No specification of how reasoning/evidence is surfaced in the commit or linked artifacts
- Evidence store is append-only JSONL — reasonable for the system, hostile for human audit

**User failure modes:**
1. Human runs `git log` → sees `[interspect] Adjust fd-safety prompt` → no way to understand WHY without reading JSONL evidence files and reverse-engineering the decision
2. Human notices behavior change (e.g., fd-safety stopped flagging something) → no breadcrumb trail back to the interspect modification that caused it
3. Multiple interspect commits accumulate → human can't triage which ones to review first (are some higher-risk than others?)
4. Human wants to understand if a change is working → must manually track canary metadata in JSON files, no human-readable summary

**Missing UX components:**
- No commit message template showing evidence summary, confidence score, risk level, canary window
- No `/interspect-log` or `/interspect-audit` command to translate evidence store into human-readable findings
- No "why this change" artifact — git notes, sidecar markdown file, or structured message body linking to evidence
- No way to search for "all interspect changes to fd-safety" without grepping git log
- No way to compare before/after behavior for a specific change

**Recommendation:** Treat commit messages as the primary audit interface. Every interspect commit should include:
```
[interspect] <one-line summary>

Evidence:
- <event type>: <count> occurrences across <N> sessions
- Confidence: <score> (threshold: 0.7)
- Risk: <level> → Safety: <gate used>

What changed: <file> line <X>-<Y>
Pattern: <human-readable pattern description>
Canary: <N> uses, monitoring until <date or count>

Evidence log: .clavain/interspect/reports/<commit-hash>.md
```

And generate a structured report file per commit with full evidence trails.

---

### 2. Propose Mode Granularity is Wrong (UX MISMATCH)

**Problem:** "One 'yes' per batch" is specified but "batch" is undefined. The design mixes changes with wildly different blast radii and confidence levels.

**Scenarios where batch approval breaks down:**

**Scenario A: Mixed risk batch**
- Interspect queues 5 modifications: 2 low-risk sidecar appends, 1 medium-risk prompt tune, 1 high-risk agent removal, 1 companion extraction scaffold
- User sees one big diff, says "yes"
- High-risk change was buried in noise, user didn't scrutinize it

**Scenario B: Can't accept partial batch**
- Batch includes 3 changes, user agrees with 2, rejects 1
- No UX for "yes to A and B, no to C"
- User must reject entire batch, manually cherry-pick later

**Scenario C: No context in diff**
- Diff shows prompt change but doesn't surface the evidence that triggered it
- User can't evaluate whether the change makes sense
- Forced to approve/reject based on diff quality alone, not on whether the modification addresses the right problem

**User expectation mismatch:**
Users expect approval granularity to match risk level. Low-risk changes (sidecar context) should auto-apply even in propose mode. High-risk changes (agent removal, companion extraction) should always require explicit approval with full evidence summary.

**Recommendation:** Abandon single-granularity propose mode. Replace with risk-based routing:
- Low risk → auto-apply, notify in summary
- Medium risk → auto-apply with canary, notify with revert instructions
- High risk → always propose, even in autonomous mode (shadow test report + approval gate)

If a true "review everything" mode is needed, make it per-change approval with evidence context, not batch approval.

---

### 3. Debugging Degradation Has No User-Facing Tools (MISSING WORKFLOW)

**Problem:** "How does a user debug when interspect makes things worse?" is not addressed.

**Scenario:** User notices fd-safety is now producing more false positives after an interspect change.

**What the user needs to do (current design):**
1. Run `git log --grep="\[interspect\]"` to find candidate commits
2. Read commit to identify which one touched fd-safety
3. Manually inspect the prompt diff
4. Guess whether this is the cause
5. Manually revert the commit
6. Hope that interspect doesn't re-apply the same change next session (no mechanism specified to prevent this)

**What's missing:**
- No `/interspect-revert <target>` command that understands interspect commits and updates canary metadata to prevent re-application
- No `/interspect-status <agent|skill>` to show modification history for a specific component
- No canary monitoring dashboard — user can't see "fd-safety is in canary period, 3/5 uses remaining, current override rate 0.6 vs baseline 0.4"
- No linkage from runtime behavior back to the interspect change that caused it
- No "blame" mode showing which interspect modification introduced a line in a prompt

**User recovery path is entirely manual and error-prone.**

**Recommendation:** Build debugging commands first, autonomous modifications second:
- `/interspect-status [component]` → modification history, canary state, current metrics vs baseline
- `/interspect-revert <commit-ish>` → revert + blacklist the modification pattern from re-application
- `/interspect-blame <agent> <behavior>` → trace runtime behavior back to modifications
- Hook into flux-drive to annotate review output with "[from fd-safety, modified by interspect <commit> <days-ago>]"

---

### 4. Onboarding is Invisible (ADOPTION RISK)

**Problem:** A new user (or the same user 3 months later) has no way to understand what interspect is doing or has done.

**Scenario A: New user inherits modified instance**
- Installs Clavain, starts using it
- Doesn't know skills/agents have been modified from upstream
- Hits unexpected behavior (agent is overly aggressive or overly lenient)
- No signal that this is due to interspect adaptation vs upstream design
- Can't compare against "stock" Clavain behavior

**Scenario B: User forgets they enabled autonomous mode**
- Works on project A for 2 weeks, interspect tunes agents
- Switches to project B
- fd-safety behavior is different, user is confused
- Doesn't remember that interspect applied project-specific routing overrides

**Scenario C: User wants to reset to baseline**
- Wants to start fresh, undo all interspect modifications
- No documented way to do this
- Must manually revert commits? Delete evidence store? Both?

**What's missing:**
- No `/interspect-summary` showing what has been modified and when
- No indicator in statusline or session-start hook output that "interspect has modified 3 agents in this project"
- No documentation explaining interspect's autonomy model in user-facing terms
- No "reset to upstream" command
- No way to distinguish upstream Clavain from interspect-adapted Clavain when reading docs or getting help

**Recommendation:**
- Session-start hook should inject interspect summary if modifications exist: "Interspect has adapted this Clavain instance: 3 agents modified, 2 skills tuned, routing overrides active. See /interspect-summary for details."
- `/interspect-summary` shows modification count, last change date, risk distribution, links to full report
- `/interspect-reset [--dry-run]` command to revert all modifications and archive evidence
- README section explaining "Interspect: What it is, how to monitor it, how to control it"

---

### 5. Evidence Collection is Passive and Incomplete (DATA QUALITY RISK)

**Problem:** The design assumes evidence will accumulate naturally, but several critical signals require active instrumentation that may not exist.

**Evidence gaps:**

**Human corrections:**
> "User edits agent output — Diff between agent output and final committed version"

- This only works if agent output was committed in an intermediate state
- If user edits in the same session before committing, there's no diff to capture
- If user rejects agent output entirely and writes from scratch, signal is lost
- Requires git-level tracking that may be noisy (user reformats code, changes unrelated to agent quality)

**False positives:**
> "Dismissed findings in `/resolve`"

- Assumes `/resolve` exists and is used
- Assumes users will actually mark findings as dismissed vs just ignoring them
- No signal if user closes a review comment without actioning it (common in GitHub PR reviews)

**Token usage:**
> "Wrap subagent calls with cost tracking"

- Requires instrumentation in Task tool dispatch, which is Claude Code core, not plugin-controlled
- If unavailable, this entire signal is lost
- No mention of fallback if cost tracking isn't feasible

**Timing:**
> "Timestamps in signal engine"

- Same issue — Task tool dispatch is out of plugin control
- Latency measurement requires start/end timestamps, need a hook on subagent return (may not exist)

**User experience impact:**
- If evidence collection is incomplete, confidence scores are wrong
- Interspect makes modifications based on partial signals
- User sees changes that don't match their experience (e.g., agent is flagged as "low signal" but user found it helpful in cases that weren't measured)

**Recommendation:**
- Audit which signals are actually collectable with current Claude Code hook API
- For missing signals, document the gap and degrade gracefully (e.g., confidence thresholds stay higher, require more cross-session evidence)
- Consider adding explicit feedback commands: `/interspect-good <agent>`, `/interspect-bad <agent> <reason>` for direct user input
- Make evidence completeness visible: `/interspect-health` shows which signal types are working, which are degraded

---

## Secondary UX Issues

### 6. Canary Monitoring Opacity

**Issue:** Canary metadata lives in JSON files (`.clavain/interspect/canaries.json` implied). User has no visibility into canary state during the monitoring window.

**User needs:**
- "Is fd-safety currently in a canary period?" (yes/no in statusline or session-start summary)
- "How is the canary performing vs baseline?" (dashboard view)
- "Can I manually end the canary early if I'm confident?" (approval command)

**Recommendation:** Surface canary state in existing UX touchpoints — statusline (via interline), session-start hook, `/interspect-status` command.

---

### 7. Cross-Project Evidence Leakage Risk

**Issue:** Evidence store is project-scoped (implied by `"project": "intermute"` in schema) but modification target is global Clavain installation.

**Scenario:**
- User works on project A (security-critical, strict fd-safety useful)
- Interspect learns "fd-safety produces too many false positives" and tunes it down
- User switches to project B (different risk profile)
- fd-safety is now under-sensitive for project B's needs

**Design doesn't address:**
- Are routing overrides project-specific or global?
- Are prompt modifications applied globally or per-project?
- Can user see "fd-safety was tuned based on evidence from project X, may not apply to project Y"?

**Recommendation:** Make project-scoping explicit:
- Routing overrides should be per-project (stored in `.clavain/interspect/routing-overrides.json` in project root)
- Prompt modifications are global but carry project-evidence tags
- If evidence is primarily from one project, warn when applying modification globally
- User can override with `/interspect-isolate <project>` to prevent cross-project learning

---

### 8. Meta-Learning Loop is Underspecified

**Issue:** "Interspect's own modification failures become evidence" is mentioned but not designed.

**Questions:**
- What's the schema for failure evidence?
- How does interspect distinguish "modification was wrong" from "modification was right but canary window was too short"?
- Can interspect get stuck in a loop (modification → revert → re-apply → revert)?
- Is there a "learning rate" or backoff mechanism?

**User-facing impact:**
- If interspect keeps trying and failing the same modification, user sees thrash
- No UX for "interspect has given up on improving X after 3 failed attempts"

**Recommendation:** Design the meta-learning feedback loop with same rigor as primary loop. Include dampening, attempt limits, and user visibility into retry state.

---

## Product Validation Issues

### 9. Problem Definition is Assumption-Heavy

**Claimed problem:** "Developers manually tune their rigs over time, this should be automatic."

**Evidence provided:** None. No user research cited. No examples of actual tuning workflows that exist today.

**Questions:**
- How many Clavain users actually tune prompts/routing today?
- What percentage of users are power-users who want this vs casual users who would be confused by autonomous changes?
- Are there examples of users saying "I wish my agents adapted automatically"?
- Or is this a solution looking for a problem?

**Risk:** Building a complex autonomy system that most users don't want and power-users don't trust.

**Recommendation:** Before implementing full autonomy, build the evidence collection and reporting layer first. Ship `/interspect-report` that shows "here are patterns in your usage, here are suggested tunings." Let users manually apply suggestions for 3 months. Collect feedback on which suggestions were useful, which were noise. Use that to validate whether autonomy is valuable.

---

### 10. Autonomy Default is Misaligned with User Control Expectations

**Design decision:** "Default: Full autonomy."

**User expectation:** When a tool modifies itself, users expect to be warned and given control.

**Analogies:**
- iOS doesn't auto-update apps by default (user opts in)
- Package managers prompt before major upgrades
- Linters suggest fixes, don't auto-apply by default (except in well-scoped scenarios like `eslint --fix` where user explicitly invoked)

**Interspect's scope is MUCH broader** — it rewrites prompts, changes workflows, excludes agents. The blast radius of a bad change is high (user's entire rig becomes less effective).

**Why "review commits after the fact" is insufficient:**
- Commits are atomic diffs, not behavioral summaries
- Most users don't review every commit in detail
- By the time user notices a problem, they've lost context on what was working before
- Reverting a commit doesn't explain what to do instead

**User segments:**
- **Casual users:** Won't understand what interspect is doing, will be confused by behavior changes, won't review commits
- **Power users:** Want control, will be frustrated by autonomous changes they didn't approve, may reject the feature entirely if defaults are too aggressive

**Recommendation:** Reverse the default. Ship with propose mode as default, make autonomous mode opt-in. After 6 months of real-world usage, re-evaluate based on actual user behavior (how many switch to autonomous? how many disable interspect entirely?).

---

### 11. Success Metrics are Absent

**Problem:** No definition of success. How will you know if interspect is working?

**Possible metrics:**
- Reduction in override rate for agents after tuning (but this could mean the agent stopped catching real issues)
- Increase in user satisfaction with review quality (requires user survey)
- Reduction in false positive rate without missing true positives (requires labeled dataset)
- Time saved by not manually tuning (requires baseline measurement of manual tuning effort)
- Adoption rate of autonomous mode vs propose mode (proxy for trust)

**Without metrics:**
- Can't validate whether interspect is net-positive
- Can't iterate on confidence thresholds, canary windows, or risk classifications
- Can't justify the complexity cost

**Recommendation:** Define 2-3 measurable success criteria before implementation. Instrument to collect those metrics. Plan a 90-day review milestone to evaluate.

---

## Flow Analysis

### Missing Flows

**Flow 1: User discovers unexpected behavior**
- User notices fd-safety is behaving differently
- ??? (no breadcrumb trail back to interspect)
- User doesn't know if this is a bug, an upstream change, or interspect tuning

**Flow 2: User wants to pause interspect**
- User is doing time-sensitive work, doesn't want autonomous changes mid-session
- ??? (no `/interspect-pause` command specified)
- User either disables the entire plugin or accepts the risk

**Flow 3: User wants to compare stock vs adapted behavior**
- User suspects interspect made things worse
- ??? (no way to run "upstream Clavain" and "adapted Clavain" side-by-side)
- User can't A/B test to validate suspicion

**Flow 4: User wants to teach interspect**
- User knows fd-safety should ignore a specific pattern in this project
- ??? (no explicit teaching command, must wait for evidence to accumulate)
- User is stuck with noise until interspect learns organically (may take many sessions)

**Flow 5: Canary fails, interspect reverts**
- Revert happens automatically
- User wasn't watching the canary
- User is confused why behavior reverted to old state
- ??? (no notification that revert happened)

**Flow 6: Shadow test blocks a high-risk change**
- Interspect generates a skill rewrite
- Shadow test fails
- Change is blocked
- ??? (user never knows this happened? Or gets a report?)

**Recommendation:** Map all user-facing flows explicitly. For each, define:
- Entry point (how does user enter this flow?)
- Steps (what does user do? what does system do?)
- Exit states (success, failure, partial completion)
- Error recovery (what if step N fails?)

---

## Terminal/CLI Specific Issues

### 12. No Statusline Integration

**Issue:** interspect state (canary active, modifications pending, evidence accumulating) is invisible unless user runs commands.

**Missed opportunity:** interline (statusline renderer) is a companion plugin. interspect should feed state to interline.

**Recommendation:** Add statusline segments:
- `[inspect:canary]` when canary monitoring is active
- `[inspect:pending(3)]` when modifications are queued in propose mode
- `[inspect:adapted]` when current project has active routing overrides

---

### 13. Evidence Store is Grep-Hostile

**Issue:** JSONL is machine-readable but human-hostile for ad-hoc investigation.

**User workflow:**
- User wants to know "what evidence led to this change?"
- Must `cat events/*.jsonl | jq 'select(.source == "fd-safety")'`
- Gets raw event stream, must manually correlate timestamps and sessions

**Recommendation:** Provide human-friendly query commands:
- `/interspect-evidence <agent|skill>` → summarized evidence for a component
- `/interspect-evidence --session <id>` → evidence from a specific session
- `/interspect-evidence --pattern <term>` → search evidence descriptions

---

## Proposed Minimum Viable Product (MVP) Scope

**The current design is too broad for a first release.** Ship value faster by reducing scope to the highest-confidence, lowest-risk capabilities.

**Phase 1: Evidence + Reporting (No Autonomy)**
- Evidence collection hooks (overrides, corrections, timing)
- `/interspect-report` command showing patterns and suggested tunings
- User manually applies suggestions
- **Value:** Users get insights without risk. Validates which signals are useful.
- **Timeline:** 4 weeks

**Phase 2: Low-Risk Autonomy (Sidecar Context Only)**
- Interspect auto-appends to sidecar files based on evidence
- No prompt modifications, no routing changes
- `/interspect-summary` and `/interspect-revert` commands
- **Value:** Users see adaptive behavior in safe scope. Tests autonomy acceptance.
- **Timeline:** 4 weeks

**Phase 3: Medium-Risk Autonomy (Routing + Prompts)**
- Add routing overrides and prompt tuning
- Shadow testing for prompts
- Canary monitoring with auto-revert
- **Value:** Full adaptive capability for most common modifications.
- **Timeline:** 6 weeks

**Phase 4: High-Risk Autonomy (Structural Changes)**
- Skill rewrites, companion extraction, workflow optimization
- Always in propose mode, even if autonomy flag is set
- **Value:** Completes vision for full self-improvement.
- **Timeline:** 8 weeks

**Cut from MVP:**
- Within-session cadence (too complex, low ROI)
- Meta-learning loop (defer until Phase 3 data exists)
- Companion extraction (too speculative, no evidence this is needed)

---

## Biggest Risks

### Risk 1: User Trust Collapse
If interspect makes agents worse and user can't easily diagnose/revert, trust in entire Clavain rig is damaged. Users may uninstall rather than debug.

**Mitigation:** Ship debugging tools (status, revert, blame) BEFORE shipping autonomous modifications.

### Risk 2: Evidence Sparsity
If signals are rare (e.g., user rarely overrides agents), interspect will have insufficient data to make good decisions. Modifications will be based on 1-2 events, leading to overfitting.

**Mitigation:** Set high confidence thresholds. Require cross-session AND cross-project evidence for any persistent change. Make evidence sparsity visible in reports.

### Risk 3: Modification Thrash
Interspect tunes based on project A evidence, user switches to project B, behavior is wrong, interspect tunes again, user switches back to A, cycle repeats.

**Mitigation:** Project-scoped routing overrides. Global modifications require evidence from multiple projects or explicit user approval.

### Risk 4: Complexity Outweighs Value
Four cadences, six modification types, shadow testing, canary monitoring, meta-learning — this is a huge surface area. If user-facing value is "agents produce 10% fewer false positives," the ROI is poor.

**Mitigation:** Ship MVP (Phase 1-2) and measure impact before building Phase 3-4. Kill the feature if adoption is low or satisfaction is neutral.

---

## Summary of Recommendations

### Blocking (must fix before shipping):
1. **Design commit message format and audit UX** — make "review commits after the fact" actually feasible
2. **Replace batch approve with risk-based routing** — don't make users approve low-risk changes, always prompt for high-risk
3. **Build debugging commands first** — status, revert, blame, evidence query
4. **Reverse autonomy default** — ship propose-mode as default, autonomous as opt-in

### High priority (needed for MVP):
5. **Add onboarding/discovery UX** — session-start summary, /interspect-summary command, README explanation
6. **Audit evidence collection feasibility** — confirm which signals are actually collectable, degrade gracefully for missing ones
7. **Make project scoping explicit** — routing overrides per-project, prompt modifications carry evidence tags
8. **Define success metrics** — pick 2-3 measurable outcomes, instrument collection

### Medium priority (can defer to phase 2):
9. **Add canary visibility** — statusline integration, dashboard view
10. **Design meta-learning loop** — failure evidence schema, retry limits, dampening
11. **Build teaching commands** — let users explicitly guide interspect instead of waiting for organic evidence

### Low priority (validate need first):
12. **Simplify cadence model** — four cadences may be over-engineered, consider consolidating
13. **Build comparison mode** — let users A/B test stock vs adapted behavior

---

## Final Product Verdict

**Should this be built?** Maybe, but not as designed.

**Core value hypothesis:** "An engineering rig that adapts to its user's patterns is more effective than a static rig."

**Evidence for hypothesis:** None provided. This is a speculative bet.

**Path forward:**

**Option A (Conservative):** Build evidence layer + reporting only (Phase 1 above). Ship to 10 power users. Collect feedback for 3 months. If users say "I want these suggestions auto-applied," build Phase 2. If they say "This is interesting but I prefer manual control," stop here.

**Option B (Aggressive):** Build full autonomy but with propose mode as default. Instrument adoption metrics. If 80% of users stay in propose mode after 6 months, recognize that autonomy isn't wanted. If 80% switch to autonomous mode, validate the vision.

**Option C (Pivot):** Abandon autonomous modifications. Keep evidence collection. Use evidence to improve upstream Clavain prompts/routing for all users via traditional development (PRs reviewed by humans). Everyone benefits, no per-user autonomy complexity.

**My recommendation:** Option A. Validate the problem before building the solution. Evidence collection is cheap and useful regardless of whether autonomy is valuable. Autonomy is expensive and risky — only build it if users demonstrate need.
