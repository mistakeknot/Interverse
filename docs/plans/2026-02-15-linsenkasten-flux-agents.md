# Linsenkasten Flux-Drive Lens Agents — Implementation Plan
**Phase:** planned (as of 2026-02-15T20:49:38Z)

> **For Claude:** REQUIRED SUB-SKILL: Use clavain:executing-plans to implement this plan task-by-task.

**Goal:** Implement Phase 0 of the Linsenkasten lens agents — move Linsenkasten into the Interverse monorepo, create one cognitive review agent (fd-systems), and add triage pre-filter rules so it only activates for document reviews.

**Architecture:** Linsenkasten moves into `plugins/linsenkasten/` as a standalone subproject with its own `.git`. A new `fd-systems.md` agent file is added to interflux's `agents/review/` directory following the existing fd-* agent format. The triage pre-filter in `SKILL.md` gets a new "Cognitive filter" rule that excludes cognitive agents from code/diff inputs.

**Tech Stack:** Markdown (agent files), shell (migration), flux-drive triage scoring (SKILL.md prompt engineering)

---

## Task 1: Move Linsenkasten into Interverse (F0)

**Files:**
- Move: `/root/projects/Linsenkasten/` → `/root/projects/Interverse/plugins/linsenkasten/`
- Create: `/root/projects/Linsenkasten` (compat symlink)
- Modify: `/root/projects/Interverse/CLAUDE.md:26` (add linsenkasten to structure table)

**Step 1: Move the Linsenkasten directory into plugins/**

```bash
mv /root/projects/Linsenkasten /root/projects/Interverse/plugins/linsenkasten
```

Linsenkasten is currently a real directory at `/root/projects/Linsenkasten/` (not a symlink). It has its own `.git` with remote `origin → https://github.com/mistakeknot/Linsenkasten.git`. The move preserves everything including `.git`.

**Step 2: Create compat symlink**

```bash
ln -s /root/projects/Interverse/plugins/linsenkasten /root/projects/Linsenkasten
```

This follows the pattern used by all other subprojects (e.g., `/root/projects/interflux` → `Interverse/plugins/interflux`).

**Step 3: Update CLAUDE.md structure table**

In `/root/projects/Interverse/CLAUDE.md`, add `linsenkasten/` to the plugins section, maintaining alphabetical order. Insert after `interwatch/`:

```
  linsenkasten/       → cognitive augmentation lenses (FLUX podcast)
```

**Step 4: Verify the migration**

Run these verification commands — all must pass:

```bash
# .git preserved with correct remote
cd /root/projects/Interverse/plugins/linsenkasten && git remote -v | grep -q "mistakeknot/Linsenkasten"

# Compat symlink works
readlink /root/projects/Linsenkasten | grep -q "Interverse/plugins/linsenkasten"

# Key files accessible
test -f /root/projects/Interverse/plugins/linsenkasten/apps/api/lens_frames_thematic.json
test -d /root/projects/Interverse/plugins/linsenkasten/packages/mcp
test -f /root/projects/Interverse/plugins/linsenkasten/CLAUDE.md
```

Expected: All commands exit 0.

**Step 5: Set POSIX ACLs for claude-user access**

```bash
setfacl -R -m u:claude-user:rwX /root/projects/Interverse/plugins/linsenkasten
setfacl -R -m d:u:claude-user:rwX /root/projects/Interverse/plugins/linsenkasten
```

**Step 6: Commit**

```bash
cd /root/projects/Interverse
git add CLAUDE.md plugins/linsenkasten
git commit -m "feat(F0): move Linsenkasten into Interverse monorepo

Migrate Linsenkasten to plugins/linsenkasten/ with own .git preserved.
Add compat symlink at /root/projects/Linsenkasten.
Update CLAUDE.md structure table.

Bead: iv-5xac"
```

---

## Task 2: Create fd-systems Agent File (F1)

**Files:**
- Create: `plugins/interflux/agents/review/fd-systems.md`

**Step 1: Write the fd-systems agent file**

Create `plugins/interflux/agents/review/fd-systems.md` with:

1. **YAML frontmatter** — `name: fd-systems`, `model: sonnet`, `description` with one-sentence summary + 2 `<example>` blocks (Context/user/assistant/`<commentary>`) matching the format from `fd-architecture.md`:

```yaml
---
name: fd-systems
description: "Flux-drive Systems Thinking reviewer — evaluates feedback loops, emergence patterns, causal reasoning, unintended consequences, and systems dynamics in strategy documents, PRDs, and plans. Reads project docs when available for codebase-aware analysis. Examples: <example>Context: User wrote a PRD for a new caching layer. user: \"Review this PRD for systems thinking blind spots\" assistant: \"I'll use the fd-systems agent to evaluate feedback loops, second-order effects, and emergence patterns in the caching strategy.\" <commentary>Caching introduces feedback loops (cache invalidation cascades), emergence (thundering herd), and systems dynamics (cold start vs steady state) — fd-systems' core domain.</commentary></example> <example>Context: User wrote a brainstorm about scaling their team structure. user: \"Check if I'm missing any systems-level risks in this reorg plan\" assistant: \"I'll use the fd-systems agent to analyze causal chains, pace layer mismatches, and potential Schelling traps in the team restructuring.\" <commentary>Organizational changes involve systems dynamics — feedback loops in communication, emergence in team behavior, and adaptation risks.</commentary></example>"
model: sonnet
---
```

2. **Opening paragraph** — role statement:

```markdown
You are a Flux-drive Systems Thinking Reviewer. Your job is to evaluate whether documents adequately consider feedback loops, emergence, causal chains, and systems dynamics — catching cognitive blind spots that domain-specific reviewers miss because they focus on implementation rather than systemic behavior.
```

3. **`## First Step (MANDATORY)`** — same as existing agents (read CLAUDE.md/AGENTS.md, codebase-aware vs generic mode).

4. **`## Review Approach`** — 4 subsections:

**### 1. Feedback Loops & Causal Reasoning**
- Map explicit and implicit feedback loops in the proposed system/strategy
- Check for missing reinforcing loops (growth spirals, death spirals) and balancing loops (natural limits, saturation)
- Trace causal chains: are second-order and third-order effects considered?
- Flag one-directional cause-effect reasoning where circular causation is more accurate
- Identify where delays in feedback loops could produce oscillation or overshoot

**### 2. Emergence & Complexity**
- Evaluate whether the document assumes controllable outcomes from complex interactions
- Check for emergent behaviors that could arise from simple rules at scale
- Flag assumptions that aggregate behavior will mirror individual behavior
- Identify convergent/divergent dynamics: where does the system tend toward equilibrium vs divergence?
- Check for preferential attachment effects (rich-get-richer, network effects) that could concentrate outcomes

**### 3. Systems Dynamics & Temporal Patterns**
- Apply behavior-over-time-graph thinking: what does this system look like at T=0, T=6mo, T=2yr?
- Check for pace layer mismatches (fast-moving changes built on slow-moving foundations, or vice versa)
- Identify bullwhip effects where small changes amplify through the chain
- Flag hysteresis: once the system moves to a new state, can it return? At what cost?
- Evaluate whether the proposal accounts for system inertia and transition dynamics

**### 4. Unintended Consequences & Traps**
- Apply cobra effect reasoning: could incentives produce the opposite of intended outcomes?
- Check for Schelling traps (locally rational choices leading to collectively bad outcomes)
- Identify crumple zones: where does the system fail gracefully vs catastrophically?
- Flag over-adaptation: is the system optimized so tightly for current conditions that it can't handle change?
- Evaluate hormesis potential: could small stresses actually strengthen the system?

5. **`## Key Lenses`** — The 12 curated lenses with 1-sentence definitions:

```markdown
## Key Lenses

<!-- Curated from Linsenkasten's Systems Dynamics, Emergence & Complexity, and Resilience frames.
     These 12 (of 288 total) were selected because they form a complete systems analysis toolkit:
     3 for feedback/causation, 3 for emergence, 3 for temporal dynamics, 3 for failure modes.
     Other cognitive domains (decisions, people, perception) are reserved for future agents. -->

When reviewing, apply these lenses to surface gaps in the document's reasoning:

1. **Systems Thinking** — Seeing interconnections, feedback structures, and wholes rather than isolated parts
2. **Compounding Loops** — Reinforcing cycles where outputs feed back as inputs, creating exponential growth or decline
3. **Behavior Over Time Graph (BOTG)** — Tracing how key variables change over time to reveal dynamics invisible in snapshots
4. **Simple Rules** — How a few local rules produce complex global behavior that no one designed
5. **Bullwhip Effect** — Small demand signals amplifying into wild oscillations through a chain of actors
6. **Hysteresis** — Systems that don't return to their original state when the input is reversed — path dependency
7. **Causal Graph** — Mapping explicit cause-effect relationships to expose hidden assumptions about what drives what
8. **Schelling Traps** — Situations where every individual acts rationally but the collective outcome is terrible
9. **Crumple Zones** — Designed failure points that absorb shock and protect core functionality
10. **Pace Layers** — Nested systems moving at different speeds (fast layers innovate, slow layers stabilize)
11. **Hormesis** — The principle that small doses of stress can strengthen a system rather than weaken it
12. **Over-Adaptation** — Optimizing so perfectly for current conditions that any change becomes catastrophic
```

6. **`## Cognitive Severity Guidance`**:

```markdown
## Cognitive Severity Guidance

Use standard P0-P3 severities in your findings output. Apply these heuristics when assigning severity:

- **Blind Spot → P1**: An entire analytical frame is absent from the document. The document shows no awareness of a systems dynamic that is clearly relevant (e.g., a scaling plan with no feedback loop analysis).
- **Missed Lens → P2**: A relevant frame is mentioned or partially addressed but underexplored. The document touches on the concept but doesn't follow through (e.g., mentions "unintended consequences" but doesn't trace specific causal chains).
- **Consider Also → P3**: An enrichment opportunity. The document's reasoning is sound but could be strengthened by applying an additional lens (e.g., applying pace layer analysis to a migration timeline).

P0 is reserved for cases where missing systems analysis creates immediate, concrete risk (rare for cognitive review).
```

7. **`## What NOT to Flag`**:

```markdown
## What NOT to Flag

- Technical implementation details (defer to fd-architecture, fd-correctness)
- Code quality, naming, or style (defer to fd-quality)
- Security or deployment concerns (defer to fd-safety)
- Performance or algorithmic complexity (defer to fd-performance)
- User experience or product-market fit (defer to fd-user-product)
- Lenses from other cognitive domains: decision quality/uncertainty (reserved for fd-decisions), trust/power/communication (reserved for fd-people), innovation/constraints (reserved for fd-resilience), perception/sensemaking (reserved for fd-perception)
- Documents that are purely technical (code, configs, API specs) — cognitive review adds no value there
```

8. **`## Focus Rules`**:

```markdown
## Focus Rules

- Prioritize findings where missing systems analysis could lead to real-world failure (not just theoretical incompleteness)
- Frame findings as questions, not lectures: "What happens when X feeds back into Y?" rather than "You failed to consider feedback loops"
- Each finding must reference a specific section of the document and a specific lens that reveals the gap
- Limit findings to 5-8 per review — focus on the most impactful blind spots, not exhaustive lens coverage
- When a systems issue intersects with a technical concern (e.g., feedback loop in a caching design), flag the systems aspect and note the technical agent that should also review it
```

**Step 2: Validate the agent file structure**

```bash
cd /root/projects/Interverse/plugins/interflux
# Check frontmatter delimiters
head -1 agents/review/fd-systems.md | grep -q "^---$"
# Check required sections
grep -q "^## First Step" agents/review/fd-systems.md
grep -q "^## Review Approach" agents/review/fd-systems.md
grep -q "^## What NOT to Flag" agents/review/fd-systems.md
grep -q "^## Key Lenses" agents/review/fd-systems.md
# Check agent count
ls agents/review/*.md | wc -l  # Should be 8
```

Expected: All greps exit 0, file count is 8 (7 existing + 1 new).

**Step 3: Commit**

```bash
cd /root/projects/Interverse/plugins/interflux
git add agents/review/fd-systems.md
git commit -m "feat(F1): create fd-systems cognitive review agent

First lens agent for flux-drive Phase 0 MVP. Reviews documents for
systems thinking blind spots using 12 curated lenses from Linsenkasten's
Systems Dynamics, Emergence & Complexity, and Resilience frames.

Bead: iv-6a1x"
```

---

## Task 3: Add Cognitive Agent Pre-filter to Triage (F2)

**Files:**
- Modify: `plugins/interflux/skills/flux-drive/SKILL.md:225-249` (Step 1.2a pre-filter section)

**Step 1: Read the current pre-filter section**

Read `plugins/interflux/skills/flux-drive/SKILL.md` lines 225-249 to see the exact text of the pre-filter rules.

**Step 2: Add cognitive filter rule**

In the "For file and directory inputs" section (after the game filter, line 237), add:

```markdown
**For all input types (cognitive agent filter):**

5. **Cognitive filter**: Skip fd-systems (and future cognitive agents: fd-decisions, fd-people, fd-resilience, fd-perception) unless ALL of these conditions are met:
   - Input type is `file` or `directory` (NOT `diff`)
   - File extension is `.md` or `.txt` (NOT code: `.go`, `.py`, `.ts`, `.tsx`, `.rs`, `.sh`, `.c`, `.java`, `.rb`)
   - Document type matches: PRD, brainstorm, plan, strategy, vision, roadmap, architecture doc, or research document

When cognitive agents pass the pre-filter, assign base_score using these heuristics:
   - base_score 3: Document explicitly discusses systems, feedback, strategy, architecture decisions, or organizational dynamics
   - base_score 2: Document is a PRD, brainstorm, or plan (general document review)
   - base_score 1: Document is `.md` but content is primarily technical reference (API docs, changelogs)
```

Also update the "Domain-general agents" line (248) to clarify:

```markdown
Domain-general agents always pass the filter: fd-architecture, fd-quality, and fd-performance (for file/directory inputs only — for diffs, fd-performance is filtered by routing patterns like other domain agents).

Cognitive agents (fd-systems and future lens agents) are filtered separately by the cognitive filter above and are NEVER included for diff or code file inputs.
```

**Step 3: Add cognitive category to triage table**

Find the triage table format in SKILL.md (the scoring table output) and add a note that cognitive agents should be marked with category "cognitive" (distinct from "technical" agents). Search for the triage table format section and add:

```markdown
Cognitive agents display as category `cognitive` in the triage table. Technical agents display as category `technical` (default).
```

**Step 4: Verify the edit**

```bash
cd /root/projects/Interverse/plugins/interflux
# Check cognitive filter exists
grep -q "Cognitive filter" skills/flux-drive/SKILL.md
grep -q "fd-systems" skills/flux-drive/SKILL.md
# Check category exists
grep -q "cognitive" skills/flux-drive/SKILL.md
```

Expected: All greps exit 0.

**Step 5: Commit**

```bash
cd /root/projects/Interverse/plugins/interflux
git add skills/flux-drive/SKILL.md
git commit -m "feat(F2): add cognitive agent pre-filter to triage

Exclude fd-systems (and future cognitive agents) from code/diff reviews.
Only activate for .md/.txt document reviews. Add 'cognitive' category
to triage table output.

Bead: iv-1d28"
```

---

## Task 4: Validate fd-systems on Test Documents

**Files:**
- Test targets (read-only):
  - `docs/prds/2026-02-15-linsenkasten-flux-agents.md` (PRD)
  - `docs/brainstorms/2026-02-15-linsenkasten-flux-agents-brainstorm.md` (brainstorm)
  - Pick one architecture doc from `docs/` directory

**Step 1: Run fd-systems on the PRD**

Invoke the fd-systems agent (via subagent_type or inline prompt) on the PRD:

```
Target: docs/prds/2026-02-15-linsenkasten-flux-agents.md
Agent: fd-systems (use the agent prompt from agents/review/fd-systems.md)
Expected: 3-8 findings with P1-P3 severities, each referencing a specific section and lens
```

The agent should be run as a `general-purpose` subagent with the full fd-systems prompt pasted in (new agent files aren't available as subagent_type until session restart).

**Step 2: Run fd-systems on the brainstorm**

Same approach, targeting `docs/brainstorms/2026-02-15-linsenkasten-flux-agents-brainstorm.md`.

**Step 3: Run fd-systems on a third document**

Pick an architecture or strategy doc and run fd-systems on it.

**Step 4: Evaluate results**

Check each run against Phase 0 success criteria:
- Does it produce findings in the correct format (`SEVERITY | ID | "Section" | Title`)?
- Are findings actionable (would an author act on them)?
- Does it correctly avoid technical implementation concerns?
- Does it reference specific lenses from the Key Lenses list?

At least 2/3 test runs should produce findings the author would act on.

**Step 5: Record validation results**

Note any prompt adjustments needed. If the agent produces low-quality findings, iterate on the prompt before committing.

---

## Task 5: Final Verification and Bead Cleanup

**Step 1: Run structural checks**

```bash
# Agent count
ls /root/projects/Interverse/plugins/interflux/agents/review/*.md | wc -l
# Expected: 8

# Linsenkasten in monorepo
test -d /root/projects/Interverse/plugins/linsenkasten/.git && echo "OK"

# Symlink works
test -L /root/projects/Linsenkasten && echo "OK"

# CLAUDE.md has linsenkasten
grep -q "linsenkasten" /root/projects/Interverse/CLAUDE.md && echo "OK"

# Cognitive filter in SKILL.md
grep -q "Cognitive filter" /root/projects/Interverse/plugins/interflux/skills/flux-drive/SKILL.md && echo "OK"
```

**Step 2: Close Phase 0 beads**

```bash
bd close iv-5xac  # F0: Move Linsenkasten
bd close iv-6a1x  # F1: fd-systems agent
bd close iv-1d28  # F2: Triage pre-filter
```

**Step 3: Update epic status**

```bash
bd update iv-55lq --notes="Phase 0 complete. fd-systems agent created and validated. Phase 1 (F1b, F3, F4) pending success gate evaluation."
```
