# User & Product Review: Sprint Resilience PRD

**Reviewer:** Flux-drive User & Product Reviewer
**Target:** `/root/projects/Interverse/docs/prds/2026-02-15-sprint-resilience.md`
**Date:** 2026-02-15

## Primary User & Job-to-be-Done

**User:** Developer using Clavain `/sprint` command via Claude Code CLI
**Job:** Complete a feature from idea to shipped code without losing context across session restarts or getting stuck in manual phase-transition busywork

## Executive Summary

This PRD introduces **significant user-facing risk** through three ambitious system changes: auto-advance between phases, tiered brainstorming with LLM complexity classification, and a sprint bead hierarchy. While the problems are real (session brittleness, over-prompting), the solutions bundle complexity that could backfire:

**Critical Issues:**
1. **Auto-advance model creates new blindness** — users lose visibility into what's happening and can't course-correct until damage is done
2. **Tiered brainstorming classification is unvalidated** — no evidence an LLM can reliably classify feature complexity; misclassification wastes time or produces bad designs
3. **Sprint bead hierarchy adds cognitive load** — parent epic + 6 child beads per sprint + JSON state management — unclear if this complexity pays for itself

**Recommendation:** **Do not build as-spec.** Break into 3 separate experiments with earlier validation gates.

---

## Detailed Findings

### 1. Auto-Advance Model Creates New Friction

**Problem being solved:** "System asks 'what next?' at every step instead of making smart defaults"

**Proposed solution:** Remove all phase-transition prompts. Sprint advances automatically from brainstorm → strategy → plan → review → execute → test → quality-gates → resolve → ship. Pauses only for: design ambiguity (2+ approaches), P0/P1 gate failure, test failure, blocking quality findings.

**User impact analysis:**

#### Flow disruption — loss of orientation
- Current model: user sees "Brainstorm complete. What's next?" and chooses from 3 options (plan now / refine / done)
- New model: system proceeds silently to strategy → plan → review → execute
- **User gets no checkpoint to verify understanding before implementation starts**
- Terminal output scrolls past status messages (`Phase: brainstorm → strategized (auto-advancing)`) while user is reading brainstorm output
- By the time user catches up, Claude has written a PRD, created beads, written a plan, AND started execution

**Evidence gap:** PRD assumes users want fewer prompts. No data on:
- How often users choose "done for now" vs "proceed" (if >20%, auto-advance is wrong default)
- How often users discover mistakes in brainstorm during the strategy review step (if common, auto-advance removes the safety check)
- Whether users actually find 1 prompt per phase (4-5 total) burdensome

**Missing flows:**
- What if user wants to review brainstorm output before it becomes a PRD?
- What if user wants to stop after planning to scope-check before execution?
- What if user runs `/sprint` as a "plan this for later" workflow — auto-advance wastes tokens executing something user didn't ask for yet

**Pause triggers are reactive, not proactive:**
- Pause on "design ambiguity (2+ approaches)" — but brainstorm phase ALWAYS explores 2-3 approaches. Does this mean brainstorm always pauses? If not, why is strategy allowed to auto-advance when plan execution isn't?
- Pause on test failure — but by then code is written. User wanted to review the PLAN before writing code, can't.
- `bd set-state <sprint> auto_advance=false` requires user to predict when they'll want control. Most users don't know until they see the output.

**Discoverability:**
- F2 AC: "Remove 'what next?' prompts from brainstorm.md Phase 4, strategy.md Phase 5, and sprint.md between all steps"
- How does user learn that auto-advance is happening? Status messages? Statusline?
- If they want to stop, what's the signal to send? Ctrl+C? `/sprint-status` to see where they are?

**Recommendation:**
- **Do not ship auto-advance as default.** Invert the model: keep prompts, add `--auto` flag for users who want unattended execution.
- Measure: what % of users pass `--auto`? If <10%, the feature solves a non-problem.
- Alternative: introduce **preview mode** — "Here's what I'll do: brainstorm → PRD → plan → execute. Proceed? (Y/n/pause-after-plan)"

---

### 2. Tiered Brainstorming Classification Is Unproven

**Problem:** "Full collaborative dialogue (current behavior) is overkill for simple features"

**Proposed solution:**
- Simple features: research → one consolidated question (approach + assumptions + escalation option)
- Medium features: research → 2-3 approaches → one choice question
- Complex features: full dialogue (current)

Classification signals: description length, ambiguity terms, pattern references, additive vs structural

**User impact analysis:**

#### Misclassification cost
- **False negative (complex marked simple):** User gets one question, picks an answer, discovers later the approach was wrong. Now they're executing a bad plan. Requires backtracking through strategy → plan → execution to fix.
- **False positive (simple marked complex):** User gets dialogue when they didn't need it. Annoying but lower cost (just extra questions).

**No validation criteria:**
- F3 AC: "Complexity classification runs automatically based on feature description"
- What accuracy is acceptable? 90%? 70%? 50%?
- PRD provides no success metric. If 40% of classifications are wrong, is the feature a failure?

**Evidence gap:**
- No examples of "simple" vs "medium" vs "complex" features with ground truth
- No interrater reliability check (do two reviewers agree on classification?)
- "Description length, ambiguity terms" — vague heuristics. What's the threshold? 50 words? 200?

**User control:**
- F3 AC: "`bd set-state <sprint> complexity=complex` overrides auto-classification"
- Requires user to classify BEFORE seeing the agent's questions. User doesn't know if brainstorm will be shallow until it's too late.
- No in-flow escalation: "This question doesn't cover my concern" → how does user request deeper dialogue?
- F3 AC: "Even simple features always get exactly one consolidated question (invariant)" — but the escape hatch is "escalation option" in the question. What does that do? Route to full dialogue? If yes, why not start there when in doubt?

**Alternative approach not considered:**
- Let user choose depth: "How deep should we go? Quick (1 question), Standard (approach selection), Deep (collaborative)"
- Or: ask ONE question, then "Does this cover it, or should we explore further?"

**Recommendation:**
- **Do not ship classification without validation.** Run 20-feature pilot: classify manually (human ground truth), then test LLM classifier accuracy. If <80% agreement, abandon auto-classification.
- Ship depth CHOICE first (user picks), measure which users pick what, THEN consider auto-classification as optimization.

---

### 3. Sprint Bead Hierarchy — Complexity vs. Value

**Problem:** "Phase state is ephemeral (lost on session restart). Sprint tracking is ad-hoc."

**Proposed solution:**
- Parent sprint bead (type=epic, sprint=true)
- 6 child beads (one per phase: brainstorm, strategy, plan, execute, review, ship)
- State fields on parent: `phase`, `sprint_artifacts` (JSON), `child_beads` (JSON array), `complexity`, `auto_advance`

**User impact analysis:**

#### Cognitive load — 7 beads per sprint
- Current: 1 bead per feature, phase tracked via bead state
- New: 1 parent + 6 children = 7 beads
- User runs `bd list` → sees 7 entries for a single feature
- Which bead do they update when work is blocked? Parent? Child? Both?

**When does bead creation happen?**
- F1 AC: "Each phase (brainstorm, strategy, plan, execute, review, ship) creates a child bead linked via `bd dep add`"
- Does this mean 6 `bd create` calls, one per phase, as the sprint progresses?
- Or: all 6 created upfront at `/sprint` start?
- If incremental: what if user stops after brainstorm? Do they have a "brainstorm" bead orphan?
- If upfront: why create "execute" and "ship" beads before knowing if the feature will even proceed?

**State redundancy:**
- Parent bead has `phase` field (current phase)
- Child beads have `status` field (pending/in_progress/completed)
- How do these stay in sync? If parent phase=execute, is execute child bead status=in_progress? Who enforces this?

**JSON state management:**
- `sprint_artifacts` (JSON): what's the schema? Array of `{phase: string, path: string}`?
- `child_beads` (JSON array): why is this needed? `bd list --parent=<sprint-id>` already surfaces children via dep links.
- F1 AC: "sprint_artifacts is updated as each artifact (brainstorm doc, PRD, plan) is created" — who updates it? lib-phase.sh? User? What if they forget?

**Legacy migration:**
- F1 AC: "Legacy beads with phase state but no sprint parent get reparented under a new sprint bead"
- When does reparenting happen? SessionStart hook auto-detect? Manual `/sprint` invocation?
- What if user has 10 old beads — do they all get sprint parents? Or only the one being resumed?

**Value proposition:**
- PRD claims: "Sprint state lives entirely on beads. SessionStart hook detects active sprints. Any session can resume any sprint with zero user setup."
- Current system ALREADY does this: `phase_get <bead-id>` reads phase from bead state. Works across sessions.
- What does the hierarchy add?
  - Artifact tracking? Could store `artifacts` JSON on single bead.
  - Child bead status? Could store `phase_completion` JSON array on single bead.
  - Complexity/auto_advance flags? Could store on single bead.
- **The hierarchy adds 6x bead overhead for tracking that could live on 1 bead with richer state.**

**Missing: Why not enrich single-bead state?**
- Non-goals says "Not adding a `sprint` type to beads — using `type=epic` with `sprint=true` state flag"
- Why not `type=sprint` with state: `{phase, artifacts: [], complexity, auto_advance}`?
- Or: keep `type=epic`, add state fields, skip child beads entirely?

**Recommendation:**
- **Do not ship hierarchy without proving single-bead enrichment is insufficient.**
- Prototype: add `artifacts` and `auto_advance` state to existing epic beads. Does this solve resume? If yes, hierarchy is over-engineering.
- If hierarchy is needed: explain WHAT problem requires 6 child beads (not just "tracking" — tracking what specifically?).

---

### 4. Missing Edge Cases — Resume Flow

**F4: Session-Resilient Resume**

"Sprint state lives entirely on beads. Any session can resume any sprint with zero user setup."

**Edge cases not addressed:**

#### Multiple active sprints
- F4 AC: "/sprint with multiple active sprints presents AskUserQuestion to choose"
- What if user has 5 active sprints? Does the question list all 5? What if they want #8 in the list?
- Recommendation from discovery scan may be stale (sprint was active yesterday, user shipped it 2 hours ago but didn't close bead). Pre-flight check guards against deleted beads but not completed work.

#### Sprint in unknown state
- What if sprint bead has `phase=execute` but no plan file in `sprint_artifacts`?
- What if `child_beads` array references a bead ID that no longer exists (user manually deleted it)?
- Does resume validate artifact existence before routing?

#### Concurrent sessions on same sprint
- Non-goal: "No concurrent users on the same sprint bead"
- But what about concurrent Claude Code sessions by the SAME user?
- User runs `/sprint` in terminal 1 → starts execute phase
- User runs `/sprint` in terminal 2 → sees same sprint as active, resumes
- Both sessions now editing same files, writing same bead state → conflict

**Recommendation:**
- Add session-level sprint lock: `bd set-state <sprint> active_session=<session-id>`. Warn if another session tries to resume.
- Or: accept collision, document it as known limitation in F4 AC.

---

### 5. Scope Creep — Bundled Proposals

**Three independent features bundled as one PRD:**

1. **Sprint bead lifecycle** (F1) — state persistence
2. **Auto-advance engine** (F2) — UX workflow change
3. **Tiered brainstorming** (F3) — LLM classification + interaction model change

**These are orthogonal:**
- Could ship F1 (bead state) without F2 (auto-advance) — users still get session resilience
- Could ship F2 (auto-advance) without F3 (tiering) — users get unattended execution for all features
- Could ship F3 (tiering) without F1/F2 — users get adaptive brainstorming today

**Risk of bundling:**
- If any one feature has issues (e.g., auto-advance creates user friction), the whole PRD is at risk
- Hard to measure success: is outcome due to F1, F2, or F3?
- Testing complexity: 3 features × edge cases = large test matrix

**Recommendation:**
- **Split into 3 PRDs.** Ship F1 (bead state) first as pure infrastructure. Validate session resume works. Then layer F2 (auto-advance) as behavior change, measure user acceptance. Then F3 (tiering) as optimization.

---

### 6. Non-Goals — Appropriate or Hiding Scope?

**Non-goal: "Sprint templates (e.g., 'quick sprint' vs 'full sprint')"**

This is EXACTLY what F3 tiered brainstorming provides: quick (simple), standard (medium), full (complex). Why is it a non-goal when it's already in scope under a different name?

**Non-goal: "Sprint metrics/velocity (defer to future)"**

Reasonable. User doesn't need burndown charts to complete one sprint.

**Non-goal: "Multi-user sprints"**

Reasonable, but see missing edge case: same-user concurrent sessions.

**Non-goal: "New beads CLI type (using type=epic with sprint=true)"**

Why? `type=sprint` would make queries cleaner: `bd list --type=sprint` vs `bd list --type=epic | jq 'select(.state.sprint==true)'`. Using a state flag instead of a type increases query complexity with no clear benefit.

**Recommendation:**
- Reconsider sprint type. If the objection is "don't want to modify beads CLI," that's an implementation detail, not a product decision.

---

## Open Questions (from PRD) — Answers

**Q1: "Should sprint beads inherit priority from feature description, or always be P2?"**

**Answer:** Neither. Priority should be USER-SPECIFIED at creation time. Feature description may imply urgency, but user knows their backlog. Default P2, allow override via `--priority` flag or post-creation `bd update`.

**Q2: "Should sprint bead auto-close when ship phase completes, or wait for explicit `bd close`?"**

**Answer:** Auto-close is dangerous with auto-advance. If ship phase has a bug (e.g., tests pass locally but CI fails), bead is closed prematurely. Require explicit close. Recommendation: emit "Sprint complete. Run `bd close <id>` to close the bead."

---

## Value Proposition Clarity

**Claimed value:** "Users lose context mid-sprint and must manually re-orient, while the system asks 'what next?' at every step instead of making smart defaults."

**Reality check:**
- **Context loss on restart:** Real problem. F1 (bead state) solves this. F4 (resume) solves this. Rest is not needed for this problem.
- **Over-prompting:** Unvalidated problem. How many prompts are too many? 3? 5? 10? No user research cited.
- **Manual re-orientation:** What does this mean? User reads `bd show <id>`, sees `phase=planned`, runs `/clavain:work`. That's 2 commands. Is this friction? For whom?

**Missing:** User testimonial, session log, or data showing current pain severity.

**Recommendation:**
- Before building, validate problem scope: instrument current `/sprint` to log:
  - How often users resume sprints (if <10%, session resilience is niche)
  - How often users choose "done for now" at phase transitions (if >30%, auto-advance is wrong default)
  - How long users spend re-orienting after session restart (if <1 min, not worth optimizing)

---

## Success Metrics — Missing

PRD has no measurable success criteria.

**What would prove this worked?**
- % of sprints that complete without user intervention (target: 80%?)
- % of resumed sprints that route correctly (target: 95%?)
- User satisfaction survey: "I feel in control of the sprint workflow" (target: 4/5?)

**What would prove it failed?**
- Users disable auto-advance immediately
- Misclassification rate >20%
- Users abandon `/sprint` for manual `/brainstorm` + `/write-plan` to retain control

**Recommendation:**
Add "Success Metrics" section to PRD before implementation.

---

## User Segmentation — Who Benefits? Who Is Harmed?

**Benefits:**
- **Power users doing repetitive sprints:** Auto-advance saves them 4-5 confirmation clicks per sprint. If they run 10 sprints/week, that's 40-50 clicks saved. Modest win.
- **Users with frequent session interruptions:** Resume feature helps. But this is solved by F1/F4 alone, not F2/F3.

**Harmed:**
- **New users learning the workflow:** Auto-advance removes checkpoints that teach the phases. User doesn't learn "strategy comes after brainstorm" because it happens automatically.
- **Users doing exploratory work:** "Let me brainstorm this idea" becomes "system wrote a PRD and started coding." User wanted idea capture, got implementation.
- **Users with complex features:** Tiered brainstorming may classify their feature as "simple," giving them one shallow question when they needed deep exploration.

**Recommendation:**
- If building, make auto-advance opt-in for first 90 days. Default to current behavior. Track adoption. If <20% opt in, feature is solving a non-problem.

---

## Recommendations Summary

### Do Not Build As-Spec

**Fundamental issues:**
1. Auto-advance removes user control without evidence users want this
2. Tiered brainstorming lacks validation that classification works
3. Sprint bead hierarchy adds complexity without clear payoff over single-bead state enrichment

### Alternative Path — 3 Experiments

**Experiment 1: Session-Resilient State (Low Risk)**
- Ship F1 + F4: bead state + resume
- Use single bead with enriched state (artifacts array, phase, complexity flag)
- Skip child beads
- Validate: does resume work across sessions? (Yes/no, binary)

**Experiment 2: Auto-Advance Opt-In (Medium Risk)**
- Add `--auto` flag to `/sprint`
- Keep confirmation prompts as default
- Measure: what % of users pass `--auto`? What % disable it mid-sprint?
- If <20% adopt, abandon auto-advance as default
- If >60% adopt, make it default with `--interactive` escape hatch

**Experiment 3: Brainstorm Depth Choice (Medium Risk)**
- Replace auto-classification with user choice: "Quick / Standard / Deep brainstorming?"
- Measure: which users pick what depth for what features?
- Use this data to train a classifier (if pattern emerges)
- If no pattern: auto-classification is not viable

### If You Must Ship as One PRD

**Minimum changes to reduce risk:**

1. **F2 (auto-advance):** Add `CLAVAIN_INTERACTIVE=true` env var (default). Only auto-advance when `false`. Emit clear status: "Auto-advancing to strategy (set CLAVAIN_INTERACTIVE=true to pause)."

2. **F3 (tiering):** Always show classification + confidence: "This looks like a SIMPLE feature (confidence: 70%). Proceed with quick brainstorm, or request deeper dialogue?" Let user override before questions start.

3. **F1 (bead hierarchy):** Justify why 6 child beads are needed vs. single bead with `{artifacts: [], phase_history: []}` state. If justification is weak, cut child beads.

4. **F4 (resume):** Add session lock or document concurrent-session collision as known limitation.

5. **Add success metrics:** Track auto-advance disable rate, classification override rate, resume success rate. Define failure thresholds (e.g., if >40% of users disable auto-advance in first week, rollback).

---

## Conclusion

This PRD attempts to solve real problems (session brittleness, possible over-prompting) but does so by introducing **three large, unvalidated changes** that shift control away from the user. The auto-advance model assumes users want "smart defaults" when they may want "checkpoints." The tiered brainstorming assumes LLMs can classify feature complexity reliably (unproven). The sprint bead hierarchy assumes 6 child beads are better than 1 enriched bead (unjustified).

**Core tension:** This is a CLI tool for developers who value control and transparency. Auto-advance + auto-classification trades control for convenience. Without evidence that users want this trade, the PRD is building on assumption.

**Final recommendation:** Do not proceed as-written. Split into 3 experiments, ship state persistence first (clear win), validate auto-advance and tiering separately with opt-in pilots before making them default behavior.
