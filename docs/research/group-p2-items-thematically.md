**Intercore Discovery Pipeline**
- [intercore] **iv-zawf** F1: Discovery schema + migration (v8→v9)
- [intercore] **iv-faq6** F2: Discovery CRUD CLI (submit/status/list/score/promote/dismiss)
- [intercore] **iv-6d4m** F3: Discovery events (event bus integration)
- [intercore] **iv-59ka** F4: Feedback signals + interest profile
- [intercore] **iv-06r4** F5: Tier gates + dedup + decay + discovery rollback
- [intercore] **iv-uomr** F6: Embedding search (brute-force cosine)
- [clavain/interphase] **iv-zsio** Integrate full discovery pipeline into sprint workflow

**Clavain Adaptive Routing + Agency**
- [clavain] **iv-dd9q** B1: Static routing table — phase-to-model mapping in config
- [clavain] **iv-k8xn** B2: Complexity-aware routing — task complexity drives model selection
- [clavain] **iv-22g1** Replace manual model-profile toggle with adaptive/complexity-aware routing
- [clavain] **iv-asfy** C1: Agency specs — declarative per-stage agent/model/tool config
- [clavain] **iv-lx00** C2: Agent fleet registry — capability + cost profiles per agent×model
- [clavain] **iv-r9j2** A3: Event-driven advancement — phase transitions trigger auto-dispatch

**Autarch Dashboard + TUI**
- [autarch] **iv-lemf** Bigend: swap project discovery to ic run list
- [autarch] **iv-9au2** Bigend: swap agent monitoring to ic dispatch list
- [autarch] **iv-gv7i** Bigend: swap run progress to ic events tail
- [autarch] **iv-4c16** Bigend: bootstrap-then-stream event viewport
- [autarch] **iv-1d9u** Bigend: dashboard metrics from kernel aggregates
- [autarch] **iv-4zle** Bigend: two-pane lazy* layout (list + detail)
- [autarch] **iv-26pj** Streaming buffer / history split per agent panel
- [autarch] **iv-jaxw** Typed KernelEvent enum for all observable state changes

**Autarch Agent Status + Resilience**
- [autarch] **iv-knwr** pkg/tui: validate components with kernel data
- [autarch] **iv-xu31** Adopt 4-state status model with consistent icons
- [autarch] **iv-ht1l** Pollard: progressive result reveal per hunter
- [autarch] **iv-xlpg** Pollard: optional-death hunter resilience

**Interspect Routing Override + Safety**
- [interspect] **iv-r6mf** F1: routing-overrides.json schema + flux-drive reader
- [interspect] **iv-8fgu** F2: routing-eligible pattern detection + propose flow
- [interspect] **iv-gkj9** F3: apply override + canary + git commit
- [interspect] **iv-2o6c** F4: status display + revert for routing overrides
- [interspect] **iv-6liz** F5: manual routing override support
- [interspect] **iv-003t** Global modification rate limiter
- [interspect] **iv-0fi2** Circuit breaker
- [interspect] **iv-drgo** Privilege separation (proposer/applier)

**Interspect Evaluation + Meta-Learning**
- [interspect] **iv-88yg** Structured commit message format
- [interspect] **iv-435u** Counterfactual shadow evaluation
- [interspect] **iv-izth** Eval corpus construction
- [interspect] **iv-rafa** Meta-learning loop
- [interspect] **iv-t1m4** Prompt tuning (Type 3) overlay-based
- [interspect] **iv-m6cd** Session-start summary injection
- [interspect] **iv-5su3** Autonomous mode flag
- [interspect] **iv-bj0w** Conflict detection
- [interspect] **iv-c2b4** /interspect:disable command
- [interspect] **iv-g0to** /interspect:reset command

**Multi-Agent Coordination + Negotiation**
- [interlock] **iv-1aug** F1: Release Response Protocol (release_ack / release_defer)
- [interlock] **iv-gg8v** F2: Auto-Release on Clean Files
- [interlock] **iv-5ijt** F3: Structured negotiate_release MCP Tool
- [interlock] **iv-6u3s** F4: Sprint Scan Release Visibility
- [interlock] **iv-2jtj** F5: Escalation Timeout for Unresponsive Agents
- [intermute] **iv-jc4j** Heterogeneous agent routing experiments inspired by SC-MAS/Dr. MAS
- [intermute] **iv-ev4o** Agent capability discovery via intermute registration
- [interverse] **iv-quk4** Hierarchical dispatch: meta-agent for N-agent fan-out

**Token Efficiency + Metrics**
- [interstat] **iv-qi8j** F1: PostToolUse:Task hook (real-time event capture)
- [interstat] **iv-lgfi** F2: Conversation JSONL parser (token backfill)
- [interstat] **iv-dkg8** F3: interstat report (analysis queries + decision gate)
- [interstat] **iv-bazo** F4: interstat status (collection progress)
- [interstat] **iv-v81k** Repository-aware benchmark expansion for agent coding tasks
- [interverse] **iv-0lt** Extract cache_hints metrics in score_tokens.py
- [interverse] **iv-1gb** Add cache-friendly format queries to regression_suite.json
- [interverse] **iv-4728** Consolidate upstream-check.sh API calls (24 to 12)

**Flux-Drive + Interflux Extraction**
- [flux-drive-spec] **iv-ia66** Phase 2: Extract domain detection library
- [flux-drive-spec] **iv-0etu** Phase 3: Extract scoring/synthesis Python library
- [flux-drive-spec] **iv-e8dg** Phase 4: Migrate Clavain to consume the library
- [interflux] **iv-905u** Intermediate result sharing between parallel flux-drive agents
- [interflux] **iv-qjwz** AgentDropout: dynamic redundancy elimination for flux-drive reviews
- [interflux] **iv-wz3j** Role-aware latent memory architecture experiments

**Ecosystem Infrastructure + Research**
- [intercore] **iv-bmux** Rebaseline horizon table against open roadmap beads
- [intercore] **iv-wp62** Add portfolio-level dependency/scheduling primitives
- [interverse] **iv-czwf** F4: Migrate interflux as dual-mode reference implementation
- [interverse] **iv-frqh** F5: clavain:setup modpack — auto-install ecosystem-only plugins
- [interverse] **iv-o9w6** F3: Companion nudge protocol implementation
- [interverse] **iv-mqm4** Session-start drift summary injection
- [interverse] **iv-zyym** Evaluate Claude Hub for event-driven GitHub agent dispatch
- [interverse] **iv-3w1x** Split upstreams.json into config + state files

**Memory, Knowledge Compounding + Caching**
- [intermem] **iv-f7po** F3: Multi-file tiered promotion — AGENTS.md index + docs/intermem/ detail
- [intermem] **iv-bn4j** F4: One-shot tiered migration — --migrate-to-tiered
- [interverse] **iv-p4qq** Smart semantic caching across sessions (intercache)
- [interverse] **iv-sdqv** Plan interscribe extraction (knowledge compounding)
- [interverse] **iv-6ikc** Plan intershift extraction (cross-AI dispatch engine)
- [interverse] **iv-xuec** Security threat model for token optimization techniques

**Research Agenda**
- [interverse] **iv-3kee** Research: product-native agent orchestration (whitespace opportunity)
- [interverse] **iv-dthn** Research: inter-layer feedback loops and optimization thresholds
- [interverse] **iv-exos** Research: bias-aware product decision framework
- [interverse] **iv-fzrn** Research: multi-agent hallucination cascades & failure taxonomy
- [interverse] **iv-l5ap** Research: transactional orchestration & error recovery patterns
- [interverse] **iv-jk7q** Research: cognitive load budgets & progressive disclosure review UX
