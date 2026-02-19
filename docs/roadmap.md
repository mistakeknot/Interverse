# Interverse Roadmap

**Modules:** 33 | **Open beads (root tracker):** 358 | **Blocked (root tracker):** 34 | **Last updated:** 2026-02-18
**Structure:** [`CLAUDE.md`](../CLAUDE.md)
**Machine output:** [`docs/roadmap.json`](roadmap.json)

---

## Ecosystem Snapshot

| Module | Location | Version | Status | Roadmap | Open Beads (context) |
|--------|----------|---------|--------|---------|----------------------|
| clavain | hub/clavain | 0.6.35 | active | yes | 13 |
| intercheck | plugins/intercheck | 0.1.2 | active | yes | 4 |
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
- [interverse] **iv-psf2.1.4** Interbus Wave 1d: interlock adapter (blocks iv-psf2.1)
- [interverse] **iv-psf2.1.3** Interbus Wave 1c: interdoc adapter (blocks iv-psf2.1)
- [interverse] **iv-psf2.1.2** Interbus Wave 1b: interflux adapter (blocks iv-psf2.1)
- [interverse] **iv-psf2.1.1** Interbus Wave 1a: interphase adapter (blocks iv-psf2.1)
- [interverse] **iv-psf2.1** Interbus Wave 1: Core workflow modules (blocks iv-psf2)
- [interverse] **iv-0681** Crash recovery + error aggregation for multi-agent sessions
- [interspect] **iv-ukct** /interspect:revert command (blocked by iv-jo3i, iv-cylo)
- [interspect] **iv-vrc4** Overlay system (Type 1) (blocked by iv-nkak)

**Recently completed:** iv-wo1t (Hook adapter — thin bridge from Claude Code hooks to intercore DB), iv-a20e (Phase state machine — own the brainstorm-to-ship lifecycle), iv-e5oa (Dispatch — spawn and track Claude Code + Codex agents), iv-dyyy (interstat plugin scaffold + SQLite schema), iv-n4p7 (intermem Phase 1: Validation overlay — citation-checking + metadata DB), iv-rkrm (intermem Phase 2: Decay + progressive disclosure), iv-zl98 (intermem Dogfood Phase 1+2A on real projects), iv-wb8o (intermem F2: Auto-archive + restore stale promoted entries), iv-z9rd (intermem F1: Time-based confidence decay), iv-fzo6 (intermem F5: CLI query interface), iv-ieh7 (Phase 1: State database — replace temp files with SQLite), iv-byh3 (Define platform kernel + lifecycle UX architecture), iv-hoqj (Interband: sideband protocol library for cross-plugin file contracts), iv-8m38 (Token budget controls + cost-aware agent dispatch), iv-d72t (Phase 4a: Reservation Negotiation Protocol), iv-jq5b (Token efficiency benchmarking framework), iv-jo3i (Canary verdict engine)

### Next (P2)

<!-- LLM:NEXT_GROUPINGS
Task: Group these P2 items under 5-10 thematic headings.
Format: **Bold Heading** followed by bullet items.
Heuristic: items sharing a [module] tag or dependency chain likely belong together.

Raw P2 items JSON:
[{"id":"iv-x4dk","title":"F6: Mutex consolidation (intercore)","priority":2,"dependencies":[{"issue_id":"iv-x4dk","depends_on_id":"iv-ieh7","type":"blocks","created_at":"2026-02-17T16:07:35.901027871-08:00","created_by":"mk"}]},{"id":"iv-qt5m","title":"F4: Run tracking (intercore)","priority":2,"dependencies":[{"issue_id":"iv-qt5m","depends_on_id":"iv-ieh7","type":"blocks","created_at":"2026-02-17T16:07:35.671966208-08:00","created_by":"mk"},{"issue_id":"iv-qt5m","depends_on_id":"iv-fnfa","type":"blocks","created_at":"2026-02-17T16:07:38.431673515-08:00","created_by":"mk"}]},{"id":"iv-gbgj","title":"[intermem] Bug: argparse parents=[shared] causes --project-dir before subcommand to be overwritten by default","priority":2,"dependencies":null},{"id":"iv-f7po","title":"[intermem] F3: Multi-file tiered promotion — AGENTS.md index + docs/intermem/ detail","priority":2,"dependencies":[{"issue_id":"iv-f7po","depends_on_id":"iv-rkrm","type":"blocks","created_at":"2026-02-18T00:00:00-08:00","created_by":"mk"}]},{"id":"iv-bn4j","title":"[intermem] F4: One-shot tiered migration — --migrate-to-tiered","priority":2,"dependencies":[{"issue_id":"iv-bn4j","depends_on_id":"iv-f7po","type":"blocks","created_at":"2026-02-18T00:00:00-08:00","created_by":"mk"}]},{"id":"iv-qfg8","title":"[intercore] Phase 2: Event bus, policy engine, interhub control room","priority":2,"dependencies":[{"issue_id":"iv-qfg8","depends_on_id":"iv-ieh7","type":"blocks","created_at":"2026-02-17T15:32:42.146985938-08:00","created_by":"mk"},{"issue_id":"iv-qfg8","depends_on_id":"iv-e5oa","type":"blocks","created_at":"2026-02-17T15:32:42.30210246-08:00","created_by":"mk"},{"issue_id":"iv-qfg8","depends_on_id":"iv-a20e","type":"blocks","created_at":"2026-02-17T15:32:42.427323353-08:00","created_by":"mk"},{"issue_id":"iv-qfg8","depends_on_id":"iv-wo1t","type":"blocks","created_at":"2026-02-17T15:32:42.554843183-08:00","created_by":"mk"}]},{"id":"iv-v81k","title":"[interstat] Repository-aware benchmark expansion for agent coding tasks","priority":2,"dependencies":[{"issue_id":"iv-v81k","depends_on_id":"iv-qznx","type":"blocks","created_at":"2026-02-16T22:40:50.614450493-08:00","created_by":"mk"}]},{"id":"iv-wz3j","title":"[interflux] Role-aware latent memory architecture experiments","priority":2,"dependencies":[{"issue_id":"iv-wz3j","depends_on_id":"iv-jc4j","type":"blocks","created_at":"2026-02-16T22:40:50.706725239-08:00","created_by":"mk"}]},{"id":"iv-jc4j","title":"[intermute] Heterogeneous agent routing experiments inspired by SC-MAS/Dr. MAS","priority":2,"dependencies":[{"issue_id":"iv-jc4j","depends_on_id":"iv-qznx","type":"blocks","created_at":"2026-02-16T22:40:50.650148113-08:00","created_by":"mk"}]},{"id":"iv-qznx","title":"[interflux] Multi-framework interoperability benchmark and scoring harness","priority":2,"dependencies":null},{"id":"iv-aose","title":"Intermap — Project-level code mapping extraction from tldr-swinton","priority":2,"dependencies":null},{"id":"iv-psf2.3.3","title":"Interbus Wave 3c: intersearch adapter","priority":2,"dependencies":[{"issue_id":"iv-psf2.3.3","depends_on_id":"iv-psf2.3","type":"parent-child","created_at":"2026-02-16T10:08:17.720805538-08:00","created_by":"mk"}]},{"id":"iv-psf2.3.2","title":"Interbus Wave 3b: tldr-swinton adapter","priority":2,"dependencies":[{"issue_id":"iv-psf2.3.2","depends_on_id":"iv-psf2.3","type":"parent-child","created_at":"2026-02-16T10:08:17.597742013-08:00","created_by":"mk"}]},{"id":"iv-psf2.3.1","title":"Interbus Wave 3a: tool-time adapter","priority":2,"dependencies":[{"issue_id":"iv-psf2.3.1","depends_on_id":"iv-psf2.3","type":"parent-child","created_at":"2026-02-16T10:08:17.482811263-08:00","created_by":"mk"}]},{"id":"iv-psf2.2.8","title":"Interbus Wave 2h: interform adapter","priority":2,"dependencies":[{"issue_id":"iv-psf2.2.8","depends_on_id":"iv-psf2.2","type":"parent-child","created_at":"2026-02-16T10:08:17.360535951-08:00","created_by":"mk"}]},{"id":"iv-psf2.2.7","title":"Interbus Wave 2g: intercraft adapter","priority":2,"dependencies":[{"issue_id":"iv-psf2.2.7","depends_on_id":"iv-psf2.2","type":"parent-child","created_at":"2026-02-16T10:08:17.23265178-08:00","created_by":"mk"}]},{"id":"iv-psf2.2.6","title":"Interbus Wave 2f: internext adapter","priority":2,"dependencies":[{"issue_id":"iv-psf2.2.6","depends_on_id":"iv-psf2.2","type":"parent-child","created_at":"2026-02-16T10:08:17.121981635-08:00","created_by":"mk"}]},{"id":"iv-psf2.2.5","title":"Interbus Wave 2e: interslack adapter","priority":2,"dependencies":[{"issue_id":"iv-psf2.2.5","depends_on_id":"iv-psf2.2","type":"parent-child","created_at":"2026-02-16T10:08:16.996352244-08:00","created_by":"mk"}]},{"id":"iv-psf2.2.4","title":"Interbus Wave 2d: interpub adapter","priority":2,"dependencies":[{"issue_id":"iv-psf2.2.4","depends_on_id":"iv-psf2.2","type":"parent-child","created_at":"2026-02-16T10:08:16.871338992-08:00","created_by":"mk"}]},{"id":"iv-psf2.2.3","title":"Interbus Wave 2c: interwatch adapter","priority":2,"dependencies":[{"issue_id":"iv-psf2.2.3","depends_on_id":"iv-psf2.2","type":"parent-child","created_at":"2026-02-16T10:08:16.742024291-08:00","created_by":"mk"}]},{"id":"iv-psf2.2.2","title":"Interbus Wave 2b: interline adapter","priority":2,"dependencies":[{"issue_id":"iv-psf2.2.2","depends_on_id":"iv-psf2.2","type":"parent-child","created_at":"2026-02-16T10:08:16.607934018-08:00","created_by":"mk"}]},{"id":"iv-psf2.2.1","title":"Interbus Wave 2a: intercheck adapter","priority":2,"dependencies":[{"issue_id":"iv-psf2.2.1","depends_on_id":"iv-psf2.2","type":"parent-child","created_at":"2026-02-16T10:08:16.495316339-08:00","created_by":"mk"}]},{"id":"iv-psf2.3","title":"Interbus Wave 3: Supporting utility modules","priority":2,"dependencies":[{"issue_id":"iv-psf2.3","depends_on_id":"iv-psf2","type":"parent-child","created_at":"2026-02-16T10:07:31.164306416-08:00","created_by":"mk"},{"issue_id":"iv-psf2.3","depends_on_id":"iv-psf2.2","type":"blocks","created_at":"2026-02-16T10:07:35.623699224-08:00","created_by":"mk"}]},{"id":"iv-psf2.2","title":"Interbus Wave 2: Visibility and safety modules","priority":2,"dependencies":[{"issue_id":"iv-psf2.2","depends_on_id":"iv-psf2","type":"parent-child","created_at":"2026-02-16T10:07:31.054823849-08:00","created_by":"mk"},{"issue_id":"iv-psf2.2","depends_on_id":"iv-psf2.1","type":"blocks","created_at":"2026-02-16T10:07:35.511473107-08:00","created_by":"mk"}]},{"id":"iv-psf2","title":"Interbus rollout: phase-based module integration","priority":2,"dependencies":null},{"id":"iv-ey90","title":"[interkasten] Webhook receiver + cloudflared tunnel","priority":2,"dependencies":null},{"id":"iv-zyym","title":"Evaluate Claude Hub for event-driven GitHub agent dispatch","priority":2,"dependencies":null},{"id":"iv-wrae","title":"Evaluate Container Use (Dagger) for sandboxed agent dispatch","priority":2,"dependencies":null},{"id":"iv-bazo","title":"F4: interstat status (collection progress)","priority":2,"dependencies":[{"issue_id":"iv-bazo","depends_on_id":"iv-jq5b","type":"blocks","created_at":"2026-02-15T19:39:15.196325153-08:00","created_by":"mk"},{"issue_id":"iv-bazo","depends_on_id":"iv-dyyy","type":"blocks","created_at":"2026-02-15T19:39:17.824863619-08:00","created_by":"mk"},{"issue_id":"iv-bazo","depends_on_id":"iv-lgfi","type":"blocks","created_at":"2026-02-15T19:39:20.282932792-08:00","created_by":"mk"}]},{"id":"iv-dkg8","title":"F3: interstat report (analysis queries + decision gate)","priority":2,"dependencies":[{"issue_id":"iv-dkg8","depends_on_id":"iv-jq5b","type":"blocks","created_at":"2026-02-15T19:39:14.773779761-08:00","created_by":"mk"},{"issue_id":"iv-dkg8","depends_on_id":"iv-dyyy","type":"blocks","created_at":"2026-02-15T19:39:17.435402212-08:00","created_by":"mk"},{"issue_id":"iv-dkg8","depends_on_id":"iv-lgfi","type":"blocks","created_at":"2026-02-15T19:39:19.767436631-08:00","created_by":"mk"}]},{"id":"iv-lgfi","title":"F2: Conversation JSONL parser (token backfill)","priority":2,"dependencies":[{"issue_id":"iv-lgfi","depends_on_id":"iv-jq5b","type":"blocks","created_at":"2026-02-15T19:39:14.367487176-08:00","created_by":"mk"},{"issue_id":"iv-lgfi","depends_on_id":"iv-dyyy","type":"blocks","created_at":"2026-02-15T19:39:16.970853651-08:00","created_by":"mk"}]},{"id":"iv-qi8j","title":"F1: PostToolUse:Task hook (real-time event capture)","priority":2,"dependencies":[{"issue_id":"iv-qi8j","depends_on_id":"iv-jq5b","type":"blocks","created_at":"2026-02-15T19:39:13.965223377-08:00","created_by":"mk"},{"issue_id":"iv-qi8j","depends_on_id":"iv-dyyy","type":"blocks","created_at":"2026-02-15T19:39:16.54486781-08:00","created_by":"mk"}]},{"id":"iv-xuec","title":"Security threat model for token optimization techniques","priority":2,"dependencies":null},{"id":"iv-dthn","title":"Research: inter-layer feedback loops and optimization thresholds","priority":2,"dependencies":null},{"id":"iv-qjwz","title":"AgentDropout: dynamic redundancy elimination for flux-drive reviews","priority":2,"dependencies":[{"issue_id":"iv-qjwz","depends_on_id":"iv-ynbh","type":"blocks","created_at":"2026-02-15T17:31:22.750671314-08:00","created_by":"mk"},{"issue_id":"iv-qjwz","depends_on_id":"iv-8m38","type":"blocks","created_at":"2026-02-15T17:42:31.207392784-08:00","created_by":"mk"}]},{"id":"iv-quk4","title":"Hierarchical dispatch: meta-agent for N-agent fan-out","priority":2,"dependencies":null},{"id":"iv-6liz","title":"[interspect] F5: manual routing override support","priority":2,"dependencies":[{"issue_id":"iv-6liz","depends_on_id":"iv-nkak","type":"blocks","created_at":"2026-02-15T12:47:16.525544459-08:00","created_by":"mk"},{"issue_id":"iv-6liz","depends_on_id":"iv-r6mf","type":"blocks","created_at":"2026-02-15T12:47:17.811690882-08:00","created_by":"mk"}]},{"id":"iv-2o6c","title":"[interspect] F4: status display + revert for routing overrides","priority":2,"dependencies":[{"issue_id":"iv-2o6c","depends_on_id":"iv-nkak","type":"blocks","created_at":"2026-02-15T12:47:16.463978896-08:00","created_by":"mk"},{"issue_id":"iv-2o6c","depends_on_id":"iv-gkj9","type":"blocks","created_at":"2026-02-15T12:47:17.740451063-08:00","created_by":"mk"}]},{"id":"iv-gkj9","title":"[interspect] F3: apply override + canary + git commit","priority":2,"dependencies":[{"issue_id":"iv-gkj9","depends_on_id":"iv-nkak","type":"blocks","created_at":"2026-02-15T12:47:16.405657788-08:00","created_by":"mk"},{"issue_id":"iv-gkj9","depends_on_id":"iv-8fgu","type":"blocks","created_at":"2026-02-15T12:47:17.672524298-08:00","created_by":"mk"}]},{"id":"iv-8fgu","title":"[interspect] F2: routing-eligible pattern detection + propose flow","priority":2,"dependencies":[{"issue_id":"iv-8fgu","depends_on_id":"iv-nkak","type":"blocks","created_at":"2026-02-15T12:47:16.331103751-08:00","created_by":"mk"},{"issue_id":"iv-8fgu","depends_on_id":"iv-r6mf","type":"blocks","created_at":"2026-02-15T12:47:17.607000944-08:00","created_by":"mk"}]},{"id":"iv-r6mf","title":"[interspect] F1: routing-overrides.json schema + flux-drive reader","priority":2,"dependencies":[{"issue_id":"iv-r6mf","depends_on_id":"iv-nkak","type":"blocks","created_at":"2026-02-15T12:47:16.272330902-08:00","created_by":"mk"}]},{"id":"iv-p4qq","title":"Smart semantic caching across sessions (intercache)","priority":2,"dependencies":null},{"id":"iv-friz","title":"CI/CD integration bridge: GitHub Actions templates for interflux + interwatch","priority":2,"dependencies":null},{"id":"iv-905u","title":"Intermediate result sharing between parallel flux-drive agents","priority":2,"dependencies":null},{"id":"iv-ev4o","title":"Agent capability discovery via intermute registration","priority":2,"dependencies":null},{"id":"iv-umvq","title":"Health aggregation service (interstatus) for 22-module ecosystem","priority":2,"dependencies":null},{"id":"iv-lwsf","title":"Shared HTTP client library (interhttp) for Go + bash","priority":2,"dependencies":null},{"id":"iv-tkc6","title":"Shared bash hook library (interlace) for clavain/interphase/interlock","priority":2,"dependencies":null},{"id":"iv-jmua","title":"Shared SQLite library (intersqlite) for 6 modules","priority":2,"dependencies":null},{"id":"iv-z1a0","title":"Cross-module integration opportunity program","priority":2,"dependencies":null},{"id":"iv-z1a1","title":"Inter-module event bus + event contracts","priority":2,"dependencies":[{"issue_id":"iv-z1a1","depends_on_id":"iv-z1a0","type":"parent-child","created_at":"2026-02-15T10:54:00-08:00","created_by":"mk"}]},{"id":"iv-z1a2","title":"Interline as unified operations HUD","priority":2,"dependencies":[{"issue_id":"iv-z1a2","depends_on_id":"iv-z1a0","type":"parent-child","created_at":"2026-02-15T10:54:00-08:00","created_by":"mk"}]},{"id":"iv-z1a4","title":"Interkasten context into discovery and sprint intake","priority":2,"dependencies":[{"issue_id":"iv-z1a4","depends_on_id":"iv-z1a0","type":"parent-child","created_at":"2026-02-15T10:54:00-08:00","created_by":"mk"}]},{"id":"iv-z1a5","title":"Cross-module quality feedback loop","priority":2,"dependencies":[{"issue_id":"iv-z1a5","depends_on_id":"iv-z1a0","type":"parent-child","created_at":"2026-02-15T10:54:00-08:00","created_by":"mk"}]},{"id":"iv-2jtj","title":"F5: Escalation Timeout for Unresponsive Agents","priority":2,"dependencies":[{"issue_id":"iv-2jtj","depends_on_id":"iv-d72t","type":"blocks","created_at":"2026-02-15T09:11:40.035790764-08:00","created_by":"mk"},{"issue_id":"iv-2jtj","depends_on_id":"iv-5ijt","type":"blocks","created_at":"2026-02-15T09:11:41.150275167-08:00","created_by":"mk"}]},{"id":"iv-6u3s","title":"F4: Sprint Scan Release Visibility","priority":2,"dependencies":[{"issue_id":"iv-6u3s","depends_on_id":"iv-d72t","type":"blocks","created_at":"2026-02-15T09:11:39.965602878-08:00","created_by":"mk"},{"issue_id":"iv-6u3s","depends_on_id":"iv-1aug","type":"blocks","created_at":"2026-02-15T09:11:41.082328262-08:00","created_by":"mk"}]},{"id":"iv-5ijt","title":"F3: Structured negotiate_release MCP Tool","priority":2,"dependencies":[{"issue_id":"iv-5ijt","depends_on_id":"iv-d72t","type":"blocks","created_at":"2026-02-15T09:11:39.905217445-08:00","created_by":"mk"},{"issue_id":"iv-5ijt","depends_on_id":"iv-1aug","type":"blocks","created_at":"2026-02-15T09:11:41.004823463-08:00","created_by":"mk"}]},{"id":"iv-gg8v","title":"F2: Auto-Release on Clean Files","priority":2,"dependencies":[{"issue_id":"iv-gg8v","depends_on_id":"iv-d72t","type":"blocks","created_at":"2026-02-15T09:11:39.848050964-08:00","created_by":"mk"},{"issue_id":"iv-gg8v","depends_on_id":"iv-1aug","type":"blocks","created_at":"2026-02-15T09:11:40.931955029-08:00","created_by":"mk"}]},{"id":"iv-1aug","title":"F1: Release Response Protocol (release_ack / release_defer)","priority":2,"dependencies":[{"issue_id":"iv-1aug","depends_on_id":"iv-d72t","type":"blocks","created_at":"2026-02-15T09:11:39.78903761-08:00","created_by":"mk"}]},{"id":"iv-f9c2","title":"[tldrs] Slice with source code option","priority":2,"dependencies":null},{"id":"iv-3w4t","title":"[tldrs] Ultracompact --depth=body variant","priority":2,"dependencies":null},{"id":"iv-2izz","title":"[tldrs] LongCodeZip block-level compression","priority":2,"dependencies":null},{"id":"iv-drgo","title":"[interspect] Privilege separation (proposer/applier)","priority":2,"dependencies":[{"issue_id":"iv-drgo","depends_on_id":"iv-nkak","type":"blocks","created_at":"2026-02-15T07:31:16.619273028-08:00","created_by":"mk"}]},{"id":"iv-435u","title":"[interspect] Counterfactual shadow evaluation","priority":2,"dependencies":[{"issue_id":"iv-435u","depends_on_id":"iv-nkak","type":"blocks","created_at":"2026-02-15T07:31:16.556756037-08:00","created_by":"mk"}]},{"id":"iv-003t","title":"[interspect] Global modification rate limiter","priority":2,"dependencies":[{"issue_id":"iv-003t","depends_on_id":"iv-nkak","type":"blocks","created_at":"2026-02-15T01:35:00.697518213-08:00","created_by":"mk"}]},{"id":"iv-sisi","title":"[interspect] Interline statusline integration","priority":2,"dependencies":[{"issue_id":"iv-sisi","depends_on_id":"iv-cylo","type":"blocks","created_at":"2026-02-15T01:35:00.87453214-08:00","created_by":"mk"}]},{"id":"iv-88yg","title":"[interspect] Structured commit message format","priority":2,"dependencies":[{"issue_id":"iv-88yg","depends_on_id":"iv-nkak","type":"blocks","created_at":"2026-02-15T01:35:00.642706311-08:00","created_by":"mk"}]},{"id":"iv-c2b4","title":"[interspect] /interspect:disable command","priority":2,"dependencies":[{"issue_id":"iv-c2b4","depends_on_id":"iv-o4x7","type":"blocks","created_at":"2026-02-15T01:35:06.051462602-08:00","created_by":"mk"}]},{"id":"iv-g0to","title":"[interspect] /interspect:reset command","priority":2,"dependencies":[{"issue_id":"iv-g0to","depends_on_id":"iv-ukct","type":"blocks","created_at":"2026-02-15T01:35:05.976166181-08:00","created_by":"mk"}]},{"id":"iv-bj0w","title":"[interspect] Conflict detection","priority":2,"dependencies":[{"issue_id":"iv-bj0w","depends_on_id":"iv-rafa","type":"blocks","created_at":"2026-02-15T01:35:05.902998086-08:00","created_by":"mk"}]},{"id":"iv-0fi2","title":"[interspect] Circuit breaker","priority":2,"dependencies":[{"issue_id":"iv-0fi2","depends_on_id":"iv-ukct","type":"blocks","created_at":"2026-02-15T01:35:05.830365862-08:00","created_by":"mk"}]},{"id":"iv-rafa","title":"[interspect] Meta-learning loop","priority":2,"dependencies":[{"issue_id":"iv-rafa","depends_on_id":"iv-jo3i","type":"blocks","created_at":"2026-02-15T01:35:05.750805411-08:00","created_by":"mk"},{"issue_id":"iv-rafa","depends_on_id":"iv-cylo","type":"blocks","created_at":"2026-02-15T07:32:25.569536849-08:00","created_by":"mk"}]},{"id":"iv-t1m4","title":"[interspect] Prompt tuning (Type 3) overlay-based","priority":2,"dependencies":[{"issue_id":"iv-t1m4","depends_on_id":"iv-izth","type":"blocks","created_at":"2026-02-15T01:35:05.639373223-08:00","created_by":"mk"},{"issue_id":"iv-t1m4","depends_on_id":"iv-cylo","type":"blocks","created_at":"2026-02-15T01:35:05.693278638-08:00","created_by":"mk"}]},{"id":"iv-izth","title":"[interspect] Eval corpus construction","priority":2,"dependencies":[{"issue_id":"iv-izth","depends_on_id":"iv-nkak","type":"blocks","created_at":"2026-02-15T01:35:05.584579926-08:00","created_by":"mk"}]},{"id":"iv-5su3","title":"[interspect] Autonomous mode flag","priority":2,"dependencies":[{"issue_id":"iv-5su3","depends_on_id":"iv-jo3i","type":"blocks","created_at":"2026-02-15T01:35:05.429857878-08:00","created_by":"mk"},{"issue_id":"iv-5su3","depends_on_id":"iv-cylo","type":"blocks","created_at":"2026-02-15T07:32:25.493376922-08:00","created_by":"mk"}]},{"id":"iv-m6cd","title":"[interspect] Session-start summary injection","priority":2,"dependencies":[{"issue_id":"iv-m6cd","depends_on_id":"iv-o4x7","type":"blocks","created_at":"2026-02-15T01:34:57.08577254-08:00","created_by":"mk"}]},{"id":"iv-rrc2","title":"F3: Demo hooks for interwatch (reuse examples)","priority":2,"dependencies":[{"issue_id":"iv-rrc2","depends_on_id":"iv-pjfp","type":"blocks","created_at":"2026-02-14T14:24:57.556296497-08:00","created_by":"mk"}]},{"id":"iv-1626","title":"Version-bump → Interwatch signal","priority":2,"dependencies":null},{"id":"iv-444d","title":"Catalog-reminder → Interwatch escalation","priority":2,"dependencies":null},{"id":"iv-mqm4","title":"Session-start drift summary injection","priority":2,"dependencies":null},{"id":"iv-l5ap","title":"Research: transactional orchestration & error recovery patterns","priority":2,"dependencies":null},{"id":"iv-jk7q","title":"Research: cognitive load budgets & progressive disclosure review UX","priority":2,"dependencies":null},{"id":"iv-3kee","title":"Research: product-native agent orchestration (whitespace opportunity)","priority":2,"dependencies":null},{"id":"iv-exos","title":"Research: bias-aware product decision framework","priority":2,"dependencies":null},{"id":"iv-fzrn","title":"Research: multi-agent hallucination cascades & failure taxonomy","priority":2,"dependencies":null},{"id":"iv-spad","title":"Deep tldrs integration into Clavain workflows","priority":2,"dependencies":[{"issue_id":"iv-spad","depends_on_id":"iv-mb6u","type":"blocks","created_at":"2026-02-14T09:08:10.98422582-08:00","created_by":"mk"}]},{"id":"iv-sdqv","title":"Plan interscribe extraction (knowledge compounding)","priority":2,"dependencies":null},{"id":"iv-6ikc","title":"Plan intershift extraction (cross-AI dispatch engine)","priority":2,"dependencies":null},{"id":"iv-2ley","title":"Plan intercraft extraction (Claude Code meta-tooling)","priority":2,"dependencies":null},{"id":"iv-e8dg","title":"[flux-drive-spec] Phase 4: Migrate Clavain to consume the library","priority":2,"dependencies":[{"issue_id":"iv-e8dg","depends_on_id":"iv-0etu","type":"blocks","created_at":"2026-02-13T22:47:12.564498248-08:00","created_by":"mk"}]},{"id":"iv-0etu","title":"[flux-drive-spec] Phase 3: Extract scoring/synthesis Python library","priority":2,"dependencies":[{"issue_id":"iv-0etu","depends_on_id":"iv-ia66","type":"blocks","created_at":"2026-02-13T22:47:12.499013209-08:00","created_by":"mk"}]},{"id":"iv-ia66","title":"[flux-drive-spec] Phase 2: Extract domain detection library","priority":2,"dependencies":null},{"id":"iv-3w1x","title":"Split upstreams.json into config + state files","priority":2,"dependencies":null},{"id":"iv-4728","title":"Consolidate upstream-check.sh API calls (24 to 12)","priority":2,"dependencies":null},{"id":"iv-0lt","title":"Extract cache_hints metrics in score_tokens.py","priority":2,"dependencies":null},{"id":"iv-1gb","title":"Add cache-friendly format queries to regression_suite.json","priority":2,"dependencies":null},{"id":"iv-ca5","title":"tldrs: truncation should respect symbol boundaries","priority":2,"dependencies":null},{"id":"iv-dsk","title":"tldrs: ultracompact needs --depth=body variant","priority":2,"dependencies":null}]

END LLM:NEXT_GROUPINGS -->

### Later (P3)

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
- [interject] **iv-pjxj** Top 10 Low‑Code AI Workflow Automation Tools (2026)
- [interject] **iv-vvpj** Make | AI Workflow Automation Software & Tools | Make
- [interject] **iv-eweo** Trigger.dev | Build and deploy fully-managed AI agents and ...
- [interject] **iv-ki35** CORE: Resolving Code Quality Issues using LLMs - Microsoft
- [interject] **iv-btx0** Here is my experience with LLM tools for programming: | Vedran B.
- [interject] **iv-ak1v** Agent Orchestration: When to Use LangChain, LangGraph, AutoGen

---

## Module Highlights

### clavain (hub/clavain)
Clavain is a recursively self-improving multi-agent rig for Claude Code — 23 skills, 4 agents, 41 commands, 19 hooks, 1 MCP server. 19 companion plugins shipped. 364 beads closed, 0 open. Average lead time: 8.8 hours.

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

END LLM:RESEARCH_AGENDA -->

---

## Cross-Module Dependencies

Major dependency chains spanning multiple modules:

- **iv-jc4j** (intermute) blocked by **iv-qznx** (interflux)
- **iv-v81k** (interstat) blocked by **iv-qznx** (interflux)
- **iv-wz3j** (interflux) blocked by **iv-jc4j** (intermute)
- **iv-ynbh** (interverse) blocked by **iv-vrc4** (interspect)

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
