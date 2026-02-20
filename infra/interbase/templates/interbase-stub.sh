#!/usr/bin/env bash
# interbase-stub.sh — shipped inside each plugin.
# Sources live ~/.intermod/ copy if present; falls back to inline stubs.

[[ -n "${_INTERBASE_LOADED:-}" ]] && return 0

# Try centralized copy first (ecosystem users)
# NOTE: Do NOT set _INTERBASE_LOADED before sourcing — the live copy sets its
# own guard. Setting it here would cause the live source to return immediately,
# skipping all function definitions.
_interbase_live="${INTERMOD_LIB:-${HOME}/.intermod/interbase/interbase.sh}"
if [[ -f "$_interbase_live" ]]; then
    _INTERBASE_SOURCE="live"
    source "$_interbase_live"
    return 0
fi

# Fallback: inline stubs (standalone users)
_INTERBASE_LOADED=1
_INTERBASE_SOURCE="stub"
ib_has_ic()          { command -v ic &>/dev/null; }
ib_has_bd()          { command -v bd &>/dev/null; }
ib_has_companion()   { compgen -G "${HOME}/.claude/plugins/cache/*/${1:-_}/*" &>/dev/null; }
ib_get_bead()        { echo "${CLAVAIN_BEAD_ID:-}"; }
ib_in_ecosystem()    { return 1; }
ib_in_sprint()       { return 1; }
ib_phase_set()       { return 0; }
ib_nudge_companion() { return 0; }
ib_emit_event()      { return 0; }
ib_session_status()  { return 0; }
