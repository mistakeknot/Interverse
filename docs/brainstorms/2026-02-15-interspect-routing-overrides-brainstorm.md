# Interspect Routing Overrides (Type 2)

**Bead:** iv-nkak
**Phase:** brainstorm (as of 2026-02-15T19:09:50Z)
**Date:** 2026-02-15
**Status:** Brainstorm

---

## What We're Building

A per-project `routing-overrides.json` file that lets interspect exclude irrelevant agents from flux-drive triage. The full loop: interspect detects a pattern (e.g., fd-game-design produces zero useful findings across 8 sessions of a Go backend), proposes the exclusion via `AskUserQuestion` with an evidence summary, and writes the override to `.claude/routing-overrides.json` on approval. Flux-drive reads the file during triage pre-filtering and skips excluded agents before scoring.

**Scope:** Agent exclusions only (no model overrides in v1). Both producer (interspect) and consumer (flux-drive) in one unit.

## Why This Approach

**Static JSON + pre-triage filter** was chosen over SQLite-backed overrides and YAML-with-conditions for three reasons:

1. **Debuggability.** A flat JSON file is readable by humans, editable in any text editor, and `git diff`-able. When a user wonders "why didn't fd-safety run?", `cat .claude/routing-overrides.json` answers instantly.

2. **Clean plugin boundary.** Interspect (in clavain) writes the file; flux-drive (in interflux) reads it. No cross-plugin DB access, no import path coupling. The file format is the contract.

3. **Per-project scoping is sufficient.** The design document notes that "a pattern that excludes fd-game-design from backend services should not affect game projects." Per-project files handle this naturally — each project's `.claude/` directory gets its own overrides. No need for conditional rules (language, project type) in the file format.

## Key Decisions

### File Format

```json
{
  "version": 1,
  "overrides": [
    {
      "agent": "fd-game-design",
      "action": "exclude",
      "reason": "Zero relevant findings across 8 sessions (backend Go services)",
      "evidence_ids": [12, 15, 23, 31, 45],
      "created": "2026-02-15T14:32:00Z",
      "created_by": "interspect"
    }
  ]
}
```

- **`version`**: Schema version for forward compatibility.
- **`agent`**: Agent identifier matching the triage roster (e.g., `fd-game-design`, `fd-safety`).
- **`action`**: Only `"exclude"` in v1. Future: `"model_override"`, `"priority_boost"`.
- **`reason`**: Human-readable summary of the evidence pattern.
- **`evidence_ids`**: References to evidence table rows in interspect.db for auditability.
- **`created`**: ISO 8601 UTC timestamp.
- **`created_by`**: `"interspect"` (automated) or `"human"` (manual edit). Distinguishes for canary monitoring.

### Location

Per-project: `<project-root>/.claude/routing-overrides.json`

This is already in the interspect protected-paths manifest's `modification_allow_list` — interspect can write to it, but it's the only place it can write routing changes.

### Consumer: Flux-Drive Triage Integration

Insert a new pre-filter step at the beginning of Step 1.2a in flux-drive's SKILL.md:

```
Step 1.2a.0: Read routing overrides
  - Check if .claude/routing-overrides.json exists
  - If yes, parse and remove excluded agents from the candidate pool
  - Log: "Routing overrides: excluded [agent-list] (interspect)"
  - If file is malformed, log warning and proceed without overrides
```

This runs before the existing domain/data/product/game/deploy filters. An excluded agent never reaches scoring.

**No override for cross-cutting agents by default.** fd-architecture and fd-quality are excluded from routing overrides unless explicitly marked as overridable. These agents provide structural baseline coverage — excluding them risks missing cross-cutting issues. The file format allows it (no schema restriction) but the triage consumer should warn: "Warning: routing override excludes cross-cutting agent fd-architecture. This removes structural coverage."

### Producer: Interspect Propose Flow

When `_interspect_classify_pattern` returns `"ready"` for a routing-eligible pattern:

1. **Generate proposal.** Build the override JSON entry with evidence summary.
2. **Present via AskUserQuestion.** Format:

```
Interspect suggests excluding fd-game-design from this project's reviews.

Evidence: 5 override events across 4 sessions, 3 projects
Pattern: fd-game-design produces no relevant findings for Go backend services
Sessions: s1 (2/10), s2 (2/11), s3 (2/12), s4 (2/14)

Accept this routing override?
[Yes] [No] [Show evidence details]
```

3. **On approval:** Write/merge into `.claude/routing-overrides.json`. If file exists, append to `overrides` array. If new, create with `version: 1`.
4. **Record modification.** Insert into interspect `modifications` table with `mod_type: "routing"`.
5. **Create canary.** Insert canary record monitoring the next 20 flux-drive runs for this project.
6. **Git commit.** Via `_interspect_flock_git`:

```
[interspect] Exclude fd-game-design from project reviews

Evidence:
- override (agent_wrong): 5 occurrences across 4 sessions, 3 projects
- Confidence: ready (3/3 counting rules met)
- Risk: Medium → Safety: canary alert

What changed: .claude/routing-overrides.json (1 exclusion added)
Pattern: fd-game-design flags zero relevant issues in Go backend projects
Canary: 20 uses or 14 days
```

### What "Routing-Eligible" Means

Not all patterns should produce routing overrides. A pattern is routing-eligible when:

- The evidence is dominated by `agent_wrong` override reasons (≥80% of events for that pattern)
- The pattern involves a specific agent being consistently irrelevant (not just occasionally wrong)
- The agent being excluded is domain-specific (not cross-cutting)

Patterns where the agent is *wrong sometimes but right other times* should produce Type 1 (context overlay) or Type 3 (prompt tuning) modifications, not routing exclusions. Routing overrides are for the case where an agent's entire domain doesn't apply.

### Manual Overrides

Users can also edit `.claude/routing-overrides.json` directly — no interspect required. Set `"created_by": "human"`. Human-created overrides:

- Are never modified by interspect (human intent takes precedence)
- Are never monitored by canary (no baseline to compare against)
- Appear in `/interspect:status` as "manual routing override"

### Removal / Revert

- **Interspect revert:** `/interspect:revert` removes the override entry and blacklists the pattern.
- **Manual removal:** Delete the entry from JSON. Interspect will re-propose if the pattern still meets counting rules (unless blacklisted).
- **Canary-triggered alert:** If flux-drive's finding quality degrades after an exclusion (e.g., defects slip through that the excluded agent would have caught), the canary alerts. Human reverts manually.

## Open Questions

1. **Cross-project routing.** Should interspect be able to propose the *same* exclusion across multiple projects when the pattern spans projects? Currently each project gets its own file, so the same proposal would be made separately per project. This seems fine for v1 — cross-project aggregation can come later.

2. **Canary metrics for routing.** What does "degradation" mean for an exclusion? The excluded agent produces *no* findings (it's not running), so override rate doesn't apply. Candidate metric: "defect escape rate increased after exclusion" via Galiana. Needs Galiana integration to be useful.

3. **Override count limit.** Should there be a maximum number of overrides per project? Probably not for v1 — the counting-rule thresholds already ensure overrides are conservative. But if interspect proposes excluding 5+ agents, something is wrong with the agent roster, not the project.

## Implementation Outline

### Changes to interflux (consumer)

1. **`skills/flux-drive/SKILL.md`** — Add Step 1.2a.0 (read routing overrides) before existing pre-filters.
2. **`skills/flux-drive/phases/slicing.md`** — Note that excluded agents are never sliced (they're gone before slicing).

### Changes to clavain (producer)

3. **`hooks/lib-interspect.sh`** — Add `_interspect_propose_routing_override()` and `_interspect_apply_routing_override()` functions.
4. **`commands/interspect.md`** — Update `/interspect` command to show routing override proposals alongside other modification proposals.
5. **`commands/interspect-status.md`** — Show active routing overrides per project.
6. **`.clavain/interspect/protected-paths.json`** — Already has `.claude/routing-overrides.json` in allow-list. Confirm no changes needed.

### Shared contract

7. **File format documented** in both clavain AGENTS.md and interflux AGENTS.md so both plugins agree on the schema.

## Next Steps

Run `/clavain:write-plan` to turn this into an implementation plan with specific code changes, test strategy, and ordering.
