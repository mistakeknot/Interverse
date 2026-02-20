# Research Agenda Synthesis — 10-15 Thematic Bullets

## 1. Cognitive Augmentation through Specialized Review Agents

**Interlens Flux-Drive Agents** — Transform 288 analytical lenses into 5-8 specialized review agents (fd-lens-systems, fd-lens-decisions, fd-lens-people, fd-lens-resilience, fd-lens-perception) that review documents for thinking quality rather than code correctness, with semantic classification and lens routing via MCP integration.

**Phase 1 Agent Creation & MCP Integration** — Complete the remaining 4 lens agents (decisions, people, resilience, perception) beyond fd-systems, wire Interlens MCP tools for dynamic lens retrieval on demand, implement severity guidance and lens-aware deduplication in synthesis phase.

---

## 2. Multi-Agent Coordination and File Conflict Resolution

**Multi-Session Merge Agent & Reservation Negotiation** — Add Phase 4 capabilities for conflict resolution when agents collide: reservation negotiation protocol (request_release / release_ack / release_defer), merge agent escalation for complex conflicts, negotiation as primary path with merge agent as fallback.

**Interbus: Central Integration Mesh** — Lightweight integration layer standardizing how Clavain and modules communicate via intent envelopes, enabling plugins to emit integration events (discover_work, start_sprint, phase_transition, review_pass) without hard dependencies, with Wave 1-3 deployment across workflow, visibility, and utility modules.

---

## 3. Sprint State Resilience and Autonomy

**Sprint Resilience Phase 1 & 2** — Rebuild sprint workflow on beads as single source of truth with parent-child bead hierarchy, auto-advance between phases pausing only on design ambiguity/gate failures/test failure, tiered brainstorming (simple/medium/complex), session-resilient resume with phase recovery.

**Intercore E3: Hook Cutover to Kernel** — Complete migration of sprint lifecycle from beads-backed temp files to intercore's ic CLI and SQLite kernel, with custom 8-phase chain, hard-fail on missing intercore, removal of ~600 lines of fallback code from lib-sprint.sh.

**Sprint Handover: Kernel-Driven Operations (A2)** — Finalize full kernel-driven sprint by removing beads fallback code, caching run ID once per session, deleting shell transition table, hard-failing without intercore, and clarifying bead as user-facing handle vs. ic run as execution engine.

---

## 4. Token Efficiency and Context Management

**Token-Efficient Skill Loading** — Reduce ceremony overhead in multi-phase skills via Strategy B (tiered compact SKILL.md files auto-generated from full docs) and Strategy C (pre-computation scripts converting deterministic logic to JSON), targeting 60-70% token savings on highest-overhead skills (interwatch, interpath, interflux).

**Flux-Drive Document Slicing** — Implement per-agent content slicing via Interserve spark classifier as MCP server, reducing per-agent token consumption by 50-70%, with 80% threshold preservation and cross-cutting agent exemption (architecture, quality always get full docs).

**Subagent Context Flooding Fix** — Wire lib-verdict.sh infrastructure into all multi-subagent processes (flux-drive, flux-research, quality-gates, review), replacing inline agent results with Findings Index summaries (5 tokens vs 3K), maintaining full prose on disk for drill-down.

**Cost-Aware Agent Scheduling & Token Budgets** — Connect existing budget infrastructure (Variant D hybrid): sprint accepts token budget parameter, phase advance checks ic run budget before advancing, flux-drive receives remaining budget via env var and applies triage cut, post-phase writeback closes token accounting loop.

---

## 5. Ecosystem Integration and Plugin Architecture

**Dual-Mode Plugin Architecture** — Establish pattern for plugins serving standalone users AND integrated ecosystem, with three-layer model (core, ecosystem integration, orchestrated), separate integration.json manifest, centralized intermod/interbase SDK with stub fallback, companion nudge protocol (max 2/session, triggered on first success), per-plugin standalone assessment deciding which should remain ecosystem-only.

**Agent Rig Autonomous Sync** — Keep Clavain installer manifests in sync with ecosystem via agent-rig.json source of truth with optional tier, auto-generator feeding setup.md and doctor.md, self-heal instruction for drift detection, integration into post-bump hook.

---

## 6. Kernel Event Pipeline and Discovery

**Intercore E5: Discovery Pipeline** — Build kernel primitives for research intake: discoveries table with embeddings/scoring/promotion, confidence-tiered action gates, discovery events (submitted/scored/promoted/proposed/dismissed), feedback ingestion updating interest profile, dedup enforcement, staleness decay.

**Intercore E6: Rollback and Recovery** — Implement two-layer rollback system: workflow state layer (rewind run phase pointer, mark intervening transitions/artifacts/dispatches), code layer (query dispatch metadata to list commits per phase for human-guided revert), preserving full audit trail with rolled_back status.

---

## 7. Phase Tracking and Quality Gates

**Reflect Phase: Closing Learning Loop** — Add mandatory reflect phase after polish and before done, making recursive self-improvement a gate-enforced part of every sprint, with complexity-scaled gate thresholds (C1 one-liner suffices, C3 requires docs/solutions/ entry), capturing learning artifacts as source for compound knowledge and interspect training.

**Intercore E3 + State Completeness** — Migrate all shell hooks (currently using `lib-intercore.sh` wrappers) to kernel events, eliminating temp-file fallback and dual-mode code, hard-failing when intercore unavailable for sprint operations.

---

## 8. Real-Time Cost Visibility and Quality Metrics

**Token Budget Controls + Measurement** — Define canonical token accounting (billing = input+output, effective_context = input+cache_read+cache_creation), per-review-type budgets in config/flux-drive/budget.yaml, historical per-agent cost estimates from interstat, budget-aware triage with defer/override, actual vs estimated reporting in synthesis.

**Autarch Status Tool (TUI)** — Standalone Bubble Tea app showing active runs with phase progress bars, dispatch status, live event stream, token totals per run, all via ic JSON CLI (no filesystem scanning), validating kernel→app data flow.

---

## 9. Autonomous Infrastructure and Monitoring

**Agent Rig Autonomous Sync** — Maintain full ecosystem visibility at setup time via agent-rig.json as single source of truth, with tier-based organization (required/recommended/optional), auto-generated plugin lists in setup.md/doctor.md, drift detection warning for uncurated plugins.

**Interwatch & Document Freshness** — Leverage existing drift detection to auto-trigger reviews on doc staleness, with scoring model and component tracking, integrated with auto-refresh via interpath and bead filing.

---

## 10. Multi-Agent Synthesis and Verdict Protocol

**Verdict Protocol Infrastructure** — Standardize agent output handling across all dispatch processes via lib-verdict.sh (status/summary/detail tracking), Findings Index-first reading pattern (5 tokens vs 3K), verdict write after agent completion, selective drill-down on attention-needed agents only.

---

## 11. Cross-Cutting Operational Improvements

**Agent Dropout & Redundancy Elimination** — Use per-agent cost-effectiveness metrics (useful_findings / tokens_consumed) from interstat and verdict tracking to identify agents contributing diminishing returns, feed signal to interspect for learned agent ranking and deprioritization.

**Blueprint Distillation for Sprint Intake** — Convert brainstorm/PRD artifacts into structured intake for sprint classifier, enabling complexity pre-classification and tiered brainstorm selection.

---

## 12. Session Resilience and Handoff

**Session-Resilient Sprint Resume** — Auto-detect active sprints from ic run list, resume with zero user setup, eliminate CLAVAIN_BEAD_ID env var as primary state, read phase from bead at session start, restore full context from kernel.

**Shift-Work Boundary Formalization** — Formalize handoff between sessions via explicit HANDOFF.md protocol, session claims on sprints, session-start hints showing active work, multi-agent session coordination patterns.

---

## 13. Code Quality and Enforcement

**Dual-Write Elimination** — Remove parallel state updates (beads + ic) after E3/A2 completion, single source of truth (kernel only), simplify testing matrix by eliminating partial-integration states.

**Intercore Gates Enforcement** — Enforce gate rules via ic gate check/override in sprint_advance, replace interphase shim with kernel integration, add rollback gate re-evaluation.

---

## 14. Information Architecture and Knowledge Compounding

**Interlens Integration** — Extend 288-lens framework beyond Interlens module into cross-project artifact review, with semantic lens selection per document section, fallback to hardcoded lens subsets for MCP-unavailable scenarios.

**Reflect Phase + Learning Artifacts** — Capture solution docs, auto-memory updates, skill improvements as artifacts registered with phase=reflect, feed docs/solutions/ database and interspect training data.

---

## 15. Measurement and Analytics

**Interstat Token Tracking + Interspect** — Aggregate token consumption per agent/session/sprint, backfill from session JSONL post-phase, write dispatch tokens for kernel visibility, surface cost-effectiveness ratios for interspect learning loop, validate token optimization claims with standardized baselines (pre-slicing vs post-slicing).

