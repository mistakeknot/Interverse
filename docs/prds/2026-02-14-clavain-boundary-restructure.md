# PRD: Clavain Boundary Restructure

**Source brainstorm:** `docs/brainstorms/2026-02-14-clavain-vs-modules-boundary-analysis.md`

## Problem

Clavain (37 commands, 27 skills, 5 agents) has accumulated domain-specific functionality and alias commands that dilute its identity as "general-purpose engineering discipline." The boundary between hub and companion modules is blurred. Users see multiple entry points for the same action (5 review commands). Domain skills (Slack, design) sit alongside core engineering skills (TDD, debugging).

## Goals

1. **Clavain = engineering discipline only.** Every skill, command, and agent passes the test: "Would someone who doesn't use our companion plugins still benefit from this?"
2. **No aliases.** One command = one name. Remove lfg, full-pipeline, cross-review, deep-review.
3. **Domain skills in domain plugins.** Move slack-messaging, distinctive-design, agent-native-architecture (full cluster), finding-duplicate-functions, and mcp-cli to appropriate companion plugins.
4. **Clarified review boundaries.** Document that Clavain owns "when/why" (orchestration), interflux owns "how" (agent execution).
5. **Formalized companion relationships.** Document the shim pattern, consider dependency declarations.

## Non-Goals

- Rewriting interphase's library interface (the shim pattern stays)
- Moving cross-AI skills (interpeer, interserve, debate) out of Clavain — too integrated with workflow
- Changing interflux's agent roster
- Restructuring the sprint/workflow pipeline itself

## Features

### F1: Remove alias commands

Delete 4 alias command files from Clavain:
- `commands/lfg.md`
- `commands/full-pipeline.md`
- `commands/cross-review.md`
- `commands/deep-review.md`

Update plugin.json command count. Update README. Update help command if it references aliases.

**Clavain after:** 33 commands (down from 37)

### F2: Move `slack-messaging` skill to new `interslack` plugin

Create a new companion plugin `interslack` for Slack integration:
- Move `skills/slack-messaging/` (SKILL.md + scripts/)
- Plugin scope: Slack messaging, channel interaction
- Minimal plugin: 1 skill, 0 agents, 0 commands, 0 hooks
- Auto-installed as Clavain rig companion

**Clavain after:** 26 skills (down from 27)

### F3: Move `distinctive-design` skill to new `interform` plugin

Create a new companion plugin `interform` for design/UX concerns:
- Move `skills/distinctive-design/` (SKILL.md)
- Plugin scope: design language, visual quality, UI patterns
- Minimal plugin: 1 skill, 0 agents, 0 commands, 0 hooks
- Auto-installed as Clavain rig companion

**Clavain after:** 25 skills (down from 26)

### F4: Move `agent-native-architecture` cluster to new `intercraft` plugin

This is the largest extraction — a full skill+agent+command cluster:
- Move `skills/agent-native-architecture/` (SKILL.md + 14 reference docs)
- Move `agents/review/agent-native-reviewer.md`
- Move `commands/agent-native-audit.md`
- Plugin scope: agent-native design patterns, architecture review, audit
- Plugin: 1 skill, 1 agent, 1 command, 0 hooks
- Auto-installed as Clavain rig companion

**Clavain after:** 24 skills, 4 agents, 32 commands

### F5: Move `finding-duplicate-functions` skill to `tldr-swinton`

This is a codebase analysis tool that pairs naturally with tldr-swinton's code analysis:
- Move `skills/finding-duplicate-functions/` (SKILL.md + 5 scripts + directory)
- Add to tldr-swinton's skill roster
- The scripts (extract-functions.sh, find-duplicates-prompt.md, etc.) are self-contained

**Clavain after:** 23 skills

### F6: Move `mcp-cli` skill to new `interdev` plugin

Create a new companion plugin `interdev` for developer tooling:
- Move `skills/mcp-cli/` (SKILL.md)
- Plugin scope: developer tool integrations (MCP CLI, potentially more)
- Minimal plugin: 1 skill, 0 agents, 0 commands, 0 hooks
- Auto-installed as Clavain rig companion

**Clavain after:** 22 skills

### F7: Update Clavain metadata and documentation

After all moves:
- Update `plugin.json`: description, skill/agent/command counts
- Update `README.md`: counts, skill list
- Update `CLAUDE.md`: counts, validation commands
- Update `help` command if it lists moved items
- Update `setup` command if it references moved items
- Run validation: `ls skills/*/SKILL.md | wc -l` should be 22

### F8: Document boundary principles

Add a `docs/ARCHITECTURE.md` or section to Clavain's AGENTS.md documenting:
1. The boundary test for hub vs companion
2. The review hierarchy (Clavain orchestrates, interflux executes)
3. The shim pattern for interphase coupling
4. The companion plugin list and what each owns

## Summary of changes

| Metric | Before | After | Delta |
|--------|--------|-------|-------|
| Commands | 37 | 32 | -5 (4 aliases + agent-native-audit) |
| Skills | 27 | 22 | -5 (slack, design, agent-native, duplicates, mcp-cli) |
| Agents | 5 | 4 | -1 (agent-native-reviewer) |
| Hooks | 8 | 8 | 0 |
| New plugins created | 0 | 4 | +4 (interslack, interform, intercraft, interdev) |

## Risks

1. **New plugin overhead** — 4 new plugins to maintain. Mitigation: they're minimal (1-2 files each), and the naming convention (inter + 1 syllable) keeps them identifiable.
2. **Breaking existing users** — Anyone using `/clavain:lfg` or `/clavain:deep-review` will need to update. Mitigation: announce in changelog. Since these are aliases, the primary commands still work.
3. **finding-duplicate-functions migration** — The scripts need to work in tldr-swinton's context. Mitigation: scripts are self-contained, no Clavain-specific imports.
4. **Plugin proliferation** — Going from 13 to 17 companion plugins. Mitigation: the rig installer (`npx @gensysven/agent-rig install`) handles installation atomically. All 4 new plugins auto-install as rig companions.

## Naming convention

All plugin names follow `inter` + one syllable:
- **interslack** — Slack messaging
- **interform** — design/UX patterns
- **intercraft** — agent-native architecture
- **interdev** — developer tooling (MCP CLI)

## Decided

1. Individual plugins, not bundled (inter + 1 syllable naming)
2. All 4 new plugins auto-install with the Clavain rig
3. Dependencies: to be decided after restructure
