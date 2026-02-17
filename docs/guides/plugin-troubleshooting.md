# Plugin Troubleshooting Guide

Consolidated reference for debugging Claude Code plugin failures. Read this before debugging plugin errors, creating hooks, or publishing.

## Diagnostic Checklist

When a plugin shows errors at session start:

1. **Cache directory exists** and matches `installed_plugins.json` path
2. **No `.orphaned_at`** marker in the cache dir root
3. **`plugin.json`** in `.claude-plugin/` — valid JSON? Correct field formats?
4. **For MCP servers**: Is the binary/command present? Can it start? Are dependencies (services, env vars) available?
5. **For hooks**: Is `hooks.json` in the correct format (event-key objects, not flat arrays)?
6. **For skills/agents**: Do referenced files exist in cache? Is frontmatter valid?
7. **Version check**: Does `installed_plugins.json` version match `plugin.json` version match marketplace version?
8. **Hook event names**: Are they in the 14-event allowlist?

## hooks.json Format

**WRONG** (silently ignored — no error, no warning):
```json
{
  "hooks": [
    { "type": "SessionStart", "script": "./hooks/session-start.sh" }
  ]
}
```

**CORRECT** (event types as object keys):
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

Key points:
- Event types are **object keys**, not array element values
- Each event contains an array of matcher+hooks objects
- Use `${CLAUDE_PLUGIN_ROOT}` for portable paths
- `"matcher"` controls when the hook fires (empty string = always)
- Always reference a known-working plugin (e.g., Clavain) as template

## Valid Hook Event Types (14-event allowlist)

`SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PermissionRequest`, `PostToolUse`, `PostToolUseFailure`, `Notification`, `SubagentStart`, `SubagentStop`, `Stop`, `TeammateIdle`, `TaskCompleted`, `PreCompact`, `SessionEnd`

Invalid events (e.g., `"Setup"`) are silently ignored. No error at source, only at plugin load time.

## Compiled MCP Servers Need Launcher Scripts

Go/Rust/C MCP servers compile to binaries that are gitignored. `claude plugins install` only does `git clone`, so the binary is missing. Claude Code has no `postInstall` hook (#9394, closed NOT_PLANNED). MCP servers launch *before* SessionStart hooks, so hooks can't fix it.

**WRONG** (binary missing after install):
```json
{ "command": "${CLAUDE_PLUGIN_ROOT}/bin/myserver" }
```

**CORRECT** (launcher auto-builds on first run):
```json
{ "command": "${CLAUDE_PLUGIN_ROOT}/bin/launch-mcp.sh" }
```

Launcher pattern (`bin/launch-mcp.sh`, tracked in git):
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

## `.orphaned_at` Markers

Claude Code marks cache directories for cleanup when they don't match `installed_plugins.json`. Stale markers prevent plugin loading.

**Diagnosis and fix:**
```bash
# Find stale markers
find ~/.claude/plugins/cache -maxdepth 4 -name ".orphaned_at" \
  -not -path "*/temp_git_*"

# Remove them
find ~/.claude/plugins/cache -maxdepth 4 -name ".orphaned_at" \
  -not -path "*/temp_git_*" -delete

# Also clean up abandoned clone attempts
rm -rf ~/.claude/plugins/cache/temp_git_*
```

## Cache/Manifest Divergence

`claude plugins install` does a shallow `git clone` at the commit matching the marketplace version tag. If the plugin author pushes fixes without bumping the version, the cache becomes permanently stale.

**Three independent failure modes:**

| Mode | Example | Fix |
|------|---------|-----|
| Manifest omission | `plugin.json` missing `skills`/`agents` arrays | Declare all capabilities explicitly |
| Cache staleness | Source fixed but cache has old commit | Delete cache dir, reinstall |
| Invalid hook events | `"Setup"` instead of `"SessionStart"` | Use only the 14 valid events |

**Prevention:**
- Always bump version when fixing any plugin file — same version + different content = permanent divergence
- Declare all capabilities in `plugin.json` — Claude Code validates declared vs described
- Test with fresh clone after hooks/manifest changes

## Plugin Manifest Requirements

- `plugin.json` MUST declare `"hooks": "./hooks/hooks.json"` — convention is `hooks/hooks.json` at plugin root
- Hooks inside `.claude-plugin/` will NOT be discovered
- `"skills": ["./path/to/SKILL.md"]` — undeclared skills are silently ignored
- `"commands"` and `"agents"` arrays must list all files explicitly
- No error or warning when these are wrong — capabilities just silently don't load

## Version Sync (3 locations)

All three must stay in sync:
1. `.claude-plugin/plugin.json` — primary
2. Language manifest (`package.json`, `pyproject.toml`) — npm/pip
3. `infra/marketplace/.claude-plugin/marketplace.json` — catalog

Use `/interpub:release <version>` or `scripts/bump-version.sh <version>` to update atomically.

## Hook API Gotchas

- Hooks receive JSON on stdin (`cat | jq`), NOT environment variables
- Use `.session_id` for stable flag files, `.tool_input.file_path` for Read params
- `$$` is subprocess PID (changes every call), NOT session identity
- `CLAUDE_SESSION_ID` is NOT a built-in env var
- "hook error" UI labels are a known Claude Code bug (#17088) — hooks work fine

## MCP Service Dependencies

MCP servers that depend on external services (e.g., interlock depends on intermute) fail silently if the service isn't running. Document required services and add health checks to plugin SessionStart hooks.

## Detailed Solution Docs

For full incident investigations and root cause analysis:
- `docs/solutions/integration-issues/plugin-loading-failures-interverse-20260215.md`
- `docs/solutions/integration-issues/plugin-validation-errors-cache-manifest-divergence-20260217.md`
- `docs/solutions/workflow-issues/auto-build-launcher-go-mcp-plugins-20260215.md`
- `docs/solutions/patterns/critical-patterns.md`
- `docs/solutions/environment-issues/git-credential-lock-multi-user-20260216.md`
