#!/usr/bin/env bats
# Tests for gen-skill-compact.sh freshness checking and manifest format

SCRIPT="$BATS_TEST_DIRNAME/../gen-skill-compact.sh"
INTERVERSE_ROOT="$BATS_TEST_DIRNAME/../.."

# Load bats-support and bats-assert
setup() {
    NPM_GLOBAL=""
    for candidate in /usr/lib/node_modules /usr/local/lib/node_modules; do
        if [[ -d "$candidate/bats-support" ]]; then
            NPM_GLOBAL="$candidate"
            break
        fi
    done
    if [[ -n "$NPM_GLOBAL" ]]; then
        load "$NPM_GLOBAL/bats-support/load"
        load "$NPM_GLOBAL/bats-assert/load"
    fi
}

# ── Manifest format ──────────────────────────────────────────────────

@test "manifest: doc-watch manifest is valid JSON" {
    local manifest="$INTERVERSE_ROOT/plugins/interwatch/skills/doc-watch/.skill-compact-manifest.json"
    run jq '.' "$manifest"
    assert_success
}

@test "manifest: artifact-gen manifest is valid JSON" {
    local manifest="$INTERVERSE_ROOT/plugins/interpath/skills/artifact-gen/.skill-compact-manifest.json"
    run jq '.' "$manifest"
    assert_success
}

@test "manifest: flux-drive manifest is valid JSON" {
    local manifest="$INTERVERSE_ROOT/plugins/interflux/skills/flux-drive/.skill-compact-manifest.json"
    run jq '.' "$manifest"
    assert_success
}

@test "manifest: doc-watch manifest has SKILL.md key" {
    local manifest="$INTERVERSE_ROOT/plugins/interwatch/skills/doc-watch/.skill-compact-manifest.json"
    run jq -e '."SKILL.md"' "$manifest"
    assert_success
}

@test "manifest: artifact-gen manifest has SKILL.md key" {
    local manifest="$INTERVERSE_ROOT/plugins/interpath/skills/artifact-gen/.skill-compact-manifest.json"
    run jq -e '."SKILL.md"' "$manifest"
    assert_success
}

@test "manifest: flux-drive manifest has SKILL.md key" {
    local manifest="$INTERVERSE_ROOT/plugins/interflux/skills/flux-drive/.skill-compact-manifest.json"
    run jq -e '."SKILL.md"' "$manifest"
    assert_success
}

@test "manifest: all hash values are 64-char hex (SHA256)" {
    for skill in plugins/interwatch/skills/doc-watch plugins/interpath/skills/artifact-gen plugins/interflux/skills/flux-drive; do
        local manifest="$INTERVERSE_ROOT/$skill/.skill-compact-manifest.json"
        local bad
        bad=$(jq -r 'to_entries[] | select(.value | test("^[a-f0-9]{64}$") | not) | .key' "$manifest")
        [[ -z "$bad" ]] || { echo "Bad hash in $skill for: $bad"; return 1; }
    done
}

# ── Compact file existence ───────────────────────────────────────────

@test "compact: doc-watch SKILL-compact.md exists" {
    [[ -f "$INTERVERSE_ROOT/plugins/interwatch/skills/doc-watch/SKILL-compact.md" ]]
}

@test "compact: artifact-gen SKILL-compact.md exists" {
    [[ -f "$INTERVERSE_ROOT/plugins/interpath/skills/artifact-gen/SKILL-compact.md" ]]
}

@test "compact: flux-drive SKILL-compact.md exists" {
    [[ -f "$INTERVERSE_ROOT/plugins/interflux/skills/flux-drive/SKILL-compact.md" ]]
}

# ── Freshness checks via gen-skill-compact.sh ────────────────────────

@test "freshness: doc-watch is fresh" {
    run bash "$SCRIPT" --check "$INTERVERSE_ROOT/plugins/interwatch/skills/doc-watch"
    assert_success
    assert_output --partial "FRESH"
}

@test "freshness: artifact-gen is fresh" {
    run bash "$SCRIPT" --check "$INTERVERSE_ROOT/plugins/interpath/skills/artifact-gen"
    assert_success
    assert_output --partial "FRESH"
}

@test "freshness: flux-drive is fresh" {
    run bash "$SCRIPT" --check "$INTERVERSE_ROOT/plugins/interflux/skills/flux-drive"
    assert_success
    assert_output --partial "FRESH"
}

@test "freshness: --check-all reports all fresh" {
    run bash "$SCRIPT" --check-all
    assert_success
    # Verify all three skills appear in output
    assert_output --partial "doc-watch"
    assert_output --partial "artifact-gen"
    assert_output --partial "flux-drive"
}

# ── Staleness detection ──────────────────────────────────────────────

@test "freshness: detects stale manifest after source change" {
    local tmpdir
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/phases"

    # Create a minimal skill
    echo "# Test Skill" > "$tmpdir/SKILL.md"
    echo "# Phase 1" > "$tmpdir/phases/phase1.md"
    echo "# Compact" > "$tmpdir/SKILL-compact.md"

    # Write a manifest with wrong hashes
    echo '{"SKILL.md": "0000000000000000000000000000000000000000000000000000000000000000"}' > "$tmpdir/.skill-compact-manifest.json"

    run bash "$SCRIPT" --check "$tmpdir"
    assert_failure
    assert_output --partial "STALE"

    rm -rf "$tmpdir"
}

@test "freshness: missing manifest returns exit 2" {
    local tmpdir
    tmpdir=$(mktemp -d)
    echo "# Test" > "$tmpdir/SKILL.md"
    echo "# Compact" > "$tmpdir/SKILL-compact.md"
    # No manifest file

    run bash "$SCRIPT" --check "$tmpdir"
    [[ "$status" -eq 2 ]]

    rm -rf "$tmpdir"
}

@test "freshness: missing compact file returns exit 2" {
    local tmpdir
    tmpdir=$(mktemp -d)
    echo "# Test" > "$tmpdir/SKILL.md"
    echo '{}' > "$tmpdir/.skill-compact-manifest.json"
    # No SKILL-compact.md

    run bash "$SCRIPT" --check "$tmpdir"
    [[ "$status" -eq 2 ]]

    rm -rf "$tmpdir"
}

# ── CLI usage ────────────────────────────────────────────────────────

@test "cli: no args exits 2" {
    run bash "$SCRIPT"
    [[ "$status" -eq 2 ]]
}

@test "cli: --help exits 0" {
    run bash "$SCRIPT" --help
    assert_success
    assert_output --partial "Usage"
}

@test "cli: --check with missing SKILL.md exits 2" {
    local tmpdir
    tmpdir=$(mktemp -d)
    # Empty dir — no SKILL.md, no manifest

    run bash "$SCRIPT" --check "$tmpdir"
    [[ "$status" -eq 2 ]]

    rm -rf "$tmpdir"
}

# ── Generation smoke test ────────────────────────────────────────────

@test "generation: mock LLM produces compact + manifest" {
    local tmpdir
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/phases"
    echo "# Test Skill" > "$tmpdir/SKILL.md"
    echo "# Phase 1" > "$tmpdir/phases/phase1.md"

    # Use cat as mock LLM — echoes input back as output
    export GEN_COMPACT_CMD="cat"
    run bash "$SCRIPT" "$tmpdir"
    assert_success
    [[ -f "$tmpdir/SKILL-compact.md" ]]
    [[ -f "$tmpdir/.skill-compact-manifest.json" ]]

    # Manifest should be valid JSON with SKILL.md key
    run jq -e '."SKILL.md"' "$tmpdir/.skill-compact-manifest.json"
    assert_success

    rm -rf "$tmpdir"
}
