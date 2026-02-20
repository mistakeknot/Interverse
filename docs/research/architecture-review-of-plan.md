# Architecture Review: Dual-Mode Plugin Architecture Implementation Plan

**Reviewer:** Flux-drive Architecture & Design Reviewer
**Date:** 2026-02-20
**Plan:** `/root/projects/Interverse/docs/plans/2026-02-20-dual-mode-plugin-architecture.md`
**PRD:** `/root/projects/Interverse/docs/prds/2026-02-20-dual-mode-plugin-architecture.md`
**Prior art consulted:**
- `docs/research/review-revised-dual-mode-architecture.md` (second-round architecture review of the brainstorm)
- `infra/interband/lib/interband.sh` (reference pattern)
- `plugins/interflux/.claude-plugin/plugin.json` (target plugin)
- `scripts/interbump.sh` (publish pipeline)
- `docs/guides/interband-sideband-protocol.md`

---

## Summary Verdict

The plan is architecturally sound at the macro level. The centralized-copy + stub-fallback pattern is a direct and correct extension of the existing interband pattern already working in this codebase. The five focus areas all have legitimate findings. Three of the eleven tasks contain structural problems significant enough to fix before implementation begins. The remaining issues are hardening gaps that can be addressed during or after implementation.

---

## 1. Centralized-Copy + Stub-Fallback Pattern: Is It Sound?

**Verdict: Sound with one critical guard-placement bug that must be fixed.**

The pattern itself is the right architecture for this problem. The existing `infra/interband/lib/interband.sh` proves the model works in production: load-once guard at line 9-10, centralized source, downstream consumers source a stub that tries the live path first. interbase follows this pattern faithfully.

**The specific bug in the stub template (Task 2).**

The stub as written in Task 2, Step 1 sets `_INTERBASE_LOADED=1` only in the fallback (inline stubs) path:

```bash
if [[ -f "$_interbase_live" ]]; then
    _INTERBASE_SOURCE="live"
    source "$_interbase_live"
    return 0               # <-- _INTERBASE_LOADED never set here
fi

_INTERBASE_LOADED=1        # Only reached in fallback path
ib_has_ic() { ... }
```

If the live copy is sourced successfully, `_INTERBASE_LOADED` is unset. A second plugin that sources the same stub will pass the guard check (`[[ -n "${_INTERBASE_LOADED:-}" ]]` is empty, so it does not short-circuit), attempt the live source again, and re-execute the top-level code of interbase.sh. This is benign only if interbase.sh itself sets the guard, which the plan does specify (Task 1, Step 2, line 46: `_INTERBASE_LOADED=1`), but the stub's correctness should not depend on the live file's internal convention.

The interband pattern at `infra/interband/lib/interband.sh` lines 9-10 sets `_INTERBAND_LOADED=1` unconditionally at the top before any code runs. The stub template must do the same:

```bash
[[ -n "${_INTERBASE_LOADED:-}" ]] && return 0
_INTERBASE_LOADED=1   # Set unconditionally before source attempt

_interbase_live="${INTERMOD_LIB:-${HOME}/.intermod/interbase/interbase.sh}"
if [[ -f "$_interbase_live" ]]; then
    _INTERBASE_SOURCE="live"
    source "$_interbase_live"
    return 0
fi

_INTERBASE_SOURCE="stub"
ib_has_ic() { ... }
```

This fix also resolves the INTERMOD_LIB dev-override edge case (Task 5, Step 5 relies on the override working correctly in isolation).

**The `ib_in_ecosystem()` function in the live copy.**

The plan defines `ib_in_ecosystem()` as:

```bash
ib_in_ecosystem()  { [[ -n "${_INTERBASE_LOADED:-}" ]] && [[ "${_INTERBASE_SOURCE:-}" == "live" ]]; }
```

After the guard fix above, `_INTERBASE_LOADED` will always be set. The distinguishing signal is `_INTERBASE_SOURCE`. This function is then correct. However, it is worth noting that `ib_in_ecosystem()` is not called anywhere in the plan — no integration feature gates on it. This is not a defect (the PRD lists it as a guard to provide), but it should not be counted as a tested path unless Task 5 adds a test case for it.

**Coupling risk assessment.** The stub-fallback pattern introduces a runtime coupling between plugins through the shared `_INTERBASE_LOADED` global in the bash environment. This is acceptable — it is the same mechanism interband uses and the ecosystem already accepts this tradeoff. The risk is bounded: the global is a flag, not state, and any plugin that sources the stub first will claim the load. Because all plugins ship the same stub template, function signatures are identical regardless of which plugin sources first.

---

## 2. Nudge Protocol Placement: SDK vs Separate Module

**Verdict: Placement is correct. Scope is proportionate. One behavior concern.**

The PRD correctly locates nudge logic in the centralized copy only, not in stubs. The revised architecture review (second round) explicitly validates this placement. The reasoning is sound: nudge logic requires durable state management and session-scoped budgeting — functionality that does not belong in a per-plugin stub and should not be duplicated across 20+ plugins.

The nudge protocol is not a separate module concern. It has no interface other than `ib_nudge_companion()`. It reads and writes files in `~/.config/interverse/`, which is a sensible location. It is small enough (roughly 60 lines in the plan) to stay in interbase.sh without turning it into a god module.

**One behavioral concern: `ib_session_status()` emits at call-site, nudge reads companion list at runtime.**

The plan's `ib_session_status()` (Task 1, Step 2) says it will count "recommended companions not installed (requires integration.json reading — deferred)". The deferred comment is the right call. But it should be made explicit in the code as a comment, not just in the plan, so the deferred scope does not silently accrete into the implementation.

**The nudge fires when `ib_nudge_companion` is called explicitly by a plugin**, not automatically at session start. This is the correct architecture (it is what the PRD F3 specifies: "triggers on first successful operation completion per session, not session-start"). The plan's Task 8 hook fires `ib_session_status` at session start, which is read-only. The nudge is invoked by feature code later. This separation is correct.

**The session_id tie.** The nudge session file is keyed to `CLAUDE_SESSION_ID`. The plan does not define where or when `CLAUDE_SESSION_ID` is set. If it is not set (a standalone user running outside Claude Code), the session file becomes `nudge-session-unknown.json`. All nudges from all standalone invocations accumulate against the same session, eventually hitting the budget of 2 and going silent permanently for that key. This is a minor but real edge case: the budget counter should reset when `CLAUDE_SESSION_ID` is absent (treat each script invocation as its own session, or disable nudging when no session ID is present). The current test in Task 3 sets `CLAUDE_SESSION_ID="test-session-$$"`, which will pass but will not catch this scenario.

---

## 3. integration.json Schema: Surface Area

**Verdict: Schema surface area is appropriate. Two field-level issues need resolution.**

The schema as specified in Task 2, Step 2:

```json
{
  "ecosystem": "interverse",
  "interbase_min_version": "1.0.0",
  "ecosystem_only": false,
  "standalone_features": [],
  "integrated_features": [],
  "companions": {
    "recommended": [],
    "optional": []
  }
}
```

This is clean. The previous architecture review's recommendation to rename `interbase_version` to `interbase_min_version` has been incorporated. `ecosystem_only` boolean is present, which was the schema's most important missing field. The schema cleanly separates Interverse-owned metadata from the Claude Code platform schema in `plugin.json`.

**Issue 1: `integrated_features` type mismatch between template and interflux instance.**

The template defines `integrated_features` as an empty array `[]`. The interflux instance (Task 7) populates it as an array of objects:

```json
{ "feature": "Phase tracking on review completion", "requires": "interphase" }
```

The template does not show this structure. When interbump copies the template for new plugins, contributors may populate `integrated_features` as a flat string array rather than an object array. Neither the install script nor any validation step in the plan enforces the object structure. The template should show the object structure with a commented example, or the install.sh should include a schema validation step. The Task 7 validation step does not check `integrated_features` object shape — it only checks count.

**Issue 2: `standalone_features` as free-form prose strings is correct for now, but should be noted.**

The field is display-only documentation. The plan uses it only for marketplace display and human reference. This is the right constraint. No code in the plan reads these strings to make decisions. This distinction should be documented in the AGENTS.md (Task 6) to prevent future accretion of feature-flagging logic on top of prose strings.

**No issues with `companions` structure.** The `recommended` vs `optional` split is the right granularity. The values are plugin names (strings), which is machine-actionable. The interflux instance correctly separates `interwatch` and `intersynth` (recommended) from `interphase` and `interstat` (optional).

---

## 4. install.sh → ~/.intermod/ Deployment Model

**Verdict: Appropriate for current scope. One operational gap in the interbump integration.**

The `~/.intermod/interbase/` target directory is correct. It follows the namespace pattern established by `~/.interband/` and isolates the SDK from unrelated home directory clutter. The `VERSION` file (single-line, read with `cat`) is simpler and more portable than any alternative.

**The install.sh itself is clean.** `set -euo pipefail`, `chmod 644`, explicit VERSION write. The test steps in Task 4 (stat permissions, cat VERSION) are adequate verification.

**Gap: interbump integration is structurally problematic (Task 10).**

The plan adds `install_interbase()` to `scripts/interbump.sh` and calls it at the end of the main execution flow. This creates a cross-module side effect in a publish-pipeline script. The existing `interbump.sh` is run from each plugin's root directory (`PLUGIN_ROOT` is resolved via `git rev-parse --show-toplevel`). The proposed addition adds this logic:

```bash
interbase_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/infra/interbase"
```

This relative path navigation from `scripts/` to `infra/interbase/` assumes interbump.sh is always invoked from the Interverse monorepo context. However, `interbump.sh` is currently invoked from plugin directories via each plugin's `scripts/bump-version.sh` thin wrapper. The resolution `$(dirname "${BASH_SOURCE[0]}")/../infra/interbase` from a plugin's working directory will resolve to `plugins/interflux/../../infra/interbase` if the plugin's bump-version.sh calls interbump.sh directly — which is the actual invocation pattern.

More precisely: `${BASH_SOURCE[0]}` inside a sourced function refers to the file where the function is defined, not the caller. Since interbump.sh is a standalone script (not sourced), `BASH_SOURCE[0]` will be the path to interbump.sh itself (e.g., `/root/projects/Interverse/scripts/interbump.sh`). The path `$(dirname "${BASH_SOURCE[0]}")/..` becomes `/root/projects/Interverse/scripts/..` which resolves to `/root/projects/Interverse`. The final `infra/interbase` path resolves correctly.

However, the conditional `if [[ -f "$interbase_dir/install.sh" ]]; then` means that if this function runs from a plugin that has its own `.git` but is not under the Interverse monorepo (a plugin checked out standalone), it will silently skip the install with no indication. This is acceptable fail-open behavior, but it should be explicitly documented in the function comment.

**A deeper concern: should interbump install interbase at all?**

interbump is a publish pipeline — it bumps versions and pushes to the marketplace. Installing infrastructure to the developer's machine is a different concern. The side effect is appropriate for ensuring the developer's machine stays current, but it should be an opt-in behavior or run as a separate step rather than being embedded in the publish pipeline. The existing `post-bump.sh` hook mechanism (`POST_BUMP` in interbump.sh lines 110-118) is the right place for plugin-specific post-bump work. Installing interbase is a monorepo-level concern, not a plugin concern. Consider calling it from a monorepo-level `Makefile` or `scripts/install-infra.sh` instead, and removing it from interbump.

---

## 5. Task Ordering and Dependency Correctness

**Verdict: Ordering is mostly correct. Two dependency issues and one missing prerequisite.**

### Correct dependencies

- Tasks 1 (interbase.sh) and 2 (stub + schema templates) are independent and can proceed in parallel, but serializing them is fine.
- Task 3 (nudge protocol) correctly depends on Task 1 (core guards must exist before nudge is added).
- Task 4 (install.sh) correctly follows Task 1.
- Task 5 (unit tests) correctly follows Tasks 1, 2, 3 (tests cover all three).
- Task 6 (AGENTS.md) correctly follows everything.
- Task 7 (interflux integration.json) correctly follows Task 2 (template defines the schema).
- Task 8 (interflux hooks) correctly depends on Tasks 1-3 (the stub sourced in hooks must exist).
- Task 9 (test and validate) correctly follows Tasks 7 and 8.
- Task 10 (interbump update) is correctly positioned last in the infra track.
- Task 11 (docs update) correctly follows all implementation.

### Dependency issue 1: Task 3 test references `ib_in_ecosystem` as `_INTERBASE_SOURCE=="live"`, but this requires the guard fix.

The nudge test (Task 3, Step 1) sets up `CLAUDE_SESSION_ID` and sources interbase.sh directly (not via the stub). The test environment has no `~/.intermod/` because `export HOME="$TEST_HOME"`. This means the nudge fires from the direct source path, not the live path. The `ib_in_ecosystem()` check inside nudge (if nudge uses it) will return false because `_INTERBASE_SOURCE` is not set to "live" when sourced directly. The nudge test does not test the full path. This is acceptable for unit testing but should be noted in the test description.

### Dependency issue 2: Task 8 step 5 destructively modifies the developer's `~/.intermod/`.

Task 8, Step 5 runs:

```bash
mv ~/.intermod ~/.intermod.bak 2>/dev/null || true
bash plugins/interflux/hooks/session-start.sh 2>&1
mv ~/.intermod.bak ~/.intermod 2>/dev/null || true
```

This is a destructive mutation of the live `~/.intermod/` directory with no atomicity guarantee. If the test step fails mid-execution, `~/.intermod.bak` may be left in place and `~/.intermod/` absent, breaking the live ecosystem. The safe alternative is to use `INTERMOD_LIB=/dev/null` or `INTERMOD_LIB=/nonexistent/path` to simulate absence without touching the real directory:

```bash
INTERMOD_LIB=/dev/null bash plugins/interflux/hooks/session-start.sh 2>&1
```

This is already the documented dev-testing override mechanism (`INTERMOD_LIB` env var overrides the path). The plan should use it rather than renaming the live directory.

### Missing prerequisite: Task 8 assumes interflux has no existing hooks.

The plan creates `plugins/interflux/hooks/hooks.json` and `plugins/interflux/hooks/session-start.sh` as new files. The current interflux structure shows no `hooks/` directory (confirmed: Glob found no files under `plugins/interflux/hooks/`). This is fine. However, the plan does not check whether any existing interflux hook scripts contain inline guards that need to be replaced with `ib_*` calls (PRD F4: "Existing inline guards in interflux hooks replaced with `ib_*` calls"). The interflux CLAUDE.md states "Phase tracking is the caller's responsibility — interflux commands do not source lib-gates.sh," which suggests no existing guards exist. But the plan should include an explicit verification step rather than assuming.

### Task ordering gap: Task 9 Step 4 references "existing interflux tests."

The plan says "if tests exist, run them." The interflux test suite exists at `plugins/interflux/tests/test-budget.sh` (confirmed by Glob). This test should be listed explicitly in Task 9 rather than guarded with a conditional. The plan currently treats it as optional discovery rather than a required regression gate.

---

## 6. Additional Structural Findings

### `ib_session_status()` output goes to stderr, but the plan's session-start hook calls it unconditionally.

Task 8, Step 2 creates `session-start.sh` that calls `ib_session_status` for all users — both stub and live mode. In stub mode, `ib_session_status` is a no-op (returns 0, no output). In live mode it emits `[interverse] beads=... | ic=...` to stderr. This is the correct design per the PRD.

However, the hook is a SessionStart hook that runs on every session. A user who installs interflux but does not have the ecosystem will see nothing (correct). A user who has the ecosystem will see the status line on every session start. The plan should verify this is the intended user experience — the prior architecture review (Q5) flagged that the status line should be limited to what interbase.sh can determine from its own guards, not per-plugin mode display. The plan complies with this constraint (the status shows beads and ic state, not "interflux=standalone vs integrated"). This is acceptable.

### The `_ib_nudge_is_dismissed()` function uses `jq` without a guard.

The nudge protocol implementation (Task 3, Step 3) uses `jq` in `_ib_nudge_is_dismissed()` and `_ib_nudge_record()`. Each function has a `command -v jq &>/dev/null || return 1` guard. However, if jq is absent, `_ib_nudge_is_dismissed()` returns 1 (not dismissed), and nudge fires. On every call. Because the dismissal check fails open as "not dismissed," the nudge will repeatedly fire regardless of prior state when jq is missing.

The safer behavior when jq is absent is to return 0 from `_ib_nudge_is_dismissed()` (treat as dismissed — silently skip all nudging) rather than returning 1 (not dismissed — always fire). This matches the fail-open safety contract stated in the interbase.sh header: "Fail-open: all functions return safe defaults if dependencies missing."

### The `ib_has_companion()` implementation is fragile.

```bash
ib_has_companion() {
    local name="${1:-}"
    [[ -n "$name" ]] || return 1
    compgen -G "${HOME}/.claude/plugins/cache/*/${name}/*" &>/dev/null
}
```

This checks the Claude Code plugin cache directory structure, which is an internal implementation detail of Claude Code's plugin system. The path `~/.claude/plugins/cache/*/pluginname/` is correct for the current marketplace layout (confirmed in interverse troubleshooting docs: `CACHE_DIR="$HOME/.claude/plugins/cache/interagency-marketplace/$PLUGIN_NAME"`). However, the glob here uses `*/pluginname/*` (two wildcards — one for marketplace, one for version), while the actual structure is `marketplace-name/plugin-name/version/`. The extra wildcard level for version means the glob matches correctly only when a version directory exists inside the plugin name directory. This is the expected installed state. The risk is that a partially installed plugin (plugin name dir exists, no version dir) returns false (not installed), which is the correct behavior. No change needed, but this should be documented in AGENTS.md.

---

## 7. Scope Assessment

The plan's 11 tasks map cleanly to the 4 PRD features (F1 → Tasks 1, 4, 5; F2 → Task 2; F3 → Task 3; F4 → Tasks 7, 8, 9, 11; cross-cutting → Tasks 6, 10). No task touches components outside the stated goal. No task creates abstractions without an immediate consumer (interbase.sh is immediately consumed by interflux in Task 8). The interbump integration in Task 10 is the only questionable addition — it extends the publish pipeline with infrastructure-install side effects that belong in a separate script. That is the one scope concern.

The nudge protocol is proportionate: 60 lines of shell with clear state boundaries (`~/.config/interverse/`) and a defined budget. It does not require a separate module.

---

## Must-Fix Before Implementation

**M1 — Guard placement bug in stub template (Task 2).**

Set `_INTERBASE_LOADED=1` before the live source attempt, not only in the fallback path. Without this, two plugins in the same session will each re-source the live copy.

```bash
[[ -n "${_INTERBASE_LOADED:-}" ]] && return 0
_INTERBASE_LOADED=1   # Must be unconditional

_interbase_live="${INTERMOD_LIB:-${HOME}/.intermod/interbase/interbase.sh}"
if [[ -f "$_interbase_live" ]]; then
    _INTERBASE_SOURCE="live"
    source "$_interbase_live"
    return 0
fi
_INTERBASE_SOURCE="stub"
# ... fallback stubs ...
```

**M2 — Replace destructive mv test with INTERMOD_LIB override (Task 8, Step 5).**

Replace the `mv ~/.intermod ~/.intermod.bak` pattern with:

```bash
INTERMOD_LIB=/nonexistent bash plugins/interflux/hooks/session-start.sh 2>&1
```

The existing `INTERMOD_LIB` override mechanism exists precisely for this use case.

**M3 — Fix `_ib_nudge_is_dismissed` jq-absent behavior (Task 3).**

Change the fallback when jq is absent from `return 1` (not dismissed, nudge fires) to `return 0` (treated as dismissed, nudge silent). Add a symmetric guard to `_ib_nudge_session_count` to return a large number (e.g., 99) when jq is absent, ensuring the budget check also blocks nudging without jq.

---

## Should-Fix (Quality Improvements)

**S1 — Make Task 9 Step 4 explicit.**

Replace "ls tests/ 2>/dev/null && echo 'Run existing tests' || echo 'No existing test suite'" with the explicit test invocation `bash /root/projects/Interverse/plugins/interflux/tests/test-budget.sh`. The test exists and should be a required regression gate.

**S2 — Add `CLAUDE_SESSION_ID` absence handling to nudge (Task 3).**

When `CLAUDE_SESSION_ID` is empty, either disable nudging (safest) or use `$$` as a per-invocation session key rather than `unknown` (which accumulates across all standalone invocations).

**S3 — Move interbase install out of interbump (Task 10).**

Call `bash infra/interbase/install.sh` from a dedicated `scripts/install-infra.sh` or a `Makefile` target. Remove the `install_interbase()` function from interbump.sh. The publish pipeline should publish plugins, not mutate the developer's home directory.

**S4 — Add `integrated_features` object shape to the template.**

The template in Task 2, Step 2 shows `integrated_features: []`. Add a commented example object inside the array showing the `{feature, requires}` shape, or use a `$schema` reference comment, so contributors know the required structure.

**S5 — Task 8 should include an explicit check for inline guards to replace.**

Add a step: "Grep interflux hooks for existing `command -v ic`, `command -v bd`, or `ib_has_ic` patterns before adding stub sourcing, to identify any guards that need to be replaced." (Current structure shows no existing hooks, so this is likely a no-op, but the plan should verify rather than assume.)

---

## Nice-to-Have

**N1 — Document `ib_has_companion()` cache path assumption in AGENTS.md.**

Note the specific path pattern `~/.claude/plugins/cache/marketplace/plugin-name/version/` and the Claude Code internal convention dependency.

**N2 — Add `ib_in_ecosystem()` to the guard unit tests (Task 5).**

Currently the test covers `ib_in_sprint`, `ib_phase_set`, `ib_emit_event`, and `ib_session_status`. `ib_in_ecosystem()` is not covered despite being a documented guard function.

**N3 — Note `standalone_features` as display-only in AGENTS.md (Task 6).**

Prevents future feature-flag logic from being accidentally built on free-form prose strings.

---

## Conclusion

The plan is implementable as written after the three must-fix corrections. The centralized-copy + stub-fallback pattern is architecturally justified and has a working precedent in infra/interband. The integration.json schema is appropriately scoped. The nudge protocol belongs in interbase.sh. The install.sh → ~/.intermod/ deployment model is sound. Task ordering is correct with two execution-level fixes (guard placement, destructive mv). The one structural recommendation worth taking seriously before implementation: remove the interbase install from interbump and put it in a dedicated infrastructure script.
