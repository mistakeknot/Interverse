# Flux-Drive Architecture Review: Intermap Extraction Plan

**Reviewer:** fd-architecture
**Date:** 2026-02-16
**Plan:** `/root/projects/Interverse/docs/plans/2026-02-16-intermap-extraction.md`
**PRD:** `/root/projects/Interverse/docs/prds/2026-02-16-intermap-extraction.md`

## PRD Feature Coverage

**F1 (Go MCP Scaffold):** Fully covered by Module 1 (Tasks 1.1-1.5).

**F2 (Extract Python modules):** Fully covered by Module 2 (Tasks 2.1-2.9).

**F3 (Remove from tldr-swinton):** Fully covered by Module 3 (Tasks 3.1-3.4).

**F4 (Project registry):** Integrated into Module 1 (Task 1.2), not isolated. Feature correctly implemented but sequencing bypasses the stated F1→F4 dependency order in the plan's intro (line 9 claims "F1→F4→F2" but execution is "F1+F4→F2").

**F5 (Agent overlay):** Fully covered by Module 4 (Tasks 4.1-4.3).

**F6 (Packaging):** Fully covered by Module 5 (Tasks 5.1-5.5).

**Gap:** None. All PRD features are addressed.

## Dependency Chain Correctness

**Intra-module dependencies:** Sound. Module 2's Python file moves follow correct import resolution order (2.2 vendors workspace → 2.4 depends on 2.2 → 2.5 depends on 2.4).

**Cross-module dependency error:** Task 2.8 (wire Python subprocess in Go) depends on Task 1.4 (register registry tools), but the plan table (line 350) shows 2.8 depending on "1.4, 2.5" with parallelization against 2.6/2.7. This is misleading — 2.8 cannot run until ALL Python modules (2.1-2.7) are moved and importable, not just 2.5. The true blocker is 2.7 (change_impact.py is the last adapter-layer file).

**Recommended fix:** Update Task 2.8 dependency from "1.4, 2.5" to "1.4, 2.7" in the execution table.

**Module 4 (agent overlay) sequencing:** Correctly marked as parallelizable with Module 2/3 (line 368). No structural dependency on Python extraction.

**Module 5 (packaging) gate:** Task 5.1 (plugin manifest) lists dependency "1.1" but should depend on completion of Modules 1-4 since the manifest declares both Go and Python MCP tools. The manifest cannot be finalized until 2.8 registers all Python tools.

**Recommended fix:** Change Task 5.1 dependency from "1.1" to "2.8, 4.2" (all tools registered).

## Adapter Layer Design

### FileExtractor Protocol

**Soundness:** Protocol approach is clean. Defining `extract(path) -> dict` with a tree-sitter default implementation resolves the `hybrid_extractor` dependency without tight coupling.

**Missing specification:** The plan does not specify the schema for the returned dict. The PRD (F2 table, line 44) shows `{functions: [...], classes: [...], imports: [...]}` but the plan never documents this. Task 2.1 should include schema definition.

**Fallback complexity:** Task 2.6 (line 185) claims "inject `TreeSitterExtractor` as default" but doesn't specify WHERE injection happens. Is this a parameter to `ProjectIndex.build()`, a module-level default, or a registry pattern? The PRD's resolution column (line 44) mentions "graceful fallback to basic tree-sitter parse if tldr-swinton unavailable" but the plan has no implementation task for this fallback logic.

**Recommended clarification:** Add explicit task or subtask: "Implement FileExtractor factory with tldr-swinton detection fallback" (checks if tldr-swinton MCP server is available, returns MCP-backed extractor if yes, tree-sitter-only if no).

### Vendoring Strategy

**workspace.py vendoring:** Clean. Zero internal dependencies confirmed (lines 11-16 of workspace.py show only stdlib imports). The version hash + CI diff check (PRD line 166) is sound but missing from the plan. Task 2.2 should add: "Record source git hash in vendored file comment."

**dirty_flag.py vendoring:** Not verified. The plan assumes zero internal deps (line 148) but does not confirm. Need to check.

**Missing: CI validation task.** PRD specifies "CI check diffs vendored copy against original and warns on divergence" (line 166). This is entirely absent from Module 2. Add Task 2.10: "Add CI check for vendored file drift."

### File Cache Replacement

**ASTCache → FileCache:** Task 2.6 (line 182) replaces `ASTCache` with a simple `dict`-based `FileCache` keyed by `(path, mtime)`. This matches PRD resolution (line 180). However, `ASTCache` in tldr-swinton provides persistence and shared state across daemon calls. The one-shot subprocess model eliminates this, but the plan doesn't state whether the Go-side cache (Task 1.3) compensates.

**Go cache scope mismatch:** Task 1.3 builds a generic `Cache[T]` with mtime invalidation (lines 63-80), but the key is a single string, not `(path, mtime)`. To cache Python analysis results per-file, the Go cache needs composite keys or a hash of all source file mtimes. Task 1.3 shows `mtimeHash string` (line 72) but doesn't specify how this is computed for a project with 500+ files.

**Recommended clarification:** Task 1.3 should specify: "mtimeHash is a hash of sorted [(path, mtime)] for all source files in the project scope." Task 2.8 should state: "Go cache key = (command, project_path, all-files-mtime-hash)."

## Go MCP Scaffold Patterns

### Comparison to Interlock

**Correct patterns adopted:**
- `cmd/interlock-mcp/main.go` structure matched (server init → tools.RegisterAll → ServeStdio) ✓
- `internal/client/client.go` for intermute HTTP client ✓
- `internal/tools/tools.go` for MCP tool registration ✓
- `bin/launch-mcp.sh` for auto-build wrapper ✓

**Missing patterns from interlock:**
- **Agent identity resolution:** interlock's `main.go` (lines 37-49) resolves agent ID from 3 env vars (`INTERLOCK_AGENT_ID`, `INTERMUTE_AGENT_ID`, `CLAUDE_SESSION_ID`) with fallback to hostname+PID. The plan's Task 2.8 (Python subprocess bridge) will pass project path but doesn't mention agent ID propagation. If intermap tools need to correlate with intermute agents (F5), the agent ID must flow from Go → Python subprocess.

**Recommended addition:** Task 2.8 should include: "Pass `INTERMUTE_AGENT_ID` or equivalent to Python subprocess via environment."

- **Project path resolution:** interlock's `getProject()` (lines 51-56) uses `INTERLOCK_PROJECT` env var with fallback to CWD basename. intermap's Task 1.2 (registry.Resolve) will do path→project mapping, but the MCP server initialization doesn't show where the default project comes from when tools are called without explicit project parameter.

**Recommended clarification:** Task 1.4 should specify default project resolution: "Tools default to CWD if project parameter is empty; use `registry.Resolve(cwd)` to find owning project."

### Python Subprocess Error Protocol

**Defined in PRD F1:** JSON stderr with `{error, message, traceback}` fields (line 28). Plan Task 2.8 implements this (lines 201-205) but doesn't specify which Python error types map to which MCP error codes (InvalidParams vs InternalError vs user-facing diagnostic). This will cause inconsistent error UX.

**Recommended addition:** Task 2.8 should include mapping table:
- `FileNotFoundError` → MCP InvalidParams ("project path not found")
- `ImportError` / `ModuleNotFoundError` → MCP InternalError ("Python environment broken")
- Analysis errors (e.g., "unsupported language") → user-facing message in tool result

## Missing Tasks

### 1. dirty_flag.py import verification

Task 2.2 assumes `dirty_flag.py` has zero internal deps but never checks. This is a hidden risk.

**New task:** Task 2.2b: "Verify dirty_flag.py dependencies (`grep '^from \.' dirty_flag.py`) — expect zero matches."

### 2. go.mod initialization

Task 1.1 lists `go.mod` creation (line 39) but doesn't specify the module path or required dependencies. Interlock uses `github.com/mistakeknot/interlock` → intermap should be `github.com/mistakeknot/intermap`.

**Clarification needed:** Task 1.1 should state: "`go.mod` with module path `github.com/mistakeknot/intermap`, require `github.com/mark3labs/mcp-go v0.10.0` (or latest)."

### 3. Python package installation

Module 2 creates a Python package but never specifies how it gets installed. Does `bin/launch-mcp.sh` add `PYTHONPATH`? Does the plugin manifest set env vars? Task 5.1 shows `PYTHONPATH: ${CLAUDE_PLUGIN_ROOT}/python` (line 309) but this assumes the Python package is importable without `pip install` / `uv pip install`.

**Missing task:** Task 2.10 (or 5.1 clarification): "Ensure `python/intermap` is importable via PYTHONPATH (no install step required) OR add setup.py/pyproject.toml + install instruction."

### 4. Python CLI argument parsing

Task 2.1 specifies `__main__.py` with `--command=X --project=Y --args=Z` (line 112) but doesn't say which parser library or how nested args are passed. The plan shows `--args='{"key":"val"}'` (line 202) suggesting JSON, but Python `argparse` doesn't natively parse JSON into a dict.

**Clarification needed:** Task 2.1 should specify: "Use `argparse` with `--args` as a string, parse JSON via `json.loads(args_str)` in `analyze.py`."

### 5. Test coverage for Python→Go bridge

Task 2.9 (Python tests) covers "all modules import without tldr-swinton" and "test `python3 -m intermap.analyze`" (lines 216-217) but doesn't test the JSON stdout/stderr protocol that Go relies on. A broken error serialization format will silently fail in production.

**Missing test:** Task 2.9 should include: "`test_error_protocol.py` — force Python errors, verify JSON stderr matches schema."

### 6. Integration test for full MCP pipeline

Module 2 ends at Task 2.9 (Python tests in isolation). Module 1 ends at Task 1.5 (Go tests in isolation). Task 2.8 wires them together but there's no end-to-end test verifying the MCP server can actually invoke Python and return results.

**Missing task:** Task 2.10 (or 3.5): "Integration test: `echo '{"jsonrpc":"2.0", "method":"tools/call", "params":{"name":"arch", "arguments":{"project":"."}}, "id":1}' | ./bin/intermap-mcp` returns valid MCP response with Python analysis result."

## Sequencing Gaps

**Critical path ambiguity:** The plan intro (line 9) claims "F4 comes before F2 because it validates the Go MCP pattern with zero Python risk." However, the execution table (line 342) shows Tasks 2.1-2.3 parallelizable with 1.2-1.5, meaning Python work starts before F4 (registry) completes. The stated rationale doesn't match actual execution order.

**Recommended fix:** Either enforce strict F1+F4 → F2 sequencing (block all Module 2 tasks until 1.5 passes), OR revise the intro justification to: "F4 integrated into F1 to prove Go-only MCP server before adding Python complexity; Python extraction begins in parallel once directory structure exists."

**tldr-swinton removal gate:** Module 3 (tldr-swinton cleanup) depends on 2.8 (Python tools registered in intermap) but the dependency table (line 351) shows 3.1 depending on 2.8 only. This is insufficient — removing tools from tldr-swinton BEFORE verifying they work in intermap risks breakage. All of Module 3 should block on Task 2.10 (integration test) once added.

**Recommended fix:** Add dependency: "3.1 depends on 2.10 (integration test)" to ensure intermap's tools are proven before tldr-swinton's are removed.

## Performance Budget Validation

**PRD spec (F1, line 33):** "1-3s cached, 10-30s cold on 500-file projects."

**Plan implementation:** Task 1.3 adds mtime-based cache with 5-minute TTL (implied from F4 PRD line 98, though not restated in plan). Task 2.8 uses this cache for Python results.

**Missing: cache key collision risk.** If two agents in different projects with the same name (e.g., both working in `interlock` directories) share the Go MCP server instance, the cache key `(command, project_path)` will collide unless `project_path` is absolute. The plan doesn't specify this.

**Recommended fix:** Task 1.3 should state: "Cache keys use absolute paths via `filepath.Abs(project)`."

**Missing: cache size limits.** A 500-file project with full call graph might produce 5-10MB of JSON. If 5 projects are cached, that's 50MB in memory. No eviction policy is specified.

**Recommended addition:** Task 1.3 should add: "LRU eviction after 10 entries OR max 100MB total, whichever comes first."

## Adapter-Layer Boundary Integrity

**project_index.py refactor (Task 2.6):** The plan states "replace `ast_cache.get(path)` with `cache.get(path, mtime)`" (line 184) but `project_index.py` currently calls `cache.get(path)` in a loop over workspace files. Changing the signature to require mtime means every call site must add `os.path.getmtime(path)`. This is not just a cache swap — it's an API change that ripples through the entire `ProjectIndex.build()` method.

**Recommended clarification:** Task 2.6 should state: "Update all `cache.get(path)` calls to `cache.get(path, os.path.getmtime(path))` — expect 10-15 call sites in ProjectIndex.build()."

**change_impact.py reimplementations (Task 2.7):** Plan claims "reimplement `get_imports` and `scan_project_files` — ~30 and ~10 lines" (lines 193-194). This assumes tree-sitter parse is trivial, but `get_imports` for Python requires distinguishing `import X`, `from X import Y`, and `from X import *` with correct module resolution. The "30 lines" estimate is optimistic.

**Risk:** Subtle behavioral drift between old api.get_imports and new reimplementation could break change_impact tests.

**Recommended mitigation:** Task 2.7 should add: "Vendored reimplementation of get_imports must match api.get_imports test cases — copy relevant tests from tldr-swinton."

## Monorepo Handling (F4)

**PRD spec (lines 81-82):** "23 projects across hub/, plugins/, services/ — registry returns 23 entries."

**Plan implementation (Task 1.2, lines 50-59):** Correct. Walks directories, finds `.git`, extracts metadata.

**Edge case not handled:** Nested `.git` directories (e.g., git submodules). If `plugins/interlock/.git` exists and `plugins/interlock/vendor/foo/.git` also exists, both will be returned as separate projects. This may be desired behavior (submodules ARE separate projects) but the plan doesn't specify.

**Recommended clarification:** Task 1.2 should state: "Nested .git directories treated as separate projects (submodule case). If this is undesired, add depth limit or .gitmodules detection."

**Group detection (line 56):** "Extract parent directory name relative to workspace root" — assumes single-level nesting (`plugins/interlock` → group "plugins"). Breaks for deeper nesting (`infra/marketplace/plugins/foo` → group is "infra" not "plugins").

**Recommended fix:** Task 1.2 should define: "Group = first directory component under workspace root. Deeper nesting uses the top-level ancestor only."

## Test Coverage Gaps

**Go tests (Task 1.5):** Cover registry and cache in isolation but no error-path tests. What happens when `.git/HEAD` is unreadable? When a project has no language markers? When mtime syscall fails?

**Recommended addition:** Task 1.5 should include: "Error-path tests for registry (unreadable .git, missing HEAD, language detection failure) and cache (mtime failure, TTL expiry edge cases)."

**Python tests (Task 2.9):** Line 216 specifies "test all modules import without tldr-swinton" but doesn't say how to enforce this. If the test env has tldr-swinton installed globally, the test passes even if imports are broken.

**Recommended fix:** Task 2.9 should specify: "Run tests in isolated venv WITHOUT tldr-swinton: `uv venv --clear && uv pip install pytest tree-sitter && uv run pytest`."

**Module 3 tests (Task 3.4):** "Fix any failures caused by removed imports/tools" (line 249) is reactive. The test suite should ALREADY have coverage for the 6 removed tools. If removing them breaks tests, those tests should be removed/updated as part of 3.1, not discovered later in 3.4.

**Recommended resequencing:** Task 3.4 should state: "Before running tests, grep test suite for references to removed tools and update/remove those tests first."

## Summary

**Blocking issues (must fix before implementation):**
1. Task 2.8 dependency correction: change "1.4, 2.5" → "1.4, 2.7"
2. Task 5.1 dependency correction: change "1.1" → "2.8, 4.2"
3. Add Task 2.10: Integration test for Go→Python MCP pipeline
4. Add missing specification for FileExtractor return schema (Task 2.1)
5. Verify dirty_flag.py has zero internal deps (new Task 2.2b)
6. Add cache size limits + absolute path requirement to Task 1.3

**Advisory improvements (recommended but not blocking):**
7. Add agent ID propagation to Python subprocess (Task 2.8)
8. Clarify FileExtractor fallback factory pattern (Task 2.6)
9. Add error-type → MCP-code mapping table (Task 2.8)
10. Add CI drift check for vendored files (new Task 2.10 or append to 2.2)
11. Specify Python CLI arg parsing implementation (Task 2.1)
12. Add error-protocol test to Python suite (Task 2.9)
13. Fix intro sequencing rationale vs actual execution order (cosmetic)
14. Add test isolation enforcement for "no tldr-swinton" tests (Task 2.9)

**Total estimated additional effort:** +3 tasks, +6 clarifications, ~8 hours additional implementation time.

**Architecture grade:** B+ (sound design with execution gaps in integration testing and dependency specification)
