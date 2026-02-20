# Interverse Roadmap

**Modules:** 35 | **Open beads (root tracker):** 347 | **Blocked (root tracker):** 35 | **Last updated:** 2026-02-20
**Structure:** [`CLAUDE.md`](../CLAUDE.md)
**Machine output:** [`docs/roadmap.json`](roadmap.json)

---

## Ecosystem Snapshot

| Module | Location | Version | Status | Roadmap | Open Beads (context) |
|--------|----------|---------|--------|---------|----------------------|
| autarch | hub/autarch | — | active | yes | 18 |
| clavain | hub/clavain | 0.6.42 | active | yes | 13 |
| intercheck | plugins/intercheck | 0.1.2 | active | yes | 4 |
| intercore | infra/intercore | — | active | yes | 5 |
| intercraft | plugins/intercraft | 0.1.0 | active | yes | 4 |
| interdev | plugins/interdev | 0.2.0 | active | yes | 4 |
| interdoc | plugins/interdoc | 5.1.1 | active | yes | 4 |
| interfluence | plugins/interfluence | 0.1.3 | active | yes | 4 |
| interflux | plugins/interflux | 0.2.13 | active | yes | 19 |
| interform | plugins/interform | 0.1.0 | active | yes | 4 |
| interject | plugins/interject | 0.1.5 | active | yes | 4 |
| interkasten | plugins/interkasten | 0.4.1 | active | yes | 12 |
| interlens | plugins/interlens | 2.2.3 | active | yes | 4 |
| interline | plugins/interline | 0.2.4 | active | yes | 4 |
| interlock | plugins/interlock | 0.2.1 | active | yes | 10 |
| intermap | plugins/intermap | 0.1.1 | early | no | n/a |
| intermem | plugins/intermem | 0.1.0 | active | no | 4 |
| intermute | services/intermute | — | active | yes | 29 |
| intermux | plugins/intermux | 0.1.0 | active | yes | 4 |
| internext | plugins/internext | 0.1.2 | active | yes | 4 |
| interpath | plugins/interpath | 0.2.1 | active | yes | 4 |
| interpeer | plugins/interpeer | 0.1.0 | early | no | n/a |
| interphase | plugins/interphase | 0.3.2 | active | yes | 4 |
| interpub | plugins/interpub | 0.1.2 | active | yes | 4 |
| intersearch | plugins/intersearch | 0.1.1 | active | yes | 4 |
| interserve | plugins/interserve | 0.1.0 | active | yes | 4 |
| interslack | plugins/interslack | 0.1.0 | active | yes | 4 |
| interstat | plugins/interstat | 0.1.0 | active | yes | 4 |
| intersynth | plugins/intersynth | 0.1.0 | early | no | n/a |
| intertest | plugins/intertest | 0.1.0 | early | no | n/a |
| interverse | root | — | active | yes | n/a |
| interwatch | plugins/interwatch | 0.1.2 | active | yes | 4 |
| tldr-swinton | plugins/tldr-swinton | 0.7.13 | active | yes | 15 |
| tool-time | plugins/tool-time | 0.3.2 | active | yes | 12 |
| tuivision | plugins/tuivision | 0.1.4 | active | yes | 4 |

**Legend:** active = recent commits or active tracker items; early = manifest exists but roadmap maturity is limited. `n/a` means there is no module-local `.beads` database.

---

## Roadmap

### Now (P0-P1)

- [intersynth] **iv-dnml** Codex dispatch via dispatch.sh with intermux visibility
- [interverse] **iv-0681** Crash recovery + error aggregation for multi-agent sessions
- [autarch] **iv-2yef** Ship minimal status tool as kernel validation wedge (blocks iv-knwr)
- [clavain] **iv-3krg** Wire /reflect step into sprint.md orchestration

**Recently completed:** iv-8jpf (Reflect phase: 5th macro-stage, 10-phase chain, --phases fix, /reflect command), iv-i66k (verify reflect transitions), iv-fos3 (reflect artifact registration), iv-mxap (doc alignment for 5 macro-stages), iv-v7n4 (sprint-to-kernel phase mapping), iv-ngvy (E3: Hook cutover — big-bang Clavain migration to ic), iv-9plh (E2: Level 2 React — SpawnHandler wiring + event reactor docs/tests), iv-som2 (E1: Kernel primitives — phase chains, tokens, skip, hash), iv-bkjb (F1: Phase chains), iv-afjh (F2: Skip command), iv-432r (F3: Artifact hashing), iv-jzfh (F4: Token tracking), iv-s4wh (F5: Token aggregation), iv-ht3h (F6: Budget events), iv-wo1t (Hook adapter — thin bridge from Claude Code hooks to intercore DB), iv-a20e (Phase state machine — own the brainstorm-to-ship lifecycle), iv-e5oa (Dispatch — spawn and track Claude Code + Codex agents), iv-dyyy (interstat plugin scaffold + SQLite schema), iv-n4p7 (intermem Phase 1: Validation overlay), iv-rkrm (intermem Phase 2: Decay + progressive disclosure), iv-zl98 (intermem Dogfood Phase 1+2A), iv-byh3 (Define platform kernel + lifecycle UX architecture), iv-hoqj (Interband: sideband protocol library), iv-8m38 (Token budget controls + cost-aware agent dispatch), iv-d72t (Phase 4a: Reservation Negotiation Protocol), iv-jq5b (Token efficiency benchmarking framework), iv-jo3i (Canary verdict engine)

### Next (P2)

**Intercore Autonomy Ladder**
- **iv-thp7** E4: Level 3 Adapt — Interspect kernel event integration (blocks E5)
- **iv-0k8s** E6: Rollback and recovery — three-layer revert
- **iv-fra3** E5: Discovery pipeline — kernel primitives for research intake (blocked by E4)

**Autarch Application Layer**
- **iv-ishl** E7: Autarch Phase 1 — Bigend migration + `ic tui` (blocks E9)
- **iv-lemf** Bigend: swap project discovery to `ic run list`
- **iv-9au2** Bigend: swap agent monitoring to `ic dispatch list`
- **iv-gv7i** Bigend: swap run progress to `ic events tail`
- **iv-1d9u** Bigend: dashboard metrics from kernel aggregates
- **iv-knwr** `pkg/tui`: validate components with kernel data (blocked by iv-2yef)
- **iv-6abk** Signal broker: connect to Intercore event bus (blocked by iv-ishl)

**Interbus Module Integration**
- **iv-psf2** Interbus rollout: phase-based module integration
- **iv-psf2.2** Wave 2: Visibility and safety modules (blocked by Wave 1)
- **iv-psf2.2.1–2.8** Individual adapter beads (intercheck, interline, interwatch, interpub, interslack, internext, intercraft, interform)
- **iv-psf2.3** Wave 3: Supporting utility modules (blocked by Wave 2)
- **iv-psf2.3.1–3.3** Individual adapter beads (tool-time, tldr-swinton, intersearch)

**Multi-Agent Coordination (interlock)**
- **iv-1aug** F1: Release Response Protocol (blocks F2–F5)
- **iv-gg8v** F2: Auto-Release on Clean Files (blocked by F1)
- **iv-5ijt** F3: Structured negotiate_release MCP Tool (blocked by F1)
- **iv-6u3s** F4: Sprint Scan Release Visibility (blocked by F1)
- **iv-2jtj** F5: Escalation Timeout for Unresponsive Agents (blocked by F3)

**Token Efficiency & Benchmarking (interstat)**
- **iv-qi8j** F1: PostToolUse:Task hook (real-time event capture)
- **iv-lgfi** F2: Conversation JSONL parser (blocks F3, F4)
- **iv-dkg8** F3: interstat report (blocked by F2)
- **iv-bazo** F4: interstat status (blocked by F2)
- **iv-v81k** Repository-aware benchmark expansion (blocked by iv-qznx)

**Interspect Self-Improvement**
- **iv-r6mf** F1: routing-overrides.json schema + flux-drive reader (blocks F2, F5)
- **iv-8fgu** F2: routing-eligible pattern detection + propose flow (blocked by F1)
- **iv-gkj9** F3: apply override + canary + git commit (blocked by F2)
- **iv-2o6c** F4: status display + revert (blocked by F3)
- **iv-6liz** F5: manual routing override support (blocked by F1)
- **iv-435u** Counterfactual shadow evaluation
- **iv-drgo** Privilege separation (proposer/applier)
- **iv-003t** Global modification rate limiter
- **iv-88yg** Structured commit message format
- **iv-sisi** Interline statusline integration
- **iv-rafa** Meta-learning loop (blocks iv-bj0w) — unblocked, consumes reflect artifacts

**Multi-Agent Intelligence**
- **iv-qznx** Multi-framework interoperability benchmark (blocks iv-jc4j, iv-v81k)
- **iv-jc4j** Heterogeneous agent routing (blocked by iv-qznx, blocks iv-wz3j)
- **iv-wz3j** Role-aware latent memory architecture (blocked by iv-jc4j)
- **iv-quk4** Hierarchical dispatch: meta-agent for N-agent fan-out
- **iv-ev4o** Agent capability discovery via intermute registration
- **iv-905u** Intermediate result sharing between parallel flux-drive agents
- **iv-qjwz** AgentDropout: dynamic redundancy elimination (blocked by iv-ynbh)

**Memory & Knowledge (intermem)**
- **iv-f7po** F3: Multi-file tiered promotion (blocks F4)
- **iv-bn4j** F4: One-shot tiered migration (blocked by F3)

**Code Context & Compression (tldr-swinton)**
- **iv-2izz** LongCodeZip block-level compression
- **iv-aose** Intermap — project-level code mapping extraction

**Platform & Infrastructure**
- **iv-p4qq** Smart semantic caching across sessions (intercache)
- **iv-friz** CI/CD integration bridge: GitHub Actions templates
- **iv-ey90** Interkasten webhook receiver + cloudflared tunnel
- **iv-zyym** Evaluate Claude Hub for event-driven GitHub agent dispatch
- **iv-xuec** Security threat model for token optimization techniques
- **iv-dthn** Research: inter-layer feedback loops and optimization thresholds
- **iv-va58** Bug: Stale subagent notifications flood after context compaction

### Later (P3)

**Reflect Phase Hardening**
- **iv-mkfy** Graduate reflect gate from soft to hard (complexity-scaled thresholds)
- **iv-64j3** Multi-agent sprint reflection (N artifacts for N dispatches) [P4]

**Autarch Phase 2 — Pollard + Gurgeh Migration**
- **iv-6376** E9: Autarch Phase 2 — Pollard + Gurgeh migration (blocked by E5, E7; blocks E10)
- **iv-fsxc** Pollard: hunter results as `ic discovery` events (blocked by iv-fra3)
- **iv-skyk** Pollard: insight scoring via kernel confidence (blocked by iv-fra3)
- **iv-8y3w** Gurgeh: spec sprint as `ic run` lifecycle (blocked by iv-ishl)
- **iv-t4v6** Gurgeh: spec evolution via run versioning (blocked by iv-ishl)
- **iv-ts3b** Arbiter extraction Phase 1: Gurgeh confidence scoring to OS (blocked by iv-8y3w)
- **iv-u2pd** Arbiter extraction Phase 2: spec sprint sequencing to Clavain skill (blocked by iv-ts3b)

- [intermem] **iv-y5tv** Phase 4: Consolidation — Compound/Interfluence write through intermem (blocked by iv-xswd)
- [intermem] **iv-xswd** Phase 3: Cross-project search — global metadata + semantic embeddings
- [interwatch] **iv-wrtg** Framework and benchmark freshness automation pipeline
- [interject] **iv-3bia** A Technical Guide to Multi-Agent Orchestration
- [interject] **iv-yqub** Securing MCP Servers in 2026: How to Govern AI Agents
- [interject] **iv-oe4n** MCP Market: Discover Top MCP Servers
- [interverse] **iv-gvpq** Study session context snapshot/restore for handoff continuity
- [interverse] **iv-nonb** Build config profile switching (interctx or extend interphase)
- [interverse] **iv-5leh** Study hook-level agent comms for intra-session coordination
- [interverse] **iv-l6ef** Port hot-path hooks to compiled Go binaries
- [interject] **iv-xda4** Evaluating Static Analysis Alerts with LLMs
- [interject] **iv-f3an** Agent Orchestration: When to Use LangChain, LangGraph, AutoGen
- [interject] **iv-bcq1** New Relic AI Model Context Protocol (MCP)
- [interject] **iv-86ee** Public preview: Power Apps MCP and enhanced agent feed for your business applica
- [interject] **iv-pjxj** Top 10 Low-Code AI Workflow Automation Tools (2026)
- [interject] **iv-vvpj** Make | AI Workflow Automation Software & Tools | Make
- [interject] **iv-eweo** Trigger.dev | Build and deploy fully-managed AI agents and ...
- [interject] **iv-ki35** CORE: Resolving Code Quality Issues using LLMs - Microsoft
- [interject] **iv-btx0** Here is my experience with LLM tools for programming: | Vedran B.
- [interject] **iv-ak1v** Agent Orchestration: When to Use LangChain, LangGraph, AutoGen

**Autarch Phase 3 — Coldwine Migration (P4)**
- **iv-qr0f** E10: Sandboxing + Autarch Phase 3 — Coldwine (blocked by E9)
- **iv-wc74** Coldwine: task hierarchy to beads (blocked by iv-6376)
- **iv-rtwl** Coldwine: agent coordination via `ic dispatch` (blocked by iv-6376)
- **iv-k1q4** Coldwine: intent submission to Clavain OS (blocked by iv-6376)
- **iv-bkzf** Arbiter extraction Phase 3: Coldwine task orchestration to Clavain skills (blocked by iv-u2pd, iv-wc74)

---

## Module Highlights

### autarch (hub/autarch)
Autarch is the application layer of the Interverse stack — interactive TUI surfaces through which Clavain's agency is experienced. Four tools: Bigend (multi-project mission control), Gurgeh (PRD generation), Coldwine (task orchestration), and Pollard (research intelligence). Shared `pkg/tui` component library (Bubble Tea + lipgloss, Tokyo Night theme). Currently migrating from standalone backends to Intercore kernel as shared state layer. Migration follows coupling depth: Bigend (read-only, first) → Pollard → Gurgeh → Coldwine (deepest coupling, last). Arbiter extraction will move agency logic from apps to OS layer.

### intercore (infra/intercore)
Intercore is the platform kernel for multi-agent orchestration — a Go CLI (`ic`) backed by SQLite that provides phase state machines, dispatch tracking, token budgets, gate enforcement, and an event bus with consumer cursors. **E1–E3 complete.** The default phase chain is now 10 phases across 5 macro-stages (Discover, Design, Build, Ship, Reflect). The reflect→done gate requires a learning artifact, closing the recursive self-improvement loop. Four epics remain: E4–E7.

### clavain (hub/clavain)
Clavain is an autonomous software agency — 15 skills, 4 agents, 53 commands (including /reflect for gate-enforced sprint learning), 22 hooks, 1 MCP server. 31 companion plugins shipped.

### intercheck (plugins/intercheck)
Intercheck is the quality and session-health layer for Claude Code and Codex operations, focused on preventing unsafe edits before damage occurs.

### intercraft (plugins/intercraft)
Intercraft captures architecture guidance and auditable agent-native design patterns for complex agent behavior.

### interdev (plugins/interdev)
Interdev provides MCP and CLI-oriented developer workflows for discoverability, command execution, and environment tooling.

### interdoc (plugins/interdoc)
Interdoc synchronizes AGENTS.md/CLAUDE.md governance and enables recursive documentation maintenance with review tooling.

### interfluence (plugins/interfluence)
Interfluence provides voice and style adaptation by profile, giving outputs that fit project conventions.

### interflux (plugins/interflux)
interflux is at stable feature-complete breadth (2 skills, 3 commands, 12 agents, 2 MCP servers) and now in a "quality and operations" phase: tightening edge-case behavior, improving observability, and codifying long-term scalability assumptions.

### interform (plugins/interform)
Interform raises visual and interaction quality for user-facing artifacts and interface workflows.

### interject (plugins/interject)
Interject provides ambient discovery and research execution services for agent workflows.

### interlens (plugins/interlens)
Interlens is the cognitive-lens platform for structured reasoning and belief synthesis.

### interline (plugins/interline)
Interline provides session state visibility with statusline signals for multi-agent and phase-aware workflows.

### interlock (plugins/interlock)
Interlock has shipped Phase 1+2 of multi-session coordination: per-session git index isolation, commit serialization, blocking edit enforcement, and automatic file reservation. The system now provides a complete safety layer from first edit through commit.

### intermux (plugins/intermux)
Intermux surfaces active agent sessions and task progress to support coordination and observability.

### internext (plugins/internext)
Internext prioritizes work proposals and tradeoffs with explicit value-risk scoring.

### interpath (plugins/interpath)
Interpath generates artifacts across roadmap, PRD, vision, changelog, and status from repository intelligence.

### interphase (plugins/interphase)
Interphase manages phase tracking, gate enforcement, and work discovery within Clavain and bead-based workflows.

### interpub (plugins/interpub)
Interpub provides safe version bumping, publishing, and release workflows for plugins and companion modules.

### intersearch (plugins/intersearch)
Intersearch underpins semantic search and Exa-backed discovery shared across Interverse modules.

### interserve (plugins/interserve)
Interserve supports Codex-side classification and context compression for dispatch efficiency.

### interslack (plugins/interslack)
InterSlack connects workflow events to team communication channels with actionable context.

### interstat (plugins/interstat)
Interstat measures token consumption, workflow efficiency, and decision cost across agent sessions.

### interwatch (plugins/interwatch)
Interwatch monitors documentation freshness and confidence so stale artifacts are identified before they mislead decisions.

### tldr-swinton (plugins/tldr-swinton)
tldr-swinton is the token-efficiency context layer for AI code workflows.

### tuivision (plugins/tuivision)
Tuivision automates TUI and terminal UI testing through scriptable sessions and screenshot workflows.

### interkasten (plugins/interkasten)
Interkasten syncs Notion databases to local markdown via MCP, providing offline-first documentation access with WAL-based write safety. Supports bidirectional sync with conflict detection and cloudflared tunnel integration.

### intermem (plugins/intermem)
Intermem graduates stable auto-memory facts into curated reference docs (AGENTS.md/CLAUDE.md). Features citation validation, time-based confidence decay, hash-based promotion/demotion markers, and CLI query tools. Phase 1 (validation overlay) and Phase 2A (decay + demotion) are complete with 184 passing tests.

---

## Research Agenda

<!-- LLM:RESEARCH_AGENDA
Task: Synthesize into 10-15 thematic research bullets.
Format: - **Topic** — 1-line summary

Brainstorm files:
2026-02-14-clavain-vs-modules-boundary-analysis
2026-02-15-intercheck-code-quality-guards-brainstorm
2026-02-15-interject-integration-sweep-brainstorm
2026-02-15-interspect-routing-overrides-brainstorm
2026-02-15-linsenkasten-flux-agents-brainstorm
2026-02-15-multi-session-phase4-merge-agent-brainstorm
2026-02-15-sprint-resilience-brainstorm
2026-02-15-token-efficient-skill-loading
2026-02-16-agent-rig-autonomous-sync-brainstorm
2026-02-16-clavain-token-efficiency-synthesis-brainstorm
2026-02-16-clavain-token-efficiency-trio-brainstorm
2026-02-16-flux-drive-document-slicing-brainstorm
2026-02-16-interbus-central-integration-mesh-brainstorm
2026-02-16-intermap-extraction-brainstorm
2026-02-16-interspect-canary-monitoring-brainstorm
2026-02-16-interstat-token-benchmarking-brainstorm
2026-02-16-linsenkasten-phase1-agents-brainstorm
2026-02-16-sprint-resilience-phase2-brainstorm
2026-02-16-subagent-context-flooding-brainstorm
2026-02-16-token-budget-controls-brainstorm
2026-02-17-intercore-state-database-brainstorm
2026-02-18-intermem-phase1-validation-overlay
2026-02-18-intercore-hook-adapter-brainstorm
2026-02-18-interfluence-code-switching-brainstorm
2026-02-19-intercore-e1-kernel-primitives-brainstorm
2026-02-19-intercore-e2-event-reactor-brainstorm

Plan files:
2026-02-14-clavain-boundary-restructure
2026-02-15-cross-module-integration-opportunities
2026-02-15-intercheck-code-quality-guards
2026-02-15-interject-design
2026-02-15-interject-integration-sweep
2026-02-15-interject-plan-best-5-frameworks-to-build-multi-agent-ai-applications-getst
2026-02-15-interject-plan-claude-codepluginsreadmemd-at-main
2026-02-15-interject-plan-create-plugins-claude-code-docs
2026-02-15-interlock-reservation-negotiation
2026-02-15-interspect-routing-overrides
2026-02-15-linsenkasten-flux-agents
2026-02-15-multi-session-coordination-brainstorm
2026-02-15-sprint-resilience-phase1
2026-02-15-token-efficient-skill-loading
2026-02-16-clavain-token-efficiency
2026-02-16-clavain-token-efficiency-trio
2026-02-16-flux-drive-document-slicing
2026-02-16-intermap-extraction
2026-02-16-interspect-canary-monitoring
2026-02-16-interstat-token-benchmarking
2026-02-16-intersynth-codex-dispatch
2026-02-16-linsenkasten-phase1-remaining-agents
2026-02-16-sprint-resilience-phase2
2026-02-16-subagent-context-flooding
2026-02-16-token-budget-controls
2026-02-17-framework-benchmark-freshness-automation
2026-02-17-heterogeneous-collaboration-routing
2026-02-17-interband-sideband-hardening
2026-02-17-intercore-state-database
2026-02-17-multi-framework-interoperability-benchmark
2026-02-17-repository-aware-benchmark-expansion
2026-02-17-role-aware-latent-memory-experiments
2026-02-18-intermem-phase1-validation-overlay
2026-02-18-intercore-hook-adapter
2026-02-18-interfluence-f1-f2-voice-storage-config
2026-02-18-intermem-phase2a-decay-demotion
2026-02-18-intercore-run-tracking
2026-02-18-interstat-report-pipeline
2026-02-18-interfluence-f3-f6-analyzer-apply-hook-skills
2026-02-18-intercore-event-bus
2026-02-19-intercore-e1-kernel-primitives
2026-02-19-intercore-e2-event-reactor
2026-02-19-intercore-spawn-handler-wiring

END LLM:RESEARCH_AGENDA -->

---

## Cross-Module Dependencies

Major dependency chains spanning multiple modules:

- **Intercore autonomy ladder:** E3 (hook cutover) → E4 (adapt) → E5 (discovery) → E6/E7 (recovery, TUI)
- **Autarch migration chain:** E7 (Bigend) → E9 (Pollard + Gurgeh) → E10 (Coldwine); arbiter extraction: iv-ts3b → iv-u2pd → iv-bkzf
- **Autarch ↔ Intercore:** E5 (discovery) blocks Pollard migration (iv-fsxc, iv-skyk); E7 blocks Gurgeh migration (iv-8y3w, iv-t4v6)
- **iv-jc4j** (intermute) blocked by **iv-qznx** (interflux)
- **iv-v81k** (interstat) blocked by **iv-qznx** (interflux)
- **iv-wz3j** (interflux) blocked by **iv-jc4j** (intermute)
- **iv-ynbh** (interverse) blocked by **iv-vrc4** (interspect) — now closed, may unblock iv-qjwz
- **Learning loop chain:** ~~iv-8jpf~~ (done) → iv-rafa (meta-learning, interspect, unblocked) → iv-bj0w (conflict detection); hardening: iv-mkfy (hard gate) → iv-64j3 (multi-agent reflection)

---

## Modules Without Roadmaps

- `plugins/intermap`
- `plugins/intermem`
- `plugins/interpeer`
- `plugins/intersynth`
- `plugins/intertest`

---

## Keeping Current

```
# Regenerate this roadmap JSON from current repo state
scripts/sync-roadmap-json.sh docs/roadmap.json

# Regenerate via interpath command flow (Claude Code)
/interpath:roadmap    (from Interverse root)

# Propagate items to subrepo roadmaps
/interpath:propagate  (from Interverse root)
```
