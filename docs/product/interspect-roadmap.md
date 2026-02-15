# Interspect — Implementation Roadmap

**Version:** 1.0
**Date:** 2026-02-15
**PRD:** `docs/product/interspect-prd.md`
**Design:** `hub/clavain/docs/plans/2026-02-15-interspect-design.md`

---

## Overview

Four phases, ~14 weeks to autonomous mode. Each phase validates assumptions from the previous one before expanding scope.

```
Phase 1          Phase 2            Phase 3               Phase 4
Evidence +       Propose Mode +     Autonomous +          Evaluate +
Reporting        Canary             Shadow Testing        Expand
[4 weeks]        [4 weeks]          [6 weeks]             [ongoing]
```

---

## Phase 1: Evidence + Reporting (4 weeks)

**Goal:** Validate which evidence signals are useful. No modifications applied.
**Gate:** >=50 evidence events across >=10 sessions before Phase 2.

### Week 1-2: Foundation

| Task | Bead | Description |
|------|------|-------------|
| SQLite schema + init | iv-interspect-schema | Create `.clavain/interspect/interspect.db` with evidence, sessions, canary, modifications tables. Init script idempotent. |
| Evidence collection hook | iv-interspect-evidence-hook | PostToolUse hook for `/resolve` dismissals. Writes to SQLite via `sqlite3` CLI. |
| Session lifecycle hook | iv-interspect-session-hooks | Extend session-start.sh to write session start event. Add session-end event to Stop hook. |
| `/interspect:correction` command | iv-interspect-correction-cmd | Explicit signal command: `<agent> <description>`. Writes `agent_wrong` event to evidence. |

### Week 3-4: Reporting

| Task | Bead | Description |
|------|------|-------------|
| `/interspect` command | iv-interspect-main-cmd | Pattern detection: query evidence store, group by agent + event type, compute frequencies. Show suggested tunings. |
| `/interspect:status` command | iv-interspect-status-cmd | Show modification history, canary state, metrics vs baseline for a component. |
| `/interspect:evidence` command | iv-interspect-evidence-cmd | Human-readable evidence summary for an agent. Query + format. |
| `/interspect:health` command | iv-interspect-health-cmd | Signal status dashboard: which collection points are active, evidence counts, staleness. |
| Session-start summary | iv-interspect-session-summary | Inject "Interspect: N agents adapted, M canaries active" via SessionStart hook. |
| Evidence sanitization | iv-interspect-sanitization | Strip control chars, truncate to 500 chars, reject injection patterns, tag with hook_id. |

### Phase 1 Deliverables
- Working evidence store collecting real data
- 4 reporting commands functional
- Session-start summary when modifications exist
- Validated: which signals produce useful data, which don't

---

## Phase 2: Propose Mode + Canary (4 weeks)

**Goal:** Propose modifications for human approval. Validate modification quality.
**Gate:** Propose-mode acceptance rate >=70% across >=10 proposals before Phase 3.

### Week 5-6: Modification Pipeline

| Task | Bead | Description |
|------|------|-------------|
| Confidence gate | iv-interspect-confidence | Implement weighted confidence function. Thresholds: <0.3 log only, 0.3-0.7 Tier 1, >=0.7 Tier 2. |
| Protected paths manifest | iv-interspect-protected-paths | Create `.clavain/interspect/protected-paths.json` with allow-list and protected list. |
| Git pre-commit hook | iv-interspect-precommit | Reject `[interspect]` commits touching protected paths. |
| Modification pipeline | iv-interspect-mod-pipeline | Classify -> Generate -> Safety gate -> Apply -> Monitor -> Verdict. |
| Git operation serialization | iv-interspect-git-flock | `flock` wrapper for all Tier 2 git add/commit operations. |
| Sidecar injection mechanism | iv-interspect-sidecar-inject | Specify and implement how agents read `interspect-context.md` sidecars. |

### Week 7-8: Canary + UX

| Task | Bead | Description |
|------|------|-------------|
| Canary monitoring | iv-interspect-canary | SQLite canary records. 20-use/14-day windows. Three metrics. Rolling baseline. |
| Canary verdict engine | iv-interspect-canary-verdict | Verdict computation at session start. Atomic claim via `UPDATE WHERE status='active'`. |
| `/interspect:revert` command | iv-interspect-revert-cmd | Revert modification group + blacklist pattern. |
| Commit message format | iv-interspect-commit-format | Structured `[interspect]` commits with evidence summary, confidence, canary info. |
| Statusline integration | iv-interspect-statusline | Interline integration: `[inspect:canary(fd-safety)]`. |
| Secret detection | iv-interspect-secret-scan | Grep for credential patterns in evidence before insertion. Redact matches. |
| Global rate limiter | iv-interspect-rate-limit | Max 5 modifications per 10 sessions. System-wide circuit breaker. |

### Phase 2 Deliverables
- Propose mode working end-to-end for Types 1-3
- Canary monitoring with 3 metrics + recall cross-check
- Protected paths enforced mechanically
- Revert with blacklisting functional
- Secret detection in evidence pipeline

---

## Phase 3: Autonomous Mode (6 weeks)

**Goal:** Enable opt-in autonomous modifications for Types 1-2. Add prompt tuning in propose mode.
**Gate:** Canary pass rate >=90% across >=20 canary windows.

### Week 9-11: Autonomy

| Task | Bead | Description |
|------|------|-------------|
| Autonomous mode flag | iv-interspect-autonomy-flag | `/interspect:enable-autonomy` and `:disable-autonomy`. Flag in protected manifest. |
| Tier 1 session-scoped state | iv-interspect-tier1 | Session-scoped file-based state (`.clavain/interspect/tier1-active.json`). Deleted at session end. |
| Shadow testing | iv-interspect-shadow-test | Eval corpus or synthetic test cases. LLM-as-judge with randomized presentation. Judge prompt protected. |
| Prompt tuning (Type 3) | iv-interspect-prompt-tuning | Surgical edits to agent `.md` files in propose mode. Galiana recall cross-check required. |

### Week 12-14: Meta-Learning

| Task | Bead | Description |
|------|------|-------------|
| Meta-learning loop | iv-interspect-meta-learning | Modification outcomes as evidence. Root-cause taxonomy. Bidirectional risk classification decay. |
| Circuit breaker | iv-interspect-circuit-breaker | 3 reverts in 30 days disables target. File beads issue. `/interspect:unblock` command. |
| Conflict detection | iv-interspect-conflict-detect | Same target modified-then-reverted by different evidence patterns -> escalate. |
| `/interspect:reset` command | iv-interspect-reset-cmd | Revert all modifications, archive evidence. |
| `/interspect:disable` command | iv-interspect-disable-cmd | Pause all interspect activity. |

### Phase 3 Deliverables
- Autonomous mode for Types 1-2 (context injection + routing)
- Prompt tuning in propose mode with shadow testing
- Meta-learning with root-cause attribution
- Full command suite operational

---

## Phase 4: Evaluate + Expand (Ongoing)

**Goal:** Recalibrate based on real data. Decide v2 scope.

| Activity | Timeline |
|----------|----------|
| Recalibrate confidence thresholds (0.3/0.7) against 3 months of data | Month 4 |
| Evaluate Types 4-6 need based on manual improvement patterns | Month 4-5 |
| Consider autonomous prompt tuning if propose acceptance >80% | Month 5 |
| Annual threat model review | Month 12 |
| Cross-model shadow testing (Oracle as judge) | Month 4 |

---

## Design Revisions Required Before Phase 1

These must be addressed in the design doc before implementation begins:

| # | Issue | Action | Bead |
|---|-------|--------|------|
| 1 | AskUserQuestion response capture claimed "Confirmed" but is infeasible | Update design SS3.1.4: remove claim, confirm `/interspect:correction` as sole override signal | iv-interspect-design-fix-auq |
| 2 | "In-memory" Tier 1 is actually session-scoped files | Update design SS3.2: clarify implementation uses disk-based ephemeral state | iv-interspect-design-fix-tier1 |
| 3 | Sidecar injection mechanism unspecified | Add new subsection specifying SessionStart concatenation approach | iv-interspect-design-fix-sidecar |
| 4 | Success metrics absent | Add SS5.5 with the 5 metrics from PRD SS6 | iv-interspect-design-fix-metrics |
| 5 | Flux-drive SKILL.md needs integration contract | Update interflux to document routing-overrides.json and sidecar consumption | iv-interspect-flux-contract |
| 6 | Git operation serialization missing | Add to SS3.4 step 4: flock wrapper for git operations | iv-interspect-design-fix-git |

---

## Dependency Graph (Critical Path)

```
Design Fixes (prereq)
  |
  v
Phase 1: Schema ──> Evidence Hook ──> Commands ──> Session Summary
                ──> Session Hooks     ──> Sanitization
                ──> Correction Cmd
  |
  v (gate: >=50 events, >=10 sessions)
Phase 2: Protected Paths ──> Confidence Gate ──> Mod Pipeline ──> Canary
         Pre-commit Hook     Git Flock          Sidecar Inject   Verdict Engine
                                                                  Revert Cmd
  |
  v (gate: acceptance >=70%, >=10 proposals)
Phase 3: Autonomy Flag ──> Shadow Testing ──> Prompt Tuning
         Tier 1 State      Meta-Learning     Circuit Breaker
```

---

## Resource Estimate

| Phase | Effort | Calendar |
|-------|--------|----------|
| Design fixes | 1-2 sessions | 1 day |
| Phase 1 | 8-12 sessions | 4 weeks |
| Phase 2 | 10-14 sessions | 4 weeks |
| Phase 3 | 12-16 sessions | 6 weeks |
| **Total to autonomous** | **~35 sessions** | **~14 weeks** |
