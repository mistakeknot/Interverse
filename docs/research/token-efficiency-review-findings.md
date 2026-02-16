---
title: "Token Efficiency Review Findings: What the Research Document Misses"
date: 2026-02-15
type: research
tags: [token-efficiency, gap-analysis, flux-drive-review, beads]
status: complete
methodology: 4-agent flux-drive review (fd-architecture, fd-systems, fd-user-product, fd-performance) + Oracle GPT-5.2 Pro (pending)
parent: token-efficiency-agent-orchestration-2026.md
---

# Token Efficiency Review Findings

## Overview

Four flux-drive reviewers independently analyzed the [token efficiency research document](token-efficiency-agent-orchestration-2026.md). This document synthesizes their findings into a unified gap map with bead references.

**Verdict**: Strong literature review (7/10) with structural gaps, missing inter-layer analysis, no primary measurements, and dependency graph errors. Six existing beads updated, four new beads created.

---

## New Beads Created

| Bead | Title | Priority | Source |
|------|-------|----------|--------|
| iv-7o7n | Document slicing for flux-drive agents | P0 | fd-architecture audit |
| iv-jq5b | Token efficiency benchmarking framework | P1 | fd-performance + fd-user-product |
| iv-dthn | Inter-layer feedback loops and thresholds | P2 | fd-systems |
| iv-eaeq | Delegation depth limits and Schelling traps | P3 | fd-systems |

## Existing Beads Updated

| Bead | Key Update |
|------|-----------|
| iv-19oc | Compression breaks prompt caching — scope to one-shot workflows only |
| iv-qtcl | A-Mem 85-93% is memory ops, not total tokens — overstated |
| iv-quk4 | Can prototype directly, doesn't need empirical testing |
| iv-8m38 | FOUNDATIONAL — all 4 reviewers agree, must build first |
| iv-qjwz | Partially mutually exclusive with iv-ynbh; needs iv-8m38 first |
| iv-ynbh | Requires 20+ historical reviews to calibrate; chicken-egg problem |

---

## Critical Findings (P0-P1)

### 1. Document Slicing is the Biggest Win (iv-7o7n, P0)
**Source:** fd-architecture

Each fd-* agent currently receives the FULL document being reviewed. Instead, each agent should get: summary + relevant sections + other sections as 1-liners. This extends the existing diff-routing.md pattern to structured documents.

**Expected savings:** 50-70% of total flux-drive token consumption.
**Effort:** 2-3 days.
**Why it was missed:** Research drew from external sources, not the internal audit.

### 2. Compression Breaks Prompt Caching (Anti-Pattern)
**Source:** fd-performance

LLMLingua and gist tokens invalidate Anthropic's 90% cache discount on recurring prompts. For flux-drive's stable agent prompts, compression is NET WORSE:
- Without compression: Pay full price once, then 90% discount on every subsequent run
- With compression: Pay compressed price every time (no cache hits — compressed text differs)

**Action:** iv-19oc scoped to one-shot workflows only (e.g., Oracle cross-AI review with 50K non-reusable context).

### 3. No Primary Measurements (iv-jq5b, P1)
**Source:** fd-user-product (consensus from all 4)

8 beads representing ~25 person-days of work proposed without validating which problem is real. Zero data on:
- Median/p90/p99 cost per flux-drive run
- Which agents consume most tokens with lowest finding rate
- Whether context limits are actually being hit
- Whether Haiku quality is acceptable for specific agent roles

**Action:** Build benchmarking framework before implementing any optimization.

---

## Structural Issues (P2)

### 4. Savings Are Not Additive
**Source:** fd-performance

File indirection (70%), AgentDropout (21.6%), and context isolation (67%) all address the same bottleneck: orchestrator context bloat. They cannot be summed. Realistic combined savings for recurring flux-drive: 80-90% after cache warm-up — but this is ceiling, not sum of individual claims.

### 5. Inter-Layer Feedback Loops (iv-dthn)
**Source:** fd-systems

Key interactions the document doesn't analyze:
1. **Compression ↔ retrieval loop**: LLMLingua changes embedding semantics → vector search degrades → more context fetching → more compression needed
2. **Token efficiency paradox**: Over-optimization degrades quality → retries → HIGHER total cost
3. **Bullwhip effect in routing**: Load spikes cascade through Haiku→Sonnet→Opus tiers
4. **Hysteresis in compression**: Once compressed, context can't be recovered for backtracking

### 6. Layer 7 is a Catch-All
**Source:** fd-architecture

Blueprint Distillation = L4 (compression), AgentDropout = L3 (isolation), Trajectory Pruning = L6 (output). Layer 7 should become "Meta-Orchestration" — patterns spanning multiple layers.

### 7. Research Collection Syndrome
**Source:** fd-user-product

6 of 8 proposed beads are invisible to the user. Only iv-8m38 (token ledger) and iv-ynbh (trust triage) have user-facing value. 29 sources cited with zero user interviews or pain point validation.

---

## Dependency Graph Corrections

### Errors in Original

- iv-quk4 marked as needing empirical testing → **Can prototype directly** (proven in OpenHands/MASAI)
- iv-8m38 marked as cost visibility → **Should be foundational prerequisite** for iv-qjwz, iv-ynbh, iv-6i37
- iv-qjwz and iv-ynbh treated as complementary → **Partially mutually exclusive** (both eliminate agents, different mechanisms)

### Corrected Wave Plan

```
[Wave 0: Highest ROI, independent]
iv-7o7n (document slicing) — 50-70% savings, 2-3 days

[Wave 1: Measurement infrastructure]
iv-jq5b (benchmarking framework) — enables all decisions

[Wave 2: Build on measurement]
iv-8m38 (token ledger v1) ← depends on iv-jq5b

[Wave 3: Build on ledger]
iv-qjwz (AgentDropout) ← depends on iv-8m38
iv-6i37 (blueprint distillation) ← depends on iv-8m38

[Wave 4: Build on historical data]
iv-ynbh (trust triage) ← depends on iv-8m38 + 20 reviews + interspect
iv-ffo5 (trajectory pruning) ← depends on iv-qtcl

[Wave 5: Deferred until evidence]
iv-quk4 (hierarchical dispatch) ← measure context usage first
iv-19oc (compression) ← one-shot workflows only
iv-qtcl (agentic memory) ← measure existing memory workflow first
```

---

## Missing Patterns (Not in Original Research)

| Pattern | Description | Source |
|---------|-------------|--------|
| Agent-scoped tooling | Subagents get role-specific tool subsets, not full MCP catalog | fd-architecture |
| Differential context updates | Delta-based transmission for multi-turn agents (60-80% per-turn savings) | fd-architecture |
| Adaptive token budgets | Stop low-priority agents when high-priority ones find severe issues | fd-architecture |
| Hybrid symbolic-neural routing | AST analysis decides which agents to invoke, skipping LLM triage | fd-architecture |
| Crumple zones | Reserve 10% context as overflow buffer instead of optimizing to 100% | fd-systems |
| "When NOT to optimize" | Identify contexts where full fidelity > token savings (debugging, exploration) | fd-systems |
| Measurement & definitions spec | Standardize unit (input/output/total tokens vs $ vs latency), counting scope (incl retries, router prompts, tool outputs), and baseline per claim | Oracle |
| "Token efficiency ≠ cost efficiency" | Provider pricing differs by input vs output; caching discounts only apply to eligible input tokens; compression can increase total cost | Oracle |
| Workflow topology diagram | End-to-end token flow: orchestrator → subagents → retrieval → patch → verify → retry | Oracle |
| Security threat model | Prompt injection via retrieval, memory poisoning in A-Mem, tempfile leakage from file indirection, repo-level prompt injection via AGENTS.md | Oracle |
| Observability & reliability (Layer 0) | Rate limits, backpressure, partial failures, idempotency, deterministic replay / audit trails | Oracle |
| "Negative results" per layer | Each layer needs explicit "when NOT to use" guidance, not just buried in appendix | Oracle |
| File indirection may shift not save | If agents read file content into model context, tokens are paid later — savings may be zero | Oracle |

---

## Recommended Implementation Order

1. **iv-7o7n** Document slicing (P0) — 2-3 days, 50-70% savings, no prerequisites
2. **iv-jq5b** Benchmarking framework (P1) — 2 days, enables all other decisions
3. **iv-8m38** Token ledger v1 (P1) — 2 days, read-only cost visibility
4. **iv-qjwz** AgentDropout (P2) — 2 days, measurable 20% savings
5. Everything else: **blocked on measurement data** from steps 2-3

---

## Review Source Agents

| Agent | Focus | Key Contribution |
|-------|-------|-----------------|
| fd-architecture (a4888f0) | Structure, patterns, dependencies | Layer restructure, missing patterns, P0 document slicing |
| fd-systems (a3f3cfc) | Feedback loops, emergence, dynamics | 7 systems findings including compression paradox |
| fd-user-product (ab11dff) | User pain, value proposition, 80/20 | Research collection syndrome, recommended priority reorder |
| fd-performance (a4789b6) | Measurement, latency, throughput | Benchmarking methodology, compression anti-pattern |
| Oracle GPT-5.2 Pro (b8b953e) | Cross-AI external review | Measurement spec, security threat model, "token ≠ cost" distinction, file indirection critique, per-layer pitfall catalog |

## Oracle-Specific Findings (Novel)

These findings were NOT caught by any of the 4 Claude-based fd-* reviewers:

### Token Efficiency ≠ Cost Efficiency
The document conflates token reduction, dollar reduction, and latency reduction. Provider pricing differs by input vs output tokens. Caching discounts only apply to eligible cached input tokens. Compression can increase total cost via re-fetch loops. Needs explicit section near Executive Summary.

### File Indirection May Be Zero Savings
If agents read the `/tmp/` file content into model context via a tool, tokens are still paid — just later. The 70% reduction may only apply to orchestrator message size, not net token budget. Need to verify whether Clavain's pattern truly avoids re-ingestion.

### Security Threat Model (iv-xuec, P2)
Missing across Layers 1, 3, 5:
- File indirection: tempfiles in `/tmp` readable by other processes
- Prompt injection via retrieved text (Layer 5 retrieval)
- Memory poisoning in A-Mem/iv-qtcl
- Repo-level prompt injection via AGENTS.md overrides (Codex CLI pattern)

### Per-Layer Pitfall Catalog
Oracle produced a comprehensive per-layer pitfall list covering all 7 layers. Key highlights:
- **Layer 1**: Schema pruning can silently remove error codes needed later
- **Layer 2**: Router cost can erase savings; cross-model context impedance
- **Layer 3**: Lossy summarization prevents orchestrator from verifying reasoning
- **Layer 4**: Cache-breaking not limited to compression — timestamps, tool list changes, temp paths all break it
- **Layer 5**: RRF across 5 strategies can increase retrieved text volume, making retrieval the dominant token driver
- **Layer 6**: Patch apply failures from concurrent edits; verification loops dwarf patch savings
- **Layer 7**: AgentDropout removes safety redundancy; trajectory pruning false positives cause premature termination

### Oracle's Corrected Priority Order
Oracle independently produced the same #1 (iv-8m38 token ledger) and #8 (iv-19oc compression) as the flux-drive consensus, but differs in middle ordering — placing iv-quk4 hierarchical dispatch at #2 (higher than flux-drive's recommendation) and trust triage (iv-ynbh) at #5 before AgentDropout (#6).

Full Oracle review: `/tmp/oracle-token-efficiency-review.md`
