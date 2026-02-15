# Interverse

Monorepo for the inter-module ecosystem — Claude Code plugins, services, and infrastructure.

Each subproject keeps its own `.git` and GitHub repo. This monorepo provides shared scripts, co-location for development, and the plugin marketplace.

## Hub

| Module | Version | Description |
|--------|---------|-------------|
| [clavain](hub/clavain/) | 0.6.13 | General-purpose engineering discipline plugin — agents, commands, skills, MCP server. Core of the ecosystem. |

## Plugins

| Module | Version | Description |
|--------|---------|-------------|
| [interdoc](plugins/interdoc/) | 5.1.0 | Recursive AGENTS.md generator with structural auto-fix, CLAUDE.md harmonization, and GPT critique |
| [interfluence](plugins/interfluence/) | 0.1.2 | Voice profile and style adaptation — analyze writing samples, build a profile, apply it to output |
| [interflux](plugins/interflux/) | 0.2.0 | Multi-agent review and research engine — 7 review agents, 5 research agents, MCP servers |
| [interkasten](plugins/interkasten/) | 0.3.1 | Bidirectional Notion sync with MCP server — project management, key doc tracking, push sync |
| [interline](plugins/interline/) | 0.2.3 | Dynamic statusline — active beads, workflow phase, coordination status, Codex dispatch |
| [interlock](plugins/interlock/) | 0.1.0 | Multi-agent file coordination — reserve files, detect conflicts, exchange messages (MCP) |
| [interpath](plugins/interpath/) | 0.1.1 | Product artifact generator — roadmaps, PRDs, vision docs, changelogs from project context |
| [interphase](plugins/interphase/) | 0.3.2 | Phase tracking, gate validation, and work discovery for Beads |
| [interpub](plugins/interpub/) | 0.1.1 | Safe plugin publishing — atomic version bumps, sync validation, commit and push |
| [interwatch](plugins/interwatch/) | 0.1.1 | Doc freshness monitoring — drift detection, confidence scoring, auto-refresh orchestration |
| [intercraft](plugins/intercraft/) | 0.1.0 | Agent-native architecture patterns — design, review, and audit for agent-first applications |
| [interdev](plugins/interdev/) | 0.1.0 | Developer tooling — MCP CLI interaction and tool discovery |
| [interform](plugins/interform/) | 0.1.0 | Design patterns and visual quality — distinctive, production-grade interfaces |
| [interslack](plugins/interslack/) | 0.1.0 | Slack integration — send messages, read channels, test integrations |
| [tldr-swinton](plugins/tldr-swinton/) | 0.7.6 | Token-efficient code reconnaissance — diff-context, semantic search, structural patterns (MCP) |
| [tool-time](plugins/tool-time/) | 0.3.1 | Tool usage analytics — tracks patterns via hooks, detects inefficiencies |
| [tuivision](plugins/tuivision/) | 0.1.2 | TUI automation and visual testing — Playwright for terminal applications (MCP) |

## Services

| Module | Description |
|--------|-------------|
| [intermute](services/intermute/) | Multi-agent coordination service — file reservation, messaging, conflict detection (Go) |

## Infrastructure

| Module | Description |
|--------|-------------|
| [marketplace](infra/marketplace/) | Interagency plugin marketplace — central registry for all plugins |
| [agent-rig](infra/agent-rig/) | Rig manager for AI coding agents — companion plugins, MCP servers, env config |
| [interbench](infra/interbench/) | Agent workbench — run capture, artifact store, eval/regression for agentic workflows |

## Shared Scripts

| Script | Description |
|--------|-------------|
| [`interbump.sh`](scripts/interbump.sh) | Unified version bump — auto-discovers version files, updates marketplace via jq, pulls before pushing |

Every plugin has a `scripts/bump-version.sh` thin wrapper that delegates to `interbump.sh`.

## Installing Plugins

```bash
# Add the marketplace
claude plugins marketplace add mistakeknot/interagency-marketplace

# Install any plugin
claude plugins install clavain@interagency-marketplace
```

## Naming Convention

All module names are **lowercase** except **Clavain** (proper noun) and **Interverse** (monorepo name).
