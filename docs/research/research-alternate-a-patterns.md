# Research: "Alternate A" Pattern in Multi-Agent Orchestration

**Date:** 2026-02-20
**Question:** Are there production-grade examples of the "Alternate A" pattern — pinned snapshots + write-set conflict detection WITHOUT read-set tracking — in multi-agent orchestration systems?

## Definition of "Alternate A"

The pattern under investigation:
1. Each agent dispatch records a **base Git commit SHA** at start
2. Agent works in an **isolated worktree** pinned to that commit
3. At merge time, only **write-set conflicts** are checked (did another dispatch modify the same files?)
4. **No read-set tracking** (we don't track which files the agent read to make its decisions)

This is structurally equivalent to **Snapshot Isolation (SI)** from database theory, where transactions read from a consistent snapshot and only write-write conflicts are detected at commit time. The key theoretical concern is **write skew** — where two agents read overlapping data but write to disjoint files, each producing correct output in isolation but an inconsistent combined result.

---

## 1. Database Theory Foundation: Snapshot Isolation

### The Exact Analogy

Marc Brooker (Amazon, distributed systems researcher) crystallized the distinction in a December 2024 blog post:

- **Serializability** requires checking: `R2 ∩ W1 = ∅` (read-set vs write-set)
- **Snapshot Isolation** requires checking: `W2 ∩ W1 = ∅` (write-set vs write-set only)

Brooker notes: "Notice how similar those two statements are: one about R2 ∩ W1 and one about W2 ∩ W1. That's the only real difference in the rules."

The practical tradeoff: "Write sets are smaller than read sets, for the majority of OLTP applications (often MUCH smaller)." By ignoring read-write conflicts, SI avoids aborting transactions based on what they merely *read*, dramatically reducing abort rates.

SI permits **write skew anomalies** — two transactions read overlapping data but write to disjoint subsets, both committing despite violating application-level constraints. However, Brooker argues SI represents "a useful minimum in the sum of worries about anomalies and performance."

### Production Databases Using Write-Write-Only Detection (SI)

The following production databases implement Snapshot Isolation with write-write-only conflict detection:
- **Oracle** (since version 7, 1992)
- **PostgreSQL** (MVCC layer; SSI added later for full serializability)
- **MySQL/InnoDB** (REPEATABLE READ is actually SI)
- **Microsoft SQL Server** (2005+, optional RCSI mode)
- **MongoDB** (WiredTiger engine)
- **InterBase / Firebird**
- **CockroachDB** (uses SI as a base, with additional mechanisms for SSI)
- **TiDB/TiKV** (Percolator-based SI)

This is not a fringe pattern. It is the **default isolation level in most production databases worldwide**.

**Source:** [Snapshot Isolation vs Serializability — Marc Brooker](https://brooker.co.za/blog/2024/12/17/occ-and-isolation.html)

---

## 2. Multi-Agent Coding Systems

### 2.1 OpenAI Codex App — Pinned Worktrees, No Conflict Detection

**Pattern match: Strong (exact Alternate A)**

The Codex app (2025) implements almost exactly the Alternate A pattern:
- **Pinned snapshot:** "The starting commit will be the HEAD commit of the branch selected when you start your thread."
- **Isolated worktree:** Each agent operates in a detached HEAD worktree sharing the same `.git` metadata
- **Write-set conflict detection:** Not automated. The "Sync with local" feature offers two modes:
  - **Overwrite:** Destination matches source (destructive)
  - **Apply:** Calculates patches since nearest shared commit, applies changes (may surface conflicts)
- **No read-set tracking:** Not mentioned anywhere in documentation

The documentation acknowledges conflicts may occur: "In some cases, changes on your worktree might conflict with changes on your local checkout." Resolution is entirely manual via the sync options. There is no proactive detection of write-set overlaps between concurrent agents.

**Source:** [Codex App Worktrees](https://developers.openai.com/codex/app/worktrees/), [Codex Multi-Agent](https://developers.openai.com/codex/multi-agent/)

### 2.2 VS Code Background Agents (GitHub Copilot) — Pinned Worktree, Post-Hoc Merge

**Pattern match: Strong (exact Alternate A)**

VS Code's background agents (2025) use an identical architecture:
- **Pinned snapshot:** Agents commit changes to the worktree at end of each turn, aligned to commit history
- **Isolated worktree:** "VS Code automatically creates a separate folder for that session"
- **Write-set conflict detection:** At merge time only — "VS Code handles any conflicts with your working tree or staged files. If conflicts occur, a merge resolution experience helps you resolve them"
- **No read-set tracking:** Not mentioned

Documentation explicitly does not address scenarios where multiple background agents work simultaneously on the same repository. The conflict detection is purely reactive (at merge time) rather than proactive.

**Source:** [VS Code Background Agents](https://code.visualstudio.com/docs/copilot/agents/background-agents)

### 2.3 Claude Code (Anthropic) — Worktree Isolation, No Automated Conflict Layer

**Pattern match: Strong (exact Alternate A)**

Claude Code's agent teams and background agents use git worktrees for isolation. Each agent gets its own working directory. Conflict detection relies on git merge at integration time.

The ecosystem has spawned several third-party coordination tools:
- **Claude Squad** — "guarantees absolute code isolation for every task via git worktrees"
- **Conductor** — "each agent gets its own isolated Git worktree"
- **parallel-cc** — coordinates parallel Claude Code sessions using git worktrees + E2B sandboxes

None of these tools track read-sets. All rely on write-set conflicts surfacing at merge time.

**Source:** [Claude Code Agent Teams](https://code.claude.com/docs/en/agent-teams), [Conductor](https://www.conductor.build/)

### 2.4 OpenHands — Branch-Per-Agent, Human-in-the-Loop Merge

**Pattern match: Moderate (Alternate A with human gating)**

OpenHands' Refactor SDK for massive parallel refactors:
- Creates a rolling implementation branch (e.g., `v1-refactor`)
- Spawns individual agent branches from this (e.g., `v1-refactor/component-a`)
- Each agent submits PRs back to the rolling branch
- Human reviews each PR before merging

The documentation explicitly states: "Don't worry about merge conflicts — agents can usually work through those easily." No write-set or read-set tracking exists. Conflict detection is entirely delegated to git merge + human review.

For the GitHub Resolver bot (bulk issue fixing), agents work in Docker sandbox containers. Each gets a full isolated environment. No coordination mechanism prevents two agents from modifying the same files.

**Source:** [OpenHands Parallel Agents](https://openhands.dev/blog/automating-massive-refactors-with-parallel-agents)

### 2.5 Windsurf (Codeium) — Parallel Cascade Sessions with Worktrees

**Pattern match: Strong (Alternate A)**

Windsurf added "Parallel Multi-Agent Sessions" in 2025, using git worktrees with side-by-side panes. Each Cascade agent operates in its own worktree. No read-set tracking. Merge conflicts handled at integration time. Documentation notes the tool "struggled when changes spanned more than 5 files — it lost context and made conflicting edits."

**Source:** [Windsurf vs Cursor comparison](https://skywork.ai/blog/vibecoding/cursor-2-0-vs-windsurf/)

### 2.6 Aider — Single-Agent, Sequential

**Pattern match: Not applicable**

Aider operates as a single-agent terminal tool working directly with a local git repo. It does not support parallel execution. Changes are committed directly. No concurrency control needed.

---

## 3. CI/CD Merge Queue Systems

### 3.1 Zuul CI (OpenStack) — Speculative Execution, Serial Ordering

**Pattern match: Different (ordered speculation, not write-set detection)**

Zuul's dependent pipeline is the closest analogy to Alternate A in CI/CD:
- Tests changes in parallel by **assuming all preceding changes pass**
- Each change is tested against a speculative merge of all preceding changes
- If change A fails, all changes behind it (B, C, D) are **retested without A**
- Detects **files changed** by each change via merger operations

**Critical difference from Alternate A:** Zuul imposes a **total ordering**. Change B is always tested against the combined state of (base + A). This eliminates write skew because each change sees a consistent, ordered view. The cost is that a failure at position N invalidates all N+1... positions.

Zuul does NOT track read-sets. It does NOT check write-set overlaps. Instead, it uses **serial ordering + speculative optimism** to achieve the equivalent of serializable execution.

**Source:** [Zuul Gating Documentation](https://zuul-ci.org/docs/zuul/latest/gating.html)

### 3.2 Aviator MergeQueue — Declared Affected Targets, Disjoint Queues

**Pattern match: Strong (explicit write-set declaration)**

Aviator is the most sophisticated merge queue and the closest production analog to Alternate A:
- PRs **declare affected targets** (strings, not predetermined)
- PRs with **non-overlapping targets** run in independent parallel queues
- PRs with **overlapping targets** are "optimistically stacked" and tested together
- **No read-set tracking** — the system relies entirely on declared write-sets

This is essentially Alternate A with **declared write-sets** rather than observed write-sets. The key difference: Aviator asks developers to declare which targets (directories, build targets, services) a PR affects, rather than automatically computing the write-set from `git diff`.

Aviator's documentation explicitly frames this as "a dial of how aggressively or conservatively to merge changes" — the same risk/throughput tradeoff as Snapshot Isolation.

**Source:** [Aviator Affected Targets](https://docs.aviator.co/mergequeue/concepts/affected-targets), [Directory-Based Affected Targets](https://docs.aviator.co/mergequeue/concepts/affected-targets/directory-based-affected-targets)

### 3.3 Trunk Merge Queue — Impact Analysis, Express Lanes

**Pattern match: Strong (automatic write-set detection)**

Trunk analyzes each PR's "impacted targets" (affected codebase sections) and creates **dynamic parallel queues**:
- Independent changes test simultaneously in separate "express lanes"
- PRs affecting different subsystems don't wait for each other
- Compatible PRs are batched and tested together (70% time savings reported)
- **No read-set tracking**

This is Alternate A with automatic write-set inference from changed files/build targets.

**Source:** [Trunk Merge Queue](https://trunk.io/merge-queue), [Outgrowing GitHub Merge Queue](https://trunk.io/blog/outgrowing-github-merge-queue)

### 3.4 Mergify — Speculative Parallel Checks

**Pattern match: Moderate (Zuul-like ordered speculation)**

Mergify's Parallel Checks create cumulative merges: (PR#1), (PR#1+PR#2), (PR#1+PR#2+PR#3), testing all in parallel. Like Zuul, this imposes an ordering. Failed PR causes all subsequent to re-test.

Performance data:
- Divided average latency by 2.5x
- Multiplied throughput by 3x
- CI cost increase: ~33% in worst case

Mergify explicitly describes the **RCV theorem**: you can only optimize two of Reliability, Cost, and Velocity simultaneously.

**Source:** [Mergify Parallel Checks](https://docs.mergify.com/merge-queue/parallel-checks/), [Mergify Performance](https://docs.mergify.com/merge-queue/performance/)

### 3.5 GitHub Merge Queue — Simple Sequential

**Pattern match: Weak (no parallelism)**

GitHub's native merge queue is strictly sequential. All PRs wait in one line regardless of independence. No write-set or read-set analysis. PRs are tested against the base branch + all preceding PRs in queue order.

**Source:** [GitHub Merge Queue Docs](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/configuring-pull-request-merges/managing-a-merge-queue)

### 3.6 Graphite Merge Queue — Partitioned Queues by File Pattern

**Pattern match: Strong (write-set partitioning)**

Graphite's merge queue offers:
- **Parallel CI:** Speculative execution across multiple stacks simultaneously
- **Partitioned queues:** Split repositories by file patterns (frontend changes don't wait for backend CI)
- **Failure isolation:** When a batch fails, bisection or full parallel isolation identifies the culprit

Partitioned queues are essentially pre-declared write-set boundaries. Each partition has independent concurrency limits. This is Alternate A at the partition level.

**Source:** [Graphite Merge Queue Optimizations](https://graphite.com/docs/merge-queue-optimizations), [Graphite Parallel CI](https://graphite.com/blog/parallel-ci)

### 3.7 Bors-NG — Batched Testing, Bisection on Failure

**Pattern match: Moderate**

Bors attempts to batch multiple PRs into a single staging branch and test them together. If CI fails, it bisects to find the failing PR. No write-set or read-set analysis — the conflict detection is purely via git merge + CI test results.

**Source:** [Bors-NG](https://github.com/bors-ng/bors-ng)

### 3.8 Sketch.dev — Lightweight Queue with ~9% Collision Rate

**Pattern match: Weak (no parallelism, accepts collisions)**

Sketch.dev's lightweight merge queue processes commits sequentially. They explicitly calculated: "the probability of having 2 commits in the same minute across 480 minutes is about 9%." They accept the occasional conflict-and-rebase as preferable to breaking main.

No write-set detection. No read-set detection. Pure optimistic concurrency with manual retry.

**Source:** [Sketch.dev Lightweight Merge Queue](https://sketch.dev/blog/lightweight-merge-queue)

---

## 4. Proactive Conflict Detection Tools

### 4.1 Clash — Read-Only Merge Simulation

**Pattern match: Write-set detection add-on for Alternate A**

Clash is an open-source CLI tool specifically designed for detecting merge conflicts across git worktrees used by parallel AI coding agents:

- Uses **git merge-tree** (via gix library) to perform three-way merges between worktree pairs
- **100% read-only** — never modifies the repository
- Discovers all worktrees, finds merge base for each pair, simulates merge, reports conflicts
- Supports **hook integration** (checks before Claude Code writes) and **watch mode** (continuous monitoring)

Clash detects **write-set overlaps** only. It does not track read-sets. It is a pure implementation of the Alternate A conflict detection layer.

**Source:** [Clash](https://github.com/clash-sh/clash)

### 4.2 MCP Agent Mail — Advisory File Reservations

**Pattern match: Pessimistic write-set declaration (complementary to Alternate A)**

MCP Agent Mail implements advisory file leases as a coordination mechanism:
- Agents **declare intent** to modify specific files via reservations
- Reservations are **advisory** (not hard locks) to avoid head-of-line blocking
- Conflict detection is per exact path pattern
- Optional pre-commit guard enforces locally

This is a **pessimistic** complement to Alternate A's **optimistic** approach: instead of detecting write-set conflicts after the fact, agents declare their intended write-set upfront. Both approaches track only write-sets, not read-sets.

**Source:** [MCP Agent Mail](https://github.com/Dicklesworthstone/mcp_agent_mail)

### 4.3 Interlock (from this project's ecosystem) — File Reservation Layer

Our own Interlock plugin implements a similar advisory file reservation system with shared/exclusive semantics. Like MCP Agent Mail, it tracks declared write-sets (file reservations) without read-set tracking.

---

## 5. Build Systems

### 5.1 Bazel — Content-Addressable Actions, No Write Conflict by Design

**Pattern match: Different (eliminates conflicts structurally)**

Bazel avoids the problem entirely through its action model:
- Each action has **declared inputs and outputs** (the action's "read-set" and "write-set")
- Actions with overlapping outputs are a **build graph error** (detected at analysis time, not execution time)
- Actions have **exclusive access** to their output directory during execution
- The action cache uses content hashes — identical outputs from different actions produce the same cache entry

Bazel has `--experimental_guard_against_concurrent_changes` to detect input file modifications during build, but this guards against external mutation, not inter-action conflicts.

Bazel's model is closer to **serializability** (full input/output declaration) than Snapshot Isolation.

**Source:** [Bazel Remote Caching](https://bazel.build/remote/caching), [BuildBuddy Explanation](https://www.buildbuddy.io/blog/bazels-remote-caching-and-remote-execution-explained/)

### 5.2 Buck2 — Declared I/O, Exclusive Output Dirs

**Pattern match: Different (same as Bazel)**

Buck2 similarly declares inputs and outputs per action. "Actions have exclusive access to their output directory." Write conflicts are structurally impossible within the build graph.

**Source:** [Buck2 Architecture](https://buck2.build/docs/developers/architecture/buck2/)

---

## 6. Version Control Systems

### 6.1 Git — Native Write-Write Detection, No Read-Set Tracking

**Pattern match: Git IS the Alternate A pattern at its core**

Git's merge algorithm is the original Alternate A:
- Each branch starts from a base commit (pinned snapshot)
- Work proceeds in isolation
- At merge time, only write-write conflicts are detected (via three-way merge on changed files)
- No tracking of which files were read

Git merge has been running in production since 2005 at massive scale. Every git repository on Earth uses this pattern.

### 6.2 Perforce Helix Core — Optional File Locking + Merge

Perforce offers both approaches:
- **File locking** (pessimistic, prevents write conflicts)
- **Merge-based resolution** (optimistic, detects write-write conflicts at submit time)

For text files, Perforce uses the same pattern as Git. For binary files (which can't be merged), exclusive checkouts/locks are recommended.

**Source:** [Perforce Resolve Conflicts](https://ftp.perforce.com/perforce/r16.2/doc/manuals/p4guide/chapter.resolve.html)

---

## 7. The Write Skew Problem: What Alternate A Misses

### 7.1 The Theoretical Risk

The known weakness of write-write-only detection is **write skew** (from database theory) or **semantic conflict** (from Martin Fowler's terminology).

Fowler's canonical example:
1. Developer A renames function `clcBl` to `calculateBill` and updates all callers
2. Developer B (on a separate branch) adds new calls to `clcBl`
3. Merge succeeds textually — no write-write conflict (they changed different files)
4. Code breaks semantically — B's new calls reference the old function name

In multi-agent coding terms:
1. Agent A refactors a function signature in `api.go`
2. Agent B (pinned to the same base commit) adds new code in `handler.go` that calls the old signature
3. No write-set overlap (different files) — Alternate A would approve the merge
4. Combined result: compilation error (or worse, silent behavioral change)

**Source:** [Martin Fowler — Semantic Conflict](https://martinfowler.com/bliki/SemanticConflict.html)

### 7.2 Research on Semantic Conflict Rates

Academic research on semantic conflicts in parallel development:

- **Semantic merge conflicts are 26x more likely to have a bug** compared to code without such conflicts (UCI empirical study)
- Symbolic execution tools (like **Semex**) can detect semantic conflicts by encoding all parallel changes into a single program with conditional guards
- Pre-trained language models have been explored for resolving textual and semantic merge conflicts (ISSTA 2022)
- **TIM (TIM Improves Merging)** uses symbolic execution to identify test cases where results differ between merged code and expected behavior

**Source:** [UCI Empirical Study](https://ics.uci.edu/~iftekha/pdf/J4.pdf), [Semantic Merge Conflict Detection](https://github.com/brendon-ng/Semantic-Merge-Conflict-Detection)

### 7.3 The DORA 2025 "AI Productivity Paradox"

The 2025 DORA Report found that AI coding assistants boost individual output (21% more tasks, 98% more PRs merged) but organizational delivery metrics stay flat. Developers using AI interact with 9% more task contexts and 47% more PRs daily. This increased parallelism is exactly the environment where write skew becomes more likely — more concurrent changes means more opportunities for semantic conflicts that write-set-only detection misses.

**Source:** [DORA 2025 Report](https://dora.dev/research/2025/dora-report/)

### 7.4 Practical Mitigations for Write Skew

Every system studied mitigates write skew through some combination of:

| Mitigation | Mechanism | Who Uses It |
|-----------|-----------|-------------|
| **CI/CD tests at merge time** | Tests catch semantic conflicts post-merge | Zuul, Bors, Mergify, Graphite, Trunk, Aviator |
| **Human code review** | Reviewer catches logical inconsistencies | OpenHands, all PR-based workflows |
| **Frequent integration** | Smaller windows reduce read staleness | Fowler's recommendation, trunk-based development |
| **Task decomposition** | Independent tasks rarely share read-sets | OpenHands Refactor SDK, manual practice |
| **Pre-commit hooks** | Lint/typecheck catches type-level semantic conflicts | Standard practice |
| **Proactive merge simulation** | Clash-style tools detect conflicts early | Clash (new, 2025) |
| **Advisory file reservations** | Declare intent, surface overlaps early | MCP Agent Mail, Interlock |

---

## 8. Summary: Is Alternate A Production-Grade?

### Verdict: Yes — It Is the Dominant Pattern

Every multi-agent coding system examined (Codex, VS Code, Claude Code, OpenHands, Windsurf) uses exactly the Alternate A pattern. Not one of them tracks read-sets. The pattern is also the default isolation level in most production databases (Oracle, PostgreSQL, MySQL, SQL Server, MongoDB).

### Taxonomy of Production Implementations

| System | Pinned Snapshot | Isolated Workspace | Write-Set Detection | Read-Set Tracking | Conflict Detection Timing |
|--------|----------------|--------------------|--------------------|-------------------|--------------------------|
| **OpenAI Codex App** | HEAD at thread start | Git worktree (detached HEAD) | Manual (Apply/Overwrite) | None | At sync time (manual) |
| **VS Code Background Agents** | Commit at session start | Git worktree | Git merge at apply | None | At apply time |
| **Claude Code + Squad/Conductor** | Branch HEAD | Git worktree | Git merge | None | At merge time |
| **OpenHands Refactor SDK** | Branch HEAD | Docker container + git branch | Git merge + human review | None | At PR review time |
| **Windsurf** | Branch HEAD | Git worktree | Git merge | None | At merge time |
| **Zuul CI** | Speculative merge of predecessors | Workspace | Serial ordering eliminates it | None | Re-test on failure |
| **Aviator MergeQueue** | HEAD + predecessors | N/A (CI) | Declared affected targets | None | At queue time |
| **Trunk Merge Queue** | HEAD | N/A (CI) | Impacted targets analysis | None | At queue time |
| **Graphite** | Speculative merge | N/A (CI) | File pattern partitions | None | At queue time |
| **Clash** | N/A (monitoring tool) | N/A | git merge-tree simulation | None | Continuous / pre-write |
| **Oracle/PostgreSQL/MySQL** | Transaction snapshot | MVCC version | Write-write intersection | None (SI level) | At commit time |

### Key Findings

1. **No production system tracks read-sets for multi-agent coding.** The complexity and performance cost are considered prohibitive. Even sophisticated merge queues (Aviator, Trunk, Graphite) operate at the write-set level.

2. **Write skew is accepted as a known risk, mitigated by CI and review.** The universal answer to "what about semantic conflicts?" is "that's what tests are for." This is an explicit, conscious tradeoff — not an oversight.

3. **The pattern has 30+ years of production history in databases.** Snapshot Isolation (write-write-only detection) has been the default in Oracle since 1992, PostgreSQL since MVCC adoption, and MySQL InnoDB's REPEATABLE READ. Billions of transactions per day run under this model.

4. **Merge queues add sophistication at the write-set level.** Aviator's "affected targets" and Trunk's "impacted targets" are essentially pre-computed write-sets used to partition work into independent queues. This is an optimization of Alternate A, not a departure from it.

5. **The emerging proactive tools (Clash, advisory reservations) stay within Alternate A.** They detect write-set overlaps earlier in the workflow but still don't track read-sets.

6. **Conflict rates are manageable in practice.** Sketch.dev measured ~9% collision probability for a small team. Mergify reports 33% CI cost increase for speculative parallel testing. No system has published data on silent semantic failure rates from write skew in multi-agent coding.

### Recommendation for Intermute

The Alternate A pattern is the right starting point. Specifically:

1. **Implement write-set conflict detection using git diff at merge time.** This is what every comparable system does.
2. **Add CI test execution as the primary write-skew mitigation.** Run tests after merge to catch semantic conflicts.
3. **Consider Clash-style proactive detection as an enhancement.** Monitor for write-set overlaps during execution, not just at merge time.
4. **Advisory file reservations (Interlock) complement the pattern well.** They surface intent conflicts before agents waste compute.
5. **Do NOT implement read-set tracking.** No comparable system does it, and the complexity is not justified by the marginal safety improvement given that CI + tests already catch the majority of semantic conflicts.

---

## References

### Multi-Agent Coding Systems
- [Codex App Worktrees](https://developers.openai.com/codex/app/worktrees/)
- [Codex Multi-Agent](https://developers.openai.com/codex/multi-agent/)
- [VS Code Background Agents](https://code.visualstudio.com/docs/copilot/agents/background-agents)
- [Claude Code Agent Teams](https://code.claude.com/docs/en/agent-teams)
- [OpenHands Parallel Agents](https://openhands.dev/blog/automating-massive-refactors-with-parallel-agents)
- [Conductor](https://www.conductor.build/)
- [Clash — Merge Conflict Detection](https://github.com/clash-sh/clash)
- [MCP Agent Mail](https://github.com/Dicklesworthstone/mcp_agent_mail)

### Merge Queue Systems
- [Zuul CI Gating](https://zuul-ci.org/docs/zuul/latest/gating.html)
- [Aviator Affected Targets](https://docs.aviator.co/mergequeue/concepts/affected-targets)
- [Trunk Merge Queue](https://trunk.io/merge-queue)
- [Graphite Merge Queue Optimizations](https://graphite.com/docs/merge-queue-optimizations)
- [Mergify Parallel Checks](https://docs.mergify.com/merge-queue/parallel-checks/)
- [GitHub Merge Queue](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/configuring-pull-request-merges/managing-a-merge-queue)
- [Sketch.dev Lightweight Merge Queue](https://sketch.dev/blog/lightweight-merge-queue)
- [Bors-NG](https://github.com/bors-ng/bors-ng)

### Database Theory
- [Snapshot Isolation vs Serializability — Marc Brooker](https://brooker.co.za/blog/2024/12/17/occ-and-isolation.html)
- [Martin Fowler — Semantic Conflict](https://martinfowler.com/bliki/SemanticConflict.html)
- [UCI Empirical Study on Merge Conflicts](https://ics.uci.edu/~iftekha/pdf/J4.pdf)
- [DORA 2025 Report](https://dora.dev/research/2025/dora-report/)

### Build Systems
- [Bazel Remote Caching](https://bazel.build/remote/caching)
- [Buck2 Architecture](https://buck2.build/docs/developers/architecture/buck2/)
