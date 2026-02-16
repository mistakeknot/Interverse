# Architecture Review: Interspect Design

**Reviewer:** flux-drive architecture specialist
**Date:** 2026-02-15
**Document:** `/root/projects/Interverse/hub/clavain/docs/plans/2026-02-15-interspect-design.md`
**Focus:** Module boundaries, coupling, complexity, and sidecar pattern

---

## Executive Summary

Interspect proposes a self-improvement engine for Clavain that autonomously modifies skills, prompts, routing, and workflows based on accumulated evidence. The design introduces **significant architectural risk** through tight coupling with existing systems (auto-compound, signal engine, flux-drive), premature complexity in the four-cadence model, and unclear ownership boundaries for evidence collection. The sidecar pattern for context injection is sound, but the modification pipeline lacks fail-safes for cascade failures and creates circular dependencies between interspect and the components it monitors.

**Critical Finding:** Interspect observes flux-drive, auto-compound, and the signal engine, but also modifies the prompts and routing that these systems depend on. This creates a **reflexive control loop** where interspect's own bugs can degrade the signal quality it uses for decision-making, leading to compounding self-degradation rather than improvement.

---

## 1. Boundaries & Coupling

### 1.1 Module Boundary Violations

**Problem:** Interspect reaches across multiple subsystem boundaries without a clear integration contract.

| Subsystem | Current Boundary | Interspect Coupling | Risk Level |
|-----------|-----------------|---------------------|------------|
| **auto-compound** | Stop hook → `hooks/auto-compound.sh` | Interspect observes Stop hook events, modifies agent prompts that auto-compound dispatches | **HIGH** — Modifies upstream behavior without versioned contract |
| **signal engine** | `hooks/lib-signals.sh` → shared signal detection | Interspect consumes signals AND modifies the agents that produce signals | **CRITICAL** — Reflexive loop can degrade own input quality |
| **flux-drive** | Skill → `plugins/interflux/skills/flux-drive/SKILL.md` | Interspect modifies agent prompts, routing-overrides.json, and triage weights used by flux-drive | **HIGH** — No isolation between observer and modification target |
| **routing system** | `skills/using-clavain/SKILL.md` → 3-layer routing table | Interspect writes `routing-overrides.json` read by routing logic | **MEDIUM** — Well-scoped interface, but override semantics unclear |

**Specific violation:** The design states interspect "wraps subagent calls with cost tracking" (Section 3.1, Table). This requires **instrumenting the Task tool invocation path** — a cross-cutting concern that affects every agent dispatch. Where does this instrumentation live? If it's in flux-drive phase code, interspect has write-coupled to flux-drive's dispatch logic. If it's a PostToolUse hook on Task, interspect now monitors ALL agent dispatches system-wide, not just flux-drive reviews.

**Recommendation:** Define a **versioned integration contract** for each subsystem interspect observes or modifies. Use explicit interfaces (e.g., `signal_engine_v1.collect_evidence()`, `flux_drive_v1.get_triage_overrides()`) rather than direct file manipulation. This allows subsystems to evolve without breaking interspect and provides rollback points when interspect modifications fail.

### 1.2 Evidence Collection Ownership

**Problem:** Evidence collection is scattered across multiple hook points with no clear owner.

The design proposes collection points in:
- PostToolUse hook on flux-drive/quality-gates (override signals)
- Hook on `/resolve` command (false positive signals)
- Diff between agent output and committed version (correction signals)
- Wrap on subagent calls (token usage)
- Timestamps in signal engine (timing)
- Periodic batch scan (extraction signals)

**Who owns these hooks?** If interspect adds 5 new PostToolUse hooks, does it pollute the global hook namespace? Does it conflict with Clavain's existing `auto-compound.sh`, `interserve-audit.sh`, `auto-publish.sh` hooks? The design doesn't specify hook registration strategy.

**Missed integration point:** The design assumes access to "User edits agent output" via diff tracking (Section 3.1, Table row 3). How is this diff captured? Clavain has no existing "track uncommitted edits" mechanism. This either requires:
1. A new PostToolUse hook on Edit/Write that snapshots agent output before human edits (invasive, expensive)
2. Git working-tree diff analysis (fragile — can't distinguish agent output from human output without metadata)
3. Integration with beads (if work is tracked) to capture resolution diffs

**Recommendation:** Consolidate evidence collection into a single **evidence bus** abstraction. All hooks write events to a common JSONL stream (already proposed as `.clavain/interspect/evidence/`), but the hooks themselves are registered and owned by interspect, not scattered across Clavain core. This clarifies ownership and prevents hook conflicts.

### 1.3 Coupling to Auto-Compound

**Critical coupling:** Interspect's "End-of-Session" cadence (Section 3.2, Cadence 2) triggers at "signal-weight engine, weight ≥ 3 (alongside auto-compound)".

This means:
1. Interspect **depends on** the signal-weight threshold used by auto-compound (currently weight ≥ 3, defined in `hooks/auto-compound.sh:87`).
2. If auto-compound changes its threshold or signal definitions, interspect's trigger condition silently changes.
3. Interspect's modifications to agent prompts can change the language patterns agents use, which changes signal detection (e.g., if an agent stops saying "root cause", `lib-signals.sh:48` no longer fires), which changes auto-compound behavior, which changes interspect's trigger frequency.

**This is a hidden circular dependency.** Auto-compound's threshold is not a stable API — it's an internal tuning parameter. Binding interspect's lifecycle to it creates fragile coupling.

**Recommendation:** Decouple interspect's session-end trigger from auto-compound's signal threshold. Use an **independent evidence threshold** based on interspect's own signal accumulation (e.g., "≥ 2 override events in session" or "≥ 5 total evidence events across last 3 sessions"). If interspect must coordinate with auto-compound, use an **explicit coordination contract** (e.g., both read from a shared `session-metadata.json` written by the Stop hook).

### 1.4 Sidecar Pattern Evaluation

**Strength:** The sidecar file pattern (`interspect-context.md` appended to agent prompts) is a good boundary. It isolates interspect's injected context from human-authored agent prompts, making rollback clean and ownership clear.

**Weakness:** The design doesn't specify **how sidecars are read**. Are they:
- Concatenated to agent `.md` files at SessionStart (requires modifying session-start.sh)?
- Read dynamically by the Task tool dispatcher (requires modifying dispatch logic in flux-drive or Clavain core)?
- Injected via a new hook on agent dispatch (adds latency to every Task call)?

**Missed constraint:** Agent context budgets are tight (typical agent prompt is 1.5-2K tokens). If sidecar files grow unbounded with "learning auto-injection" (Cadence 2, mechanism description), agents will hit context limits and truncate critical instructions. The design has no **sidecar budget** or pruning strategy.

**Recommendation:** Specify the sidecar injection mechanism explicitly (favor SessionStart concatenation for simplicity). Add a **sidecar budget** (e.g., max 500 tokens per sidecar, enforced at write time). When budget is exceeded, interspect must either consolidate learnings or promote them to the core agent prompt (which requires shadow testing).

---

## 2. Pattern Analysis

### 2.1 Four-Cadence Complexity

**Problem:** The design introduces four cadences (within-session, end-of-session, periodic batch, threshold gate), but the **justification for four distinct execution contexts is weak**.

Let's trace the actual behavior:

| Cadence | Trigger | Scope | Safety | Unique Capability |
|---------|---------|-------|--------|-------------------|
| 1: Within-Session | After each review cycle | In-memory only | None (dies with session) | Immediate pattern detection (e.g., "same override twice") |
| 2: End-of-Session | Stop hook, weight ≥ 3 | Persistent, atomic commits | Canary flag | Cross-session evidence aggregation (≥ 2 sessions) |
| 3: Periodic Batch | `/interspect` or every 10 sessions | Structural changes, multi-file | Shadow testing | Companion extraction, workflow optimization |
| 4: Threshold Gate | N/A (filter, not cadence) | N/A | N/A | Confidence thresholding (0.3 / 0.7 / 0.9) |

**Analysis:**
- **Cadence 1** (within-session) has a unique capability: immediate reactive tuning. This is valuable for hot-path optimization (e.g., "agent X produced zero findings for 3 files in a row, demote it").
- **Cadence 4** is not a cadence — it's a **decision gate** applied to all other cadences. Misclassified.
- **Cadence 2 vs. Cadence 3** differ only in **scope** (single-file tweaks vs. multi-file structural changes) and **trigger frequency** (every session vs. every 10 sessions). These are not conceptually distinct — they're the same pipeline with different risk profiles.

**The real axis is risk level, not cadence.** The design conflates **execution timing** with **modification scope**. This creates unnecessary abstraction layers.

**Simplification:** Collapse to **two tiers**:
1. **Session-scoped modifications** (in-memory or low-risk persistent changes, triggered on Stop hook)
2. **Structural modifications** (multi-file or high-risk changes, triggered on explicit `/interspect` command or confidence threshold)

Both tiers use the same confidence gate (Section 3.2, Cadence 4 formula). Both tiers use the same modification pipeline (Section 3.3). The only difference is **automatic vs. manual trigger** and **risk tolerance**.

**Benefit:** Simpler mental model, fewer code paths, easier testing. The "every 10 sessions" auto-trigger for structural changes can be a policy flag on tier 2 (default: manual only, opt-in: auto every N sessions).

### 2.2 Anti-Pattern: God Module Risk

**Problem:** Interspect observes all agent dispatches, all hooks, all commits, all user corrections, and modifies all prompts, all routing, all workflows. This is the **god module anti-pattern** — a single component with read/write access to the entire system.

**Blast radius:** If interspect has a bug in its modification logic (e.g., generates syntactically invalid agent YAML, writes corrupted routing-overrides.json, or misjudges a shadow test), it can **degrade or break every agent and workflow in Clavain**. The canary monitoring (Section 3.6) only catches this **after the damage propagates to production use**.

**Missing safeguard:** The design states "Interspect cannot modify its own safety gates, canary thresholds, revert logic, or autonomy mode flag" (Section 2). This is good, but insufficient. Interspect also shouldn't be able to:
- Modify the Stop hook that triggers its own execution (circular dependency)
- Modify lib-signals.sh that defines its evidence inputs (input tampering)
- Modify the Task tool dispatcher that invokes agents (infinite loop risk)

**Recommendation:** Introduce a **modification allow-list** that restricts interspect to specific file patterns:
- `agents/*/interspect-context.md` (sidecar files only, not core agent `.md`)
- `.claude/routing-overrides.json` (routing tweaks)
- `.clavain/interspect/` (own state only)

Any modification outside this allow-list requires **propose mode** (human approval via AskUserQuestion), even in "full autonomy" mode. This creates a blast radius boundary.

### 2.3 Reflexive Control Loop

**Critical pattern flaw:** Interspect modifies the agents that produce the evidence interspect consumes.

**Scenario:**
1. Interspect detects "fd-safety agent has 40% false positive rate" (baseline from evidence store).
2. Interspect applies "prompt tightening" — adds "Do NOT flag X when Y" clauses to fd-safety.md.
3. Fd-safety now produces fewer findings overall (both true positives AND false positives drop).
4. Human override rate **appears** to drop (fewer overrides in absolute terms).
5. Interspect interprets this as success, applies more tightening.
6. Fd-safety becomes overly conservative, missing real issues.
7. Interspect has no signal that true positives dropped (because those are missed bugs, not recorded events).

**This is a compounding degradation loop.** Interspect optimizes for **observable metrics** (override rate, false positive rate), but lacks ground truth for **recall** (missed issues). The only signal for degraded recall is "a bug shipped to production" — which is not in the evidence store.

**Recommendation:** Add a **recall validation mechanism**:
- Maintain a **regression test suite** of known-good findings from past reviews (e.g., "fd-safety correctly flagged SQL injection in commit abc123").
- On every prompt modification, re-run the modified agent against this test suite (part of shadow testing).
- If recall drops > 10% (agent misses findings it previously caught), auto-revert the modification **regardless of false positive improvement**.

This breaks the reflexive loop by injecting an external ground truth signal.

### 2.4 Naming and Abstraction Leakage

**Minor issue:** The design uses "cadence" to mean "execution tier" but also "execution frequency" (e.g., "Periodic Batch" cadence). In distributed systems, "cadence" typically refers to Uber's workflow orchestration system. In signal processing, it refers to time intervals. Here it's used for risk classification. This is terminologically confusing.

**Recommendation:** Use **tiers** (tier 1 = in-memory, tier 2 = persistent low-risk, tier 3 = structural high-risk) or **modification levels** to clarify that this is about scope and safety, not timing.

---

## 3. Simplicity & YAGNI

### 3.1 Premature Optimization: Six Modification Types

**Problem:** Section 4 defines six modification types (context injection, routing adjustment, prompt tuning, skill rewriting, workflow optimization, companion extraction). The design provides detailed risk classification and safety gates for all six, but **no evidence that all six are needed now**.

**Usage projection:**
- **Type 1 (context injection)** and **Type 2 (routing adjustment)** are clearly useful — these are low-risk, high-value wins (e.g., "don't run game-design agent on backend services").
- **Type 3 (prompt tuning)** is the core use case driving the design.
- **Type 4-6** (skill rewriting, workflow optimization, companion extraction) are **speculative**. The design provides no evidence these patterns have been manually performed often enough to justify automation.

**Companion extraction (Type 6)** is particularly speculative. The description says "Detect stability signals for tightly-coupled capabilities. Scaffold companion structure. Generate extraction report. **Human does actual implementation**" (emphasis added). If the human does the implementation, this isn't autonomous self-improvement — it's a proposal generator. That's a fundamentally different feature (closer to `/brainstorm` or `/strategy` commands) and doesn't belong in interspect's modification pipeline.

**Recommendation:** **Ship Type 1-3 only** in the first iteration. Defer Type 4-6 until there's evidence they're needed (e.g., "we manually restructured 3 skills based on interspect evidence, should automate this"). Use YAGNI ruthlessly — every modification type adds testing burden, failure modes, and maintenance cost.

### 3.2 Evidence Store Growth

**Problem:** The design acknowledges "How to handle evidence store growth over time?" (Section 6, Open Questions) but defers the answer. This is a **non-optional design decision** for a system that runs indefinitely and appends to JSONL files on every session.

**Growth projection:**
- Assume 10 sessions/day, 5 evidence events/session (conservative).
- 50 events/day × 365 days = 18,250 events/year.
- At ~200 bytes/event (JSON envelope + context), that's 3.6 MB/year — manageable.
- But: if token-usage.jsonl logs **every agent dispatch** (not just sessions), and flux-drive dispatches 5-10 agents per review, that's 50-100 events/day just for token tracking. Now we're at 10-20 MB/year per project.

**For a monorepo with 20 subprojects**, evidence stores across all projects = 200-400 MB/year. This will bloat git repos and slow down evidence queries (grep across 18K+ lines).

**Recommendation:** Design the pruning/archival strategy **now**, not later:
- **Retention policy:** Keep last 90 days of raw events in `.clavain/interspect/evidence/`, archive older events to compressed `.jsonl.gz` monthly snapshots.
- **Aggregation:** Derive summary statistics (e.g., "fd-safety override rate by week") and store in a separate `.clavain/interspect/metrics.jsonl` file. Shadow testing and confidence thresholds can use aggregated metrics instead of raw events.
- **Gitignore raw events:** Only commit aggregated metrics and canary metadata to git. Raw evidence is session-local.

This keeps the design shippable long-term without accumulating unbounded state.

### 3.3 Shadow Testing Complexity

**Problem:** Shadow testing (Section 3.5) requires:
1. Picking 3-5 recent real inputs from evidence store.
2. Running old prompt/skill → capturing output.
3. Running new prompt/skill → capturing output.
4. Comparing via LLM-as-judge.
5. Scoring and deciding.

**This is expensive** (2× agent dispatch + 1 LLM judge call per test case, × 3-5 cases = 7-11 LLM calls per modification). For a "periodic batch" that modifies 3 agents, that's 21-33 LLM calls. At 5-10 seconds per call, shadow testing takes **2-5 minutes** per batch.

**Worse:** Where do the "3-5 recent real inputs" come from? The evidence store only logs **events** (overrides, corrections), not **inputs** (the files reviewed). To replay a review, interspect needs to:
- Store the **original file content** reviewed (not just the finding).
- Store the **agent invocation context** (CWD, project CLAUDE.md, domain profile).
- Reconstruct the Task tool call with the same parameters.

**This is not in the design.** Without stored inputs, shadow testing cannot run.

**Recommendation:** **Simplify shadow testing** for the MVP:
- **Skip input replay.** Instead, generate **synthetic test cases** for each agent (e.g., "fd-safety should flag unsafe user input handling"). Store these in `config/flux-drive/agent-tests/{agent-name}.yaml`.
- Run old vs. new agent prompts against synthetic tests only (not real past inputs).
- This is faster (no evidence replay needed), deterministic (same tests every time), and easier to maintain.
- **Defer full input replay** to a later iteration when there's evidence synthetic tests are insufficient.

### 3.4 Canary Monitoring: Insufficient Sample Size

**Problem:** Section 3.6 describes canary monitoring with "canary_window: 5" — the modified agent must be used 5 times before a verdict is rendered.

**For rarely-used agents, this is too small.** Example:
- `fd-game-design` agent is only relevant for game projects.
- If Clavain reviews 10 projects/week and only 1 is a game, fd-game-design runs once per week.
- Canary window of 5 uses = 5 weeks to verdict.
- In that 5-week window, if 2/5 reviews are false positives (40% rate), is that worse than baseline? Depends on the baseline, but **sample size is too small to be statistically significant** (95% confidence interval for 40% over 5 trials is ±42%, so true rate could be anywhere from 0% to 82%).

**The design assumes all agents have similar usage frequency.** This is false — domain-specific agents (game-design, performance) are used far less often than general agents (architecture, quality).

**Recommendation:** Use **time-bounded canary windows** instead of use-count windows:
- Monitor for 7 days or 5 uses, whichever comes first.
- If < 3 uses in 7 days, extend window to 14 days.
- If still < 3 uses, skip canary verdict (too little data) and rely on manual review via `/interspect --report`.

This prevents rarely-used agents from blocking interspect's improvement loop while avoiding false confidence from small samples.

---

## 4. Key Risks and Mitigations

### Risk 1: Interspect Degrades Itself (Reflexive Failure)

**Scenario:** Interspect modifies signal patterns → auto-compound stops triggering → interspect loses evidence → makes worse modifications → further degradation.

**Likelihood:** HIGH (circular dependency already present in design).

**Mitigation:**
- Add **immutable signal definitions**: `lib-signals.sh` is read-only to interspect.
- Add **recall validation** (regression test suite for agent findings).
- Add **circuit breaker**: if canary revert rate > 50% over 10 modifications, interspect auto-disables and files an issue.

### Risk 2: Hook Namespace Pollution

**Scenario:** Interspect adds 5 PostToolUse hooks → conflicts with Clavain's existing hooks → hooks fire in wrong order or duplicate events.

**Likelihood:** MEDIUM (design doesn't specify hook registration strategy).

**Mitigation:**
- Consolidate interspect's hooks into a **single PostToolUse hook** that routes by tool name (Edit/Write → correction tracking, Task → cost tracking, Bash → auto-publish coordination).
- Register interspect hooks in a **separate hooks.json** file (`.clavain/interspect/hooks.json`) that Clavain core merges at runtime. This clarifies ownership.

### Risk 3: Evidence Store as Attack Vector

**Scenario:** Malicious evidence injection (e.g., fake "override" events written to JSONL) causes interspect to make bad modifications.

**Likelihood:** LOW (requires local file write access), but consequences are HIGH (can poison entire improvement loop).

**Mitigation:**
- Add **evidence signatures**: each event includes a `session_id` that must match the Claude Code session ID (validated at read time).
- Reject events with future timestamps or session IDs from terminated sessions.
- This prevents injection via manual JSONL edits.

### Risk 4: Sidecar Budget Explosion

**Scenario:** Learnings accumulate in sidecar files → agent context overflow → truncated prompts → degraded agent performance.

**Likelihood:** MEDIUM (design has no budget enforcement).

**Mitigation:**
- Enforce **500-token sidecar budget** at write time (reject appends that exceed budget).
- Provide `/interspect --consolidate-sidecars` command to merge redundant learnings and prune low-confidence entries.
- Log warning when sidecar is 80% of budget (proactive alert before truncation).

---

## 5. Integration Points with Existing Clavain Architecture

### 5.1 Auto-Compound Integration

**Current state:** `hooks/auto-compound.sh` triggers `/compound` command on Stop when signal weight ≥ 3.

**Interspect dependency:** Cadence 2 (end-of-session) triggers "alongside auto-compound" at the same threshold.

**Integration requirement:** Both hooks must coordinate to avoid **duplicate Stop hook blocks** (both return `"decision":"block"` → user sees two sequential prompts).

**Proposed contract:**
```json
// Shared session metadata written by first Stop hook to fire
{
  "session_id": "abc123",
  "signals": ["commit", "resolution"],
  "signal_weight": 5,
  "hooks_notified": ["auto-compound"]
}
```

Both hooks read this file. If `hooks_notified` already contains their name, they skip (no-op). If not, they append their name and proceed. This ensures at most one Stop hook blocks per session.

**File location:** `/tmp/clavain-session-{session_id}.json` (cleaned up by last hook to fire).

### 5.2 Signal Engine Integration

**Current state:** `hooks/lib-signals.sh` defines 7 signal patterns (commit, resolution, investigation, bead-closed, insight, recovery, version-bump) with weights.

**Interspect dependency:** Consumes these signals as evidence, modifies agents that produce these signals.

**Isolation requirement:** Interspect must **NOT** be able to modify `lib-signals.sh` or the Stop hook that calls it. These are **immutable inputs** to interspect's evidence loop.

**Proposed contract:**
- Move `lib-signals.sh` to **Clavain core** (`hooks/lib-signals.sh`), not interspect.
- Interspect reads signal definitions via a **versioned API** (e.g., `source hooks/lib-signals.sh && get_signal_definitions` returns JSON schema).
- If interspect needs custom signals, it defines them in `.clavain/interspect/custom-signals.sh` and registers them with the signal engine (append, don't modify core signals).

This prevents interspect from tampering with its own inputs while allowing extensibility.

### 5.3 Flux-Drive Integration

**Current state:** Flux-drive (in interflux companion) executes a 3-phase review pipeline (analyze + triage, launch agents, synthesis). Triage uses static scoring (domain relevance, concern applicability) and routes agents via Task tool.

**Interspect dependency:** Modifies triage scoring via `routing-overrides.json`, modifies agent prompts via sidecar files, tracks token usage per agent.

**Integration points:**
1. **Triage override:** Flux-drive phase 1 must read `.claude/routing-overrides.json` and apply exclusions/model overrides BEFORE scoring. (Current flux-drive code does not mention this file — **missing implementation**.)
2. **Sidecar injection:** Flux-drive Task tool dispatch must concatenate `agents/{category}/{name}-interspect-context.md` (if exists) to agent prompt before invoking Task. (Current flux-drive code does not mention sidecars — **missing implementation**.)
3. **Cost tracking:** Flux-drive must log token usage per agent to `.clavain/interspect/evidence/token-usage.jsonl` after each Task completion. (Current flux-drive code does not mention cost tracking — **missing implementation**.)

**All three integration points are design assumptions, not implemented features.** The interspect design depends on modifications to flux-drive that are not specified in flux-drive's current SKILL.md.

**Recommendation:** **Specify the flux-drive integration contract explicitly** before implementing interspect. Either:
- Update flux-drive SKILL.md to document override/sidecar/tracking behavior (preferred — keeps contract in one place).
- Create an `interspect-integration.md` spec that both flux-drive and interspect reference.

Without this, interspect and flux-drive will drift out of sync.

---

## 6. Recommended Design Changes

### 6.1 Critical Changes (Block Implementation Without These)

1. **Define versioned integration contracts** for auto-compound, signal engine, and flux-drive. Interspect must not reach into internals.
2. **Remove reflexive control loop:** Add recall validation (regression test suite) to prevent agent degradation from going undetected.
3. **Specify flux-drive integration points:** Document routing-overrides.json, sidecar injection, and cost tracking in flux-drive SKILL.md.
4. **Add modification allow-list:** Restrict interspect to sidecar files and routing-overrides.json. Anything else requires propose mode.

### 6.2 High-Priority Simplifications

5. **Collapse four cadences to two tiers** (session-scoped vs. structural). Eliminate conceptual overhead.
6. **Ship Type 1-3 modifications only** (context injection, routing, prompt tuning). Defer skill rewriting, workflow optimization, and companion extraction until proven necessary.
7. **Simplify shadow testing:** Use synthetic test cases instead of input replay for MVP.
8. **Design evidence pruning now:** 90-day retention + monthly archival to prevent unbounded growth.

### 6.3 Important Boundary Clarifications

9. **Consolidate evidence collection into single hook** with internal routing. Don't pollute global hook namespace.
10. **Decouple interspect trigger from auto-compound threshold.** Use independent evidence accumulation logic.
11. **Move signal definitions to Clavain core** (immutable to interspect). Allow custom signals via separate file.
12. **Use time-bounded canary windows** (7-14 days) instead of use-count windows to handle low-frequency agents.

### 6.4 Optional Enhancements (Not Blockers)

13. Add evidence signatures to prevent injection attacks.
14. Add sidecar budget enforcement (500 tokens).
15. Rename "cadences" to "tiers" or "modification levels" for clarity.
16. Add circuit breaker (auto-disable if revert rate > 50%).

---

## 7. Open Architecture Questions (Require Decisions)

1. **Where does cost tracking instrumentation live?** PostToolUse hook on Task (global, affects all agents) vs. flux-drive dispatch logic (scoped, only affects flux-drive reviews)?

2. **How are sidecars injected?** SessionStart concatenation (simple, requires session-start.sh changes) vs. Task tool wrapper (dynamic, requires dispatch logic changes)?

3. **What is the rollback strategy for multi-file structural changes?** If interspect modifies 3 agent prompts in one batch and canary monitoring flags 1 as degraded, does it revert all 3 or just the flagged one? (Atomic rollback vs. granular rollback.)

4. **How does interspect handle companion plugin updates?** If interflux updates fd-architecture agent, does interspect's sidecar file survive the update (append to new version) or get orphaned (old version's sidecar doesn't apply to new version)?

5. **Should routing-overrides.json be project-scoped or global?** Current design implies per-project (`.claude/routing-overrides.json`), but this means interspect learns "exclude fd-game-design" separately for every non-game project. Would a global override (`~/.claude/clavain/routing-overrides.json`) be more efficient?

6. **What is the error handling contract for shadow testing?** If shadow testing times out (agent hung) or fails (agent crashed), does interspect:
   - Reject the modification (safe, but blocks improvements)
   - Apply the modification with extended canary window (risky, but doesn't block)
   - Prompt the user (breaks full autonomy mode)

---

## 8. Compatibility with Clavain's "Recursively Self-Improving" Vision

The Clavain README states: "Recursively self-improving multi-agent rig — brainstorm to ship."

**Interspect aligns with this vision** by making self-improvement explicit and observable. However, **"recursively" is a loaded term** — it typically implies a system that improves its own improvement process. Interspect's meta-learning loop (Section 3.7: "Interspect improves its own improvement process") is a step toward true recursion, but the current design stops short:

- Interspect can learn "fd-safety modifications fail often, raise risk classification" (meta-learning about agent types).
- Interspect **cannot** learn "shadow testing with 3 test cases gives false confidence, increase to 5 cases" (meta-learning about its own validation process).
- Interspect **cannot** learn "canary window of 5 is too small for low-frequency agents, switch to time-based windows" (meta-learning about its own monitoring strategy).

**Why?** Because these meta-parameters (shadow test count, canary window size, confidence thresholds) are hardcoded in interspect's pipeline (Sections 3.3, 3.5, 3.6). They're not in the evidence → decision loop.

**True recursive self-improvement would require:** Interspect's own meta-parameters (test count, window size, thresholds) stored in a **mutable config file** that interspect can modify based on meta-evidence (e.g., "revert rate correlates with test count < 5" → increase test count). This is significantly more complex and risky than the current design — defer to a later iteration.

**Recommendation:** Rename "recursively self-improving" to **"continuously self-improving"** or **"evidence-driven self-improving"** to avoid over-promising. Reserve "recursively" for when interspect can modify its own meta-parameters.

---

## 9. Summary of Findings

| Category | Finding | Severity | Recommendation |
|----------|---------|----------|----------------|
| **Boundaries** | Tight coupling to auto-compound, signal engine, flux-drive without versioned contracts | **CRITICAL** | Define explicit integration contracts |
| **Boundaries** | Evidence collection scattered across 6 hook points with unclear ownership | **HIGH** | Consolidate into evidence bus |
| **Boundaries** | Sidecar injection mechanism unspecified | **HIGH** | Document in flux-drive SKILL.md |
| **Coupling** | Reflexive control loop: modifies agents that produce evidence | **CRITICAL** | Add recall validation |
| **Coupling** | Interspect trigger bound to auto-compound threshold (fragile) | **HIGH** | Use independent threshold |
| **Pattern** | God module risk: read/write access to all agents and workflows | **HIGH** | Add modification allow-list |
| **Pattern** | Four-cadence model conflates timing with risk (unnecessary complexity) | **MEDIUM** | Collapse to two tiers |
| **Simplicity** | Six modification types, but only 3 are justified (Types 4-6 speculative) | **MEDIUM** | Ship Types 1-3 only |
| **Simplicity** | Shadow testing requires input replay (not designed, expensive) | **HIGH** | Use synthetic tests for MVP |
| **Simplicity** | Evidence store growth unbounded (will bloat git repos) | **MEDIUM** | Design pruning now (90-day retention) |
| **Simplicity** | Canary window use-count insufficient for low-frequency agents | **MEDIUM** | Switch to time-bounded windows |
| **Integration** | Flux-drive integration points (overrides, sidecars, cost tracking) not implemented | **CRITICAL** | Specify contract before implementing |
| **Integration** | Hook coordination with auto-compound undefined (risk of duplicate blocks) | **HIGH** | Use shared session metadata |
| **Integration** | Signal definitions mutable by interspect (input tampering risk) | **MEDIUM** | Move to Clavain core (immutable) |

**Overall Assessment:** The interspect design is **architecturally ambitious but structurally fragile**. It introduces valuable capabilities (evidence-driven improvement, autonomous prompt tuning) but couples them tightly to existing systems without clear boundaries. The four-cadence model adds complexity without corresponding value. The reflexive control loop (modifying agents that produce evidence) is a critical design flaw that can cause compounding degradation.

**Ship/No-Ship:** **Do not implement as designed.** Address the 4 critical findings (integration contracts, reflexive loop, flux-drive integration, modification allow-list) and 3 high-priority simplifications (collapse cadences, defer Types 4-6, simplify shadow testing) before proceeding. With these changes, interspect becomes a viable self-improvement engine. Without them, it's a high-risk entanglement that will create more maintenance burden than value.

---

## 10. Positive Aspects (To Preserve)

Despite the critical findings, several design elements are **strong and should be preserved**:

1. **Evidence store as append-only JSONL** — simple, auditable, greppable. Good choice.
2. **Sidecar pattern for context injection** — clean separation of concerns, easy rollback. Excellent boundary.
3. **Confidence thresholds prevent premature action** — "one override isn't evidence, three across two sessions is" is exactly right. Keep this.
4. **Git commits as undo mechanism** — atomic, versioned, revertible. Natural fit for file-based modifications.
5. **Meta-learning loop** — "modification failures become evidence" is the seed of true recursive improvement. Build on this.
6. **Autonomy model with propose-mode escape hatch** — provides both full automation and human oversight. Flexible.
7. **Canary monitoring with auto-revert** — catches degradation in production use. Critical safety feature.

These are the keeper patterns. The design's core insight — **capture evidence, build confidence, modify safely, monitor outcomes** — is sound. The execution details need refinement, but the foundation is good.
