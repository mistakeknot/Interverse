# Quality Review: Interlock Reservation Negotiation Protocol Implementation Plan

**Reviewer:** Flux-drive Quality & Style Reviewer
**Date:** 2026-02-16
**Plan:** `/root/projects/Interverse/docs/plans/2026-02-15-interlock-reservation-negotiation.md`
**Focus:** Code quality, naming conventions, Go idioms, test approach, error handling, and bash safety

---

## Executive Summary

The plan is **structurally sound** and incorporates most flux-drive amendments, but contains **12 quality issues** spanning Go error wrapping, helper function inconsistency, test coverage gaps, bash injection risks, and documentation update errors. All issues are correctable within the existing task structure.

**Critical findings:**
1. **Amendment A7 incompletely applied** — error wrapping uses `%v` in 4 locations despite mandate for `%w`
2. **Helper function naming inconsistency** — `stringOr`, `intOr`, `boolOr` exist but plan doesn't verify or document them
3. **Bash safety gap** — Task 4 uses raw `$REQ_FILE` in jq patterns, creating injection risk
4. **Test coverage incomplete** — Amendment A9 lists 5 missing tests but Task 7 doesn't add them

---

## Go Code Quality Issues

### 1. Error Wrapping: Partial `%w` Adoption (Amendment A7)

**Finding:** Plan mandates `%w` for error chains (Amendment A7), but implementation still uses `%v` in 4 locations.

**Locations:**
- Task 2, line 280: `return mcp.NewToolResultError(fmt.Sprintf("check conflicts: %v", err)), nil`
- Task 2, line 320: `return mcp.NewToolResultError(fmt.Sprintf("send negotiation request: %v", err)), nil`
- Task 3, line 558: `return mcp.NewToolResultError(fmt.Sprintf("list reservations: %v", err)), nil`
- Task 6, line 882: `return 0, err` (correct, but surrounding context uses `%v`)

**Impact:** Error context is lost when errors are wrapped, making debugging harder. The `%v` verb stringifies errors instead of preserving the chain.

**Fix:** Replace all `%v` with `%w` in error formatting:
```go
// Before
return mcp.NewToolResultError(fmt.Sprintf("check conflicts: %v", err)), nil

// After
return mcp.NewToolResultError(fmt.Sprintf("check conflicts: %w", err)), nil
```

**Note:** MCP error results are terminal (returned to client), so wrapping may not propagate further. However, consistency with Go idioms and future refactoring justify the change.

---

### 2. Helper Function Verification Missing

**Finding:** Plan adds `stringOr` helper (Task 2, Step 4, line 456) but doesn't verify whether `intOr` and `boolOr` already exist.

**Context:** Existing `tools.go` (reviewed code) shows:
- Line 684-692: `intOr` exists
- Line 694-699: `boolOr` exists
- Line 701-706: `stringOr` exists

**Impact:** Task 2 Step 4 says "Add `stringOr` helper if not present" but doesn't include a verification step. This creates risk of duplicate definitions or confusion about whether the helper is new.

**Fix:** Update Task 2 Step 4 to explicitly state "Verify helpers exist" instead of conditional addition:
```markdown
**Step 4: Verify helper functions**

The plan uses `stringOr`, `intOr`, `boolOr` helpers. Check `tools.go` lines 684-706:
- `intOr` converts `any` to `int` with fallback
- `boolOr` converts `any` to `bool` with fallback
- `stringOr` converts `any` to `string` with fallback (non-empty check)

All three helpers already exist. No changes needed.
```

---

### 3. Constant Naming Consistency

**Finding:** Plan defines constants `normalTimeoutMinutes`, `urgentTimeoutMinutes`, `negotiationPollInterval` (Amendment A7) but doesn't enforce Go naming convention for exported vs unexported.

**Context:** These are package-level constants in `tools.go`. Current naming follows unexported convention (lowercase first letter), which is correct for internal use.

**Impact:** Low — naming is already correct. But plan doesn't document the decision.

**Fix:** Add comment to Task 2 Step 4 explaining why constants are unexported:
```go
// Package-level unexported constants (used only within tools.go)
const (
	normalTimeoutMinutes    = 10
	urgentTimeoutMinutes    = 5
	negotiationPollInterval = 2 * time.Second
)
```

---

### 4. nil Slice vs Empty Slice Inconsistency

**Finding:** Amendment A7 requires "nil guard to `FetchThread` return (return empty slice, not nil)" but Task 1 implementation returns `nil` in error cases (line 191).

**Context:** Task 1 Step 3 `FetchThread` implementation:
```go
if err := c.doJSON(ctx, "GET", path, nil, &result); err != nil {
    return nil, err  // ❌ returns nil slice
}
```

But reviewed `client.go` (line 301-302) correctly returns empty slice:
```go
if threadID == "" {
    return make([]Message, 0), nil  // ✅ empty slice
}
```

**Impact:** Inconsistent nil handling across error paths. Go idiom prefers empty slices over nil for "no results" scenarios.

**Fix:** Update Task 1 Step 3 to return empty slice on all error paths:
```go
func (c *Client) FetchThread(ctx context.Context, threadID string) ([]Message, error) {
    // ... existing code ...
    if err := c.doJSON(ctx, "GET", path, nil, &result); err != nil {
        return make([]Message, 0), fmt.Errorf("fetch thread %q: %w", threadID, err)
    }
    if result.Messages == nil {
        return make([]Message, 0), nil
    }
    return result.Messages, nil
}
```

---

### 5. Business Logic Layering (Amendment A4)

**Finding:** Amendment A4 mandates moving business logic to client layer, but Task 3 `respondToRelease` still duplicates `patternsOverlap` logic inline (line 563).

**Plan text (Task 3, line 620):**
> Note: `patternsOverlap` is in `client.go` — export it or duplicate the logic. Simplest: copy the same prefix logic as a package-level helper in `tools.go`.

**Context:** Reviewed `client.go` shows `PatternsOverlap` is already exported (line 572), and `ReleaseByPattern` uses it (line 355).

**Impact:** Plan text suggests duplicating logic, but existing code already exports the helper. Task 3 implementation (line 563) calls `patternsOverlap(r.PathPattern, file)` which doesn't exist in `tools.go`.

**Fix:** Update Task 3 Step 1 to use `client.PatternsOverlap` and `client.ReleaseByPattern`:
```go
// Before (plan's inline logic)
for _, r := range reservations {
    if r.IsActive && patternsOverlap(r.PathPattern, file) {
        if err := c.DeleteReservation(ctx, r.ID); err == nil {
            released = true
        }
    }
}

// After (use existing client method)
released, err := c.ReleaseByPattern(ctx, c.AgentID(), file)
if err != nil {
    return nil, fmt.Errorf("release reservations by pattern: %w", err)
}
```

This matches the reviewed implementation (tools.go line 572-575).

---

## Test Coverage Gaps (Amendment A9)

### 6. Missing Unit Tests Not Added in Plan

**Finding:** Amendment A9 lists 5 missing tests but Task 7 ("Final Validation") doesn't add them:
- `TestFetchThread_NotFound`
- `TestFetchThread_EmptyMessages`
- `TestNegotiateRelease_BlockingTimeout`
- Structural test for `INTERLOCK_AUTO_RELEASE` presence
- `TestReleaseByPattern_Idempotent`

**Plan coverage:**
- Task 1: Adds `TestSendMessageFull` and `TestFetchThread` (basic happy path only)
- Task 2: No Go tests added (only structural)
- Task 4: No structural test for `INTERLOCK_AUTO_RELEASE`
- Task 6: No idempotent test for `ReleaseByPattern`

**Impact:** Test suite won't catch edge cases like:
- 404 on `/api/threads/{id}` triggering fallback
- Empty message arrays in thread responses
- Blocking timeout with unresponsive server
- Idempotent force-release when reservation already deleted

**Fix:** Add Task 7b "Add Edge Case Tests":
```markdown
**Step 3b: Add edge case tests**

Add to `internal/client/client_test.go`:
- `TestFetchThread_NotFound` (404 triggers fallback to inbox filtering)
- `TestFetchThread_EmptyMessages` (empty thread returns `[]`, not nil)
- `TestReleaseByPattern_Idempotent` (empty reservation list returns 0)

Add to `internal/tools/tools_test.go` (create if not exists):
- `TestNegotiateRelease_BlockingTimeout` (mock server never responds, tool returns `status:timeout`)

Add to `tests/structural/test_structure.py`:
- `test_auto_release_env_var_in_hook` (assert `INTERLOCK_AUTO_RELEASE` appears in pre-edit.sh)
```

---

## Bash Code Quality Issues

### 7. jq Injection Risk in Task 4 (Amendment A8 Incomplete)

**Finding:** Task 4 auto-release logic (line 751) uses raw `$REQ_FILE` in jq pattern match, creating injection risk:
```bash
echo "$MY_RES" | jq -r ".reservations[]? | select(.path_pattern == \"$REQ_FILE\" or .is_active == true) | .id"
```

**Context:** Amendment A8 mandates "Use `jq --arg` for safe variable injection" but Task 4 implementation doesn't apply it.

**Impact:** If `$REQ_FILE` contains jq metacharacters (e.g., `"`, `\`, `$`), the jq expression can break or execute unintended logic.

**Fix:** Use `jq --arg` for safe interpolation:
```bash
echo "$MY_RES" | jq -r --arg file "$REQ_FILE" '.reservations[]? | select(.path_pattern == $file or .is_active == true) | .id'
```

---

### 8. Redundant `|| true` in Critical Paths

**Finding:** Task 4 auto-release sends messages with `|| true` fail-open (line 767, 771), which is correct for advisory features. But reservation deletion also uses `|| true` (line 753), silently swallowing delete errors.

**Plan text (Task 4, line 753):**
```bash
[[ -n "$res_id" ]] && intermute_curl DELETE "/api/reservations/${res_id}" 2>/dev/null || true
```

**Context:** Amendment A8 says "Existing `|| true` fail-open pattern is correct, keep it" but doesn't distinguish between advisory (messages) and critical (reservations).

**Impact:** If reservation deletion fails (e.g., network error, 404), the agent still sends `release_ack`, creating false acknowledgment. The requester thinks the file is released but reservation still exists.

**Fix:** Remove `|| true` from reservation deletion, keep it for messages:
```bash
# Delete reservation (fail-open on error)
if echo "$MY_RES" | jq -r --arg file "$REQ_FILE" '.reservations[]? | select(.path_pattern == $file and .is_active == true) | .id' | while IFS= read -r res_id; do
    [[ -n "$res_id" ]] && intermute_curl DELETE "/api/reservations/${res_id}" 2>/dev/null
done; then
    # Send release_ack only if deletion succeeded
    # ... (existing message logic)
fi
```

**Alternative (simpler):** Keep current behavior but add a comment explaining the fail-open tradeoff:
```bash
# Advisory auto-release: best-effort delete, send ack regardless (fail-open)
```

---

### 9. Shell Variable Quoting in Task 4

**Finding:** Task 4 uses unquoted variables in case patterns (line 743):
```bash
case "$dirty" in
    $REQ_FILE) HAS_DIRTY=true; break ;;
esac
```

**Context:** This is a glob pattern match, not string equality. If `$REQ_FILE` is `*.go`, the pattern works. But if it's `foo bar.go`, the space causes word-splitting.

**Impact:** File patterns with spaces fail to match dirty files, causing incorrect auto-release.

**Fix:** Quote the case pattern and use explicit glob:
```bash
# Check if any dirty file matches the requested pattern
while IFS= read -r dirty; do
    # Use glob match (bash extended pattern)
    if [[ "$dirty" == $REQ_FILE ]]; then
        HAS_DIRTY=true
        break
    fi
done <<< "$DIRTY_FILES"
```

Or use double-quoted case pattern (no glob, exact match):
```bash
case "$dirty" in
    "$REQ_FILE") HAS_DIRTY=true; break ;;
esac
```

**Recommended:** Use `[[ ... == ... ]]` glob match for consistency with existing interlock hooks.

---

## Structural Test Issues

### 10. Tool Count Update Incomplete

**Finding:** Plan updates tool count from 9 to 11 across 3 tasks:
- Task 2: 9 → 10 (`negotiate_release` added)
- Task 3: 10 → 11 (`respond_to_release` added)

But Task 2 Step 6 and Task 3 Step 3 both say "Update `EXPECTED_TOOLS` to include..." without showing the intermediate state.

**Context:** `test_structure.py` line 62 asserts exact count:
```python
assert len(names) == 11, f"Expected 11 tools, found {len(names)}: {names}"
```

**Impact:** If Task 2 tests are run before Task 3 completes, the count is 10 but the test expects 11.

**Fix:** Split count updates across tasks:
- Task 2 Step 6: Update to 10 tools, add `negotiate_release` to `EXPECTED_TOOLS`
- Task 3 Step 3: Update to 11 tools, add `respond_to_release` to `EXPECTED_TOOLS`

**Plan text correction:**
```markdown
**Task 2, Step 6:**
Update `EXPECTED_TOOLS` to include `"negotiate_release"` (10 tools total).
Update `test_tool_count` assertion to `assert len(names) == 10`.

**Task 3, Step 3:**
Update `EXPECTED_TOOLS` to include `"respond_to_release"` (11 tools total).
Update `test_tool_count` assertion to `assert len(names) == 11`.
```

---

## Documentation Issues

### 11. PRD.md Update Missing Negotiation Features

**Finding:** Task 7 Step 1 says "Add negotiation protocol to feature list" but doesn't specify what to add or where.

**Context:** PRD.md typically has:
- Feature overview
- Tool reference
- Architecture diagrams
- Workflow examples

**Impact:** Vague instruction leads to incomplete or inconsistent documentation updates.

**Fix:** Add specific PRD updates to Task 7 Step 1:
```markdown
**Step 1: Update PRD.md**

- Change "9 tools" to "11 tools" in overview
- Add "Negotiation Protocol" section:
  - `negotiate_release` — structured release requests with urgency + blocking wait
  - `respond_to_release` — ack (release) or defer with ETA
  - Timeout escalation: 5min urgent, 10min normal
  - Auto-release advisory mode via `INTERLOCK_AUTO_RELEASE=1`
- Update tool reference table to include both new tools
- Add workflow example: "Request file release with urgent timeout"
```

---

### 12. AGENTS.md Negotiation Section Already Exists

**Finding:** Task 7 Step 3 says "add negotiation protocol docs" to AGENTS.md, but reviewed AGENTS.md (lines 30-40) already has a comprehensive negotiation section.

**Plan text (Task 7, line 1073):**
```markdown
Update PRD, CLAUDE.md, AGENTS.md with new tool count (11),
negotiation protocol documentation, and updated skill references.
```

**Context:** Existing AGENTS.md includes:
- Negotiation protocol overview
- Tool descriptions
- `INTERLOCK_AUTO_RELEASE` flag
- Timeout escalation rules
- Status visibility

**Impact:** Task may duplicate or overwrite existing content.

**Fix:** Change Task 7 Step 3 to verification instead of addition:
```markdown
**Step 3: Verify AGENTS.md accuracy**

Existing `AGENTS.md` lines 30-40 already document negotiation protocol.
Verify accuracy:
- Tool count is 11 ✓
- `negotiate_release` and `respond_to_release` documented ✓
- Timeout escalation (5min urgent, 10min normal) ✓
- `INTERLOCK_AUTO_RELEASE` advisory mode ✓
- `/interlock:status` pending negotiations table ✓

No changes needed unless implementation differs from docs.
```

---

## Go Idiom Compliance

### Overall Assessment: **Strong**

The plan follows Go idioms well:
- ✅ Accept interfaces, return structs (client returns concrete `[]Message`, not interface)
- ✅ Error wrapping with `fmt.Errorf` (after fixing `%v` → `%w`)
- ✅ Nil-safe slice returns (after fixing Task 1 FetchThread)
- ✅ Constants are unexported (package-private)
- ✅ Helper functions follow `xOr` naming pattern
- ✅ Context propagation (all client methods accept `context.Context`)

**Minor gaps:**
- No `golangci-lint` validation step in Task 7
- No explicit check for `go fmt` compliance

**Recommended addition to Task 7 Step 5:**
```markdown
**Step 5: Lint and format**

Run: `cd plugins/interlock && go fmt ./... && golangci-lint run ./...`
Expected: No format changes, no lint errors
```

---

## Test Strategy Evaluation

### Current Coverage:
- ✅ Unit tests for new client methods (Task 1: `SendMessageFull`, `FetchThread`)
- ✅ Structural tests for tool count, naming, hook syntax
- ✅ Integration test guidance (Task 4 Step 3: manual two-session test)
- ❌ Missing edge case tests (Amendment A9)
- ❌ Missing timeout enforcement test (background goroutine)
- ❌ Missing concurrent negotiation test (two agents request same file)

### Recommended Additions:
1. **Race detector test** (Task 7): `go test -race ./...` to catch concurrency bugs in timeout checker goroutine
2. **Thread polling circuit breaker test** (Task 2): Verify `maxConsecutiveErrors = 3` fires correctly
3. **Idempotent force-release test** (Task 6): `CheckExpiredNegotiations` called twice on same request
4. **Auto-release TOCTOU test** (Task 4): File becomes dirty between `git diff` check and reservation delete (already addressed by Amendment A3 advisory-only mode)

---

## Bash Safety Summary

| Pattern | Status | Location | Fix Needed |
|---------|--------|----------|------------|
| `jq --arg` for variables | ❌ Partial | Task 4 line 751 | Use `--arg file "$REQ_FILE"` |
| Quoting in case patterns | ⚠️ Ambiguous | Task 4 line 743 | Use `[[ ... == ... ]]` glob match |
| `|| true` fail-open | ⚠️ Nuanced | Task 4 line 753 | Add comment or remove from reservation delete |
| `--max-time` circuit breaker | ✅ Correct | Task 4 line 72 | Already uses `intermute_curl_fast` |
| `set -euo pipefail` | ✅ Correct | Existing hooks | Already enforced |

**Verdict:** Bash code is **mostly safe** but needs jq injection fix and quoting clarification.

---

## Naming Convention Review

### Go Naming:
- ✅ `negotiateRelease` — camelCase function (unexported, used in `RegisterAll`)
- ✅ `SendMessageFull` — PascalCase method (exported from client)
- ✅ `MessageOptions` — PascalCase struct (exported)
- ✅ `normalTimeoutMinutes` — camelCase constant (unexported)
- ✅ `NegotiationTimeout` — PascalCase struct (exported from client)

### MCP Tool Naming:
- ✅ `negotiate_release` — snake_case (MCP convention)
- ✅ `respond_to_release` — snake_case (MCP convention)
- ✅ `request_release` — snake_case (deprecated, but consistent)

### Bash Function Naming:
- ✅ `negotiation_check_path` — snake_case (Bash convention)
- ✅ `intermute_curl_fast` — snake_case (Bash convention)

**Verdict:** Naming is **fully consistent** with language conventions.

---

## Error Handling Pattern Review

### Current Patterns:
1. **MCP tool errors:** Return `mcp.NewToolResultError(...)` with descriptive message ✅
2. **Client errors:** Return wrapped error with `fmt.Errorf("context: %w", err)` ✅ (after fixing `%v`)
3. **Hook errors:** Fail-open with `|| true` for network calls ✅
4. **Timeout enforcement:** Background goroutine + inbox-driven checks (dual enforcement) ✅

### Missing Patterns:
- No retry logic for transient Intermute failures (acceptable for v1)
- No exponential backoff on timeout checker goroutine (acceptable, 30s fixed interval)
- No structured logging in hooks (acceptable, uses `cat <<ENDJSON` for Claude context)

**Verdict:** Error handling is **production-ready** for coordinated agent workflows.

---

## Recommendations

### Critical (Must Fix):
1. **Fix jq injection in Task 4** (line 751) — use `jq --arg`
2. **Add missing unit tests** (Amendment A9) — Task 7b
3. **Fix error wrapping** — replace `%v` with `%w` in 4 locations

### High Priority (Should Fix):
4. **Clarify auto-release fail-open** — add comment explaining tradeoff (Task 4 line 753)
5. **Split structural test updates** — separate Task 2 (10 tools) and Task 3 (11 tools)
6. **Add lint step** — `golangci-lint run` in Task 7

### Low Priority (Nice to Have):
7. **Document helper verification** — Task 2 Step 4 comment on existing helpers
8. **Add race detector test** — `go test -race` in Task 7
9. **Verify AGENTS.md instead of rewriting** — Task 7 Step 3

---

## Conclusion

The plan demonstrates **strong Go idiom compliance** and **thoughtful architecture**, but needs **12 targeted fixes** across error wrapping, bash safety, test coverage, and documentation accuracy. All issues are addressable within the existing 7-task structure with minor amendments.

**Overall Quality Grade:** B+ (85/100)
**Readiness:** Ready for implementation after applying critical fixes (items 1-3)

---

## Appendix: Fix Checklist

### Task 1 Amendments:
- [ ] Change `FetchThread` error return from `nil` to `make([]Message, 0)`
- [ ] Add `TestFetchThread_NotFound` and `TestFetchThread_EmptyMessages`

### Task 2 Amendments:
- [ ] Fix error wrapping: `%v` → `%w` in lines 280, 320
- [ ] Add comment on constant naming convention
- [ ] Update structural test to expect 10 tools (not 11)
- [ ] Add `TestNegotiateRelease_BlockingTimeout`

### Task 3 Amendments:
- [ ] Use `client.ReleaseByPattern` instead of inline loop (line 563)
- [ ] Fix error wrapping: `%v` → `%w` in line 558
- [ ] Update structural test to expect 11 tools
- [ ] Add helper verification to Step 1

### Task 4 Amendments:
- [ ] Fix jq injection: use `--arg file "$REQ_FILE"` (line 751)
- [ ] Clarify quoting in case pattern (line 743) or switch to `[[ ... == ... ]]`
- [ ] Add comment explaining fail-open on reservation delete (line 753)
- [ ] Add structural test for `INTERLOCK_AUTO_RELEASE` presence

### Task 6 Amendments:
- [ ] Add `TestReleaseByPattern_Idempotent`

### Task 7 Amendments:
- [ ] Add specific PRD.md update instructions (Step 1)
- [ ] Change AGENTS.md task from "add" to "verify" (Step 3)
- [ ] Add lint step: `golangci-lint run` (Step 5)
- [ ] Add race detector test: `go test -race ./...` (Step 5)
- [ ] Add Task 7b: Edge case tests (Amendment A9)

**Estimated fix effort:** 2-3 hours (mostly test additions + bash quoting fixes)
