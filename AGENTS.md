# Interverse — Agent Development Guide

## Overview

Interverse is the physical monorepo containing the full inter-module ecosystem for Claude Code. 22 plugins, 1 shared library (intersearch), 1 hub (Clavain), 1 service (intermute), and shared infrastructure. Each module keeps its own `.git` — this is not a git monorepo, but a directory layout with independent repos.

## Instruction Loading Order

Use nearest, task-scoped instruction loading instead of reading every instruction file in the repo.

1. Read root `AGENTS.md` once at session start.
2. Before editing files in a module, read that module's local `AGENTS.md`.
3. If local `AGENTS.md` is missing, read that module's local `CLAUDE.md` as fallback.
4. For cross-module changes, repeat steps 2-3 for each touched module.
5. Resolve conflicts with this precedence: local `AGENTS.md` > local `CLAUDE.md` > root `AGENTS.md` > root `CLAUDE.md`.

## Glossary

| Term | Meaning |
|------|---------|
| **Beads** | File-based issue tracker (`bd` CLI). Each project can have a `.beads/` database. All active tracking is at Interverse root. |
| **Hub** | The central orchestrator plugin — Clavain. All companion plugins integrate with it. |
| **Plugin** | A Claude Code extension (skills, commands, hooks, agents, MCP servers) installed from the marketplace. |
| **MCP** | Model Context Protocol — enables plugins to expose tools as server processes that Claude Code calls directly. |
| **Companion** | A plugin that integrates with Clavain (listed in its manifest). Standalone plugins work independently. |
| **Marketplace** | The `interagency-marketplace` registry at `infra/marketplace/` — JSON catalog of all published plugins. |
| **Interspect** | Analytics subsystem inside Clavain — evidence collection, pattern detection, routing overrides. Not a standalone module. |

## Directory Layout

| Path | Role | Description |
|------|------|-------------|
| `hub/clavain/` | Hub | Recursively self-improving multi-agent rig — brainstorm to ship |
| `plugins/intercraft/` | Plugin | Agent-native architecture patterns and audit |
| `plugins/intercheck/` | Plugin | Code quality guards and session health monitoring (hooks) |
| `plugins/interdev/` | Plugin | MCP CLI developer tooling and tool discovery |
| `plugins/interdoc/` | Plugin | Recursive AGENTS.md generator with cross-AI critique |
| `plugins/interfluence/` | Plugin | Voice profile analysis and style adaptation (MCP) |
| `plugins/interflux/` | Plugin | Multi-agent document review + research engine (MCP) |
| `plugins/interform/` | Plugin | Design patterns and visual quality for interfaces |
| `plugins/interject/` | Plugin | Ambient discovery and research engine (MCP, Python) |
| `plugins/interkasten/` | Plugin | Bidirectional Notion sync with adaptive documentation (MCP) |
| `plugins/intersearch/` | Library | Shared embedding client + Exa semantic search (used by interject, interflux) |
| `plugins/interline/` | Plugin | Dynamic statusline for Claude Code |
| `plugins/interlock/` | Plugin | Multi-agent file coordination via intermute (MCP) |
| `plugins/internext/` | Plugin | Work prioritization and tradeoff analysis |
| `plugins/interpath/` | Plugin | Product artifact generator (roadmaps, PRDs, changelogs) |
| `plugins/interphase/` | Plugin | Phase tracking, gate validation, work discovery |
| `plugins/interpub/` | Plugin | Safe plugin version bumping and publishing |
| `plugins/interslack/` | Plugin | Slack integration via slackcli |
| `plugins/interstat/` | Plugin | Token efficiency benchmarking for agent workflows |
| `plugins/interwatch/` | Plugin | Doc freshness monitoring and drift detection |
| `plugins/interlens/` | Plugin | Cognitive augmentation lenses — planned, no manifest yet |
| `plugins/tldr-swinton/` | Plugin | Token-efficient code context via MCP server |
| `plugins/tool-time/` | Plugin | Tool usage analytics for Claude Code and Codex CLI |
| `plugins/tuivision/` | Plugin | TUI automation and visual testing via MCP server |
| `services/intermute/` | Service | Multi-agent coordination service (Go, SQLite) |
| `sdk/interbase/` | SDK | Shared integration SDK for dual-mode plugins |
| `infra/interbench/` | Infra | Eval harness for tldr-swinton capabilities (Go CLI) |
| `infra/marketplace/` | Infra | interagency plugin marketplace registry |
| `scripts/` | Shared | Cross-project scripts (interbump.sh) |
| `docs/` | Docs | **Platform-level** documentation only (cross-cutting brainstorms, research, solutions) |

> **Docs convention:** `Interverse/docs/` is for platform-level work only. Each subproject keeps its own docs at `Interverse/<subproject>/docs/` (e.g., `intermem/docs/brainstorms/`, `plugins/interlock/docs/`).

## Module Relationships

```
clavain (hub)
├── interphase  (phase tracking, gates, work discovery)
├── interline   (statusline rendering)
├── interflux   (multi-agent review + research)
├── interpath   (product artifact generation)
├── interwatch  (doc freshness monitoring)
├── interlock   (multi-agent file coordination)
├── intercraft  (agent-native architecture patterns)
├── interdev    (MCP CLI developer tooling)
├── interform   (design patterns + visual quality)
├── internext   (work prioritization + tradeoff analysis)
└── interslack  (Slack integration)

interject (MCP)    ← ambient discovery engine, uses intersearch for embeddings + Exa
intersearch (lib)  ← shared embedding client + Exa search (used by interject, interflux)
intermute (service) ← used by interlock for file reservation + messaging
interpub           ← used to publish all plugins
interdoc           ← generates AGENTS.md for all projects
interfluence       ← standalone voice profiling
interkasten        ← standalone Notion sync
tldr-swinton       ← standalone code context MCP
intercheck         ← standalone code quality guards + context monitoring
interstat          ← standalone token efficiency benchmarking
interlens           ← cognitive augmentation lenses (planned)
tool-time          ← standalone usage analytics
tuivision          ← standalone TUI testing MCP
marketplace        ← registry for all published plugins
```

## Bead Tracking

All work is tracked at the **Interverse level** using the monorepo `.beads/` database. Module-level `.beads/` databases are read-only archives of historical closed beads.

- Create beads from the Interverse root: `cd /root/projects/Interverse && bd create --title="[module] Description" ...`
- Use `[module]` prefix in bead titles to identify the relevant module (e.g., `[interlock]`, `[interflux]`, `[clavain]`)
- Filter by module: `bd list --status=open | grep -i interlock`
- Cross-module beads use multiple prefixes: `[interlock/intermute]`

### Roadmap

The ecosystem roadmap is at [`docs/roadmap.md`](docs/roadmap.md) with machine-readable canonical output in [`docs/roadmap.json`](docs/roadmap.json). Regenerate both with `/interpath:roadmap` from the Interverse root. Propagate items to sub-module roadmaps with `/interpath:propagate`.

`scripts/sync-roadmap-json.sh` also generates the canonical JSON rollup across `hub/`, `plugins/`, and `services/` roadmaps and cross-module dependencies.

## Naming Convention

- All module directory names are **lowercase** (hyphens allowed): `interflux`, `intermute`, `tldr-swinton`, `tool-time`
- In prose and documentation, use **lowercase**: `interflux provides review agents`
- Exception: **Clavain** (proper noun, hub name) and **Interverse** (monorepo name)
- GitHub repos: `github.com/mistakeknot/<lowercase-name>`

## Prerequisites

Required tools (all pre-installed on this server):

| Tool | Used by | Purpose |
|------|---------|---------|
| `jq` | interbump, hooks | JSON manipulation |
| `uv` | tldr-swinton, interject, intersearch | Python package management |
| `go` (1.24+) | intermute, interlock, interbench | Go builds and tests |
| `node`/`npm` | interkasten | MCP server build |
| `python3` | tldr-swinton, tool-time, interject | CLI tools, analysis scripts |
| `bd` | all | Beads issue tracker CLI |

**Secrets** (in environment or dotfiles — never commit):
- `INTERKASTEN_NOTION_TOKEN` — Notion API token for interkasten sync
- `EXA_API_KEY` — Exa search API for interject and interflux research agents
- `SLACK_TOKEN` — Slack API for interslack

## Development Workflow

Each subproject under `hub/`, `plugins/`, `services/`, and `infra/marketplace/` is an independent git repo with its own `.git`. The root `Interverse/` directory also has a `.git` for the monorepo skeleton (`scripts/`, `docs/`, `.beads/`, `CLAUDE.md`, `AGENTS.md`). **Git commands operate on whichever `.git` is nearest** — always verify with `git rev-parse --show-toplevel` if unsure which repo you're in. To work on a specific module:

```bash
cd /root/projects/Interverse/plugins/interflux
# Each has its own CLAUDE.md, AGENTS.md, .git
```

### Running and testing by module type

**Plugins (hooks/skills/commands only):**
```bash
claude --plugin-dir /root/projects/Interverse/plugins/<name>
# Structural tests (if present):
cd plugins/<name> && uv run pytest tests/structural/ -v
```

**MCP server plugins** (interkasten, interlock, interject, tldr-swinton, tuivision, interflux):
```bash
# Build/install the server first, then test via Claude Code:
cd plugins/interkasten/server && npm install && npm run build && npm test
cd plugins/interlock && bash scripts/build.sh && go test ./...
cd plugins/tldr-swinton && uv tool install -e .  # installs `tldrs` CLI
```

**Service** (intermute):
```bash
cd services/intermute
go run ./cmd/intermute     # starts on :7338
go test ./...              # run all tests
```

**Infra** (interbench):
```bash
cd infra/interbench && go build -o interbench . && ./interbench --help
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

Both methods call the same underlying engine (`scripts/interbump.sh`). All `/interpath:*`, `/interpub:*`, etc. are **Claude Code slash commands** — run them inside a Claude Code session, not from a terminal.

## Plugin Dev/Publish Gate

Applies to work in `hub/clavain/` and `plugins/*`.

Before claiming a plugin release is complete:

1. Run module-appropriate checks from **Running and testing by module type**.
2. Publish only via supported entrypoints:
   - Claude Code: `/interpub:release <version>`
   - Terminal (from plugin root): `scripts/bump-version.sh <version>`
   - Optional preflight: `scripts/bump-version.sh <version> --dry-run`
3. Do not hand-edit version files or marketplace versions for normal releases; `scripts/interbump.sh` is the source of truth.
4. Release is complete only when both pushes succeed:
   - plugin repo push
   - `infra/marketplace` push
5. If the plugin includes hooks, preserve the post-bump/cache-bridge behavior from `interbump` (do not bypass with ad-hoc scripts).
6. After publish, restart Claude Code sessions so the new plugin version is picked up.

### Cross-repo changes

When a change spans multiple repos (e.g., adding an MCP tool to interlock that requires an intermute API change):

1. Make changes in each repo independently
2. Commit and push the **dependency first** (e.g., intermute before interlock)
3. Reference the same Interverse-level bead in both commit messages
4. Always verify you're in the right repo: `git rev-parse --show-toplevel`

## Version Bumping (interbump)

All plugins and the hub share a single version bump engine at `scripts/interbump.sh`. Each module's `scripts/bump-version.sh` is a thin wrapper that delegates to it.

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

## Operational Guides

Consolidated reference guides — read the relevant guide before working in that area.

| Guide | When to Read | Path |
|-------|-------------|------|
| Plugin Troubleshooting | Before debugging plugin errors, creating hooks, publishing | `docs/guides/plugin-troubleshooting.md` |
| Shell & Tooling Patterns | Before writing bash hooks, jq pipelines, or bd commands | `docs/guides/shell-and-tooling-patterns.md` |
| Multi-Agent Coordination | Before multi-agent workflows, subagent dispatch, or token analysis | `docs/guides/multi-agent-coordination.md` |
| Data Integrity Patterns | Before WAL, sync, or validation code in TypeScript | `docs/guides/data-integrity-patterns.md` |
| Beads 0.51 Upgrade | Before unpinning/upgrading beads in Interverse | `docs/guides/beads-0.51-upgrade-plan.md` |

## Critical Patterns

Patterns that bite every session. Each learned from a production failure.

**1. hooks.json format** — Event types are **object keys** (`"SessionStart": [...]`), NOT array elements with `"type"` field. Wrong format silently ignored.

**2. Compiled MCP servers need launcher scripts** — `plugin.json` must point to `bin/launch-mcp.sh` (tracked), not the binary (gitignored). No `postInstall` hook exists.

**3. `.orphaned_at` markers block plugin loading** — After version bumps or cache manipulation: `find ~/.claude/plugins/cache -maxdepth 4 -name ".orphaned_at" -not -path "*/temp_git_*" -delete`

**4. Valid hook events (14 total)** — `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PermissionRequest`, `PostToolUse`, `PostToolUseFailure`, `Notification`, `SubagentStart`, `SubagentStop`, `Stop`, `TeammateIdle`, `TaskCompleted`, `PreCompact`, `SessionEnd`. Invalid events silently ignored.

**5. jq null-slice** — `null[:10]` is a runtime error (exit 5), NOT null. Fix: `(.field // [])[:10]`. Shell functions returning JSON must return `{}`, never `""`.

**6. Billing tokens ≠ effective context** — Cache hits are free for billing but consume context. Decision gates about context limits MUST use `input + cache_read + cache_creation`, never `input + output`.

## Compatibility

Symlinks at `/root/projects/<name>` point into this monorepo for backward compatibility with scripts, configs, and Claude Code session history that reference old paths. These can be removed once all references are updated.

## Landing the Plane (Session Completion)

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File beads for remaining work** - `bd create` for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd sync              # compatibility sync step (0.50.x syncs, 0.51+ no-op)
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

<!-- bv-agent-instructions-v1 -->

---

## Beads Workflow Integration

This project uses [beads_viewer](https://github.com/Dicklesworthstone/beads_viewer) for issue tracking. Issues are stored in `.beads/` and tracked in git.

### Essential Commands

```bash
# View issues (launches TUI - avoid in automated sessions)
bv

# CLI commands for agents (use these instead)
bd ready              # Show issues ready to work (no blockers)
bd list --status=open # All open issues
bd show <id>          # Full issue details with dependencies
bd create --title="..." --type=task --priority=2
bd update <id> --status=in_progress
bd close <id> --reason="Completed"
bd close <id1> <id2>  # Close multiple issues at once
bd sync               # Compatibility sync step (0.50.x syncs, 0.51+ no-op)
```

### Workflow Pattern

1. **Start**: Run `bd ready` to find actionable work
2. **Claim**: Use `bd update <id> --status=in_progress`
3. **Work**: Implement the task
4. **Complete**: Use `bd close <id>`
5. **Sync**: Run `bd sync` at session end (no-op on beads 0.51+)

### Key Concepts

- **Dependencies**: Issues can block other issues. `bd ready` shows only unblocked work.
- **Priority**: P0=critical, P1=high, P2=medium, P3=low, P4=backlog (use numbers, not words)
- **Types**: task, bug, feature, epic, decision, question, docs
- **Blocking**: `bd dep add <issue> <depends-on>` to add dependencies

### Session Protocol

**Before ending any session, run this checklist:**

```bash
git status              # Check what changed
git add <files>         # Stage code changes
bd sync                 # Compatibility sync step (0.50.x syncs, 0.51+ no-op)
git commit -m "..."     # Commit code
bd sync                 # Optional second pass in legacy git-portable setups
git push                # Push to remote
```

### Best Practices

- Check `bd ready` at session start to find available work
- Update status as you work (in_progress → closed)
- Create new issues with `bd create` when you discover tasks
- Use descriptive titles and set appropriate priority/type
- Always run `bd sync` before ending session (no-op on beads 0.51+)

<!-- end-bv-agent-instructions -->

## Cross-Cutting Lessons (not covered by any single guide)
- Never use `> file` redirect — use `--write-output <path>` (browser mode uses console.log) <!-- intermem:69657f61 -->
- Never wrap with external `timeout` — use `--timeout <seconds>` flag <!-- intermem:aea8907b -->
- Requires: `DISPLAY=:99 CHROME_PATH=/usr/local/bin/google-chrome-wrapper`

### Git Credential Lock <!-- intermem:8ed6945e -->
- **Root cause (mk user)**: Shared `server/.gitconfig` had `credential.helper = store --file /root/.claude/git-credentials` — mk can't access `/root/`, so `O_CREAT|O_EXCL` on lock file fails with ENOENT <!-- intermem:6d774d12 -->
- **Fix**: Removed credential helper from shared config (`dotfiles-sync/server/.gitconfig`); each user has own credential config in their `.gitconfig` <!-- intermem:d5211b36 -->
- **TODO (root)**: Replace root's `.gitconfig` symlink → real file with `[include] path=.../server/.gitconfig` + `[credential] helper = store --file /root/.claude/git-credentials` <!-- intermem:7f56c5c7 -->
- **Diagnosis trick**: `strace -e trace=openat,rename -f git push 2>&1 | grep "credential\|lock"` reveals which credential paths are attempted <!-- intermem:d543cc33 -->
- See `docs/solutions/environment-issues/git-credential-lock-multi-user-20260216.md`

### Tmux Cross-User Access (intermux) <!-- intermem:3bd3d012 -->
- tmux needs 3 layers: directory perms (`711`), socket perms (`777`), and `server-access` ACL <!-- intermem:255e8dbe -->
- Fix: `chmod 711 /tmp/tmux-0 && chmod 777 /tmp/tmux-0/default && tmux server-access -a claude-user` <!-- intermem:3a24c33e -->
- Intermux uses `TMUX_SOCKET` env var → `-S` flag on all tmux commands

### Plugin Publishing (all plugins) <!-- intermem:601991fb -->
- **BUG**: A hook auto-runs `interbump.sh` on every `git push` from plugin repos, auto-incrementing in a loop. Use `bash scripts/bump-version.sh <version>` once and accept the version it produces. <!-- intermem:553367b0 -->
- `claude plugins install` runs `--recurse-submodules` — set `update = none` in `.gitmodules` for data-only submodules

### Beads Tracker (Interverse) <!-- intermem:b6828079 -->
- **Migrated from SQLite to Dolt** — storage at `.beads/dolt`, DB name `beads_iv` <!-- intermem:cb5736f3 -->
- Use `bd` from `~/.local/bin/bd` (v0.52.0), NOT the old `/usr/local/bin/bd` <!-- intermem:28c38916 -->
- `bd sync --from-main` and `bd sync --status` are **obsolete** — use plain `bd sync` only

### Agent Dispatch <!-- intermem:bce0aa55 -->
- New agent `.md` files created mid-session NOT available as `subagent_type` until restart <!-- intermem:4a3ea505 -->
- Workaround: `subagent_type: general-purpose` + paste full agent prompt <!-- intermem:67045609 -->
- Background agents from previous sessions survive context exhaustion

### modernc.org/sqlite (pure Go, no CGO) <!-- intermem:9e965d66 -->
- **CTE + UPDATE RETURNING not supported** — `WITH claim AS (UPDATE ... RETURNING 1) SELECT ...` fails with syntax error. Use direct `UPDATE ... RETURNING` with row counting (`rows.Next()`) instead. <!-- intermem:b93bf498 -->
- DSN `_pragma` unreliable — always set PRAGMAs explicitly after `sql.Open` <!-- intermem:830d796b -->
- `SetMaxOpenConns(1)` mandatory for WAL correctness in CLI tools <!-- intermem:216a2865 -->
- Concurrent `sql.Open` from goroutines: first connection claims lock, others get SQLITE_BUSY before `busy_timeout` is set (PRAGMA hasn't run). Don't test concurrent migration from goroutines; test sequentially. <!-- intermem:3061b862 -->

## Research References
- `new-modules-research.md` — embedding model comparisons and papers <!-- intermem:b9d81bf4 -->

## Search Improvements
- BM25 via `rank-bm25`: pure Python, complements vector search for identifiers <!-- intermem:b18c0a7d -->
- RRF (Reciprocal Rank Fusion): ~20 lines to merge dense + sparse results <!-- intermem:c9fa2603 -->
- Cross-encoder reranking: post-retrieval precision boost <!-- intermem:724a46d5 -->
- ast-grep: structural code search (tree-sitter based, 15k stars) <!-- intermem:00ceb26d -->

## Code Compression
- LongCodeZip (ASE 2025): 5.6x compression, training-free, two-stage <!-- intermem:90802e3a -->
- DAST (ACL 2025): AST-aware compression using node information density <!-- intermem:776e7987 -->
- ContextEvolve (Feb 2026 arxiv): multi-agent compression, 33% improvement + 29% token reduction <!-- intermem:5c2290f6 -->

## Key Papers
- nomic-embed-code: ICLR 2025 (CoRNStack) <!-- intermem:5a5b0b08 -->
- CodeXEmbed: COLM 2025 <!-- intermem:bda89db4 -->
- LoRACode: ICLR 2025 <!-- intermem:ba1c1b85 -->
- LongCodeZip: ASE 2025 <!-- intermem:c38b5039 -->
- DAST: ACL 2025 <!-- intermem:11f20db0 -->
- Prompt Compression Survey: NAACL 2025 Oral <!-- intermem:1adb62b6 -->
- ContextEvolve: arxiv 2602.02597 (Feb 2026) <!-- intermem:7e1f3e30 -->
- Kimi-Dev: SWE-Agent skill priors (60.4% SWE-bench Verified) <!-- intermem:60e16ee9 -->
