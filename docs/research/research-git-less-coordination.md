# Research: Multi-Agent Git Coordination Without Worktrees

> **Date**: 2026-02-15
> **Scope**: How multiple AI coding agents can safely share a single git working tree
> **Constraint**: No git worktrees -- all agents operate on the same checkout

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Core Coordination Problems](#2-core-coordination-problems)
3. [Coordination Primitives](#3-coordination-primitives)
4. [Claude Code Specifics](#4-claude-code-specifics)
5. [Real Multi-Agent Systems](#5-real-multi-agent-systems)
6. [The GIT_INDEX_FILE Trick](#6-the-git_index_file-trick)
7. [Practical Architecture Proposals](#7-practical-architecture-proposals)
8. [Comparison Matrix](#8-comparison-matrix)
9. [Recommendations](#9-recommendations)
10. [Sources](#10-sources)

---

## 1. Executive Summary

Running multiple AI coding agents in a single git working tree is a fundamentally harder problem than using worktrees, but it is tractable with the right primitives. The industry overwhelmingly uses worktrees or full container isolation (Devin, OpenHands, Codex). For teams that cannot or will not use worktrees -- due to trunk-based development policies, monorepo constraints, or resource limitations -- there are four viable approaches:

| Approach | Core Mechanism | Conflict Rate | Complexity |
|----------|---------------|---------------|------------|
| **Turn-based serialization** | Only one agent edits at a time | Zero | Low |
| **File-ownership partitioning** | Each agent owns disjoint file sets | Low (boundary crossings only) | Low |
| **Per-session GIT_INDEX_FILE** | Separate staging areas, same working tree | Medium (filesystem-level) | Medium |
| **Central coordinator with reservations** | Server grants exclusive edit rights | Low (depends on granularity) | High |

The fundamental insight is: **the git staging area (index) is the hardest single-process bottleneck, not file editing itself.** Two agents can safely edit different files simultaneously in the same working tree, but they cannot safely run `git add` and `git commit` concurrently because the `.git/index` file is a single binary blob protected by a single lock file (`.git/index.lock`).

---

## 2. Core Coordination Problems

### 2.1 Simultaneous File Editing

**Problem**: Two agents edit the same file at the same time. One agent reads version A, the other reads version A. Agent 1 writes version B. Agent 2 writes version C, overwriting B without incorporating its changes.

**Analysis**: This is the classic lost-update problem. It manifests at two levels:

1. **Filesystem level**: Claude Code's `Write` tool performs atomic writes (write to temp file, rename). The last write wins. There is no merge -- the entire file is replaced.

2. **Edit tool level**: Claude Code's `Edit` tool uses string-matching replacement (`old_string` -> `new_string`). If Agent 1's edit changes the context that Agent 2's `old_string` matches against, Agent 2's edit will fail with "old_string not found." This is actually a safety mechanism -- the Edit tool has built-in optimistic concurrency detection via exact string matching.

**Key insight**: The `Edit` tool's string-matching behavior provides natural conflict detection. The `Write` tool does not -- it silently overwrites. Any coordination scheme should prefer `Edit` over `Write` for concurrent scenarios.

### 2.2 Git Staging Area Conflicts (The Index Problem)

**Problem**: Git's staging area is a single binary file at `.git/index`. All operations that modify the index (`git add`, `git rm`, `git reset`) acquire an exclusive lock via `.git/index.lock`. Only one process can hold this lock at a time.

**Mechanics of the lock**:
1. Process calls `git add file.txt`
2. Git creates `.git/index.lock` via `open(O_CREAT|O_EXCL)` (atomic create-if-not-exists)
3. Git reads `.git/index`, modifies it in memory, writes to `.git/index.lock`
4. Git renames `.git/index.lock` to `.git/index` (atomic replace)
5. If step 2 fails because the lock exists, git prints `fatal: Unable to create '.git/index.lock': File exists.`

**Consequences for multi-agent**:
- Two agents cannot run `git add` simultaneously. The second one gets `index.lock` error.
- If an agent crashes mid-operation, the lock file is orphaned. No other agent can stage until it is manually removed.
- Claude Code's background `git status --porcelain` polling creates stale `index.lock` files that persist for 20+ seconds (documented in [anthropics/claude-code#11005](https://github.com/anthropics/claude-code/issues/11005)).
- There is no queue -- if two processes race for the lock, it is non-deterministic which wins.

**Severity**: This is the single hardest problem for worktree-less multi-agent git usage. The index is a global mutable singleton.

### 2.3 Commit Ordering and Merge Conflicts

**Problem**: Even if agents stage files successfully, commits are not atomic across sessions. Agent 1 stages files A and B, Agent 2 stages files C and D. If Agent 2 commits first, the commit includes Agent 1's staged files A and B (because the index is shared). Agent 1's subsequent commit then has nothing to commit or commits an inconsistent state.

**Detailed scenario**:
```
Time  Agent 1                    Agent 2                    Index State
T1    git add src/foo.go         -                          {foo.go}
T2    -                          git add src/bar.go         {foo.go, bar.go}
T3    -                          git commit -m "Add bar"    COMMITS {foo.go, bar.go}
T4    git commit -m "Add foo"    -                          EMPTY -- nothing to commit!
```

Agent 1's work is now attributed to Agent 2's commit. Agent 1's commit message is lost.

**This is not just theoretical.** Any system where multiple agents share the same `.git/index` without coordination will hit this within minutes of concurrent operation.

### 2.4 Read-After-Write Consistency

**Problem**: Agent 1 writes file X. Agent 2 reads file X expecting the original content. Agent 2 gets Agent 1's version and makes decisions based on unexpected state.

**Analysis**: This is the simplest problem to reason about but the hardest to prevent without coordination. It affects:

1. **File reads**: Agent 2's `Read` tool returns whatever is on disk, including Agent 1's uncommitted changes.
2. **Test execution**: Agent 2 runs tests that pass/fail based on Agent 1's uncommitted changes, producing misleading results.
3. **Build artifacts**: Agent 2 builds with Agent 1's half-finished changes, producing corrupt binaries.
4. **Git status**: Agent 2 sees Agent 1's unstaged changes in `git status`, confusing its understanding of repository state.

**Mitigation**: Read-after-write consistency is only achievable with filesystem isolation (worktrees, containers) or strict turn-based execution. No advisory protocol can prevent an agent from reading a file that another agent just modified.

### 2.5 Pre-Commit Hook Interactions

**Problem**: Pre-commit hooks run during `git commit`. If two agents commit simultaneously, two instances of the hook run on the same files, potentially interfering.

**Specific risks**:
- **Formatters** (gofmt, prettier): Hook A formats file X. Hook B also formats file X. Both succeed, but they race on the filesystem write.
- **Linters**: Hook A and Hook B both lint the full codebase. Both may report the same issues. Both may fail, causing both commits to abort.
- **Test runners**: Hook A runs `go test ./...`, which creates temporary files. Hook B also runs tests. They share the same `_test` cache, `.test` binaries, and coverage outputs.
- **Lock files**: The pre-commit framework itself uses lock files for hook installation. Concurrent installations can deadlock.

**Observed behavior**: Pre-commit hooks are designed for single-process execution. The pre-commit framework runs hooks sequentially within a single invocation. Running two `git commit` commands simultaneously creates two independent hook pipelines that are unaware of each other.

---

## 3. Coordination Primitives

### 3.1 Pessimistic: File-Level Locks/Reservations

**Mechanism**: Before editing a file, an agent must acquire an exclusive lock. Other agents block or skip that file until the lock is released.

**Implementation options**:

**A. Filesystem advisory locks (flock/fcntl)**:
```bash
# Agent acquires lock before editing
flock --exclusive --timeout 30 /tmp/locks/src-foo-go.lock -c "edit src/foo.go"
```
- Pros: OS-native, automatic cleanup on process death, no daemon needed
- Cons: Advisory only (agents must cooperate), lock files accumulate, no remote visibility

**B. Lock files on disk**:
```bash
echo "agent-1:$(date +%s)" > .locks/src/foo.go.lock
# Edit the file
rm .locks/src/foo.go.lock
```
- Pros: Simple, visible in `ls`, can include metadata (who, when, why)
- Cons: Not atomic (race between check and create), no automatic cleanup on crash

**C. Server-mediated reservations** (what intermute implements):
```http
POST /api/reservations
{"agent_id": "agent-1", "path_pattern": "internal/http/*.go", "exclusive": true, "ttl_minutes": 30}
```
- Pros: Conflict detection, TTL-based automatic expiry, glob patterns, audit trail
- Cons: Requires running server, network dependency, agents must check before editing

**Cursor's experience with pessimistic locking**: Cursor tried equal-status agents with file locking and found that agents held locks too long. With 20 agents, throughput dropped to that of 2-3 agents because lock contention became the bottleneck.

**Verdict**: Pessimistic locking works for 2-3 agents with coarse granularity (package-level, not file-level). Beyond that, lock contention dominates. The intermute reservation system with TTL expiry is a good implementation of this pattern.

### 3.2 Optimistic: Concurrency with Conflict Detection

**Mechanism**: Agents edit freely without locking. Before committing, they check whether their changes conflict with changes made by other agents since they started. If conflicts are detected, the agent retries or asks for resolution.

**Implementation options**:

**A. Content-hash versioning**:
```bash
# Before editing, record the file hash
BEFORE_HASH=$(sha256sum src/foo.go | cut -d' ' -f1)
# Edit the file
# Before committing, check the hash
AFTER_HASH=$(sha256sum src/foo.go | cut -d' ' -f1)
if [[ "$BEFORE_HASH" != "$AFTER_HASH" && "$(git diff HEAD -- src/foo.go)" != "" ]]; then
    echo "CONFLICT: file was modified by another agent"
fi
```

**B. Git-based detection** (what Clash does across worktrees):
```bash
# Use git merge-tree to simulate merge in memory
git merge-tree $(git merge-base HEAD other-branch) HEAD other-branch
# Check output for conflicts
```

**C. Claude Code's Edit tool** (natural OCC):
The Edit tool's `old_string` matching is a natural optimistic concurrency check. If another agent modified the context around the target string, the edit fails because the `old_string` no longer matches. This is functionally equivalent to a compare-and-swap operation:
```
CAS(expected_content="old_string", new_content="new_string")
```

**Cursor's experience with OCC**: When Cursor used optimistic concurrency, agents became risk-averse, avoiding hard tasks to minimize the chance of conflict-induced retries. The retry cost (re-reading, re-analyzing, re-editing) was high enough that agents learned to avoid contentious files entirely.

**Verdict**: OCC works well when conflicts are rare (agents editing different files). The Edit tool's built-in OCC is the strongest version because it operates at the exact edit site, not the whole file. The problem is what to do when conflicts are detected -- LLM-based conflict resolution is expensive and error-prone.

### 3.3 Turn-Based / Round-Robin

**Mechanism**: Only one agent can edit files at a time. Agents take turns, with a coordinator granting "the floor" to each agent in sequence.

**Implementation options**:

**A. Token-passing**:
```bash
# Single lock file controls who can edit
while ! mkdir /tmp/edit-token 2>/dev/null; do sleep 1; done
# Agent has the token -- can edit and commit
# When done:
rmdir /tmp/edit-token
```

**B. Time-sliced**:
```
Agent 1: minutes 0-4
Agent 2: minutes 5-9
Agent 3: minutes 10-14
(repeat)
```

**C. Phase-based** (what Clavain uses):
```
Phase 1: All agents read/research (no edits)
Phase 2: Agent A edits (others wait)
Phase 3: Agent B edits (others wait)
Phase 4: All agents test/review
```

**Verdict**: Turn-based is the simplest correct solution. It eliminates all coordination problems at the cost of parallelism. For 2-3 agents doing short tasks, the throughput loss is acceptable. For 5+ agents, the serialization bottleneck makes this impractical.

### 3.4 Message Passing Between Agents

**Mechanism**: Agents communicate through a message bus (intermute, Agent Teams mailbox, Redis pub/sub) to announce intentions, coordinate file ownership, and share state.

**Implementation patterns**:

**A. Intention broadcasting**:
```
Agent 1 -> all: "I'm about to edit internal/http/handlers.go"
Agent 2 -> Agent 1: "I'm currently editing that file, please wait"
Agent 1 -> all: "OK, I'll work on something else"
```

**B. Reservation requests** (intermute + interlock pattern):
```
Agent 1 -> intermute: RESERVE internal/http/*.go
intermute -> Agent 1: GRANTED (30 min TTL)
Agent 2 -> intermute: RESERVE internal/http/*.go
intermute -> Agent 2: DENIED (conflict with Agent 1)
```

**C. Claude Code Agent Teams mailbox**:
```
Lead -> Teammate 1: "You own src/auth/"
Lead -> Teammate 2: "You own src/api/"
Lead -> Teammate 3: "You own tests/"
```

**Verdict**: Message passing is the most flexible approach but requires all agents to participate. It is the basis for all production multi-agent systems. The question is where the coordination state lives -- in a central server (intermute), in files on disk (Agent Teams), or in agent memory (convention-only).

---

## 4. Claude Code Specifics

### 4.1 How Claude Code Interacts with Git

Claude Code uses the filesystem directly through three tools:

| Tool | Behavior | Concurrency Safety |
|------|----------|-------------------|
| `Read` | Reads file content. No locks, no caching. | Safe (read-only), but sees other agents' uncommitted changes |
| `Edit` | String-matching replacement (`old_string` -> `new_string`). Fails if `old_string` not found. | **Partially safe** -- natural OCC through string matching |
| `Write` | Atomic write (temp file + rename). Replaces entire file. | **Unsafe** -- last write wins, no conflict detection |
| `Bash(git add ...)` | Stages files. Acquires `.git/index.lock`. | **Unsafe** -- fails if another process holds `index.lock` |
| `Bash(git commit ...)` | Commits staged files. Acquires `.git/index.lock`. Runs pre-commit hooks. | **Unsafe** -- races with other commits, shared index |
| `Bash(git status ...)` | Polls repository state. Acquires `index.lock` for refresh. | **Unsafe** -- Claude Code polls frequently in the background, creating stale locks |

### 4.2 The Background Git Status Problem

Claude Code runs `git status --porcelain` frequently in the background to track repository state. This creates `.git/index.lock` files that can persist for 20+ seconds even after the git process exits ([anthropics/claude-code#11005](https://github.com/anthropics/claude-code/issues/11005)).

**Impact on multi-session**: In a shared working tree, Session A's background `git status` can block Session B's `git add` or `git commit` with a stale lock. This happens 2-3 times per minute during active use.

**Workaround**: Use `git status --no-optional-locks --porcelain` for background polling. This flag prevents the index refresh that creates the lock file. The tradeoff is that `git status` may report slightly stale information.

### 4.3 The Shared Index Problem in Detail

When two Claude Code sessions share the same `.git` directory:

```
Session A's mental model:     Session B's mental model:
  "I staged foo.go"            "I staged bar.go"

Actual index state:
  {foo.go, bar.go}  (BOTH are staged)

Session B commits:
  Commit includes BOTH foo.go and bar.go
  Session A's work is now in Session B's commit
  Session A's next commit has nothing to commit
```

This is the most dangerous failure mode because it is **silent**. No error is produced. The wrong files end up in the wrong commits.

**Solutions**:
1. **GIT_INDEX_FILE**: Give each session its own index file (see Section 6)
2. **Commit serialization**: Only one session commits at a time
3. **Stage-and-commit atomically**: Always run `git add` and `git commit` as a single operation: `git commit -a -m "message"` or `git add foo.go && git commit -m "message"` (but this still races with the index)

### 4.4 Pre-Commit Hook Interactions

When two sessions run `git commit` concurrently:

1. Session A acquires `index.lock`, starts pre-commit hook
2. Session B tries to commit, gets `index.lock` error, waits or fails
3. Session A's pre-commit hook (e.g., `gofmt`, `go vet`) runs on the full codebase, including Session B's uncommitted changes
4. If the hook fails because of Session B's half-finished work, Session A's commit is blocked

**The pre-commit double-bind**: Pre-commit hooks cannot distinguish "files I'm committing" from "files another session modified." They see the entire working tree. A formatter hook will format files from both sessions. A linter hook will lint files from both sessions. This means Session A's commit can fail because of Session B's code.

**Workaround**: Scope hooks to only staged files:
```bash
# In pre-commit hook, only check files being committed
FILES=$(git diff --cached --name-only --diff-filter=ACM)
for f in $FILES; do
    gofmt -l "$f"
done
```
This reduces but does not eliminate cross-session interference, because the staged files may include files from another session (due to the shared index problem).

---

## 5. Real Multi-Agent Systems

### 5.1 Devin (Cognition)

**Approach**: Full container isolation. Each Devin session runs in its own "Devbox" -- a complete virtual machine with shell, editor, and browser. There is no shared working tree between sessions.

**Git coordination**: Not needed. Each session has its own git clone. Sessions create pull requests to merge work back to the main branch. Conflicts are resolved at PR merge time.

**Relevance to shared-tree problem**: None. Devin sidesteps the problem entirely through physical isolation. This is the most expensive but most correct approach.

### 5.2 OpenHands (formerly OpenDevin)

**Approach**: Docker container sandboxing. Each agent session gets its own Docker container with an isolated filesystem. The platform supports multi-agent delegation through `AgentDelegateAction`, where a parent agent delegates subtasks to child agents.

**Git coordination**: Each container has its own working copy. Containers communicate through a REST API. The SDK supports hierarchical agent coordination through a delegation tool -- sub-agents operate as independent conversations that inherit the parent's model configuration and workspace context.

**Shared state**: The "workspace context" is inherited but the filesystem is isolated. There is no mechanism for two agents to edit the same file simultaneously.

**Relevance to shared-tree problem**: Like Devin, OpenHands avoids the problem through isolation. However, its delegation model is instructive -- the parent agent acts as a coordinator that can serialize work across child agents.

### 5.3 Claude Code Agent Teams (Anthropic)

**Approach**: Convention-based coordination within a shared working directory. Agent Teams does NOT use worktrees, separate indexes, or container isolation. All teammates share the same filesystem and the same `.git` directory.

**Git coordination**: None built-in. The documentation explicitly states: "Two teammates editing the same file leads to overwrites. Break the work so each teammate owns a different set of files." This is pure convention -- the system relies on the team lead assigning non-overlapping file ownership.

**Task coordination**: File-locked task claiming (JSON files on disk at `~/.claude/tasks/{team-name}/`). Tasks have dependency ordering. Teammates self-claim available tasks.

**Known limitations**: No session resumption with in-process teammates. Task status can lag. No mechanism to prevent two teammates from editing the same file if the lead assigns overlapping work.

**Relevance**: Agent Teams is the closest to our "without worktrees" constraint. It demonstrates that convention-based file ownership, combined with a central coordinator (the lead), is viable for 2-5 agents. But it offers no safety net -- if two teammates touch the same file, one's work is silently lost.

### 5.4 GitButler (Virtual Branches Without Worktrees)

**Approach**: GitButler uses Claude Code lifecycle hooks to automatically create virtual branches per session. All sessions share the same working directory. Changes are tracked per-session and assigned to the correct branch.

**How it works**:
1. Claude Code hooks notify GitButler when a session starts editing and when a chat completes
2. GitButler creates a virtual branch per session ID
3. File modifications are tracked and assigned to the session's branch
4. On chat completion, GitButler commits the session's changes to its branch

**Limitations** (from [gitbutlerapp/gitbutler#12224](https://github.com/gitbutlerapp/gitbutler/issues/12224)):
- "If both agents modify the same file simultaneously, one will overwrite the other's changes before GitButler can assign the diffs."
- "All applied virtual branches share the same physical workspace" -- no filesystem isolation.
- Runtime interference: code execution sees a mix of changes from all applied branches.
- Virtual branches are a logical abstraction over the same physical files.

**Relevance**: GitButler demonstrates the best current attempt at worktree-less multi-agent git coordination. But the core problem remains unsolved -- simultaneous edits to the same file create race conditions at the filesystem level, before GitButler can intervene.

### 5.5 Cursor (Hierarchical Agents)

**Approach**: After failing with both pessimistic locking and optimistic concurrency, Cursor adopted a hierarchical three-role model:

1. **Planners**: Continuously explore the codebase and create tasks. Read-only access.
2. **Workers**: Execute assigned tasks. Each worker gets exclusive ownership of specific files. Workers push changes when done.
3. **Judges**: Evaluate whether to continue at each cycle end. Read-only access.

**Key lesson**: Equal-status agents with locking = throughput collapse. Equal-status agents with OCC = risk aversion. The hierarchy works because planners and judges never write, and workers never overlap.

**Relevance**: This is the most practical architecture for shared-tree multi-agent work. The key insight is that most agents should be read-only. Only workers write, and workers are assigned non-overlapping file sets.

### 5.6 ccswarm (Worktree-Based)

**Approach**: Full worktree isolation with actor-model coordination. Each agent type (Frontend, Backend, DevOps, QA) gets its own worktree.

**Relevance**: Not applicable to the "without worktrees" constraint, but demonstrates the Actor Model pattern (message-passing, no shared state) which could be adapted.

### 5.7 intermute + interlock (This Project)

**Approach**: Server-mediated file reservations with TTL-based expiry.

The intermute service provides a reservation API:
```go
type Reservation struct {
    ID          string        // Unique reservation ID
    AgentID     string        // Agent holding the reservation
    Project     string        // Project scope
    PathPattern string        // Glob pattern for files (e.g., "pkg/events/*.go")
    Exclusive   bool          // True for exclusive lock, false for shared
    Reason      string        // Why this reservation was made
    TTL         time.Duration // Time-to-live
    CreatedAt   time.Time
    ExpiresAt   time.Time
    ReleasedAt  *time.Time
}
```

The interlock plugin wraps this as an MCP server for Claude Code, with a `PreToolUse:Edit` hook that checks for reservation conflicts before allowing edits.

**Design decisions**:
- Advisory-only PreToolUse hook (warns but does not block)
- Mandatory git pre-commit enforcement (blocks commits on conflicting reservations)
- Glob patterns for file matching (not exact paths)
- TTL expiry prevents orphaned locks from agent crashes

**Relevance**: This is the most sophisticated coordination mechanism in the codebase. It solves the pessimistic locking problem with TTL expiry and glob patterns, reducing the "agents hold locks too long" issue that Cursor encountered.

---

## 6. The GIT_INDEX_FILE Trick

### 6.1 Mechanism

Git supports an environment variable `GIT_INDEX_FILE` that overrides the default `.git/index` path. By giving each agent session its own index file, they can stage files independently without `index.lock` contention.

```bash
# Session 1 uses its own index
export GIT_INDEX_FILE=.git/index-session-1
git add src/foo.go
git commit -m "Add foo"

# Session 2 uses its own index (concurrently, no conflict)
export GIT_INDEX_FILE=.git/index-session-2
git add src/bar.go
git commit -m "Add bar"
```

### 6.2 How It Works

1. Each session sets `GIT_INDEX_FILE` to a unique path (e.g., `.git/index-{session-id}`)
2. `git add` stages files into the session-specific index
3. `git commit` creates a commit from the session-specific index
4. Both commits reference the same object store (`.git/objects/`), so they are part of the same repository history
5. Each commit's parent is `HEAD` at the time of commit -- but this creates a problem (see below)

### 6.3 The Commit Parent Problem

With separate indexes, both sessions see the same `HEAD`. When both commit:

```
Before:
  HEAD -> commit A

Session 1 commits (parent=A): HEAD -> commit B
Session 2 commits (parent=A): HEAD -> commit C  (overwrites ref, B is dangling!)
```

Both commits have parent A, but only the last one to update `refs/heads/main` survives as the branch tip. The other becomes a dangling commit (still in the object store but not reachable from any branch).

**This is essentially the same problem as concurrent pushes to the same branch.** Git's ref update is atomic (via lockfile on the ref), but it's last-writer-wins.

### 6.4 Solving the Parent Problem

**Option A: Sequential commits via lock**:
```bash
flock .git/commit.lock git commit -m "message"
```
Each session stages freely with its own index, but commits are serialized through a filesystem lock. This prevents the dangling commit problem.

**Option B: Create branch per session, merge to main**:
```bash
# Each session creates its own branch from main
GIT_INDEX_FILE=.git/index-$SESSION_ID git checkout -b work/$SESSION_ID main
# Stage and commit to the branch
GIT_INDEX_FILE=.git/index-$SESSION_ID git add src/foo.go
GIT_INDEX_FILE=.git/index-$SESSION_ID git commit -m "Add foo"
# A coordinator merges branches to main
git merge work/$SESSION_ID --no-edit
```
This is functionally equivalent to worktrees but without the filesystem duplication.

**Option C: Rebase before commit**:
```bash
# Before committing, rebase the index onto current HEAD
GIT_INDEX_FILE=.git/index-$SESSION_ID git read-tree HEAD
GIT_INDEX_FILE=.git/index-$SESSION_ID git add src/foo.go
GIT_INDEX_FILE=.git/index-$SESSION_ID git commit -m "Add foo"
```
This refreshes the index from the latest HEAD before staging, reducing (but not eliminating) conflicts.

### 6.5 Limitations

1. **Working tree is still shared**: Two sessions editing the same file on disk still create filesystem-level conflicts. `GIT_INDEX_FILE` only isolates the staging area, not the working tree.
2. **Git status is confusing**: Each session sees different "staged" vs "unstaged" states because their indexes differ.
3. **Hooks see one index**: Pre-commit hooks use whichever `GIT_INDEX_FILE` is set for that commit, so they only validate one session's staged files.
4. **Claude Code sets no `GIT_INDEX_FILE`**: There is no built-in way to set `GIT_INDEX_FILE` per Claude Code session. It would require a hook or wrapper.
5. **Background polling ignores it**: Claude Code's background `git status` uses the default index, not the session-specific one.

### 6.6 Verdict

`GIT_INDEX_FILE` is a powerful but incomplete solution. It solves the staging area contention problem (Section 2.2) and the shared index problem (Section 4.3), but it does not solve filesystem-level conflicts (Section 2.1) or read-after-write consistency (Section 2.4). It is best used as one layer in a multi-layer coordination stack.

---

## 7. Practical Architecture Proposals

### 7.1 Architecture A: Serialized Commits with Parallel Editing

**Principle**: Let agents edit files in parallel (partitioned by ownership), but serialize all git operations through a single coordinator.

```
┌──────────┐    ┌──────────┐    ┌──────────┐
│ Agent 1   │    │ Agent 2   │    │ Agent 3   │
│ (HTTP)    │    │ (Storage) │    │ (WS)      │
└─────┬─────┘    └─────┬─────┘    └─────┬─────┘
      │                │                │
      ▼                ▼                ▼
┌─────────────────────────────────────────────┐
│           Git Coordinator Process            │
│  - Receives commit requests via queue        │
│  - Validates no file overlap                 │
│  - Stages, commits, pushes sequentially      │
│  - Returns commit hash to requesting agent   │
└─────────────────────────────────────────────┘
```

**Implementation**:
1. Agents edit files directly on disk (partitioned by ownership)
2. When an agent wants to commit, it sends a request to the coordinator (via intermute message, file queue, or Unix socket)
3. The coordinator:
   a. Checks that no other commit is in progress
   b. Validates the requested files against active reservations
   c. Runs `git add` on the specified files
   d. Runs `git commit` with the agent's message
   e. Returns the commit hash
4. Pre-commit hooks run in the coordinator's context, isolated from other agents

**Pros**: Eliminates all git contention. Commits are clean and attributable. Pre-commit hooks work correctly.
**Cons**: Coordinator is a single point of failure. Commit latency increases with queue depth. Requires a running daemon.

### 7.2 Architecture B: Per-Session Index with Convention-Based Ownership

**Principle**: Each agent gets its own `GIT_INDEX_FILE`. File ownership is enforced by convention and hooks.

```
┌──────────────┐  ┌──────────────┐  ┌──────────────┐
│   Agent 1    │  │   Agent 2    │  │   Agent 3    │
│ INDEX_FILE=  │  │ INDEX_FILE=  │  │ INDEX_FILE=  │
│ .git/idx-1   │  │ .git/idx-2   │  │ .git/idx-3   │
└──────┬───────┘  └──────┬───────┘  └──────┬───────┘
       │                 │                 │
       ▼                 ▼                 ▼
┌────────────────────────────────────────────────┐
│              Shared .git/objects                │
│         Commit serialization via flock          │
└────────────────────────────────────────────────┘
```

**Implementation**:
1. SessionStart hook sets `GIT_INDEX_FILE=.git/index-$CLAUDE_SESSION_ID`
2. PreToolUse hook (Edit/Write) checks intermute reservations
3. All `git add` operations use the session-specific index
4. `git commit` is wrapped with `flock .git/commit.lock` for serialization
5. After commit, session's index is reset to HEAD: `git read-tree HEAD`

**Pros**: Agents can stage independently. No coordinator daemon needed. Uses existing git infrastructure.
**Cons**: Working tree conflicts remain unsolved. Claude Code integration is complex (env vars per session). Background git polling needs custom handling.

### 7.3 Architecture C: Beads-Driven Work Queue with Interlock Enforcement

**Principle**: Use Beads for task partitioning and interlock for file reservation enforcement. No git-level changes.

```
┌──────────┐         ┌──────────┐
│  Beads   │ ◄──────►│ intermute│
│  (tasks) │         │ (reserve)│
└─────┬────┘         └─────┬────┘
      │                    │
      ▼                    ▼
┌─────────────────────────────────┐
│     PreToolUse Hook (interlock) │
│  1. Check bead file annotations │
│  2. Check intermute reservations │
│  3. Block or warn on conflict    │
└─────────────────────────────────┘
      │
      ▼
┌─────────────────────────────────┐
│  Pre-Commit Hook (mandatory)    │
│  1. Verify committed files      │
│     match agent's reservations  │
│  2. Block commit on violation   │
└─────────────────────────────────┘
```

**Implementation**:
1. Every bead includes `Files:` annotation listing affected files/packages
2. Sessions register with intermute and reserve their file patterns
3. PreToolUse hook checks reservations before Edit/Write
4. Pre-commit hook validates that committed files are covered by the committing agent's reservations
5. Turn-based: only one agent commits at a time (enforced by pre-commit lock)

**Pros**: Builds on existing infrastructure (Beads, intermute, interlock). No git internals modifications. Advisory + mandatory enforcement layers.
**Cons**: Requires all agents to use interlock. Reservation TTL must be tuned. Does not prevent filesystem-level read-after-write issues.

### 7.4 Architecture D: Hybrid (The Recommended Approach)

**Principle**: Combine the best elements: file ownership partitioning (cheap), interlock reservations (enforcement), per-session index files (git safety), and commit serialization (correctness).

**Layers**:

| Layer | Mechanism | What It Prevents |
|-------|-----------|-----------------|
| 1. Convention | CLAUDE.md package ownership | Most file conflicts (agents work in different dirs) |
| 2. Advisory | interlock PreToolUse hook | Accidental file overlap (warns before edit) |
| 3. Git staging | GIT_INDEX_FILE per session | Index corruption (separate staging areas) |
| 4. Git commit | flock-serialized commits | Commit races (sequential commits) |
| 5. Mandatory | Pre-commit hook with reservation check | Unauthorized commits (blocks on violation) |

**Each layer catches what the previous layers miss**:
- Convention prevents 90% of conflicts (agents in different packages)
- Advisory interlock catches the remaining 9% (boundary files)
- Per-session index handles the 1% where two agents stage simultaneously
- Serialized commits prevent the commit-ordering problem
- Pre-commit validation is the final safety net

---

## 8. Comparison Matrix

### 8.1 Approaches for Shared Working Tree

| Approach | File Conflicts | Index Conflicts | Commit Races | Read Consistency | Setup Cost | Scalability |
|----------|---------------|----------------|--------------|-----------------|------------|-------------|
| Convention only | Prevented by discipline | Unprotected | Unprotected | Unprotected | None | 2-3 agents |
| Interlock reservations | Advisory warning | Unprotected | Unprotected | Unprotected | Medium | 3-5 agents |
| GIT_INDEX_FILE | Unprotected | **Solved** | Partially solved | Unprotected | Medium | 3-5 agents |
| Serialized commits | Unprotected | **Solved** | **Solved** | Unprotected | High | 5+ agents |
| Hybrid (recommended) | Advisory + convention | **Solved** | **Solved** | Unprotected | High | 3-5 agents |
| Git worktrees | **Solved** | **Solved** | N/A (branches) | **Solved** | Low | 10+ agents |
| Container isolation | **Solved** | **Solved** | N/A (PRs) | **Solved** | Very high | Unlimited |

### 8.2 Industry Approaches

| System | Isolation Method | Shared Tree? | Coordination |
|--------|-----------------|-------------|--------------|
| Devin | Container per session | No | PRs |
| OpenHands | Docker sandbox per session | No | Agent delegation |
| Claude Code Agent Teams | Convention only | **Yes** | Task list + messaging |
| GitButler | Virtual branches (logical) | **Yes** | Hook-based branch assignment |
| Cursor | Hierarchical roles | **Yes** (workers partition) | Planner-Worker-Judge |
| ccswarm | Git worktrees | No | Actor model |
| Vibe Kanban | Git worktrees | No | Kanban board |
| intermute + interlock | Server reservations | **Yes** | Reservation API + hooks |

---

## 9. Recommendations

### 9.1 For 2-3 Agents (Current State)

Use **Architecture C** (Beads + interlock):
1. Define package ownership in CLAUDE.md
2. Use Beads `Files:` annotations for task-level ownership
3. Deploy interlock PreToolUse hook for advisory warnings
4. Serialize commits through a simple lock (`flock .git/commit.lock`)
5. Accept that read-after-write consistency is not guaranteed

This is what the intermute project already has in place. It works because 2-3 agents can be manually coordinated and the conflict rate is low with good package boundaries.

### 9.2 For 3-5 Agents (Near-Term)

Add **per-session GIT_INDEX_FILE** (Architecture D hybrid):
1. Implement a SessionStart hook that sets `GIT_INDEX_FILE`
2. Wrap all git commit operations with `flock`
3. Add a pre-commit hook that validates files against interlock reservations
4. Consider using intermute itself as the commit coordination channel

### 9.3 For 5+ Agents (Future)

Use git worktrees or container isolation. The shared working tree approach does not scale beyond 5 agents because:
- Filesystem-level read-after-write conflicts become frequent
- Convention-based ownership breaks down as the number of agents exceeds the number of natural package boundaries
- The commit serialization bottleneck limits throughput
- Test interference (shared build artifacts, caches, databases) becomes unmanageable

### 9.4 What NOT to Do

1. **Do not let multiple agents run `git add` and `git commit` without coordination.** This is the most common failure mode and it silently misattributes work.
2. **Do not rely on `git merge` to resolve conflicts after the fact.** LLM-based merge resolution is unreliable and expensive.
3. **Do not use pessimistic file-level locking at scale.** Cursor's experience shows throughput collapses with more than a few agents.
4. **Do not assume the Edit tool's OCC is sufficient.** It catches same-site conflicts but not same-file/different-site conflicts where one edit changes the context for another.
5. **Do not ignore Claude Code's background git polling.** It creates stale `index.lock` files that block other sessions. Use `--no-optional-locks` if possible.

---

## 10. Sources

### Git Internals
- [Git Environment Variables](https://git-scm.com/book/en/v2/Git-Internals-Environment-Variables) -- GIT_INDEX_FILE and related variables
- [Git Hooks Documentation](https://git-scm.com/docs/githooks) -- Pre-commit hook behavior
- [Understanding Git's index.lock File](https://www.pluralsight.com/resources/blog/guides/understanding-and-using-gits-indexlock-file) -- Lock file mechanics
- [Azure DevOps: Git index.lock](https://learn.microsoft.com/en-us/azure/devops/repos/git/git-index-lock) -- Microsoft's documentation on index locking

### Claude Code Issues and Documentation
- [Stale .git/index.lock files (claude-code#11005)](https://github.com/anthropics/claude-code/issues/11005) -- Background git polling creates stale locks
- [Git process zombies (claude-code#10078)](https://github.com/anthropics/claude-code/issues/10078) -- Zombie processes from git operations
- [Claude Code Agent Teams Documentation](https://code.claude.com/docs/en/agent-teams) -- Official multi-agent coordination
- [Claude Code Common Workflows](https://code.claude.com/docs/en/common-workflows) -- Worktree-based parallel sessions

### Multi-Agent Systems
- [GitButler: Managing Multiple Claude Code Sessions Without Worktrees](https://blog.gitbutler.com/parallel-claude-code) -- Hook-based virtual branches
- [GitButler Issue #12224: Parallel Multi-Agent Isolation Concerns](https://github.com/gitbutlerapp/gitbutler/issues/12224) -- Limitations of virtual branches
- [OpenHands Platform (ICLR 2025)](https://arxiv.org/abs/2407.16741) -- Docker-sandboxed agent architecture
- [OpenHands Software Agent SDK](https://arxiv.org/html/2511.03690v1) -- Composable agent framework with delegation
- [ccswarm](https://github.com/nwiizo/ccswarm) -- Worktree-based multi-agent orchestration
- [Agent-MCP](https://github.com/rinadelph/Agent-MCP) -- MCP-based multi-agent coordination
- [Devin Enterprise Deployment](https://docs.devin.ai/enterprise/deployment/overview) -- Container isolation architecture

### Coordination Patterns
- [Optimistic Concurrency Control (Wikipedia)](https://en.wikipedia.org/wiki/Optimistic_concurrency_control) -- OCC fundamentals
- [File Locking in Linux](https://gavv.net/articles/file-locks/) -- flock/fcntl advisory locks
- [flock(2) Linux Manual Page](https://man7.org/linux/man-pages/man2/flock.2.html) -- Advisory lock system call
- [AI Coding Agents in 2026: Coherence Through Orchestration](https://mikemason.ca/writing/ai-coding-agents-jan-2026/) -- Industry perspective
- [Container Use for Isolated Parallel Coding Agents](https://www.infoq.com/news/2025/08/container-use/) -- Container-based isolation

### Internal Project Documents
- `/root/projects/Interverse/services/intermute/docs/research/research-multi-agent-patterns.md` -- Comprehensive multi-agent pattern research
- `/root/projects/Interverse/services/intermute/docs/research/2026-02-14-brainstorm-clavain-multi-session-coordination.md` -- Clavain integration brainstorm
- `/root/projects/Interverse/services/intermute/docs/research/2026-02-14-prd-multi-session-coordination.md` -- Multi-session coordination PRD
- `/root/projects/Interverse/services/intermute/internal/core/models.go` -- Reservation model with glob patterns and TTL
- `/root/projects/Interverse/services/intermute/internal/http/handlers_reservations.go` -- Reservation API handlers
