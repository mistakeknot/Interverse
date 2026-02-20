# Synthesis Report — Dual-Mode Plugin Architecture Brainstorm Review

**Date:** 2026-02-20
**Reviewed Document:** `/root/projects/Interverse/docs/brainstorms/2026-02-20-dual-mode-plugin-architecture-brainstorm.md`
**Review Agents:** 4 launched, 4 completed (100% success rate)
- fd-architecture (architectural soundness)
- fd-user-product (user experience & marketplace implications)
- fd-systems (systems thinking & feedback dynamics)
- fd-decisions (decision quality & reversibility)

**Context:** Brainstorm for dual-mode plugin architecture — how Interverse modules serve both standalone Claude Code users and integrated Clavain/Intercore users. Key tension: vendored interbase.sh vs centralized 'intermod' container.

---

## Overall Verdict

**NEEDS_WORK** (architecture direction is sound; three blocking product issues and one major design blind spot must resolve before planning)

- **Gate Status:** FAIL
- **Confidence Level:** Low-to-medium (two P1 design decisions lack empirical grounding)
- **Reversibility:** Medium-to-high cost to reverse (vendoring becomes harder to undo at 20+ published plugins)

---

## Validation Summary

| Agent | Status | Verdict | Key Finding |
|-------|--------|---------|------------|
| fd-architecture | Valid | needs-changes | Three P1 design issues: vendoring sync problem, plugin.json schema conflict, intermod already exists; P3 nudge concurrency race |
| fd-user-product | Valid | needs-work | Three BLOCKING: interlock/interphase have no standalone value; nudge spec incomplete; marketplace manifest already stale |
| fd-systems | Valid | needs-attention | Four P1 risks from systems thinking lens: version drift loop, test isolation assumptions, Schelling trap (vendoring vs centralization), pace layer inversion (nudge bundled with core) |
| fd-decisions | Valid | needs-input | Two P1 blind spots: vendoring pattern borrowed from npm/Go doesn't transfer to Claude Code; centralized container dismissed without evaluation; hybrid stub-plus-live approach not explored |

**Validation: 4/4 agents valid, 0 failed**

---

## Critical Findings (Blocking Planning)

### BLOCKING-01: Three Plugins Have <50% Standalone Value on Marketplace

**Severity:** BLOCKING (product decision prerequisite)
**Agents:** fd-user-product, fd-architecture
**Convergence:** 3/4 agents flagged

**Summary:**
- **interlock** (30% standalone): File coordination requires intermute service at 127.0.0.1:7338. Standalone install gets non-functional MCP tools with no error guidance. Users see "Companion plugin for Clavain" label but interpret as "works with" not "requires."
- **interphase** (20% standalone): Phase tracking without beads has no state store. Brainstorm says "provide lightweight phase tracking" without specifying where state lives. This is an implementation task, not a percentage recalibration.
- **interject** (90% claimed, should be 65-75%): Research findings with no persistent store produce throwaway stdout. Without beads, the ambient research engine's value is severely degraded — findings are read once and forgotten.

**Required Action Before Planning:**
1. Decide for each plugin: don't publish standalone, build meaningful local mode, or accept ecosystem-only designation.
2. For interphase: specify lightweight state store (`.local/share/interverse/interphase/state.json` or similar) and build it.
3. Recalibrate interject's standalone % based on realistic value without persistent output.

**Why This Blocks Planning:**
The dual-mode architecture improves degradation handling and adds manifest declarations. It cannot manufacture standalone value for plugins that have none. Publishing infrastructure around unresolved product questions creates marketplace debt.

---

### BLOCKING-02: Nudge Protocol Is Critically Underspecified

**Severity:** BLOCKING (implementation prerequisite)
**Agents:** fd-user-product, fd-architecture, fd-systems
**Convergence:** 3/4 agents flagged with overlapping gaps

**Missing Specifications:**
1. **Trigger event:** Session start (user has no context)? First successful review (highest receptivity)? First invocation? All three?
2. **Durable dismissal:** Temp file `/tmp/interverse-nudge-${CLAUDE_SESSION_ID}` means users who have seen nudge 30 times see it again tomorrow.
3. **Action instruction:** "install interphase" is not actionable. "/plugin install interphase for automatic phase tracking" is self-contained.
4. **Companion-installed check:** Nudging after companion is already installed is a bug.
5. **Aggregate nudge budget:** At 10+ installed plugins × 2-3 missing companions each, ecosystem nudge volume is `(plugins) × (missing companions)`, not bounded.
6. **Cobra effect risk:** User sees nagging plugin → disables/uninstalls plugin → ecosystem adoption falls.

**Convergent Guidance:**
- Trigger: First successful review/research completion (highest-value moment, user is receptive)
- Durable state: `~/.config/interverse/nudge-state.json` keyed by `plugin:companion` pair
- Nudge text: `"[interverse] Tip: run /plugin install {companion} for {benefit}."`
- Dismissal: Once companion installed (detectable via `ib_has_companion()`), never nudge again. Optional: dismissed flag after three ignores prevents indefinite repetition.
- Aggregate: Session-level nudge coordinator that caps total ecosystem nudges per session or per plugin.

**Why This Blocks Planning:**
Implementation without a spec guesses wrong on trigger event and repeat-forever policy. A bad nudge experience damages ecosystem adoption signal and user trust.

---

### BLOCKING-03: Marketplace Manifest Already Drifting Before Architecture Ships

**Severity:** BLOCKING (data integrity prerequisite)
**Agents:** fd-user-product
**Convergence:** 1/4 agents (but confirms a structural problem)

**Evidence:**
`infra/marketplace/.claude-plugin/marketplace.json` line 207: "7 review agents, 2 commands, 1 skill, 1 MCP server."
Actual interflux plugin.json: "17 agents (12 review + 5 research), 3 commands, 2 skills, 2 MCP servers."

**Why This Matters:**
The integration manifest specification assumes tooling will read plugin.json and generate companion suggestions. But marketplace.json is separately maintained and has already drifted. If the architecture adds an `integration.json` alongside, it will suffer the same drift unless the publication pipeline is hardened.

**Required Action:**
- Marketplace descriptions must be auto-generated from plugin.json at publish time (interbump should own this), OR
- Description field must be stable and not enumerate counts (counts always drift).
- Establish version-sync verification in CI to catch manifest drift on each PR.

---

## Major Design Blind Spots (P1 / Design Risk)

### P1-A: Vendoring Pattern Borrowed From npm/Go Does Not Transfer to Claude Code

**Severity:** P1 (Decision reversal cost grows with each plugin)
**Agents:** fd-decisions, fd-architecture
**Convergence:** 2/4 agents (both architecture-focused reviewers)

**Problem Statement:**
The brainstorm states "Vendoring is the npm/Go pattern for this exact problem." npm and Go have:
- Build steps that invoke lockfile resolution
- Automated propagation (`npm install`, `go mod vendor` in CI/CD)
- Dependency trees that are queryable and auditable

Claude Code plugins are directory-copied into `~/.claude/plugins/cache/`. The "update via interbump at publish time" mechanism requires re-publishing every plugin every time interbase.sh changes. This replicates upgrade friction at a new layer rather than eliminating it.

**Key Question Not Asked:**
How often is interbase.sh expected to change? The document identifies as the core problem that "intercore evolves frequently." If interbase.sh changes with every intercore release, vendoring creates a publish-every-plugin requirement. This is the opposite of the intended outcome.

**Hybrid Alternative Not Explored:**
Ship minimal stubs inside the plugin (zero install friction), but source a live centralized copy at `~/.intermod/interbase.sh` if present. Ecosystem users get live updates; standalone users get functional stubs. This "starter option" is the smallest commitment that preserves both paths. Committing to full vendoring before validating update frequency forecloses this path.

**Convergent Recommendation (fd-decisions):**
Gather two empirical facts before planning: (1) expected interbase.sh update frequency as intercore evolves, and (2) expected standalone-only vs. full-suite user ratio. These resolve the vendoring decision and determine which model (vendoring, centralized container, or hybrid) is correct.

---

### P1-B: Extending plugin.json Risks Claude Code Schema Conflict

**Severity:** P1 (Platform ownership issue)
**Agents:** fd-architecture
**Convergence:** 1/4 agents (architecture reviewer only, but authoritative)

**Problem:**
The brainstorm adds an `"integration"` key to `plugin.json`, a Claude Code platform-owned schema file. The brainstorm itself flags "risks schema conflicts with future Claude Code updates" as an open question. This understates the problem.

**Concrete Scenario:**
If Claude Code adds an `"integration"` key for its own purposes (plugin inter-dependencies, platform capability flags), the key will conflict silently or be overwritten. Tooling that reads Interverse-specific metadata from a platform-schema file creates coupling between ecosystem tooling and the Claude Code schema version.

**Required Fix:**
Use `.claude-plugin/integration.json` as a separate Interverse-owned file alongside `plugin.json`. This:
- Carries no platform conflict risk
- Is clearly Interverse-specific to any reader
- Is trivially extensible for future manifest features
- Solves the "file bloat" concern (the existing plugin structure already has plugin.json, hooks.json, CLAUDE.md, AGENTS.md as separate concerns)

**Precedent in Interverse:**
The codebase already made this decision for an analogous problem. `infra/interband/lib/interband.sh` is a shared library with its own config schema — Interverse-specific metadata lives in separate files, not in platform-owned structures.

---

### P1-C: The Intermod Alternative Already Exists as ~/.interband/ — Generalization Pattern Not Recognized

**Severity:** P1 (Missed pattern recognition, design simplification opportunity)
**Agents:** fd-architecture
**Convergence:** 1/4 agents (architecture reviewer only, but pattern-authority source)

**Evidence:**
- `~/.interband/` is already a namespaced home-path directory owned by the Interverse ecosystem.
- Its load pattern (`_gate_load_interband` in `lib-gates.sh` lines 29-42) is exactly the runtime-resolution mechanism interbase needs: canonical path, env override, fail-open fallback.
- The user's intermod question reveals that the interband pattern is the answer and was not recognized as such in the brainstorm.

**Generalization Path:**
The `~/.intermod/` directory is the generalization of `~/.interband/`:
- interband handles **data** (JSON sideband state)
- interbase would handle **code** (shell library)
- Both use the same filesystem-path resolution pattern and the same fail-open degradation

**Concrete Structure:**
```
~/.intermod/interbase/interbase.sh  — canonical location, installed by publish toolchain
INTERMOD_LIB env var                — developer override for testing unpublished versions
Fall-through                        — if not present, plugins use existing inline guards unchanged
```

**Why This Matters:**
This is not a new idea. It is a **proven pattern** in the codebase. Recognizing it as such would:
- Simplify the design (no new concepts)
- Leverage existing path-search and ACL infrastructure
- Allow incremental migration (standalone plugins don't break)
- Reduce implementation scope (no need to invent vendoring propagation)

**Security Note:**
The only difference between interband (data) and interbase (code) is that sourcing executable code from a user-writable path is a security surface. The mitigation matches the existing system: `interbump` installs with `chmod 644`, and the POSIX ACL infrastructure in root `CLAUDE.md` applies.

---

## Systems Thinking Findings (P1 Risks from Feedback Dynamics)

### P1-SYS-A: Vendoring Creates a Diverging Compounding Loop, Not a Stable Distribution

**Severity:** P1 (Emergent failure mode over time)
**Agents:** fd-systems
**Convergence:** 1/4 agents (systems thinking specialist only, but high-impact analysis)

**Causal Chain (Compounding Loop):**

1. Ecosystem-integrated plugins (interphase, intercore) update interbase.sh frequently because kernel events are their primary value.
2. Standalone-leaning plugins (tldr-swinton, interfluence, interstat at 95%+ standalone) have low publish frequency because their core value does not depend on interbase.sh.
3. `interbump` updates interbase.sh only at publish time — so slow-publishing plugins accumulate more drift with each kernel change.
4. Slower-publishing plugins are exactly the ones most likely to be installed standalone, where drift is invisible to users.
5. When a standalone user eventually installs a companion that depends on a newer interbase.sh API, the guard functions in the older vendored copy silently return the wrong result (e.g., `ib_in_sprint` checking an old `ic run current` flag that has been renamed).
6. The failure mode is not a crash — it is **silent capability degradation**, which the standalone user has no way to diagnose.

**Behavior-Over-Time Graph (12 months):**
- T=0: All plugins ship consistent interbase.sh
- T=6mo: Ecosystem-heavy plugins on v1.4, standalone-heavy on v1.1
- T=12mo: Delta large enough that `ib_emit_event` signatures diverged — two plugins in the same session call the same function with incompatible argument orders

**Missing Mechanism:**
Is there a way to detect that a running plugin's vendored interbase.sh is more than N versions behind, and surface that during session start rather than silently degrading?

**Why This Blocks Planning:**
The brainstorm does not model this compounding loop or describe detection/recovery. The "test interbase once, trust it everywhere" claim (P1-SYS-B) assumes aggregate behavior mirrors individual behavior, which it does not.

---

### P1-SYS-B: "Test interbase Once, Trust It Everywhere" Assumes Aggregate Behavior Mirrors Individual

**Severity:** P1 (Test strategy gap)
**Agents:** fd-systems
**Convergence:** 1/4 agents (systems thinking specialist only, but testing assumption is critical)

**The Claim:**
"The `interbase.sh` guards are the single point of failure isolation — if they work correctly, all plugins degrade correctly. Test interbase once, trust it everywhere."

**Why This Is Wrong:**
This is a reductionist claim in a context where emergence is the operative dynamic. Each plugin adds its own local rules on top of interbase.sh:
- Conditional sourcing of specific functions
- Overriding specific guards for certain code paths
- Layering additional checks on top of base guards
- Assuming certain guard behaviors (e.g., that `ib_has_ic()` means intercore is usable, not just installed)

The emergent behavior of 20+ plugins each applying local rules to a shared base is **not the same** as testing the base in isolation.

**Concrete Examples:**
- interflux may source interbase.sh and redefine `ib_has_ic()` locally for a specific code path.
- interphase may source interbase.sh but skip calling `ib_in_sprint` because it has its own sprint detection.
- interstat may call `ib_emit_event` with a payload format that matches v1.2 but breaks on v1.5.

None of these failures are catchable by testing interbase.sh in isolation.

**The Document's Test Architecture is Correct, But Incomplete:**
The proposed test suite (`test-standalone.sh`, `test-integrated.sh`, `test-degradation.sh`) is correct at the per-plugin level. But the document makes an additional claim — that testing interbase once reduces the per-plugin testing burden — that is only true if no plugin adds local state that interacts with interbase.sh functions.

In a system of 20+ plugins with independent development cadences and no shared integration test, that assumption is likely violated.

**Missing Test Requirement:**
Session-level (not plugin-level) integration tests that:
1. Load multiple plugins simultaneously in the same Claude Code session
2. Verify that each plugin's sourced interbase.sh version is compatible
3. Check for signature mismatches when multiple plugins call the same function
4. Simulate version skew scenarios (e.g., plugin A vendored v1.1, plugin B vendored v1.5)

---

### P1-SYS-C: Centralized "intermod" Would Invert the Failure Mode, Not Eliminate It (Schelling Trap)

**Severity:** P1 (Systems dynamics of the vendoring vs. centralization choice)
**Agents:** fd-systems
**Convergence:** 1/4 agents (systems thinking specialist only)

**Vendoring Failure Mode:**
Silent divergence. Slow-publishing plugins fall behind; drift is invisible until symptom (capability degradation).

**Centralized Failure Mode (Schelling Trap):**
The opposite — a single updated interbase.sh immediately changes behavior of all installed plugins simultaneously, without any plugin author having reviewed or tested the change. This is a **coupling-on-write** problem rather than a coupling-on-read problem.

**Why It's a Schelling Trap:**
- **Individual incentive:** Each plugin author benefits from always having the latest interbase.sh (no drift, no stale guards).
- **Collective incentive:** The ecosystem as a whole prefers vendoring for resilience — a breaking change in interbase.sh takes down all plugins simultaneously rather than one at a time.
- **Individually-rational / collectively-suboptimal:** Each author prefers centralized (reduces their maintenance burden). But collectively, vendoring produces better resilience.

**Hysteresis Question (Not Addressed):**
Once 20+ plugins are installed and depend on a centralized intermod, what is the cost of reverting to vendoring? The transition path back is not free:
- Each plugin publisher must re-vendor at their next release
- During transition, some plugins use centralized path, others use vendored path
- That transition window is the highest-risk period

**Why This Matters:**
The document's choice of vendoring is likely correct, but the reasoning is shallow. The stronger argument is the hysteresis argument: **vendoring localizes failures in space** (one plugin breaks at a time) whereas **centralization concentrates them in time** (all plugins break together on every interbase.sh breaking change).

---

### P1-SYS-D: Pace Layer Inversion — Nudge Protocol Bundled With Core Prevents Fast Updates

**Severity:** P1 (Architecture pattern violation)
**Agents:** fd-systems
**Convergence:** 1/4 agents (systems thinking specialist only)

**The Pace Layer Model:**
- **Slow:** Kernel event bus, `ic` CLI protocol, bead schema (foundational, stable)
- **Medium:** interbase.sh guard functions, ecosystem detection (update when kernel evolves)
- **Fast:** Individual plugin features, companion nudges, discovery hints (update when plugin authors ship)

**The Problem:**
Layer 1 (Standalone Core) calls Layer 2 functions (e.g., `ib_nudge_companion`) that are bundled in vendored interbase.sh alongside medium-layer integration code. This couples the fast layer (plugin feature: nudge text) to the medium layer (interbase.sh) at every publish.

**Concrete Consequence:**
Updating nudge text for interflux ("Tip: install interphase...") requires a full `interbump` publish cycle even though the nudge is pure cosmetic text. This violates pace layer separation.

**Recommended Fix:**
Split interbase.sh into two parts:
- `interbase-core.sh` — guards, detection (slow/medium, rarely changes)
- `interbase-nudge.sh` OR inline plugin strings — nudge text (fast, updatable independently)

This allows nudge updates without coupling to a full interbase.sh version bump.

---

## Medium-Severity Findings (P2)

### P2-A: Three-Layer Model Creates Accidental Testing Complexity

**Severity:** P2 (Implementation complexity)
**Agents:** fd-architecture
**Convergence:** 1/4 agents (architecture reviewer only)

**The Issue:**
The three layers (Standalone Core, Ecosystem Integration, Orchestrated Mode) are a useful documentation concept but are not independent code sections — they are conditional branches inside one set of hooks. The test matrix explodes:
- Layer 2 depends on multiple binary presence checks: `ic`, `bd`, each companion
- Layer 3 depends on all of the above plus orchestration state
- Testing matrix grows exponentially, not linearly

**Recommendation (fd-architecture):**
Keep the three-layer model as documentation only. The test harness (`test-standalone.sh`, `test-integrated.sh`, `test-degradation.sh`) is the deliverable. Do not add "layer" concept to the implementation — the current guard-then-delegate pattern (`ib_has_ic || return 0; ...ecosystem code...`) is already correct.

---

### P2-B: Standalone User Journey Has No Integration Status Visibility

**Severity:** P2 (User experience gap)
**Agents:** fd-user-product
**Convergence:** 1/4 agents (user-product reviewer only)

**The Issue:**
Three different visibility states exist (no interphase, interphase without interline, full integration) with no user-facing indicator of which state is active. Session-start hook emits no status line. Users don't know if a plugin is running in standalone mode, partial integration, or full orchestrated mode.

**Recommendation:**
Session-start hook emits a single structured status line:
```
[interverse] Status: interflux=standalone | interphase=partial | intercore=not-detected
```
One line, machine-parseable, dismissible. This is a requirement for the integrated user journey.

---

### P2-C: Stub-Plus-Live-Discovery Hybrid Not Explored (Alternative to Vendoring)

**Severity:** P2 (Design option foreclosure)
**Agents:** fd-decisions
**Convergence:** 1/4 agents (decision quality reviewer only)

**The Alternative:**
Ship minimal stubs inside the plugin (zero install friction), but source a live centralized copy at `~/.intermod/interbase.sh` if present. Ecosystem users get live updates; standalone users get functional stubs. This "starter option" is the smallest commitment that preserves both paths.

**Current Status:**
Not mentioned in brainstorm. The choice is framed as: vendor full interbase.sh OR make it a separate plugin (with install friction). This is a false dichotomy.

**Why This Matters:**
Committing to full vendoring before validating demand forecloses this path. At 0 published plugins, reversibility cost is low. At 20+ published plugins, switching to hybrid becomes expensive (requires re-publishing all plugins).

---

## Low-Severity Findings (P3)

### P3-A: Nudge Concurrency Race (Parallel Hook Execution)

**Severity:** P3 (Low-frequency annoyance)
**Agents:** fd-architecture
**Convergence:** 1/4 agents (architecture reviewer only)

**The Issue:**
The nudge-once-per-session pattern uses `/tmp/interverse-nudge-${CLAUDE_SESSION_ID}`. Parallel hook execution (PreToolUse hooks for Edit and Write fire simultaneously) can both read the flag as absent before either writes it, producing two nudge outputs.

**Fix:**
Atomic touch pattern: `[[ ! -f "$flag" ]] && touch "$flag" 2>/dev/null && echo_nudge`. The touch-then-check pattern is atomic enough for this use case.

---

### P3-B: Hysteresis of Low Standalone Percentage Plugins Has No Crumple Zone

**Severity:** P3 (User perception risk)
**Agents:** fd-systems
**Convergence:** 1/4 agents (systems thinking specialist only)

**The Issue:**
A user who installs interlock (30% standalone) today gets a poor experience and may form lasting negative impression. Even if standalone experience improves later, the negative signal (marketplace rating) persists. This is hysteresis — the system (user perception) does not return to neutral when the input (plugin quality) improves.

**Recommendation:**
Design crumple zones — what should fail gracefully when a user discovers <50% standalone value immediately. Rather than silently providing degraded functionality, aggressively route the user toward integrated value (companion discovery, one-command install instructions). The nudge protocol partly serves this role, but the architecture does not connect the two.

---

## Improvements and Quick Wins

### I-A: Interbase.sh Should Self-Detect Centralized ~/.intermod/ Copy (Hedge for Future)

**Priority:** Medium (low-cost hedge, high-value optionality)
**Recommendation:** Write interbase.sh to check `~/.intermod/interbase.sh` first and fall back to the bundled copy. This costs two lines and gives intermod a migration path without mandating it. Revisit when the first actual interbase.sh incompatibility occurs.

---

### I-B: Nudge Text Must Include Install Command

**Priority:** Medium (UX improvement, one-line change)
**Current:** `"[interverse] Tip: install interphase for automatic phase tracking."`
**Recommended:** `"[interverse] Tip: run /plugin install interphase for automatic phase tracking after reviews."`

The action instruction belongs in the nudge.

---

### I-C: Intermod Alternative Generalization

**Priority:** High (pattern recognition, design simplification)
**Recommendation:** Recognize `~/.intermod/` as a generalization of the proven `~/.interband/` pattern. Document the generalization in `sdk/interbase/AGENTS.md`.

---

## Recommendations for Next Steps

### Before Moving to Planning (Hard Prerequisites)

1. **Product decision on sub-50% plugins (BLOCKING):**
   - Resolve: don't publish, build local mode, or ecosystem-only for interlock (30%) and interphase (20%)
   - Build lightweight phase-tracking state store for interphase if staying on marketplace
   - Recalibrate interject's standalone % (recommend 65-75%, not 90%)

2. **Complete nudge protocol specification (BLOCKING):**
   - Trigger event: first successful review completion
   - Durable state: `~/.config/interverse/nudge-state.json` with `plugin:companion` keying
   - Nudge text template: include `/plugin install` command
   - Aggregate budget: session-level coordinator capping ecosystem nudges per session

3. **Fix marketplace manifest drift (BLOCKING):**
   - Auto-generate descriptions from plugin.json at publish time, OR
   - Replace enumerated counts with stable descriptions
   - Add CI check for manifest sync

4. **Gather empirical facts before vendoring commitment (HIGH):**
   - Expected interbase.sh update frequency as intercore evolves (weekly? monthly?)
   - Expected standalone-only vs. full-suite user ratio from early marketplace data
   - These two data points resolve vendoring vs. centralized vs. hybrid decision

5. **Recognize intermod as generalization of interband (HIGH):**
   - Document the pattern in sdk/interbase/AGENTS.md
   - Establish ~/.intermod/ directory structure
   - Implement runtime path search with INTERMOD_LIB override

### If Proceeding to Planning (Conditional on Above)

1. **Establish sdk/interbase/ as the canonical home:**
   - Define interbase.sh function set (guards + telemetry only)
   - Define integration.json schema (separate from plugin.json)
   - Design test harness (test-standalone.sh, test-integrated.sh, test-degradation.sh)

2. **Add post-bump.sh hook to interbump:**
   - Installs `~/.intermod/interbase/interbase.sh` from published version
   - One addition to existing publish pipeline

3. **Migrate interflux as reference implementation:**
   - 90% standalone, cleanest case
   - Validates the full dual-mode pattern before applying to ecosystem-heavy plugins

4. **Sequence plugin adoption:**
   - No plugin disrupted before its next natural publish cycle
   - Migration is incremental by design

---

## Files for Reference

- Full architectural analysis: `/root/projects/Interverse/docs/research/review-dual-mode-architecture.md`
- Rollback/recovery quality review: `/root/projects/Interverse/.clavain/quality-gates/fd-quality.md`
- Rollback/recovery correctness review: `/root/projects/Interverse/.clavain/quality-gates/fd-correctness.md`

---

## Summary Table: Convergence Across Agents

| Finding | fd-arch | fd-user | fd-syst | fd-decis | Consensus |
|---------|---------|---------|---------|----------|-----------|
| Vendoring sync problem (P1) | ✓ F1 | — | ✓ S-01 | ✓ D-01 | 3/4 converge |
| plugin.json schema conflict (P1) | ✓ F3 | — | — | — | 1/4 (but authoritative) |
| intermod pattern not recognized (P1) | ✓ F4 | ✓ UP-08 | — | ✓ D-02 | 3/4 converge |
| interlock/interphase low standalone (BLOCKING) | ✓ F5 | ✓ UP-05 | — | — | 2/4 converge |
| Nudge spec incomplete (BLOCKING) | ✓ F6 | ✓ UP-02 | ✓ S-05 | — | 3/4 converge |
| Test isolation assumptions (P1-SYS) | — | — | ✓ S-02 | — | 1/4 (specialist) |
| Pace layer inversion (P1-SYS) | — | — | ✓ S-04 | — | 1/4 (specialist) |
| Three-layer testing complexity (P2) | ✓ F2 | — | — | — | 1/4 |
| Marketplace manifest drift (BLOCKING) | — | ✓ UP-03 | — | — | 1/4 (but critical) |

**Key Insight:** BLOCKING-level findings converge across 2-3 agents. P1 design findings show strong convergence (3/4 agents on key patterns). Systems-thinking P1s are specialist-only but represent high-impact emergent risks over time.

---

## Confidence Assessment

| Aspect | Confidence | Rationale |
|--------|-----------|-----------|
| Vendoring creates sync problems | High | Modeled via compounding loop (fd-systems) + pattern recognition (fd-architecture) + decision lens (fd-decisions) — 3/4 agents converge |
| Three BLOCKING issues are real | Medium-High | All BLOCKING findings tied to product decisions (sub-50% plugins, nudge spec, manifest drift) with 2-3 agent convergence |
| Empirical facts missing | High | fd-decisions explicitly calls for (1) update frequency and (2) user ratio data before committing to vendoring |
| Architecture direction is sound | High | All agents affirm the three-layer model and integration manifest as correct directions |
| Too early to plan | High | Two P1 design decisions lack empirical grounding; three BLOCKING product decisions unresolved |

**Overall Recommendation:** WAIT for data. The architecture direction is sound. The decision quality and design blind spots suggest this brainstorm is 80% ready for planning, but the 20% gap is in the details that determine success or failure. Gathering empirical facts (interbase update frequency, standalone user ratio) and resolving product decisions (sub-50% plugins, nudge spec) are prerequisite work, not parallel work.

