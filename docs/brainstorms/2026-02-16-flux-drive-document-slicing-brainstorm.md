# Flux-Drive Document Slicing via Interserve Spark Classifier

**Bead:** iv-7o7n
**Phase:** brainstorm (as of 2026-02-16T15:32:37Z)
**Date:** 2026-02-16
**Status:** Approach selected, ready for strategy/planning

---

## What We're Building

Per-agent document slicing for flux-drive reviews. Instead of sending the full document to every fd-* agent, each agent receives:
- **Priority sections** (full content) — sections classified as relevant to that agent's domain
- **Context sections** (1-line summaries) — everything else, for awareness
- **Cross-cutting agents** (fd-architecture, fd-quality) — always get full document

Classification is performed by an **Interserve spark model via an always-on interserve MCP server**, giving semantic understanding at near-zero cost.

## Why This Approach

### The Problem
Each fd-* agent currently receives the FULL document. For a 5-agent review of a 10k-token document:
- 5 agents × (1k overhead + 10k document) = **55k tokens**
- Only ~10% of document is relevant to each agent's focus area
- This is the single largest token sink in flux-drive

### Why Interserve Spark (not Python script, not inline LLM)

**Experiment results (5 variants tested 2026-02-15):**
- All variants successfully produced per-agent sliced files
- Python script (Variant D): Most reliable thresholds, 0 LLM tokens, but fails on `##` inside code blocks
- Inline LLM (Variant B): ~4.7k token overhead nearly cancels savings on <500 line docs
- Inline+checkpoint (Variant E): Found the code-block bug, but slowest variant

**Why Interserve spark wins:**
1. **Semantic classification** — understands markdown structure, handles code blocks, ambiguous headings
2. **Near-zero cost** — spark tier is the cheapest available (~$0.001-0.003 per classification)
3. **Always-on MCP server** — reusable infrastructure for other classification/routing tasks (iv-hyza, iv-kmyj)
4. **0 Claude tokens** — classification happens outside Claude's context window entirely

**Why not Python script:**
- Keyword matching is rigid — misclassifies ambiguous sections
- Code-block edge case requires manual fix (tracking in_code_block state)
- No semantic understanding of section content

**Why not inline LLM:**
- ~4.7k output tokens per classification (Write tool calls)
- Barely breaks even on documents under 500 lines
- Competes with the agent work for Claude's context window

### What the interserve MCP server enables beyond slicing
- **Summary-mode output extraction** (iv-hyza) — classify agent outputs into structured fields
- **Conditional phase skipping** (iv-kmyj) — score requirements completeness
- **Complexity routing** (iv-jdow) — classify task complexity for model selection
- Building this infrastructure once unlocks multiple optimization beads

## Key Decisions

1. **Interserve spark as classifier** — not Python script, not Claude LLM
2. **Always-on MCP server** — systemd service, not per-invocation subprocess
3. **Classification output format** — JSON with per-agent section assignments + confidence scores
4. **80% threshold preserved** — if an agent's priority sections cover ≥80% of doc lines, send full document
5. **Cross-cutting agents exempt** — fd-architecture and fd-quality always get full document
6. **Slicing.md spec is the authority** — the existing spec is comprehensive, just never executed; we're building the execution layer

## Scope

### In scope
- Interserve MCP server with `classify_sections` tool
- Section extraction (split by `##`, skip code blocks)
- Per-agent temp file generation with slicing metadata
- Integration into flux-drive Phase 2 (launch.md Step 2.1c)
- 80% threshold enforcement
- Cross-cutting agent exemption

### Out of scope (future iterations)
- Diff slicing (already handled by existing diff-routing.md)
- Knowledge layer integration
- Multi-document reviews
- Agent scoring model (iv-jdow territory)

## Open Questions

1. **MCP server language** — Go (matches interlock-mcp) or TypeScript (matches interkasten, tuivision)?
2. **Codex CLI invocation** — Use existing dispatch.sh or direct `codex exec`?
3. **Classification prompt** — How much context to send? Just headings, or headings + first N lines?
4. **Failure mode** — If Interserve spark is down, fall back to full document (no slicing) or Python script?

## Token Economics

### Before (current state)
5 agents × 15k doc = **75k tokens** per review

### After (with slicing)
- Classification cost: ~500-1k Interserve spark tokens (not Claude tokens)
- Per-agent documents: avg 30-50% of original
- Cross-cutting agents (2): full document
- Savings: **50-70% reduction** → ~25-37k Claude tokens per review
- Net: 0 Claude token overhead for classification + 38-50k Claude tokens saved

## Prior Art

- `plugins/interflux/skills/flux-drive/phases/slicing.md` — Complete spec (366 lines), never executed
- `hub/clavain/docs/research/audit-flux-drive-token-flow.md` — Token flow audit identifying this as P0
- `/tmp/slicing-experiment/{a,b,c,d,e}/` — 5-variant experiment results
- `docs/research/token-efficiency-agent-orchestration-2026.md` — Landscape analysis showing no other orchestrator does per-agent content slicing
