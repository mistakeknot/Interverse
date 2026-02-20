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
    echo "[interverse] $(IFS=' | '; echo "${parts[*]}")" >&2
}

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
        jq --null-input --arg k "$key" '{($k): {"ignores": 1, "dismissed": false}}' > "$nf" 2>/dev/null || true
        return
    fi
    command -v jq &>/dev/null || return 0
    local ignores
    ignores=$(jq -r --arg k "$key" '.[$k].ignores // 0' "$nf" 2>/dev/null) || ignores=0
    ignores=$((ignores + 1))
    local dismissed="false"
    if (( ignores >= 3 )); then dismissed="true"; fi
    local tmp
    tmp=$(mktemp "${nf}.XXXXXX") || return 0
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

    # Atomic dedup: mkdir is atomic on POSIX — first caller wins
    local flag_dir
    flag_dir="$(_ib_nudge_state_dir)"
    mkdir -p "$flag_dir" 2>/dev/null || true
    local flag="${flag_dir}/.nudge-${CLAUDE_SESSION_ID:-x}-${plugin}-${companion}"
    mkdir "$flag" 2>/dev/null || return 0  # fails if already exists = dedup

    # Emit nudge
    echo "[interverse] Tip: run /plugin install ${companion} for ${benefit}." >&2

    # Record state
    _ib_nudge_session_increment
    _ib_nudge_record "$plugin" "$companion"
}
