# Research: Topology Experiment Context for iv-7z28

**Date:** 2026-02-15  
**Scope:** Background research for topology experiment bead (iv-7z28)  
**Research Questions:**
1. How does flux-drive currently decide agent count?
2. What agent topologies currently exist?
3. What does the brainstorm doc say about topology experiments?
4. What task types are mentioned in the bead description?
5. How does Galiana measure agent performance?
6. Are there existing topology configs or agent roster files?

---

## 1. How flux-drive Decides Agent Count

### Current Algorithm: Dynamic Slot Ceiling

flux-drive uses a **dynamic slot ceiling** algorithm (documented in `plugins/interflux/docs/spec/core/scoring.md`):

```
base_slots       = 4                          # minimum for any review

scope_slots:
  - single file:           +0
  - small diff (<500):     +1
  - large diff (500+):     +2
  - directory/repo:        +3

domain_slots:
  - 0 domains detected:    +0
  - 1 domain detected:     +1
  - 2+ domains detected:   +2

generated_slots:
  - has flux-gen agents:   +2
  - no flux-gen agents:    +0

total_ceiling = base + scope + domain + generated
hard_maximum  = 12                            # absolute cap
```

**Stage Assignment:**
- **Stage 1**: Top 40% of total slots, rounded up (min: 2, max: 5)
- **Stage 2**: All remaining selected agents
- **Expansion pool**: Agents scoring ≥2 but not selected

**Example Calculations:**

| Scenario | Base | Scope | Domain | Generated | Total | Stage 1 | Stage 2 |
|----------|------|-------|--------|-----------|-------|---------|---------|
| Single-file plan, web-api domain, no flux-gen | 4 | +0 | +1 | +0 | 5 | 2 | 3 |
| Game project plan, game-simulation, 2 flux-gen agents | 4 | +0 | +1 | +2 | 7 | 3 | 4 |
| Database migration diff (<500), data-pipeline | 4 | +1 | +1 | +0 | 6 | 3 | 3 |

**Key Finding:** Agent count is **not fixed** — it adapts to review complexity. The algorithm balances thoroughness (include all relevant perspectives) with resource efficiency (exclude tangential agents for simple reviews).

### Scoring Algorithm

Each agent receives a score:

```
final_score = base_score + domain_boost + project_bonus + domain_agent_bonus
max_possible = 3 + 2 + 1 + 1 = 7
```

**Base Score (0-3):**
- 0 = Irrelevant (always excluded, bonuses cannot override)
- 1 = Tangential (include only for thin sections AND slots remain)
- 2 = Adjacent (relevant but not primary focus)
- 3 = Core (agent's domain directly overlaps)

**Domain Boost (0-2):**
- Applied only if base_score ≥ 1
- Based on injection criteria bullet counts (≥3 bullets → +2, 1-2 bullets → +1, 0 bullets → +0)

**Project Bonus (0-1):**
- +1 if project has CLAUDE.md or AGENTS.md
- +1 if agent is project-specific (generated via flux-gen)

**Domain Agent Bonus (0-1):**
- +1 if agent is project-specific AND detected domain matches agent specialization

### Expansion Scoring (Stage 2)

After Stage 1 completes, an **expansion score** is computed for each Stage 2 candidate:

```
expansion_score = 0

# Severity signals (from Stage 1 findings)
for each P0 finding in an adjacent agent's domain:
  expansion_score += 3

for each P1 finding in an adjacent agent's domain:
  expansion_score += 2

# Disagreement signals
if Stage 1 agents disagree on a finding:
  expansion_score += 2

# Domain signals
if agent has domain injection criteria met:
  expansion_score += 1
```

**Expansion Thresholds:**

| max(expansion_scores) | Decision | Behavior |
|-----------------------|----------|----------|
| ≥3 | RECOMMEND expansion | Default option: "Launch [agents]" |
| 2 | OFFER expansion | No default, explain: "moderate signals" |
| ≤1 | RECOMMEND stop | Default: "Stage 1 sufficient" |

**Key Finding:** flux-drive uses **two-stage dispatch** with conditional expansion based on Stage 1 findings. Not all agents launch upfront — only if Stage 1 reveals sufficient severity/complexity.

### Domain Adjacency Map

Agents have 2-3 "neighbors" — agents with related domains where a finding in one makes the neighbor more valuable:

```yaml
adjacency:
  architecture: [performance, quality]
  correctness: [safety, performance]
  safety: [correctness, architecture]
  quality: [architecture, user-product]
  user-product: [quality, game-design]
  performance: [architecture, correctness]
  game-design: [user-product, correctness, performance]
```

**Key Finding:** Adjacency prevents the "everything is connected" problem. A P0 in safety justifies launching correctness and architecture, but not game-design.

---

## 2. Existing Agent Topologies

### Topology 1: quality-gates (5 agents max)

**File:** `hub/clavain/commands/quality-gates.md`

**Always run:**
- `interflux:review:fd-architecture` — structural review
- `interflux:review:fd-quality` — naming, conventions, idioms

**Risk-based (based on file paths and content):**
- Auth/crypto/input handling/secrets → `interflux:review:fd-safety`
- Database/migration/schema/backfill → `interflux:review:fd-correctness` + `data-migration-expert`
- Performance-critical paths → `interflux:review:fd-performance`
- Concurrent/async code → `interflux:review:fd-correctness`
- User-facing flows → `interflux:review:fd-user-product`

**Threshold:** Don't run more than 5 agents total. Prioritize by risk.

**Dispatch:** All agents run in parallel via Task tool with `run_in_background: true`.

**Key Finding:** quality-gates uses a **fixed cap (5 agents)** with risk-based selection. Simpler than flux-drive's dynamic ceiling.

### Topology 2: flux-drive (2-12 agents, staged)

**File:** `plugins/interflux/skills/flux-drive/SKILL.md`, `docs/spec/core/staging.md`

**Stage 1:**
- Top 40% by relevance score (min: 2, max: 5)
- Launch in parallel
- Timeout: 5 minutes for Haiku, 10 minutes for Sonnet/Opus

**Stage 2:**
- Conditional (based on Stage 1 findings)
- User approval required
- Launch in parallel if approved

**Key Finding:** flux-drive uses **two-stage topology** with conditional expansion. Agent count varies 2-12 based on review complexity.

### Topology 3: interpeer (2 agents)

**File:** `hub/clavain/commands/interpeer.md`

**Agents:**
- Host agent (e.g., Claude Opus 4.6)
- Other agent (auto-detected: Codex or Oracle)

**Modes:**
- **Quick mode:** Single second-opinion call
- **Deep mode:** Switch to Oracle for deeper review
- **Council mode:** Get consensus
- **Mine mode:** Focus on disagreements

**Key Finding:** interpeer is a **2-agent topology** — host + one other AI. Simplest multi-agent pattern.

### Topology 4: Parallel dispatch (variable, interserve mode)

**File:** `hub/clavain/commands/sprint.md` (lines 131-133)

**Pattern:** When interserve mode is active and plan has independent modules, dispatch them in parallel using `dispatching-parallel-agents` skill. Agent count is **plan-driven** (one agent per independent module).

**Key Finding:** Parallel dispatch topology is **task-driven** — agent count matches module count, not fixed.

### Summary: Existing Topologies

| Topology | Agent Count | Dispatch Strategy | Conditional Expansion? |
|----------|-------------|-------------------|------------------------|
| quality-gates | 2-5 (fixed cap) | Risk-based selection, parallel launch | No |
| flux-drive | 2-12 (dynamic) | Scored triage, two-stage | Yes (Stage 2) |
| interpeer | 2 (fixed) | Host + other AI | Yes (deep/council modes) |
| Parallel dispatch | Variable (plan-driven) | One per module | No |

---

## 3. What the Brainstorm Doc Says About Topology Experiments

**File:** `hub/clavain/docs/brainstorms/2026-02-14-clavain-vision-philosophy-brainstorm.md`

### Oracle's #1 Priority: Outcome-Based Agent Analytics v1

Lines 228-234:

```
Oracle's #1 Priority: Outcome-Based Agent Analytics (v1 Deliverable)
1. Unified trace/event log — per-agent (tokens, latency, model, context size, tool calls), 
   per-gate (pass/fail + reasons), per-human-touch (overrides, time-to-decision)
2. 5 Clavain Discipline KPIs — defect escape rate, human override rate by agent/domain, 
   cost per landed change, time-to-first-signal, redundant work ratio
3. Measured feedback loop — agents with low precision get smaller scope; domains with 
   high defect escapes get stricter gates; expensive agents invoked only if early 
   screeners detect risk
4. One empirical experiment — run same tasks with 2/4/6/8 agents, plot quality vs. 
   cost vs. time vs. attention, derive 2-3 topology templates to standardize
```

**Key Quote (line 234):**

> "Make the discipline measurable and reproducible before you scale the constellation. Build the truth engine, then let everything else compete for survival under data."

### Research Area #20: Latency Budgets as First-Class Constraints (Oracle)

Lines 188-189:

```
Time-to-feedback alongside token cost. 12 agents cheaper than 8 doesn't matter if 3x 
slower and breaks flow. Need time-per-gate and time-to-first-signal optimization. 
Latency budgets should be as explicit as token budgets.
```

**Key Finding:** The topology experiment is Oracle's **primary empirical recommendation**. The question isn't "should we run it?" but "what do we measure?"

### Weakest Parts / Tensions (Oracle Feedback)

Lines 199-209:

```
3. **More agents can increase attention burn.** Scaling agents without topology discipline 
   and output compression means more noise and more review fatigue. Contradicts "human 
   attention is the bottleneck."

4. **Autonomy before observability.** Adaptive routing and cross-project learning are 
   automation multipliers. Doing them before discipline telemetry creates an 
   un-debuggable system.

10. (Oracle) What is the right topology for multi-agent review? Need empirical data 
    (2/4/6/8 agent experiment).
```

**Key Finding:** Oracle argues that topology is **currently a guess**. The experiment is needed to ground the system in data instead of heuristics.

---

## 4. Task Types Mentioned in iv-7z28 Bead Description

**Bead:** iv-7z28 — "Run topology experiment: 2/4/6/8 agents on same tasks"

**Description excerpt:**

> Run the same set of real tasks (planning, code review, refactor, docs, bugfix) with 2, 4, 6, and 8 agents.

**5 Task Types:**

1. **planning** — e.g., PRD review, architecture plan
2. **code review** — e.g., diff review, PR review
3. **refactor** — e.g., refactoring plan review
4. **docs** — e.g., README review, AGENTS.md review
5. **bugfix** — e.g., bug investigation, root cause analysis

**Additional Context (iv-705b bead):**

iv-705b ("Design agent evals as CI harness") mentions the same 5 task types as the foundation for agent regression testing:

> a small corpus of real tasks (planning, code review, refactor, docs, bugfix) with expected properties (not exact text)

**Key Finding:** These 5 task types are intended as the **standard evaluation corpus** for both topology experiments (iv-7z28) and agent evals as CI (iv-705b).

---

## 5. How Galiana Measures Agent Performance

**File:** `hub/clavain/galiana/analyze.py`

### 5 Clavain Discipline KPIs

Galiana computes 5 KPIs from telemetry data (`~/.clavain/telemetry.jsonl`) and findings docs (`docs/research/flux-drive/**/findings.json`):

#### KPI 1: Defect Escape Rate

```python
def compute_defect_escape_rate(events):
    """Defect escape rate = defect reports / unique beads that reached done."""
    defects = sum(1 for e in events if e.get("event") == "defect_report")
    shipped = {
        bead for e in events
        if e.get("event") == "phase_transition" and e.get("phase") == "done"
    }
    return safe_rate(defects, len(shipped))
```

**Measures:** How many shipped beads had escaped defects.

#### KPI 2: Human Override Rate

```python
def compute_human_override_rate(events):
    """Override rate = gate_enforce(decision=skip) / gate_enforce(total)."""
    gate_events = [e for e in events if e.get("event") == "gate_enforce"]
    skipped = sum(1 for e in gate_events if e.get("decision") == "skip")
    return safe_rate(skipped, len(gate_events))
```

**Measures:** How often humans override agent recommendations. Includes breakdown by gate tier.

#### KPI 3: Cost Per Landed Change

```python
def compute_cost_per_landed_change(tool_events, shipped_beads):
    """Compute avg tool calls and avg sessions per shipped bead."""
    tool_count = len(tool_events)
    session_count = len({e.get("_session_id") for e in tool_events})
    shipped_count = len(shipped_beads)
    return {
        "avg_tools": round(tool_count / shipped_count, 4),
        "avg_sessions": round(session_count / shipped_count, 4),
    }
```

**Measures:** Resource usage per shipped bead (tool calls + sessions). Requires tool-time plugin data.

#### KPI 4: Time-to-First-Signal

```python
def compute_time_to_first_signal():
    """Current schema placeholder until signal events include bead ids."""
    return {
        "avg_seconds": None,
        "p50": None,
        "p90": None,
        "note": "signal events don't link to beads yet",
    }
```

**Status:** Not yet implemented. Signal events don't include bead IDs in current schema.

**Planned Measures:** Latency from workflow start to first actionable finding.

#### KPI 5: Redundant Work Ratio

```python
def compute_findings_metrics(findings_docs):
    """Compute redundant work ratio and agent scorecard."""
    total = 0
    convergent = 0
    for finding in findings:
        total += 1
        convergence = int(finding.get("convergence", 1))
        if convergence > 1:
            convergent += 1
    return safe_rate(convergent, total)
```

**Measures:** What fraction of findings were flagged by multiple agents (convergence > 1). Higher ratio = more redundant work.

### Agent Scorecard

For each agent, Galiana tracks:

```python
scorecard[agent] = {
    "findings": 0,      # Total findings by this agent
    "p0_findings": 0,   # P0 (critical) findings
    "p1_findings": 0,   # P1 (important) findings
}
```

**Extraction logic:**

```python
def extract_finding_agents(finding):
    """Normalize agents from either `agent` or `agents` fields."""
    agents = []
    # Supports both singular "agent" and plural "agents" fields
    # Deduplicates and preserves order
    return deduped_agents
```

**Key Finding:** Galiana provides **per-agent precision tracking** (P0/P1 counts) and **convergence metrics** (redundant work ratio). These are the current foundation for measuring agent performance.

---

## 6. Existing Topology Configs or Agent Roster Files

### Agent Roster: Plugin Agents (interflux)

**File:** `plugins/interflux/skills/flux-drive/references/agent-roster.md`

**7 core review agents:**

| Agent | subagent_type | Domain |
|-------|--------------|--------|
| fd-architecture | interflux:review:fd-architecture | Module boundaries, coupling, patterns, complexity |
| fd-safety | interflux:review:fd-safety | Threats, credentials, trust, deploy risk, rollback |
| fd-correctness | interflux:review:fd-correctness | Data consistency, races, transactions, async bugs |
| fd-quality | interflux:review:fd-quality | Naming, conventions, testing, language idioms |
| fd-user-product | interflux:review:fd-user-product | User flows, UX friction, value prop, scope |
| fd-performance | interflux:review:fd-performance | Bottlenecks, memory, algorithmic complexity, scaling |
| fd-game-design | interflux:review:fd-game-design | Balance, pacing, psychology, feedback loops, emergent behavior |

**5 research agents:**

| Agent | subagent_type | Domain |
|-------|--------------|--------|
| best-practices-researcher | interflux:research:best-practices-researcher | Industry best practices, common patterns |
| framework-docs-researcher | interflux:research:framework-docs-researcher | Framework-specific documentation |
| git-history-analyzer | interflux:research:git-history-analyzer | Historical context from git log |
| learnings-researcher | interflux:research:learnings-researcher | Past solutions from docs/solutions/ |
| repo-research-analyst | interflux:research:repo-research-analyst | Cross-repo patterns |

**Key Finding:** No "topology config" file exists. Agent selection is **algorithmic** (scoring + slot ceiling) rather than declarative.

### Domain Profiles: 11 Domains

**Directory:** `plugins/interflux/config/flux-drive/domains/`

**11 domain profiles:**
1. cli-tool.md
2. claude-code-plugin.md
3. data-pipeline.md
4. desktop-tauri.md
5. embedded-systems.md
6. game-simulation.md
7. library-sdk.md
8. ml-pipeline.md
9. mobile-app.md
10. tui-app.md
11. web-api.md

**Each profile contains:**
- Detection signals (directories, files, frameworks, keywords)
- Injection criteria (domain-specific review bullets per agent)
- Optional: domain-specific agent specs (e.g., game-simulation has fd-simulation-kernel, fd-game-systems, fd-agent-narrative)

**Key Finding:** Domain profiles guide **agent behavior** (injection criteria) but do not define **topology templates**. They affect scoring bonuses (+1 or +2) but not fixed agent counts.

### Domain Adjacency Map

**File:** `plugins/interflux/docs/spec/core/staging.md` (lines 62-74)

```yaml
adjacency:
  architecture: [performance, quality]
  correctness: [safety, performance]
  safety: [correctness, architecture]
  quality: [architecture, user-product]
  user-product: [quality, game-design]
  performance: [architecture, correctness]
  game-design: [user-product, correctness, performance]
```

**Key Finding:** This is the only **hardcoded topology structure** in the codebase. It defines which agents are "adjacent" for expansion scoring, but does not define fixed topologies like "always run these 3 agents together."

---

## Summary of Findings

### 1. Agent Count Decision

flux-drive uses a **dynamic slot ceiling** (4-12 agents) based on scope + domains + flux-gen agents. Agents are scored 0-7 and ranked. Top 40% go to Stage 1 (parallel launch), remainder to Stage 2 (conditional expansion). quality-gates uses a simpler **fixed cap (5 agents)** with risk-based selection.

### 2. Existing Topologies

4 topologies exist:
- **quality-gates:** 2-5 agents, risk-based, parallel
- **flux-drive:** 2-12 agents, scored triage, two-stage with conditional expansion
- **interpeer:** 2 agents (host + other AI), modes for depth/consensus
- **Parallel dispatch:** Variable (plan-driven), one agent per module

### 3. Brainstorm Doc Insights

Oracle's **#1 priority** is the topology experiment (iv-7z28). It's the foundation for data-driven agent selection. Oracle argues current topology is **heuristic-based** and needs empirical grounding. Key metrics: quality, cost, time, human attention.

Oracle identified **tension #3:** "More agents can increase attention burn." The experiment should measure **coordination tax** and **when more agents hurt**.

### 4. Task Types

5 task types for the experiment: **planning, code review, refactor, docs, bugfix**. These are also the foundation for agent evals as CI (iv-705b).

### 5. Galiana Measurement

Galiana computes 5 KPIs:
1. **Defect escape rate** (defects / shipped beads)
2. **Human override rate** (gate skips / total gates)
3. **Cost per landed change** (tool calls + sessions / shipped beads)
4. **Time-to-first-signal** (not yet implemented)
5. **Redundant work ratio** (convergent findings / total findings)

Plus **agent scorecard** (findings, P0 count, P1 count per agent).

**Key Gap:** Time-to-first-signal is a **placeholder** — signal events don't include bead IDs yet. This is needed for the experiment's "time vs. quality" measurement.

### 6. Topology Configs

**No explicit topology config files exist.** Agent selection is algorithmic:
- Dynamic slot ceiling (4-12)
- Scoring algorithm (0-7)
- Domain adjacency map (hardcoded in staging.md)
- Domain profiles (11 domains, injection criteria)

**Key Finding:** To run the experiment, we need to **override** the dynamic ceiling with fixed topologies (2/4/6/8 agents) and measure outcomes.

---

## Next Steps for iv-7z28

1. **Define fixed topologies** for the experiment (override dynamic ceiling):
   - 2-agent: architecture + quality
   - 4-agent: architecture + quality + safety + correctness
   - 6-agent: 4-agent + performance + user-product
   - 8-agent: 6-agent + game-design + (research agent OR Oracle)

2. **Select 5 representative tasks** (one per type):
   - planning: PRD review or architecture plan
   - code review: PR diff review
   - refactor: refactoring plan review
   - docs: AGENTS.md review or README review
   - bugfix: bug investigation or root cause analysis

3. **Instrument time-to-first-signal** in telemetry (currently missing):
   - Add bead_id to signal events
   - Measure elapsed time from workflow start to first P0/P1 finding

4. **Run 5 tasks × 4 topologies = 20 reviews** and collect:
   - Quality: P0/P1 count, defect escape rate (via Galiana)
   - Cost: tool calls, tokens (via tool-time + Galiana)
   - Time: total elapsed, time-to-first-signal
   - Attention: human override rate, review time (manual tracking)

5. **Plot 4 dimensions:**
   - Quality vs. agent count (do 8 agents find more P0s than 2?)
   - Cost vs. agent count (is 12 agents cheaper than 8 via better orchestration?)
   - Time vs. agent count (do 8 agents take 4x longer than 2?)
   - Attention vs. agent count (do 8 agents create more review fatigue?)

6. **Derive 2-3 topology templates** to standardize:
   - Example: "For planning tasks, 4 agents (arch + quality + safety + correctness) is the sweet spot"
   - Example: "For bugfix tasks, 2 agents (arch + correctness) is sufficient"

---

**Generated:** 2026-02-15  
**Source Bead:** iv-7z28 (in_progress, phase: brainstorm)
