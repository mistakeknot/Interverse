# Plan: Intersynth Codex Dispatch via dispatch.sh
**Bead:** iv-dnml
**Phase:** planned

## Overview

Replace `Task(intersynth:*)` Claude Code subagent calls with Codex dispatch via `dispatch.sh`. Synthesis runs in a completely separate Codex process — zero tokens enter the host context. Intermux auto-detects the Codex session for real-time visibility.

**Token savings stack:**
| Layer | Host context cost |
|-------|------------------|
| Before intersynth (raw) | ~30-40K tokens |
| With intersynth (Task subagent) | ~500 tokens |
| With intersynth (Codex dispatch) | ~100 tokens (verdict sidecar) |

## Prerequisites

- intersynth plugin exists with `synthesize-review.md` and `synthesize-research.md` agents (done: iv-24qk)
- `dispatch.sh` exists in clavain with `--prompt-file`, `-o`, `.verdict` sidecar extraction (done)
- intermux watches tmux for "codex" sessions automatically (done — no changes needed)
- Codex CLI installed and configured (`~/.codex/config.toml`)

## Tasks

### Task 1: Convert intersynth agent files to Codex prompt templates
**Files:**
- `plugins/intersynth/agents/synthesize-review.md`
- `plugins/intersynth/agents/synthesize-research.md`

**Changes:**
1. These files currently serve as Claude Code subagent definitions (frontmatter with `name:`, `description:`, model hints). Convert them to **dual-purpose** files that work as both:
   - Claude Code agent definitions (fallback when Codex unavailable)
   - Codex prompt templates (primary path)
2. Add a `## Output Contract` section to each that specifies:
   - Write all output to `{OUTPUT_DIR}/synthesis.md` (review) or `{OUTPUT_DIR}/synthesis.md` (research)
   - Write verdict files via `lib-verdict.sh` (source from `{VERDICT_LIB}`)
   - Last block of stdout must be the verdict suffix for `.verdict` sidecar extraction:
     ```
     --- VERDICT ---
     STATUS: pass|warn|error
     FILES: N changed
     FINDINGS: N (P0: X, P1: Y, P2: Z)
     SUMMARY: one-line result
     ---
     ```
3. Add `## Codex Execution Notes` section:
   - `sandbox: workspace-write` (needs to write verdict files, synthesis.md, findings.json)
   - `tier: fast` (synthesis is mechanical dedup + categorization, not deep reasoning)
   - Files the agent needs to read: `{OUTPUT_DIR}/*.md` (agent outputs)
   - Files the agent writes: `{OUTPUT_DIR}/synthesis.md`, `{OUTPUT_DIR}/findings.json`, `.clavain/verdicts/*.json`

**Dependencies:** None
**Risk:** Low — additive changes, existing Claude Code agent interface preserved as fallback

### Task 2: Create dispatch helper in intersynth
**File:** `plugins/intersynth/scripts/dispatch-synthesis.sh`

**Purpose:** Thin wrapper that resolves `dispatch.sh`, writes the prompt file from template + variables, calls dispatch, and returns the verdict.

**Interface:**
```bash
bash dispatch-synthesis.sh \
  --mode review|research \
  --output-dir /path/to/output \
  --verdict-lib /path/to/lib-verdict.sh \
  --context "PR #123 — Fix auth bug" \
  --project-dir /path/to/project \
  [--research-question "..."] \
  [--query-type "..."] \
  [--estimated-depth "..."] \
  [--protected-paths "..."]
```

**Implementation:**
1. Resolve dispatch.sh (same pattern as interserve skill Step 0)
2. Select prompt template: `synthesize-review.md` or `synthesize-research.md`
3. Write assembled prompt to `/tmp/intersynth-task-{ts}.md`:
   - Paste the agent markdown (stripped of YAML frontmatter)
   - Substitute variables: `{OUTPUT_DIR}`, `{VERDICT_LIB}`, `{CONTEXT}`, etc.
4. Call dispatch.sh:
   ```bash
   CLAVAIN_DISPATCH_PROFILE=interserve bash "$DISPATCH" \
     --prompt-file "$PROMPT_FILE" \
     -C "$PROJECT_DIR" \
     --name "intersynth-${MODE}" \
     -o "/tmp/intersynth-result-${TS}.md" \
     -s workspace-write \
     --tier fast
   ```
5. Check exit code and `.verdict` sidecar
6. Output the verdict file path to stdout

**Dependencies:** Task 1
**Risk:** Low — dispatch.sh is battle-tested

### Task 3: Update quality-gates.md to use Codex dispatch
**File:** `hub/clavain/commands/quality-gates.md`

**Changes:**
Replace the current Task-based synthesis:
```
Task(intersynth:synthesize-review):
  prompt: |
    OUTPUT_DIR={OUTPUT_DIR}
    ...
```

With Codex dispatch:
```bash
# Dispatch synthesis to Codex agent
bash "${INTERSYNTH_DIR}/scripts/dispatch-synthesis.sh" \
  --mode review \
  --output-dir "$OUTPUT_DIR" \
  --verdict-lib "${CLAUDE_PLUGIN_ROOT}/hooks/lib-verdict.sh" \
  --context "{X files changed across Y languages}" \
  --project-dir "$PROJECT_ROOT"
```

After dispatch:
1. Read `.verdict` sidecar for gate decision (7 lines)
2. Read `{OUTPUT_DIR}/synthesis.md` for user report
3. Never touch individual agent output files

Add fallback: if `codex` CLI not available, fall back to `Task(intersynth:synthesize-review)`.

**Dependencies:** Task 2
**Risk:** Low

### Task 4: Update review.md to use Codex dispatch
**File:** `hub/clavain/commands/review.md`

**Changes:** Same pattern as Task 3, with `--context "PR #{pr_number} — {title}"` and `--protected-paths "docs/plans/*.md, docs/solutions/*.md"`.

**Dependencies:** Task 2
**Risk:** Low

### Task 5: Update flux-drive synthesize.md to use Codex dispatch
**File:** `plugins/interflux/skills/flux-drive/phases/synthesize.md`

**Changes:** Same pattern as Task 3, with `--mode review` and `--context "Reviewing {INPUT_TYPE}: {INPUT_STEM} ({N} agents, {early_stop_note})"`.

**Dependencies:** Task 2
**Risk:** Low

### Task 6: Update flux-research SKILL.md to use Codex dispatch
**File:** `plugins/interflux/skills/flux-research/SKILL.md`

**Changes:** Use `--mode research` with research-specific flags:
```bash
bash "${INTERSYNTH_DIR}/scripts/dispatch-synthesis.sh" \
  --mode research \
  --output-dir "$OUTPUT_DIR" \
  --verdict-lib "${VERDICT_LIB}" \
  --project-dir "$PROJECT_ROOT" \
  --research-question "$RESEARCH_QUESTION" \
  --query-type "$type" \
  --estimated-depth "$estimated_depth"
```

**Dependencies:** Task 2
**Risk:** Low

### Task 7: Add Codex fallback detection
**File:** All 4 caller files (Tasks 3-6)

**Changes:** Add a prerequisite check at the top of each synthesis section:
```bash
# Check Codex availability
if command -v codex &>/dev/null; then
  SYNTH_MODE="codex"
else
  SYNTH_MODE="task"
fi
```

When `SYNTH_MODE=task`, use the existing `Task(intersynth:*)` calls as fallback. This ensures synthesis works even without Codex installed.

**Dependencies:** Tasks 3-6
**Risk:** None — pure guard clause

## Execution Order

```
Task 1 (prompt templates) → Task 2 (dispatch helper) → Tasks 3-6 (callers, parallel) → Task 7 (fallback)
```

Tasks 3-6 are independent and can run in parallel after Task 2.

## Intermux Visibility (Zero Changes Needed)

Intermux's tmux watcher scans every 10 seconds for sessions matching "codex" in name. When `dispatch.sh` runs `codex exec`, the Codex process inherits the tmux environment. Intermux auto-detects it and exposes:
- `list_agents` — shows the synthesis Codex session
- `peek_agent` — real-time pane content (what the synthesis agent is doing)
- `activity_feed` — chronological events
- `agent_health` — stuck/crashed detection

The `--name intersynth-{mode}` flag in dispatch.sh writes state to `/tmp/clavain-dispatch-$$.json` for statusline visibility.

**No changes to intermux required.**

## Verification

1. Run `/clavain:quality-gates` on a real diff — verify `codex exec` is dispatched, `.verdict` sidecar is created, host never reads agent output files
2. Run `intermux list_agents` during synthesis — verify the Codex session appears
3. Run `/interflux:flux-drive` on a plan file — verify synthesis.md is written by Codex
4. Remove `codex` from PATH temporarily — verify fallback to Task-based synthesis works
5. Check host context consumption before/after — should be ~100 tokens for verdict vs ~500 for Task return

## Testing

These are skill/command files (markdown instructions). Verification is by running the commands in a session. The dispatch helper script (`dispatch-synthesis.sh`) can be syntax-checked with `bash -n`.
