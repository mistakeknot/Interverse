# Safety Review: Dual-Mode Plugin Architecture Implementation Plan

**Plan:** `docs/plans/2026-02-20-dual-mode-plugin-architecture.md`
**Reviewer:** Flux-drive Safety Reviewer
**Date:** 2026-02-20
**Context:** Local-only single-developer workstation, Tailscale-only external exposure, all agent sessions run as `claude-user` (same UID)

---

## Threat Model

**System Architecture:**
- Deployment: Local development machine, no network exposure beyond Tailscale
- Trust boundary: The human developer (root/mk) vs. Claude Code agent sessions running as `claude-user`
- All agent sessions share the same UID, the same home directory (via ACL/symlinks), and the same `~/.intermod/` path
- Untrusted inputs: None — all callers of interbase.sh are authorized agent sessions launched by the same human operator
- Credentials/secrets: None in interbase.sh itself; plugins sourcing it may have env vars (EXA_API_KEY, etc.) but those are not processed by interbase
- Attack surface: The shared sourcing path `~/.intermod/interbase/interbase.sh` — code executed in every plugin that sources the stub

**Risk Classification:** Medium

The primary risk is not adversarial attack. It is:
1. The `~/.intermod/interbase/interbase.sh` sourcing chain creating an unintended code execution path if install.sh writes a bad version
2. Race conditions in nudge deduplication causing duplicate or no output
3. Nudge state files accumulating user activity data across sessions
4. The `interbump` hook writing to the live centralized copy atomically enough to survive concurrent agent sourcing

No auth flows, no credential handling, no network sockets, no privilege escalation vectors. This is shell library distribution infrastructure.

---

## Security Findings

### MEDIUM: Centralized `~/.intermod/interbase.sh` is a Shared Code Execution Path

**Finding:** Every plugin that ships `interbase-stub.sh` will source `~/.intermod/interbase/interbase.sh` at session start. This means `install.sh` writing a bad or incomplete file will affect every installed plugin simultaneously on the next session start.

**Concrete scenario:**
1. `interbump` runs mid-session (e.g., during a plugin publish)
2. `install.sh` starts: `cp "$SCRIPT_DIR/lib/interbase.sh" "$TARGET_DIR/interbase.sh"` — this is a non-atomic copy
3. Another agent session starts, sources the partially-written file
4. `bash` sources a truncated shell script: syntax error propagates into the hook execution context
5. Depending on Claude Code's hook error handling, the session may fail to initialize cleanly

**Severity:** Medium — exploitability is low (requires two things happening simultaneously), but blast radius is wide (all plugins with the stub).

**Mitigation:** The install script should use an atomic write pattern, identical to the `jq` update pattern already in `interbump.sh`:

```bash
# Replace the cp line in install.sh with:
local tmp="${TARGET_DIR}/interbase.sh.tmp.$$"
cp "$SCRIPT_DIR/lib/interbase.sh" "$tmp"
chmod 644 "$tmp"
mv -f "$tmp" "$TARGET_DIR/interbase.sh"
```

`mv` within the same filesystem is atomic. The current `cp` + `chmod` sequence is not.

**Action required:** Make `install.sh` use `cp` to a `.tmp.$$` temp file, then `mv -f` to the target. This eliminates the torn-write window.

---

### LOW: File Permissions on `~/.intermod/interbase.sh` (644) — Appropriate but Incomplete Analysis

**Finding:** The plan sets `chmod 644` on the installed file. This is correct for the local-only single-developer threat model. The file needs to be readable by `claude-user` (which runs Claude Code sessions) and writable only by root/mk (which runs `interbump`).

**Verification:** The CLAUDE.md documents that POSIX ACLs govern access between root and `claude-user`. The `chmod 644` permission is correct: root owns the file and can write it; `claude-user` can read and source it. The existing `setfacl` infrastructure on `/root/` directories should be extended to `/root/.intermod/` if it is created under that path.

**Residual concern:** The plan places `~/.intermod/` under `$HOME`, which resolves to `/root/` for the primary user and `/home/claude-user/` for `claude-user` sessions. Because `/home/claude-user/` is symlinked to `/root/`, `~/.intermod/` will resolve to `/root/.intermod/` in both cases — this is correct and consistent with how `~/.interband/` works today. No action required on permissions beyond including `/root/.intermod/` in the existing `setfacl` sweep.

**Recommendation (low priority):** Add `/root/.intermod/` to the `setfacl` commands in `CLAUDE.md`'s "When adding new projects" section so the ACL infrastructure is not forgotten on first install.

---

### LOW: No Integrity Check on Sourced File

**Finding:** `interbase-stub.sh` sources `~/.intermod/interbase/interbase.sh` with no integrity check:

```bash
if [[ -f "$_interbase_live" ]]; then
    _INTERBASE_SOURCE="live"
    source "$_interbase_live"
    return 0
fi
```

In the defined threat model (single developer, local machine, trusted filesystem), this is acceptable. There is no adversarial actor who could replace the file. The risk of accidental corruption is addressed by the atomic install fix above.

**What would NOT be acceptable:** If `~/.intermod/interbase/interbase.sh` were written by a third-party package manager, received over the network, or located in a world-writable directory. None of those apply here.

**No action required** for the current threat model.

---

### LOW: `INTERMOD_LIB` Environment Variable Override — Acceptable

**Finding:** The stub resolves the interbase path via:

```bash
_interbase_live="${INTERMOD_LIB:-${HOME}/.intermod/interbase/interbase.sh}"
```

An environment variable can override the sourcing path. In the defined threat model, all agents run as `claude-user` with environment variables set by the human developer. A malicious `INTERMOD_LIB` value pointing to a hostile script would require the developer to have set it themselves — outside the threat model.

**Legitimate use:** `INTERMOD_LIB` is the correct developer override pattern (matching `INTERBAND_LIB` in the interband precedent). It is documented in the architecture review as intentional.

**No action required.**

---

### INFORMATIONAL: No Credential or Secret Exposure

**Finding:** `interbase.sh` processes no credentials. It reads environment variables (`CLAVAIN_BEAD_ID`, `CLAUDE_SESSION_ID`) that are non-secret identifiers. The nudge state files (`~/.config/interverse/nudge-state.json`, session files) contain only plugin names, ignore counts, and dismissed flags — no API keys, tokens, or user data.

The `ib_emit_event` function passes `--payload="$payload"` to `ic events emit`. The payload is caller-controlled. If a caller passes a payload containing a secret, it would be written to the intercore event log. This is a caller responsibility, not an interbase responsibility. No action required in interbase itself.

---

## Command Injection Analysis

### Examined: `ib_nudge_companion` — No Injection Vector

The flag filename is constructed as:

```bash
local flag="${flag_dir}/.nudge-${CLAUDE_SESSION_ID:-x}-${plugin}-${companion}"
```

This path is used in:
```bash
[[ ! -f "$flag" ]] || return 0
touch "$flag" 2>/dev/null || return 0
```

`[[ -f ... ]]` and `touch` with a double-quoted argument do not invoke a subshell or interpret metacharacters. If `CLAUDE_SESSION_ID` or `companion` contained shell metacharacters, the filename would be unusual but the operations would not execute arbitrary code.

**Edge case:** If `companion` contains a `/` (e.g., `org/plugin`), the path would traverse a subdirectory that may not exist, causing `touch` to fail silently (`|| return 0` catches it). The nudge would then fire on every invocation (no flag written). This is a correctness issue, not a security issue. Plugin names in the Interverse ecosystem use flat lowercase names (no slashes), so this is theoretical.

**No injection risk.**

---

### Examined: `_ib_nudge_record` — jq Usage is Safe

```bash
jq --arg k "$key" --argjson ig "$ignores" --argjson dis "$dismissed" \
    '.[$k] = {"ignores":$ig,"dismissed":$dis}' "$nf" > "$tmp" 2>/dev/null
```

`key` is `"${plugin}:${companion}"` — both controlled by the calling plugin. Using `--arg k` (not `--args` or interpolation into the filter string) means `$key` is passed as a jq variable, not interpreted as jq code. This is the correct, injection-safe pattern, matching the `jq --arg` usage documented in the existing safety review for interlock.

**No injection risk.**

---

### Examined: `ib_emit_event` — Payload Passthrough

```bash
ic events emit "$run_id" "$event_type" --payload="$payload"
```

`$payload` is passed as a single shell word (double-quoted assignment to `--payload`). No eval, no subshell. The `ic` binary receives it as a single argument. If `$payload` contains shell metacharacters, they are not interpreted by bash at this call site.

**No injection risk at the interbase level.** Payload content validation is the caller's responsibility.

---

### Examined: `ib_has_companion` — Glob Expansion in `compgen`

```bash
compgen -G "${HOME}/.claude/plugins/cache/*/${name}/*" &>/dev/null
```

`$name` is the companion plugin name, provided by the calling plugin. If `name` contained `..` or glob metacharacters, the glob pattern would expand unexpectedly. However:
- `compgen -G` expands globs but does not execute code
- Path traversal via `..` in a glob would at worst check for the existence of unintended paths
- No code is executed based on the glob result — it is only used as a boolean existence check

**No code execution risk.** The theoretical path traversal via a malicious `$name` is outside the threat model (caller-controlled in trusted plugin code).

---

## Race Condition Analysis: Nudge Deduplication

### Finding: Flag File Approach Has a TOCTOU Window

The current deduplication in `ib_nudge_companion`:

```bash
local flag="${flag_dir}/.nudge-${CLAUDE_SESSION_ID:-x}-${plugin}-${companion}"
[[ ! -f "$flag" ]] || return 0
touch "$flag" 2>/dev/null || return 0
# Emit nudge
```

The check (`[[ ! -f ... ]]`) and the write (`touch`) are two separate operations. If two hook invocations run in parallel (e.g., Claude Code fires SessionStart for multiple plugins simultaneously), both can pass the `[[ ! -f ... ]]` check before either writes the flag file. Both will emit the nudge.

**Frequency:** Low. The `CLAUDE_SESSION_ID` and `plugin` variables in the flag name mean the window is per-session and per-plugin. Parallel execution of the same plugin's hooks for the same companion in the same session is the only collision scenario.

**Impact:** The user sees duplicate nudge messages in stderr. Annoying, not harmful.

**Mitigation options:**

**Option A (Sufficient):** Use `mkdir` as the atomic lock instead of `touch`:

```bash
local lock_dir="${flag_dir}/.nudge-lock-${CLAUDE_SESSION_ID:-x}-${plugin}-${companion}"
mkdir "$lock_dir" 2>/dev/null || return 0
# lock_dir creation is atomic — only one process succeeds
# Emit nudge
```

`mkdir` is atomic on Linux (single syscall). The first process to call it succeeds; concurrent callers get EEXIST and return 0.

**Option B (Current plan — acceptable for MVP):** Accept the low-frequency duplicate nudge as a cosmetic issue. The session budget counter (`_ib_nudge_session_count`) still limits total nudges to 2 per session, so even if two fire simultaneously for the same companion, the counter catches the next one.

**Recommendation:** Implement Option A (`mkdir` lock) — it is a one-line change that eliminates the race entirely. The existing comment in the plan mentions "Atomic: prevent parallel duplicate" but the implementation does not achieve atomicity. The comment is aspirational; the code is not.

**Action required (low priority):** Replace `[[ ! -f "$flag" ]] || return 0; touch "$flag"` with `mkdir "$lock_dir" 2>/dev/null || return 0`.

---

### Finding: Session Count Increment is Not Atomic

The session count update:

```bash
count=$(_ib_nudge_session_count)   # reads JSON
count=$((count + 1))
printf '{"count":%d}\n' "$count" > "$sf"  # writes JSON
```

This is a read-modify-write on the session file. If two hooks run in parallel and both read count=0 before either writes count=1, both will write count=1 (not count=2), and the budget check will allow a third nudge that should have been blocked.

**Impact:** The session budget of 2 can be exceeded by 1 (at most) due to parallelism. The user sees 3 nudge messages in a session instead of 2. This is a cosmetic issue only.

**Mitigation:** Implement the `mkdir` lock from Option A above. The lock directory prevents parallel execution of the count increment, not just the flag check.

**No action required as a blocker.** The budget enforcement is best-effort; the cosmetic impact is minimal.

---

## Privacy / Data Concerns: Nudge State Files

### Finding: Nudge State Records Plugin Usage Patterns

`~/.config/interverse/nudge-state.json` persists:
- Plugin names (which companion was nudged toward which plugin)
- Ignore counts (how many times the nudge was shown and not acted on)
- Dismissed flag (whether the user has been nudged 3+ times without installing)

`~/.config/interverse/nudge-session-${CLAUDE_SESSION_ID}.json` persists:
- Session-scoped nudge count

**Privacy assessment:** This is user-local data about the user's own plugin installation behavior. It is stored in `~/.config/interverse/`, a path owned by and readable only by the user. There is no network transmission of this data. No PII is collected.

**Concern:** The `CLAUDE_SESSION_ID` in the session filename leaks the Claude session identifier to the filesystem. Session IDs are not security-sensitive in this context (local machine, single user), but they are a correlatable identifier if the filesystem is shared or audited.

**No action required** for the local-only threat model. If the system were extended to a multi-user machine, session file names should be hashed before use as path components.

---

### Finding: Nudge State Files Accumulate Indefinitely

There is no cleanup mechanism for session files (`nudge-session-${CLAUDE_SESSION_ID}.json`). Each Claude Code session creates a new file. A developer with many sessions per day will accumulate many files in `~/.config/interverse/`.

**Impact:** Storage accumulation (each file is ~20 bytes; 1000 sessions = ~20KB — negligible). Directory listing pollution (ls of `~/.config/interverse/` becomes noisy over time).

**Recommendation (low priority):** Add a cleanup pass to `ib_nudge_companion` or the install script that prunes session files older than 7 days:

```bash
find "$(_ib_nudge_state_dir)" -name 'nudge-session-*.json' -mtime +7 -delete 2>/dev/null || true
```

This is optional and does not block deployment.

---

## Deployment Safety Analysis

### Finding: `interbump` Hook Writes Live Centralized Copy — No Rollback Path

**Plan (Task 10):** `interbump` calls `install_interbase` after version bumps, which runs `bash "$interbase_dir/install.sh"`. This overwrites `~/.intermod/interbase/interbase.sh` with the version from the current monorepo.

**Risk:** If a breaking change to `interbase.sh` is published and the install runs, all active plugin sessions that source the stub will use the new version on their next hook invocation. There is no automatic rollback mechanism.

**Rollback path (manual):**
1. `git -C /root/projects/Interverse/sdk/interbase revert HEAD` — reverts the source
2. `bash /root/projects/Interverse/sdk/interbase/install.sh` — reinstalls the reverted version
3. Restart affected Claude Code sessions

This is a 3-command recovery. For a single-developer local tool, this is acceptable.

**What would make this safer:** Keeping the previous version as `~/.intermod/interbase/interbase.sh.bak` before overwrite:

```bash
# In install.sh, before the mv:
[[ -f "$TARGET_DIR/interbase.sh" ]] && cp "$TARGET_DIR/interbase.sh" "$TARGET_DIR/interbase.sh.bak"
```

**Recommendation (low priority):** Add the `.bak` preservation to `install.sh`. This gives a one-command rollback (`mv ~/.intermod/interbase/interbase.sh.bak ~/.intermod/interbase/interbase.sh`) that does not require git.

---

### Finding: `interbump` Runs `install_interbase` Without `--dry-run` Guard

**Plan (Task 10):**

```bash
install_interbase() {
    local interbase_dir
    interbase_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/sdk/interbase"
    if [[ -f "$interbase_dir/install.sh" ]]; then
        echo -e "${CYAN}Installing interbase.sh to ~/.intermod/...${NC}"
        bash "$interbase_dir/install.sh"
    fi
}
```

The plan says "Call `install_interbase` at the end of the main execution flow." The existing `interbump.sh` has thorough `--dry-run` guards around every file mutation. The `install_interbase` function does not check `$DRY_RUN`.

**Impact:** Running `interbump --dry-run` would still install the live interbase.sh, defeating the dry-run guarantee. This is a correctness bug.

**Fix:**

```bash
install_interbase() {
    local interbase_dir
    interbase_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/sdk/interbase"
    if [[ -f "$interbase_dir/install.sh" ]]; then
        if $DRY_RUN; then
            echo -e "  ${YELLOW}[dry-run]${NC} Would install interbase.sh to ~/.intermod/"
        else
            echo -e "${CYAN}Installing interbase.sh to ~/.intermod/...${NC}"
            bash "$interbase_dir/install.sh"
        fi
    fi
}
```

**Action required:** Add `$DRY_RUN` guard to `install_interbase` before Task 10 is implemented.

---

### Finding: No Version Check Before Install — Silent Downgrade Possible

**Plan:** `install.sh` unconditionally overwrites `~/.intermod/interbase/interbase.sh` with the version from the current monorepo checkout. If a developer has a newer interbase installed (e.g., by manually running `install.sh` from a more recent commit) and then runs `interbump` from an older plugin's directory, the install would silently downgrade interbase.

**Impact:** Plugins relying on newer interbase functions would fall back to stub behavior on next session start (fail-open, so not catastrophic). The developer would see unexpected behavior without an obvious error message.

**Fix:** Compare VERSION files before overwriting:

```bash
INSTALLED_VERSION=$(cat "$TARGET_DIR/VERSION" 2>/dev/null || echo "0.0.0")
if [[ "$VERSION" == "$INSTALLED_VERSION" ]]; then
    echo "interbase.sh already at v${VERSION} — skipping install"
    exit 0
fi
# Optionally: version comparison (semver) to prevent downgrade
```

A strict "no downgrade" guard using semver comparison would fully prevent this. A simpler equality check (skip if same version) catches the most common case.

**Recommendation (medium priority):** Add a version equality check to `install.sh`. The downgrade protection is optional but prevents silent regressions.

---

### Finding: Standalone Mode Test (Task 8, Step 5) Mutates Live `~/.intermod/`

**Plan:**

```bash
mv ~/.intermod ~/.intermod.bak 2>/dev/null || true
bash plugins/interflux/hooks/session-start.sh 2>&1
mv ~/.intermod.bak ~/.intermod 2>/dev/null || true
```

This test step temporarily renames the live intermod directory. If the test script is interrupted between the two `mv` commands (Ctrl+C, shell exit, crash), `~/.intermod/` is left renamed to `~/.intermod.bak` and all active plugin sessions will fall back to stub mode on their next hook invocation.

**Impact:** Recoverable (`mv ~/.intermod.bak ~/.intermod`) but surprising. An interrupted test leaves the system in a degraded state with no warning.

**Fix:** The test should use `HOME=$(mktemp -d)` to simulate a fresh environment, rather than mutating the live directory:

```bash
# Safer standalone mode test:
TEST_HOME=$(mktemp -d)
INTERMOD_LIB="" HOME="$TEST_HOME" bash plugins/interflux/hooks/session-start.sh 2>&1
rm -rf "$TEST_HOME"
```

Setting `INTERMOD_LIB=""` clears the override variable. Setting `HOME="$TEST_HOME"` prevents the stub from finding `~/.intermod/` because the stub resolves `${HOME}/.intermod/interbase/interbase.sh`.

**Action required:** Replace the `mv ~/.intermod ~/.intermod.bak` pattern in Task 8 Step 5 with the `HOME=$(mktemp -d)` isolation pattern. The test suite in Task 5 already does this correctly (using `TEST_HOME=$(mktemp -d)`); the manual test in Task 8 should match.

---

### Finding: `ib_in_ecosystem` Logic Depends on `_INTERBASE_LOADED` Always Being Set — But Checks Same Variable It Declares

```bash
ib_in_ecosystem() { [[ -n "${_INTERBASE_LOADED:-}" ]] && [[ "${_INTERBASE_SOURCE:-}" == "live" ]]; }
```

`_INTERBASE_LOADED` is set to `1` at the top of `interbase.sh`. By the time `ib_in_ecosystem` is callable, `_INTERBASE_LOADED` is always set (because the script is sourced). The first condition is therefore always true when called from within the centralized copy. This makes `ib_in_ecosystem` equivalent to `[[ "${_INTERBASE_SOURCE:-}" == "live" ]]` — the first check is redundant but harmless.

**No security concern.** Minor logical dead code in the guard.

---

## Backwards Compatibility and Migration Safety

### Finding: interflux Plugin Has No Existing Hooks — Zero Regression Risk

Task 8 adds `hooks/` to interflux. The current `plugins/interflux/.claude-plugin/plugin.json` has no `hooks` key and no `hooks/` directory. Adding the SessionStart hook is purely additive. There are no existing hooks to break.

**Verification:** `plugins/interflux/.claude-plugin/plugin.json` has no hooks declaration. The plugin currently relies on Claude Code's default behavior (no session initialization). Adding `hooks/hooks.json` with a SessionStart hook adds behavior but does not remove or modify anything existing.

**Rollback path if hooks cause issues:** Remove `hooks/hooks.json` from the plugin and redeploy. Claude Code will stop running the session-start hook.

**Low regression risk.** The only failure mode is if `session-start.sh` exits non-zero and Claude Code treats it as a hard error (blocking session start). The script uses `|| true` and fail-open patterns throughout — this is unlikely.

---

### Finding: No Schema Validation for `integration.json` at Runtime

`integration.json` is created in Task 7 but never validated by any runtime code in interbase.sh (the plan defers companion-count reading to a future iteration: "Count recommended companions not installed (requires integration.json reading — deferred)").

**Assessment:** This is acceptable for MVP. The file is validated during development via `python3 -c "import json; json.load(...)"` (Task 7 Step 2). Runtime schema validation is a future enhancement, not a current gap.

**No action required.**

---

## Pre-Deploy Checklist

**MUST FIX before Task 10 is implemented:**

1. Add `$DRY_RUN` guard to `install_interbase` in `interbump.sh` — running `interbump --dry-run` should not modify `~/.intermod/`

2. Make `install.sh` use atomic write (`cp` to temp, `chmod`, then `mv -f`) to prevent torn-write during concurrent sourcing

**SHOULD FIX before first interflux plugin publish with these changes:**

3. Replace `mv ~/.intermod ~/.intermod.bak` pattern in Task 8 Step 5 with `HOME=$(mktemp -d) INTERMOD_LIB=""` isolation

4. Replace `[[ ! -f "$flag" ]] || return 0; touch "$flag"` with `mkdir` atomic lock in `ib_nudge_companion` — eliminates the TOCTOU duplicate-nudge window

**RECOMMENDED (low priority, non-blocking):**

5. Add `.bak` preservation to `install.sh` for single-command rollback without git

6. Add version equality check to `install.sh` to prevent silent downgrade via older `interbump` calls

7. Add session file pruning (files older than 7 days) to prevent accumulation in `~/.config/interverse/`

8. Add `/root/.intermod/` to the `setfacl` commands in `CLAUDE.md` for `claude-user` ACL coverage

---

## Rollback Analysis

**Rollback feasibility:** High

**Reversible changes:**
- `~/.intermod/interbase/interbase.sh` — overwrite with previous version or delete (plugins fall back to stub)
- `plugins/interflux/hooks/` — git revert, redeploy plugin
- `plugins/interflux/.claude-plugin/integration.json` — git revert, no runtime impact (not yet read by any code)
- `scripts/interbump.sh` — git revert

**Irreversible changes:**
- `~/.config/interverse/nudge-state.json` — accumulated nudge state persists. Not harmful; can be deleted manually if desired.
- Session nudge files — same, accumulated, deletable

**Data migration:** None required. No schema changes to any existing database.

**Rollback procedure:**
1. Delete or restore `~/.intermod/interbase/interbase.sh` — plugins using stub will fall back to inline no-ops
2. `git revert` the interflux hook additions — removes SessionStart hook
3. Restart Claude Code sessions to pick up the reverted plugin

**Rollback risk:** Low. The centralized SDK and the stub fallback are designed specifically so that removing the centralized copy returns plugins to pre-migration behavior without errors.

---

## Post-Deploy Verification

**Immediate (first session after deploy):**
1. Start a Claude Code session with interflux loaded — verify `[interverse] beads=active | ic=...` appears in stderr
2. Start a Claude Code session without `~/.intermod/` present — verify no output (stub mode, `ib_session_status` is a no-op)
3. Run `bash sdk/interbase/tests/test-nudge.sh` and `test-guards.sh` — verify all pass
4. Run `interbump --dry-run` on any plugin — verify no `~/.intermod/` modification occurs (after fix #1 above)

**First-day:**
1. Check `~/.config/interverse/nudge-state.json` exists and is valid JSON after a nudge fires
2. Verify session files are created in `~/.config/interverse/` with correct session IDs
3. Verify `~/.intermod/interbase/VERSION` matches `sdk/interbase/lib/VERSION`

**Failure signatures:**

| Symptom | Root Cause | Immediate Mitigation |
|---------|------------|----------------------|
| Session start fails with bash syntax error | Torn write during install | Restore from `.bak` or reinstall: `bash sdk/interbase/install.sh` |
| Duplicate nudge messages in same session | TOCTOU race on flag file | Cosmetic only; replace with `mkdir` lock in next patch |
| `[interverse]` output missing in integrated mode | `~/.intermod/interbase.sh` not present | Run `bash sdk/interbase/install.sh` |
| `interbump --dry-run` modified `~/.intermod/` | Missing `$DRY_RUN` guard | Block deployment of Task 10 until guard is added |
| interflux session fails to start | session-start.sh non-zero exit | Check `~/.claude/debug/<session-id>.txt`; disable hook by removing `hooks/hooks.json` |

---

## Risk Summary

| Risk | Severity | Status | Mitigation |
|------|----------|--------|------------|
| Torn write during `install.sh` cp+chmod | Medium | Open | Use atomic `cp tmp + mv -f` |
| `interbump --dry-run` runs live install | Medium | Open | Add `$DRY_RUN` guard to `install_interbase` |
| TOCTOU on nudge flag file | Low | Open | Replace `touch` with `mkdir` atomic lock |
| Standalone mode test mutates live `~/.intermod/` | Low | Open | Use `HOME=$(mktemp -d) INTERMOD_LIB=""` |
| Session nudge file accumulation | Low | Accepted | Add pruning in future iteration |
| Silent downgrade via older `interbump` | Low | Open | Add version check to `install.sh` |
| No `.bak` for rollback without git | Low | Accepted | Add to `install.sh`; not a blocker |
| `ib_in_ecosystem` redundant check | Informational | Harmless | Cosmetic dead code |
| Credential/secret exposure | None | N/A | No credentials processed |
| Command injection | None | N/A | jq `--arg`, no eval, no subshell on user data |

**Go/no-go decision:**
- **No-go for Task 10** until `$DRY_RUN` guard is added to `install_interbase`
- **No-go for Tasks 1-9 production deploy** until `install.sh` uses atomic write
- **Go for Tasks 1-9 development/testing** — no safety concerns block local iteration
- **Go for Task 7 and 8 (interflux integration.json + hooks)** — purely additive, zero regression risk
