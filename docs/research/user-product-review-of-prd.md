# User and Product Review: Reflect Phase Sprint Integration

**PRD:** `/root/projects/Interverse/docs/prds/2026-02-20-reflect-phase-sprint-integration.md`
**Bead:** iv-8jpf
**Reviewer:** Flux-drive User and Product Reviewer
**Date:** 2026-02-20

---

## Primary User and Job Statement

The primary user is an AI agent (Claude) executing a Clavain sprint. The job is to complete a unit of software work from brainstorm through shipped code. The agent operates autonomously through a defined phase chain, with minimal human interruption unless a gate blocks or a failure occurs.

This context is unusual: the user is not a human typing commands. The agent reads the sprint command, follows its instructions procedurally, and uses lib-sprint.sh functions for state transitions. This changes the evaluation criteria substantially. Friction for a human (typing overhead, decision fatigue, mental context switching) maps differently to an agent (token cost, instruction ambiguity, undefined branching behavior, and false positive gate blocks that stop the sprint mid-flow).

---

## Summary Verdict

The reflect phase is architecturally sound and the motivation is well-justified. The core loop — every sprint produces at least one learning artifact before marking done — is the right design. However, the PRD ships with five gaps that could cause the mandatory gate to become either a systematic bottleneck or a content-free checkbox, undermining the stated goal. These are solvable but require explicit decisions before implementation.

---

## 1. Agent Flow Friction Analysis

### 1.1 The engineering-docs skill is heavy for C1 work

The `/reflect` command delegates exclusively to the `clavain:engineering-docs` skill. That skill is a 7-step workflow: detect confirmation phrase, gather context (with blocking user prompts if context is missing), check existing docs, generate filename, validate YAML schema (blocking), write file, cross-reference, then present a decision menu.

For a C1 sprint — a one-liner rename or a trivial config key fix — this 7-step flow is disproportionate. The brainstorm says "a one-line memory note takes <10 seconds," but the engineering-docs skill has two blocking user prompts (Step 2 if context is missing, Step 3 if a similar doc exists) and a YAML validation gate that blocks until the schema passes.

The C1 gate threshold is documented as "any artifact" in the brainstorm and "artifact registered with `phase=reflect` via `ic run artifact add`" in the gate rule. But the `/reflect` command only routes through `clavain:engineering-docs`, which produces a full solution doc. There is no C1-appropriate lightweight path defined in the sprint command or the `/reflect` command.

**Risk:** For C1 sprints, the agent faces a heavy process for a trivial learning. The agent will either generate low-quality YAML-validated docs with placeholder content (gaming the gate) or the sprint will stall when the skill's blocking prompts have no meaningful content to fill.

**Needed:** A C1 artifact path that registers a one-line note without invoking the 7-step skill. This could be as simple as `ic run artifact add <run> --phase=reflect --content="one-liner note"` without writing a solution doc. The `/reflect` command needs branching logic: if complexity is 1 or 2, take the lightweight path; if complexity is 3 or higher, invoke engineering-docs.

### 1.2 The reflect command does not read complexity from sprint state

The `/reflect` command as written in `/root/projects/Interverse/hub/clavain/commands/reflect.md` has no reference to the sprint's complexity score. It always invokes the full `clavain:engineering-docs` skill. The complexity score was cached on the bead in the Pre-Step phase of the sprint command, and lib-sprint.sh has `sprint_classify_complexity()` available, but `/reflect` does not use it.

This is a direct gap between the brainstorm's gate-scaling design and the actual implementation plan. The PRD lists "Complexity-scaled gate thresholds documented: C1=any artifact, C2=non-empty content, C3=solution doc" as an acceptance criterion in F3. But none of the command-level or skill-level changes described implement the conditional routing that makes this real.

**Needed:** F3's acceptance criteria should include an explicit code path in the `/reflect` command that reads `sprint_classify_complexity` (or the cached complexity state on the bead), then branches to the appropriate artifact producer.

### 1.3 The "nothing meaningful to reflect on" case is unspecified

The brainstorm states "even trivial work teaches something" and uses this to justify no skip path. However, some sprints genuinely produce no novel learning: a sprint that adds a boilerplate file using an existing template, a sprint that closes a bead because the issue was already fixed upstream, or a sprint that executes a plan that is entirely routine. The agent has no guidance for what to write in these cases.

The engineering-docs skill has a built-in filter: "Non-trivial problems only — skip documentation for simple typos, obvious syntax errors, trivial fixes immediately corrected." The C1 gate says "any artifact," but if the engineering-docs skill's own criteria would cause it to skip documentation (because the fix is trivial), the agent is in a deadlock: the gate requires an artifact, but the skill says don't document trivial fixes.

**Risk:** The agent resolves this ambiguity by writing a meaningless artifact to satisfy the gate. "No bugs found, sprint completed cleanly" registered as a reflect artifact passes the `artifact exists` gate but produces no actual compound knowledge. This is the checkbox risk the brainstorm acknowledges but does not adequately mitigate.

**Needed:** A defined artifact type for "clean sprint — no novel learnings" that satisfies the C1 gate without pretending to document something. A complexity calibration note ("estimated C2, actual was C1 because the feature was pre-built by E3") is the brainstorm's suggested answer. The `/reflect` command should make this explicit as a valid artifact path with a concrete output format, not leave the agent to invent it.

### 1.4 The sprint command is not updated in this PRD

F1 says "Sprint command includes Step 9: Reflect that invokes `/reflect`" as an acceptance criterion. The current sprint command ends at Step 9: Ship with `phase=done` set immediately after. The sprint summary is also displayed at Step 9.

The PRD proposes inserting reflect between Ship (renumbered Step 10) and done. But the sprint command has three places that embed step numbering: the `--from-step <n>` argument handling (which lists step names: `brainstorm, strategy, plan, plan-review, execute, test, quality-gates, resolve, ship`), the `Session Checkpointing` section (which lists step names for checkpoint tracking), and the `Sprint Summary` display (which shows "Steps completed: n/9"). All three need updating. The PRD lists "Sprint error recovery section updated to reference the new step count" in F1's acceptance criteria, but the `--from-step` argument handling and checkpoint step list are not mentioned. A future implementer reading only the PRD would miss these.

**Needed:** F1's acceptance criteria should explicitly list the `--from-step` argument (which must add "reflect" as a valid step name), the checkpoint step list (which must include "reflect"), and the sprint summary denominator (9 becomes 10).

### 1.5 Checkpoint recovery has no reflect step

The sprint command's checkpoint recovery reads `checkpoint_completed_steps` and skips to the first incomplete step. If a sprint is interrupted during the reflect phase — the agent is mid-way through writing a solution doc, the session ends — the checkpoint may show "ship" as complete but "reflect" as incomplete. On resume, the agent should route to reflect.

The `sprint_next_step()` mapping in lib-sprint.sh already handles `reflect → done` correctly (returns "done" when at reflect phase). But the checkpoint recovery logic in the sprint command routes based on checkpoint step names, not phase state. If "reflect" is not in the checkpoint step list, a sprint interrupted during reflect will resume at ship (already completed) and try to re-execute it, or skip to done without completing the reflect gate.

**Needed:** "reflect" added as a named step in the checkpoint step list, and the checkpoint recovery routing verified to handle reflect → done correctly.

---

## 2. Product Validation

### 2.1 The problem is real and the solution is appropriately scoped

The brainstorm provides credible evidence that the reflect phase is missing from the learning loop. The vision document's reference to "compound" as an end-state behavior without a corresponding lifecycle phase is a genuine gap. The `/compound` command existing standalone but being rarely invoked is a reasonable inference from how optional steps behave in automated workflows. The problem statement is accurate and the solution is not overengineered.

### 2.2 The "always required, scaling with complexity" design is correct

The brainstorm's rejection of a skip path for low-complexity work is directionally right. Agents would classify work as C1 to avoid the overhead if the gate were skippable below a threshold. The bet that C1 gate cost is low enough to be acceptable is valid — if the C1 path is actually lightweight (a one-liner), not if it still routes through the 7-step engineering-docs skill.

The design is correct in principle. The implementation risk is that the C1 path is not yet lightweight in the command/skill layer, which defeats the argument.

### 2.3 The soft gate graduation plan is appropriate but needs a trigger

The brainstorm notes "soft gate initially (advisory), graduating to hard gate after validation." The PRD does not include this nuance — F1's acceptance criteria say "Step 10 (Ship, renumbered) cannot proceed without a reflect artifact (gate enforced)" with no mention of soft/hard graduation.

If the gate ships as hard immediately, the first sprint where the engineering-docs skill stalls (missing context, YAML failure) will block the run from completing. This is a high-severity adoption risk for the first sprints using the new phase chain.

**Needed:** The acceptance criteria in F1 should specify whether the gate is hard or soft on initial shipment, and if soft, what condition triggers graduation to hard. A reasonable approach: soft for the first 10 sprints (emit a warning but allow `ic run advance`), then hard once the path is validated to not produce false blocks.

### 2.4 The DefaultPhaseChain mutation risk is underweighted in the PRD

The brainstorm's section on "Layer 1: Kernel (intercore)" identifies a serious migration risk: existing runs with `phases IS NULL` use `ResolveChain()` which returns `DefaultPhaseChain` at call time. Changing the Go variable changes all NULL-chain runs retroactively. A sprint currently in the `polish` phase will advance to `reflect` instead of `done` on next `ic run advance`.

The PRD lists this as an Open Question (OS-level: "Should `shipping` be renamed to `polish`?") but does not include the NULL-chain migration risk as an explicit item in the features or acceptance criteria. The brainstorm correctly identifies Option (a) — migrate existing NULL-chain runs to explicit chains before updating `DefaultPhaseChain` — as the safer path. But F2's acceptance criteria only describe the bash transition table changes, not the Go-layer migration.

Looking at the actual lib-sprint.sh (line 78), `sprint_create` already writes an explicit `phases_json` when creating new runs. This means new sprints created after E3 are protected — they have an explicit chain and will not be affected by `DefaultPhaseChain` changes. The risk only applies to runs created before E3 that have `phases IS NULL`.

**Needed:** An explicit statement in the PRD about whether NULL-chain run migration is in scope, and if not, a migration prerequisite check before the kernel change is deployed.

### 2.5 Non-goal boundary is clean and well-drawn

The non-goals are well-calibrated. Deferring complexity-scaled quality checks to Interspect, deferring multi-agent reflect to a future iteration, and deferring Autarch UI are all correct scope-limiting decisions. The reflect phase's job is to produce learning artifacts, not to evaluate their quality. That boundary is maintained.

---

## 3. User Impact Assessment

### 3.1 Value proposition for the primary user (the agent)

From the agent's perspective, the reflect phase changes one behavior: before marking a sprint done, the agent must write something down. If the path is smooth (complexity-scaled, non-blocking for C1), the cost is low and the agent continues. If the path stalls (YAML validation failure, missing context prompts, ambiguous "what to write" cases), the agent is blocked or produces garbage output.

The value is asymmetric from the agent's view: the compound knowledge goes into `docs/solutions/` where a future session can read it. The agent executing the current sprint does not benefit from its own reflection immediately. The benefit is systemic and cross-session. This is correct and not a UX problem — it mirrors how documentation works for human developers — but it means the agent has no immediate reinforcement signal that the reflect step was worthwhile.

### 3.2 The decision menu at the end of engineering-docs is misaligned with automated flow

The engineering-docs skill ends with a 7-option decision menu that expects the user to respond with a choice. In the automated sprint context, the agent must make this choice without human input. The skill's design assumes "user" means "human responding interactively." In the sprint flow, the agent will either always pick "Option 1: Continue workflow" (the recommended path) without reading the other options, or sometimes halt to ask the human operator which option to choose, breaking the auto-advance assumption.

Option 1 is correct behavior, but it means steps 2-7 of the decision menu are dead weight for automated sprint flows. More problematically, the skill has blocking points at Steps 2 and 3 ("ask user and WAIT") that assume a human is present. In the sprint auto-advance context, the agent should be able to synthesize its own context from conversation history without blocking, and should always proceed without a human confirmation step. The current skill design does not support this.

**Needed:** A non-blocking mode for `clavain:engineering-docs` when invoked from an automated sprint context, or an explicit statement in the sprint command that the agent should provide all necessary context as arguments to `/reflect` so the skill has no missing-context blocking points.

### 3.3 The reflect command is underspecified for the inter-session case

The `/reflect` command says "Use `sprint_find_active` to find the current sprint and confirm it is in the `shipping` or `reflect` phase." This is correct for the normal case. But consider: a sprint is in `reflect` phase, the session ends before the artifact is registered (session crash, context limit hit), the sprint command's checkpoint recovery routes the agent to the reflect step, and the agent runs `/reflect`. The `sprint_find_active` returns the sprint still in `reflect` phase (the gate never advanced to `done`). The agent re-runs the engineering-docs skill, potentially producing a duplicate artifact for the same sprint.

The `sprint_set_artifact` function in lib-sprint.sh uses `intercore_run_artifact_add`, which adds a new artifact record rather than upserting. A re-run of reflect would produce a second artifact. This is not a critical bug (the gate just checks for existence, not uniqueness), but it could result in duplicate solution docs in `docs/solutions/`.

**Needed:** The `/reflect` command should check whether a reflect-phase artifact already exists for the current run before proceeding. If it does and the run is still in `reflect` phase, the agent should skip artifact creation and proceed directly to `sprint_advance`.

---

## 4. Flow Analysis

### 4.1 Happy path (C3 sprint, first run)

1. Sprint completes `polish` (currently `shipping`) phase.
2. Sprint advances to `reflect` phase.
3. Sprint command routes to `/reflect`.
4. `/reflect` invokes `clavain:engineering-docs`.
5. Skill extracts context from conversation history, writes solution doc, validates YAML, creates file in `docs/solutions/`.
6. `/reflect` registers artifact: `sprint_set_artifact <sprint_id> "reflect" <path>`.
7. `/reflect` calls `sprint_advance <sprint_id> "reflect"` which advances to `done`.
8. Sprint command closes bead, displays summary.

This path is coherent and has no undefined steps.

### 4.2 Error path: YAML validation failure

1. Skill reaches Step 5 (YAML validation).
2. YAML frontmatter fails validation (wrong enum value, missing required field).
3. Skill blocks and presents error message.
4. In automated sprint context: no human is available to provide corrected values.
5. Sprint stalls indefinitely (or until context limit).

This path has no defined recovery. The gate is satisfied only by a successfully written artifact. A YAML failure before file creation means no artifact is registered, and `sprint_advance` from `reflect` to `done` will fail the gate check.

**Outcome:** Sprint is stuck in `reflect` phase. The agent cannot advance. This is a hard block with no automated recovery path.

**Mitigation needed:** Either YAML validation failures should fallback to writing a simpler non-YAML artifact (a markdown note without frontmatter) that still satisfies the C1 gate, or the reflect step should handle YAML failure by logging a warning and registering the failed-validation doc as a C1 artifact to avoid blocking the sprint.

### 4.3 Error path: No learnings to document (C1 clean sprint)

1. Sprint completes ship phase.
2. Sprint advances to reflect.
3. `/reflect` invokes engineering-docs.
4. Skill's Step 1 check: "non-trivial problems only — skip documentation for simple typos."
5. Sprint was a trivial rename. Skill says: skip.
6. No artifact created.
7. `sprint_advance` from reflect fails gate check (no artifact).
8. Sprint stuck.

This is the same hard block as 4.2, but for a semantically different reason. The engineering-docs skill's own skip criteria conflict with the gate's "any artifact required" requirement.

**Resolution:** The reflect command must route to a different artifact type for C1 sprints that bypasses the engineering-docs skill's "non-trivial only" filter. A complexity calibration note or a `"clean sprint"` artifact registered directly via `ic run artifact add` is the correct path.

### 4.4 Error path: Sprint interrupted during reflect (session crash)

If a sprint is interrupted during the reflect phase and the run's phase is still `reflect`, the resume routing calls `sprint_next_step("reflect")` which returns `"done"` (because the next phase after reflect is done). The sprint command maps `"done"` to "tell user Sprint is complete." The sprint command would tell the user "Sprint is complete" even though the reflect artifact was never registered and the gate was never passed.

**Root cause:** The sprint command's resume logic routes based on `sprint_next_step(phase)`, which returns the command to produce the next phase. When phase is `reflect`, the next phase is `done`. But there is no command that produces `done` by running reflect — `/reflect` is the command for producing the reflect artifact and then advancing to done. The sprint command has no way to know the gate was never satisfied.

**Fix needed:** The sprint command's resume routing must distinguish between "the current phase has been completed and we should route to the command for the next phase" versus "the current phase is in-progress and we should route to the command that completes this phase." For the reflect phase specifically, the resume routing should check whether a reflect artifact exists before routing to "done." If no reflect artifact exists and phase is `reflect`, route to `/reflect`, not to done.

### 4.5 Missing flow: multi-agent sprints

Both the brainstorm and PRD defer multi-agent reflect. However, the sprint command already supports parallel agent dispatch (Step 5 parallel execution, Step 7 parallel quality gates). If a sprint dispatches 5 subagents to execute different modules, each may have learned something distinct. The reflect phase in its current design produces one artifact from one conversation context. The subagent learnings are not accessible to the primary agent's reflect step unless the subagent explicitly wrote something down during execution. This is correctly deferred, but should be noted as a design constraint on the current artifact model.

### 4.6 Open questions from the PRD, evaluated

**Q1: Should `shipping` be renamed to `polish` in lib-sprint.sh?**

The current lib-sprint.sh transition table uses `shipping`. The kernel uses `polish`. Looking at the actual code (line 570): the transition table uses `shipping`, and `sprint_phase_whitelist()` also uses `shipping`. The phase chain stored in `phases_json` on line 78 uses `shipping`.

Renaming is the right long-term decision. Not renaming creates a permanent divergence between the kernel's canonical phase names and the bash layer's names. When someone looks at `ic run show` output (which uses kernel phase names) versus `sprint_read_state` output (which uses bash phase names), the confusion will surface immediately. Recommendation: rename `shipping` to `polish` as part of this PRD. It is a one-line change in lib-sprint.sh and avoids documented-divergence that will confuse future implementers.

**Q2: Should `plan-reviewed` stay as an OS-only phase?**

The kernel's `DefaultPhaseChain` does not include `plan-reviewed`. The `phases_json` in `sprint_create` includes `plan-reviewed`. This means every sprint run has a phase that the kernel's gate rules do not know about. Since gate rules are keyed to phase transitions, a run with `plan-reviewed` in its chain will need custom gate rules defined for that transition. This is a pre-existing issue, not introduced by this PRD. But F5's acceptance criteria are the right place to make this decision explicit. If `plan-reviewed` stays OS-only, the gate rule table needs a `plan-reviewed → executing` rule that is in the OS-level gate config.

---

## 5. Complexity Scaling: Is It Well-Calibrated?

The three-tier gate (C1=any artifact, C2=non-empty content, C3=solution doc) is the right structure.

**C1 (trivial/simple, score 1-2):** The gate passes if any artifact is registered. The brainstorm says "a one-line memory note takes less than 10 seconds." This is the correct threshold. The implementation gap is that no one-liner path exists in the current command or skill chain.

**C2 (moderate, score 3):** The gate requires an artifact with content hash (non-empty, real content). This is enforced by the intercore artifact storage. The engineering-docs skill produces a full solution doc, which easily satisfies non-empty. This tier is well-calibrated.

**C3 (complex/research, score 4-5):** The gate requires an artifact in `docs/solutions/` path. The engineering-docs skill produces exactly this. This tier is well-calibrated.

The calibration problem is entirely at C1. The C2 and C3 tiers are correctly served by the existing engineering-docs skill. C1 needs a separate, simpler path. The 1-5 scale in `sprint_classify_complexity()` maps 1-2 to "trivial/simple," which is the band where the lightweight path is needed.

A concrete proposal for the C1 path: read the cached complexity from the bead before invoking engineering-docs, and for complexity 1 or 2, register a brief memory note directly via `ic run artifact add --phase=reflect --type=memory-note` with the note content. This satisfies the gate's "any artifact" requirement without invoking the 7-step process.

---

## 6. Scope Assessment

The PRD scope is appropriate. The five features (F1-F5) are tightly coupled and collectively represent the minimum viable wiring. F4 (documentation alignment) is the one feature that could be deferred without blocking the functional change, but it is small enough that deferring it creates more debt than it saves.

One scope concern: F5 (Sprint-to-Kernel Phase Mapping) includes "lib-sprint.sh `PHASES_JSON` updated to use kernel-canonical names where possible." This is the `shipping` → `polish` rename question. If this rename is included in F5, it is a migration-affecting change. Existing sprint beads in the `shipping` phase will not match the new phase name if it changes in the kernel. The migration script (analogous to F7 in the E3 PRD) would need to cover this. F5's acceptance criteria should explicitly state whether a migration for existing `shipping` → `polish` phase name changes is in scope.

---

## 7. Prioritized Issues

**P0 — Sprint blocking, no recovery path:**
The YAML validation failure path and the "nothing meaningful to reflect on" path both result in hard blocks with no automated recovery. These must be resolved before the gate is enforced.
File: `/root/projects/Interverse/hub/clavain/commands/reflect.md`
Fix: Add fallback artifact registration that bypasses engineering-docs when the gate would otherwise block.

**P0 — Resume routing bug for interrupted reflect:**
If a sprint is interrupted during the reflect phase, the resume logic routes to "Sprint is complete" without checking whether the reflect gate was satisfied.
File: `/root/projects/Interverse/hub/clavain/commands/sprint.md`
Fix: Resume routing must check for reflect artifact existence when phase is `reflect`.

**P1 — No C1 lightweight artifact path:**
The `/reflect` command does not branch on complexity and always invokes the heavy engineering-docs skill.
File: `/root/projects/Interverse/hub/clavain/commands/reflect.md`
Fix: Read complexity from bead state, branch to lightweight artifact registration for C1/C2.

**P1 — engineering-docs skill has blocking user prompts incompatible with auto-advance:**
Steps 2 and 3 of the skill block and wait for human input. In automated sprint context, no human is present.
File: `/root/projects/Interverse/hub/clavain/skills/engineering-docs/SKILL.md`
Fix: Either pass all required context as arguments from `/reflect`, or add a non-interactive mode.

**P2 — Sprint command step numbering and checkpoint list not updated:**
F1's acceptance criteria miss the `--from-step` argument list, the checkpoint step list, and the sprint summary denominator.
File: `/root/projects/Interverse/docs/prds/2026-02-20-reflect-phase-sprint-integration.md`
Fix: Add these to F1's acceptance criteria checklist.

**P2 — Soft/hard gate graduation is not specified:**
F1 says gate-enforced but the brainstorm says soft initially. The PRD does not specify.
File: `/root/projects/Interverse/docs/prds/2026-02-20-reflect-phase-sprint-integration.md`
Fix: Add acceptance criterion for initial gate hardness and graduation condition.

**P3 — Potential duplicate artifacts on re-run:**
If `/reflect` runs twice for the same sprint (interrupted and resumed), two artifacts may be registered.
File: `/root/projects/Interverse/hub/clavain/commands/reflect.md`
Fix: Check for existing reflect artifact before invoking engineering-docs.

**P3 — DefaultPhaseChain mutation not addressed in PRD:**
The kernel risk (NULL-chain runs advancing unexpectedly) is in the brainstorm but not in the PRD's features or acceptance criteria. E3's explicit chain writes protect new runs, but the PRD should say so explicitly.
File: `/root/projects/Interverse/docs/prds/2026-02-20-reflect-phase-sprint-integration.md`
Fix: Add a note confirming E3 protects existing runs or identifying which runs require pre-migration.

---

## 8. Questions That Could Change Implementation Direction

1. **Is the reflect gate soft or hard on day one?** If hard, the P0 issues above must be resolved before ship. If soft, the P0 issues are P1 (can be fixed in the validation period).

2. **Does the agent always have conversation history available when `/reflect` runs?** If context compaction has occurred before the reflect phase, the engineering-docs skill may have no conversation history to extract from. This changes whether the skill's Step 2 context extraction will succeed without blocking prompts.

3. **Is `plan-reviewed` in the sprint's phase chain or not?** The current `phases_json` in lib-sprint.sh includes it. The kernel's `DefaultPhaseChain` does not. If this PRD introduces reflect while leaving plan-reviewed unresolved, the sprint chain will have both OS-only and kernel-canonical phases mixed. The gate rule table must cover all phases in the chain.

4. **What is the expected artifact for a sprint that produces no bugs, no gotchas, and no pattern discoveries?** The brainstorm says "complexity calibration note" but the command does not say this. Without a defined answer, different sprint executions will produce different artifact types for the same situation, making the learning corpus inconsistent.

---

## 9. Positive Findings

The existing lib-sprint.sh transition table and `sprint_phase_whitelist()` already include `reflect` in the phase chains. The E3 implementation was forward-compatible with this change — `sprint_phase_whitelist()` for C1 (score 1) already includes `reflect` in the whitelist: `"planned executing shipping reflect done"`. This means reflect is mandatory even for C1 complexity in the skip logic, which is consistent with the PRD's design intent.

The `/reflect` command correctly uses `sprint_set_artifact` followed by `sprint_advance`, which is the correct sequence for gate satisfaction. The brainstorm's differentiation between Interspect (cross-sprint statistical learning) and reflect (within-sprint specific learning) is the right architectural separation. The non-goal list is tight — the decision to defer multi-agent reflect, Interspect integration, and Autarch UI is correct.

Note that `sprint_create` on line 78 of lib-sprint.sh already writes `reflect` into the `phases_json` for new runs:
```bash
local phases_json='["brainstorm","brainstorm-reviewed","strategized","planned","plan-reviewed","executing","shipping","reflect","done"]'
```
This means new sprint runs already have the correct phase chain. The kernel-layer change in F2 may only need to update `DefaultPhaseChain` as a documentation alignment, since new sprints are not using it anyway.

---
