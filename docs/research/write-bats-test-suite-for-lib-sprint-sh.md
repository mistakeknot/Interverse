# BATS Test Suite for lib-sprint.sh — Analysis

## Overview

Created a comprehensive BATS test suite at `/root/projects/Interverse/hub/clavain/tests/shell/test_lib_sprint.bats` covering all 23 required test cases for the sprint state library (`hooks/lib-sprint.sh`).

**Result: All 23 tests pass.**

## Architecture of the Test Suite

### Mock Strategy

The test suite uses mock `bd()` shell functions defined within each `@test` block. This avoids needing a real beads database while allowing precise control over what each `bd` subcommand returns. Key patterns:

- **Per-test mocks**: Each test defines its own `bd()` with `export -f bd` for the specific behavior needed.
- **Call logging**: Tests that need to verify *which* commands were called use `BD_CALL_LOG` — a temp file that `bd()` appends to, then verified with `grep`.
- **Stateful mocks**: Tests like concurrent artifact writes (#9) use a state file (`BD_STATE_FILE`) that the mock reads from and writes to, simulating real bd state persistence.

### Source Guard Handling

`lib-sprint.sh` uses `_SPRINT_LOADED` as a double-source guard. The `_source_sprint_lib()` helper unsets all guards (`_SPRINT_LOADED`, `_GATES_LOADED`, `_PHASE_LOADED`, `_DISCOVERY_LOADED`, `_LIB_LOADED`) before each re-source to ensure clean loading.

### Dependency Isolation

`lib-sprint.sh` sources `lib.sh` and `lib-gates.sh` from the same directory. These are loaded with `2>/dev/null || true`, so they gracefully degrade. The test sets `INTERPHASE_ROOT=""` so lib-gates.sh provides no-op stubs rather than trying to delegate to a real interphase installation.

### Temp Directory Pattern

Each test gets an isolated `TEST_PROJECT` temp directory with a `.beads` subdirectory (required by `sprint_find_active`). Cleanup happens in `teardown()` for both temp dirs and lock files.

## Test Coverage Map

| # | Test | Function | What it validates |
|---|------|----------|-------------------|
| 1 | sprint_create returns a valid bead ID | `sprint_create` | Happy path — creates bead, returns extracted ID |
| 2 | sprint_create partial init failure cancels bead | `sprint_create` | Rollback on `set-state phase=brainstorm` failure, verify cancel call |
| 3 | sprint_finalize_init sets sprint_initialized=true | `sprint_finalize_init` | Correct bd set-state call |
| 4 | sprint_find_active returns only initialized sprint beads | `sprint_find_active` | Filters out uninitialized sprints |
| 5 | sprint_find_active excludes non-sprint beads | `sprint_find_active` | Filters out beads where sprint!=true |
| 6 | sprint_read_state returns all fields as valid JSON | `sprint_read_state` | All 7 fields present, valid JSON |
| 7 | sprint_read_state recovers from corrupt JSON | `sprint_read_state` | Corrupt artifacts/history fall back to `{}` |
| 8 | sprint_set_artifact updates artifact path under lock | `sprint_set_artifact` | Lock acquired, artifact written, lock released |
| 9 | sprint_set_artifact handles concurrent calls | `sprint_set_artifact` | Two sequential calls, both keys present in final state |
| 10 | sprint_set_artifact stale lock cleanup after 5s | `sprint_set_artifact` | Pre-created lock with old mtime gets broken |
| 11 | sprint_record_phase_completion adds timestamp | `sprint_record_phase_completion` | `phase_history` updated with `{phase}_at` key |
| 12 | sprint_record_phase_completion invalidates caches | `sprint_record_phase_completion` | Cache files deleted |
| 13 | sprint_claim succeeds for first claimer | `sprint_claim` | Returns 0, session written |
| 14 | sprint_claim blocks second claimer | `sprint_claim` | Returns 1 when another session holds claim |
| 15 | sprint_claim allows takeover after TTL expiry | `sprint_claim` | 61-minute-old claim gets taken over |
| 16 | sprint_claim blocks at 59 minutes | `sprint_claim` | Not-yet-expired claim blocks new claimer |
| 17 | sprint_release clears claim | `sprint_release` | Both active_session and claim_timestamp cleared |
| 18 | sprint_next_step maps all phases correctly | `sprint_next_step` | All 9 phase mappings verified |
| 19 | sprint_next_step returns brainstorm for unknown | `sprint_next_step` | Fallback behavior for unknown input |
| 20 | sprint_invalidate_caches removes cache files | `sprint_invalidate_caches` | Multiple cache files deleted |
| 21 | sprint_find_active returns [] when bd not available | `sprint_find_active` | Graceful degradation without bd |
| 22 | sprint_create returns "" when bd fails | `sprint_create` | Graceful degradation without bd |
| 23 | enforce_gate delegates to check_phase_gate | `enforce_gate` | Wrapper passes args through correctly |

## Key Implementation Details

### Test 2 (Partial Init Failure)
The mock `bd set-state` checks `$*` for `phase=brainstorm` and returns 1. The test then verifies `bd update iv-fail1 --status=cancelled` appears in the call log. This validates the rollback path in `sprint_create`.

### Test 9 (Concurrent Artifacts)
Uses a state file as persistent mock storage. Two sequential `sprint_set_artifact` calls write different artifact types. The test verifies both keys are present in the final JSON — confirming the read-modify-write cycle under locking works correctly.

### Test 10 (Stale Lock)
Creates a lock directory, then uses `touch -d "10 seconds ago"` to backdate its mtime. The library's stale lock detection (>5 seconds) kicks in after 10 retries, breaks the lock, and the operation succeeds.

### Tests 15-16 (TTL Boundary)
Use `date -d "61 minutes ago"` and `date -d "59 minutes ago"` to test the exact TTL boundary. The library uses 60-minute TTL (`age_minutes -lt 60`), so 61 minutes allows takeover while 59 minutes blocks.

### Test 23 (enforce_gate)
The mock `check_phase_gate` must be defined AFTER sourcing `lib-sprint.sh`, because the sourcing chain loads `lib-gates.sh` which defines its own no-op `check_phase_gate` stub. Defining the mock before sourcing would get overwritten.

## Gotchas Encountered

1. **bash -n fails on .bats files**: BATS uses `@test` syntax that isn't valid bash. Syntax checking must be done by running `bats` itself, not `bash -n`.

2. **Source guard interaction**: `_SPRINT_LOADED` must be unset before every source, but so must the guards for `lib.sh` (`_LIB_LOADED`) and `lib-gates.sh` (`_GATES_LOADED`) since `lib-sprint.sh` sources them transitively.

3. **Function definition ordering with lib-gates.sh**: The `check_phase_gate` no-op stub from `lib-gates.sh` overwrites any mock defined before sourcing. The mock must come after `_source_sprint_lib()`.

4. **Lock directories vs files**: The sprint lock mechanism uses `mkdir` for atomic locking. The stale lock test must create a directory (not a file) and use `touch -d` on it to backdate the mtime.

5. **bd state mock for sprint_claim verify step**: `sprint_claim` writes `active_session=$session_id` then reads it back for verification. The mock must return the written value on the verify read, requiring a state file approach.
