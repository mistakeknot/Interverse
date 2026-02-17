# PRD: Intermap — Project-Level Code Mapping
**Bead:** iv-aose

## Problem

Claude Code agents working across multi-project workspaces have no central project registry. To answer "which projects exist?" or "which project owns this file?", agents must trial-and-error through directory listings. There is no cross-project dependency mapping and no way to overlay agent activity onto a project map.

Separately, tldr-swinton conflates two concerns: file/symbol-level context (its core identity) and project-level architecture analysis (call graphs, dead code, impact analysis). The 6 project-level tools (`arch`, `calls`, `dead`, `impact`, `change_impact`, `diagnostics`) operate on different data structures (call graphs, project indexes) than the file-level tools (AST nodes, context packs). Extracting them would sharpen both plugins' identities and allow project-level analysis to evolve independently.

**Evidence supporting extraction:**
- The 6 project-level modules (209 KB) have minimal coupling to tldr-swinton internals — dependency analysis shows only shallow wrapper calls, not deep integration
- `diagnostics.py` has zero internal imports; `durability.py` depends only on `cross_file_calls`; `analysis.py` uses only lazy imports
- The natural seam exists: project-level modules depend on `workspace.py` (9 KB, standalone) and `cross_file_calls.py` (119 KB, depends only on workspace)
- `project_index.py` and `change_impact.py` have shallow adapter-layer dependencies (single-method calls) that can be resolved with protocol interfaces

## Solution

Extract project-level analysis into a new **intermap** plugin (Go MCP server + Python subprocess), add a project registry and agent overlay, and leave tldr-swinton focused on file/symbol-level context.

## Features

### F1: Go MCP Scaffold + Python Subprocess Bridge
**What:** Create the intermap plugin with a Go MCP server that invokes Python analysis code via subprocess.
**Acceptance criteria:**
- [ ] Go binary compiles and serves MCP tools via stdio
- [ ] `bin/launch-mcp.sh` auto-builds binary (follows interlock pattern)
- [ ] Python subprocess bridge: Go calls `python3 -m intermap.analyze --command=X --project=Y` and parses JSON stdout
- [ ] Error protocol: Python errors serialized as `{"error": "<type>", "message": "<msg>", "traceback": "<trace>"}` on stderr; Go parses and translates to MCP tool errors with actionable messages
- [ ] Go-side result cache: call graph results cached in memory with file mtime invalidation + manual `refresh` parameter on tools
- [ ] `plugin.json` manifest with MCP server configuration
- [ ] CLAUDE.md and AGENTS.md documentation

**Performance budget:** One-shot Python subprocess. Expected latency: 1-3s for cached results (mtime check only), 10-30s for cold call graph build on 500+ file projects. Cache invalidates when any source file mtime changes. v0.2 may introduce a persistent Python daemon if latency proves problematic.

### F2: Extract Python Modules from tldr-swinton
**What:** Move 6 Python modules (~209 KB) from tldr-swinton into intermap's Python package, resolving import dependencies via adapter interfaces.

**Dependency resolution strategy:**

| Module | Dependencies | Resolution |
|--------|-------------|------------|
| `cross_file_calls.py` (119 KB) | `workspace.py` | Vendor workspace.py verbatim (9 KB, zero internal deps) |
| `analysis.py` (13 KB) | `cross_file_calls` (lazy), `api.build_project_call_graph` (lazy) | Move with cross_file_calls; replace `api` lazy import with direct call to intermap's own `cross_file_calls.build_project_call_graph` |
| `project_index.py` (13 KB) | `ast_cache` (get/put), `hybrid_extractor` (extract), `FunctionInfo` (type), `cross_file_calls`, `workspace` | Define `FileExtractor` protocol with one method: `extract(path) -> dict`. Implement via subprocess call to tldr-swinton's `extract` MCP tool (graceful fallback to basic tree-sitter parse if tldr-swinton unavailable). `ASTCache` replaced with simple dict-based file cache. |
| `change_impact.py` (12 KB) | `analysis.analyze_impact`, `api.extract_file/get_imports/scan_project_files`, `dirty_flag.get_dirty_files` | `analysis` moves with it. `extract_file` → FileExtractor protocol. `get_imports/scan_project_files` → reimplemented (30 lines each, just tree-sitter parse + glob). `dirty_flag` → vendored verbatim (zero internal deps, stdlib only). |
| `diagnostics.py` (40 KB) | None | Clean move, no changes needed |
| `durability.py` (12 KB) | `cross_file_calls.ProjectCallGraph` | Moves with cross_file_calls |

**Acceptance criteria:**
- [ ] All 6 modules moved with dependencies resolved per table above
- [ ] `workspace.py` vendored verbatim with source attribution comment and version tag
- [ ] `dirty_flag.py` vendored verbatim with source attribution comment
- [ ] `FileExtractor` protocol defined; default implementation uses tree-sitter directly
- [ ] `python3 -c "import intermap.analyze"` succeeds without tldr-swinton installed
- [ ] `python3 -c "import intermap.analyze"` succeeds WITH tldr-swinton installed (no conflicts)
- [ ] `uv run pytest` passes on intermap's test suite

### F3: Remove Moved Tools from tldr-swinton + Migration Layer
**What:** Remove the 6 MCP tools from tldr-swinton's MCP server, add deprecation shims, and update agent-facing references.

**Migration plan:**

| Phase | tldr-swinton version | Behavior |
|-------|---------------------|----------|
| **Phase A** (this release) | v0.7.0 | Tools removed from MCP server. Deprecation note in SessionStart hook output: "Project-level tools (arch, calls, dead, impact, change_impact, diagnostics) have moved to intermap." |
| **Phase B** (1 release later) | v0.7.1+ | Remove deprecation note. Clean state. |

**Acceptance criteria:**
- [ ] Tools removed from `mcp_server.py` and daemon command handlers
- [ ] Dead imports cleaned up across tldr-swinton
- [ ] `uv run pytest` passes on tldr-swinton after removal
- [ ] tldr-swinton MCP server starts without errors after removal
- [ ] SessionStart hook output includes deprecation notice directing to intermap
- [ ] No references to moved modules remain in tldr-swinton (except deprecation notice)
- [ ] Skills that previously triggered these tools updated to reference intermap

### F4: Project Registry + Path Resolver
**What:** Go-native project discovery that catalogs all projects in a workspace and resolves any path to its owning project.

**Scope:** Workspace-local. Scans directories under the CWD (or configured workspace root). Does NOT scan the entire filesystem.

**Monorepo handling:** Each `.git` directory defines a project boundary. For Interverse (23 `.git` dirs), `project_registry` returns 23 projects, each with their own name/path/language. The Interverse root directory is NOT a project (it has no `.git` of its own). Projects are grouped by parent directory (hub/, plugins/, services/).

**Metadata schema (v0.1):**
```json
{
  "name": "interlock",
  "path": "/root/projects/Interverse/plugins/interlock",
  "language": "go",
  "group": "plugins",
  "git_branch": "main"
}
```
- `language`: Detected by presence of `go.mod` (go), `pyproject.toml` (python), `package.json` (typescript), `Cargo.toml` (rust). Multi-language projects get the primary language (first match).
- `group`: Parent directory name within workspace (hub, plugins, services, infra).

**Cache invalidation:**
- Default TTL: 5 minutes
- mtime-based: watches `.git/HEAD` files for branch changes, directory mtime for new/deleted projects
- Manual refresh: `refresh: true` parameter forces re-scan
- `resolve_project` uses the registry cache — no separate cache

**Acceptance criteria:**
- [ ] `project_registry` MCP tool: returns all git repos under workspace root
- [ ] `resolve_project` MCP tool: given a file path, returns the owning project (walks up to .git root)
- [ ] Cache uses mtime + TTL with manual refresh parameter
- [ ] Handles Interverse monorepo structure (23 projects across hub/, plugins/, services/)
- [ ] Works without Python — pure Go implementation
- [ ] Returns empty list (not error) for non-workspace directories

### F5: Agent Overlay (intermute Direct Integration)
**What:** Enrich project map with live agent activity data from intermute's HTTP API directly (no MCP-to-MCP calls).

**Integration pattern:** intermap queries intermute's REST API (`GET /api/agents`) directly, same pattern as interlock. Eliminates the 3-hop MCP chain.

**Discovery:** intermap reads `INTERMUTE_URL` environment variable (same as interlock). If unset or unreachable, agent overlay returns empty data.

**Degraded output:**
```json
{
  "name": "interlock",
  "path": "/root/projects/Interverse/plugins/interlock",
  "language": "go",
  "agents": [],
  "agents_available": false,
  "agents_error": "intermute unreachable"
}
```
- `agents_available: false` tells the agent that absence of data is due to service unavailability, not absence of agents
- `agents_error` provides troubleshooting context

**Acceptance criteria:**
- [ ] `agent_map` MCP tool: combines project registry with intermute HTTP API data
- [ ] Returns per-project: which agents are working there, their status, files being edited
- [ ] Queries intermute HTTP API directly (no MCP-to-MCP calls)
- [ ] Graceful degradation with `agents_available` and `agents_error` fields
- [ ] No hard dependency on intermute — intermap works standalone

### F6: Marketplace + Plugin Packaging
**What:** Package intermap for the interagency marketplace and update ecosystem references.
**Acceptance criteria:**
- [ ] Added to `marketplace.json` in interagency-marketplace
- [ ] `scripts/bump-version.sh` wrapper for interbump
- [ ] Interverse CLAUDE.md updated with intermap in structure listing
- [ ] hooks/hooks.json with SessionStart hook providing project summary
- [ ] Skills directory with `/intermap:status` skill (trigger: "explore project structure", "what projects exist", "project map")
- [ ] Skill trigger conditions documented in AGENTS.md

## Non-goals
- Cognition-style task-prompted codemaps (v0.2)
- Replacing tldr-swinton's file-level tools (extract, context, structure, diff_context)
- Moving flow analysis (CFG/DFG/PDG) — these are function-level, not project-level
- Moving semantic search — already isolated in its own module
- Building a visualization/UI layer
- Multi-language call graph support beyond Python + Go in v0.1 (TypeScript/Rust deferred to v0.2; `project_registry` returns all languages, but `arch`/`calls` only analyze Python/Go)

## Dependencies
- `github.com/mark3labs/mcp-go` — Go MCP SDK (same as intermux/interlock)
- Python 3.x with tree-sitter (for cross_file_calls AST parsing)
- intermute service (optional, for agent overlay — HTTP API, not MCP)
- tldr-swinton must continue working after extraction (F3 is the critical path)

## Resolved Design Decisions

### 1. workspace.py: Vendor verbatim
Copy `workspace.py` (9 KB, 200 lines, zero internal deps) into intermap's Python package. Add source attribution comment with version hash. CI check diffs vendored copy against original and warns on divergence.

**Rationale:** It's already minimal. A "reimplementation" risks behavioral drift. A shared library adds a third package to maintain — overkill for 200 lines.

### 2. project_index.py dependencies: FileExtractor protocol
Define a `FileExtractor` protocol:
```python
class FileExtractor(Protocol):
    def extract(self, path: str) -> dict:
        """Return {functions: [...], classes: [...], imports: [...]}"""
        ...
```
Default implementation uses tree-sitter directly (basic AST parse, ~50 lines). Optional enhanced implementation calls tldr-swinton's `extract` MCP tool for richer results.

`ASTCache` replaced with a simple `dict[str, dict]` keyed by `(path, mtime)`. No persistence across calls (one-shot model).

**Rationale:** project_index.py only calls `extractor.extract(path)`, `cache.get(path)`, `cache.put(path, info)`, and uses `FunctionInfo` as a data container. The 300+ KB dependency chain is a red herring — the actual interface surface is 3 methods and 1 type.

### 3. Python subprocess model: One-shot with Go-side caching
One-shot subprocess calls for v0.1. The Go MCP server caches Python results in memory:
- Key: `(command, project_path, source_mtime_hash)`
- TTL: 5 minutes
- Invalidation: any source file mtime change (checked via Go's os.Stat)
- Manual refresh: `refresh: true` parameter on all tools

Expected performance: 1-3s cached (Go mtime check), 10-30s cold (Python subprocess + tree-sitter parse). If latency proves problematic after real-world usage, v0.2 introduces a persistent Python daemon.

**Rationale:** One-shot is simpler to deploy (no daemon lifecycle), debug (each call is independent), and test (no shared state). The Go-side cache eliminates repeated cold starts for the common case.

### 4. Agent overlay: Direct HTTP, not MCP-to-MCP
intermap queries intermute's REST API directly (`GET /api/agents`), same as interlock does. No MCP-to-MCP calls, no intermux middleman.

**Rationale:** MCP-to-MCP calls are untested in the ecosystem and may have stdio contention issues. Direct HTTP is proven (interlock does it), adds zero new patterns, and eliminates a dependency layer.

### 5. Multi-language scope: Python + Go for v0.1
`project_registry` returns all detected languages. Call graph tools (`arch`, `calls`, `dead`, `impact`) support Python and Go only. Other languages return a clear error: "Call graph analysis for <lang> available in v0.2."

**Rationale:** Interverse is 19 Python projects and 2 Go services. TypeScript (1 project) and Rust (0 projects) support has no immediate demand.

## Success Metrics

| Metric | Target | Measurement |
|--------|--------|-------------|
| **Adoption** | All agents with tldr-swinton also have intermap within 2 weeks | Check `installed_plugins.json` across active sessions |
| **Tool usage** | `project_registry` called 5+ times per multi-project session | MCP tool invocation logs |
| **Migration pain** | Zero "command not found" errors for removed tools | SessionStart deprecation notice effectiveness |
| **Performance** | < 3s for cached tool calls, < 30s for cold call graph on 500-file project | Time measurements in Go MCP server |
| **Abort criterion** | If adoption < 50% after 1 month, evaluate whether to revert extraction and add F4/F5 to tldr-swinton instead |

## Risk Mitigation

| Risk | Mitigation |
|------|-----------|
| Breaking tldr-swinton consumers during extraction | Deprecation notice in SessionStart hook; update all skill/agent references atomically |
| Python import chain pulls in too much of tldr-swinton | FileExtractor protocol provides clean boundary; CI checks `import intermap.analyze` without tldr-swinton |
| Two MCP servers for one logical domain confuses agents | Clear tool descriptions: intermap = project-level (call graphs, registry), tldr-swinton = file-level (context, extract, structure). Skill trigger conditions are explicit. |
| Performance regression from subprocess overhead | Go-side mtime cache eliminates repeated cold starts; v0.2 daemon if needed |
| Vendored workspace.py drifts from original | CI check diffs vendored copy against tldr-swinton source |
