# PRD: Sprint Workflow Resilience & Autonomy
**Bead:** iv-ty1f

## Problem

The Clavain `/sprint` workflow is brittle to session restarts (phase state is ephemeral), over-prompts the user at non-critical phase transitions, and underuses beads for tracking. Users lose context mid-sprint and must manually re-orient, while the system asks "what next?" at every step instead of making smart defaults.

## Solution

Redesign the sprint workflow around three pillars: (1) a sprint bead as the single source of truth for pipeline state; (2) auto-advance between phases, pausing only for genuine decisions; (3) tiered brainstorming that adjusts interaction depth to feature complexity.

## Post-Review Design Revisions

The following changes address findings from architecture and correctness reviews:

1. **Phase child beads eliminated.** Phase beads added noise (6 beads/sprint), state desync risk, and solved no problem that `bd set-state` on the sprint bead doesn't already solve. Phase tracking now lives entirely on the sprint bead's state fields.

2. **Sprint bead = strategy epic.** When `/strategy` runs inside a sprint, it enriches the sprint bead with feature children instead of creating a separate epic. One parent bead tracks both pipeline phase AND feature decomposition.

3. **Sprint-specific logic in lib-sprint.sh (Clavain).** Auto-advance, sprint discovery, and sprint state accessors live in a new Clavain library. Interphase libraries remain generic (no sprint awareness).

4. **State accessor functions.** `sprint_set_artifact()`, `sprint_get_state()` centralize JSON parsing and use filesystem locking to prevent read-modify-write races.

5. **Session claim on resume.** `active_session` state field prevents two sessions from resuming the same sprint.

6. **Phased rollout.** Phase 1: F1+F4+F5 (sprint beads + resume + status). Phase 2: F2 (auto-advance). Phase 3: F3 (tiered brainstorming).

## Sprint Bead Hierarchy (Revised)

```
Sprint Bead (type=epic, sprint=true)
├── Feature Bead: F1 (from /strategy)  ← only children
├── Feature Bead: F2 (from /strategy)
└── Feature Bead: F3 (from /strategy)
```

Phase tracking lives on the sprint bead:
- `sprint=true` — marks this as a sprint bead
- `phase` — current lifecycle phase
- `sprint_artifacts` — JSON: `{"brainstorm": "path", "prd": "path", "plan": "path"}`
- `complexity` — "simple" | "medium" | "complex"
- `auto_advance` — true/false
- `active_session` — session ID claiming this sprint (prevents multi-session races)
- `phase_history` — JSON: `{"brainstorm_at": "ts", "strategized_at": "ts", ...}`

## Features

### Phase 1: Resume & Tracking

#### F1: Sprint Bead Lifecycle

**What:** Create a sprint bead (type=epic, sprint=true) at sprint start with state fields for pipeline tracking. When `/strategy` runs, it adds feature beads as children of the sprint bead rather than creating a separate epic.

**Acceptance criteria:**
- [ ] `/sprint "feature desc"` creates a sprint bead with `bd set-state <id> sprint=true`
- [ ] Sprint bead state includes: `phase`, `sprint_artifacts`, `complexity`, `auto_advance`, `active_session`, `phase_history`
- [ ] `sprint_artifacts` updated as each artifact is created, via `sprint_set_artifact()` with filesystem locking
- [ ] `/sprint` with an existing sprint bead resumes it (reads state, routes to correct phase)
- [ ] `/strategy` inside a sprint adds feature beads to the sprint bead (no separate epic)
- [ ] Session claim: `active_session` prevents concurrent resume (with 60-min TTL)
- [ ] Legacy beads with phase state but no sprint parent get reparented under a new sprint bead (with existing-parent check)
- [ ] Sprint-specific logic lives in `hub/clavain/hooks/lib-sprint.sh` (not interphase)

#### F4: Session-Resilient Resume

**What:** Sprint state lives entirely on beads. SessionStart hook detects active sprints. Any session can resume any sprint with zero user setup.

**Acceptance criteria:**
- [ ] `sprint_find_active()` in lib-sprint.sh queries for in-progress sprint beads (sprint=true state)
- [ ] SessionStart hook injects resume hint: `Active sprint: <id> (phase: X, next: Y)`
- [ ] `/sprint` with no args auto-resumes the single active sprint
- [ ] `/sprint` with multiple active sprints presents AskUserQuestion to choose
- [ ] `/sprint <bead-id>` directly resumes from current phase
- [ ] `sprint_read_state()` reads all sprint state fields in one call
- [ ] Artifact paths read from bead state, not filesystem scan
- [ ] Discovery cache invalidated on every `advance_phase()` call
- [ ] `CLAVAIN_BEAD_ID` set for backward compat but NOT the primary state source

#### F5: Sprint Status Visibility

**What:** Enhanced statusline and sprint-status command showing sprint context and progress.

**Acceptance criteria:**
- [ ] Statusline shows `[sprint: <id> | <phase> → <next>]` when sprint is active
- [ ] `/sprint-status` shows sprint-aware section: sprint bead, feature children, progress
- [ ] Progress bar: `[brainstorm ✓] [strategy ✓] [plan ✓] [execute ▶] [review ○] [ship ○]`
- [ ] Each completed phase shows artifact link and completion timestamp
- [ ] Active session shown if sprint is claimed

### Phase 2: Autonomy

#### F2: Auto-Advance Engine

**What:** Remove phase-transition confirmation prompts. Sprint advances automatically, pausing only for flag-based triggers.

**Acceptance criteria:**
- [ ] Sprint proceeds through all phases without user confirmation
- [ ] Status messages at each transition: `Phase: brainstorm → strategized (auto-advancing)`
- [ ] Pause triggers: design ambiguity (2+ approaches), P0/P1 gate failure, test failure, quality gate findings
- [ ] When paused, AskUserQuestion with options, tradeoffs, and recommendation
- [ ] `bd set-state <sprint> auto_advance=false` pauses at next transition
- [ ] Remove "what next?" prompts from brainstorm.md, strategy.md, and sprint.md
- [ ] Auto-advance uses strict transition table (no skip paths — every phase visited)
- [ ] Auto-advance logic lives in `lib-sprint.sh` (not lib-gates.sh)
- [ ] Pause decisions logged to telemetry

### Phase 3: Intelligence

#### F3: Tiered Brainstorming

**What:** Auto-classify feature complexity and adjust brainstorm depth.

**Acceptance criteria:**
- [ ] Complexity classification based on feature description
- [ ] Simple: research repo → one consolidated AskUserQuestion confirming approach
- [ ] Medium: research repo → 2-3 approaches → one question to choose
- [ ] Complex: full collaborative dialogue
- [ ] Even simple features always get exactly one consolidated question (invariant)
- [ ] `bd set-state <sprint> complexity=complex` overrides auto-classification
- [ ] Classification signals: description length, ambiguity terms, pattern references

## Implementation Architecture

### New: `hub/clavain/hooks/lib-sprint.sh`

Sprint-specific library in Clavain (not interphase). Provides:

- `sprint_create(title)` — creates sprint bead with `sprint=true`, returns ID
- `sprint_find_active()` — finds in-progress sprint beads
- `sprint_read_state(sprint_id)` — reads all state fields at once
- `sprint_set_artifact(sprint_id, type, path)` — locked JSON update
- `sprint_claim(sprint_id, session_id)` — session claim with TTL check
- `sprint_release(sprint_id)` — release session claim
- `sprint_should_pause(sprint_id, phase)` — checks pause triggers (Phase 2)
- `sprint_advance(sprint_id, target_phase)` — auto-advance with strict transitions (Phase 2)
- `sprint_classify_complexity(description)` — complexity classification (Phase 3)

Uses interphase primitives (`phase_set`, `phase_get`, `enforce_gate`, `advance_phase`) for generic phase tracking. Sprint-specific orchestration stays in Clavain.

### Modified: `hub/clavain/commands/sprint.md`

- Top: sprint bead creation/resume (replaces CLAVAIN_BEAD_ID env var logic)
- Discovery: check for active sprint first, then general discovery
- Phase routing: read phase from bead state, route to correct step
- Phase 2: remove "what next?" prompts, add auto-advance
- Phase 3: add complexity classification before brainstorm

### Modified: `hub/clavain/commands/strategy.md`

- If inside a sprint: add feature beads to sprint bead (no separate epic)
- If standalone: create epic as before (backward compat)
- Remove Phase 5 "what next?" prompt (Phase 2)

### Modified: `hub/clavain/commands/brainstorm.md`

- Phase 3: add complexity tier routing
- Remove Phase 4 "what next?" prompt (Phase 2)

### Modified: `hooks/session-start.sh`

- Call `sprint_find_active()` and inject resume hint

## Non-goals

- **Phase child beads:** Eliminated per architecture review. Phase tracking via `bd set-state` on sprint bead.
- **Separate strategy epic:** Sprint bead IS the epic. `/strategy` enriches it.
- **Sprint templates:** No pre-built sprint configurations
- **Sprint metrics/velocity:** No burndown charts (defer to future)
- **Multi-user sprints:** No concurrent users on the same sprint bead
- **Interphase sprint awareness:** Interphase stays generic. Sprint logic in Clavain only.

## Correctness Safeguards

Per correctness review findings:

1. **Atomic initialization:** `sprint_initialized=true` set only after all setup completes. Discovery skips beads where `sprint_initialized != true`.
2. **Locked JSON updates:** `sprint_set_artifact()` uses `mkdir` lock (`/tmp/sprint-lock-$id`) for read-modify-write serialization.
3. **Session claim:** `active_session` with 60-min TTL prevents concurrent resume. `sprint_claim()` does write-then-verify.
4. **Reparenting safety:** Check for existing sprint parent before reparenting. Reject if parent already exists.
5. **Desync auto-repair:** On read, if bead phase != artifact header phase, rewrite artifact header to match bead (bead is authoritative).
6. **Discovery cache invalidation:** `advance_phase()` deletes `/tmp/clavain-discovery-brief-*.cache`.
7. **Idempotent transitions:** `advance_phase()` checks current == target before writing.

## Resolved Questions

1. **Sprint bead priority:** P2 default, user can override.
2. **Auto-close behavior:** Auto-close sprint bead when ship phase completes, with telemetry log.
3. **Phase beads:** Eliminated. All phase state on sprint bead.
4. **Strategy epic overlap:** Sprint bead IS the epic. `/strategy` enriches it.
5. **Auto-advance library placement:** In `lib-sprint.sh` (Clavain), not `lib-gates.sh` (interphase).
