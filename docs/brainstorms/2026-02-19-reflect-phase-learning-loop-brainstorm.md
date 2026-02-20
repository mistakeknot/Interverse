# Reflect Phase: Closing the Learning Loop

**Bead:** iv-8jpf
**Phase:** brainstorm (as of 2026-02-20T15:10:28Z)
**Date:** 2026-02-19
**Status:** Planned

## What We're Building

A mandatory `reflect` phase in the Clavain sprint lifecycle, positioned after `polish` and before `done`. This makes the recursive self-improvement loop a gate-enforced part of every sprint — the system literally cannot mark work as done without capturing what it learned.

The default phase chain becomes 10 phases across 5 macro-stages:

```
Discover          Design            Build                    Ship       Reflect
brainstorm →      strategized →     executing →              polish →   reflect → done
brainstorm-       planned           review
reviewed
```

## Why This Matters

### The missing feedback loop

Clavain's thesis is recursive self-improvement: the system gets better at building software by learning from how it built software. The current lifecycle ends at `done` — there's no formal step where the system captures what worked, what failed, what patterns emerged, or how its own process should change.

The `/compound` skill exists but is standalone — invoked manually, easy to skip under pressure, and disconnected from the sprint state machine. In practice, reflection happens when someone remembers to run it, which means it doesn't happen for most work.

This is the difference between a delivery pipeline (Discover → Design → Build → Ship) and a learning system (Discover → Design → Build → Ship → Reflect → [feeds into next Discover]). Without the reflect phase, Clavain is architecturally incapable of the thing that justifies its existence.

### Evidence from the vision doc

The Interverse vision document states the convergence target explicitly:

> "The agency runs its own sprints — research, brainstorm, plan, execute, review, compound."

The word "compound" appears in the vision's description of the end state, but it has no corresponding phase in the lifecycle. The reflect phase is the mechanism that makes this vision statement true.

### Relationship to Interspect

The Interspect profiler (cross-cutting concern) reads kernel events and proposes OS configuration changes. But Interspect operates at the *system* level — it learns about agent performance patterns across many sprints. The reflect phase operates at the *sprint* level — it captures what was learned during this specific piece of work.

These are complementary, not redundant:
- **Interspect** learns: "agent X produces false positives 40% of the time" (statistical, cross-sprint)
- **Reflect** learns: "the lipgloss Height function is a floor, not a ceiling" (specific, within-sprint)

The reflect phase feeds the `docs/solutions/` knowledge base and auto-memory. Interspect feeds the routing overlay and gate rule adjustments. Both are learning loops; they operate at different scales.

### Relationship to iv-rafa (Meta-learning loop)

iv-rafa defines Interspect's meta-learning: modification outcomes become evidence, risk classifications decay based on success/failure. The reflect phase is the *input source* for some of this data. When reflect captures "this approach failed because X," that's a data point Interspect can use to adjust future routing decisions. The two are synergistic: iv-rafa is the machine that processes learning data; the reflect phase is one of the machines that produces it.

## Why This Approach

### 5th macro-stage over folding into Ship

Ship is outward-facing: deliver value to the user/codebase. Reflect is inward-facing: deliver value to the system itself. These are conceptually distinct operations with different goals, different evidence requirements, and different failure modes. Burying reflection inside Ship muddies the semantics and makes it easier to treat as optional.

The 5-stage model also makes the recursive loop visible in the architecture. Anyone reading the lifecycle immediately sees that learning is a first-class step, not an afterthought.

### After polish, before done (not replacing done)

The kernel treats the last phase in a chain as terminal — reaching it sets `status=completed`. If reflect were terminal, completing the reflection would be overloaded with "mark the run complete," and gate enforcement on the terminal phase has subtle interactions with the kernel's completion logic. Keeping `done` as terminal preserves clean kernel semantics: `done` means "the run is finished." `reflect` means "capture what was learned."

### Always required, scaling with complexity

Even trivial work teaches something. A C1 bugfix that notes "this config key is silently ignored when X" prevents hours of debugging later. If reflect were skippable for low-complexity work, agents would learn to classify everything as C1 to avoid the overhead. And the micro-learnings from simple fixes compound the fastest — they're the exact knowledge that's hardest to accumulate any other way.

The gate scales in depth, not presence:
- **C1:** One-liner memory note or auto-memory update suffices
- **C2:** Memory note + brief what-worked/what-didn't assessment
- **C3:** Full solution doc in `docs/solutions/` with YAML frontmatter

### At least one learning artifact (flexible gate)

The gate passes if ANY learning artifact exists for the reflect phase. This means:
- A `docs/solutions/` entry (from `/compound`)
- An auto-memory update (MEMORY.md or topic file)
- A skill or prompt improvement commit
- A complexity calibration note ("estimated C2, actual was C1 because X")

This is flexible enough to avoid blocking trivial work (a one-liner memory note takes 10 seconds) while structured enough to enforce the habit. The kernel just checks "artifact exists with phase=reflect" — the OS defines what qualifies.

## Key Decisions

1. **Macro-stage count:** 5 (Discover, Design, Build, Ship, Reflect). This is a change from the current 4-stage model documented in the glossary.

2. **Phase chain length:** 10 phases (was 8). The chain becomes:
   ```
   brainstorm → brainstorm-reviewed → strategized → planned → executing → review → polish → reflect → done
   ```
   Note: `plan-reviewed` from the bash transition table was already divergent from the intercore DefaultPhaseChain (which doesn't include it). This brainstorm follows the intercore chain as canonical.

3. **Gate rule:** Soft gate initially (advisory), graduating to hard gate after validation. The gate checks for at least one artifact registered with `phase=reflect`. During the validation period, skipping reflect logs a warning but doesn't block completion.

4. **Complexity scaling:** The gate threshold scales with run complexity:
   - C1: Any artifact (even a one-line note registered via `ic run artifact add`)
   - C2: At least one artifact with content hash (non-empty, real content)
   - C3: At least one artifact in `docs/solutions/` path

5. **Skill wiring:** The existing `/compound` command and `engineering-docs` skill become the primary producers of reflect-phase artifacts. A new `/reflect` command (alias or wrapper) is added for discoverability.

6. **Sprint command mapping:** `sprint_next_step()` maps the `reflect` phase to a new `reflect` command, which invokes `/compound` with sprint context.

## Implementation Surface

### Layer 1: Kernel (intercore)

**Changes:**
- Add `PhaseReflect = "reflect"` constant to `internal/phase/phase.go`
- Update `DefaultPhaseChain` to include `reflect` between `polish` and `done` (10 phases)
- Update `internal/phase/phase_test.go` — the valid default chain test case changes from 8 to 10 phases
- Add gate rule for `polish → reflect` transition in `internal/phase/gate.go` gate rules table
- Update `infra/intercore/AGENTS.md` to document the new default chain and reflect phase

**Migration concern:** Existing runs with `phases IS NULL` (using DefaultPhaseChain) will see the new 10-phase chain on next `ic run advance`. Runs currently in `polish` will advance to `reflect` instead of `done`. This is correct behavior — but existing runs that are near completion will encounter an unexpected new phase. Mitigation: runs created before the change keep their explicit phase chain; only new runs use the updated default.

**Actually:** Runs with `phases IS NULL` use `ResolveChain()` which returns `DefaultPhaseChain` at call time. Changing the Go variable changes all NULL-chain runs retroactively. This needs careful handling — either:
  - (a) Migrate all existing NULL-chain runs to have an explicit 8-phase chain before updating `DefaultPhaseChain`, or
  - (b) Accept the behavior change (existing runs get reflect phase) and document it

Option (b) is simpler and arguably correct — if we believe reflect is always required, then existing runs should get it too.

### Layer 2: OS (Clavain)

**Changes:**
- `_sprint_transition_table()` in `lib-sprint.sh`: add `polish → reflect` and `reflect → done` transitions
- `sprint_next_step()`: map `reflect` to a new `reflect` command
- New `/reflect` command (or alias of `/compound` with sprint context injection)
- Gate rules: define what evidence satisfies the reflect gate at each complexity level
- Update skills/commands that reference the phase count or phase list

### Documentation

- `docs/glossary.md`: Update macro-stage definition to 5 stages, add Reflect row
- `docs/interverse-vision.md`: Update references to "four phases" or "four macro-stages"
- `docs/roadmap.md`: Add this feature to the roadmap
- `infra/intercore/AGENTS.md`: Update default chain documentation from 8 to 10 phases
- `hub/clavain/AGENTS.md`: Update sprint lifecycle references

## Risks and Mitigations

| Risk | Severity | Mitigation |
|------|----------|------------|
| Reflect becomes a checkbox exercise (agents generate meaningless notes) | Medium | Gate rule requires content hash on artifact — empty files don't pass. Quality can be validated by Interspect over time. |
| Velocity impact on high-volume work | Low | C1 gate threshold is intentionally minimal. A one-line memory note takes <10 seconds. |
| Existing NULL-chain runs get unexpected reflect phase | Medium | Option (a): migrate existing runs to explicit chains before updating DefaultPhaseChain. |
| Phase count drift between bash transition table and Go DefaultPhaseChain | Low | Both already documented as needing sync. The plan adds `reflect` to both simultaneously. |
| `/compound` skill doesn't produce artifacts registered with `phase=reflect` | Medium | Wire `/compound` output to auto-register via `ic run artifact add --phase=reflect`. |

## What This Enables

1. **Compound knowledge accumulation:** Every sprint produces at least one learning artifact. Over hundreds of sprints, the `docs/solutions/` and auto-memory databases become comprehensive institutional knowledge.

2. **Complexity calibration feedback:** When reflect captures "estimated C2, actual was C1," that data feeds back into future complexity estimates. The system gets better at scoping work.

3. **Interspect training data:** Reflect artifacts are structured learning events that Interspect can correlate with run outcomes. "What did the agent learn?" becomes queryable data.

4. **Skill evolution:** When reflect identifies "the brainstorm skill missed X," that's a concrete improvement opportunity. Skills improve based on evidence, not intuition.

5. **Self-building credibility:** The system that builds itself now also learns from building itself. This is the full recursive loop that the vision document describes.

## Open Questions

1. **Should reflect be skippable via `ic run skip` for emergency hotfixes?** The argument for: sometimes you need to ship NOW. The argument against: hotfixes are exactly when you learn the most. Recommendation: not skippable. Hotfix learnings ("why did this break in prod?") are the highest-value reflections.

2. **Should reflect artifacts be visible in Autarch's Bigend dashboard?** Probably yes — surfacing "what was learned" alongside "what was shipped" makes the learning loop visible to the human operator.

3. **How does this interact with multi-agent sprints?** If multiple agents work on a sprint, each should contribute to reflection. The gate could require N artifacts where N = number of dispatches. Deferred to implementation planning.
