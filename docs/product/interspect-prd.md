# Interspect — Product Requirements Document

**Version:** 2.0 (post-Oracle review)
**Date:** 2026-02-15
**Status:** Pre-implementation
**Owner:** Clavain hub
**Design doc:** `hub/clavain/docs/plans/2026-02-15-interspect-design.md`
**Reviews:** `docs/research/fd-*-review-interspect.md` (7 agents)
**Oracle review:** `docs/research/oracle-interspect-review.md`
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
- Canary alert rate <10% (modifications don't degrade agent quality)
- Time from pattern detection to proposed fix: < 3 sessions

## 2. Solution Overview

Interspect is Clavain's **observability-first** improvement engine — an OODA loop that:
1. **Observes** — Collects evidence about agent performance (overrides, false positives, corrections)
2. **Orients** — Detects patterns across sessions and projects via counting-rule thresholds
3. **Decides** — Proposes modifications (overlays, routing adjustments) for human approval
4. **Acts** — Applies reversible overlays with canary monitoring and alerting

**Key constraints:**
- **Observability-first, not autonomy-first.** The product is visibility into agent performance. Modification is a feature of the observability platform, not the product itself.
- **Continuously self-improving, not recursively self-improving.** Interspect improves agents, not itself. Its own safety infrastructure (counting rules, canary logic, protected paths) is immutable.
- **Overlays, not rewrites.** Canonical agent prompts are never directly edited. Changes are layered via feature-flag overlays that can be instantly toggled.

## 3. User Personas

**Primary:** Solo developer using Clavain for daily code review on 3-5 active projects across Go, Python, and TypeScript.

**Interaction modes:**
- **Passive** (default): Interspect collects evidence silently. User sees session-start summaries when overlays/canaries exist.
- **Active**: User invokes `/interspect` for analysis, `/interspect:correction` to file manual signals, `/interspect:revert` to undo bad changes.
- **Autonomous** (opt-in, Phase 3): Low/medium-risk overlays auto-apply with canary monitoring. High-risk always requires approval. Requires counterfactual shadow evaluation first.

## 4. Requirements

### 4.1 Evidence Collection (Phase 1)

| ID | Requirement | Priority | Feasibility |
|----|-------------|----------|-------------|
| E1 | Collect human override events with reason taxonomy (`agent_wrong`, `deprioritized`, `already_fixed`) | P0 | Confirmed — `/interspect:correction` command |
| E2 | Track session lifecycle (start, end, abandoned/dark sessions) | P0 | Confirmed — SessionStart/Stop hooks (non-blocking) |
| E3 | Track dismissed findings from `/resolve` with dismissal reason | P1 | Confirmed — requires `/resolve` skill instrumentation |
| E4 | Store evidence in SQLite with WAL mode for concurrent access | P0 | Confirmed — `sqlite3` CLI available |
| E5 | Retain raw events 90 days, compute weekly aggregates, archive | P1 | Standard SQL |
| E6 | Sanitize evidence fields (strip control chars, truncate 500 chars, reject injection patterns, tag with hook_id) | P0 | Bash/SQL |
| E7 | Flag abandoned sessions (start_ts but no end_ts after 24h) | P2 | SQL query |

### 4.2 Analysis & Reporting (Phase 1)

| ID | Requirement | Priority |
|----|-------------|----------|
| A1 | `/interspect` command: show detected patterns, suggested tunings with counting-rule confidence | P0 |
| A2 | `/interspect:status [component]`: modification history, canary state, metrics vs baseline | P0 |
| A3 | `/interspect:evidence <agent>`: human-readable evidence summary | P0 |
| A4 | `/interspect:health`: active/degraded signals, evidence counts, canary states | P1 |
| A5 | Session-start summary when overlays/canaries exist (non-blocking) | P1 |

### 4.3 Overlay System (Phase 2)

| ID | Requirement | Priority |
|----|-------------|----------|
| O1 | Feature-flag prompt overlays: `.clavain/interspect/overlays/<agent>/<overlay-id>.md` with runtime concatenation | P0 |
| O2 | 500-token budget per overlay | P0 |
| O3 | Rollback = disable overlay (not git revert) | P0 |
| O4 | Routing overrides: per-project `routing-overrides.json` for agent exclusions | P0 |
| O5 | Propose mode: present overlay diff + evidence summary via AskUserQuestion, one change at a time | P0 |
| O6 | Atomic git commits with structured `[interspect]` message format | P0 |
| O7 | Git operation serialization via flock (concurrent session safety) | P0 |

### 4.4 Confidence Gate (Phase 2)

| ID | Requirement | Priority |
|----|-------------|----------|
| G1 | Counting-rule thresholds: >=3 sessions AND >=2 projects (or >=2 languages) AND >=N events of same typed pattern | P0 |
| G2 | Below threshold: log only (visible in `/interspect` report) | P0 |
| G3 | Above threshold: eligible for propose mode | P0 |
| G4 | No weighted formula in v1 — evaluate whether one adds value in Phase 4 | P1 |

### 4.5 Canary Monitoring (Phase 2)

| ID | Requirement | Priority |
|----|-------------|----------|
| C1 | 20-use or 14-day canary window | P0 |
| C2 | Rolling baseline from last 20 uses, minimum 15 observations | P0 |
| C3 | Three metrics: override rate, false positive rate, finding density | P0 |
| C4 | **Alert on degradation, do not auto-revert** — surface via `/interspect:status` and statusline | P0 |
| C5 | Recall cross-check via Galiana defect_escape_rate | P1 |
| C6 | Canary expiry on human edit (status: expired_human_edit) | P1 |
| C7 | `/interspect:revert <overlay>` with pattern blacklisting — manual trigger only | P0 |

### 4.6 Safety Infrastructure (Phase 2)

| ID | Requirement | Priority |
|----|-------------|----------|
| S1 | Protected paths manifest (hooks, counting rules, judge prompt, galiana) | P0 |
| S2 | Git pre-commit hook rejects `[interspect]` commits touching protected paths | P0 |
| S3 | Secret detection in evidence pipeline (redact credential patterns) | P1 |
| S4 | Global modification rate limiter (max N per M sessions) | P1 |
| S5 | Circuit breaker: 3 reverts in 30 days disables target | P1 |

### 4.7 Autonomous Mode (Phase 3)

| ID | Requirement | Priority |
|----|-------------|----------|
| X1 | Opt-in via `/interspect:enable-autonomy` (flag in protected manifest) | P0 |
| X2 | Low/medium-risk overlays auto-apply with canary | P0 |
| X3 | High-risk always requires propose mode | P0 |
| X4 | Counterfactual shadow evaluation: candidate changes must win in shadow eval before auto-applying | P0 |
| X5 | Eval corpus construction from production reviews — **hard prerequisite for Type 3 (prompt tuning)** | P0 |
| X6 | Meta-learning loop with root-cause taxonomy | P1 |
| X7 | Rare agents = propose-only permanently (insufficient data for canary validation) | P0 |

### 4.8 Privilege Separation (Phase 3)

| ID | Requirement | Priority |
|----|-------------|----------|
| P1 | Unprivileged proposer: can only write to staging directory, cannot write to repo | P0 |
| P2 | Privileged applier: applies allowlisted patch format after verification | P0 |
| P3 | Proposer cannot invoke git commit, cannot write to .git/, cannot alter hooks | P0 |

### 4.9 Modification Types (v1 scope)

| Type | Description | Mechanism | Safety Gate |
|------|-------------|-----------|-------------|
| 1. Context overlay | Feature-flag overlay files appended to agent prompts | `.clavain/interspect/overlays/<agent>/` | Canary alert |
| 2. Routing adjustment | Per-project `routing-overrides.json` for agent exclusions | Enable/disable artifact | Canary alert |
| 3. Prompt tuning | Overlay-based additions to agent behavior (not direct `.md` edits) | Overlay file | Eval corpus + canary alert |

Types 4-6 (skill rewriting, workflow optimization, companion extraction) deferred to v2.

## 5. Non-Requirements (Explicitly Out of Scope)

- Recursive self-improvement (modifying interspect's own meta-parameters)
- Multi-user isolation (single-user assumption for v1)
- Token/timing instrumentation (Claude Code hook API doesn't support PreToolUse)
- Automatic human override capture from AskUserQuestion (PostToolUse hooks don't receive user responses)
- Direct editing of canonical agent `.md` files (use overlay system instead)
- Auto-revert on canary degradation (alert only; human triggers revert)
- Tier 1 session-scoped modifications (log patterns instead; don't auto-adjust mid-session)
- Weighted confidence formula (use counting rules; evaluate weighted formula in Phase 4)

## 6. Success Metrics

| Metric | Target | Measurement |
|--------|--------|-------------|
| `agent_wrong` override rate | Decreasing trend over 90 days | Evidence store: `SELECT COUNT(*) WHERE override_reason='agent_wrong'` per 10-session window |
| Propose-mode acceptance rate | >80% | Track accept/reject via AskUserQuestion responses in `/interspect` command |
| Canary alert rate | <10% | Canary table: overlays triggering degradation alerts / total active canaries |
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
| Reflexive control loop (agent degrades its own monitoring signals) | High | Protected paths manifest, Galiana recall cross-check, finding density metric, privilege separation |
| Evidence poisoning via prompt injection | High | Sanitization pipeline, hook_id provenance, HMAC signing (Phase 3), privilege separation |
| Goodhart's Law (agents become quieter, not better) | Medium | Finding density metric + recall cross-check + counterfactual shadow evaluation |
| Over-modification (runaway bug) | Medium | Global rate limiter, per-target circuit breaker |
| Low evidence volume (insufficient signal) | Medium | Phase 1 validates signal quality before any modifications |
| Mechanical enforcement too soft (Oracle risk #1) | High | Privilege separation (Phase 3): proposer can't write to repo; applier enforces allowlist |
| Metric validity / quiet drift (Oracle risk #2) | High | Counting rules (debuggable), Galiana cross-check, counterfactual evaluation |

## 9. Cross-References

- **Design:** `hub/clavain/docs/plans/2026-02-15-interspect-design.md`
- **Reviews:** `docs/research/fd-*-review-interspect.md`
- **Oracle review:** `docs/research/oracle-interspect-review.md`
- **Research:** `docs/research/research-self-improving-ai-systems.md`
- **Roadmap:** `docs/product/interspect-roadmap.md`
- **Feasibility:** `docs/research/research-implementation-feasibility.md`
