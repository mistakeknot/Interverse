---
module: interlock
date: 2026-02-15
problem_type: workflow_issue
component: tooling
symptoms:
  - "interlock MCP failed at session start — binary missing from plugin cache"
  - "claude plugins install clones repo but gitignored Go binary is absent"
root_cause: missing_workflow_step
resolution_type: tooling_addition
severity: medium
tags: [go, mcp, plugin, auto-build, launcher, compiled-binary]
---

# Troubleshooting: Compiled MCP Binary Missing After Plugin Install

## Problem
Go-based MCP servers in Claude Code plugins fail on first use because `claude plugins install` only does `git clone` — the compiled binary is gitignored and never built. There's no `postInstall` hook in the plugin spec (requested in #9394, closed NOT_PLANNED).

## Environment
- Module: interlock (Go MCP server wrapping intermute)
- Go Version: 1.23.0
- Affected Component: MCP server launch during plugin loading
- Date: 2026-02-15

## Symptoms
- Plugin shows "MCP failed" in session start banner
- `bin/` directory contains only `.gitkeep`, no compiled binary
- MCP tools from the plugin are unavailable
- `file /path/bin/interlock-mcp` returns "No such file or directory"

## What Didn't Work

**Attempted: SessionStart hook to auto-build**
- **Why it failed:** MCP servers in `plugin.json` are launched *before* SessionStart hooks run. By the time the hook could build the binary, the MCP launch has already failed. Hook ordering is: MCP server start → SessionStart hooks → conversation begins.

**Attempted: postInstall in plugin.json**
- **Why it failed:** The `postInstall` field doesn't exist in the Claude Code plugin spec. Feature request #9394 was closed as NOT_PLANNED by Anthropic.

**Attempted: Check binary into git**
- **Why it failed:** Viable but problematic — Go binaries are ~10MB, platform-specific (linux/amd64 vs darwin/arm64), and inflate repo size. Every rebuild changes the binary hash, creating noisy diffs.

## Solution

Replace the direct binary path in `plugin.json` with a **launcher shell script** that auto-builds if the binary is missing, then `exec`s it.

**New file: `bin/launch-mcp.sh`** (tracked in git):
```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BINARY="${SCRIPT_DIR}/interlock-mcp"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

if [[ ! -x "$BINARY" ]]; then
    if ! command -v go &>/dev/null; then
        echo '{"error":"go not found"}' >&2
        exit 1
    fi
    cd "$PROJECT_ROOT"
    go build -o "$BINARY" ./cmd/interlock-mcp/ 2>&1 >&2
fi

exec "$BINARY" "$@"
```

**Changed: `.claude-plugin/plugin.json`**
```json
// Before:
"command": "${CLAUDE_PLUGIN_ROOT}/bin/interlock-mcp"

// After:
"command": "${CLAUDE_PLUGIN_ROOT}/bin/launch-mcp.sh"
```

**No change needed to `.gitignore`** — `bin/interlock-mcp` stays ignored, `bin/launch-mcp.sh` is tracked.

## Why This Works

1. **MCP command timing**: Claude Code resolves `plugin.json` → launches the MCP command as a subprocess. The command is whatever string is in the `"command"` field — it can be a script, not just a binary.

2. **Lazy build**: The launcher checks `[[ ! -x "$BINARY" ]]` which is instant when the binary exists. On first run after install, it calls `go build` (~15 seconds with dependency download, ~3 seconds cached), writes the binary, then `exec`s it. The `exec` replaces the shell process with the Go binary, so there's no wrapper overhead after build.

3. **Self-healing**: If someone deletes the binary or the Go module updates, the next session auto-rebuilds. No manual intervention needed.

4. **Transparent to Claude Code**: Claude Code doesn't care whether the MCP command is a binary or a script — it just needs a process that speaks JSON-RPC on stdio.

## Prevention

- **For any compiled-language MCP server** (Go, Rust, C): always use a launcher script, never point `plugin.json` directly at the compiled binary
- **Pattern**: `bin/launch-mcp.sh` (tracked) + `bin/<name>` (gitignored)
- **Error handling**: The launcher should emit a clear error to stderr if the build toolchain isn't available, rather than failing silently
- **Redirect build output to stderr**: `go build ... 2>&1 >&2` keeps stdout clean for JSON-RPC

## Related Issues
- See also: [plugin-loading-failures-interverse-20260215.md](../integration-issues/plugin-loading-failures-interverse-20260215.md) — broader plugin debugging session where this pattern was discovered
