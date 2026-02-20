#!/usr/bin/env bash
# Test interbase.sh guard functions
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_HOME=$(mktemp -d)
trap 'rm -rf "$TEST_HOME"' EXIT
export HOME="$TEST_HOME"

# Reset interbase state
unset _INTERBASE_LOADED _INTERBASE_SOURCE CLAVAIN_BEAD_ID

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
assert_eq() {
    local desc="$1" actual="$2" expected="$3"
    if [ "$actual" = "$expected" ]; then PASS=$((PASS + 1)); echo "  PASS: $desc"
    else FAIL=$((FAIL + 1)); echo "  FAIL: $desc (got '$actual', expected '$expected')"; fi
}
assert_empty() {
    local desc="$1" actual="$2"
    if [ -z "$actual" ]; then PASS=$((PASS + 1)); echo "  PASS: $desc"
    else FAIL=$((FAIL + 1)); echo "  FAIL: $desc (expected empty, got '$actual')"; fi
}
assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if echo "$haystack" | grep -qF "$needle" 2>/dev/null; then PASS=$((PASS + 1)); echo "  PASS: $desc"
    else FAIL=$((FAIL + 1)); echo "  FAIL: $desc (output did not contain '$needle')"; fi
}
assert_nonempty() {
    local desc="$1" actual="$2"
    if [ -n "$actual" ]; then PASS=$((PASS + 1)); echo "  PASS: $desc"
    else FAIL=$((FAIL + 1)); echo "  FAIL: $desc (expected non-empty)"; fi
}

echo "=== Guard Function Tests ==="

# _INTERBASE_LOADED is set
assert_nonempty "load guard set" "${_INTERBASE_LOADED:-}"

# ib_get_bead returns empty when no bead set
result=$(ib_get_bead)
assert_empty "ib_get_bead empty without CLAVAIN_BEAD_ID" "$result"

# ib_get_bead returns value when set
export CLAVAIN_BEAD_ID="iv-test1"
result=$(ib_get_bead)
assert_eq "ib_get_bead returns bead ID" "$result" "iv-test1"

# ib_in_sprint returns false without bead context
unset CLAVAIN_BEAD_ID
assert_not "ib_in_sprint false without bead context" ib_in_sprint

# ib_phase_set is no-op without bd (no error)
assert "ib_phase_set no-op without bd" ib_phase_set "iv-test1" "brainstorm" "test"

# ib_emit_event is no-op without ic (no error)
assert "ib_emit_event no-op without ic" ib_emit_event "run1" "test_event" '{"key":"val"}'

# ib_session_status emits to stderr
output=$(ib_session_status 2>&1)
assert_contains "ib_session_status emits [interverse]" "$output" "[interverse]"

# Double-source prevention — verify guard blocks re-execution
# Set INTERBASE_VERSION to sentinel; if re-source executes body, it would reset to "1.0.0"
INTERBASE_VERSION="sentinel_check"
source "$SCRIPT_DIR/../lib/interbase.sh"
assert_eq "load guard prevents double execution" "$INTERBASE_VERSION" "sentinel_check"

echo ""
echo "=== Stub Fallback Tests ==="

# Reset and test stub
unset _INTERBASE_LOADED _INTERBASE_SOURCE
export HOME="$TEST_HOME"  # No ~/.intermod/ exists

source "$SCRIPT_DIR/../templates/interbase-stub.sh"
assert_nonempty "stub sets _INTERBASE_LOADED" "${_INTERBASE_LOADED:-}"
assert_eq "stub sets _INTERBASE_SOURCE=stub" "${_INTERBASE_SOURCE:-}" "stub"

# Stub functions return safe defaults
assert_not "stub ib_in_sprint returns false" ib_in_sprint
assert "stub ib_phase_set is no-op" ib_phase_set "x" "y"
assert "stub ib_nudge_companion is no-op" ib_nudge_companion "x" "y"
assert "stub ib_emit_event is no-op" ib_emit_event "x" "y"

echo ""
echo "=== Live Source Tests ==="

# Install live copy and verify stub sources it
unset _INTERBASE_LOADED _INTERBASE_SOURCE
mkdir -p "$TEST_HOME/.intermod/interbase"
cp "$SCRIPT_DIR/../lib/interbase.sh" "$TEST_HOME/.intermod/interbase/interbase.sh"

source "$SCRIPT_DIR/../templates/interbase-stub.sh"
assert_eq "stub sources live copy when present" "${_INTERBASE_SOURCE:-}" "live"

# Verify live functions are richer than stubs (session_status emits output)
output=$(ib_session_status 2>&1)
assert_nonempty "live ib_session_status emits content" "$output"

echo ""
echo "Results: $PASS passed, $FAIL failed"
# cleanup via trap EXIT
[ "$FAIL" -eq 0 ] || exit 1
