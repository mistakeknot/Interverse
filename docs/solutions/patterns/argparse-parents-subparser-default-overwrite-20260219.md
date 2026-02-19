---
module: intermem
date: 2026-02-19
problem_type: python_pattern
component: cli
symptoms:
  - "CLI flag value silently overwritten when placed before subcommand"
  - "--project-dir /path query uses cwd instead of /path"
  - "Flags only work when placed after the subcommand, not before"
root_cause: argparse_parents_default_overwrite
resolution_type: pattern
severity: medium
tags: [python, argparse, cli, subparsers, parents, defaults, suppress]
---

# argparse `parents=[shared]` Overwrites Flags Parsed by Main Parser

## Problem

When using `argparse` with subparsers that share common flags via `parents=[shared]`, placing a flag *before* the subcommand causes its value to be silently overwritten by the subparser's default.

```
intermem --project-dir /path query --topics
# Expected: project_dir=/path
# Actual:   project_dir=.  (cwd — the default)
```

The flag only works when placed *after* the subcommand:
```
intermem query --project-dir /path --topics  # works
```

## Root Cause

`argparse.parents` copies argument definitions (including defaults) into the child parser. When the main parser and subparsers both inherit from the same `parents=[shared]`:

1. Main parser parses `--project-dir /path` → sets `project_dir=/path`
2. Subparser `query` inherits its own copy of `--project-dir` with `default=Path.cwd()`
3. Since the user didn't specify `--project-dir` *after* `query`, the subparser applies its default
4. Default overwrites the value from step 1

## Wrong Pattern

```python
# Shared parent with real defaults
shared = argparse.ArgumentParser(add_help=False)
shared.add_argument("--project-dir", type=Path, default=Path.cwd())
shared.add_argument("--json", action="store_true")

# Main parser inherits shared — correct
parser = argparse.ArgumentParser(parents=[shared])

# Subparsers ALSO inherit shared — this is the bug
subparsers = parser.add_subparsers(dest="command")
subparsers.add_parser("query", parents=[shared])  # BUG: re-defaults --project-dir
```

## Correct Pattern

Use `argparse.SUPPRESS` as the default on subparser copies. SUPPRESS means "don't set this attribute at all if the flag isn't explicitly provided," so the main parser's value is preserved.

```python
# Main parser: real defaults
parser = argparse.ArgumentParser()
parser.add_argument("--project-dir", type=Path, default=Path.cwd())
parser.add_argument("--json", action="store_true", default=False)

# Subparser parent: same flags, SUPPRESS defaults
sub_shared = argparse.ArgumentParser(add_help=False)
sub_shared.add_argument("--project-dir", type=Path, default=argparse.SUPPRESS)
sub_shared.add_argument("--json", action="store_true", default=argparse.SUPPRESS)

subparsers = parser.add_subparsers(dest="command")
subparsers.add_parser("query", parents=[sub_shared])
```

Now both positions work:
- `cmd --project-dir /path query` → main parser sets it, subparser doesn't overwrite
- `cmd query --project-dir /path` → subparser explicitly sets it

## Alternative: Remove Parents Entirely

If you don't need flags after the subcommand, just remove `parents=[shared]` from subparsers. The main parser's namespace is shared, so its flags are always available.

```python
subparsers.add_parser("query")  # no parents — inherits nothing
# cmd --project-dir /path query  → works
# cmd query --project-dir /path  → error: unrecognized arguments
```

This is simpler but breaks backward compatibility if users expect flags in either position.

## Key Lesson

Never use the same `parents=[shared]` on both the main parser and its subparsers. The subparser's copied defaults will overwrite values already parsed by the main parser. Use a separate parent with `default=argparse.SUPPRESS` for subparsers.

## Cross-References

- `plugins/intermem/intermem/__main__.py` — the fixed CLI entry point
- Bead: iv-gbgj
