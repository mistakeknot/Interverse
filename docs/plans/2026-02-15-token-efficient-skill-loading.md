# Token-Efficient Skill Loading — Implementation Plan

**Bead:** Clavain-1lri
**PRD:** [`docs/prds/2026-02-15-token-efficient-skill-loading.md`](../prds/2026-02-15-token-efficient-skill-loading.md)
**Date:** 2026-02-15
**Phase:** plan-reviewed (v2 — addresses fd-architecture P0 + fd-quality P1 findings)

---

## Task 1: Build interwatch-scan.py (pre-computation script)

**Plugin:** interwatch
**Files:** `plugins/interwatch/scripts/interwatch-scan.py`

Write a Python script (matching `gen-catalog.py` precedent) that:
1. Reads `config/watchables.yaml` (or project's `.interwatch/watchables.yaml` if present) using PyYAML
2. For each watchable, evaluates all configured signals using subprocess calls:
   - `bead_closed`: `bd list --status=closed` count since doc mtime
   - `bead_created`: `bd list --status=open` count delta
   - `version_bump`: compare `plugin.json` version vs doc header
   - `component_count_changed`: compare actual component counts vs doc claims
   - `file_renamed`/`file_deleted`/`file_created`: `git diff --name-status` since doc mtime
   - `commits_since_update`: `git rev-list --count` since doc mtime
   - `brainstorm_created`: count brainstorm files newer than doc
   - `companion_extracted`: check plugin cache vs doc mentions
3. Computes drift score (sum of weight * count per signal)
4. Maps to confidence tier (Green <3, Low 3-5, Medium 6-8, High 9-12, Certain 13+)
5. Outputs JSON to stdout (format per PRD section 6)

**Why Python over shell:** YAML parsing in bash is an anti-pattern (fd-quality P1-2). Python handles YAML natively, and `gen-catalog.py` establishes the precedent for Python-based pre-computation in this ecosystem.

**Dependencies:** Python 3, PyYAML, bd CLI, git
**Tests:** Add `tests/test_interwatch_scan.bats` with mock watchables and signal sources (invokes the Python script)

## Task 2: Generate compact SKILL.md for interwatch/doc-watch

**Plugin:** interwatch
**Files:** `plugins/interwatch/skills/doc-watch/SKILL-compact.md`

Use LLM to summarize the 7-file skill (SKILL.md + 3 phases + 3 references = 364 lines) into a single ~60-80 line file that contains:
- The algorithm: load watchables → run `interwatch-scan.sh` → read JSON → apply action matrix
- The action matrix table (5 confidence tiers → actions)
- Generator invocation format
- State update instructions (write `.interwatch/drift.json`)

**Key change:** Instead of "read phases/detect.md to learn signal evaluation", the compact version says "run `scripts/interwatch-scan.sh` and read the JSON output."

Update SKILL.md with a compact-mode preamble: `<!-- compact: SKILL-compact.md -->`

## Task 3: Generate compact SKILL.md for interpath/artifact-gen

**Plugin:** interpath
**Files:** `plugins/interpath/skills/artifact-gen/SKILL-compact.md`

Summarize the discover phase + 5 artifact-type phases into ~60-80 lines:
- Discovery checklist (what to gather, in parallel)
- Per-artifact-type output structure (one paragraph each)
- Writing guidelines
- Output location convention

Update SKILL.md with compact-mode preamble.

## Task 4: Generate compact SKILL.md for interflux/flux-drive

**Plugin:** interflux
**Files:** `plugins/interflux/skills/flux-drive/SKILL-compact.md`

This is the hardest one — 1,954 lines across 9 files. The compact version (~150-200 lines) needs:
- Triage algorithm (steps 1-1.4)
- Domain detection (step 1.0) with cache key convention
- Agent roster reference (7 review + 5 research agents, one line each)
- Launch protocol (stage 1 vs stage 2 expansion)
- Synthesis contract (output format, verdict rules)
- Scoring formula (compact version of the full algorithm)

**Note:** flux-drive has genuine algorithmic complexity. The compact version must preserve the scoring algorithm and launch protocol exactly — these aren't "nice to have" descriptions, they're the algorithm itself.

Update SKILL.md with compact-mode preamble.

## Task 5: Build gen-skill-compact.sh (LLM-powered generator)

**Location:** `scripts/gen-skill-compact.sh`

Script that:
1. Takes a skill directory path as argument
2. Reads SKILL.md + all files in phases/ and references/
3. Calls an LLM to summarize (backend-agnostic: supports `claude -p`, `DISPLAY=:99 oracle --wait`, or reading from stdin for CI)
4. Writes output to SKILL-compact.md in the same directory
5. Records source file hashes in a `.skill-compact-manifest.json` for freshness checking

**LLM backend abstraction (fd-architecture P0 fix):**
```bash
# Default: claude -p
# Override: GEN_COMPACT_CMD="oracle --wait -p" gen-skill-compact.sh <dir>
# CI/pipe: echo "$content" | GEN_COMPACT_CMD="cat" gen-skill-compact.sh <dir>
```
The script reads `$GEN_COMPACT_CMD` (default: `claude -p`) and pipes the concatenated skill content + prompt to it.

Prompt template:
```
Summarize this skill into a single compact instruction file (50-200 lines depending on complexity).
Keep: algorithm steps, decision points, output contracts, tables, code blocks.
Remove: examples, rationale, verbose descriptions, "why" explanations.
Add: "For edge cases or full reference, read SKILL.md" at the bottom.
```

**Freshness check:** `gen-skill-compact.sh --check` compares current source hashes against `.skill-compact-manifest.json` and reports which compact files need regeneration. Exit codes: 0 = all fresh, 1 = stale files found (prints which), 2 = manifest missing.

## Task 6: Wire compact loading into skill invocations

**Files:** Each plugin's SKILL.md files (3 plugins)

Add a compact-mode detection preamble to each SKILL.md:

```markdown
<!-- If SKILL-compact.md exists in this directory, load it instead of following the multi-file instructions below. The compact version contains the same algorithm in a single file. -->
```

This is a convention, not enforcement — the agent chooses to follow it. No code changes to Claude Code itself.

## Task 7: Add freshness tests

**Files:** `plugins/interwatch/tests/test_compact_freshness.bats` (or similar per-plugin)

For each plugin with a compact file:
- Verify SKILL-compact.md exists
- Verify `.skill-compact-manifest.json` exists and lists all source files
- Verify source file hashes match manifest (compact file is up to date)

This catches the drift risk: if someone edits a phase doc but forgets to regenerate the compact file.

## Execution Order

Tasks 1-4 are independent and can run in parallel.
Task 5 depends on having at least one compact file to test against.
Task 6 depends on compact files existing (Tasks 2-4).
Task 7 depends on Task 5 (needs manifest format).

```
[1: scan.py] ──────────────────────────────────┐
[2: compact interwatch] ───────────┐            │
[3: compact interpath]  ───────────┤            │
[4: compact interflux]  ───────────┤            │
                                   ├─[6: wire]──┤
                                   │            ├─[7: tests]
                                   └─[5: gen]───┘
```

Parallel batch 1: Tasks 1, 2, 3, 4
Sequential: Task 5, then Task 6, then Task 7
