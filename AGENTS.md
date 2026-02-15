# Interverse — Agent Development Guide

## Overview

Interverse is the physical monorepo containing the full inter-module ecosystem for Claude Code. 13 plugins, 1 hub (Clavain), 1 service (intermute), and shared infrastructure. Each module keeps its own `.git` — this is not a git monorepo, but a directory layout with independent repos.

## Directory Layout

| Path | Role | Description |
|------|------|-------------|
| `hub/clavain/` | Hub | Recursively self-improving multi-agent rig — brainstorm to ship |
| `plugins/interdoc/` | Plugin | Recursive AGENTS.md generator with cross-AI critique |
| `plugins/interfluence/` | Plugin | Voice profile analysis and style adaptation (MCP) |
| `plugins/interflux/` | Plugin | Multi-agent document review + research engine (7 review agents, MCP) |
| `plugins/interkasten/` | Plugin | Bidirectional Notion sync with adaptive documentation (MCP) |
| `plugins/interline/` | Plugin | Dynamic statusline for Claude Code |
| `plugins/interlock/` | Plugin | Multi-agent file coordination via intermute (MCP) |
| `plugins/interpath/` | Plugin | Product artifact generator (roadmaps, PRDs, changelogs) |
| `plugins/interphase/` | Plugin | Phase tracking, gate validation, work discovery |
| `plugins/interpub/` | Plugin | Safe plugin version bumping and publishing |
| `plugins/interwatch/` | Plugin | Doc freshness monitoring and drift detection |
| `plugins/tldr-swinton/` | Plugin | Token-efficient code context via MCP server |
| `plugins/tool-time/` | Plugin | Tool usage analytics for Claude Code and Codex CLI |
| `plugins/tuivision/` | Plugin | TUI automation and visual testing via MCP server |
| `services/intermute/` | Service | Multi-agent coordination service (Go, SQLite) |
| `infra/marketplace/` | Infra | interagency plugin marketplace registry |
| `scripts/` | Shared | Cross-project scripts (interbump.sh) |
| `docs/` | Docs | Shared documentation, brainstorms, research |

## Module Relationships

```
clavain (hub)
├── interphase  (phase tracking, gates, work discovery)
├── interline   (statusline rendering)
├── interflux   (multi-agent review + research)
├── interpath   (product artifact generation)
├── interwatch  (doc freshness monitoring)
└── interlock   (multi-agent file coordination)

intermute (service) ← used by interlock for file reservation + messaging
interpub           ← used to publish all plugins
interdoc           ← generates AGENTS.md for all projects
interfluence       ← standalone voice profiling
interkasten        ← standalone Notion sync
tldr-swinton       ← standalone code context MCP
tool-time          ← standalone usage analytics
tuivision          ← standalone TUI testing MCP
marketplace        ← registry for all published plugins
```

## Naming Convention

- All module directory names are **lowercase**: `interflux`, `intermute`, `interkasten`
- In prose and documentation, use **lowercase**: `interflux provides review agents`
- Exception: **Clavain** (proper noun, hub name) and **Interverse** (monorepo name)
- GitHub repos: `github.com/mistakeknot/<lowercase-name>`

## Development Workflow

Each subproject is an independent git repo. To work on a specific module:

```bash
cd /root/projects/Interverse/plugins/interflux
# Each has its own CLAUDE.md, AGENTS.md, .git
```

### Testing plugins locally

```bash
claude --plugin-dir /root/projects/Interverse/plugins/<name>
```

### Publishing

In Claude Code chat, use the interpub slash command:

```
/interpub:release <version>
```

Or from a terminal, use the bump script directly:

```bash
cd plugins/interflux
scripts/bump-version.sh 0.2.1            # bump + commit + push
scripts/bump-version.sh 0.2.1 --dry-run  # preview only
```

Both methods call the same underlying engine (`scripts/interbump.sh`).

## Version Bumping (interbump)

All plugins and the hub share a single version bump engine at `scripts/interbump.sh`. Each module's `scripts/bump-version.sh` is a thin wrapper (5 lines) that delegates to it.

### How it works

1. Reads plugin name and current version from `.claude-plugin/plugin.json` via **jq**
2. Auto-discovers version files: `plugin.json` (always), plus `pyproject.toml`, `package.json`, `server/package.json`, `agent-rig.json`, `docs/PRD.md` if they exist
3. Finds marketplace by walking up from plugin root looking for `infra/marketplace/` (monorepo layout), falling back to `../interagency-marketplace` (legacy sibling checkout)
4. Runs `scripts/post-bump.sh` if present (runs after version file edits but before git commit)
5. Updates all version files (jq for JSON, sed for toml/md)
6. Updates marketplace.json via `jq '(.plugins[] | select(.name == $name)).version = $ver'`
7. Git add + commit + `pull --rebase` + push (both plugin and marketplace repos)
8. Creates cache symlinks in `~/.claude/plugins/cache/` so running Claude Code sessions' plugin Stop hooks (which reference the old version path) continue to resolve after the version directory is renamed

### Post-bump hooks

Modules with extra work needed between version edits and git commit use `scripts/post-bump.sh`:

| Plugin | Post-bump action |
|--------|-----------------|
| `hub/clavain/` | Runs `gen-catalog.py` to refresh skill/agent/command counts |
| `plugins/tldr-swinton/` | Reinstalls CLI via `uv tool install`, checks interbench sync |

### Adding a new plugin

1. Create `scripts/bump-version.sh` (copy any existing 5-line wrapper)
2. Ensure `.claude-plugin/plugin.json` has `name` and `version` fields
3. Add an entry to `infra/marketplace/.claude-plugin/marketplace.json`
4. If the plugin needs pre-commit work, add `scripts/post-bump.sh`

## Compatibility

Symlinks at `/root/projects/<name>` point into this monorepo for backward compatibility with scripts, configs, and Claude Code session history that reference old paths. These can be removed once all references are updated.

## Landing the Plane (Session Completion)

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd sync
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
