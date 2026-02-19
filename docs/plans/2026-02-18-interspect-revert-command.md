# [interspect] /interspect:revert command

**Bead:** iv-ukct
**Phase:** executing (as of 2026-02-19T03:17:13Z)

## Context

The `/interspect:revert` command SKILL.md (`hub/clavain/commands/interspect-revert.md`) already exists with complete overlay+routing logic. The overlay disable functions (`_interspect_disable_overlay`, `_interspect_disable_overlay_locked`) are fully implemented in `lib-interspect.sh`.

**What's missing:** The routing override revert and blacklist operations are only defined as inline pseudocode in the SKILL.md — no reusable library functions exist. This means:
1. The revert logic is duplicated (SKILL.md inline vs what should be in lib)
2. It can't be tested via bats (no function to call)
3. It doesn't follow the established pattern (`_interspect_apply_routing_override` has a matching `_locked` function, but there's no `_interspect_revert_routing_override`)

## Tasks

### Task 1: Add `_interspect_revert_routing_override` to lib-interspect.sh

**File:** `hub/clavain/hooks/lib-interspect.sh`
**Location:** After `_interspect_apply_override_locked()` (line ~757), before the Overlay section header

Add two functions following the exact pattern of `_interspect_apply_routing_override`:

**`_interspect_revert_routing_override "$agent"`**
- Pre-flock validation: `_interspect_validate_agent_name`, `_interspect_validate_overrides_path`
- Idempotency check: verify override exists via `_interspect_override_exists`
- Write commit message to temp file
- Call `_interspect_flock_git _interspect_revert_override_locked ...`
- Clean up temp file, report success/failure

**`_interspect_revert_override_locked "$root" "$filepath" "$fullpath" "$agent" "$commit_msg_file" "$db"`**
- Read current JSON, `jq del(.overrides[] | select(.agent == $agent))`
- Write updated JSON
- `git add` + `git commit --no-verify -F "$commit_msg_file"`
- On git failure: rollback (unstage + restore)
- Update DB: `UPDATE canary SET status = 'reverted' WHERE group_id = '$agent' AND status = 'active'`
- Update DB: `UPDATE modifications SET status = 'reverted' WHERE group_id = '$agent' AND status = 'applied'`

### Task 2: Add `_interspect_blacklist_pattern` to lib-interspect.sh

**File:** `hub/clavain/hooks/lib-interspect.sh`
**Location:** After the revert functions from Task 1

**`_interspect_blacklist_pattern "$pattern_key" "$reason"`**
- Validate pattern_key with `_interspect_sql_escape`
- `INSERT OR REPLACE INTO blacklist (pattern_key, blacklisted_at, reason) VALUES (...)`
- Return 0 on success

This extracts the inline blacklist SQL from `interspect-revert.md` and `interspect-unblock.md` into a reusable function.

### Task 3: Update `interspect-revert.md` to use library functions

**File:** `hub/clavain/commands/interspect-revert.md`

Replace the inline `_interspect_revert_override_locked` definition and raw blacklist SQL with calls to the new library functions:
- Remove Override section: call `_interspect_revert_routing_override "$AGENT"` instead of inline flock logic
- Blacklist Decision sections: call `_interspect_blacklist_pattern "$AGENT" "reason"` instead of raw SQL

### Task 4: Add bats tests for revert and blacklist functions

**File:** `hub/clavain/tests/shell/test_interspect_routing.bats`

Add tests:
1. `_interspect_revert_routing_override` removes override from JSON and git commits
2. `_interspect_revert_routing_override` is idempotent (no-op if override doesn't exist)
3. `_interspect_revert_routing_override` rejects invalid agent names
4. `_interspect_revert_routing_override` updates canary status to 'reverted'
5. `_interspect_revert_routing_override` updates modifications status to 'reverted'
6. `_interspect_blacklist_pattern` inserts into blacklist table
7. `_interspect_blacklist_pattern` is idempotent (INSERT OR REPLACE)

### Task 5: Syntax check and run tests

```bash
bash -n hooks/lib-interspect.sh
bats tests/shell/test_interspect_routing.bats
```

## Acceptance Criteria

- `_interspect_revert_routing_override` and `_interspect_revert_override_locked` exist in lib
- `_interspect_blacklist_pattern` exists in lib
- SKILL.md uses library functions instead of inline logic
- All new bats tests pass
- `bash -n` succeeds on lib-interspect.sh
- Existing tests still pass
