# User & Product Review (v2) — Dual-Mode Plugin Architecture Brainstorm

Reviewer: fd-user-product (second round)
Date: 2026-02-20
Source: /root/projects/Interverse/docs/brainstorms/2026-02-20-dual-mode-plugin-architecture-brainstorm.md
Context: This is a second review. The first round (review-dual-mode-user-product.md) flagged three BLOCKING issues and six significant findings. The brainstorm has been substantially revised in response.

---

## Primary User

Two users remain relevant. The revision does not change them; it only changes whether the product serves them better.

**User A — Standalone discoverer.** A developer who installs one or two Interverse plugins from the marketplace without Clavain, beads, or ic. Job: get useful functionality from a single install with no ecosystem buy-in required.

**User B — Integrated operator.** A developer running Clavain with multiple companion plugins who adds a new module mid-workflow. Job: extend an existing workflow with a new plugin that correctly detects the ecosystem and participates in it without requiring configuration.

---

## Scope of This Review

The first review raised three BLOCKING issues and six significant issues. The revised brainstorm addresses several of them explicitly. This review evaluates:

1. Product decisions for sub-50% standalone plugins (interlock, interphase, interline) — do the revised decisions hold up? What does "ecosystem-only" mean for a user who installs Clavain?
2. The nudge protocol, now specified with trigger, durable state, aggregate budget, and dismissal — are the remaining UX gaps material?
3. interject recalibrated from 90% to 70% — is this the right number and does the reasoning hold?
4. The session status line format — signal or noise?
5. "Build local statusline value" for interline — is this realistic?

---

## 1. Sub-50% Plugin Product Decisions — Do They Hold Up?

### What the Revision Says

The revised table makes the following decisions:

- **interlock (30%)** → Ecosystem-only. "Bundle with Clavain modpack, not published as standalone marketplace plugin."
- **interphase (20%)** → Ecosystem-only. "Bundle with Clavain modpack."
- **interline (40%)** → "Build meaningful standalone mode: show git branch, test status, recent errors as a general-purpose statusline. If standalone value stays below 50%, make ecosystem-only."

### Interlock and Interphase: "Ecosystem-only" Is a Decision, Not an Implementation

Calling them ecosystem-only is the correct product decision. The problem: the brainstorm does not define what "ecosystem-only" means in practice for User B.

**The Clavain modpack assumption is unexamined.** The document says "bundle with Clavain modpack" twice. There is no "Clavain modpack" defined anywhere in the brainstorm, in CLAUDE.md, or in the synthesis report. This is assumed infrastructure. The product question is: when a user installs Clavain, do interlock and interphase auto-install? Or does the user still need to run `/plugin install interlock` separately?

If the answer is "Clavain installs them automatically," then the user journey for User B is clean: install Clavain, get the ecosystem plugins. This is correct behavior and should be stated explicitly.

If the answer is "the user still installs them separately but they are just not visible in the standalone marketplace," then "ecosystem-only" means nothing more than suppressing the marketplace listing. The user still has to know interlock exists and install it manually. This is not a meaningful improvement over the current state.

The brainstorm does not specify the Clavain install trigger. Without that, "ecosystem-only" is a marketing decision, not a product decision.

**What the label "Companion plugin for Clavain" already meant.** The first review noted that interlock already had "companion plugin for Clavain" in its plugin.json but that label was easy to misread as "works with" rather than "requires." Ecosystem-only resolves the listing problem but only if the plugin is actually removed from standalone marketplace visibility. If it remains listed with the current description but without a standalone mode note, the same trust problem persists.

**The interphase "no state store" problem.** The first review identified that interphase at 20% means "phase tracking without beads has no state store." The revised brainstorm accepts the ecosystem-only designation. But the question of where phase state lives when beads is absent was listed as an open implementation question in the synthesis. Ecosystem-only sidesteps that question, which is correct: if it only runs inside Clavain (which implies beads), state storage is not the plugin's problem. This is fine, but it confirms the modpack assumption: interphase works because Clavain brings beads. That dependency chain must be explicit.

**Summary:** The ecosystem-only decisions are right. They are incomplete without a definition of what the Clavain install sequence does for these plugins. This is the one remaining gap that could cause User B to encounter a broken partial install state.

---

## 2. Nudge Protocol — Remaining UX Gaps

### What the Revision Specifies

The revised brainstorm now includes a complete nudge specification table:

| Aspect | Decision |
|--------|----------|
| Trigger event | First successful operation completion |
| Durable state | `~/.config/interverse/nudge-state.json` keyed by `plugin:companion` pair |
| Nudge text | `"[interverse] Tip: run /plugin install {companion} for {benefit}."` |
| Dismissal | Companion installed = never nudge. After 3 ignores, mark dismissed and stop. |
| Aggregate budget | Max 2 nudges per session via `~/.config/interverse/nudge-session-${CLAUDE_SESSION_ID}.json` |
| Output channel | stderr (hook output). Never blocks workflow. |
| Concurrency | Atomic touch pattern prevents duplicates from parallel hooks. |

The first review's core complaints were: no trigger event, no durable dismissal, no actionable install command, no aggregate budget. All four are now addressed.

### Remaining Gap 1: "3 Ignores" Is Undefined as a User Behavior

The dismissal rule says "after 3 ignores for the same pair, mark dismissed." The protocol does not define what constitutes an "ignore." Options:

- 3 sessions in which the nudge fired and the companion was not installed afterward
- 3 occurrences of the nudge in a single session
- 3 calendar days since the first nudge with no install

This matters because the durable state is keyed by `plugin:companion` pair and survives sessions. If "3 ignores" means "3 session firings," then the nudge persists for 3 days minimum before stopping. If it means "3 occurrences across all time," it stops quickly. Neither is wrong, but the ambiguity will produce inconsistent implementation.

Recommended definition: increment the ignore count each time the nudge fires (one per trigger event, per session, per pair) and the companion is not installed during that session. This is implementable and predictable.

### Remaining Gap 2: The Session-Level Budget File Is Per-Session by CLAUDE_SESSION_ID

The aggregate budget uses `nudge-session-${CLAUDE_SESSION_ID}.json`. This is correct — it bounds the total ecosystem nudge volume per session. However, CLAUDE_SESSION_ID is a runtime env variable. The brainstorm does not confirm that this variable is available in hook execution context.

If CLAUDE_SESSION_ID is not set or differs between hooks in the same session, the per-session budget file becomes per-hook-invocation, which means the budget is never shared and every plugin can fire its nudge independently. The aggregate budget collapses.

This is a small implementation risk but worth flagging before the protocol is built: confirm that CLAUDE_SESSION_ID is stable across all hook calls in a session.

### Remaining Gap 3: stderr Behavior Is Rendering-Context Dependent

The first review flagged this, and the revision does not address it. "stderr (hook output)" is specified as the delivery channel. The problem: Claude Code renders hook stderr differently depending on the hook event type and the Claude Code version. A nudge in a `PreToolUse` hook fires before the tool runs and may appear as a warning prefix. A nudge in a `Stop` hook appears at session end when the user is disengaging. A nudge in `PostToolUse` may be suppressed if the tool succeeded.

The brainstorm now correctly specifies the trigger event (first successful operation). But "first successful operation" maps to a hook event type — likely `PostToolUse` or `Stop` after a review command — and the rendering of stderr in that hook event determines whether the nudge is visible.

The spec is now correct in intent. The implementation must pin the nudge to a hook event where stderr is consistently visible. This is not a brainstorm-level gap, but it is a design decision the implementation will need to make that is not captured anywhere.

### What the Revision Gets Right

The three key improvements are substantial:
- Trigger on first successful operation (not session start) is correct. The user has context.
- Durable state keyed by `plugin:companion` is correct. It stops indefinite nudging.
- Actionable text with `/plugin install {companion}` is correct. The user has a next step.

The aggregate budget (max 2 per session) is reasonable. At 10+ plugins, uncapped nudges could fire 20+ times per session. The cap prevents the cobra effect.

The atomic touch for concurrency is correct and matches the pattern in the existing codebase.

**Overall verdict on nudge protocol:** The spec is now substantially complete. The two remaining gaps (ignore count definition, CLAUDE_SESSION_ID availability) are implementation-level, not design-level. The protocol is ready to move to implementation with those two points resolved.

---

## 3. interject at 70% — Is This the Right Number?

### The Revised Rationale

The brainstorm notes: "*interject recalibrated from 90% to 70%: without beads, research findings produce throwaway stdout with no persistent store. Valuable but degraded."

The first review called this out specifically: "without beads or a persistent store, findings go to stdout and are likely forgotten. Might be 70-75% in practice."

### Is 70% the Right Number?

The question is whether "throwaway stdout" accurately describes what happens to a standalone interject user, and whether losing that persistence drops the plugin from 90% to 70% or to something lower.

**What interject does as an "ambient discovery + research engine."** Based on its description, interject's value is ambient scanning that surfaces actionable findings. Two components are at play:

1. The scanning and surfacing — finding relevant context, connections, research results. This works standalone.
2. The persistence and integration — storing those findings in beads, linking them to sprints, making them retrievable later. This requires the ecosystem.

The 70% estimate implies the scanning is 70% of the value and persistence is 30%. Whether this is right depends on the user's actual workflow.

**The stdout problem is more severe for ambient tools than for interactive tools.** For a tool like interflux, a review output to stdout is still actionable: the user reads it, acts on it, moves on. For an ambient tool that surfaces findings during background scanning, stdout without persistence means: the finding appeared, the user may or may not have seen it, and it is gone when the session ends. For ambient discovery specifically, persistence is not a 30% enhancement — it is closer to what makes the pattern coherent at all. A research engine whose findings evaporate is not 70% as useful; it is a fundamentally different (and less useful) tool.

A more defensible calibration: interject standalone is genuinely useful for one-session research tasks where the user explicitly invokes it and reads the output during the session. It is not useful for its "ambient" use case (passive background discovery with persistent findings). If the "ambient" part is the primary value proposition, 60-65% may be more honest.

**However, 70% is acceptable for the purpose of the standalone decision.** The threshold question is whether 70% justifies standalone publication. At 70%, the answer is yes — the plugin provides real, session-level value without the ecosystem. The difference between 70% and 65% does not change the product decision. "Publish standalone" is correct at both numbers.

**What "throwaway stdout" means for the user.** In practical terms: a user runs an interject research query and gets structured findings in their terminal. They can read them, copy them, act on them in the session. They cannot retrieve them next session without manually copying them somewhere. This is genuinely useful. It is also genuinely degraded compared to the integrated experience. The 70% figure is honest as a rough estimate.

**Recommendation:** Keep 70%. The number is defensible and the product decision it supports (publish standalone) is correct. Adding a note in the marketplace listing that findings are session-scoped without beads would give users accurate expectations without requiring a percentage recalibration debate.

---

## 4. Session Status Line — Signal or Noise?

### What the Revision Specifies

The session-start status line:

```
[interverse] interflux=standalone | beads=active | ic=not-detected | 2 companions available
```

One line. Machine-parseable. Appears once per session. Shows plugin mode, detected tools, companion count.

### The Signal-to-Noise Question

The first review said this should be a requirement, not an open question. The revision has implemented it. The question now is whether the specific format serves the user.

**The format mixes abstraction levels.** `interflux=standalone` is plugin-level status. `beads=active` is ecosystem-tool status. `ic=not-detected` is CLI tool status. `2 companions available` is a count with no names. These four fields are not at the same level of abstraction, and the line does not give the user a clear next action.

A user who sees this line asks:
- "What does standalone mean for interflux?" — no answer in the line
- "beads=active is good, right?" — probably yes, but why?
- "ic=not-detected — should I care?" — unclear
- "2 companions available — which ones?" — no answer

The line is machine-parseable and human-confusing. It gives information without orientation.

**The format works for the integrated operator (User B), not the standalone discoverer (User A).** User B running Clavain will understand what beads, ic, and standalone mode mean. The status line is useful to them as a quick health check. User A, who installed interflux alone, will see this line and have no framework for interpreting it.

**This is not a reason to remove the status line.** It is a reason to reconsider who it is for. If this is an ecosystem-operator health check, it belongs in the centralized interbase.sh (ecosystem users only, already specified) and User A will never see it. That is already the design. The status line only emits when the centralized copy is present, which means standalone-only users do not see it. This is correct.

**The format should provide a clear affordance.** The current format ends with "2 companions available" but gives no path to learn which ones. Adding a follow-up path would improve it:

```
[interverse] interflux=standalone | beads=active | ic=not-detected | 2 companions: run /interverse status for details
```

Or, if the goal is to stay on one line without requiring a follow-up command, list the companions:

```
[interverse] interflux=standalone | beads=active | ic=not-detected | +interphase +interwatch available
```

The second version makes the status line actionable: the user sees which plugins would improve their experience. This is more useful than a count.

**The `ic=not-detected` phrasing.** "not-detected" is ambiguous — does it mean not installed, not running, or not configured? For a user who has ic installed but not initialized for this project, "not-detected" is misleading. Consider "ic=inactive" or "ic=not-initialized" to distinguish "not installed" from "installed but not active in this context."

**Overall verdict on status line:** The decision to emit it is correct. The format has two issues: the companion count should name the companions (or point to a command that does), and "not-detected" should distinguish not-installed from not-initialized. Both are small format changes, not design changes.

---

## 5. "Build Local Statusline Value" for interline — Is This Realistic?

### What the Revision Says

interline (40% standalone) is given the option: "Build meaningful standalone mode: show git branch, test status, recent errors as a general-purpose statusline. If standalone value stays below 50%, make ecosystem-only."

### The Problem With This Framing

"Build local statusline value" is not a product decision — it is a deferred implementation task inside a product decision. The brainstorm is saying: "we don't know if standalone value is achievable, so we'll try to build it and reassess." This is reasonable but it creates an open-ended workstream with no defined success criterion.

**What a standalone statusline would actually show.** Git branch, test status, and recent errors are the suggested features. These exist in other tools:
- Git branch: `starship`, `oh-my-zsh` git prompt, `powerline`, every shell theme
- Test status: `watch -n5 pytest` output, CI status in terminal
- Recent errors: shell history, tmux scrollback

The question is not whether these features are useful — they are. The question is whether interline should build them when existing tools already provide them well.

**What interline's actual differentiation is.** interline is a "statusline renderer" in the context of the Interverse ecosystem. Its value proposition is rendering Interverse-specific state: bead context, sprint phase, agent count. These are things no other tool provides. A standalone statusline showing git branch is feature duplication with dozens of existing tools, not differentiation.

If interline builds a generic statusline to hit the 50% threshold, it becomes a worse version of starship for standalone users while remaining a good Interverse-specific renderer for integrated users. This is a product dilution risk: the standalone mode cannibalizes the plugin's clear identity.

**The honest decision.** interline's identity is ecosystem-specific. Its 40% standalone value is honest. The right call is ecosystem-only, not "build a generic statusline to justify standalone publication."

The "build local value" path should only be pursued if interline's standalone mode would do something meaningfully different from existing terminal statusline tools — for example, showing Claude Code session-specific context (active hooks, context window usage, recent tool calls) that no other tool provides. That would be differentiated. A generic git-branch display is not.

**If the team does pursue standalone mode.** The success criterion must be defined before work begins: "standalone interline provides value that a user with starship would not get from starship alone." If that criterion cannot be met, ecosystem-only is the correct decision. The brainstorm should commit to one path rather than leaving it open.

**Summary:** "Build local statusline value" as stated is not a realistic product path unless the standalone features are differentiated from existing tools. The honest decision for interline is ecosystem-only. If the team wants to challenge that, they should define the standalone differentiator first, then decide whether to build it.

---

## 6. Marketplace Drift — What the Revision Does and Does Not Address

The first review flagged marketplace drift as a BLOCKING issue. The revised brainstorm includes it as Remaining Open Question 1: "Should interbump auto-generate descriptions from plugin.json + integration.json? Or should descriptions be stable text?"

**Leaving this as an open question is not sufficient.** Marketplace manifest drift was flagged as BLOCKING because the integration manifest is worthless for pre-install discoverability if marketplace.json is not regenerated from it. The revised brainstorm acknowledges the problem but does not resolve it.

The two options presented (auto-generate vs. stable text) have different tradeoffs:
- Auto-generate: accurate counts, risk of description churn on every plugin version bump
- Stable text: human-maintained, will drift again

A third option that the brainstorm does not mention: stable description text plus auto-generated structured metadata fields (agent count, companion list, standalone features). The description is human prose; the structured fields are machine-generated and always current. This separates the prose that stays stable from the counts that drift.

The failure mode if this stays unresolved: the integration.json is built and maintained, interbump reads it, but marketplace.json is updated manually and drifts within 3 months. The user-product reviewer in the next brainstorm revision flags the same issue. The open question should be closed to a decision, not carried forward indefinitely.

---

## 7. Migration Sequencing — Missing from User Impact Analysis

The "Remaining Open Question 2" is: which plugin gets the dual-mode treatment first? The brainstorm suggests interflux (90% standalone, cleanest case).

This is correct from an implementation standpoint. It is incomplete from a user impact standpoint. The dual-mode migration is a silent architectural change for existing users — existing interflux users will have interbase-stub.sh sourced in their hooks without knowing it. The migration plan should specify:

- Are there any user-visible behavior changes when a plugin migrates to the dual-mode pattern?
- If the stub stubs out a function that previously silently failed in a different way, does any existing user workflow break?
- Is the migration backwards-compatible for users who installed interflux before the migration?

The answers are probably "no visible change, yes compatible," but the brainstorm does not verify this. For User B (integrated operator), the migration is invisible. For User A (standalone), the stub adds 10 lines to a file they never read. The risk is low but worth a one-sentence statement.

---

## 8. What the Revision Successfully Resolves

To be explicit about what improved between v1 and v2:

- **BLOCKING-01 (sub-50% plugins):** Resolved. interlock and interphase are ecosystem-only. The incomplete piece is the Clavain modpack install trigger definition.
- **BLOCKING-02 (nudge protocol underspecified):** Substantially resolved. Trigger event, durable state, aggregate budget, and dismissal are all now specified. Two implementation-level gaps remain (ignore count definition, CLAUDE_SESSION_ID availability).
- **BLOCKING-03 (marketplace drift):** Acknowledged but not resolved — left as an open question.
- **P1-B (plugin.json schema conflict):** Resolved. Separate integration.json is now specified.
- **P1-C (intermod pattern not recognized):** Resolved. The stub-plus-live-discovery hybrid is now the specified approach, explicitly modeled on the interband pattern.
- **P2-B (no integration status visibility):** Resolved. Session status line is now specified.
- **UP-06 (interject too generous):** Resolved. 70% is a defensible recalibration.
- **UP-09/UP-10 (nudge improvements):** Resolved in the nudge specification.

The revision closed 7 of the 9 first-round findings. The two remaining are marketplace drift (open question, not closed) and the interlock/interphase Clavain install sequence (implied but not specified).

---

## Flow Analysis — Revised Flows

### User B (Integrated) Installing an Ecosystem-Only Plugin

1. User has Clavain installed with companions.
2. User attempts `/plugin install interlock` from marketplace.
3. **Gap: is interlock visible in the standalone marketplace?** If ecosystem-only means "removed from marketplace listing," the user should not be able to find it there. If it remains listed with a different label, what does the user see?
4. If not visible, user discovers interlock through Clavain modpack auto-install. Clean.
5. If Clavain modpack auto-installs interlock, interlock is available in the next session. Does the user get any notification that new ecosystem plugins were installed?

The happy path for ecosystem-only plugins only works if the Clavain modpack install is defined and automatic. This flow is currently underdefined.

### Standalone User Discovering the Ecosystem Through nudge

1. User installs interflux standalone.
2. User runs first review (first successful operation).
3. Nudge fires: "[interverse] Tip: run /plugin install interphase for automatic phase tracking."
4. **Question: if interphase is ecosystem-only and requires Clavain, is `/plugin install interphase` the right instruction?** Or should the nudge say "run /plugin install clavain to unlock phase tracking and more"?
5. If the user follows the nudge and installs interphase without Clavain, they get a 20% standalone plugin with no standalone value. This is the exact problem that ecosystem-only designation was meant to prevent.

This is a flow contradiction: the nudge protocol's job is to point users toward companion plugins, but if some companions are ecosystem-only, the nudge must not point standalone users toward those specific plugins. The nudge system needs to respect the ecosystem-only designation. ib_nudge_companion() must check whether the companion is standalone-viable before nudging. If it is ecosystem-only, the nudge should point toward Clavain, not toward the plugin directly.

This is a new gap created by the ecosystem-only decision that does not yet have a specification.

---

## Findings Summary

### Issues Found

**V2-01. SIGNIFICANT: "Ecosystem-only" lacks a Clavain install trigger specification.** The decision to make interlock and interphase ecosystem-only is correct, but "bundle with Clavain modpack" describes infrastructure that does not exist yet. The user-facing question — does installing Clavain auto-install these plugins? — is unanswered. Without this, ecosystem-only is a marketplace label, not a product change.

**V2-02. SIGNIFICANT: Nudge protocol must not route standalone users to ecosystem-only plugins.** If interphase is ecosystem-only, the nudge should not tell a standalone interflux user to install interphase directly. The nudge for ecosystem-only companions should route to Clavain, not to the companion. ib_nudge_companion() needs to respect the ecosystem-only flag.

**V2-03. MINOR: "3 ignores" for nudge dismissal is undefined as user behavior.** The brainstorm specifies "after 3 ignores, mark dismissed" without defining what constitutes an ignore. Implementation will guess and produce inconsistent behavior across plugin teams.

**V2-04. MINOR: CLAUDE_SESSION_ID availability in hook context is unverified.** The aggregate nudge budget uses this variable to name the session file. If it is not set or varies between hook calls, the per-session cap does not work.

**V2-05. MINOR: Session status line does not name available companions.** "2 companions available" without naming them provides no actionable signal. The user cannot act on a count.

**V2-06. MINOR: "ic=not-detected" conflates not-installed with not-initialized.** A user who has ic installed but not configured for the current project sees the same label as a user who has never heard of ic.

**V2-07. LOW: "Build local statusline value" for interline is not a decision.** It defers the product decision behind implementation work with no defined success criterion. The honest decision is ecosystem-only for interline given that git-branch/test-status features duplicate existing tools without differentiation.

**V2-08. LOW: Marketplace drift remains an open question.** The revision acknowledges the problem but does not close it to a decision. The open question should be resolved before the integration.json infrastructure is built.

**V2-09. LOW: Migration backwards-compatibility for existing standalone users is not specified.** When interflux migrates to dual-mode, are existing installations silently updated? Do existing users see any change?

### Improvements

**V2-I1. Define the Clavain modpack install contract.** Specify: when a user installs Clavain, which ecosystem-only plugins auto-install? Does this happen silently or with user confirmation? This closes the ecosystem-only decision.

**V2-I2. Add ecosystem-only flag to ib_nudge_companion() routing.** Ecosystem-only companions should route nudges to Clavain, not to the plugin directly. One conditional in the nudge emission logic.

**V2-I3. Define "ignore count" increment rule.** Recommended: increment once per session per pair where the nudge fired and companion was not installed by session end. This is predictable and implementable.

**V2-I4. Replace companion count with companion names in status line.** `| +interphase +interwatch available` instead of `| 2 companions available`. Users can act on names.

**V2-I5. Replace "not-detected" with "not-initialized" for ic state.** Distinguish installation state from project initialization state.

**V2-I6. Close the marketplace drift open question.** Recommend: stable prose description plus auto-generated structured metadata (agent count, companion list) in a separate machine-readable field. interbump generates the structured fields; humans own the prose.

---

## Verdict

The revised brainstorm is substantially better than the first version. Seven of nine first-round findings are closed. The architecture direction (stub-plus-live-discovery hybrid, separate integration.json, session status line, ecosystem-only for sub-50% plugins, complete nudge spec) is sound and the product decisions are mostly correct.

Two significant gaps remain: the Clavain modpack install sequence needs to be defined for the ecosystem-only decision to be meaningful for User B, and the nudge routing logic needs to respect ecosystem-only status to avoid a flow contradiction for User A.

The nudge protocol is now implementation-ready with two small clarifications (ignore count definition, CLAUDE_SESSION_ID availability).

The marketplace drift issue remains open and should be closed before integration.json infrastructure is built.

**Revised status: NEEDS-MINOR-CHANGES before planning.** The blocking issues from v1 are resolved. The remaining gaps are implementable without design rework. The architecture can proceed to planning with these issues logged as work items.
