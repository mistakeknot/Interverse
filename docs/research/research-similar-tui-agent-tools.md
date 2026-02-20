# Research: Similar TUI Agent Tools for Autarch Inspiration

**Date:** 2026-02-19
**Purpose:** Identify open-source projects combining TUI interfaces with AI agent orchestration, multi-agent monitoring, or developer mission control dashboards — to inform the design of Autarch (Bigend, Gurgeh, Coldwine, Pollard).
**Related:** `docs/research/research-schmux-repo-for-autarch.md` (in-depth schmux analysis, already complete)

---

## Context: What Autarch Is

Autarch is a suite of four Go Bubble Tea TUI apps that render Intercore kernel state via the `ic` CLI:

| App | Role |
|-----|------|
| **Bigend** | Multi-project mission control — overview of all active `ic` runs across repos |
| **Gurgeh** | PRD generation with confidence scoring — wizard-style structured document creation |
| **Coldwine** | Task orchestration with agent coordination — per-run dispatch management and event streaming |
| **Pollard** | Research intelligence with multi-domain hunters — multi-source synthesis with structured output |

---

## Summary: Top 10 Inspirations

Ranked by relevance and actionable pattern density.

---

### 1. schmux — Smart Cognitive Hub on tmux

**Repo:** https://github.com/sergeknystautas/schmux
**Stars:** Active (v1.1.1, Feb 2026)
**Language:** Go + React/TypeScript
**What it does:** Multi-agent AI orchestration on tmux. Runs Claude, Codex, Gemini in isolated tmux sessions per git clone. Web dashboard for monitoring, Go daemon for lifecycle management.

**Covered in full depth:** See `docs/research/research-schmux-repo-for-autarch.md`

**Key patterns for Autarch:**

- **Dual-signal status detection**: agents write to a `$SCHMUX_STATUS_FILE`; LLM (NudgeNik) classifies state from raw terminal output as fallback after 5+ min silence. Maps to Pollard's research status classification.
- **Bootstrap-then-stream viewport**: send last 1000 lines as "full" snapshot on connect, then stream incremental "append" chunks. Maps directly to Coldwine's event viewport.
- **SessionTracker goroutine + buffered channel**: one goroutine per active run, sends events to a buffered channel, consumer (UI) drains at its own rate. Adapt to `tea.Cmd` in Bubble Tea.
- **Workspace-as-container, sessions-as-tabs**: workspace card groups multiple sessions with a tab bar. Maps to Bigend's run-as-container, dispatches-as-tabs model.
- **NudgeNik structured JSON classification**: LLM extracts `{state, confidence, evidence, summary}` from raw terminal lines. Maps directly to Gurgeh's confidence scoring and Pollard's synthesis.
- **Human-as-coordinator philosophy**: TUI is an observability surface, not an autonomous orchestrator. Exact philosophy for Autarch.

**Bigend mapping:** workspace card → run card, session tabs → dispatch tabs
**Coldwine mapping:** SessionTracker → RunTracker, bootstrap pattern → ic event stream
**Gurgeh mapping:** quick-launch presets → PRD templates, NudgeNik JSON → confidence schema
**Pollard mapping:** NudgeNik classifier → research domain classifier

---

### 2. claude-squad — Multi-Agent Terminal Manager

**Repo:** https://github.com/smtg-ai/claude-squad
**Stars:** 6,066
**Language:** Go
**What it does:** Manages multiple Claude Code, Aider, Codex, OpenCode, and Amp instances in separate workspaces. Provides a simple Bubble Tea TUI with a list-pane-left + detail-pane-right layout for navigation and management.

**Architectural pattern:** Classic two-pane TUI — left list of agents, right panel shows selected agent's session. Each agent runs in its own git worktree via tmux. The TUI is a thin monitor; the actual agent processes run independently.

**Key patterns for Autarch:**

- **Two-pane Bubble Tea layout**: vertical split with a scrollable list on the left and a contextual detail view on the right. The most proven layout pattern for mission control in this space.
- **Agent lifecycle as list items**: each item shows agent type (icon), task name, status, and relative timestamp. Minimal but information-dense.
- **Worktree isolation**: each agent gets its own git worktree to prevent file conflicts. For Coldwine, Intercore dispatches already provide this isolation.
- **Keyboard-driven navigation**: `j/k` to move list, `Enter` to focus, `q` to quit, `?` for help. Standard vi-mode keybindings that users expect.
- **Thin monitor principle**: claude-squad does not orchestrate agents — it just shows their state and provides attach/kill shortcuts. Autarch should follow this same principle.

**Maps to:** Bigend (list layout), Coldwine (agent lifecycle items), general UI conventions

---

### 3. NTM (Named Tmux Manager)

**Repo:** https://github.com/Dicklesworthstone/ntm
**Stars:** 149
**Language:** Go
**What it does:** Spawns, tiles, and coordinates Claude Code, Codex, and Gemini CLI agents across tmux panes with a TUI command palette. Features animated gradients, Catppuccin themes, context monitoring, multi-channel notifications, conflict tracking, and JSONL event logging.

**Architectural pattern:** Command palette as primary interaction surface. NTM's TUI is not a dashboard — it's a launcher + coordinator. You invoke it to spawn sessions, send broadcast prompts, check quotas, and rotate accounts. The actual agents run in tmux panes outside the TUI.

**Key patterns for Autarch:**

- **Command palette TUI** (`internal/palette/`): Bubble Tea component showing categorized commands with fuzzy search. For Gurgeh, a palette-style wizard for selecting PRD templates and confidence thresholds.
- **Agent color coding**: Claude → Mauve, Codex → Blue, Gemini → Yellow, User → Green. Consistent color identity across all status displays. Autarch should assign colors to agent types in Bigend/Coldwine.
- **Robot mode** (`--robot-status`, `--robot-list`, `--robot-send`): JSON output for machine consumption. For Autarch, each app should support `--json` flag for scripting.
- **Context monitoring**: NTM tracks token usage and detects when agents hit context limits, triggering automatic compaction notifications. For Bigend, show context utilization per active dispatch.
- **Conflict tracking**: detects when multiple agents modify the same file concurrently. For Bigend, flag dispatch conflicts on the run card.
- **Animated gradients + Catppuccin themes**: NTM is the strongest proof-of-concept for aesthetically polished Go TUI with Bubble Tea. Use as visual reference for Autarch's styling.
- **Service layer pattern** (planned): CLI, TUI, and API all consume a shared `internal/core` layer. Autarch should structure each app with a `core/` package that wraps `ic` CLI calls, keeping presentation logic out of the data layer.

**Maps to:** Gurgeh (palette UX), Bigend (agent color coding, conflict indicators), all apps (robot mode, service layer)

---

### 4. agent-deck — AI-Aware Terminal Session Manager

**Repo:** https://github.com/asheshgoplani/agent-deck
**Stars:** 933
**Language:** Go (Bubble Tea)
**What it does:** Terminal session manager for Claude, Gemini, OpenCode, Codex. Adds AI-specific intelligence on top of tmux: smart status detection (knows when Claude is thinking vs. waiting), session forking with context inheritance, MCP socket pooling, global search.

**Architectural pattern:** Structured as tmux + AI awareness. The "smart status detection" is the core innovation — agent-deck knows if a session is in an active thinking state, a waiting state, or stalled. It does this by parsing terminal output patterns, not by querying the AI API directly.

**Key patterns for Autarch:**

- **AI-state awareness beyond binary running/stopped**: agent-deck distinguishes "thinking", "waiting for input", "stalled", "completed". Bigend and Coldwine need this same nuance in dispatch state display.
- **Session forking with context inheritance**: clone an active session and its full conversation history into a new session. For Coldwine, this maps to forking a dispatch at a given phase checkpoint.
- **MCP socket pooling** (85-90% memory reduction): shares MCP process instances across sessions via Unix sockets, with auto-reconnect on crash. Relevant if Autarch apps ever need persistent connections to the Intercore MCP server.
- **Global search across conversations**: fuzzy-search all session histories. For Pollard, cross-run search is a core feature.
- **Organized groups**: sessions organized into named groups. For Bigend, runs organized by project or team.

**Maps to:** Bigend (AI-state nuance, groups), Coldwine (dispatch fork, state transitions), Pollard (cross-run search)

---

### 5. ccswarm — Multi-Agent Orchestration with TUI

**Repo:** https://github.com/nwiizo/ccswarm
**Stars:** 108
**Language:** Rust
**What it does:** Multi-agent orchestration system using Claude Code with git worktree isolation. Features a ProactiveMaster orchestrator using a type-state pattern, channel-based zero-shared-state coordination, and a dedicated `tui/` module.

**Architectural pattern:** Leader-Worker-Verifier model. A `ProactiveMaster` dispatches work via typed channels. Workers run in isolated git worktrees. A verification agent runs 6-check workflow after completion. TUI is a real-time monitor showing all agent states.

**Key patterns for Autarch:**

- **Type-state pattern for orchestration**: the ProactiveMaster is typed to its current phase, preventing invalid state transitions at compile time. For Coldwine's task orchestration, use Go generics/interface types to encode phase constraints.
- **Channel-based zero-shared-state**: no mutexes on the critical path. All coordination via typed message channels. Maps directly to Bubble Tea's `tea.Msg` passing — avoid shared state in Autarch models.
- **Verification agent as a first-class entity**: a dedicated "verifier" checks outputs before marking phase complete. Maps to Gurgeh's confidence scoring step — a verification pass that scores PRD completeness.
- **93% token reduction via session-persistent MessageBus**: instead of new LLM calls per task, maintain a persistent session that accumulates context. For Coldwine, suggest using a single long-running `ic` dispatch rather than spawning new ones per phase.
- **DynamicSpawner for workload balancing**: spawns new agents when queue depth exceeds threshold, retires idle agents. For Bigend, show queue depth and spawn recommendations.
- **TUI `tui/` module as standalone component**: ccswarm's TUI is a separate sub-crate that can be composed independently. For Autarch, each app (`bigend/`, `gurgeh/`, etc.) should be a standalone binary with shared components in `internal/`.

**Maps to:** Coldwine (type-state, channel design), Gurgeh (verification pass for confidence), Bigend (queue depth display)

---

### 6. k9s — Kubernetes CLI in Style

**Repo:** https://github.com/derailed/k9s
**Stars:** ~30,000+
**Language:** Go (custom TUI, not Bubble Tea)
**What it does:** Terminal UI for Kubernetes cluster management. Real-time watch on cluster state, resource list panels, command-driven navigation (`:pod`, `:deploy`), plugin system, XRay view, Popeye audit.

**Architectural pattern:** Command-driven resource navigation. k9s invented the "colon-command" navigation paradigm for TUIs — you switch between resource types by typing their name. The UI is stateless relative to the resource; the cluster is the state authority (analogous to Autarch's `ic` CLI as state authority).

**Key patterns for Autarch:**

- **Colon-command navigation**: press `:`, type resource name, enter. For Bigend, `:run <id>`, `:project <name>`, `:phase <num>` to navigate directly to any Intercore entity.
- **Header region + main display separation**: top strip shows cluster info + keybinding hints; main area shows selected resource. Bigend should follow this: top strip shows summary stats (active runs, alerts), main area shows selected run detail.
- **`/` search mode**: filter the current list in-place without changing view. For all Autarch apps, `/` should filter the visible list.
- **XRay mode**: shows resource relationships as a tree. For Bigend, a tree view of run → phases → dispatches → events.
- **Plugin system via YAML**: extend k9s with custom commands per resource type. For Autarch, a config file that maps Intercore run types to custom Bigend panel layouts.
- **Single resource displayed at a time**: k9s doesn't try to show everything simultaneously. Each Autarch app has one primary view; alt-views are accessed via keybindings.
- **Watch-and-update loop**: k9s continuously polls Kubernetes. Autarch continuously polls `ic run status` and `ic events` — same model.

**Maps to:** All Autarch apps (navigation paradigm, `/` search), Bigend (XRay tree view, header/main layout)

---

### 7. lazydocker / lazygit — Lazy* TUI Pattern

**Repos:** https://github.com/jesseduffield/lazydocker, https://github.com/jesseduffield/lazygit
**Stars:** 40,000+ combined
**Language:** Go (gocui)
**What they do:** Terminal UIs for Docker and Git management. Panels for different entity types; keyboard navigation within and between panels; context-sensitive keybindings.

**Architectural pattern:** Multi-panel layout with a `GuiRepoState` per active context. lazygit's key insight is that each panel has its own state machine, and the active panel "owns" the keyboard. Switching panels is explicit (tab/arrow navigation). Context system ensures that keybindings only fire in the appropriate panel.

**Key patterns for Autarch:**

- **Context-sensitive keybindings**: `e` in the files panel edits the file; `e` in the commits panel edits the commit message. For Autarch, the same key does different things in different panels — only valid actions are enabled in each context.
- **Multi-panel synchronized state**: selecting a branch in lazygit's branches panel automatically filters the commits panel. For Bigend, selecting a run in the run list automatically updates the dispatch list and event stream.
- **GuiRepoState per worktree**: lazygit preserves UI state independently for each open repo. For Bigend, preserve scroll position and selected dispatch separately for each run.
- **Custom commands via config**: lazygit users define their own keybindings in `config.yml`. For Autarch, expose custom keybinding hooks for user-defined `ic` CLI commands.
- **Dual-pane diff viewer**: inline before/after diff rendering. For Bigend/Coldwine, show `ic dispatch diff` output in a diff panel next to the event stream.

**Maps to:** Bigend (multi-panel sync, per-run state), Coldwine (diff panel), all apps (context keybindings)

---

### 8. sampler — YAML-Configured Terminal Dashboard

**Repo:** https://github.com/sqshq/sampler
**Stars:** ~12,000
**Language:** Go
**What it does:** Configurable terminal dashboard for shell command visualization and alerting. Define panels in YAML, each panel runs a shell command at a configured rate, output visualized as charts/sparklines/gauges/text.

**Architectural pattern:** Pull-based polling dashboard. Each component has an independent refresh rate. Components are positioned in a grid layout defined by YAML. No hardcoded panel types — the type determines how output is rendered.

**Key patterns for Autarch:**

- **Independent refresh rates per component**: some Bigend panels update every 2 seconds (event count), others every 30 seconds (git status). sampler's per-component `rate` is the right model.
- **Grid layout from config**: sampler positions components via a percentage-based grid in YAML. For Bigend, a config-driven panel layout rather than hardcoded positions allows user customization.
- **Trigger/alerting system**: sampler fires alerts when conditions are met. For Bigend, trigger visual alert (and optionally sound) when a run enters "needs_input" or "error" state.
- **Shell command as the data source**: sampler's entire data model is "run this shell command, use its output". For Autarch, `ic` CLI is the equivalent shell command — the same composable pull pattern.
- **PTY mode for interactive commands**: sampler supports PTY for commands that require a real terminal. For Coldwine, use PTY to stream interactive `ic events` output.
- **Multi-step init**: sampler supports sequential init commands before sampling begins. For Autarch startup: `ic db open → ic project list → ic run list`, each blocking the next.

**Maps to:** Bigend (grid layout, independent refresh rates, alerting), Coldwine (PTY streaming)

---

### 9. OpenCode — Rich Go TUI for AI Coding

**Repo:** https://github.com/opencode-ai/opencode
**Stars:** Active
**Language:** Go (Bubble Tea initially; migrated to TypeScript/OpenTUI)
**What it does:** Terminal-based AI coding assistant with rich TUI: chat view, LSP integration, session storage (SQLite), 75+ LLM providers, `/compact` and `/init` built-in commands.

**Architectural pattern:** Root `appModel` struct as the central Bubble Tea orchestrator. Uses boolean flags on the model to control which dialogs are open (blocking keyboard input when dialogs active). Event cascading with command batching for efficiency.

**Key patterns for Autarch:**

- **Dialog blocking pattern**: when a dialog is open, all keyboard messages are intercepted before reaching underlying components. For Gurgeh's PRD wizard, use this pattern — the wizard form captures all input while active.
- **Event cascading with command batching**: `tea.Batch(cmd1, cmd2, cmd3)` to fire multiple async operations from one Update call. For Coldwine, batch the initial state load: fetch run status + fetch recent events + fetch active dispatches simultaneously.
- **Context-sensitive completion triggers**: `/` for commands, `@` for files, `!` for bash. For Bigend, `@` to mention a run ID, `/` for navigation commands.
- **`/compact` session command**: summarize and create new session to manage context growth. For Pollard, a `/compact` equivalent that summarizes accumulated research findings.
- **Subscription system via goroutines**: `setupSubscriptions()` creates one goroutine per event type, forwards them as `tea.Msg` to the TUI. For Autarch, create subscription goroutines for `ic run status`, `ic events`, and `ic dispatch list` with appropriate polling rates.
- **SQLite for session persistence**: OpenCode stores full session history. For Autarch, Intercore's SQLite DB is the equivalent — no separate persistence layer needed.

**Maps to:** Gurgeh (dialog blocking, form wizard), Coldwine (command batching, subscription goroutines), Pollard (/compact pattern)

---

### 10. wtfutil — Personal Information Dashboard

**Repo:** https://github.com/wtfutil/wtf
**Stars:** ~15,000
**Language:** Go (tcell + tview)
**What it does:** Personal terminal dashboard with 50+ configurable modules (GitHub PRs, OpsGenie, Jira, Slack, New Relic, etc.). Modules are YAML-configured widgets arranged in a grid. Each module polls its data source independently.

**Architectural pattern:** Module = data source + renderer. Each module implements `Refresh()` (poll data) and `Render()` (draw to its panel). The framework calls `Refresh()` on each module's configured interval. Modules are fully independent — no inter-module communication.

**Key patterns for Autarch:**

- **Module-as-widget pattern**: each Autarch panel is a self-contained module with its own refresh schedule and rendering logic. Bigend's run-list widget, phase-progress widget, and event-tail widget are independent modules.
- **YAML-driven layout**: modules specify their grid position (`top`, `left`, `height`, `width`) in percentage terms. For Autarch, a `.autarch.yaml` config file that positions widgets on the dashboard.
- **50+ integration modules as a catalog**: wtfutil shows what developer information is worth surfacing on a dashboard. The Intercore equivalents: active runs, phase progress, dispatch status, event rate, error count, last commit.
- **Focus cycling**: tab/shift-tab moves focus between modules; the focused module receives keyboard shortcuts. For Bigend, tab cycles focus between the run list, phase strip, and event viewport.
- **Widget border + title**: each module gets a labeled border showing its data source. For Autarch, labeled borders on each panel showing the `ic` command driving it (e.g., `[ic run list]`).

**Maps to:** Bigend (module-as-widget, YAML layout, focus cycling), all apps (widget border conventions)

---

## Cross-Cutting Patterns Summary

### Navigation Paradigms (choose one per app)

| Pattern | Best For | Reference |
|---------|----------|-----------|
| List + detail (two-pane) | Bigend, Coldwine | claude-squad, lazydocker |
| Command palette | Gurgeh (wizard mode) | NTM, OpenCode |
| Colon-command navigation | Bigend (power user mode) | k9s |
| Tab-per-entity | Bigend (run tabs) | schmux |

### Data Fetching Patterns

| Pattern | Use Case | Reference |
|---------|----------|-----------|
| Bootstrap + incremental stream | Event viewports (Coldwine) | schmux, OpenCode |
| Per-component independent polling | Dashboard panels (Bigend) | sampler, wtfutil |
| Subscription goroutine → tea.Msg | Any real-time data | OpenCode, ccswarm |
| Buffered channel + non-blocking send | Producer/consumer decoupling | schmux |

### Status Display Conventions

| Element | Convention | Reference |
|---------|------------|-----------|
| Agent state | Emoji + text badge (not just color) | schmux, NTM |
| Relative timestamps | "2m ago", "1h ago" | schmux, agent-deck |
| Activity indicators | Spinner for active, checkmark for done | claude-squad, OpenCode |
| Confidence | Percentage + tier label (High/Medium/Low) | PM Toolkit AI, Seekrates |
| Agent color coding | Consistent per-agent-type color | NTM |

### PRD / Confidence Scoring (Gurgeh)

No open-source TUI-native PRD generator with confidence scoring exists. This is a genuine gap. The closest inspiration comes from:

- **PM Toolkit AI prompt framework**: explicit three-tier confidence system (High >80%, Medium 50-80%, Low <50%) with `[ASSUMPTION]`, `[ESTIMATE]`, `[UNCERTAIN]` inline markers.
- **Seekrates AI**: queries multiple LLMs simultaneously, computes consensus percentage as confidence score, flags dissenting views.
- **ccswarm verification agent**: six-check workflow before marking completion — adapt as PRD completeness checklist.
- **NudgeNik JSON schema** from schmux: `{state, confidence, evidence[], summary}` — exact schema for Gurgeh's per-section scoring output.

**Gurgeh design recommendation:** Wizard-style (NTM palette UX) with three phases: (1) structured input form (charmbracelet/huh), (2) multi-pass LLM generation with per-section confidence scoring using NudgeNik-style JSON, (3) review view with confidence badges and `[ASSUMPTION]` highlighting.

### Research Intelligence (Pollard)

The multi-domain hunter pattern is underexplored in open-source TUI tooling. Closest analogues:

- **Consensus.app architecture**: search-before-synthesis, Consensus Meter (agreement percentage), filter by study type and quality. For Pollard, filter research by domain (code analysis, web search, paper review) with a synthesis meter.
- **Elicit**: systematic review with structured data extraction across N sources. For Pollard, structured extraction from N concurrent `ic dispatch` research agents.
- **ccswarm Leader-Worker-Verifier**: Pollard = leader dispatches domain hunters (workers), aggregates results, verifier checks coverage gaps.
- **Seekrates multi-model consensus**: aggregate findings from multiple agents, compute consensus percentage, surface dissenting evidence.

**Pollard design recommendation:** Three-column layout — left: domain hunter status (running/done/stalled per domain), center: live synthesis as findings arrive, right: source citations with confidence indicators. Inspired by schmux workspace-as-tabs + NudgeNik classification.

---

## What Does Not Exist Yet (Autarch's Genuine Novelty)

After surveying the entire landscape, these features have no prior open-source art in the TUI space:

1. **IC-kernel-native TUI**: all existing tools wrap tmux or shell commands; none surface a structured agent orchestration kernel (like Intercore) with typed phases, dispatches, and gate events.
2. **PRD confidence scoring TUI**: Gurgeh's per-section confidence scoring with `[ASSUMPTION]` markers, rendered in a terminal wizard, is novel.
3. **Multi-domain research synthesis TUI**: Pollard's parallel domain hunters with live synthesis aggregation has no TUI equivalent.
4. **Phase gate visualization**: Bigend's phase progress strip (with gate pass/fail colors) is unique — k9s shows resource status but not phase progression with typed gates.
5. **Cross-run run search**: agent-deck has per-session search; Bigend would add cross-project, cross-run, cross-phase search via the Intercore DB.

---

## Recommended Go Libraries (Confirmed by Research)

| Library | Use | Used By |
|---------|-----|---------|
| `github.com/charmbracelet/bubbletea` | Core framework | claude-squad, agent-deck, NTM |
| `github.com/charmbracelet/lipgloss` | Styling, colors, borders | NTM, OpenCode, hatchet |
| `github.com/charmbracelet/bubbles` | List, viewport, spinner, textinput | all Bubble Tea apps |
| `github.com/charmbracelet/huh` | Form wizard (Gurgeh) | schmux, hatchet |
| `github.com/charmbracelet/harmonica` | Spring animations (optional) | Bubble Tea ecosystem |
| `github.com/creack/pty` | PTY streaming (Coldwine) | schmux |
| `github.com/fsnotify/fsnotify` | File signal watching | schmux |

---

## Architecture Decision: Bubble Tea Confirmed

The Bubble Tea + Lip Gloss + huh stack is validated by:
- **claude-squad** (6k stars): two-pane agent list in pure Bubble Tea
- **agent-deck** (933 stars): AI-aware session manager in Go + Bubble Tea
- **NTM** (149 stars): animated gradients, command palette, full agent coordination
- **Hatchet blog post**: "Building a TUI is Easy Now" — praise for the Charm ecosystem as equivalent to React + Tailwind for terminals
- **OpenCode**: rich TUI built with Bubble Tea before migrating to TypeScript for different reasons (not Bubble Tea limitations)

The Elm Architecture model (Init/Update/View) + tea.Cmd for async ops + tea.Msg for events is the correct mental model for all four Autarch apps.

---

## Sources

- https://github.com/sergeknystautas/schmux
- https://github.com/smtg-ai/claude-squad
- https://github.com/Dicklesworthstone/ntm
- https://github.com/asheshgoplani/agent-deck
- https://github.com/nwiizo/ccswarm
- https://github.com/derailed/k9s
- https://github.com/jesseduffield/lazydocker
- https://github.com/jesseduffield/lazygit
- https://github.com/sqshq/sampler
- https://github.com/wtfutil/wtf
- https://github.com/opencode-ai/opencode
- https://github.com/charmbracelet/bubbletea
- https://deepwiki.com/opencode-ai/opencode/4-terminal-ui-system
- https://hatchet.run/blog/tuis-are-easy-now
- https://www.warp.dev/oz
- https://pmtoolkit.ai/prompts/prd-writing
- https://consensus.app/
- https://elicit.com/
- https://seekrates-ai.com/
- https://github.com/openai/codex/issues/12047
