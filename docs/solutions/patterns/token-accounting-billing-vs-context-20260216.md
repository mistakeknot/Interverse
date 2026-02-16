---
module: interstat
date: 2026-02-16
problem_type: measurement_error
component: token-benchmarking
symptoms:
  - "Decision gate said SKIP when real data showed context limits being hit"
  - "p95 total_tokens was 33K but sessions were hitting context compaction"
  - "Billing tokens don't reflect what the model actually sees"
root_cause: wrong_metric
resolution_type: dual_metric_reporting
severity: high
tags: [tokens, context-window, cache, billing, measurement, decision-gate, interstat]
---

# Token Accounting: Billing Tokens vs Effective Context

## Problem

When building a decision gate for hierarchical dispatch (iv-8m38), the initial report used `total_tokens = input_tokens + output_tokens` — the billing metric. This showed p95 of ~33K tokens, well under the 120K threshold, suggesting hierarchical dispatch was unnecessary.

But sessions were clearly hitting context limits and triggering compaction. The billing metric was lying.

## Root Cause

Claude's API reports four token categories:

| Field | What it measures |
|-------|-----------------|
| `input_tokens` | Uncached input tokens (billed) |
| `output_tokens` | Generated output tokens (billed) |
| `cache_read_input_tokens` | Tokens served from cache (NOT billed as input) |
| `cache_creation_input_tokens` | Tokens written to cache (billed once) |

**Billing tokens** = `input + output` — what you pay for.
**Effective context** = `input + cache_read + cache_creation` — what the model actually sees in its context window.

The difference can be enormous because cache hits are "free" for billing but still consume context window space. In our data, billing p95 was ~33K but effective context p95 was ~20.8M — a **630x difference**.

## Solution

Track both metrics in the report. Use **effective context** for any decision about context window limits:

```bash
# Billing tokens (what you pay for)
P95=$(sqlite3 "$DB" "SELECT total_tokens FROM agent_runs WHERE total_tokens IS NOT NULL ORDER BY total_tokens ASC LIMIT 1 OFFSET CAST((SELECT COUNT(*) FROM agent_runs WHERE total_tokens IS NOT NULL) * 0.95 AS INTEGER)")

# Effective context (what the model sees)
CTX_P95=$(sqlite3 "$DB" "SELECT COALESCE(input_tokens,0)+COALESCE(cache_read_tokens,0)+COALESCE(cache_creation_tokens,0) as ctx FROM agent_runs WHERE total_tokens IS NOT NULL ORDER BY ctx ASC LIMIT 1 OFFSET CAST((SELECT COUNT(*) FROM agent_runs WHERE total_tokens IS NOT NULL) * 0.95 AS INTEGER)")
```

The decision gate in `plugins/interstat/scripts/report.sh` now uses effective context for the threshold comparison.

## Key Lesson

**Never use billing tokens to reason about context window capacity.** Cache hits are invisible to billing but fully visible to the model. Any decision gate about "are we hitting context limits?" must use effective context.

## Cross-References

- `plugins/interstat/scripts/report.sh` — dual-metric report implementation
- Bead iv-jq5b — token benchmarking framework
- Bead iv-8m38 — hierarchical dispatch (blocked on this measurement)
