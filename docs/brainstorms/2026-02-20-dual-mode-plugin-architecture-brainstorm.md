# Dual-Mode Plugin Architecture

**Bead:** iv-gcu2

How Interverse modules serve two audiences — standalone Claude Code users and integrated Clavain/Intercore users — without degrading either experience.

> **Revision:** Updated 2026-02-20 with findings from 4-agent review (fd-architecture, fd-user-product, fd-systems, fd-decisions). See `docs/research/synthesize-review-findings.md` for full synthesis.

## What We're Building

An architectural pattern and supporting infrastructure that lets each Interverse plugin work as a **standalone Claude Code plugin** (core features, genuinely useful alone) while also being a **power module** in the integrated ecosystem (phase tracking, cross-plugin coordination, sprint lifecycle, bead management, kernel events).

Plugins are ecosystem-aware: they know they're part of Interverse, suggest companions, and declare their integration surface. But their core value prop never depends on the ecosystem.

## Why This Approach

### The Tension

Today, every plugin uses ad-hoc fail-open guards (`command -v bd || return 0`, `is_joined || exit 0`, `[[ -n "$INTERMUTE_AGENT_ID" ]] || exit 0`). This works — no plugin crashes without dependencies. But it creates four compounding problems:

1. **Feature duplication** — 20+ plugins each re-implement the same guard patterns, bead query helpers, phase tracking stubs, and degradation logic. The same 15-30 lines of shell appear in every `lib.sh`.

2. **Upgrade friction** — When intercore evolves (E3 hook cutover, E6 rollback), every companion plugin's integration layer needs updating. The blast radius of a kernel change is proportional to the companion count.

3. **Discoverability gap** — A user installs interflux and gets code reviews. They don't know that installing interphase would give them phase tracking, or that interwatch would auto-trigger reviews on drift. The standalone experience silently lacks capabilities the user doesn't know exist.

4. **Testing complexity** — Each plugin must be tested in both standalone mode AND integrated mode AND various partial-integration states (beads but no ic, ic but no Clavain, etc.). The matrix grows with every new integration point.

### Design Constraints

- **Integrated-first** — The Interverse ecosystem is the primary product. Standalone is a gateway.
- **Standalone must be genuinely useful** — Not a demo version. A user who installs interflux alone should get real code reviews, not a crippled experience.
- **Ecosystem-aware** — Plugins know about Interverse. They suggest companions, declare integration surfaces, and participate in discovery.
- **Per-plugin calibration** — Some plugins are 95% standalone (tldr-swinton). Others are low standalone (interlock). The architecture must accommodate this range, including deciding which plugins shouldn't be published standalone at all.

## Key Decisions

### 1. The Three-Layer Plugin Model

Every plugin has three conceptual layers. These are a **documentation and testing concept**, not implementation boundaries — in code, they remain conditional branches inside hooks using guard-then-delegate patterns.

**Layer 1: Standalone Core** — The plugin's primary value prop. Works with zero external dependencies. This is what a marketplace user gets.
- interflux: multi-agent code review
- interwatch: doc drift detection + scoring
- tldr-swinton: token-efficient code context
- interstat: token usage measurement
- interfluence: voice profile adaptation

**Layer 2: Ecosystem Integration** — Lights up when companions or ic/beads are detected. Adds cross-cutting capabilities.
- Phase tracking (interphase)
- Bead lifecycle (beads)
- Sprint state (intercore runs)
- Cross-plugin events (kernel event bus)
- Companion discovery + nudges

**Layer 3: Orchestrated Mode** — Full Clavain integration. The plugin participates in sprint workflows, gate enforcement, auto-advance, and multi-agent coordination.
- Sprint skill routing
- Quality gate enforcement
- Agent dispatch and tracking
- Checkpoint recovery
- Session handoff

### 2. Integration Manifest (`integration.json` — Separate from `plugin.json`)

> **Review finding (P1-B):** Extending `plugin.json` with an `"integration"` key risks schema collision with future Claude Code platform changes. Use a separate Interverse-owned file instead. Precedent: the codebase already separates platform-owned schemas (`plugin.json`) from ecosystem-specific metadata.

Each plugin declares its ecosystem surface in `.claude-plugin/integration.json`:

```json
{
  "ecosystem": "interverse",
  "interbase_version": "1.0.0",
  "standalone_features": [
    "Multi-agent code review (fd-architecture, fd-quality, fd-correctness, fd-safety)",
    "Document review with automatic agent triage",
    "Research orchestration with parallel agents"
  ],
  "integrated_features": [
    { "feature": "Phase tracking on review completion", "requires": "interphase" },
    { "feature": "Sprint gate enforcement", "requires": "intercore" },
    { "feature": "Bead-linked review findings", "requires": "beads" },
    { "feature": "Auto-review on doc drift", "requires": "interwatch" }
  ],
  "companions": {
    "recommended": ["interphase", "interwatch"],
    "optional": ["intercore", "interstat"]
  }
}
```

This serves three purposes:
- **Discoverability**: tooling (marketplace, `/doctor`, session-start) can read this and suggest missing companions
- **Documentation**: users see what they gain from each companion
- **Testing**: the integration matrix is explicit and enumerable

### 3. Shared Integration SDK — Centralized `~/.intermod/` with Stub Fallback

> **Review finding (P1-A, P1-C):** Vendoring interbase.sh into every plugin creates a compounding drift loop — slow-publishing plugins accumulate stale guards that silently degrade. The `~/.interband/` pattern already proves the centralized-with-fallback approach works. The user's "intermod" idea generalizes interband from data to code.

**Architecture: Stub-Plus-Live-Discovery Hybrid**

Each plugin ships a **minimal stub** (~10 lines) that provides zero-dep guard functions. At runtime, if `~/.intermod/interbase/interbase.sh` exists, the plugin sources the live centralized copy instead. This gives both guarantees:
- **Standalone users** get functional stubs — zero install friction, no silent failures
- **Ecosystem users** get live updates — one `interbase.sh` update reaches all plugins immediately

```bash
# hooks/interbase-stub.sh — shipped inside each plugin (~10 lines)
# Minimal guards for standalone operation. Overridden by ~/.intermod/ if present.

[[ -n "${_INTERBASE_LOADED:-}" ]] && return 0

# Try centralized copy first (ecosystem users)
_interbase_live="${INTERMOD_LIB:-${HOME}/.intermod/interbase/interbase.sh}"
if [[ -f "$_interbase_live" ]]; then
    source "$_interbase_live"
    return 0
fi

# Fallback: inline stubs (standalone users)
_INTERBASE_LOADED=1
ib_has_ic()          { command -v ic &>/dev/null; }
ib_has_bd()          { command -v bd &>/dev/null; }
ib_has_companion()   { [[ -d "${HOME}/.claude/plugins/cache/"*"/$1/"* ]] 2>/dev/null; }
ib_in_ecosystem()    { [[ -f "${HOME}/.intermod/interbase/interbase.sh" ]]; }
ib_get_bead()        { echo "${CLAVAIN_BEAD_ID:-}"; }
ib_in_sprint()       { return 1; }  # standalone: never in sprint
ib_phase_set()       { return 0; }  # no-op
ib_nudge_companion() { return 0; }  # no-op in stub — nudges live in centralized copy only
ib_emit_event()      { return 0; }  # no-op
```

**The centralized `~/.intermod/interbase/interbase.sh`** is the full implementation with:
- All guard functions (matching stub signatures)
- Phase tracking helpers
- Nudge protocol (see Decision 4)
- Event emission
- Session status reporting
- Version metadata for compatibility checks

**Why this pattern works (proven by interband):**

The `_load_interband_lib` pattern in `hub/clavain/scripts/dispatch.sh` already demonstrates this exact approach:
1. Check env override (`INTERBAND_LIB`)
2. Try monorepo-relative paths
3. Fall back to `~/.local/share/interband/lib/interband.sh`
4. Fail open if nothing found

The intermod pattern generalizes this: interband handles **data** (JSON sideband state), interbase handles **code** (shell library). Both use filesystem-path resolution with fail-open degradation.

**`~/.intermod/` directory structure:**

```
~/.intermod/
├── interbase/
│   ├── interbase.sh          # Full integration SDK
│   └── VERSION               # Semantic version for compatibility checks
├── interband/                 # (future: consolidate interband here)
│   └── interband.sh
└── manifest.json              # Registry of installed modules + versions
```

**Installation:** `interbump` installs `~/.intermod/interbase/interbase.sh` from the canonical `infra/interbase/` location at plugin publish time. The `clavain:setup` skill can also install/update it.

**Developer override:** `INTERMOD_LIB=/path/to/dev/interbase.sh` for testing unpublished versions.

**Security note:** Sourcing executable code from a user-writable path is a security surface. Mitigation matches the existing system: `interbump` installs with `chmod 644`, and the POSIX ACL infrastructure already covers `~/.intermod/`.

### 4. Companion Nudge Protocol

> **Review finding (BLOCKING-02):** The original nudge spec was critically underspecified — missing trigger event, durable state, action instructions, aggregate budget, and cobra effect mitigation.

When a plugin detects it could do more with a missing companion, it emits a one-time nudge.

**Nudge specification:**

| Aspect | Decision |
|--------|----------|
| **Trigger event** | First successful operation completion (e.g., first review done, first drift scan). User has context and is receptive. NOT session-start (no context). |
| **Durable state** | `~/.config/interverse/nudge-state.json` keyed by `plugin:companion` pair. Survives across sessions. |
| **Nudge text** | `"[interverse] Tip: run /plugin install {companion} for {benefit}."` — includes actionable install command. |
| **Dismissal** | Once companion installed (via `ib_has_companion()`), never nudge again. After 3 ignores for the same pair, mark dismissed and stop. |
| **Aggregate budget** | Session-level: max 2 nudges per session across ALL plugins. Coordinator checks `~/.config/interverse/nudge-session-${CLAUDE_SESSION_ID}.json`. |
| **Output channel** | stderr (hook output). Never blocks workflow. |
| **Concurrency** | Atomic touch pattern: `[[ ! -f "$flag" ]] && touch "$flag" 2>/dev/null && echo_nudge` prevents duplicate nudges from parallel hooks. |

**Important:** Nudge logic lives in the centralized `interbase.sh` only, NOT in stubs. Standalone users don't get nudges (they don't have `~/.intermod/`). This is correct — nudging requires ecosystem awareness to be meaningful, and it avoids the pace-layer inversion problem (nudge text updates don't require re-publishing plugins).

### 5. Testing Architecture

The integration manifest enables a standardized test matrix:

```bash
# test-standalone.sh — runs in CI with NO ecosystem tools installed
# Verifies: all standalone_features work, no errors from missing deps
# Verifies: stub interbase functions return safe defaults

# test-integrated.sh — runs with full ecosystem
# Verifies: all integrated_features activate correctly
# Verifies: centralized interbase.sh is sourced over stubs

# test-degradation.sh — runs with partial ecosystem (each companion individually)
# Verifies: each integration point degrades gracefully when its specific companion is absent
```

> **Review finding (P1-SYS-B):** "Test interbase once, trust it everywhere" is a reductionist claim. Individual plugins layer local rules on top of interbase.sh — they may override guards, skip calls, or assume specific guard behaviors. Testing the base in isolation does NOT guarantee correct aggregate behavior.

**Additional required test level:**

```bash
# test-session.sh — loads multiple plugins simultaneously
# Verifies: all plugins source the same interbase.sh version (centralized)
# Verifies: no signature mismatches across plugins calling the same function
# Verifies: simulated version skew scenarios produce warnings, not silent degradation
```

The centralized `~/.intermod/` approach makes session-level testing far simpler than vendoring would — all plugins always share the same copy, eliminating version skew as a failure mode for ecosystem users.

### 6. Per-Plugin Standalone Assessment

> **Review finding (BLOCKING-01):** Plugins below 50% standalone need product decisions, not just percentage recalibration. Publishing a low-standalone plugin to the marketplace creates lasting negative perception (hysteresis — bad first impressions persist even after improvements).

| Plugin | Standalone % | Core Value (standalone) | Power Features (integrated) | Product Decision |
|--------|-------------|------------------------|----------------------------|-----------------|
| tldr-swinton | 100% | Token-efficient code context | None needed | Publish standalone |
| interfluence | 95% | Voice profile adaptation | Session context from Clavain | Publish standalone |
| interflux | 90% | Multi-agent code review | Phase tracking, sprint gates, bead-linked findings | Publish standalone |
| interject | 70%* | Ambient discovery + research | Bead creation for findings, persistent output | Publish standalone |
| interwatch | 75% | Doc drift detection + scoring | Auto-refresh via interpath, bead filing | Publish standalone |
| interstat | 70% | Token usage measurement | Sprint budget integration, ic token writeback | Publish standalone |
| interline | 40% | Basic statusline | Bead context, phase display, agent count | Build local statusline value OR ecosystem-only |
| interlock | 30% | Local file tracking only | Multi-agent coordination via intermute | **Ecosystem-only** — don't publish standalone |
| interphase | 20% | Phase state display only | Gate enforcement, sprint integration, Clavain shims | **Ecosystem-only** — don't publish standalone |

*interject recalibrated from 90% to 70%: without beads, research findings produce throwaway stdout with no persistent store. Valuable but degraded.

**Product decisions for sub-50% plugins:**
- **interlock** → Ecosystem-only. File coordination without intermute is not useful. Bundle it with Clavain modpack, not published as standalone marketplace plugin.
- **interphase** → Ecosystem-only. Phase tracking without beads has no state store. Core value requires the ecosystem. Bundle with Clavain modpack.
- **interline** → Build meaningful standalone mode: show git branch, test status, recent errors as a general-purpose statusline. If standalone value stays below 50%, make ecosystem-only.

### 7. Session Status Line

> **Review finding (P2-B):** Users have no visibility into which integration mode is active. Session-start hook should emit a structured status line.

When interbase.sh is sourced (centralized copy only), session-start emits:

```
[interverse] interflux=standalone | beads=active | ic=not-detected | 2 companions available
```

One line. Machine-parseable. Appears once per session. Shows: each installed plugin's mode (standalone/integrated/orchestrated), detected ecosystem tools, count of recommended companions not yet installed.

## Resolved Questions

These were open questions in the original brainstorm, now resolved by review:

1. **Where does interbase.sh live?** `infra/interbase/` in the monorepo (canonical source). Published to `~/.intermod/interbase/interbase.sh` at install time. Each plugin ships a minimal stub that sources the centralized copy if present.

2. **How aggressive should nudges be?** Max 2 per session across all plugins. Trigger on first successful operation (not session-start). Durable state prevents indefinite repetition. See Decision 4 for full spec.

3. **plugin.json extension or separate file?** Separate file: `.claude-plugin/integration.json`. No risk of Claude Code schema conflict.

4. **How do we handle interlock/interphase?** Ecosystem-only — don't publish to marketplace as standalone plugins. Bundle with Clavain modpack.

5. **Version pinning for interbase.sh?** Not needed with the centralized approach. All ecosystem plugins source the same copy. Standalone users have stubs that provide safe defaults. The `VERSION` file in `~/.intermod/interbase/` enables compatibility checks if needed.

## Remaining Open Questions

1. **Marketplace manifest drift** — Plugin descriptions in `marketplace.json` are manually maintained and already stale. Should `interbump` auto-generate descriptions from `plugin.json` + `integration.json`? Or should descriptions be stable text that doesn't enumerate counts?

2. **Migration sequencing** — Which plugin gets the dual-mode treatment first? interflux (90% standalone, cleanest case) is the obvious reference implementation. But should we build `infra/interbase/` and `~/.intermod/` infrastructure first, or migrate interflux and extract the pattern?

3. **Interband consolidation** — Should `~/.interband/` eventually move under `~/.intermod/` for consistency? The interband protocol is stable and works; migration is low priority but the inconsistency is worth acknowledging.

4. **Session-level test harness** — How do we practically load multiple plugins in a test Claude Code session? The test infrastructure for session-level integration testing doesn't exist yet.
