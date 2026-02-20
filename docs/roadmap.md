# Interverse Roadmap

**Modules:** 35 | **Open beads (root tracker):** 353 | **Blocked (root tracker):** 55 | **Last updated:** 2026-02-20
**Structure:** [`CLAUDE.md`](../CLAUDE.md)
**Machine output:** [`docs/roadmap.json`](roadmap.json)

---

## Ecosystem Snapshot

| Module | Location | Version | Status | Roadmap | Open Beads (context) |
|--------|----------|---------|--------|---------|----------------------|
| autarch | hub/autarch | 0.1.0 | early | no | n/a |
| clavain | hub/clavain | 0.6.51 | active | yes | n/a |
| intercheck | plugins/intercheck | 0.1.4 | active | yes | 4 |
| intercraft | plugins/intercraft | 0.1.0 | active | yes | 4 |
| interdev | plugins/interdev | 0.2.0 | active | yes | 4 |
| interdoc | plugins/interdoc | 5.1.1 | active | yes | 4 |
| interfluence | plugins/interfluence | 0.2.3 | active | yes | 4 |
| interflux | plugins/interflux | 0.2.16 | active | yes | 19 |
| interform | plugins/interform | 0.1.0 | active | yes | 4 |
| interject | plugins/interject | 0.1.6 | active | yes | 4 |
| interkasten | plugins/interkasten | 0.4.2 | active | yes | 12 |
| interleave | plugins/interleave | 0.1.1 | early | no | n/a |
| interlens | plugins/interlens | 2.2.4 | active | yes | 4 |
| interline | plugins/interline | 0.2.4 | active | yes | 4 |
| interlock | plugins/interlock | 0.2.1 | active | yes | 10 |
| intermap | plugins/intermap | 0.1.3 | early | no | n/a |
| intermem | plugins/intermem | 0.2.1 | early | no | n/a |
| intermute | services/intermute | — | active | yes | 29 |
| intermux | plugins/intermux | 0.1.1 | active | yes | 4 |
| internext | plugins/internext | 0.1.2 | active | yes | 4 |
| interpath | plugins/interpath | 0.2.2 | active | yes | 4 |
| interpeer | plugins/interpeer | 0.1.0 | early | no | n/a |
| interphase | plugins/interphase | 0.3.2 | active | yes | 4 |
| interpub | plugins/interpub | 0.1.2 | active | yes | 4 |
| intersearch | plugins/intersearch | 0.1.1 | active | yes | 4 |
| interserve | plugins/interserve | 0.1.1 | active | yes | 4 |
| interslack | plugins/interslack | 0.1.0 | active | yes | 4 |
| interstat | plugins/interstat | 0.2.2 | active | yes | 4 |
| intersynth | plugins/intersynth | 0.1.2 | early | no | n/a |
| intertest | plugins/intertest | 0.1.1 | early | no | n/a |
| interverse | root | — | active | yes | n/a |
| interwatch | plugins/interwatch | 0.1.2 | active | yes | 4 |
| tldr-swinton | plugins/tldr-swinton | 0.7.14 | active | yes | 15 |
| tool-time | plugins/tool-time | 0.3.2 | active | yes | 12 |
| tuivision | plugins/tuivision | 0.1.4 | active | yes | 4 |

**Legend:** active = recent commits or active tracker items; early = manifest exists but roadmap maturity is limited. `n/a` means there is no module-local `.beads` database.

---

## Roadmap

### Now (P0-P1)

- [autarch] **iv-0v7j** Wire signal broker into Bigend/TUI runtime path
- [clavain] **iv-145j** Implement event-reactor auto-advance loop for phase transitions
- [intercore] **iv-1vz6** Update vision doc: rollback is already shipped in v1 CLI
- [interverse] **iv-2lfb** F1: Build infra/interbase/ — centralized interbase.sh SDK (blocked by iv-gcu2)
- [interverse] **iv-gcu2** Dual-mode plugin architecture — interbase SDK + integration manifest
- [interverse] **iv-h7e2** F2: Define integration.json schema + interbase-stub.sh template (blocked by iv-gcu2)
- [intercore] **iv-ishl** E7: Autarch Phase 1 — Bigend migration + ic tui (blocked by iv-9plh, iv-c6az)
- [interverse/clavain] **iv-t93l** Close Interspect routing loop with automatic adaptation

**Recently completed:** iv-kj6w (A2: Sprint handover — sprint skill becomes kernel-driven), iv-bld6 (F2: Workflow state rollback (ic run rollback --to-phase)), iv-2yef (Autarch: ship minimal status tool as kernel validation wedge), iv-pbmc (Cost-aware agent scheduling with token budgets), iv-8jpf (Add reflect/compound phase to default sprint chain), iv-shra (E4.2: Durable cursor registration for long-lived consumers), iv-3sns (E4.1: Kernel interspect_events table + ic interspect record CLI), iv-ooon (Harmonize Clavain docs with revised vision — 6 drift fixes), iv-yeka (Update roadmap.md for new vision + parallel tracks), iv-lhdb (P0: Event emission authority — only kernel should emit state events), iv-s6zo (F1: lib-sprint.sh rewrite — ic run CRUD), iv-l49k (Apply Oracle review synthesis — 10 themes across 3 vision docs), iv-l49k.3 (T3: Move policy out of kernel doc — scoring, decay, presets, revert), iv-l49k.4 (T4: Resolve ic state contradiction — promote to public primitive), iv-l49k.2 (T2: Add write-path contracts — define who can mutate kernel state), iv-l49k.6 (T6: Create shared glossary — resolve term overloading across docs), iv-l49k.1 (T1: Normalize stack to 3 layers — remove 'Layer 3: Drivers' language), iv-ckkr (Apply vision doc review findings — 17 content moves + doc fixes), iv-byh3 (Define platform kernel + lifecycle UX architecture), iv-7o7n (Document slicing for flux-drive agents (P0 token optimization))

### Next (P2)

<!-- LLM:NEXT_GROUPINGS
Task: Group these P2 items under 5-10 thematic headings.
Format: **Bold Heading** followed by bullet items.
Heuristic: items sharing a [module] tag or dependency chain likely belong together.

Raw P2 items JSON:
[{"id":"iv-003t","title":"[interspect] Global modification rate limiter","priority":2,"dependencies":[{"issue_id":"iv-003t","depends_on_id":"iv-nkak","type":"blocks","created_at":"2026-02-15T01:35:01Z","created_by":"mk","metadata":"{}"}]},{"id":"iv-06r4","title":"F5: Tier gates + dedup + decay + discovery rollback","priority":2,"dependencies":[{"issue_id":"iv-06r4","depends_on_id":"iv-59ka","type":"blocks","created_at":"2026-02-20T11:58:44Z","created_by":"mk","metadata":"{}"},{"issue_id":"iv-06r4","depends_on_id":"iv-6d4m","type":"blocks","created_at":"2026-02-20T11:58:44Z","created_by":"mk","metadata":"{}"},{"issue_id":"iv-06r4","depends_on_id":"iv-fra3","type":"blocks","created_at":"2026-02-20T11:58:43Z","created_by":"mk","metadata":"{}"}]},{"id":"iv-0etu","title":"[flux-drive-spec] Phase 3: Extract scoring/synthesis Python library","priority":2,"dependencies":[{"issue_id":"iv-0etu","depends_on_id":"iv-ia66","type":"blocks","created_at":"2026-02-13T22:47:12Z","created_by":"mk","metadata":"{}"}]},{"id":"iv-0fi2","title":"[interspect] Circuit breaker","priority":2,"dependencies":[{"issue_id":"iv-0fi2","depends_on_id":"iv-ukct","type":"blocks","created_at":"2026-02-15T01:35:06Z","created_by":"mk","metadata":"{}"}]},{"id":"iv-0lt","title":"Extract cache_hints metrics in score_tokens.py","priority":2,"dependencies":null},{"id":"iv-1aug","title":"F1: Release Response Protocol (release_ack / release_defer)","priority":2,"dependencies":[{"issue_id":"iv-1aug","depends_on_id":"iv-d72t","type":"blocks","created_at":"2026-02-15T09:11:40Z","created_by":"mk","metadata":"{}"}]},{"id":"iv-1d9u","title":"[autarch] Bigend: dashboard metrics from kernel aggregates","priority":2,"dependencies":null},{"id":"iv-1gb","title":"Add cache-friendly format queries to regression_suite.json","priority":2,"dependencies":null},{"id":"iv-22g1","title":"[clavain] Replace manual model-profile toggle with adaptive/complexity-aware routing","priority":2,"dependencies":null},{"id":"iv-26pj","title":"[autarch] Streaming buffer / history split per agent panel","priority":2,"dependencies":null},{"id":"iv-2jtj","title":"F5: Escalation Timeout for Unresponsive Agents","priority":2,"dependencies":[{"issue_id":"iv-2jtj","depends_on_id":"iv-5ijt","type":"blocks","created_at":"2026-02-15T09:11:41Z","created_by":"mk","metadata":"{}"},{"issue_id":"iv-2jtj","depends_on_id":"iv-d72t","type":"blocks","created_at":"2026-02-15T09:11:40Z","created_by":"mk","metadata":"{}"}]},{"id":"iv-2o6c","title":"[interspect] F4: status display + revert for routing overrides","priority":2,"dependencies":[{"issue_id":"iv-2o6c","depends_on_id":"iv-gkj9","type":"blocks","created_at":"2026-02-15T12:47:18Z","created_by":"mk","metadata":"{}"},{"issue_id":"iv-2o6c","depends_on_id":"iv-nkak","type":"blocks","created_at":"2026-02-15T12:47:16Z","created_by":"mk","metadata":"{}"}]},{"id":"iv-3kee","title":"Research: product-native agent orchestration (whitespace opportunity)","priority":2,"dependencies":null},{"id":"iv-3w1x","title":"Split upstreams.json into config + state files","priority":2,"dependencies":null},{"id":"iv-435u","title":"[interspect] Counterfactual shadow evaluation","priority":2,"dependencies":[{"issue_id":"iv-435u","depends_on_id":"iv-nkak","type":"blocks","created_at":"2026-02-15T07:31:17Z","created_by":"mk","metadata":"{}"}]},{"id":"iv-4728","title":"Consolidate upstream-check.sh API calls (24 to 12)","priority":2,"dependencies":null},{"id":"iv-4c16","title":"[autarch] Bigend: bootstrap-then-stream event viewport","priority":2,"dependencies":null},{"id":"iv-4zle","title":"[autarch] Bigend: two-pane lazy* layout (list + detail)","priority":2,"dependencies":null},{"id":"iv-59ka","title":"F4: Feedback signals + interest profile","priority":2,"dependencies":[{"issue_id":"iv-59ka","depends_on_id":"iv-faq6","type":"blocks","created_at":"2026-02-20T11:58:44Z","created_by":"mk","metadata":"{}"},{"issue_id":"iv-59ka","depends_on_id":"iv-fra3","type":"blocks","created_at":"2026-02-20T11:58:42Z","created_by":"mk","metadata":"{}"}]},{"id":"iv-5ijt","title":"F3: Structured negotiate_release MCP Tool","priority":2,"dependencies":[{"issue_id":"iv-5ijt","depends_on_id":"iv-1aug","type":"blocks","created_at":"2026-02-15T09:11:41Z","created_by":"mk","metadata":"{}"},{"issue_id":"iv-5ijt","depends_on_id":"iv-d72t","type":"blocks","created_at":"2026-02-15T09:11:40Z","created_by":"mk","metadata":"{}"}]},{"id":"iv-5su3","title":"[interspect] Autonomous mode flag","priority":2,"dependencies":[{"issue_id":"iv-5su3","depends_on_id":"iv-cylo","type":"blocks","created_at":"2026-02-15T07:32:25Z","created_by":"mk","metadata":"{}"},{"issue_id":"iv-5su3","depends_on_id":"iv-jo3i","type":"blocks","created_at":"2026-02-15T01:35:05Z","created_by":"mk","metadata":"{}"}]},{"id":"iv-6d4m","title":"F3: Discovery events (event bus integration)","priority":2,"dependencies":[{"issue_id":"iv-6d4m","depends_on_id":"iv-faq6","type":"blocks","created_at":"2026-02-20T11:58:43Z","created_by":"mk","metadata":"{}"},{"issue_id":"iv-6d4m","depends_on_id":"iv-fra3","type":"blocks","created_at":"2026-02-20T11:58:42Z","created_by":"mk","metadata":"{}"}]},{"id":"iv-6ikc","title":"Plan intershift extraction (cross-AI dispatch engine)","priority":2,"dependencies":null},{"id":"iv-6liz","title":"[interspect] F5: manual routing override support","priority":2,"dependencies":[{"issue_id":"iv-6liz","depends_on_id":"iv-nkak","type":"blocks","created_at":"2026-02-15T12:47:17Z","created_by":"mk","metadata":"{}"},{"issue_id":"iv-6liz","depends_on_id":"iv-r6mf","type":"blocks","created_at":"2026-02-15T12:47:18Z","created_by":"mk","metadata":"{}"}]},{"id":"iv-6u3s","title":"F4: Sprint Scan Release Visibility","priority":2,"dependencies":[{"issue_id":"iv-6u3s","depends_on_id":"iv-1aug","type":"blocks","created_at":"2026-02-15T09:11:41Z","created_by":"mk","metadata":"{}"},{"issue_id":"iv-6u3s","depends_on_id":"iv-d72t","type":"blocks","created_at":"2026-02-15T09:11:40Z","created_by":"mk","metadata":"{}"}]},{"id":"iv-88yg","title":"[interspect] Structured commit message format","priority":2,"dependencies":[{"issue_id":"iv-88yg","depends_on_id":"iv-nkak","type":"blocks","created_at":"2026-02-15T01:35:01Z","created_by":"mk","metadata":"{}"}]},{"id":"iv-8fgu","title":"[interspect] F2: routing-eligible pattern detection + propose flow","priority":2,"dependencies":[{"issue_id":"iv-8fgu","depends_on_id":"iv-nkak","type":"blocks","created_at":"2026-02-15T12:47:16Z","created_by":"mk","metadata":"{}"},{"issue_id":"iv-8fgu","depends_on_id":"iv-r6mf","type":"blocks","created_at":"2026-02-15T12:47:18Z","created_by":"mk","metadata":"{}"}]},{"id":"iv-905u","title":"Intermediate result sharing between parallel flux-drive agents","priority":2,"dependencies":[{"issue_id":"iv-905u","depends_on_id":"iv-ffo5","type":"relates-to","created_at":"2026-02-18T15:45:10Z","created_by":"mk","metadata":"{}"}]},{"id":"iv-9au2","title":"[autarch] Bigend: swap agent monitoring to ic dispatch list","priority":2,"dependencies":null},{"id":"iv-asfy","title":"[clavain] C1: Agency specs — declarative per-stage agent/model/tool config","priority":2,"dependencies":null},{"id":"iv-bazo","title":"F4: interstat status (collection progress)","priority":2,"dependencies":[{"issue_id":"iv-bazo","depends_on_id":"iv-dyyy","type":"blocks","created_at":"2026-02-15T19:39:18Z","created_by":"mk","metadata":"{}"},{"issue_id":"iv-bazo","depends_on_id":"iv-jq5b","type":"blocks","created_at":"2026-02-15T19:39:15Z","created_by":"mk","metadata":"{}"},{"issue_id":"iv-bazo","depends_on_id":"iv-lgfi","type":"blocks","created_at":"2026-02-15T19:39:20Z","created_by":"mk","metadata":"{}"}]},{"id":"iv-bj0w","title":"[interspect] Conflict detection","priority":2,"dependencies":[{"issue_id":"iv-bj0w","depends_on_id":"iv-rafa","type":"blocks","created_at":"2026-02-15T01:35:06Z","created_by":"mk","metadata":"{}"}]},{"id":"iv-bmux","title":"[intercore] Rebaseline horizon table against open roadmap beads","priority":2,"dependencies":null},{"id":"iv-bn4j","title":"[intermem] F4: One-shot tiered migration — --migrate-to-tiered","priority":2,"dependencies":[{"issue_id":"iv-bn4j","depends_on_id":"iv-f7po","type":"blocks","created_at":"2026-02-18T08:36:04Z","created_by":"mk","metadata":"{}"},{"issue_id":"iv-bn4j","depends_on_id":"iv-rkrm","type":"blocks","created_at":"2026-02-18T08:36:02Z","created_by":"mk","metadata":"{}"}]},{"id":"iv-c2b4","title":"[interspect] /interspect:disable command","priority":2,"dependencies":[{"issue_id":"iv-c2b4","depends_on_id":"iv-o4x7","type":"blocks","created_at":"2026-02-15T01:35:06Z","created_by":"mk","metadata":"{}"}]},{"id":"iv-czwf","title":"F4: Migrate interflux as dual-mode reference implementation","priority":2,"dependencies":[{"issue_id":"iv-czwf","depends_on_id":"iv-2lfb","type":"blocks","created_at":"2026-02-20T12:49:43Z","created_by":"mk","metadata":"{}"},{"issue_id":"iv-czwf","depends_on_id":"iv-gcu2","type":"blocks","created_at":"2026-02-20T12:49:42Z","created_by":"mk","metadata":"{}"},{"issue_id":"iv-czwf","depends_on_id":"iv-h7e2","type":"blocks","created_at":"2026-02-20T12:49:43Z","created_by":"mk","metadata":"{}"}]},{"id":"iv-dd9q","title":"[clavain] B1: Static routing table — phase-to-model mapping in config","priority":2,"dependencies":null},{"id":"iv-dkg8","title":"F3: interstat report (analysis queries + decision gate)","priority":2,"dependencies":[{"issue_id":"iv-dkg8","depends_on_id":"iv-dyyy","type":"blocks","created_at":"2026-02-15T19:39:17Z","created_by":"mk","metadata":"{}"},{"issue_id":"iv-dkg8","depends_on_id":"iv-jq5b","type":"blocks","created_at":"2026-02-15T19:39:15Z","created_by":"mk","metadata":"{}"},{"issue_id":"iv-dkg8","depends_on_id":"iv-lgfi","type":"blocks","created_at":"2026-02-15T19:39:20Z","created_by":"mk","metadata":"{}"}]},{"id":"iv-drgo","title":"[interspect] Privilege separation (proposer/applier)","priority":2,"dependencies":[{"issue_id":"iv-drgo","depends_on_id":"iv-nkak","type":"blocks","created_at":"2026-02-15T07:31:17Z","created_by":"mk","metadata":"{}"}]},{"id":"iv-dthn","title":"Research: inter-layer feedback loops and optimization thresholds","priority":2,"dependencies":null},{"id":"iv-e8dg","title":"[flux-drive-spec] Phase 4: Migrate Clavain to consume the library","priority":2,"dependencies":[{"issue_id":"iv-e8dg","depends_on_id":"iv-0etu","type":"blocks","created_at":"2026-02-13T22:47:13Z","created_by":"mk","metadata":"{}"}]},{"id":"iv-ev4o","title":"Agent capability discovery via intermute registration","priority":2,"dependencies":null},{"id":"iv-exos","title":"Research: bias-aware product decision framework","priority":2,"dependencies":null},{"id":"iv-f7po","title":"[intermem] F3: Multi-file tiered promotion — AGENTS.md index + docs/intermem/ detail","priority":2,"dependencies":[{"issue_id":"iv-f7po","depends_on_id":"iv-rkrm","type":"blocks","created_at":"2026-02-18T08:36:02Z","created_by":"mk","metadata":"{}"}]},{"id":"iv-faq6","title":"F2: Discovery CRUD CLI (submit/status/list/score/promote/dismiss)","priority":2,"dependencies":[{"issue_id":"iv-faq6","depends_on_id":"iv-fra3","type":"blocks","created_at":"2026-02-20T11:58:42Z","created_by":"mk","metadata":"{}"},{"issue_id":"iv-faq6","depends_on_id":"iv-zawf","type":"blocks","created_at":"2026-02-20T11:58:43Z","created_by":"mk","metadata":"{}"}]},{"id":"iv-frqh","title":"F5: clavain:setup modpack — auto-install ecosystem-only plugins","priority":2,"dependencies":[{"issue_id":"iv-frqh","depends_on_id":"iv-gcu2","type":"blocks","created_at":"2026-02-20T12:49:42Z","created_by":"mk","metadata":"{}"}]},{"id":"iv-fzrn","title":"Research: multi-agent hallucination cascades & failure taxonomy","priority":2,"dependencies":[{"issue_id":"iv-fzrn","depends_on_id":"iv-ffo5","type":"relates-to","created_at":"2026-02-18T15:45:11Z","created_by":"mk","metadata":"{}"}]},{"id":"iv-g0to","title":"[interspect] /interspect:reset command","priority":2,"dependencies":[{"issue_id":"iv-g0to","depends_on_id":"iv-ukct","type":"blocks","created_at":"2026-02-15T01:35:06Z","created_by":"mk","metadata":"{}"}]},{"id":"iv-gg8v","title":"F2: Auto-Release on Clean Files","priority":2,"dependencies":[{"issue_id":"iv-gg8v","depends_on_id":"iv-1aug","type":"blocks","created_at":"2026-02-15T09:11:41Z","created_by":"mk","metadata":"{}"},{"issue_id":"iv-gg8v","depends_on_id":"iv-d72t","type":"blocks","created_at":"2026-02-15T09:11:40Z","created_by":"mk","metadata":"{}"}]},{"id":"iv-gkj9","title":"[interspect] F3: apply override + canary + git commit","priority":2,"dependencies":[{"issue_id":"iv-gkj9","depends_on_id":"iv-8fgu","type":"blocks","created_at":"2026-02-15T12:47:18Z","created_by":"mk","metadata":"{}"},{"issue_id":"iv-gkj9","depends_on_id":"iv-nkak","type":"blocks","created_at":"2026-02-15T12:47:16Z","created_by":"mk","metadata":"{}"}]},{"id":"iv-gv7i","title":"[autarch] Bigend: swap run progress to ic events tail","priority":2,"dependencies":null},{"id":"iv-ht1l","title":"[autarch] Pollard: progressive result reveal per hunter","priority":2,"dependencies":null},{"id":"iv-ia66","title":"[flux-drive-spec] Phase 2: Extract domain detection library","priority":2,"dependencies":null},{"id":"iv-izth","title":"[interspect] Eval corpus construction","priority":2,"dependencies":[{"issue_id":"iv-izth","depends_on_id":"iv-nkak","type":"blocks","created_at":"2026-02-15T01:35:06Z","created_by":"mk","metadata":"{}"}]},{"id":"iv-jaxw","title":"[autarch] Typed KernelEvent enum for all observable state changes","priority":2,"dependencies":null},{"id":"iv-jc4j","title":"[intermute] Heterogeneous agent routing experiments inspired by SC-MAS/Dr. MAS","priority":2,"dependencies":[{"issue_id":"iv-jc4j","depends_on_id":"iv-qznx","type":"blocks","created_at":"2026-02-16T22:40:51Z","created_by":"mk","metadata":"{}"}]},{"id":"iv-jk7q","title":"Research: cognitive load budgets & progressive disclosure review UX","priority":2,"dependencies":null},{"id":"iv-k8xn","title":"[clavain] B2: Complexity-aware routing — task complexity drives model selection","priority":2,"dependencies":[{"issue_id":"iv-k8xn","depends_on_id":"iv-dd9q","type":"blocks","created_at":"2026-02-20T09:28:06Z","created_by":"mk","metadata":"{}"}]},{"id":"iv-knwr","title":"[autarch] pkg/tui: validate components with kernel data","priority":2,"dependencies":[{"issue_id":"iv-knwr","depends_on_id":"iv-2yef","type":"blocks","created_at":"2026-02-19T23:12:03Z","created_by":"mk","metadata":"{}"}]},{"id":"iv-l5ap","title":"Research: transactional orchestration & error recovery patterns","priority":2,"dependencies":[{"issue_id":"iv-l5ap","depends_on_id":"iv-ffo5","type":"relates-to","created_at":"2026-02-18T15:45:12Z","created_by":"mk","metadata":"{}"}]},{"id":"iv-lemf","title":"[autarch] Bigend: swap project discovery to ic run list","priority":2,"dependencies":null},{"id":"iv-lgfi","title":"F2: Conversation JSONL parser (token backfill)","priority":2,"dependencies":[{"issue_id":"iv-lgfi","depends_on_id":"iv-dyyy","type":"blocks","created_at":"2026-02-15T19:39:17Z","created_by":"mk","metadata":"{}"},{"issue_id":"iv-lgfi","depends_on_id":"iv-jq5b","type":"blocks","created_at":"2026-02-15T19:39:14Z","created_by":"mk","metadata":"{}"}]},{"id":"iv-lx00","title":"[clavain] C2: Agent fleet registry — capability + cost profiles per agent×model","priority":2,"dependencies":[{"issue_id":"iv-lx00","depends_on_id":"iv-asfy","type":"blocks","created_at":"2026-02-20T09:28:07Z","created_by":"mk","metadata":"{}"},{"issue_id":"iv-lx00","depends_on_id":"iv-dd9q","type":"blocks","created_at":"2026-02-20T09:28:06Z","created_by":"mk","metadata":"{}"}]},{"id":"iv-m6cd","title":"[interspect] Session-start summary injection","priority":2,"dependencies":[{"issue_id":"iv-m6cd","depends_on_id":"iv-o4x7","type":"blocks","created_at":"2026-02-15T01:34:57Z","created_by":"mk","metadata":"{}"}]},{"id":"iv-mqm4","title":"Session-start drift summary injection","priority":2,"dependencies":null},{"id":"iv-o9w6","title":"F3: Companion nudge protocol implementation","priority":2,"dependencies":[{"issue_id":"iv-o9w6","depends_on_id":"iv-2lfb","type":"blocks","created_at":"2026-02-20T12:49:43Z","created_by":"mk","metadata":"{}"},{"issue_id":"iv-o9w6","depends_on_id":"iv-gcu2","type":"blocks","created_at":"2026-02-20T12:49:42Z","created_by":"mk","metadata":"{}"}]},{"id":"iv-p4qq","title":"Smart semantic caching across sessions (intercache)","priority":2,"dependencies":[{"issue_id":"iv-p4qq","depends_on_id":"iv-qtcl","type":"relates-to","created_at":"2026-02-18T15:45:12Z","created_by":"mk","metadata":"{}"}]},{"id":"iv-qi8j","title":"F1: PostToolUse:Task hook (real-time event capture)","priority":2,"dependencies":[{"issue_id":"iv-qi8j","depends_on_id":"iv-dyyy","type":"blocks","created_at":"2026-02-15T19:39:17Z","created_by":"mk","metadata":"{}"},{"issue_id":"iv-qi8j","depends_on_id":"iv-jq5b","type":"blocks","created_at":"2026-02-15T19:39:14Z","created_by":"mk","metadata":"{}"}]},{"id":"iv-qjwz","title":"AgentDropout: dynamic redundancy elimination for flux-drive reviews","priority":2,"dependencies":[{"issue_id":"iv-qjwz","depends_on_id":"iv-8m38","type":"blocks","created_at":"2026-02-15T17:42:31Z","created_by":"mk","metadata":"{}"},{"issue_id":"iv-qjwz","depends_on_id":"iv-ynbh","type":"blocks","created_at":"2026-02-15T17:31:23Z","created_by":"mk","metadata":"{}"}]},{"id":"iv-quk4","title":"Hierarchical dispatch: meta-agent for N-agent fan-out","priority":2,"dependencies":null},{"id":"iv-r6mf","title":"[interspect] F1: routing-overrides.json schema + flux-drive reader","priority":2,"dependencies":[{"issue_id":"iv-r6mf","depends_on_id":"iv-nkak","type":"blocks","created_at":"2026-02-15T12:47:16Z","created_by":"mk","metadata":"{}"}]},{"id":"iv-r9j2","title":"[clavain] A3: Event-driven advancement — phase transitions trigger auto-dispatch","priority":2,"dependencies":[{"issue_id":"iv-r9j2","depends_on_id":"iv-kj6w","type":"blocks","created_at":"2026-02-20T09:28:05Z","created_by":"mk","metadata":"{}"}]},{"id":"iv-rafa","title":"[interspect] Meta-learning loop","priority":2,"dependencies":[{"issue_id":"iv-rafa","depends_on_id":"iv-8jpf","type":"blocks","created_at":"2026-02-19T23:37:00Z","created_by":"mk","metadata":"{}"},{"issue_id":"iv-rafa","depends_on_id":"iv-cylo","type":"blocks","created_at":"2026-02-15T07:32:26Z","created_by":"mk","metadata":"{}"},{"issue_id":"iv-rafa","depends_on_id":"iv-jo3i","type":"blocks","created_at":"2026-02-15T01:35:06Z","created_by":"mk","metadata":"{}"}]},{"id":"iv-sdqv","title":"Plan interscribe extraction (knowledge compounding)","priority":2,"dependencies":[{"issue_id":"iv-sdqv","depends_on_id":"iv-qtcl","type":"relates-to","created_at":"2026-02-18T15:45:13Z","created_by":"mk","metadata":"{}"}]},{"id":"iv-t1m4","title":"[interspect] Prompt tuning (Type 3) overlay-based","priority":2,"dependencies":[{"issue_id":"iv-t1m4","depends_on_id":"iv-cylo","type":"blocks","created_at":"2026-02-15T01:35:06Z","created_by":"mk","metadata":"{}"},{"issue_id":"iv-t1m4","depends_on_id":"iv-izth","type":"blocks","created_at":"2026-02-15T01:35:06Z","created_by":"mk","metadata":"{}"}]},{"id":"iv-uomr","title":"F6: Embedding search (brute-force cosine)","priority":2,"dependencies":[{"issue_id":"iv-uomr","depends_on_id":"iv-06r4","type":"blocks","created_at":"2026-02-20T11:58:44Z","created_by":"mk","metadata":"{}"},{"issue_id":"iv-uomr","depends_on_id":"iv-fra3","type":"blocks","created_at":"2026-02-20T11:58:43Z","created_by":"mk","metadata":"{}"}]},{"id":"iv-v81k","title":"[interstat] Repository-aware benchmark expansion for agent coding tasks","priority":2,"dependencies":[{"issue_id":"iv-v81k","depends_on_id":"iv-qznx","type":"blocks","created_at":"2026-02-16T22:40:51Z","created_by":"mk","metadata":"{}"}]},{"id":"iv-wp62","title":"[intercore] Add portfolio-level dependency/scheduling primitives","priority":2,"dependencies":null},{"id":"iv-wz3j","title":"[interflux] Role-aware latent memory architecture experiments","priority":2,"dependencies":[{"issue_id":"iv-wz3j","depends_on_id":"iv-jc4j","type":"blocks","created_at":"2026-02-16T22:40:51Z","created_by":"mk","metadata":"{}"}]},{"id":"iv-xlpg","title":"[autarch] Pollard: optional-death hunter resilience","priority":2,"dependencies":null},{"id":"iv-xu31","title":"[autarch] Adopt 4-state status model with consistent icons","priority":2,"dependencies":null},{"id":"iv-xuec","title":"Security threat model for token optimization techniques","priority":2,"dependencies":[{"issue_id":"iv-xuec","depends_on_id":"iv-qtcl","type":"relates-to","created_at":"2026-02-18T15:45:13Z","created_by":"mk","metadata":"{}"}]},{"id":"iv-zawf","title":"F1: Discovery schema + migration (v8→v9)","priority":2,"dependencies":[{"issue_id":"iv-zawf","depends_on_id":"iv-fra3","type":"blocks","created_at":"2026-02-20T11:58:42Z","created_by":"mk","metadata":"{}"}]},{"id":"iv-zsio","title":"[clavain/interphase] Integrate full discovery pipeline into sprint workflow","priority":2,"dependencies":null},{"id":"iv-zyym","title":"Evaluate Claude Hub for event-driven GitHub agent dispatch","priority":2,"dependencies":null}]

END LLM:NEXT_GROUPINGS -->

### Later (P3)

- [interject] **iv-045** Show HN: Off Grid – Run AI text, image gen, vision offline on your phone
- [interverse] **iv-0681** Crash recovery + error aggregation for multi-agent sessions
- [interverse] **iv-0d3a** flux-gen UX: onboarding, integration, docs mentions
- [interject] **iv-0fl7** Exa MCP Integration with Codex | Composio
- [interverse] **iv-0plv** Backend cost arbitrage — multi-model routing in clodex
- [interject] **iv-0r8** Building Interactive Programs inside Claude Code - DEV Community
- [interject] **iv-13q** viktorxhzj/feishu-webhook-skill: A Claude Code skill for sending messages to Fei
- [interverse] **iv-1626** Version-bump → Interwatch signal
- [autarch] **iv-16sw** Pollard: parallel model race for confidence scoring
- [interverse] **iv-173y** Research: guardian agent patterns (formalize quality-gates)
- [interverse] **iv-19m** tldrs: slice command should optionally include source code
- [interverse] **iv-19oc** Research: prompt compression techniques (LLMLingua, gist tokens) for agent context
- [interject] **iv-1cn** Show HN: Skill that lets Claude Code/Codex spin up VMs and GPUs
- [intercore] **iv-1et1** Document current CLI surface for interspect/compat commands
- [interverse] **iv-1n6z** Monorepo build orchestrator (interbuild) with change detection
- [clavain] **iv-1vny** C4: Cross-phase handoff protocol — structured output-to-input contracts (blocked by iv-asfy)
- [interject] **iv-1x2n** Redacta: Elevating Video Content with GitHub Copilot CLI - DEV Community
- [autarch] **iv-1yck** Bigend: htop-style cost + tool columns per agent
- [interject] **iv-22w** Discover and install prebuilt plugins through marketplaces - Claude Code Docs
- [clavain] **iv-240m** C3: Composer — match agency specs to fleet registry within budget (blocked by iv-asfy, iv-lx00)

---

## Module Highlights

### clavain (hub/clavain)
Clavain is an autonomous software agency — 15 skills, 4 agents, 52 commands, 22 hooks, 1 MCP server. 31 companion plugins in the inter-* constellation. 1000 beads tracked, 660 closed, 339 open. Runs on its own TUI (Autarch), backed by Intercore kernel and Interspect profiler.

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
tldr-swinton is the token-efficiency context layer for AI code workflows. The product has:

### tuivision (plugins/tuivision)
Tuivision automates TUI and terminal UI testing through scriptable sessions and screenshot workflows.

<!-- LLM:MODULE_HIGHLIGHTS
Task: Write 2-3 sentence summaries for these modules.
Format: ### module (location)
vX.Y.Z. Summary text.

Modules needing highlights:
interkasten|plugins/interkasten

END LLM:MODULE_HIGHLIGHTS -->

---

## Research Agenda

<!-- LLM:RESEARCH_AGENDA
Task: Synthesize into 10-15 thematic research bullets.
Format: - **Topic** — 1-line summary

Brainstorm files:
2026-02-15-linsenkasten-flux-agents-brainstorm
2026-02-15-multi-session-phase4-merge-agent-brainstorm
2026-02-15-sprint-resilience-brainstorm
2026-02-15-token-efficient-skill-loading
2026-02-16-agent-rig-autonomous-sync-brainstorm
2026-02-16-flux-drive-document-slicing-brainstorm
2026-02-16-interbus-central-integration-mesh-brainstorm
2026-02-16-linsenkasten-phase1-agents-brainstorm
2026-02-16-sprint-resilience-phase2-brainstorm
2026-02-16-subagent-context-flooding-brainstorm
2026-02-16-token-budget-controls-brainstorm
2026-02-19-intercore-e3-hook-cutover-brainstorm
2026-02-19-reflect-phase-learning-loop-brainstorm
2026-02-20-autarch-status-tool-brainstorm
2026-02-20-cost-aware-agent-scheduling-brainstorm
2026-02-20-dual-mode-plugin-architecture-brainstorm
2026-02-20-intercore-e5-discovery-pipeline-brainstorm
2026-02-20-intercore-rollback-recovery-brainstorm
2026-02-20-sprint-handover-kernel-driven-brainstorm

Plan files:
2026-02-15-cross-module-integration-opportunities
2026-02-15-linsenkasten-flux-agents
2026-02-15-multi-session-coordination-brainstorm
2026-02-15-sprint-resilience-phase1
2026-02-15-token-efficient-skill-loading
2026-02-16-flux-drive-document-slicing
2026-02-16-linsenkasten-phase1-remaining-agents
2026-02-16-sprint-resilience-phase2
2026-02-16-subagent-context-flooding
2026-02-16-token-budget-controls
2026-02-17-framework-benchmark-freshness-automation
2026-02-17-heterogeneous-collaboration-routing
2026-02-17-interband-sideband-hardening
2026-02-17-multi-framework-interoperability-benchmark
2026-02-17-repository-aware-benchmark-expansion
2026-02-17-role-aware-latent-memory-experiments
2026-02-19-bias-aware-product-decision-framework
2026-02-19-blueprint-distillation-sprint-intake
2026-02-19-catalog-reminder-interwatch-escalation
2026-02-19-clavain-roadmap-vision-alignment
2026-02-19-hierarchical-dispatch-meta-agent
2026-02-19-intercore-e3-hook-cutover
2026-02-19-intercore-spawn-handler-wiring
2026-02-19-interscribe-extraction-plan
2026-02-19-session-start-drift-summary-injection
2026-02-19-shift-work-boundary-formalization
2026-02-19-tldrs-import-graph-compression-dedup
2026-02-19-tldrs-longcodezip-block-compression
2026-02-19-tldrs-precomputed-context-bundles
2026-02-19-tldrs-structured-output-serialization
2026-02-19-tldrs-symbol-popularity-index
2026-02-20-autarch-status-tool
2026-02-20-cost-aware-agent-scheduling
2026-02-20-intercore-e5-discovery-pipeline
2026-02-20-intercore-rollback-recovery
2026-02-20-reflect-phase-sprint-integration
2026-02-20-sprint-handover-kernel-driven
2026-02-20-tui-kernel-validation

END LLM:RESEARCH_AGENDA -->

---

## Cross-Module Dependencies

Major dependency chains spanning multiple modules:

- **iv-wz3j** (interflux) blocked by **iv-jc4j** (intermute)
- **iv-6abk** (autarch) blocked by **iv-ishl** (intercore)
- **iv-t4v6** (autarch) blocked by **iv-ishl** (intercore)
- **iv-8y3w** (autarch) blocked by **iv-ishl** (intercore)
- **iv-3r6q** (interflux) blocked by **iv-r6mf** (interspect)
- **iv-5pvo** (intercore) blocked by **iv-ev4o** (interverse)

---

## Modules Without Roadmaps

- `hub/autarch`
- `plugins/interleave`
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
