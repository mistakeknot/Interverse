# Shell & Tooling Patterns Guide

Consolidated reference for bash hooks, jq pipelines, and beads commands. Read this before writing shell hooks or using bd.

## `set -euo pipefail` with Fallback Paths

When using strict mode with commands that must be allowed to fail (for fallback logic), use `|| variable=$?` to prevent premature exit.

**WRONG** (set -e exits before fallback):
```bash
set -euo pipefail

sqlite3 "$DB" "INSERT ..." >/dev/null 2>&1
insert_status=$?  # NEVER REACHED — set -e already exited

if [ "$insert_status" -ne 0 ]; then
  # fallback — NEVER REACHED
fi
```

**CORRECT** (captures exit code):
```bash
set -euo pipefail

insert_status=0
sqlite3 "$DB" "INSERT ..." >/dev/null 2>&1 || insert_status=$?

if [ "$insert_status" -ne 0 ]; then
  # fallback — works correctly
fi
```

The `|| insert_status=$?` captures the exit code while satisfying `set -e` — the compound command as a whole succeeds.

**Key rule:** Initialize the status variable BEFORE the command: `status=0; cmd || status=$?`

**Alternative — subshell isolation:**
```bash
if ! (sqlite3 "$DB" "INSERT ..." >/dev/null 2>&1); then
  # fallback path
fi
```

## jq Null Safety

`null[:10]` is a runtime error (exit 5), NOT null. The `//` alternative operator never fires because jq aborts before evaluating it.

**WRONG** (crashes with exit 5):
```bash
echo "$checkpoint" | jq '.completed_steps[:5]'
# If .completed_steps is null → runtime error, not []
```

**CORRECT** (guard before slicing):
```bash
echo "$checkpoint" | jq '(.completed_steps // [])[:5]'
```

**Important:** The `//` must wrap the field access, not the slice:
- `(.field // [])[:5]` — correct, converts null to [] before slicing
- `.field[:5] // []` — wrong, crashes before `//` evaluates

**Shell functions returning JSON:**
```bash
# WRONG — empty string becomes null in jq
read_data() { [[ -f "$FILE" ]] && cat "$FILE" || echo ""; }

# CORRECT — return valid JSON
read_data() { [[ -f "$FILE" ]] && cat "$FILE" || echo "{}"; }
```

**Detection:** Search for `|| echo ""` in functions that return JSON — each one is a potential null-slice bug:
```bash
grep -rn '|| echo ""' hooks/lib-*.sh | grep -v '#'
```

## Beads Sync Modes

`bd sync --from-main` is for ephemeral branches only. For trunk-based development (our workflow), use plain `bd sync`.

| Command | Use Case | What It Does |
|---------|----------|-------------|
| `bd sync` | Trunk-based (main branch) | Export DB → JSONL |
| `bd sync --import` | After `git pull` | Import JSONL → DB |
| `bd sync --from-main` | Ephemeral branches only | Pull beads from main branch |
| `bd sync --full` | Legacy full sync | Pull → merge → export → commit → push |

**Common mistake:** `bd sync --from-main` fails with "no git remote configured" on main — this is correct behavior, not a bug. Use `bd sync` instead.

## Hook Input/Output Contract

Hooks receive JSON on stdin, not environment variables:
```bash
# Read hook input
INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id')
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
```

Hooks must output valid JSON to stdout. Use `set -euo pipefail` in all hook scripts.

## awk `sub()` $0 Mutation

In awk, `sub()`/`gsub()` modify `$0` in-place. All subsequent pattern rules in the same program evaluate against the modified `$0`. Always add `next` after a rule that modifies `$0` if later rules check `$0` patterns.

```awk
# WRONG — Rule 2 fires on the same line because sub() changed $0
found && /^  - / { sub(/^  - */, ""); items = items "," $0 }
found && !/^  - / { exit }  # Fires immediately — modified $0 no longer matches ^  -

# RIGHT — next prevents Rule 2 from seeing the modified line
found && /^  - / { sub(/^  - */, ""); items = items "," $0; next }
found && !/^  - / { exit }
```

## Beads Daemon Stale Startlock

If `bd` commands hang, the daemon startlock is stale. One-liner fix:

```bash
kill $(cat .beads/daemon.pid 2>/dev/null) 2>/dev/null; rm -f .beads/bd.sock .beads/bd.sock.startlock .beads/daemon.pid .beads/daemon.lock
```

Common after force-killed sessions or network disconnects.

## Detailed Solution Docs

- `docs/solutions/patterns/set-e-with-fallback-paths-20260216.md`
- `docs/solutions/runtime-errors/jq-null-slice-from-empty-string-return-clavain-20260216.md`
- `docs/solutions/workflow-issues/bd-sync-from-main-trunk-based-20260216.md`
- `interverse/interlearn/docs/solutions/patterns/awk-sub-pattern-fallthrough-20260221.md`
- `interverse/tldr-swinton/docs/solutions/workflow-issues/bd-commands-hang-stale-startlock-20260213.md`
