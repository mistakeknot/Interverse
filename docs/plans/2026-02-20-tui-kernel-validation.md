# Plan: Validate TUI Components with Kernel Data

**Bead:** iv-knwr

## Goal

Verify that shared TUI components (`ShellLayout`, `ChatPanel`, `Composer`, `CommandPicker`, `AgentSelector`) and status panes (`RunsPane`, `DispatchPane`, `EventsPane`) render correctly when fed realistic kernel data from `ic` CLI. Currently, `pkg/tui/` tests cover behavioral mechanics (focus cycling, key handling, filtering) and `internal/status/` tests cover JSON parsing + cursor logic, but **no tests verify that render output contains expected kernel data strings**.

## Scope

- Add render-with-kernel-data tests to `internal/status/` panes (DispatchPane, EventsPane, RunsPane View output)
- Add integration-style render tests to `pkg/tui/` components fed with realistic data shapes
- Verify edge cases: empty data, nil optional fields, long strings, unknown status values
- **Out of scope:** Interactive TUI testing (tuivision), mocking `ic` CLI calls, modifying component code

## Tasks

### Task 1: DispatchPane render tests (`internal/status/dispatches_test.go`) — NEW FILE

Add tests that call `DispatchPane.View()` with realistic kernel data and verify output contains expected strings.

**Tests to add:**
1. `TestDispatchPaneEmpty` — empty dispatches list → output contains "No dispatches"
2. `TestDispatchPaneRenderWithData` — feed 2 dispatches (one running with name+model, one completed with nil name) → verify output contains: dispatch IDs, display names, status text, model name; completed dispatch falls back to agent_type
3. `TestDispatchPaneRenderLongName` — dispatch with 30-char name → verify `!strings.Contains(view, fullName)` and `strings.Contains(view, fullName[:20])`. Use short IDs (≤8 chars) and models (≤12 chars) in fixtures to avoid secondary truncation.
4. `TestDispatchPaneRenderNilFields` — dispatch with nil StartedAt, CompletedAt, Name, Model, ScopeID → no panic, `strings.Contains(view, "—")` (em dash U+2014, not ASCII hyphen)

**Pattern:** Create `DispatchPane`, call `SetSize(80, 20)`, `SetDispatches(runID, dispatches)`, check `View()` output with `strings.Contains`.

### Task 2: EventsPane render tests (`internal/status/events_test.go`) — NEW FILE

Add tests that call `EventsPane.View()` with realistic kernel event data.

**Tests to add:**
1. `TestEventsPaneEmpty` — empty events → output contains "No events"
2. `TestEventsPaneRenderWithData` — feed 3 events (phase advance, dispatch start, error). **Must call `SetSize(80, 20)`** or maxRows clamps to 1. Verify output contains: event types, state transitions ("brainstorm → strategized"). **Do NOT hardcode formatted timestamps** — `formatEventTime` calls `t.Local()`, so UTC→local conversion is machine-dependent. Check for transition text, not time strings.
3. `TestEventsPaneRenderTruncation` — `SetSize(80, 3)` (header + 2 rows) with 5 events → only last 2 events shown (newest-last tail behavior). Verify events[3] and events[4] type strings present, events[0] type string absent.
4. `TestEventsPaneRenderMalformedTimestamp` — event with non-RFC3339 timestamp → no panic. **Note:** `formatEventTime` truncates to 8 chars for long timestamps. Check `strings.Contains(view, timestamp[:8])`, not the full raw string.

**Pattern:** Same as Task 1 — construct pane, set size, set events, verify `View()` strings.

### Task 3: RunsPane render coverage (`internal/status/runs_test.go`) — EXTEND

The file already has cursor/empty tests but no View() render tests.

**Tests to add:**
1. `TestRunsPaneRenderWithData` — feed 2 runs (one active brainstorm, one completed done) → verify output contains: "RUNS" header, run IDs, goal text, phase names
2. `TestRunsPaneRenderTruncation` — run with 80-char goal string → verify it's truncated in output
3. `TestRunsPaneRenderDiffersWithCursor` — render View() with cursor at 0, then move cursor to 1 and render again. Assert `view1 != view2` (selected row gets `Width()` padding which differs even in no-color mode). Do NOT check for specific cursor symbols — highlight is background-color-only.

### Task 4: StatusSymbol/StatusIndicator coverage for kernel statuses (`pkg/tui/components_test.go`) — NEW FILE

The `components.go` helper functions are used by all status panes but have no tests. Verify they handle all kernel status values.

**Tests to add:**
1. `TestStatusSymbolKernelStatuses` — table-driven: verify each kernel-emitted status ("running", "completed", "active", "failed", "waiting", "idle") returns non-empty string and `!strings.Contains(result, "?")`. **Note:** `StatusSymbol()` returns lipgloss-wrapped output, so use `strings.Contains` not equality.
2. `TestStatusSymbolUnknown` — unknown status → `strings.Contains(result, "?")` is true
3. `TestAgentBadgeKnownTypes` — "claude", "codex", "aider", "cursor" → returns non-empty badge. **Case matters:** `AgentBadge("claude")` renders `"Claude"` (capital C). Use `strings.Contains(badge, "Claude")` not `"claude"`.
4. `TestAgentBadgeFallback` — unknown agent → returns badge with raw agent type string
5. `TestPriorityBadge` — P0-P3 → returns formatted priority string

### Task 5: ChatPanel with kernel-shaped slash commands (`pkg/tui/chatpanel_test.go`) — EXTEND

Verify ChatPanel correctly handles sprint-related slash commands that come from kernel context.

**Tests to add:**
1. `TestChatPanelKernelSlashCommands` — table-driven: "/new", "/help", "/quit extra-arg" → all parsed correctly as SlashCommandMsg with expected command and args. These test `ParseSlashCommand` with realistic inputs. **Do NOT reference SprintCommands() pool** — this tests the parser, not command availability.
2. `TestChatPanelRenderMessages` — add messages with user, agent, system roles using **plain text only** (no Markdown syntax — glamour renders it, making literal `strings.Contains` unreliable). Verify View() contains the plain content text.

### Task 6: CommandPicker with sprint commands (`pkg/tui/command_picker_test.go`) — EXTEND

Verify the pre-built command pools used in kernel context.

**Tests to add:**
1. `TestSprintCommandsPool` — `SprintCommands()` returns non-empty list, all have Command field set
2. `TestCommandPickerFilterSprintCommands` — populate with SprintCommands(), filter "vis" → matches "vision" command (SprintCommands contains vision, problem, acceptance, etc. — NOT "phase")
3. `TestGlobalCommandsPoolNoDuplicates` — `GlobalCommands()` has no duplicate Command strings

## Execution Order

Tasks 1-4 are independent (new files or extending different files) → **execute in parallel**.
Tasks 5-6 extend existing test files → can also run in parallel with 1-4 since they touch different files.

All 6 tasks can run in parallel.

## Verification

```bash
cd /root/projects/Autarch && go test ./pkg/tui/... ./internal/status/... -v -count=1
```

All existing + new tests must pass. No component code should be modified — this is pure test addition.

## Review Findings (flux-drive)

**Reviewed by:** fd-correctness (with live Go probes), fd-quality

All P0/P1 findings have been incorporated into the task descriptions above. Key patterns for implementors:
- Always call `SetSize(80, 20)` before `View()` — default height=0 clamps maxRows to 1
- Use `strings.Contains` for all assertions — lipgloss ANSI wraps but doesn't split literal text
- Use short fixture IDs (≤8 chars), models (≤12 chars) to avoid truncation traps
- `formatEventTime` calls `t.Local()` — never hardcode timezone-dependent time strings
- Em dash `"—"` is Unicode U+2014 (3 bytes), not ASCII hyphen
