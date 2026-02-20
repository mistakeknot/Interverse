# Correctness Review: Dual-Mode Plugin Architecture Implementation Plan

**Plan:** `/root/projects/Interverse/docs/plans/2026-02-20-dual-mode-plugin-architecture.md`
**Reviewer:** Julik (Correctness / Concurrency)
**Date:** 2026-02-20

---

## Invariants That Must Hold

Before cataloguing failures, naming what the system is supposed to guarantee:

1. **I1 — Session budget**: No more than 2 nudges fire in any single Claude session.
2. **I2 — Durable dismissal**: After 3 ignores, a companion is permanently silenced for that plugin/companion pair.
3. **I3 — Deduplication**: A nudge for a given `(session, plugin, companion)` triple fires at most once, even under parallel hook execution.
4. **I4 — Fail-open**: Sourcing `interbase-stub.sh` in a fresh environment with no ecosystem tools must never error, never produce output, never block.
5. **I5 — No double-source**: Sourcing `interbase.sh` or `interbase-stub.sh` a second time in the same shell must be a no-op.
6. **I6 — jq write safety**: A failed jq transformation must never truncate the state file; old state is always preferred over empty state.
7. **I7 — Stub isolation**: The stub's `_INTERBASE_LOADED=1` must not be visible to the live `interbase.sh`'s own guard in a way that prevents the live functions from loading.

---

## Finding 1 (CRITICAL): TOCTOU Race in `ib_nudge_companion` — I1 and I3 Both Violated

**Severity:** High — two invariants broken under parallel execution.

### The code

```bash
# Session budget check
local count
count=$(_ib_nudge_session_count)
(( count >= 2 )) && return 0

# ... dismissal check ...

# Atomic: prevent parallel duplicate
local flag="${flag_dir}/.nudge-${CLAUDE_SESSION_ID:-x}-${plugin}-${companion}"
[[ ! -f "$flag" ]] || return 0
touch "$flag" 2>/dev/null || return 0

# Emit nudge
echo "[interverse] Tip: ..." >&2

_ib_nudge_session_increment
_ib_nudge_record "$plugin" "$companion"
```

### The race sequence (I3 — duplicate nudge for same triple)

1. Hook process A calls `ib_nudge_companion "interphase" "phase tracking" "interflux"`.
2. Hook process B calls `ib_nudge_companion "interphase" "phase tracking" "interflux"` concurrently (e.g., two hooks fire at session start, or the user triggers two tool calls in rapid succession).
3. A reads `[[ ! -f "$flag" ]]` → true.
4. B reads `[[ ! -f "$flag" ]]` → true (A has not yet called `touch`).
5. A calls `touch "$flag"`.
6. B calls `touch "$flag"` (file now exists, but B already passed the check).
7. Both A and B reach `echo "[interverse] Tip..."` — the nudge fires twice.

The flag exists to prevent exactly this, but the check-then-act is not atomic. `touch` on Linux is not an atomic test-and-set. The correct primitive is `set -C` (noclobber) with a redirect, or `mkdir` (which is atomic on POSIX-compliant filesystems).

### The race sequence (I1 — budget exceeded)

1. A reads `count=1` (one nudge already fired this session).
2. B reads `count=1` concurrently.
3. Both see `count < 2`, both pass the budget check.
4. Both call `_ib_nudge_session_increment` → each reads 1, writes 2. Net count is 2 but two nudges were emitted. If there were more companions, the count could reach 4 with a budget of 2.

`_ib_nudge_session_increment` itself is also a non-atomic read-increment-write:

```bash
count=$(_ib_nudge_session_count)   # read
count=$((count + 1))               # increment in memory
printf '{"count":%d}\n' "$count" > "$sf"  # write (no locking)
```

Two concurrent callers both reading `count=0` both write `{"count":1}`. The budget counter underreports by (N-1) where N is the number of concurrent nudge calls.

### Fix

Replace the flag file check-then-act with an atomic mkdir-based lock:

```bash
# Atomic deduplication via mkdir (atomic on POSIX filesystems)
local lock_dir="${flag_dir}/.nudge-lock-${CLAUDE_SESSION_ID:-x}-${plugin}-${companion}"
if ! mkdir "$lock_dir" 2>/dev/null; then
    return 0  # Another process already claimed this nudge
fi
# From here: we are the sole owner for this (session, plugin, companion)
```

For the budget counter, use the same mkdir trick around the read-increment-write, or accept that over-nudging by one is tolerable (the flag dedup already prevents duplicates per triple). The real production risk is the per-triple dedup, not the budget count.

---

## Finding 2 (HIGH): `_ib_nudge_record` Truncates State File on jq Failure — I6 Violated

**Severity:** High — data loss on every jq error silently discards all previous nudge history.

### The code

```bash
local tmp="${nf}.tmp.$$"
jq --arg k "$key" --argjson ig "$ignores" --argjson dis "$dismissed" \
    '.[$k] = {"ignores":$ig,"dismissed":$dis}' "$nf" > "$tmp" 2>/dev/null && \
    mv -f "$tmp" "$nf" 2>/dev/null || rm -f "$tmp" 2>/dev/null
```

This is the correct jq-temp-mv pattern *when jq succeeds*. The guard `&& mv` ensures the move only happens on jq exit 0. If jq fails, `rm -f "$tmp"` runs and the original `$nf` is untouched. So far correct.

However, there are two problems:

**Problem 2a — `> "$tmp"` truncates on open, before jq runs.**

The redirect `> "$tmp"` creates or truncates the temp file immediately when the shell evaluates the command — before jq has processed a single byte. If `"$nf"` is unreadable (permissions changed by another process, filesystem full), jq exits non-zero, `rm -f "$tmp"` cleans up the (empty) temp file, and `$nf` is untouched. This part is safe.

But if `"$nf"` and `"$tmp"` are the same path (e.g., `mktemp` collision or `$$` reuse across rapid fork-exec), jq reads from a truncated file and writes empty JSON. The `$$` PID suffix is process-unique within a single shell session but NOT across concurrent subshell invocations that share the same PID namespace — a PID can be reused in rapid succession on busy systems.

**Problem 2b — `ignores` read from the pre-existing file; write races with another writer.**

```bash
ignores=$(jq -r --arg k "$key" '.[$k].ignores // 0' "$nf" 2>/dev/null) || ignores=0
ignores=$((ignores + 1))
# ... then write back
jq ... '.[$k] = {...}' "$nf" > "$tmp"
```

Between the read of `$nf` and the write of `$tmp` -> `$nf`, another process could have already incremented the same key. The final write wins and overwrites the other writer's increment. `ignores` can be understated, meaning dismissal (at 3 ignores) is delayed indefinitely if two processes always race and one always overwrites the other.

### Fix

Use a more collision-resistant tmp name:

```bash
local tmp
tmp=$(mktemp "${nf}.XXXXXX") || return 0
```

`mktemp` generates a random suffix and creates the file atomically, guaranteeing uniqueness without PID reuse risk. Still not a solution to the logical race (two concurrent writes), but at least the temp files do not collide.

For the logical race: accept that `ignores` may be undercount by at most 1 (tolerable — dismissal just takes one extra session). The consequence is delayed dismissal, not infinite nudging, because the per-triple flag file dedup (once fixed per Finding 1) already prevents within-session spam.

---

## Finding 3 (HIGH): Stub's `_INTERBASE_LOADED=1` Blocks Live Copy — I7 Violated

**Severity:** High — the stub poisons the guard variable before the live copy can set its own functions.

### The code (stub)

```bash
[[ -n "${_INTERBASE_LOADED:-}" ]] && return 0
_INTERBASE_LOADED=1                          # <-- set HERE

_interbase_live="${INTERMOD_LIB:-${HOME}/.intermod/interbase/interbase.sh}"
if [[ -f "$_interbase_live" ]]; then
    _INTERBASE_SOURCE="live"
    source "$_interbase_live"                # live copy checks _INTERBASE_LOADED
    return 0
fi
```

### The live copy guard

```bash
[[ -n "${_INTERBASE_LOADED:-}" ]] && return 0
_INTERBASE_LOADED=1
```

### The failure

When the stub sources the live copy, `_INTERBASE_LOADED` is already `1`. The live copy sees a non-empty variable, hits `return 0`, and exits immediately — without defining any of the real `ib_*` functions. The shell now has the stub's no-op definitions (which were not yet written, because the stub returns before defining them when it takes the `source live; return 0` branch) — or in the case where the stub set `_INTERBASE_LOADED=1` BEFORE the `if` block, it depends on evaluation order.

Let me trace carefully:

```
Stub line 1:  [[ -n "${_INTERBASE_LOADED:-}" ]] && return 0   # variable unset → proceeds
Stub line 2:  _INTERBASE_LOADED=1                              # GUARD SET
Stub line 3:  if [[ -f "$_interbase_live" ]]; then
Stub line 4:      _INTERBASE_SOURCE="live"
Stub line 5:      source "$_interbase_live"
                  # Inside live copy:
                  # [[ -n "${_INTERBASE_LOADED:-}" ]] && return 0
                  # _INTERBASE_LOADED is "1" → return 0 IMMEDIATELY
                  # No ib_* functions defined from live copy
Stub line 6:      return 0
              fi
```

When the stub takes the live-source path, it calls `return 0` at line 6 *before* it ever defines any fallback functions. So the shell has no `ib_*` functions at all — neither the rich live ones nor the stub fallbacks. Any call to `ib_phase_set`, `ib_nudge_companion`, etc., will be "command not found."

Actually, if `return` is called at line 6, the functions below (the fallback stubs) are never evaluated. So the caller inherits: `_INTERBASE_LOADED=1`, `_INTERBASE_SOURCE=live`, and *zero* `ib_*` function definitions.

### Fix

Move `_INTERBASE_LOADED=1` to after the live-source path succeeds, or remove it from the stub entirely and rely on the live copy to set it:

```bash
# Stub version — DO NOT set _INTERBASE_LOADED here
_interbase_live="${INTERMOD_LIB:-${HOME}/.intermod/interbase/interbase.sh}"
if [[ -f "$_interbase_live" ]]; then
    _INTERBASE_SOURCE="live"
    source "$_interbase_live"   # live copy sets _INTERBASE_LOADED=1
    return 0
fi

# Only reach here if live copy absent — define stubs and then mark loaded
_INTERBASE_SOURCE="stub"
_INTERBASE_LOADED=1
ib_has_ic()          { command -v ic &>/dev/null; }
# ... rest of stub definitions
```

Alternatively, unset `_INTERBASE_LOADED` before sourcing the live copy:

```bash
_INTERBASE_LOADED=1
if [[ -f "$_interbase_live" ]]; then
    _INTERBASE_SOURCE="live"
    unset _INTERBASE_LOADED     # let live copy claim ownership
    source "$_interbase_live"
    return 0
fi
```

The first approach (defer setting the variable) is cleaner.

---

## Finding 4 (MEDIUM): `ib_in_ecosystem()` Check Is Always True After Load — Logic Error

**Severity:** Medium — the function produces misleading results and any code branching on it will misbehave.

### The code

```bash
ib_in_ecosystem() { [[ -n "${_INTERBASE_LOADED:-}" ]] && [[ "${_INTERBASE_SOURCE:-}" == "live" ]]; }
```

The first condition `[[ -n "${_INTERBASE_LOADED:-}" ]]` is always true by the time any caller can invoke `ib_in_ecosystem`, because `_INTERBASE_LOADED=1` is set during `source` and the function is only available after sourcing. The first conjunct adds no discrimination: `ib_in_ecosystem` reduces to `[[ "${_INTERBASE_SOURCE:-}" == "live" ]]`.

This is not a critical bug (the logic still works), but it is misleading. The intent is clearly to distinguish "running from live centralized copy" vs "running from stub". The first check is dead weight and should be removed, or the intent of the function should be documented to avoid future misuse:

```bash
ib_in_ecosystem() { [[ "${_INTERBASE_SOURCE:-}" == "live" ]]; }
```

If the goal was also to distinguish "not loaded yet" from "loaded as stub", the variable names need to change (`_INTERBASE_SOURCE` should be set to `"stub"` only when the stub fallback path is active, which it does — so this check is simply redundant on the first conjunct).

---

## Finding 5 (MEDIUM): `return 0` Inside Stub When Sourced via `bash script.sh` Terminates the Script

**Severity:** Medium — `return` outside a function in a non-sourced context is a fatal error in strict shells.

### The code

```bash
if [[ -f "$_interbase_live" ]]; then
    _INTERBASE_SOURCE="live"
    source "$_interbase_live"
    return 0          # <-- unconditional return at top level
fi
```

When a file is sourced (`. file` or `source file`), `return` at the top level returns to the caller — correct.

When the file is executed directly (`bash interbase-stub.sh`), `return` outside a function causes:
- In `bash`: "return: can only `return' from a function or sourced script" — exits with status 1.
- With `set -e` active in the calling script, this propagates as an error.

The plan's test steps run `bash -n infra/interbase/templates/interbase-stub.sh` (syntax check only, not execution), so this won't be caught. But any debugging session where a developer runs `bash session-start.sh` and session-start.sh sources the stub, and the stub finds the live copy, will hit this. The live copy also has a top-level `return 0` as its load guard.

The standard defense is to check `${BASH_SOURCE[0]}` against `$0`:

```bash
# Only use return if we are being sourced, not executed
_ib_return() { return "${1:-0}"; }
```

Or more idiomatically at the top of any sourceable library:

```bash
# Ensure the file is being sourced, not executed
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "This file must be sourced, not executed." >&2
    exit 1
fi
```

In practice, `return` at the top level of a sourced-only library is the accepted idiom and bash is lenient. The real risk is a confused developer executing the stub directly during debugging. A guard comment suffices; the behavioral risk is low in production.

---

## Finding 6 (MEDIUM): `_ib_nudge_session_count` Returns "0" String on Missing File — Arithmetic Hazard

**Severity:** Medium — subtle in bash but safe under current usage; fragile under refactoring.

### The code

```bash
_ib_nudge_session_count() {
    local sf
    sf="$(_ib_nudge_session_file)"
    [[ -f "$sf" ]] || { echo "0"; return; }
    command -v jq &>/dev/null || { echo "0"; return; }
    jq -r '.count // 0' "$sf" 2>/dev/null || echo "0"
}
```

And the callers:

```bash
count=$(_ib_nudge_session_count)
(( count >= 2 )) && return 0
```

`(( count >= 2 ))` works correctly when `count` is `"0"` or `"1"`. However if `jq` outputs `null` (because `.count` is actually absent and `// 0` did not fire — possible if the file contains `{"count":null}`), `(( count >= 2 ))` with `count=null` will cause bash to treat `null` as 0 via implicit integer conversion. That is accidentally correct behavior, but the `echo "0"` fallback on `jq` non-zero exit is the right defense.

The more subtle issue: `jq -r '.count // 0'` with a file containing `{"count":null}` outputs `0` (the `// 0` alternative fires for `null`). So this is safe. With `{"count":"two"}` it outputs `"two"` which would make `(( "two" >= 2 ))` silently coerce to 0. This is contrived but worth documenting.

**No fix required** given the code only writes `{"count":N}` where N is an integer. The concern is hypothetical corruption.

---

## Finding 7 (MEDIUM): Test Suite Has Structural Defects — Guards Cannot Be Reset Between Test Sections

**Severity:** Medium — tests claim to validate load guard behavior but cannot actually exercise double-source prevention correctly.

### The `test-guards.sh` double-source test

```bash
# Double-source prevention
unset _INTERBASE_LOADED
source "$SCRIPT_DIR/../lib/interbase.sh"
assert "load guard prevents double execution" [[ "${_INTERBASE_LOADED:-}" == "1" ]]
```

This does not test double-source prevention. It tests that after unsetting and re-sourcing, the guard gets set. The actual invariant to test is: "if interbase.sh is sourced twice WITHOUT unsetting `_INTERBASE_LOADED`, the second source is a no-op and does not redefine functions." But you cannot unset `_INTERBASE_LOADED` inside a test and then source again — that just exercises normal first-load behavior, not deduplication.

The correct test for double-source prevention:

```bash
# Define a sentinel to detect re-execution
source "$SCRIPT_DIR/../lib/interbase.sh"   # first load
_sentinel_loaded_once=1
source "$SCRIPT_DIR/../lib/interbase.sh"   # second load — should be no-op
# If guard works, _sentinel_loaded_once is still 1 and was not redefined
assert "sentinel survives double source" [[ "${_sentinel_loaded_once:-0}" == "1" ]]
```

### The stub-to-live transition test

```bash
unset _INTERBASE_LOADED _INTERBASE_SOURCE
mkdir -p "$TEST_HOME/.intermod/interbase"
cp "$SCRIPT_DIR/../lib/interbase.sh" "$TEST_HOME/.intermod/interbase/interbase.sh"

source "$SCRIPT_DIR/../templates/interbase-stub.sh"
assert "stub sources live copy when present" [[ "${_INTERBASE_SOURCE:-}" == "live" ]]
```

With the bug from Finding 3 present (stub sets `_INTERBASE_LOADED=1` before sourcing live copy), the live copy's guard returns immediately, the stub's `return 0` fires, and `_INTERBASE_SOURCE` was set to `"live"` on line 4 of the stub. So `_INTERBASE_SOURCE == "live"` is **true** — but no live functions were actually loaded. The test passes while the real behavior is broken. This is a false positive.

The test should also verify that `ib_session_status` produces non-empty output (which it does check at line 524-525), and that would catch the bug — but only if `ib_session_status` is not the no-op stub version. If functions were not loaded from live copy (Finding 3 scenario), `ib_session_status` would be undefined and the test would fail with "command not found" rather than giving a meaningful assertion failure message.

### The nudge session budget test

```bash
# Test: nudge respects session budget (max 2)
ib_nudge_companion "comp1" "benefit1" 2>/dev/null || true
ib_nudge_companion "comp2" "benefit2" 2>/dev/null || true
output=$(ib_nudge_companion "comp3" "benefit3" 2>&1) || true
assert "nudge respects session budget of 2" [[ -z "$output" ]]
```

This test is sequential — one call after another in a single process. It does not test the concurrent budget race from Finding 1. It will pass correctly but gives false confidence that the budget is enforced under parallelism.

### The companion-installed test path

```bash
output=$(ib_nudge_companion "interphase" "automatic phase tracking" 2>&1) || true
assert "nudge emits output for missing companion" [[ -n "$output" ]]
```

`ib_has_companion "interphase"` calls:
```bash
compgen -G "${HOME}/.claude/plugins/cache/*/${name}/*" &>/dev/null
```

In the test, `HOME="$TEST_HOME"` (a fresh temp dir). So `${HOME}/.claude/plugins/cache/*/interphase/*` does not exist, and `compgen -G` returns exit 1. The companion is correctly identified as absent. But if a developer runs this test on a machine that has interphase installed (i.e., real `$HOME`), the test would fail because the companion is found installed. The test correctly sets `HOME` to isolate this, so this is fine.

---

## Finding 8 (LOW): `ib_has_companion` Uses `compgen -G` With Unbounded Glob Expansion

**Severity:** Low — correctness concern, not a crash risk.

### The code

```bash
ib_has_companion() {
    local name="${1:-}"
    [[ -n "$name" ]] || return 1
    compgen -G "${HOME}/.claude/plugins/cache/*/${name}/*" &>/dev/null
}
```

`compgen -G` returns 0 if the pattern matches at least one file, 1 if no match. This works. However:

1. If `$name` contains a slash or glob metacharacter (e.g., a crafted companion name `../../etc`), the glob expands into unexpected paths. In practice companion names are controlled strings, so this is low risk.

2. `compgen -G` with a deeply nested unmatched glob can be slow in large filesystems. In a hook that runs at session start, this adds latency proportional to the number of installed plugins. In practice, plugin caches are small, so not a production issue.

3. The pattern `*/${name}/*` requires at least one file inside the plugin directory to match. An empty plugin directory (installed but no files) returns 1 (not installed), which is arguably correct.

---

## Finding 9 (LOW): `ib_phase_set` Silently Accepts Any Phase Name

**Severity:** Low — no input validation.

### The code

```bash
ib_phase_set() {
    local bead="$1" phase="$2" reason="${3:-}"
    ib_has_bd || return 0
    bd set-state "$bead" "phase=$phase" >/dev/null 2>&1 || true
}
```

No validation of `$bead` or `$phase`. An empty bead ID would call `bd set-state "" "phase=..."` which would likely fail silently (due to `|| true`). An empty phase would set `phase=` in beads state.

Given the fail-open design philosophy of interbase, this is acceptable. A warning-level note: add a guard `[[ -n "$bead" && -n "$phase" ]] || return 0` for defense-in-depth.

---

## Finding 10 (LOW): `install.sh` Has No Idempotency — Overwrites Running Copy Mid-Session

**Severity:** Low — atomic install is missing.

### The code

```bash
cp "$SCRIPT_DIR/lib/interbase.sh" "$TARGET_DIR/interbase.sh"
```

`cp` on Linux is not atomic. During the copy window, a concurrent hook sourcing `interbase.sh` could read a partially-written file. This is a small race window (milliseconds), but sourcing a truncated shell script causes immediate parse errors that propagate to the hook.

The fix is the same temp-then-mv pattern used for JSON files:

```bash
tmp=$(mktemp "$TARGET_DIR/interbase.sh.XXXXXX")
cp "$SCRIPT_DIR/lib/interbase.sh" "$tmp"
mv -f "$tmp" "$TARGET_DIR/interbase.sh"
chmod 644 "$TARGET_DIR/interbase.sh"
```

On Linux, `mv` within the same filesystem is atomic (rename syscall). The chmod must come before the mv, or after — but if after and a reader sources between mv and chmod, they read a 600 file. Put chmod on the tmp before mv:

```bash
tmp=$(mktemp "$TARGET_DIR/interbase.sh.XXXXXX")
cp "$SCRIPT_DIR/lib/interbase.sh" "$tmp"
chmod 644 "$tmp"
mv -f "$tmp" "$TARGET_DIR/interbase.sh"
```

---

## Finding 11 (LOW): `interbump.sh` Modification Runs `install_interbase` Even on Dry-Run

**Severity:** Low — the proposed code does not guard against `--dry-run` mode.

### The proposed addition

```bash
install_interbase() {
    local interbase_dir
    interbase_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/infra/interbase"
    if [[ -f "$interbase_dir/install.sh" ]]; then
        echo -e "${CYAN}Installing interbase.sh to ~/.intermod/...${NC}"
        bash "$interbase_dir/install.sh"
    fi
}
```

And "Call `install_interbase` at the end of the main execution flow."

The existing `interbump.sh` exits early on `$DRY_RUN=true` (line 208-211):
```bash
if $DRY_RUN; then
    echo -e "\n${YELLOW}Dry run complete. No files changed.${NC}"
    exit 0
fi
```

If `install_interbase` is called BEFORE this early exit, it will run during dry-run. If called after, it is fine. The plan says "at the end of the main execution flow" without specifying the placement. Implementers should put it after the dry-run exit guard, i.e., after line 211 of the existing script.

---

## Summary Table

| # | Finding | Invariant(s) | Severity | Fix Complexity |
|---|---------|--------------|----------|----------------|
| 1 | TOCTOU race in `ib_nudge_companion` — check-then-touch flag and budget counter | I1, I3 | CRITICAL | Low — replace `touch` with `mkdir`; accept budget may over-emit by 1 |
| 2 | `_ib_nudge_record` temp file PID collision + write race on ignores counter | I6 | HIGH | Low — use `mktemp`, accept ignores undercount by 1 |
| 3 | Stub sets `_INTERBASE_LOADED=1` before sourcing live copy; live copy returns immediately with no functions defined | I7 | HIGH | Low — move guard-set to after live-source or unset before sourcing |
| 4 | `ib_in_ecosystem()` first conjunct is dead code | — | MEDIUM | Trivial — remove first conjunct |
| 5 | `return 0` at top level of stub/live copy fails if executed rather than sourced | I4 | MEDIUM | Low — add BASH_SOURCE guard or defensive comment |
| 6 | Session count arithmetic coercion on malformed JSON | I1 | MEDIUM | None required given controlled write paths |
| 7 | Test suite validates wrong properties for double-source, gives false positive for stub-to-live transition, misses concurrency coverage | — | MEDIUM | Medium — rewrite specific assertions |
| 8 | `ib_has_companion` glob unbounded and metachar-unsafe | — | LOW | Low — validate `$name` input |
| 9 | `ib_phase_set` no guard on empty bead/phase | I2 adjacent | LOW | Trivial — add null check |
| 10 | `install.sh` non-atomic copy — sourcing hook can read partial file | I4 | LOW | Low — use temp+mv+chmod pattern |
| 11 | `install_interbase` must be placed after dry-run exit in interbump.sh | — | LOW | Trivial — ordering |

---

## Prioritized Action Items

**Do before any merge:**

1. **Fix Finding 3 (stub guard variable ordering)** — this renders all integrated-mode functionality silently broken. Move `_INTERBASE_LOADED=1` inside the fallback block, after the live-source path exits. Every test that claims to verify integrated mode is a false positive until this is fixed.

2. **Fix Finding 1 (TOCTOU dedup)** — replace `[[ ! -f "$flag" ]] || return 0; touch "$flag"` with `mkdir "$lock_dir" 2>/dev/null || return 0`. The session budget race is less consequential (worst case: one extra nudge), but the per-triple dedup failure is a visible user regression (duplicate nudge messages at session start).

3. **Fix the test for stub-to-live transition (Finding 7)** — after fixing Finding 3, add an assertion that verifies a rich function is actually defined (e.g., `declare -f ib_session_status | grep -q "beads="`) to confirm live functions were loaded, not just that `_INTERBASE_SOURCE=="live"`.

**Do before first production use:**

4. **Fix Finding 2 (mktemp for temp files)** — switch `${nf}.tmp.$$` to `mktemp "${nf}.XXXXXX"` in `_ib_nudge_record`.

5. **Fix Finding 10 (atomic install)** — temp+chmod+mv in `install.sh`.

6. **Fix Finding 11 (dry-run guard in interbump)** — verify placement of `install_interbase` call.

**Cleanup before v1 release:**

7. Fix Finding 4 (dead conjunct in `ib_in_ecosystem`), Finding 5 (BASH_SOURCE guard), Finding 9 (empty bead guard).
