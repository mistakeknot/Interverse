# Brainstorm: Intermap — Project-Level Code Mapping Extracted from tldr-swinton
**Bead:** iv-aose

**Date:** 2026-02-16
**Status:** Complete
**Next:** `/clavain:strategy`

## What We're Building

**Intermap** is a Go MCP server plugin that owns project-level code analysis: call graphs, architecture detection, dead code analysis, impact analysis, diagnostics, and project registry. It extracts ~209 KB of Python modules from tldr-swinton's monolithic `core/` directory, leaving tldr-swinton focused on its core competency (file/symbol-level context, compression, and extraction).

Intermap also adds new capabilities that don't exist today:
- **Project registry** — discover and catalog all projects in a workspace
- **Cross-project dependency mapping** — which projects import/depend on each other
- **Agent overlay** — consume intermux data to show who's working where
- **CWD-to-project resolution** — resolve any filesystem path to its owning project

## Why This Approach

tldr-swinton is 1.4 MB of Python across 80+ files. The `core/` module alone is 1.1 MB. This makes it:
- Hard to reason about as a single unit
- Slow to load (all modules imported even when only using `extract`)
- Conflating two distinct concerns: file-level context (its identity) and project-level mapping (what intermap will own)

The natural seam line exists: the graph/architecture cluster (`cross_file_calls.py`, `analysis.py`, `project_index.py`, `change_impact.py`, `diagnostics.py`, `durability.py`) has minimal coupling to the extraction/context clusters. Its only internal dependency is `workspace.py` (which stays in tldr-swinton).

## Key Decisions

### 1. Language: Go MCP server + Python subprocess
Intermap is a Go binary (like intermux and interlock) that shells out to Python for the heavy analysis. The extracted Python modules live inside intermap's repo. The Go layer handles MCP protocol, project registry, agent overlay, and orchestration. The Python layer does the actual code analysis.

**Rationale:** Consistent with the intermux/interlock pattern. The Go MCP scaffold is proven. Python analysis code moves as-is without rewriting.

### 2. Clean extraction — move, don't duplicate
The six MCP tools (`arch`, `calls`, `dead`, `impact`, `change_impact`, `diagnostics`) move completely out of tldr-swinton. They are removed from its MCP server. Agents call intermap for project-level analysis.

**Rationale:** Duplication creates confusion about which plugin to call. Clean cut is cleaner than a deprecation period for an internal ecosystem.

### 3. Codemaps deferred to v0.2
The Cognition-style task-prompted codemaps feature ("show me everything relevant to adding OAuth") is explicitly out of scope for v0.1. Focus is on clean extraction + project registry + agent overlay.

**Rationale:** YAGNI. The extraction alone is a full sprint. Codemaps needs the foundation to be solid first.

### 4. Agent overlay via MCP tool calls
Intermap consumes intermux's `list_agents` tool via MCP when it needs agent location data. No tight coupling — intermap works fine without intermux installed.

**Rationale:** Loose coupling. MCP is the standard inter-plugin communication pattern. Graceful degradation if intermux isn't running.

## What Moves to Intermap

### Python modules extracted from tldr-swinton:
| Module | Size | What it does |
|--------|------|-------------|
| `cross_file_calls.py` | 119 KB | Call graph builder across files |
| `analysis.py` | 13 KB | Impact analysis, dead code, architecture layers |
| `project_index.py` | 13 KB | Unified symbol index for project-scoped engines |
| `change_impact.py` | 12 KB | Test selection based on changed files |
| `diagnostics.py` | 40 KB | Type checkers + linters (12 languages) |
| `durability.py` | 12 KB | Call graph persistence/caching |
| **Total** | **~209 KB** | |

### MCP tools that move:
| Tool | Current owner | What it does |
|------|--------------|-------------|
| `arch` | tldr-swinton | Detect architecture layers from call patterns |
| `calls` | tldr-swinton | Build full cross-file call graph |
| `dead` | tldr-swinton | Find unreachable code |
| `impact` | tldr-swinton | Reverse call graph for a function |
| `change_impact` | tldr-swinton | Find tests affected by changes |
| `diagnostics` | tldr-swinton | Run type checkers + linters |

### New capabilities intermap adds:
| Capability | Description |
|-----------|-------------|
| `project_registry` | Discover all projects in workspace, catalog metadata |
| `project_deps` | Cross-project dependency graph (which projects import which) |
| `agent_map` | Overlay intermux agent data on project map |
| `resolve_project` | CWD/path → project identification |

## What Stays in tldr-swinton

- **Extraction** (ast_extractor, hybrid_extractor, signatures) — core identity
- **Context engines** (contextpacks, compression, attention pruning) — core identity
- **Flow analysis** (CFG/DFG/PDG) — function-level, not project-level
- **Semantic search** — separate module, already isolated
- **Navigation** (tree, structure, extract, context, diff_context, distill)
- **Daemon/infra** (daemon, MCP server, API, state)
- **workspace.py** — stays as shared configuration (intermap's Python modules import it)

## Architecture

```
┌─────────────────────────────────────────────┐
│              Claude Code Agents             │
│       ┌────────┐  ┌────────┐  ┌────────┐   │
│       │ Agent A │  │ Agent B │  │ Agent C │  │
│       └───┬────┘  └───┬────┘  └───┬────┘   │
│           │ MCP tools  │           │        │
│    ┌──────┴────────────┴───────────┴──────┐ │
│    │           intermap (Go MCP)          │ │
│    │  • Project registry (Go)             │ │
│    │  • Agent overlay (Go, calls intermux)│ │
│    │  • Path resolver (Go)                │ │
│    │  • Python subprocess for analysis:   │ │
│    │    ├── cross_file_calls.py            │ │
│    │    ├── analysis.py                   │ │
│    │    ├── project_index.py              │ │
│    │    ├── change_impact.py              │ │
│    │    ├── diagnostics.py                │ │
│    │    └── durability.py                 │ │
│    └──────────────┬───────────────────────┘ │
│                   │ MCP tool call           │
│    ┌──────────────┴───────────────────────┐ │
│    │         intermux (Go MCP)            │ │
│    │  • list_agents (agent locations)     │ │
│    └──────────────────────────────────────┘ │
│    ┌──────────────────────────────────────┐ │
│    │       tldr-swinton (Python MCP)      │ │
│    │  • extract, context, structure       │ │
│    │  • diff_context, semantic, distill   │ │
│    │  • CFG/DFG/PDG (function-level)      │ │
│    └──────────────────────────────────────┘ │
└─────────────────────────────────────────────┘
```

## Interface Contract

### Python subprocess protocol
The Go binary invokes Python analysis via:
```bash
python3 -m intermap.analyze --command=<cmd> --project=<path> [--args=<json>]
```
Output: JSON to stdout. Errors: non-zero exit + stderr.

### Workspace configuration
Both intermap and tldr-swinton read `.claude/workspace.json` for project scoping. The `workspace.py` module stays in tldr-swinton. Intermap's Python modules import from a vendored copy or use a lightweight reimplementation.

### intermux integration
Intermap calls intermux's `list_agents` MCP tool (if available) and enriches its project map with agent locations. If intermux is not installed, agent overlay is simply empty.

## Open Questions

1. **workspace.py sharing** — Should intermap vendor a copy of workspace.py, or should it become a shared package (e.g., in intersearch)?
2. **Daemon migration** — The extracted Python modules currently run inside tldr-swinton's daemon. Should intermap run its own Python daemon, or use one-shot subprocess calls?
3. **ProjectIndex dependency** — `project_index.py` imports from `ast_cache`, `ast_extractor`, `hybrid_extractor`, `workspace`. Should these stay as tldr-swinton imports, or should ProjectIndex be simplified for intermap's needs?

## Risk Assessment

| Risk | Mitigation |
|------|-----------|
| Breaking tldr-swinton consumers during extraction | Remove tools atomically in one commit; update all skill/agent references |
| Python import chain pulls in too much of tldr-swinton | Audit and break dependencies; vendor minimal needed code |
| Two MCP servers for one logical domain confuses agents | Clear tool descriptions; intermap = project-level, tldr = file-level |
| Performance regression from subprocess overhead | Cache call graphs; one-shot analysis is fine for project-level queries |
