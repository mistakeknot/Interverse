# Plan: Fix argparse parents=[shared] overwriting --project-dir

**Bead:** iv-gbgj
**Phase:** executing (as of 2026-02-19T01:20:47Z)
**Date:** 2026-02-18
**Working dir:** `plugins/intermem/`

---

## Problem

When running `intermem --project-dir /path query --topics`, the `query` subparser inherits `parents=[shared]` which re-adds `--project-dir` with `default=Path.cwd()`. The subparser's default silently overwrites the value parsed by the main parser. The flag only works when placed AFTER the subcommand.

## Root Cause

Lines 65, 67 in `__main__.py`:
```python
subparsers.add_parser("sweep", parents=[shared], ...)
subparsers.add_parser("query", parents=[shared], ...)
```

`argparse.parents` copies all argument definitions including defaults. The subparser re-defaults `--project-dir` to `Path.cwd()`, overwriting whatever the main parser parsed.

## Fix

**Remove `parents=[shared]` from subparsers.** The subparsers don't need their own copies of `--project-dir`, `--project-root`, or `--json` — these are already on the main parser and will be available in the parsed namespace regardless of subcommand.

### Changes

**File:** `intermem/__main__.py`

1. Remove `parents=[shared]` from both `add_parser()` calls:
   - `subparsers.add_parser("sweep", help=...)` — no parents
   - `subparsers.add_parser("query", help=...)` — no parents

2. No other changes needed. The shared args (`--project-dir`, `--project-root`, `--json`) are on the main parser and flow through to all subcommands automatically.

### Verification

```bash
cd plugins/intermem
# Before fix: project_dir gets overwritten
uv run python -m intermem --project-dir /tmp query --topics 2>&1
# After fix: project_dir=/tmp is preserved
uv run python -m intermem --project-dir /tmp query --topics 2>&1
# Backward compat: subcommand-last still works
uv run python -m intermem query --topics --project-dir /tmp 2>&1
# No subcommand still works
uv run python -m intermem --project-dir /tmp --dry-run 2>&1
```

## Risk

**Minimal.** Removing parents is purely subtractive — we're removing duplicate argument definitions. The args already exist on the main parser. No behavior changes for any existing valid invocation.
