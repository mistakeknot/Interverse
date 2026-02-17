# Intermap Extraction Plan — Correctness Review
**Reviewer:** Julik (flux-drive correctness)
**Date:** 2026-02-16
**Plan:** `/root/projects/Interverse/docs/plans/2026-02-16-intermap-extraction.md`
**PRD:** `/root/projects/Interverse/docs/prds/2026-02-16-intermap-extraction.md`

## Executive Summary

The plan correctly replicates the interlock Go MCP pattern and accurately describes the intermute HTTP integration. However, there are **three critical correctness failures** in the Python dependency resolution strategy that will cause import errors, runtime failures, and silent data corruption at module boundaries.

**Verdict:** BLOCK until dependency resolution is corrected. The Go scaffold is sound; the Python extraction strategy is broken.

---

## Finding 1: CRITICAL — analysis.py lazy imports misrepresented

**Location:** Plan Task 2.5 (Move analysis.py)

**Claim in plan:**
> "Lazy `from .api import build_project_call_graph` → replace with `from .cross_file_calls import build_project_call_graph`"

**Reality from codebase:**
```python
# analysis.py line 382, 403, 428 — THREE lazy import sites
from .api import build_project_call_graph
from .api import build_project_call_graph, get_code_structure
```

**Failure mode:**
- `analysis.py` imports `build_project_call_graph` from `api.py`, which is a **re-export wrapper** (see `/root/projects/Interverse/plugins/tldr-swinton/src/tldr_swinton/modules/core/api.py` line 79-80)
- `api.py` line 79: `from .cross_file_calls import build_project_call_graph` — this is the actual source
- The plan says "replace with `from .cross_file_calls import ...`" — this is correct for `build_project_call_graph` BUT
- `dead_code_analysis()` (line 403) also imports `get_code_structure` from `.api` — **this is NOT from cross_file_calls**
- `get_code_structure` lives in a different tldr-swinton module and is NOT moving to intermap

**Consequence:**
- If you naively replace the imports as written, `dead_code_analysis()` will fail at runtime with `ImportError: cannot import name 'get_code_structure'`
- This is a **silent corruption risk** — the code will compile, tests may pass if they don't exercise `dead_code_analysis`, but production use will crash

**Corrective action:**
Task 2.5 must distinguish between the two import sources:
- `build_project_call_graph` → direct import from `.cross_file_calls` (correct)
- `get_code_structure` → either (a) vendor the implementation from api.py, or (b) make `dead_code_analysis()` callable with a pre-computed structure argument so the caller provides it

The plan does not acknowledge this split and will produce broken code.

---

## Finding 2: CRITICAL — project_index.py dependency surface underestimated

**Location:** Plan Task 2.6 (Move project_index.py), PRD dependency table

**Claim in PRD:**
> "project_index.py depends on: ast_cache (get/put), hybrid_extractor (extract), FunctionInfo (type), cross_file_calls, workspace"

**Reality from codebase:**
```python
# project_index.py imports (line 17-21):
from .ast_cache import ASTCache
from .ast_extractor import FunctionInfo
from .cross_file_calls import build_project_call_graph
from .hybrid_extractor import HybridExtractor
from .workspace import iter_workspace_files
```

**Unstated dependencies:**
- `iter_workspace_files` is imported from workspace.py — the plan says workspace.py will be vendored, so this is covered
- BUT: `ASTCache` is not just a "simple dict-based file cache" — it's a **persistent SQLite-backed cache** with schema, migrations, and mtime tracking
- The plan says "replace `ASTCache` with simple dict-based file cache" — this is a **behavioral change**, not a dependency resolution

**From `/root/projects/Interverse/plugins/tldr-swinton/src/tldr_swinton/modules/core/ast_cache.py`:**
- ASTCache uses `stacked_db.py` (SQLite storage layer)
- Tracks file mtimes, caches parsed AST data, handles schema versioning
- **NOT** a simple `dict[(path, mtime), dict]` as the plan claims

**Failure mode:**
- If you replace ASTCache with a naive dict, you lose persistence across subprocess invocations
- The plan says "one-shot subprocess" so "no persistence across calls" — this is **intentional data loss**
- BUT: the PRD performance budget says "1-3s for cached results (mtime check only)" — how do you mtime-check with no persistence?
- **Contradiction:** Plan says "Go-side caching" but Python side needs mtime data to know what changed

**Race condition risk:**
- Go-side cache keys on `source_mtime_hash` (plan Task 1.3)
- Python side has no mtime cache → must `os.stat()` every file on every call
- If source file is written between Go's mtime check and Python's parse, you get stale data served from Go cache

**Corrective action:**
Either:
1. Vendor `ASTCache` + `stacked_db` (adds ~15 KB, pulls in SQLite dep) and accept persistent state
2. OR: Make Python side stateless, Go side does all mtime tracking, and pass `changed_files: []` as argument so Python only parses what Go says is dirty
3. OR: Accept cold-start latency on every call (10-30s) and remove "cached" from performance budget

The plan tries to have both persistence and statelessness, which is incoherent.

---

## Finding 3: HIGH — change_impact.py import rewrites incomplete

**Location:** Plan Task 2.7 (Move change_impact.py)

**Claim in plan:**
> "`from .api import extract_file, get_imports, scan_project_files` → reimplement: ~30 lines tree-sitter parse + ~10 lines glob"

**Reality from codebase:**
```python
# change_impact.py line 14:
from .api import extract_file, get_imports, scan_project_files
```

**What api.py actually exports:**
- `extract_file` → wraps `ast_extractor._extract_file_impl` (line 27) — full AST parse with function signatures, classes, imports, complexity
- `get_imports` → tree-sitter parse for import statements (this is indeed ~30 lines)
- `scan_project_files` → walks workspace with `.tldrsignore` filtering and language detection (NOT just `glob.glob("**/*.py")`)

**Failure mode:**
- Plan says "reimplement `scan_project_files` as ~10 lines glob" — this is **wrong**
- The real implementation:
  - Respects `.tldrsignore` (gitignore-style exclusions)
  - Detects language from file extensions and magic comments
  - Filters test files vs source files
  - Handles symlinks and permission errors gracefully
- A naive `glob.glob("**/*.py", recursive=True)` will:
  - Parse vendored dependencies (false positives in call graph)
  - Parse test fixtures (noise in dead code analysis)
  - Fail on permission errors in venv dirs
  - Miss language boundary files (e.g., Cython .pyx)

**Consequence:**
- `change_impact.py` will produce incorrect results (false positives in affected tests, missing real dependencies)
- This is a **correctness failure**, not just performance — the tool will give wrong answers

**Corrective action:**
Task 2.7 must either:
1. Vendor the full `scan_project_files` implementation (pulls in `workspace.py` dependency — already vendored, so this works)
2. OR: Reimplement with `.tldrsignore` support and language detection (more than 10 lines, needs testing)
3. OR: Accept degraded correctness and document the limitation in tool descriptions

The plan assumes the simple case and will ship broken behavior.

---

## Finding 4: MEDIUM — intermute API integration correct but incomplete

**Location:** Plan Module 4 (Agent Overlay), Task 4.1-4.2

**Claim in plan:**
> "Call `intermuteClient.ListAgents()` to get agents" (Task 4.2)

**Reality from codebase:**

**interlock client.go pattern (line 102-107):**
```go
type Agent struct {
    AgentID string `json:"agent_id"`
    Name    string `json:"name"`
    Project string `json:"project"`
    Status  string `json:"status"`
}
```

**intermute handlers_agents.go response (line 35-45):**
```go
type agentJSON struct {
    AgentID      string            `json:"agent_id"`
    SessionID    string            `json:"session_id"`
    Name         string            `json:"name"`
    Project      string            `json:"project"`
    Capabilities []string          `json:"capabilities"`
    Metadata     map[string]string `json:"metadata"`
    Status       string            `json:"status"`
    LastSeen     string            `json:"last_seen"`
    CreatedAt    string            `json:"created_at"`
}
```

**Discrepancy:**
- interlock's `Agent` struct is a **subset** of intermute's `agentJSON`
- Missing fields: `SessionID`, `Capabilities`, `Metadata`, `LastSeen`, `CreatedAt`
- This is fine for interlock's use case (it only needs name/status for reservation conflict resolution)
- BUT: intermap's "agent overlay" feature (PRD F5) promises "which agents are working there, their status, **files being edited**"

**Failure mode:**
- Files being edited are NOT in the `/api/agents` response — they're in the **reservations** data
- To show "files being edited", `agent_map` must also call `/api/reservations?project=X` and join on agent_id
- The plan says "call ListAgents()" but does NOT mention calling ListReservations or joining the data

**Consequence:**
- The agent overlay will show "agent X is active in project Y" but NOT "agent X is editing file Z"
- This is **incomplete per the PRD spec** — the PRD promises file-level visibility, the plan delivers agent-level visibility only

**Corrective action:**
Task 4.2 must add:
1. `client.ListReservations(project)` call (already exists in interlock client, just needs to be exposed)
2. Join logic: `for each agent, find their reservations, add {files: [patterns]}` to the agent record
3. Update the agent_map tool schema to include a `files` array

This is not a blocker (the feature works without it, just less useful), but it's a PRD-plan mismatch.

---

## Finding 5: LOW — interlock pattern replication mostly correct

**Location:** Plan Module 1 (Go MCP Scaffold)

**Checked against:** `/root/projects/Interverse/plugins/interlock/cmd/interlock-mcp/main.go`

**Correctness:**
- Plan Task 1.1 structure matches interlock: `cmd/`, `internal/`, `bin/launch-mcp.sh` — CORRECT
- Plan line 41-42: "`server.NewMCPServer`, `tools.RegisterAll`, `server.ServeStdio`" — matches interlock main.go lines 23-33 — CORRECT
- Plan Task 1.4: MCP tool registration pattern matches interlock's `tools.RegisterAll()` (interlock/internal/tools/tools.go line 26-41) — CORRECT

**Minor discrepancy:**
- interlock uses `client.NewClient(opts...)` pattern with functional options (line 15-21)
- Plan Task 4.1 describes `NewIntermuteClient(baseURL string)` — **inconsistent signature**
- Should be `NewClient(opts...)` with `WithBaseURL(url)` option for consistency

**Corrective action:**
Task 4.1: Use the same functional options pattern as interlock (`WithSocketPath`, `WithBaseURL`). This is a style issue, not a blocker, but inconsistency will confuse maintainers.

---

## Finding 6: LOW — Go cache design has mtime race window

**Location:** Plan Task 1.3 (Go-side result cache)

**Cache key (line 72):**
```
mtimeHash string  // hash of all relevant file mtimes
```

**Invalidation claim (Plan Module 2, line 185-188):**
> "Key: `(command, project_path, source_mtime_hash)`
> Invalidation: any source file mtime change (checked via Go's os.Stat)"

**Race scenario:**
1. Go checks mtime of `project/file.py` → 1000
2. Go computes mtimeHash → `abc123`
3. Go checks cache with key `(arch, project, abc123)` → miss
4. Go spawns Python subprocess
5. **User edits `project/file.py`** (mtime now 1001)
6. Python subprocess parses the NEW version of the file
7. Go caches result with key `abc123` (based on OLD mtime)
8. Next call: mtime still 1001, Go computes `abc123` (because it re-stats before the edit completed), serves stale cached result

**Failure mode:**
- This is a classic TOCTOU (time-of-check-time-of-use) race
- Window is small (milliseconds between stat and subprocess fork) but non-zero
- In practice: harmless on human timescales (editors don't save mid-second), but dangerous if intermap is called in a tight loop (e.g., file watcher)

**Corrective action:**
Task 1.3 cache design should:
1. Stat all files AFTER Python subprocess returns (not before)
2. Cache with the post-parse mtimes, not the pre-parse mtimes
3. If any mtime changed during parse, discard the result and return "file changed during analysis" error

Alternatively: Accept the race and document "results may be stale if files modified during analysis" — this is probably fine for v0.1.

---

## Summary of Blockers

| # | Severity | Finding | Fix Effort |
|---|----------|---------|------------|
| 1 | CRITICAL | analysis.py imports `get_code_structure` from api.py, not cross_file_calls — will crash at runtime | 30 min (vendor or stub) |
| 2 | CRITICAL | ASTCache replacement contradicts performance budget — plan claims both persistence and statelessness | 2 hr (design decision) |
| 3 | HIGH | scan_project_files naive glob will produce wrong results (false positives in call graphs) | 1 hr (vendor real impl) |
| 4 | MEDIUM | agent_map missing file reservation join — incomplete per PRD | 1 hr (add join logic) |
| 5 | LOW | Inconsistent client constructor pattern vs interlock | 15 min (refactor) |
| 6 | LOW | Mtime TOCTOU race in Go cache | 30 min (stat after parse) |

**Recommendation:**
- Fix findings 1, 2, 3 before starting implementation (these are plan-level errors, not code bugs)
- Findings 4, 5, 6 can be deferred to post-v0.1 if time is tight

---

## Invariants to Preserve

**Data integrity:**
1. **Call graph correctness:** Moving cross_file_calls.py must not change its output for the same input (no silent behavior changes)
2. **Import resolution:** All `from .X import Y` statements must resolve after the move (no runtime ImportErrors)
3. **Cache consistency:** mtime-based invalidation must never serve results from a file that was modified AFTER the cached parse

**Concurrency (deferred to v0.2, but note for later):**
- If Python daemon mode is added, the cache becomes shared mutable state across concurrent tool calls
- Need synchronization on cache updates (or per-project cache partitions)

**Failure transparency:**
- Plan says "error protocol: Python errors as JSON on stderr" — this is good
- BUT: Must handle Python process crash (e.g., OOM, segfault in tree-sitter) — Go should detect non-zero exit + missing JSON and return "analysis failed, check logs"

---

## Files Reviewed

| Path | Lines Checked | Findings |
|------|--------------|----------|
| `/root/projects/Interverse/docs/plans/2026-02-16-intermap-extraction.md` | Full file (371 lines) | Findings 1-6 |
| `/root/projects/Interverse/docs/prds/2026-02-16-intermap-extraction.md` | Full file (224 lines) | Finding 2 (dependency table) |
| `/root/projects/Interverse/plugins/interlock/cmd/interlock-mcp/main.go` | Lines 1-80 | Finding 5 (pattern replication) |
| `/root/projects/Interverse/plugins/interlock/internal/client/client.go` | Lines 1-150 | Finding 5 (client pattern) |
| `/root/projects/Interverse/plugins/tldr-swinton/src/tldr_swinton/modules/core/diagnostics.py` | Import lines 23-28 | Zero internal deps (CORRECT) |
| `/root/projects/Interverse/plugins/tldr-swinton/src/tldr_swinton/modules/core/cross_file_calls.py` | Import lines 17-25 | Only workspace.py dep (CORRECT) |
| `/root/projects/Interverse/plugins/tldr-swinton/src/tldr_swinton/modules/core/durability.py` | Import lines 11-20 | Only cross_file_calls dep (CORRECT) |
| `/root/projects/Interverse/plugins/tldr-swinton/src/tldr_swinton/modules/core/analysis.py` | Lines 1-60, grep for lazy imports | Finding 1 (get_code_structure missing) |
| `/root/projects/Interverse/plugins/tldr-swinton/src/tldr_swinton/modules/core/project_index.py` | Import lines 17-21 | Finding 2 (ASTCache underestimated) |
| `/root/projects/Interverse/plugins/tldr-swinton/src/tldr_swinton/modules/core/change_impact.py` | Import lines 13-15 | Finding 3 (scan_project_files wrong) |
| `/root/projects/Interverse/plugins/tldr-swinton/src/tldr_swinton/modules/core/workspace.py` | Grep for internal imports | Zero deps (CORRECT, vendoring safe) |
| `/root/projects/Interverse/plugins/tldr-swinton/src/tldr_swinton/modules/core/dirty_flag.py` | Grep for internal imports | Zero deps (CORRECT, vendoring safe) |
| `/root/projects/Interverse/plugins/tldr-swinton/src/tldr_swinton/modules/core/api.py` | Lines 1-80 | Finding 1 (re-export wrapper for get_code_structure) |
| `/root/projects/Interverse/services/intermute/AGENTS.md` | Lines 1-100 | Finding 4 (API endpoint verification) |
| `/root/projects/Interverse/services/intermute/internal/http/handlers_agents.go` | Lines 1-80 | Finding 4 (response schema mismatch) |

---

**Next step:** Revise plan tasks 2.5, 2.6, 2.7 to address findings 1-3 before implementation begins.
