# Flux-Drive Safety Review: interserve MCP Server

**Review Date:** 2026-02-16
**Reviewer:** FD-Safety (Claude Opus 4.6)
**Component:** interserve MCP server (Go stdio server for document section classification)
**Version:** 0.1.0
**Risk Classification:** Medium (subprocess invocation + file I/O from MCP client input)

---

## Executive Summary

The interserve MCP server exposes two tools (`extract_sections`, `classify_sections`) that read markdown files and optionally invoke an external bash script for AI-powered classification. The security posture is **generally sound for a local-only, trusted-client environment**, but contains **three medium-severity deployment risks** and **one critical missing control** that could enable privilege escalation or data exfiltration if the MCP client or dispatch script path is compromised.

**Key findings:**
1. **Path traversal vector (MEDIUM)**: `file_path` from MCP client is passed directly to `os.ReadFile` with no validation — allows reading any file the process can access
2. **Subprocess invocation via environment variable (HIGH)**: `INTERSERVE_DISPATCH_PATH` controls which bash script is executed, with hardcoded fallback to a specific absolute path
3. **Auto-build on first launch (MEDIUM)**: `launch-mcp.sh` runs `go build` without pinning go.sum, fetching dependencies from the internet at MCP server startup
4. **No rollback strategy**: Changes to dispatch.sh or tiers.yaml have immediate effect with no versioning or rollback mechanism

**Recommended mitigations** (prioritized by exploitability × blast radius):
- Add path validation to restrict `file_path` to workspace-relative paths or opt-in directories
- Pin `INTERSERVE_DISPATCH_PATH` in plugin manifest instead of allowing env override
- Pre-build Go binary in plugin installation hook instead of auto-building on first use
- Add dispatch.sh execution logging and audit trail for multi-user systems

---

## Threat Model

### System Context
- **Deployment model**: Local-only MCP server, launched on-demand by Claude Code via stdio transport
- **Trust boundaries**:
  - **Trusted**: Claude Code itself (the MCP client), user's prompt input to Claude Code
  - **Untrusted**: None identified in normal operation — this is a local developer tool
  - **Semi-trusted**: Environment variables (can be overridden by shell config, but user-controlled)
- **Network exposure**: None (stdio transport, no network listeners)
- **Privilege level**: Runs as `claude-user` (non-root, member of `docker`, `ollama` groups, no sudo access)
- **Data access**: File system read access to all files readable by `claude-user` (via POSIX ACLs)
- **Credential exposure risk**: Medium — if a malicious file path is supplied, could read `.git-credentials`, `.env`, or SSH keys

### Attack Scenarios (Realistic)
1. **Malicious MCP client**: If a compromised or malicious Claude Code plugin invokes interserve tools with attacker-controlled `file_path`, it can read arbitrary files (credentials, SSH keys, private docs)
2. **Environment variable poisoning**: If `.zshrc` or a malicious plugin sets `INTERSERVE_DISPATCH_PATH=/tmp/evil.sh`, interserve will execute it via bash
3. **Dependency confusion during auto-build**: If `go build` fetches dependencies and a malicious package is published with the same name as a private dep, it could be executed during build
4. **Dispatch script compromise**: If `/root/projects/Interverse/hub/clavain/scripts/dispatch.sh` is writable by another user or modified by a malicious plugin, interserve will execute arbitrary code

### Attack Scenarios (Theoretical, Out of Scope)
- **Untrusted MCP client over network**: Not applicable — stdio transport, local-only
- **Multi-tenant environment**: Not applicable — single-user developer workstation
- **Unauthenticated access**: Not applicable — MCP server only responds to stdio from parent process (Claude Code)

---

## Security Findings

### 1. Path Traversal via `file_path` Parameter (MEDIUM)

**Location**: `internal/tools/tools.go:42-50`, `tools.go:81-89`

**Issue**: Both `extract_sections` and `classify_sections` accept a `file_path` parameter from the MCP client and pass it directly to `os.ReadFile()` with no validation.

```go
filePath, errText := requiredString(req.GetArguments(), "file_path")
if errText != "" {
    return mcp.NewToolResultError(errText), nil
}

doc, err := os.ReadFile(filePath)  // ← No path validation
if err != nil {
    return mcp.NewToolResultError(fmt.Sprintf("read %s: %v", filePath, err)), nil
}
```

**Exploitability**: Medium
- Requires compromised MCP client or malicious Claude Code plugin
- Claude Code itself (the primary MCP client) is trusted and would not send malicious paths
- However, if a malicious plugin invokes interserve tools programmatically, it can read arbitrary files

**Impact**: Medium → High (depending on file permissions)
- Can read any file accessible to `claude-user` (which has POSIX ACLs granting read access to most project files, config files, and potentially credentials)
- Potential data exfiltration targets: `.git-credentials`, `.env`, SSH keys in `~/.ssh/`, `.claude.json` (API keys), `.config/` secrets

**Mitigation**:
1. **Restrict to workspace-relative paths** (recommended):
   ```go
   // Option A: Require relative paths only, resolve against a workspace root
   if filepath.IsAbs(filePath) {
       return mcp.NewToolResultError("file_path must be relative to workspace root"), nil
   }
   workspaceRoot := os.Getenv("INTERSERVE_WORKSPACE_ROOT")
   if workspaceRoot == "" {
       workspaceRoot = os.Getenv("PWD")  // fallback to current directory
   }
   resolvedPath := filepath.Join(workspaceRoot, filePath)

   // Prevent directory traversal (.., symlinks)
   absPath, err := filepath.Abs(resolvedPath)
   if err != nil {
       return mcp.NewToolResultError(fmt.Sprintf("invalid path: %v", err)), nil
   }
   if !strings.HasPrefix(absPath, workspaceRoot) {
       return mcp.NewToolResultError("file_path escapes workspace root"), nil
   }

   doc, err := os.ReadFile(absPath)
   ```

2. **Opt-in allowlist** (more restrictive, better for high-security environments):
   - Maintain a config file with allowed directories (e.g., `/root/projects/**`, `/tmp/interserve-*`)
   - Reject paths outside the allowlist

3. **Audit logging** (defense-in-depth):
   - Log all `file_path` values to a dedicated audit log (timestamp, MCP client identity if available, file path, success/failure)
   - Enables post-incident forensics if credentials are leaked

**Residual risk after mitigation**: Low (path validation eliminates the attack vector for normal operation; residual risk is a bug in the validation logic itself)

---

### 2. Subprocess Invocation via Environment Variable (HIGH)

**Location**: `cmd/interserve-mcp/main.go:18-21`, `internal/classify/classify.go:101-109`

**Issue**: The path to the bash script executed by interserve is controlled by the `INTERSERVE_DISPATCH_PATH` environment variable, with a hardcoded fallback:

```go
dispatchPath := os.Getenv("INTERSERVE_DISPATCH_PATH")
if dispatchPath == "" {
    dispatchPath = "/root/projects/Interverse/hub/clavain/scripts/dispatch.sh"
}
```

Then invoked via:
```go
cmd := exec.CommandContext(
    ctx,
    "bash",
    dispatchPath,  // ← Controlled by env var
    "--tier", "fast",
    "--sandbox", "read-only",
    "--prompt-file", promptPath,
    "-o", outputPath,
)
```

**Exploitability**: Medium
- Requires attacker control over environment variables (malicious `.zshrc`, compromised plugin setting env vars, or malicious systemd unit file if interserve were launched as a service)
- The plugin manifest **does set this env var explicitly** (`INTERSERVE_DISPATCH_PATH: /root/projects/Interverse/hub/clavain/scripts/dispatch.sh`), which mitigates the risk for normal Claude Code usage
- However, if the manifest were missing or a user manually launched the binary with a malicious env var, arbitrary code execution is trivial

**Impact**: High → Critical
- Arbitrary code execution as `claude-user` (full read access to projects, docker/ollama group membership)
- Could exfiltrate credentials, modify project files, spawn reverse shells, or escalate privileges if `dispatch.sh` itself has unsafe patterns (see Finding 3)

**Mitigation**:
1. **Remove env var override capability** (recommended):
   ```go
   // Remove the os.Getenv call entirely — pin the path at compile time or in a config file
   const dispatchPath = "/root/projects/Interverse/hub/clavain/scripts/dispatch.sh"

   // OR: Read from a config file in a trusted location with strict permissions
   configPath := filepath.Join(os.Getenv("HOME"), ".config", "interserve", "dispatch-path.conf")
   dispatchPath, err := readDispatchPathFromConfig(configPath)
   if err != nil {
       return fmt.Errorf("failed to load dispatch path config: %w", err)
   }
   ```

2. **Validate dispatch path before execution** (defense-in-depth):
   ```go
   // Ensure the script is owned by root or claude-user and not world-writable
   info, err := os.Stat(dispatchPath)
   if err != nil {
       return fmt.Errorf("dispatch script not found: %w", err)
   }
   mode := info.Mode()
   if mode&0o002 != 0 {  // World-writable check
       return fmt.Errorf("dispatch script is world-writable (unsafe): %s", dispatchPath)
   }

   // Optional: verify owner is root or claude-user
   stat, ok := info.Sys().(*syscall.Stat_t)
   if ok && stat.Uid != 0 && stat.Uid != os.Getuid() {
       return fmt.Errorf("dispatch script is owned by untrusted user: %s", dispatchPath)
   }
   ```

3. **Audit logging for dispatch invocations**:
   - Log every `dispatch.sh` invocation with timestamp, resolved path, args, and exit code
   - Enables detection of unexpected invocations (e.g., if a malicious plugin sets `INTERSERVE_DISPATCH_PATH`)

**Residual risk after mitigation**: Low (pinning the path and validating ownership/permissions eliminates the env var attack vector; residual risk is compromise of the dispatch script itself, covered in Finding 4)

---

### 3. Dispatch Script Execution Security

**Location**: `/root/projects/Interverse/hub/clavain/scripts/dispatch.sh` (executed via `bash`)

**Issue**: The dispatch script is a 600+ line bash script that:
- Resolves tier names to model strings from a YAML config file
- Supports template assembly with `{{MARKER}}` substitution using `perl` (safe multi-line handling)
- Injects documentation content (`CLAUDE.md`, `AGENTS.md`) into prompts via `--inject-docs`
- Invokes `codex exec` with user-supplied arguments and prompts

**Security posture of dispatch.sh**:
- **Good**: No `eval` usage, careful quoting of variables, `set -euo pipefail` for fail-fast behavior
- **Good**: Template substitution uses `perl` for safe multi-line handling (avoids shell injection in marker values)
- **Good**: Flags like `--yolo` are blocked unless `CLAVAIN_ALLOW_UNSAFE=1` is set (opt-in unsafe mode)
- **Moderate**: `--inject-docs` reads files from `$WORKDIR` and prepends them to prompts — if `$WORKDIR` is attacker-controlled, could inject malicious content into the prompt (low impact, as the prompt is sent to a trusted AI, not executed)
- **Moderate**: `EXTRA_ARGS` array passes through unknown flags to `codex exec` — if a malicious flag is added to the pass-through list, it could bypass sandbox restrictions

**Exploitability**: Low → Medium (requires compromise of dispatch.sh itself or modification of tiers.yaml/dispatch logic)

**Impact**: High (arbitrary code execution via `codex exec` with full filesystem access if `--sandbox danger-full-access` is forced)

**Mitigation**:
1. **File integrity monitoring** (recommended for dispatch.sh and tiers.yaml):
   - Add a post-edit hook that checks if dispatch.sh or config files are modified outside of git commits
   - Alert if unexpected changes are detected (e.g., via inotify + sha256 checksums)

2. **Restrict dispatch.sh ownership and permissions** (already correct per Finding 2 analysis):
   ```bash
   # Verify current state (already 775 claude-user:claude-user per analysis)
   stat -c "%a %U:%G" /root/projects/Interverse/hub/clavain/scripts/dispatch.sh
   # → 775 claude-user:claude-user (correct, group-writable but not world-writable)
   ```

3. **Audit trail for dispatch invocations** (defense-in-depth):
   - Modify dispatch.sh to log every invocation to a dedicated audit log (`/var/log/clavain-dispatch.log` with append-only permissions)
   - Log: timestamp, user, PID, workdir, model/tier, prompt size, output path, exit code

**Residual risk**: Low (dispatch.sh is well-written and has no obvious command injection vectors; residual risk is a logic bug in argument parsing or a malicious git commit modifying dispatch.sh)

---

### 4. Auto-Build on First Launch (MEDIUM)

**Location**: `bin/launch-mcp.sh:6-13`

**Issue**: The launch script auto-builds the Go binary if it doesn't exist:

```bash
if [[ ! -x "$BINARY" ]]; then
    if ! command -v go &>/dev/null; then
        echo '{"error":"go not found — cannot build interserve-mcp. Install Go 1.23+ and restart."}' >&2
        exit 1
    fi
    cd "$PROJECT_ROOT"
    go build -o "$BINARY" ./cmd/interserve-mcp/ 2>&1 >&2  # ← Fetches deps from internet
fi
exec "$BINARY" "$@"
```

**Exploitability**: Low → Medium
- Requires attacker control over the Go module cache, go.sum, or ability to publish a malicious package to a public registry
- **Dependency confusion attack**: If a private dependency name matches a public package name, `go build` might fetch the public (malicious) package
- **Supply chain risk**: If `go.sum` is not present or is stale, `go build` will fetch dependencies without verifying checksums

**Impact**: High (arbitrary code execution during build, with full access to the build environment and any secrets accessible to `claude-user`)

**Mitigation**:
1. **Pre-build in plugin installation hook** (recommended):
   ```bash
   # Add to .claude-plugin/plugin.json:
   # "installScript": "scripts/install.sh"

   # scripts/install.sh:
   #!/usr/bin/env bash
   set -euo pipefail
   cd "$(dirname "$0")/.."
   go build -o bin/interserve-mcp ./cmd/interserve-mcp/
   ```
   - This moves the build to a one-time install step, where the user is more likely to notice unexpected behavior
   - Eliminates the auto-build on first MCP server launch (when the user is focused on Claude Code, not plugin installation)

2. **Pin dependencies with go.sum** (already done, per `go.sum` analysis):
   - `go.sum` is present and contains checksums for all dependencies → `go build` will verify integrity
   - **Verify go.sum is committed**: `git ls-files plugins/interserve/go.sum` → should return the file path

3. **Dependency audit** (defense-in-depth):
   - Run `go list -m all | xargs -n1 go mod why` to identify why each dependency is included
   - Review `go.mod` for unexpected private/internal package names that could be confused with public packages
   - Use `govulncheck` to scan for known CVEs in dependencies

**Residual risk**: Low (go.sum provides integrity checks; residual risk is a compromised Go toolchain or a 0-day in a dependency)

---

### 5. Temp File Handling

**Location**: `internal/classify/classify.go:76-99`, `internal/tempfiles/tempfiles.go:51-56`

**Issue**: Temp files are created for prompt input and classification output.

**Security posture**:
- **Good**: `os.CreateTemp("", "interserve-prompt-*.txt")` uses a secure random suffix (Go stdlib guarantees unpredictability)
- **Good**: `defer os.Remove(...)` ensures cleanup on success
- **Good**: Error handling removes all created files on failure (`tempfiles.go:52-54`)
- **Good**: Permissions are `0o600` (owner-only read/write) in `tempfiles.go:51`
- **Moderate**: No explicit permission setting in `classify.go` temp file creation → uses Go's default (`0o600` on Unix, per Go stdlib docs)

**Exploitability**: Low (temp file names are unpredictable, permissions are restrictive)

**Impact**: Low (temporary prompt content or classification output could leak to disk if cleanup fails, but only accessible to the same user)

**Mitigation**: None required — current implementation is secure.

**Residual risk**: Negligible (residual risk is a bug in Go's `os.CreateTemp` or a kernel vulnerability allowing unprivileged temp file access)

---

### 6. Subprocess Argument Injection

**Location**: `internal/classify/classify.go:101-109`

**Issue**: The dispatch script is invoked with hardcoded flags and temp file paths:

```go
cmd := exec.CommandContext(
    ctx,
    "bash",
    dispatchPath,
    "--tier", "fast",
    "--sandbox", "read-only",
    "--prompt-file", promptPath,
    "-o", outputPath,
)
```

**Security posture**:
- **Good**: All arguments are hardcoded or derived from `os.CreateTemp` (no user input flows into the command)
- **Good**: No shell interpolation — `exec.CommandContext` uses `execve` directly (no shell parsing of arguments)
- **No injection vector identified**: `promptPath` and `outputPath` are temp file paths created by the process itself, not influenced by MCP client input

**Exploitability**: None (no user input flows into command arguments)

**Mitigation**: None required.

---

## Deployment & Migration Findings

### 1. No Rollback Strategy for dispatch.sh or tiers.yaml

**Issue**: Changes to `dispatch.sh` or `hub/clavain/config/dispatch/tiers.yaml` take effect immediately, with no versioning or rollback mechanism.

**Impact**: Medium
- If a buggy or malicious commit modifies dispatch.sh, all interserve invocations are affected immediately
- No easy way to revert to a known-good version without manual git operations
- Tier config changes (e.g., changing `fast` tier to a more expensive model) have immediate cost/latency impact

**Recommended mitigations**:
1. **Version dispatch.sh in sync with interserve plugin version**:
   - Tag dispatch.sh commits with the interserve version that depends on them
   - Use `git describe --tags --always` in dispatch.sh to embed version info in logs

2. **Pre-deploy checks for dispatch.sh changes**:
   - Add a pre-commit hook that runs `bash -n dispatch.sh` to catch syntax errors
   - Run a smoke test: `dispatch.sh --dry-run -C /tmp -o /tmp/test.md "test prompt"`

3. **Tier config validation**:
   - Add a schema validator for `tiers.yaml` (e.g., JSON Schema or a Go validation script)
   - Require explicit approval for tier config changes (e.g., pull request review)

4. **Rollback procedure**:
   - Document the rollback steps in `AGENTS.md`:
     ```bash
     # Rollback dispatch.sh to previous commit
     git log --oneline hub/clavain/scripts/dispatch.sh | head -5
     git checkout <commit-sha> hub/clavain/scripts/dispatch.sh
     # Restart Claude Code sessions to pick up the change
     ```

**Residual risk**: Low (git provides version history; residual risk is failure to notice a breaking change until multiple sessions are affected)

---

### 2. No Monitoring or Alerting for Dispatch Failures

**Issue**: If `dispatch.sh` fails (e.g., due to missing `codex` binary, invalid tier config, or network issues fetching models), the failure is returned to the MCP client as a JSON error, but there's no centralized logging or alerting.

**Impact**: Low → Medium
- Failures are visible to the user (MCP client receives an error), but not aggregated for trend analysis
- If dispatch failures are frequent (e.g., due to a bad tier config or missing dependency), the user might not notice a pattern
- No visibility for the system administrator if interserve is used by multiple users on a shared server

**Recommended mitigations**:
1. **Structured logging**:
   - Add JSON-formatted logs to stderr for all dispatch.sh invocations:
     ```bash
     echo "$(date -Iseconds) dispatch_started workdir=$WORKDIR tier=$TIER model=$MODEL" >&2
     # ... (at end)
     echo "$(date -Iseconds) dispatch_completed workdir=$WORKDIR exit=$CODEX_EXIT duration=${ELAPSED}s" >&2
     ```
   - Redirect stderr to a dedicated log file (e.g., `/var/log/clavain-dispatch.log`) in a systemd-managed environment

2. **Failure alerts**:
   - Monitor `/var/log/clavain-dispatch.log` for frequent failures (e.g., >5 failures in 10 minutes)
   - Send alerts via systemd's `OnFailure=` directive or a log aggregation tool (Loki, journalctl filters)

3. **Health check endpoint** (future enhancement):
   - Add an MCP tool `interserve_health_check` that verifies:
     - `dispatch.sh` is executable and owned by a trusted user
     - `tiers.yaml` is readable and valid
     - `codex` binary is in PATH
   - Claude Code plugins can call this on session start to detect environment issues early

**Residual risk**: Low (users will notice failures during interactive use; residual risk is silent degradation that only affects background/automated interserve invocations)

---

### 3. Plugin Auto-Build Failure Modes

**Issue**: If `launch-mcp.sh` fails to build the Go binary (e.g., due to missing `go` binary, network issues fetching deps, or corrupted `go.sum`), the MCP server fails to start, and Claude Code's MCP client will timeout or return a generic error.

**Impact**: Low (user-visible failure, but unclear root cause)

**Recommended mitigations**:
1. **Explicit error messages**:
   - Current implementation already prints a JSON error if `go` is not found (good)
   - Enhance to detect network failures:
     ```bash
     if ! go build -o "$BINARY" ./cmd/interserve-mcp/ 2>&1 >&2; then
       echo '{"error":"go build failed. Check network connectivity and go.sum integrity."}' >&2
       exit 1
     fi
     ```

2. **Pre-build validation in plugin installation**:
   - Add an install script that builds the binary and fails the plugin installation if build fails
   - Moves the failure to a point where the user is focused on plugin setup, not mid-session usage

3. **Fallback behavior**:
   - If the binary build fails, provide a degraded mode (e.g., skip classification and return an empty slicing map)
   - Not recommended — better to fail loudly and fix the root cause

**Residual risk**: Low (build failures are rare in a stable environment; residual risk is a corrupted `go.sum` or upstream registry outage)

---

## Risk Prioritization

| Finding | Exploitability | Blast Radius | Priority | Mitigation Effort |
|---------|---------------|--------------|----------|-------------------|
| **2. Subprocess invocation via env var** | Medium | High → Critical | **HIGH** | Low (pin path in code) |
| **1. Path traversal via `file_path`** | Medium | Medium → High | **MEDIUM** | Medium (add path validation) |
| **4. Auto-build on first launch** | Low → Medium | High | **MEDIUM** | Low (pre-build in install hook) |
| **3. Dispatch script security** | Low | High | **LOW** | Medium (file integrity monitoring) |
| **Deployment: No rollback for dispatch.sh** | Low | Medium | **LOW** | Low (document rollback procedure) |
| **Deployment: No monitoring for dispatch failures** | Low | Low → Medium | **LOW** | Medium (add structured logging) |

**Recommended implementation order:**
1. Finding 2 (env var pinning) — highest impact, lowest effort
2. Finding 1 (path validation) — closes a concrete attack vector
3. Finding 4 (pre-build in install hook) — reduces supply chain risk
4. Deployment findings (rollback docs + logging) — improves operability

---

## What NOT to Flag (Residual Context)

- **Missing authentication on MCP tools**: Not applicable — MCP client (Claude Code) is trusted, no untrusted callers in the threat model
- **Temp file race conditions**: Not exploitable — temp file names are unpredictable (secure by design in Go stdlib)
- **JSON deserialization vulnerabilities**: Not applicable — uses Go's `encoding/json` (memory-safe, no code execution risk)
- **Dispatch script command injection**: Not found — careful quoting and `set -euo pipefail` eliminate shell injection vectors
- **Missing rate limiting**: Not applicable — local-only tool, no DoS risk from untrusted callers

---

## Actionable Recommendations

### Immediate (Ship Blockers)
1. **Pin `INTERSERVE_DISPATCH_PATH` in code** (remove env var override):
   ```go
   // cmd/interserve-mcp/main.go
   const dispatchPath = "/root/projects/Interverse/hub/clavain/scripts/dispatch.sh"
   // Remove: dispatchPath := os.Getenv("INTERSERVE_DISPATCH_PATH")
   ```
   - **Why**: Eliminates the most exploitable privilege escalation vector
   - **Effort**: 5 minutes (1-line code change + plugin.json manifest update)

2. **Add path validation to `file_path` parameter**:
   - Implement workspace-relative path validation (see Finding 1 mitigation for code snippet)
   - **Why**: Closes the file disclosure vector for compromised MCP clients
   - **Effort**: 30 minutes (add validation function + unit tests)

### Short-term (Next Release)
3. **Pre-build Go binary in plugin install hook**:
   - Move `go build` from `launch-mcp.sh` to a new `scripts/install.sh`
   - Add `"installScript": "scripts/install.sh"` to `plugin.json`
   - **Why**: Reduces supply chain risk and improves first-use UX
   - **Effort**: 1 hour (script + testing + manifest update)

4. **Add dispatch.sh execution logging**:
   - Append structured logs to `/var/log/clavain-dispatch.log` (timestamp, user, workdir, tier, exit code)
   - **Why**: Enables forensics if dispatch.sh is compromised or misconfigured
   - **Effort**: 2 hours (modify dispatch.sh + logrotate config + testing)

### Long-term (Technical Debt)
5. **File integrity monitoring for dispatch.sh**:
   - Add a post-edit hook that verifies `dispatch.sh` hasn't been modified outside of git commits
   - **Why**: Detects unauthorized modifications (malicious plugin, compromised user account)
   - **Effort**: 4 hours (hook script + inotify watcher + testing)

6. **Dependency audit and govulncheck CI job**:
   - Add a CI step that runs `govulncheck ./...` on every commit
   - **Why**: Catches known CVEs in Go dependencies before they're deployed
   - **Effort**: 2 hours (CI config + dependency review)

---

## Conclusion

The interserve MCP server is **secure for its intended use case** (local-only, trusted MCP client), but contains **two medium-severity findings** (path traversal, env var subprocess invocation) that should be mitigated before wider deployment. The dispatch script is well-written and has no obvious command injection vectors, but lacks rollback and monitoring capabilities for safe operation in a multi-user environment.

**Go/no-go recommendation**: **Go**, with the two immediate mitigations (pin dispatch path, validate file paths) implemented before the next release.

**Residual risk after all mitigations**: Low — the system will be secure against realistic threats in the defined threat model (local developer workstation, trusted MCP client, non-adversarial environment).
