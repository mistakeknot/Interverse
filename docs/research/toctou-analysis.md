# TOCTOU Analysis: Git+Kernel Snapshot Transactions (GKST)

## 1. Executive Summary (Ranked Recommendations)

### Primary (build this): Git-anchored snapshots + OCC validation + single-writer merge + provenance-carrying context

Treat every agent dispatch as an optimistic transaction over two versioned substrates:
- **Repo substrate**: Git commit (content-hash DAG of blobs/trees/commits)
- **Kernel substrate**: event log + derived state, stored in SQLite (append-only events; derived views) with explicit snapshot IDs and commit-time validation (your kernel becomes the transaction coordinator).
- **Commit protocol**: long-running work happens off to the side (per-dispatch worktree); validation and merge are short and serialized (single-writer merge queue), minimizing pessimistic locking while eliminating silent TOCTOU.

This is structurally closest to OCC + multiversion snapshots as in classic transaction processing and to conflict-range validation patterns used in FoundationDB, adapted to Git paths and kernel objects.

Why it wins: Strong, general TOCTOU coverage without killing parallelism; integrates naturally with Git reality (commits/worktrees/3-way merge) and with your event-sourced kernel (deterministic replay and auditability).

### Alternate A (simpler / conservative): Pinned snapshots + merge-queue + coarse path locks (no full read-set)

Use the same per-dispatch worktrees and single-writer merge queue, but skip "full read-set" validation. Instead:
- validate only base commit (HEAD drift) and write-set overlaps
- optionally add coarse path-prefix lease locks (module-level) to reduce conflicts

Why it's simpler: fewer moving parts.
Why it bites: higher silent-semantic-risk from summary/context drift; higher "false success" rate when decisions relied on unstated dependencies.

### Alternate B (ambitious / frontier): Structured change representation + semantic merge + selective CRDT

Move from "line patches" to "semantic patches" and structured diffs for high-value codepaths; optionally represent a subset of files (or AST-level edits) as CRDT/OT-like operations.
- semantic patching: Coccinelle/SmPL
- AST diffs: GumTree
- CRDTs: Yjs/Automerge

Why it's attractive: reduces merge conflicts; allows parallel edits with fewer "hard conflicts."
Why it bites: large engineering + correctness surface area; semantics of merges become tool-dependent; difficult to make "high-confidence" across arbitrary languages.

---

## 2. Threat Model + TOCTOU Taxonomy

### System model (assumptions made explicit)
- Repo is Git with shared branch (e.g., main), and both humans and agents can update it.
- Kernel is SQLite storing append-only events + derived projections; multiple agents read kernel state concurrently and append events/updates. SQLite has a single-writer property, but WAL gives high read concurrency.
- Agents run for seconds-minutes, fan-out/fan-in, and sometimes operate on partial reads / summaries.
- Human interrupts are real: uncoordinated repo edits mid-flight.

### Terminology (define once)
- **SnapshotRef**: (repo_commit_sha, kernel_event_id) - the precise state an agent "checked."
- **Read-set**: the set of kernel objects and repo artifacts (paths/blobs/summaries/tool versions) the agent's reasoning depended on.
- **Write-set**: the kernel mutations and repo paths the agent intends to change.
- **Validation**: commit-time check that the read-set is still valid relative to current state (OCC-style).

### A) Repo drift taxonomy

**A1. HEAD drift (branch tip changed)**
- Check: agent records base_commit = HEAD at dispatch start.
- Use: agent applies patch or merges output assuming that base.
- Mutates between: HEAD advances due to other agent merges or human commits.
- Surfaces as:
  - patch doesn't apply -> wasted cycles
  - patch applies with 3-way merge but semantics wrong (silent)
  - gate evaluated on old commit but "used" on new commit -> false pass

**A2. File drift (content changed)**
- Check: agent reads file foo.go (or a summary thereof).
- Use: agent generates patch modifying foo.go or related files.
- Mutates between: foo.go blob changes in repo (human or parallel agent).
- Surfaces as:
  - conflict markers / failed apply
  - mis-placed edits (line offsets) leading to subtle breakage
  - tests fail later; or worse: tests don't cover it -> silent regression

**A3. Lockfile / dependency drift**
- Check: agent inspects lockfile (go.sum, package-lock.json, etc.) and runs tests.
- Use: agent relies on test results as a gate.
- Mutates between: lockfile changes or dependency graph changes.
- Surfaces as:
  - "green" gate on old dependency set, but broken on new
  - repeated flaky reruns; non-reproducible debugging

**A4. Rebase drift / rewritten history**
- Check: agent references commit IDs or assumes ancestry.
- Use: agent attempts to cherry-pick/rebase/merge based on that history.
- Mutates between: human does force-push/rebase; commit IDs become unreachable.
- Surfaces as:
  - inability to locate base blobs for 3-way apply
  - applying wrong base; losing provenance

### B) Kernel drift taxonomy

**B1. Phase state drift**
- Check: agent observes phase P is "OPEN" and expects to advance it.
- Use: agent emits event "advance phase" or triggers dispatch gated by phase.
- Mutates between: another dispatch advances or closes P.
- Surfaces as:
  - duplicate transitions, inconsistent fan-in decisions
  - tasks run after phase closed (policy violation)

**B2. Dispatch ordering drift (scheduler state)**
- Check: agent sees list of pending dispatches / priorities.
- Use: agent chooses next action based on that ordering.
- Mutates between: OS policy engine changes priorities, new dispatches appear, earlier dispatch completes.
- Surfaces as:
  - duplicated work
  - starvation or priority inversion
  - wasted cycles due to invalid assumptions about "what's already done"

**B3. Gate criteria drift (policy changed)**
- Check: agent reads gate definition "tests X + lint Y".
- Use: agent runs those checks; claims gate pass.
- Mutates between: policy engine updates gate definition or toolchain required.
- Surfaces as:
  - false gate pass
  - inconsistent enforcement; audit failures

### C) Tool output drift taxonomy

**C1. Environment/toolchain drift**
- Check: tests pass on environment E1.
- Use: merge is approved assuming tests are meaningful.
- Mutates between: tool versions, environment variables, OS libs, external service state.
- Surfaces as: non-reproducible "it passed earlier"; flakiness; silent miscompiles.

Bazel's hermeticity framing is the right mental model: outputs should be a pure function of declared inputs + tools.

### D) Summary/context drift taxonomy

**D1. Summary drift (compressed view stale)**
- Check: agent reads summary S of files {A,B,C}.
- Use: agent decides edits based on S.
- Mutates between: A/B/C changes; S no longer corresponds.
- Surfaces as: edits that target outdated APIs; broken refactors; false confidence.

**D2. Partial-read drift (agent saw only subset)**
- Check: agent saw only file slices/snippets.
- Use: agent edits a function whose invariants are elsewhere.
- Mutates between: not even necessary-this is a TOCTOU-like failure caused by incomplete check.
- Surfaces as: invariant violations; inconsistent style; broken build.

### E) Human interrupt drift taxonomy

**E1. Mid-flight human edits in same area**
- Check: agent starts work assuming working tree state.
- Use: agent writes patch that overwrites or conflicts with human changes.
- Mutates between: human commit(s) on main.
- Surfaces as: conflict, or silent revert if patch is applied incorrectly.

### F) Parallel dispatch conflicts taxonomy

**F1. Write-write conflicts on same paths**
- Check: both dispatches read same base commit and plan changes.
- Use: both attempt to merge.
- Mutates between: first merge changes file; second merge attempts apply.
- Surfaces as: conflicts; or semantic skew if both edits "fit" syntactically.

**F2. Read-write conflicts (decision drift)**
- Check: dispatch B reads file A to decide; dispatch A changes that file.
- Use: dispatch B commits without noticing, producing semantically wrong change.
- Mutates between: file read dependency changed.
- Surfaces as: silent corruption (highest severity).

This is the canonical OCC failure mode if you don't model read dependencies.

---

## 3. Candidate Mechanisms (Curated)

### 1) Git-anchored snapshot isolation (repo MVCC via commits + worktrees)
- Definition: treat a Git commit SHA as an immutable snapshot of the repo; each agent works in an isolated worktree rooted at that commit.
- Proven in: Git's design; build/release workflows across industry.
- Kernel shape: Dispatch.base_repo_commit_sha; kernel creates/assigns a linked worktree for that commit.
- Prevents: "dirty reads" of evolving working directory; most repo drift during agent runtime.
- Doesn't prevent: semantic drift between base and merge target; decision drift unless validated.
- Complexity cost: low (worktree management, cleanup, quotas).

### 2) Kernel snapshot IDs (event-log MVCC)
- Definition: treat kernel state as derived from an ordered event log; a dispatch reads at a specific kernel_event_id and must validate assumptions before writing.
- Proven in: state machine/event sourcing patterns; deterministic replay in workflow engines.
- Kernel shape: every dispatch records base_kernel_event_id; kernel provides "read at event_id" views.
- Prevents: phase/gate drift being invisible (when combined with validation).
- Doesn't prevent: incorrect derived logic; needs invariants.
- Cost: moderate (versioning + snapshot queries).

### 3) OCC with explicit validation (read-set + write-set)
- Definition: do work without locks, then validate at commit that nothing relevant changed; abort/retry on conflict.
- Proven in: classic OCC; FoundationDB's conflict ranges are a production-grade example.
- Kernel shape:
  - repo: read-set = set of (path, blob_hash_at_base); write-set = set of paths changed
  - kernel: read-set = (object_id, version); write-set = events emitted/rows changed
  - commit protocol enforces validation atomically.
- Prevents: silent read-write and write-write drift; false gate passes due to stale predicates.
- Doesn't prevent: missing read dependencies; requires inference fallback.
- Cost: moderate (schema + validations + retries).

### 4) Snapshot isolation / MVCC-like semantics (formal grounding)
- Definition: each transaction reads from a consistent snapshot; commit succeeds if no conflicting writes occurred.
- Proven in: MVCC databases; formal literature on anomalies/guarantees.
- Kernel shape: use SnapshotRef + OCC validation to approximate snapshot isolation across repo+kernel.
- Prevents: inconsistent reads; many anomalies.
- Cost: conceptual + implementation synergy with OCC.

### 5) Deterministic replay (event sourcing + workflow history)
- Definition: record an execution history so state can be replayed deterministically.
- Proven in: Temporal; state-machine replication literature.
- Kernel shape: every agent action and merge attempt emits events; "replay run" reconstructs kernel state and repo snapshot chain.
- Prevents: irreproducible debugging; enables audit and "why did we merge this?".
- Cost: low-moderate (logging discipline, replay tooling).

### 6) Sagas / compensations for long-running operations
- Definition: represent a long-lived transaction as sequence of smaller transactions with compensating actions on failure.
- Proven in: original Sagas paper; widespread in distributed workflows.
- Kernel shape: a dispatch is a saga step; "compensation" is: drop worktree, invalidate artifacts, emit failure, schedule retry/rebase step.
- Prevents: holding locks for minutes; allows safe partial progress.
- Cost: moderate (defining compensations and retry policies).

### 7) Content-hash anchoring (Git blobs/trees + kernel hashes)
- Definition: use content hashes as stable references.
- Add hash chaining to kernel events for tamper-evident audit (or Merkle roots).
- Proven in: Git; transparency logs like Trillian use Merkle trees with inclusion/consistency proofs.
- Kernel shape: store prev_event_hash/event_hash; periodically anchor a root hash into a Git note/trailer.
- Prevents: undetected kernel history rewriting; supports forensic debugging.
- Cost: low.

### 8) Locking strategies (path locks, semantic locks) - used narrowly
- Definition: serialize specific conflicts with locks. For long-running tasks, locks must be leases or two-phase with short hold.
- Proven in: classic locking; also conflict-range based "lock by key-range" in FDB.
- Kernel shape:
  - Lock(key_prefix, mode=lease, ttl) for advisory reservations
  - mandatory exclusive lock only during merge critical section
- Prevents: high-frequency hotspots; reduces conflict retries.
- Cost: moderate (deadlock avoidance, TTL, fairness).

### 9) Semantic patching / structured diffs (vs line patches)
- Definition: represent code transformations at semantic/AST level.
- Proven in: Linux driver evolutions; automated refactors.
- Kernel shape: optional "patch type": line_diff | semantic_patch | ast_edit_script.
- Prevents: some line-level misapplication; reduces conflicts in refactors.
- Cost: high (language tooling, safety).

### 10) Hermetic/reproducible execution environments
- Definition: make tool outputs a function of declared inputs/tools.
- Proven in: Bazel/Nix ecosystems.
- Kernel shape: dispatch includes tool_env_digest (container digest / Nix derivation hash / toolchain hash).
- Prevents: tool output drift; reduces flaky gates.
- Cost: moderate-high depending on adoption depth.

---

## 4. Decision Matrix

Scoring: 0-5 where 5 is best. "Engineering complexity" and "Runtime overhead" scored with 5 = low complexity/overhead.

| Approach | Correctness | Coverage | Eng. Complexity | Runtime Overhead | Parallelism | Debuggability | Incremental | Fit (Go+SQLite+Git) | OSS |
|----------|-------------|----------|-----------------|------------------|-------------|---------------|-------------|---------------------|-----|
| A0. Status quo | 1 | 1 | 5 | 5 | 5 | 1 | 5 | 5 | 5 |
| A1. Pinned snapshots + worktrees | 2 | 3 | 4 | 4 | 5 | 3 | 5 | 5 | 5 |
| A2. Two-store OCC (SnapshotRef + read-set + merge queue) | 5 | 5 | 3 | 3 | 4 | 5 | 4 | 5 | 5 |
| A3. A2 + advisory path-prefix leases | 5 | 5 | 3 | 3 | 3 | 5 | 3 | 5 | 4 |
| A4. Pessimistic path locks | 4 | 4 | 3 | 3 | 1 | 4 | 3 | 5 | 3 |
| A5. Calvin-like deterministic ordering + OCC | 4 | 4 | 2 | 3 | 3 | 5 | 2 | 4 | 3 |
| A6. A2 + semantic/AST patch option | 4 | 5 | 1 | 2 | 4 | 4 | 2 | 3 | 4 |
| A7. CRDT-first repo state | 3 | 4 | 1 | 2 | 5 | 2 | 1 | 2 | 4 |

**Decision: Build A2 now. Keep A3 as early extension. A6/A7 as later research.**

---

## 5. Primary Architecture + 2 Alternates

### 5.1 Primary: Git+Kernel Snapshot Transactions (GKST)

**Mechanism summary:**
1. Pinned snapshots: Every dispatch runs against an immutable SnapshotRef (base_git_commit, base_kernel_event_id).
2. Read-set capture (declared + inferred): capture what the agent actually depended on (repo paths/blobs, kernel object versions, summaries, tool env).
3. OCC validation + short critical merge section: before changes are "used" (merged / gates advanced), validate read-set still holds; then apply patch in a single-writer merge queue.
4. Deterministic event-sourced audit: every check/use boundary becomes explicit and replayable.

#### Kernel Primitive Changes

**Events (append-only; hash-chained)**
- events(event_id INTEGER PRIMARY KEY AUTOINCREMENT, run_id, ts, type, payload_json, prev_hash, hash)
- hash is H(prev_hash || canonical(payload))

**Runs**
- runs(run_id, created_at, head_ref, head_commit, last_event_id, ...)

**Phases**
- phases(phase_id, run_id, state, version, updated_event_id, ...)
- version increments on any semantic change

**Gates**
- gates(gate_id, run_id, phase_id, definition_json, version, updated_event_id, ...)
- gate evaluation is an event: GateEvaluated{gate_id, candidate_commit, tool_env_digest, input_digest, result, details}

**Dispatches - Core additions:**
- dispatches(dispatch_id, run_id, phase_id, status, base_repo_commit, base_kernel_event_id, scope_hint, created_at, ...)
- dispatch_inputs(dispatch_id, kind, ref, digest, metadata_json) where kind in {repo_path, repo_tree, kernel_object, summary, tool_env}
- dispatch_writes(dispatch_id, kind, ref, metadata_json)

**Locks (narrow and explicit)**
Two lock classes:
1. Merge lock (mandatory): single global lock during "apply+advance HEAD" critical section.
2. Scope leases (advisory): path-prefix lock with TTL; used to reduce conflicts.

Schema: locks(lock_key TEXT PRIMARY KEY, mode TEXT, holder_dispatch_id, expires_at, created_at)

#### Repo State Pinning

At dispatch start:
- read run.head_commit as base_repo_commit
- create a linked worktree at that commit: git worktree add <path> <base_repo_commit>
- agent operates only inside that worktree

#### Read-set Capture / Inference

Sources of read-set (ranked by confidence):
1. Instrumented file access (best): wrap all file reads through kernel-provided API
2. Prompt/context capture (good): every file snippet inserted into model context logged with (path, blob_hash, range_hash)
3. Summary provenance (required): summaries stored as artifacts with dependency digests
4. Fallback coarse read-set (safety): repo tree hash at base commit or scope_prefix tree hash

#### Commit Protocol (kernel-level)

**1. Prepare (no mutation to shared HEAD)**
- record DispatchPrepared{dispatch_id, base_commit, patch_hash, read_set_hash, write_set_hash, tool_env_digest, ...}
- compute write-set (paths modified)
- optionally acquire advisory scope locks (leases)

**2. Validate (against current state)**
- validate kernel read-set: for each (object_id, version) read: ensure current version unchanged
- validate repo read-set: for each (path, expected_blob_hash) ensure blob hash at current HEAD matches expected
- validate write-write conflicts: ensure no committed dispatch modified any path in write-set since base_commit

**3. Apply+Advance HEAD (short critical section, serialized)**
- acquire global merge lock (SQLite BEGIN IMMEDIATE)
- re-check current HEAD (avoid ABA race)
- attempt apply: git apply --3way <patch>
- create merge commit with metadata trailers (Dispatch-ID, Base-Commit, ReadSet, ToolEnv)
- update run.head_commit to new commit
- emit DispatchCommitted event

#### Conflict Behavior

Three conflict classes:
1. **Hard conflict**: patch cannot apply cleanly -> schedule RebaseDispatch with updated base
2. **Read-set invalidation (decision drift)**: abort and retry with refreshed context
3. **Kernel drift invalidation**: abort; reschedule under new phase/gate; or drop if phase closed

#### Gate Semantics

Gates certify a specific candidate commit under a specific tool environment.
Gate evaluation event must include: candidate_commit, gate_definition_version, tool_env_digest, inputs_digest, result + artifacts.

Any time candidate commit changes, gates are invalidated unless system can prove inputs digest unchanged.

#### Observability (Replay Capsule)

Minimum per dispatch commit:
- base SnapshotRef
- read-set entries
- patch bytes + patch hash
- tool env digest + tool versions
- gate eval results with input digests
- merge attempt logs and conflict markers

#### What Will Bite You
1. Incomplete read-set inference -> residual silent drift
2. 3-way merge success != semantic correctness
3. High churn repos cause retry storms
4. SQLite write contention under heavy event traffic

### 5.2 Alternate A: Pinned snapshots + merge queue + write-set conflict checks

Same worktrees and merge queue, but validate only base_commit ancestry/HEAD drift and write-set overlap. No full read-set inference.

**Tradeoffs:** MVP faster, but doesn't address summary/context drift (D1/D2) or read-write decision drift (F2).

### 5.3 Alternate B: Structured change + semantic merge + selective CRDT

Represent changes as semantic patches (SmPL-like) and/or AST edit scripts. Merge at structure level. CRDT for configs.

**Tradeoffs:** Fewer conflicts but high engineering complexity; per-language tooling; harder to validate.

---

## 6. MVP Plan + 30/60/90 Roadmap

### 2-4 Week MVP (12 tasks)

**Week 1: SnapshotRef + worktree isolation**
1. Kernel schema additions (dispatches.base_repo_commit, base_kernel_event_id, dispatch_inputs, dispatch_writes, locks, events.prev_hash/hash)
2. Enable WAL + tune SQLite connection mode
3. Worktree manager Go package
4. Dispatch start protocol (snapshot + emit DispatchStarted)

**Week 2: Read-set capture + patch production**
5. Context/file read logging wrapper
6. Summary artifact with provenance
7. Patch capture (git diff, patch_hash, write_set)

**Week 3: OCC commit protocol + merge queue**
8. Single-writer merge queue (SQLite BEGIN IMMEDIATE + locks row)
9. Validation engine (kernel objects, repo read-set, write-write conflicts)
10. Apply via 3-way merge

**Week 4: Gate revalidation + observability**
11. Gate evaluation "certificates" (bound to candidate_commit, tool_env_digest, gate_version, inputs_digest)
12. Replay/debug tool (CLI: replay-run, repro bundle export)

### MVP Failure Handling
- Reject: validation fails -> dispatch aborted, schedule retry
- Retry: automatic retry policy, exponential backoff for hotspots
- Quarantine: repeated conflict >N -> require human approval
- Human review: only when system cannot safely resolve

### MVP Success Criteria
- Conflict rate (per dispatch, by type)
- Rerun rate (retries per successful merge)
- False pass rate (gate pass that later fails)
- Time-to-merge distribution (median/p95)
- Stale-summary detection rate
- Can reproduce any merge outcome from event log + artifacts

### 30/60/90 Roadmap

**30 days (post-MVP):**
- Advisory scope leases (A3) for hotspots
- git rerere integration
- Improved read-set inference (tool reads)

**60 days:**
- Hermetic tool execution (pinned containers/Nix)
- Bazel-like inputs digest for gates
- Optional structured patch mode (GumTree) for limited languages

**90 days:**
- TLA+ formalization of commit protocol
- Tamper-evident anchoring (Merkle root, Trillian)
- Semantic patch library for recurring refactors (Coccinelle-like)

---

## 7. Validation/Test Harness

### A) Invariants (safety properties)
1. HEAD advances only via kernel-logged merge events
2. Commit-time validation completeness for declared/inferred read-set
3. Gate binding correctness (candidate_commit, gate_version, tool_env_digest, inputs_digest)
4. Merge lock mutual exclusion
5. Lease lock uniqueness
6. Event log append-only; hashes chain correctly

### B) Concurrency simulation (Go harness)
- N dispatch goroutines with random durations
- M "human interrupt" goroutines committing to main
- Random gate definition updates
- Random summary regeneration/consumption
- Assertions on all invariants

### C) Mutation injection (fault injection for TOCTOU)
- Repo mutation: mutate file after agent reads it, expect read-set invalidation
- Kernel mutation: change phase/gate after agent checked, expect validation failure

### D) Property-based tests
- Randomized operation sequences (StartDispatch, ReadFile, UpdateGate, HumanCommit, ProducePatch, AttemptCommit)
- Check safety invariants

### E) Replay-based debugging
- Every test run emits full event history + git commits
- Replayer reconstructs state

### F) Telemetry
- Before/after: rate of silent regressions, rerun rate
- Track: invalidations by cause, stale summary prevented count

---

## 8. Curated Papers + Repos

### Top 10 Papers
1. Kung & Robinson (1981) - OCC formalization
2. Berenson et al. (1995) - ANSI SQL isolation critique / snapshot isolation
3. Garcia-Molina & Salem (1987) - Sagas
4. Thomson et al. (2012) - Calvin deterministic transactions
5. Schneider (1990) - State machine replication
6. Lamport (1978) - Time, clocks, ordering
7. Dolstra & de Jonge (2004) - Nix reproducible deployment
8. Shapiro et al. (2011) - CRDT foundations
9. Padioleau et al. (2006) - Semantic patches (Coccinelle)
10. Falleri et al. (2014) - GumTree AST differencing

### Top 10 Repos
1. git/git - content addressing, merge, patch
2. temporalio/temporal - durable workflows, replay
3. apple/foundationdb - OCC, conflict ranges
4. bazelbuild/bazel - hermetic builds, action graphs
5. NixOS/nix - reproducible environments
6. google/trillian - transparency logs, Merkle proofs
7. jepsen-io/jepsen - concurrency testing
8. tlaplus/tlaplus - TLC model checker
9. coccinelle/coccinelle - semantic patches
10. SpoonLabs/gumtree-spoon-ast-diff - AST differencing
