# Correctness Review: interserve MCP Server
**Reviewed**: 2026-02-16
**Reviewer**: Julik (Flux-drive Correctness Reviewer)
**Scope**: Data consistency, subprocess lifecycle, JSON parsing edge cases, arithmetic correctness

---

## Executive Summary

**Overall verdict**: Safe for production with caveats. No show-stopping correctness issues found.

**Critical findings**:
- None (no data corruption or resource leak bugs)

**High priority**:
1. Integer division boundary condition in threshold guard (10% exact fails the check — likely intentional but undocumented)
2. Potential temp file collision in high-throughput scenarios (same-second writes)
3. JSON parsing missing type validation for section_id

**Low priority**:
4. stdout contamination risk in subprocess output (already mitigated by `--sandbox read-only`)
5. Context timeout behavior underdocumented

---

## 1. Subprocess Lifecycle (classify.go lines 76-122)

### Resource Cleanup
**Status**: ✅ Correct

```go
promptFile, err := os.CreateTemp("", "interserve-prompt-*.txt")
// ...
promptPath := promptFile.Name()
defer os.Remove(promptPath)
```

**Analysis**:
- Both `promptPath` and `outputPath` use `defer os.Remove()` immediately after capturing path
- Cleanup happens on all exit paths (success, error, panic)
- File handles closed before subprocess starts → no lock contention

**Edge case verified**: Early return paths (lines 78, 86, 93, 97) all exit after defer registration → cleanup still runs.

### Subprocess Hang Protection
**Status**: ✅ Correct

```go
cmd := exec.CommandContext(ctx, "bash", dispatchPath, ...)
```

**Analysis**:
- Uses `context.Context` via `exec.CommandContext()` → subprocess killed if context canceled
- Caller (MCP request handler) should enforce MCP-level timeout
- If dispatch.sh hangs indefinitely and context has no deadline, process leaks

**Recommendation**: Document expected context timeout policy in MCP handler layer. If no timeout exists, add one at the MCP request boundary (e.g., 5 minutes for fast tier, 30 minutes for slow tier).

### stdout Contamination Risk
**Status**: ⚠️ Low risk, mitigated by design

```go
combined, err := cmd.CombinedOutput()
// ...
payload := strings.TrimSpace(string(rawOutput))
if payload == "" {
    payload = strings.TrimSpace(string(combined))
}
```

**Analysis**:
- `CombinedOutput()` merges stdout and stderr into `combined`
- Primary read from `outputPath` (file output), fallback to `combined` only if file is empty
- If dispatch.sh writes debug logs to stdout, they'll contaminate the fallback path
- Mitigation: `dispatch.sh` runs with `--sandbox read-only` → stderr-only logging convention likely enforced

**Risk scenario**:
1. dispatch.sh writes valid JSON to `-o outputPath`
2. Also writes "DEBUG: classification complete" to stdout
3. `outputPath` read succeeds → contamination never happens

**Failure mode**: If `outputPath` write fails silently but dispatch writes partial JSON to stdout, fallback reads mixed output → JSON parse fails → graceful degradation to `statusNoClassification`.

**Verdict**: Low risk. Current design recovers correctly. Consider logging a warning if fallback path is used so operators can detect dispatch bugs.

### Race Between Prompt Write and Dispatch Read
**Status**: ✅ No race

```go
if _, err := promptFile.WriteString(prompt); err != nil {
    _ = promptFile.Close()
    return classifyError(...)
}
if err := promptFile.Close(); err != nil {
    return classifyError(...)
}
// Only now:
cmd := exec.CommandContext(ctx, "bash", dispatchPath, "--prompt-file", promptPath, ...)
```

**Analysis**:
- File fully written and closed before subprocess starts
- OS page cache + close() ensures all bytes visible to subprocess
- No TOCTOU race

---

## 2. Threshold Arithmetic (classify.go lines 265-294)

### Integer Division Boundary Conditions

#### 10% Domain Mismatch Guard (line 268)
**Status**: ⚠️ Boundary condition unclear

```go
if result.SlicingMap[agent.Name].TotalPriorityLines*100/totalLines > 10 {
```

**Problem**: Strict inequality (`>`) means **10.0% exactly fails the guard**.

**Test cases**:
| Priority Lines | Total Lines | Calculation | Result |
|---------------|-------------|-------------|---------|
| 5 | 50 | `5*100/50 = 10` | ❌ Fails (10 not > 10) |
| 6 | 50 | `6*100/50 = 12` | ✅ Passes |
| 10 | 100 | `10*100/100 = 10` | ❌ Fails |
| 11 | 100 | `11*100/100 = 11` | ✅ Passes |
| 1000 | 10000 | `1000*100/10000 = 10` | ❌ Fails |

**Is this intentional?** If the design is "reject documents where no agent has MORE than 10%", current code is correct. If the design is "reject when no agent has AT LEAST 10%", change to `>= 10`.

**Recommendation**: Add a comment clarifying intent:
```go
// Domain mismatch guard: if no agent has >10% priority lines (strict, so 10% exactly fails)
```

Or change to `>= 11` (equivalent to "at least 11%") if 10% should pass.

#### 80% Full-Doc Upgrade (line 287)
**Status**: ✅ Correct

```go
if slice.TotalPriorityLines*100/totalLines >= 80 {
```

**Analysis**: Inclusive threshold (`>=`) means 80.0% exactly triggers full-doc upgrade. This is typically desired behavior.

**Test cases**:
| Priority Lines | Total Lines | Calculation | Result |
|---------------|-------------|-------------|---------|
| 80 | 100 | `80*100/100 = 80` | ✅ Full doc (80 >= 80) |
| 79 | 100 | `79*100/100 = 79` | ❌ Sliced (79 < 80) |
| 800 | 1000 | `800*100/1000 = 80` | ✅ Full doc |
| 799 | 1000 | `799*100/1000 = 79` | ❌ Sliced |

**Verdict**: Boundary behaves as expected. No issue.

### Integer Overflow
**Status**: ✅ Safe for realistic inputs

**Analysis**:
- `TotalPriorityLines` is `int` (platform-dependent, but at least 32 bits)
- Maximum intermediate value: `TotalPriorityLines * 100`
- Overflow threshold: 2^31 / 100 = 21,474,836 lines (for 32-bit int)
- Even for multi-MB documents, line counts rarely exceed 100k

**Worst case**: A 100MB markdown file with 1-byte lines would have ~100M lines → overflow risk.

**Recommendation**: Add overflow guard if processing untrusted documents:
```go
if totalLines > 10_000_000 { // ~100MB markdown
    return ClassifyResult{..., Error: "document too large for classification"}
}
```

### Division by Zero
**Status**: ✅ Guarded

```go
if totalLines <= 0 {
    return result
}
```

Lines 261-263 prevent all division by zero in lines 268 and 287.

---

## 3. Section ID Consistency

### ID Assignment (extract.go lines 22-43)
```go
nextID := 1
emit := func(heading string, bodyLines []string, isPreamble bool) {
    sections = append(sections, Section{
        ID: nextID,
        // ...
    })
    nextID++
}
```

**Analysis**: Sequential ID assignment starting from 1. IDs are deterministic and unique within a document.

### Round-Trip Through Dispatch (classify.go lines 153-158)
```go
classified := make(map[int][]SectionAssignment, len(decoded.Sections))
for _, section := range decoded.Sections {
    classified[section.SectionID] = append(classified[section.SectionID], section.Assignments...)
}
```

**Analysis**:
- Codex dispatch receives section metadata with IDs in the prompt (see `BuildPrompt()`)
- Returns assignments keyed by `section_id`
- If Codex returns a section_id not in the original document, it's silently ignored (line 222 lookup succeeds but no corresponding Section exists)

**Failure mode**: Codex invents section_id=999 → lookup in `classified[999]` creates empty slice → `normalizeAssignments()` processes empty list → no impact on output.

**Verdict**: Safe. Invalid section IDs are benignly ignored.

### JSON Type Mismatch (dispatchSection.SectionID)
**Status**: ⚠️ Type validation missing

```go
type dispatchSection struct {
    SectionID   int                 `json:"section_id"`
    Assignments []SectionAssignment `json:"assignments"`
}
```

**Problem**: If Codex returns `"section_id": "42"` (string instead of int), `json.Unmarshal()` fails with a type error.

**Current behavior**:
```go
if err := json.Unmarshal([]byte(payload), &decoded); err != nil {
    return ClassifyResult{
        Status: statusNoClassification,
        // ...
        Error: fmt.Sprintf("invalid classification JSON: %v", err),
    }
}
```

**Analysis**: JSON parse failure triggers graceful degradation to `statusNoClassification`. No data corruption.

**Recommendation**: Accept current behavior (robust error handling). Optionally add schema validation if you want to distinguish "Codex returned malformed JSON" from "Codex returned wrong types" for debugging.

---

## 4. Map Mutation During Iteration (classify.go lines 255-259)

```go
for agent, slice := range result.SlicingMap {
    sort.Ints(slice.PrioritySections)
    sort.Ints(slice.ContextSections)
    result.SlicingMap[agent] = slice
}
```

**Status**: ✅ Safe in Go

**Analysis**:
- Go spec allows updating existing map keys during `range` iteration
- Only prohibited operation is adding/deleting keys during iteration
- This code only updates values at existing keys → safe

**Reference**: [Go spec: For statements with range clause](https://golang.org/ref/spec#For_statements)

---

## 5. Temp File Collision (tempfiles.go lines 37-48)

### Collision Scenario
```go
ts := time.Now().Unix()
fileName := fmt.Sprintf("flux-drive-%s-%d-%s.md", inputStem, ts, agent)
```

**Problem**: If two `GenerateAgentFiles()` calls execute within the same second with the same `inputStem`, they generate identical filenames.

**Risk assessment**:
- `time.Now().Unix()` returns seconds since epoch → 1-second resolution
- If two MCP requests arrive within 1 second and target the same temp directory, collision occurs
- Second write overwrites first → previous agent's temp file silently replaced

**Failure narrative**:
1. Request A: `GenerateAgentFiles("doc", ...)` at timestamp `1739750400` → writes `flux-drive-doc-1739750400-julik.md`
2. Request B: `GenerateAgentFiles("doc", ...)` at timestamp `1739750400` (same second) → overwrites `flux-drive-doc-1739750400-julik.md`
3. If request A is still reading the file, it sees corrupted content (partial write from request B)

**Mitigation**: Use `os.CreateTemp()` instead of manual filename generation:
```go
tmpFile, err := os.CreateTemp(tmpDir, fmt.Sprintf("flux-drive-%s-*-%s.md", inputStem, agent))
if err != nil {
    // cleanup...
}
defer tmpFile.Close()
path := tmpFile.Name()
```

`CreateTemp()` adds random suffix → collision-free even within same second.

**Current mitigating factors**:
- MCP requests are typically serialized (one agent at a time)
- Even if concurrent, different `inputStem` values avoid collision
- File contents written atomically via `os.WriteFile()` → readers see either old or new, not partial

**Verdict**: Low-priority fix. Collision unlikely in practice but trivial to eliminate.

---

## 6. JSON Parsing Edge Cases

### Code Fence Stripping (classify.go lines 321-340)

```go
func stripCodeFences(raw string) string {
    trimmed := strings.TrimSpace(raw)
    if !strings.HasPrefix(trimmed, "```") {
        return trimmed
    }

    lines := strings.Split(trimmed, "\n")
    if len(lines) == 0 {
        return ""
    }

    lines = lines[1:] // Drop opening fence
    for len(lines) > 0 && strings.TrimSpace(lines[len(lines)-1]) == "" {
        lines = lines[:len(lines)-1]
    }
    if len(lines) > 0 && strings.HasPrefix(strings.TrimSpace(lines[len(lines)-1]), "```") {
        lines = lines[:len(lines)-1] // Drop closing fence
    }
    return strings.TrimSpace(strings.Join(lines, "\n"))
}
```

#### Test Case: ````json` (4 backticks)
**Input**:
```
````json
{"sections": []}
````
```

**Analysis**:
- `strings.HasPrefix(trimmed, "```")` matches (first 3 chars are backticks)
- Opening fence `````json` dropped entirely (line 332)
- Closing fence `````" matched by `strings.HasPrefix(..., "```")` → dropped
- Result: `{"sections": []}`

**Verdict**: ✅ Handles 4-backtick fences correctly (treats them as 3-backtick fences).

#### Test Case: Backtick in JSON Content
**Input**:
```
```json
{"sections": [{"note": "Use ``` for code"}]}
```
```

**Analysis**:
- Opening fence `\```json` dropped
- Content: `{"sections": [{"note": "Use ``` for code"}]}`
- Closing fence logic checks `strings.HasPrefix(lines[len(lines)-1], "```")` → matches `\````, not the embedded backticks
- Result: Correct JSON

**Verdict**: ✅ Embedded backticks in JSON strings do not trigger false fence detection.

#### Test Case: Unclosed Fence
**Input**:
```
```json
{"sections": []}
```

**Analysis**:
- Opening fence dropped
- Loop at line 333 trims trailing empty lines
- Line 336 checks last line for closing fence → not found (no trailing `\```)
- Result: `{"sections": []}`

**Verdict**: ✅ Handles unclosed fences gracefully (returns content without fence).

### Confidence Clamping (classify.go lines 310-315)
```go
if a.Confidence < 0 {
    a.Confidence = 0
}
if a.Confidence > 1 {
    a.Confidence = 1
}
```

**Status**: ✅ Correct

**Analysis**: Silently clamps out-of-range confidence values. Prevents downstream consumers from seeing invalid probabilities.

**Edge case**: What if Codex returns `"confidence": "high"` (string instead of float)?
- `json.Unmarshal()` would fail at parse time (line 144) → graceful degradation to `statusNoClassification`
- No silent corruption

---

## 7. Concurrency Analysis

### Thread Safety
**Current scope**: Single-threaded (no goroutines spawned).

**Future risk**: If `Classify()` is called concurrently from multiple MCP requests:
- Temp file names use `time.Now().Unix()` → collision risk (covered in section 5)
- No shared mutable state between calls → no data races
- Each call owns its own `ClassifyResult` → no cross-contamination

**Recommendation**: If adding concurrency (e.g., parallel dispatch to multiple agents), switch to `os.CreateTemp()` for collision-free temp file creation.

### Context Cancellation
**Status**: ✅ Subprocess respects cancellation

```go
cmd := exec.CommandContext(ctx, "bash", dispatchPath, ...)
```

**Analysis**: If MCP request is canceled (e.g., client disconnect), `ctx.Done()` channel closes → subprocess receives `SIGKILL` → temp files cleaned up via `defer`.

**Edge case**: What if subprocess ignores SIGKILL?
- Not possible — SIGKILL is uncatchable
- Process dies immediately
- Temp files cleaned up by OS (files closed when process exits)

**Verdict**: Cancellation behavior is correct.

---

## 8. Data Consistency Invariants

### Invariant 1: Section IDs are unique within a document
**Enforcement**: `nextID++` in `extract.go` line 42.
**Status**: ✅ Guaranteed by sequential assignment.

### Invariant 2: SlicingMap contains all agents (even with zero sections)
**Enforcement**: `buildEmptySlicingMap()` pre-populates all agents.
**Status**: ✅ Preserved through all code paths (lines 213, 119, 138, etc.).

### Invariant 3: No section appears in both Priority and Context for the same agent
**Enforcement**: `prioritySeen` and `contextSeen` deduplication maps (lines 216-252).
**Status**: ✅ Verified — `prioritySeen[agent][section.ID]` prevents duplicates.

**Edge case**: What if Codex returns duplicate assignments?
```json
{"section_id": 1, "assignments": [
    {"agent": "julik", "relevance": "priority"},
    {"agent": "julik", "relevance": "priority"}
]}
```

**Analysis**:
- Line 222 iterates `normalized` assignments
- Line 236 checks `!prioritySeen[assignment.Agent][section.ID]`
- First occurrence sets `prioritySeen[agent][1] = true`
- Second occurrence skipped → no duplicate in final slice

**Verdict**: ✅ Deduplication logic is correct.

### Invariant 4: TotalPriorityLines matches sum of section.LineCount for all PrioritySections
**Enforcement**: Line 238 increments `slice.TotalPriorityLines += section.LineCount` in lockstep with `slice.PrioritySections = append(...)`.
**Status**: ✅ Consistent.

**Edge case**: 80% upgrade path (lines 287-293) replaces sections with full doc:
```go
slice.PrioritySections = allSectionIDs
slice.TotalPriorityLines = totalLines
```

**Analysis**: Correctly overwrites both slice composition AND line count → invariant preserved.

---

## 9. Error Handling Completeness

### Classified Error Paths
| Error Scenario | Recovery Path | Data Corruption Risk |
|---------------|---------------|---------------------|
| Temp file creation fails | `classifyError()` → `statusNoClassification` | ✅ None |
| Temp file write fails | `classifyError()` → cleanup via `defer` | ✅ None |
| Subprocess fails | Return empty classification with error message | ✅ None |
| Output file unreadable | `classifyError()` | ✅ None |
| JSON parse failure | Return `statusNoClassification` with error | ✅ None |
| Invalid section_id | Silently ignored (benign) | ✅ None |

**Verdict**: All error paths degrade gracefully to "no classification available" without corrupting data or leaking resources.

---

## Recommendations

### Critical (fix before production)
None identified.

### High Priority
1. **Document the 10% threshold boundary behavior** (line 268):
   - Add comment: `// Strict inequality: 10.0% exactly does NOT pass`
   - Or change to `>= 10` if intent is "at least 10%"

2. **Fix temp file collision risk** (tempfiles.go line 48):
   ```go
   tmpFile, err := os.CreateTemp(tmpDir, fmt.Sprintf("flux-drive-%s-*-%s.md", inputStem, agent))
   // ... handle err
   path := tmpFile.Name()
   if _, err := tmpFile.WriteString(content); err != nil { /* cleanup */ }
   _ = tmpFile.Close()
   ```

3. **Add context timeout documentation** (classify.go line 61):
   - Document expected timeout policy in function comment
   - Recommend 5min for fast tier, 30min for slow tier

### Low Priority
4. **Log warning when fallback to stdout is used** (classify.go line 131):
   ```go
   if payload == "" {
       // Fallback to combined stdout/stderr (dispatch may have failed to write output file)
       payload = strings.TrimSpace(string(combined))
   }
   ```

5. **Add overflow guard for pathological documents** (classify.go line 261):
   ```go
   if totalLines > 10_000_000 {
       return ClassifyResult{..., Error: "document too large"}
   }
   ```

---

## Conclusion

The interserve MCP server demonstrates robust error handling and correct resource lifecycle management. No critical correctness issues found.

The identified issues are:
1. **Boundary condition ambiguity** in threshold logic (documentation fix)
2. **Temp file collision** in high-throughput scenarios (trivial fix with `os.CreateTemp()`)
3. **Missing context timeout documentation** (add function comment)

All three are low-risk in typical MCP workloads (single-threaded, low QPS). The codebase is production-ready with the understanding that concurrent usage may require the temp file fix.

**Overall safety grade**: A- (robust, with minor documentation/collision gaps)
