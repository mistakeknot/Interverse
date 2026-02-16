---
module: System
date: 2026-02-15
problem_type: integration_issue
component: tooling
symptoms:
  - "interlock MCP failed at session start"
  - "interject Plugin 2 errors at session start"
  - "interflux Plugin 1 error at session start"
  - "beads Plugin failed to load 1 error at session start"
root_cause: incomplete_setup
resolution_type: environment_setup
severity: high
tags: [claude-code, plugin, mcp, hooks, orphaned-at, version-mismatch, binary-missing]
---

# Troubleshooting: Claude Code Plugin Loading Failures (4 Plugins)

## Problem
Four plugins failed to load at Claude Code session start with varying errors: MCP connection failure (interlock), hook errors (interject), orphaned marker (interflux), and version mismatch (beads). Each had a different root cause requiring distinct investigation.

## Environment
- Module: Interverse monorepo (all plugins)
- Claude Code: latest
- Affected Component: Plugin loading system, MCP server initialization, hooks system
- Date: 2026-02-15

## Symptoms
- `interlock MCP` showed as "failed" in session start banner
- `interject Plugin` showed "2 errors" in session start banner
- `interflux Plugin` showed "1 error" in session start banner
- `beads Plugin` showed "failed to load · 1 error" in session start banner
- All four plugins' skills, agents, and MCP tools were unavailable

## What Didn't Work

**Direct solution:** Each of the four failures was diagnosed individually through systematic inspection of the plugin cache directories, plugin.json manifests, and runtime dependencies.

## Solution

### Fix 1: interlock MCP — Missing Binary

The interlock MCP server is a compiled Go binary (`bin/interlock-mcp`). The plugin cache only had a `.gitkeep` placeholder — the binary was never checked into git (it's gitignored) and `claude plugins install` only does `git clone`.

```bash
# The cache had only .gitkeep:
ls bin/
# .gitkeep

# Fix: copy compiled binary from source repo
cp /root/projects/Interverse/plugins/interlock/bin/interlock-mcp \
   ~/.claude/plugins/cache/interagency-marketplace/interlock/0.2.0/bin/interlock-mcp
chmod +x ~/.claude/plugins/cache/interagency-marketplace/interlock/0.2.0/bin/interlock-mcp
```

Additionally, the interlock MCP depends on the **intermute** coordination service running. It wasn't running, so even with the binary present, the MCP would fail to connect.

```bash
# Build and start intermute
cd services/intermute && go build -o /usr/local/bin/intermute ./cmd/intermute/
intermute serve --port 7338 &>/var/log/intermute.log &

# Verify
curl -s http://127.0.0.1:7338/health  # {"status":"ok"}
```

### Fix 2: interject — Wrong hooks.json Format

The `hooks.json` used a flat array with `"type"` field instead of the correct event-key object format.

```json
// Before (WRONG — silently ignored):
{
  "hooks": [
    {
      "type": "SessionStart",
      "script": "./hooks/session-start.sh"
    }
  ]
}

// After (CORRECT — event type as object key):
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

Key differences:
- Hooks nested under event-type keys (`"SessionStart"`, `"PostToolUse"`, etc.)
- Each event contains an array of matcher+hooks objects
- `"command"` field uses `${CLAUDE_PLUGIN_ROOT}` for path resolution
- `"matcher"` field controls when the hook fires (empty string = always)

Fixed in both the source repo AND the plugin cache.

### Fix 3: interflux — `.orphaned_at` Marker File

Claude Code's plugin cache uses `.orphaned_at` files to mark directories for cleanup when they don't match an `installed_plugins.json` entry. The interflux cache dir had a stale `.orphaned_at` marker, causing Claude Code to skip loading it.

```bash
# The file contained an epoch timestamp:
cat .orphaned_at  # 1771209386081

# Fix: simply remove the marker
rm ~/.claude/plugins/cache/interagency-marketplace/interflux/0.2.8/.orphaned_at
```

The interlock cache had the same issue — also removed its `.orphaned_at`.

### Fix 4: beads — Version Mismatch

The installed plugin was at version `0.49.6` but the upstream source had moved to `0.50.3`. The cache directory still pointed to the old version.

```bash
# 1. Upgrade the bd CLI binary
# (Required mv trick because daemon kept binary file busy)
mv /usr/local/bin/bd /usr/local/bin/bd.old
cp /tmp/beads-upgrade/bd /usr/local/bin/bd
chmod +x /usr/local/bin/bd
rm -f /usr/local/bin/bd.old

# 2. Create new plugin cache from source
mkdir -p ~/.claude/plugins/cache/beads-marketplace/beads/0.50.3
cp -r /root/projects/upstreams/beads/claude-plugin/* ~/.claude/plugins/cache/beads-marketplace/beads/0.50.3/
cp -r /root/projects/upstreams/beads/claude-plugin/.claude-plugin ~/.claude/plugins/cache/beads-marketplace/beads/0.50.3/

# 3. Update installed_plugins.json to point to new version
# Changed installPath and version from 0.49.6 to 0.50.3

# 4. Fix ACLs for claude-user access
setfacl -R -m u:claude-user:rwX ~/.claude/plugins/cache/beads-marketplace/beads/0.50.3
setfacl -R -m d:u:claude-user:rwX ~/.claude/plugins/cache/beads-marketplace/beads/0.50.3
```

### Bonus: Cache Cleanup

Removed 25 abandoned `temp_git_*` directories from the plugin cache — failed or abandoned `claude plugins install` attempts that were never cleaned up.

```bash
rm -rf ~/.claude/plugins/cache/temp_git_*
```

## Why This Works

1. **Missing binary**: Go-based MCP servers compile to a single binary. When the binary is gitignored, `git clone` during plugin install only gets the `.gitkeep` placeholder. The binary must either be checked into git, or a post-install build step must be added to the plugin.

2. **hooks.json format**: Claude Code's hook system expects a specific JSON structure where event types are object keys, not array element values. The flat array format is syntactically valid JSON but semantically wrong for Claude Code — and there's **no validation error**, hooks just silently don't load.

3. **`.orphaned_at` markers**: Claude Code periodically scans the plugin cache and marks directories that don't match any `installed_plugins.json` entry. These markers can become stale after version updates where the old cache dir gets marked but the matching installed_plugins entry still points to it (e.g., during a `claude plugins update` that failed partway).

4. **Version mismatch**: The `installed_plugins.json` registry is the authoritative source for which plugin version is loaded. When the upstream marketplace moves to a new version but the local cache and registry aren't updated, the plugin loads from the stale cache — which may have an incompatible structure.

## Prevention

- **Binary-based MCP servers**: Either check the compiled binary into git (not ideal for cross-platform), or add a `postInstall` script that builds from source. Document the build requirement in the plugin README.
- **hooks.json**: Always reference a working plugin's hooks.json (e.g., Clavain's) as a template. The correct format nests hooks under event-type keys. Add hooks.json validation to the plugin-validator agent.
- **`.orphaned_at` markers**: After any `claude plugins update` or manual cache manipulation, check for stale orphaned markers: `find ~/.claude/plugins/cache -maxdepth 4 -name ".orphaned_at" -not -path "*/temp_git_*"`
- **Version sync**: Use `/interpub:release <version>` or `scripts/bump-version.sh` to keep all three version locations in sync (plugin.json, language manifest, marketplace.json). Run `bd doctor` to catch version drift early.
- **MCP service dependencies**: Document which services must be running for MCP servers to connect. Consider adding health checks to plugin SessionStart hooks.
- **Cache cleanup**: Periodically clean up `temp_git_*` dirs from the plugin cache to prevent confusion and disk bloat.

## Diagnostic Checklist for Plugin Failures

When a plugin shows errors at session start:

1. **Check the cache directory exists** and matches `installed_plugins.json` path
2. **Check for `.orphaned_at`** marker in the cache dir root
3. **Check `plugin.json`** in `.claude-plugin/` — valid JSON? correct field formats?
4. **For MCP servers**: Is the binary/command present? Can it start? Are dependencies (services, env vars) available?
5. **For hooks**: Is `hooks.json` in the correct format (event-key objects, not flat arrays)?
6. **For skills/agents**: Do referenced files exist? Is frontmatter valid?
7. **Version check**: Does `installed_plugins.json` version match `plugin.json` version match marketplace version?

## Related Issues
- See also: [auto-build-launcher-go-mcp-plugins-20260215.md](../workflow-issues/auto-build-launcher-go-mcp-plugins-20260215.md) — launcher pattern that permanently fixes the missing binary problem for compiled MCP servers
