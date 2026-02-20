# Backlog Triage — Post-E3 Architecture Alignment

Date: 2026-02-20
Trigger: E3 hook cutover complete, vision refresh done, architecture solidified

## Summary
- Total ready beads: 311
- Detailed triage scope: 60 ready beads at P0-P2
- Relevant: 38
- Misplaced: 7 (module reassignment recommended)
- Stale: 2 (recommend close)
- Aspirational: 12 (recommend defer/tag)
- Duplicate: 1 (recommend close with cross-ref)
- P3+ bulk (not individually reclassified): 251
  - 130 interject feed-intake items
  - 50 state-change/event artifacts
  - 71 other backlog items

## Stale (recommend close)
| Bead | Title | Why stale |
|------|-------|-----------|
| iv-2ley | Plan intercraft extraction (Claude Code meta-tooling) | Superseded by shipped extraction: `plugins/intercraft` is already present and active in current roadmap/constellation. |
| iv-aose | Intermap — Project-level code mapping extraction from tldr-swinton | Superseded by shipped extraction: `plugins/intermap` exists and is versioned/shipped. Bead reflects pre-extraction state. |

## Misplaced (recommend reassign)
| Bead | Title | Current | Should be | Why |
|------|-------|---------|-----------|-----|
| iv-0lt | Extract cache_hints metrics in score_tokens.py | Unscoped/root | `plugins/tldr-swinton` + `infra/interbench` | Work is tldrs scoring + benchmarking; description still references pre-rename Ashpool semantics. |
| iv-1aug | F1: Release Response Protocol (release_ack / release_defer) | Unscoped/root | `plugins/interlock` (+ `services/intermute`) | Description targets `plugins/interlock/internal/tools/tools.go` and intermute threading. |
| iv-905u | Intermediate result sharing between parallel flux-drive agents | Unscoped/root | `plugins/interflux` + `services/intermute` | Primary behavior is flux-drive coordination via intermute message channels. |
| iv-ev4o | Agent capability discovery via intermute registration | Unscoped/root | `plugins/interlock` + `services/intermute` (+ `plugins/interflux` consumer) | Registration/API changes are interlock/intermute concerns; flux-drive is downstream consumer. |
| iv-lgfi | F2: Conversation JSONL parser (token backfill) | Unscoped/root | `plugins/interstat` | Depends on interstat scaffold/metrics schema and is explicitly interstat token backfill. |
| iv-qi8j | F1: PostToolUse:Task hook (real-time event capture) | Unscoped/root | `plugins/interstat` | Depends on interstat scaffold and writes real-time interstat metric rows. |
| iv-rrc2 | F3: Demo hooks for interwatch (reuse examples) | Unscoped/root | `plugins/interwatch` (or split to `plugins/interstat` for metrics subparts) | Title/description are interwatch-hook centric; currently lacks module scoping. |

## Duplicate (recommend close)
| Bead | Title | Duplicates | Evidence |
|------|-------|------------|----------|
| iv-cy1s | [clavain] Agent cancellation as multi-phase protocol (request/drain/finalize) | iv-0681 | Bead description states implementation is covered by iv-0681; treat iv-cy1s as design note/subtask and close as duplicate after cross-linking. |

## Aspirational (recommend defer/tag)
| Bead | Title | Blocked on |
|------|-------|------------|
| iv-3kee | Research: product-native agent orchestration (whitespace opportunity) | More outcome data from kernel+OS operation (E4/E5 era) before strong claims/publication. |
| iv-435u | [interspect] Counterfactual shadow evaluation | Interspect Phase 2 maturity + enough real traffic/evidence corpus. |
| iv-5su3 | [interspect] Autonomous mode flag | Eval corpus and stable canary baselines (Phase 3 gate). |
| iv-6ikc | Plan intershift extraction (cross-AI dispatch engine) | Intershift module decision/ownership and stabilized post-sprint kernel contracts. |
| iv-drgo | [interspect] Privilege separation (proposer/applier) | Phase 3 Interspect implementation runway and hardening sequence. |
| iv-ey90 | [interkasten] Webhook receiver + cloudflared tunnel | Deferred by design to v0.5.x; multi-process SQLite coordination model not finalized. |
| iv-izth | [interspect] Eval corpus construction | Sufficient production review corpus and curation pipeline. |
| iv-p4qq | Smart semantic caching across sessions (intercache) | New module/ownership decision and cross-session cache infra design. |
| iv-quk4 | Hierarchical dispatch: meta-agent for N-agent fan-out | Nested dispatch behavior validation and notification/context bubbling proof. |
| iv-rafa | [interspect] Meta-learning loop | Enough successful/failed modification history for robust taxonomy. |
| iv-sdqv | Plan interscribe extraction (knowledge compounding) | Interscribe module spin-up and extraction scheduling behind current priorities. |
| iv-zyym | Evaluate Claude Hub for event-driven GitHub agent dispatch | Event-driven dispatch architecture decision (native intercore/clavain path vs external service). |

## Relevant (no action needed)
| Bead | Title | Layer | Notes |
|------|-------|-------|-------|
| iv-003t | [interspect] Global modification rate limiter | Profiler | Aligns with Interspect safety posture (guardrails before autonomy). |
| iv-00qk | [intercore] Budget composition via meet() for sprint cost tracking | Kernel | Fits kernel mechanism scope (budget primitives, composition semantics). |
| iv-0681 | Crash recovery + error aggregation for multi-agent sessions | OS + Drivers | Matches post-E3 reliability gaps across Clavain/interlock/intermute/interline. |
| iv-0fi2 | [interspect] Circuit breaker | Profiler | Canonical safe-autonomy control; explicitly in Interspect roadmap. |
| iv-0k8s | [intercore] E6: Rollback and recovery — three-layer revert | Kernel | Directly aligned with intercore roadmap track and layer contract. |
| iv-1626 | Version-bump → Interwatch signal | OS + Driver | Correct bridge from release workflow to drift detection signal path. |
| iv-1gb | Add cache-friendly format queries to regression_suite.json | Driver | Correctly scoped regression coverage for tldrs output format. |
| iv-2izz | [tldrs] LongCodeZip block-level compression | Driver | Token-efficiency frontier work, aligned to tldrs mission. |
| iv-2yef | Autarch: ship minimal status tool as kernel validation wedge | Apps | Explicitly called out in Autarch/Intercore vision migration path. |
| iv-3w1x | Split upstreams.json into config + state files | OS | Legitimate config/state hygiene for Clavain upstream sync flow. |
| iv-444d | Catalog-reminder → Interwatch escalation | OS + Driver | Correctly couples catalog drift signals into interwatch scoring. |
| iv-4728 | Consolidate upstream-check.sh API calls (24 to 12) | OS | Operational efficiency in Clavain maintenance path; not architecture-conflicting. |
| iv-88yg | [interspect] Structured commit message format | Profiler | Auditability requirement aligns with safe change control. |
| iv-c2b4 | [interspect] /interspect:disable command | Profiler | Safety off-switch aligns with conservative modification model. |
| iv-ca5 | tldrs: truncation should respect symbol boundaries | Driver | Correctness fix for token-compressed output contract. |
| iv-dnml | [intersynth] Codex dispatch via dispatch.sh with intermux visibility | OS + Driver | Fits Clavain/intersynth/intermux dispatch stack and token pressure goals. |
| iv-dsk | tldrs: ultracompact needs --depth=body variant | Driver | Correctly scoped quality fix for tldrs output-depth behavior. |
| iv-dthn | Research: inter-layer feedback loops and optimization thresholds | Cross-layer research | Directly aligned with Interverse layered frontier optimization needs. |
| iv-exos | Research: bias-aware product decision framework | OS research | Aligns with Clavain strategy/decision stage quality concerns. |
| iv-f7po | [intermem] F3: Multi-file tiered promotion — AGENTS.md index + docs/intermem/ detail | Driver | Fits intermem mission (memory promotion, durable docs layering). |
| iv-friz | CI/CD integration bridge: GitHub Actions templates for interflux + interwatch | Driver ecosystem | Adoption/operational bridge for shipped capabilities. |
| iv-fzrn | Research: multi-agent hallucination cascades & failure taxonomy | OS research | Matches Clavain quality-gate and failure-mode research agenda. |
| iv-g0to | [interspect] /interspect:reset command | Profiler | Required safety/rollback primitive for controlled adaptation. |
| iv-ia66 | [flux-drive-spec] Phase 2: Extract domain detection library | Driver | Aligns with interflux portability and domain detection hardening. |
| iv-ishl | [intercore] E7: Autarch Phase 1 — Bigend migration + ic tui | Kernel + Apps | Canonical E7 roadmap epic; directly architecture-aligned. |
| iv-jk7q | Research: cognitive load budgets & progressive disclosure review UX | OS research | Supports human-attention bottleneck principle in Clavain vision. |
| iv-l5ap | Research: transactional orchestration & error recovery patterns | Kernel/OS research | Fits intercore durability and rollback/recovery direction. |
| iv-m6cd | [interspect] Session-start summary injection | Profiler | Correct observability UX for active overlays/canaries. |
| iv-md5q | Clavain: define and test Day-1 workflow end-to-end | OS | Directly validates documented Day-1 promise in current vision. |
| iv-mqm4 | Session-start drift summary injection | OS + Driver | Correctly surfaces interwatch drift state at session start. |
| iv-peb6 | [interlock] Obligation leak detection on session close | Driver | Fits interlock reliability and coordination invariants. |
| iv-qznx | [interflux] Multi-framework interoperability benchmark and scoring harness | Driver | Aligned with evaluation/benchmark frontier and interflux remit. |
| iv-r6mf | [interspect] F1: routing-overrides.json schema + flux-drive reader | Profiler + Driver | Core contract between Interspect adaptation and flux-drive routing. |
| iv-sisi | [interspect] Interline statusline integration | Profiler + App surface | Correct observability projection for canary state. |
| iv-spad | Deep tldrs integration into Clavain workflows | OS + Driver | Explicitly aligned with Clavain roadmap and token-efficiency frontier. |
| iv-thp7 | [intercore] E4: Level 3 Adapt — Interspect kernel event integration | Kernel + Profiler | Canonical E4 epic in current roadmap; foundational for adaptation loop. |
| iv-urmc | [intercore] Structured dispatch outcomes with severity ordering | Kernel | Fits kernel mechanism semantics and gate aggregation logic. |
| iv-xuec | Security threat model for token optimization techniques | Cross-layer security | High-value cross-layer safety requirement for optimization work. |

## P3+ bulk (listed, not individually reclassified)
- P3+ ready count: 251
- Bulk patterns:
  - 130 `interject` intake/feed beads (valuable pipeline input; should be triaged in dedicated intake pass)
  - 50 `State change:*` event beads (operational artifacts, low strategic signal)
  - 71 other P3/P4 backlog items (mixed research, infra, and polish)
- Recommendation:
  - Run a separate cleanup pass for `State change:*` artifacts.
  - Batch-triage `interject` feed beads by topical clusters and confidence.
  - Keep this report’s hard decisions focused on P0-P2 execution path.
