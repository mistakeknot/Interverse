# Architecture Review: Sprint Workflow Resilience & Autonomy

**PRD:** docs/prds/2026-02-15-sprint-resilience.md
**Bead:** iv-ty1f
**Reviewed:** 2026-02-15
**Reviewer:** Architecture & Design (Flux-drive)

## Executive Summary

This PRD proposes a significant restructuring of the Clavain sprint workflow around three pillars: (1) sprint beads with parent-child hierarchy, (2) auto-advance between phases, and (3) tiered brainstorming. The architecture introduces **five major structural issues** that create hidden coupling, management overhead, and state consistency risks.

**Critical findings:**
1. **JSON blob coupling** — sprint state fields create implicit schema contracts between callers
2. **6-child bead overhead** — phase beads add management complexity without clear value
3. **Shim boundary misalignment** — delegation to interphase creates ownership confusion
4. **Auto-advance engine placement** — belongs in new library, not lib-gates.sh
5. **Distributed state consistency** — sprint state read/written across multiple libraries with no coordination

**Recommendation:** Major architectural revision required before implementation. Current design trades session resilience for long-term maintainability debt.

---

## 1. Boundaries & Coupling

### Problem 1.1: JSON Blob Coupling (Implicit Schema Contracts)

**Finding:** The PRD proposes storing sprint metadata via `bd set-state`:
```bash
bd set-state <sprint-id> sprint_artifacts='{"brainstorm": "path", "prd": "path", "plan": "path"}'
bd set-state <sprint-id> child_beads='["id1", "id2", "id3", "id4", "id5", "id6"]'
bd set-state <sprint-id> complexity='simple'
bd set-state <sprint-id> auto_advance='true'
```

**Coupling mechanism:**
- **Every caller** must know the JSON structure of `sprint_artifacts` and `child_beads`
- No schema validation — typos or structure changes silently break readers
- Schema lives in heads/documentation, not code — drift inevitable
- Parsers scattered across: sprint.md, sprint-status.md, session-start.sh, lib-discovery.sh, lib-gates.sh

**Example failure scenario:**
```bash
# Writer (sprint.md) changes schema from:
sprint_artifacts='{"brainstorm": "path"}'
# to:
sprint_artifacts='{"artifacts": [{"type": "brainstorm", "path": "..."}]}'

# Reader (sprint-status.md) continues using old schema:
bd state <id> sprint_artifacts | jq '.brainstorm'  # null (silent failure)
```

**Blast radius:**
- Changing artifact schema requires coordinated updates to 5+ files across 2 plugins
- No compile-time checks — failures emerge at runtime in unrelated sessions
- Debugging requires tracing JSON structure assumptions across bash/jq fragments

**Architectural violation:** This is a **leaky abstraction**. Beads (`bd`) is a generic issue tracker — it shouldn't be burdened with sprint-specific schema knowledge. The sprint workflow is imposing domain logic onto infrastructure via untyped JSON blobs.

**Better boundary:**
- Sprint state belongs in sprint-domain code (Clavain plugin)
- Beads should store opaque references (e.g., `sprint_state_file=/tmp/clavain-sprint-<id>.json`)
- Sprint libraries own their state format

**Recommendation:** Use a state file pattern:
```bash
bd set-state <id> sprint_state_file='/tmp/clavain-sprint-<id>.json'
# All sprint-specific state lives in that file, owned by sprint libraries
# Single source of truth, schema versioning possible, clear ownership
```

---

### Problem 1.2: Shim Boundary Misalignment (Clavain → interphase Delegation)

**Current architecture:**

Clavain hooks/ are bash shims that delegate to interphase:
```bash
# hub/clavain/hooks/lib-gates.sh (shim)
_BEADS_ROOT=$(_discover_beads_plugin)
if [[ -n "$_BEADS_ROOT" && -f "${_BEADS_ROOT}/hooks/lib-gates.sh" ]]; then
    source "${_BEADS_ROOT}/hooks/lib-gates.sh"  # Delegate to interphase
fi
```

**Intended boundary:**
- **interphase** owns phase/gate/discovery logic (reusable primitives)
- **Clavain** orchestrates workflow (sprint-specific coordination)

**Finding:** The PRD adds sprint-specific logic without clarifying where it lives:

**F1: Sprint Bead Lifecycle**
- "Sprint bead state includes: `sprint_artifacts`, `child_beads`, `complexity`, `auto_advance`"
- Where does this schema live? Interphase (generic) or Clavain (sprint-specific)?

**F2: Auto-Advance Engine**
- "Sprint proceeds from brainstorm → strategy → plan → review → execute → test → quality-gates → resolve → ship"
- This is **sprint workflow knowledge**, not a generic phase primitive

**F4: Session-Resilient Resume**
- "`discovery_find_active_sprint()` in lib-discovery.sh queries for in-progress sprint beads"
- Interphase lib-discovery.sh currently has no sprint awareness — it scans generic beads

**Ownership collision:**

If sprint logic moves into interphase libraries:
- **Coupling:** interphase becomes aware of Clavain's sprint model
- **Portability broken:** Other consumers of interphase (future plugins) inherit sprint assumptions
- **Circular dependency risk:** Clavain depends on interphase, interphase knows Clavain's sprint schema

If sprint logic stays in Clavain:
- **Duplication:** Clavain reimplements discovery_scan_beads with sprint filtering
- **Coordination overhead:** Two discovery scanners (generic in interphase, sprint-specific in Clavain)
- **Shim purpose unclear:** Why delegate to interphase if Clavain needs custom logic anyway?

**Recommendation:**

**interphase libraries remain generic:**
- No sprint awareness
- Continue providing: phase_set, phase_get, discovery_scan_beads, enforce_gate

**Clavain adds sprint-specific libraries:**
- `hub/clavain/hooks/lib-sprint.sh` — sprint CRUD, resume, auto-advance
- `hub/clavain/hooks/lib-sprint-discovery.sh` — sprint-aware discovery (wraps interphase discovery_scan_beads)

**Benefits:**
- Clear ownership: sprint logic lives in Clavain
- Interphase remains reusable by other plugins
- Shim boundary preserved: Clavain uses interphase primitives, doesn't extend them

---

### Problem 1.3: Auto-Advance Engine Placement (Wrong Library)

**Finding:** The PRD proposes adding auto-advance logic but doesn't specify where it lives. By implication (F2 mentions "lib-gates.sh"), it would go in the gates library.

**Why this is wrong:**

1. **lib-gates.sh is a validation library, not an orchestrator**
   - Current responsibility: Check if phase transitions are valid
   - Proposed responsibility: Drive phase transitions
   - This violates single responsibility principle

2. **Auto-advance is workflow policy, not gate validation**
   - Gates ask: "Is this transition allowed?"
   - Auto-advance decides: "Should we transition now?"
   - These are distinct concerns

3. **lib-gates.sh has no sprint awareness**
   - It validates generic phase transitions (brainstorm → strategy)
   - Sprint auto-advance needs sprint-specific context (pause triggers, complexity tier)

**Blast radius:** If auto-advance goes in lib-gates.sh:
- **Every gate check** becomes a potential auto-advance trigger
- **Coupling:** Gate validation can't run without auto-advance logic
- **Testing complexity:** Can't test gates in isolation
- **Interphase portability broken:** Other plugins using lib-gates.sh inherit sprint auto-advance behavior

**Correct placement:** Auto-advance is **sprint orchestration**, which is Clavain-specific. It belongs in:

```bash
# hub/clavain/hooks/lib-sprint.sh (new library)
sprint_auto_advance() {
    local sprint_id="$1"

    # Read sprint state (phase, complexity, auto_advance flag)
    local current_phase=$(phase_get "$sprint_id")
    local auto_enabled=$(bd state "$sprint_id" auto_advance)

    # Check pause triggers (sprint-specific policy)
    if _sprint_should_pause "$sprint_id" "$current_phase"; then
        return 0  # Stay in current phase
    fi

    # Determine next phase (sprint-specific sequence)
    local next_phase=$(_sprint_next_phase "$current_phase")

    # Validate transition (delegates to interphase lib-gates.sh)
    if enforce_gate "$sprint_id" "$next_phase" ""; then
        advance_phase "$sprint_id" "$next_phase" "auto-advance" ""
    fi
}
```

**Benefits:**
- Clear ownership: sprint policy in Clavain, validation in interphase
- lib-gates.sh remains reusable
- Auto-advance can evolve independently of gate validation

---

## 2. Pattern Analysis

### Problem 2.1: Six-Child Bead Overhead (Management vs. Value)

**Finding:** The PRD proposes creating 6 child beads per sprint — one for each phase:
1. Brainstorm phase bead
2. Strategy phase bead
3. Plan phase bead
4. Execute phase bead
5. Review phase bead
6. Ship phase bead

**Claimed benefit:** "Each phase creates a child bead linked via `bd dep add`"

**Actual cost:**
- **6x bead churn** — `bd create`, `bd dep add`, `bd close` for each phase
- **Noise in backlog** — `bd list` shows 7 items (1 sprint + 6 phases) for a single feature
- **Dependency graph clutter** — `bd show <sprint-id>` displays 6 blockers/dependencies
- **State desync risk** — Phase bead status must stay in sync with sprint parent phase field

**YAGNI check:** What breaks if we **remove** phase beads entirely?

**Breaks:**
- Nothing in sprint workflow (phases tracked via `bd set-state <sprint> phase=...`)
- Nothing in discovery (uses sprint parent bead + phase field)
- Nothing in statusline (reads phase from sprint parent)

**Still works:**
- Sprint resume (reads phase from parent bead)
- Progress tracking (reads `sprint_artifacts` + phase)
- Auto-advance (reads/writes phase on parent bead)

**Conclusion:** Phase beads are **accidental complexity**. They solve no current problem and create management overhead.

**Ownership confusion:** Who owns phase beads? They're created by sprint.md but their lifecycle is unclear:

**Scenario 1: User manually closes a phase bead**
```bash
bd close brainstorm-phase-bead-id
```
What happens to the sprint? Does auto-advance skip the phase? Does the sprint get stuck?

**Scenario 2: Sprint is resumed after phase bead is deleted**
```bash
bd delete plan-phase-bead-id  # User cleanup
/sprint  # Resume
# Discovery scanner reads child_beads='["...", "<deleted-id>", "..."]'
# bd show <deleted-id> fails
# Resume logic breaks
```

**Recommendation:** Eliminate phase beads. Store phase metadata directly on the sprint bead:
```bash
bd set-state <sprint> phase=strategized
bd set-state <sprint> phase.brainstorm.completed_at='2026-02-15T10:30:00Z'
bd set-state <sprint> phase.strategy.completed_at='2026-02-15T11:45:00Z'
```

---

### Problem 2.2: State Management Pattern Risks (Triple Persistence)

**Current pattern** (Dual Persistence):

The existing architecture uses **dual persistence** for phase state:
1. **Primary:** `bd set-state <id> phase=<value>` (beads database)
2. **Secondary:** `**Phase:** <value>` header in artifact files (markdown)

**Proposed pattern** (Triple Persistence):

The PRD adds a **third persistence layer**:
1. **Bead state:** `bd set-state <sprint> phase=...`, `sprint_artifacts=...`, `child_beads=...`
2. **Artifact headers:** `**Phase:** ...` in brainstorm/plan files
3. **Child bead state:** `bd set-state <phase-bead> phase=...`

**New failure modes:**

**Desync scenario: Sprint phase != phase bead phase**
```bash
bd set-state <sprint> phase=executing
bd set-state <execute-phase-bead> phase=shipping  # User manually updated child
# Which is authoritative?
```

**Complexity explosion:** With triple persistence, every state update requires **3 writes**:
```bash
advance_phase() {
    # Write 1: Sprint bead phase
    bd set-state "$sprint_id" phase="$target"

    # Write 2: Artifact header (if applicable)
    _gate_write_artifact_phase "$artifact_path" "$target"

    # Write 3: Phase bead (proposed in PRD)
    local phase_bead=$(echo "$child_beads" | jq -r '.[] | select(.type == "phase-execute")')
    bd set-state "$phase_bead" phase="$target"
}
```

**Any write failure → partial update → desync.**

**Recommendation:** Eliminate triple persistence:
- Keep beads state as primary (existing)
- Keep artifact headers as fallback (existing)
- **Remove phase beads** (per Section 2.1)

---

## 3. Simplicity & YAGNI

### Problem 3.1: Distributed State Consistency (Read/Write Coordination)

**Finding:** Sprint state is read and written from **multiple libraries** with no coordination:

**Writers:**
- `commands/sprint.md` — sets `sprint_artifacts`, `child_beads`, `phase`
- `commands/brainstorm.md` — updates `sprint_artifacts.brainstorm`
- `commands/strategy.md` — updates `sprint_artifacts.prd`, `child_beads`
- `commands/write-plan.md` — updates `sprint_artifacts.plan`
- `hooks/lib-gates.sh::advance_phase()` — updates `phase`
- `hooks/lib-sprint.sh::sprint_auto_advance()` — updates `phase`, `auto_advance`

**Readers:**
- `commands/sprint-status.md` — reads all sprint state
- `hooks/session-start.sh` — reads `phase`, `sprint_artifacts`
- `hooks/lib-discovery.sh::discovery_find_active_sprint()` — reads `phase`
- `commands/sprint.md` (resume path) — reads all sprint state

**JSON Merge Conflicts:**

**Scenario: Two commands update different artifacts in parallel**
```bash
# Command A: Updates brainstorm artifact
current=$(bd state <sprint> sprint_artifacts)
updated=$(echo "$current" | jq '.brainstorm = "new-path"')
bd set-state <sprint> sprint_artifacts="$updated"

# Command B: Updates PRD artifact (reads stale state)
current=$(bd state <sprint> sprint_artifacts)  # Doesn't see A's update
updated=$(echo "$current" | jq '.prd = "new-path"')
bd set-state <sprint> sprint_artifacts="$updated"  # Overwrites A's change
```

Result: Brainstorm path is lost.

**Root cause:**

**No atomic read-modify-write primitive in `bd set-state`:**
- Each `bd state <id> <key>` is a separate read
- Each `bd set-state <id> <key>=<value>` is a separate write
- No transaction support across multiple keys

**Recommendation:** Add state accessor library with locking:

```bash
# lib-sprint.sh provides atomic accessors:
sprint_set_artifact() {
    local sprint_id="$1" type="$2" path="$3"
    # Read current, merge, write atomically
    local lock="/tmp/sprint-${sprint_id}.lock"
    (
        flock -x 200
        current=$(bd state "$sprint_id" sprint_artifacts)
        updated=$(echo "$current" | jq --arg type "$type" --arg path "$path" '.[$type] = $path')
        bd set-state "$sprint_id" sprint_artifacts="$updated"
    ) 200>"$lock"
}
```

---

### Problem 3.2: Missing Failure Modes & Edge Cases

**Failure Mode 1: Sprint Bead Deleted Mid-Session**

**Scenario:**
```bash
# Session 1: User starts sprint
/sprint "new feature"
sprint_id="Foo-abc123"

# Session 2: User cleans backlog
bd delete Foo-abc123

# Session 1: Auto-advance tries to update
bd set-state Foo-abc123 phase=executing  # Error: bead not found
```

**PRD doesn't specify:** How does auto-advance handle deleted sprint beads?

**Recommendation:** Auto-advance should validate sprint bead exists before updating. If deleted, emit error and stop.

**Failure Mode 2: Sprint Resume After Artifact Deletion**

**Scenario:**
```bash
# Sprint has sprint_artifacts='{"plan": "docs/plans/2026-02-15-feature.md"}'
# User deletes the plan file
rm docs/plans/2026-02-15-feature.md

# New session
/sprint  # Resumes sprint
# Auto-advance tries to read plan path from sprint_artifacts
# File doesn't exist
```

**Recommendation:** Add artifact validation to sprint_resume():
```bash
sprint_resume() {
    local sprint_id="$1"
    local artifacts=$(bd state "$sprint_id" sprint_artifacts)

    # Validate each artifact exists
    echo "$artifacts" | jq -r '.[]' | while read path; do
        if [[ ! -f "$path" ]]; then
            echo "WARNING: Sprint artifact missing: $path" >&2
        fi
    done
}
```

---

### Problem 3.3: Complexity vs. Value Analysis

**Feature cost estimation:**

| Feature | LOC (est.) | Modules Touched | Risk |
|---------|-----------|----------------|------|
| F1: Sprint Bead Lifecycle | 150 | sprint.md, lib-sprint.sh, discovery | Medium |
| F2: Auto-Advance Engine | 200 | lib-sprint.sh, all phase commands | High |
| F3: Tiered Brainstorming | 100 | brainstorm.md, lib-sprint.sh | Low |
| F4: Session-Resilient Resume | 80 | session-start.sh, sprint.md | Low |
| F5: Sprint Status Visibility | 60 | sprint-status.md, statusline | Low |

**Total:** ~590 LOC across 2 plugins, 8 files

**User-facing value:**

**Current pain points (from PRD):**
1. "Phase state is ephemeral" — Users lose context mid-sprint
2. "Over-prompts at non-critical phase transitions" — Friction slows velocity
3. "Underuses beads for tracking" — Manual re-orientation required

**Proposed value:**
1. Sprint resume from any session (F4)
2. Fewer confirmation prompts (F2)
3. Sprint progress visibility (F5)

**Value-to-complexity ratio:**
- F4 (resume) is **high value, low complexity** — should ship first
- F2 (auto-advance) is **medium value, high complexity** — risky investment
- F3 (tiered brainstorming) is **low value, low complexity** — nice-to-have

**Recommendation:** Phased rollout:

**Phase 1: Resume without auto-advance**
- F1 (sprint beads, simplified: no phase children)
- F4 (session-resilient resume)
- F5 (sprint status visibility)
- Result: Users can resume sprints, manual phase transitions remain

**Phase 2: Auto-advance (after validating Phase 1 in production)**
- F2 (auto-advance engine)
- Result: Fewer prompts, smoother flow

**Phase 3: Optimizations**
- F3 (tiered brainstorming)

---

## 4. Alternate Design: Simplified Sprint Model

### Core Idea

Rather than modeling sprints as **beads with complex state**, model them as **artifact collections with phase tracking**.

**State file format:**
```json
{
  "id": "Foo-abc123",
  "title": "Feature: reservation negotiation",
  "phase": "executing",
  "started_at": "2026-02-15T10:00:00Z",
  "artifacts": {
    "brainstorm": "docs/brainstorms/2026-02-15-reservation.md",
    "prd": "docs/prds/2026-02-15-reservation.md",
    "plan": "docs/plans/2026-02-15-reservation.md"
  },
  "auto_advance": true,
  "complexity": "medium"
}
```

**Sprint commands:**
```bash
# Start: Write state file
sprint_start() {
    echo '{"id": "...", "phase": "brainstorm", ...}' > /tmp/clavain-sprint-active.json
}

# Resume: Read state file
sprint_resume() {
    if [[ -f /tmp/clavain-sprint-active.json ]]; then
        sprint_id=$(jq -r '.id' /tmp/clavain-sprint-active.json)
        phase=$(jq -r '.phase' /tmp/clavain-sprint-active.json)
        # Route based on phase
    fi
}

# Advance: Update state file
sprint_advance() {
    jq '.phase = "executing"' /tmp/clavain-sprint-active.json > tmp && mv tmp /tmp/clavain-sprint-active.json
}
```

**Pros:**
- **Single source of truth** — no bead/artifact/child desync
- **Atomic updates** — file write is atomic
- **No bd dependency** — sprint works even if beads CLI is broken
- **Schema versioning** — add `.schema_version` field, migrate on load
- **Simpler resume** — check if file exists

**Cons:**
- **Single sprint limit** — can't have multiple sprints in progress
- **No backlog visibility** — sprints not in `bd list` output
- **Session-local state** — `/tmp` cleared on reboot (could use `~/.clavain/sprint-active.json` instead)

### Hybrid Approach

Keep beads for **feature tracking**, use state file for **sprint orchestration**:

```bash
# Feature bead exists (from strategy.md)
bd create --title="Feature: reservation" --type=feature --priority=2
feature_id="Foo-abc123"

# Sprint state file references the feature bead
{
  "feature_bead_id": "Foo-abc123",
  "phase": "executing",
  "artifacts": {...}
}
```

**Best of both worlds:**
- Feature tracked in beads (shows in backlog, prioritized, etc.)
- Sprint coordination via state file (atomic, versioned, resilient)
- No phase children (eliminate overhead)

**Recommendation:** Prototype hybrid approach before committing to full bead-based design.

---

## 5. Recommendations by Priority

### P0: Fix Before Implementation

1. **Eliminate phase beads** (Section 2.1)
   - Remove F1's child_beads creation
   - Store phase completion timestamps directly on sprint bead
   - Saves ~100 LOC, reduces state desync risk

2. **Create lib-sprint.sh library** (Section 1.2)
   - Extract sprint-specific logic from PRD
   - Keep interphase libraries generic
   - Clear ownership boundary

3. **Add state accessor functions** (Section 3.1)
   - `sprint_set_artifact()`, `sprint_get_artifact()`
   - Centralize JSON parsing/merging
   - Reduce read-modify-write races

4. **Specify failure handling** (Section 3.2)
   - Deleted sprint beads → error and stop
   - Missing artifacts → warn and skip
   - Stale sprint detection → 48h for active phases, 7d for planning

### P1: Address During Implementation

5. **Move auto-advance to lib-sprint.sh** (Section 1.3)
   - Don't extend lib-gates.sh
   - Keep validation and orchestration separate

6. **Add artifact validation to resume** (Section 3.2)
   - Check files exist before routing
   - Graceful degradation for missing artifacts

7. **Phase rollout** (Section 3.3)
   - Ship F1+F4+F5 first (resume without auto-advance)
   - Validate in production before adding F2

### P2: Future Enhancements

8. **State file migration** (Section 1.1)
   - Replace JSON blobs with state file reference
   - Enables schema versioning, atomic updates

9. **Staleness metrics** (Section 3.2)
   - Track sprint idle time
   - Auto-suggest archival for stale sprints

---

## Summary of Architectural Issues

| # | Issue | Severity | Mitigation Complexity |
|---|-------|----------|----------------------|
| 1 | JSON blob coupling | High | Medium (state accessors) |
| 2 | 6-child bead overhead | Medium | Low (delete feature) |
| 3 | Shim boundary misalignment | High | Medium (new library) |
| 4 | Auto-advance placement | Medium | Low (move to lib-sprint.sh) |
| 5 | Distributed state consistency | High | High (locking + accessors) |
| 6 | Triple persistence | Medium | Low (remove phase beads) |
| 7 | Missing failure modes | Medium | Medium (add validation) |
| 8 | Complexity vs. value | Low | Low (phase rollout) |

**Total technical debt if shipped as-is:** ~8 person-days of rework to fix state consistency bugs, boundary violations, and accidental complexity.

**Recommended approach:** Major revision per Sections 1-5 before implementation.
