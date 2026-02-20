# Architecture Review: Dual-Mode Plugin Architecture Brainstorm

**Document under review:** `/root/projects/Interverse/docs/brainstorms/2026-02-20-dual-mode-plugin-architecture-brainstorm.md`
**Reviewer:** Flux-drive Architecture & Design Reviewer
**Date:** 2026-02-20
**Mode:** Codebase-aware (CLAUDE.md, AGENTS.md, source code read across plugins/interphase, plugins/interlock, infra/interband, hub/clavain/hooks, scripts/interbump.sh)

---

## Executive Summary

The brainstorm is directionally correct about the core problem: ad-hoc per-plugin guards accumulate until every plugin is a slightly different reimplementation of the same degradation logic. The three proposals in the document — a shared interbase.sh library, a three-layer conceptual model, and an integration manifest in plugin.json — each have real merit and real problems. The user's intermod question deserves a serious answer because the codebase already has a precedent (interband) that makes the choice clearer than the brainstorm acknowledges.

The most important architectural finding: the vendored-interbase approach repeats the same duplication problem it claims to solve, just at a different level. And the "intermod" alternative the user asks about already partially exists as `~/.interband/` — an unacknowledged prior art case that changes the answer significantly.

---

## Finding F1 — Vendored interbase.sh creates a synchronization problem that is larger than the problem it solves

**Severity:** Must-fix (design)
**Section:** Key Decision 3, "Shared Integration SDK (interbase)"

The brainstorm proposes vendoring interbase.sh into each plugin at publish time via `interbump`. The stated rationale is "version-locked to the plugin's release — no compatibility matrix." This argument is circular. The goal is to reduce the blast radius when the ecosystem evolves. Vendoring does not reduce it — it shifts it from runtime to release-time, and makes it invisible.

### What the codebase already shows

The project already made this exact decision twice, in opposite directions:

**Decision 1 — Keep it vendored (interlock/lib.sh)**

`/root/projects/Interverse/plugins/interlock/hooks/lib.sh` is a self-contained utility library (curl wrappers, flag checks, git root finder). It is not shared with any other plugin. Its scope is narrow and stable: it wraps a single service's API. This is the correct scope for vendoring.

**Decision 2 — Shared library at a known path (infra/interband)**

`/root/projects/Interverse/infra/interband/lib/interband.sh` is already a shared library consumed by multiple plugins. `lib-gates.sh` in interphase loads it via a multi-candidate search path:

```bash
for candidate in \
    "${INTERBAND_LIB:-}" \
    "${_GATES_SCRIPT_DIR}/../../../infra/interband/lib/interband.sh" \
    "${_GATES_SCRIPT_DIR}/../../../interband/lib/interband.sh" \
    "${repo_root}/../interband/lib/interband.sh" \
    "${HOME}/.local/share/interband/lib/interband.sh"
do
    if [[ -n "$candidate" && -f "$candidate" ]]; then
        source "$candidate" && _GATE_INTERBAND_LOADED=1 && return 0
    fi
done
_GATE_INTERBAND_LOADED=0
```

This is already an intermod-style resolution pattern. It uses a canonical path, an environment variable override, and a fail-open fallback. It works today for interband. The brainstorm proposes solving the same problem with a different mechanism for interbase.

### The specific problem with vendoring interbase.sh

Suppose 20 plugins ship interbase.sh v1.2, and `ib_in_sprint()` has a bug that causes false negatives when `ic` is on PATH but the project has no active run. The fix requires a new release of every affected plugin. But:

1. `interbump` does not know which plugins have a stale interbase.sh — it only bumps versions, it does not audit library content.
2. Users with one installed plugin version and another installed plugin's interbase.sh will have inconsistent behavior depending on which plugin runs first.
3. The brainstorm's open question 5 ("Version pinning for vendored interbase.sh — do we handle version skew?") is in fact the core failure mode, not an open question.

### What the brainstorm gets right about the alternative

It correctly identifies that Claude Code has no plugin dependency resolution. A separate plugin for interbase would require install-order coordination that the platform cannot provide. This rules out the "separate plugin" option the brainstorm dismisses.

### Recommendation

The correct scope for interbase.sh is a shared library at a stable filesystem path, loaded with fail-open fallback identical to the interband pattern — not vendored into each plugin. The specifics follow in the intermod analysis (F4).

---

## Finding F2 — The three-layer model is a useful conceptual tool, not an implementation boundary

**Severity:** Advisory (complexity)
**Section:** Key Decision 1, "The Three-Layer Plugin Model"

The three layers (Standalone Core, Ecosystem Integration, Orchestrated Mode) are clearly described and map correctly to the actual variation in the plugin table. The concern is that the model conflates "conceptual layers" with "implementation layers" — and if the team treats them as implementation layers, it creates accidental complexity.

### The problem

The brainstorm says "every plugin has three conceptual layers." In practice, Layers 2 and 3 are not independent code sections — they are conditional branches inside Layer 1 code. A plugin does not have a `standalone/`, `ecosystem/`, and `orchestrated/` directory. It has one set of hooks that execute different branches depending on which guards pass.

The current guard pattern in the codebase demonstrates this:

```bash
# From interlock's session-start.sh (representative of current approach)
is_joined || exit 0
# ... all the coordination code follows
```

That is already a two-layer pattern. A three-layer model does not add structure; it adds three code paths that must be tested in combination (3! partial orderings for the three binary presence checks ic/bd/companion).

### What is actually needed

The brainstorm's own testing section reveals what the three layers require:

```bash
# test-standalone.sh — NO ecosystem tools installed
# test-integrated.sh — full ecosystem
# test-degradation.sh — partial ecosystem
```

This test matrix is the right deliverable from the three-layer model. The implementation does not need to know it is "layer 2" — it needs each guard to be a named, testable function (via interbase or equivalent) and each integration path to be one `if ib_has_ic; then ... fi` block. The value of the model is the test matrix enumeration, not a separate implementation per layer.

**Recommendation:** Keep the three-layer model as a documentation concept and test-matrix generator. Retire the idea that plugins must be structured around it at the code level. The existing guard-then-delegate pattern is the right implementation shape; the goal is to replace 20 copies of the guard functions with one canonical version loaded from a shared location.

---

## Finding F3 — Extending plugin.json with an "integration" section is the wrong contract point

**Severity:** Must-fix (boundary)
**Section:** Key Decision 2, "Integration Manifest (plugin.json Extension)"

The brainstorm proposes adding an `"integration"` key to plugin.json. The open question at the end of the document correctly identifies the risk: "risks schema conflicts with future Claude Code updates." This concern understates the problem.

### The actual boundary

`plugin.json` is a Claude Code platform schema. The Interverse project does not own it. Adding a top-level `"integration"` key to a schema owned by a third party creates three problems:

1. **Fragility:** If Claude Code ever uses `"integration"` for its own purposes (plugin interdependencies, platform-level feature flags), the Interverse key will conflict silently or be overwritten.
2. **Discoverability tool dependency:** The brainstorm says tooling (marketplace, `/doctor`, session-start) can read this field. That tooling lives in Clavain and the marketplace, not in Claude Code. Clavain reads plugin.json today only via `python3 -c "import json; json.load(open('.claude-plugin/plugin.json'))"` for validation. Reading Interverse-specific metadata from a platform-schema file creates coupling between ecosystem tooling and the platform schema version.
3. **Standalone user confusion:** A user who reads their plugin.json to understand its configuration will find an `"integration"` key that Claude Code's own documentation does not explain. It creates a two-audience schema problem in a file that is already confusing.

The brainstorm's own parenthetical — "A separate integration.json is safer but adds file bloat" — is the correct answer, and "file bloat" is not a real cost.

### Recommendation

Use `integration.json` (or `.claude-plugin/integration.json` alongside `plugin.json`) as a separate file, owned entirely by the Interverse ecosystem. It carries no risk of Claude Code schema conflict, it is clearly Interverse-specific to anyone reading it, and it is trivially extensible. The "file bloat" concern is not architectural — it is one 20-line JSON file per plugin. The existing codebase already has `.claude-plugin/plugin.json`, `CLAUDE.md`, `AGENTS.md`, and `hooks/hooks.json` as separate concerns; adding `integration.json` is consistent, not bloated.

---

## Finding F4 — The intermod alternative deserves adoption, not dismissal, because the codebase already has one

**Severity:** Must-fix (design decision)
**Section:** "Why not have an intermod folder/container?" (user question)

The user asks: why not a `~/.intermod/` directory, analogous to `~/.claude/plugins/`, where shared modules live and plugins source from?

The honest answer is: the project already does this, and calls it `~/.interband/`. The question reveals that the interband precedent was not generalized when it was established.

### What interband demonstrates

`~/.interband/` is a runtime directory owned by the Interverse ecosystem, not by Claude Code. Its structure:

```
~/.interband/
  interphase/
    bead/
      {session_id}.json
  interlock/
    coordination/
      {session_id}.json
  clavain/
    dispatch/
      {session_id}.json
```

This is precisely the `~/.intermod/` pattern the user describes — a namespaced directory under a well-known home path, organized by producer, consumed by readers who know the path convention.

The `_gate_load_interband()` function in `lib-gates.sh` shows that the pattern already resolves library code at runtime from a known location, with INTERBAND_LIB environment variable override for development. This is the exact mechanism interbase would need.

### The intermod pattern applied to interbase

Concrete proposal:

**Location:** `~/.intermod/interbase/interbase.sh` (installed by interbump or a setup script)

**Load pattern (matching interband precedent):**

```bash
_ib_load() {
    [[ "${_IB_LOADED:-0}" -eq 1 ]] && return 0
    local candidate
    for candidate in \
        "${INTERMOD_LIB:-}" \
        "${HOME}/.intermod/interbase/interbase.sh" \
        "${HOME}/.local/share/intermod/interbase/interbase.sh" \
        "/root/projects/Interverse/sdk/interbase/interbase.sh"
    do
        if [[ -n "$candidate" && -f "$candidate" ]]; then
            source "$candidate" && _IB_LOADED=1 && return 0
        fi
    done
    _IB_LOADED=0
    return 1
}
```

**Installation:** `interbump` already walks up from plugin roots to find `infra/marketplace`. It can equally install `sdk/interbase/interbase.sh` to `~/.intermod/interbase/interbase.sh` during `post-bump.sh` or as a precondition step.

**Degradation behavior:** If `~/.intermod/interbase/interbase.sh` is not present, `_ib_load` returns 1. Every consumer wraps it the same way interband is wrapped: `_ib_load || return 0`. The plugin falls back to its existing inline guards. This means the migration to interbase can be incremental — plugins adopt it as they are published, and the ecosystem works during the transition.

### Why this is strictly better than vendoring

| Property | Vendored interbase.sh | ~/.intermod/interbase.sh |
|----------|----------------------|--------------------------|
| Bug fix reaches all plugins | No (requires re-releasing each plugin) | Yes (update one file) |
| Version skew possible | Yes (per-plugin freeze) | No (one canonical version) |
| Install-order problem | No | No (loaded at runtime, not install) |
| Works without network | Yes | Yes (local file) |
| Precedent in this codebase | No | Yes (interband) |
| Standalone user awareness | None (internal) | None (installed by ecosystem toolchain) |
| Developer override | No | Yes (INTERMOD_LIB env var) |

The only argument for vendoring over `~/.intermod/` is "standalone users never know it exists." But standalone users also never know about `~/.interband/` — it is created by interphase's session-start hook on first run, not by a separate install step. The same approach applies to interbase.

### One real concern about intermod

The interband pattern for data files (JSON sideband state) is different from what interbase needs (executable shell code). Sourcing shell code from a user's home directory is a security surface: if `~/.intermod/interbase/interbase.sh` is writable by a process that should not be writing it, all plugins that source it are compromised. This is the same concern that applies to sourcing any library from a user-writable path. The mitigation is the same: the `interbump`/install path should `chmod 644` the file, and the existing ACL infrastructure the CLAUDE.md documents (for `claude-user` isolation) should apply.

---

## Finding F5 — Per-plugin standalone percentages are mostly calibrated correctly, with one exception that matters

**Severity:** Advisory
**Section:** "Per-Plugin Standalone Assessment"

The table is honest about the hard cases. The standalone % targets hold up against the actual plugin purposes:

- tldr-swinton at 100% is correct. Its value (token-efficient code context) is entirely self-contained.
- interflux at 90% is plausible. Multi-agent code review works without phase tracking or sprint integration. The 10% gap is real: bead-linked findings lose their destination without beads.
- interfluence at 95% is accurate. Voice profile adaptation is inherently standalone.
- interlock at 30% is the correct and honest assessment — and the most important number in the table.

### The interlock problem is an architecture problem, not a percentage problem

The brainstorm says interlock at 30% standalone is a "poor marketplace experience" and lists three options: don't publish standalone, build local-only mode, mark as ecosystem-only. This framing understates the structural problem.

Interlock's standalone value at 30% is not a feature gap — it is a fundamental scope mismatch. Interlock wraps intermute's HTTP API. Without intermute (the Go service), interlock has no server to call. Its MCP tools (`reserve_files`, `check_conflicts`, `negotiate_release`) all make HTTP calls to `http://127.0.0.1:7338`. A standalone user who installs interlock and runs `/interlock:reserve` will get `curl: (7) Failed to connect to 127.0.0.1 port 7338`.

The three options the brainstorm lists are all valid. But there is a fourth option the brainstorm does not consider: **do not publish interlock to the public marketplace at all, and distribute it only as a Clavain companion**. The existing marketplace already has an install path through Clavain — users who install Clavain get a companion recommendation list. Interlock could live exclusively in that companion list without a public standalone listing. This avoids the bad first-impression problem (user installs, gets connection refused on every tool call) without building a local-only mode that would be architecturally misleading (interlock's purpose is coordination, not local tracking).

### interphase at 20% deserves the same question

Interphase's 20% standalone value is the same structural issue from the other direction: phase tracking without beads (`bd`) stores phase in what? The brainstorm says "provide lightweight phase tracking even without beads" but does not say where the state goes. The correct answer is a local JSON file (similar to how interband writes to `~/.interband/`) — but that is a meaningful implementation task, not a percentage calibration. The brainstorm should either scope this explicitly or acknowledge interphase as ecosystem-only in the same way as interlock.

---

## Finding F6 — The companion nudge protocol is well-designed but needs a suppression mechanism that does not rely on session temp files

**Severity:** Advisory
**Section:** Key Decision 4, "Companion Nudge Protocol"

The nudge-once-per-session rule using a temp file is correct for the common case. The failure mode is: if Claude Code runs hooks as isolated subprocess calls (which it does — hooks are exec'd, not sourced into a persistent shell), a temp file keyed on session ID works only if the session ID is stable and the hook reads/writes the same temp path on every invocation.

The Claude Code hooks execute in ephemeral shell subprocesses. A `SESSION_TEMP=/tmp/interverse-nudge-${CLAUDE_SESSION_ID}` file written by a PreToolUse hook will persist across invocations in the same session, because it is a real file at a stable path. This is correct. The pattern already works in `_gate_update_statusline` in `lib-gates.sh` (line 494: `local state_file="/tmp/clavain-bead-${session_id}.json"`).

The only edge case is parallel hook execution — if two hooks run simultaneously in the same session and both check for the nudge flag before either writes it, both nudge. This is a low-frequency annoyance, not a correctness problem. The existing interband prune mechanism shows the project is aware of concurrent file access patterns. A `touch` atomicity idiom (`[[ ! -f "$flag" ]] && touch "$flag" 2>/dev/null && echo_nudge`) handles this without a lock.

---

## What the Brainstorm Gets Right

These positions should be preserved in planning:

1. **The problem statement is accurate.** Twenty plugins with ad-hoc guard patterns is a real maintenance liability. The blast radius of a kernel change (intercore E3 hook cutover, E6 rollback) propagating to every companion plugin is documented by the MEMORY.md and the E6 review this very session.

2. **"Not a plugin" is the right answer for the shared library.** Claude Code has no dependency resolution, and a separate plugin would require user-level install coordination that the platform cannot provide. The shared library should be distributed via the existing install toolchain (interbump/post-bump hooks).

3. **Testing architecture is the most valuable deliverable.** The `test-standalone.sh` / `test-integrated.sh` / `test-degradation.sh` matrix is immediately actionable and solves the "testing matrix grows with every integration point" problem regardless of which shared library approach is chosen.

4. **Integrated-first is the correct primary design constraint.** The ecosystem is the product. Standalone is a discovery and adoption path, not the primary feature surface.

5. **interbase.sh content is correctly scoped.** The proposed functions (`ib_has_ic`, `ib_has_bd`, `ib_in_sprint`, `ib_phase_set`, `ib_nudge_companion`, `ib_emit_event`) are the right abstraction level — guards and telemetry helpers, not business logic. No plugin-specific workflow code belongs in interbase.

---

## Recommendations Summary

| Finding | Severity | Recommendation |
|---------|----------|----------------|
| F1: Vendored interbase creates synchronization problem | Must-fix | Use `~/.intermod/interbase/interbase.sh` with fail-open load pattern, matching interband precedent |
| F2: Three-layer model as implementation structure creates complexity | Advisory | Keep as documentation concept and test-matrix generator only; implementation stays guard-then-delegate |
| F3: plugin.json extension risks schema conflict with Claude Code | Must-fix | Use `integration.json` as a separate Interverse-owned file |
| F4: Intermod alternative already exists as interband | Must-fix | Generalize interband's `~/.interband/` pattern into `~/.intermod/` for library distribution |
| F5: interlock at 30% and interphase at 20% are structural, not calibration issues | Advisory | Consider Clavain-companion-only distribution for interlock; scope a local state store for interphase standalone mode |
| F6: Nudge temp file approach is correct but needs concurrent-write guard | Advisory | Add `touch`-based atomic flag check to prevent duplicate nudges from parallel hook execution |

---

## Sequencing

If this brainstorm moves to planning, the smallest viable change that delivers the core value:

1. Establish `sdk/interbase/` in the monorepo with `interbase.sh` — identical scope to the brainstorm's function list.
2. Add a `post-bump.sh` hook to `interbump` that installs `~/.intermod/interbase/interbase.sh` on each plugin publish. This is a one-time addition to the existing publish pipeline.
3. Add `integration.json` schema definition (not plugin.json extension) — one file in `sdk/interbase/` as the canonical schema, one instance per plugin.
4. Migrate one plugin (interflux, the 90% standalone case) end-to-end as a reference implementation.
5. Update `intertest`'s test scaffolding to provide the three-mode test harness. All other plugins adopt it as they are published.

Steps 1-3 are a single PR per component. Step 4 validates the approach. Step 5 is the ongoing migration path. No plugin needs to be disrupted before its next natural publish cycle.
