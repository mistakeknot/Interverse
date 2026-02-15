# Multi-Session Coordination Without Worktrees

**Date:** 2026-02-15
**Bead:** iv-rlnq
**Status:** Brainstorm
**Question:** What else do we need for Clavain to use Intermute for coordinating multiple Claude Code sessions on the same repo without worktrees?

---

## Problem Statement

We want multiple Claude Code sessions to safely edit the same git repo simultaneously, all committing to `main`, without using git worktrees. This requires solving three interrelated problems:

1. **File-level isolation** — two sessions editing the same file produce corrupted output
2. **Git index serialization** — `git add` + `git commit` are not atomic across sessions; concurrent operations corrupt the index
3. **Work partitioning** — sessions need to know what each other is working on to avoid overlap

## Current Stack Assessment

| Layer | Component | Ready | Gaps |
|-------|-----------|-------|------|
| **Service** | Intermute | Agent registry, heartbeats, messaging, file reservations (advisory), WebSocket broadcast, domain entities | No git-aware operations. Reservations advisory only. |
| **Plugin** | Interlock | PreToolUse:Edit warnings, pre-commit blocking, reserve/release/check MCP tools, join/leave/status commands | Edit warnings don't block. No auto-reserve. No git index coordination. |
| **Hub** | Clavain | Sprint workflow, parallel dispatch, HANDOFF.md, beads tracking | No interlock integration in sprint flow. No conflict detection. No merge strategy. |
| **Native** | CC Agent Teams | Shared task list, teammate messaging, file locking on task claims, tmux split panes | Experimental. File-based (not Intermute-backed). Requires `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`. |

### What Works Today

- Intermute's reservation API is sound: glob patterns, exclusive/shared modes, TTL with heartbeat cleanup, WebSocket notifications
- Interlock's pre-commit hook correctly blocks commits touching reserved files (mandatory gate)
- Interlock's PreToolUse:Edit hook detects conflicts (advisory only)
- Agent registration + heartbeat lifecycle prevents stale agent accumulation
- Intermute messaging enables inter-session communication

### What Doesn't Work

- **No auto-join** — Clavain workflows don't call `/interlock:join`, so sessions are invisible to each other
- **Edit hook is advisory** — warns but doesn't prevent edits to reserved files
- **No auto-reserve** — agents must explicitly call `reserve_files` before editing; nobody does this manually
- **No git serialization** — two sessions can `git add` + `git commit` simultaneously, corrupting the index
- **No post-commit sync** — Session A commits; Session B doesn't know and may have stale state
- **No work partitioning** — two sessions can claim the same bead issue

---

## Gap Analysis by Priority

### P0: Critical — Multi-Session Breaks Without These

#### 1. Git Index Isolation + Commit Serialization

**Problem:** Git's `.git/index` is a single binary file. Two sessions running `git add` concurrently get `index.lock` errors. Even if they succeed, the shared index means Session A's commit accidentally includes Session B's staged files.

**Solution: Per-Session GIT_INDEX_FILE + flock-serialized commits**
- SessionStart hook sets `GIT_INDEX_FILE=.git/index-$CLAUDE_SESSION_ID` — each session gets its own staging area
- All `git add` operations use the session-specific index (no contention)
- `git commit` is wrapped with `flock .git/commit.lock` for serialization (only one session commits at a time)
- After commit, session index is refreshed: `git read-tree HEAD`
- This approach was validated by research (see `docs/research/research-git-less-coordination.md` Section 6)

**Note:** This eliminates the need for a commit-lock endpoint in Intermute. A local `flock` is simpler and avoids network round-trips. Intermute's role shifts to file-level reservation coordination, not git-level locking.

**Complexity:** Low-Medium (SessionStart hook + flock wrapper in pre-commit)

#### 2. Mandatory File Reservation on Edit

**Problem:** Interlock's PreToolUse:Edit hook only warns. Agents freely overwrite each other's files.

**Solution: Blocking Edit Hook + Auto-Reserve**
- PreToolUse:Edit returns `{"decision": "block", "message": "..."}` when file is exclusively reserved by another session
- On first edit of any file, auto-create a reservation (15min TTL, auto-renewing on subsequent edits)
- On commit, auto-release reservations for committed files

**Complexity:** Medium (hook behavior change + auto-reserve logic in interlock)

#### 3. Session Registration in Sprint Workflow

**Problem:** Clavain's `/sprint` and `/work` don't register with Intermute.

**Solution: Auto-Join on Session Start**
- SessionStart hook: if Intermute is reachable, auto-register agent
- `/sprint` step 1: call `interlock:status` to show active sessions and their reservations
- Inject active-session context into the sprint prompt

**Complexity:** Low (hook modification + skill text update)

### P1: Important — Coordination Is Fragile Without These

#### 4. Post-Commit Sync Notification

**Problem:** After Session A commits, Session B has stale HEAD. Next edit may conflict.

**Solution: Commit Event Broadcasting**
- New endpoint: `POST /api/events/committed` — agent reports commit hash + changed files
- Intermute broadcasts to WebSocket subscribers
- Interlock's PostToolUse:Bash hook detects `git commit` success → calls endpoint → triggers all other sessions' next PreToolUse to `git pull --rebase`

**Complexity:** Medium (new endpoint + hook + client-side pull logic)

#### 5. Work Partitioning via Beads

**Problem:** Two sessions can claim the same bead issue simultaneously.

**Solution: Bead-Agent Binding**
- When `bd update <id> --status=in_progress` runs, record `INTERMUTE_AGENT_ID` in issue metadata
- If another session tries to claim the same issue, warn via Intermute message
- `/sprint` shows which beads are claimed by which sessions

**Complexity:** Low (beads metadata + warning in interlock)

#### 6. Dirty-Tree Pre-Flight Check

**Problem:** Session B starts, finds unexpected dirty tree from Session A's uncommitted work.

**Solution: Pre-Flight Status Check**
- SessionStart: check `git status` for dirty tree
- Query Intermute for active agents with reservations
- If dirty tree + no active agents → stale state, warn user
- If dirty tree + active agent → another session is working, warn and suggest coordination

**Complexity:** Low (SessionStart hook enhancement)

### P2: Nice to Have — Significantly Improves UX

#### 7. Live Awareness via Statusline

- Interline statusline shows "2 agents: AgentA→src/foo.go, AgentB→tests/"
- WebSocket subscription to Intermute reservation events
- Update on reserve/release/commit

#### 8. Conflict Resolution Automation

- When `git pull --rebase` produces conflicts, attempt auto-resolution
- If auto-merge fails, send Intermute message to both sessions with conflict details
- Escalation path: auto-merge → message other agent → ask user

#### 9. Agent Teams Evaluation

- Claude Code's experimental Agent Teams feature overlaps significantly with this design
- Uses file-based task list + locking at `~/.claude/teams/`
- Could supplement Intermute (Agent Teams for task coordination, Intermute for file reservations)
- Or could be the primary mechanism if it matures (reduces custom infrastructure)
- **Decision needed:** build on Intermute (we control it) vs. adopt Agent Teams (Anthropic controls it)

---

## Architecture Decision: Intermute-First vs. Agent Teams

| Factor | Intermute-First | Agent Teams-First |
|--------|----------------|------------------|
| **Control** | Full — we own the code | None — experimental CC feature |
| **Persistence** | SQLite with events, survives restarts | File-based, per-team lifetime |
| **Cross-host** | HTTP API works across network | Local only (file-based) |
| **Integration depth** | Deep — hooks, MCP tools, WebSocket | Shallow — env var + natural language |
| **Stability** | Stable (our code) | Experimental, may change/break |
| **Effort** | Build P0-P1 features (~2 weeks) | Evaluate + bridge (~1 week) |
| **File locking** | Advisory (application-level) | Advisory (file-based flock) |

**Recommendation:** Build on Intermute for the coordination primitives (reservations, commit lock, messaging), but evaluate Agent Teams for the orchestration layer (task assignment, teammate awareness). They complement rather than compete.

---

## Implementation Phases

### Phase 1: Git Safety (Interlock hooks, no Intermute changes needed)
1. SessionStart hook sets `GIT_INDEX_FILE=.git/index-$CLAUDE_SESSION_ID` (per-session staging)
2. Pre-commit hook wraps commit with `flock .git/commit.lock` (serialized commits)
3. Post-commit hook: `git read-tree HEAD` to refresh index + broadcast via Intermute WebSocket

### Phase 2: Mandatory Reservations (Interlock)
4. PreToolUse:Edit → blocking mode (not advisory)
5. Auto-reserve on first edit
6. Auto-release on commit

### Phase 3: Workflow Integration (Clavain)
7. SessionStart auto-join
8. Sprint pre-flight (active agents + dirty tree check)
9. Bead-agent binding
10. Post-commit rebase notification

### Phase 4: UX Polish
11. Statusline integration
12. Conflict resolution automation
13. Agent Teams bridge evaluation

---

## Open Questions

1. **Commit lock granularity** — project-level lock (simple) vs. file-set lock (allows parallel commits to disjoint files)?
2. **Auto-reserve TTL** — 15 minutes default? Should it auto-renew on each edit?
3. **Rebase automation** — should sessions auto-pull after another session commits, or just warn?
4. **Agent Teams bridge** — worth the effort, or wait for the feature to stabilize?
5. **Scope** — should this work across the Interverse monorepo (each subproject has its own .git), or only within a single repo?

---

## Original Intent: Future Iteration Triggers

These ideas surfaced during research but are out of scope for the initial build:

| Trigger | Feature | Why Deferred |
|---------|---------|-------------|
| Agent count > 3 | Commit queue (FIFO) instead of lock | Contention at scale |
| Cross-host sessions | Intermute over Tailscale | Currently single-host only |
| Merge conflicts > 2/session | Auto-stash + retry protocol | Need data on conflict frequency first |
| Agent Teams GA | Replace interlock with native teams | Depends on Anthropic's roadmap |
| Codex CLI sessions | Codex → Intermute bridge | Different agent lifecycle model |
