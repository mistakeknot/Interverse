#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

declare -A MODULE_DEST=(
  [interject]="interverse/interject/docs"
  [intercore]="core/intercore/docs"
  [clavain]="os/clavain/docs"
  [interspect]="core/intercore/docs"
  [interfluence]="interverse/interfluence/docs"
  [interlock]="interverse/interlock/docs"
  [interstat]="interverse/interstat/docs"
  [interserve]="interverse/interserve/docs"
  [intermap]="interverse/intermap/docs"
  [intercheck]="interverse/intercheck/docs"
  [interflux]="interverse/interflux/docs"
  [intersynth]="interverse/intersynth/docs"
)

MODULE_ORDER=(
  interject
  intercore
  clavain
  interspect
  interfluence
  interlock
  interstat
  interserve
  intermap
  intercheck
  interflux
  intersynth
)

SECTIONS=(brainstorms plans prds research)
MOVED_FILES=0

# Create destination scaffolding up front.
for module in "${MODULE_ORDER[@]}"; do
  for section in "${SECTIONS[@]}"; do
    mkdir -p "${MODULE_DEST[$module]}/${section}"
  done
  mkdir -p "${MODULE_DEST[$module]}/research/flux-drive"
done
mkdir -p "interverse/interlens/docs/research/flux-drive"

move_file() {
  local src="$1"
  local dst="$2"

  mkdir -p "$(dirname "$dst")"
  if [[ -e "$dst" ]]; then
    echo "WARN: destination exists, skipping file: $dst" >&2
    return
  fi

  mv "$src" "$dst"
  ((MOVED_FILES += 1))
}

for section in "${SECTIONS[@]}"; do
  src_dir="docs/${section}"
  [[ -d "$src_dir" ]] || continue

  while IFS= read -r -d '' file; do
    base_name="$(basename "$file")"
    base_lower="$(printf '%s' "$base_name" | tr '[:upper:]' '[:lower:]')"

    # Keep linsenkasten files in shared docs.
    [[ "$base_lower" == *linsenkasten* ]] && continue

    matches=()
    for module in "${MODULE_ORDER[@]}"; do
      if [[ "$base_lower" == *"$module"* ]]; then
        matches+=("$module")
      fi
    done

    if [[ "${#matches[@]}" -eq 1 ]]; then
      module="${matches[0]}"
      dst_file="${MODULE_DEST[$module]}/${section}/${base_name}"
      move_file "$file" "$dst_file"
    elif [[ "${#matches[@]}" -gt 1 ]]; then
      echo "WARN: ambiguous module match, skipping file: $file" >&2
    fi
  done < <(find "$src_dir" -maxdepth 1 -type f -print0)
done

declare -A FLUX_DRIVE_DIR_MAP=(
  ["docs/research/flux-drive/2026-02-15-interspect-routing-overrides"]="core/intercore/docs/research/flux-drive/2026-02-15-interspect-routing-overrides"
  ["docs/research/flux-drive/2026-02-15-interspect-routing-overrides-plan"]="core/intercore/docs/research/flux-drive/2026-02-15-interspect-routing-overrides-plan"
  ["docs/research/flux-drive/interspect-overlay-plan"]="core/intercore/docs/research/flux-drive/interspect-overlay-plan"
  ["docs/research/flux-drive/intermap-extraction"]="interverse/intermap/docs/research/flux-drive/intermap-extraction"
  ["docs/research/flux-drive/2026-02-15-interlens-flux-agents"]="interverse/interlens/docs/research/flux-drive/2026-02-15-interlens-flux-agents"
  ["docs/research/flux-drive/clavain-token-efficiency-trio"]="os/clavain/docs/research/flux-drive/clavain-token-efficiency-trio"
  ["docs/research/flux-drive/2026-02-16-token-budget-controls"]="interverse/interstat/docs/research/flux-drive/2026-02-16-token-budget-controls"
)

for src_dir in "${!FLUX_DRIVE_DIR_MAP[@]}"; do
  dst_dir="${FLUX_DRIVE_DIR_MAP[$src_dir]}"
  [[ -d "$src_dir" ]] || continue

  if [[ -e "$dst_dir" ]]; then
    echo "WARN: destination exists, skipping directory: $dst_dir" >&2
    continue
  fi

  files_in_dir="$(find "$src_dir" -type f | wc -l | tr -d ' ')"
  mkdir -p "$(dirname "$dst_dir")"
  mv "$src_dir" "$dst_dir"
  ((MOVED_FILES += files_in_dir))
done

VERIFICATION_OUTPUT="$(
  find docs -type f -name '*.md' \
    | grep -iE 'interject|intercore|interspect|interfluence|interlock|interstat|interserve|intermap|intercheck|interflux|intersynth|clavain' \
    | grep -vi 'linsenkasten' \
    | grep -v '/guides/' \
    | grep -v '/solutions/' || true
)"

if [[ -z "$VERIFICATION_OUTPUT" ]]; then
  echo "VERDICT: CLEAN"
else
  echo "VERDICT: NEEDS_ATTENTION [module-tagged files still present in shared docs]"
  printf '%s\n' "$VERIFICATION_OUTPUT"
fi

echo "FILES_CHANGED: $MOVED_FILES"
