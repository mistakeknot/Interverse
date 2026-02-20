# interbase — Shared Integration SDK

Centralized Bash SDK enabling Interverse plugins to work in both standalone (Claude Code marketplace) and integrated (Clavain/Intercore ecosystem) modes.

## File Structure

```
sdk/interbase/
  lib/
    interbase.sh    — core SDK (installed to ~/.intermod/interbase/)
    VERSION         — semver for installed copy
  templates/
    interbase-stub.sh   — shipped inside each plugin
    integration.json    — schema template for plugin integration manifests
  tests/
    test-guards.sh      — guard function + stub fallback tests
    test-nudge.sh       — nudge protocol tests
  install.sh            — deploy to ~/.intermod/interbase/
```

## Function Reference

### Guards (fail-open)
| Function | Signature | Behavior |
|----------|-----------|----------|
| `ib_has_ic` | `()` | Returns 0 if `ic` CLI is on PATH |
| `ib_has_bd` | `()` | Returns 0 if `bd` CLI is on PATH |
| `ib_has_companion` | `(name)` | Returns 0 if plugin `name` is in Claude Code cache |
| `ib_in_ecosystem` | `()` | Returns 0 if sourced via live copy (not stub) |
| `ib_get_bead` | `()` | Echoes `$CLAVAIN_BEAD_ID` or empty string |
| `ib_in_sprint` | `()` | Returns 0 if bead context + active ic run |

### Actions (no-op without dependencies)
| Function | Signature | Behavior |
|----------|-----------|----------|
| `ib_phase_set` | `(bead, phase, [reason])` | Sets phase via `bd set-state` (no-op without bd) |
| `ib_emit_event` | `(run_id, event_type, [payload])` | Emits via `ic events emit` (no-op without ic) |
| `ib_session_status` | `()` | Prints `[interverse] beads=... \| ic=...` to stderr |
| `ib_nudge_companion` | `(companion, benefit, [plugin])` | Suggests missing companion install (max 2/session) |

### Internal helpers (prefixed `_ib_`)
- `_ib_nudge_state_dir`, `_ib_nudge_state_file`, `_ib_nudge_session_file` — path helpers
- `_ib_nudge_session_count`, `_ib_nudge_session_increment` — session budget tracking
- `_ib_nudge_is_dismissed`, `_ib_nudge_record` — durable dismissal (3 ignores = dismissed)

## Install

```bash
bash sdk/interbase/install.sh
# Installs to ~/.intermod/interbase/interbase.sh
```

Uses atomic temp-then-mv to prevent partial reads by concurrent hooks.

## Plugin Adoption Pattern

1. Copy `templates/interbase-stub.sh` into plugin's `hooks/` directory
2. Create `integration.json` in `.claude-plugin/` using `templates/integration.json` as schema
3. Source the stub in session-start hook
4. Call `ib_*` functions — they're no-ops in standalone, functional in ecosystem

## Dev Testing

Override the live copy path without modifying `~/.intermod/`:
```bash
INTERMOD_LIB=/path/to/dev/interbase.sh bash your-hook.sh
```

Simulate standalone mode:
```bash
INTERMOD_LIB=/nonexistent bash your-hook.sh
```

## Test Commands

```bash
bash sdk/interbase/tests/test-guards.sh   # 16 tests
bash sdk/interbase/tests/test-nudge.sh     # 4 tests
```

## Load Guard Pattern

The stub must NOT set `_INTERBASE_LOADED` before attempting to source the live copy — otherwise the live copy's own guard would short-circuit, skipping all function definitions. The guard is only set in the fallback (stub) path.

## Nudge Protocol

- Max 2 nudges per session (tracked in `~/.config/interverse/nudge-session-*.json`)
- After 3 ignores of the same companion, permanently dismissed
- Durable state in `~/.config/interverse/nudge-state.json`
- Atomic dedup via `mkdir` (prevents parallel duplicate nudges)
- Only fires from live copy; stubs have a no-op implementation

## Relationship to interband

interband (`infra/interband/`) provides data sharing between plugins (key-value state, channels). interbase provides code sharing (SDK functions). Both use the same resolution pattern: env override → monorepo path → home directory fallback.
