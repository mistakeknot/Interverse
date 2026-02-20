# Autarch TUI Adoption Pattern Beads — Creation Log

**Date:** 2026-02-20  
**Source:** Research synthesis from TUI tool analysis (dmux, pi_agent_rust, schmux, lazydocker, ralph-tui, huh, Textual, claude-swarm, overmind, agent-deck)  
**Run from:** /root/projects/Interverse

---

## Summary

19 beads created across 5 categories: cross-cutting patterns (5), Bigend (4), Gurgeh (3), Coldwine (3), and Pollard (4). All scoped as P2 (high value, ship soon) or P3 (important, next sprint). No P1s — none were architectural emergencies, all are adoption improvements over working baselines.

---

## Created Beads — Full Table

| # | Bead ID   | Title                                                                 | Type    | Priority | Category       |
|---|-----------|-----------------------------------------------------------------------|---------|----------|----------------|
| 1 | iv-xu31   | [autarch] Adopt 4-state status model with consistent icons           | task    | P2       | Cross-cutting  |
| 2 | iv-jaxw   | [autarch] Typed KernelEvent enum for all observable state changes    | feature | P2       | Cross-cutting  |
| 3 | iv-26pj   | [autarch] Streaming buffer / history split per agent panel           | task    | P2       | Cross-cutting  |
| 4 | iv-wgyx   | [autarch] Tool output auto-collapse (>20 lines → 5 lines preview)   | task    | P3       | Cross-cutting  |
| 5 | iv-9a0n   | [autarch] Differential rendering — dirty-range-only repaints         | task    | P3       | Cross-cutting  |
| 6 | iv-4zle   | [autarch] Bigend: two-pane lazy* layout (list + detail)              | feature | P2       | Bigend         |
| 7 | iv-4c16   | [autarch] Bigend: bootstrap-then-stream event viewport               | task    | P2       | Bigend         |
| 8 | iv-1yck   | [autarch] Bigend: htop-style cost + tool columns per agent           | feature | P3       | Bigend         |
| 9 | iv-pgte   | [autarch] Bigend: multi-project grouping with flat index nav         | feature | P3       | Bigend         |
|10 | iv-nlq2   | [autarch] Gurgeh: huh group-as-phase for sprint wizard               | feature | P3       | Gurgeh         |
|11 | iv-v3wx   | [autarch] Gurgeh: crash-resume via persistent session state          | feature | P3       | Gurgeh         |
|12 | iv-sydv   | [autarch] Gurgeh: subagent call tracing inline                       | task    | P3       | Gurgeh         |
|13 | iv-bri5   | [autarch] Coldwine: steering vs follow-up message queues             | feature | P3       | Coldwine       |
|14 | iv-4f1r   | [autarch] Coldwine: risk-gated autopilot for agent decisions         | feature | P3       | Coldwine       |
|15 | iv-qu7m   | [autarch] Coldwine: ActionResult chaining for multi-step flows       | task    | P3       | Coldwine       |
|16 | iv-ht1l   | [autarch] Pollard: progressive result reveal per hunter              | feature | P2       | Pollard        |
|17 | iv-frwf   | [autarch] Pollard: confidence tier display (High/Medium/Low + score) | task    | P3       | Pollard        |
|18 | iv-xlpg   | [autarch] Pollard: optional-death hunter resilience                  | task    | P2       | Pollard        |
|19 | iv-16sw   | [autarch] Pollard: parallel model race for confidence scoring        | feature | P3       | Pollard        |

---

## Priority Breakdown

### P2 — High Value (ship soon)
- iv-xu31 — Status model (cross-cutting, foundational UX)
- iv-jaxw — KernelEvent enum (cross-cutting, foundational observability)
- iv-26pj — Streaming buffer/history split (cross-cutting, prevents flicker)
- iv-4zle — Bigend two-pane layout (core navigation pattern)
- iv-4c16 — Bigend bootstrap-then-stream (core data flow)
- iv-ht1l — Pollard progressive result reveal (core UX for scan results)
- iv-xlpg — Pollard hunter resilience (correctness: scan must not die)

### P3 — Important, Next Sprint
- iv-wgyx — Tool output auto-collapse
- iv-9a0n — Differential rendering
- iv-1yck — Bigend htop-style columns
- iv-pgte — Bigend multi-project grouping
- iv-nlq2 — Gurgeh huh group-as-phase
- iv-v3wx — Gurgeh crash-resume
- iv-sydv — Gurgeh subagent tracing
- iv-bri5 — Coldwine message queues
- iv-4f1r — Coldwine risk-gated autopilot
- iv-qu7m — Coldwine ActionResult chaining
- iv-frwf — Pollard confidence tier display
- iv-16sw — Pollard parallel model race

---

## Category Analysis

### Cross-cutting (5 beads — apply to all Autarch apps)

**Why these first:** These establish shared vocabulary and shared rendering infrastructure. If status icons and KernelEvent are inconsistent across apps, every downstream UI decision diverges. Ship iv-xu31, iv-jaxw, iv-26pj before per-app work begins.

- **iv-xu31** (Status model): Single source of truth for the 6-state icon set (working/analyzing/waiting/idle/done/failed). Inspired by dmux and agent-deck which both independently converged on this pattern.
- **iv-jaxw** (KernelEvent enum): Defines the observable event vocabulary for the entire system. intermux and intermap both consume this stream externally — must be stable.
- **iv-26pj** (Streaming buffer): Two-buffer pattern (currentOutput + finalized history) prevents the most common flicker issue in streaming TUIs. Pi_agent_rust and schmux both use it.
- **iv-wgyx** (Tool auto-collapse): Agents can produce 100+ lines per tool call. Without auto-collapse, output panels become unreadable quickly.
- **iv-9a0n** (Differential rendering): Full-screen repaints on every spinner tick cause visible flicker. Line-level dirty tracking + CSI 2026 synchronized output eliminates it.

### Bigend (4 beads — operator dashboard app)

**Core pattern:** The lazy* layout (lazydocker/lazyactions DNA) is the right call for an operator-facing dashboard. Two-pane list+detail with flat keyboard nav is proven for this use case.

- **iv-4zle** (Two-pane layout): Foundational layout decision. Everything else builds on this.
- **iv-4c16** (Bootstrap-then-stream): Correct data access pattern — snapshot on connect, incremental deltas after. Prevents the "stale data until next poll" problem.
- **iv-1yck** (htop-style columns): Cost visibility is a first-class concern for multi-agent runs. claude-swarm showed this clearly.
- **iv-pgte** (Multi-project grouping): Needed once Autarch manages runs across multiple repos. Flat index nav avoids nested selection complexity.

### Gurgeh (3 beads — sprint wizard app)

**Core pattern:** charmbracelet/huh as the form engine is the right call — it integrates as a tea.Model directly. The crash-resume pattern is non-optional for 10+ minute sprint workflows.

- **iv-nlq2** (huh group-as-phase): Maps the conceptual phase model directly to huh.Group. Confidence gate as huh.Confirm shows scores inline.
- **iv-v3wx** (Crash-resume): Session persistence to .gurgeh/specs/history/session.json. ralph-tui's implementation is a direct reference.
- **iv-sydv** (Subagent tracing): When Arbiter fires Pollard during Phase 2, it should be visible in the sprint wizard — not a black box.

### Coldwine (3 beads — agent steering app)

**Core pattern:** The steering/follow-up queue separation is the key insight from pi_agent_rust. Risk classification before auto-accept is required for safe autonomous operation.

- **iv-bri5** (Message queues): Steering messages interrupt; follow-up messages queue. Queue depth visible in UI per agent.
- **iv-4f1r** (Risk-gated autopilot): Three-tier classification (safe/risky/destructive) with different handling paths. Never auto-accept destructive.
- **iv-qu7m** (ActionResult chaining): tea.Msg types per dialog step keeps the UI model thin. Pure functions for state transitions.

### Pollard (4 beads — intelligence scan app)

**Core pattern:** Progressive reveal is essential — scans with many hunters should show results as they arrive, not after all complete. Hunter isolation (optional-death) is a correctness requirement.

- **iv-ht1l** (Progressive reveal): Rows appear as each hunter finishes. Spinner rows for in-progress. Sort by confidence descending.
- **iv-frwf** (Confidence tier display): "High (0.87)" in green is more scannable than "0.87". Qualitative tier as primary signal.
- **iv-xlpg** (Hunter resilience): One hunter's API rate limit must not kill the scan. Inspired by overmind OVERMIND_CAN_DIE pattern.
- **iv-16sw** (Parallel model race): errgroup race for confidence scoring with content-hash cache (5s TTL). Inspired by dmux PaneAnalyzer Promise.any.

---

## Sequencing Recommendation

**Sprint 1 (P2 cross-cutting + Bigend foundation):**
1. iv-xu31 — Status model (day 1, all apps)
2. iv-jaxw — KernelEvent enum (day 1-2, all apps)
3. iv-26pj — Streaming buffer (day 2-3, all apps)
4. iv-4zle — Bigend layout (day 3-4)
5. iv-4c16 — Bigend bootstrap-then-stream (day 4-5)
6. iv-ht1l — Pollard progressive reveal (day 5-6)
7. iv-xlpg — Pollard hunter resilience (day 6)

**Sprint 2 (P3 features by app):**
- Bigend: iv-1yck, iv-pgte
- Gurgeh: iv-nlq2, iv-v3wx, iv-sydv
- Coldwine: iv-bri5, iv-4f1r, iv-qu7m
- Pollard: iv-frwf, iv-16sw
- Cross-cutting: iv-wgyx, iv-9a0n

---

## Source Research Files

The beads were derived from these research docs in /root/projects/Interverse/docs/research/:
- `research-dmux-repo-for-autarch.md`
- `research-pi-agent-rust-repo.md`
- `research-schmux-repo-for-autarch.md`
- `research-similar-tui-agent-tools.md`
- `find-tui-tools-matching-autarch-subapps.md`
