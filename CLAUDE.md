# Interverse

Monorepo for the inter-module ecosystem — Claude Code plugins, services, and infrastructure.

## Structure

```
hub/clavain/          → self-improving agent rig — brainstorm to ship (proper case: Clavain)
plugins/              → companion plugins (all lowercase)
  interdoc/           → AGENTS.md generator
  interfluence/       → voice profile + style adaptation
  interflux/          → multi-agent review engine
  interkasten/        → Notion sync + documentation
  interline/          → statusline renderer
  interlock/          → multi-agent file coordination (MCP)
  intermap/           → project-level code mapping + architecture analysis (MCP)
  intermux/           → agent activity visibility + tmux monitoring (MCP)
  interpath/          → product artifact generator
  interphase/         → phase tracking + gates
  interpub/           → plugin publishing
  interwatch/         → doc freshness monitoring
  interslack/         → Slack integration
  interform/          → design patterns + visual quality
  intercraft/         → agent-native architecture patterns
  interdev/           → developer tooling + skill/plugin authoring
  interpeer/          → cross-AI peer review (Oracle/GPT escalation)
  intertest/          → engineering quality disciplines (TDD, debugging, verification)
  intercheck/         → code quality guards + session health monitoring
  interleave/         → deterministic skeleton + LLM islands pattern (spec + library)
  interject/          → ambient discovery + research engine (MCP)
  interserve/         → Codex spark classifier + context compression (MCP)
  interstat/          → token efficiency benchmarking
  intersynth/         → multi-agent synthesis engine (verdict aggregation)
  internext/          → work prioritization + tradeoff analysis
  intersearch/        → shared embedding + Exa search library
  interlens/          → cognitive augmentation lenses (FLUX podcast)
  tldr-swinton/       → token-efficient code context (MCP)
  tool-time/          → tool usage analytics
  tuivision/          → TUI automation + visual testing (MCP)
services/
  intermute/          → multi-agent coordination service (Go)
sdk/
  interbase/          → shared integration SDK for dual-mode plugins
infra/
  marketplace/        → interagency plugin marketplace
scripts/              → shared scripts (interbump.sh)
docs/                 → shared documentation
```

## Naming Convention

- All module names are **lowercase** — `interflux`, `intermute`, `interkasten`
- Exception: **Clavain** (hub, proper noun) and **Interverse** (monorepo name)
- GitHub repos match: `github.com/mistakeknot/interflux`

## Working in Subprojects

Each subproject has its own `CLAUDE.md` and `AGENTS.md`. When working in a subproject, those take precedence.

Compatibility symlinks exist at `/root/projects/<name>` pointing into this monorepo for backward compatibility.

## Plugin Publish Policy

For plugin development and release workflow (including publish gates and required completion criteria), follow root `AGENTS.md`:
- `## Publishing`
- `## Plugin Dev/Publish Gate`
- `## Version Bumping (interbump)`

## Design Decisions (Do Not Re-Ask)

- Physical monorepo, not symlinks — projects live here, old locations are symlinks back
- Each subproject keeps its own `.git` — not a git monorepo
- Clavain is the hub; everything else is a module
