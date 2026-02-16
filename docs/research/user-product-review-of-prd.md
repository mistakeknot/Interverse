---
title: "User & Product Review: Interstat Token Benchmarking PRD"
date: 2026-02-16
type: research
tags: [user-product, prd-review, interstat, token-efficiency, scope-validation]
status: complete
reviewer: flux-drive fd-user-product lens
parent: docs/prds/2026-02-16-interstat-token-benchmarking.md
---

# User & Product Review: Interstat Token Benchmarking PRD

## Summary

The PRD is **95% right** but has **one critical misalignment**: it treats measurement as the end goal when the actual user pain is "I need to decide which of 8 beads to build, and I'm blocked because I don't know which one actually saves money." The 120K decision gate is a proxy metric that may not survive contact with real data. The PRD should reframe around **decision velocity** (time to actionable data) rather than statistical rigor (50 runs, p99 confidence).

**Verdict**: APPROVE with scope reduction. Cut F4 (status command), simplify F3 (report) to answer ONE question: "Should I build hierarchical dispatch or skip it?" Launch as a decision accelerator, not a general-purpose benchmarking framework.

---

## 1. Problem Validation: Is "Optimizing Blind" the Real Pain?

### The Stated Problem
> "8 optimization beads (~25 person-days) were proposed without any primary measurements of actual token consumption. All 4 flux-drive reviewers flagged this as the critical gap — we're optimizing blind."

### The Actual User Pain (One Layer Deeper)
The user is NOT suffering from "lack of measurements" — they're suffering from **decision paralysis**. The pain is:
- "I have 8 beads on the backlog representing 25 person-days of work"
- "I don't know which ones are worth building"
- "I can't start ANY of them until I have data"
- "Getting that data is blocking me from making progress"

**Evidence**: The PRD itself states the downstream blocker — "is p99 context actually exceeding 120K tokens?" This is not a curiosity question; it's a go/no-go gate for iv-8m38 (hierarchical dispatch).

### The Problem with "50 Invocations"
The PRD treats 50 flux-drive runs as a baseline for statistical validity. But:
- **How long does that take?** If the user runs flux-drive 2x/day, that's 25 days before making a decision. If they run it 5x/day, it's 10 days. The PRD doesn't acknowledge this time dimension.
- **Is the threshold binary or gradient?** If p99 is 119K (just under the 120K threshold), does that mean "skip hierarchical dispatch forever" or "skip for now, revisit in 6 months"? The decision gate is presented as a one-time verdict, but token consumption changes as Clavain adds more plugins, reviewers, and context.
- **What if the data is inconclusive?** If p50 is 80K but p99 is 150K, the answer isn't binary. The PRD doesn't specify what happens when the data doesn't cleanly answer the question.

### Recommendation: Reframe the Problem
**Before**: "We're optimizing blind — we need a benchmarking framework."
**After**: "We're blocked on 8 beads because we don't know which optimization levers are real. We need to collect enough data to make a go/no-go decision on hierarchical dispatch within 1 week."

This reframing shifts the success metric from "statistical rigor" to "decision velocity."

---

## 2. Decision Gate Validity: Is 120K the Right Threshold?

### The Gate as Stated
> "if p99 < 120K → SKIP hierarchical dispatch (iv-8m38)"

### Problems with This Gate

#### 2.1. Where Did 120K Come From?
The PRD doesn't justify the 120K threshold. Is it:
- Anthropic's context window limit minus safety margin?
- The point at which latency becomes user-painful?
- The point at which caching stops working efficiently?
- An arbitrary round number?

Without a rationale, 120K is a Schelling point — it sounds plausible but may not map to real user pain.

#### 2.2. p99 is Fragile to Outliers
If 49 flux-drive runs are under 100K but one run hits 180K due to a particularly complex brainstorm, p99 will be 180K. The decision gate would say "BUILD hierarchical dispatch" based on a single outlier. Is that the right call?

**Alternative metrics to consider:**
- **p95 instead of p99** — more robust to single outliers
- **Frequency of exceeding threshold** — "5% of runs exceed 120K" is more actionable than "p99 is 125K"
- **Cost impact** — "Runs over 120K cost 2x more due to cache misses" ties the metric to user pain (dollars)

#### 2.3. The Threshold Ignores Cost Dynamics
From `token-efficiency-review-findings.md` (Oracle finding):
> "Token efficiency ≠ cost efficiency. Provider pricing differs by input vs output tokens. Caching discounts only apply to eligible cached input tokens. Compression can increase total cost via re-fetch loops."

120K **total tokens** might be fine if:
- 100K are cached input (90% discount)
- 10K are output (full price)
- 10K are non-cached input (full price)

But 120K might be painful if:
- 60K are non-cached input (full price)
- 60K are output (full price)

The decision gate needs to account for **token composition**, not just total count.

### Recommendation: Multi-Threshold Decision Tree
Replace the binary gate with a decision tree:

```
IF p95 input_tokens < 100K AND cache_hit_rate > 80%
  → SKIP hierarchical dispatch (caching is working)

ELSE IF p50 input_tokens < 80K BUT p99 > 150K
  → BUILD adaptive routing (most runs are fine, but tail needs help)

ELSE IF avg cost_per_finding > $2
  → BUILD cost-aware triage (expensive but still under context limits)

ELSE
  → COLLECT MORE DATA (inconclusive)
```

This matches the actual decision space better than a single 120K threshold.

---

## 3. Time to Value: How Long Before 50 Runs?

### The Implicit Assumption
The PRD assumes "50 flux-drive invocations" is achievable within a reasonable timeframe but never states what "reasonable" means.

### The Reality Check
**Current flux-drive usage patterns (estimated from context):**
- Sprint workflow: brainstorm → plan → PRD review → implementation → correctness review → ship
- Flux-drive used for: PRD review, plan review, brainstorm review, research doc review
- Estimated flux-drive invocations per sprint: 3-5
- Sprints per week: 1-2

**Calculation:**
- If 1.5 sprints/week × 4 invocations/sprint = 6 invocations/week
- 50 invocations = **8.3 weeks** before decision gate data is ready
- 8 beads × 3 days avg = 24 days of blocked work = **~5 weeks of engineering capacity frozen**

### The Compound Blocker
From `bd show iv-8m38`:
> "DEPENDS ON: iv-jq5b (this bead)"
> "BLOCKS: iv-qjwz (AgentDropout), iv-6i37 (Blueprint distillation)"

This creates a **3-layer cascade**:
1. Wait 8 weeks for 50 interstat measurements (iv-jq5b)
2. Then build token ledger v1 (iv-8m38, ~5 days)
3. Then build AgentDropout/Blueprint distillation (iv-qjwz/iv-6i37, ~5 days combined)

Total time to first optimization bead shipped: **10+ weeks** from today.

### The Faster Path: Progressive Disclosure
Instead of "wait for 50 runs, then decide," the PRD should support **incremental decision-making**:

- **After 10 runs (1.5 weeks):** Check if p50 is clearly under/over threshold. If conclusive, make early call.
- **After 25 runs (4 weeks):** Check if p90 is stable. If trending clearly, make directional decision.
- **After 50 runs (8 weeks):** Full confidence for edge case analysis.

This gets the user to a "confident enough to proceed" state in **1.5-4 weeks** instead of 8.

### Recommendation: Add Early Exit Criteria to F3
F3 (report command) should output:
- Current run count
- **Confidence level**: "LOW (N<10) | MEDIUM (10≤N<25) | HIGH (N≥25) | VERY HIGH (N≥50)"
- **Early decision signal**: "Data suggests X with Y confidence; recommend Z action OR collect N more runs"

Example output after 12 runs:
```
Interstat Report (12 flux-drive runs)
Confidence: MEDIUM (needs 13 more for HIGH)

p50 input tokens: 85K (± 12K)
p90 input tokens: 115K (± 18K)
Cache hit rate: 87%

EARLY SIGNAL: p90 trending below 120K threshold
RECOMMENDATION: Collect 13 more runs for HIGH confidence, then SKIP hierarchical dispatch
ALTERNATIVE: Start prototyping iv-qjwz (AgentDropout) now — it's independent of context limits
```

This cuts decision latency from 8 weeks to 2-4 weeks.

---

## 4. Scope Creep Risk: 5 Features for "Just Measure"

### The Original Ask (Implicit)
From the problem statement: "we need to know what agents actually cost" → this is fundamentally a **data collection + one query** problem.

### The PRD's Scope
- F0: Plugin scaffold + SQLite schema
- F1: PostToolUse:Task hook (real-time capture)
- F2: JSONL parser (token backfill)
- F3: Built-in analysis queries (report command)
- F4: Collection status (status command)

### What's Actually Needed for the Decision Gate?
**Minimum viable measurement:**
1. Capture flux-drive runs (session_id, timestamp, agent names)
2. Parse JSONL for input_tokens, output_tokens, cache_hit_tokens
3. Run ONE query: `SELECT percentile(input_tokens, 0.95) FROM runs WHERE scope='invocation'`
4. Output: "95th percentile: 112K tokens → SKIP hierarchical dispatch"

**Everything else is scope creep:**
- `findings_count`, `findings_severity`, `tokens_per_finding` → **YAGNI**. These are useful for optimizing agent selection (iv-ynbh trust triage) but NOT for the hierarchical dispatch decision gate.
- `workflow_id` grouping → **YAGNI**. The decision gate is per-invocation, not per-sprint.
- `v_agent_summary` view → **Nice to have** but not blocking. Can be added after initial decision.
- F4 status command → **YAGNI**. The user can run `sqlite3 metrics.db "SELECT COUNT(*) FROM agent_runs"` if they're curious.

### The Over-Engineering Signal
From the schema (lines 51-78):
- 7 columns for "from PostToolUse hook"
- 5 columns for "from JSONL parser"
- 4 columns for "outcome metrics" (findings_count, findings_severity)
- 3 columns for metadata (model, target_file, parsed_at)

**19 columns** to answer a single question: "Is p95 input_tokens > 120K?"

Compare to the **minimum schema**:
```sql
CREATE TABLE flux_runs (
    id INTEGER PRIMARY KEY,
    timestamp TEXT,
    session_id TEXT,
    input_tokens INTEGER,
    output_tokens INTEGER,
    cache_hit_tokens INTEGER
);
```

6 columns. Still answers the decision gate. Can add more later if needed.

### Why This Happened
The PRD conflates two goals:
1. **Immediate goal**: Answer the hierarchical dispatch decision gate (1 week)
2. **Future goal**: Build a general-purpose agent benchmarking framework (useful indefinitely)

The schema was designed for Goal 2, but the user's pain is Goal 1.

### Recommendation: Two-Phase Delivery

#### Phase 1 (v0.1, ship in 2 days)
**Goal**: Answer hierarchical dispatch question ASAP
- F0: Minimal plugin scaffold (no fancy views, just one table)
- F1: PostToolUse:Task hook (capture session_id, timestamp, agent_name)
- F2: JSONL parser (backfill input_tokens, output_tokens, cache_hit_tokens)
- F3: ONE command: `interstat check-dispatch` → outputs p95 input_tokens + recommendation

**Schema**:
```sql
CREATE TABLE runs (
    timestamp TEXT,
    session_id TEXT,
    agent_name TEXT,
    input_tokens INTEGER,
    output_tokens INTEGER,
    cache_hit_tokens INTEGER
);
CREATE INDEX idx_runs_timestamp ON runs(timestamp);
```

**Output**:
```
Interstat: Hierarchical Dispatch Decision Gate
Data: 12 flux-drive runs (needs 13 more for high confidence)

p50 input tokens: 85K
p95 input tokens: 112K
Cache hit rate: 87%

VERDICT: SKIP hierarchical dispatch (p95 comfortably under 120K)
CONFIDENCE: MEDIUM (collect 13 more runs to upgrade to HIGH)
```

#### Phase 2 (v0.2, ship after decision made)
**Goal**: Support ongoing optimization decisions
- Add `findings_count`, `findings_severity` for iv-ynbh (trust triage)
- Add `workflow_id` for sprint-level analysis
- Add F4 (status command)
- Add cost-per-finding analysis for iv-qjwz (AgentDropout)

This two-phase approach **cuts time-to-decision from 8 weeks to 1.5-2 weeks** by ruthlessly deferring non-critical features.

---

## 5. User Experience: Who Consumes the Output?

### The PRD's UX Assumption
> "Output is readable in terminal (formatted table or aligned text)" (F3, line 55)

This implies a **human-readable CLI output** — which is correct for the user's immediate need (solo developer making a decision).

### The Missing Use Case: Agent Consumption
The broader Clavain ecosystem has **agents making decisions** based on cost data:
- iv-8m38 (token ledger) needs to read current session cost to enforce budgets
- iv-qjwz (AgentDropout) needs to compare agent cost-per-finding to decide which agents to skip
- iv-ynbh (trust triage) needs historical accuracy-per-cost ratios

These use cases need **machine-readable output** (JSON, SQLite queries, or MCP tool).

### The Good News
The PRD already chose SQLite as the storage layer, which is inherently machine-readable. The CLI commands are just a convenience layer. So this is **not a gap**, just an under-documented strength.

### Recommendation: Make Machine-Readability Explicit
Add to F3 acceptance criteria:
- [ ] `interstat report --json` outputs structured JSON for agent consumption
- [ ] `interstat report --query <sql>` allows custom SQLite queries (power user escape hatch)

Example JSON output:
```json
{
  "runs": 12,
  "confidence": "MEDIUM",
  "metrics": {
    "p50_input_tokens": 85000,
    "p95_input_tokens": 112000,
    "cache_hit_rate": 0.87
  },
  "decision_gates": {
    "hierarchical_dispatch": {
      "threshold": 120000,
      "verdict": "SKIP",
      "rationale": "p95 (112K) is 7% below threshold with 87% cache hit rate"
    }
  }
}
```

This future-proofs the tool for agent-driven optimization while keeping the human UX clean.

---

## 6. Scope Creep Risk (Continued): The "Framework" Trap

### The Language Tells the Story
The PRD is titled "Token Efficiency **Benchmarking Framework**" (emphasis mine). Words like "framework," "infrastructure," and "foundation" are scope creep red flags — they signal **platform thinking** when the user needs a **point solution**.

**Evidence of framework thinking:**
- "Built-in analysis queries" (F3) — plural, suggesting many queries for many use cases
- "Collection status" (F4) — monitoring infrastructure, not a decision tool
- Three-level granularity (workflow → invocation → agent) — generality beyond the immediate need
- 4 indexes + 2 views — database design for query flexibility, not one-time decision

### The User's Actual Context
From the problem statement:
> "The user is a solo developer running a Claude Code plugin ecosystem."

**Solo developer** = no team to amortize framework investment across. The ROI calculation is:
- **Framework approach**: 5 days to build, supports infinite future queries, reusable across all optimization decisions
- **Point solution approach**: 2 days to build, answers one question, throwaway after decision

For a solo dev, the point solution wins unless the framework has **near-term reuse** (within 2-4 weeks).

### Where's the Near-Term Reuse?
From `token-efficiency-review-findings.md`, the recommended implementation order AFTER interstat:
1. iv-8m38 (token ledger) — needs session-level cost tracking (different from flux-drive benchmarking)
2. iv-qjwz (AgentDropout) — needs agent-level cost-per-finding (requires `findings_count` column, which is scope creep for Phase 1)
3. iv-6i37 (blueprint distillation) — compression experiment, no direct interstat dependency

**Only iv-qjwz reuses interstat's agent-level metrics**, and that's **2-3 months away** (after iv-jq5b → iv-8m38 → iv-qjwz cascade).

### The Right Scope: Decision Accelerator, Not Framework
The PRD should be titled **"Hierarchical Dispatch Decision Support (Interstat v0.1)"** and scoped to:
- Answer ONE question: "Should I build iv-8m38 hierarchical dispatch?"
- Ship in 2 days instead of 5
- Defer "framework" features (multi-query support, status monitoring, workflow grouping) to v0.2 after the decision is made

If the decision is "yes, build hierarchical dispatch," the user will spend the next 5 days building iv-8m38, not querying interstat. The framework investment doesn't pay off.

If the decision is "no, skip hierarchical dispatch," the user will move to iv-qjwz (AgentDropout), which needs **different metrics** (findings_count, which isn't in the Phase 1 schema). Again, framework investment doesn't pay off.

### Recommendation: Rename and Rescope
**New title**: "Interstat v0.1: Hierarchical Dispatch Decision Gate"
**New scope**: F0 + F1 + F2 + F3 (ONE query: check-dispatch command), ship in 2 days
**Defer to v0.2**: F4 (status), multi-agent analysis, cost-per-finding, workflow grouping

---

## 7. Missing from PRD: Failure Modes

### The PRD Assumes Happy Path
The acceptance criteria are all success-oriented:
- "INSERT completes in <50ms" (F1)
- "Idempotent: re-running is a no-op" (F2)
- "Handles <50 runs gracefully" (F3)

But there are no criteria for **user-facing failure modes**:

#### 7.1. Insufficient Data, Conflicting Signals
What if after 50 runs:
- p50 = 80K (comfortably under threshold)
- p95 = 118K (just under threshold)
- p99 = 145K (over threshold)

The data says "most runs are fine, but the tail exceeds limits." The binary decision gate ("SKIP or BUILD hierarchical dispatch") forces a choice that doesn't match the nuance.

**Missing**: Guidance for inconclusive results. The report should support:
- "SKIP for now, revisit after 100 runs"
- "BUILD adaptive routing (not full hierarchical dispatch)"
- "OPTIMIZE tail cases first (document slicing, agent pruning)"

#### 7.2. JSONL Format Changes
From dependencies (line 76):
> "Claude Code conversation JSONL format — internal, undocumented, may change. Parser must be defensively coded."

**Missing**: What happens when Claude Code updates the JSONL format and the parser breaks? Acceptance criteria should include:
- [ ] Parser logs schema version or hash of first JSONL line (detect format drift)
- [ ] Graceful degradation: if `usage` field is missing, log warning and skip token backfill
- [ ] Version guard: "This parser was tested against Claude Code v1.2.3; you're running v1.3.0 — results may be inaccurate"

#### 7.3. Zero Flux-Drive Usage
What if the user installs interstat but never runs flux-drive? After 2 weeks:
```
$ interstat report
Interstat Report (0 runs)
No data available. Run flux-drive to collect measurements.
```

This is technically correct but not helpful. Better UX:
```
$ interstat report
Interstat: No Data Yet

Interstat tracks flux-drive token usage. To collect data:
  1. Run /flux-drive on a brainstorm, plan, or PRD
  2. Wait for SessionEnd hook to parse JSONL
  3. Re-run this command

Expected timeline: 10-15 runs for early signal (1.5 weeks at 1 flux-drive/day)

Troubleshooting: Run `interstat debug` to check hook installation.
```

### Recommendation: Add Failure Mode Acceptance Criteria
For F3 (report command):
- [ ] If N < 10: output "Insufficient data" + onboarding help text
- [ ] If p95 and p99 disagree on verdict: output "Inconclusive, collect more data OR revisit threshold"
- [ ] If JSONL parser fails: output "Token data incomplete (parser error)" + troubleshooting link
- [ ] If no flux-drive runs in past 7 days: output "No recent activity" + usage reminder

---

## 8. Alternative Considered: Is Measurement Even Needed?

### The PRD Assumes Measurement is Prerequisite
But there's an alternative path: **prototype first, measure later**.

From `token-efficiency-review-findings.md` on iv-quk4 (originally a measurement-blocked bead):
> "iv-quk4 marked as needing empirical testing → Can prototype directly (proven in OpenHands/MASAI)"

This pattern could apply to hierarchical dispatch (iv-8m38):
1. Build a minimal hierarchical dispatch prototype (2 days)
2. Run it on 5 flux-drive invocations and compare side-by-side to current approach
3. If savings are obvious (20%+ token reduction), ship it
4. If savings are marginal (<10%), abandon it

**Time to decision**: 1 week (prototype + test) vs. 8 weeks (measure 50 runs + analyze).

### Why Measurement Wins Anyway
Two reasons the PRD's approach is still better:

#### 8.1. Hierarchical Dispatch is Expensive to Prototype
Unlike iv-quk4 (context isolation, mostly config changes), hierarchical dispatch requires:
- Router logic (which agents to invoke at each tier)
- Retry orchestration (if tier-1 agents fail, escalate to tier-2)
- Cost tracking (to enforce budget limits)
- Tier definitions (which agents belong in tier-1 vs tier-2)

This is **5 days of work** (per iv-8m38 estimate). If measurement proves "not needed," that's 5 days saved. The measurement cost (2-3 days for interstat + 1.5 weeks data collection) is cheaper than the prototype cost.

#### 8.2. Measurement Unblocks Other Beads
Interstat data is reusable:
- iv-qjwz (AgentDropout) needs agent-level cost-per-finding
- iv-ynbh (trust triage) needs historical accuracy rates
- iv-6i37 (blueprint distillation) needs cost-per-finding to validate compression ROI

Prototyping hierarchical dispatch only answers the hierarchical dispatch question. Measurement answers 4+ questions at once.

### Recommendation: Acknowledge the Alternative in PRD
Add to "Non-goals" section:
> - **Prototyping before measurement** — considered but rejected. Hierarchical dispatch (iv-8m38) is expensive to build (~5 days) compared to measurement cost (~3 days + 1.5 weeks data collection). Measurement also unblocks iv-qjwz, iv-ynbh, iv-6i37, making it higher ROI.

This shows the decision was considered, not overlooked.

---

## 9. The Bigger Picture: Is This the Right First Optimization?

### The PRD Focuses on Hierarchical Dispatch
But from `token-efficiency-review-findings.md`, the recommended priority order is:
1. **iv-7o7n (document slicing)** — 50-70% savings, 2-3 days, **no measurement needed**
2. **iv-jq5b (benchmarking)** — enables decisions for everything else
3. **iv-8m38 (hierarchical dispatch)** — build after measurement

### The User-Product Question
Why is the user building iv-jq5b (measurement) before iv-7o7n (document slicing)?

**Possible reasons:**
- Document slicing is already done (not in the bead list as open)
- Document slicing requires Clavain architecture changes, so it's riskier
- User wants to validate ALL optimization beads at once, not just one

**Missing from PRD**: Rationale for why measurement comes before the "highest ROI, no prereq" optimization.

### Recommendation: Add Context to Problem Statement
Replace line 9:
> "8 optimization beads (~25 person-days) were proposed without any primary measurements."

With:
> "8 optimization beads (~25 person-days) were proposed without any primary measurements. The highest-ROI optimization (document slicing, iv-7o7n) is already underway. The remaining 7 beads require measurement to prioritize, as they have overlapping scope and unknown cost/benefit ratios."

This clarifies **why measurement is the next step** rather than just building optimizations.

---

## 10. Open Questions from PRD (Lines 82-86)

The PRD lists 3 open questions. User-product lens on each:

### Q1: JSONL Correlation
> "When flux-drive dispatches 4 agents in parallel, how do we match JSONL entries to specific agents?"

**User-product take**: This is an implementation detail, not a product risk. Worst case: correlation fails, and all 4 agents' tokens are summed as "invocation-level" metrics. The decision gate (p95 input_tokens) still works — it just can't break down cost by agent.

**Risk level**: LOW. If unsolvable, defer agent-level metrics to v0.2 and ship invocation-level metrics in v0.1.

### Q2: Invocation Grouping
> "How to detect that 4 Task calls are part of the same `/flux-drive` invocation vs. independent calls?"

**User-product take**: Same as Q1 — this affects granularity, not decision gate validity. If grouping fails, treat each agent as independent. The p95 metric becomes "p95 per agent" instead of "p95 per invocation." Still useful, just different.

**Risk level**: LOW. Timestamp clustering (within 2s) is good enough for v0.1. Perfect correlation can be a v0.2 refinement.

### Q3: JSONL Format
> "Need to inspect actual conversation JSONL structure before writing the parser."

**User-product take**: This is the ONLY real blocker. If the JSONL format doesn't expose `usage` fields, the entire F2 (token backfill) approach fails.

**Risk level**: MEDIUM-HIGH. This should be validated **before writing the PRD**, not listed as an open question. The PRD assumes the JSONL contains `input_tokens`, `output_tokens`, `cache_hit_tokens` — if this assumption is wrong, the whole design changes.

### Recommendation: Validate Q3 Immediately
Before approving the PRD, run:
```bash
# Find a recent flux-drive session
session_dir=$(find ~/.claude/projects/*/conversations -name "*.jsonl" -mtime -7 | head -1)

# Check for usage metadata
jq 'select(.type=="api_response") | .usage' "$session_dir" | head -5
```

If this returns null or missing fields, **the PRD needs a redesign**. F2 (JSONL parser) would need to be replaced with:
- API response interception (Claude Code plugin hook, if available)
- Anthropic API log scraping (hacky, fragile)
- Estimation based on character count (inaccurate)

This is a **go/no-go prereq** for the current PRD design.

---

## Summary of Recommendations

### High Priority (Blocking Approval)
1. **Validate JSONL format** (Open Question 3) — confirm `usage` fields exist before proceeding
2. **Reframe problem statement** — from "we're optimizing blind" to "we're blocked on decisions and need data fast"
3. **Cut scope to Phase 1** — defer F4, multi-agent analysis, and findings_count to v0.2
4. **Add early exit criteria to F3** — support progressive decision-making (10 runs → early signal, 25 runs → medium confidence, 50 runs → high confidence)

### Medium Priority (Improve Outcomes)
5. **Replace binary decision gate** — use multi-threshold decision tree (cache_hit_rate, p50 vs p95 spread, cost-per-finding)
6. **Add failure mode acceptance criteria** — handle insufficient data, conflicting signals, JSONL parser breakage
7. **Document time-to-decision** — state expected timeline (1.5-8 weeks based on flux-drive usage rate)
8. **Add machine-readable output** — JSON output for agent consumption (future-proofing)

### Low Priority (Nice to Have)
9. **Rename PRD** — from "framework" to "decision gate" (sets right scope expectations)
10. **Add rationale for measurement-first** — why not build iv-7o7n (document slicing) first?

---

## Approval Decision

**APPROVE** with the following conditions:
1. Validate Open Question 3 (JSONL format) within 24 hours — this is a go/no-go blocker
2. Implement Phase 1 scope reduction (defer F4, cut to 2-day delivery)
3. Add early exit criteria to F3 (progressive confidence levels)

If JSONL validation fails, **REJECT** and pivot to alternative design (API interception or estimation-based approach).

---

## Final Take: This is 95% Right

The PRD demonstrates strong product thinking:
- Correctly identifies the root blocker (lack of measurements)
- Chooses the right data sources (PostToolUse hook + JSONL)
- Designs for reusability (SQLite, machine-readable)
- Acknowledges JSONL fragility upfront

The 5% gap is **over-scoping for a solo developer's immediate need**. The user needs to make ONE decision (build or skip hierarchical dispatch) within 1-2 weeks, not build a general-purpose benchmarking framework over 5 days + 8 weeks data collection.

**Ship Phase 1 in 2 days. Make the decision. Then decide if Phase 2 is worth building.**
