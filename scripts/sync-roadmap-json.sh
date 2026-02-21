#!/usr/bin/env bash
# shellcheck disable=SC2155

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT_DOCS_DIR="$ROOT_DIR/docs"
OUTPUT="${1:-$ROOT_DOCS_DIR/roadmap.json}"
ROOT_ROADMAP_CANONICAL="$ROOT_DOCS_DIR/interverse-roadmap.md"
ROOT_ROADMAP_LEGACY="$ROOT_DOCS_DIR/roadmap.md"
EM_DASH="—"

require() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "Required command not found: $1" >&2
        exit 1
    }
}

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    echo "$value"
}

valid_item_id() {
    local value="$1"
    [[ "$value" =~ ^[A-Za-z][A-Za-z0-9._-]*-[A-Za-z0-9._-]+$ ]]
}

as_json_array() {
    local raw="$1"
    local self_id="${2:-}"
    if [ -z "$raw" ]; then
        echo "[]"
        return
    fi
    jq -R -s --arg self "$self_id" 'split("\n") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0)) | map(select(. != $self)) | unique' <<<"$raw"
}

module_roadmap_file() {
    local module_dir="$1"
    local module="$2"
    local canonical="$module_dir/docs/${module}-roadmap.md"
    local legacy="$module_dir/docs/roadmap.md"

    if [ -f "$canonical" ]; then
        echo "$canonical"
    elif [ -f "$legacy" ]; then
        echo "$legacy"
    else
        echo ""
    fi
}

root_roadmap_file() {
    if [ -f "$ROOT_ROADMAP_CANONICAL" ]; then
        echo "$ROOT_ROADMAP_CANONICAL"
    elif [ -f "$ROOT_ROADMAP_LEGACY" ]; then
        echo "$ROOT_ROADMAP_LEGACY"
    else
        echo ""
    fi
}

extract_version() {
    local module_dir="$1"
    local version
    if [ -f "$module_dir/.claude-plugin/plugin.json" ]; then
        version="$(jq -r '.version // empty' "$module_dir/.claude-plugin/plugin.json")"
        [ -n "$version" ] && echo "$version" && return
    fi
    if [ -f "$module_dir/package.json" ]; then
        version="$(jq -r '.version // empty' "$module_dir/package.json")"
        [ -n "$version" ] && echo "$version" && return
    fi
    if [ -f "$module_dir/pyproject.toml" ]; then
        version="$(grep -m1 -E '^version\s*=' "$module_dir/pyproject.toml" | sed -E 's/^version[[:space:]]*=[[:space:]]*\"([^\"]+)\".*$/\1/')"
        [ -n "$version" ] && echo "$version" && return
    fi
    echo "$EM_DASH"
}

map_phase() {
    local heading="$1"
    local lower
    lower="$(tr "[:upper:]" "[:lower:]" <<<"$heading")"
    if [[ "$lower" == *"later"* || "$lower" == *"deferred"* || "$lower" == *"backlog"* || "$lower" == *"long-term"* || "$lower" == *"phase 3"* || "$lower" == *"phase 4"* || "$lower" == *"p3"* || "$lower" == *"p4"* ]]; then
        echo "later"
    elif [[ "$lower" == *"phase 2"* || "$lower" == *"next"* || "$lower" == *"mid-term"* || "$lower" == *"p2"* ]]; then
        echo "next"
    elif [[ "$lower" == *"phase 1"* || "$lower" == *"now"* || "$lower" == *"current"* || "$lower" == *"short-term"* || "$lower" == *"p1"* || "$lower" == *"p0"* ]]; then
        echo "now"
    else
        echo "next"
    fi
}

priority_for() {
    local label="$1" phase="$2"
    if [[ "$label" == *P0* ]]; then echo "P0"
    elif [[ "$label" == *P1* ]]; then echo "P1"
    elif [[ "$label" == *P2* ]]; then echo "P2"
    elif [[ "$label" == *P3* ]]; then echo "P3"
    elif [[ "$label" == *P4* ]]; then echo "P4"
    else
        case "$phase" in
            now) echo "P1" ;;
            next) echo "P2" ;;
            later) echo "P3" ;;
            *) echo "P3" ;;
        esac
    fi
}

add_item() {
    local module="$1"
    local phase="$2"
    local item_id="$3"
    local title="$4"
    local source_tag="$5"
    local source_file="$6"
    local blocked_json="$7"
    local status="$8"
    local priority="$9"

    title="$(trim "$title")"
    status="$(trim "$status")"
    [ -n "$status" ] || status="open"
    [ -n "$source_file" ] || source_file="docs/roadmap.md"

    jq -c -n \
        --arg module "$module" \
        --arg id "$item_id" \
        --arg title "$title" \
        --arg phase "$phase" \
        --arg priority "$priority" \
        --arg status "$status" \
        --arg source "$source_tag" \
        --arg source_file "$source_file" \
        --arg notes "$title" \
        --argjson blocked_by "$blocked_json" \
        '{module:$module,id:$id,title:$title,phase:$phase,priority:$priority,status:$status,source:$source,source_file:$source_file,blocked_by:$blocked_by,notes:$notes}' \
        >>"$ITEMS_FILE"

    if [ "$status" != "closed" ]; then
        CURRENT_OPEN_COUNT=$((CURRENT_OPEN_COUNT + 1))
    fi
    ID_TO_MODULE["$item_id"]="$module"
}

add_module() {
    local module="$1"
    local location="$2"
    local version="$3"
    local roadmap_source="$4"
    local open_beads="$5"
    local status="$6"

    jq -c -n \
        --arg module "$module" \
        --arg location "$location" \
        --arg version "$version" \
        --arg roadmap_source "$roadmap_source" \
        --argjson open_beads "$open_beads" \
        --arg status "$status" \
        '{module:$module,location:$location,version:$version,has_roadmap:($roadmap_source!="none"),roadmap_source:$roadmap_source,open_beads:$open_beads,status:$status}' \
        >>"$MODULES_FILE"
}

add_highlight() {
    local module="$1"
    local location="$2"
    local summary="$3"
    summary="$(trim "$summary")"
    [ -z "$summary" ] && return
    jq -c -n --arg module "$module" --arg location "$location" --arg summary "$summary" \
        '{module:$module,location:$location,summary:$summary}' >>"$HIGHLIGHTS_FILE"
}

add_research() {
    local item="$1"
    local source_file="$2"
    item="$(trim "$item")"
    [ -z "$item" ] && return
    jq -c -n --arg item "$item" --arg sf "$source_file" \
        '{item:$item,source_file:$sf}' >>"$RESEARCH_FILE"
}

add_no_roadmap_module() {
    local module="$1"
    local location="$2"
    local version="$3"
    local notes="$4"
    jq -c -n --arg module "$module" --arg location "$location" --arg version "$version" --arg notes "$notes" \
        '{module:$module,location:$location,version:$version,notes:$notes}' >>"$NO_ROADMAP_FILE"
}

collect_markdown_items() {
    local module="$1"
    local source_file="$2"
    local source_path="$3"
    local location="$4"

    local line=""
    local raw line_clean
    local in_where=0 in_research=0
    local phase="next"
    local summary=""
    local summary_count=0
    local heading=""

    while IFS= read -r raw || [ -n "${raw:-}" ]; do
        line="$(trim "${raw//$'\r'/}")"
        [ -z "$line" ] && continue

        if [[ "$line" =~ ^#{2,}[[:space:]]+(.+) ]]; then
            heading="${BASH_REMATCH[1]}"
            phase="$(map_phase "$heading")"
            if (( in_where == 1 && summary_count > 0 )); then
                add_highlight "$module" "$location" "$summary"
                in_where=0
                summary=""
                summary_count=0
            fi
            in_research=0
            if [[ "$heading" == *"Research Agenda"* ]]; then
                in_research=1
            elif [[ "$heading" == *"Where We Are"* ]]; then
                in_where=1
            fi
            continue
        fi

        if (( in_research == 1 )); then
            if [[ "$line" =~ ^[[:space:]]*[-*][[:space:]] ]]; then
                line_clean="$(trim "${line#[*-]}")"
                add_research "$line_clean" "$source_path"
            fi
            continue
        fi

        if (( in_where == 1 )) && (( summary_count < 2 )) && [[ ! "$line" =~ ^[[:space:]]*[-*] ]]; then
            summary="$summary $line"
            summary_count=$((summary_count + 1))
            continue
        fi

        local item_id=""
        local title=""

        if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*\[([^]]+)\][[:space:]]*\*\*([^*]+)\*\*[[:space:]]*(.*)$ ]]; then
            item_id="${BASH_REMATCH[1]}"
            title="${BASH_REMATCH[2]}"
            if [ -n "${BASH_REMATCH[3]:-}" ]; then
                title="${title} ${BASH_REMATCH[3]}"
            fi
        elif [[ "$line" =~ ^[[:space:]]*\|[[:space:]]*([^|]+)[[:space:]]*\|[[:space:]]*([^|]+)\| ]]; then
            item_id="${BASH_REMATCH[1]}"
            title="${BASH_REMATCH[2]}"
        else
            continue
        fi

        item_id="$(trim "$item_id")"
        title="$(trim "$title")"
        if ! valid_item_id "$item_id"; then
            continue
        fi
        key="$module|$item_id"
        if [ -n "${SEEN_ITEM[$key]:-}" ]; then
            continue
        fi
        SEEN_ITEM["$key"]=1

        local status="open"
        local blocked
        if [[ "$title" == *"in progress"* || "$title" == *"in-progress"* ]]; then
            status="in_progress"
        elif [[ "$title" == *"blocked"* ]]; then
            status="blocked"
        fi
        blocked="$(grep -oE '[A-Za-z][A-Za-z0-9._-]*-[A-Za-z0-9._-]+' <<<"$title" || true)"
        local blocked_json
        blocked_json="$(as_json_array "$blocked" "$item_id")"
        add_item "$module" "$phase" "$item_id" "$title" "module-roadmap-md" "$source_path" "$blocked_json" "$status" "$(priority_for "$title" "$phase")"
    done < "$source_file"

    if (( in_where == 1 )) && (( summary_count > 0 )); then
        add_highlight "$module" "$location" "$summary"
    fi
}

collect_json_items() {
    local module="$1"
    local module_location="$2"
    local source_file="$3"
    local source_path="$4"

    local phase
    for phase in now next later; do
        while IFS= read -r line; do
            [ -z "$line" ] && continue

            local item_id
            item_id="$(trim "$(jq -r '.id // ""' <<<"$line")")"
            if ! valid_item_id "$item_id"; then
                continue
            fi

            local key="$module|$item_id"
            if [ -n "${SEEN_ITEM[$key]:-}" ]; then
                continue
            fi
            SEEN_ITEM["$key"]=1

            local title status priority
            title="$(trim "$(jq -r '.title // .name // .summary // .item // ""' <<<"$line")")"
            status="$(trim "$(jq -r '.status // "open"' <<<"$line")")"
            priority="$(trim "$(jq -r '.priority // ""' <<<"$line")")"
            if [ -z "$priority" ]; then
                priority="$(priority_for "$title" "$phase")"
            fi

            local blocked
            blocked="$(jq -r '.blocked_by // [] | if type=="string" then [.] elif type=="array" then . else [] end | .[]?' <<<"$line")"
            local blocked_json
            if [ -n "$blocked" ]; then
                blocked_json="$(printf '%s\n' "$blocked" | as_json_array "$item_id")"
            else
                blocked_json="[]"
            fi
            add_item "$module" "$phase" "$item_id" "$title" "module-roadmap-json" "$source_path" "$blocked_json" "$status" "$priority"
        done < <(jq -c --arg phase "$phase" '.roadmap[$phase][]?' "$source_file")
    done

    local summary
    summary="$(jq -r '.summary // .module_summary // empty' "$source_file")"
    [ -n "$summary" ] && add_highlight "$module" "$module_location" "$summary"
}

collect_research_json() {
    local source_file="$1"
    local source_path="$2"
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local item
        item="$(jq -r '.item // .title // empty' <<<"$line")"
        [ -n "$item" ] && add_research "$item" "$source_path"
    done < <(jq -c '.research_agenda[]?' "$source_file")
}

add_synthetic_roadmap_item() {
    local target_module="$1"
    local item_id="$2"
    local phase="$3"
    local item_context="$4"
    local title="$5"
    local source_file="$6"
    local source_tag="${7:-interverse-rollup}"
    local status="${8:-planned}"
    local priority="${9:-P2}"

    title="$(trim "$title")"
    [ -n "$title" ] || return
    if [ "$target_module" != "$item_context" ] && [ -n "$item_context" ]; then
        title="Platform: ${item_context} — ${title}"
    fi

    add_item "$target_module" \
        "$phase" \
        "PL-${item_id}" \
        "$title" \
        "$source_tag" \
        "$source_file" \
        "[]" \
        "$status" \
        "$priority"
}

collect_interverse_roadmap_from_json() {
    local source_file="$ROOT_DOCS_DIR/roadmap.json"
    [ -f "$source_file" ] || return 1
    local phase
    for phase in now next later; do
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            local item_id
            local item_title
            local item_source
            local priority
            local module
            item_id="$(trim "$(jq -r '.id // ""' <<<"$line")")"
            [ -n "$item_id" ] || continue
            item_title="$(trim "$(jq -r '.title // .summary // .item // ""' <<<"$line")")"
            [ -n "$item_title" ] || continue
            item_source="$(trim "$(jq -r '.source // ""' <<<"$line")")"
            priority="$(trim "$(jq -r '.priority // ""' <<<"$line")")"
            module="$(trim "$(jq -r '.module // "interverse"' <<<"$line")")"
            if [ "$module" = "interverse" ] || [ "$item_source" = "interverse-rollup" ] || [ "$item_source" = "missing-module-roadmap" ] || [ "$item_source" = "empty-module-roadmap" ] || [[ "$item_id" == PL-* ]]; then
                continue
            fi
            [ -n "$priority" ] || priority="$(priority_for "$item_title" "$phase")"
            add_synthetic_roadmap_item \
                "interverse" \
                "$item_id" \
                "$phase" \
                "$module" \
                "$item_title" \
                "$source_file" \
                "interverse-rollup" \
                "planned" \
                "$priority"
        done < <(jq -c --arg phase "$phase" '.roadmap[$phase][]?' "$source_file")
    done
    return 0
}

collect_interverse_roadmap_from_markdown() {
    local source_file
    source_file="$(root_roadmap_file)"
    [ -n "$source_file" ] || return 1
    [ -f "$source_file" ] || return 1

    local line
    local phase="next"
    local current_module=""

    while IFS= read -r line || [ -n "${line:-}" ]; do
        line="$(trim "${line//$'\r'/}")"
        [ -z "$line" ] && continue

        if [[ "$line" =~ ^#{2,3}[[:space:]]+Now ]]; then
            phase="now"
            continue
        fi
        if [[ "$line" =~ ^#{2,3}[[:space:]]+Next ]]; then
            phase="next"
            continue
        fi
        if [[ "$line" =~ ^#{2,3}[[:space:]]+Later ]]; then
            phase="later"
            continue
        fi

        if [[ "$line" =~ ^-[[:space:]]*\[([^\]]+)\][[:space:]]+\*\*([A-Za-z][A-Za-z0-9._-]*-[A-Za-z0-9._-]+)\*\*[[:space:]]*(.*)$ ]]; then
            current_module="${BASH_REMATCH[1]}"
            add_synthetic_roadmap_item \
                "interverse" \
                "${BASH_REMATCH[2]}" \
                "$phase" \
                "$current_module" \
                "${BASH_REMATCH[3]}" \
                "$source_file" \
                "interverse-rollup" \
                "planned" \
                "P2"
        elif [[ "$line" =~ ^[[:space:]]*\|[[:space:]]*([A-Za-z][A-Za-z0-9._-]*-[A-Za-z0-9._-]+)[[:space:]]*\|[[:space:]]*([^|]+)\| ]]; then
            add_synthetic_roadmap_item \
                "interverse" \
                "${BASH_REMATCH[1]}" \
                "$phase" \
                "${BASH_REMATCH[2]}" \
                "$source_file" \
                "interverse-rollup" \
                "planned" \
                "P2"
        fi
    done < "$source_file"
}

append_cross_dependencies() {
    while IFS= read -r line; do
        local item_id item_module
        item_id="$(jq -r '.id // empty' <<<"$line")"
        item_module="$(jq -r '.module // empty' <<<"$line")"
        [ -z "$item_id" ] && continue
        while IFS= read -r dep_id; do
            [ -z "$dep_id" ] && continue
            local dep_module="${ID_TO_MODULE[$dep_id]:-}"
            [ -z "$dep_module" ] && continue
            [ "$dep_module" = "$item_module" ] && continue
            local key="$item_id|$dep_id"
            if [ -n "${SEEN_CROSS[$key]:-}" ]; then
                continue
            fi
            SEEN_CROSS["$key"]=1
            jq -c -n --arg a "$item_id" --arg a_mod "$item_module" --arg b "$dep_id" --arg b_mod "$dep_module" \
                '{raw:($a + " [" + $a_mod + "] blocked by " + $b + " [" + $b_mod + "]")}' >>"$CROSS_FILE"
        done < <(jq -r '.blocked_by[]?' <<<"$line")
    done < "$ITEMS_FILE"
}

parse_root_fallback() {
    local source
    source="$(root_roadmap_file)"
    [ -f "$source" ] || return
    local source_label="docs/roadmap.md"
    if [ "$source" = "$ROOT_ROADMAP_CANONICAL" ]; then
        source_label="docs/interverse-roadmap.md"
    fi
    while IFS= read -r line || [ -n "${line:-}" ]; do
        if [[ "$line" =~ ^-[[:space:]]*\[([^]]+)\][[:space:]]+\*\*([^*]+)\*\* ]] && valid_item_id "${BASH_REMATCH[1]}"; then
            add_item "interverse" next "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "root-roadmap-fallback" "$source_label" "[]" "open" "P2"
        fi
    done < "$source"
}

require jq

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

MODULES_FILE="$TMP_DIR/modules.jsonl"
ITEMS_FILE="$TMP_DIR/items.jsonl"
HIGHLIGHTS_FILE="$TMP_DIR/highlights.jsonl"
RESEARCH_FILE="$TMP_DIR/research.jsonl"
NO_ROADMAP_FILE="$TMP_DIR/no-roadmap.jsonl"
CROSS_FILE="$TMP_DIR/cross.jsonl"
touch "$MODULES_FILE" "$ITEMS_FILE" "$HIGHLIGHTS_FILE" "$RESEARCH_FILE" "$NO_ROADMAP_FILE" "$CROSS_FILE"

declare -A SEEN_ITEM=()
declare -A ID_TO_MODULE=()
declare -A SEEN_CROSS=()

for base in "$ROOT_DIR/apps" "$ROOT_DIR/os" "$ROOT_DIR/core" "$ROOT_DIR/interverse"; do
    [ -d "$base" ] || continue
    while IFS= read -r -d '' module_dir; do
        module="$(basename "$module_dir")"
        module_location="${module_dir#$ROOT_DIR/}"
        version="$(extract_version "$module_dir")"
        roadmap_md_source="$(module_roadmap_file "$module_dir" "$module")"
        roadmap_json="$module_dir/docs/roadmap.json"
        CURRENT_OPEN_COUNT=0
        roadmap_source="none"
        has_roadmap=0
        module_items_before="$(wc -l < "$ITEMS_FILE")"

        if [ -f "$roadmap_json" ]; then
            roadmap_source="json"
            has_roadmap=1
            collect_json_items "$module" "$module_location" "$roadmap_json" "docs/roadmap.json"
            collect_research_json "$roadmap_json" "docs/roadmap.json"
        elif [ -f "$roadmap_md_source" ]; then
            roadmap_source="markdown"
            has_roadmap=1
            if [ "$roadmap_md_source" = "$module_dir/docs/${module}-roadmap.md" ]; then
                collect_markdown_items "$module" "$roadmap_md_source" "${module_location}/docs/${module}-roadmap.md" "$module_location"
            else
                collect_markdown_items "$module" "$roadmap_md_source" "${module_location}/docs/roadmap.md" "$module_location"
            fi
        fi

        if (( has_roadmap == 1 )); then
            module_items_after="$(wc -l < "$ITEMS_FILE")"
            module_item_count=$((module_items_after - module_items_before))
            add_module "$module" "$module_location" "$version" "$roadmap_source" "$CURRENT_OPEN_COUNT" "active"

            if [ "$module_item_count" -eq 0 ]; then
                add_synthetic_roadmap_item \
                    "$module" \
                    "${module}-EMPTY-RM" \
                    "later" \
                    "$module" \
                    "Roadmap file exists but has no parseable roadmap entries; add Now/Next/Later items to docs/${module}-roadmap.md, docs/roadmap.md, or docs/roadmap.json." \
                    "$module_location/docs/${module}-roadmap.md" \
                    "empty-module-roadmap" \
                    "planned" \
                    "P4"
            fi
        else
            if [ "$version" = "$EM_DASH" ]; then
                status="planned"
            else
                status="early"
            fi
            add_module "$module" "$module_location" "$version" "$roadmap_source" 0 "$status"
            add_no_roadmap_module "$module" "$module_location" "$version" "No docs/${module}-roadmap.md"
            add_synthetic_roadmap_item \
                "$module" \
                "${module}-NO-RM" \
                "later" \
                "$module" \
                "Roadmap artifact missing in this module; create docs/${module}-roadmap.md or docs/roadmap.md to define module priorities." \
                "$module_location/docs/${module}-roadmap.md" \
                "missing-module-roadmap" \
                "planned" \
                "P4"
        fi
    done < <(find "$base" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
done

if ! collect_interverse_roadmap_from_json; then
    collect_interverse_roadmap_from_markdown
fi
if [ -f "$ROOT_DOCS_DIR/roadmap.json" ]; then
    interverse_roadmap_source="json"
elif [ -n "$(root_roadmap_file)" ]; then
    interverse_roadmap_source="markdown"
else
    interverse_roadmap_source="none"
fi
interverse_open_beads=0
add_module "interverse" "root" "$(extract_version "$ROOT_DIR")" "$interverse_roadmap_source" "$interverse_open_beads" "active"

module_count="$(jq -s 'length' "$MODULES_FILE")"
if [ "$module_count" -eq 0 ]; then
    echo "No modules discovered under apps/, os/, core/, or interverse/" >&2
    exit 1
fi

if [ ! -s "$ITEMS_FILE" ]; then
    parse_root_fallback
fi

append_cross_dependencies

open_beads="$(jq -s '[.[] | select(.status == "open" or .status == "in_progress" or .status == "blocked")] | unique_by(.id) | length' "$ITEMS_FILE")"
blocked_items="$(jq -s '[.[] | select((.status=="blocked") or ((.blocked_by | length) > 0))] | unique_by(.id) | length' "$ITEMS_FILE")"

modules_json="$(jq -s '.' "$MODULES_FILE")"
items_now="$(jq -s '[.[] | select(.phase == "now")]' "$ITEMS_FILE")"
items_next="$(jq -s '[.[] | select(.phase == "next")]' "$ITEMS_FILE")"
items_later="$(jq -s '[.[] | select(.phase == "later")]' "$ITEMS_FILE")"
highlights_json="$(jq -s '.' "$HIGHLIGHTS_FILE")"
research_json="$(jq -s '.' "$RESEARCH_FILE")"
cross_json="$(jq -s '.' "$CROSS_FILE")"
no_roadmap_json="$(jq -s '.' "$NO_ROADMAP_FILE")"

if ! jq -n \
    --arg project "Interverse" \
    --arg kind "interverse-monorepo-roadmap" \
    --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%S%:z)" \
    --argjson module_count "$module_count" \
    --argjson open_beads "$open_beads" \
    --argjson blocked "$blocked_items" \
    --argjson modules "$modules_json" \
    --argjson roadmap_now "$items_now" \
    --argjson roadmap_next "$items_next" \
    --argjson roadmap_later "$items_later" \
    --argjson module_highlights "$highlights_json" \
    --argjson research_agenda "$research_json" \
    --argjson cross_module_dependencies "$cross_json" \
    --argjson modules_without "$no_roadmap_json" \
    '{project:$project,kind:$kind,generated_at:$generated_at,module_count:$module_count,open_beads:$open_beads,blocked:$blocked,modules:$modules,snapshot:$modules,roadmap:{now:$roadmap_now,next:$roadmap_next,later:$roadmap_later},module_highlights:$module_highlights,research_agenda:$research_agenda,cross_module_dependencies:$cross_module_dependencies,modules_without_roadmaps:$modules_without,dependency_graph:$cross_module_dependencies}' \
    >"$OUTPUT"; then
    echo "Failed to write $OUTPUT" >&2
    exit 1
fi

jq -M . "$OUTPUT" >"${OUTPUT}.tmp" && mv "${OUTPUT}.tmp" "$OUTPUT"
echo "Wrote roadmap JSON: $OUTPUT"
