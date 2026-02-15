# Clavain Hook and Command Patterns - Analysis for Interspect Phase 1

**Date**: 2026-02-15  
**Purpose**: Understand Clavain's hook and command infrastructure for implementing Interspect Phase 1 (event logging)  
**Scope**: Medium thoroughness - hooks, commands, SQLite usage, plugin structure, .clavain/ directory

---

## 1. Hook Patterns

### 1.1 Hook Input Protocol

**All hooks receive JSON on stdin** (NOT environment variables). Critical pattern from `session-start.sh`:

```bash
# Read hook input from stdin (must happen before anything else consumes it)
HOOK_INPUT=$(cat)
```

This is THE blocking requirement - hooks must `cat` stdin immediately before any other commands consume it.

**Standard fields available:**
- `.session_id` - stable session identifier
- `.transcript_path` - path to conversation transcript
- `.stop_hook_active` - boolean, true if Stop hook is running
- `.tool_input.file_path` - for Read/Write hooks (not relevant for Interspect Phase 1)

### 1.2 Hook Output Protocol - additionalContext

Hooks emit JSON to stdout. Two main patterns:

**Pattern 1: SessionStart - additionalContext injection**
```bash
cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "Context string with \\n literals..."
  }
}
EOF
```

The `additionalContext` field gets injected into Claude's prompt. Note the escaped newlines (`\\n`) - these are literal strings, NOT bash newlines.

**Pattern 2: Stop hooks - block decision**
```bash
jq -n --arg reason "$REASON" '{"decision":"block","reason":$reason}'
```

The `reason` field becomes a prompt that Claude evaluates. If Claude decides to act on it, the stop is blocked.

### 1.3 Sentinel Protocol (Critical for Stop Hooks)

Stop hooks use TWO sentinel files to prevent cascades:

**Shared sentinel** (prevents hook cascade):
```bash
STOP_SENTINEL="/tmp/clavain-stop-${SESSION_ID}"
if [[ -f "$STOP_SENTINEL" ]]; then exit 0; fi
touch "$STOP_SENTINEL"  # Write BEFORE any slow operations
```

**Per-hook throttle** (prevents same hook from firing repeatedly):
```bash
THROTTLE_SENTINEL="/tmp/clavain-compound-last-${SESSION_ID}"
if [[ -f "$THROTTLE_SENTINEL" ]]; then
    # Check mtime, exit if < 300s old
fi
touch "$THROTTLE_SENTINEL"  # After decision to fire
```

**Cleanup pattern** (all Stop hooks do this):
```bash
find /tmp -maxdepth 1 \( -name 'clavain-stop-*' -o -name 'clavain-compound-last-*' \) -mmin +60 -delete 2>/dev/null || true
```

### 1.4 Session Persistence - CLAUDE_ENV_FILE

From `session-start.sh`:
```bash
if [[ -n "${CLAUDE_ENV_FILE:-}" ]]; then
    _session_id=$(echo "$HOOK_INPUT" | jq -r '.session_id // empty')
    echo "export CLAUDE_SESSION_ID=${_session_id}" >> "$CLAUDE_ENV_FILE"
fi
```

This is how hooks persist values across Bash tool calls within a session. `CLAUDE_SESSION_ID` is NOT a built-in - it's written by SessionStart hook via this mechanism.

### 1.5 JSON Escaping

Hooks use `escape_for_json()` from `lib.sh` for embedding markdown/text into JSON:

```bash
escape_for_json() {
    local s="$1"
    s="${s//\\/\\\\}"       # Backslash
    s="${s//\"/\\\"}"       # Quote
    s="${s//$'\n'/\\n}"     # Newline to \n
    s="${s//$'\r'/\\r}"     # etc.
    # ... handles control chars with printf -v
    printf '%s' "$s"
}
```

This is essential for `additionalContext` strings that contain markdown with special characters.

---

## 2. Command Patterns

### 2.1 Structure: YAML Frontmatter + Markdown

All commands follow this pattern:

```markdown
---
name: galiana
description: Discipline analytics — view KPIs, report defects, or reset cache
argument-hint: "[optional subcommand]"
---

# Command Documentation

<subcommand> #$ARGUMENTS </subcommand>

Route by subcommand:
1. No args: ...
2. `report-defect <id>`: ...
```

**Key elements:**
- YAML frontmatter with `name`, `description`, `argument-hint`
- `<subcommand>` tag captures `$ARGUMENTS` from user invocation
- Routing logic based on argument parsing
- Bash code blocks show implementation

### 2.2 Argument Routing Examples

**Simple routing** (`sprint-status.md`):
```bash
source "${CLAUDE_PLUGIN_ROOT}/hooks/sprint-scan.sh" && sprint_full_scan
```
No args needed, just sources library and calls function.

**Subcommand routing** (`galiana.md`):
```
1. No args: invoke Skill("galiana")
2. report-defect <bead-id>: collect metadata, call galiana_log_defect
3. experiment [flags]: run Python script with flags
4. reset: rm cache file
```

**Auto-detection routing** (`resolve.md`):
Priority waterfall - check for PR number, todo files, code TODOs in order. Detects source type automatically.

### 2.3 Library Sourcing Pattern

Commands that need shared functions use this pattern:

```bash
GALIANA_LIB=$(find ~/.claude/plugins/cache -path '*/clavain/*/galiana/lib-galiana.sh' 2>/dev/null | head -1)
[[ -z "$GALIANA_LIB" ]] && GALIANA_LIB=$(find ~/projects -path '*/hub/clavain/galiana/lib-galiana.sh' 2>/dev/null | head -1)
if [[ -z "$GALIANA_LIB" ]]; then
  echo "Error: Could not locate galiana/lib-galiana.sh" >&2
  exit 1
fi
source "$GALIANA_LIB"
```

Searches plugin cache first, then dev repo as fallback.

---

## 3. Existing SQLite Usage

**No SQLite in Clavain itself.** Searched entire codebase for `sqlite3` patterns - only found:
- Test fixtures in `galiana/evals/golden/` (synthetic Python code for testing)
- Research docs mentioning SQLite in other contexts

**Key finding:** Clavain uses **JSONL for all telemetry and state**, not SQLite.

### 3.1 JSONL Telemetry Pattern (Galiana)

From `galiana/lib-galiana.sh`:

```bash
galiana_log_signals() {
    local telemetry_file="${HOME}/.clavain/telemetry.jsonl"
    mkdir -p "$(dirname "$telemetry_file")" 2>/dev/null || return 0
    jq -n -c \
        --arg event "signal_persist" \
        --arg session_id "$session_id" \
        --arg signals "$signals" \
        --argjson weight "$weight" \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{event: $event, session_id: $session_id, signals: $signals, weight: $weight, timestamp: $ts}' \
        >> "$telemetry_file" 2>/dev/null || true
}
```

**Key patterns:**
- **Path**: `~/.clavain/telemetry.jsonl` (user home, not project dir)
- **Atomicity**: jq generates one JSON line, appended with `>>`
- **Fail-safe**: `|| return 0` or `|| true` - never blocks workflow
- **mkdir guard**: creates parent dir before write
- **Timestamp format**: ISO 8601 UTC

**Event types logged:**
- `signal_persist` - when auto-compound detects problem-solving signals
- `workflow_start` - when a workflow begins (bead, command, project)
- `workflow_end` - when workflow completes (includes duration)
- `defect_report` - when a defect is manually logged via `/galiana report-defect`

### 3.2 Why JSONL Over SQLite

Analysis of the codebase suggests JSONL was chosen because:
1. **No dependencies** - jq is ubiquitous, no sqlite3 binary needed
2. **Append-only** - no locking/concurrency issues with multiple sessions
3. **Grep-friendly** - can use `jq 'select(.event=="X")' file.jsonl` for queries
4. **Human-readable** - can inspect with `tail` or `less`
5. **Fail-safe** - partial writes just create incomplete lines, easily filtered

---

## 4. Plugin Structure (.claude-plugin/plugin.json)

From `clavain/.claude-plugin/plugin.json`:

```json
{
  "name": "clavain",
  "version": "0.6.17",
  "description": "...",
  "mcpServers": {
    "context7": {
      "type": "http",
      "url": "https://mcp.context7.com/mcp"
    }
  }
}
```

**Hooks are registered implicitly** - Claude Code scans `hooks/*.sh` automatically.

**MCP servers** can be declared in `mcpServers` field. This makes them available to all sessions when the plugin is loaded.

**No explicit hook registration** - the presence of `hooks/session-start.sh`, `hooks/auto-compound.sh`, etc. is sufficient. Claude Code discovers them by convention.

---

## 5. The .clavain/ Directory Pattern

### 5.1 Current Structure

From the codebase exploration:

```
.clavain/
  scratch/           # Session-scoped ephemeral state
    handoff.md       # Written by session-handoff hook, read by next SessionStart
    inflight-agents.json  # Written by Stop hooks, consumed by SessionStart
```

**Key characteristics:**
- Created on-demand by hooks (no `/clavain:init` command found for creating it)
- `scratch/` is for **session handoff state** - transient files that coordinate across sessions
- `.gitignore` should contain `.clavain/scratch/` (research docs note this was a past bug)

### 5.2 Usage Patterns

**Write pattern** (from `session-handoff.sh`):
```bash
HANDOFF_PATH="HANDOFF.md"  # Default: project root
if [[ -d ".clavain" ]]; then
    mkdir -p ".clavain/scratch" 2>/dev/null || true
    HANDOFF_PATH=".clavain/scratch/handoff.md"
fi
```

**Read pattern** (from `session-start.sh`):
```bash
handoff_context=""
if [[ -f ".clavain/scratch/handoff.md" ]]; then
    handoff_content=$(head -40 ".clavain/scratch/handoff.md" 2>/dev/null) || handoff_content=""
    if [[ -n "$handoff_content" ]]; then
        handoff_context="\\n\\n**Previous session context:**\\n$(escape_for_json "$handoff_content")"
    fi
fi
```

**Consumption** (from `session-start.sh`):
```bash
# Consume manifest
rm -f ".clavain/scratch/inflight-agents.json" 2>/dev/null || true
```

Files in `scratch/` are **consumed on read** - deleted after SessionStart hook reads them.

### 5.3 Expected Pattern for Interspect

Based on established patterns, Interspect should use:

**For SQLite database:**
- `.clavain/interspect.db` (project-scoped state, persistent)
- NOT in `scratch/` (scratch is for session handoff only)

**For per-project config:**
- `.clavain/interspect-config.json` (if needed for project-specific settings)

**Precedent:** The `~/.clavain/telemetry.jsonl` pattern suggests Galiana stores **user-global** state in home dir, not project dir. Interspect's event log is **project-scoped**, so `.clavain/interspect.db` is the right location.

---

## 6. Companion Plugin Discovery

From `hooks/lib.sh`:

```bash
_discover_interflux_plugin() {
    if [[ -n "${INTERFLUX_ROOT:-}" ]]; then
        echo "$INTERFLUX_ROOT"
        return 0
    fi
    local f
    f=$(find "${HOME}/.claude/plugins/cache" -maxdepth 5 \
        -path '*/interflux/*/.claude-plugin/plugin.json' 2>/dev/null | sort -V | tail -1)
    if [[ -n "$f" ]]; then
        echo "$(dirname "$(dirname "$f")")"
        return 0
    fi
    echo ""
}
```

**Pattern:** Check env var override first, then search plugin cache for a marker file, strip path to get plugin root.

**For Interspect integration:** Clavain could use `_discover_interspect_plugin()` to check if Interspect is installed, and conditionally enable logging in hooks if it's present.

---

## 7. Hook Execution Flow (SessionStart Example)

1. **Read stdin immediately**: `HOOK_INPUT=$(cat)`
2. **Persist session state**: Write to `CLAUDE_ENV_FILE` if available
3. **Clean up old plugin versions** (symlink old dirs to current)
4. **Load skill content**: Read `skills/using-clavain/SKILL.md` for injection
5. **Detect companions**: Check for beads, oracle, interflux, etc.
6. **Build context strings**: Companions, conventions, setup hints, warnings
7. **Run scanners**: Sprint status, work discovery (lightweight, <1s)
8. **Check session handoff**: Read `.clavain/scratch/handoff.md` if present
9. **Detect in-flight agents**: Check manifest + filesystem scan
10. **Emit JSON output**: `hookSpecificOutput.additionalContext` with all context
11. **Exit 0**: Always succeed (fail-open pattern)

**Critical timing:** Slow operations (curl to Intermute, discovery scans) come AFTER fast guards (session ID persistence). Fast context is always available even if slow parts fail.

---

## 8. Key Learnings for Interspect Phase 1

### 8.1 What to Adopt

1. **JSONL over SQLite** for initial implementation
   - Append-only, no locking issues
   - jq-based queries work fine for Phase 1 volume
   - Can migrate to SQLite in Phase 2 if query performance matters

2. **Fail-safe patterns** everywhere
   - `mkdir -p ... || return 0` before writes
   - `2>/dev/null || true` on all queries
   - Never block hook execution on logging failure

3. **Sentinels for Stop hooks**
   - Write shared sentinel BEFORE any slow work
   - Use per-hook throttle for repeated firing prevention
   - Clean up stale sentinels in /tmp

4. **JSON stdin protocol**
   - `cat` stdin immediately, before any other commands
   - Use `jq -r '.field // fallback'` for safe extraction

5. **Location conventions**
   - User-global state: `~/.clavain/telemetry.jsonl`
   - Project state: `.clavain/interspect.jsonl` (or `.db`)
   - Session handoff: `.clavain/scratch/`

### 8.2 What NOT to Do

1. **Don't use env vars for hook input** - they're not set. Use stdin JSON.

2. **Don't create subdirs without guards** - `mkdir -p ... || true` is required, permissions can fail.

3. **Don't use `$$` as session ID** - it's subprocess PID, changes every hook invocation. Use `.session_id` from stdin.

4. **Don't read files without existence checks** - use `if [[ -f file ]]` or `head file 2>/dev/null || fallback`.

5. **Don't use `head -N` on files >10KB without byte limit** - add `| head -c 4096` to prevent context bloat.

### 8.3 Testing Strategy (From Clavain Patterns)

From `tests/shell/` structure:
- Use `bats` for shell tests
- Mock `$HOME`, `$CLAUDE_ENV_FILE` via exports
- Test hooks with synthetic JSON stdin via `bash -c "echo '$JSON' | hooks/script.sh"`
- Assert JSON output structure with `jq` validation

---

## 9. Implementation Checklist for Interspect Phase 1

Based on Clavain patterns:

- [ ] Create `hooks/interspect-log.sh` (ReadStart hook? or just SessionStart?)
- [ ] Source `interspect/lib-logging.sh` for event append function
- [ ] Use stdin JSON protocol: `HOOK_INPUT=$(cat)`, parse with jq
- [ ] Append events to `.clavain/interspect.jsonl` (fail-safe, no blocking)
- [ ] Use ISO 8601 timestamps: `date -u +%Y-%m-%dT%H:%M:%SZ`
- [ ] mkdir guard: `mkdir -p .clavain 2>/dev/null || return 0`
- [ ] Extract relevant fields: `.session_id`, `.tool_input.file_path` for Read/Write
- [ ] NO output to stdout (logging hook should be silent, not inject context)
- [ ] Exit 0 always (fail-open)

**Alternative:** Implement as a **companion plugin** (separate repo like interflux) rather than a Clavain submodule. This keeps Clavain dependency-free and lets users opt-in to Interspect.

---

## 10. Open Questions

1. **Should Interspect be a Clavain submodule or separate plugin?**
   - Separate plugin = cleaner separation, opt-in by users
   - Submodule = tighter integration, Clavain can surface events in commands
   
2. **Which hooks should log events?**
   - SessionStart? (log session begin)
   - ReadStart/ReadEnd? (log file access)
   - Stop? (log session end)
   - Or just Read/Write hooks with `interspect_log_file_access()`?

3. **Event schema - what fields?**
   - Minimal: `{event, session_id, timestamp, file_path}`
   - Extended: `{event, session_id, timestamp, file_path, operation, tool_name, line_range, project_path}`

4. **Storage location final decision:**
   - `.clavain/interspect.jsonl` (project-scoped, gitignored)
   - `~/.clavain/interspect/${project_hash}.jsonl` (user-global, per-project files)
   - Hybrid: project file for current session, rollup to user-global on SessionStop?

---

## Appendix: File Paths Reference

**Hooks:**
- `hooks/lib.sh` - shared utilities (discovery, escaping, inflight detection)
- `hooks/session-start.sh` - SessionStart hook, additionalContext injection
- `hooks/auto-compound.sh` - Stop hook, signal detection + block decision
- `hooks/session-handoff.sh` - Stop hook, detects incomplete work
- `hooks/sprint-scan.sh` - scanner library (sourced by hooks + commands)
- `hooks/lib-signals.sh` - signal detection for auto-compound

**Commands:**
- `commands/galiana.md` - telemetry analytics command
- `commands/resolve.md` - auto-routing resolver command
- `commands/sprint-status.md` - deep workflow scan command

**Libraries:**
- `galiana/lib-galiana.sh` - telemetry event logging functions

**Plugin:**
- `.claude-plugin/plugin.json` - plugin manifest, MCP server declarations

**Project state:**
- `.clavain/scratch/handoff.md` - session handoff (ephemeral)
- `.clavain/scratch/inflight-agents.json` - agent manifest (ephemeral)
- `~/.clavain/telemetry.jsonl` - user-global telemetry (persistent)

**Expected for Interspect:**
- `.clavain/interspect.jsonl` or `.clavain/interspect.db` - project event log
