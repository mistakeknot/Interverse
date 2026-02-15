# Interspect — Product Requirements Document

**Version:** 1.0
**Date:** 2026-02-15
**Status:** Pre-implementation
**Owner:** Clavain hub
**Design doc:** `hub/clavain/docs/plans/2026-02-15-interspect-design.md`
**Reviews:** `docs/research/fd-*-review-interspect.md` (7 agents)
**Research:** `docs/research/research-self-improving-ai-systems.md`

---

## 1. Problem Statement

Clavain's multi-agent review system dispatches 4-12 specialized agents per code review. These agents produce findings that are sometimes wrong (`agent_wrong`), sometimes stale (`already_fixed`), and sometimes correctly deprioritized by the user (`deprioritized`). Today, there is no mechanism to learn from these override patterns — the same false positives recur across sessions, the same irrelevant agents get dispatched, and prompt quality drifts without feedback.

**Evidence of the problem:**
- Manual agent prompt edits happen reactively, with no systematic evidence backing
- Routing decisions (which agents to dispatch) are static — no per-project or per-domain adaptation
- Override patterns repeat: users dismiss the same finding types across sessions
- No visibility into which agents are underperforming

**What success looks like:**
- Override rate for `agent_wrong` decreases over time (measurable via evidence store)
- Users accept >80% of proposed modifications in propose mode
- Canary pass rate >90% (modifications don't degrade agent quality)
- Time from pattern detection to proposed fix: < 3 sessions

## 2. Solution Overview

Interspect is Clavain's self-improvement engine — an OODA loop that:
1. **Observes** — Collects evidence about agent performance (overrides, false positives, corrections)
2. **Orients** — Detects patterns across sessions and projects via confidence scoring
3. **Decides** — Classifies modifications by risk and routes through safety gates
4. **Acts** — Applies modifications (context injection, routing adjustment, prompt tuning) with canary monitoring

**Key constraint:** Continuously self-improving, not recursively self-improving. Interspect improves agents, not itself. Its own safety infrastructure (confidence function, canary logic, protected paths) is immutable.

## 3. User Personas

**Primary:** Solo developer using Clavain for daily code review on 3-5 active projects across Go, Python, and TypeScript.

**Interaction modes:**
- **Passive** (default): Interspect collects evidence silently. User sees session-start summaries when modifications exist.
- **Active**: User invokes `/interspect` for analysis, `/interspect:correction` to file manual signals, `/interspect:revert` to undo bad changes.
- **Autonomous** (opt-in): Low/medium-risk modifications auto-apply with canary monitoring. High-risk always requires approval.

## 4. Requirements

### 4.1 Evidence Collection (Phase 1)

| ID | Requirement | Priority | Feasibility |
|----|-------------|----------|-------------|
| E1 | Collect human override events with reason taxonomy (`agent_wrong`, `deprioritized`, `already_fixed`) | P0 | Confirmed — `/interspect:correction` command |
| E2 | Track session lifecycle (start, end, abandoned/dark sessions) | P0 | Confirmed — SessionStart/Stop hooks |
| E3 | Track dismissed findings from `/resolve` with dismissal reason | P1 | Confirmed — requires `/resolve` skill instrumentation |
| E4 | Store evidence in SQLite with WAL mode for concurrent access | P0 | Confirmed — `sqlite3` CLI available |
| E5 | Retain raw events 90 days, compute weekly aggregates, archive | P1 | Standard SQL |
| E6 | Sanitize evidence fields (strip control chars, truncate 500 chars, reject injection patterns) | P0 | Bash/SQL |
| E7 | Flag abandoned sessions (start_ts but no end_ts after 24h) | P2 | SQL query |

### 4.2 Analysis & Reporting (Phase 1)

| ID | Requirement | Priority |
|----|-------------|----------|
| A1 | `/interspect` command: show detected patterns, suggested tunings | P0 |
| A2 | `/interspect:status [component]`: modification history, canary state, metrics vs baseline | P0 |
| A3 | `/interspect:evidence <agent>`: human-readable evidence summary | P0 |
| A4 | `/interspect:health`: active/degraded signals, evidence counts, canary states | P1 |
| A5 | Session-start summary when modifications exist | P1 |

### 4.3 Modification Pipeline (Phase 2)

| ID | Requirement | Priority |
|----|-------------|----------|
| M1 | Confidence gate: weighted function of evidence count, cross-session factor, cross-project diversity, recency decay | P0 |
| M2 | Modification allow-list enforced by protected paths manifest | P0 |
| M3 | Propose mode: present diff + evidence summary via AskUserQuestion, one change at a time | P0 |
| M4 | Atomic git commits with structured `[interspect]` message format | P0 |
| M5 | Git operation serialization via flock (concurrent session safety) | P0 |
| M6 | One active canary per target file | P0 |

### 4.4 Canary Monitoring (Phase 2)

| ID | Requirement | Priority |
|----|-------------|----------|
| C1 | 20-use or 14-day canary window | P0 |
| C2 | Rolling baseline from last 20 uses, minimum 15 observations | P0 |
| C3 | Three metrics: override rate, false positive rate, finding density | P0 |
| C4 | Revert threshold: relative >50% AND absolute >0.1 | P0 |
| C5 | Recall cross-check via Galiana defect_escape_rate | P1 |
| C6 | Canary expiry on human edit (status: expired_human_edit) | P1 |
| C7 | `/interspect:revert <commit>` with pattern blacklisting | P0 |

### 4.5 Safety Infrastructure (Phase 2)

| ID | Requirement | Priority |
|----|-------------|----------|
| S1 | Protected paths manifest (hooks, confidence function, judge prompt, galiana) | P0 |
| S2 | Git pre-commit hook rejects `[interspect]` commits touching protected paths | P0 |
| S3 | Secret detection in evidence pipeline (redact credential patterns) | P1 |
| S4 | Global modification rate limiter (max N per M sessions) | P1 |
| S5 | Circuit breaker: 3 reverts in 30 days disables target | P1 |

### 4.6 Autonomous Mode (Phase 3)

| ID | Requirement | Priority |
|----|-------------|----------|
| X1 | Opt-in via `/interspect:enable-autonomy` (flag in protected manifest) | P0 |
| X2 | Low/medium-risk auto-apply with canary | P0 |
| X3 | High-risk always requires propose mode | P0 |
| X4 | Shadow testing for prompt tuning (eval corpus + synthetic tests, LLM-as-judge) | P1 |
| X5 | Meta-learning loop with root-cause taxonomy | P1 |

### 4.7 Three Modification Types (v1 scope)

| Type | Description | Risk | Safety Gate |
|------|-------------|------|-------------|
| 1. Context injection | Sidecar files appended to agent prompts (500-token budget) | Medium | Canary |
| 2. Routing adjustment | Per-project `routing-overrides.json` for agent exclusions | Medium | Canary |
| 3. Prompt tuning | Surgical edits to agent `.md` files | Medium | Shadow test + canary |

Types 4-6 (skill rewriting, workflow optimization, companion extraction) deferred to v2.

## 5. Non-Requirements (Explicitly Out of Scope)

- Recursive self-improvement (modifying interspect's own meta-parameters)
- Multi-user isolation (single-user assumption for v1)
- Token/timing instrumentation (Claude Code hook API doesn't support PreToolUse)
- Automatic human override capture from AskUserQuestion (PostToolUse hooks don't receive user responses)
- Full input replay for shadow testing (deferred to v2)

## 6. Success Metrics

| Metric | Target | Measurement |
|--------|--------|-------------|
| `agent_wrong` override rate | Decreasing trend over 90 days | Evidence store: `SELECT COUNT(*) WHERE override_reason='agent_wrong'` per 10-session window |
| Propose-mode acceptance rate | >80% | Track accept/reject via AskUserQuestion responses in `/interspect` command |
| Canary pass rate | >90% | Canary table: `SELECT COUNT(*) WHERE status='passed' / total` |
| Evidence collection uptime | >95% of sessions | `/interspect:health` signal status |
| Time to proposed fix | <3 sessions after pattern appears | Modification timestamp - earliest evidence timestamp for the pattern |

## 7. Dependencies

| Dependency | Status | Impact if Missing |
|------------|--------|------------------|
| Galiana telemetry | Operational | Lose recall cross-check; canary monitoring still works |
| Flux-drive agent roster | Operational | No agents to tune; interspect is useless |
| Beads tracking | Operational | Lose circuit-breaker issue filing |
| Interline statusline | Operational | Lose canary visibility in statusline |
| sqlite3 CLI | Installed (3.45.1) | Evidence store won't work |

## 8. Risks

| Risk | Severity | Mitigation |
|------|----------|-----------|
| Reflexive control loop (agent degrades its own monitoring signals) | High | Protected paths manifest, Galiana recall cross-check, finding density metric |
| Evidence poisoning via prompt injection | High | Sanitization pipeline, XML-delimited structured prompts, hook_id provenance |
| Goodhart's Law (agents become quieter, not better) | Medium | Finding density metric + recall cross-check |
| Over-modification (runaway bug) | Medium | Global rate limiter, per-target circuit breaker |
| Low evidence volume (insufficient signal) | Medium | Phase 1 validates signal quality before any modifications |

## 9. Cross-References

- **Design:** `hub/clavain/docs/plans/2026-02-15-interspect-design.md`
- **Reviews:** `docs/research/fd-*-review-interspect.md`
- **Research:** `docs/research/research-self-improving-ai-systems.md`
- **Roadmap:** `docs/product/interspect-roadmap.md`
- **Feasibility:** `docs/research/research-implementation-feasibility.md`
