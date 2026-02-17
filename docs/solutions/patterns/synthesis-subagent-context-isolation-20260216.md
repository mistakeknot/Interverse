---
title: "Synthesis Subagent for Context-Efficient Multi-Agent Orchestration"
category: patterns
severity: high
date: 2026-02-16
tags: [multi-agent, context-window, synthesis, intersynth, verdict, subagent]
related: [token-accounting-billing-vs-context-20260216]
---

## Problem

When an orchestrator agent dispatches N review/research subagents in parallel, each agent produces 3-5K tokens of findings. The orchestrator must collect, deduplicate, and synthesize these findings. Reading all agent output files directly floods the orchestrator's context with 20-40K tokens of review prose, causing:

1. **Context exhaustion** in long workflows (sprint chains exhaust context before shipping)
2. **Lost coherence** when context compresses and earlier phases are forgotten
3. **Redundant content** — agent results already persisted to disk but also pulled into context

## Investigation

Analyzed 4 multi-subagent processes:

| Process | Background dispatch? | File output? | Context flooding? |
|---------|---------------------|-------------|-------------------|
| flux-drive | Yes | Yes (.md) | Yes — synthesis reads ALL files fully |
| flux-research | Yes | Yes (.md) | Yes — synthesis reads ALL files fully |
| quality-gates | Yes | No | **Severe** — results return inline via TaskOutput |
| review | Yes | No | **Severe** — results return inline via TaskOutput |

Also found: `lib-verdict.sh` (128 lines) existed with full structured verdict infrastructure but was never called by any process.

## Solution: Three-Tier Context Isolation

```
Tier 1: Review Agents (background)    → write .md files to OUTPUT_DIR
         ↓
Tier 2: Synthesis Subagent (foreground) → reads files, deduplicates, writes verdicts + synthesis.md
         ↓
Tier 3: Host Agent                     → reads ~10-line compact return + synthesis.md (~30-50 lines)
```

### Key design decisions

1. **Dedicated plugin (`intersynth`)** — not inline prompts. Provides `intersynth:synthesize-review` and `intersynth:synthesize-research` as proper subagent types. Avoids mega-prompt duplication across 4 processes.

2. **File-based output contract** — agents write findings to `{OUTPUT_DIR}/{agent-name}.md` with a standard Findings Index format. They return a single line ("Findings written to...") instead of full prose.

3. **Verdict files as structured handoff** — `verdict_write()` produces ~100-byte JSON per agent with status, summary, and detail path. The orchestrator reads verdict summaries (~500 bytes total) instead of full prose (~15KB per agent).

4. **Synthesis subagent runs foreground** — the host needs the result (PASS/FAIL) to proceed. But the subagent's return value is a compact summary (~10-15 lines), not the full synthesis. Full synthesis goes to `{OUTPUT_DIR}/synthesis.md`.

5. **Model routing** — haiku for simple synthesis (quality-gates, 2-3 agents), sonnet for complex synthesis (flux-drive, 8+ agents with convergence tracking).

### Context savings

- **Before**: Host reads 30K-40K tokens of agent prose
- **After**: Host reads ~500 tokens (compact return + synthesis.md header)
- **Reduction**: 60-80x

## Files Changed

- `hub/clavain/commands/quality-gates.md` — added OUTPUT_DIR, file-based output contract, intersynth delegation
- `hub/clavain/commands/review.md` — same pattern
- `plugins/interflux/skills/flux-drive/phases/synthesize.md` — replaced inline collection with intersynth
- `plugins/interflux/skills/flux-research/SKILL.md` — replaced inline synthesis with intersynth
- `plugins/intersynth/` — new plugin (2 agents, lib-verdict.sh, CLAUDE.md)

## Reusable Pattern

When orchestrating N parallel subagents:

1. **Never read agent output files in the host context.** Delegate to a synthesis subagent.
2. **Define a standard output contract** (Findings Index format) so synthesis is mechanical, not interpretive.
3. **Use structured verdict files** as the handoff mechanism — they're tiny (~100 bytes) and machine-parseable.
4. **Return compact summaries** from synthesis — the host only needs PASS/FAIL + top findings. Full reports go to disk.
5. **Separate review synthesis from research synthesis** — their input/output contracts differ (findings index vs source attribution).

## Verify

1. Run `/clavain:quality-gates` on a real diff — verify intersynth agent is dispatched and host context stays clean
2. Run `/interflux:flux-drive` on a plan file — verify synthesis.md is written and host gets compact return
3. Check `.clavain/verdicts/` after a review — should contain one `.json` per agent
