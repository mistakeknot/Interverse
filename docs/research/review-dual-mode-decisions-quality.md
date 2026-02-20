# Decision Quality Review — Dual-Mode Plugin Architecture Brainstorm

Reviewer: fd-decisions
Date: 2026-02-20
Document: /root/projects/Interverse/docs/brainstorms/2026-02-20-dual-mode-plugin-architecture-brainstorm.md
Mode: Codebase-aware (CLAUDE.md + AGENTS.md present, Interverse monorepo context applied)

---

## Findings Index

| SEVERITY | ID | Section | Title |
|----------|----|---------|-------|
| P1 | D-01 | Section 3 — Shared Integration SDK | Anchoring on npm/Go vendoring patterns that may not apply to the plugin runtime model |
| P1 | D-02 | Section 3 — "Why not a separate plugin" | Centralized container alternative dismissed without evaluation |
| P2 | D-03 | Section 3 — "Why vendored, not a plugin dependency" | False dichotomy between vendoring and centralized container; hybrid not explored |
| P2 | D-04 | Section 5 — Testing Architecture | Sunk cost anchor on fail-open pattern suppresses pre-mortem on interbase.sh becoming a new failure point |
| P3 | D-05 | Section 2 — Open Questions (Q5) | Version skew treated as an open question without reversibility analysis |
| P3 | D-06 | Section 1 — Per-Plugin Standalone Assessment | Explore/exploit imbalance: ecosystem-first framing may foreclose standalone learning signal |

---

## Summary

The brainstorm is well-structured and internally consistent. It correctly identifies the core tension — ad-hoc fail-open guards spread across 20+ plugins — and proposes three coherent mechanisms to address it: the three-layer model, the integration manifest, and the vendored interbase.sh SDK. The decision process, however, has three significant gaps. First, the vendoring recommendation is anchored so tightly on npm/Go precedent that it never tests whether that precedent applies: Claude Code plugins do not have a build step, do not have a lockfile, and are deployed by copying a directory into `~/.claude/plugins/cache/` — properties that make the centralized container model qualitatively different here compared to npm or Go. Second, the user's specific alternative hypothesis — "why not an intermod folder similar to the Claude Code plugin folder?" — is rejected in a single sentence without any evaluation of its actual tradeoffs against vendoring. This is a P1 blind spot because the centralized container and vendoring have an inverted risk profile depending on update frequency and the number of plugins, and the document commits to vendoring before establishing which scenario applies. Third, the fail-open pattern that "already works" receives implicit sunk-cost protection — the brainstorm acknowledges it as the status quo but never asks what would have to be true for interbase.sh to make things meaningfully worse.

---

## Issues Found

### D-01. P1: Anchoring on npm/Go vendoring patterns that may not apply to the plugin runtime model

**Section:** "Why vendored, not a plugin dependency" (Section 3)

**Lens applied:** Sour Spots — combinations that look promising but deliver the worst of both worlds.

The brainstorm justifies vendoring by citing npm and Go as precedents: "Vendoring is the npm/Go pattern for this exact problem." These ecosystems share a defining characteristic that the Claude Code plugin ecosystem does not: they have a build step and an artifact boundary. In npm, vendored dependencies are isolated per package in `node_modules/` and updated by running `npm install`. In Go, vendored code is checked into `vendor/` and updated by running `go mod vendor`. Both give you a reproducible, automated propagation mechanism — the "update via interbump at publish time" step.

The Claude Code plugin ecosystem has a different property: plugins are installed as directories copied into `~/.claude/plugins/cache/`. There is no build step and no lockfile. When a plugin is installed from the marketplace, the vendored interbase.sh is whatever was baked in at publish time. This is correct for the "version-locked to the plugin's release" goal — but it creates a sour spot: the benefits of vendoring (no install-order problem, version isolation) are real, but so are the costs that npm/Go vendoring avoids through tooling:

- In npm/Go, "update the vendor copy" is a single command that runs across all consumers automatically. In this ecosystem, it requires `interbump` to touch every plugin individually and every plugin to be re-published to the marketplace.
- In npm/Go, a user gets the latest vendored version when they run install. In this ecosystem, a user who installed interflux six months ago has interbase.sh v1.0 and will not receive interbase.sh v1.5 updates until they explicitly reinstall interflux — even if interbase.sh v1.5 fixes a critical bug in `ib_emit_event`.

The question the brainstorm does not ask: what is the update velocity of interbase.sh? If it changes frequently (because intercore evolves, as the document itself notes is a problem), vendoring replicates the upgrade friction problem at a new layer — now every plugin must be re-published every time interbase.sh changes, rather than every time intercore's API changes. If it changes rarely (because the guards are stable and additive), centralized container and vendoring converge in practice and the choice is low-stakes.

**What to ask before committing:** How often is the current fail-open guard code (the `command -v bd || return 0` pattern) expected to change as intercore evolves? If the answer is "whenever the kernel cuts over, like E3," then vendoring may replicate rather than solve the upgrade friction problem.

---

### D-02. P1: Centralized container alternative dismissed without evaluation

**Section:** "Why not a separate plugin" (Section 3, two-bullet dismissal)

**Lens applied:** Cone of Uncertainty — the range of possible outcomes narrows as you gather information. The document narrows to vendoring before the relevant uncertainties (update frequency, plugin install behavior, user demographics) are resolved.

The brainstorm dismisses the centralized container alternative in exactly two bullets:
1. "Claude Code has no plugin dependency resolution"
2. "A separate plugin adds install friction for standalone users"

The user's question — "why not an intermod folder similar to the Claude Code plugin folder?" — describes a different model than "a separate plugin." A centralized container like `~/.intermod/interbase.sh` or `~/.claude/interverse/interbase.sh` is not a Claude Code plugin. It does not require Claude Code's dependency resolution. It is a known filesystem path that hook scripts source directly:

```bash
# In any plugin's hooks/lib.sh:
INTERBASE="${HOME}/.intermod/interbase.sh"
if [[ -f "$INTERBASE" ]]; then
    source "$INTERBASE"
else
    # fallback stubs inline, or fail-open
fi
```

This is closer to how `/usr/local/bin/` or `~/.local/lib/` works — a user-space installation target, not a package manager concept. The Claude Code plugin folder itself (`~/.claude/plugins/cache/`) uses exactly this model: tools discover plugins by scanning a known directory path, not through a dependency resolver. The intermod container would be the same pattern applied to shared libraries rather than plugins.

The dismissed alternative has a meaningfully different tradeoff profile that was not surfaced:

| Property | Vendoring | Centralized Container |
|----------|-----------|----------------------|
| Install friction (standalone user) | Zero — ships inside plugin | Low — requires one additional install step, or auto-install via a bootstrap hook |
| Update model | Per-plugin re-publish | Single update propagates to all installed plugins immediately |
| Version skew risk | Each plugin locks its version; 20+ copies diverge over time | One authoritative version; all plugins use same version |
| Failure mode | Bug in vendored copy is silent until user reinstalls plugin | Bug in centralized copy affects all plugins simultaneously |
| Interbase.sh size growth | Grows proportionally with plugin count * interbase size | Grows once |
| Bootstrap in new environment | Zero-config | Requires interbase to be installed before plugins source it |

The centralized container is strictly better on update propagation and version coherence, and strictly worse on bootstrap and blast radius. Neither dominates — the right choice depends on empirical facts about the ecosystem (update frequency, how often users install plugins in isolation vs. as a suite) that the brainstorm does not gather before deciding.

**What to ask before committing:** What percentage of expected users install a single standalone plugin vs. the full Interverse suite? If 80% install the full suite, a centralized container with a one-time bootstrap is a better fit. If 80% install single plugins, vendoring's zero-config property wins.

---

### D-03. P2: False dichotomy between vendoring and centralized container; hybrid not explored

**Section:** Section 3 overall, and Open Questions Q1

**Lens applied:** The Starter Option — making the smallest possible commitment to learn the most before scaling.

The brainstorm frames the choice as binary: vendor interbase.sh into each plugin OR make it a separate plugin (with Claude Code dependency resolution). The centralized container question aside, there is a third hybrid that is not named:

**Hybrid: Ship stubs in the plugin, source live copy if available.**

```bash
# In plugin hooks/interbase.sh — always ships with the plugin:
# Version: 1.2 (stubs — full interbase not installed)

INTERBASE_LIVE="${HOME}/.intermod/interbase.sh"
if [[ -f "$INTERBASE_LIVE" ]]; then
    source "$INTERBASE_LIVE"
    return 0
fi

# Fallback stubs — functional but less capable
ib_has_ic() { command -v ic &>/dev/null; }
ib_has_bd() { command -v bd &>/dev/null; }
# ... minimal stubs only ...
```

This hybrid gives:
- Zero install friction for standalone users (stubs ship in the plugin, always work)
- Live update propagation for ecosystem users (centralized copy takes precedence)
- No version skew problem (ecosystem users all get the same live copy; standalone users get stubs that are good enough for their use case)
- Graceful degradation in both directions (missing centralized copy falls back to stubs; missing plugin-level stubs would be a publish failure)

The document's Open Question 1 ("Should interbase.sh be a separate repo or live in a canonical location within Interverse?") partially gestures at this but frames it as a source location question, not a runtime discovery question. Combining `sdk/interbase/` as the canonical source with runtime discovery at `~/.intermod/interbase.sh` would give both the monorepo management benefits the document wants and the live-update benefits the centralized container offers.

**What to ask before committing:** Would the stub-plus-live-discovery hybrid satisfy the standalone-user and ecosystem-user constraints simultaneously? If yes, vendoring full interbase.sh into every plugin is premature — the starter option is to ship stubs and add live discovery, then decide whether to promote interbase to a full install if usage warrants it.

---

### D-04. P2: Sunk cost anchor on fail-open pattern suppresses pre-mortem on interbase.sh as a new failure point

**Section:** "Why This Approach" (Section 2, The Tension) and Section 5, Testing Architecture

**Lens applied:** Theory of Change — mapping the causal chain from action to intended outcome to test assumptions.

The brainstorm's theory of change for interbase.sh is:
- Current: 20+ plugins each implement ad-hoc guards -> upgrade friction, feature duplication, testing complexity
- Proposed: One interbase.sh, vendored into all plugins -> single point of failure isolation -> test once, trust everywhere

The document says: "The `interbase.sh` guards are the single point of failure isolation — if they work correctly, all plugins degrade correctly. Test interbase once, trust it everywhere."

This is stated as a benefit, but "single point of failure isolation" is also a description of a new systemic risk that did not exist before. The current fail-open guards are distributed — a bug in interflux's `command -v bd` guard affects only interflux. Under the proposed model, a bug in `ib_has_bd()` — or a shell portability issue with the sourcing mechanism — affects all 20+ plugins simultaneously. The document never asks: what is the failure mode when interbase.sh itself has a bug?

The sunk cost anchor is this: the document's motivation for interbase.sh is to solve the current fail-open guard problem, which "already works." But the opening section explicitly acknowledges the current approach works ("This works — no plugin crashes without dependencies"). The argument for change rests on upgrade friction and feature duplication, which are real costs. The argument does not include a pre-mortem: what would have to be true for interbase.sh to make things meaningfully worse than the current state?

Concretely: if `ib_in_sprint()` has a bug in version 1.2 that causes it to return true even when no sprint exists, and that version is vendored into all 20+ plugins before the bug is caught, the blast radius is all 20+ plugins emitting spurious sprint events simultaneously. Under the current ad-hoc pattern, the same bug would be localized to whatever plugin introduced it.

The testing architecture proposed (test interbase once, trust everywhere) is exactly correct for the happy path. It does not address the unhappy path: how is a bad interbase.sh version caught before it propagates to all plugins? The current per-plugin tests catch regressions in each plugin's specific guard logic. A centralized interbase.sh test suite is necessary but not described.

**What to ask before committing:** What is the rollout plan if interbase.sh v1.3 introduces a regression? Can a plugin pin to v1.2 (if vendored), and what is the recovery path for users who have already installed the affected plugin versions?

---

### D-05. P3: Version skew treated as an open question without reversibility analysis

**Section:** Open Questions, Q5

**Lens applied:** Signposts — pre-committed decision criteria that trigger a strategy change when observed.

Open Question 5 asks: "When a plugin ships interbase.sh v1.2 but the ecosystem has moved to v1.5, do we handle version skew? Or is 'each plugin ships what it ships' sufficient?"

This is framed as a deferred decision. But it is actually the reversibility question for the entire architecture choice. The vendoring approach is easy to reverse now (before any plugins have shipped with interbase.sh) and increasingly hard to reverse later (once 20+ plugins are in the marketplace with vendored copies at various versions). The document does not identify this as a point of no return.

A signpost to pre-commit to would be: "If interbase.sh requires a breaking change before all 20+ plugins can be re-published, we will treat that as evidence that the centralized container model should be adopted instead." Without this signpost, the decision is made implicitly — once vendoring is in place, the path dependency makes it costly to switch even if the evidence strongly favors the container model.

The reversibility comparison is:
- Vendoring: reversible now (no plugins shipped), moderately costly at 5 plugins, very costly at 20+ plugins (requires re-publishing all and ensuring users reinstall)
- Centralized container: reversible at any point (removing `~/.intermod/interbase.sh` causes plugins to fall back to stubs if hybrid is used, or to nothing if not)

The reversibility asymmetry argues for trying the centralized container first as a starter option, and only adopting vendoring if the container model proves insufficient — not the other way around.

---

### D-06. P3: Explore/exploit imbalance — ecosystem-first framing may foreclose standalone learning signal

**Section:** Design Constraints ("Integrated-first — The Interverse ecosystem is the primary product. Standalone is a gateway")

**Lens applied:** Explore vs. Exploit — the tension between learning new approaches and optimizing known ones.

The design constraint "Integrated-first" is stated as a given, not a decision. The brainstorm then builds the entire three-layer model on top of this axiom. But the standalone mode, if genuinely useful, would provide a distinct learning signal: which features users want when they have no ecosystem context. That signal is only available if standalone mode is treated as a real product rather than a gateway.

The per-plugin standalone assessment table (Section 6) reveals that interlock (30%) and interphase (20%) have very low standalone value. The document proposes either raising their standalone value or marking them "ecosystem-only." But there is a third interpretation: if these plugins have near-zero standalone value, they are poor candidates for separate marketplace publication at all — they are internal components of the Clavain system that happen to be packaged as plugins. Publishing them standalone creates misleading marketplace presence without the claimed dual-mode benefit.

The explore/exploit question is: is the dual-mode architecture being chosen because users have expressed demand for standalone plugins, or because the architecture seems elegant given the monorepo structure? If it is the latter, the "ecosystem-first" constraint is also an exploit decision (optimize the known Clavain workflow) rather than an explore decision (learn what standalone users actually need). Building the entire interbase.sh infrastructure before any standalone plugins have marketplace traction means the architecture is being locked in before the learning signal arrives.

**What to ask before committing:** Is there any existing evidence that standalone plugin users exist or would find value in these plugins outside the Clavain ecosystem? If not, delaying the dual-mode architecture until there is marketplace data would reduce the risk of building infrastructure for a use case that doesn't materialize.

---

## Overall Assessment

The brainstorm makes one clearly premature commitment (vendoring interbase.sh without evaluating the centralized container model's actual tradeoffs) and one implicit false dichotomy (vendor vs. separate plugin, where the real alternative is a hybrid stub-plus-live-discovery pattern). The remaining issues are enrichment opportunities rather than blockers.

The most impactful action before moving to planning: run a 30-minute analysis comparing the three options (vendoring, centralized container, hybrid) against the two empirical facts the brainstorm doesn't gather — expected interbase.sh update frequency and the standalone vs. ecosystem-suite user ratio. Those two data points resolve the D-01 and D-02 findings and likely determine which model is correct.

---

NOTE: MCP server unavailable — review used fallback lens subset (12/288 lenses). Install interlens-mcp for full coverage.
