# Architecture Review — Revised Dual-Mode Plugin Architecture Brainstorm (Round 2)

**Reviewer:** fd-architecture (second pass)
**Date:** 2026-02-20
**Input:** `/root/projects/Interverse/docs/brainstorms/2026-02-20-dual-mode-plugin-architecture-brainstorm.md`
**Prior synthesis:** `/root/projects/Interverse/docs/research/synthesize-review-findings.md`
**Output:** `/root/projects/Interverse/.clavain/quality-gates/fd-architecture-v2.md`

---

## Context

The first-round review identified three P1 blocking issues: vendoring drift, plugin.json schema conflict, and the intermod pattern being unrecognized. The brainstorm has been revised to incorporate all three. This review evaluates whether the revisions resolve those issues and whether any new structural problems were introduced by the changes.

Five focal questions were specified:

1. Is the stub-plus-live-discovery hybrid (interbase-stub.sh → ~/.intermod/interbase.sh) architecturally sound?
2. Does the ~/.intermod/ directory structure make sense? Is manifest.json needed?
3. Is the integration.json schema well-designed?
4. Does the "ecosystem-only" product decision for interlock/interphase create architectural problems?
5. Is the session status line emitted by centralized interbase.sh at the right layer?

---

## Focal Question Analysis

### Q1: Stub-Plus-Live-Discovery Hybrid

The pattern as written is structurally correct and directly mirrors the proven interband pattern in `infra/interband/lib/interband.sh`. The guard-loaded flag `[[ -n "${_INTERBASE_LOADED:-}" ]] && return 0` is present and correct, preventing double-sourcing across multiple plugins in the same session.

**Edge cases identified:**

**Edge case A — Source failure mid-load.** The stub code does:

```bash
if [[ -f "$_interbase_live" ]]; then
    source "$_interbase_live"
    return 0
fi
```

If `source "$_interbase_live"` exits with a non-zero status (syntax error in a partially written interbase.sh, or a sourced dependency missing), the `return 0` is never reached and the function continues into the inline stubs. This is actually correct fail-open behavior. However, the `_INTERBASE_LOADED` guard is only set in the inline-stub path — if the live source succeeds, `_INTERBASE_LOADED` is never set. A second plugin that sources the same stub file will check `_INTERBASE_LOADED`, find it unset, try the live path again, succeed, and silently re-source interbase.sh. This is benign only if interbase.sh is itself idempotent with a `[[ -n "${_INTERBASE_LOADED:-}" ]]` guard at its top, which the brainstorm implies but does not state explicitly. The stub should set `_INTERBASE_LOADED=1` before `source "$_interbase_live"` so the guard works regardless of which path loaded the library.

**Edge case B — Partial ecosystem detection in `ib_in_ecosystem()`.** The stub defines `ib_in_ecosystem()` as a filesystem check: `[[ -f "${HOME}/.intermod/interbase/interbase.sh" ]]`. This will always return false when the stubs are active (since if the file existed, the live path would have been taken). The stub definition is therefore a dead function — it will never be called from within the stub path. This is not a bug but it is a confusing invariant. Any code that calls `ib_in_ecosystem()` before the live library is available will always get false, which is correct, but the function definition in the stub body serves no purpose because the condition is structurally identical to the branch that skips the stub.

**Edge case C — INTERMOD_LIB override and the guard.** If `INTERMOD_LIB` is set to a dev path and the dev copy does not export `_INTERBASE_LOADED`, two plugins in the same session will each source the dev copy independently. The fix is the same as Edge case A: set `_INTERBASE_LOADED=1` unconditionally in the stub before the live source attempt, and verify that the live interbase.sh sets it too.

**Edge case D — Race on first session boot.** If multiple hooks fire in parallel at session start (a documented Claude Code behavior), each will evaluate the stub's `[[ -f "$_interbase_live" ]]` check before any has set `_INTERBASE_LOADED`. Since `source` in bash is not atomic across processes, all concurrent hooks may each independently source interbase.sh. This is likely harmless (bash function redefinition is idempotent for pure functions) but generates unnecessary work. The interband pattern handles this the same way, so this is a known and accepted tradeoff.

**Net assessment of Q1:** The hybrid pattern is architecturally sound and resolves P1-A from the first round. The `_INTERBASE_LOADED` guard placement is the one technical correction needed: it must be set before the live source attempt, not only in the fallback branch.

---

### Q2: ~/.intermod/ Directory Structure and manifest.json

The proposed structure:

```
~/.intermod/
├── interbase/
│   ├── interbase.sh
│   └── VERSION
├── interband/            (future)
└── manifest.json
```

The subdirectory-per-library structure (`~/.intermod/interbase/`) is correct. It follows the existing `~/.interband/` naming convention and is isolated from any future additions under `~/.intermod/`. The `VERSION` file is the right mechanism — a single line read by `cat` is simpler and more portable than embedding version metadata in a shell variable that requires sourcing to inspect.

**manifest.json is premature.** The brainstorm's stated purposes for `manifest.json` — "Registry of installed modules + versions" — introduces a maintenance problem without a current consumer. Nothing in the brainstorm reads manifest.json: not the stub, not the live interbase.sh, not interbump, not any described tooling. A registry file that is written at install time but never read is entropy, not infrastructure.

The VERSION file already provides what a tool actually needs at runtime (version of the specific library). If cross-library introspection is needed later (e.g., "which intermod libraries are installed?"), `ls ~/.intermod/*/VERSION` accomplishes this without a separately maintained manifest. A manifest makes sense only when there is tooling that requires it — for example, a `/doctor` check that validates module versions. That tooling does not exist yet.

**Interband consolidation under ~/.intermod/.** The brainstorm lists this as a future open question. The correct position is: do not migrate until there is a concrete use case. The interband protocol at `~/.interband/` works today, has multiple consumers (interphase, dispatch.sh), and its path is hardcoded in resolution chains across the codebase. Moving it to `~/.intermod/interband/` would require updating every resolution chain in every consumer. This is a maintenance cost with no functional benefit until `~/.intermod/` provides a capability that justifies the migration.

**Net assessment of Q2:** Directory structure is sound. Drop manifest.json — premature with no current consumer. Defer interband consolidation.

---

### Q3: integration.json Schema

The schema as proposed:

```json
{
  "ecosystem": "interverse",
  "interbase_version": "1.0.0",
  "standalone_features": [...],
  "integrated_features": [{ "feature": "...", "requires": "..." }],
  "companions": {
    "recommended": [...],
    "optional": [...]
  }
}
```

**What the schema does well:**
- Separating integration metadata from plugin.json resolves P1-B cleanly. The file is Interverse-owned.
- The `requires` field in `integrated_features` is the right granularity — it links a feature description to a specific companion name, enabling automated companion suggestions without ambiguity.
- Splitting companions into `recommended` vs `optional` is a useful product distinction for marketplace display.

**Missing field — `ecosystem_only` boolean.** The brainstorm makes the product decision that interlock and interphase are ecosystem-only and should not be published standalone. There is no field in integration.json to record this decision. Without it, tooling (marketplace CI, interbump) has no way to enforce the ecosystem-only constraint automatically — it must be enforced by convention. Adding `"ecosystem_only": true` gives interbump a gate to reject standalone publish attempts and gives the marketplace a display signal ("requires Clavain ecosystem").

**Missing field — `install_mode`.** Related: the brainstorm says ecosystem-only plugins should be "bundled with Clavain modpack." There is no concept of a modpack or bundle installation in the schema. If this becomes real (a `/clavain:setup` skill that installs all recommended ecosystem plugins), the schema needs a field for that relationship. For now, a simple `"bundle": "clavain"` string would express the intent without over-specifying the mechanism.

**`interbase_version` field is underspecified.** The field value `"1.0.0"` expresses the minimum compatible version of interbase.sh this plugin requires. However, the brainstorm also says interbase.sh will have a `VERSION` file at `~/.intermod/interbase/VERSION`. There is no described mechanism by which the stub or tooling checks this compatibility field at runtime. If this field is only documentation, name it `interbase_min_version` and note that enforcement is deferred. If it is meant to be checked at session start, describe the check.

**`standalone_features` as free-form strings.** This field is valuable for documentation and marketplace display. It becomes a maintenance liability if it's also used to drive automated behavior (e.g., test harness that maps feature descriptions to test cases). Free-form strings cannot be compared, sorted, or queried. If the test architecture in Decision 5 relies on this field to enumerate test cases, it needs structured identifiers, not prose descriptions. If it is display-only, the current format is fine.

**Net assessment of Q3:** Schema is well-formed and resolves the plugin.json collision risk. Three additions would make it complete: `ecosystem_only` boolean, `interbase_min_version` renaming with enforcement note, and deferral note on `standalone_features` being display-only rather than machine-actionable.

---

### Q4: Ecosystem-Only Decision for interlock/interphase

The brainstorm correctly identifies both plugins as ecosystem-only and routes them through the Clavain modpack rather than the standalone marketplace.

**The architectural problem this creates is installation ownership.** The brainstorm says "Bundle with Clavain modpack" but does not define what a modpack is, where it is specified, or how `interbump` or `/clavain:setup` knows to install these plugins as part of Clavain setup. There is no existing "modpack" concept in the marketplace schema (see Q3 above) and no `clavain:setup` skill with plugin-install capabilities in the current Clavain hub.

Concretely: a user who installs Clavain today via the marketplace gets Clavain. They do not automatically get interlock and interphase. If interlock and interphase are delisted from standalone marketplace entries (as recommended), the only install path is manual (`/plugin install interlock`). The brainstorm does not describe how a Clavain user discovers this requirement or how setup is automated.

**The circular dependency surface.** interlock depends on intermute (a service). intermute is a Go binary in `services/intermute/`. The install chain for a complete ecosystem setup is: install Clavain → discover interlock/interphase recommendation → install those plugins → start intermute service. This chain has no automated path today. The ecosystem-only decision does not create new architectural problems, but it does surface an existing gap: there is no defined "full ecosystem setup" workflow. The brainstorm notes "Bundle with Clavain modpack" as if this is an existing mechanism; it is not.

**interphase state store gap (carried forward from first round).** The first-round review noted that interphase at 20% standalone has no state store for phase tracking without beads. The revised brainstorm lists interphase as ecosystem-only, which avoids this problem — ecosystem users will have beads. This is a correct resolution. However, the brainstorm does not update the integration.json design to reflect the `ecosystem_only: true` signal that would let tooling enforce this.

**Net assessment of Q4:** The ecosystem-only decision is architecturally correct and resolves the structural mismatch identified in the first round. The gap is that "bundle with Clavain modpack" refers to infrastructure that does not exist. This is a planning debt, not an architecture defect, but it should be scoped as a concrete deliverable (a `clavain:setup` skill that installs companion plugins) before the ecosystem-only decision becomes actionable.

---

### Q5: Session Status Line at the Centralized interbase.sh Layer

The proposed status line:

```
[interverse] interflux=standalone | beads=active | ic=not-detected | 2 companions available
```

Emitted by `~/.intermod/interbase/interbase.sh` at session start.

**The layer question.** Placing status line emission in interbase.sh means it fires once per session, from whichever plugin first sources the live copy. This is a side-effecting behavior embedded in a library that is otherwise a guard/helper provider. There is a precedent for this in the codebase: `session-start.sh` hooks are the standard place for session-start output. Having a shared library emit to stderr on load conflates "library initialization" with "user-facing output."

The problem is that interbase.sh is sourced at arbitrary points (whenever a hook fires that includes the stub), not exclusively at session start. If a PreToolUse hook fires before the SessionStart hook, interbase.sh will be sourced — and the status line will appear mid-session, not at session start. The `_INTERBASE_LOADED` guard prevents it from appearing twice, but it does not control when the first source happens relative to session lifecycle.

**Correct layering.** The status line should be emitted by the SessionStart hook of whichever plugin is responsible for the interverse session context, not by the library itself. In the current architecture, each plugin has its own `session-start.sh`. The right pattern is: a single designated plugin (e.g., interflux, as the reference implementation) emits the status line in its `session-start.sh` by calling an `ib_session_status` function from interbase.sh. The function is in interbase.sh; the invocation is in the hook. This respects the separation between library code and hook lifecycle.

There is a secondary issue: the status line content requires knowing which plugins are installed (`interflux=standalone`). interbase.sh at load time does not know which other plugins are installed — it only knows which guard conditions are met (ic present, bd present, etc.). Building a per-plugin status entry requires the status line emitter to either iterate over installed plugins (expensive) or require each plugin to register itself with interbase.sh (coupling). The existing interband approach handles this via file-based sideband — interline reads sideband state rather than being told by a central authority.

The simpler and more consistent approach: emit a single ecosystem-level status line (not per-plugin), limited to what interbase.sh can determine from its own guards at load time: `[interverse] beads=active | ic=not-detected | 2 companions available`. Per-plugin mode information belongs in each plugin's own session-start hook or in a dedicated status tool (the autarch-status-tool brainstorm addresses exactly this).

**Net assessment of Q5:** The session status line is at the wrong layer. Library initialization code should not emit user-facing output. The content should be emitted by a SessionStart hook via a library call. The content should be limited to what interbase.sh can determine from its own guards; per-plugin mode display requires a dedicated status aggregator.

---

## Cross-Cutting Issue: Source-Then-Return Does Not Set the Loaded Guard

This is the most concrete code-level defect in the proposed stub. The stub as written:

```bash
[[ -n "${_INTERBASE_LOADED:-}" ]] && return 0

_interbase_live="${INTERMOD_LIB:-${HOME}/.intermod/interbase/interbase.sh}"
if [[ -f "$_interbase_live" ]]; then
    source "$_interbase_live"
    return 0
fi

_INTERBASE_LOADED=1
ib_has_ic() { ... }
...
```

`_INTERBASE_LOADED` is only set in the fallback path. If the live source succeeds, `_INTERBASE_LOADED` remains unset. The second plugin to source the stub will pass the guard check, attempt the live source again, and succeed — executing interbase.sh's top-level code a second time.

If interbase.sh itself sets `_INTERBASE_LOADED=1` at its top (which it should, following the `_INTERBAND_LOADED` pattern in `infra/interband/lib/interband.sh`), then the guard in the stub becomes effective on the second call. But this depends on interbase.sh's internal convention, not on the stub's own correctness. The stub should set `_INTERBASE_LOADED=1` immediately before calling `source`, making the guard unconditionally correct:

```bash
[[ -n "${_INTERBASE_LOADED:-}" ]] && return 0
_INTERBASE_LOADED=1  # Set before source so guard works regardless of source path

_interbase_live="${INTERMOD_LIB:-${HOME}/.intermod/interbase/interbase.sh}"
if [[ -f "$_interbase_live" ]]; then
    source "$_interbase_live"
    return 0
fi

# Fallback stubs
ib_has_ic() { ... }
...
```

This matches the `_INTERBAND_LOADED=1` placement in `infra/interband/lib/interband.sh` line 10, which sets the guard unconditionally at the top before any code runs.

---

## What the Revision Gets Right

These positions from the revised brainstorm are structurally sound and should carry forward to planning:

- Stub-plus-live-discovery is the correct resolution of the vendoring problem. It preserves standalone operation and eliminates drift for ecosystem users simultaneously.
- Separate `integration.json` cleanly resolves platform schema ownership. The file location (`.claude-plugin/integration.json`) is consistent with the existing plugin structure convention.
- Nudge logic in centralized interbase.sh only (not stubs) is correct. This was the pace-layer inversion problem from the first review; the revised brainstorm addresses it properly.
- Session-level test harness (`test-session.sh`) added in Decision 5 addresses the P1-SYS-B finding from the synthesis report. The addition of a multi-plugin session test is the right response.
- Ecosystem-only designation for interlock and interphase is the correct product decision. The first round correctly identified these as structural mismatches, not calibration issues.
- Atomic touch pattern for nudge concurrency guard is present and correct.

---

## Remaining Open Questions (from brainstorm) — Assessment

**Q: Marketplace manifest drift** — Still unresolved. Not introduced by this revision but remains a structural problem.

**Q: Migration sequencing** — The brainstorm asks whether to build sdk/interbase/ first or migrate interflux first. The correct answer: build `sdk/interbase/` with the stub template and integration.json schema first. This establishes the contract. Then migrate interflux as the first consumer. The infrastructure without a consumer is not useful, but the consumer without the infrastructure spec makes the first migration a spec-making exercise.

**Q: Interband consolidation** — Correctly deferred. See Q2 analysis.

**Q: Session-level test harness** — The brainstorm asks how to practically load multiple plugins in a test Claude Code session. This is a genuine gap with no easy answer. The test architecture for session-level integration does not exist. This should be flagged as a known dependency before the architecture can claim its testing guarantees.
