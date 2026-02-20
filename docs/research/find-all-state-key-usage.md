# State Key Usage: `ic state set` and `intercore_state_set`

**Date:** 2026-02-19
**Scope:** All shell scripts in `hub/clavain/hooks/`, `infra/intercore/`, and supporting docs.

---

## Summary

Three state keys are currently in use in **live production shell code** (hooks and integration tests). Several additional keys appear only in **planning/research documents** (aspirational, not yet implemented). One key (`sprint_link`) was explicitly removed.

---

## Live State Keys (In Actual Shell Scripts)

### 1. `checkpoint`

**Used in:** `hub/clavain/hooks/lib-sprint.sh`

Primary storage for sprint checkpoint data (bead ID, phase, step, plan path, git SHA, timestamps, completed steps, key decisions).

```bash
# Write (lib-sprint.sh:1002)
intercore_state_set "checkpoint" "$run_id" "$checkpoint_json" 2>/dev/null || true

# Read (lib-sprint.sh:986)
existing=$(intercore_state_get "checkpoint" "$run_id") || existing="{}"

# Read (lib-sprint.sh:1047)
ckpt=$(intercore_state_get "checkpoint" "$run_id") || ckpt=""
```

**Scope:** `$run_id` (the intercore run ID associated with the bead)

**Notes:** Previously stored in `.clavain/checkpoint.json`; migrated to ic state as the primary path. File-based fallback still exists when ic is unavailable.

---

### 2. `cursor`

**Used in:** `hub/clavain/hooks/lib-intercore.sh` (the `intercore_events_cursor_set` wrapper function)

Stores event bus consumer cursor positions. Written with `--ttl=24h`.

```bash
# Write (lib-intercore.sh:436)
echo "{\"phase\":${phase_id},\"dispatch\":${dispatch_id}}" | \
    $INTERCORE_BIN state set "cursor" "$consumer" --ttl=24h 2>/dev/null
```

**Scope:** `$consumer` (consumer name, e.g., an agent or hook identifier)

**Notes:** This is written via the low-level `$INTERCORE_BIN state set` call, not via `intercore_state_set()`. The `intercore_events_cursor_set` wrapper function wraps this pattern. The primary cursor management path goes through `ic events cursor list/reset` — this wrapper is a manual override path.

---

### 3. `discovery_brief` (delete-only)

**Used in:** `hub/clavain/hooks/lib-sprint.sh` (the `sprint_invalidate_discovery_cache` function)

The key is **deleted** (all scopes) when sprint state changes, invalidating cached discovery briefs.

```bash
# Delete-all (lib-sprint.sh:1109)
intercore_state_delete_all "discovery_brief" "/tmp/clavain-discovery-brief-*.cache"
```

**Scope:** Varies — all scopes deleted at once via `intercore_state_delete_all`.

**Notes:** The second argument `/tmp/clavain-discovery-brief-*.cache` is the legacy file glob passed to `intercore_state_delete_all` — in the current lib-intercore.sh version this arg is accepted but the function uses `ic state list` to find scopes. This key is never written via `ic state set` in the current hooks (it may be written by interphase/lib-discovery.sh separately). It is only managed here via delete.

---

### 4. `dispatch` (test/integration only)

**Used in:** `infra/intercore/test-integration.sh`

Used in integration tests to verify round-trip state storage. Not used in production hooks.

```bash
# Write (test-integration.sh:50)
printf '%s\n' '{"phase":"brainstorm"}' | ic state set dispatch test-session --db="$TEST_DB"

# Write (test-integration.sh:106)
printf '%s\n' '{"test":true}' | ic state set dispatch test-session --db="$TEST_DB"

# Write (test-integration.sh:65) — secret rejection test
printf '%s\n' '{"token":"sk-abc1234567890abcdefghijklmnop"}' | ic state set dispatch secret-test --db="$TEST_DB"
```

**Scope:** `test-session`, `secret-test`

**Notes:** This key appears in many planning docs as the canonical example for session dispatch state. However, there is **no production hook code** that actually writes to `dispatch` — it exists only in integration tests and research documents.

---

### 5. `ephemeral` (test only)

**Used in:** `infra/intercore/test-integration.sh`

TTL test key. Not used in production hooks.

```bash
printf '%s\n' '{"temp":true}' | ic state set ephemeral test-session --ttl=1s --db="$TEST_DB"
```

---

### 6. `bad` (test only)

**Used in:** `infra/intercore/test-integration.sh`

JSON validation test key. Not used in production hooks.

```bash
printf '%s\n' 'not json' | ic state set bad test-session --db="$TEST_DB" 2>/dev/null
```

---

## Keys in Research/Planning Docs Only (Not Yet Implemented)

These appear in `docs/research/`, `docs/plans/`, or `docs/prds/` — they represent intended or aspirational usage, not live code.

| Key | Source document | Intended use |
|-----|----------------|--------------|
| `sprint_link` | `docs/research/review-plan-correctness.md:535`, `docs/research/review-plan-architecture.md:267` | Link sprint ID to run (but explicitly REMOVED — see lib-sprint.sh:121: "No redundant sprint_link ic state write needed (YAGNI — removed per arch review)") |
| `bead_phase` | `infra/intercore/docs/brainstorms/` | Bead phase tracking (brainstorm-era concept) |
| `dispatch` (production) | `docs/research/correctness-review-of-prd.md`, `infra/intercore/docs/research/` | Session dispatch state migration from `/tmp/clavain-dispatch-*.json` |
| `discovery_cache` | `infra/intercore/docs/research/` | Discovery cache (variant name for `discovery_brief`) |
| `intercheck.count` | `infra/intercore/docs/product/intercore-vision.md:570` | Session check accumulator (vision doc only) |
| `checkpoint` (plan variant) | `docs/plans/2026-02-19-intercore-e3-hook-cutover.md:907` | Hook cutover plan — matches current live usage |

---

## Key Names (Authoritative List)

**Currently in use in live shell code:**

1. `checkpoint` — sprint checkpoint state (read/write in lib-sprint.sh)
2. `cursor` — event bus consumer cursor position (write in lib-intercore.sh via intercore_events_cursor_set)
3. `discovery_brief` — discovery cache invalidation (delete-only in lib-sprint.sh)

**In integration tests only (not production):**

4. `dispatch` — round-trip test and secret-rejection test
5. `ephemeral` — TTL test
6. `bad` — JSON validation test

**Explicitly removed / never implemented:**

7. `sprint_link` — removed per arch review (YAGNI)

---

## Source Files Searched

- `/root/projects/Interverse/hub/clavain/hooks/lib-sprint.sh` — checkpoint r/w, discovery_brief delete
- `/root/projects/Interverse/hub/clavain/hooks/lib-intercore.sh` — intercore_state_set wrapper def, cursor write
- `/root/projects/Interverse/infra/intercore/lib-intercore.sh` — upstream source of lib-intercore.sh
- `/root/projects/Interverse/infra/intercore/test-integration.sh` — integration tests (dispatch, ephemeral, bad)
- All other `.sh` files in `hub/clavain/hooks/` — no additional `ic state set` calls found
- All `.sh` files in `hub/clavain/scripts/` — no `ic state set` calls found
- Research and plan docs — used to identify aspirational keys vs live usage
