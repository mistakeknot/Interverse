# Interverse

Monorepo for the inter-module ecosystem — Claude Code plugins, services, and infrastructure.

Each subproject keeps its own `.git` and GitHub repo. This monorepo provides shared scripts, co-location for development, and the plugin marketplace.

**[Interactive Ecosystem Diagram](https://mistakeknot.github.io/interchart/)** — explore how all plugins, skills, agents, and services connect. Auto-regenerates every 6 hours.

## Hub

| Module | Version | Description |
|--------|---------|-------------|
| [Autarch](https://github.com/mistakeknot/Autarch) | n/a | AI agent development tools suite (Bigend, Gurgeh, Coldwine, Pollard) |
| [Clavain](https://github.com/mistakeknot/Clavain) | 0.6.39 | Self-improving agent rig — product and engineering discipline from brainstorm to ship. Core of the ecosystem. |

## Plugins

| Module | Version | Description |
|--------|---------|-------------|
| [interchart](https://github.com/mistakeknot/interchart) | 0.1.0 | Interactive ecosystem diagram — D3.js force graph of all plugins, skills, and relationships |
| [intercheck](https://github.com/mistakeknot/intercheck) | 0.1.4 | Code quality guards and session health monitoring |
| [interdoc](https://github.com/mistakeknot/interdoc) | 5.1.0 | Recursive AGENTS.md generator with structural auto-fix, CLAUDE.md harmonization, and GPT critique |
| [interfluence](https://github.com/mistakeknot/interfluence) | 0.1.2 | Voice profile and style adaptation — analyze writing samples, build a profile, apply it to output |
| [interflux](https://github.com/mistakeknot/interflux) | 0.2.0 | Multi-agent review and research engine — 7 review agents, 5 research agents, MCP servers |
| [interject](https://github.com/mistakeknot/interject) | 0.1.6 | Ambient discovery and research engine |
| [interkasten](https://github.com/mistakeknot/interkasten) | 0.3.1 | Bidirectional Notion sync with MCP server — project management, key doc tracking, push sync |
| [interline](https://github.com/mistakeknot/interline) | 0.2.3 | Dynamic statusline — active beads, workflow phase, coordination status, Codex dispatch |
| [interlock](https://github.com/mistakeknot/interlock) | 0.1.0 | Multi-agent file coordination — reserve files, detect conflicts, exchange messages (MCP) |
| [interleave](https://github.com/mistakeknot/interleave) | 0.1.1 | Deterministic skeleton with LLM islands and template-driven writing |
| [interpath](https://github.com/mistakeknot/interpath) | 0.1.1 | Product artifact generator — roadmaps, PRDs, vision docs, changelogs from project context |
| [interphase](https://github.com/mistakeknot/interphase) | 0.3.2 | Phase tracking, gate validation, and work discovery for Beads |
| [interpeer](https://github.com/mistakeknot/interpeer) | 0.1.0 | Cross-AI peer review through Claude↔Codex, Oracle, and multi-model council modes |
| [interpub](https://github.com/mistakeknot/interpub) | 0.1.1 | Safe plugin publishing — atomic version bumps, sync validation, commit and push |
| [intersearch](https://github.com/mistakeknot/intersearch) | 0.1.1 | Shared embedding and search infrastructure for semantic search and web retrieval |
| [interserve](https://github.com/mistakeknot/interserve) | 0.1.1 | Interserve MCP server for context compression and content extraction |
| [interstat](https://github.com/mistakeknot/interstat) | 0.2.2 | Token efficiency benchmarking for agent workflows |
| [intersynth](https://github.com/mistakeknot/intersynth) | 0.1.2 | Multi-agent synthesis engine for combining and summarizing parallel findings |
| [intertest](https://github.com/mistakeknot/intertest) | 0.1.1 | Engineering quality disciplines for debugging, test-driven development, and verification gates |
| [interwatch](https://github.com/mistakeknot/interwatch) | 0.1.1 | Doc freshness monitoring — drift detection, confidence scoring, auto-refresh orchestration |
| [intercraft](https://github.com/mistakeknot/intercraft) | 0.1.0 | Agent-native architecture patterns — design, review, and audit for agent-first applications |
| [interdev](https://github.com/mistakeknot/interdev) | 0.1.0 | Developer tooling — MCP CLI interaction and tool discovery |
| [interform](https://github.com/mistakeknot/interform) | 0.1.0 | Design patterns and visual quality — distinctive, production-grade interfaces |
| [internext](https://github.com/mistakeknot/internext) | 0.1.0 | Work prioritization and next-task analysis — tradeoff-aware recommendations from project context |
| [interslack](https://github.com/mistakeknot/interslack) | 0.1.0 | Slack integration — send messages, read channels, test integrations |
| [interlens](https://github.com/mistakeknot/interlens) | 2.2.4 | FLUX cognitive lenses for structured thinking and belief-driven synthesis |
| [intermap](https://github.com/mistakeknot/intermap) | 0.1.3 | Project-level code mapping with call graphs and architecture analysis |
| [intermem](https://github.com/mistakeknot/intermem) | 0.2.1 | Memory synthesis for graduating stable auto-memory facts into documentation |
| [intermux](https://github.com/mistakeknot/intermux) | 0.1.1 | Agent activity visibility with tmux monitoring and health signals |
| [tldr-swinton](https://github.com/mistakeknot/tldr-swinton) | 0.7.6 | Token-efficient code reconnaissance — diff-context, semantic search, structural patterns (MCP) |
| [tool-time](https://github.com/mistakeknot/tool-time) | 0.3.1 | Tool usage analytics — tracks patterns via hooks, detects inefficiencies |
| [tuivision](https://github.com/mistakeknot/tuivision) | 0.1.2 | TUI automation and visual testing — Playwright for terminal applications (MCP) |

## Services

| Module | Description |
|--------|-------------|
| [intermute](https://github.com/mistakeknot/intermute) | Multi-agent coordination service — file reservation, messaging, conflict detection (Go) |

## Infrastructure

| Module | Description |
|--------|-------------|
| [interband](https://github.com/mistakeknot/interband) | Shared sideband protocol and message transport helpers for cross-module coordination |
| [interbase](https://github.com/mistakeknot/interbase) | Shared integration SDK for plugin interoperability in the Interverse ecosystem |
| [intercore](https://github.com/mistakeknot/intercore) | Kernel service for runs, dispatches, gates, events, and agent lifecycle orchestration |
| [marketplace](https://github.com/mistakeknot/interagency-marketplace) | Interagency plugin marketplace — central registry for all plugins |
| [agent-rig](https://github.com/mistakeknot/agent-rig) | Rig manager for AI coding agents — companion plugins, MCP servers, env config |
| [interbench](https://github.com/mistakeknot/interbench) | Agent workbench — run capture, artifact store, eval/regression for agentic workflows |

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
