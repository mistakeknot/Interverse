# Flux-Drive Architecture Review: interserve MCP Server

**Reviewed**: 2026-02-16
**Reviewer**: fd-architecture (Flux-Drive)
**Scope**: New interserve Go MCP server + integration with interflux flux-drive system

---

## Executive Summary

**Verdict**: Safe to proceed. The interserve architecture is clean, well-bounded, and correctly integrated.

**Key Strengths**:
- Crystal-clear separation of concerns across 5 Go packages with zero circular dependencies
- Dependency flow follows natural data transformation pipeline (extract → classify → tempfiles → tools)
- MCP boundary is thin and stateless (stdio server with no plugin-side state)
- Integration with flux-drive is properly specified via slicing.md as the single source of truth

**Structural Observations**:
- Module boundaries are appropriate for current scope
- Coupling is intentional and directional
- Fallback path (hardcoded dispatch.sh) is pragmatic for monorepo deployment
- Integration contracts are clearly specified in markdown specs, not buried in code

**Recommendations**: 2 minor improvements for long-term maintainability, zero blocking issues.

---

## 1. Boundaries & Coupling

### 1.1 Module Structure

The Go package hierarchy is well-designed:

```
cmd/interserve-mcp/          → Entry point (9 lines)
internal/
  extract/               → Section parsing (164 lines)
  classify/              → Dispatch invocation + domain logic (341 lines)
    - classify.go        → Main classification workflow
    - prompt.go          → Agent domain definitions + prompt builder
  tempfiles/             → Per-agent markdown generation (131 lines)
  tools/                 → MCP tool registration (170 lines)
```

**Boundary integrity**: Each package has a single responsibility with clear external contracts:

| Package | Responsibility | Exports | Imports (internal) |
|---------|---------------|---------|-------------------|
| `extract` | Markdown section splitting | `Section`, `ExtractSections()` | None |
| `classify` | Interserve spark classification | `ClassifyResult`, `Classify()`, `AgentDomain` | `extract` |
| `tempfiles` | Per-agent file generation | `GenerateAgentFiles()` | `extract`, `classify` |
| `tools` | MCP tool handlers | `RegisterAll()` | `extract`, `classify` |

**Coupling analysis**:

1. **extract → classify** (Section type): Clean data dependency. `classify` needs structured sections, `extract` provides them. Alternative (passing raw strings) would duplicate parsing logic.

2. **classify → extract** (uses Section in Classify()): Appropriate. Classification operates on extracted structure. Splitting would require an intermediate adapter type with no architectural benefit.

3. **tempfiles → {extract, classify}**: Correct. Tempfile generation needs both section structure (from `extract`) and slicing metadata (from `classify`). This is composition, not entanglement.

4. **tools → {extract, classify}**: MCP handlers orchestrate the pipeline. This is the integration layer — coupling here is expected and well-controlled.

**Verdict**: Dependency graph is a clean DAG. No circular dependencies, no god modules, no leaky abstractions.

### 1.2 Hardcoded Fallback Path

```go
dispatchPath := os.Getenv("INTERSERVE_DISPATCH_PATH")
if dispatchPath == "" {
    dispatchPath = "/root/projects/Interverse/hub/clavain/scripts/dispatch.sh"
}
```

**Analysis**:
- This is a **deployment assumption**, not a design flaw.
- The MCP server is consumed by interflux (same monorepo), which sets `INTERSERVE_DISPATCH_PATH` in `plugin.json`.
- Fallback ensures zero-config operation when launched directly (e.g., during development or testing).
- **Boundary respected**: The hardcoded path is in `main.go` (entry point), not buried in internal packages.

**Risk**: If interserve is ever extracted to a standalone project, the fallback path becomes invalid. However, this is a **future extraction concern**, not a current architecture issue. The env var override provides the proper abstraction for external use.

**Recommendation**: Document the monorepo assumption in `cmd/interserve-mcp/main.go` inline comment:
```go
// Fallback for Interverse monorepo deployment.
// External users should always set INTERSERVE_DISPATCH_PATH.
```

### 1.3 Integration Boundary: MCP Tools

The `tools` package exposes two MCP tools:
1. `extract_sections` — returns section metadata (ID, heading, line count, first sentence)
2. `classify_sections` — returns full classification result (status, sections, slicing_map)

**Interface contract**:
- Both tools accept `file_path` (string) and read the file themselves.
- `classify_sections` optionally accepts `agents` (array of names or {name, description} objects).
- Return values are JSON-serialized structs.

**Boundary evaluation**:
- Tools are **read-only** — no file writes, no side effects.
- Callers (flux-drive orchestrator) are responsible for interpreting results and writing temp files.
- This is the correct division: interserve **classifies**, flux-drive **orchestrates**.

**Data flow**:
```
flux-drive (orchestrator)
  → mcp__plugin_interserve_interserve__classify_sections(file_path)
  → interserve MCP server (read file + extract + classify via dispatch.sh)
  → returns ClassifyResult JSON
flux-drive
  → interprets slicing_map
  → writes per-agent temp files (via tempfiles logic OR its own implementation)
  → launches agents with temp file paths
```

**Concern**: The `tempfiles` package exists in interserve but is **not exposed via MCP tools**. This means:
- `tempfiles.GenerateAgentFiles()` is only usable by Go code that imports interserve as a library.
- The flux-drive orchestrator (which invokes interserve via MCP) must reimplement the temp file generation logic.

**Recommendation**: Either:
1. **Add a third MCP tool** `generate_agent_files` that wraps `tempfiles.GenerateAgentFiles()`, OR
2. **Remove the `tempfiles` package** if flux-drive is expected to handle temp file generation itself.

**Current state**: The `tempfiles` package is **orphaned** — it's not used by the MCP server and not exposed to MCP clients. This suggests incomplete integration or scope creep during development.

**Mitigation**: Check `launch.md` Step 2.1c. If it says "invoke interserve tempfiles generation," then MCP tool 3 is missing. If it says "flux-drive writes temp files using slicing_map," then `tempfiles` package should be deleted.

---

## 2. Pattern Analysis

### 2.1 Extraction Logic (extract.go)

**Pattern**: State machine for fence-aware section parsing.

```go
inFence := false
fence := ""
for _, line := range lines {
    if marker := fenceMarker(line); marker != "" {
        if !inFence { inFence = true; fence = marker }
        else if marker == fence { inFence = false; fence = "" }
    }
    if !inFence && strings.HasPrefix(line, "## ") { /* emit section */ }
}
```

**Correctness**:
- Handles both ``` and ~~~ fences correctly.
- Unclosed fences are correctly handled (entire remainder becomes one section body).
- YAML frontmatter is skipped (lines between `---` markers at document start).
- Empty preamble is skipped (no section created if preamble has no content).

**Edge cases covered by tests**:
- Nested fence markers inside code blocks (correctly ignored).
- Empty sections between consecutive headings (kept in output).
- Unclosed fences (remaining document becomes part of last section).

**Anti-pattern check**: None detected. This is a clean single-pass parser with explicit state tracking.

### 2.2 Classification via Dispatch (classify.go)

**Pattern**: External process invocation with temp file I/O.

```go
promptFile, _ := os.CreateTemp("", "interserve-prompt-*.txt")
defer os.Remove(promptPath)
cmd := exec.CommandContext(ctx, "bash", dispatchPath,
    "--tier", "fast", "--sandbox", "read-only",
    "--prompt-file", promptPath, "-o", outputPath)
combined, err := cmd.CombinedOutput()
```

**Boundary**: Interserve does **not** know about Interserve spark internals. It only knows:
- How to invoke `dispatch.sh` (via bash).
- Expected JSON response schema (sections with assignments).
- Error conditions (exit code != 0, empty output, malformed JSON).

**Concern**: Tight coupling to Clavain's dispatch.sh implementation. If dispatch.sh changes its flag syntax or response format, interserve breaks.

**Mitigation**: The coupling is **intentional and documented**. Interserve is a Clavain companion plugin, not a standalone tool. The README should make this explicit.

**Recommendation**: Add integration test that verifies dispatch.sh contract:
```go
func TestDispatchContract(t *testing.T) {
    // Invoke dispatch.sh with known prompt
    // Verify response has expected JSON schema
    // This test fails if dispatch.sh breaks compatibility
}
```

**Code fence stripping**: `stripCodeFences()` handles LLM output that wraps JSON in markdown fences. This is a **defensive pattern** — Interserve spark should return raw JSON, but stripping fences makes interserve resilient to LLM output formatting quirks.

### 2.3 Domain Mismatch Guard

```go
// Domain mismatch guard: if no agent has >10% priority lines, classification likely failed.
anyAboveThreshold := false
for _, agent := range agents {
    if result.SlicingMap[agent.Name].TotalPriorityLines*100/totalLines > 10 {
        anyAboveThreshold = true
        break
    }
}
if !anyAboveThreshold {
    result.Error = "domain mismatch: no agent has >10% priority lines"
    return result
}
```

**Pattern**: Sanity check on classification output to detect failure modes.

**Rationale**: If Interserve spark misclassifies the document (e.g., classifies a Go API design doc using game-design agents), the result will be diffuse low-priority assignments across all agents. The 10% threshold detects this and triggers fallback.

**Correctness**: This is a **heuristic**, not a guarantee. Edge cases:
- A document that is truly cross-cutting (no agent gets >10%) will be flagged as "mismatch" even if classification is correct.
- A document with 11 equal sections across 5 agents (each agent gets 2 sections = 18%) passes the guard even if classification is nonsense.

**Recommendation**: Treat this as a **confidence signal**, not a blocker. The flux-drive orchestrator should log the mismatch warning and offer the user a choice:
- "Classification uncertain (no agent >10% priority). Use full-document mode for all agents?"
- Or: "Proceed with slicing anyway (experimental)."

**Alternative pattern**: Return confidence scores per agent in the JSON response, let orchestrator decide threshold policy. This decouples the heuristic from interserve.

### 2.4 80% Threshold Upgrade

```go
if slice.TotalPriorityLines*100/totalLines >= 80 {
    slice.PrioritySections = allSectionIDs
    slice.TotalPriorityLines = totalLines
    slice.ContextSections = nil
    slice.TotalContextLines = 0
}
```

**Pattern**: Collapse slicing when overhead exceeds benefit.

**Rationale**: If an agent needs 80% of the document as priority, the token savings from omitting 20% are negligible. Simpler to send the full document.

**Correctness**: This is **pragmatic**. The 80% number is a policy choice, not a law of nature. Tests verify the threshold is applied correctly.

**Concern**: The 80% threshold is **hardcoded** in `buildResult()`. If flux-drive wants to tune this threshold per project (e.g., lower threshold for very large documents), it cannot override interserve's logic.

**Recommendation**: Make the threshold configurable:
```go
type ClassifyOptions struct {
    Agents []AgentDomain
    FullDocThreshold int // default 80
}
func ClassifyWithOptions(ctx, dispatchPath, sections, opts) ClassifyResult
```

This keeps the default behavior (80%) but allows flux-drive to override via MCP tool parameters.

---

## 3. Integration with Flux-Drive

### 3.1 Specification as Single Source of Truth

**Observation**: The integration contract is defined in `plugins/interflux/skills/flux-drive/phases/slicing.md`, not scattered across code comments.

**Benefits**:
- Developers read one markdown file to understand the full slicing algorithm.
- Code changes that violate the spec are immediately visible (spec remains authoritative).
- The spec is versioned alongside the code (git history tracks evolution).

**Risks**:
- Code and spec can drift if developers update code without updating slicing.md.
- No automated enforcement that code conforms to spec.

**Mitigation**: The spec includes explicit examples and edge cases. A **conformance test suite** would close the gap:
```go
// Test that interserve classification matches examples in slicing.md
func TestSlicingSpecConformance(t *testing.T) {
    // For each example in slicing.md → Document Slicing → Classification Methods
    // - Extract sections from example document
    // - Run classify_sections
    // - Verify result matches expected slicing_map from spec
}
```

**Recommendation**: Add conformance tests. Until then, rely on integration testing during flux-drive reviews to catch drift.

### 3.2 Slicing.md Case 2 Integration

From `launch.md` Step 2.1c:

```
#### Case 2: File/directory inputs — document slicing active (>= 200 lines)

1. Classify sections: Invoke interserve MCP classify_sections tool with file_path.
2. Check result: If status is "no_classification", fall back to Case 1 (shared file).
3. Generate per-agent files: For each agent in slicing_map:
   - If cross-cutting: use shared REVIEW_FILE.
   - If zero priority sections: skip dispatching this agent.
   - Otherwise: write per-agent temp file following slicing.md.
4. Record all paths: Store REVIEW_FILE_{agent} paths for prompt construction.
```

**Analysis**:
- Step 1 invokes interserve MCP tool. ✅
- Step 2 checks `status` field from ClassifyResult. ✅
- Step 3 **does not invoke interserve** — flux-drive writes temp files itself. ⚠️
- Step 4 records paths for later use in agent prompts. ✅

**Conclusion**: The `tempfiles` package in interserve is **orphaned**. It implements the per-agent temp file logic, but the flux-drive orchestrator does not call it.

**Two possible resolutions**:
1. **Add MCP tool 3**: `generate_agent_files(file_path, slicing_map)` → returns map of agent → temp file path. Flux-drive invokes this instead of Step 3's manual file writing.
2. **Delete tempfiles package**: Flux-drive owns temp file generation. Interserve only provides classification metadata.

**Recommendation**: Option 2 (delete `tempfiles`). Reasons:
- Temp file generation is **orchestration logic**, not classification logic.
- Flux-drive already has context about output directories, file naming conventions, and cleanup policies.
- Interserve returning file paths would require interserve to manage temp file lifecycle (when to delete?), which crosses the boundary.

**Better division of responsibility**:
- Interserve: "Here's the slicing metadata (which sections each agent should see)."
- Flux-drive: "I'll write the temp files in my output directory and pass paths to agents."

**If keeping tempfiles**: Add MCP tool 3 and update `launch.md` Step 2.1c to invoke it. Otherwise, remove the package and tests.

### 3.3 Cross-Cutting Agent Handling

From `slicing.md`:
```
Cross-cutting agents (fd-architecture, fd-quality): always receive the full document.
```

From `classify.go`:
```go
var CrossCuttingAgents = map[string]bool{
    "fd-architecture": true,
    "fd-quality": true,
}
```

From `tempfiles.go`:
```go
if classify.CrossCuttingAgents[agent] { continue } // skip temp file for cross-cutting
```

**Integration check**:
- Slicing.md defines cross-cutting agents in prose. ✅
- Classify.go **hardcodes** the list. ⚠️
- Tempfiles.go references the hardcoded list. ✅

**Concern**: If flux-drive adds a new cross-cutting agent (e.g., `fd-security`), it must:
1. Update `slicing.md`.
2. Update `classify.go` (`CrossCuttingAgents` map).
3. Update `prompt.go` (if agent needs domain description).

This is a **three-location update** for a single logical change.

**Recommendation**: Make cross-cutting agent list configurable via MCP tool parameters:
```go
type ClassifyOptions struct {
    Agents []AgentDomain
    CrossCuttingAgents []string // agents that always get full document
}
```

Or, define cross-cutting agents in `slicing.md` machine-readable format (YAML frontmatter?) and have both interserve and flux-drive read from the same source.

**Current state**: The duplication is **low-risk** (only 2 agents, unlikely to change frequently), but it's a **structural smell**. If the list grows or changes often, this becomes a maintenance burden.

---

## 4. Simplicity & YAGNI

### 4.1 Premature Abstractions

**Extract package**:
- `Preview()` method: Used by `classify.go` to build prompts. ✅
- `FirstSentence()` method: Used by both `classify.go` (prompts) and `tempfiles.go` (summaries). ✅
- No unused methods detected.

**Classify package**:
- `AgentDomain` struct: Used by `BuildPrompt()` and MCP tool interface. ✅
- `DefaultAgents()`: Provides baseline agents when caller doesn't override. ✅
- `CrossCuttingAgents` map: Used by `buildResult()` (filtering) and `tempfiles.go` (skipping). ✅
- No speculative interfaces or plugin hooks.

**Tempfiles package**:
- `GenerateAgentFiles()`: Not called by MCP server. ⚠️ (See Section 3.2 — orphaned package).
- `renderAgentMarkdown()`: Helper for `GenerateAgentFiles()`. Also unused if parent is unused.

**Verdict**: Minimal abstractions. The only YAGNI violation is the orphaned `tempfiles` package.

### 4.2 Complexity Hot Spots

**Most complex function**: `buildResult()` in `classify.go` (104 lines).

**What it does**:
1. Filters assignments to allowed agents.
2. Groups sections by agent into priority/context buckets.
3. Applies 10% domain mismatch guard.
4. Applies 80% threshold upgrade.
5. Returns structured ClassifyResult.

**Complexity drivers**:
- Multiple policies (filtering, thresholds, upgrades) in one function.
- Integer arithmetic to avoid floating-point errors (e.g., `lines*100/total >= 80`).

**Refactor opportunity**: Extract policy steps into named helpers:
```go
func buildResult(classified, sections, agents) ClassifyResult {
    result := initializeResult(sections, agents)
    result = applyAssignments(classified, sections, agents)
    if !passesDomainMismatchGuard(result, sections) {
        return noClassificationResult(sections, agents, "domain mismatch")
    }
    result = applyFullDocThreshold(result, sections, agents, 80)
    return result
}
```

**Current state**: Readable but dense. Tests cover all branches (80% threshold, domain mismatch, normalization). Not urgent to refactor, but would improve maintainability.

### 4.3 Accidental Complexity

**Dispatch invocation**: Uses temp files for prompt and output instead of stdin/stdout piping.

**Rationale**: Clavain's `dispatch.sh` accepts `--prompt-file` (file path) and `-o` (output path). Using temp files matches the dispatch.sh interface.

**Alternative**: If dispatch.sh accepted stdin for prompts, interserve could use:
```go
cmd.Stdin = strings.NewReader(prompt)
output, _ := cmd.Output()
```

**Verdict**: Temp file approach is **imposed by dispatch.sh's interface**, not interserve's choice. Not accidental complexity.

**Cleanup**: `defer os.Remove(promptPath)` ensures temp files are deleted after use. ✅

---

## 5. Missing Components

### 5.1 Error Handling Coverage

**Covered**:
- File read errors (MCP tools return error result).
- Dispatch.sh failures (non-zero exit, stderr captured in error message).
- JSON unmarshaling errors (malformed classification output).
- Empty/missing output from dispatch.sh.

**Gaps**:
- **Timeout handling**: `exec.CommandContext(ctx, ...)` uses context for cancellation, but MCP server does not set timeouts on tool invocations. If dispatch.sh hangs, the MCP tool hangs indefinitely.
- **Partial output**: If dispatch.sh writes incomplete JSON (e.g., crashes mid-write), `json.Unmarshal()` fails, but interserve doesn't log the raw output for debugging.

**Recommendation**:
1. Add default timeout to MCP tool invocations (e.g., 5 minutes).
2. Log raw output on JSON parse failure:
```go
if err := json.Unmarshal(payload, &decoded); err != nil {
    fmt.Fprintf(os.Stderr, "interserve: invalid JSON from dispatch: %s\n", payload)
    return ClassifyResult{Status: statusNoClassification, Error: ...}
}
```

### 5.2 Test Coverage

**Unit tests exist for**:
- `extract.go`: 6 tests covering basic parsing, code blocks, frontmatter, unclosed fences, empty sections, previews.
- `classify.go`: 3 tests covering prompt building, 80% threshold, domain mismatch guard.
- `tempfiles.go`: Tests exist but not reviewed in detail.

**Gaps**:
- No integration test for full MCP tool invocation (extract_sections, classify_sections).
- No test for dispatch.sh contract conformance.
- No test for `tools.parseAgentsArg()` (handles both `["agent1", "agent2"]` and `[{name, description}]` formats).

**Recommendation**: Add integration test suite:
```go
// Test MCP tool extract_sections
func TestExtractSectionsTool(t *testing.T) {
    server := setupTestServer()
    req := mcp.CallToolRequest{Name: "extract_sections", Arguments: {file_path: "testdata/doc.md"}}
    resp, _ := server.CallTool(req)
    // Verify response contains expected sections
}
```

### 5.3 Documentation

**Exists**:
- `CLAUDE.md`: Quick commands, design decisions.
- Inline code comments: Minimal but sufficient (e.g., `// Section is a markdown slice rooted at a top-level (##) heading.`).

**Missing**:
- **AGENTS.md**: No developer guide for interserve (how to build, test, extend).
- **README.md**: No project overview for external users.
- **Architecture diagram**: No visual representation of package dependencies.

**Recommendation**: Add `AGENTS.md` with:
- Build instructions (`go build -o bin/interserve-mcp ./cmd/interserve-mcp/`).
- Test instructions (`go test ./... -v`).
- MCP tool reference (tool names, parameters, return schemas).
- Integration with flux-drive (when to use interserve vs. keyword-based slicing).

---

## 6. Structural Recommendations

### 6.1 High Priority

**Recommendation 1**: Resolve the orphaned `tempfiles` package.
- **Current state**: Package exists but is not used by MCP server or exposed via tools.
- **Action**: Either add MCP tool 3 (`generate_agent_files`) OR delete the package and update flux-drive to generate temp files.
- **Rationale**: Unused code is a maintenance burden and suggests incomplete integration.
- **Effort**: Low (delete package) or Medium (add MCP tool + tests).

**Recommendation 2**: Add integration tests for MCP tools.
- **Current state**: Unit tests exist, but no end-to-end test of MCP tool invocation.
- **Action**: Add `internal/tools/tools_test.go` with test server setup and tool invocation tests.
- **Rationale**: Catch regressions in MCP tool interface changes.
- **Effort**: Medium (requires test harness for mcp-go server).

### 6.2 Medium Priority

**Recommendation 3**: Make cross-cutting agent list configurable.
- **Current state**: Hardcoded in `classify.go` as `CrossCuttingAgents` map.
- **Action**: Accept `cross_cutting_agents` array parameter in `classify_sections` MCP tool.
- **Rationale**: Decouple agent roster from interserve code. Easier to add new cross-cutting agents without code changes.
- **Effort**: Low (add parameter parsing, default to current list).

**Recommendation 4**: Make 80% threshold configurable.
- **Current state**: Hardcoded in `buildResult()` as integer `80`.
- **Action**: Add optional `full_doc_threshold` parameter to `classify_sections` tool (default 80).
- **Rationale**: Allow flux-drive to tune threshold based on document size or project policy.
- **Effort**: Low (add parameter, default to 80).

**Recommendation 5**: Add AGENTS.md developer guide.
- **Current state**: Only `CLAUDE.md` exists (minimal quick reference).
- **Action**: Write comprehensive developer guide covering build, test, extend, integration.
- **Rationale**: Onboard new contributors and document integration contract with flux-drive.
- **Effort**: Medium (requires structured documentation writing).

### 6.3 Low Priority

**Recommendation 6**: Extract policy logic from `buildResult()` into named helpers.
- **Current state**: 104-line function with multiple responsibilities.
- **Action**: Refactor into `applyAssignments()`, `passesDomainMismatchGuard()`, `applyFullDocThreshold()`.
- **Rationale**: Improve readability and testability of individual policies.
- **Effort**: Medium (requires careful refactoring + test updates).

**Recommendation 7**: Add conformance tests for slicing.md spec.
- **Current state**: Spec exists but no automated verification that code matches spec.
- **Action**: Parse examples from slicing.md and run classification to verify output matches spec.
- **Rationale**: Catch spec/code drift early.
- **Effort**: High (requires spec parsing or manual test case extraction).

---

## 7. Risks & Mitigations

### 7.1 Tight Coupling to dispatch.sh

**Risk**: If Clavain's `dispatch.sh` changes its interface (flags, JSON schema, error handling), interserve breaks.

**Likelihood**: Medium (dispatch.sh is actively developed).

**Impact**: High (classification stops working, flux-drive falls back to keyword matching).

**Mitigation**:
- Add integration test that verifies dispatch.sh contract (flags, response schema).
- Test fails on dispatch.sh interface changes, forcing explicit interserve update.
- Document dispatch.sh version compatibility in `AGENTS.md`.

### 7.2 Domain Mismatch False Positives

**Risk**: 10% threshold flags valid classifications as "mismatch" for cross-cutting documents.

**Likelihood**: Low (most documents have clear domain focus).

**Impact**: Medium (flux-drive falls back to full-document mode, wastes slicing effort).

**Mitigation**:
- Treat mismatch as a **warning**, not a blocker.
- Log the slicing_map alongside the warning so users can inspect results.
- Consider lowering threshold to 5% after collecting real-world data.

### 7.3 Orphaned Tempfiles Package

**Risk**: Developers assume `tempfiles` is used and add features to it, wasting effort.

**Likelihood**: Medium (package exists in codebase with tests).

**Impact**: Low (wasted effort, but no runtime breakage).

**Mitigation**: Resolve immediately (delete package OR add MCP tool 3). See Recommendation 1.

### 7.4 Spec/Code Drift

**Risk**: `slicing.md` spec diverges from interserve implementation over time.

**Likelihood**: Medium (spec is markdown, code is Go — no automated linkage).

**Impact**: Medium (confusion for developers, unexpected behavior).

**Mitigation**:
- Add conformance tests (Recommendation 7).
- Treat `slicing.md` as source of truth; flag code changes that contradict spec.
- Version the spec (add version header to slicing.md).

---

## 8. Integration Checklist

For flux-drive orchestrator developers:

- [ ] **Invoke interserve MCP tool** `classify_sections` when document >= 200 lines.
- [ ] **Check `status` field** in ClassifyResult. If `"no_classification"`, fall back to full document mode.
- [ ] **Interpret `slicing_map`**: For each agent, read `priority_sections` and `context_sections` lists.
- [ ] **Write per-agent temp files** (flux-drive's responsibility, not interserve's).
- [ ] **Handle cross-cutting agents**: Skip slicing for agents in `CrossCuttingAgents` map (or get list from interserve response).
- [ ] **Apply 80% threshold**: If `total_priority_lines * 100 / total_lines >= 80`, send full document to that agent.
- [ ] **Log domain mismatch warnings**: If `status == "no_classification"` with `error` containing "domain mismatch", notify user.
- [ ] **Track section requests**: Count "Request full section: X" annotations in agent findings for quality metrics.

---

## 9. Conclusion

The interserve MCP server is architecturally sound. Module boundaries are clear, coupling is intentional and directional, and integration with flux-drive is well-specified. The only blocking issue is the orphaned `tempfiles` package, which should be resolved before shipping.

**Recommended action sequence**:
1. **Immediate**: Resolve tempfiles package (delete or expose via MCP tool 3).
2. **Before first production use**: Add integration tests for MCP tools.
3. **Within 2 weeks**: Write AGENTS.md developer guide.
4. **Long-term**: Make cross-cutting agents and 80% threshold configurable, add conformance tests.

**Verdict**: Safe to integrate into flux-drive once tempfiles package is resolved. No fundamental architectural flaws detected.

---

## Appendix: Dependency Graph

```
cmd/interserve-mcp/main.go
  → internal/tools.RegisterAll()
      → internal/extract.ExtractSections()
      → internal/classify.Classify()
          → internal/extract.Section (type)
      → internal/classify.DefaultAgents()
      → internal/classify.AgentDomain (type)
      → internal/classify.ClassifyResult (type)

[ORPHANED]
internal/tempfiles.GenerateAgentFiles()
  → internal/extract.Section (type)
  → internal/classify.ClassifyResult (type)
  → internal/classify.CrossCuttingAgents (map)
```

**Edge weights**:
- `cmd/interserve-mcp` → `tools`: Bootstrap (thin, stateless).
- `tools` → `extract`: Data transformation (Section extraction).
- `tools` → `classify`: Orchestration (Classify invokes extract internally).
- `classify` → `extract`: Data dependency (Section type).
- `tempfiles` → `{extract, classify}`: Orphaned (not invoked by MCP server).

**Circular dependencies**: None.

**God modules**: None.

**Leaky abstractions**: None detected. Each package's exported API is minimal and cohesive.
