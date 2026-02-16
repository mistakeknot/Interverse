# Clavain Workflow Structure & Trace Event Emission Points

**Analysis Date:** 2026-02-14  
**Purpose:** Map the full lifecycle pipeline to identify where trace events should be emitted

---

## Executive Summary

The Clavain workflow implements a **9-phase trunk-based development pipeline** with phase tracking, gate validation, and multi-agent orchestration. Trace events should be emitted at **23 critical decision points** across the lifecycle, from initial work discovery through final shipment.

**Key findings:**
1. Phase tracking infrastructure exists via **interphase plugin** (`lib-gates.sh`, `lib-phase.sh`)
2. Commands delegate to skills that invoke subagents — 3-layer orchestration hierarchy
3. flux-drive review architecture supports both staged dispatch and research escalation
4. No existing trace instrumentation — clean integration opportunity

---

## Full Lifecycle Pipeline

```
┌─────────────────────────────────────────────────────────────────────┐
│                    CLAVAIN LIFECYCLE PIPELINE                        │
└─────────────────────────────────────────────────────────────────────┘

┌──────────────┐
│   DISCOVERY  │ ← Work discovery scanner (sprint-scan.sh)
└──────┬───────┘
       │ (optional — if no args to /sprint)
       ├─ discovery_scan_beads() → JSON output
       ├─ User selection → infer_bead_action()
       └─ Route to appropriate phase entry point
       │
       ▼
┌──────────────┐
│  BRAINSTORM  │ ← /clavain:brainstorm (commands/brainstorm.md)
└──────┬───────┘
       │ Uses: brainstorming skill
       ├─ Phase 0: Assess clarity
       ├─ Phase 1: Repo research (repo-research-analyst agent)
       ├─ Phase 2: Collaborative dialogue (AskUserQuestion loop)
       ├─ Phase 3: Explore approaches
       └─ Phase 4: Write brainstorm doc → advance_phase("brainstorm")
       │
       ▼
┌──────────────┐
│  STRATEGIZE  │ ← /clavain:strategy (commands/strategy.md)
└──────┬───────┘
       │ Structures brainstorm → PRD
       ├─ Phase 1: Extract features
       ├─ Phase 2: Write PRD
       ├─ Phase 3: Create beads (epic + child features)
       ├─ Phase 4: Validate with flux-drive
       └─ advance_phase("strategized") on epic + features
       │
       ▼
┌──────────────┐
│     PLAN     │ ← /clavain:write-plan (commands/write-plan.md)
└──────┬───────┘
       │ Delegates to: writing-plans skill
       ├─ Infer context (PRD, beads, recent docs)
       ├─ Write implementation plan
       └─ advance_phase("planned")
       │
       ▼
┌──────────────┐
│ PLAN REVIEW  │ ← /interflux:flux-drive <plan-file> (Step 4 of sprint)
└──────┬───────┘
       │ Multi-agent review BEFORE execution
       ├─ Phase 1: Analyze + Static Triage
       │   ├─ Step 1.0: Understand project (tech stack, divergence)
       │   ├─ Step 1.0.1: Classify domain (detect-domains.py)
       │   ├─ Step 1.0.2: Check staleness (cache validation)
       │   ├─ Step 1.0.3: Re-detect + compare (if stale)
       │   ├─ Step 1.0.4: Agent generation (flux-gen, if needed)
       │   ├─ Step 1.1: Analyze document → profile
       │   ├─ Step 1.2: Select agents (scoring, slicing, staging)
       │   └─ Step 1.3: User confirmation
       ├─ Phase 2: Launch
       │   ├─ Step 2.1: Knowledge context (qmd retrieval)
       │   ├─ Step 2.1a: Domain criteria injection
       │   ├─ Step 2.1c: Write temp files (slicing if large)
       │   ├─ Step 2.2: Stage 1 launch (top agents, background tasks)
       │   ├─ Step 2.2a: Research dispatch (between stages, optional)
       │   ├─ Step 2.2b: Domain-aware expansion decision
       │   ├─ Step 2.2c: Stage 2 launch (if expanded)
       │   └─ Step 2.3: Monitor + verify completion
       └─ Phase 3: Synthesize
           ├─ Step 3.1: Validate agent output (findings index)
           ├─ Step 3.2: Collect results
           ├─ Step 3.3: Deduplicate + organize
           ├─ Step 3.4: Write summary.md + findings.json
           ├─ Step 3.6: Create beads from findings
           └─ advance_phase("plan-reviewed") → enforce_gate before executing
       │
       ▼
┌──────────────┐
│   EXECUTE    │ ← /clavain:work <plan-file> (commands/work.md)
└──────┬───────┘
       │ Gate: enforce_gate("executing") checks plan-reviewed for P0/P1
       ├─ advance_phase("executing") at START
       ├─ Phase 1: Quick start (read plan, clarify, setup, todo list)
       ├─ Phase 2: Execute (task loop, incremental commits, tests)
       │   ├─ Option: subagent-driven-development (fresh subagent per task)
       │   ├─ Option: dispatching-parallel-agents (independent tasks)
       │   └─ Option: interserve mode (Codex agents for implementation)
       └─ Phase 3: Quality check (tests, linting)
       │
       ▼
┌──────────────┐
│ QUALITY GATES│ ← /clavain:quality-gates (commands/quality-gates.md)
└──────┬───────┘
       │ Auto-select reviewers based on what changed
       ├─ Phase 1: Analyze changes (git diff classification)
       ├─ Phase 2: Select reviewers (risk-based)
       ├─ Phase 3: Gather context (diff, file list)
       ├─ Phase 4: Run agents in parallel (Task w/ run_in_background)
       ├─ Phase 5: Synthesize results (P0/P1/P2 triage)
       ├─ Phase 6: File findings as beads (optional)
       └─ On PASS: enforce_gate("shipping") → advance_phase("shipping")
       │
       ▼
┌──────────────┐
│   RESOLVE    │ ← /clavain:resolve (commands/resolve.md)
└──────┬───────┘
       │ Auto-detect source: todo files / PR comments / code TODOs
       ├─ Analyze findings
       ├─ Plan resolution
       ├─ Spawn pr-comment-resolver agents (parallel)
       └─ Commit changes
       │
       ▼
┌──────────────┐
│     SHIP     │ ← landing-a-change skill (skills/landing-a-change/SKILL.md)
└──────┬───────┘
       │ Delegates to: verification-before-completion skill
       ├─ Step 1: Verify tests (MUST pass before proceeding)
       ├─ Step 2: Verify plan compliance
       ├─ Step 3: Review evidence checklist
       ├─ Step 4: AskUserQuestion (commit options)
       ├─ Step 5: Execute choice (commit, push, changelog)
       └─ advance_phase("done") + bd close "$CLAVAIN_BEAD_ID"
```

---

## Trace Event Emission Points

### Category 1: Discovery & Routing (Pre-Workflow)

**Point 1: Work Discovery Scan**
- **File:** `hub/clavain/hooks/sprint-scan.sh` (discovery_scan_beads)
- **Trigger:** `/clavain:sprint` with no args
- **Event:** `discovery.scan_start`, `discovery.scan_complete`
- **Context:** bead count, action distribution, orphan count

**Point 2: User Selection**
- **File:** `hub/clavain/commands/sprint.md` (Step 3)
- **Trigger:** AskUserQuestion response
- **Event:** `discovery.selection`
- **Context:** selected bead ID, action, recommended flag, position in list

**Point 3: Routing Decision**
- **File:** `hub/clavain/commands/sprint.md` (Step 6)
- **Trigger:** Route based on action (brainstorm/strategize/plan/execute/ship)
- **Event:** `workflow.route`
- **Context:** from phase, to command, bead ID

---

### Category 2: Brainstorm Phase

**Point 4: Brainstorm Start**
- **File:** `hub/clavain/commands/brainstorm.md` (Phase 0)
- **Trigger:** Command invocation
- **Event:** `phase.brainstorm.start`
- **Context:** feature description length, clarity assessment

**Point 5: Repo Research Dispatch**
- **File:** `hub/clavain/commands/brainstorm.md` (Phase 1.1)
- **Trigger:** Task(repo-research-analyst)
- **Event:** `agent.dispatch.research`
- **Context:** agent type, query

**Point 6: Brainstorm Document Written**
- **File:** `hub/clavain/commands/brainstorm.md` (Phase 3)
- **Trigger:** Write to docs/brainstorms/
- **Event:** `phase.brainstorm.complete`
- **Context:** doc path, section count, decision count

---

### Category 3: Strategy Phase

**Point 7: Strategy Start**
- **File:** `hub/clavain/commands/strategy.md` (Input resolution)
- **Trigger:** Command invocation
- **Event:** `phase.strategy.start`
- **Context:** input type (file/recent/none), brainstorm path

**Point 8: Beads Created**
- **File:** `hub/clavain/commands/strategy.md` (Phase 3)
- **Trigger:** bd create (epic + features)
- **Event:** `beads.created`
- **Context:** epic ID, feature IDs, feature count

---

### Category 4: Plan Phase

**Point 9: Plan Start**
- **File:** `hub/clavain/skills/writing-plans/SKILL.md`
- **Trigger:** Skill invocation
- **Event:** `phase.plan.start`
- **Context:** inferred context (PRD, beads, docs)

**Point 10: Plan Written**
- **File:** `hub/clavain/commands/write-plan.md` (after skill completes)
- **Trigger:** Write to docs/plans/
- **Event:** `phase.plan.complete`
- **Context:** plan path, task count, module count

---

### Category 5: Plan Review (flux-drive)

**Point 11: flux-drive Start**
- **File:** `plugins/interflux/skills/flux-drive/SKILL.md` (Phase 1)
- **Trigger:** Command invocation
- **Event:** `review.flux_drive.start`
- **Context:** input type (file/directory/diff), input path

**Point 12: Domain Detection**
- **File:** `plugins/interflux/skills/flux-drive/SKILL.md` (Step 1.0.1)
- **Trigger:** detect-domains.py script
- **Event:** `review.domain_detection`
- **Context:** detected domains, confidence scores, cache status

**Point 13: Agent Generation**
- **File:** `plugins/interflux/skills/flux-drive/SKILL.md` (Step 1.0.4)
- **Trigger:** flux-gen auto-generation
- **Event:** `review.agent_generation`
- **Context:** domain shift, new agents, orphaned agents

**Point 14: Agent Triage**
- **File:** `plugins/interflux/skills/flux-drive/SKILL.md` (Step 1.2)
- **Trigger:** Scoring algorithm complete
- **Event:** `review.triage_complete`
- **Context:** total agents, stage 1 count, stage 2 count, expansion pool

**Point 15: Stage 1 Launch**
- **File:** `plugins/interflux/skills/flux-drive/phases/launch.md` (Step 2.2)
- **Trigger:** Task dispatch (run_in_background)
- **Event:** `review.stage_launch`
- **Context:** stage number, agent list, slicing active

**Point 16: Research Escalation**
- **File:** `plugins/interflux/skills/flux-drive/phases/launch.md` (Step 2.2a)
- **Trigger:** Research agent dispatch (between stages)
- **Event:** `review.research_escalation`
- **Context:** finding ID, research agent, query

**Point 17: Expansion Decision**
- **File:** `plugins/interflux/skills/flux-drive/phases/launch.md` (Step 2.2b)
- **Trigger:** Domain-aware expansion scoring
- **Event:** `review.expansion_decision`
- **Context:** max expansion score, recommended agents, user choice

**Point 18: Synthesis Complete**
- **File:** `plugins/interflux/skills/flux-drive/phases/synthesize.md` (Step 3.5)
- **Trigger:** Report presented to user
- **Event:** `review.flux_drive.complete`
- **Context:** verdict, P0/P1/P2 counts, convergence stats, slicing stats

---

### Category 6: Execute Phase

**Point 19: Execution Start (with Gate Check)**
- **File:** `hub/clavain/commands/work.md` (Phase 1b)
- **Trigger:** enforce_gate("executing")
- **Event:** `phase.execute.start`, `gate.check`
- **Context:** bead ID, gate result (pass/skip/blocked), plan path

**Point 20: Subagent Dispatch**
- **File:** `hub/clavain/skills/dispatching-parallel-agents/SKILL.md` or `subagent-driven-development/SKILL.md`
- **Trigger:** Task() calls for implementation/review
- **Event:** `agent.dispatch.implementation` or `agent.dispatch.review`
- **Context:** agent type, task scope, parallel count

---

### Category 7: Quality Gates Phase

**Point 21: Quality Gates Start**
- **File:** `hub/clavain/commands/quality-gates.md` (Phase 1)
- **Trigger:** Command invocation
- **Event:** `phase.quality_gates.start`
- **Context:** change file count, risk domains detected

**Point 22: Quality Gates Result (with Gate Check)**
- **File:** `hub/clavain/commands/quality-gates.md` (Phase 5b)
- **Trigger:** Synthesis complete + enforce_gate("shipping")
- **Event:** `phase.quality_gates.complete`, `gate.check`
- **Context:** verdict (pass/fail), P0/P1/P2 counts, gate result

---

### Category 8: Ship Phase

**Point 23: Ship Complete**
- **File:** `hub/clavain/skills/landing-a-change/SKILL.md` (Step 5)
- **Trigger:** Commit + push (or user choice)
- **Event:** `phase.ship.complete`
- **Context:** commit SHA, bead closed, changelog generated

---

## Phase Tracking Infrastructure

### interphase Plugin Architecture

**Library:** `/root/projects/Interverse/plugins/interphase/hooks/lib-gates.sh`

**Key Functions:**
```bash
# Record phase transition (dual persistence: beads + artifact headers)
advance_phase "$bead_id" "$phase" "$reason" "$artifact_path"

# Gate validation (checks valid transitions before allowing progress)
enforce_gate "$bead_id" "$target_phase" "$artifact_path"
  └─ Returns: 0 (pass), 1 (blocked), with CLAVAIN_SKIP_GATE override

# Read current phase (with fallback: beads → artifact header → empty)
phase_get_with_fallback "$bead_id" "$artifact_path"

# Enforcement tier (based on bead priority: P0/P1 = hard, P2/P3 = soft, P4+ = none)
get_enforcement_tier "$bead_id"

# Review staleness check (finds flux-drive review by bead ID)
check_review_staleness "$bead_id" "$artifact_path"
```

**Phase Graph:**
```
CLAVAIN_PHASES = [
  brainstorm,
  brainstorm-reviewed,
  strategized,
  planned,
  plan-reviewed,  ← Gate before executing (P0/P1 only)
  executing,
  shipping,       ← Gate before shipping (review freshness check)
  done
]
```

**Valid Transitions:**
- Linear: `brainstorm → brainstorm-reviewed → strategized → planned → plan-reviewed → executing → shipping → done`
- Skip paths: `:planned`, `:executing`, `planned:executing`, etc.
- Re-entry: `shipping:planned`, `done:brainstorm` (new work on same bead)

**Dual Persistence:**
1. **Beads metadata:** `.beads/issues.jsonl` (via `bd` CLI)
2. **Artifact headers:** `**Phase:** plan-reviewed` (in markdown frontmatter)

**Statusline Integration:**
- `_gate_update_statusline()` writes `/tmp/clavain-bead-${session_id}.json`
- **interline** plugin reads this for status bar display
- No direct dependency — file-based sideband

---

## Agent Dispatch Patterns

### 3-Layer Orchestration Hierarchy

```
┌─────────────┐
│  COMMAND    │ ← Entry point (/clavain:sprint, /clavain:work, etc.)
└──────┬──────┘
       │ Invokes
       ▼
┌─────────────┐
│   SKILL     │ ← Reusable workflow (writing-plans, flux-drive, etc.)
└──────┬──────┘
       │ Spawns
       ▼
┌─────────────┐
│  SUBAGENT   │ ← Background worker (Task tool, run_in_background: true)
└─────────────┘
```

### Subagent Types

**1. Implementation Agents (dispatching-parallel-agents)**
- Pattern: Parallel specialists (independent tasks)
- Trigger: Plan has 3+ independent modules
- Example: `Task("Fix agent-tool-abort.test.ts")`

**2. Review Agents (subagent-driven-development)**
- Pattern: Two-stage review (spec compliance → code quality)
- Trigger: Per-task validation after implementation
- Example: `Task(spec-reviewer-prompt.md)` → `Task(code-quality-reviewer-prompt.md)`

**3. Research Agents (flux-drive)**
- Pattern: On-demand knowledge retrieval
- Trigger: Agent finds pattern needing external context
- Example: `Task(interflux:research:best-practices-researcher)`
- Budget: 1 escalation per review agent, 2 between stages

**4. Review Agents (flux-drive)**
- Pattern: Staged dispatch (Stage 1 → expansion decision → Stage 2)
- Trigger: flux-drive command
- Example: `Task(interflux:review:fd-architecture)` with `run_in_background: true`

**5. Cross-AI (Oracle)**
- Pattern: GPT-5.2 Pro via CLI (browser mode)
- Trigger: flux-drive roster includes Oracle
- Example: `oracle --wait -f files... -p "prompt"` with `run_in_background: true`

**6. Codex Agents (interserve mode)**
- Pattern: True parallel execution in separate sandboxes
- Trigger: `INTERSERVE_ENABLED=true` or `/interserve` command
- Example: Codex CLI delegation (separate from Claude context)

---

## Decision Points Requiring Telemetry

### High-Value Metrics

1. **Discovery effectiveness:**
   - User accepts first recommendation → 1, other → 0
   - Orphan artifact detection rate
   - Action inference accuracy (compare to user override)

2. **flux-drive performance:**
   - Agent selection stability (triage score distribution)
   - Expansion decision accuracy (expansion score vs user choice)
   - Slicing effectiveness (token savings, convergence impact)
   - Knowledge injection hit rate (provenance: independent vs primed)
   - Research escalation ROI (severity change after research)

3. **Gate enforcement:**
   - Gate block rate (by tier: hard/soft/none)
   - Skip override usage (`CLAVAIN_SKIP_GATE` frequency)
   - Review staleness detection accuracy

4. **Workflow completion:**
   - Phase transition dwell time (time in each phase)
   - Full pipeline completion rate (brainstorm → done)
   - Early abandonment points (where users stop)

5. **Agent dispatch patterns:**
   - Parallel dispatch depth (max concurrent agents)
   - Retry rate (agent completion failures)
   - Subagent type distribution (implementation/review/research)

---

## Integration Recommendations

### Where to Emit Traces

**Existing hooks (add instrumentation):**
- `hooks/session-start.sh` — session metadata, plugin versions
- `hooks/lib-gates.sh` — `advance_phase()`, `enforce_gate()`, `check_review_staleness()`
- `hooks/sprint-scan.sh` — `discovery_scan_beads()`, `discovery_log_selection()`

**Command entry points (add wrappers):**
- All commands in `commands/*.md` → wrap with `trace_command_start/end`

**Skill checkpoints (add inline events):**
- `skills/flux-drive/SKILL.md` → each phase boundary
- `skills/dispatching-parallel-agents/SKILL.md` → dispatch + completion
- `skills/writing-plans/SKILL.md` → plan generation complete

**Agent dispatch (Task tool wrapper):**
- Intercept Task() calls with metadata (agent type, run_in_background flag)
- Track completion via TaskOutput polling

### Trace Schema Suggestions

```json
{
  "event": "phase.transition",
  "timestamp": "2026-02-14T19:30:00Z",
  "session_id": "abc123",
  "bead_id": "feature-xyz",
  "from_phase": "planned",
  "to_phase": "executing",
  "artifact_path": "docs/plans/2026-02-14-my-feature.md",
  "reason": "Executing: docs/plans/2026-02-14-my-feature.md",
  "gate_check": {
    "required": true,
    "result": "pass",
    "tier": "hard",
    "override": false
  }
}
```

```json
{
  "event": "review.flux_drive.agent_dispatch",
  "timestamp": "2026-02-14T19:35:00Z",
  "session_id": "abc123",
  "review_id": "flux-drive-my-plan-abc",
  "stage": 1,
  "agents": [
    {"type": "interflux:review:fd-architecture", "score": 5, "slot": 1},
    {"type": "interflux:review:fd-safety", "score": 4, "slot": 2}
  ],
  "slicing_active": true,
  "domain_context": ["game-simulation"],
  "knowledge_entries_injected": 3
}
```

```json
{
  "event": "gate.check",
  "timestamp": "2026-02-14T19:40:00Z",
  "session_id": "abc123",
  "bead_id": "feature-xyz",
  "target_phase": "executing",
  "current_phase": "plan-reviewed",
  "result": "pass",
  "tier": "hard",
  "review_staleness": "fresh",
  "override": null
}
```

---

## File Paths Reference

### Commands (23 decision points)
- `/root/projects/Interverse/hub/clavain/commands/sprint.md` — Discovery + routing
- `/root/projects/Interverse/hub/clavain/commands/brainstorm.md` — Brainstorm orchestration
- `/root/projects/Interverse/hub/clavain/commands/strategy.md` — PRD + beads creation
- `/root/projects/Interverse/hub/clavain/commands/write-plan.md` — Plan generation
- `/root/projects/Interverse/hub/clavain/commands/execute-plan.md` — Batch execution
- `/root/projects/Interverse/hub/clavain/commands/work.md` — Autonomous execution
- `/root/projects/Interverse/hub/clavain/commands/quality-gates.md` — Auto-reviewer selection
- `/root/projects/Interverse/hub/clavain/commands/resolve.md` — Finding resolution

### Skills (workflow logic)
- `/root/projects/Interverse/hub/clavain/skills/brainstorming/SKILL.md`
- `/root/projects/Interverse/hub/clavain/skills/writing-plans/SKILL.md`
- `/root/projects/Interverse/hub/clavain/skills/executing-plans/SKILL.md`
- `/root/projects/Interverse/hub/clavain/skills/dispatching-parallel-agents/SKILL.md`
- `/root/projects/Interverse/hub/clavain/skills/subagent-driven-development/SKILL.md`
- `/root/projects/Interverse/hub/clavain/skills/landing-a-change/SKILL.md`
- `/root/projects/Interverse/hub/clavain/skills/verification-before-completion/SKILL.md`

### flux-drive (multi-agent review)
- `/root/projects/Interverse/plugins/interflux/skills/flux-drive/SKILL.md` — Main orchestrator
- `/root/projects/Interverse/plugins/interflux/skills/flux-drive/phases/launch.md` — Agent dispatch
- `/root/projects/Interverse/plugins/interflux/skills/flux-drive/phases/synthesize.md` — Results aggregation
- `/root/projects/Interverse/plugins/interflux/skills/flux-drive/phases/slicing.md` — Content routing
- `/root/projects/Interverse/plugins/interflux/commands/flux-drive.md` — Command wrapper

### Phase Tracking (interphase companion)
- `/root/projects/Interverse/plugins/interphase/hooks/lib-gates.sh` — Gate validation + phase transitions
- `/root/projects/Interverse/plugins/interphase/hooks/lib-phase.sh` — Phase state management
- `/root/projects/Interverse/plugins/interphase/hooks/lib-discovery.sh` — Work scanner

### Hooks (infrastructure)
- `/root/projects/Interverse/hub/clavain/hooks/session-start.sh` — Session init
- `/root/projects/Interverse/hub/clavain/hooks/sprint-scan.sh` — Discovery scanner
- `/root/projects/Interverse/hub/clavain/hooks/lib.sh` — Shared utilities

---

## Next Steps for Trace Integration

1. **Define trace schema** — standardize event format across all emission points
2. **Add hook instrumentation** — `lib-gates.sh`, `sprint-scan.sh`, `session-start.sh`
3. **Wrap command entry points** — 23 trace points from discovery → ship
4. **Instrument flux-drive phases** — 8 trace points from triage → synthesis
5. **Capture agent dispatch metadata** — Task tool wrapper for subagent tracking
6. **Test with real workflows** — `/sprint` end-to-end, validate event sequence
7. **Connect to intermute** — forward traces to coordination service for cross-session analytics

---

**Analysis complete.** Full lifecycle mapped with 23 trace emission points identified.
