# Interspect — Vision Document

**Version:** 1.0
**Date:** 2026-02-15
**PRD:** `docs/product/interspect-prd.md`
**Roadmap:** `docs/product/interspect-roadmap.md`

---

## The Core Idea

Every time a human overrides a code review finding, dismisses a false positive, or manually corrects an agent's output, information is created and then lost. Interspect captures that information and turns it into systematic improvement.

Clavain dispatches agents. Agents produce findings. Humans evaluate findings. Today, the evaluation signal evaporates. Tomorrow, with Interspect, it compounds.

## Where We Are

Clavain is a multi-agent rig that orchestrates code review, planning, debugging, and shipping workflows. It routes work to specialized agents (fd-architecture, fd-safety, fd-correctness, etc.) and synthesizes their outputs. It works. But it doesn't learn.

The agents are static. Their prompts are handcrafted. Their routing is rule-based. When an agent produces a false positive, the human dismisses it and moves on. When the same false positive recurs three sessions later, the human dismisses it again. The system has no memory of its mistakes.

## Where We're Going

### v1: The Evidence-Driven Feedback Loop

Interspect v1 closes the simplest feedback loop: **observe agent performance, detect patterns, propose targeted modifications, monitor outcomes.**

Three modification types cover 90% of the improvement surface:
1. **Context injection** — Tell agents what they're getting wrong ("this project uses parameterized queries, stop flagging SQL injection")
2. **Routing adjustment** — Stop dispatching irrelevant agents to projects they don't apply to
3. **Prompt tuning** — Surgical edits to agent prompts based on accumulated evidence

The safety model is conservative: propose mode by default, canary monitoring for every change, automatic revert when quality degrades, protected paths for safety infrastructure.

This is not AI improving itself. This is a feedback system that turns human evaluations into agent improvements, with the human in the loop at every decision point.

### v2: Closing More Loops

Once v1 proves the evidence-to-improvement pipeline works:

- **Skill rewriting** — Restructure entire skills (not just prompts) when evidence shows systematic issues
- **Workflow optimization** — Adjust agent dispatch timing, parallelization, and model selection based on cost/quality data
- **Eval corpus construction** — Automatically build test suites from production reviews, creating a regression safety net
- **Cross-model evaluation** — Use GPT-5.2 Pro (Oracle) as an independent judge for shadow testing, eliminating the self-referential bias of Claude evaluating Claude

### v3: Intrinsic Metacognition

The long-term vision — informed by the ICML 2025 position paper on metacognitive learning — is an agent system that doesn't just improve its outputs but improves its improvement process.

Today's Interspect is "extrinsic metacognition": a human-designed OODA loop with fixed cadences, thresholds, and safety gates. v3 would allow the loop itself to evolve:

- Confidence thresholds calibrated continuously, not manually reviewed every 90 days
- Evidence collection strategies that adapt (adding new signal types when existing ones prove insufficient)
- Safety gates that scale with demonstrated track record (not just time-based)

This requires solving the reflexive control loop problem: ensuring the system can't degrade the signals it uses to evaluate its own performance. The protected paths manifest is the v1 answer. A formal verification approach (inspired by the "Guaranteed Safe AI" framework) would be the v3 answer.

## Design Principles

### 1. Propose Before Acting
The default is always to show the human what would change and why. Autonomous mode is opt-in, earned through demonstrated quality, and instantly revocable.

### 2. Every Change is Reversible
Git commits as the undo mechanism. Modification groups for atomic revert. Pattern blacklisting to prevent re-application. No change is permanent until the human says so.

### 3. The Safety Infrastructure is Not the System's to Modify
Meta-rules are human-owned. The confidence function, canary thresholds, revert logic, and protected paths are mechanically enforced — not policy statements. Interspect can improve agents, but it cannot improve (or degrade) itself.

### 4. Measure What Matters, Not What's Easy
Override rate alone is a trap (Goodhart's Law). Three metrics — override rate, false positive rate, and finding density — cross-check each other. Galiana's defect escape rate provides an independent recall signal. When metrics conflict, conservatism wins.

### 5. Evidence Compounds; Assumptions Don't
Phase 1 collects evidence for 4 weeks before any modifications are attempted. Thresholds are "conservative guesses" until real data calibrates them. Types 4-6 are deferred not because they're bad ideas but because there's no evidence they're needed yet.

## The Broader Context

The AI agent ecosystem (2025-2026) is converging on self-improvement:
- **SICA** achieves 17-53% gains via agent source code self-editing
- **Darwin Godel Machine** evolves agents from 20% to 50% on SWE-bench
- **Devin** improved from 34% to 67% PR merge rate over 18 months
- **NVIDIA LLo11yPop** uses OODA loops for datacenter agent optimization

But safety lags capability. No production system has solved the reflexive control loop. No system has achieved intrinsic metacognitive learning. The tools (Langfuse, Portkey, Promptfoo) exist for safe prompt A/B testing, but the integration with self-modifying agent systems is nascent.

Interspect's contribution is not inventing a new algorithm. It's building the disciplined evidence-to-improvement pipeline with safety gates that actually work — in a real production system, not a benchmark. If Clavain can demonstrate that self-improving multi-agent review works safely in practice, the patterns generalize.

## Success at Each Horizon

| Horizon | Timeframe | What Success Looks Like |
|---------|-----------|------------------------|
| v1 | 3-6 months | Override rate decreasing, >80% proposal acceptance, >90% canary pass rate |
| v2 | 6-12 months | Eval corpus covers 80% of agent domains, cross-model shadow testing operational, skill rewrites improving review quality |
| v3 | 12-24 months | Self-calibrating confidence thresholds, adaptive evidence collection, formal verification of safety invariants |

## What This Is Not

- **Not AGI self-improvement.** Interspect modifies prompts and routing for a specific set of code review agents. It does not modify itself.
- **Not a replacement for human judgment.** Propose mode is the default because humans are better at evaluating agent quality than agents are. Interspect reduces the toil of manually tuning agents, not the responsibility.
- **Not an autonomous system by default.** Every deployment starts in evidence-collection-only mode. Autonomy is earned, not assumed.
