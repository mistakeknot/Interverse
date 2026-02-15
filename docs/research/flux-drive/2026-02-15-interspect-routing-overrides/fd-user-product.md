# Flux-Drive User & Product Review: Interspect Routing Overrides

**Primary User:** Plugin developers and power users of Clavain/interflux who run flux-drive reviews regularly and notice certain agents consistently produce no useful output for their specific project type.

**Job to be Done:** Reduce token waste and review noise by excluding domain-irrelevant agents from flux-drive triage without manually editing flux-drive's scoring logic.

---

### Findings Index

| Severity | ID | Section | Title |
|----------|-----|---------|-------|
| P0 | UX-1 | F2 Propose Flow | AskUserQuestion options missing from PRD spec |
| P0 | UX-2 | F2 Propose Flow | No user path to "Show evidence details" promised in brainstorm |
| P0 | UX-3 | F4 Status | Status display lacks actionable context for users |
| P1 | PROD-1 | Problem Definition | Evidence quality missing from problem statement |
| P1 | UX-4 | F2 Propose Flow | Proposal timing undefined — when does interspect ask? |
| P1 | UX-5 | F3 Apply Flow | Failure recovery path unspecified |
| P2 | PROD-2 | Success Metrics | No measurable success criteria defined |
| P2 | UX-6 | F5 Manual Overrides | Discovery gap: users won't know they can hand-edit |
| P2 | UX-7 | Cross-Cutting Warning | Warning message appears too late to prevent damage |
| P3 | FLOW-1 | F2 Propose Flow | Cancellation path unspecified |
| P3 | UX-8 | F4 Status | Revert by commit SHA requires git familiarity |

**Verdict:** needs-changes

---

### Summary

This PRD addresses a real pain point — token waste from irrelevant agents — but the user interaction design is underspecified. The brainstorm shows a three-option AskUserQuestion UI ("Yes / No / Show evidence details") that doesn't appear in the PRD, and the PRD provides no guidance on when the question is asked, what happens on failure, or how users discover the manual override capability. The status display (F4) is specified as a data dump without considering what actions users want to take from it. Success measurement is absent — the PRD can't validate whether overrides actually reduce noise or accidentally hide valuable findings.

The technical design is sound: JSON file format is git-friendly, per-project scoping works, canary monitoring provides safety. But the user-facing flows need completion before implementation.

---

### Issues Found

#### P0: UX-1 — AskUserQuestion options missing from PRD spec

**Location:** F2 acceptance criteria

**Evidence:** Brainstorm line 88 shows three-button proposal:
```
Accept this routing override?
[Yes] [No] [Show evidence details]
```

But PRD F2 acceptance criteria only say "Proposal presented via AskUserQuestion" without specifying the options structure. The brainstorm implies a progressive disclosure pattern (third option shows detailed evidence before committing), but the PRD omits this entirely.

**User Impact:** Without the "Show evidence details" path, users must decide blind — they see aggregate counts (5 events, 4 sessions) but can't inspect what those override events actually were. This breaks confidence: users won't approve exclusions without seeing representative examples of why the agent was wrong.

**Fix:** Add acceptance criterion to F2:
- AskUserQuestion presents three options: "Accept", "Decline", "Show details"
- "Show details" expands evidence summary inline (timestamps, override reasons, context excerpts) and re-presents the decision
- Specify the exact format of the evidence summary

---

#### P0: UX-2 — No user path to "Show evidence details" implementation

**Location:** F2 Propose Flow

**Evidence:** PRD says "present via AskUserQuestion" but doesn't specify how to implement progressive disclosure. AskUserQuestion tool typically returns a single choice — there's no documented pattern for "Show details → re-ask" flows in Claude Code's tool APIs.

**User Impact:** If implemented naively, "Show evidence details" might just dump evidence to console and proceed to decision, losing the ability to review before choosing. Or it might require a second `/interspect` invocation, breaking flow continuity.

**Questions:**
1. Does AskUserQuestion support multi-stage flows or should this be two sequential questions?
2. Should details be shown as additional context before the question, not as a choice option?
3. Is there a Clavain pattern for progressive disclosure that this should follow?

**Fix:** Specify the implementation approach in F2:
- Either: "Details" option triggers a second AskUserQuestion with full evidence + Accept/Decline
- Or: Always show evidence summary above the question (no "Details" option needed)
- Document the chosen pattern as a reference for future interactive proposals

---

#### P0: UX-3 — Status display lacks actionable context

**Location:** F4 acceptance criteria

**Evidence:** F4 says status shows "agent, reason, created date, canary state" but doesn't specify how users understand:
- Why this override exists (link to evidence)
- Whether it's still valid (has the project changed since creation?)
- What to do next (accept canary result, revert, keep monitoring)

**User Impact:** Users see a list of overrides but can't act on it without running separate commands. Example scenario: canary shows "quality degraded" but status doesn't surface that — user has to mentally cross-reference two outputs.

**Fix:** Expand F4 status format to include:
- Evidence count and latest evidence date (shows if pattern is still active)
- Canary verdict if monitoring has completed ("PASSED", "ALERT: quality degraded", "monitoring: 8/20 uses")
- Next action hint ("Run `/interspect:revert fd-game-design` to undo" vs "Canary monitoring active, 12 uses remaining")
- Total token savings estimate (if flux-drive logs agent invocation costs)

---

#### P1: PROD-1 — Evidence quality missing from problem statement

**Location:** Problem section

**Evidence:** PRD says "fd-game-design never produces useful findings for a Go backend project" but doesn't define "useful" or how interspect distinguishes signal from noise. Line 33 in PRD says pattern detection requires "≥80% of events have override_reason: agent_wrong" — but what if users never run `/interspect:correction`? What if evidence is all passive dispatch tracking?

**User Impact:** If users don't manually record corrections, interspect collects no override signals, pattern detection never fires, and the whole feature is inert. This is a critical adoption dependency not surfaced in the problem statement.

**Questions:**
1. What's the minimum evidence threshold before proposals can happen? (PRD says counting rules must be met but doesn't link to their values)
2. How do users know to run `/interspect:correction` after dismissing irrelevant findings?
3. Is there an onboarding flow that teaches evidence collection?

**Fix:** Add to problem statement:
- "Requires active evidence collection via `/interspect:correction` — users must manually override irrelevant findings for patterns to emerge."
- Link to interspect Phase 1 evidence collection requirements
- Consider adding a "getting started" criterion to F2: if no override events exist for any agent, show educational message instead of proposals

---

#### P1: UX-4 — Proposal timing undefined

**Location:** F2 acceptance criteria

**Evidence:** Line 37 says "Proposal runs when `/interspect` command triggers Tier 2 analysis" but doesn't specify whether the user expects this. Is the proposal inline during the analysis report? A separate prompt after? Does it interrupt other proposals?

**User Impact:** Timing matters for decision quality. If proposals appear mid-session while the user is focused on other work, they'll approve blindly just to clear the prompt. If proposals appear at the end of `/interspect` output, users can review analysis first and make informed decisions.

**Flow gap:** If interspect detects 3 routing-eligible patterns, does it ask 3 sequential questions? Show all 3 in one question? Batch them for a separate approval step?

**Fix:** Specify in F2:
- Proposals appear after pattern analysis table is shown (user sees classification first)
- Multiple proposals are batched: one AskUserQuestion with checkboxes per override, or sequential questions with a "Review all proposals" preamble
- User can defer decisions: "Skip all for now" option that doesn't blacklist patterns

---

#### P1: UX-5 — Failure recovery path unspecified

**Location:** F3 Apply + Commit

**Evidence:** F3 says "Atomic: if commit fails, the override is not left in a partial state" but doesn't specify what "not partial" means or what the user sees on failure.

**Failure modes:**
- Git lock held by another process
- Merge conflict in routing-overrides.json (concurrent session added override)
- Pre-commit hook failure
- Disk full

**User Impact:** If commit fails, does the JSON file get written (orphaned uncommitted override) or rolled back? Does interspect retry? Does the user get instructions for manual recovery?

**Fix:** Add to F3:
- Rollback strategy: JSON write happens in temp file, only renamed after git commit succeeds
- On failure, show error message with recovery steps: "Could not commit routing override. Run `git status` to check lock, then retry `/interspect`."
- Failed proposals are not re-offered in the same session (avoid repeat prompts)

---

#### P2: PROD-2 — No measurable success criteria

**Location:** Open Questions, Solution section

**Evidence:** PRD positions this as solving token waste and noise, but provides no way to measure whether it works. Line 87 mentions "Canary metrics for routing exclusions" as an open question but doesn't commit to how success will be validated post-release.

**User Impact:** Without success metrics, users and maintainers can't tell if routing overrides are helping or hiding valuable findings. Example invisible failure: user excludes fd-safety from a game project, later ships a memory corruption bug that fd-safety would have caught.

**Deferred dependencies:** Open Question 1 mentions Galiana's `defect_escape_rate` as the right metric but says it requires Galiana integration (separate bead). This means v1 ships without the ability to prove it works.

**Fix:** Add explicit v1 success criteria that don't require Galiana:
- Measure: total agent invocations before/after overrides (should decrease)
- Measure: user-reported override rate for excluded agents in weeks before exclusion vs weeks after (pattern should disappear if exclusion was correct)
- Measure: revert rate (if >20% of overrides get reverted, triage logic is broken)
- Document that defect escape rate is deferred to v2 (when Galiana integration lands)

---

#### P2: UX-6 — Manual override discovery gap

**Location:** F5 Manual Override Support

**Evidence:** F5 says "Users can create routing overrides by hand" and human-created overrides are respected, but there's no documentation, help text, or discovery path. Users have to know the file exists, know the schema, and know to set `created_by: "human"`.

**User Impact:** This is a power-user escape hatch that will stay invisible to 95% of users. The ones who need it most (users with project-specific constraints interspect can't detect) won't find it.

**Discovery paths that don't exist:**
- `/interspect:help` or `/help interspect` doesn't mention manual overrides
- No example file or template in Clavain docs
- Git commit message from interspect doesn't say "you can also edit this file manually"

**Fix:** Add to F5:
- Document manual override workflow in Clavain AGENTS.md with example JSON
- Add comment header to generated `routing-overrides.json`: `// Generated by interspect. Safe to edit manually — set "created_by": "human" for custom overrides.`
- `/interspect:status` footer mentions manual overrides: "You can also hand-edit `.claude/routing-overrides.json` — see docs/manual-overrides.md"

---

#### P2: UX-7 — Cross-cutting agent warning appears too late

**Location:** F1 Consumer (flux-drive reader)

**Evidence:** PRD line 74 says flux-drive consumer should warn "Warning: routing override excludes cross-cutting agent fd-architecture. This removes structural coverage." But this warning appears during flux-drive triage, *after* the override was already committed. The user approved it sessions ago and forgot about it.

**User Impact:** Users see the warning when it's too late to prevent the mistake — they already excluded fd-architecture and the warning is noise unless they immediately revert. Better to prevent the mistake during proposal (F2).

**Fix:** Move cross-cutting check to F2 proposal flow:
- Detection: F2 checks if proposed agent is in cross-cutting list (fd-architecture, fd-quality)
- Warning: proposal includes alert: "⚠️ fd-architecture provides structural coverage across all projects. Excluding it may hide systemic issues. Are you sure?"
- Still show warning in flux-drive consumer (defense in depth) but primary prevention is at approval time

---

#### P3: FLOW-1 — Cancellation path unspecified

**Location:** F2 Propose Flow

**Evidence:** Proposal shows "Accept / Decline / Show details" but doesn't say what "Decline" means. Does it blacklist the pattern (never propose again)? Defer (ask again next session)? Just skip?

**User Impact:** If "Decline" = blacklist, users lose the ability to reconsider as evidence grows. If "Decline" = defer, users get repeat prompts every session until they approve.

**Fix:** Add to F2:
- "Decline" action is a one-session skip — pattern will re-propose next session if still eligible
- Add third option: "Never propose this exclusion" → blacklists the pattern permanently
- Blacklist is reversible via `/interspect:unblock <agent>`

---

#### P3: UX-8 — Revert by commit SHA requires git literacy

**Location:** F4 Status + Revert

**Evidence:** F4 says `/interspect:revert` supports "agent name or commit SHA" but doesn't explain when SHA is needed. If a user has multiple overrides for the same agent (unlikely but possible if they revert and re-apply), SHA-based targeting is necessary but not discoverable.

**User Impact:** Most users will use agent name only. SHA option is invisible until they hit the edge case.

**Fix:** Add to F4:
- Status output includes revert command hint: "To revert: `/interspect:revert fd-game-design` or `/interspect:revert a1b2c3d` (if multiple)"
- If agent name matches multiple overrides, revert command shows options: "Multiple overrides found for fd-game-design. Use `/interspect:revert <commit-sha>` to target specific one, or `/interspect:revert fd-game-design --all`"

---

### Improvements

#### IMP-1: Add onboarding moment for new users

**Rationale:** This feature depends on evidence collection habits. If users don't know to run `/interspect:correction` when dismissing irrelevant findings, pattern detection never fires.

**Proposal:** First-run experience in F2:
- If `/interspect` runs and finds 0 override events across all agents, show educational message:
  ```
  Interspect can propose routing overrides, but needs evidence first.
  When you dismiss an irrelevant finding, run:
  `/interspect:correction <agent> <reason>`

  This teaches interspect which agents don't fit your project.
  ```
- Track shown-once per project (`.claude/interspect-onboarding-shown` sentinel)

---

#### IMP-2: Preview mode for proposals

**Rationale:** Approving an override is a semi-permanent decision (reverting requires a second command). Users might want to see what flux-drive triage would look like without the agent before committing.

**Proposal:** Add to F2:
- Fourth option in proposal: "Preview triage without this agent"
- Runs a mock flux-drive triage with the agent excluded, shows scoring table
- Re-presents the approval question with preview context

**Cost:** Requires tight coupling between interspect and flux-drive triage logic (might be invasive). Could defer to v2.

---

#### IMP-3: Bulk operations in status view

**Rationale:** If a user has 5 overrides and wants to clean up after a project pivot, reverting one-by-one is tedious.

**Proposal:** Extend F4 status command:
- `/interspect:status --interactive` presents checklist of all overrides with bulk actions: "Revert selected", "Keep all", "Review individually"
- Uses AskUserQuestion with multi-select if supported, otherwise sequential questions

---

#### IMP-4: Token savings report

**Rationale:** The value proposition is "reduce token waste" but users have no visibility into whether it's working. Showing estimated savings makes the feature's value tangible.

**Proposal:** Add to F4 status display:
- Query flux-drive dispatch logs (if they exist) to count how many times each excluded agent *would have been invoked* based on triage scoring
- Estimate tokens saved: `invocations_prevented * avg_agent_tokens`
- Show in status: "Estimated token savings: ~45K tokens across 12 reviews (fd-game-design: 30K, fd-performance: 15K)"

**Dependency:** Requires flux-drive to log hypothetical agent selections, not just actual dispatches. Might be a larger change.

---

#### IMP-5: Explain why cross-cutting agents can't be excluded by default

**Rationale:** PRD says cross-cutting exclusions are allowed but warned against (line 74). Users might not understand why fd-architecture and fd-quality are special.

**Proposal:** When user tries to exclude a cross-cutting agent:
- Proposal includes explanation: "fd-architecture checks structural issues that affect all code regardless of domain (coupling, complexity, testability). Excluding it means these issues won't be caught."
- Offer alternative: "Consider `/interspect:correction fd-architecture <specifics>` for targeted improvements instead of full exclusion."

---

### Flow Analysis

#### Happy Path: First Override Proposal

**Entry:** User runs `/interspect` after recording 5+ corrections for fd-game-design across 3+ sessions.

1. `/interspect` runs pattern analysis, classifies fd-game-design pattern as "ready"
2. Shows classification table (Ready / Growing / Emerging patterns)
3. Presents AskUserQuestion: "Interspect suggests excluding fd-game-design... Accept / Decline / Show details"
4. User selects "Show details"
5. Expanded evidence shown inline (5 events with timestamps, reasons, context excerpts)
6. Re-presents question: "Accept / Decline"
7. User selects "Accept"
8. Interspect writes routing-overrides.json, records modification, creates canary, commits to git
9. Confirmation: "Excluded fd-game-design. Canary monitoring: 20 uses. Run `/interspect:status` to review."
10. Next flux-drive run skips fd-game-design in triage, logs "Routing overrides: excluded [fd-game-design]"

**Missing states:**
- What if routing-overrides.json already exists but is malformed? (F1 says graceful degradation but doesn't specify user notification)
- What if git lock is held during commit? (F3 says atomic but doesn't specify retry or user action)

---

#### Error Path: Commit Failure During Apply

**Entry:** User approves override, but git commit fails (lock held by another process).

1. Interspect writes temp JSON file
2. Attempts git commit, fails with lock error
3. **Undefined:** Does interspect show error immediately or retry silently?
4. **Undefined:** Does temp file get cleaned up or left orphaned?
5. **Undefined:** Does user get actionable error message?

**Fix needed:** F3 must specify rollback (delete temp file), error message ("Git lock held. Retry after other process completes."), and no retry (user re-runs `/interspect` manually).

---

#### Revert Flow: User Wants to Undo Override

**Entry:** User notices fd-game-design exclusion was wrong (agent would have caught a real issue).

1. User runs `/interspect:status` to see active overrides
2. Status shows: "fd-game-design | excluded | 2026-02-10 | canary: monitoring (8/20 uses)"
3. User runs `/interspect:revert fd-game-design`
4. Interspect removes override from JSON, blacklists pattern, commits
5. Confirmation: "Reverted fd-game-design exclusion. Pattern blacklisted (won't re-propose). Run `/interspect:unblock fd-game-design` to allow future proposals."
6. Next flux-drive run includes fd-game-design in triage

**Missing transition:** What if user reverts while canary is still monitoring? Does revert close the canary or mark it invalid?

**Fix needed:** F4 revert acceptance criteria should specify canary state update.

---

#### Manual Override Flow: Power User Hand-Edits

**Entry:** User knows they want to exclude fd-performance from a latency-insensitive project, doesn't want to wait for evidence accumulation.

1. User creates `.claude/routing-overrides.json` manually (no template or docs to guide them — **UX-6 gap**)
2. Adds override with `created_by: "human"`
3. **Undefined:** Does interspect validate the file on next session start? Show confirmation?
4. Next flux-drive run reads file, excludes fd-performance
5. `/interspect:status` shows "fd-performance | manual override | ..."

**Missing states:**
- What if user sets `created_by: "interspect"` for a manual override? (F5 says defaults to "human" if missing but doesn't prevent lies)
- What if user's manual JSON is malformed? (F1 says graceful degradation but doesn't specify notification path)

---

### Domain-Specific Checks (Claude Code Plugin)

#### Discovery: How do users find this feature?

**Current paths:**
- Users who read AGENTS.md or CLAUDE.md (low reach)
- Users who run `/interspect` after collecting evidence (requires prior knowledge of `/interspect:correction`)

**Missing paths:**
- No `/help interspect` text mentions routing overrides
- No in-session hint when user dismisses a flux-drive finding (ideal teachable moment)
- No onboarding flow that explains evidence → pattern → override pipeline

**Recommendation:** Add teachable moment in flux-drive synthesis phase:
- When user reviews findings and implicitly ignores an agent's output (doesn't act on it), flux-drive could prompt: "fd-game-design had no relevant findings. Run `/interspect:correction fd-game-design "not applicable to this project"` to teach interspect."
- This requires flux-drive to detect when findings are unused (hard to measure) — might be too invasive for v1

---

#### Help System: Does this integrate with existing help?

**Current state:**
- `/interspect` command exists but doesn't mention routing overrides in its output (because Phase 1 is evidence-only)
- `/interspect:status` will show overrides (F4) but no help text explains what they are

**Gap:** Users who discover `/interspect:status` see override data but don't understand:
- Why overrides exist (what problem do they solve?)
- How to create one (proposals vs manual)
- When to revert

**Fix:** Add help integration:
- `/interspect:status` footer includes: "Routing overrides exclude agents from flux-drive triage. Created automatically (via proposals) or manually (edit routing-overrides.json). See `/clavain:using-clavain` → Interspect section."
- Update using-clavain skill with routing override lifecycle explanation

---

#### Error Messages: Are they actionable?

**F1 Consumer errors:**
- "Malformed/missing file does not break triage" — what does user see? Nothing? Silent fallback is good for flux-drive but bad for debugging. User might wonder why their manual override isn't working.

**F3 Apply errors:**
- Commit failure: no error message specified
- Merge conflict in routing-overrides.json: no resolution path
- Pre-commit hook rejection: user sees generic git error, doesn't understand context

**Fix:** Add error message acceptance criteria:
- F1: If routing-overrides.json is malformed, log warning in flux-drive output: "Warning: .claude/routing-overrides.json is malformed (invalid JSON). Ignoring overrides. Run `/interspect:validate` to check syntax."
- F3: On commit failure, show: "Could not commit routing override: [git error]. Override not applied. Check git status and retry."
- F3: On merge conflict, show: "Another session modified routing-overrides.json. Resolve conflict manually or re-run `/interspect` after conflict resolution."

---

#### Fresh Install: Does this work out of the box?

**Dependency chain:**
1. Interspect Phase 1 (evidence collection) must be active
2. User must run `/interspect:correction` to create override signals
3. Evidence must meet counting-rule thresholds (3 sessions, 2 projects, 5 events per PRD dependencies)
4. `/interspect` command must trigger Tier 2 analysis
5. User must approve proposal
6. Flux-drive must be invoked to consume the override

**Friction points:**
- Step 2 requires manual evidence creation — nothing prompts users to do this
- Step 3 means users need corrections across multiple sessions and projects before proposals appear (long time-to-value)
- No guidance on what counts as enough evidence

**Recommendation:** Add to F2:
- Show evidence progress in `/interspect` output even for non-ready patterns: "fd-game-design: 3/5 events, 2/3 sessions, 1/2 projects (needs 1 more project)"
- This teaches users how close they are to unlocking proposals

---

### Questions for User Research

If user interviews were available, these questions would validate/invalidate assumptions:

1. **Frequency:** How often do users encounter fully-irrelevant agents (never useful) vs occasionally-wrong agents (useful sometimes)? If occasional-wrong dominates, routing exclusions are the wrong solution (context overlays fit better).

2. **Evidence habits:** Do users currently track which agents are wrong? How? (Mental notes, comments in code, external docs?) This reveals whether `/interspect:correction` fits existing workflows or requires behavior change.

3. **Confidence threshold:** Would users approve an exclusion based on 5 events across 3 sessions, or do they need more evidence? (Counting rule thresholds are arbitrary without user validation.)

4. **Recovery anxiety:** How worried are users about accidentally excluding a useful agent? Does canary monitoring provide enough safety, or do they want a trial mode (exclude for 1 week, auto-revert if no improvement)?

5. **Token visibility:** Do users currently track token usage per agent? Do they care about cost savings or just noise reduction? (Determines whether IMP-4 token savings report is valuable.)

---

<!-- flux-drive:complete -->
