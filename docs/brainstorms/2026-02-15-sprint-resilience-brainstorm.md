# Sprint Workflow Resilience & Autonomy Redesign
**Bead:** iv-ty1f

## What We're Building

A unified redesign of the Clavain `/sprint` workflow addressing three interconnected problems: **session continuity** (losing track of phase across restarts), **excessive user prompting** (asking for confirmation at every phase transition), and **shallow beads integration** (no sprint-level tracking, ephemeral state). The solution centers on making beads the single source of truth for sprint state, with a parent-child bead hierarchy, tiered autonomy, and auto-resume on session start.

## Why This Approach

### Problem Analysis

1. **Session continuity is fragile.** `CLAVAIN_BEAD_ID` is set during discovery but exists only as an in-memory variable. If a session restarts mid-sprint (context exhaustion, network drop, user closes terminal), the bead context is lost. The SessionStart hook doesn't restore it. Discovery rescans from scratch and may recommend a different ordering.

2. **Too many prompts at non-critical moments.** The brainstorm, strategy, plan, and execute phases each end with "What next?" questions. For a user running a full sprint, these are friction — they know the pipeline. The system should auto-advance and only pause when it genuinely needs human judgment (design ambiguity, gate failures, blocking issues).

3. **Beads integration is surface-level.** Phase state is stored on beads via `bd set-state`, but there's no concept of a "sprint" as a tracked unit of work. Artifacts (brainstorm, PRD, plan) are linked to individual beads but not to each other. When `/strategy` creates feature beads, they aren't structurally connected to the brainstorm or plan that spawned them.

### Design Principles

- **Beads are the source of truth** — no env vars, no temp files, no HANDOFF.md parsing
- **Auto-advance by default, pause on flags** — only interrupt for genuine decisions
- **Tiered brainstorming** — complexity determines interaction depth
- **Parent-child hierarchy** — sprint bead is the umbrella, phase artifacts are children
- **Session-resilient** — any session can resume any sprint with zero user setup

## Key Decisions

### 1. Sprint Bead Hierarchy

**Decision:** Every `/sprint` invocation creates (or resumes) a parent sprint bead. Phase artifacts become child beads linked via `bd dep`.

**Structure:**
```
Sprint Bead (type=sprint, P2)
├── Brainstorm Bead (type=task) — links to brainstorm doc
├── Strategy Bead (type=task) — links to PRD
├── Plan Bead (type=task) — links to plan doc
├── Execute Bead (type=task) — represents implementation work
│   └── Feature Beads (from /strategy) — individual features
├── Review Bead (type=task) — quality gates + resolution
└── Ship Bead (type=task) — landing + commit
```

**Sprint bead state fields** (via `bd set-state`):
- `phase` — current lifecycle phase (brainstorm, strategized, planned, etc.)
- `sprint_artifacts` — JSON: `{"brainstorm": "path", "prd": "path", "plan": "path"}`
- `child_beads` — JSON array of child bead IDs
- `complexity` — "simple" | "medium" | "complex" (set during brainstorm triage)
- `auto_advance` — true/false (can be toggled by user)

**Lifecycle:** Sprint bead auto-closes when all children close (or when the ship phase completes). Child beads are created on-demand as each phase starts, not all upfront.

### 2. Autonomy Model: Auto-Advance with Flag-Based Pauses

**Decision:** Sprint runs end-to-end without confirmation prompts. It pauses ONLY when:

| Pause Trigger | What Happens |
|---|---|
| **Design ambiguity** | 2+ valid approaches found during brainstorm/strategy. AskUserQuestion with options, tradeoffs, and recommendation. |
| **Gate failure** | P0/P1 phase gate blocked. Show what's blocked and why, offer override or fix options. |
| **Quality gate findings** | Blocking issues found by review agents. Show summary, offer fix or skip. |
| **User-set breakpoint** | `bd set-state <sprint> auto_advance=false` pauses at next transition. |
| **Test failure** | Build/test suite fails. Show error, offer fix or investigate. |

**What's removed:** "Brainstorm captured, what next?", "Plan written, proceed?", "Ready to execute?", and all other phase-transition confirmations. These become autonomous with a brief status message: `Phase: brainstorm → strategized (auto-advancing)`.

### 3. Tiered Brainstorming

**Decision:** Sprint auto-classifies feature complexity and adjusts brainstorm depth:

| Tier | Criteria | Brainstorm Behavior |
|---|---|---|
| **Simple** | Clear description, single obvious approach, <100 words, references existing patterns | Research repo → present ONE consolidated AskUserQuestion confirming approach + any edge cases → write brainstorm doc |
| **Medium** | Moderate description, 2-3 possible approaches | Research repo → present 2-3 approaches with tradeoffs → ONE question to choose → write brainstorm doc |
| **Complex** | Vague/ambitious description, many unknowns, cross-cutting concerns | Full collaborative dialogue (current behavior) — multiple questions, incremental design, approach exploration |

**Key invariant:** Even simple features always get one consolidated question. The question includes:
1. Proposed approach with brief rationale
2. Key assumptions being made
3. Option to escalate to full brainstorm if user disagrees

**Classification signals:**
- Description length and specificity
- Number of ambiguous terms ("maybe", "or", "could")
- Whether existing patterns are referenced
- Whether the change is additive (new feature) vs. structural (refactor)
- `bd set-state` can override: `complexity=complex` forces full brainstorm

### 4. Session Continuity via Bead-First Resume

**Decision:** Sprint state lives entirely on the sprint bead. Sessions restore state from beads, not env vars.

**How it works:**

1. **SessionStart hook** runs `discovery_brief_scan()` (already exists). Enhanced to check for in-progress sprint beads and inject a resume hint into `additionalContext`:
   ```
   Active sprint: Interverse-abc (phase: plan-reviewed, next: execute)
   Resume with /sprint or /sprint Interverse-abc
   ```

2. **`/sprint` with no args** checks for active sprint beads first (before general discovery):
   - Query: `bd list --status=in_progress --json` → filter for `type=sprint`
   - If exactly one: auto-resume it (set `CLAVAIN_BEAD_ID`, read phase, route to next step)
   - If multiple: AskUserQuestion to choose which sprint to resume
   - If none: fall through to general discovery (existing behavior)

3. **`/sprint <bead-id>`** directly resumes that sprint bead:
   - Read all state: phase, artifacts, child beads, complexity
   - Route to the correct step based on phase
   - No re-scanning, no re-discovery

4. **Phase reads from bead, not memory:**
   - `advance_phase()` already writes to bead via `bd set-state`
   - Every step reads its prerequisites from the bead's `sprint_artifacts` state
   - If an artifact path is in the state, skip re-scanning `docs/` for it

**Eliminated dependencies:**
- No more `CLAVAIN_BEAD_ID` env var as primary state (still set for backward compat, but read from bead)
- No HANDOFF.md for sprint state (can still exist for general session handoff)
- No temp files in `/tmp/` for sprint tracking

### 5. Sprint Status Visibility

**Decision:** Enhance the statusline and sprint-status to show sprint context clearly.

- **Statusline** (interline): Show `[sprint: Interverse-abc | plan-reviewed → executing]` when a sprint is active
- **`/sprint-status`**: Add sprint-aware section showing:
  - Active sprint bead and its children
  - Phase progress bar: `[brainstorm ✓] [strategy ✓] [plan ✓] [review ✓] [execute ▶] [ship ○]`
  - Artifact links for each completed phase
  - Time in current phase
  - Any blocked children

## Implementation Scope

### Changes to interphase (libraries)

1. **lib-discovery.sh:**
   - Add `discovery_find_active_sprint()` — returns the in-progress sprint bead (if any)
   - Modify `discovery_scan_beads()` to prioritize sprint beads over loose beads
   - Add sprint-type filtering to `infer_bead_action()`

2. **lib-phase.sh:**
   - Add `phase_read_sprint_state()` — reads all sprint state fields at once
   - Add `phase_write_sprint_state()` — atomic write of sprint artifacts/children
   - Add `phase_create_child_bead()` — creates child bead and links to sprint parent

3. **lib-gates.sh:**
   - Add auto-advance logic: `gate_should_pause()` checks pause triggers
   - Modify `enforce_gate()` to emit status messages instead of blocking on soft gates

### Changes to Clavain (commands/skills)

1. **commands/sprint.md:** Major rewrite:
   - Sprint bead creation/resume at top
   - Auto-advance between steps (remove "what next?" prompts)
   - Tiered brainstorm classification
   - Phase routing from bead state (not filesystem scan)

2. **commands/brainstorm.md:**
   - Add complexity classification logic
   - Tiered behavior (simple/medium/complex)
   - Always-one-question invariant for simple features

3. **hooks/session-start.sh:**
   - Inject sprint resume hint when active sprint bead found
   - Use `discovery_find_active_sprint()` for fast check

4. **skills/brainstorming/SKILL.md:**
   - Add tiered brainstorm guidelines
   - Update question patterns for consolidated approach

## Resolved Questions

1. **Child bead granularity:** All phases get child beads. Every phase (brainstorm, strategy, plan, execute, review, ship) gets a dedicated child bead under the sprint parent. This provides full granular tracking and makes the sprint bead a comprehensive record of the entire workflow.

2. **Backward compatibility:** Create parent and reparent. When `/sprint` encounters an existing in-progress bead with phase state but no sprint parent, it creates a new sprint bead and reparents the existing bead underneath via `bd dep add`. This maintains a clean hierarchy going forward while preserving existing work.

## Open Questions

1. **Multi-sprint support:** Can a user have multiple active sprints? The auto-resume logic assumes one, but power users might interleave. If yes, discovery needs a sprint selector. **Recommendation:** Support multiple, present AskUserQuestion when >1 active sprint found.

2. **Sprint bead type:** Should we add a `sprint` type to beads, or use `type=epic` with a `sprint=true` state flag? Adding a type requires beads CLI changes. **Recommendation:** Use `type=epic` with `bd set-state <id> sprint=true` — avoids beads CLI changes and `epic` semantically fits (parent of multiple tasks).
