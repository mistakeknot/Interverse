# Brainstorm: Sprint Resilience Phase 2 — Autonomy Layer
**Phase:** brainstorm (as of 2026-02-16T02:17:43Z)

## What We're Building

Phase 2 of Sprint Resilience adds the autonomy layer on top of Phase 1's state foundation. Five features:

1. **F1: Sprint Bead Lifecycle** (iv-h0dr) — Largely done in Phase 1. Remaining: wire `/strategy` to use sprint bead as epic (no separate epic creation), ensure `sprint_create` is called from `/sprint` on new sprints.

2. **F2: Auto-Advance Engine** (iv-5si3) — Remove "what next?" prompts from brainstorm.md, strategy.md, sprint.md. Sprint auto-advances between phases, pausing only on: design ambiguity, P0/P1 gate failure, test failure, quality gate findings. `sprint_should_pause()` and `sprint_advance()` functions in lib-sprint.sh.

3. **F3: Tiered Brainstorming** (iv-cu5w) — Auto-classify feature complexity (simple/medium/complex) from description. Simple: research + one consolidated question. Medium: 2-3 approaches + one choice. Complex: full collaborative dialogue. `sprint_classify_complexity()` in lib-sprint.sh.

4. **F4: Session-Resilient Resume** (iv-jv5f) — Largely done in Phase 1 (sprint_find_active, session-start hints, sprint_claim). Remaining: ensure `/sprint` with no args auto-resumes single active sprint, multiple sprints trigger AskUserQuestion.

5. **F5: Sprint Status Visibility** (iv-glxa) — Largely done in Phase 1 (progress bars in sprint-scan.sh, session-start hints). Remaining: ensure statusline shows sprint context via interline.

## Why This Approach

Phase 1 already built the hard parts (state management, concurrency, session claims). Phase 2 is primarily about **removing friction** — fewer prompts, smarter defaults, automatic classification. The PRD (docs/prds/2026-02-15-sprint-resilience.md) has detailed acceptance criteria for each feature.

## Key Decisions

- **Auto-advance lives in lib-sprint.sh** (Clavain), not lib-gates.sh (interphase) — sprint-specific logic stays in Clavain
- **Strict transition table** — no skip paths, every phase visited in order
- **Pause triggers are code-level checks**, not user prompts — the system decides when to pause
- **Complexity classification is heuristic** — description length, ambiguity terms, pattern references
- **Simple features still get exactly one question** — invariant, never zero questions
- **F1/F4/F5 are mostly gap-filling** — Phase 1 did the heavy lifting, Phase 2 wires up remaining edges
- **Brainstorm skipped** — PRD is already detailed enough for direct planning

## Open Questions

None — the PRD resolves all design questions. Proceed to `/clavain:write-plan`.
