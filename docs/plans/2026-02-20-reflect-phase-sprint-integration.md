# Reflect Phase Sprint Integration — Implementation Plan
**Phase:** executing (as of 2026-02-20T15:32:27Z)

> **For Claude:** REQUIRED SUB-SKILL: Use clavain:executing-plans to implement this plan task-by-task.

**Goal:** Wire the kernel's existing reflect phase into the Clavain OS sprint flow so reflection is gate-enforced, not skippable.

**Architecture:** The kernel already ships `PhaseReflect`, gate rules, and a 9-phase `DefaultPhaseChain`. This plan updates the OS layer (sprint command, reflect command, docs) to close the loop. No kernel code changes except fixing a stale comment.

**Tech Stack:** Bash (lib-sprint.sh, commands), Go (one comment fix), Markdown (docs)

---

## Sequencing

```
Task 1-2 (F2a: verify transitions) → Task 3-6 (F3: reflect command) → Task 7-10 (F1: sprint command) → Task 11-14 (F4+F5: docs)
```

F2a is a verification pass. F3 must ship before F1 because the sprint step invokes `/reflect`. F4 and F5 are docs-only.

---

### Task 1: Verify lib-sprint.sh Transition Table and Phase Whitelists (F2a)

**Files:**
- Verify: `hub/clavain/hooks/lib-sprint.sh:569-580` (transition table)
- Verify: `hub/clavain/hooks/lib-sprint.sh:593-605` (sprint_next_step)
- Verify: `hub/clavain/hooks/lib-sprint.sh:910-917` (sprint_phase_whitelist)
- Verify: `hub/clavain/hooks/lib-sprint.sh:78` (PHASES_JSON)
- Verify: `hub/clavain/hooks/lib-gates.sh:25` (CLAVAIN_PHASES fallback)

**Step 1: Verify transition table has shipping→reflect→done**

Read `hub/clavain/hooks/lib-sprint.sh` lines 569-580 and confirm:
- `shipping)  echo "reflect" ;;` exists
- `reflect)   echo "done" ;;` exists

Expected: Both transitions already present. If missing, add them.

**Step 2: Verify sprint_next_step maps reflect correctly**

Read lines 593-605 and confirm:
- `reflect) echo "reflect" ;;` exists (maps the `reflect` next-phase to the `reflect` command)

Expected: Already present.

**Step 3: Verify PHASES_JSON includes reflect**

Read line 78 and confirm the JSON array is:
```
["brainstorm","brainstorm-reviewed","strategized","planned","plan-reviewed","executing","shipping","reflect","done"]
```

Expected: Already present (9 phases).

**Step 4: Verify sprint_phase_whitelist includes reflect for all tiers**

Read lines 910-917 and confirm `reflect` appears in every complexity tier:
- C1: `planned executing shipping reflect done`
- C2: `planned plan-reviewed executing shipping reflect done`
- C3+: all phases including `reflect`

Expected: Already present.

**Step 5: Verify lib-gates.sh fallback includes reflect**

Read line 25 and confirm:
```bash
CLAVAIN_PHASES=(brainstorm brainstorm-reviewed strategized planned plan-reviewed executing shipping reflect done)
```

Expected: Already present.

**Step 6: Run syntax check**

Run: `bash -n hub/clavain/hooks/lib-sprint.sh && bash -n hub/clavain/hooks/lib-gates.sh && echo "OK"`
Expected: OK (no syntax errors)

**Step 7: Verify sprint-scan.sh includes reflect**

Run: `grep -c 'reflect' hub/clavain/hooks/sprint-scan.sh`
Expected: 0 or more — sprint-scan.sh may not reference individual phases. If it has a phase array, confirm reflect is included. If no phase array, this is a no-op.

**Step 8: Commit (if any fixes were needed)**

If all verifications pass with no changes needed, skip this step.
```bash
cd /root/projects/Interverse/hub/clavain
git add hooks/lib-sprint.sh hooks/lib-gates.sh
git commit -m "fix: ensure reflect phase in transition table and whitelists (F2a)"
```

---

### Task 2: Verify sprint-scan.sh Phase Coverage (F2a)

**Files:**
- Verify: `hub/clavain/hooks/sprint-scan.sh`

**Step 1: Search for any hardcoded phase lists**

Run: `grep -n 'phase\|PHASE\|shipping\|polish\|done' hub/clavain/hooks/sprint-scan.sh | head -20`

Check if sprint-scan.sh has its own phase array or hardcoded phase names that would need `reflect` added. Based on the PRD, confirm coverage.

Expected: sprint-scan.sh uses `sprint_find_active` and `sprint_next_step` from lib-sprint.sh — it delegates phase logic, doesn't maintain its own list. Verification only.

**Step 2: Report results**

Document which files passed verification. No commit needed if nothing changed.

---

### Task 3: Update /reflect Precondition — Accept `reflect` Phase Only (F3)

**Files:**
- Modify: `hub/clavain/commands/reflect.md:18`

**Step 1: Read the current reflect command**

Read: `hub/clavain/commands/reflect.md`

Current line 18 says:
```
1. **Identify the active sprint.** Use `sprint_find_active` (sourced from lib-sprint.sh) to find the current sprint and confirm it is in the `shipping` or `reflect` phase.
```

**Step 2: Update the precondition**

Change line 18 from accepting `shipping or reflect` to accepting `reflect` only. The sprint command is responsible for advancing `shipping → reflect` before invoking `/reflect`.

Old:
```
1. **Identify the active sprint.** Use `sprint_find_active` (sourced from lib-sprint.sh) to find the current sprint and confirm it is in the `shipping` or `reflect` phase.
```

New:
```
1. **Identify the active sprint.** Use `sprint_find_active` (sourced from lib-sprint.sh) to find the current sprint and confirm it is in the `reflect` phase. (The sprint command advances `shipping → reflect` before invoking `/reflect`.)
```

**Step 3: Run syntax check on the parent hooks**

Run: `bash -n hub/clavain/hooks/lib-sprint.sh && echo "OK"`
Expected: OK (reflect.md is a markdown command, not bash — the syntax check validates lib-sprint.sh which it sources)

---

### Task 4: Add Idempotency Check to /reflect (F3)

**Files:**
- Modify: `hub/clavain/commands/reflect.md`

**Step 1: Add idempotency check before step 2**

Insert a new step between step 1 (identify sprint) and step 2 (capture learnings). This checks whether a reflect artifact already exists, making re-runs safe.

After step 1, insert:

```
1b. **Check for existing reflect artifact.** Before invoking engineering-docs, check if a reflect artifact is already registered:
   ```bash
   source hub/clavain/hooks/lib-sprint.sh
   existing=$(sprint_get_artifact "<sprint_id>" "reflect" 2>/dev/null) || existing=""
   ```
   If `existing` is non-empty, report "Reflect artifact already registered: <existing>. Skipping to advance." and jump to step 4 (advance).
```

---

### Task 5: Add C1 Lightweight Path to /reflect (F3)

**Files:**
- Modify: `hub/clavain/commands/reflect.md`

**Step 1: Add complexity-aware branching to step 2**

Replace the current step 2 with a complexity-aware version. For C1-C2 sprints, write a brief memory note. For C3+, invoke the full engineering-docs skill.

Old step 2:
```
2. **Capture learnings.** Use the `clavain:engineering-docs` skill to document what was learned during this sprint. The skill provides the full 7-step documentation workflow including YAML validation, category classification, and cross-referencing.

   If no context argument was provided, extract context from the recent conversation history — what was built, what went wrong, what patterns emerged.
```

New step 2:
```
2. **Capture learnings (complexity-scaled).**

   Check sprint complexity:
   ```bash
   source hub/clavain/hooks/lib-sprint.sh
   complexity=$(bd state "<sprint_id>" complexity 2>/dev/null) || complexity="3"
   ```

   **C1-C2 (lightweight path):** Write a brief memory note capturing what was learned. If the sprint was routine with no novel learnings, write a complexity calibration note instead (e.g., "Estimated C2, actual was C1 because X"). Register the note path as the reflect artifact.

   **C3+ (full path):** Use the `clavain:engineering-docs` skill to document what was learned during this sprint. The skill provides the full 7-step documentation workflow including YAML validation, category classification, and cross-referencing.

   If no context argument was provided, extract context from the recent conversation history — what was built, what went wrong, what patterns emerged.
```

---

### Task 6: Add Intercore Artifact Registration to /reflect (F3)

**Files:**
- Modify: `hub/clavain/commands/reflect.md`

**Step 1: Update step 3 to register with both intercore and beads**

Old step 3:
```
3. **Register the artifact.** After the engineering doc is written, register it as a reflect-phase artifact:
   ```bash
   source hub/clavain/hooks/lib-sprint.sh
   sprint_set_artifact "<sprint_id>" "reflect" "<path_to_doc>"
   ```
```

New step 3:
```
3. **Register the artifact.** After the learning artifact is written, register it with both intercore (kernel) and beads (OS):
   ```bash
   source hub/clavain/hooks/lib-sprint.sh

   # Kernel path: ic run artifact add (enables gate check)
   run_id=$(bd state "<sprint_id>" run_id 2>/dev/null) || run_id=""
   if [[ -n "$run_id" ]]; then
       ic run artifact add "$run_id" --phase=reflect --path="<path_to_doc>" 2>/dev/null || true
   fi

   # OS path: beads artifact (always)
   sprint_set_artifact "<sprint_id>" "reflect" "<path_to_doc>"
   ```
```

**Step 2: Commit the full reflect.md changes (Tasks 3-6)**

```bash
cd /root/projects/Interverse/hub/clavain
git add commands/reflect.md
git commit -m "feat: update /reflect — precondition, idempotency, C1 path, ic artifact (F3)"
```

---

### Task 7: Add Step 9 (Reflect) to Sprint Command (F1)

**Files:**
- Modify: `hub/clavain/commands/sprint.md`

**Step 1: Read current Steps 7-9**

Read: `hub/clavain/commands/sprint.md` lines 301-341

Current Step 8 is "Resolve Issues" and Step 9 is "Ship".

**Step 2: Add Step 9: Reflect between Resolve and Ship**

After Step 8 (Resolve Issues, ending around line 335), insert a new Step 9:

```markdown
## Step 9: Reflect

Advance the sprint from `shipping` to `reflect`, then invoke `/reflect`:

```bash
export GATES_PROJECT_DIR="."; source "${CLAUDE_PLUGIN_ROOT}/hooks/lib-gates.sh"
advance_phase "$CLAVAIN_BEAD_ID" "reflect" "Entering reflect phase" ""
```

Run `/reflect` — it captures learnings (complexity-scaled), registers the artifact, and advances `reflect → done`.

**Phase-advance ownership:** `/reflect` owns both artifact registration AND the `reflect → done` advance. Do NOT call `advance_phase` after `/reflect` returns.

**Soft gate:** On initial shipment, emit a warning but allow advance if no reflect artifact exists. Graduate to hard gate after 10 successful reflect phases across sprints.
```

**Step 3: Renumber old Step 9 (Ship) to Step 10**

Change `## Step 9: Ship` to `## Step 10: Ship`.

---

### Task 8: Update Sprint Summary and Error Recovery Step Count (F1)

**Files:**
- Modify: `hub/clavain/commands/sprint.md`

**Step 1: Update Sprint Summary step count**

Find the line (around 348):
```
- Steps completed: <n>/9
```

Change to:
```
- Steps completed: <n>/10
```

**Step 2: Update Session Checkpointing step name list**

Find line 134:
```
Step names: `brainstorm`, `strategy`, `plan`, `plan-review`, `execute`, `test`, `quality-gates`, `resolve`, `ship`.
```

Change to:
```
Step names: `brainstorm`, `strategy`, `plan`, `plan-review`, `execute`, `test`, `quality-gates`, `resolve`, `reflect`, `ship`.
```

**Step 3: Update --from-step argument**

Find line 113:
```
- **If `$ARGUMENTS` contains `--from-step <n>`**: Skip directly to step `<n>` regardless of checkpoint state. Step names: brainstorm, strategy, plan, plan-review, execute, test, quality-gates, resolve, ship.
```

Change to:
```
- **If `$ARGUMENTS` contains `--from-step <n>`**: Skip directly to step `<n>` regardless of checkpoint state. Step names: brainstorm, strategy, plan, plan-review, execute, test, quality-gates, resolve, reflect, ship.
```

---

### Task 9: Update Sprint Resume Routing for Reflect (F1)

**Files:**
- Modify: `hub/clavain/commands/sprint.md`

**Step 1: Verify sprint resume routing handles reflect**

Read lines 29-37 (sprint resume routing). The routing uses `sprint_next_step()` which already maps `reflect → "reflect"` (verified in Task 1). However, the routing table at line 36 maps commands to slash commands:

```
- `ship` → `/clavain:quality-gates`
```

Verify there's no explicit `reflect` routing needed — `sprint_next_step("shipping")` returns `"reflect"`, which should route to `/reflect`. The sprint resume routing at lines 30-37 lists explicit mappings. Add `reflect` if missing:

After `- `ship` → `/clavain:quality-gates``:
```
        - `reflect` → `/reflect`
```

Wait — the current routing at line 36 says `ship` maps to quality-gates, which is actually the command for the shipping phase. Check if the `reflect` command route is already handled. Since `sprint_next_step` returns command names and the routing maps them to slash commands, we need:

```
        - `reflect` → `/reflect`
```

**Step 2: Verify the "done" message still works**

The routing already has `- `done` → tell user "Sprint is complete"` — this is correct since `/reflect` advances to `done`.

---

### Task 10: Commit Sprint Command Changes (F1)

**Files:**
- Commit: `hub/clavain/commands/sprint.md`

**Step 1: Run a quick validation**

Verify no broken markdown:
```bash
grep -c '## Step' hub/clavain/commands/sprint.md
```
Expected: 10 (Steps 1-10, plus possible sub-steps) — at least count Pre-Step + Steps 1-10.

**Step 2: Commit**

```bash
cd /root/projects/Interverse/hub/clavain
git add commands/sprint.md
git commit -m "feat: add Step 9 Reflect to sprint command, renumber Ship to Step 10 (F1)"
```

---

### Task 11: Fix Intercore Phase Count Comment (F4)

**Files:**
- Modify: `infra/intercore/internal/phase/phase.go:64`
- Modify: `infra/intercore/AGENTS.md:277`

**Step 1: Fix Go comment**

In `infra/intercore/internal/phase/phase.go` line 64:

Old:
```go
// DefaultPhaseChain is the 10-phase Clavain lifecycle.
```

New:
```go
// DefaultPhaseChain is the 9-phase Clavain lifecycle.
```

**Step 2: Run Go tests**

Run: `cd /root/projects/Interverse/infra/intercore && go test ./internal/phase/ -short -timeout=30s`
Expected: PASS

**Step 3: Fix AGENTS.md phase count**

In `infra/intercore/AGENTS.md` line 277:

Old:
```
Runs can specify a custom phase chain via `--phases='["a","b","c"]'` at creation. If no chain is specified, the default 10-phase Clavain lifecycle is used:
```

New:
```
Runs can specify a custom phase chain via `--phases='["a","b","c"]'` at creation. If no chain is specified, the default 9-phase Clavain lifecycle is used:
```

**Step 4: Commit**

```bash
cd /root/projects/Interverse/infra/intercore
git add internal/phase/phase.go AGENTS.md
git commit -m "fix: correct DefaultPhaseChain comment from 10-phase to 9-phase (F4)"
```

---

### Task 12: Update Clavain Vision Doc — Macro-Stages (F4)

**Files:**
- Modify: `hub/clavain/docs/clavain-vision.md:169-171`
- Modify: `hub/clavain/docs/clavain-vision.md:298`
- Modify: `hub/clavain/docs/clavain-vision.md:300-304`
- Modify: `hub/clavain/docs/clavain-vision.md:536`

**Step 1: Fix "four macro-stages" → "five macro-stages"**

Line 169:
Old: `## Scope: Four Macro-Stages`
New: `## Scope: Five Macro-Stages`

Line 171:
Old: `Clavain covers the full product development lifecycle through four macro-stages.`
New: `Clavain covers the full product development lifecycle through five macro-stages.`

**Step 2: Add Reflect macro-stage section**

After the Ship macro-stage section (before line 298), add:

```markdown
### Reflect

Capture what was learned. The agency documents patterns discovered, mistakes caught, decisions validated, and complexity calibration data. This closes the recursive learning loop — every sprint feeds knowledge back into the system.

| Capability | Models / Agents |
|---|---|
| C1-C2 lightweight learnings | Haiku (quick memory notes) |
| C3+ engineering documentation | Opus (full solution docs) |
| Complexity calibration | Automatic (estimated vs actual comparison) |
| **Output** | Learning artifacts (memory notes, solution docs, calibration data) |
```

**Step 3: Update the macro-stage → sub-phase mapping**

Line 298:
Old: `Each macro-stage maps to sub-phases internally — Discover includes research and brainstorm; Design includes strategy, plan, and plan-review; Build includes execute and test; Ship includes review, deploy, and learn.`
New: `Each macro-stage maps to sub-phases internally — Discover includes research and brainstorm; Design includes strategy, plan, and plan-review; Build includes execute and test; Ship includes review and deploy; Reflect includes learning capture and complexity calibration.`

**Step 4: Update handoff contracts**

Line 304:
Old: `- **Ship → (next cycle):** Compounded learnings, shipped artifacts. Feed back into Discover for the next iteration.`
New:
```
- **Ship → Reflect:** Shipped code, review verdicts, agent telemetry. Reflect reads these as evidence for what worked and what didn't.
- **Reflect → (next cycle):** Compounded learnings, complexity calibration data, updated memory. Feed back into Discover for the next iteration.
```

**Step 5: Fix "one phase of four"**

Line 536:
Old: `The coding is one phase of four.`
New: `The coding is one phase of five.`

**Step 6: Commit**

```bash
cd /root/projects/Interverse/hub/clavain
git add docs/clavain-vision.md
git commit -m "docs: update vision doc from 4 to 5 macro-stages, add Reflect (F4)"
```

---

### Task 13: Update Glossary and AGENTS.md References (F4)

**Files:**
- Modify: `docs/glossary.md:25-27`
- Modify: `hub/clavain/AGENTS.md`

**Step 1: Update glossary Sprint definition**

In `docs/glossary.md` line 25, the Sprint definition says:
```
| **Sprint** | An OS-level run template with preset phases (brainstorm → strategize → plan → review → execute → ship → reflect). The full development lifecycle. |
```

This already mentions reflect — verify it's correct. The macro-stage definition at line 27 says:
```
| **Macro-stage** | OS-level workflow grouping: Discover, Design, Build, Ship, Reflect. Each maps to sub-phases in the kernel. |
```

This already lists 5 macro-stages including Reflect — verify it's correct.

**Step 2: Update AGENTS.md sprint lifecycle references**

Search `hub/clavain/AGENTS.md` for any references to "4 macro-stages" or outdated phase counts and fix them.

Run: `grep -n 'macro.stage\|4.*stage\|four.*stage\|8.*phase\|step.*9\|9.*step' hub/clavain/AGENTS.md`

Fix any stale references found.

**Step 3: Commit if changes were made**

```bash
cd /root/projects/Interverse
git add docs/glossary.md
git commit -m "docs: verify glossary reflects 5 macro-stages (F4)"

cd /root/projects/Interverse/hub/clavain
git add AGENTS.md
git commit -m "docs: update AGENTS.md sprint lifecycle references (F4)"
```

---

### Task 14: Add Sprint-to-Kernel Phase Mapping Table (F5)

**Files:**
- Modify: `docs/glossary.md`

**Step 1: Add the mapping table**

After the "Cross-Cutting" section (around line 57) and before "Terms to Avoid", add:

```markdown
## Sprint Phase Mapping (OS ↔ Kernel)

The OS (Clavain) and kernel (Intercore) both use 9-phase chains, but with different phase names. This table shows the canonical mapping.

| # | OS Phase (`PHASES_JSON`) | Kernel Phase (`DefaultPhaseChain`) | Notes |
|---|---|---|---|
| 1 | `brainstorm` | `brainstorm` | Same |
| 2 | `brainstorm-reviewed` | `brainstorm-reviewed` | Same |
| 3 | `strategized` | `strategized` | Same |
| 4 | `planned` | `planned` | Same |
| 5 | `plan-reviewed` | *(no equivalent)* | OS-only — flux-drive plan review gate. Kernel has no `plan-reviewed` phase. |
| 6 | `executing` | `executing` | Same |
| 7 | `shipping` | `polish` | Historical divergence. OS rename deferred (see iv-52om). |
| 8 | `reflect` | `reflect` | Same. Gate rule `CheckArtifactExists` fires for both chains. |
| 9 | `done` | `done` | Same. Terminal phase — sets `status=completed`. |

**Kernel gate rule coverage:** Only `{reflect, done}: CheckArtifactExists` fires for OS-created sprints, because the OS uses different phase names for earlier phases. This is a known pre-existing condition.

**Why divergent:** `plan-reviewed` exists in the OS because flux-drive plan review is an OS-level gate with no kernel equivalent. `shipping` was the original name for the quality-gates/ship step; renaming it to `polish` requires migration of all existing sprints (deferred to iv-52om).
```

**Step 2: Commit**

```bash
cd /root/projects/Interverse
git add docs/glossary.md
git commit -m "docs: add Sprint-to-Kernel phase mapping table (F5)"
```

---

## Verification Checklist

After all tasks are complete:

1. `bash -n hub/clavain/hooks/lib-sprint.sh` — passes
2. `bash -n hub/clavain/hooks/lib-gates.sh` — passes
3. `cd infra/intercore && go test ./internal/phase/ -short` — passes
4. `grep -c 'reflect' hub/clavain/commands/sprint.md` — at least 5 occurrences
5. `grep -c 'reflect' hub/clavain/commands/reflect.md` — at least 8 occurrences
6. `grep -c '10-phase' infra/intercore/internal/phase/phase.go` — 0 (all fixed to 9-phase)
7. `grep -c '10-phase' infra/intercore/AGENTS.md` — 0 (all fixed to 9-phase)
8. `grep 'four macro' hub/clavain/docs/clavain-vision.md` — 0 matches (all fixed to five)
