# Quality Review: interserve Go MCP Server

**Reviewer**: Flux-drive Quality & Style Reviewer
**Date**: 2026-02-16
**Scope**: Go 1.23 + mcp-go v0.43.2
**Status**: Production-ready with minor improvements needed

## Executive Summary

The interserve MCP server demonstrates solid Go fundamentals with clean package structure, robust error handling, and good test coverage of core logic. The code follows Go idioms and naming conventions consistently. Key strengths: context-preserving error wrapping, defensive validation, and clear separation of concerns. Areas for improvement: remove unnecessary custom `min()` function (Go 1.23 stdlib has it), add integration tests for subprocess dispatch, and improve test clarity around domain mismatch thresholds.

---

## Universal Quality Checks

### Naming Consistency ✅
- **Package naming**: All lowercase, idiomatic (`extract`, `classify`, `tempfiles`, `tools`)
- **Exported types**: Clear, descriptive (`AgentDomain`, `ClassifyResult`, `Section`)
- **Functions**: Verb-first for actions (`ExtractSections`, `BuildPrompt`, `GenerateAgentFiles`)
- **Private helpers**: Concise and clear (`splitLines`, `fenceMarker`, `collectSections`)
- **Constants**: Descriptive (`statusSuccess`, `statusNoClassification`)

No naming inconsistencies found — vocabulary is uniform across the codebase.

### File Organization ✅
```
cmd/interserve-mcp/        → binary entrypoint
internal/
  extract/             → markdown section parsing
  classify/            → AI classification + domain logic
  tempfiles/           → per-agent file generation
  tools/               → MCP tool registration
```

Clear layering: `tools` depends on `classify` + `extract`, `tempfiles` depends on both. No circular dependencies, no ad-hoc structure.

### Error Handling ✅ (Excellent)

#### Context Preservation
All errors use `%w` for chain-preserving wrapping:
```go
// classify.go
return nil, fmt.Errorf("create prompt temp file: %w", err)
return nil, fmt.Errorf("write agent temp file for %s: %w", agent, err)

// tempfiles.go
return nil, fmt.Errorf("create temp dir %q: %w", tmpDir, err)
```

#### Defensive Error Accumulation
`tempfiles.go` cleans up on partial failure:
```go
if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
    for _, created := range files {
        _ = os.Remove(created)
    }
    return nil, fmt.Errorf("write agent temp file for %s: %w", agent, err)
}
```

This is excellent — avoids leaking temp files when mid-loop writes fail.

#### Graceful Degradation
`classify.go` returns structured errors instead of panicking:
```go
return ClassifyResult{
    Status: statusNoClassification,
    Sections: buildEmptySections(sections),
    SlicingMap: buildEmptySlicingMap(agents),
    Error: "dispatch returned empty classification output",
}
```

MCP tools convert errors to user-facing messages:
```go
return mcp.NewToolResultError(fmt.Sprintf("read %s: %v", filePath, err)), nil
```

No silent failures detected.

### Test Strategy ✅ (Core Logic), ⚠️ (Subprocess Integration)

#### Strengths
- **extract_test.go**: 8 tests covering core parsing logic (YAML frontmatter, fenced blocks, empty sections, preview truncation)
- **classify_test.go**: 4 tests covering prompt structure, 80% threshold, domain mismatch guard
- **tempfiles_test.go**: 2 tests covering file generation, metadata headers, cross-cutting agent filtering
- **Table-driven where appropriate**: `TestBuildResultAppliesEightyPercentThreshold` uses subtests

#### Gaps
1. **No integration tests for subprocess dispatch** — `classify.Classify` shells out to `dispatch.sh`, but tests don't verify:
   - Timeout behavior
   - Malformed JSON from subprocess
   - Signal handling (SIGTERM/SIGINT)
   - `ctx.Done()` cancellation propagation
2. **No fuzz tests** — `ExtractSections` parses untrusted markdown but has no fuzz coverage for pathological inputs (deeply nested fences, non-UTF-8, etc.)
3. **No tests for `tools.go`** — MCP tool handlers (`extractSectionsTool`, `classifySectionsTool`) have zero test coverage

**Recommendation**: Add a `TestClassifySubprocessFailure` using a mock script that returns non-JSON garbage, and a `TestClassifyContextCancellation` that verifies early exit.

### API Design Consistency ✅
- **Accept interfaces, return structs**: `Classify` returns concrete `ClassifyResult`, not interface
- **Slice return convention**: Empty slices, not `nil` (`[]ClassifiedSection{}` in error cases)
- **Pointer receivers**: Only `Section` methods (`Preview()`, `FirstSentence()`) use value receivers (structs are small, copy is cheap)
- **Nilable parameters**: `result *classify.ClassifyResult` is nil-checked in `GenerateAgentFiles`

One minor inconsistency: `parseAgentsArg` returns `nil` for empty input, but could return `[]AgentDomain{}` to match slice convention. Not a bug, just style preference.

### Complexity Budget ✅
- **No premature abstractions**: No interfaces where concrete types suffice
- **Clear responsibilities**: Each package has a single purpose
- **Helper functions**: Small, focused (`splitLines`, `fenceMarker`, `collectSections`)
- **Stateless functions**: All top-level functions are pure or depend only on explicit parameters (no hidden global state)

The 341-line `classify.go` is dense but not convoluted — most complexity is in `buildResult`, which handles domain mismatch guards and the 80% threshold upgrade. Could be split into helper functions but current structure is navigable.

### Dependency Discipline ✅
- **Only one external dependency**: `github.com/mark3labs/mcp-go` (required for MCP protocol)
- **Standard library preferred**: `os`, `os/exec`, `encoding/json`, `strings`, `fmt` — no unnecessary packages
- **No vendoring**: Relies on Go modules for reproducibility

---

## Go-Specific Review

### Error Handling Patterns ✅ (Excellent)
Already covered above — context-preserving `%w`, structured error returns, cleanup on failure. No discarded errors found (`grep "_ = err" → zero results`).

### Naming Convention ✅
**5-second rule for exported symbols**:
- `ExtractSections` → immediately clear
- `AgentDomain` → unambiguous
- `ClassifyResult` → self-documenting
- `GenerateAgentFiles` → verb makes intent obvious

**Private helpers**:
- `splitLines`, `fenceMarker`, `truncateRunes` → short, clear, localized scope
- `buildResult`, `buildEmptySections` → verb prefix for constructors

No violations of Go naming idioms.

### File/Module Organization ✅
- **No overgrown files**: Longest file is `classify.go` at 341 lines (acceptable for core domain logic)
- **Single responsibility**: Each file has one job:
  - `extract.go` → parsing
  - `classify.go` → classification orchestration + result building
  - `prompt.go` → prompt construction (62 lines, could have been in `classify.go` but separation is fine)
  - `tempfiles.go` → file generation

No need to split further — files are cohesive.

### Accept Interfaces, Return Structs ✅
All public functions return concrete types:
```go
func ExtractSections(doc string) []Section
func Classify(...) ClassifyResult
func GenerateAgentFiles(...) (map[string]string, error)
```

No unnecessary interface abstractions.

### Imports ✅
Standard Go grouping (stdlib, external, internal):
```go
import (
    "context"
    "encoding/json"
    "fmt"
    "os"

    "github.com/mark3labs/mcp-go/mcp"
    "github.com/mark3labs/mcp-go/server"
    "github.com/mistakeknot/interserve/internal/classify"
)
```

Follows `goimports` conventions — no violations.

### Testing ✅ (Core Logic), ⚠️ (Subprocess)
**Strengths**:
- **Table-driven tests**: `TestBuildResultAppliesEightyPercentThreshold` uses subtests appropriately
- **Helper functions**: `cleanupTempFiles(t, files)` uses `t.Helper()` correctly
- **Clear failure messages**: All `t.Fatalf` calls include context
- **Temp dir cleanup**: Uses `t.TempDir()` for automatic cleanup

**Gaps**:
- No race detection tests mentioned (project should run `go test -race` in CI)
- No fuzz tests for parsing logic
- No subprocess integration tests

**Recommendation**: Add `TestClassifyDispatchTimeout` and run `go test -race ./...` in CI.

---

## Go 1.23 Compatibility Issue ⚠️

### Custom `min()` Function — REMOVE IT
**File**: `internal/extract/extract.go`
```go
func min(a, b int) int { if a < b { return a }; return b }
```

**Problem**: Go 1.23 includes `min()` in the standard library ([builtin package](https://pkg.go.dev/builtin@go1.23.0#min)). The custom implementation is now redundant and conflicts with best practices.

**Impact**: Low (code works fine), but this is technical debt.

**Fix**:
```diff
- func min(a, b int) int { if a < b { return a }; return b }
+ // Remove custom min() — Go 1.23 has it in builtin
```

Change usage in `extract.go`:
```go
end := min(50, count)  // This now uses builtin.min
```

No other changes needed — Go's `min()` is a generic function that works with any ordered type, including `int`.

---

## Test Quality Deep Dive

### extract_test.go ✅ (8 tests, comprehensive)
- **Basic parsing**: Preamble handling, multi-section docs
- **Fence awareness**: Ignores `## ` inside ```` ``` ```` and `~~~` blocks
- **Edge cases**: Unclosed fences, YAML frontmatter, empty sections
- **Preview logic**: Small sections (≤50 lines), large sections (head+tail with omission marker)

**Coverage**: Excellent — all major code paths tested.

### classify_test.go ✅ (Core Logic), ⚠️ (Subprocess)
**Strengths**:
- `TestBuildPromptIncludesAgentsAndHeadings`: Verifies prompt structure
- `TestBuildPromptApproxTokenBudgetForTwentySections`: Guards against token explosion (8000 token limit)
- `TestBuildResultAppliesEightyPercentThreshold`: Verifies 80% threshold upgrade (2 subtests)
- `TestBuildResultDomainMismatchGuard`: Verifies 10% threshold rejection

**Issue**: Domain mismatch test is **unclear about threshold boundaries**:
```go
// Test comment: "5/50 = 10%"
classified := map[int][]SectionAssignment{
    1: {{Agent: "fd-safety", Relevance: "priority", Confidence: 0.6}}, // 5/50 = 10%
}
result := buildResult(classified, sections, agents)
if result.Status != "no_classification" { ... }
```

**Problem**: 10% is the **exact threshold** in the code:
```go
if result.SlicingMap[agent.Name].TotalPriorityLines*100/totalLines > 10 {
    anyAboveThreshold = true
}
```

The test expects `no_classification` for exactly 10%, but the code uses `>` (strictly greater than), so 10% should **fail** the guard. The test comment says "5/50 = 10%" but the code creates 10 sections of 5 lines each (total = 50), with section 1 (5 lines) assigned → 5/50 = 10%. Since `10 > 10` is false, the guard should trigger `no_classification`.

**Verdict**: Test is **correct**, but the threshold boundary is fragile. If someone changes `> 10` to `>= 10`, the test will break.

**Recommendation**: Add explicit boundary tests:
```go
t.Run("exactly 10 percent triggers mismatch", func(t *testing.T) { /* 10/100 → no_classification */ })
t.Run("11 percent passes mismatch guard", func(t *testing.T) { /* 11/100 → success */ })
```

### tempfiles_test.go ✅ (2 tests, good coverage)
- `TestGenerateAgentFiles_PrioritySections`: Verifies full file structure (header, priority sections, context summaries, footer)
- `TestGenerateAgentFiles_SkipsZeroPriority`: Verifies no files created for agents with zero priority lines

**Coverage**: Solid — tests the happy path and the skip-zero-priority guard.

**Gap**: No test for `cross-cutting agent filtering`. The code skips `fd-architecture` and `fd-quality`:
```go
if classify.CrossCuttingAgents[agent] {
    continue
}
```

The first test **does** verify this (checks that `fd-architecture` file is NOT created), but the assertion is indirect:
```go
if len(files) != 1 { t.Fatalf("expected 1 generated file, got %d", len(files)) }
if _, ok := files["fd-architecture"]; ok { t.Fatalf("cross-cutting agent should not get a temp file") }
```

This is fine, but could be more explicit. Consider a dedicated test:
```go
func TestGenerateAgentFiles_SkipsCrossCuttingAgents(t *testing.T) { /* only cross-cutting agents → zero files */ }
```

---

## Risky Code Patterns

### 1. Subprocess Handling — No Timeout Enforcement ⚠️
**File**: `classify.go`
```go
cmd := exec.CommandContext(ctx, "bash", dispatchPath, ...)
combined, err := cmd.CombinedOutput()
if err != nil {
    stderr := strings.TrimSpace(string(combined))
    if stderr == "" { stderr = err.Error() }
    return ClassifyResult{..., Error: fmt.Sprintf("dispatch failed: %s", stderr)}
}
```

**Issue**: `CommandContext` respects `ctx.Done()`, but there's no explicit timeout in the calling code. If `dispatch.sh` hangs, the caller is responsible for cancellation.

**Impact**: Low in production (dispatch.sh has internal timeouts), but no tests verify this.

**Recommendation**: Add a test with a mock script that sleeps forever and verify `ctx` cancellation:
```go
func TestClassifyContextCancellation(t *testing.T) {
    ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
    defer cancel()
    result := classify.Classify(ctx, "/path/to/slow-script", sections, agents)
    if result.Status == "success" {
        t.Fatal("expected timeout failure")
    }
}
```

### 2. Temp File Cleanup — Best Effort, Not Guaranteed ✅ (Acceptable)
**File**: `classify.go`
```go
defer os.Remove(promptPath)
defer os.Remove(outputPath)
```

**Pattern**: Uses `defer` for cleanup, but doesn't check error. If `os.Remove` fails (file locked, permission denied), the temp file leaks.

**Verdict**: **Acceptable** — temp files are in `os.TempDir()`, which is periodically cleaned by the OS. Explicit error handling would add noise without meaningful benefit.

### 3. JSON Parsing — No Schema Validation ⚠️
**File**: `classify.go`
```go
var decoded dispatchResponse
if err := json.Unmarshal([]byte(payload), &decoded); err != nil {
    return ClassifyResult{..., Error: fmt.Sprintf("invalid classification JSON: %v", err)}
}
```

**Issue**: After unmarshaling, no validation that `decoded.Sections` is non-empty or that `section_id` values are valid (positive, within range).

**Impact**: Low (AI output is usually well-formed), but malformed JSON could cause logic bugs downstream.

**Recommendation**: Add validation after unmarshal:
```go
if len(decoded.Sections) == 0 {
    return ClassifyResult{..., Error: "dispatch returned empty sections array"}
}
for _, section := range decoded.Sections {
    if section.SectionID <= 0 {
        return ClassifyResult{..., Error: fmt.Sprintf("invalid section_id: %d", section.SectionID)}
    }
}
```

---

## Code Smells

### 1. `tools.go` — No Tests ⚠️
**File**: `internal/tools/tools.go`
**Issue**: MCP tool handlers have **zero test coverage**. This is risky because:
- Argument parsing (`requiredString`, `parseAgentsArg`) is untested
- JSON serialization (`jsonResult`) is untested
- Error path coverage is unknown

**Recommendation**: Add `tools_test.go` with:
```go
func TestRequiredStringValidation(t *testing.T) { /* missing arg, empty string */ }
func TestParseAgentsArg(t *testing.T) { /* string array, object array, invalid types */ }
func TestExtractSectionsToolHandler(t *testing.T) { /* mock MCP request */ }
```

### 2. Magic Numbers — 80% and 10% Thresholds 🤔
**File**: `classify.go`
```go
if result.SlicingMap[agent.Name].TotalPriorityLines*100/totalLines > 10 { ... }
if slice.TotalPriorityLines*100/totalLines >= 80 { ... }
```

**Issue**: Hardcoded thresholds with no explanation. Why 10%? Why 80%?

**Impact**: Low (domain logic is subjective), but lacks clarity.

**Recommendation**: Extract to named constants with comments:
```go
const (
    // DomainMismatchThreshold: if no agent has >10% priority lines, reject classification
    DomainMismatchThreshold = 10

    // FullDocumentThreshold: if agent has >=80% priority lines, upgrade to full doc
    FullDocumentThreshold = 80
)
```

### 3. `stripCodeFences` — Not Shown, But Referenced ⚠️
**File**: `classify.go`
```go
payload = stripCodeFences(payload)
```

**Issue**: This function is called but not included in the provided source. Cannot review without seeing implementation.

**Assumption**: Strips ```` ```json ... ``` ```` from AI output. If it uses regex, verify it handles nested fences correctly.

---

## Security & Trust

### Subprocess Injection — SAFE ✅
```go
cmd := exec.CommandContext(ctx, "bash", dispatchPath, "--tier", "fast", ...)
```

**Verdict**: Safe — no user input in `dispatchPath` (comes from `main.go` env var or hardcoded default). All flags are static strings.

### Temp File Permissions — SAFE ✅
```go
os.WriteFile(path, []byte(content), 0o600)  // Owner read-write only
os.MkdirAll(tmpDir, 0o755)                  // Standard directory perms
```

**Verdict**: Conservative permissions — temp files are not world-readable.

### Path Traversal — SAFE (Assuming Validation Upstream) ⚠️
**File**: `tools.go`
```go
doc, err := os.ReadFile(filePath)
```

**Issue**: No validation that `filePath` is within expected bounds. If MCP client passes `../../etc/passwd`, this will read it.

**Mitigation**: This is a local MCP server (no network exposure), and the client (Claude Code) is trusted. No ACL enforcement needed.

**Verdict**: Acceptable for local use, but document the trust boundary.

---

## Performance Considerations

### 1. Subprocess Overhead — Acceptable ⚠️
Every classification shells out to `dispatch.sh`, which itself calls `claude` (another process). This is **expensive** but unavoidable given the architecture.

**Mitigation**: Classification results are meant to be cached (caller's responsibility).

### 2. String Builder Usage — GOOD ✅
`prompt.go` and `tempfiles.go` use `strings.Builder` for concatenation:
```go
var b strings.Builder
fmt.Fprintf(&b, "Section %d\n", section.ID)
```

**Verdict**: Idiomatic and efficient — avoids `+` concatenation in loops.

### 3. Unnecessary Allocations in `collectSections` 🤔
```go
out := make([]extract.Section, 0, len(ids))
seen := make(map[int]bool, len(ids))
```

Pre-allocating with `len(ids)` capacity is good, but `seen` map could be optimized:
- If `ids` has no duplicates (common case), `seen` is wasted work
- Could use a comment: `// Dedup in case classification assigned same section multiple times`

**Verdict**: Premature optimization — keep it for robustness.

---

## Documentation Quality

### Exported Functions — GOOD ✅
```go
// GenerateAgentFiles writes per-agent temp files based on classification results.
// Returns a map of agent name → temp file path.
// Agents with zero priority sections are skipped (not dispatched).
func GenerateAgentFiles(...) (map[string]string, error)
```

Clear docstrings for all exported functions.

### Internal Helpers — SPARSE ⚠️
```go
func buildResult(classified map[int][]SectionAssignment, sections []extract.Section, agents []AgentDomain) ClassifyResult
```

No docstring for the **most complex function** in the codebase (handles domain mismatch guard, 80% threshold upgrade). Add a comment block:
```go
// buildResult constructs the final ClassifyResult, applying:
// 1. Domain mismatch guard: reject if no agent has >10% priority lines
// 2. Full-doc upgrade: if agent has >=80% priority lines, promote all sections to priority
// 3. Per-section normalization: filter invalid assignments, clamp confidence to [0,1]
func buildResult(...) ClassifyResult
```

### Package-Level Comments — MISSING ⚠️
None of the packages have a package docstring. Add to each:
```go
// Package extract parses markdown documents into sections delimited by ## headings,
// honoring fenced code blocks and YAML frontmatter.
package extract
```

---

## Recommendations Summary

### Critical (Fix Before Merge)
1. **Remove custom `min()` function** — Go 1.23 has it in builtin
2. **Add subprocess integration tests** — timeout, cancellation, malformed JSON
3. **Add `tools_test.go`** — MCP handler logic is untested

### High Priority (Fix Soon)
4. **Add boundary tests for domain mismatch threshold** — 10% exact boundary is fragile
5. **Document `buildResult` complexity** — most intricate logic in codebase
6. **Extract magic numbers to constants** — 10% and 80% thresholds

### Medium Priority (Technical Debt)
7. **Add package-level docstrings** — improves `go doc` output
8. **Validate JSON schema after unmarshal** — guard against malformed AI output
9. **Run `go test -race ./...` in CI** — verify no data races

### Low Priority (Nice to Have)
10. **Add fuzz tests for `ExtractSections`** — pathological markdown inputs
11. **Dedicated cross-cutting agent test** — clarify `tempfiles.go` skip logic

---

## Verdict

**Status**: Production-ready with minor improvements
**Go Idiom Score**: 9/10 (loses point for custom `min()`)
**Test Coverage**: 7/10 (core logic strong, subprocess/tools weak)
**Error Handling**: 10/10 (exemplary `%w` wrapping and cleanup)

The code demonstrates strong Go fundamentals. Fix the `min()` function, add subprocess tests, and this is a solid, maintainable codebase.
