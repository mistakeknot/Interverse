### Findings Index

| Severity | ID | Section | Title |
|----------|-----|---------|-------|
| P2 | Q1 | Features | Cross-cutting agent warning lacks severity guidance |
| P2 | Q2 | Features | Evidence-to-override type mapping underspecified |
| P2 | Q3 | Non-goals | Missing override governance limits |
| P3 | Q4 | Features | AskUserQuestion format not specified |
| P3 | Q5 | Features | Staleness detection for routing overrides missing |
| P3 | Q6 | Open Questions | Canary metric definition deferred without timeline |
| P1 | Q7 | Solution | Type classification confusing and unnecessary |
| P1 | Q8 | Features | Routing-eligible pattern definition incomplete |
| P2 | Q9 | Features | Git commit atomicity strategy undefined |
| P3 | Q10 | Features | Revert blacklist persistence unclear |

Verdict: **needs-changes**

### Summary

This PRD proposes a routing overrides system for interspect to exclude irrelevant flux-drive agents based on evidence patterns. The core concept is sound — close the feedback loop by excluding agents that consistently produce zero relevant findings. However, the PRD has specification gaps around pattern classification, atomicity guarantees, and governance limits that risk implementation drift. The "Type 2" classification is confusing and adds no value. Critical acceptance criteria are missing details on how routing-eligible patterns are detected, how git commit rollback works, and whether the 80% threshold is configurable. The canary metric question is labeled "open" but appears fundamental to v1 validation.

The PRD assumes familiarity with interspect internals (evidence store, counting rules, canary system) without defining the integration surface or validating that the existing infrastructure can support routing modifications. Cross-cutting agent warnings exist but lack guidance on when to block vs warn. The business case is solid, but implementation clarity needs tightening before plan generation.

### Issues Found

#### P1-Q7: Type classification confusing and unnecessary

**Evidence:** PRD title includes "(Type 2)", brainstorm references "Type 1 (context overlay)" and "Type 3 (prompt tuning)", F2 acceptance criteria mentions "Routing-eligible pattern detection" and "Pattern involves a specific agent being consistently irrelevant (not just occasionally wrong)" with a note that other patterns should produce "Type 1 or Type 3 modifications".

**Problem:** The type taxonomy is never defined in the PRD, forcing readers to infer from context. The types appear to be:
- Type 1: Context overlays
- Type 2: Routing overrides (this PRD)
- Type 3: Prompt tuning

But this classification adds no clarity and creates coupling risk. If interspect eventually supports 7 modification types, will every PRD be labeled "Type N"? The types seem to describe *what changes* (overlay vs exclusion vs prompt), not *why* or *when*. The acceptance criteria in F2 define routing-eligibility by override_reason frequency (≥80% agent_wrong), which is a clear, testable rule. The "Type 2" label adds nothing.

**Fix:** Remove "(Type 2)" from the title. Replace all references to "Type 1/2/3" with descriptive terms: "context overlay modification", "routing exclusion modification", "prompt tuning modification". Update F2 to say "routing exclusion modifications are proposed when..." instead of "not Type 1 or Type 3".

**Severity:** P1 — This is a core product naming issue that will propagate to code, docs, and user-facing messages if not fixed now.

---

#### P1-Q8: Routing-eligible pattern definition incomplete

**Evidence:** F2 acceptance criteria states "Routing-eligible pattern detection: ≥80% of events for the pattern have `override_reason: agent_wrong`" and "Pattern involves a specific agent being consistently irrelevant (not just occasionally wrong)". Brainstorm §"What 'Routing-Eligible' Means" adds two additional bullets.

**Problem:** The 80% threshold is presented as a fixed constant, but it should be configurable via `.clavain/interspect/confidence.json` (which already has `min_sessions`, `min_diversity`, `min_events`). The second criterion "specific agent being consistently irrelevant" is redundant with the 80% threshold — if 80% of events are agent_wrong, the agent is definitionally irrelevant. The third criterion "domain-specific (not cross-cutting)" is stated but never operationalized. How does the code know fd-architecture is cross-cutting? Is there a hardcoded list? A manifest? An agent metadata field?

The brainstorm mentions "Patterns where the agent is *wrong sometimes but right other times*" should not produce routing overrides, but the PRD provides no guidance on how to detect this. If an agent has 5 agent_wrong events and 1 agent_correct event (83% wrong), does that trigger a routing override? Or does interspect require 100% wrong for routing and use the 80% threshold for something else?

**Fix:**
1. Add `min_agent_wrong_pct: 80` to `.clavain/interspect/confidence.json` schema (F1 acceptance criteria).
2. Define "cross-cutting agent" operationally: add a `cross_cutting: true` field to agent frontmatter in interflux, or maintain a hardcoded list in `lib-interspect.sh`, or add `.clavain/interspect/cross-cutting-agents.json`. Specify which approach in F2.
3. Clarify in F2: "A pattern is routing-eligible when ≥80% of override events for that (source, event) tuple have `override_reason: agent_wrong` AND the agent is not cross-cutting. Patterns with mixed correctness (e.g., 5 wrong, 1 right) are routing-eligible if they meet the percentage threshold."
4. Add acceptance criterion: "Routing-eligible threshold (default 80%) is configurable via confidence.json."

**Severity:** P1 — This criterion gates all routing override proposals. Underspecification will cause inconsistent behavior and user confusion.

---

#### P2-Q1: Cross-cutting agent warning lacks severity guidance

**Evidence:** F1 acceptance criteria: "Cross-cutting agent exclusions (fd-architecture, fd-quality) trigger a warning in the triage log."

**Problem:** A warning in the triage log is easy to miss and does not prevent the exclusion. The PRD does not specify whether:
1. The exclusion should be blocked entirely (error, not warning)
2. The exclusion should require an extra confirmation step
3. The exclusion should be allowed but logged prominently
4. The exclusion should be allowed with a different canary metric or shorter window

The brainstorm mentions "warn" but also says "These agents provide structural baseline coverage — excluding them risks missing cross-cutting issues." If the risk is real, a warning is insufficient.

**Fix:** Add to F1 acceptance criteria: "Cross-cutting agent exclusions are allowed but require explicit confirmation. The triage warning includes: 'WARNING: Excluding fd-architecture removes structural coverage. Verify this is intentional. Proceed? [Yes/No/Show Evidence]'." Alternatively, if cross-cutting exclusions should be blocked: "Cross-cutting agents cannot be excluded in v1 — proposals for these agents are never generated."

**Severity:** P2 — This affects safety/governance but has a clear workaround (user can manually edit the JSON).

---

#### P2-Q2: Evidence-to-override type mapping underspecified

**Evidence:** F2 acceptance criteria: "Routing-eligible pattern detection: ≥80% of events for the pattern have `override_reason: agent_wrong`". Evidence table schema (from lib-interspect.sh) includes `event TEXT NOT NULL` and `override_reason TEXT`.

**Problem:** The PRD assumes `event` and `override_reason` values are already standardized, but never lists them. The only mention is "agent_wrong" as one override_reason. What are the others? "agent_correct"? "false_positive"? "scope_creep"? If a pattern has 5 events split as `{agent_wrong: 4, agent_late: 1}`, is that routing-eligible (80% wrong)? Or does "agent_late" count as non-wrong and disqualify the pattern?

The evidence schema also has `source` and `event` columns. For routing overrides, what are the valid (source, event) tuples? Is it `(agent_name, "override")`? Or `("flux-drive", "irrelevant_agent")`? The PRD needs to specify the evidence collection contract so flux-drive knows what events to emit.

**Fix:** Add a new section "Evidence Contract for Routing Overrides" with:
1. Table of `override_reason` values: `agent_wrong` (agent's domain doesn't apply), `agent_late` (agent ran but findings came too late), `agent_noisy` (agent flagged non-issues). Specify which reasons count toward routing-eligibility.
2. Table of `(source, event)` tuples that produce routing proposals: `(agent_name, "override")` with `override_reason: agent_wrong`.
3. Note: flux-drive must emit these events. Specify in Dependencies section that flux-drive changes are required.

**Severity:** P2 — Routing logic will work with hardcoded assumptions, but without documentation this becomes a hidden coupling point.

---

#### P2-Q3: Missing override governance limits

**Evidence:** Open Questions §2: "If interspect proposes excluding many agents, it signals an agent roster problem, not a project problem. Consider a soft cap (warn after 3 exclusions) but don't block."

**Problem:** This is presented as a open question but should be a design decision. If interspect proposes excluding 5 of 7 review agents, something is deeply wrong — either the project is radically outside flux-drive's target domain, or the agent roster is misconfigured, or the evidence collection is broken. A soft cap prevents degenerate cases where routing-overrides.json has 10+ exclusions and flux-drive becomes a no-op.

The PRD also doesn't address what happens when *all* domain-specific agents are excluded but cross-cutting agents remain. Does flux-drive run with only fd-architecture and fd-quality? Is that useful?

**Fix:**
1. Move governance limits from Open Questions to Non-goals or Features.
2. Add acceptance criterion to F2: "If a project already has 3 routing overrides, new proposals include a warning: 'This project has excluded 3 agents. Consider reviewing the agent roster or project domain classification.'"
3. Add acceptance criterion to F4: "`/interspect:status` shows override count per project and flags projects with ≥3 overrides as 'high exclusion rate — review roster'."
4. Optional: Add to Non-goals: "Hard caps on override count — users can exclude as many agents as needed, but interspect will warn."

**Severity:** P2 — Degrades product quality and user trust if not addressed, but not a v1 blocker.

---

#### P2-Q9: Git commit atomicity strategy undefined

**Evidence:** F3 acceptance criteria: "Atomic: if commit fails, the override is not left in a partial state."

**Problem:** The PRD specifies atomicity as a requirement but does not define the rollback strategy. There are four candidate approaches:
1. Write to temp file → git add → git commit → rename temp file to `.claude/routing-overrides.json` on success
2. Write to `.claude/routing-overrides.json` → git add → git commit → revert file on commit failure
3. Abort the entire proposal if git is in a dirty state (no rollback needed)
4. Use git's staging area as the source of truth (only promote to working tree after commit)

The brainstorm references `_interspect_flock_git` for serialized git operations, but `flock` only prevents concurrent access — it doesn't provide transactional rollback. If the commit fails (due to pre-commit hook, lock contention, or network error), how does interspect undo the file write?

The acceptance criteria also mentions "modification recorded in interspect `modifications` table" and "canary record created" — do these DB inserts happen before or after the git commit? If before, and the commit fails, are the DB rows rolled back? Or does the DB record persist even though the file wasn't committed?

**Fix:**
1. Specify the atomicity strategy in F3: "Write override to temp file `.claude/routing-overrides.json.tmp`. Git add + commit. On success, rename temp to `.claude/routing-overrides.json`. On failure, delete temp and abort proposal."
2. Specify DB transaction order: "SQLite inserts (modifications + canary tables) occur AFTER git commit success. If commit fails, no DB records are created."
3. Add acceptance criterion: "If git commit fails, the user sees: 'Failed to commit routing override (reason: <git error>). Override not applied. Retry? [Yes/No]'."

**Severity:** P2 — Partial writes create broken states that require manual cleanup. This is testable but must be specified before implementation.

---

#### P3-Q4: AskUserQuestion format not specified

**Evidence:** F2 acceptance criteria: "Proposal presented via AskUserQuestion with: agent name, event count, session count, project count, and representative evidence."

**Problem:** The PRD lists *what* to show but not *how*. Compare to the brainstorm, which includes a concrete proposal format:
```
Interspect suggests excluding fd-game-design from this project's reviews.

Evidence: 5 override events across 4 sessions, 3 projects
Pattern: fd-game-design produces no relevant findings for Go backend services
Sessions: s1 (2/10), s2 (2/11), s3 (2/12), s4 (2/14)

Accept this routing override?
[Yes] [No] [Show evidence details]
```

The PRD should include this or a similar template so implementers know the expected UX. The PRD also doesn't specify what "representative evidence" means — is it session IDs, timestamps, file paths, or override_reason values?

**Fix:** Add a new subsection under F2: "Proposal Format" with the example from the brainstorm or an equivalent template. Specify that "representative evidence" means "session IDs and dates for the most recent occurrences."

**Severity:** P3 — Missing detail, but implementers can infer from brainstorm or use reasonable judgment.

---

#### P3-Q5: Staleness detection for routing overrides missing

**Evidence:** F1 acceptance criteria lists pre-triage reader responsibilities but does not mention cache staleness. Flux-drive Step 1.0.2 (from context files) includes domain detection staleness checking.

**Problem:** Routing overrides can become stale in two ways:
1. The excluded agent was updated (new version, new prompts, new capabilities) and might now be relevant
2. The project changed domains (was a Go backend, now includes a game simulation module)

If fd-game-design was excluded 6 months ago because the project was a REST API, but the project recently added a procedural map generator, the override is stale. The PRD does not address how to detect or notify users of stale overrides.

Domain detection already has staleness checking (Step 1.0.2), but routing overrides are independent. There's no mechanism to invalidate overrides when the project changes.

**Fix:** Add to F1 or F4 acceptance criteria: "Routing overrides include a `created` timestamp. If an override is >90 days old, flux-drive triage logs: 'NOTE: Routing override for fd-game-design is 120 days old. Re-evaluate if project scope has changed.'" Alternatively, defer to v2: add to Non-goals: "Automatic staleness detection for routing overrides — users manually review via `/interspect:status`."

**Severity:** P3 — This is a quality-of-life feature, not a correctness issue. Users can manually review overrides via git log or `/interspect:status`.

---

#### P3-Q6: Canary metric definition deferred without timeline

**Evidence:** Open Questions §1: "Canary metrics for routing exclusions. The excluded agent produces no findings (it's not running), so override rate doesn't apply. Best candidate: Galiana's `defect_escape_rate` — but Galiana integration is a separate bead. For v1, canary monitors session-level quality metrics as a proxy."

**Problem:** This is labeled an "open question" but the answer is load-bearing for v1 validation. The canary system is supposed to detect when a routing override was wrong — the excluded agent would have caught a defect that slipped through. But without a metric, the canary is a no-op. The PRD says "session-level quality metrics as a proxy" but never defines what those are. Is it:
- User overrides per session (more overrides after exclusion = bad)?
- Total findings count (fewer findings after exclusion = bad)?
- Review duration (faster reviews after exclusion = good, evidence that the agent was noise)?

The PRD should either commit to a v1 canary metric or move canary monitoring to v2. Deferring this to implementation risks building a canary system that can't detect failures.

**Fix:**
1. If Galiana integration is blockers: Move F3's "canary record created" to v2. Update acceptance criteria: "Routing overrides are applied without canary monitoring in v1. Canary integration deferred to v2 pending Galiana defect tracking."
2. If v1 needs canaries: Define the proxy metric in F3: "Canary monitors user override rate (overrides per session) for 20 sessions after exclusion. If override rate increases by >20% relative to baseline, alert: 'Routing override for fd-X may have degraded review quality.'"

**Severity:** P3 — The feature works without canaries (users can manually revert), but this is a product completeness issue.

---

#### P3-Q10: Revert blacklist persistence unclear

**Evidence:** F4 acceptance criteria: "Revert removes the entry from `routing-overrides.json` and blacklists the pattern."

**Problem:** Where is the blacklist stored? Is it:
1. In the interspect SQLite DB (per-project, survives file deletion)?
2. In `routing-overrides.json` as a `"blacklisted": true` flag (per-project, visible in git)?
3. In a separate `.clavain/interspect/routing-blacklist.json` file?
4. Nowhere (blacklist is in-memory for the current session only)?

The PRD also doesn't specify what "blacklists the pattern" means. Does it prevent re-proposing the same (agent, project) pair forever? For 30 days? Until the evidence count doubles? The brainstorm mentions "Interspect will re-propose if the pattern still meets counting rules (unless blacklisted)" but never defines the blacklist TTL or invalidation conditions.

**Fix:** Add to F4 acceptance criteria: "Blacklist is persisted in interspect.db `blacklist` table with columns: `pattern_key` (source|event|reason), `blacklisted_at`, `reason`. Blacklisted patterns are never re-proposed unless the user runs `/interspect:reset-blacklist <pattern>`."

**Severity:** P3 — Revert works without a blacklist (just removes the override), but users will be annoyed if interspect re-proposes the same exclusion every session.

---

### Improvements

#### I1: Clarify the business case with data

**Observation:** The PRD opens with "If fd-game-design never produces useful findings for a Go backend project, it still runs every time — wasting tokens and adding noise to synthesis."

**Opportunity:** This is a plausible scenario, but the PRD provides no data on how often this happens. Is this a real pain point from user feedback, or a hypothetical edge case? The problem statement would be stronger with one of:
1. "In 14 flux-drive runs across 3 backend projects, fd-game-design produced 0 P0-P2 findings and 2 P3 findings (12% useful rate)."
2. "User reported: 'fd-game-design always runs but never applies to my CLI tools.'"
3. "Interspect evidence from clavain dev sessions shows 8 agent_wrong overrides for fd-game-design on backend beads."

**Recommendation:** Add a "Motivation" section with 1-2 concrete examples from interspect evidence, user feedback, or clavain session logs. This validates the feature's value and helps prioritize v1 vs v2 scope.

---

#### I2: Define success metrics upfront

**Observation:** The PRD has detailed acceptance criteria but no success metrics. How will you know if routing overrides are working?

**Opportunity:** Add a "Success Metrics" section:
1. **Adoption rate:** ≥1 routing override created per 10 projects with active flux-drive usage within 30 days of release.
2. **Token savings:** Median flux-drive token cost decreases by ≥10% for projects with routing overrides.
3. **Accuracy:** <5% of routing overrides are reverted within 20 sessions (canary alerts).
4. **User satisfaction:** 0 reports of "flux-drive skipped an agent I needed" due to routing overrides.

**Recommendation:** Add success metrics so you can validate the feature post-launch and decide whether to invest in v2 (model overrides, conditional routing).

---

#### I3: Consider hybrid approach: suppress vs exclude

**Observation:** The PRD treats routing overrides as binary: run the agent or don't. But there's a spectrum:
1. **Exclude:** Agent never runs (current proposal).
2. **Suppress:** Agent runs but findings are hidden unless manually requested.
3. **Deprioritize:** Agent runs with lower priority (context-only content, not full diff).
4. **Flag:** Agent runs normally but findings are tagged "review carefully — agent may not apply to this project."

**Opportunity:** A "suppress" mode gives users a safer escape hatch. If fd-game-design is suppressed, it still runs (preserving the option to check findings), but its output doesn't clutter the synthesis. If a defect slips through, the user can review suppressed findings and revert the suppression.

**Recommendation:** Add to Non-goals (v1) or Future Work: "Suppression mode (agent runs but findings hidden) — defer to v2 based on user feedback." This acknowledges the design space without expanding scope.

---

#### I4: Link to flux-drive spec conformance

**Observation:** The PRD references "flux-drive Step 1.2a" and "triage pre-filtering" but never cites the flux-drive spec. The CLAUDE.md context mentions "The flux-drive review protocol is documented in `docs/spec/`."

**Opportunity:** If routing overrides change the triage algorithm, do they require a spec update? Is this a conformance-level change (breaking) or an extension (compatible)?

**Recommendation:** Add to Dependencies: "Flux-drive spec update required — routing overrides are a Step 1.2a.0 extension. Update `docs/spec/core/scoring.md` to document pre-filtering as an optional extension point. Conformance level: SHOULD (agents can safely ignore routing-overrides.json if not implemented)."

---

#### I5: Validate assumptions about evidence volume

**Observation:** F2 requires "≥80% of events for the pattern have `override_reason: agent_wrong`" and the default counting rules are "3 sessions, 2 projects, 5 events" (from confidence.json context).

**Opportunity:** This assumes interspect collects enough override events to detect patterns. If users rarely run `/interspect:correction` and evidence collection is sparse, routing overrides will never trigger. The PRD should validate that the evidence pipeline can support this feature.

**Recommendation:** Add to Dependencies: "Interspect Phase 1 evidence collection must be active and producing override events. Minimum data requirement: ≥1 override event per 5 flux-drive runs (20% correction rate) across ≥2 projects. If correction rate is <10%, routing proposals will not trigger — users should run `/interspect:correction` proactively."

---

#### I6: Specify version migration strategy

**Observation:** F1 defines the file format as `{"version": 1, "overrides": [...]}` but does not specify what happens when version changes.

**Opportunity:** If v2 adds new fields (e.g., `"conditional": {"language": "go"}`), how does flux-drive handle a v1 file? Does it:
1. Reject the file and log an error?
2. Read it in compatibility mode (ignore unknown fields)?
3. Auto-upgrade it to v2 format?

**Recommendation:** Add to F1 acceptance criteria: "Flux-drive ignores `routing-overrides.json` with `version > 1` and logs: 'Routing overrides file uses unsupported version 2. Update interflux plugin.' Backward compatibility (v2 reader handling v1 files) is forward-planned by reserving the version field."

---

#### I7: Document the interspect + flux-drive contract

**Observation:** The PRD describes two plugins (clavain with interspect, interflux with flux-drive) interacting via a shared file. This is clean separation but creates a hidden contract.

**Opportunity:** If flux-drive changes its agent roster (renames fd-game-design to fd-gameplay), routing-overrides.json entries for "fd-game-design" become orphaned. The PRD should specify how to handle:
1. Overrides for agents that no longer exist (warn? ignore? error?)
2. Overrides with typos ("fd-game-desgin") — fail silently or warn?
3. Agent renames (migration path?)

**Recommendation:** Add to F1 acceptance criteria: "If routing-overrides.json references an agent not in the flux-drive roster, log: 'WARNING: Routing override for unknown agent "fd-game-desgin" — check spelling or remove entry.' Unknown agents are ignored, not treated as errors."

---

<!-- flux-drive:complete -->
