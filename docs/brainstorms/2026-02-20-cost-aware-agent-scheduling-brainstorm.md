# Cost-Aware Agent Scheduling with Token Budgets
**Bead:** iv-pbmc | **Sprint:** iv-suzr
**Phase:** brainstorm (as of 2026-02-20T17:02:28Z)
**Date:** 2026-02-20
**Status:** brainstorm

## Problem

Clavain's agent dispatch is currently cost-blind. Flux-drive dispatches 7+ review agents regardless of session budget. Sprint workflows have no token ceiling — a C4 sprint can consume 500K+ tokens across phases with no guardrails. The infrastructure exists at each layer (intercore budget algebra, flux-drive triage, interstat measurement) but nothing connects them. The result: no spend awareness until after the session ends, when interstat backfills from JSONL.

### Evidence

- **interstat is batch-only:** Token counts in `agent_runs` are NULL during a live session. The `analyze.py` script only runs at SessionEnd. Flux-drive's synthesis cost report (Step 3.4b) queries these NULL fields and gets nothing useful.
- **Budget checker is a dead letter:** `intercore/internal/budget/Checker` is instantiated with `recorder: nil` everywhere. Budget threshold events (`budget.warning`, `budget.exceeded`) emit to stderr only — no event bus write.
- **Sprint advance is budget-ignorant:** `sprint_advance()` delegates to `intercore_run_advance()` which checks gate rules but never calls `ic run budget`.
- **Flux-drive triage has budget logic but no sprint context:** `budget.yaml` defines per-type budgets (plan=150K, brainstorm=80K). But if a sprint has a 200K total budget and 150K is already spent, flux-drive doesn't know — it uses its own static budget.yaml values.
- **Dispatch records lack token counts:** `ic dispatch tokens <id> --set` exists but nothing calls it. The `AggregateTokens()` function works but returns 0 for every run.

### Gap Map

```
                  ┌─────────────┐
                  │  Sprint OS  │ ← no token_budget on sprint bead
                  │ lib-sprint  │ ← sprint_advance() doesn't check budget
                  └──────┬──────┘
                         │ (no budget propagation)
                  ┌──────▼──────┐
                  │  Flux-drive │ ← uses static budget.yaml, not sprint budget
                  │   Triage    │ ← triage cut logic exists but is disconnected
                  └──────┬──────┘
                         │ (no token writeback)
                  ┌──────▼──────┐
                  │  Intercore  │ ← Budget algebra exists, checker dead-lettered
                  │   Kernel    │ ← AggregateTokens() returns 0 (no input data)
                  └──────┬──────┘
                         │ (no real-time feed)
                  ┌──────▼──────┐
                  │  Interstat  │ ← batch-only, NULL tokens mid-session
                  │ Measurement │
                  └─────────────┘
```

## Constraints

1. **Billing tokens = input + output** (not total_tokens which includes cache). Canonical definition in `docs/solutions/patterns/token-accounting-billing-vs-context-20260216.md`.
2. **Soft enforcement** — warn + offer override, never hard-block without escape hatch. Already established in budget.yaml (`enforcement: soft`).
3. **Min 2 agents always dispatched** regardless of budget. Stage 1 agents are budget-protected.
4. **Batch measurement is acceptable for v1** — perfect real-time accounting is a non-goal. Reasonable estimates are sufficient for triage decisions.
5. **No new standalone modules** — extend existing infrastructure (lib-sprint.sh, flux-drive skill, interstat hooks, intercore CLI).
6. **Must work without intercore** — beads-only sprints (no ic run) should still get budget warnings, just without kernel enforcement.

## Approach Variants

### Variant A: Estimation-First (Low Infrastructure)

Don't solve the real-time token counting problem. Instead, use pre-computed estimates.

**How it works:**
1. Sprint creation accepts `--token-budget=N` (already supported by ic run create)
2. `sprint_read_state()` surfaces `token_budget` from ic run
3. Before each phase, estimate cost based on `budget.yaml` agent defaults × expected agent count
4. `sprint_advance()` checks estimated cumulative cost vs budget → warn if >80%
5. Flux-drive receives remaining budget as env var, applies its existing triage cut logic
6. After session ends, interstat backfills actuals — sprint summary shows estimated vs actual

**Pros:** No new hooks, no JSONL parsing, no real-time plumbing. Works today.
**Cons:** Estimates can be wildly wrong (40K default vs 120K actual for Oracle). Budget violations detected only after the fact. No interspect signal.

### Variant B: PostToolUse Running Total (Medium Infrastructure)

Add a lightweight PostToolUse hook that maintains a running token counter by parsing the tool result metadata (not the full session JSONL).

**How it works:**
1. PostToolUse hook (new: `hooks/token-counter.sh`) fires on every tool call
2. Claude Code's PostToolUse event includes `input_tokens` and `output_tokens` in the tool result metadata (needs verification — may only include result text, not token counts)
3. Hook maintains `/tmp/clavain-tokens-${SESSION_ID}.json` with running `{input, output, billing}` totals
4. Sprint library reads this file: `sprint_tokens_spent()` → billing total
5. `sprint_advance()` checks `sprint_tokens_spent() < token_budget` → warn/block
6. Flux-drive reads remaining budget from sprint context, applies triage cut
7. At phase completion, write to `ic dispatch tokens` so intercore aggregation works

**Pros:** Live-ish budget tracking, sprint advance can enforce, flux-drive gets real budget context.
**Cons:** Depends on PostToolUse metadata including token counts (unverified). Hook fires on EVERY tool call — latency risk. /tmp files need cleanup.

### Variant C: Interstat Session Streaming (High Infrastructure)

Make interstat produce real-time session totals by parsing JSONL incrementally, not just at SessionEnd.

**How it works:**
1. `interstat` adds a PostToolUse hook that incrementally parses `session.jsonl`
2. New `scripts/stream-tokens.sh` reads from last-known offset, appends new token entries
3. Writes to `interstat.metrics.db` → new `session_tokens` table with running totals
4. Sprint library queries interstat DB: `SELECT SUM(billing_tokens) FROM session_tokens WHERE session_id=?`
5. All downstream consumers (sprint advance, flux-drive, interspect) read from this single source of truth

**Pros:** Single source of truth, all consumers benefit, data is durable (not /tmp).
**Cons:** JSONL parsing on every tool call is expensive. interstat DB contention with background analyze.py. Requires interstat schema migration. Over-engineered for v1.

### Variant D: Hybrid Estimation + Writeback (Recommended)

Combine Variant A's estimation with post-phase actual writeback. No real-time JSONL parsing.

**How it works:**

**Component 1: Sprint budget parameter**
- `sprint_create()` accepts budget param → passes to `ic run create --token-budget=N`
- `sprint_read_state()` includes `token_budget` and `tokens_spent` (from `ic run tokens`)
- Default budgets by complexity: C1=50K, C2=100K, C3=250K, C4=500K, C5=1M
- User override: `bd set-state <sprint> token_budget=300000`

**Component 2: Sprint advance budget check**
- `sprint_advance()` calls `ic run budget <id>` before advancing
- If exit code 1 (exceeded): warn user, offer override (`CLAVAIN_SKIP_BUDGET=reason`)
- If budget-warn-pct exceeded: display warning, continue
- Beads-only fallback: skip budget check (no ic run = no budget enforcement)

**Component 3: Flux-drive budget integration**
- Sprint step passes remaining budget to flux-drive via env: `FLUX_BUDGET_REMAINING=150000`
- Flux-drive triage uses `min(budget.yaml default, FLUX_BUDGET_REMAINING)` as effective budget
- If no env var, falls back to budget.yaml (backward compatible)

**Component 4: Post-phase token writeback**
- After each phase completes, estimate tokens consumed for that phase
- Source: interstat `agent_runs` for phases that dispatched agents (flux-drive, quality-gates)
- Source: rough estimate (30K per phase) for non-agent phases (brainstorm, strategy, plan)
- Write to `ic dispatch tokens` with a synthetic dispatch ID per phase
- This feeds `AggregateTokens()` so `ic run budget` returns meaningful numbers for subsequent phases

**Component 5: Interspect cost-effectiveness signal (stretch goal)**
- After synthesis, count accepted vs total findings per agent (from verdict files)
- Query interstat for per-agent token consumption (from `agent_runs`, may be NULL)
- Write cost-effectiveness ratio to interspect evidence: `useful_findings / tokens_consumed`
- interspect uses this for learned deprioritization alongside override rate

**Pros:**
- No real-time JSONL parsing, no new hooks, no /tmp files
- Works with existing infrastructure: ic run budget, budget.yaml, interstat
- Post-phase writeback closes the data loop for subsequent budget checks
- Backward compatible: no budget = no enforcement
- Interspect integration is additive (stretch goal, not blocking)

**Cons:**
- Token accounting is phase-granularity, not tool-call granularity
- First phase (brainstorm) always runs without budget context (no prior phases to aggregate)
- Estimates for non-agent phases are rough (but budget enforcement is soft, so this is acceptable)

## Recommendation

**Variant D: Hybrid Estimation + Writeback.**

It threads the needle between "good enough" and "buildable in a sprint." The key insight: we don't need real-time per-tool-call accounting. Phase-granularity writeback gives the sprint advance check real data by phase 3-4, which is exactly when budgets start mattering (the early brainstorm/strategy phases are cheap).

Component 5 (interspect) is a stretch goal — build it if Components 1-4 ship cleanly, defer if not.

## Files Touched

| Component | Files | Type |
|-----------|-------|------|
| C1: Sprint budget | `hub/clavain/hooks/lib-sprint.sh` | Modify |
| C2: Sprint advance | `hub/clavain/hooks/lib-sprint.sh` | Modify |
| C3: Flux-drive integration | `plugins/interflux/skills/flux-drive/SKILL-compact.md` | Modify |
| C3: Flux-drive integration | `plugins/interflux/skills/flux-drive/phases/synthesize.md` | Modify |
| C4: Token writeback | `hub/clavain/hooks/lib-sprint.sh` | Modify |
| C4: Token writeback | `hub/clavain/commands/sprint.md` | Modify |
| C5: Interspect signal | `hub/clavain/hooks/lib-interspect.sh` | Modify |
| C5: Interspect signal | `hub/clavain/hooks/interspect-evidence.sh` | Modify |
| Docs | `docs/glossary.md` (token budget term) | Modify |
| Docs | `hub/clavain/AGENTS.md` | Modify |

## Open Questions

1. **Default budgets by complexity** — are C1=50K, C2=100K, C3=250K, C4=500K, C5=1M reasonable? Need to calibrate against actual sprint data from interstat.
2. **Budget warn percentage** — 80% is the current default in intercore. Should this be per-complexity or uniform?
3. **Flux-drive env var naming** — `FLUX_BUDGET_REMAINING` or something more structured? Could also pass via a temp file.
4. **Non-agent phase estimates** — 30K per phase is a guess. Need to measure brainstorm/strategy/plan phases from interstat session data to get a real baseline.
5. **Should budget check be in sprint_advance or sprint_should_pause?** — sprint_should_pause already handles gate checks and manual pause. Budget could be another pause trigger type.

## Risk Assessment

- **Integration complexity: Medium.** Each component is small, but wiring them together crosses 3 repos (clavain, interflux, intercore).
- **Estimation accuracy: Low risk.** Soft enforcement means wrong estimates just produce bad warnings, not blocked sprints.
- **Performance: Low risk.** No new hooks, no JSONL parsing, no real-time computation. Everything is at phase boundaries.
- **Backward compatibility: Low risk.** No budget = no enforcement. Existing sprints unaffected.
