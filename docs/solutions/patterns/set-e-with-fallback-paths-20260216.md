---
module: interstat
date: 2026-02-16
problem_type: shell_pattern
component: hooks
symptoms:
  - "Hook script exits before reaching fallback logic"
  - "set -e kills script at sqlite3 failure, skipping JSONL fallback"
root_cause: set_e_interaction
resolution_type: pattern
severity: medium
tags: [bash, set-e, error-handling, hooks, fallback, shell]
---

# `set -euo pipefail` with Fallback Recovery Paths

## Problem

A Claude Code hook (`post-task.sh`) needs to INSERT into SQLite, but if the DB is locked or unavailable, it must fall back to appending to a JSONL file. The quality review flagged `set -u` as too loose — the script should use `set -euo pipefail` for strictness.

But adding `set -e` causes the script to exit immediately when `sqlite3` returns non-zero, skipping the fallback logic entirely.

## Wrong Pattern

```bash
set -euo pipefail

sqlite3 "$DB" "INSERT ..." >/dev/null 2>&1
insert_status=$?  # NEVER REACHED — set -e already exited

if [ "$insert_status" -ne 0 ]; then
  # fallback to JSONL — NEVER REACHED
fi
```

## Correct Pattern

```bash
set -euo pipefail

insert_status=0
sqlite3 "$DB" "INSERT ..." >/dev/null 2>&1 || insert_status=$?

if [ "$insert_status" -ne 0 ]; then
  # fallback to JSONL — works correctly
fi
```

The `|| insert_status=$?` captures the exit code while satisfying `set -e` — the compound command as a whole succeeds (the `||` branch always returns 0 from the assignment).

## Alternative: Subshell Isolation

For more complex fallback logic, isolate the risky command in a subshell:

```bash
set -euo pipefail

if ! (sqlite3 "$DB" "INSERT ..." >/dev/null 2>&1); then
  # fallback path
fi
```

## Key Lesson

When using `set -euo pipefail` with commands that must be allowed to fail (for fallback logic), always use `|| variable=$?` or `if !` to prevent premature exit. Initialize the status variable before the command so the fallback condition works even if the command never runs.

## Cross-References

- `plugins/interstat/hooks/post-task.sh` — the hook that uses this pattern
- Quality review: `plugins/interstat/docs/research/quality-review-of-interstat-code.md`
