# Plan: Intermap — Project-Level Code Mapping Extraction
**Bead:** iv-aose
**Phase:** plan-reviewed (as of 2026-02-17T00:15:13Z)
**PRD:** `docs/prds/2026-02-16-intermap-extraction.md`
**Date:** 2026-02-16

## Implementation Order

Features are ordered by dependency chain: F1 (scaffold) → F4 (registry, pure Go) → F2 (Python extraction) → F3 (tldr-swinton cleanup) → F5 (agent overlay) → F6 (packaging). F4 comes before F2 because it validates the Go MCP pattern with zero Python risk.

## Module 1: Go MCP Scaffold (F1 + F4)

### Task 1.1: Create plugin directory structure
Create `plugins/intermap/` following the interlock pattern.

```
plugins/intermap/
├── .claude-plugin/
│   └── plugin.json
├── .git/               (git init)
├── bin/
│   └── launch-mcp.sh
├── cmd/
│   └── intermap-mcp/
│       └── main.go
├── internal/
│   ├── cache/
│   │   └── cache.go
│   ├── registry/
│   │   └── registry.go
│   └── tools/
│       └── tools.go
├── go.mod
├── CLAUDE.md
└── AGENTS.md
```

**Files to create:**
- `go.mod` — module `github.com/mistakeknot/intermap`, require `github.com/mark3labs/mcp-go`
- `bin/launch-mcp.sh` — copy from interlock, change binary name to `intermap-mcp`
- `cmd/intermap-mcp/main.go` — MCP server entry point (follows interlock pattern: `server.NewMCPServer`, `tools.RegisterAll`, `server.ServeStdio`)
- `.claude-plugin/plugin.json` — MCP server config pointing to `bin/launch-mcp.sh`

**Verify:** `go build ./cmd/intermap-mcp/` compiles successfully.

### Task 1.2: Implement project registry (F4)
Pure Go implementation in `internal/registry/registry.go`.

**Functions:**
- `Scan(root string) ([]Project, error)` — walk directories, find `.git` dirs, build project list
- `Resolve(path string) (*Project, error)` — walk up from path to find nearest `.git` parent
- `Project` struct: `Name, Path, Language, Group, GitBranch string`

**Language detection:** Check for `go.mod` → "go", `pyproject.toml` → "python", `package.json` → "typescript", `Cargo.toml` → "rust". First match wins.

**Group detection:** Extract parent directory name relative to workspace root. `plugins/interlock` → group "plugins".

**Git branch:** Read `.git/HEAD` → parse `ref: refs/heads/<branch>`.

### Task 1.3: Implement Go-side result cache
`internal/cache/cache.go` — generic mtime-based cache.

```go
type Cache[T any] struct {
    entries map[string]entry[T]
    ttl     time.Duration
    maxSize int  // LRU eviction after N entries (default: 10)
}

type entry[T any] struct {
    value     T
    cachedAt  time.Time
    mtimeHash string  // sha256 of sorted [(abs_path, mtime)] for all project files
    lastUsed  time.Time
}
```

**Methods:**
- `Get(key string, mtimeHash string) (T, bool)` — return cached if key matches, mtime matches, and not expired
- `Put(key string, mtimeHash string, value T)` — evict LRU entry if at capacity
- `Invalidate(key string)`
- `MtimeHash(projectPath string) (string, error)` — walk project source files, stat each, return `sha256(sorted([(abs_path, mtime)]))`

**Requirements:**
- All cache keys use **absolute paths** (`filepath.Abs(project)`) to prevent collision between agents in different CWDs
- LRU eviction after 10 entries (prevents unbounded memory growth)
- mtimeHash computed AFTER Python subprocess returns (not before) to avoid TOCTOU race

### Task 1.4: Register MCP tools for registry
`internal/tools/tools.go` — register `project_registry` and `resolve_project` tools.

**`project_registry` tool:**
- Parameters: `root` (string, optional — defaults to CWD), `refresh` (bool, optional)
- Returns: JSON array of Project objects
- Uses cache with directory mtime as key

**`resolve_project` tool:**
- Parameters: `path` (string, required)
- Returns: single Project object or error "path not within any project"
- Uses registry cache

**Verify:** Build and run manually: `echo '{"jsonrpc":"2.0","method":"tools/list","id":1}' | ./bin/intermap-mcp` returns both tools.

### Task 1.5: Write Go tests
`internal/registry/registry_test.go` — test Scan and Resolve against Interverse structure.
`internal/cache/cache_test.go` — test TTL expiry, mtime invalidation, manual refresh.

**Verify:** `go test ./...` passes.

---

## Module 2: Python Extraction (F2)

### Task 2.1: Create Python package structure
```
plugins/intermap/
├── python/
│   └── intermap/
│       ├── __init__.py
│       ├── __main__.py        (CLI entry: python3 -m intermap.analyze)
│       ├── analyze.py         (command dispatcher)
│       ├── protocols.py       (FileExtractor protocol)
│       ├── extractors.py      (default tree-sitter FileExtractor)
│       ├── file_cache.py      (simple dict-based (path,mtime) cache)
│       └── vendor/
│           ├── __init__.py
│           ├── workspace.py   (vendored from tldr-swinton)
│           └── dirty_flag.py  (vendored from tldr-swinton)
```

**`__main__.py`:** Parse `--command=X --project=Y --args=Z`, dispatch to analyze.py, print JSON to stdout, errors as JSON to stderr.

**`protocols.py`:**
```python
from typing import Protocol

class FileExtractor(Protocol):
    def extract(self, path: str) -> dict:
        """Return {functions: [...], classes: [...], imports: [...]}"""
        ...
```

**`extractors.py`:** Default `TreeSitterExtractor` that parses files using tree-sitter directly. ~50 lines. Returns basic function/class/import data.

**`file_cache.py`:** Simple `dict[tuple[str,float], dict]` keyed by `(path, mtime)`.

### Task 2.2: Vendor workspace.py and dirty_flag.py
Copy verbatim from tldr-swinton:
- `plugins/tldr-swinton/src/tldr_swinton/modules/core/workspace.py` → `python/intermap/vendor/workspace.py`
- `plugins/tldr-swinton/src/tldr_swinton/modules/core/dirty_flag.py` → `python/intermap/vendor/dirty_flag.py`

Add source attribution comment at top of each:
```python
# Vendored from tldr-swinton (plugins/tldr-swinton/src/tldr_swinton/modules/core/<name>.py)
# Version: <git hash at time of copy>
# Do not modify — update the source and re-vendor.
```

**Verify:** `python3 -c "from intermap.vendor.workspace import WorkspaceConfig"` succeeds.

### Task 2.3: Move diagnostics.py (clean, zero deps)
Copy `diagnostics.py` from tldr-swinton. Zero internal imports — only update the module path in `__init__.py`.

**Verify:** `python3 -c "from intermap.diagnostics import run_diagnostics"` (or whatever the entry function is).

### Task 2.4: Move cross_file_calls.py + durability.py
Copy both files. Update imports:
- `from .workspace import ...` → `from .vendor.workspace import ...`

durability.py imports `from .cross_file_calls import ProjectCallGraph` — this just works since both move together.

**Verify:** `python3 -c "from intermap.cross_file_calls import build_project_call_graph"` succeeds.

### Task 2.5: Move analysis.py
Copy file. Update imports — **three distinct lazy import sites** (lines ~382, ~403, ~428):
- `from .cross_file_calls import CallGraph` → already works (moved together)
- Lazy `from .api import build_project_call_graph` → replace with `from .cross_file_calls import build_project_call_graph`
- Lazy `from .api import build_project_call_graph, get_code_structure` → **`get_code_structure` is NOT in cross_file_calls**. It lives in api.py and delegates to `hybrid_extractor.extract_directory()`. Resolution: vendor a minimal `get_code_structure()` into intermap (~20 lines — it calls `FileExtractor.extract()` on each file and aggregates results into a dict).

**Create `intermap/code_structure.py`:** Reimplements `get_code_structure(project_path)` using `FileExtractor` protocol + `iter_workspace_files`. This replaces the `api.py` import without pulling in the full API facade.

**Verify:** `python3 -c "from intermap.analysis import dead_code_analysis, architecture_analysis"` succeeds (both functions use the lazy imports).

### Task 2.6: Move project_index.py (adapter layer)
Copy file. Replace imports:
- `from .ast_cache import ASTCache` → replace with `from .file_cache import FileCache`
- `from .ast_extractor import FunctionInfo` → define lightweight `FunctionInfo` dataclass in `protocols.py`
- `from .hybrid_extractor import HybridExtractor` → use `FileExtractor` protocol from `protocols.py`, inject `TreeSitterExtractor` as default
- `from .cross_file_calls import build_project_call_graph` → works (moved together)
- `from .workspace import iter_workspace_files` → `from .vendor.workspace import iter_workspace_files`

Update the `ProjectIndex.build()` method:
- Replace `ast_cache = ASTCache(project)` → `cache = FileCache()`
- Replace `extractor = HybridExtractor()` → accept `extractor: FileExtractor` as parameter (via constructor injection on `ProjectIndex.__init__`)
- Replace `info = ast_cache.get(file_path)` → `info = cache.get(file_path, os.path.getmtime(file_path))` — expect ~10-15 call sites in `build()`

**Note on ASTCache:** The original `ASTCache` is SQLite-backed (persistent across daemon calls). Since intermap uses one-shot subprocess, there is no process persistence. The Go-side cache (Task 1.3) compensates: Go tracks file mtimes and only invokes Python when something changed. Python always builds fresh from disk. The `FileCache` is just an in-process dict for deduplication within a single call (if the same file is referenced multiple times during one `build()` invocation).

**Cache coherence model:** Go computes `mtimeHash` as `sha256(sorted([(abs_path, mtime) for path in project_files]))`. Go caches the entire Python result keyed by `(command, project_path, mtimeHash)`. Python is stateless — always cold. If any source file changes, mtimeHash changes → cache miss → Python re-analyzes. mtimes are checked AFTER Python returns (not before) to avoid TOCTOU race.

**Verify:** `python3 -c "from intermap.project_index import ProjectIndex"` succeeds.

### Task 2.7: Move change_impact.py (adapter layer)
Copy file. Replace imports:
- `from .analysis import analyze_impact` → works (moved together)
- `from .api import extract_file` → use `FileExtractor` protocol
- `from .api import get_imports` → reimplement with `.tldrsignore` support: parse import statements with tree-sitter, handle `import X`, `from X import Y`, `from X import *` (Python); `import "path"` (Go). ~50 lines, not 30.
- `from .api import scan_project_files` → reimplement properly: walk workspace files using vendored `workspace.py`'s `iter_workspace_files()` (which already handles exclusion patterns), filter by language extension, handle symlinks and permission errors. NOT a naive `glob.glob`. ~30 lines.
- `from .dirty_flag import get_dirty_files` → `from .vendor.dirty_flag import get_dirty_files`

**Copy relevant test cases from tldr-swinton:** To prevent behavioral drift between old `api.get_imports` and new reimplementation, copy `test_get_imports` test cases from tldr-swinton's test suite and adapt them for intermap's implementation.

**Verify:** `python3 -c "from intermap.change_impact import find_affected_tests"` succeeds.

### Task 2.8: Wire Python subprocess bridge in Go
Update `cmd/intermap-mcp/main.go` to add Python analysis tools.

**New function in `internal/tools/`:** `pythonCall(command string, project string, args map[string]any) (map[string]any, error)`:
- Executes `python3 -m intermap.analyze --command=X --project=Y --args='{"key":"val"}'`
- Parses JSON stdout as result
- Parses JSON stderr as error (per error protocol in PRD)
- Returns structured error if Python exits non-zero

**Register 6 MCP tools:** `arch`, `calls`, `dead`, `impact`, `change_impact`, `diagnostics` — each calls `pythonCall` with appropriate command and wraps result with Go-side cache.

**Verify:** Full pipeline test: `echo '{"jsonrpc":"2.0","method":"tools/call","params":{"name":"project_registry"},"id":1}' | ./bin/intermap-mcp`

### Task 2.9: Write Python tests
Create `python/tests/` with:
- `test_imports.py` — verify all modules import without tldr-swinton
- `test_file_cache.py` — test mtime-based cache
- `test_extractors.py` — test TreeSitterExtractor on sample Python/Go files
- `test_analyze_cli.py` — test `python3 -m intermap.analyze --command=diagnostics --project=.`

**Verify:** `cd python && uv run pytest` passes. Run in isolated venv WITHOUT tldr-swinton to confirm import independence.

### Task 2.10: Integration test (Go → Python pipeline)
End-to-end test that the MCP server can invoke Python and return results.

**Test:** `echo '{"jsonrpc":"2.0","method":"tools/call","params":{"name":"arch","arguments":{"project":"."}},"id":1}' | ./bin/intermap-mcp` returns valid MCP response with Python analysis result.

Also test error protocol: invoke with a non-existent project path → verify Go returns structured MCP error (not raw Python traceback).

**Verify:** Integration test passes. This is the gate for Module 3 — do not remove tools from tldr-swinton until intermap's tools are proven working.

---

## Module 3: tldr-swinton Cleanup (F3)

### Task 3.1: Remove 6 tools from tldr-swinton MCP server
In `mcp_server.py`:
- Remove `impact_tool`, `dead_code_tool`, `arch_tool`, `calls_tool`, `diagnostics_tool`, `change_impact_tool` functions
- Remove their registrations from the tool list

In `daemon.py`:
- Remove command handlers for `impact`, `dead`, `arch`, `calls`, `diagnostics`, `change_impact`

In `cli.py`:
- Remove any CLI commands for these tools (if they exist)

### Task 3.2: Clean up dead imports
After removing tools, run through `mcp_server.py`, `daemon.py`, `api.py`:
- Remove imports of `cross_file_calls`, `analysis`, `project_index`, `change_impact`, `diagnostics`, `durability` that are no longer needed
- Keep `cross_file_calls` imports in `api.py` if other tools still use `build_project_call_graph` (check first)

### Task 3.3: Add deprecation notice to SessionStart
In the Setup hook (`hooks/setup.sh`), add output line:
```
Note: Project-level tools (arch, calls, dead, impact, change_impact, diagnostics) have moved to intermap. Install: claude plugins install intermap
```

### Task 3.4: Run tldr-swinton test suite
`cd plugins/tldr-swinton && uv run pytest`

Fix any failures caused by removed imports/tools. Expect some test files to be removed or updated for the 6 moved tools.

**Verify:** All tests pass, MCP server starts without errors.

---

## Module 4: Agent Overlay (F5)

### Task 4.1: Add intermute HTTP client
`internal/client/client.go` — lightweight HTTP client for intermute API. Follow interlock's functional options pattern for consistency.

```go
type Client struct {
    baseURL string
    http    *http.Client
}

func NewClient(opts ...Option) *Client { ... }
func WithBaseURL(url string) Option { ... }
func WithSocketPath(path string) Option { ... }
func (c *Client) ListAgents() ([]Agent, error) { ... }
func (c *Client) ListReservations(project string) ([]Reservation, error) { ... }
```

**Discovery:** Read `INTERMUTE_URL` env var. If empty, client methods return empty results + `agents_available: false`.

### Task 4.2: Register agent_map tool
`internal/tools/tools.go` — add `agent_map` tool.

**Logic:**
1. Call `registry.Scan()` to get projects
2. Call `client.ListAgents()` to get agents
3. Call `client.ListReservations(project)` for each project that has agents — join reservation data to get "files being edited"
4. For each agent, match to project via path resolution
5. Enrich project records with agent data + file patterns from reservations
6. Return combined result with `agents_available` and `agents_error` fields

**Graceful degradation:** If intermute client returns error, still return projects with empty agents and diagnostic fields.

### Task 4.3: Write agent overlay tests
Test with mock intermute responses:
- Test normal case (agents mapped to projects)
- Test degraded case (intermute unreachable)
- Test no agents case (intermute returns empty list)

**Verify:** `go test ./...` passes.

---

## Module 5: Packaging (F6)

### Task 5.1: Create plugin manifest
`.claude-plugin/plugin.json`:
```json
{
  "name": "intermap",
  "version": "0.1.0",
  "description": "Project-level code mapping: project registry, call graphs, architecture analysis, agent overlay. MCP server with 9 tools.",
  "mcpServers": {
    "intermap": {
      "type": "stdio",
      "command": "${CLAUDE_PLUGIN_ROOT}/bin/launch-mcp.sh",
      "env": {
        "INTERMUTE_URL": "http://127.0.0.1:7338",
        "PYTHONPATH": "${CLAUDE_PLUGIN_ROOT}/python"
      }
    }
  }
}
```

### Task 5.2: Create hooks and skills
- `hooks/hooks.json` — Setup hook for auto-build + optional SessionStart for project summary
- `skills/intermap-status/SKILL.md` — `/intermap:status` skill with triggers: "explore project structure", "what projects exist", "project map"

### Task 5.3: Add to marketplace
- Add intermap entry to `infra/marketplace/.claude-plugin/marketplace.json`
- Create `scripts/bump-version.sh` wrapper for interbump

### Task 5.4: Update Interverse CLAUDE.md
Add `intermap/` to the structure listing with description.

### Task 5.5: Create CLAUDE.md and AGENTS.md
- `CLAUDE.md` — quick reference (build, test, publish)
- `AGENTS.md` — full dev guide (architecture, tools, dependency resolution, vendoring)

---

## Execution Order

| # | Task | Depends on | Parallelizable with |
|---|------|-----------|-------------------|
| 1.1 | Plugin directory structure | — | — |
| 1.2 | Project registry | 1.1 | — |
| 1.3 | Result cache | 1.1 | 1.2 |
| 1.4 | Register registry tools | 1.2, 1.3 | — |
| 1.5 | Go tests | 1.4 | — |
| 2.1 | Python package structure | 1.1 | 1.2-1.5 |
| 2.2 | Vendor workspace/dirty_flag | 2.1 | — |
| 2.3 | Move diagnostics.py | 2.1 | 2.2 |
| 2.4 | Move cross_file_calls + durability | 2.2 | 2.3 |
| 2.5 | Move analysis.py + code_structure.py | 2.4 | — |
| 2.6 | Move project_index.py | 2.1, 2.4 | 2.5 |
| 2.7 | Move change_impact.py | 2.2, 2.5 | 2.6 |
| 2.8 | Wire Python subprocess in Go | 1.4, **2.7** | — |
| 2.9 | Python tests (isolated venv) | 2.7 | 2.8 |
| 2.10 | Integration test (Go→Python) | 2.8 | — |
| 3.1 | Remove tools from tldr-swinton | **2.10** | — |
| 3.2 | Clean dead imports | 3.1 | — |
| 3.3 | Add deprecation notice | 3.1 | 3.2 |
| 3.4 | Run tldr-swinton tests | 3.2, 3.3 | — |
| 4.1 | Intermute HTTP client | 1.1 | 2.x, 3.x |
| 4.2 | Register agent_map tool | 4.1, 1.4 | — |
| 4.3 | Agent overlay tests | 4.2 | — |
| 5.1 | Plugin manifest | **2.8, 4.2** | — |
| 5.2 | Hooks and skills | 5.1 | — |
| 5.3 | Add to marketplace | 5.1 | 5.2 |
| 5.4 | Update Interverse CLAUDE.md | 5.1 | 5.2, 5.3 |
| 5.5 | Create CLAUDE.md + AGENTS.md | 5.1 | 5.2-5.4 |

**Parallel dispatch opportunities:**
- Module 1 (Go scaffold + registry) can proceed immediately
- Module 2 tasks 2.1-2.3 can start in parallel with Module 1 tasks 1.2-1.5
- Module 4 (agent overlay) can be developed in parallel with Module 2 and 3
- Module 5 tasks block on 2.8 + 4.2 (all tools must be registered before manifest is finalized)

**Critical path:** 1.1 → 1.2+1.3 → 1.4 → (2.1-2.7 Python extraction) → 2.8 → 2.10 → 3.1-3.4 → 5.1-5.5

## Estimated task count: 23 tasks across 5 modules
