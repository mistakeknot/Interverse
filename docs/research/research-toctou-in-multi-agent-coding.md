# TOCTOU-Class Failures in Multi-Agent Code Generation Systems

**Research Date:** 2026-02-20
**Research Question:** What evidence exists for TOCTOU-class failures in real multi-agent code generation systems? Has anyone published incident reports or post-mortems about silent merge corruption from parallel agents?
**Context:** Evaluating whether TOCTOU failures are theoretical or practical in multi-agent coding, to decide between Phase 1 (Alternate A — minimal coordination) and Phase 3 (full OCC infrastructure).

---

## Executive Summary

**The evidence is mixed but increasingly compelling.** No one has published a detailed post-mortem documenting a specific silent merge corruption incident from parallel AI coding agents. However, the problem is acknowledged as real by every major player, and an entire ecosystem of tools (Clash, git worktree isolation, Augment Intent) has emerged specifically to prevent it. The absence of published incident reports likely reflects both the novelty of multi-agent coding and the fact that most teams hit these problems during internal development, not in production deployments.

**Key findings:**
1. **Cursor documented two failed coordination approaches** (locking and OCC) before arriving at a Planner/Worker/Judge hierarchy — the failures were real enough to force architectural redesign.
2. **Carlini's 16-agent Claude compiler project** reports "merge conflicts are frequent" but provides no data on whether any were resolved incorrectly (silent corruption).
3. **Google DeepMind quantified error amplification at 17.2x** for independent agents, though this measures semantic/logical errors, not file-level corruption.
4. **TOCTOU-Bench (August 2025)** measured 12% vulnerability rate in LLM agent trajectories, reduced to 8% with combined defenses.
5. **BoostSecurity demonstrated a real TOCTOU attack** against GitHub Copilot with a 3-second attack window — disclosed, acknowledged, and fixed.
6. **Cursor has a documented silent revert bug** where the Agent Review Tab causes code changes to silently revert due to IDE cache/disk state divergence.
7. **The Clash tool exists** specifically because parallel agents in worktrees create merge conflicts that go undetected until too late.

**Bottom line:** TOCTOU-class failures in multi-agent coding are **observed, not theoretical**, but the available evidence is primarily anecdotal and architectural (teams building defenses) rather than quantitative (measured failure rates in production). No published post-mortem exists describing silent merge corruption causing a production incident.

---

## Detailed Findings by System

### 1. Devin (Cognition)

**What we found:**
- Cognition's official blog acknowledges that "merge conflicts [...] Devin tends to struggle with" — a known limitation of their autonomous coding agent.
- Devin Enterprise includes "MultiDevin" for parallel task execution, but no published incident reports about coordination failures.
- No public post-mortem or incident database.

**Assessment:**
- **Failure mode:** Acknowledged (merge conflict resolution difficulty)
- **Severity:** Unclear — no data on whether failed resolutions caused silent corruption or loud errors
- **Mitigation:** Manual human resolution of merge conflicts
- **Quantitative data:** None published

**Sources:**
- [Devin GA announcement](https://cognition.ai/blog/devin-generally-available)
- [Devin 2.0](https://cognition.ai/blog/devin-2)

---

### 2. SWE-agent / SWE-bench (Princeton)

**What we found:**
- SWE-agent is single-agent by design — each instance works on one issue in one Docker container. No multi-agent coordination is needed for the benchmark itself.
- Verdent AI achieved 76.1% on SWE-bench Verified using multi-agent parallel execution, but details of their coordination mechanism are not published.
- SWE-ReX supports "massively parallel" agent runs, but these are parallel *instances* on *separate tasks*, not multiple agents editing the same codebase.
- During training, DeepSWE (Together AI) spawned 512 Docker containers in parallel for RL iterations, which crashed the Docker daemon — an infrastructure failure, not a TOCTOU failure.

**Assessment:**
- **Failure mode:** Not applicable — SWE-bench is fundamentally a single-agent benchmark
- **Severity:** N/A
- **Mitigation:** N/A (isolation by design)
- **Quantitative data:** None on coordination failures

**Sources:**
- [SWE-agent GitHub](https://github.com/SWE-agent/SWE-agent)
- [Verdent AI multi-agent approach](https://jangwook.net/en/blog/en/multi-agent-swe-bench-verdent/)
- [SWE-ReX GitHub](https://github.com/swe-agent/SWE-ReX)

---

### 3. OpenHands (formerly OpenDevin)

**What we found:**
- Published at ICLR 2025, OpenHands supports hierarchical agent delegation via `AgentDelegateAction`.
- Agent isolation is achieved through Docker containerization — each agent operates in its own container, torn down post-session.
- No published documentation of coordination failures between agents.
- The architecture prevents cross-agent file interference by design (separate containers).

**Assessment:**
- **Failure mode:** Prevented by architecture (container isolation)
- **Severity:** N/A
- **Mitigation:** Docker containerization, filesystem isolation
- **Quantitative data:** None on coordination failures

**Sources:**
- [OpenHands paper (ICLR 2025)](https://arxiv.org/abs/2407.16741)
- [OpenHands GitHub](https://github.com/OpenHands/OpenHands)

---

### 4. Cursor

**What we found — this is the richest source of evidence:**

**4a. Failed coordination approaches (documented by Mike Mason, Jan 2026):**
- Cursor experimented with **locking**: Agents held locks too long, reducing effective throughput from 20 agents to 2-3. This is a liveness failure, not a correctness failure.
- Cursor experimented with **optimistic concurrency control**: Agents became risk-averse and avoided hard tasks. This is a behavioral failure — the OCC mechanism worked but changed agent behavior negatively.
- **Successful approach**: Planner/Worker/Judge hierarchy. Workers execute tasks independently, push changes when done. No inter-worker coordination. Judges evaluate at cycle boundaries.

**4b. Silent revert bug (documented in community):**
- A file locking conflict between the Agent Review Tab and the editor causes **code changes to silently revert**. The AI writes changes to disk (visible in `git diff`), but the IDE cache doesn't update — the user sees old code while new code is committed.
- **This is a real TOCTOU-class failure**: The check (what the IDE shows) diverges from the use (what's on disk).
- Workaround: Close the Agent Review Tab before using "Fix in Chat."

**4c. Long-running agent state drift:**
- Long-running agents lose sync between their mental model and disk state over time. Agents start calling non-existent functions.
- Mitigation: Force periodic re-indexing. Keep sessions under 2 hours.

**4d. FastRender project (Jan 2026):**
- Cursor claimed agents built a browser (1M+ lines, 1000 files) in one week using GPT-5.2 with hierarchical orchestration.
- Reality check: Code didn't compile at announcement. When functional, pages loaded in "a literal minute."
- No published data on how many merge conflicts occurred or whether any caused silent corruption.

**Assessment:**
- **Failure mode:** OBSERVED — both coordination failures (locking, OCC behavioral issues) and silent revert bug
- **Severity:** The silent revert is **high severity** — changes appear to be saved but the user sees stale state
- **Mitigation:** Architectural redesign (Planner/Worker/Judge), workarounds for IDE bugs
- **Quantitative data:** Throughput reduction from 20 to 2-3 agents under locking. No data on silent revert frequency.

**Sources:**
- [Mike Mason: AI Coding Agents in 2026](https://mikemason.ca/writing/ai-coding-agents-jan-2026/)
- [Cursor 2.0 multi-agent review](https://aitoolanalysis.com/cursor-2-0-review-2025/)
- [Cursor tips (murataslan1)](https://github.com/murataslan1/cursor-ai-tips)

---

### 5. Aider

**What we found:**
- Aider explicitly warns: "While waiting for Aider's reply, it's unwise to edit files that have been added to the chat, as edits and Aider's edits might conflict."
- Aider's EditBlock format (`<<<<<<< ... >>>>>>>`) is designed for single-agent operation — it assumes exclusive access to files being edited.
- No multi-agent coordination mechanism exists in Aider.
- Aider's approach is fundamentally single-agent: one human, one AI, taking turns.

**Assessment:**
- **Failure mode:** Acknowledged (user warned not to edit simultaneously)
- **Severity:** Unknown — no data on what happens when the user ignores the warning
- **Mitigation:** User discipline (don't edit while Aider is working)
- **Quantitative data:** None

**Sources:**
- [Aider FAQ](https://aider.chat/docs/faq.html)
- [Aider edit formats](https://aider.chat/docs/more/edit-formats.html)

---

### 6. Claude Code / Anthropic

**What we found:**

**6a. Carlini's 16-agent compiler project (Jan 2026):**
- 16 Claude Opus 4.6 agents built a 100,000-line Rust C compiler over ~2,000 sessions ($20,000).
- **Coordination mechanism**: File-based task locking via `current_tasks/` directory. If two agents claim the same task, git synchronization forces the second to pick a different one.
- **Merge conflict handling**: "Merge conflicts are frequent, but Claude is smart enough to figure that out." Each agent pulls, merges, pushes, then removes its lock.
- **No data on silent corruption**: The blog post does not mention any instance of incorrect merge resolution. The only near-failure was Claude executing `pkill -9 bash` and killing itself.
- **No quantitative data** on conflict frequency, resolution success rate, or time spent on merge resolution.

**6b. Claude Code worktree isolation:**
- Claude Code creates isolated git worktrees for each agent in multi-agent mode.
- The lead agent creates a plan, spawns subagents with role definitions, and reconciles outputs.
- File conflict detection prevents agents from "stepping on each other" in claude-swarm orchestration.

**6c. Resource exhaustion:**
- One documented case where 24 parallel subagent processes were spawned within a 2-minute window, overwhelming disk I/O. Infrastructure failure, not coordination failure.

**Assessment:**
- **Failure mode:** Merge conflicts are confirmed frequent. No data on whether any were resolved incorrectly.
- **Severity:** Unknown — "Claude is smart enough" is the only assessment, with no evidence backing it
- **Mitigation:** File-based task locking, git worktree isolation
- **Quantitative data:** ~2,000 sessions, 16 agents, 100K lines. No conflict-specific metrics.

**Sources:**
- [Anthropic: Building a C compiler](https://www.anthropic.com/engineering/building-c-compiler)
- [Claude Code agent teams](https://www.sitepoint.com/anthropic-claude-code-agent-teams/)
- [Feature request: parallel agent execution](https://github.com/anthropics/claude-code/issues/3013)

---

### 7. OpenAI Codex CLI

**What we found:**
- Each agent works in its own isolated copy of the codebase (via git worktrees or separate clones).
- When two agents modify the same file, their changes live in different branches/worktrees.
- Conflict resolution is manual: "the 'Apply' sync method attempts a patch; if it fails, use 'Overwrite' for one and manually merge the other."
- Multi-agent workflows are "currently experimental" and require explicit opt-in.

**Assessment:**
- **Failure mode:** Prevented by worktree isolation. Merge conflicts deferred to human resolution.
- **Severity:** Low for agent work (isolated). Unknown for merge phase.
- **Mitigation:** Git worktree isolation, manual merge
- **Quantitative data:** None

**Sources:**
- [Codex CLI multi-agents](https://developers.openai.com/codex/multi-agent/)
- [Codex CLI features](https://developers.openai.com/codex/cli/features/)

---

### 8. GitHub Copilot / Copilot Workspace

**What we found:**

**8a. Bot-Delegated TOCTOU (BoostSecurity, June 2025):**
- **This is the strongest documented TOCTOU attack against a coding agent.**
- When a maintainer assigns Copilot to an issue, there is a ~3-second window before the bot reads the issue content. An attacker can swap the issue text for a malicious prompt during this window.
- The bot, with `workflow: write` permissions, would create whatever the attacker requested (e.g., a GitHub Actions workflow that exfiltrates secrets).
- **Disclosure timeline**: Reported June 3, 2025 (HackerOne). Acknowledged June 4. Fixed by November 2025.
- **Status**: Demonstrated in controlled research, not confirmed exploited in the wild.

**8b. Copilot parallel agents:**
- Copilot Swarm Orchestrator uses per-agent git branches with dependency-aware scheduling.
- Merge conflicts are handled by "reviewing each worktree and merging sequentially."
- Auto-compaction prevents context overflow when approaching 95% token limit.

**Assessment:**
- **Failure mode:** DEMONSTRATED (TOCTOU attack with 3-second window)
- **Severity:** HIGH — secrets exfiltration, supply chain compromise
- **Mitigation:** Fixed by GitHub (specific fix not disclosed)
- **Quantitative data:** 3-second attack window. No frequency data.

**Sources:**
- [BoostSecurity: Bot-Delegated TOCTOU](https://boostsecurity.io/blog/split-second-side-doors-how-bot-delegated-toctou-breaks-the-cicd-threat-model)
- [Copilot Swarm Orchestrator](https://github.com/moonrunnerkc/copilot-swarm-orchestrator)

---

### 9. Windsurf (Codeium)

**What we found:**
- Windsurf Wave 13 added git worktree support for parallel Cascade sessions.
- Documented terminal rendering bug: concurrent Claude Code parallel agents updating display simultaneously causes language server memory leaks and system crashes.
- No documented file-level corruption or silent merge failures.

**Assessment:**
- **Failure mode:** Infrastructure (terminal rendering), not coordination
- **Severity:** Low (crashes, not corruption)
- **Mitigation:** Git worktree isolation, debug console workaround
- **Quantitative data:** None

**Sources:**
- [Windsurf changelog](https://windsurf.com/changelog)
- [Windsurf Wave 13](https://www.testingcatalog.com/windsurf-wave-13-brings-free-swe-1-5-and-new-upgrades/)

---

### 10. Augment Code (Intent)

**What we found:**
- Augment Code's Intent platform explicitly positions itself against the coordination problem: "most AI coding tools [...] run agents side by side with coordination being manual and agents' work conflicting as soon as code changes."
- Their architecture: Coordinator agent creates spec, Implementor agents work in waves, Verifier agent checks results against spec.
- Git worktrees for isolation, file-level locking to prevent simultaneous edits.
- Currently in public beta.

**Assessment:**
- **Failure mode:** Acknowledged as the central problem their product solves
- **Severity:** Implied high (they built a company around preventing it)
- **Mitigation:** Spec-driven coordination, waves, verification
- **Quantitative data:** None published

**Sources:**
- [Augment Code Intent](https://www.augmentcode.com/product/intent)
- [The End of Linear Work](https://www.augmentcode.com/blog/the-end-of-linear-work)

---

## Academic Research

### 11. TOCTOU-Bench (August 2025)

**Paper:** "Mind the Gap: Time-of-Check to Time-of-Use Vulnerabilities in LLM-Enabled Agents" (arXiv 2508.17155)

**Key findings:**
- First systematic study of TOCTOU vulnerabilities in LLM agents.
- 66 realistic user tasks designed to evaluate TOCTOU susceptibility.
- **12% of executed agent trajectories contained TOCTOU vulnerabilities** (baseline).
- Three defenses tested:
  - **Prompt Rewriting**: 3% decrease in vulnerable plan generation
  - **State Integrity Monitoring**: 95% reduction in attack window
  - **Tool Fuser**: Reduces sequential tool calls that create TOCTOU windows
- Combined defenses reduced vulnerability from 12% to 8%.
- Automated detection accuracy: only 25%.

**Assessment:**
- **Failure mode:** Measured at 12% baseline vulnerability rate
- **This is the strongest quantitative evidence available.** 12% is not rare.
- The low automated detection rate (25%) means most TOCTOU failures go undetected.
- Focus is on security (malicious state modification), not multi-agent coordination, but the underlying mechanism is identical.

**Sources:**
- [arXiv paper](https://arxiv.org/abs/2508.17155)
- [Promptfoo LLM Security Database](https://www.promptfoo.dev/lm-security-db/vuln/llm-agent-toctou-vulnerabilities-90d35ca4)

---

### 12. MAST: Why Do Multi-Agent LLM Systems Fail? (NeurIPS 2025)

**Paper:** Cemri, Pan, Yang et al. "Why Do Multi-Agent LLM Systems Fail?"

**Key findings:**
- 14 unique failure modes across 3 categories: system design, inter-agent misalignment, task verification.
- Analyzed 150 traces with expert annotation (Cohen's kappa = 0.88).
- MAST-Data dataset: 1600+ annotated traces across 7 MAS frameworks.
- Models tested: GPT-4, Claude 3, Qwen2.5, CodeLlama.
- **The paper does not specifically isolate file-level TOCTOU or merge corruption** as a distinct failure mode, but "inter-agent misalignment" encompasses coordination failures that could manifest as conflicting edits.

**Assessment:**
- **Failure mode:** Taxonomy exists but doesn't specifically call out TOCTOU/file corruption
- **Quantitative data:** "Performance gains on popular benchmarks are often minimal" — suggesting coordination overhead frequently erases benefits
- Published at NeurIPS 2025 Datasets & Benchmarks track

**Sources:**
- [arXiv paper](https://arxiv.org/abs/2503.13657)
- [NeurIPS poster](https://neurips.cc/virtual/2025/loc/san-diego/poster/121528)

---

### 13. Towards a Science of Scaling Agent Systems (Google DeepMind, Dec 2025)

**Paper:** Google DeepMind + MIT

**Key findings:**
- **Independent agents amplify errors 17.2x** (95% CI: [14.3, 20.1]) compared to single-agent baselines.
- Centralized coordination contains amplification to 4.4x.
- Error taxonomy: Logical Contradiction (12.3-18.7%), Numerical Drift (20.9-24.1%), Context Omission (15.8-25.2%), Coordination Failure (0-12.4%).
- Five architectures tested: Single, Independent, Decentralized, Centralized, Hybrid.
- Performance deltas ranged from -70% to +81% depending on task-architecture alignment.
- Predictive framework correctly identifies optimal strategy for 87% of configurations.
- **Critically: does NOT test file-level concurrent editing.** Benchmarks are BrowseComp-Plus, Finance-Agent, PlanCraft, Workbench — reasoning/planning tasks, not code generation.

**Assessment:**
- **The 17.2x error amplification is for semantic/logical errors, not file corruption.** But it demonstrates that unstructured multi-agent systems have fundamental coordination problems.
- The finding that coordination helps (4.4x vs 17.2x) supports building coordination infrastructure, even if the specific failure mode measured isn't TOCTOU.

**Sources:**
- [arXiv paper](https://arxiv.org/abs/2512.08296)
- [Google Research blog](https://research.google/blog/towards-a-science-of-scaling-agent-systems-when-and-why-agent-systems-work/)

---

### 14. "Bag of Agents" Error Trap (Towards Data Science, Jan 2026)

Analysis of the DeepMind paper above, adding:
- "The secret to building robust, performant systems is the Topology of Coordination and not simply adding more agents."
- Identifies 10 fundamental archetypes for decomposing multi-agent systems.
- Accuracy gains saturate beyond the 4-agent threshold without structured topology.

**Sources:**
- [Towards Data Science article](https://towardsdatascience.com/why-your-multi-agent-system-is-failing-escaping-the-17x-error-trap-of-the-bag-of-agents/)

---

## Purpose-Built Tools (Evidence the Problem Is Real)

### 15. Clash (Rust CLI, 2025)

- Open-source tool specifically built to detect merge conflicts across git worktrees used by parallel AI coding agents.
- Supports Claude Code, Cursor, Codex, Windsurf.
- Uses `git merge-tree` (via gix) to simulate three-way merges without modifying the repo.
- **Read-only conflict detection** — does not resolve, only warns.
- The Hacker News discussion (no comments with real-world data) and the README both frame this as addressing an anticipated/emerging problem rather than documenting past incidents.

**Sources:**
- [Clash GitHub](https://github.com/clash-sh/clash)
- [HN discussion](https://news.ycombinator.com/item?id=46887382)

### 16. Git Worktree Ecosystem

Multiple blog posts and talks (including a Microsoft AI Dev Days talk) document the emerging pattern of using git worktrees to isolate parallel AI agents:
- [Microsoft AI Dev Days: Parallel AI Agents with Git Worktrees](https://gist.github.com/johnlindquist/2c85b171b51b6a6684a0f5e037814198)
- [Git Worktrees: The Secret Weapon](https://medium.com/@mabd.dev/git-worktrees-the-secret-weapon-for-running-multiple-ai-coding-agents-in-parallel-e9046451eb96)
- [Upsun Developer Center](https://devcenter.upsun.com/posts/git-worktrees-for-parallel-ai-coding-agents/)

The sheer volume of content about worktree isolation (10+ blog posts in late 2025 / early 2026) indicates the community recognizes concurrent editing as a real problem worth solving.

---

## Industry Reports

### 17. Anthropic 2026 Agentic Coding Trends Report

- Documents running 5-10 Claude Code sessions in parallel.
- Recommends git worktree isolation.
- Acknowledges that multi-agent coordination is a key trend requiring "better task breakdown, coordination methods, and visibility across concurrent agent sessions."

**Sources:**
- [Anthropic report](https://resources.anthropic.com/2026-agentic-coding-trends-report)

### 18. Google DORA 2025 Report (cited by Mason)

- 90% AI adoption increase correlates with:
  - 9% increase in bug rates
  - 91% increase in code review time
  - 154% increase in PR size
- Not specific to multi-agent coordination, but demonstrates that AI-generated code has quality implications at scale.

---

## Failure Mode Taxonomy

Based on this research, TOCTOU-class failures in multi-agent coding systems fall into these categories:

| # | Failure Mode | Observed? | Severity | Example |
|---|---|---|---|---|
| 1 | **Merge conflict (loud)** | YES, frequent | Low | Carlini's 16 agents: "merge conflicts are frequent" |
| 2 | **Merge conflict (silent/incorrect resolution)** | Not documented | HIGH if it exists | No published incidents |
| 3 | **IDE cache/disk divergence** | YES | High | Cursor silent revert bug |
| 4 | **Agent state drift** | YES | Medium | Cursor long-running agents calling non-existent functions |
| 5 | **Task lock contention** | YES | Medium (liveness) | Cursor locking: 20 agents -> 2-3 throughput |
| 6 | **OCC behavioral effects** | YES | Medium | Cursor OCC: agents avoid hard tasks |
| 7 | **External state TOCTOU** | YES, measured | High | TOCTOU-Bench: 12% vulnerability rate |
| 8 | **Bot-delegated TOCTOU** | DEMONSTRATED | Critical | BoostSecurity vs. Copilot: 3-second attack window |
| 9 | **Error amplification** | YES, measured | High | DeepMind: 17.2x for independent agents |
| 10 | **Resource exhaustion** | YES | Medium | 24 Claude subagents overwhelming disk I/O |

---

## Assessment: Theoretical vs. Practical

### Definitely Practical (Observed in Real Systems)
1. **Merge conflicts between parallel agents** — confirmed by Carlini (Claude), acknowledged by Devin, mitigated by everyone via worktrees
2. **Cursor silent revert** — a genuine TOCTOU-class failure where disk state and editor state diverge
3. **Agent state drift** — agents' mental models diverge from actual file state over time
4. **Coordination overhead degrading performance** — Cursor's locking/OCC experiments
5. **TOCTOU in agent tool chains** — 12% baseline vulnerability rate (TOCTOU-Bench)
6. **Error amplification** — 17.2x for uncoordinated agents (DeepMind)

### Likely Practical but Undocumented
1. **Silent incorrect merge resolution** — Carlini says Claude "figures it out" but provides no verification data. Given that merge resolution is an LLM reasoning task with nonzero error rates, some incorrect resolutions are statistically inevitable over 2,000 sessions.
2. **Partial file corruption from concurrent writes** — prevented by worktree isolation in most systems, but systems without isolation (like our interlock shared-directory model) are vulnerable.

### Theoretical / Not Yet Observed
1. **Cascading corruption from one bad merge** — a silently incorrect merge that causes subsequent agents to build on a broken foundation. Plausible but not documented.
2. **Semantic merge correctness** — two agents make individually correct but mutually incompatible changes that compile but produce incorrect behavior. This is the hardest class to detect.

---

## Implications for Our Decision

### Arguments for Stopping at Phase 1 (Alternate A)
1. **No published post-mortem** documents silent merge corruption causing a real incident.
2. **Git worktree isolation is the industry standard** and prevents most file-level TOCTOU.
3. **Our system is small** — typically 2-4 agents, not 16+. The 17.2x error amplification is for larger systems.
4. **The practical failures documented are mostly loud** (merge conflicts) or infrastructure (resource exhaustion), not silent corruption.

### Arguments for Investing in Phase 3 (Full OCC)
1. **12% baseline TOCTOU vulnerability** (TOCTOU-Bench) is not rare.
2. **Only 25% automated detection** means most TOCTOU failures go unnoticed.
3. **Cursor's experience** shows that both naive locking AND naive OCC fail — the right coordination architecture matters and is non-obvious.
4. **The industry is converging on coordination infrastructure** (Augment Intent, Clash, worktree isolation) — we'd be aligned with the trajectory.
5. **Silent incorrect merge resolution is statistically inevitable** over enough sessions, even if no one has published an incident report.
6. **We use a shared-directory model** (interlock), not worktree isolation, making us more exposed than systems that isolate by default.

### Recommendation

**The reviewer's challenge was valid — there is no smoking gun.** But the absence of evidence is not evidence of absence. The fact that:
- Every major player has invested in coordination infrastructure
- Cursor tried and failed with two coordination approaches before finding one that works
- TOCTOU-Bench measured 12% baseline vulnerability
- Google DeepMind measured 17.2x error amplification
- A purpose-built tool (Clash) was created specifically for this problem

...suggests the problem is real enough to justify Phase 1 (basic coordination/detection) but does not yet justify Phase 3 (full OCC with versioned state) without our own incident data.

**Recommended approach:** Implement Phase 1 with telemetry to measure our actual conflict rate. If conflicts occur at >1% of multi-agent sessions, escalate to Phase 3. If they don't, stop at Phase 1.

---

## Source Index

### Primary Research Papers
- [TOCTOU-Bench: Mind the Gap (arXiv 2508.17155)](https://arxiv.org/abs/2508.17155)
- [MAST: Why Do Multi-Agent LLM Systems Fail? (NeurIPS 2025)](https://arxiv.org/abs/2503.13657)
- [Towards a Science of Scaling Agent Systems (DeepMind, Dec 2025)](https://arxiv.org/abs/2512.08296)
- [OpenHands (ICLR 2025)](https://arxiv.org/abs/2407.16741)
- [LLM-Based MAS for SE: Literature Review](https://arxiv.org/html/2404.04834v4)

### Industry Sources
- [Anthropic: Building a C Compiler with Parallel Claudes](https://www.anthropic.com/engineering/building-c-compiler)
- [Anthropic: 2026 Agentic Coding Trends Report](https://resources.anthropic.com/2026-agentic-coding-trends-report)
- [Mike Mason: AI Coding Agents in 2026](https://mikemason.ca/writing/ai-coding-agents-jan-2026/)
- [BoostSecurity: Bot-Delegated TOCTOU](https://boostsecurity.io/blog/split-second-side-doors-how-bot-delegated-toctou-breaks-the-cicd-threat-model)
- [Augment Code: Intent](https://www.augmentcode.com/blog/the-end-of-linear-work)

### Tools and Community
- [Clash: Merge conflict detection for parallel AI agents](https://github.com/clash-sh/clash)
- [Codex CLI multi-agents](https://developers.openai.com/codex/multi-agent/)
- [17x Error Trap analysis (TDS)](https://towardsdatascience.com/why-your-multi-agent-system-is-failing-escaping-the-17x-error-trap-of-the-bag-of-agents/)

### Agent Documentation
- [Aider FAQ (conflict warning)](https://aider.chat/docs/faq.html)
- [Devin docs](https://docs.devin.ai/)
- [OpenHands GitHub](https://github.com/OpenHands/OpenHands)
