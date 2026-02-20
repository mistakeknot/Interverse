# Dual-Mode Plugin Architecture Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use clavain:executing-plans to implement this plan task-by-task.

**Goal:** Build the shared integration SDK (`interbase.sh`), integration manifest schema (`integration.json`), companion nudge protocol, and migrate interflux as the reference implementation of the dual-mode plugin pattern.

**Architecture:** Centralized `~/.intermod/interbase/interbase.sh` with per-plugin stub fallback (`hooks/interbase-stub.sh`). Each plugin declares its ecosystem surface in `.claude-plugin/integration.json`. The nudge protocol lives in the centralized copy only. interflux is the first plugin to adopt.

**Tech Stack:** Bash (interbase.sh), JSON (integration.json schema), bats-core (shell tests)

**Bead:** iv-gcu2
**Phase:** planned (as of 2026-02-20T21:03:09Z)

---

## Task 1: Create `infra/interbase/` directory structure

**Files:**
- Create: `infra/interbase/lib/interbase.sh`
- Create: `infra/interbase/templates/interbase-stub.sh`
- Create: `infra/interbase/templates/integration.json`
- Create: `infra/interbase/install.sh`
- Create: `infra/interbase/AGENTS.md`
- Create: `infra/interbase/README.md`

**Step 1: Create directory scaffold**

```bash
mkdir -p infra/interbase/lib infra/interbase/templates infra/interbase/tests
```

**Step 2: Create interbase.sh — load guard and core guards**

Write `infra/interbase/lib/interbase.sh` with:

```bash
#!/usr/bin/env bash
# Shared integration SDK for Interverse plugins.
#
# Contract:
# - Source via interbase-stub.sh (shipped in each plugin)
# - Centralized at ~/.intermod/interbase/interbase.sh
# - Fail-open: all functions return safe defaults if dependencies missing
# - No user-facing output at load time (use ib_session_status explicitly)

[[ -n "${_INTERBASE_LOADED:-}" ]] && return 0
_INTERBASE_LOADED=1

INTERBASE_VERSION="1.0.0"

# --- Guards ---
ib_has_ic()        { command -v ic &>/dev/null; }
ib_has_bd()        { command -v bd &>/dev/null; }
ib_has_companion() {
    local name="${1:-}"
    [[ -n "$name" ]] || return 1
    # Check Claude Code plugin cache for any version of the named plugin
    compgen -G "${HOME}/.claude/plugins/cache/*/${name}/*" &>/dev/null
}
ib_in_ecosystem()  { [[ -n "${_INTERBASE_LOADED:-}" ]] && [[ "${_INTERBASE_SOURCE:-}" == "live" ]]; }
ib_get_bead()      { echo "${CLAVAIN_BEAD_ID:-}"; }
ib_in_sprint() {
    [[ -n "${CLAVAIN_BEAD_ID:-}" ]] || return 1
    ib_has_ic || return 1
    ic run current --project=. &>/dev/null 2>&1
}

# --- Phase tracking (no-op without bd) ---
ib_phase_set() {
    local bead="$1" phase="$2" reason="${3:-}"
    ib_has_bd || return 0
    bd set-state "$bead" "phase=$phase" >/dev/null 2>&1 || true
}

# --- Event emission (no-op without ic) ---
ib_emit_event() {
    local run_id="$1" event_type="$2" payload="${3:-'{}'}"
    ib_has_ic || return 0
    ic events emit "$run_id" "$event_type" --payload="$payload" >/dev/null 2>&1 || true
}

# --- Session status (callable, not auto-emitting) ---
ib_session_status() {
    local parts=()
    if ib_has_bd; then parts+=("beads=active"); else parts+=("beads=not-detected"); fi
    if ib_has_ic; then
        if ic run current --project=. &>/dev/null 2>&1; then
            parts+=("ic=active")
        else
            parts+=("ic=not-initialized")
        fi
    else
        parts+=("ic=not-detected")
    fi
    # Count recommended companions not installed (requires integration.json reading — deferred)
    echo "[interverse] $(IFS=' | '; echo "${parts[*]}")" >&2
}
```

The nudge protocol functions will be added in Task 3.

**Step 3: Run syntax check**

Run: `bash -n infra/interbase/lib/interbase.sh`
Expected: No output (clean syntax)

**Step 4: Commit**

```bash
git add infra/interbase/lib/interbase.sh
git commit -m "feat(interbase): core SDK with guards, phase tracking, event emission"
```

---

## Task 2: Create interbase-stub.sh template and integration.json schema

**Files:**
- Create: `infra/interbase/templates/interbase-stub.sh`
- Create: `infra/interbase/templates/integration.json`

**Step 1: Write the stub template**

Write `infra/interbase/templates/interbase-stub.sh`:

```bash
#!/usr/bin/env bash
# interbase-stub.sh — shipped inside each plugin.
# Sources live ~/.intermod/ copy if present; falls back to inline stubs.

[[ -n "${_INTERBASE_LOADED:-}" ]] && return 0
_INTERBASE_LOADED=1

# Try centralized copy first (ecosystem users)
_interbase_live="${INTERMOD_LIB:-${HOME}/.intermod/interbase/interbase.sh}"
if [[ -f "$_interbase_live" ]]; then
    _INTERBASE_SOURCE="live"
    source "$_interbase_live"
    return 0
fi

# Fallback: inline stubs (standalone users)
_INTERBASE_SOURCE="stub"
ib_has_ic()          { command -v ic &>/dev/null; }
ib_has_bd()          { command -v bd &>/dev/null; }
ib_has_companion()   { compgen -G "${HOME}/.claude/plugins/cache/*/${1:-_}/*" &>/dev/null; }
ib_get_bead()        { echo "${CLAVAIN_BEAD_ID:-}"; }
ib_in_sprint()       { return 1; }
ib_phase_set()       { return 0; }
ib_nudge_companion() { return 0; }
ib_emit_event()      { return 0; }
ib_session_status()  { return 0; }
```

**Step 2: Write the integration.json template**

Write `infra/interbase/templates/integration.json`:

```json
{
  "ecosystem": "interverse",
  "interbase_min_version": "1.0.0",
  "ecosystem_only": false,
  "standalone_features": [],
  "integrated_features": [],
  "companions": {
    "recommended": [],
    "optional": []
  }
}
```

**Step 3: Syntax check both files**

Run: `bash -n infra/interbase/templates/interbase-stub.sh`
Expected: No output

Run: `python3 -c "import json; json.load(open('infra/interbase/templates/integration.json'))"`
Expected: No error

**Step 4: Commit**

```bash
git add infra/interbase/templates/
git commit -m "feat(interbase): stub template and integration.json schema"
```

---

## Task 3: Implement nudge protocol in interbase.sh

**Files:**
- Modify: `infra/interbase/lib/interbase.sh`

**Step 1: Write the failing test**

Write `infra/interbase/tests/test-nudge.sh`:

```bash
#!/usr/bin/env bash
# Test nudge protocol behavior
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_HOME=$(mktemp -d)
export HOME="$TEST_HOME"
export CLAUDE_SESSION_ID="test-session-$$"

# Reset interbase load state
unset _INTERBASE_LOADED _INTERBASE_SOURCE

source "$SCRIPT_DIR/../lib/interbase.sh"

PASS=0; FAIL=0
assert() {
    local desc="$1"; shift
    if "$@" 2>/dev/null; then ((PASS++)); echo "  PASS: $desc"
    else ((FAIL++)); echo "  FAIL: $desc"; fi
}
assert_not() {
    local desc="$1"; shift
    if ! "$@" 2>/dev/null; then ((PASS++)); echo "  PASS: $desc"
    else ((FAIL++)); echo "  FAIL: $desc"; fi
}

echo "=== Nudge Protocol Tests ==="

# Test: nudge fires when companion not installed
output=$(ib_nudge_companion "interphase" "automatic phase tracking" 2>&1) || true
assert "nudge emits output for missing companion" [[ -n "$output" ]]

# Test: nudge respects session budget (max 2)
ib_nudge_companion "comp1" "benefit1" 2>/dev/null || true
ib_nudge_companion "comp2" "benefit2" 2>/dev/null || true
output=$(ib_nudge_companion "comp3" "benefit3" 2>&1) || true
assert "nudge respects session budget of 2" [[ -z "$output" ]]

# Test: durable state file created
assert "nudge state file exists" [[ -f "$TEST_HOME/.config/interverse/nudge-state.json" ]]

# Test: session file created
assert "session nudge file exists" compgen -G "$TEST_HOME/.config/interverse/nudge-session-*" > /dev/null

echo ""
echo "Results: $PASS passed, $FAIL failed"
rm -rf "$TEST_HOME"
[[ $FAIL -eq 0 ]] || exit 1
```

**Step 2: Run test to verify it fails**

Run: `bash infra/interbase/tests/test-nudge.sh`
Expected: FAIL (ib_nudge_companion not yet implemented)

**Step 3: Implement nudge protocol in interbase.sh**

Add to `infra/interbase/lib/interbase.sh` after the event emission section:

```bash
# --- Companion nudge protocol ---
# Only fires from centralized copy (stubs have no-op). Max 2 per session.
# Durable state: ~/.config/interverse/nudge-state.json
# Session state: ~/.config/interverse/nudge-session-${CLAUDE_SESSION_ID}.json

_ib_nudge_state_dir() { echo "${HOME}/.config/interverse"; }
_ib_nudge_state_file() { echo "$(_ib_nudge_state_dir)/nudge-state.json"; }
_ib_nudge_session_file() {
    local sid="${CLAUDE_SESSION_ID:-unknown}"
    echo "$(_ib_nudge_state_dir)/nudge-session-${sid}.json"
}

_ib_nudge_session_count() {
    local sf
    sf="$(_ib_nudge_session_file)"
    [[ -f "$sf" ]] || { echo "0"; return; }
    command -v jq &>/dev/null || { echo "0"; return; }
    jq -r '.count // 0' "$sf" 2>/dev/null || echo "0"
}

_ib_nudge_session_increment() {
    local sf count
    sf="$(_ib_nudge_session_file)"
    mkdir -p "$(dirname "$sf")" 2>/dev/null || true
    count=$(_ib_nudge_session_count)
    count=$((count + 1))
    printf '{"count":%d}\n' "$count" > "$sf" 2>/dev/null || true
}

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

_ib_nudge_record() {
    local plugin="$1" companion="$2"
    local nf key
    nf="$(_ib_nudge_state_file)"
    mkdir -p "$(dirname "$nf")" 2>/dev/null || true
    key="${plugin}:${companion}"
    if [[ ! -f "$nf" ]]; then
        printf '{"%s":{"ignores":1,"dismissed":false}}\n' "$key" > "$nf" 2>/dev/null || true
        return
    fi
    command -v jq &>/dev/null || return 0
    local ignores
    ignores=$(jq -r --arg k "$key" '.[$k].ignores // 0' "$nf" 2>/dev/null) || ignores=0
    ignores=$((ignores + 1))
    local dismissed="false"
    if (( ignores >= 3 )); then dismissed="true"; fi
    local tmp="${nf}.tmp.$$"
    jq --arg k "$key" --argjson ig "$ignores" --argjson dis "$dismissed" \
        '.[$k] = {"ignores":$ig,"dismissed":$dis}' "$nf" > "$tmp" 2>/dev/null && \
        mv -f "$tmp" "$nf" 2>/dev/null || rm -f "$tmp" 2>/dev/null
}

ib_nudge_companion() {
    local companion="${1:-}" benefit="${2:-}" plugin="${3:-unknown}"
    [[ -n "$companion" ]] || return 0

    # Already installed — never nudge
    ib_has_companion "$companion" && return 0

    # Session budget exhausted (max 2)
    local count
    count=$(_ib_nudge_session_count)
    (( count >= 2 )) && return 0

    # Durable dismissal
    _ib_nudge_is_dismissed "$plugin" "$companion" && return 0

    # Check ecosystem_only — route to clavain:setup instead
    # (integration.json check would go here; for now use simple fallback)
    local install_cmd="/plugin install ${companion}"

    # Atomic: prevent parallel duplicate
    local flag_dir
    flag_dir="$(_ib_nudge_state_dir)"
    mkdir -p "$flag_dir" 2>/dev/null || true
    local flag="${flag_dir}/.nudge-${CLAUDE_SESSION_ID:-x}-${plugin}-${companion}"
    [[ ! -f "$flag" ]] || return 0
    touch "$flag" 2>/dev/null || return 0

    # Emit nudge
    echo "[interverse] Tip: run ${install_cmd} for ${benefit}." >&2

    # Record state
    _ib_nudge_session_increment
    _ib_nudge_record "$plugin" "$companion"
}
```

**Step 4: Run tests to verify they pass**

Run: `bash infra/interbase/tests/test-nudge.sh`
Expected: All PASS

**Step 5: Commit**

```bash
git add infra/interbase/lib/interbase.sh infra/interbase/tests/test-nudge.sh
git commit -m "feat(interbase): companion nudge protocol with durable state and session budget"
```

---

## Task 4: Create install script and VERSION file

**Files:**
- Create: `infra/interbase/install.sh`

**Step 1: Write the install script**

Write `infra/interbase/install.sh`:

```bash
#!/bin/bash
# Install interbase.sh to ~/.intermod/interbase/
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION=$(cat "$SCRIPT_DIR/lib/VERSION" 2>/dev/null || echo "1.0.0")
TARGET_DIR="${HOME}/.intermod/interbase"

mkdir -p "$TARGET_DIR"
cp "$SCRIPT_DIR/lib/interbase.sh" "$TARGET_DIR/interbase.sh"
chmod 644 "$TARGET_DIR/interbase.sh"
echo "$VERSION" > "$TARGET_DIR/VERSION"
chmod 644 "$TARGET_DIR/VERSION"

echo "Installed interbase.sh v${VERSION} to ${TARGET_DIR}/"
```

**Step 2: Create VERSION file**

Write `infra/interbase/lib/VERSION`:

```
1.0.0
```

**Step 3: Test the install**

Run: `bash infra/interbase/install.sh`
Expected: "Installed interbase.sh v1.0.0 to ~/.intermod/interbase/"

Run: `cat ~/.intermod/interbase/VERSION`
Expected: `1.0.0`

Run: `stat -c '%a' ~/.intermod/interbase/interbase.sh`
Expected: `644`

**Step 4: Commit**

```bash
git add infra/interbase/install.sh infra/interbase/lib/VERSION
git commit -m "feat(interbase): install script for ~/.intermod/ deployment"
```

---

## Task 5: Write core unit tests for interbase.sh

**Files:**
- Create: `infra/interbase/tests/test-guards.sh`

**Step 1: Write guard tests**

Write `infra/interbase/tests/test-guards.sh`:

```bash
#!/usr/bin/env bash
# Test interbase.sh guard functions
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_HOME=$(mktemp -d)
export HOME="$TEST_HOME"

# Reset interbase state
unset _INTERBASE_LOADED _INTERBASE_SOURCE CLAVAIN_BEAD_ID

source "$SCRIPT_DIR/../lib/interbase.sh"

PASS=0; FAIL=0
assert() {
    local desc="$1"; shift
    if "$@" 2>/dev/null; then ((PASS++)); echo "  PASS: $desc"
    else ((FAIL++)); echo "  FAIL: $desc"; fi
}
assert_not() {
    local desc="$1"; shift
    if ! "$@" 2>/dev/null; then ((PASS++)); echo "  PASS: $desc"
    else ((FAIL++)); echo "  FAIL: $desc"; fi
}

echo "=== Guard Function Tests ==="

# _INTERBASE_LOADED is set
assert "load guard set" [[ -n "${_INTERBASE_LOADED:-}" ]]

# ib_get_bead returns empty when no bead set
result=$(ib_get_bead)
assert "ib_get_bead empty without CLAVAIN_BEAD_ID" [[ -z "$result" ]]

# ib_get_bead returns value when set
export CLAVAIN_BEAD_ID="iv-test1"
result=$(ib_get_bead)
assert "ib_get_bead returns bead ID" [[ "$result" == "iv-test1" ]]

# ib_in_sprint returns false without ic
assert_not "ib_in_sprint false without ic" ib_in_sprint

# ib_phase_set is no-op without bd (no error)
assert "ib_phase_set no-op without bd" ib_phase_set "iv-test1" "brainstorm" "test"

# ib_emit_event is no-op without ic (no error)
assert "ib_emit_event no-op without ic" ib_emit_event "run1" "test_event" '{"key":"val"}'

# ib_session_status emits to stderr
output=$(ib_session_status 2>&1)
assert "ib_session_status emits [interverse]" [[ "$output" == *"[interverse]"* ]]

# Double-source prevention
unset _INTERBASE_LOADED
source "$SCRIPT_DIR/../lib/interbase.sh"
assert "load guard prevents double execution" [[ "${_INTERBASE_LOADED:-}" == "1" ]]

echo ""
echo "=== Stub Fallback Tests ==="

# Reset and test stub
unset _INTERBASE_LOADED _INTERBASE_SOURCE
export HOME="$TEST_HOME"  # No ~/.intermod/ exists

source "$SCRIPT_DIR/../templates/interbase-stub.sh"
assert "stub sets _INTERBASE_LOADED" [[ -n "${_INTERBASE_LOADED:-}" ]]
assert "stub sets _INTERBASE_SOURCE=stub" [[ "${_INTERBASE_SOURCE:-}" == "stub" ]]

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
assert "stub sources live copy when present" [[ "${_INTERBASE_SOURCE:-}" == "live" ]]

# Verify live functions are richer than stubs (session_status emits output)
output=$(ib_session_status 2>&1)
assert "live ib_session_status emits content" [[ -n "$output" ]]

echo ""
echo "Results: $PASS passed, $FAIL failed"
rm -rf "$TEST_HOME"
[[ $FAIL -eq 0 ]] || exit 1
```

**Step 2: Run tests**

Run: `bash infra/interbase/tests/test-guards.sh`
Expected: All PASS

**Step 3: Commit**

```bash
git add infra/interbase/tests/test-guards.sh
git commit -m "test(interbase): guard function tests, stub fallback, and live source verification"
```

---

## Task 6: Add AGENTS.md and README for infra/interbase/

**Files:**
- Create: `infra/interbase/AGENTS.md`
- Create: `infra/interbase/README.md`

**Step 1: Write AGENTS.md**

Write `infra/interbase/AGENTS.md` with: overview (shared integration SDK for Interverse plugins), file structure, function reference (all `ib_*` functions with signatures and behavior), install instructions, dev testing via `INTERMOD_LIB`, test commands, nudge protocol internals, and relationship to interband (data vs code pattern generalization).

**Step 2: Write README.md**

Brief user-facing README: what it is, how to install (`bash install.sh`), how plugins use it (via `interbase-stub.sh`).

**Step 3: Commit**

```bash
git add infra/interbase/AGENTS.md infra/interbase/README.md
git commit -m "docs(interbase): AGENTS.md and README"
```

---

## Task 7: Create interflux `integration.json`

**Files:**
- Create: `plugins/interflux/.claude-plugin/integration.json`

**Step 1: Write integration.json for interflux**

Write `plugins/interflux/.claude-plugin/integration.json`:

```json
{
  "ecosystem": "interverse",
  "interbase_min_version": "1.0.0",
  "ecosystem_only": false,
  "standalone_features": [
    "Multi-agent code review (12 review agents with domain auto-detection)",
    "Document review with automatic agent triage and scored findings",
    "Multi-agent research orchestration with parallel dispatch",
    "Domain-specific knowledge injection from config profiles"
  ],
  "integrated_features": [
    { "feature": "Phase tracking on review completion", "requires": "interphase" },
    { "feature": "Sprint gate enforcement for shipping", "requires": "intercore" },
    { "feature": "Bead-linked review findings", "requires": "beads" },
    { "feature": "Auto-review on doc drift detection", "requires": "interwatch" },
    { "feature": "Knowledge compounding from review findings", "requires": "clavain" }
  ],
  "companions": {
    "recommended": ["interwatch", "intersynth"],
    "optional": ["interphase", "interstat"]
  }
}
```

**Step 2: Validate JSON**

Run: `python3 -c "import json; d=json.load(open('plugins/interflux/.claude-plugin/integration.json')); print('OK:', len(d['standalone_features']), 'standalone,', len(d['integrated_features']), 'integrated')"`
Expected: `OK: 4 standalone, 5 integrated`

**Step 3: Commit (from interflux repo)**

```bash
cd /root/projects/Interverse/plugins/interflux
git add .claude-plugin/integration.json
git commit -m "feat(interflux): add integration.json for dual-mode architecture"
```

---

## Task 8: Add interbase-stub.sh and session-start hook to interflux

**Files:**
- Create: `plugins/interflux/hooks/interbase-stub.sh`
- Create: `plugins/interflux/hooks/hooks.json`
- Create: `plugins/interflux/hooks/session-start.sh`
- Modify: `plugins/interflux/.claude-plugin/plugin.json` (no change needed — hooks/ auto-loaded)

**Step 1: Copy stub template into interflux hooks**

```bash
mkdir -p plugins/interflux/hooks
cp infra/interbase/templates/interbase-stub.sh plugins/interflux/hooks/interbase-stub.sh
```

**Step 2: Create session-start.sh hook**

Write `plugins/interflux/hooks/session-start.sh`:

```bash
#!/usr/bin/env bash
# interflux session-start hook — source interbase and emit status
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source interbase (live or stub)
source "$HOOK_DIR/interbase-stub.sh"

# Emit ecosystem status (no-op in stub mode)
ib_session_status
```

**Step 3: Create hooks.json**

Write `plugins/interflux/hooks/hooks.json`:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "type": "command",
        "command": "bash ${CLAUDE_PLUGIN_ROOT}/hooks/session-start.sh"
      }
    ]
  }
}
```

**Step 4: Syntax check**

Run: `bash -n plugins/interflux/hooks/session-start.sh`
Expected: No output

Run: `python3 -c "import json; json.load(open('plugins/interflux/hooks/hooks.json'))"`
Expected: No error

**Step 5: Test standalone mode (no ~/.intermod/)**

```bash
# Temporarily rename intermod to simulate standalone
mv ~/.intermod ~/.intermod.bak 2>/dev/null || true
bash plugins/interflux/hooks/session-start.sh 2>&1
# Should produce no output (stub ib_session_status is no-op)
mv ~/.intermod.bak ~/.intermod 2>/dev/null || true
```

**Step 6: Test integrated mode (with ~/.intermod/)**

```bash
# Ensure interbase is installed
bash infra/interbase/install.sh
bash plugins/interflux/hooks/session-start.sh 2>&1
# Should produce: [interverse] beads=active | ic=...
```

**Step 7: Commit (from interflux repo)**

```bash
cd /root/projects/Interverse/plugins/interflux
git add hooks/
git commit -m "feat(interflux): add hooks with interbase-stub.sh and session-start"
```

---

## Task 9: Run full test suite and verify backwards compatibility

**Files:**
- No new files — validation only

**Step 1: Run interbase unit tests**

Run: `bash infra/interbase/tests/test-guards.sh`
Expected: All PASS

Run: `bash infra/interbase/tests/test-nudge.sh`
Expected: All PASS

**Step 2: Verify interflux plugin structure**

Run: `python3 -c "import json; d=json.load(open('plugins/interflux/.claude-plugin/plugin.json')); print('plugin.json OK')" && python3 -c "import json; d=json.load(open('plugins/interflux/.claude-plugin/integration.json')); print('integration.json OK')"`
Expected: Both OK

**Step 3: Verify hooks.json format**

Run: `python3 -c "import json; d=json.load(open('plugins/interflux/hooks/hooks.json')); assert 'hooks' in d; assert 'SessionStart' in d['hooks']; print('hooks.json OK')"`
Expected: `hooks.json OK`

**Step 4: Verify no existing interflux tests break**

```bash
cd /root/projects/Interverse/plugins/interflux
ls tests/ 2>/dev/null && echo "Run existing tests" || echo "No existing test suite"
```

If tests exist, run them and verify they pass.

**Step 5: Verify standalone mode produces no errors**

```bash
# Simulate fresh standalone install — no ~/.intermod/, no bd, no ic
env -u CLAVAIN_BEAD_ID HOME=$(mktemp -d) bash -c '
  source plugins/interflux/hooks/interbase-stub.sh
  ib_phase_set "x" "y" && echo "phase_set: OK"
  ib_emit_event "x" "y" && echo "emit_event: OK"
  ib_nudge_companion "x" "y" && echo "nudge: OK"
  echo "All standalone no-ops: OK"
'
```
Expected: All OK, no errors

**Step 6: Commit any fixes**

If any tests fail, fix and commit. Otherwise no commit needed.

---

## Task 10: Update interbump to install interbase.sh

**Files:**
- Modify: `scripts/interbump.sh`

**Step 1: Add intermod install to interbump**

Add a function to `scripts/interbump.sh` that runs after the version bump:

```bash
# After all version bumps, ensure ~/.intermod/ has latest interbase.sh
install_interbase() {
    local interbase_dir
    interbase_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/infra/interbase"
    if [[ -f "$interbase_dir/install.sh" ]]; then
        echo -e "${CYAN}Installing interbase.sh to ~/.intermod/...${NC}"
        bash "$interbase_dir/install.sh"
    fi
}
```

Call `install_interbase` at the end of the main execution flow.

**Step 2: Test interbump with --dry-run**

Run: `cd plugins/interflux && bash ../../scripts/interbump.sh 0.2.16 --dry-run`
Expected: Shows version bump operations, mentions interbase install

**Step 3: Commit**

```bash
git add scripts/interbump.sh
git commit -m "feat(interbump): install interbase.sh to ~/.intermod/ at publish time"
```

---

## Task 11: Final integration test and documentation update

**Files:**
- Modify: `infra/interbase/AGENTS.md` (if needed)
- Modify: `plugins/interflux/AGENTS.md` (add dual-mode section)

**Step 1: Full end-to-end test**

```bash
# 1. Install interbase
bash infra/interbase/install.sh

# 2. Run all interbase tests
bash infra/interbase/tests/test-guards.sh
bash infra/interbase/tests/test-nudge.sh

# 3. Test interflux standalone
env HOME=$(mktemp -d) bash plugins/interflux/hooks/session-start.sh 2>&1
# Expected: no output (stub mode)

# 4. Test interflux integrated
bash plugins/interflux/hooks/session-start.sh 2>&1
# Expected: [interverse] beads=... | ic=...

# 5. Verify VERSION
cat ~/.intermod/interbase/VERSION
# Expected: 1.0.0
```

**Step 2: Update interflux AGENTS.md**

Add a "Dual-Mode Architecture" section to `plugins/interflux/AGENTS.md` documenting:
- interbase-stub.sh sourcing pattern
- integration.json contents
- How standalone vs integrated mode works
- Testing: standalone, integrated, degradation

**Step 3: Final commit**

```bash
cd /root/projects/Interverse/plugins/interflux
git add AGENTS.md
git commit -m "docs(interflux): add dual-mode architecture section to AGENTS.md"
```

```bash
cd /root/projects/Interverse
git add infra/interbase/
git commit -m "feat(interbase): complete interbase SDK v1.0.0 with tests and docs"
```
