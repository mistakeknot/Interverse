#!/bin/bash
#
# interbump — unified version bump for all Interverse plugins.
#
# Auto-discovers version files, updates via jq (JSON) or sed (toml/md),
# handles marketplace, git pull --rebase + push, and cache symlink bridging.
#
# Usage:
#   interbump.sh <version> [--dry-run]
#
# Called from each plugin's scripts/bump-version.sh thin wrapper.
# Must be run from the plugin's root directory (where .claude-plugin/ lives).

set -euo pipefail

# --- Colors (TTY-aware) ---
if [ -t 1 ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; NC=''
fi

# --- Parse args ---
usage() {
    echo "Usage: $0 <version> [--dry-run]"
    echo "  version   Semver string, e.g. 0.5.0"
    echo "  --dry-run Show what would change without writing"
    exit 1
}

VERSION="" DRY_RUN=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --help|-h) usage ;;
        *) VERSION="$arg" ;;
    esac
done
[ -z "$VERSION" ] && usage

if ! echo "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$'; then
    echo -e "${RED}Error: '$VERSION' doesn't look like a valid version (expected X.Y.Z)${NC}" >&2
    exit 1
fi

# --- Locate plugin root ---
PLUGIN_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
PLUGIN_JSON="$PLUGIN_ROOT/.claude-plugin/plugin.json"

if [ ! -f "$PLUGIN_JSON" ]; then
    echo -e "${RED}Error: No .claude-plugin/plugin.json found at $PLUGIN_ROOT${NC}" >&2
    exit 1
fi

# --- Read plugin identity via jq ---
PLUGIN_NAME=$(jq -r '.name' "$PLUGIN_JSON")
CURRENT=$(jq -r '.version' "$PLUGIN_JSON")

if [ "$CURRENT" = "$VERSION" ]; then
    echo -e "${YELLOW}$PLUGIN_NAME already at $VERSION — nothing to do.${NC}"
    exit 0
fi

# --- Auto-discover version files ---
VERSION_FILES=(".claude-plugin/plugin.json")
[ -f "$PLUGIN_ROOT/pyproject.toml" ]        && VERSION_FILES+=("pyproject.toml")
[ -f "$PLUGIN_ROOT/package.json" ]           && VERSION_FILES+=("package.json")
[ -f "$PLUGIN_ROOT/server/package.json" ]    && VERSION_FILES+=("server/package.json")
[ -f "$PLUGIN_ROOT/agent-rig.json" ]         && VERSION_FILES+=("agent-rig.json")
[ -f "$PLUGIN_ROOT/docs/PRD.md" ]            && VERSION_FILES+=("docs/PRD.md")

# --- Find marketplace ---
MARKETPLACE_ROOT=""
# Walk up looking for infra/marketplace/ (monorepo layout)
dir="$PLUGIN_ROOT"
for _ in 1 2 3 4; do
    dir="$(dirname "$dir")"
    if [ -f "$dir/core/marketplace/.claude-plugin/marketplace.json" ]; then
        MARKETPLACE_ROOT="$dir/core/marketplace"
        break
    fi
done
# Fall back to legacy sibling layout
if [ -z "$MARKETPLACE_ROOT" ] && [ -f "$PLUGIN_ROOT/../interagency-marketplace/.claude-plugin/marketplace.json" ]; then
    MARKETPLACE_ROOT="$PLUGIN_ROOT/../interagency-marketplace"
fi

if [ -z "$MARKETPLACE_ROOT" ]; then
    echo -e "${RED}Error: Cannot find marketplace (tried core/marketplace/ and ../interagency-marketplace/)${NC}" >&2
    exit 1
fi

MARKETPLACE_JSON="$MARKETPLACE_ROOT/.claude-plugin/marketplace.json"
MARKETPLACE_CURRENT=$(jq -r --arg name "$PLUGIN_NAME" '.plugins[] | select(.name == $name) | .version' "$MARKETPLACE_JSON")

if [ -z "$MARKETPLACE_CURRENT" ]; then
    echo -e "${RED}Error: Plugin '$PLUGIN_NAME' not found in marketplace.json${NC}" >&2
    exit 1
fi

# --- Discovery table ---
echo -e "${CYAN}Plugin:${NC}      $PLUGIN_NAME"
echo -e "${CYAN}Current:${NC}     $CURRENT"
echo -e "${CYAN}New:${NC}         $VERSION"
echo -e "${CYAN}Files:${NC}       ${VERSION_FILES[*]}"
echo -e "${CYAN}Marketplace:${NC} $(realpath --relative-to="$PWD" "$MARKETPLACE_JSON" 2>/dev/null || echo "$MARKETPLACE_JSON") ($MARKETPLACE_CURRENT → $VERSION)"
echo ""

# --- Post-bump hook (plugin-specific pre-commit work) ---
POST_BUMP="$PLUGIN_ROOT/scripts/post-bump.sh"
if [ -f "$POST_BUMP" ]; then
    echo -e "${CYAN}Running post-bump hook...${NC}"
    if $DRY_RUN; then
        echo -e "  ${YELLOW}[dry-run]${NC} Would run scripts/post-bump.sh $VERSION"
    else
        bash "$POST_BUMP" "$VERSION"
    fi
    echo ""
fi

# --- Update version files ---
update_json() {
    local file="$1" label="$2"
    if $DRY_RUN; then
        echo -e "  ${YELLOW}[dry-run]${NC} $label"
    else
        local tmp="${file}.tmp"
        jq --arg ver "$VERSION" '.version = $ver' "$file" > "$tmp" && mv "$tmp" "$file"
        echo -e "  ${GREEN}Updated${NC} $label"
    fi
}

update_sed() {
    local file="$1" pattern="$2" replacement="$3" label="$4"
    if $DRY_RUN; then
        echo -e "  ${YELLOW}[dry-run]${NC} $label"
    else
        if [[ "$(uname)" == "Darwin" ]]; then
            sed -i '' "s|$pattern|$replacement|" "$file"
        else
            sed -i "s|$pattern|$replacement|" "$file"
        fi
        echo -e "  ${GREEN}Updated${NC} $label"
    fi
}

for vf in "${VERSION_FILES[@]}"; do
    case "$vf" in
        *.json)
            update_json "$PLUGIN_ROOT/$vf" "$vf"
            ;;
        pyproject.toml)
            # Match any version string — not anchored to $CURRENT, so
            # already-drifted files still get updated correctly.
            update_sed "$PLUGIN_ROOT/$vf" \
                "^version = \"[0-9][0-9.]*\"" \
                "version = \"$VERSION\"" \
                "$vf"
            ;;
        docs/PRD.md)
            update_sed "$PLUGIN_ROOT/$vf" \
                "^\*\*Version:\*\* [0-9][0-9.]*" \
                "**Version:** $VERSION" \
                "$vf"
            ;;
    esac
done

# --- Post-update verification ---
VERIFY_FAILED=false
for vf in "${VERSION_FILES[@]}"; do
    case "$vf" in
        *.json)
            actual=$(jq -r '.version' "$PLUGIN_ROOT/$vf" 2>/dev/null || echo "")
            ;;
        pyproject.toml)
            actual=$(grep -m1 '^version = ' "$PLUGIN_ROOT/$vf" 2>/dev/null | sed 's/version = "\(.*\)"/\1/')
            ;;
        docs/PRD.md)
            actual=$(grep -m1 '^\*\*Version:\*\*' "$PLUGIN_ROOT/$vf" 2>/dev/null | sed 's/\*\*Version:\*\* //')
            ;;
        *)
            continue
            ;;
    esac
    if [ "$actual" != "$VERSION" ]; then
        echo -e "  ${RED}VERIFY FAILED${NC} $vf: expected $VERSION, got '$actual'"
        VERIFY_FAILED=true
    fi
done

if $VERIFY_FAILED; then
    echo -e "\n${RED}Error: Some version files were not updated correctly. Aborting.${NC}" >&2
    exit 1
fi

# --- Update marketplace via jq ---
if $DRY_RUN; then
    echo -e "  ${YELLOW}[dry-run]${NC} marketplace.json ($PLUGIN_NAME)"
else
    tmp="${MARKETPLACE_JSON}.tmp"
    jq --arg name "$PLUGIN_NAME" --arg ver "$VERSION" \
        '(.plugins[] | select(.name == $name)).version = $ver' \
        "$MARKETPLACE_JSON" > "$tmp" && mv "$tmp" "$MARKETPLACE_JSON"
    echo -e "  ${GREEN}Updated${NC} marketplace.json ($PLUGIN_NAME)"
fi

if $DRY_RUN; then
    echo -e "\n${YELLOW}Dry run complete. No files changed.${NC}"
    exit 0
fi

# --- Git: plugin repo ---
echo ""
cd "$PLUGIN_ROOT"
git add "${VERSION_FILES[@]}"
git commit -m "chore: bump version to $VERSION"
git pull --rebase 2>/dev/null || true
git push
echo -e "${GREEN}Pushed $PLUGIN_NAME${NC}"

# --- Git: marketplace repo ---
cd "$MARKETPLACE_ROOT"
git add .claude-plugin/marketplace.json
git commit -m "chore: bump $PLUGIN_NAME to v$VERSION"
git pull --rebase 2>/dev/null || true
git push
echo -e "${GREEN}Pushed marketplace${NC}"

# --- Cache symlink bridging ---
if [ -f "$PLUGIN_ROOT/.claude-plugin/hooks/hooks.json" ] || [ -f "$PLUGIN_ROOT/hooks/hooks.json" ]; then
    CACHE_DIR="$HOME/.claude/plugins/cache/interagency-marketplace/$PLUGIN_NAME"
    if [[ -d "$CACHE_DIR" ]]; then
        REAL_DIR=""
        for candidate in "$CACHE_DIR"/*/; do
            [[ -d "$candidate" ]] || continue
            [[ -L "${candidate%/}" ]] && continue
            REAL_DIR="$(basename "$candidate")"
            break
        done

        if [[ -n "$REAL_DIR" ]]; then
            if [[ -n "$CURRENT" && "$CURRENT" != "$REAL_DIR" && ! -e "$CACHE_DIR/$CURRENT" ]]; then
                ln -sf "$REAL_DIR" "$CACHE_DIR/$CURRENT"
                echo -e "  ${GREEN}Symlinked${NC} cache/$CURRENT → $REAL_DIR"
            fi
            if [[ "$VERSION" != "$REAL_DIR" && ! -e "$CACHE_DIR/$VERSION" ]]; then
                ln -sf "$REAL_DIR" "$CACHE_DIR/$VERSION"
                echo -e "  ${GREEN}Symlinked${NC} cache/$VERSION → $REAL_DIR (pre-download bridge)"
            fi
            echo -e "  Running sessions' Stop hooks bridged via $REAL_DIR"
        fi
    fi
fi

# --- Install interbase.sh to ~/.intermod/ ---
install_interbase() {
    local interbase_dir
    interbase_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/sdk/interbase"
    if [[ -f "$interbase_dir/install.sh" ]]; then
        if $DRY_RUN; then
            echo -e "${CYAN}Would install interbase.sh to ~/.intermod/${NC}"
            return
        fi
        echo -e "${CYAN}Installing interbase.sh to ~/.intermod/...${NC}"
        bash "$interbase_dir/install.sh"
    fi
}
install_interbase

# --- Summary ---
echo ""
echo -e "${GREEN}Done!${NC} $PLUGIN_NAME v$VERSION"
echo ""
echo "Next: restart Claude Code sessions to pick up the new plugin version."
