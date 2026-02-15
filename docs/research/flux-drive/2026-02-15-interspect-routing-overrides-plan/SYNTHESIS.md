# Flux-Drive Review Synthesis: Interspect Routing Overrides Plan

**Document:** `docs/plans/2026-02-15-interspect-routing-overrides.md`
**Review Date:** 2026-02-15
**Agents:** fd-architecture, fd-correctness, fd-safety, fd-user-product, fd-quality

---

## Verdict: needs-changes

All 5 agents returned **needs-changes**. The plan's architecture is sound (file-based producer-consumer contract, flock serialization, canary monitoring), but it has critical correctness and security defects that would cause data corruption or injection vulnerabilities in production.

---

## Critical Findings (Must Fix Before Implementation)

### 1. Flock scope bug — DB writes outside critical section (P0)
**Flagged by:** fd-correctness (RACE-01), fd-architecture (ARCH-08)

The DB inserts (modification record, canary record) run AFTER the flock block exits. This means:
- Two concurrent sessions can both commit overrides for the same agent
- Orphaned DB records reference non-existent commits
- Canary monitoring fails because group_id doesn't match actual file contents

**Fix:** Move DB inserts inside the flock block, after `git commit` but before releasing the lock. Pass DB path and variables into the subprocess.

### 2. Incomplete rollback — git restore doesn't unstage (P0)
**Flagged by:** fd-correctness (DATA-01), fd-quality (Q-005), fd-safety (OPS-03)

On commit failure, `git restore` only restores the working tree, not the index. The override remains staged. User's next unrelated commit accidentally includes the failed override.

**Fix:** Use `git reset HEAD -- "$FILEPATH"` to unstage, THEN `git restore` to clean the working tree.

### 3. Shell injection via unescaped reason parameter (P1)
**Flagged by:** fd-safety (SEC-01), fd-architecture (ARCH-04), fd-correctness (SHELL-01)

The `$reason` variable (user-provided via AskUserQuestion or CLI args) is interpolated into a `bash -c` subprocess via triple-nested quote escaping. An attacker-controlled reason can execute arbitrary shell commands.

**Fix:** Pass variables via `env` (not inline string substitution), or write the commit message to a temp file and reference via `git commit -F`.

### 4. SQL injection — inconsistent escaping across functions (P1)
**Flagged by:** fd-safety (SEC-02, SEC-03), fd-architecture (ARCH-02), fd-quality (Q-002)

Task 1 (`_interspect_is_routing_eligible`) escapes single quotes, but Tasks 3 and 5 do NOT escape at all. Agent name is user-provided and directly interpolated into SQL.

**Fix:** Create `_interspect_sql_escape()` helper and apply to ALL SQL queries. Or use sqlite3 `.param` parameterized queries. Add input validation: agent names must match `^[a-zA-Z0-9_-]+$`.

---

## High-Priority Findings (Should Fix Before Implementation)

### 5. Agent roster validation — wrong paths, tight coupling (P1)
**Flagged by:** fd-architecture (ARCH-01), fd-correctness (DATA-04), fd-safety (OPS-01), fd-quality (Q-011)

All 4 technical agents flagged the agent roster validation. Issues:
- Hardcoded marketplace path doesn't match actual Claude Code cache layout
- Misses git-dev installations and project-specific agents
- Creates tight coupling between clavain and interflux directory structures
- Runs outside flock (TOCTOU race)

**Fix:** Remove agent validation entirely from interspect. Flux-drive already handles unknown agents gracefully at triage time. If validation is needed, validate only the format (`^fd-[a-z-]+$`) and let flux-drive enforce roster membership.

### 6. Read-without-lock races (P1)
**Flagged by:** fd-correctness (RACE-02), fd-architecture (ARCH-05)

`_interspect_read_routing_overrides()` reads without acquiring the flock. This causes stale proposals (user sees already-applied overrides) and inconsistent status displays.

**Fix (conservative):** Wrap reads in shared flock (`flock -s`). **Fix (optimistic):** Accept the race, add re-check after user accepts but before entering flock. Show "Override was applied by another session, skipping."

### 7. Duplicate DB records on metadata update (P1)
**Flagged by:** fd-correctness (DATA-02)

When an existing override is updated (metadata change), the plan still creates NEW modification and canary records. Results in duplicate monitoring records and confusing modification history.

**Fix:** Track `IS_NEW` flag during merge. Only insert DB records for genuinely new overrides.

### 8. No discovery path — users can't find the feature (P1)
**Flagged by:** fd-user-product (UX1, PROD2)

Users encounter noisy agents during flux-drive reviews but have no way to discover that interspect can fix this. The plan assumes users already know about `/interspect:correction` and `/interspect:propose`.

**Fix:** Add a discovery nudge in flux-drive: after 3+ overrides of the same agent in one session, show "Tip: Run `/interspect:correction` to record patterns." Also: when `/interspect:propose` finds no evidence, explain what evidence is and how to collect it.

### 9. Sequential proposal flow blocks batch decisions (P1)
**Flagged by:** fd-user-product (UX2)

Proposals are presented one at a time via AskUserQuestion. Users can't compare proposals or batch-accept/decline.

**Fix:** Detect all eligible patterns first, show summary table, use multi-select AskUserQuestion with "Accept all" / "Decline all" options.

---

## Medium-Priority Findings (Fix During Implementation)

### 10. Path traversal via env var (P2)
**Flagged by:** fd-architecture (ARCH-03), fd-correctness (Improvement 6), fd-quality (Q-007 ENV)

`FLUX_ROUTING_OVERRIDES_PATH` is not validated. Absolute paths or `../` traversal could read/write outside the repo.

**Fix:** Reject absolute paths and `..` components.

### 11. Git commit blocking inside flock (P2)
**Flagged by:** fd-safety (OPS-02)

If pre-commit hooks hang, the flock is held indefinitely, starving other sessions.

**Fix:** Use `git commit --no-verify` for interspect commits (simple JSON edits don't need linting). Or add flock timeout with retry.

### 12. Error messages assume domain knowledge (P2)
**Flagged by:** fd-user-product (UX4)

"routing-overrides.json malformed" tells users what's wrong but not what to do. Missing: path to file, suggested action, impact severity.

**Fix:** Include absolute path, suggested action ("Run `/interspect:revert` or check syntax"), and impact ("All agents will run this session").

### 13. Canary window too slow (20 sessions) (P2)
**Flagged by:** fd-user-product (PROD1)

20 sessions = 2-4 weeks. Users want faster feedback.

**Fix:** Reduce to 5 sessions or 7 days. Add fast-feedback prompt after 3 sessions.

### 14. Test portability — hardcoded paths (P2)
**Flagged by:** fd-correctness (SHELL-02), fd-safety (OPS-04), fd-quality (Q-007)

Tests hardcode `/root/projects/Interverse/`. Breaks in CI or other environments.

**Fix:** Use dynamic discovery via `git rev-parse --show-toplevel` or relative paths from test file location.

### 15. Revert creates permanent blacklist without warning (P2)
**Flagged by:** fd-user-product (UX7)

`/interspect:revert` silently blacklists the pattern. Users expect "undo" but get "undo + never propose again."

**Fix:** Offer two options: "Remove exclusion and allow future proposals" vs "Remove and blacklist permanently."

### 16. Missing export for config variable (P2)
**Flagged by:** fd-quality (Q-001)

`_INTERSPECT_MIN_AGENT_WRONG_PCT` is set but could be empty in subshells. Add validation guard.

### 17. Non-atomic file writes (P2)
**Flagged by:** fd-correctness (Improvement 1)

Direct writes to routing-overrides.json can corrupt on crash. Use temp file + rename pattern.

---

## Low-Priority Findings (P3 — Can Defer)

| # | Finding | Agents |
|---|---------|--------|
| 18 | /interspect and /interspect:propose overlap (ARCH-07) | fd-architecture |
| 19 | Malformed JSON moves file, destroying evidence (SEC-04) | fd-safety |
| 20 | Missing AskUserQuestion dismissal handling (Q-004) | fd-quality |
| 21 | Incomplete canary query in status display (Q-006) | fd-quality |
| 22 | Integer truncation in percentage calc untested (Q-008) | fd-quality |
| 23 | Documentation placement contradicts scope (Q-009) | fd-quality |
| 24 | Inconsistent command descriptions (Q-010) | fd-quality |
| 25 | Missing retry mechanism for transient failures (Q-012) | fd-quality |

---

## Cross-Agent Improvement Suggestions

### Highly recommended
1. **Centralize SQL escaping** — `_interspect_sql_escape()` helper (4 agents flagged this)
2. **Remove agent roster validation** — delegate to flux-drive (4 agents flagged this)
3. **Refactor apply function** — replace fragile heredoc with named function taking positional args (3 agents)
4. **Add integration tests** for producer-consumer contract (2 agents)
5. **Add discovery nudge** in flux-drive when same agent is overridden repeatedly (1 agent, high impact)

### Nice to have
6. Schema validation for routing-overrides.json (fd-architecture, fd-quality)
7. Audit log for override lifecycle events (fd-quality)
8. Dry-run mode for `/interspect:propose` (fd-quality)
9. Configurable canary window in confidence.json (fd-quality, fd-user-product)
10. Token savings display in `/interspect:status` (fd-user-product)

---

## Finding Overlap Matrix

Shows which findings were independently identified by multiple agents:

| Theme | ARCH | CORR | SAFE | UX/PROD | QUAL | Count |
|-------|------|------|------|---------|------|-------|
| SQL injection / escaping | ARCH-02 | — | SEC-02, SEC-03 | — | Q-002 | 4 |
| Agent roster validation | ARCH-01 | DATA-04 | OPS-01 | — | Q-011 | 4 |
| Shell injection / quoting | ARCH-04 | SHELL-01 | SEC-01 | — | — | 3 |
| Flock scope / DB atomicity | ARCH-08 | RACE-01 | — | — | — | 2 |
| Rollback incompleteness | — | DATA-01 | OPS-03 | — | Q-005 | 3 |
| Test portability | — | SHELL-02 | OPS-04 | — | Q-007 | 3 |
| Read-without-lock race | ARCH-05 | RACE-02 | — | — | — | 2 |
| Path traversal | ARCH-03 | — | — | — | — | 1 |

**Key insight:** SQL injection and agent roster validation were the most widely-detected issues (4/5 agents each). These represent systemic patterns, not isolated bugs.

---

## Recommended Fix Order

Based on severity, overlap count, and dependency:

1. **Shell injection fix** (finding 3) — blocks all other work in apply function
2. **SQL injection fix** (finding 4) — blocks all DB-touching code
3. **Flock scope fix** (finding 1) — restructures apply function
4. **Rollback fix** (finding 2) — included in flock restructure
5. **Remove agent validation** (finding 5) — simplifies apply function
6. **Duplicate DB records** (finding 7) — clean up inside flock
7. **Discovery path** (finding 8) — UX addition, no dependencies
8. **Batch proposals** (finding 9) — UX change, independent
9. **Path validation** (finding 10) — quick defensive fix
10. **Read locking** (finding 6) — independent, lower urgency

Fixes 1-6 are interconnected (all modify the apply function or its callers). Recommended to tackle as a single refactoring pass.

---

## Summary Statistics

| Priority | Count | Verdict |
|----------|-------|---------|
| P0 (must fix) | 2 | Block implementation |
| P1 (should fix) | 7 | Fix before implementation |
| P2 (medium) | 8 | Fix during implementation |
| P3 (low) | 8 | Can defer |
| **Total unique findings** | **25** | |
| Improvements suggested | 10 | Optional |
