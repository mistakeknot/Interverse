# Quality Review: Dual-Mode Plugin Architecture Implementation Plan

**File reviewed:** `docs/plans/2026-02-20-dual-mode-plugin-architecture.md`
**Date:** 2026-02-20
**Reviewer:** Flux-drive Quality & Style Reviewer
**Languages in scope:** Bash (interbase.sh, interbase-stub.sh, install.sh, test scripts)

---

## Executive Summary

The plan is architecturally sound and the fail-open design contract is well considered. The `ib_*` / `_ib_*` naming convention is applied consistently throughout. However, there are several concrete Bash correctness problems in the code as written: a redundant stderr redirect, a load-guard bypass that silently breaks double-source protection, a `_ib_nudge_is_dismissed` return-value bug under `set -e`, a file-write path with no atomic safety, and a test harness that is weaker than bats-core in ways that matter for this code. The jq patterns are mostly correct but have one null-safety gap. None of the issues are architectural; all are fixable before implementation begins.

---

## 1. Bash Best Practices

### 1.1 Redundant Stderr Redirect on `ic run current` (LOW)

**Location:** `interbase.sh`, `ib_in_sprint`

```bash
ic run current --project=. &>/dev/null 2>&1
```

`&>/dev/null` already redirects both stdout and stderr to `/dev/null`. The trailing `2>&1` is a no-op and is syntactically confusing — it makes `2` point to `&1` which is already the write end of `/dev/null`. The same pattern appears in `ib_session_status`.

**Fix:** Use one form consistently. The project convention (seen in lib-gates.sh, lib-signals.sh) is `&>/dev/null`.

```bash
ic run current --project=. &>/dev/null
```

### 1.2 `set -euo pipefail` Absent in interbase.sh and interbase-stub.sh (MEDIUM)

**Location:** `infra/interbase/lib/interbase.sh`, `infra/interbase/templates/interbase-stub.sh`

Neither file declares strict mode. The plan notes the contract "Fail-open: all functions return safe defaults if dependencies missing" and the fail-open design is correct — but the absence of strict mode in sourced library files means that callers who rely on their own `set -e` will silently have it applied only inconsistently across the library's function bodies.

For sourced libraries, the recommended pattern (consistent with how `lib-gates.sh` and `lib-signals.sh` are structured in this codebase) is to omit `set -euo pipefail` from the library itself but explicitly handle every command that can fail with `|| true`, `|| return 0`, or `|| variable=$?`. Review the current functions:

- `ib_phase_set`: uses `|| true` correctly.
- `ib_emit_event`: uses `|| true` correctly.
- `_ib_nudge_record`: uses `|| true` on mkdir, file creation, and the `jq | mv` pipeline. Mostly correct, but the `jq ... > "$tmp"` and `mv -f "$tmp" "$nf"` compound uses `&&` with trailing `|| rm -f "$tmp"`. Under `set -e` in a caller, if the `jq` step fails and `&&` short-circuits, the `|| rm -f "$tmp"` succeeds, making the compound succeed, but the state file is not updated — which is the correct fail-safe behavior. This is acceptable.
- `_ib_nudge_is_dismissed`: see finding 1.4 below.

The test scripts correctly declare `set -euo pipefail`. No change needed there.

**Recommendation:** Document in `AGENTS.md` that library files are `set -e`-clean by convention (no bare failing commands), not by declaration. This prevents a future contributor from adding `set -euo pipefail` to the library header, which would change behavior for callers who source it in a non-strict context.

### 1.3 Load Guard Bypass Creates Silent Double-Source Risk (HIGH)

**Location:** `infra/interbase/tests/test-guards.sh`, Task 5, "Double-source prevention" test

```bash
# Double-source prevention
unset _INTERBASE_LOADED
source "$SCRIPT_DIR/../lib/interbase.sh"
assert "load guard prevents double execution" [[ "${_INTERBASE_LOADED:-}" == "1" ]]
```

This test `unset`s `_INTERBASE_LOADED` and then re-sources `interbase.sh`. The guard at the top of `interbase.sh` is:

```bash
[[ -n "${_INTERBASE_LOADED:-}" ]] && return 0
_INTERBASE_LOADED=1
```

After the `unset`, the guard does not fire and the entire file is re-executed. All `ib_*` functions are redefined (harmless), but `INTERBASE_VERSION` is re-declared and crucially `_INTERBASE_LOADED` is set to `1` again. The test asserts `_INTERBASE_LOADED == "1"` — this passes trivially whether or not the guard actually worked, because re-executing the file also sets `_INTERBASE_LOADED=1`.

This test does not verify guard protection at all. It verifies that sourcing the file unconditionally sets the variable, which is not what "load guard prevents double execution" means.

**Fix:** The double-source test should leave `_INTERBASE_LOADED` set (not unset it) and then verify the file is NOT re-executed. A reliable way to test this is to define a sentinel function before the second source and verify it still exists with its original definition afterward:

```bash
# Verify load guard prevents re-execution
# _INTERBASE_LOADED is already "1" from the initial source above
_test_sentinel_before_double_source() { echo "sentinel-value"; }
source "$SCRIPT_DIR/../lib/interbase.sh"  # guard should fire and return early
# If guard failed, the file redefined all functions but not the sentinel
assert "load guard allows user-defined sentinels to survive" \
    [[ "$(_test_sentinel_before_double_source)" == "sentinel-value" ]]
assert "load guard still set after re-source attempt" \
    [[ "${_INTERBASE_LOADED:-}" == "1" ]]
```

Alternatively, add a counter to `interbase.sh` (`_INTERBASE_LOAD_COUNT=$((_INTERBASE_LOAD_COUNT + 1))`) outside the guard, and assert it equals `1` after two source calls. Either approach makes the test meaningful.

### 1.4 `_ib_nudge_is_dismissed` Return Bug Under `set -e` Callers (HIGH)

**Location:** `interbase.sh`, `_ib_nudge_is_dismissed`

```bash
_ib_nudge_is_dismissed() {
    local plugin="$1" companion="$2"
    local nf key
    nf="$(_ib_nudge_state_file)"
    [[ -f "$nf" ]] || return 1
    command -v jq &>/dev/null || return 1
    key="${plugin}:${companion}"
    local dismissed
    dismissed=$(jq -r --arg k "$key" '.[$k].dismissed // false' "$nf" 2>/dev/null) || return 1
    [[ "$dismissed" == "true" ]]
}
```

The final line `[[ "$dismissed" == "true" ]]` is the function's return value: it returns 0 (true) if dismissed, 1 (false) if not. The caller in `ib_nudge_companion` uses:

```bash
_ib_nudge_is_dismissed "$plugin" "$companion" && return 0
```

This is correct: if dismissed, return early from the nudge function.

However, the jq expression `.[$k].dismissed // false` has a null-safety problem. When the key `$k` does not exist in the JSON object, `.[$k]` returns `null`. `.[$k].dismissed` is then `null.dismissed`, which in jq evaluates to `null`, not an error. The `// false` alternative then correctly produces `false`. So the dismissed-when-key-absent case is handled.

But when the file exists and contains valid JSON but the `dismissed` field itself is missing (e.g., `{"plugin:comp": {"ignores": 2}}`), `.[$k].dismissed` returns `null`, and `// false` correctly yields `false`. This is correct.

The real risk is a different one: `dismissed=$(jq ... 2>/dev/null) || return 1`. If jq exits non-zero (e.g., the file is corrupted JSON), the function returns 1, which means "not dismissed." This is the correct fail-open behavior. But if jq outputs an empty string (e.g., if `"$nf"` is empty), `dismissed` will be `""`, and `[[ "$dismissed" == "true" ]]` returns 1 (not dismissed). This is correct.

The one actual bug: in `_ib_nudge_record`, the initial file creation uses `printf`:

```bash
printf '{"%s":{"ignores":1,"dismissed":false}}\n' "$key" > "$nf" 2>/dev/null || true
```

If `$key` contains a double-quote character (e.g., a plugin name with a `"` in it), this produces malformed JSON. Plugin and companion names are controlled values and are unlikely to contain quotes, but the pattern is fragile. Use `jq --null-input` for JSON construction:

```bash
jq --null-input --arg k "$key" '{($k): {"ignores": 1, "dismissed": false}}' \
    > "$nf" 2>/dev/null || true
```

This is especially important because the `key` is `"${plugin}:${companion}"` and both values come from caller input to `ib_nudge_companion`.

### 1.5 `_ib_nudge_record` tmp File Left on Partial Failure (MEDIUM)

**Location:** `interbase.sh`, `_ib_nudge_record`

```bash
local tmp="${nf}.tmp.$$"
jq --arg k "$key" --argjson ig "$ignores" --argjson dis "$dismissed" \
    '.[$k] = {"ignores":$ig,"dismissed":$dis}' "$nf" > "$tmp" 2>/dev/null && \
    mv -f "$tmp" "$nf" 2>/dev/null || rm -f "$tmp" 2>/dev/null
```

The operator precedence here is:

```
(A && B) || C
```

where:
- A = `jq ... > "$tmp" 2>/dev/null`
- B = `mv -f "$tmp" "$nf" 2>/dev/null`
- C = `rm -f "$tmp" 2>/dev/null`

If A fails (jq error, disk full), B is skipped, C runs — tmp file cleaned up. Correct.
If A succeeds but B fails (mv error), C runs — tmp file cleaned up, but the state file is NOT updated. The `|| true` on the outer `_ib_nudge_record` call in `ib_nudge_companion` means this failure is swallowed. This is acceptable fail-safe behavior.
If A succeeds and B succeeds, C does NOT run. Correct.

The logic is actually correct. However, under a caller with `set -e`, the compound `(A && B) || C` as a whole succeeds (C is `rm -f`, which succeeds), so `set -e` is not triggered. The behavior is consistent with the fail-open contract.

One real problem: the `$$` in `tmp="${nf}.tmp.$$"` uses the shell's PID. If two instances of `ib_nudge_companion` run concurrently within the same process (not typical for a sourced library, but possible if called from a subshell), they share the PID and could race on the tmp file. A safer pattern is:

```bash
local tmp
tmp=$(mktemp "${nf}.tmp.XXXXXX" 2>/dev/null) || return 0
```

This produces a genuinely unique name and is the documented convention for atomic writes in this codebase (see `docs/guides/data-integrity-patterns.md`).

### 1.6 `install.sh` Uses `#!/bin/bash` While All Other Scripts Use `#!/usr/bin/env bash` (LOW)

**Location:** `infra/interbase/install.sh`

```bash
#!/bin/bash
```

All other scripts in the plan use `#!/usr/bin/env bash`, which is the established convention in this codebase (see `lib-gates.sh`, `lib-signals.sh`). `install.sh` is the only exception. Use `#!/usr/bin/env bash` for consistency.

### 1.7 `ib_in_ecosystem` Is Always False From the Live Copy (MEDIUM)

**Location:** `interbase.sh`, `ib_in_ecosystem`

```bash
ib_in_ecosystem()  { [[ -n "${_INTERBASE_LOADED:-}" ]] && [[ "${_INTERBASE_SOURCE:-}" == "live" ]]; }
```

`_INTERBASE_SOURCE` is set in `interbase-stub.sh` before sourcing `interbase.sh`:

```bash
_INTERBASE_SOURCE="live"
source "$_interbase_live"
```

When `interbase.sh` is sourced directly (e.g., in the test suite via `source "$SCRIPT_DIR/../lib/interbase.sh"`), `_INTERBASE_SOURCE` is never set, so `ib_in_ecosystem` returns false. This is the correct behavior for direct-source scenarios.

But when sourced through the stub (the intended production path), `_INTERBASE_SOURCE` is set before the `source` call, so by the time `interbase.sh` runs, the variable is already in the environment. This works.

The issue is that `interbase.sh` itself never sets `_INTERBASE_SOURCE`. If someone sources `interbase.sh` directly with `_INTERBASE_SOURCE` already set to `"live"` from a prior run, `ib_in_ecosystem` would return true. This is an unlikely misconfiguration but the function is fragile because it conflates "was I loaded through the stub" with "is the live copy present."

**Recommendation:** Document in the function comment that `_INTERBASE_SOURCE` is set by the stub, not by `interbase.sh` itself, so direct sourcing always reports `ib_in_ecosystem` as false. This prevents confusion during debugging.

---

## 2. Test Harness: Custom `assert()` vs. bats-core

### 2.1 The Custom Harness Is Functionally Adequate But Has One Structural Gap (MEDIUM)

The plan's tech stack states "bats-core (shell tests)" but the implementation uses a custom `assert()` / `assert_not()` helper. This discrepancy should be resolved — either update the tech stack declaration or adopt bats-core.

The custom harness as written:

```bash
assert() {
    local desc="$1"; shift
    if "$@" 2>/dev/null; then ((PASS++)); echo "  PASS: $desc"
    else ((FAIL++)); echo "  FAIL: $desc"; fi
}
```

Differences from bats-core that matter for this code:

1. **`$@` as a command.** `assert "desc" [[ -n "$output" ]]` passes `[[`, `-n`, `"$output"`, `]]` as positional arguments and executes `[[ -n "$output" ]]` as a command. This is correct in Bash — `[[` is a builtin. However, the `2>/dev/null` on `"$@"` suppresses any stderr from inside the condition, including errors from malformed jq calls. A `set -e` failure inside `"$@"` is NOT caught — the `if` construct catches the exit code, not `set -e`. This is correct behavior for the assertion pattern but can obscure real errors.

2. **No test isolation.** bats-core runs each `@test` block in a subshell with a clean environment. The custom harness runs all assertions in the same shell process. This means a sourced variable from one test section bleeds into the next. In `test-guards.sh`, the stub test section does:

   ```bash
   unset _INTERBASE_LOADED _INTERBASE_SOURCE
   export HOME="$TEST_HOME"  # No ~/.intermod/ exists
   source "$SCRIPT_DIR/../templates/interbase-stub.sh"
   ```

   But this is run after the guard function tests that already set `_INTERBASE_LOADED=1`. After the `unset`, the stub correctly loads. The "Live Source Tests" section then does another `unset` and sources the stub again. This sequential dependency on `unset` is fragile — if any test in the middle fails with `exit 1`, later sections never run and `rm -rf "$TEST_HOME"` is skipped (leaking the temp directory).

3. **`|| true` on test calls suppresses assertion failures.** In `test-nudge.sh`:

   ```bash
   output=$(ib_nudge_companion "interphase" "automatic phase tracking" 2>&1) || true
   assert "nudge emits output for missing companion" [[ -n "$output" ]]
   ```

   The `|| true` is correct here (prevents `set -e` from exiting on a non-zero return from `ib_nudge_companion`). But it also means if `ib_nudge_companion` itself exits non-zero for an unexpected reason (a bug, not the intended no-op return), the test silently ignores it and the assertion on `$output` catches only the visible symptom.

**Recommendation:** Add a `trap 'rm -rf "$TEST_HOME"' EXIT` to both test scripts so the temp directory is always cleaned up even on failure. This is the most important structural fix:

```bash
TEST_HOME=$(mktemp -d)
trap 'rm -rf "$TEST_HOME"' EXIT
export HOME="$TEST_HOME"
```

This also makes it safe to remove the manual `rm -rf "$TEST_HOME"` at the end.

### 2.2 Missing Test: Nudge Budget Counts Across Independent Calls (MEDIUM)

**Location:** `test-nudge.sh`

```bash
ib_nudge_companion "comp1" "benefit1" 2>/dev/null || true
ib_nudge_companion "comp2" "benefit2" 2>/dev/null || true
output=$(ib_nudge_companion "comp3" "benefit3" 2>&1) || true
assert "nudge respects session budget of 2" [[ -z "$output" ]]
```

This test assumes that the first two `ib_nudge_companion` calls each increment the session counter. But it does not assert that they actually fired (emitted output). If `ib_has_companion` happens to return true for `comp1` or `comp2` (e.g., because a plugin with that name exists in `$TEST_HOME/.claude/plugins/cache/`), the counter would not increment and the third call would fire, making `$output` non-empty and the test fail.

The test sets `export HOME="$TEST_HOME"` (a fresh temp dir) so `$HOME/.claude/plugins/cache/` does not exist, making `ib_has_companion` return false. This is correct. But the assumption is not verified.

**Fix:** Assert that the first two calls produce non-empty output:

```bash
out1=$(ib_nudge_companion "comp1" "benefit1" 2>&1) || true
assert "nudge fires for first missing companion" [[ -n "$out1" ]]
out2=$(ib_nudge_companion "comp2" "benefit2" 2>&1) || true
assert "nudge fires for second missing companion" [[ -n "$out2" ]]
output=$(ib_nudge_companion "comp3" "benefit3" 2>&1) || true
assert "nudge respects session budget of 2" [[ -z "$output" ]]
```

### 2.3 No Test for `ib_nudge_companion` Dismissal After 3 Ignores (LOW)

The durable dismissal logic in `_ib_nudge_record` sets `dismissed=true` after 3 ignores. There is no test for this. Given that dismissal requires state across multiple session-level calls and the session budget would normally block after 2, this case requires a direct call to `_ib_nudge_record` to build up ignore count, then verify `ib_nudge_companion` skips. This is worth adding to `test-nudge.sh`:

```bash
# Simulate 3 prior ignores by direct state manipulation
_ib_nudge_record "testplugin" "persisted-comp"
_ib_nudge_record "testplugin" "persisted-comp"
_ib_nudge_record "testplugin" "persisted-comp"
output=$(CLAUDE_SESSION_ID="fresh-session-$$" ib_nudge_companion "persisted-comp" "some-benefit" "testplugin" 2>&1) || true
assert "nudge suppressed after 3 ignores (durable dismissal)" [[ -z "$output" ]]
```

Note this test also needs a fresh `CLAUDE_SESSION_ID` to bypass the session budget counter.

---

## 3. Naming Conventions

### 3.1 `ib_*` Prefix Applied Consistently — One Gap in the Stub (LOW)

The public API uses `ib_*` and internal helpers use `_ib_*` throughout `interbase.sh`. The stub template replicates the public functions correctly.

One minor inconsistency: in `interbase-stub.sh`, the intermediate variable `_interbase_live` uses a single-underscore prefix:

```bash
_interbase_live="${INTERMOD_LIB:-${HOME}/.intermod/interbase/interbase.sh}"
```

This is a local variable in the sourced namespace (not a function), so it pollutes the caller's environment as `_interbase_live`. It should be either `local` (it can't be local outside a function) or use a more namespaced name to avoid collisions:

```bash
_INTERBASE_LIVE_PATH="${INTERMOD_LIB:-${HOME}/.intermod/interbase/interbase.sh}"
```

Using screaming snake case signals to readers that this is a module-level variable, consistent with how `_INTERBASE_LOADED`, `_INTERBASE_SOURCE`, and `_GATES_LOADED` are named in the existing codebase.

### 3.2 `ib_in_ecosystem` vs. `ib_in_sprint` — Inconsistent Implicit vs. Explicit Subject (LOW)

`ib_in_ecosystem` and `ib_in_sprint` use the same grammatical pattern (predicate without an explicit subject), but `ib_in_sprint` checks if there is an active sprint in the *current project*, while `ib_in_ecosystem` checks if the *current session* is ecosystem-sourced. These are different subjects. The names are fine individually but could cause confusion for a contributor who assumes both test "the current session."

**Recommendation:** No rename required, but add a one-line comment above each:

```bash
# Returns 0 if this library was loaded through a stub (ecosystem user), 1 if direct/standalone
ib_in_ecosystem()  { ... }

# Returns 0 if the current project has an active ic sprint, 1 otherwise
ib_in_sprint() { ... }
```

### 3.3 `plugin` Parameter in `ib_nudge_companion` Has an Implicit Default That Loses Information (MEDIUM)

```bash
ib_nudge_companion() {
    local companion="${1:-}" benefit="${2:-}" plugin="${3:-unknown}"
```

When `plugin` defaults to `"unknown"`, the nudge state is keyed as `"unknown:${companion}"` in the durable state file. If two different plugins both call `ib_nudge_companion` without providing the third argument, their dismissal states are merged under the same `"unknown"` namespace. A user who dismisses a nudge from interflux (because interflux defaulted to `"unknown"`) would also suppress the same companion nudge from a different plugin.

The third parameter should either:
- Be required (add a guard: `[[ -n "${3:-}" ]] || return 0`), or
- Be auto-detected from the calling plugin context (e.g., a module-level `INTERBASE_PLUGIN_NAME` variable set by the stub during install-time customization).

Given that the stub template is copied per-plugin, the cleanest approach is to add a variable to the stub template:

```bash
# Set by each plugin's stub copy at install time
INTERBASE_PLUGIN_NAME="${INTERBASE_PLUGIN_NAME:-}"
```

And in the `interflux` copy, set it to `"interflux"`. The `ib_nudge_companion` caller in `session-start.sh` then omits the third argument and the library uses `INTERBASE_PLUGIN_NAME`.

---

## 4. jq Usage Patterns

### 4.1 `_ib_nudge_session_count` Returns "0" When jq Is Missing — Correct (NO ISSUE)

```bash
_ib_nudge_session_count() {
    local sf
    sf="$(_ib_nudge_session_file)"
    [[ -f "$sf" ]] || { echo "0"; return; }
    command -v jq &>/dev/null || { echo "0"; return; }
    jq -r '.count // 0' "$sf" 2>/dev/null || echo "0"
}
```

The `// 0` alternative operator handles null correctly here (`.count` not present → `null` → `0`). The `|| echo "0"` handles jq failure (malformed file). The `echo "0"` paths are consistent. This pattern matches the documented jq null-safety convention in `docs/guides/shell-and-tooling-patterns.md`. No issue.

### 4.2 `_ib_nudge_is_dismissed` jq Expression Has Null-Chaining Gap (MEDIUM)

```bash
dismissed=$(jq -r --arg k "$key" '.[$k].dismissed // false' "$nf" 2>/dev/null) || return 1
```

Per the `shell-and-tooling-patterns.md` guide: `null[:10]` crashes, and the `//` operator does not fire after a runtime error. Null chaining via `.field.subfield` works differently: if `.[$k]` is `null`, then `.[$k].dismissed` is also `null` (jq evaluates `.null.dismissed` to `null` without error — this is valid in jq's type system). The `// false` then correctly fires.

However, if `.[$k]` is a JSON type that does not support field access (e.g., `"string"` or `42`), jq will emit a type error and exit non-zero. The `2>/dev/null` suppresses the error message, and the `|| return 1` (not dismissed) is the correct fail-open behavior.

The actual gap: `_ib_nudge_record` writes `{"ignores": $ig, "dismissed": $dis}` where `$dis` is a Bash variable that is either `"false"` or `"true"` — but these are passed as `--argjson dis "$dismissed"`. `--argjson` parses the value as JSON, so `"false"` parses to the boolean `false` and `"true"` parses to `true`. This is correct and `_ib_nudge_is_dismissed`'s comparison `[[ "$dismissed" == "true" ]]` matches the `jq -r` output of boolean `true` as the string `"true"`. Correct.

One edge: when the file is initially created by the `printf` fallback path (finding 1.4), `dismissed` is written as the literal string `false` in the JSON: `{"ignores":1,"dismissed":false}`. This is valid JSON boolean. The jq read is correct.

**No code change required**, but the `printf` JSON construction should be replaced with `jq --null-input` as noted in finding 1.4.

### 4.3 `_ib_nudge_record` `ignores` Arithmetic Uses Bash Integer on jq String Output (LOW)

```bash
ignores=$(jq -r --arg k "$key" '.[$k].ignores // 0' "$nf" 2>/dev/null) || ignores=0
ignores=$((ignores + 1))
```

`jq -r` outputs `0` as the string `"0"` (not the integer `0`). Bash arithmetic `$((ignores + 1))` treats string integers correctly, so `$((0 + 1))` is `1`. This is safe for the expected values.

If the JSON file is manually edited and `.[$k].ignores` contains a non-integer (e.g., `"three"`), `$((ignores + 1))` will produce a syntax error and fail. Under `set -e` in a caller, this would exit the caller. The function should guard:

```bash
ignores=$(jq -r --arg k "$key" '.[$k].ignores // 0' "$nf" 2>/dev/null) || ignores=0
# Ensure numeric
[[ "$ignores" =~ ^[0-9]+$ ]] || ignores=0
ignores=$((ignores + 1))
```

This is LOW severity because the JSON is only written by the library itself, not by external processes.

---

## 5. Anti-Patterns

### 5.1 `ib_session_status` Uses Array Join Pattern That Is Non-Portable (LOW)

```bash
echo "[interverse] $(IFS=' | '; echo "${parts[*]}")" >&2
```

Setting `IFS` inside a command substitution `$(...)` modifies IFS only within the subshell. The `echo "${parts[*]}"` then uses the modified IFS to join array elements. This is a correct Bash idiom but it relies on the subshell inheriting the array, which it does in Bash 4+. It will fail in `sh` (POSIX shell) and in Bash versions before 4.0. Since the shebang is `#!/usr/bin/env bash` and the `parts` array syntax is already Bash-only, this is acceptable — but worth noting it is Bash 4+ specific.

A simpler alternative that avoids the subshell:

```bash
local joined
printf -v joined '%s | ' "${parts[@]}"
joined="${joined% | }"
echo "[interverse] ${joined}" >&2
```

### 5.2 `ib_has_companion` Uses `compgen -G` for Glob — Correct but Fragile on Path Changes (LOW)

```bash
ib_has_companion() {
    local name="${1:-}"
    [[ -n "$name" ]] || return 1
    compgen -G "${HOME}/.claude/plugins/cache/*/${name}/*" &>/dev/null
}
```

`compgen -G` returns 0 if the glob matches at least one path, 1 otherwise. This is the correct idiom for glob existence checks without word splitting risk. Used identically in the stub. No issue with the pattern.

The fragility is that the Claude Code plugin cache path `~/.claude/plugins/cache/*/` is hardcoded. If Claude Code ever changes this path, `ib_has_companion` will always return 1 (companion never detected) without any error — the nudge protocol would fire on every session for installed companions. A `CLAUDE_PLUGIN_CACHE_DIR` environment variable override would make this testable and future-proof:

```bash
local cache_root="${CLAUDE_PLUGIN_CACHE_DIR:-${HOME}/.claude/plugins/cache}"
compgen -G "${cache_root}/*/${name}/*" &>/dev/null
```

This also makes `test-guards.sh` able to test `ib_has_companion` for a "found" case by creating a directory under `$TEST_HOME/.claude/plugins/cache/testplugin/v1/`.

### 5.3 Task 9 Standalone Mode Test Uses Inline `env -u` with `bash -c` and Heredoc-like Quoting (LOW)

**Location:** Task 9, Step 5

```bash
env -u CLAVAIN_BEAD_ID HOME=$(mktemp -d) bash -c '
  source plugins/interflux/hooks/interbase-stub.sh
  ib_phase_set "x" "y" && echo "phase_set: OK"
  ...
'
```

This `bash -c '...'` pattern with a multi-line string is exactly the kind of command that the `CLAUDE.md` global instructions warn against: multi-line Bash in a tool call creates invalid permission entries in `.claude/settings.local.json`. When the implementer runs this as a validation step in Claude Code's Bash tool, each newline-separated fragment becomes a separate entry.

**Fix:** Write the validation script to a temp file and invoke it:

```bash
# Write to temp file, then run
bash /tmp/test-standalone.sh
```

This is a plan-level authoring issue, not a code correctness issue, but it has an operational impact.

### 5.4 Task 8 Step 5 Destructively Renames `~/.intermod` (MEDIUM)

```bash
mv ~/.intermod ~/.intermod.bak 2>/dev/null || true
bash plugins/interflux/hooks/session-start.sh 2>&1
mv ~/.intermod.bak ~/.intermod 2>/dev/null || true
```

If `session-start.sh` exits with an error between the two `mv` calls, `~/.intermod` is left in its backup location and the rename is not undone. The subsequent `mv ~/.intermod.bak ~/.intermod` requires the backup to still exist. This is a test-teardown issue, not a production code issue, but it leaves the developer's environment in a broken state on test failure.

**Fix:** Use a subshell with a trap, or better, simulate standalone mode using `INTERMOD_LIB=/nonexistent` to override the library path without touching the filesystem:

```bash
# Simulate standalone: point INTERMOD_LIB to a nonexistent path
INTERMOD_LIB=/nonexistent bash plugins/interflux/hooks/session-start.sh 2>&1
# Expected: no output (stub mode, ib_session_status is no-op)
```

This is safe, reversible, and works because `interbase-stub.sh` reads `INTERMOD_LIB`:

```bash
_interbase_live="${INTERMOD_LIB:-${HOME}/.intermod/interbase/interbase.sh}"
if [[ -f "$_interbase_live" ]]; then
    ...
fi
```

If the path does not exist, the `[[ -f ... ]]` check fails and the stub fallback is used. The rename-and-restore approach should be removed entirely.

---

## 6. `interbump.sh` Integration (Task 10)

### 6.1 `install_interbase` Uses `BASH_SOURCE[0]` Inside a Function Called From interbump.sh (LOW)

```bash
install_interbase() {
    local interbase_dir
    interbase_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/infra/interbase"
    ...
}
```

`BASH_SOURCE[0]` inside a function sourced into or called from `interbump.sh` refers to the file where the function is defined, not the file that is being executed. If `install_interbase` is defined inline in `interbump.sh`, `BASH_SOURCE[0]` is `interbump.sh` itself. The `..` navigation from `scripts/` goes to the repo root, and then `/infra/interbase` resolves correctly.

However, if the function is ever extracted to a separate file and sourced, `BASH_SOURCE[0]` would be that separate file's path, and the relative navigation would break. This is an existing pattern in `interbump.sh` (likely already using `BASH_SOURCE[0]`), so it is consistent. No change required — just note the assumption.

---

## Summary Table

| Finding | Severity | Location | Category |
|---------|----------|----------|----------|
| Double-source test does not verify guard fires — asserts trivially | HIGH | test-guards.sh | Test correctness |
| `_ib_nudge_is_dismissed` / `ib_nudge_companion` — JSON construction via `printf` is injection-prone | HIGH | interbase.sh | Bash / jq safety |
| Task 8 Step 5 renames `~/.intermod` without cleanup on failure | MEDIUM | Plan step | Operational safety |
| `tmp` file uses `$$` PID; should use `mktemp` per data-integrity patterns guide | MEDIUM | interbase.sh | Atomicity |
| `ib_in_ecosystem` never true when sourced directly; undocumented assumption | MEDIUM | interbase.sh | Naming / docs |
| `plugin` param defaults to `"unknown"` — merges dismissal state across plugins | MEDIUM | interbase.sh | API design |
| `_interbase_live` variable name pollutes caller namespace; should use screaming snake | MEDIUM | interbase-stub.sh | Naming |
| Test harness lacks `trap EXIT` cleanup; leaked temp dirs on failure | MEDIUM | test-nudge.sh, test-guards.sh | Test robustness |
| Budget test does not assert first two calls actually fired | MEDIUM | test-nudge.sh | Test correctness |
| No test for durable dismissal after 3 ignores | LOW | test-nudge.sh | Test coverage |
| Redundant `2>&1` after `&>/dev/null` | LOW | interbase.sh | Bash idiom |
| `install.sh` uses `#!/bin/bash` not `#!/usr/bin/env bash` | LOW | install.sh | Style |
| `_ib_nudge_record` `ignores` value not validated as integer before arithmetic | LOW | interbase.sh | Robustness |
| `ib_session_status` array join uses subshell IFS pattern (Bash 4+ only) | LOW | interbase.sh | Portability |
| `ib_has_companion` cache path hardcoded; not overridable for testing | LOW | interbase.sh | Testability |
| Task 9 Step 5 multi-line `bash -c` will produce invalid settings entries | LOW | Plan step | Operational hygiene |
| `ib_in_ecosystem` and `ib_in_sprint` should have subject-clarifying comments | LOW | interbase.sh | Documentation |
| Tech stack says bats-core but implementation uses custom harness | LOW | Plan header | Consistency |

---

## Priority Order for Fixes Before Implementation

1. **(HIGH)** Replace `printf '{"%s":...}' "$key"` with `jq --null-input` in `_ib_nudge_record` to prevent JSON injection.
2. **(HIGH)** Fix the double-source test to actually verify the guard fires.
3. **(MEDIUM)** Replace `mv ~/.intermod ~/.intermod.bak` in Task 8 Step 5 with `INTERMOD_LIB=/nonexistent`.
4. **(MEDIUM)** Replace `${nf}.tmp.$$` with `mktemp "${nf}.tmp.XXXXXX"` per the data-integrity patterns guide.
5. **(MEDIUM)** Add `trap 'rm -rf "$TEST_HOME"' EXIT` to both test scripts.
6. **(MEDIUM)** Fix budget test to assert first two calls fired before asserting third is suppressed.
7. **(MEDIUM)** Rename `_interbase_live` to `_INTERBASE_LIVE_PATH` in the stub.
8. **(MEDIUM)** Address `plugin` defaulting to `"unknown"` — either require it or expose `INTERBASE_PLUGIN_NAME`.
9. **(LOW)** Fix `install.sh` shebang to `#!/usr/bin/env bash`.
10. **(LOW)** Remove redundant `2>&1` after `&>/dev/null`.
