# Clavain vs Interverse Modules: Boundary Analysis

## Problem Statement

Clavain has grown to 37 commands, 27 skills, 5 agents, and 8 hooks. Meanwhile, 13 companion plugins provide 22 skills, 13 agents, 21 commands, 7+ MCP servers, and 15 hooks. The boundary between "what belongs in Clavain" and "what belongs in a companion module" has become unclear.

Key symptoms:
- Clavain directly `source`s interphase libraries (`lib-gates.sh`, `lib-discovery.sh`, `lib-phase.sh`)
- Clavain commands reference companion functionality by name (e.g., sprint calls interflux's flux-drive)
- Some Clavain skills overlap with companion plugin domains (e.g., `interpeer` skill in Clavain orchestrates Oracle/Codex which are external tools)
- Alias commands bloat Clavain's surface area (lfg, full-pipeline, cross-review, deep-review all alias other commands)

## Current State Inventory

### Clavain (hub) — 37 commands, 27 skills, 5 agents

**Commands by category:**

| Category | Commands | Count |
|----------|----------|-------|
| **Workflow orchestration** | sprint, lfg (alias), full-pipeline (alias), work, execute-plan, write-plan | 6 |
| **Brainstorm/strategy** | brainstorm, strategy | 2 |
| **Review/quality** | review, review-doc, quality-gates, plan-review, deep-review (alias) | 5 |
| **Cross-AI** | interpeer, cross-review (alias), debate | 3 |
| **Debugging/fixing** | repro-first-debugging, fixbuild, resolve, triage | 4 |
| **Shipping** | changelog, smoke-test | 2 |
| **Meta/setup** | setup, init, doctor, help, heal-skill, generate-command, create-agent-skill | 7 |
| **Mode toggles** | interserve-toggle, model-routing | 2 |
| **Ops** | sprint-status, upstream-sync, triage-prs, migration-safety, agent-native-audit, compound | 6 |

**Skills by category:**

| Category | Skills | Count |
|----------|--------|-------|
| **Core engineering** | test-driven-development, systematic-debugging, verification-before-completion, code-review-discipline, refactor-safely, landing-a-change | 6 |
| **Planning/execution** | writing-plans, executing-plans, dispatching-parallel-agents, subagent-driven-development | 4 |
| **Claude Code dev** | developing-claude-code-plugins, working-with-claude-code, create-agent-skills, writing-skills | 4 |
| **Cross-AI** | interpeer, interserve | 2 |
| **Domain-specific** | agent-native-architecture, distinctive-design, mcp-cli, slack-messaging, finding-duplicate-functions | 5 |
| **Workflow** | brainstorming, engineering-docs, file-todos, upstream-sync | 4 |
| **Meta** | using-clavain, using-tmux-for-interactive-commands | 2 |

**Agents (5):**
- agent-native-reviewer, data-migration-expert, plan-reviewer, bug-reproduction-validator, pr-comment-resolver

### Companion Plugins (13)

| Plugin | Purpose | Relationship to Clavain |
|--------|---------|------------------------|
| **interflux** | Multi-agent review engine (12 agents) | Clavain's quality-gates/review commands dispatch interflux agents |
| **interphase** | Phase tracking + gates + discovery | Clavain sources its shell libraries directly |
| **interline** | Statusline renderer | Reads state written by interphase/Clavain |
| **interpath** | Product artifact generator | Clavain's strategy command produces PRDs that interpath would also produce |
| **interwatch** | Doc freshness monitoring | Independent, delegates to interdoc/interpath |
| **interdoc** | AGENTS.md generator | Independent, invoked on-demand |
| **interfluence** | Voice profile + style | Independent, MCP-based |
| **interkasten** | Notion sync | Independent, MCP-based |
| **interlock** | Multi-agent coordination | Independent, MCP-based, wraps intermute |
| **interpub** | Plugin publishing | Independent, invoked on-demand |
| **tldr-swinton** | Token-efficient code context | Independent, MCP-based |
| **tool-time** | Usage analytics | Independent, observational |
| **tuivision** | TUI automation | Independent, MCP-based |

## Boundary Violations Identified

### 1. Clavain sources interphase internals

Clavain's `sprint.md`, `quality-gates.md`, and other commands directly `source` interphase's shell libraries:
```bash
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib-gates.sh" && advance_phase ...
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib-discovery.sh" && discovery_scan_beads
```

This works because Clavain ships shim files (`hooks/lib-gates.sh`, `hooks/lib-discovery.sh`) that delegate to interphase's actual libraries. But it means:
- Clavain's commands hardcode interphase's internal API
- If interphase changes its library interface, Clavain's shims must update
- The shim pattern adds indirection without decoupling

**Assessment:** This coupling is intentional — interphase is explicitly a "companion plugin for Clavain." The shim pattern is the right approach but could be documented better.

### 2. Clavain's `strategy` command generates PRDs

The `/clavain:strategy` command creates PRDs in `docs/prds/`. Meanwhile, `interpath` also generates PRDs via `/interpath:prd`. These are distinct but conceptually overlapping:
- Clavain's strategy: brainstorm → PRD (inline, part of the sprint workflow)
- interpath's prd: beads state + project context → PRD (standalone artifact generation)

**Assessment:** Not a true violation — strategy produces PRDs as a workflow artifact, while interpath generates them as standalone product documents. But users may be confused about which to use.

### 3. Clavain has 4 alias commands

- `lfg` → alias for `sprint`
- `full-pipeline` → alias for `sprint`
- `cross-review` → alias for `interpeer`
- `deep-review` → alias for `flux-drive` (which is an interflux command)

**Assessment:** `deep-review` is especially concerning — it aliases a command that lives in a companion plugin. This creates a dependency where Clavain users expect `/clavain:deep-review` to work but the actual implementation is in interflux. The other aliases are convenience but add surface area.

### 4. Clavain skills that are domain-specific

Several Clavain skills are arguably domain-specific rather than "general-purpose engineering discipline":

- **slack-messaging** — Slack is a specific integration, not engineering discipline
- **distinctive-design** — UI/UX design is a domain, not a workflow pattern
- **agent-native-architecture** — Could be a standalone plugin for agent design patterns
- **finding-duplicate-functions** — Codebase analysis tool, could live with tldr-swinton or standalone
- **mcp-cli** — MCP interaction is a tooling concern, could be in a dev-tools plugin

**Assessment:** These work fine in Clavain for a single-user system. But if Clavain is meant to be installable by others ("opinionated engineering discipline"), domain-specific skills dilute the core identity.

### 5. Cross-AI orchestration scattered across skill + command + companion

Cross-AI review involves:
- `interpeer` skill in Clavain (defines modes: quick, deep, council, mine)
- `interpeer` command in Clavain (invokes the skill)
- `cross-review` command in Clavain (alias for interpeer)
- `debate` command in Clavain (structured Claude↔Codex debate)
- `interserve` skill in Clavain (Codex CLI dispatch)
- `interserve-toggle` command in Clavain (mode toggle)
- Oracle CLI (external tool, invoked by interpeer skill)
- Codex CLI (external tool, invoked by interserve skill)

**Assessment:** Cross-AI orchestration is deeply embedded in Clavain. It's arguably a separate concern (multi-agent orchestration) that could be its own module, but the tight integration with Clavain's workflow makes extraction expensive.

### 6. Clavain's review command vs interflux's flux-drive

- `/clavain:review` — "Perform exhaustive code reviews using multi-agent analysis and deep inspection"
- `/interflux:flux-drive` — "Intelligent multi-agent document/codebase review"
- `/clavain:deep-review` — alias for flux-drive

Both dispatch reviewer agents. The distinction: Clavain's `review` is the orchestrator that decides which interflux agents to dispatch, while flux-drive is the execution engine. But users see three entry points for "review my code."

**Assessment:** This is the most important boundary to clarify. The user-facing story should be: Clavain owns the "when and why" (workflow context), interflux owns the "how" (agent execution).

## Proposed Boundary Principles

### What belongs in Clavain (the hub)

1. **Workflow orchestration** — sprint, brainstorm, strategy, write-plan, work, execute-plan
2. **Quality gates and discipline** — quality-gates, review, resolve, verification
3. **Meta/setup** — setup, init, doctor, help, generate-command
4. **Core engineering skills** — TDD, systematic debugging, verification, code review discipline, refactor safely, landing changes
5. **Planning skills** — writing plans, executing plans, parallel dispatch
6. **Claude Code meta-skills** — working with Claude Code, developing plugins, creating skills

**The test:** "Would someone who doesn't use our specific companion plugins still benefit from this?" If yes → Clavain.

### What belongs in companion modules

1. **Domain-specific review** — All 12 interflux agents (architecture, safety, correctness, etc.)
2. **Product artifacts** — PRD, roadmap, vision, changelog, status (interpath)
3. **Phase tracking** — Phase lifecycle, gate validation, discovery (interphase)
4. **Statusline** — Visual state rendering (interline)
5. **Doc freshness** — Drift detection, signal scoring (interwatch)
6. **External integrations** — Notion (interkasten), voice profile (interfluence), Slack (should move out of Clavain)
7. **Specialized tooling** — Code context (tldr-swinton), TUI testing (tuivision), agent coordination (interlock)
8. **Analytics** — Tool usage patterns (tool-time)

**The test:** "Does this have a clear domain boundary and could evolve independently?" If yes → companion module.

### Gray area: Cross-AI orchestration

Cross-AI skills (interpeer, interserve, debate) are deeply tied to Clavain's workflow but could theoretically be a separate "interagent" module. **Recommendation:** Keep in Clavain for now — the workflow integration is too tight, and extracting would create more coupling than it removes.

## Specific Recommendations

### Move OUT of Clavain

| Item | Current Location | Proposed Location | Rationale |
|------|-----------------|-------------------|-----------|
| `slack-messaging` skill | Clavain | New `intercom` plugin or standalone | Not engineering discipline |
| `distinctive-design` skill | Clavain | New `interdesign` plugin or standalone | Domain-specific, not workflow |
| `deep-review` command | Clavain | Remove (users use `/interflux:flux-drive` directly) | Alias creates confusion |
| `lfg` command | Clavain | Keep (harmless alias, well-known) | Convenience |
| `full-pipeline` command | Clavain | Remove | Redundant with sprint |
| `cross-review` command | Clavain | Remove | Redundant with interpeer |

### Keep in Clavain but clarify

| Item | Clarification Needed |
|------|---------------------|
| `strategy` command | Document that it produces "workflow PRDs" distinct from interpath's "product PRDs" |
| `review` vs `flux-drive` | Document that review = orchestrator, flux-drive = engine |
| `interpeer` | Document that it stays in Clavain because it's workflow-integrated |
| interphase shims | Document the shim pattern and version contract |

### Consider for future extraction

| Item | Why it could move | Why it stays for now |
|------|-------------------|---------------------|
| `agent-native-architecture` skill | Domain-specific pattern | Only 1 skill, not worth a plugin |
| `finding-duplicate-functions` skill | Codebase analysis tool | Pairs well with refactor-safely |
| `mcp-cli` skill | Dev tooling | Generic enough to be core engineering |
| Cross-AI skills (interpeer, interserve, debate) | Separate concern | Too integrated with workflow |

## Design Questions for User

1. **Should Clavain be installable standalone (without companions)?** Currently it can be, but some commands degrade (sprint without interphase has no discovery, quality-gates without interflux has no agents).

2. **Should companion plugins declare Clavain as a dependency?** Currently none do. Adding `"dependencies": ["clavain"]` would formalize the relationship.

3. **How many entry points for "review" is too many?** Currently: `/clavain:review`, `/clavain:deep-review`, `/clavain:quality-gates`, `/interflux:flux-drive`, `/clavain:plan-review`. That's 5 review-related commands.

4. **Should domain-specific skills like slack-messaging and distinctive-design move out?** They work fine for your use but dilute Clavain's "general-purpose engineering discipline" identity.

5. **Is the shim pattern the right coupling model for interphase?** Alternatives: (a) Clavain calls `bd` CLI directly instead of sourcing libraries, (b) interphase exposes a command that Clavain invokes, (c) keep shims but version-lock them.
