#!/usr/bin/env bash
# Test nudge protocol behavior
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_HOME=$(mktemp -d)
trap 'rm -rf "$TEST_HOME"' EXIT
export HOME="$TEST_HOME"
export CLAUDE_SESSION_ID="test-session-$$"

# Reset interbase load state
unset _INTERBASE_LOADED _INTERBASE_SOURCE

source "$SCRIPT_DIR/../lib/interbase.sh"

PASS=0; FAIL=0
assert() {
    local desc="$1"; shift
    if "$@" 2>/dev/null; then PASS=$((PASS + 1)); echo "  PASS: $desc"
    else FAIL=$((FAIL + 1)); echo "  FAIL: $desc"; fi
}
assert_not() {
    local desc="$1"; shift
    if ! "$@" 2>/dev/null; then PASS=$((PASS + 1)); echo "  PASS: $desc"
    else FAIL=$((FAIL + 1)); echo "  FAIL: $desc"; fi
}
assert_nonempty() {
    local desc="$1" actual="$2"
    if [ -n "$actual" ]; then PASS=$((PASS + 1)); echo "  PASS: $desc"
    else FAIL=$((FAIL + 1)); echo "  FAIL: $desc (expected non-empty)"; fi
}
assert_empty() {
    local desc="$1" actual="$2"
    if [ -z "$actual" ]; then PASS=$((PASS + 1)); echo "  PASS: $desc"
    else FAIL=$((FAIL + 1)); echo "  FAIL: $desc (expected empty, got '$actual')"; fi
}
assert_file_exists() {
    local desc="$1" path="$2"
    if [ -f "$path" ]; then PASS=$((PASS + 1)); echo "  PASS: $desc"
    else FAIL=$((FAIL + 1)); echo "  FAIL: $desc (file not found: $path)"; fi
}

echo "=== Nudge Protocol Tests ==="

# Test: nudge fires when companion not installed
output=$(ib_nudge_companion "interphase" "automatic phase tracking" 2>&1) || true
assert_nonempty "nudge emits output for missing companion" "$output"

# Test: nudge respects session budget (max 2)
ib_nudge_companion "comp1" "benefit1" 2>/dev/null || true
ib_nudge_companion "comp2" "benefit2" 2>/dev/null || true
output=$(ib_nudge_companion "comp3" "benefit3" 2>&1) || true
assert_empty "nudge respects session budget of 2" "$output"

# Test: durable state file created
assert_file_exists "nudge state file exists" "$TEST_HOME/.config/interverse/nudge-state.json"

# Test: session file created
session_file="$TEST_HOME/.config/interverse/nudge-session-${CLAUDE_SESSION_ID}.json"
assert_file_exists "session nudge file exists" "$session_file"

echo ""
echo "Results: $PASS passed, $FAIL failed"
# cleanup via trap EXIT
[ "$FAIL" -eq 0 ] || exit 1
