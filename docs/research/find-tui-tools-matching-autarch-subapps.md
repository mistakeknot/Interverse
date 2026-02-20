# TUI Tools Matching Autarch Subapps — Concrete Inspirations

**Date:** 2026-02-20
**Scope:** Open-source TUI tools that match the specific interaction patterns of Bigend, Gurgeh, Coldwine, and Pollard. Focus on actionable patterns worth adopting, not framework surveys.

---

## Subapp Summaries (for reference)

| Subapp | What it does |
|--------|-------------|
| **Bigend** | Multi-project mission control — aggregates data from Praude/Tandemonium/tmux across all projects, shows agent activity, provides web + TUI views |
| **Gurgeh** | TUI-first PRD/spec generation — multi-phase sprint with Arbiter LLM orchestration, confidence scoring per phase, cross-section consistency validation |
| **Coldwine** | Task orchestration for human-AI collaboration — assigns tasks to agents via worktrees, coordinates dispatch, manages the review/approve/merge loop, 2,219-line model |
| **Pollard** | General-purpose research intelligence — multi-domain hunters (GitHub, OpenAlex, PubMed, USDA, CourtListener), aggregates into confidence-tiered insights and reports |

---

## Bigend: Multi-Project Mission Control

### 1. claude-swarm (affaan-m)

**Repo:** https://github.com/affaan-m/claude-swarm
**What it does:** Multi-agent orchestration for Claude Code built for the Feb 2026 Claude Code Hackathon. Decomposes a task into a dependency graph via Opus 4.6, then runs parallel agents. Features an htop-style terminal UI (`ui.py`) showing agent progress, tool usage, costs, and file conflict state in real time. Includes session replay via JSONL event recording.

**Maps to:** Bigend — specifically the live agent status and cross-project activity feed.

**Pattern worth adopting:** The **htop-style row-per-agent layout** with columns for status, active tool, cost, and duration. Each agent is one row; the display updates at a fixed framerate. The key insight: cost and tool-usage columns are equally important as status — Bigend currently has no cost column per agent.

Also: the **Quality Gate phase** between execution and summary — a second Opus pass that reviews all agent outputs before showing results. Bigend could show a "review pending" state between agent completion and handoff to the user.

**Screenshot description:** A bordered table with columns: Agent ID | Status (spinner/done) | Current Tool | Files Touched | Cost | Duration. Header row shows aggregate: N agents, total cost, elapsed time. Bottom pane shows log stream from the selected agent.

---

### 2. agent-deck (asheshgoplani)

**Repo:** https://github.com/asheshgoplani/agent-deck
**What it does:** Terminal session manager for AI coding agents (Claude, Gemini, OpenCode, Codex). Built in Go + Bubble Tea on top of tmux. Adds AI-specific intelligence: 3-state status detection (Running/Waiting/Idle) with tool-specific busy indicators, session forking with context inheritance, fuzzy search across all sessions, MCP socket pooling, and hierarchical group organization.

**Maps to:** Bigend — the session list with intelligent status detection is exactly what Bigend's TUI view needs.

**Pattern worth adopting:** The **3-state status model (Running/Waiting/Idle)** with content hashing and a 2-second activity cooldown to prevent flickering. Bigend currently polls tmux; agent-deck's approach of detecting prompt patterns per tool (Claude Code vs. Gemini vs. Codex have different prompts) is more accurate.

Also: **status bar integration** — waiting sessions appear in the tmux status bar with `Ctrl+b 1–6` jump shortcuts. Bigend could surface "agents awaiting input" at the OS level without requiring the user to enter the TUI.

Also: **hierarchical group organization** — collapsible folders of sessions. For Bigend spanning many projects, this is directly applicable: group sessions by project, collapse completed sprints.

**Screenshot description:** Left panel: tree of groups → sessions, each session showing a colored dot (green=Running, yellow=Waiting, gray=Idle). Right panel: live terminal output from selected session. Bottom: fuzzy search bar, active filter tokens.

---

### 3. tmuxcc (nyanko3141592)

**Repo:** https://github.com/nyanko3141592/tmuxcc
**What it does:** Rust TUI dashboard for monitoring AI agents in tmux panes. Detects agent type by process name, parses agent-specific output (separate parser per tool), shows a tree of session → pane → agent with status, and provides a preview pane for selected agent output. Approval flow: when Claude Code hits a permission prompt, tmuxcc surfaces it and lets you approve/reject without switching windows.

**Maps to:** Bigend — the approval flow is a missing feature. When an agent waits for a `--allowedTools` permission prompt, Bigend currently has no way to surface that without tmux attach.

**Pattern worth adopting:** **Per-tool output parsers** (separate `claude_code.rs`, `opencode.rs`, `codex_cli.rs` modules) that extract structured state from raw terminal output. Bigend's tmux integration would benefit from this approach rather than trying to parse all agents uniformly. Also: the **action bar at the bottom** with keyboard shortcuts for the most common operations (Approve/Reject/All) shown inline in the TUI rather than requiring escape to tmux.

**Architecture note from source:** tree-structured state (`AppState → AgentTree`), with a monitor task polling at 500ms. Clean separation between `monitor/`, `parsers/`, `tmux/`, and `ui/` packages — directly adoptable for Bigend's Go architecture.

---

### 4. lazyactions (nnnkkk7)

**Repo:** https://github.com/nnnkkk7/lazyactions
**What it does:** Lazygit-style TUI for GitHub Actions — browse workflow runs, stream job logs, trigger/cancel/rerun workflows, fuzzy search. Shown at HN Feb 2026.

**Maps to:** Bigend — specifically the CI/CD pipeline view. Bigend's web view shows build status; this is the terminal equivalent pattern.

**Pattern worth adopting:** The **lazygit panel pattern**: left panel is a navigable list with status indicators per row; right panel is the detail/log view for the selected item. This two-pane layout is the dominant pattern for "many things, one detail" dashboards and is directly applicable to Bigend's TUI agent list.

Also: the framing that motivated the tool — "push code → open browser → Actions tab → wait → find workflow" — is exactly the context-switch pain Bigend's TUI is meant to solve for agent sessions. The HN thread has useful discussion on keyboard shortcut design for this pattern.

---

## Gurgeh: PRD/Spec Generation with Confidence Scoring

### 5. charmbracelet/huh

**Repo:** https://github.com/charmbracelet/huh
**What it does:** Terminal forms and prompts library for Go. Groups of fields act as "pages" in a multi-step flow. Ships with: Input, Text (multiline), Select, MultiSelect, Confirm field types. Built-in spinner, validation per field with inline error display, autocomplete suggestions, responsive height, and a first-class accessible mode. Integrates directly as a `tea.Model` into Bubble Tea applications.

**Maps to:** Gurgeh — the onboarding/configuration flow and any section of the sprint where the user provides structured input (goals, constraints, stakeholders, CUJs).

**Pattern worth adopting:** **Group-as-page**: each Gurgeh sprint phase (Problem → Goals → CUJs → Architecture → Validation) maps naturally to a `huh.Group`. The user navigates forward/back through groups; `huh` handles scrolling within a group when terminal height is small. Validation per field allows Gurgeh's Arbiter to surface "this CUJ is missing a success metric" before allowing phase advance.

The critical gap in Gurgeh's current TUI is that the Arbiter's confidence score and phase-advance decision live in Go code but aren't surfaced as a structured form element. `huh.NewConfirm()` with a custom description showing the confidence breakdown ("Section scores: Goals 87%, CUJs 62%, Architecture 91% — minimum threshold 70%") would give users a clear gate display before they commit to the next phase.

**Screenshot description:** Full-screen form with phase indicator at top (dots or step numbers). Current group of fields rendered in center. Error messages appear inline below each field. Bottom: [Enter] Next / [Esc] Back / [Ctrl+C] Quit.

---

### 6. ralph-tui (subsy)

**Repo:** https://github.com/subsy/ralph-tui
**What it does:** Terminal UI for orchestrating AI coding agents against a task list. Core loop: select task → build prompt with context → execute agent → detect completion → next task. Supports pause/resume with disk persistence, cross-iteration context (tracks patterns from previous tasks), subagent call tracing in real time, and remote monitoring via WebSocket. Built in TypeScript/Bun (original) and Rust/ratatui (observation dashboard variant).

**Maps to:** Gurgeh — specifically the Arbiter's sprint orchestration loop. Ralph's `ExecutionEngine` state machine (idle → running → paused → completed → failed) is the closest open-source analog to Gurgeh's multi-phase sprint state machine.

**Pattern worth adopting:** **Cross-iteration context** — Ralph tracks what patterns emerged across tasks so each new task gets relevant context. For Gurgeh, this maps to the cross-section consistency check: sections generated in Phase 3 should be visible as context when Phase 5 is being generated. Ralph's session persistence model (`.ralph-tui/session.json`) is directly applicable to Gurgeh's sprint checkpoint saves in `.gurgeh/specs/history/`.

Also: **subagent call tracing** — when the Arbiter fires a Pollard scan during sprint Phase 2, Gurgeh's TUI should show the subagent call inline (indented under the current phase row) with its status. Ralph does this for nested Claude Code calls.

Also: **pause/resume across crashes** — Gurgeh sprints can be long (10+ minutes with multiple LLM calls). A persistent state file that allows resume after crash is a safety feature Gurgeh currently lacks at the TUI layer.

---

## Coldwine: Task Orchestration + Agent Coordination

### 7. pueue (Nukesor)

**Repo:** https://github.com/Nukesor/pueue
**What it does:** Rust command-line task manager for sequential and parallel execution of long-running shell commands. Daemon architecture: `pueued` runs continuously, `pueue` CLI controls it from any terminal. Per-group parallelism limits. Task dependencies. JSON output for integration. Disk-persistent queue. Log streaming per task with `pueue follow <id>`. Pause/resume at group or task granularity.

**Maps to:** Coldwine — Coldwine is essentially a domain-specific pueue where "tasks" are agent work items, "workers" are Claude Code instances, and the "queue" is `.tandemonium/`. The structural parallels are direct.

**Pattern worth adopting:** **Named groups with independent parallelism limits** — Coldwine could adopt group semantics per worktree or per project. Group "frontend" runs max 2 agents; group "infra" runs max 1. Pueue shows group headers in `pueue status` output with aggregate counts.

The most transferable UI pattern: **the status table format**. Pueue's `status` output shows: ID | Group | Status | Command (truncated) | Started | End. Each row is one task. Status uses color: green=Success, blue=Running, yellow=Queued, red=Failed. This is directly applicable to Coldwine's task board view and cleaner than the current approach of showing full task descriptions.

Also: **`pueue follow <id>`** is the equivalent of Coldwine's "attach to agent" — stream output from a specific running task without switching terminal windows.

**Screenshot description:** Terminal table with border. Header: group name (with parallelism count). Rows: ID | Status (colored) | Command | Runtime. Footer: summary counts. Selected row highlighted. Keyboard shortcut bar.

---

### 8. taskwarrior-tui (kdheepak)

**Repo:** https://github.com/kdheepak/taskwarrior-tui
**What it does:** Rust TUI for Taskwarrior. Vim-style navigation, live filter updates, multiple selection, tab completion, color coding by priority/urgency. Displays tasks in a sortable table with custom columns (project, tags, due date, urgency score, status). Context-aware: filters persist per session.

**Maps to:** Coldwine — the task table view is the closest existing TUI to what Coldwine's task board should look like. Taskwarrior's urgency score (a computed float) is directly analogous to Coldwine's task priority.

**Pattern worth adopting:** **Sortable columns with computed scores visible inline** — urgency is shown as a numeric column, not hidden in a detail pane. For Coldwine, showing the task's computed priority + assigned agent + drift status as sortable columns (not just task name and status) would significantly improve scan-ability.

Also: **live filter updates** — type to filter the task list without a separate search mode. Current Coldwine TUI requires mode switching to filter.

Also: **multiple selection** — select N tasks and apply an action (assign to agent, complete, defer) to all of them. Coldwine currently operates one task at a time.

---

## Pollard: Research Intelligence

### 9. Pueue (as parallel worker visibility pattern — Nukesor)

(See entry above for repo.)

**Maps to:** Pollard — when `pollard scan` runs multiple hunters in parallel (GitHub Scout, OpenAlex, PubMed, USDA, CourtListener), there is no visibility into which hunters are running, which have completed, and what each found. Pueue's status table where each row is one hunter provides exactly this.

**Pattern worth adopting:** The **per-task log streaming** model: after all hunters complete, `pueue log <id>` shows the full output of any individual hunter. For Pollard, this means the user can inspect raw OpenAlex results without the aggregated report hiding them. The drill-down from aggregate → individual source is the key pattern.

---

### 10. Textual (Textualize) — async workers + DataTable

**Repo:** https://github.com/Textualize/textual
**What it does:** Python TUI framework. Key feature for Pollard's use case: `@work(exclusive=False)` decorator runs multiple async workers concurrently, each independently updating the TUI. DataTable widget for structured result display. Scores returned from `matcher.match()` are usable for sorting and highlighting. Workers update the UI as soon as their result is ready (fan-out to fan-in pattern).

**Maps to:** Pollard — the fan-out + progressive result display pattern. When Pollard's hunters return results at different times (GitHub fast, PubMed slow), the display should update progressively as each hunter completes, not wait for all to finish.

**Pattern worth adopting:** **Progressive result reveal with source attribution** — each row in the DataTable has a "Source" column and an "Arrived at" timestamp. Rows appear as hunters complete. A spinner column shows in-progress hunters. Completed rows show a confidence tier (High / Medium / Low) as a colored badge.

The confidence display pattern specifically: instead of a raw float (0.87), show a qualitative tier with the float as secondary information. "High (0.87)" in green is more scannable than "0.87" alone. Textual's CSS-like styling makes this straightforward with class-based coloring.

**Screenshot description:** Header: "Pollard Research — [query] — 3/7 hunters complete". DataTable with columns: Source | Title | Confidence | Domain | Arrived. Running hunters shown as spinner rows with "Fetching..." in the Title column. Completed rows sorted by confidence descending. Selected row shows full abstract/detail in a bottom panel.

---

### 11. overmind (DarthSim)

**Repo:** https://github.com/DarthSim/overmind
**What it does:** Procfile-based process manager using tmux for session isolation. Each process in the Procfile gets its own tmux window. `overmind connect <name>` attaches to any process. Port assignment is automatic (base + step per process). Processes can be marked "optional" (death does not kill siblings). Individual process restart without full stack restart.

**Maps to:** Pollard — when `pollard watch` runs continuous monitoring across multiple competitor/domain watchers, each watcher is a long-running process. Overmind's model of "named processes with individual attach" maps directly.

**Pattern worth adopting:** **Named process + attach** — each Pollard hunter in watch mode gets a name ("github-scout", "openalex", "pubmed"). The Pollard TUI shows a process list with status. Pressing Enter on a hunter attaches to its output stream. This eliminates the current opacity of `pollard watch` where all output is mixed in stdout.

Also: **optional process death** — if the USDA hunter fails (rate limit), the watch loop should continue with the remaining hunters. Overmind's `OVERMIND_CAN_DIE` concept (processes that are allowed to exit without triggering global shutdown) is directly applicable to Pollard's hunter resilience model.

---

## Cross-Cutting Pattern: The Lazy* Layout

The lazygit / lazydocker / lazyactions family converged on a consistent layout that is highly applicable to all four Autarch subapps:

```
+---------------------------+----------------------------------+
| Left panel: scrollable    | Right panel: detail view for     |
| list with status per row  | selected item. Live-updating.    |
|                           |                                  |
| > item 1  [running] ●     | [full output / log / content]    |
|   item 2  [done]    ✓     |                                  |
|   item 3  [failed]  ✗     |                                  |
|   item 4  [waiting] ◌     |                                  |
+---------------------------+----------------------------------+
| Bottom: action bar — keyboard shortcuts for selected item    |
+-------------------------------------------------------------+
```

The key design decisions in this pattern:
1. **Status column is always visible**, not collapsed into a detail view
2. **Color is the primary status signal**, not position or icons alone
3. **The detail pane is context-sensitive** — it changes content when you navigate the list, with no explicit "open" action required
4. **Action bar shows only actions valid for the current selection** — not a fixed set of all possible actions

Bigend, Coldwine, and Pollard all have a "list of things with status" as their primary view. All three would benefit from this layout over their current approaches.

---

## Summary Table

| Tool | Repo | Maps to | Key pattern |
|------|------|---------|------------|
| claude-swarm | github.com/affaan-m/claude-swarm | Bigend | htop-style agent rows with cost + tool columns |
| agent-deck | github.com/asheshgoplani/agent-deck | Bigend | 3-state status detection, hierarchical groups, tmux status bar integration |
| tmuxcc | github.com/nyanko3141592/tmuxcc | Bigend | Per-tool output parsers, inline approval flow |
| lazyactions | github.com/nnnkkk7/lazyactions | Bigend | Two-pane lazygit layout for CI/agent lists |
| charmbracelet/huh | github.com/charmbracelet/huh | Gurgeh | Group-as-phase multi-step form, inline confidence gate display |
| ralph-tui | github.com/subsy/ralph-tui | Gurgeh | Sprint state machine, cross-iteration context, subagent tracing, crash-resume |
| pueue | github.com/Nukesor/pueue | Coldwine + Pollard | Named task queues, per-group parallelism, status table, log streaming per task |
| taskwarrior-tui | github.com/kdheepak/taskwarrior-tui | Coldwine | Computed score column, live filter, multi-select batch actions |
| Textual | github.com/Textualize/textual | Pollard | Progressive result reveal, fan-out async workers, confidence tier display |
| overmind | github.com/DarthSim/overmind | Pollard | Named long-running hunters, individual attach, optional-death resilience |

---

## Prioritized Adoption Candidates

If forced to pick three patterns to implement first:

**1. 3-state status detection (agent-deck)** — Bigend's most glaring gap. The difference between "Claude is thinking" and "Claude is waiting for you" is critical; missing it causes unnecessary interruptions.

**2. Group-as-phase with confidence gate (huh)** — Gurgeh's Arbiter already computes confidence scores; surfacing them as a form element before phase advance would make the TUI an actual workflow tool rather than a display.

**3. Progressive result reveal with source attribution (Textual pattern)** — Pollard scans can take 30–60 seconds; showing a spinner until all hunters finish is a poor experience. Fan-out display where each hunter row updates independently is a low-implementation-cost, high-UX-value change.
