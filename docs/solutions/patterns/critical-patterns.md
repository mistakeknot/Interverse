# Critical Patterns — Required Reading

Patterns that must be followed every time. Each was learned from a production failure.

---

## 1. Compiled MCP Servers Need a Launcher Script (ALWAYS REQUIRED)

### ❌ WRONG (Binary missing after `claude plugins install`)
```json
{
  "mcpServers": {
    "myserver": {
      "command": "${CLAUDE_PLUGIN_ROOT}/bin/myserver"
    }
  }
}
```
The binary is gitignored. `git clone` gets an empty `bin/` with `.gitkeep`. MCP fails silently at session start.

### ✅ CORRECT
```json
{
  "mcpServers": {
    "myserver": {
      "command": "${CLAUDE_PLUGIN_ROOT}/bin/launch-mcp.sh"
    }
  }
}
```
With `bin/launch-mcp.sh` (tracked in git):
```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BINARY="${SCRIPT_DIR}/myserver"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

if [[ ! -x "$BINARY" ]]; then
    cd "$PROJECT_ROOT"
    go build -o "$BINARY" ./cmd/myserver/ 2>&1 >&2
fi
exec "$BINARY" "$@"
```

**Why:** Claude Code has no `postInstall` hook (requested in #9394, closed NOT_PLANNED). MCP servers launch *before* SessionStart hooks, so hooks can't fix a missing binary. The launcher self-heals: builds on first run (~15s), instant on subsequent runs.

**Placement/Context:** Any plugin with a compiled MCP server (Go, Rust, C). Track the launcher in git, gitignore the binary.

**Documented in:** `docs/solutions/workflow-issues/auto-build-launcher-go-mcp-plugins-20260215.md`

---

## 2. hooks.json Format: Event-Type Keys, Not Flat Arrays (ALWAYS REQUIRED)

### ❌ WRONG (Hooks silently don't load — no error, no warning)
```json
{
  "hooks": [
    {
      "type": "SessionStart",
      "script": "./hooks/session-start.sh"
    }
  ]
}
```

### ✅ CORRECT
```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/hooks/session-start.sh"
          }
        ]
      }
    ]
  }
}
```

**Why:** Claude Code's hook system expects event types as object keys (`"SessionStart"`, `"PostToolUse"`, etc.), each containing an array of matcher+hooks objects. The flat array format is valid JSON but semantically wrong — hooks are silently ignored with zero feedback.

**Placement/Context:** Every `hooks.json` in every plugin. Reference a known-working plugin (e.g., Clavain) as template. Always use `${CLAUDE_PLUGIN_ROOT}` for paths.

**Documented in:** `docs/solutions/integration-issues/plugin-loading-failures-interverse-20260215.md`

---

## 3. Remove `.orphaned_at` After Plugin Cache Manipulation (ALWAYS CHECK)

### ❌ WRONG (Plugin loads but shows errors, or fails to load entirely)
```
~/.claude/plugins/cache/marketplace/plugin/version/.orphaned_at  ← stale marker
```
Claude Code sees the marker and treats the plugin as pending cleanup.

### ✅ CORRECT
```bash
# After any manual plugin cache update, check for stale markers:
find ~/.claude/plugins/cache -maxdepth 4 -name ".orphaned_at" \
  -not -path "*/temp_git_*" -exec rm -v {} \;
```

**Why:** Claude Code periodically marks cache directories for cleanup when they don't match `installed_plugins.json`. After version updates, manual cache manipulation, or failed `claude plugins update`, stale markers prevent loading.

**Placement/Context:** After any manual plugin cache operation, after version bumps, and as a diagnostic step when plugins show errors at session start.

**Documented in:** `docs/solutions/integration-issues/plugin-loading-failures-interverse-20260215.md`
