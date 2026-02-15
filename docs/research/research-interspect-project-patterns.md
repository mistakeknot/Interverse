# Interspect Project Analysis — Comprehensive Research Document

**Date:** 2026-02-15  
**Scope:** Complete interspect project discovery within Interverse monorepo  
**Status:** Pre-implementation, Phase 1 focus (Evidence + Reporting)  
**Audience:** Clavain hub team, interflux companions, implementation planning

---

## Executive Summary

**Interspect** is Clavain's observability-first self-improvement engine — an OODA loop (Observe → Orient → Decide → Act) that systematically captures evidence about agent performance and proposes safe, reversible modifications (overlays and routing overrides) based on that evidence.

**Key positioning:** The product is visibility into agent performance. Modification is a feature of the observability platform, not the platform itself. Observability ships first (Phase 1), then safe overlays (Phase 2), then autonomy with shadow evaluation (Phase 3).

**Status:** Pre-implementation. Design completed 2026-02-15. 28 beads in dependency graph, 17 open + 11 closed. Phase 1 gate: >=50 evidence events, >=10 sessions. Target: 4-week Phase 1 implementation.

---

## 1. Project Location & Structure

### Directory Layout

```
/root/projects/Interverse/
├── docs/
│   ├── product/
│   │   ├── interspect-prd.md              # Product requirements (v2.0)
│   │   ├── interspect-vision.md           # Strategic vision document
│   │   └── interspect-roadmap.md          # 3-phase implementation roadmap
│   └── research/
│       ├── oracle-interspect-review.md    # GPT-5.2 Pro strategic review (215 lines)
│       ├── fd-architecture-review-interspect.md
│       ├── fd-safety-review-interspect.md
│       ├── fd-correctness-review-interspect.md
│       ├── fd-feedback-loops-review-interspect.md
│       ├── fd-measurement-validity-review-interspect.md
│       ├── fd-self-modification-review-interspect.md
│       ├── fd-user-product-review-interspect.md
│       └── research-self-improving-ai-systems.md
├── hub/clavain/
│   ├── docs/plans/
│   │   └── 2026-02-15-interspect-design.md  # Design doc v3 (620 lines, comprehensive)
│   ├── commands/
│   │   ├── interspect.md                    # Main analysis command
│   │   ├── interspect-status.md             # Canary + modification status
│   │   ├── interspect-evidence.md           # Evidence summary for agent
│   │   ├── interspect-health.md             # Collection uptime + signal health
│   │   └── interspect-correction.md         # Manual override signal command
│   ├── hooks/
│   │   ├── lib-interspect.sh                # Shared library (478 lines, fully implemented)
│   │   ├── interspect-evidence.sh           # PostToolUse hook for /resolve dismissals
│   │   ├── interspect-session.sh            # SessionStart hook
│   │   └── interspect-session-end.sh        # Stop hook
│   └── scripts/
│       └── interspect-init.sh               # SQLite DB + table init
├── .clavain/interspect/
│   ├── interspect.db                        # SQLite evidence store (36K, WAL mode)
│   ├── protected-paths.json                 # Allowed/protected file list (enforced by hooks)
│   └── confidence.json                      # Counting-rule thresholds
└── hub/clavain/.clavain/interspect/
    ├── interspect.db                        # Clone/test database (empty)
    ├── protected-paths.json                 # Same structure (179 bytes)
    └── confidence.json                      # Same structure
```

**Total interspect files:** 24 across the monorepo.  
**Database size:** 36K (main), 0 (test clone).

---

## 2. Core Concept & Design

### The OODA Loop

Interspect implements a continuous feedback cycle:

1. **Observe** — Collect evidence about agent performance:
   - `agent_wrong` overrides via `/interspect:correction` command
   - Session lifecycle (start/stop, abandoned sessions)
   - Dismissed findings from `/resolve` command
   - Future: token usage, timing, defect escapes via Galiana

2. **Orient** — Detect patterns via counting-rule confidence gate:
   - >=3 sessions AND >=2 projects/languages AND >=N events of same pattern type
   - Below threshold: logged only (visible in `/interspect` report)
   - Above threshold: eligible for proposals

3. **Decide** — Propose modifications via `AskUserQuestion`:
   - Context overlays (Type 1): `.clavain/interspect/overlays/<agent>/*.md` appended to agent prompt
   - Routing adjustments (Type 2): `.claude/routing-overrides.json` per-project exclusions
   - Prompt tuning (Type 3): overlay-based, requires eval corpus first

4. **Act** — Apply reversible changes with monitoring:
   - Atomic git commits with `[interspect]` message format
   - Canary monitoring: 20-use or 14-day window
   - Three metrics: override rate, FP rate, finding density (Goodhart's Law protection)
   - Alert on degradation (do NOT auto-revert) — human approves revert

### Key Design Principles (from v2 post-Oracle)

| Principle | Rationale | Implementation |
|-----------|-----------|-----------------|
| **Observability-first** | Ship visibility before autonomy | Phase 1 = 4 weeks evidence collection, zero modifications |
| **Overlays not rewrites** | Instant rollback, A/B testable, upstream-mergeable | `.clavain/interspect/overlays/<agent>/` with runtime concatenation |
| **Propose-mode default** | User expects control when tool modifies itself | Autonomy is opt-in via `/interspect:enable-autonomy` (Phase 3) |
| **Meta-rules immutable** | Safety infrastructure cannot be self-modified | Protected paths manifest + git pre-commit hook enforcement |
| **Counting rules, not formulas** | Simpler, debuggable, no arbitrary weightings | 3 thresholds: sessions, projects/languages, event count |
| **Canary: detect+alert, no auto-revert** | 80% safety with 20% complexity | Alert via `/interspect:status` + statusline; human triggers revert |
| **Evidence compounds, assumptions don't** | Type 3 (prompt tuning) requires real eval corpus, not synthetic | Eval corpus is hard prerequisite in Phase 3 |

---

## 3. Evidence Architecture

### SQLite Schema (WAL Mode)

**Tables:**

```sql
evidence (
  id, ts, session_id, seq, source, source_version, event,
  override_reason, context, project, project_lang, project_type
)
sessions (session_id, start_ts, end_ts, project)
canary (
  id, file, commit_sha, group_id, applied_at,
  window_uses, uses_so_far, window_expires_at,
  baseline_override_rate, baseline_fp_rate, baseline_finding_density,
  baseline_window, status, verdict_reason
)
modifications (
  id, group_id, ts, tier, mod_type, target_file,
  commit_sha, confidence, evidence_summary, status
)
```

**Why SQLite:** v1 used JSONL append-only files. Concurrent sessions with atomic renames lose events (second writer clobbers first). SQLite WAL provides concurrent reads, serialized writes, ACID transactions.

**Retention policy:**
- Raw events: 90 days
- Aggregates: weekly, retained indefinitely
- Dark sessions: flagged after 24h with no end_ts

### Collection Points (Phase 1)

| Signal | Source | Status | Notes |
|--------|--------|--------|-------|
| Human override | `/interspect:correction <agent> <desc>` | Confirmed | Sole mechanism for override signals — PostToolUse hooks cannot capture AskUserQuestion responses |
| Dismissed findings | `/resolve` command hook | Confirmed | Requires instrumentation |
| Session lifecycle | SessionStart/Stop hooks | Confirmed | Non-blocking, timestamps buffered to avoid observer effect |
| Token usage | Task tool dispatch wrapping | Deferred | Requires investigation — may not be feasible from plugin hooks |
| Defect escapes | Galiana telemetry | Planned | Used as recall cross-check, not primary signal |

### Sanitization Pipeline

Evidence fields are sanitized before insertion:

1. Strip ANSI escape sequences
2. Strip control characters (0x00-0x08, 0x0B-0x0C, 0x0E-0x1F)
3. Truncate to 500 chars (DoS prevention)
4. Redact secrets (API keys, tokens, credentials, connection strings)
5. Reject instruction-like patterns (heuristic scanner: `<system>`, `ignore previous`, `you are now`, etc.)

**Redaction patterns:** AWS keys (AKIA*), GitHub tokens (gh[ps]_*, github_pat_*), Anthropic keys (sk-ant-*), OpenAI keys (sk-*), connection strings (proto://user:pass@host).

### Override Reason Taxonomy

Not all overrides indicate agent wrongness:

- **`agent_wrong`** — Finding was incorrect (quality signal) — feeds prompt tuning
- **`deprioritized`** — Finding correct but not worth fixing now (priority signal)
- **`already_fixed`** — Finding correct but stale (context signal)

Only `agent_wrong` overrides drive quality-related modifications. All three feed pattern detection.

---

## 4. Confidence Gate & Pattern Detection

### Counting-Rule Thresholds (Simple, Debuggable)

A pattern is **ready for proposal** when ALL of:

- Evidence from **>=3 sessions** (protects against systematic bias in one session)
- Evidence from **>=2 projects** OR **>=2 languages** (cross-project diversity)
- **>=N events** of same typed pattern (default N=5, calibrated from real data)

**Classification levels:**

- **Ready** (all 3 met) → "Eligible for Phase 2 proposal"
- **Growing** (1-2 met) → Show which criteria not yet met, watch progress
- **Emerging** (<1 met) → "Watching"

**Why not weighted confidence?** v1's weighted formula (evidence_count * 0.3 + cross_session * 0.3 + ...) is arbitrary until calibrated. Simple thresholds are easier to reason about, debug, and explain. Evaluate weighted scoring in Phase 4 after 3 months of data.

### Pattern Definition

Two override events match the "same pattern" if:

- Same `source` (agent)
- Same event type
- Similar `context` (determined by LLM similarity at logging time — not post-hoc matching)

Pattern IDs assigned at evidence insertion.

---

## 5. Modification Pipeline & Safety

### Three Modification Types (v1 Scope Only)

| Type | Description | Location | Risk | Gate |
|------|-------------|----------|------|------|
| **1. Context Overlay** | Feature-flag `.md` files appended to agent prompt | `.clavain/interspect/overlays/<agent>/<id>.md` | Medium | Canary alert |
| **2. Routing Adjustment** | Per-project `routing-overrides.json` for agent exclusions | `.claude/routing-overrides.json` | Medium | Canary alert |
| **3. Prompt Tuning** | Overlay-based additions to agent behavior | `.clavain/interspect/overlays/<agent>/<id>.md` | Medium | Eval corpus + canary |

**Deferred to v2:** Types 4-6 (skill rewriting, workflow optimization, companion extraction) — no evidence they're needed yet.

### Modification Pipeline (Classify → Generate → Gate → Apply → Monitor → Verdict)

1. **Classify** — What kind of change? Check against modification allow-list. Reject changes to files outside allow-list.
2. **Generate** — Produce concrete diff to target file(s). Tag with modification group ID.
3. **Safety gate** — Route by risk level (see table above).
4. **Apply** — In propose mode: present diff via `AskUserQuestion`, one change at a time. In autonomous mode: atomic git commit + serialize via `flock`.
5. **Monitor** — Insert canary record in SQLite. Compare next N uses against rolling baseline.
6. **Verdict** — After canary window: keep (better/neutral) or revert (worse). Log outcome as evidence.

**One active canary per target:** If a file has active canary, new modifications deferred until canary closes.

### Protected Paths Manifest

**Location:** `.clavain/interspect/protected-paths.json`

```json
{
  "protected_paths": [
    "hooks/*.sh",
    "hooks/hooks.json",
    ".clavain/interspect/protected-paths.json",
    ".clavain/interspect/confidence.json",
    ".clavain/interspect/shadow-judge-prompt.md",
    "galiana/**"
  ],
  "modification_allow_list": [
    ".clavain/interspect/overlays/**/*.md",
    ".claude/routing-overrides.json"
  ],
  "always_propose": [
    ".clavain/interspect/overlays/**/*.md"
  ]
}
```

**Enforcement:** 
1. Modification pipeline's Classify step checks against allow-list.
2. Git pre-commit hook rejects `[interspect]` commits touching protected paths.
3. Protected paths, confidence params, and judge prompt are in protected list — interspect cannot modify its own safety.

### Canary Monitoring (Detect + Alert, No Auto-Revert)

After applying change, canary record inserted:

- **Window:** 20 uses OR 14 days (whichever first)
- **Baseline:** Last 20 uses before modification, minimum 15 observations, recomputed if >30 days old
- **Three metrics:** override rate, FP rate, finding density (Goodhart's Law cross-check)
- **Alert threshold:** Relative increase >50% AND absolute increase >0.1
- **Action:** Alert via `/interspect:status` + statusline. Do NOT auto-revert. Human triggers `/interspect:revert <commit>` manually.
- **Recall cross-check:** Check Galiana `defect_escape_rate` during window — escalate if it increased
- **Expiry on human edit:** If human directly edits monitored file, canary invalidated (`expired_human_edit`)

---

## 6. Three-Phase Rollout

### Phase 1: Evidence + Reporting (4 weeks)

**Deliverables:**
- SQLite evidence store, WAL mode, sanitization, 90-day retention
- Evidence collection hooks (overrides, session lifecycle, dismissals)
- `/interspect` command (pattern detection + classification)
- `/interspect:status`, `/interspect:evidence`, `/interspect:health` commands
- Session-start summary when overlays/canaries exist
- **Zero modifications applied**

**Gate:** >=50 evidence events, >=10 sessions before Phase 2

**Beads:** iv-o4x7, iv-ev9d, iv-c38n, iv-i2fr, iv-t7f3, iv-qeu0, iv-jcjz, iv-lb0f, iv-m6cd, iv-sw17

### Phase 2: Overlays + Canary Alerting (4 weeks)

**Deliverables:**
- Overlay system (Type 1) and routing overrides (Type 2) in propose mode
- Counting-rule confidence gate
- Protected paths manifest + git pre-commit hook
- Canary monitoring (3 metrics, alert only)
- `/interspect:revert` command (manual one-command revert + blacklisting)
- Secret detection + git operation serialization via `flock`

**Gate:** >70% proposal acceptance, >=10 proposals before Phase 3

**Beads:** iv-2nt4, iv-i03k, iv-nrnh, iv-vrc4, iv-nkak, iv-jkce, iv-fbrx, iv-cylo, iv-ukct, iv-88yg, iv-sisi, iv-003t

### Phase 3: Autonomy + Eval Corpus (6 weeks)

**Deliverables:**
- Autonomous mode flag (opt-in via `/interspect:enable-autonomy`)
- Eval corpus construction from production reviews (hard prereq for Type 3)
- Counterfactual shadow evaluation on real traffic
- Prompt tuning (Type 3) in propose mode, overlay-based
- Privilege separation (unprivileged proposer + privileged applier)
- Meta-learning loop with root-cause taxonomy
- Circuit breaker (3 reverts in 30 days disables target)

**Gate:** <10% canary alert rate, >=20 canary windows, eval corpus covers >=3 agent domains

**Beads:** iv-5su3, iv-izth, iv-435u, iv-t1m4, iv-drgo, iv-rafa, iv-0fi2, iv-bj0w, iv-g0to, iv-c2b4

### Phase 4: Evaluate + Expand (Ongoing)

- Calibrate counting-rule thresholds against 3 months of data
- Evaluate weighted confidence function benefit over simple rules
- Cross-model shadow testing (Oracle as independent judge)
- Consider autonomous Type 3 if acceptance >80% AND eval corpus sufficient
- Evaluate Types 4-6 based on manual improvement patterns

---

## 7. Beads Dependency Graph

### Open Beads (17)

**Blocked by iv-nkak (Routing overrides — critical blocker):**
- iv-vrc4 [P1] — Overlay system (Type 1)
- iv-435u [P2] — Counterfactual shadow evaluation
- iv-88yg [P2] — Structured commit message format
- iv-drgo [P2] — Privilege separation (proposer/applier)
- iv-003t [P2] — Global modification rate limiter
- iv-cylo [P1] — Canary monitoring (detect + alert)
- iv-izth [P2] — Eval corpus construction
- iv-sisi [P2] — Interline statusline integration

**Blocked by iv-cylo (Canary monitoring):**
- iv-ukct [P1] — `/interspect:revert` command
- iv-rafa [P2] — Meta-learning loop
- iv-5su3 [P2] — Autonomous mode flag
- iv-t1m4 [P2] — Prompt tuning (Type 3)
- iv-jo3i [P1] — Canary verdict engine (completed)

**Other open:**
- iv-c2b4 [P2] — `/interspect:disable` command
- iv-bj0w [P2] — Conflict detection
- iv-m6cd [P2] — Session-start summary injection
- iv-g0to [P2] — `/interspect:reset` command

### Closed Beads (11)

**Completed foundational work:**
- iv-o4x7 — SQLite schema + init (blocks all Phase 1/2)
- iv-ev9d — Evidence collection hook
- iv-c38n — Session lifecycle hooks
- iv-i2fr — `/interspect:correction` command
- iv-t7f3 — `/interspect` command (pattern detection)
- iv-qeu0 — `/interspect:status` command
- iv-jcjz — `/interspect:evidence` command
- iv-sw17 — Evidence sanitization pipeline

**Design fixes (completed):**
- iv-3jir — Removed AskUserQuestion response capture claim
- iv-qhdc — Removed Tier 1 (session-scoped modifications)
- iv-3pje — Added privilege separation design
- iv-2nt4 — Counting-rule confidence gate
- iv-i03k — Protected paths manifest
- iv-nrnh — Git pre-commit hook
- iv-jkce — Git operation serialization (flock)
- iv-fbrx — Secret detection in evidence pipeline
- iv-jo3i — Canary verdict engine
- iv-u80a, iv-0dha, iv-2hm5, iv-84m3 — Other design fixes

---

## 8. Key Routing Patterns

### Routing Overrides (Type 2 Modification)

Per-project `routing-overrides.json` stored at `.claude/routing-overrides.json` in project root.

**Purpose:** Exclude agents from dispatch, override model selection.

**Example structure (inferred from design):**

```json
{
  "agent_exclusions": {
    "fd-game-design": ["backend-service"],
    "fd-performance": ["prototype"]
  },
  "model_overrides": {
    "fd-safety": "claude-opus-4-6"
  }
}
```

**Consumption:** Flux-drive triage reads overrides before dispatching agents. Scoped to current project only.

**Integration:** Interspect modifies routing-overrides.json. Flux-drive reads it as input to triage logic. See `hub/clavain/skills/using-clavain/references/routing-tables.md` for 3-layer routing context.

---

## 9. Oracle Review Findings (GPT-5.2 Pro, 2026-02-15)

### Strategic Recommendation

**"Ship as observability-first product, treat autonomy as gated experiment."**

Key points:
1. **Dominant failure mode:** slow drift from weak proxies (override/FP rates), not "one bad diff"
2. **Dominant security risk:** prompt injection + excessive agency + write access to git mechanics
3. **Operational risk:** anything touching hooks + evidence + canaries is correctness minefield

### Simplification Opportunities (Adopted in v2)

1. **Drop Tier 1** (session-scoped mods) — marginal gain for complexity cost
2. **Collapse confidence to counting rules** — debuggable, not arbitrary formula
3. **Canary: detect+alert only** — 80% safety with 20% complexity, avoid revert-chain edge cases
4. **Defer Type 3** until eval corpus exists — synthetic tests give false confidence
5. **Privilege separation** — unprivileged proposer (write to staging only) + privileged applier (allowlisted patches)

### Novel Ideas (Deferred to Phase 3+)

1. **Outcome-first evidence** (not interaction-first) — test failures, CI deltas, defect escapes
2. **Counterfactual shadow evaluation** — run candidate in shadow path on real traffic before auto-applying
3. **Evidence provenance signing** — HMAC-sign evidence rows to prevent forgery
4. **Bandit learning for routing** — contextual bandit instead of fixed thresholds

### Three Remaining Risks (Prioritized)

| Risk | Severity | Mitigation |
|------|----------|-----------|
| **Mechanical enforcement too soft** | High | Privilege separation (Phase 3) — proposer literally cannot write to repo |
| **Metric validity + calibration** | High | Counting rules (debuggable), Galiana cross-check, counterfactual eval |
| **Operational reliability** | High | SQLite fixes concurrency, but still need boring reliability; avoid big experimental swings |

---

## 10. Architecture Integration Points

### With Flux-drive (Agent Dispatch)

**Observation:** Interspect monitors agent dispatches via flux-drive triage.  
**Modification:** Interspect modifies `routing-overrides.json` read by flux-drive before dispatch.  
**Risk:** Circular dependency — interspect observes flux-drive → modifies routing → changes evidence quality.  
**Mitigation:** Canary monitoring detects degradation; protected paths prevent modifying flux-drive skills.

### With Auto-Compound (Knowledge Capture)

**Observation:** Interspect runs AFTER auto-compound Stop hook (sentinel protocol).  
**Modification:** None directly; interspect observes auto-compound evidence.  
**Coordination:** Both participate in shared sentinel protocol (`/tmp/clavain-stop-${SESSION_ID}`).

### With Signal Engine (Evidence Collection)

**Observation:** Interspect consumes signals from `lib-signals.sh`.  
**Modification:** Interspect modifies agent prompts that produce signals.  
**Risk:** REFLEXIVE LOOP — interspect's changes can degrade signal quality, leading to self-degradation.  
**Mitigation:** Finding density metric + Galiana defect_escape_rate cross-check detect signal degradation.

### With Galiana (Telemetry)

**Observation:** Interspect reads Galiana telemetry (`~/.clavain/telemetry.jsonl`) for recall cross-check.  
**Modification:** None.  
**Use case:** Canary monitoring checks Galiana `defect_escape_rate` — if escape rate increased during canary window, escalate alert severity.

---

## 11. Remaining Open Questions

### From Design Doc

1. **Confidence function calibration** — Initial thresholds (3 sessions, 2 projects, 5 events) are conservative guesses. Need 3 months real data to calibrate.
2. **Token/timing instrumentation** — Can Task tool dispatch be instrumented from plugin hooks? If not, Type 5 (workflow optimization) may never be feasible.
3. **Multi-user isolation** — Current design assumes single-user. If Clavain shared, need per-user evidence stores + scoped modifications.
4. **LLM judge calibration** — Shadow testing judge has known biases. Randomized presentation + calibration against human judgments on held-out set needed.

### From Oracle Review

1. **Outcome-first evidence strategy** — Should interspect collect test failures, CI deltas, defect escapes, time-to-resolution as primary signals instead of interaction-first (overrides/dismissals)?
2. **Counterfactual evaluation feasibility** — How much real-traffic data needed to build representative shadow eval corpus? When should this flip from "propose mode" to "shadow eval + canary"?
3. **Evidence poisoning resilience** — HMAC signing, or just rely on hook_id provenance + manual review?

---

## 12. Key Files Reference

| File | Purpose | Lines | Status |
|------|---------|-------|--------|
| `docs/product/interspect-prd.md` | Product requirements (v2.0) | 200 | Approved |
| `docs/product/interspect-vision.md` | Strategic vision + design principles | 107 | Approved |
| `docs/product/interspect-roadmap.md` | 3-phase rollout + critical path | 210 | Approved |
| `hub/clavain/docs/plans/2026-02-15-interspect-design.md` | Complete design doc (v3) | 620 | Pre-implementation |
| `docs/research/oracle-interspect-review.md` | GPT-5.2 Pro strategic review | 215 | Approved, integrated into v2 |
| `hub/clavain/hooks/lib-interspect.sh` | Shared library (fully implemented) | 478 | Production-ready |
| `hub/clavain/.clavain/interspect/protected-paths.json` | Safety enforcement manifest | 18 | In use |
| `hub/clavain/.clavain/interspect/confidence.json` | Counting-rule thresholds | 5 | In use |
| 7x `fd-*-review-interspect.md` | Flux-drive specialist reviews | ~1500 total | Integrated into design |

---

## 13. Implementation Readiness Checklist

### Phase 1 Prerequisites (All Complete)

- [x] Design finalized (post-Oracle 2026-02-15)
- [x] Protected paths manifest defined
- [x] SQLite schema + WAL mode confirmed
- [x] lib-interspect.sh fully implemented (478 lines)
- [x] Evidence sanitization pipeline designed
- [x] Counting-rule confidence gate specified
- [x] Commands interface documented (5 commands)
- [x] Hooks architecture specified (3 hooks)
- [x] Beads dependency graph complete (28 beads, 11 closed, 17 open)
- [x] Oracle review integrated + simplifications adopted

### Phase 1 Implementation Tasks

- **iv-o4x7** — SQLite schema + init script
- **iv-ev9d** — Evidence collection hook (`/resolve` dismissals)
- **iv-c38n** — Session lifecycle hooks (SessionStart/Stop)
- **iv-i2fr** — `/interspect:correction` command
- **iv-t7f3** — `/interspect` command (pattern detection)
- **iv-qeu0** — `/interspect:status` command
- **iv-jcjz** — `/interspect:evidence` command
- **iv-sw17** — Evidence sanitization (design complete, code TBD)
- **iv-lb0f** — `/interspect:health` command
- **iv-m6cd** — Session-start summary injection

---

## 14. Success Metrics

| Metric | Target | Measurement |
|--------|--------|-------------|
| `agent_wrong` override rate | Decreasing trend over 90 days | Evidence store: overrides per 10-session window |
| Propose-mode acceptance rate | >80% | Track accept/reject in `/interspect:status` command |
| Canary alert rate | <10% | Overlays triggering alerts / total active canaries |
| Evidence collection uptime | >95% of sessions | `/interspect:health` signal status |
| Time to proposed fix | <3 sessions after pattern appears | Modification timestamp - earliest evidence timestamp |

---

## 15. Cross-References & Dependencies

### External Integrations

- **Galiana** — Telemetry source for defect escape rate cross-check (operational)
- **Flux-drive** — Agent dispatch triage reads routing-overrides.json (operational)
- **Interflux** — Core agent prompts subject to interspect modifications (operational)
- **Interline** — Statusline integration for canary visibility (operational, Phase 2)
- **Interphase** — Phase tracking for gate enforcement (optional, Phase 2+)
- **Interlock** — Multi-agent coordination for concurrent session safety (optional, Phase 2)

### Upstream Repos

- `hub/clavain/` — Primary implementation location
- `plugins/interflux/` — Agent roster, triage logic
- `plugins/interline/` — Statusline rendering

---

## Summary

**Interspect** is a well-researched, carefully scoped self-improvement system for Clavain with:

- **Clear scope:** Evidence collection (Phase 1) → safe overlays + routing (Phase 2) → autonomy + eval (Phase 3)
- **Rigorous safety design:** Protected paths, counting rules, canary monitoring (detect+alert), privilege separation
- **Production-ready architecture:** SQLite with WAL, sanitization pipeline, git serialization via flock
- **Strategic alignment:** Observability-first, propose-mode default, evidence compounds (not assumptions)

Phase 1 is ready for immediate implementation — 10 beads, 4 weeks, zero modifications applied, pure observability value. The design has been validated by 7 flux-drive specialists + Oracle (GPT-5.2 Pro) review, with all major recommendations integrated into v2.
