# Flux-Drive Architecture Review: Intermap Extraction PRD

**Document:** `/root/projects/Interverse/docs/prds/2026-02-16-intermap-extraction.md`
**Reviewer:** Flux-Drive Architecture & Design Reviewer
**Date:** 2026-02-16

---

## Executive Summary

The PRD proposes extracting project-level analysis tools from tldr-swinton (208 KB, 6 modules) into a new intermap plugin using Go MCP + Python subprocess architecture. The extraction boundary is well-defined and addresses a legitimate concern-conflation problem. However, the design introduces structural risks around module coupling, subprocess bridge reliability, and ownership fragmentation that require resolution before implementation.

**Critical findings:**
- **Premature extraction boundary** — dependency resolution unfinished; 3 of 6 modules have unresolved import entanglements with tldr-swinton internals (ast_cache, ast_extractor, hybrid_extractor)
- **Subprocess bridge adds failure modes** — Go→Python IPC introduces serialization, error propagation, and state management complexity not present in direct module imports
- **Project registry duplicates existing patterns** — git repo discovery and path resolution already implemented in multiple places; no consolidation plan
- **Agent overlay coupling** — intermap→intermux→interlock creates a 3-hop integration chain where intermap's value depends on intermute service health

**Recommendation:** Defer extraction until dependency resolution strategy is concrete. If proceeding, start with F4 (project registry) as a standalone service to validate the Go MCP pattern before moving Python code.

---

## 1. Boundaries & Coupling

### 1.1 Module Extraction Boundary

**Finding:** The extraction selects 6 Python modules (208 KB total) based on "project-level vs file-level" separation, but 3 of the 6 have unresolved import dependencies on tldr-swinton internals that are not being extracted.

**Evidence:**
```python
# project_index.py (13 KB)
from .ast_cache import ASTCache
from .ast_extractor import FunctionInfo
from .hybrid_extractor import HybridExtractor

# cross_file_calls.py (119 KB)
from .workspace import WorkspaceConfig, load_workspace_config
# (lazy import: from .workspace import iter_workspace_files)

# change_impact.py (12 KB)
from .api import extract_file, get_imports, scan_project_files
from .dirty_flag import get_dirty_files
```

**Module dependency map:**
```
Proposed intermap modules:
├── cross_file_calls.py (119 KB) → workspace.py (9 KB, shared)
├── analysis.py (13 KB) → cross_file_calls (clean)
├── project_index.py (13 KB) → ast_cache, ast_extractor, hybrid_extractor (300+ KB, NOT moving)
├── change_impact.py (12 KB) → api.py, dirty_flag.py (NOT moving)
├── diagnostics.py (40 KB) → subprocess wrappers only (clean)
└── durability.py (12 KB) → cross_file_calls only (clean)
```

**Impact:**
- `project_index.py` is the most problematic — imports 3 heavyweight modules (300+ KB) that are core to tldr-swinton's symbol extraction. The PRD proposes "simplify ProjectIndex to not need them" (Open Question 2, option b) but provides no design for what the simplified version looks like or whether it can still serve the call graph use case.
- `change_impact.py` depends on `api.py` (tldr-swinton's public API layer) and `dirty_flag` (session-based change tracking). These are deeply integrated with tldr-swinton's daemon and cannot be vendored without breaking session state semantics.
- `workspace.py` is shared by both sides — PRD proposes vendoring a "lightweight reimplementation" but does not specify what gets cut. The existing module is only 9 KB and already lightweight.

**Recommendation:**
1. **Resolve dependencies before extraction.** Do not move modules until import boundaries are clean. Either:
   - Extract ast_cache/ast_extractor/hybrid_extractor as a shared library (makes both plugins dependent on a third module)
   - Simplify project_index to use cross_file_calls output directly without needing AST extractors (requires design work)
   - Leave project_index in tldr-swinton and call it via RPC (defeats extraction goal)
2. **Drop change_impact from v0.1 scope.** It is too entangled with tldr-swinton's session state and API layer. Mark it as v0.2 work after the extraction boundary stabilizes.
3. **Vendor workspace.py as-is, not a "reimplementation".** It is already minimal (9 KB, 200 lines) and has no dependencies. Reimplementing risks behavioral drift.

### 1.2 Go MCP + Python Subprocess Bridge

**Finding:** The PRD proposes a Go MCP server that shells out to Python via subprocess for all analysis operations. This pattern exists in the ecosystem (interlock, intermux are Go MCP servers) but those do not bridge to Python — they implement all logic in Go. The subprocess bridge introduces coupling and failure modes not present in pure-Go or pure-Python MCP servers.

**Architecture layers:**
```
Claude Code
    ↓ (MCP stdio)
Go MCP Server (intermap-mcp)
    ↓ (subprocess: python3 -m intermap.analyze --command=X --project=Y)
Python Analysis Module
    ↓ (tree-sitter, file I/O)
Codebase
```

**Failure modes introduced:**
1. **Serialization boundary:** Every tool call requires JSON serialization (Go→Python input, Python→Go output). Errors in JSON encoding/decoding become silent failures or tool errors.
2. **Process lifecycle:** Python subprocess must start, run, exit cleanly on every call. Timeouts, OOM kills, and stuck processes become MCP tool errors rather than internal exceptions.
3. **State management:** One-shot subprocess model (PRD Open Question 3) means no shared state between calls. Every call rebuilds indexes from scratch. Call graph construction for a 1000-file project may take 10-30 seconds per tool invocation.
4. **Error propagation:** Python exceptions must be caught, serialized to JSON stderr, parsed by Go, and translated to MCP errors. Stack traces are lost. Debugging requires checking both Go and Python logs.
5. **Dependency duplication:** Both Go binary and Python venv must be kept in sync during development and deployment. Plugin install must ensure Python deps are available (uv, tree-sitter bindings).

**Comparison to existing patterns:**

| Plugin | MCP Server | Logic | Bridge | State |
|--------|-----------|-------|--------|-------|
| interlock | Go | Go | HTTP → intermute | None |
| intermux | Go | Go | None | In-memory |
| tldr-swinton | Python | Python | None | Persistent daemon |
| interkasten | Node | TypeScript | None | SQLite |
| **intermap (proposed)** | **Go** | **Python** | **subprocess** | **None (one-shot)** |

**Intermap is unique in bridging Go→Python.** No existing plugin uses this pattern. The closest is interlock, which bridges Go→intermute's HTTP API, but that is a stable RPC interface with error codes and versioning. Python subprocess output is unversioned stderr/stdout.

**Performance impact:**
- PRD assumes one-shot subprocess calls (Open Question 3: "Leaning: one-shot for v0.1").
- tldr-swinton's call graph build on Interverse monorepo (22 modules, ~500 Python files): **~15 seconds** with warm file cache.
- If intermap invokes this on every `arch` or `calls` tool invocation, agents will wait 15 seconds per call.
- Caching is not specified in the PRD. The Go server has no mechanism to cache Python results between calls.

**Recommendation:**
1. **Start with Go-native implementation for F4 (project registry).** File discovery, .git root walking, and path resolution can be implemented in pure Go without Python. This validates the Go MCP pattern and provides immediate value (no tldr-swinton dependency, fast startup).
2. **Defer Python bridge until performance and error handling are prototyped.** Open Question 3 ("one-shot vs daemon") is load-bearing. Test both approaches with a realistic 500-file project before committing to the architecture.
3. **Add explicit caching layer in Go if using one-shot model.** Call graph results should be cached in Go memory with TTL and file mtime invalidation. This brings performance closer to tldr-swinton's daemon model without requiring a persistent Python process.
4. **Design error propagation protocol.** Define JSON schema for Python errors (type, message, file, line, traceback). Go should parse this and translate to structured MCP errors with actionable messages.

### 1.3 Project Registry Design

**Finding:** F4 proposes a Go-native project registry with `project_registry` and `resolve_project` tools. This duplicates discovery logic already implemented in multiple places:

- **beads (`bd`):** Walks directories to find `.beads/` databases and `.git` roots
- **interbump.sh:** Walks up from plugin dirs to find Interverse root and marketplace repo
- **interkasten:** Has project detection logic for Notion sync scoping
- **clavain:** Discovers plugins by scanning `~/.claude/plugins/cache/` and Interverse structure

**No consolidation plan.** The PRD does not explain how existing discovery logic will migrate to intermap or whether intermap's registry will become authoritative.

**API surface:**
```
project_registry() → [{name, path, language, metadata}]
resolve_project(file_path) → {name, path}
```

**Questions not answered:**
- What is `language` detection based on? Presence of `go.mod`, `package.json`, `pyproject.toml`? Does it handle multi-language projects (e.g., tldr-swinton has Python + tree-sitter C++ bindings)?
- What is `metadata`? PRD does not specify. If it is git metadata (branch, commit, remote), this duplicates `git rev-parse`. If it is project-specific config, where is it stored?
- How does registry handle Interverse monorepo structure? Each submodule has its own `.git`, but they share a parent directory. Does `project_registry` return 23 projects (root + 22 submodules) or 1 project (Interverse)?
- Is the registry workspace-scoped (respects `.claude/workspace.json` active packages) or global?

**Caching semantics:**
- PRD specifies "configurable TTL (default 5 min)" but does not explain invalidation. If a new git repo is cloned during a session, does the agent need to wait 5 minutes for it to appear? Is there a `refresh` parameter?
- TTL-based caching is fragile for file resolution (`resolve_project`). If a file is moved between projects (e.g., during a refactor), the cache may return stale project ownership for up to 5 minutes.

**Recommendation:**
1. **Specify registry scope and semantics before implementation.** Answer:
   - Does `project_registry` return all git repos under a workspace root, or only those in `.claude/workspace.json` active packages?
   - How are multi-git monorepos handled (Interverse structure)?
   - What is the minimum viable `metadata` for v0.1? (Suggest: language enum, git branch, nothing else)
2. **Make invalidation explicit, not TTL-only.** Provide a `refresh: bool` parameter on `project_registry` and invalidate `resolve_project` cache when the project list changes. File-based caching (mtime on .git dirs) is more reliable than time-based TTL.
3. **Consolidate discovery logic as a follow-up goal.** Document which existing tools should migrate to calling intermap's registry (e.g., clavain plugin discovery, beads project listing) and create migration beads. Do not assume adoption will happen organically.

### 1.4 Agent Overlay Integration

**Finding:** F5 proposes an `agent_map` tool that combines project registry data with live agent activity from intermux. This creates a 3-hop integration chain:

```
Claude Code
    ↓ (MCP)
intermap (Go MCP server)
    ↓ (MCP client call)
intermux (Go MCP server)
    ↓ (HTTP push)
intermute (Go service)
```

**Coupling introduced:**
- intermap depends on intermux MCP server being available (ENV: INTERMUX_MCP_URL or similar)
- intermux depends on intermute service being reachable (ENV: INTERMUTE_URL)
- intermute depends on interlock join-flag (`~/.config/clavain/intermute-joined`)

**This is a 3-service dependency chain where each layer has optional/graceful-degradation semantics.** The PRD specifies "graceful degradation: if intermux MCP server unavailable, returns projects without agent data" (F5 acceptance criteria), but does not explain:
- How does intermap discover intermux? Via env var? Via a config file? Via service discovery?
- What is the performance impact of calling another MCP server from within an MCP tool? Does this serialize two stdio round-trips?
- What happens if intermux is available but intermute is not? Does intermap get empty agent data, or does intermux return an error that intermap must handle?

**Alternative architectures not considered:**
1. **intermux pushes to a shared state file** (e.g., `/tmp/agent-map.json`) that intermap reads directly. No MCP-to-MCP call required.
2. **intermap queries intermute HTTP API directly** (same as interlock does). Cuts out intermux as a middleman.
3. **Agent overlay is a separate tool, not integrated into project registry.** Keep `project_registry` pure (just file discovery) and add `agent_overlay(project_path)` as a separate tool. Agents can compose them manually.

**Recommendation:**
1. **Simplify integration to avoid MCP-to-MCP calls.** Use a shared state file (option 1) or direct HTTP API (option 2). MCP servers calling other MCP servers is not a tested pattern in the ecosystem and may have stdio contention issues.
2. **Make agent overlay a separate tool (`agent_overlay`), not integrated into `agent_map`.** Keep `project_registry` and `resolve_project` pure (no intermux dependency). This reduces coupling and makes intermap useful even when intermute/intermux are not running.
3. **Document the dependency chain in AGENTS.md.** Explain what works when intermute is down (project registry, call graphs) vs what requires it (agent overlay). Provide a troubleshooting flowchart for "why is agent data missing?"

---

## 2. Pattern Analysis

### 2.1 Extraction Patterns in Interverse

**Existing extractions:**
- **intersearch** (library) — extracted from interject and interflux as a shared embedding client. Clean boundary: both consumers import it, no bidirectional deps.
- **intermute** (service) — extracted from interlock as a standalone coordination service. Clean boundary: HTTP API with versioned endpoints.

**Proposed intermap extraction:**
- **Direction:** tldr-swinton → intermap (6 modules move, tldr-swinton loses tools)
- **Boundary:** Project-level (call graphs, arch) vs file-level (context, extract)
- **Coupling:** intermap depends on tldr-swinton internals (workspace, ast_cache, hybrid_extractor) unless "simplified" (unspecified design)

**Pattern mismatch:** Successful extractions in Interverse create **libraries or services with clean inbound dependencies**. intermap as designed has **outbound dependencies on the module it is being extracted from** (tldr-swinton). This is extraction-in-name-only — intermap will be a wrapper around tldr-swinton's internals, not a standalone module.

**Alternative pattern: Refactor before extraction:**
1. **Phase 1:** Refactor tldr-swinton to isolate project-level analysis behind a clean internal API boundary (e.g., `project_analysis.py` module). Keep it in tldr-swinton.
2. **Phase 2:** If Phase 1 API boundary stabilizes and proves useful, extract it to intermap with the API as the import surface.

This is how intersearch was created: interject and interflux both needed embedding search, so the shared code was extracted into a library. They did not extract first and then figure out the API.

**Recommendation:**
1. **Do not extract until the boundary is clean.** If project_index, change_impact, and cross_file_calls cannot be made import-independent from tldr-swinton core (ast_cache, api, dirty_flag), they are not ready to move.
2. **Consider extraction as a v0.2 goal, not v0.1.** Start by building the project registry (F4) in intermap as a standalone Go tool. Once that is stable, revisit whether Python call graph analysis should move or stay.

### 2.2 Anti-Patterns

**Leaky abstraction: "Vendored minimal dependencies"**

The PRD acceptance criteria for F2 includes "vendored minimal dependencies (workspace config, any needed extractors)" but does not define what "minimal" means or how to prevent drift.

**Risk:** Vendored code forks create maintenance burden. If tldr-swinton's workspace.py gains a bug fix or feature (e.g., support for `.git/info/exclude` patterns), intermap's vendored copy will not receive the fix unless manually synced.

**Better alternatives:**
1. **Extract workspace.py to a shared library** (e.g., `interverse-workspace` package). Both tldr-swinton and intermap import it.
2. **Keep workspace.py in tldr-swinton and make it a dependency.** intermap's Python package lists `tldr-swinton` as a dependency and imports `from tldr_swinton.modules.core.workspace import ...`.

Both options avoid duplication. Option 2 is simpler (no new repo/package) but creates a dependency cycle if intermap is intended to replace tldr-swinton tools. Option 1 is cleaner but adds a third module to maintain.

**Recommendation:**
- **If workspace.py must be vendored, do not modify it.** Copy the file verbatim and add a comment linking to the source. Set up a CI check that diffs the vendored copy against the original and warns on divergence.
- **Prefer shared library (option 1) if vendoring more than one module.** Vendoring 2-3 modules (workspace, ast_cache stub, extractor stub) is a maintenance hazard. At that point, extract them as `interverse-codebase-utils` or similar.

**Premature extensibility: Multi-language support**

The PRD specifies that project registry should return `language` metadata and cross_file_calls supports Python, TypeScript, Go, Rust. This is feature-complete for tldr-swinton's current scope, but the PRD does not explain why intermap needs multi-language support if its primary consumer is Claude Code agents working in the Interverse monorepo (majority Python, some Go, some TypeScript).

**Risk:** Supporting 4 languages in v0.1 means:
- Maintaining tree-sitter bindings for all 4 (Python, TS, Go, Rust)
- Testing call graph correctness for all 4
- Handling language-specific quirks (e.g., Go's package system, Rust's module tree, TS's import resolution)

If the primary use case is Interverse development, this is over-engineered. 90% of calls will be Python or Go. Rust and TypeScript support can be deferred.

**Recommendation:**
- **Scope v0.1 to Python + Go only.** These are the dominant languages in Interverse (19 Python projects, 2 Go services, 1 TS project). Defer Rust/TS support to v0.2 once the architecture is validated.
- **Make language support a capability check, not a hard requirement.** If tree-sitter-rust is not installed, `project_registry` should still return Rust projects with `language: "rust"` but `arch`/`calls` should return an error ("Rust analysis requires tree-sitter-rust"). This allows incremental rollout.

### 2.3 Naming and Ownership

**Module naming:**

- **intermap** — suggests "mapping" or "visualization" but the PRD scope is project analysis (call graphs, dead code, impact). The name does not align with function.
- Alternative: **interscope** (project scoping), **intergraph** (call graph focus), **interarch** (architecture analysis)

**Ownership boundaries:**

The PRD does not specify who owns intermap post-extraction. Questions:
- Is it a companion plugin for clavain (like interlock, interflux)?
- Is it standalone (like tldr-swinton)?
- Does clavain automatically invoke intermap tools, or do agents call them directly?

**Companion vs standalone:**

| Model | Discovery | Invocation | Integration |
|-------|-----------|-----------|-------------|
| Companion (interlock) | Declared in clavain manifest | Clavain skills call tools | Tight (join-flag gating) |
| Standalone (tldr-swinton) | Installed independently | Agents call directly | Loose (optional) |

The PRD leans toward standalone (F6 includes "Added to marketplace.json", no mention of clavain integration), but F5 (agent overlay) assumes intermux integration, which is clavain-coupled.

**Recommendation:**
1. **Clarify ownership model before F6 (marketplace packaging).** If standalone, cut F5 (agent overlay) from v0.1 — it introduces clavain coupling. If companion, declare it in clavain's manifest and gate F4/F5 on join-flag (like interlock).
2. **Rename to match function.** "intermap" sounds like a visualization tool. Suggest "interscope" (project scoping + cross-file analysis) or keep functions in tldr-swinton as a `project` subcommand namespace.

---

## 3. Simplicity & YAGNI

### 3.1 Unnecessary Abstractions

**Go MCP scaffold when Python MCP exists:**

The PRD justifies Go MCP + Python subprocess as the architecture, but tldr-swinton is already a Python MCP server with 20 tools. If the goal is to add project registry and agent overlay, why not add them as tools to tldr-swinton's existing MCP server?

**Rationale given (implicit in PRD structure):**
- "tldr-swinton is a 1.4 MB monolith" — size is not a problem unless it causes slow startup or high memory usage. PRD provides no performance data showing this is an issue.
- "No central project registry" — true, but project registry does not require a separate plugin. It could be a new module in tldr-swinton.

**Rationale not given:**
- Deployment independence (intermap can update without tldr-swinton reinstall)
- Language separation (Go for performance, Python for flexibility)
- Ownership separation (different maintainers for file-level vs project-level tools)

If none of these apply, the extraction is premature. The simplest solution is:
1. Add `project_registry` and `resolve_project` as new tools in tldr-swinton's MCP server (Python implementation, 50 lines).
2. Add `agent_overlay` as a separate tool that queries intermux (if agent activity is needed).
3. Keep call graph tools (`arch`, `calls`, `impact`) in tldr-swinton.

**This requires zero extraction, zero new repos, zero Go bridge complexity.** The only change is adding 3 tools to tldr-swinton's `mcp_server.py`.

**Recommendation:**
- **Justify extraction with concrete benefits, not abstractions.** If the goal is to make project analysis available to non-tldr-swinton users (e.g., agents that do not want the full 1.4 MB install), document this as a requirement. If the goal is to reduce tldr-swinton's scope, explain why file-level and project-level analysis cannot coexist in one plugin (they currently do, with no reported issues).
- **Start with in-place refactor.** Add F4 (project registry) as new tools in tldr-swinton. If adoption proves the value and the tools feel out-of-scope for tldr-swinton, then extract. Do not extract speculatively.

### 3.2 Scope Creep

**F5 (agent overlay) is a feature, not a boundary requirement.**

The PRD problem statement is "no central project registry, no cross-project dependency mapping, and no way to overlay agent activity onto a project map." The first two are valid — project registry and call graphs solve real needs. The third (agent overlay) is speculative.

**Use case not demonstrated:**
- Who needs to see agent activity on a project map?
- What decisions does this enable that are not already served by intermux's `agent_status` tool or interlock's `list_agents`?
- Is this for visualization (out of scope per PRD non-goals), or for agent coordination?

If coordination, this duplicates interlock. If visibility, this duplicates intermux. The PRD does not explain what unique value agent overlay provides.

**Recommendation:**
- **Cut F5 from v0.1 scope.** Deliver F1-F4 (Go MCP scaffold, Python extraction, project registry) and validate whether agents actually request "which agents are working in this project" before building the integration.
- **If F5 is required, make it a separate tool, not integrated into project registry.** Keep concerns separate: `project_registry` is pure file discovery, `agent_overlay` is live metadata enrichment. Do not couple them.

### 3.3 Hidden Complexity

**"Simplify ProjectIndex to not need ast_cache/ast_extractor" (Open Question 2)**

This is listed as an open question with "Leaning: simplify" but no design. ProjectIndex is 13 KB and imports:
```python
from .ast_cache import ASTCache
from .ast_extractor import FunctionInfo
from .hybrid_extractor import HybridExtractor
```

These are **core tldr-swinton infrastructure** (300+ KB combined). Removing them is not simplification — it is a rewrite. The PRD does not specify:
- What does "simplified ProjectIndex" do? Does it still build symbol ranges? Does it still support diff-context engine?
- How does simplified ProjectIndex get symbol data? If it parses files itself, you are reimplementing ast_extractor. If it calls tldr-swinton's daemon, you have not eliminated the dependency.

**Recommendation:**
- **Resolve Open Question 2 before starting implementation.** If ProjectIndex cannot be simplified (likely), do not include it in v0.1 extraction scope. Move only the 3 modules with clean boundaries: analysis.py, diagnostics.py, durability.py.
- **Treat "simplify" as a red flag.** Any time a design says "simplify X", ask: what gets removed, and what breaks? If the answer is unclear, the design is not ready.

---

## Focus Areas Summary

### Module Boundaries and Coupling

| Component | Status | Concern |
|-----------|--------|---------|
| cross_file_calls.py → workspace.py | Clean (shared utility) | Vendoring creates drift risk |
| project_index.py → ast_cache/extractor/hybrid | Entangled | 300+ KB of core tldr-swinton deps, no separation plan |
| change_impact.py → api/dirty_flag | Entangled | Depends on session state and public API layer |
| analysis.py → cross_file_calls | Clean | No issues |
| diagnostics.py | Clean | Subprocess wrappers only, no internal deps |
| durability.py → cross_file_calls | Clean | No issues |

**Verdict:** 3 of 6 modules have unresolved coupling. Extraction is not viable until dependency resolution is concrete.

### Go MCP + Python Subprocess Bridge Pattern

| Aspect | Assessment |
|--------|------------|
| Precedent | None — no existing plugin uses Go→Python bridge |
| Failure modes | 5 new failure modes (serialization, lifecycle, state, errors, deps) |
| Performance | Unspecified — one-shot subprocess may be 10-30 sec per call |
| Caching | Not specified — Go layer has no cache design |
| Error handling | Not specified — no protocol for Python exception translation |

**Verdict:** High-risk architecture with no prototype. Recommend Go-native implementation for project registry (F4) first, defer Python bridge until performance/error handling are validated.

### Project Registry Design Decisions

| Decision | Status | Concern |
|----------|--------|---------|
| Registry scope (workspace vs global) | Unspecified | Affects monorepo handling, caching semantics |
| Language detection | Unspecified | Multi-language support is over-scoped for v0.1 |
| Metadata schema | Unspecified | "metadata" field is undefined |
| Cache invalidation | TTL-only | Fragile for file moves, no manual refresh |
| Monorepo handling | Unspecified | Interverse has 23 .git dirs — how are they grouped? |

**Verdict:** Design incomplete. Core semantics (scope, schema, invalidation) must be specified before implementation.

### Agent Overlay Integration via MCP

| Component | Integration | Concern |
|-----------|-------------|---------|
| intermap → intermux | MCP client call | Unproven pattern (MCP-to-MCP), stdio contention risk |
| intermux → intermute | HTTP push | Existing, stable |
| Graceful degradation | Specified | Good, but mechanism not detailed (env var? config?) |
| Alternative designs | Not considered | Shared state file or direct HTTP API would reduce layers |

**Verdict:** 3-hop chain (intermap→intermux→intermute) is over-coupled. Recommend separate `agent_overlay` tool or shared state file pattern.

### Extraction Boundary (Which Modules Move vs Stay)

**Move (clean boundary):**
- analysis.py (13 KB) — only depends on cross_file_calls
- diagnostics.py (40 KB) — no internal dependencies
- durability.py (12 KB) — only depends on cross_file_calls

**Defer (entangled):**
- project_index.py (13 KB) — depends on ast_cache, ast_extractor, hybrid_extractor (300+ KB)
- change_impact.py (12 KB) — depends on api, dirty_flag (session state)

**Shared (vendor or extract to library):**
- workspace.py (9 KB) — used by both sides
- cross_file_calls.py (119 KB) — depends on workspace, could be standalone library

**Verdict:** Move 3 clean modules (65 KB), defer 2 entangled modules (25 KB), treat cross_file_calls + workspace (128 KB) as shared library extraction candidate.

---

## Recommendations

### Must-Fix (Blocking)

1. **Resolve Open Questions 2 and 3 before starting implementation.**
   - Open Question 2: How is ProjectIndex simplified? Provide concrete design or drop it from v0.1.
   - Open Question 3: One-shot vs daemon for Python subprocess? Prototype both, measure call graph build time on 500-file project.

2. **Reduce extraction scope to clean-boundary modules only.**
   - Move: analysis.py, diagnostics.py, durability.py (65 KB, no entanglements)
   - Defer: project_index.py, change_impact.py (25 KB, unresolved deps)
   - Treat cross_file_calls.py as a separate extraction decision (could become shared library)

3. **Specify project registry semantics before F4 implementation.**
   - Scope: workspace-local or global?
   - Monorepo handling: how are Interverse's 23 .git dirs treated?
   - Metadata schema: define minimum viable fields for v0.1
   - Cache invalidation: add `refresh` parameter, use mtime-based invalidation

4. **Eliminate MCP-to-MCP call in F5 (agent overlay).**
   - Option A: intermux writes `/tmp/agent-map.json`, intermap reads it (shared state)
   - Option B: intermap queries intermute HTTP API directly (skip intermux layer)
   - Option C: Make agent overlay a separate tool, not integrated into project registry

### Optional (Quality)

5. **Add caching layer to Go MCP server if using one-shot Python subprocess.**
   - Cache call graph results in Go memory with file mtime invalidation
   - Specify TTL (5 min default) and manual refresh parameter

6. **Vendor workspace.py verbatim, do not reimplement.**
   - Copy file as-is with source attribution comment
   - Add CI check to diff vendored copy against original and warn on divergence

7. **Scope multi-language support to Python + Go for v0.1.**
   - Defer TypeScript and Rust to v0.2
   - Return language enum for all projects, but only support call graph analysis for Python/Go

8. **Rename to align with function.**
   - "intermap" suggests visualization; consider "interscope" (project scoping) or "intergraph" (call graph focus)

### Architectural Alternatives

**Option 1: No extraction — add features to tldr-swinton**
- Add `project_registry`, `resolve_project`, `agent_overlay` as new MCP tools in tldr-swinton
- Keep call graph tools in place
- **Pros:** Zero new repos, zero Go bridge, immediate delivery
- **Cons:** tldr-swinton remains large (but size is not a demonstrated problem)

**Option 2: Phased extraction — project registry first**
- **Phase 1:** Build F4 (project registry) in intermap as pure Go MCP server, no Python
- **Phase 2:** Validate adoption and performance, then revisit Python call graph extraction
- **Pros:** Validates Go MCP pattern with low risk, provides immediate value (fast project discovery)
- **Cons:** Delays call graph features, but they work fine in tldr-swinton today

**Option 3: Extract as shared library, not plugin**
- Extract cross_file_calls + analysis + diagnostics as `interverse-code-analysis` Python package
- Both tldr-swinton and (future) intermap import it
- **Pros:** Eliminates vendoring, supports gradual migration
- **Cons:** Adds a third module to maintain

---

## Conclusion

The PRD identifies a real concern-conflation problem (file-level vs project-level analysis) but proposes an extraction with unresolved dependencies, unproven architecture, and speculative features. The Go MCP + Python subprocess pattern is high-risk with no precedent in the ecosystem. The extraction boundary includes 3 entangled modules (108 KB of 208 KB) with no concrete separation plan.

**Primary recommendation:** Defer extraction until dependency resolution is complete. Start with F4 (project registry) as a standalone Go MCP server to validate the architecture without Python bridge risk. If that succeeds, revisit call graph extraction in v0.2 with a concrete design for simplifying ProjectIndex and change_impact.

**Alternative recommendation:** Add project registry tools to tldr-swinton as new MCP tools (Python implementation, 50 lines). This delivers the functionality immediately with zero extraction risk. If adoption proves the value and agents request a standalone plugin, extract in v0.2 after usage patterns are understood.

**Do not proceed with v0.1 as specified.** The open questions are load-bearing, the extraction boundary is incomplete, and the subprocess bridge is untested. Resolve these before committing to the architecture.
