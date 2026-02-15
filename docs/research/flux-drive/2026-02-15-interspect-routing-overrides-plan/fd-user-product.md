# Flux-drive User & Product Review: Interspect Routing Overrides Plan

**Primary user:** Claude Code power user working on a project where one or more flux-drive agents consistently produce irrelevant findings. They've been manually overriding findings using `/interspect:correction`, building up evidence over multiple sessions. They want to stop wasting tokens and reduce noise.

**Job to be done:** Permanently exclude agents that never produce relevant findings for this project, without editing plugin code or breaking other projects.

---

### Findings Index
- P1 | UX1 | Task 3, F2 | No path from user intent to discovery — users don't know `/interspect:propose` exists
- P1 | UX2 | Task 3, F2 | Sequential proposal flow blocks users who want to batch-decide
- P2 | UX3 | Task 3, F2 | "Show evidence details" offers raw SQL output instead of human-readable summary
- P1 | UX4 | Task 2, F1 | Error messages assume user knows what routing-overrides.json is
- P2 | UX5 | Task 5, F4 | Status command buried, no reminder to check after applying overrides
- P2 | PROD1 | F2, F4 | Success signal requires 20 sessions — too slow to validate decisions
- P1 | PROD2 | F2 | Evidence dependency not surfaced until user tries to use feature
- P2 | PROD3 | F5 | Manual override workflow requires JSON editing with no validation
- P1 | UX6 | Task 3, F2 | Progress display shows arbitrary numbers without context for decision-making
- P2 | UX7 | Task 5, F4 | Revert creates permanent blacklist with no warning about future proposals

**Verdict:** needs-changes

---

### Summary

This plan implements a sophisticated evidence-driven agent exclusion system, but the user experience has critical discovery and feedback gaps that will prevent adoption. The biggest issue is **no clear path from problem to solution** — users who encounter noisy agents won't discover `/interspect:correction` (prerequisite) or `/interspect:propose` (main feature) without reading documentation. The implementation assumes users have already collected evidence and understand the interspect mental model.

The **proposal flow forces sequential decisions** when users often want to review all proposals before committing. Error messages and progress displays lean heavily on internal terminology (routing overrides, canary, blacklist, agent_wrong_pct) without explaining user impact. The success signal (canary monitoring over 20 sessions) is too distant to validate whether an exclusion improved workflow.

The core value proposition is solid: learn from corrections and automate exclusions. But delivery needs better onboarding, batch decision support, and faster feedback loops.

---

### Issues Found

#### P1 | UX1 | Task 3, F2 | No path from user intent to discovery

**Evidence:** Task 3 creates `/interspect:propose` as the main entry point. Task 6 integrates proposals into `/interspect` (the analysis command). Neither location is discoverable when the user encounters the problem: "fd-game-design keeps running and producing noise."

**User impact:** Users hit the pain (noisy agent) in the middle of a flux-drive review session. They don't know interspect exists, much less that it can fix this. They resort to manually declining findings every session, or worse, losing trust in flux-drive entirely.

**Missing flow:**
1. User sees irrelevant finding from fd-game-design in flux-drive output
2. User wants to say "don't run this agent on this project anymore"
3. User has no idea how to do this

The plan has no mention of:
- In-context help when users override findings (e.g., flux-drive could suggest `/interspect:correction` after 2+ overrides of the same agent in one session)
- Ambient reminders in `/interspect` or `/interspect:status` that proposals are waiting
- `/help interspect` output explaining the workflow: correction → analysis → proposal → exclusion

**Fix:** Add a discovery nudge in Task 2 (flux-drive consumer): After triage table, if the session has 3+ overrides for the same agent, inject a note: "Tip: Run `/interspect:correction` to record patterns. After sufficient evidence, `/interspect` will propose routing overrides to reduce noise."

Alternatively, add to Task 6: After showing "ready" patterns, if the user has never run `/interspect:correction`, show: "These patterns came from manual overrides. Run `/interspect:correction <agent> <reason>` to collect richer evidence for future proposals."

---

#### P1 | UX2 | Task 3, F2 | Sequential proposal flow blocks batch decisions

**Evidence:** Task 3 line 290: "For each eligible pattern, present via AskUserQuestion" — proposals are presented one at a time with Accept/Decline. If interspect finds 3 eligible patterns, the user must decide on pattern 1 before seeing patterns 2 and 3.

**User impact:** User cannot compare proposals or make batch decisions. If they accept fd-game-design exclusion and then see fd-performance is also eligible, they might reconsider the first decision (maybe both are false positives due to project scope mismatch). Sequential flow forces premature commitment.

Common scenario: User reviews all proposals, accepts 2/3, declines 1. Sequential UX makes this require 3 separate AskUserQuestion interactions instead of one multi-select.

**Fix:** Change Task 3 proposal flow:
1. Detect all eligible patterns first
2. Show a summary table: "Interspect found 3 routing-eligible patterns: fd-game-design (5 events, 80% agent_wrong), fd-performance (6 events, 85% agent_wrong), fd-correctness (5 events, 100% agent_wrong)."
3. Ask: "Which agents do you want to exclude? (Select all that apply)" with options: each agent + "Show evidence for [agent]" + "Accept all" + "Decline all".
4. On "Show evidence for [agent]", display details inline and return to the selection.
5. On "Accept", apply all selected exclusions in batch.

This cuts interaction count from N proposals to 1 decision + optional evidence drilldowns.

---

#### P2 | UX3 | Task 3, F2 | Raw SQL output instead of human-readable evidence

**Evidence:** Task 3 line 307-308: If user selects "Show evidence details", the command runs `sqlite3 -separator ' | ' "$DB" "SELECT ts, override_reason, substr(context, 1, 200)..."` and displays raw query output.

**User impact:** User sees `2026-02-10T14:23:15Z | agent_wrong | {"desc":"Recommended async when project is sync-only","reason":"agent_wrong"}` — requires decoding timestamps, JSON structure, and truncated context. Not actionable for deciding whether to exclude the agent.

**Better format:**
```
Recent corrections for fd-game-design:
- Feb 10, 2:23pm: Recommended async patterns for sync-only project
- Feb 9, 11:45am: Suggested multiplayer architecture for single-player game
- Feb 8, 3:12pm: Flagged performance issue in non-critical path

Pattern: Agent assumes features (async, multiplayer) not present in this project.
```

**Fix:** In Task 3, replace raw SQL with a formatting step:
1. Query same data
2. Parse JSON context
3. Format as bulleted list with relative timestamps ("2 days ago")
4. Add a one-line pattern summary if multiple corrections share a theme

---

#### P1 | UX4 | Task 2, F1 | Error messages assume domain knowledge

**Evidence:** Task 2 Step 1 line 201: "If malformed, log `WARNING: routing-overrides.json malformed, ignoring overrides` in triage output, move file to `.claude/routing-overrides.json.corrupted`, and continue."

Line 206: "If the excluded agent is cross-cutting (fd-architecture, fd-quality, fd-safety, fd-correctness), add a **prominent warning** to triage output: `⚠️ Routing override excludes cross-cutting agent {name}. This removes structural/security coverage.`"

**User impact:** Messages tell the user what went wrong but not what to do. "Routing-overrides.json malformed" — which file? Where? How do I fix it? The user didn't create this file manually, interspect did. "Removes structural/security coverage" — does that mean my code will have bugs? Should I revert?

**Missing info:**
- Path to the file (absolute, not relative)
- Suggested action ("Run `/interspect:revert` to undo" or "Check `.claude/routing-overrides.json` for syntax errors")
- Impact severity ("This session will run all agents. Override remains inactive until file is repaired.")

**Fix:** Revise Task 2 error messages:
- Malformed JSON: `"WARNING: Routing overrides file (.claude/routing-overrides.json) is malformed. All agents will run this session. File moved to routing-overrides.json.corrupted. Check syntax or run /interspect:revert to start fresh."`
- Cross-cutting exclusion: `"⚠️ Routing override excludes {name}, which checks [architecture/security/correctness] across all code. This may allow structural issues to pass unreviewed. Run /interspect:status to review exclusions."`

---

#### P2 | UX5 | Task 5, F4 | No post-apply reminder to check results

**Evidence:** Task 4 ends with `"SUCCESS: Excluded ${agent}. Canary monitoring: 20 uses. Commit: ${commit_sha}"` but does not guide the user to validate the decision. Task 5 adds `/interspect:status` to show overrides, but users don't know to run it.

**User impact:** User applies override, sees success message, forgets about it. 10 sessions later, they wonder "Did that actually help? Should I revert it?" Status is buried in a separate command they've never run.

**Expected behavior:** After applying an override, the user should get actionable next steps:
- "Excluded fd-game-design. Next flux-drive triage will skip this agent."
- "Run `/interspect:status` after 5-10 sessions to check if this improved review quality."
- "If quality degrades, revert via `/interspect:revert fd-game-design`."

**Fix:** In Task 4 `_interspect_apply_routing_override`, extend the success message:
```bash
echo "SUCCESS: Excluded ${agent}. Commit: ${commit_sha}"
echo "Canary monitoring: 20 uses. Run /interspect:status after 5-10 sessions to check impact."
echo "To undo: /interspect:revert ${agent}"
```

Add to Task 6 (interspect integration): After any proposal is accepted, inject a session-level reminder: "New routing override applied. Review impact via `/interspect:status` in future sessions."

---

#### P2 | PROD1 | F2, F4 | Success signal requires 20 sessions — too slow

**Evidence:** PRD line 123 (canary metrics): "V1 canary monitors user override rate (overrides/session) for 20 sessions after exclusion." Task 4 line 483: `window_uses: 20`.

**Problem validation:** 20 sessions is 2-4 weeks of active work for a typical project. Users want faster feedback: "Did this help or hurt?" Waiting 20 sessions means users either forget about the decision or have already reverted it manually.

**Alternative success signals:**
- Token savings: "Flux-drive cost reduced by 12% since exclusion (3 sessions)."
- Synthesis quality: "No increase in override rate for remaining agents (5 sessions)."
- User sentiment: After 3-5 sessions, ask "Has excluding fd-game-design improved review quality?" (binary feedback).

**Risk:** If the canary takes 20 sessions to fire an alert, the user has already internalized the exclusion as "good" or "bad" and the alert is stale.

**Fix:** In Task 4, reduce canary window to 5 sessions or 7 days (whichever comes first). Add a "fast feedback" prompt after 3 sessions:
```
Routing override for fd-game-design: 3 sessions since exclusion.
Token savings: [X]%. Override rate for other agents: [stable/increased].
Keep this exclusion? [Yes, it's working] [No, revert it] [Ask me later]
```

This gives users actionable data within 3-5 days instead of 3-4 weeks.

---

#### P1 | PROD2 | F2 | Evidence dependency not surfaced until user tries feature

**Evidence:** PRD line 11: "This feature requires active evidence collection via `/interspect:correction`. Users must manually override irrelevant findings for patterns to emerge. Without corrections, routing proposals never trigger."

Task 3 proposal flow assumes evidence exists. No plan step surfaces this dependency when evidence is missing.

**User scenario:**
1. User reads about routing overrides in docs or discovers `/interspect:propose` via `/help`.
2. User runs `/interspect:propose`.
3. Command outputs "No routing-eligible patterns found."
4. User confused: "I have noisy agents, why isn't this working?"

Missing step: Explain that the system needs evidence first, and how to collect it.

**Fix:** Add to Task 3 (propose command):
- If no classified patterns exist at all (empty evidence DB): Show `"No patterns detected yet. Record corrections via /interspect:correction when agents produce irrelevant findings. Interspect learns from your overrides."`
- If classified patterns exist but none are "ready": Show progress toward thresholds (already planned) plus: `"Keep recording corrections via /interspect:correction. Patterns become proposal-ready after [min_events] events across [min_sessions] sessions."`
- If patterns are "ready" but none are routing-eligible (wrong event type or below agent_wrong_pct threshold): Show `"Patterns detected but not routing-eligible. Routing overrides require ≥80% of corrections to be 'agent_wrong' (not 'deprioritized' or 'already_fixed')."`

---

#### P2 | PROD3 | F5 | Manual override workflow requires JSON editing with no validation

**Evidence:** PRD F5 line 91-99: Users can hand-edit `.claude/routing-overrides.json` and set `"created_by": "human"`. Task 8 adds documentation with example JSON.

**Usability gap:** Users comfortable with JSON editing don't need interspect — they can exclude agents by editing flux-drive roster config. Users who need interspect (less technical, prefer commands) will struggle with manual JSON editing.

**Failure modes:**
- Typo in agent name → override silently ignored, user confused why agent still runs
- Invalid JSON → file corrupted, all overrides lost
- Missing required fields → partial override, undefined behavior

**Better workflow:** Add `/interspect:override <agent> <reason>` command for manual overrides (bypasses evidence requirements). This gives non-technical users a path to quick exclusions while technical users retain JSON editing option.

**Fix (optional enhancement beyond plan scope):** In Task 8 docs, add a note:
```
For quick manual exclusions without evidence, use `/interspect:override <agent> <reason>`.
This creates a manual override without requiring evidence collection.
Advanced users can also hand-edit `.claude/routing-overrides.json`.
```

If time/scope allows, add a simple `/interspect:override` command that wraps `_interspect_apply_routing_override` with `created_by: "human"` and empty evidence_ids.

---

#### P1 | UX6 | Task 3, F2 | Progress display lacks decision-making context

**Evidence:** Task 3 line 319: `"{agent}: {events}/{min_events} events, {sessions}/{min_sessions} sessions ({needs} more {criteria})"`

PRD F2 line 50: `"fd-game-design: 3/5 events, 2/3 sessions (needs 1 more session)"`

**User impact:** User sees "needs 1 more session" but doesn't know:
- How long will that take? (Could be tomorrow or 2 weeks depending on activity)
- What happens if they keep ignoring the noisy agent? (More token waste)
- Can they manually override the threshold? (Yes, via hand-editing, but not documented in this context)

Progress without timeline or action is not actionable.

**Fix:** Enhance progress display:
```
fd-game-design: 4/5 events, 2/3 sessions (needs 1 more session with corrections)
→ Keep using /interspect:correction when this agent is wrong. Or exclude manually via /interspect:override if you're sure.
```

This gives users two paths: wait for automatic proposal or take manual action now.

---

#### P2 | UX7 | Task 5, F4 | Revert creates permanent blacklist without warning

**Evidence:** Task 5 (interspect-revert.md) line 627-629: `"INSERT OR REPLACE INTO blacklist (pattern_key, blacklisted_at, reason) VALUES ('${AGENT}', '${TS}', 'User reverted via /interspect:revert');"` with no user confirmation.

PRD F4 line 83: "Blacklisted patterns never re-proposed unless user runs `/interspect:unblock <agent>`"

**User impact:** User reverts an override because they want to test whether the agent is useful now (project evolved, agent improved). They expect revert = "undo the exclusion." But revert also permanently prevents future proposals, which the user didn't intend.

**Scenario:**
1. User excludes fd-performance because project was a prototype (performance didn't matter).
2. Project goes to production, performance now matters.
3. User runs `/interspect:revert fd-performance` expecting "run this agent again."
4. 10 sessions later, user has evidence that fd-performance would be useful, but interspect never proposes it because it's blacklisted.

**Expected behavior:** Revert should offer two options:
- "Remove exclusion and allow future proposals" (default)
- "Remove exclusion and never propose this again" (blacklist)

**Fix:** In Task 5, update `/interspect:revert` flow:
1. After finding the override, ask: "Remove exclusion for {agent}. Should interspect re-propose this if evidence accumulates? [Yes, allow proposals] [No, blacklist permanently]"
2. If "allow proposals", skip blacklist insert.
3. If "blacklist permanently", insert blacklist record.

Update the success message: "Reverted routing override for {agent}. [Future proposals: allowed / Pattern blacklisted — won't re-propose]."

---

### Improvements

#### 1. Add onboarding for new users

The plan assumes users understand the interspect mental model (evidence → pattern → proposal → override). First-time users need a guided flow.

**Suggestion:** Add a `/interspect:setup` command that:
1. Explains what interspect does (learns from corrections, proposes exclusions)
2. Shows how to record corrections (`/interspect:correction`)
3. Explains thresholds (5 events, 3 sessions)
4. Offers to run an initial analysis (`/interspect`)

Run this automatically the first time a user triggers any interspect command.

---

#### 2. Expose token savings prominently

The PRD success metric is "≥10% token cost reduction" but this is never shown to the user. Token savings is the primary value proposition — make it visible.

**Suggestion:** In Task 5 `/interspect:status`, add a section:
```
### Impact Summary
Routing overrides active: 2 agents
Estimated token savings: 180k tokens across 8 sessions (15% reduction)
Time saved: ~4 minutes per flux-drive triage
```

Calculate by comparing average flux-drive cost before exclusions vs. after (requires tracking pre/post metrics in DB).

---

#### 3. Add escape hatch for "exclude all but X"

Power users working on specialized projects may want to exclude most agents and keep only 2-3 relevant ones (e.g., only fd-architecture + fd-correctness for infrastructure work).

**Suggestion:** Add `/interspect:exclude-all-except <agent1> <agent2>` command that generates overrides for all roster agents except the specified ones. This is faster than individually excluding 5-7 agents.

---

#### 4. Cross-cutting agent exclusions need stronger UX

Excluding fd-architecture or fd-safety removes structural/security coverage. The plan warns but doesn't block. For safety-critical projects, this is risky.

**Suggestion:** Add an extra confirmation step for cross-cutting agents:
```
⚠️ fd-safety provides security coverage across all code.

Excluding it means:
- No automatic detection of auth bypass, injection, or crypto misuse
- No OWASP coverage in reviews
- You are responsible for manual security validation

This is a high-risk decision. Type 'exclude fd-safety' to confirm:
```

Require typed confirmation instead of button click to slow down the decision and surface consequences.

---

#### 5. Add recovery path for "all agents excluded"

Edge case: User excludes all agents (or all but one). Flux-drive triage becomes useless.

**Suggestion:** In Task 2 (flux-drive consumer), add a check after applying overrides:
- If candidate pool has ≤1 agent remaining, inject error: "Routing overrides exclude nearly all agents. Review quality will be severely degraded. Run `/interspect:status` to review exclusions."
- Block triage if 0 agents remain: "All agents excluded by routing overrides. Flux-drive cannot run. Revert at least one override via `/interspect:revert` or edit `.claude/routing-overrides.json`."

This prevents users from accidentally disabling flux-drive entirely.

---

### Recommendations

**Must fix before shipping:**
- UX1 (discovery path from problem to solution)
- UX2 (batch proposal decisions)
- UX4 (actionable error messages)
- PROD2 (evidence dependency surfaced when missing)
- UX6 (progress display with action)

**Should fix for v1:**
- UX3 (human-readable evidence)
- UX5 (post-apply reminder)
- PROD1 (faster success signal)
- UX7 (revert blacklist warning)

**Consider for v1.1:**
- Onboarding flow (`/interspect:setup`)
- Token savings display
- Exclude-all-except command
- Cross-cutting confirmation UX
- All-agents-excluded safeguard
