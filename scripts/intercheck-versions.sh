#!/bin/bash
#
# intercheck-versions — verify all version locations are in sync.
#
# Auto-discovers version files (same logic as interbump.sh) and checks
# that they all contain the same version string. Also checks marketplace.
#
# Usage:
#   intercheck-versions.sh [-v|--verbose]
#
# Called from each plugin's scripts/check-versions.sh thin wrapper,
# or directly. Must be run from the plugin's root directory.
#
# Exit codes:
#   0 — all in sync
#   1 — mismatch detected

set -e

# --- Colors (TTY-aware) ---
if [ -t 1 ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; NC=''
fi

VERBOSE=false
for arg in "$@"; do
    case "$arg" in
        -v|--verbose) VERBOSE=true ;;
    esac
done

# --- Locate plugin root ---
PLUGIN_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
PLUGIN_JSON="$PLUGIN_ROOT/.claude-plugin/plugin.json"

if [ ! -f "$PLUGIN_JSON" ]; then
    echo -e "${RED}Error: No .claude-plugin/plugin.json found at $PLUGIN_ROOT${NC}" >&2
    exit 1
fi

PLUGIN_NAME=$(jq -r '.name' "$PLUGIN_JSON")
PLUGIN_VERSION=$(jq -r '.version' "$PLUGIN_JSON")

if [ -z "$PLUGIN_VERSION" ] || [ "$PLUGIN_VERSION" = "null" ]; then
    echo -e "${RED}Error: Could not extract version from plugin.json${NC}" >&2
    exit 1
fi

# --- Auto-discover version files (mirrors interbump.sh) ---
MISMATCH=false
check_version() {
    local file="$1" actual="$2" label="$3"
    if [ "$actual" != "$PLUGIN_VERSION" ]; then
        echo -e "${RED}Version mismatch!${NC}" >&2
        echo "  .claude-plugin/plugin.json:  $PLUGIN_VERSION" >&2
        echo "  $label:  $actual" >&2
        echo "" >&2
        MISMATCH=true
    fi
}

if [ -f "$PLUGIN_ROOT/pyproject.toml" ]; then
    PY_VERSION=$(grep -m1 -E '^version\s*=' "$PLUGIN_ROOT/pyproject.toml" | sed 's/.*"\([^"]*\)".*/\1/')
    if [ -n "$PY_VERSION" ]; then
        check_version "pyproject.toml" "$PY_VERSION" "pyproject.toml"
    fi
fi

if [ -f "$PLUGIN_ROOT/package.json" ]; then
    PKG_VERSION=$(jq -r '.version // empty' "$PLUGIN_ROOT/package.json")
    if [ -n "$PKG_VERSION" ]; then
        check_version "package.json" "$PKG_VERSION" "package.json"
    fi
fi

if [ -f "$PLUGIN_ROOT/server/package.json" ]; then
    SRV_VERSION=$(jq -r '.version // empty' "$PLUGIN_ROOT/server/package.json")
    if [ -n "$SRV_VERSION" ]; then
        check_version "server/package.json" "$SRV_VERSION" "server/package.json"
    fi
fi

# --- Find marketplace (same walk-up as interbump.sh) ---
MARKETPLACE_JSON=""
dir="$PLUGIN_ROOT"
for _ in 1 2 3 4; do
    dir="$(dirname "$dir")"
    if [ -f "$dir/core/marketplace/.claude-plugin/marketplace.json" ]; then
        MARKETPLACE_JSON="$dir/core/marketplace/.claude-plugin/marketplace.json"
        break
    fi
done
# Legacy sibling layout
if [ -z "$MARKETPLACE_JSON" ] && [ -f "$PLUGIN_ROOT/../interagency-marketplace/.claude-plugin/marketplace.json" ]; then
    MARKETPLACE_JSON="$PLUGIN_ROOT/../interagency-marketplace/.claude-plugin/marketplace.json"
fi

if [ -n "$MARKETPLACE_JSON" ]; then
    MKT_VERSION=$(jq -r --arg name "$PLUGIN_NAME" '.plugins[] | select(.name == $name) | .version' "$MARKETPLACE_JSON" 2>/dev/null)
    if [ -n "$MKT_VERSION" ] && [ "$MKT_VERSION" != "$PLUGIN_VERSION" ]; then
        echo -e "${RED}Marketplace version drift!${NC}" >&2
        echo "  plugin.json:    $PLUGIN_VERSION" >&2
        echo "  marketplace:    $MKT_VERSION" >&2
        echo "" >&2
        MISMATCH=true
    fi
fi

if $MISMATCH; then
    echo "Run: scripts/bump-version.sh $PLUGIN_VERSION" >&2
    exit 1
fi

if $VERBOSE; then
    echo -e "${GREEN}✓ $PLUGIN_NAME versions in sync: $PLUGIN_VERSION${NC}"
fi

exit 0
