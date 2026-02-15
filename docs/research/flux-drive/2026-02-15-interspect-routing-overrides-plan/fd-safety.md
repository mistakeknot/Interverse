# Safety Review: Interspect Routing Overrides Implementation Plan

**Review Date:** 2026-02-15
**Reviewer:** Flux-drive Safety Agent
**Document:** `docs/plans/2026-02-15-interspect-routing-overrides.md`
**Domain:** claude-code-plugin (clavain hub + interflux plugin coordination)

---

## Findings Index

- P1 | SEC-01 | Task 4 line 396-404 | Shell injection via unescaped reason parameter in flock subprocess
- P1 | SEC-02 | Task 3 line 308, Task 5 line 628 | SQL injection via unescaped agent name in evidence query
- P2 | OPS-01 | Task 4 line 383-393 | Agent roster validation uses glob search without cache existence check
- P2 | OPS-02 | Task 4 line 396-460 | Git commit inside flock may block other sessions indefinitely
- P2 | SEC-03 | Task 1 line 80 | SQL escaping uses string replacement instead of parameterized query
- P3 | OPS-03 | Task 4 line 452-454 | Git rollback on commit failure may not restore file if working tree is dirty
- P3 | SEC-04 | Task 2 line 201-206 | Malformed JSON moves file to .corrupted without preserving evidence
- P3 | OPS-04 | Task 7 line 774 | Test hardcodes /root/projects/Interverse path — will fail in CI or different environments

**Verdict:** needs-changes

---

## Summary

This plan implements a producer-consumer routing override system where Clavain's interspect subsystem proposes and applies agent exclusions, and interflux's flux-drive honors them during triage. The architecture is sound: file-based coordination via `.claude/routing-overrides.json`, flock-based serialization, and DB records written after commit success.

However, the implementation has **two critical shell and SQL injection vulnerabilities** (P1) that allow untrusted input to execute arbitrary commands or leak database contents. The `reason` parameter passed to `_interspect_apply_routing_override` is user-controlled (via AskUserQuestion or command arguments) and interpolated into a bash subprocess without escaping. Similarly, the `agent` parameter is interpolated into raw SQL queries without proper escaping in multiple locations. These must be fixed before merging.

Secondary issues include operational risks (git commit blocking inside flock, agent roster validation race conditions, incomplete rollback on dirty working trees) and test environment assumptions. The plan correctly flags cross-cutting agent warnings and implements canary monitoring, but the security fundamentals need hardening.

---

## Issues Found

### P1 | SEC-01 | Shell injection via unescaped reason parameter

**Location:** Task 4, lines 396-460 (`_interspect_apply_routing_override`)

**Evidence:**
```bash
_interspect_flock_git bash -c '
    set -e
    ...
    REASON="'"$reason"'"
    EVIDENCE_IDS='"'"'"$evidence_ids"'"'"'
    ...
    git commit -m "[interspect] Exclude ${AGENT} from flux-drive triage

Reason: ${REASON}
Evidence: ${EVIDENCE_IDS}
Created-by: ${CREATED_BY}"
'
```

The `$reason` variable is user-provided (from AskUserQuestion responses, command arguments, or direct API calls) and interpolated into a bash subprocess without escaping. An attacker can inject shell commands:

**Attack vector:**
```bash
# User provides reason: 'test"; rm -rf /; echo "'
# Result after interpolation:
REASON="test"; rm -rf /; echo ""
```

**Impact:** Arbitrary command execution in the plugin's execution context (claude-user permissions). Can delete files, exfiltrate data, modify git history, or corrupt the interspect database.

**Likelihood:** High if commands are exposed via CLI or if AskUserQuestion responses are passed unsanitized.

**Fix:**
Use a heredoc or write reason to a temp file:
```bash
_interspect_flock_git bash -c '
    set -e
    ROOT="'"$root"'"
    FILEPATH="'"$filepath"'"
    AGENT="'"$agent"'"
    CREATED_BY="'"$created_by"'"
    CREATED=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # Write reason to temp file to avoid injection
    REASON_FILE=$(mktemp)
    cat > "$REASON_FILE" << "REASON_EOF"
'"$reason"'
REASON_EOF
    REASON=$(cat "$REASON_FILE")
    rm -f "$REASON_FILE"

    # Write evidence to temp file
    EVIDENCE_FILE=$(mktemp)
    cat > "$EVIDENCE_FILE" << "EVIDENCE_EOF"
'"$evidence_ids"'
EVIDENCE_EOF
    EVIDENCE_IDS=$(cat "$EVIDENCE_FILE")
    rm -f "$EVIDENCE_FILE"

    # ... rest of logic
'
```

Or use printf %q for shell escaping:
```bash
ESCAPED_REASON=$(printf '%q' "$reason")
_interspect_flock_git bash -c 'REASON='"$ESCAPED_REASON"'; ...'
```

**Alternative (safer):** Write the entire commit message to a file outside the subprocess, then reference it inside:
```bash
local commit_msg_file
commit_msg_file=$(mktemp)
cat > "$commit_msg_file" <<EOF
[interspect] Exclude ${agent} from flux-drive triage

Reason: ${reason}
Evidence: ${evidence_ids}
Created-by: ${created_by}
EOF

_interspect_flock_git bash -c '
    set -e
    # ... file operations ...
    git add "$FILEPATH"
    git commit -F "'"$commit_msg_file"'"
'
rm -f "$commit_msg_file"
```

---

### P1 | SEC-02 | SQL injection via unescaped agent name

**Location:** Task 3 line 308 (interspect-propose.md), Task 5 line 628 (interspect-revert.md)

**Evidence (Task 3):**
```bash
sqlite3 -separator ' | ' "$DB" "SELECT ts, override_reason, substr(context, 1, 200) FROM evidence WHERE source = '${agent}' AND event = 'override' ORDER BY ts DESC LIMIT 5;"
```

**Evidence (Task 5):**
```bash
sqlite3 "$DB" "DELETE FROM blacklist WHERE pattern_key = '${AGENT}'; SELECT changes();"
```

The `agent` variable is user-provided (command argument or user input) and interpolated directly into SQL without parameterization. An attacker can exfiltrate data or bypass constraints:

**Attack vector:**
```bash
# User provides agent: "' OR 1=1 --"
# Resulting query:
SELECT ts, override_reason, substr(context, 1, 200) FROM evidence WHERE source = '' OR 1=1 --' AND event = 'override' ...
# Returns all evidence rows, not just for one agent
```

**Impact:**
- **Data exfiltration:** Dump entire evidence/blacklist/canary tables
- **Constraint bypass:** Delete arbitrary blacklist entries
- **DoS:** Trigger expensive queries with LIKE wildcards

**Likelihood:** High if commands accept arbitrary agent names from user input.

**Fix:**
Use parameterized queries via sqlite3's `.param` interface or pass via stdin:

```bash
# Safe pattern (Task 3):
sqlite3 "$DB" <<EOF
.param set :agent '$agent'
SELECT ts, override_reason, substr(context, 1, 200)
FROM evidence
WHERE source = :agent AND event = 'override'
ORDER BY ts DESC LIMIT 5;
EOF
```

Or escape single quotes in bash before interpolation (defensive, but parameterization is better):
```bash
local escaped_agent="${agent//\'/\'\'}"
sqlite3 "$DB" "DELETE FROM blacklist WHERE pattern_key = '${escaped_agent}';"
```

**Note:** Task 1 line 80 (`_interspect_is_routing_eligible`) already shows this pattern:
```bash
local escaped="${agent//\'/\'\'}"
```
But Task 3 and Task 5 do NOT apply this escaping. All SQL interpolations must be reviewed.

---

### P2 | OPS-01 | Agent roster validation race condition

**Location:** Task 4, lines 383-393

**Evidence:**
```bash
# Validate agent exists in roster
local agent_found=0
local interflux_root
for d in ~/.claude/plugins/cache/interagency-marketplace/interflux/*/agents/review \
         "${root}/plugins/interflux/agents/review" \
         "${root}/.claude/agents"; do
    if [[ -f "${d}/${agent}.md" ]]; then
        agent_found=1
        break
    fi
done
if (( agent_found == 0 )); then
    echo "ERROR: Agent ${agent} not found in flux-drive roster. Cannot create override." >&2
    return 1
fi
```

**Issue:** The glob `~/.claude/plugins/cache/interagency-marketplace/interflux/*/agents/review` assumes the cache directory exists and contains a versioned interflux subdirectory. If interflux is not installed, or the version directory doesn't match the glob (e.g., older version removed, newer version not yet installed), this validation fails incorrectly.

**Impact:**
- **False negatives:** Cannot create overrides for valid agents if cache is empty or version mismatches
- **False positives:** Can create overrides for non-existent agents if the monorepo fallback `${root}/plugins/interflux/agents/review` contains stale files

**Likelihood:** Medium — happens during version bumps, clean installs, or monorepo development.

**Fix:**
1. Check if interflux cache path exists before globbing:
```bash
local cache_base="$HOME/.claude/plugins/cache/interagency-marketplace/interflux"
if [[ -d "$cache_base" ]]; then
    for d in "$cache_base"/*/agents/review; do
        [[ -d "$d" ]] || continue
        if [[ -f "${d}/${agent}.md" ]]; then
            agent_found=1
            break
        fi
    done
fi
```

2. Or query the flux-drive roster programmatically via MCP if available (more robust, but adds dependency).

3. Document in AGENTS.md that this validation only works when interflux is installed or in monorepo dev mode.

---

### P2 | OPS-02 | Git commit inside flock may block indefinitely

**Location:** Task 4, lines 396-460

**Evidence:**
```bash
_interspect_flock_git bash -c '
    ...
    git add "$FILEPATH"
    if ! git commit -m "[interspect] Exclude ${AGENT} from flux-drive triage
    ...
    fi
'
```

**Issue:** The `_interspect_flock_git` wrapper holds an exclusive file lock during the entire read-modify-write-commit operation. If `git commit` triggers hooks (pre-commit, commit-msg, post-commit) that block or prompt for input, the lock is held indefinitely. This starves other sessions trying to apply overrides or run interspect commands.

**Impact:**
- **DoS for other sessions:** Any blocking hook (e.g., pre-commit running expensive linters, CI integration, GPG signing prompt) holds the lock
- **Deadlock risk:** If a pre-commit hook tries to acquire another lock that's held by a waiting session
- **Timeout cascade:** Long-running commits cause flock timeouts in other sessions, leading to spurious failures

**Likelihood:** Medium in projects with complex git hooks, GPG signing, or interactive pre-commit checks.

**Fix:**

**Option 1:** Move DB inserts inside the flock, commit outside (breaks canary-on-success guarantee):
```bash
_interspect_flock_git bash -c '
    # read, modify, write, git add
    git add "$FILEPATH"
'
# commit outside the lock
git commit -m "..." || { git restore "$FILEPATH"; return 1; }
# then insert DB records
```
**Tradeoff:** Canary records may be inserted even if commit fails later (violates design invariant).

**Option 2:** Use `git commit --no-verify` to skip hooks inside flock:
```bash
git commit --no-verify -m "[interspect] Exclude ${AGENT} ..."
```
**Tradeoff:** Bypasses pre-commit validation. Acceptable if interspect applies simple JSON edits that don't need linting.

**Option 3:** Set a flock timeout and retry on timeout:
```bash
# In lib-interspect.sh, _interspect_flock_git wrapper:
flock -w 30 "$lockfile" "$@" || {
    echo "WARN: Lock timeout after 30s. Retry or check for stuck processes." >&2
    return 1
}
```
**Tradeoff:** Fails fast but doesn't prevent the root cause. Better UX for detecting the issue.

**Recommendation:** Use Option 2 (`--no-verify`) since routing-overrides.json is a simple JSON file and validation happens at read time (Task 2 line 201). Document in AGENTS.md that interspect commits bypass hooks.

---

### P2 | SEC-03 | SQL escaping inconsistency across functions

**Location:** Task 1, line 80 (`_interspect_is_routing_eligible`)

**Evidence:**
```bash
local escaped="${agent//\'/\'\'}"
...
blacklisted=$(sqlite3 "$db" "SELECT COUNT(*) FROM blacklist WHERE pattern_key = '${escaped}';")
...
total=$(sqlite3 "$db" "SELECT COUNT(*) FROM evidence WHERE source = '${escaped}' AND event = 'override';")
```

**Issue:** This function correctly escapes single quotes via `${agent//\'/\'\'}`, but **Task 3 line 308** and **Task 5 line 628** do NOT. This creates an inconsistent security posture where some functions are injection-safe and others are not.

**Impact:** Developers assume SQL is safe because _some_ functions escape correctly, leading to copy-paste vulnerabilities.

**Likelihood:** High — already present in the plan.

**Fix:** Standardize on ONE approach across ALL SQL queries:

**Option A:** Centralize escaping in a helper function:
```bash
_interspect_sql_escape() {
    echo "${1//\'/\'\'}"
}

# Usage:
local safe_agent=$(_interspect_sql_escape "$agent")
sqlite3 "$db" "SELECT ... WHERE source = '${safe_agent}'"
```

**Option B:** Use parameterized queries everywhere (safer, but requires sqlite3 3.32+):
```bash
sqlite3 "$db" <<EOF
.param set :agent '$agent'
SELECT COUNT(*) FROM blacklist WHERE pattern_key = :agent;
EOF
```

**Recommendation:** Add `_interspect_sql_escape()` helper in Task 1, apply it to ALL SQL queries in Tasks 3, 4, 5, 6, 7. Grep for `sqlite3.*WHERE.*\$` to find unescaped interpolations.

---

### P3 | OPS-03 | Incomplete git rollback on dirty working tree

**Location:** Task 4, lines 452-454

**Evidence:**
```bash
if ! git commit -m "[interspect] Exclude ${AGENT} from flux-drive triage
...
    # Rollback on commit failure
    git restore "$FILEPATH" 2>/dev/null || git checkout -- "$FILEPATH" 2>/dev/null || true
    echo "ERROR: Git commit failed. Override not applied." >&2
    exit 1
fi
```

**Issue:** If the working tree has other staged or unstaged changes (e.g., user is mid-refactor), `git restore` only unstages the routing-overrides.json file but does NOT remove the working tree changes written by the apply function. The file remains modified in the working tree, creating a state mismatch.

**Impact:**
- **Partial state:** File is modified but not committed, override is not in DB
- **Confusion:** Next session sees dirty working tree, re-applies override, or commits unintended changes
- **Audit trail loss:** No way to tell if the file was intentionally edited or left dirty by a failed apply

**Likelihood:** Low in typical usage (interspect runs in clean sessions), but higher in monorepo dev workflows.

**Fix:**

**Option 1:** Stash and restore on failure:
```bash
_interspect_flock_git bash -c '
    set -e
    # Check for dirty tree
    if ! git diff-index --quiet HEAD -- "$FILEPATH" 2>/dev/null; then
        echo "WARN: ${FILEPATH} has uncommitted changes. Stashing before apply." >&2
        git stash push -m "interspect pre-apply stash" "$FILEPATH"
        STASHED=1
    else
        STASHED=0
    fi

    # ... read, modify, write, add ...

    if ! git commit -m "..."; then
        # Restore from stash if we stashed earlier
        if (( STASHED == 1 )); then
            git stash pop
        else
            git restore --source=HEAD "$FILEPATH"
        fi
        exit 1
    fi

    # Drop stash on success
    if (( STASHED == 1 )); then
        git stash drop
    fi
'
```

**Option 2:** Validate clean tree before applying (fail fast):
```bash
if ! git diff-index --quiet HEAD -- "$filepath"; then
    echo "ERROR: ${filepath} has uncommitted changes. Commit or stash before applying overrides." >&2
    return 1
fi
```

**Recommendation:** Use Option 2 (fail fast). Document in AGENTS.md that interspect requires a clean working tree for the target file.

---

### P3 | SEC-04 | Evidence destruction on malformed JSON

**Location:** Task 2, lines 201-206 (flux-drive SKILL.md)

**Evidence:**
```markdown
a. Parse JSON. If malformed, log `"WARNING: routing-overrides.json malformed, ignoring overrides"` in triage output, move file to `.claude/routing-overrides.json.corrupted`, and continue with no exclusions.
```

**Issue:** Moving the malformed file to `.corrupted` **destroys the only evidence** of what the file contained before corruption. If the corruption was caused by a write race, filesystem error, or malicious edit, the original content is lost. No way to recover or debug.

**Impact:**
- **Loss of audit trail:** Cannot determine which overrides were active before corruption
- **Irreversible data loss:** User cannot recover manually-written overrides
- **Debugging difficulty:** No way to reproduce or investigate the corruption

**Likelihood:** Low in normal operation, but higher during filesystem failures, disk full errors, or concurrent writes.

**Fix:**

**Option 1:** Copy instead of move, with timestamp:
```markdown
a. Parse JSON. If malformed:
   - Copy to `.claude/routing-overrides.json.corrupted-$(date +%s)`
   - Log `"WARNING: routing-overrides.json malformed, backup saved to .corrupted-{timestamp}. Ignoring overrides."`
   - Continue with no exclusions
```

**Option 2:** Leave original in place, warn user:
```markdown
a. Parse JSON. If malformed:
   - Log `"ERROR: routing-overrides.json is malformed JSON. Fix manually or remove to reset. Ignoring overrides."`
   - Continue with no exclusions (do NOT move or delete)
```

**Recommendation:** Use Option 2 (leave in place). This is read-only code (consumer), not write-path, so leaving a malformed file doesn't break anything. User can fix or remove it manually.

---

### P3 | OPS-04 | Test environment hardcoded path

**Location:** Task 7, line 774

**Evidence:**
```bash
# Source lib
INTERSPECT_LIB="$(find /root/projects/Interverse/hub/clavain -name lib-interspect.sh -type f | head -1)"
source "$INTERSPECT_LIB"
```

**Issue:** Test hardcodes `/root/projects/Interverse/` path, which only exists on the ethics-gradient server. CI, other developers, or different install locations will fail.

**Impact:**
- **CI failure:** Tests cannot run in GitHub Actions or other CI environments
- **Local dev failure:** Developers cloning to different paths cannot run tests
- **Brittleness:** Breaks if monorepo is renamed or moved

**Likelihood:** High for any CI or multi-developer usage.

**Fix:**

**Option 1:** Search relative to test file location:
```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INTERSPECT_LIB="$(cd "$SCRIPT_DIR/../../hooks" && pwd)/lib-interspect.sh"
source "$INTERSPECT_LIB"
```

**Option 2:** Use `git rev-parse` to find repo root:
```bash
REPO_ROOT="$(git rev-parse --show-toplevel)"
INTERSPECT_LIB="$REPO_ROOT/hub/clavain/hooks/lib-interspect.sh"
source "$INTERSPECT_LIB"
```

**Recommendation:** Use Option 2 (git-based). This works in CI, local dev, and monorepo installs. Fall back to Option 1 if outside a git repo.

---

## Improvements

### 1. Add validation for cross-cutting agent exclusions

**Current behavior:** Task 3 shows a warning when proposing exclusion of cross-cutting agents (fd-architecture, fd-quality, fd-safety, fd-correctness), but the warning is only cosmetic. User can accept the proposal without additional confirmation.

**Risk:** User accidentally excludes safety/security agents by clicking "Accept" quickly, removing critical coverage.

**Improvement:**
- Require **two-step confirmation** for cross-cutting agents:
  1. First prompt: "⚠️ This agent provides security/structural coverage. Are you sure?"
  2. Second prompt: "Type 'EXCLUDE' to confirm removal of {agent}."
- Reject proposals for cross-cutting agents if less than 10 override events (too small sample size for high-impact decision).
- Log cross-cutting exclusions to a separate audit log for review.

### 2. Add monitoring for orphaned overrides

**Current behavior:** If an agent is removed from the flux-drive roster (e.g., renamed, deleted, merged into another agent), overrides for that agent remain in `routing-overrides.json` but have no effect. User has no visibility into this.

**Risk:** Configuration drift — user thinks an agent is excluded but it doesn't exist anymore.

**Improvement:**
- In `/interspect:status`, flag orphaned overrides: "⚠️ Override for {agent} targets unknown agent (agent not in current roster)."
- In flux-drive Step 1.2a.0, log unknown agent names: `"WARNING: Routing override for unknown agent {name} — check spelling or remove entry."`
- Add `/interspect:prune` command to remove orphaned overrides automatically.

### 3. Canary monitoring should fail safe

**Current behavior:** Task 4 line 483-486 shows canary insert failure is logged as a warning but doesn't block override application:
```bash
if ! sqlite3 "$db" "INSERT INTO canary ..."; then
    echo "WARN: Canary monitoring failed — override active but unmonitored." >&2
fi
```

**Risk:** Override is applied but never reviewed (canary window tracking is broken). Silent degradation of monitoring coverage.

**Improvement:**
- Make canary insert failures **block override application**:
```bash
if ! sqlite3 "$db" "INSERT INTO canary ..."; then
    echo "ERROR: Canary monitoring failed. Override not applied." >&2
    return 1
fi
```
- Or require user confirmation: "Canary monitoring failed. Apply override without monitoring? [y/N]"

### 4. Document rollback feasibility for routing overrides

**Current behavior:** Plan includes `/interspect:revert` but doesn't explain what happens to reviews that already ran with the override active.

**Risk:** User assumes revert "undoes" the exclusion retroactively, but past triage outputs cannot be re-run without manual work.

**Improvement (documentation):**
- In AGENTS.md, clarify:
  - Revert restores the agent to the roster **for future reviews only**
  - Past triage outputs (when agent was excluded) are **not re-run automatically**
  - To re-review past work: re-run `/flux-drive` on the artifacts with the agent restored
- Add `--since <date>` flag to `/flux-drive` for re-reviewing artifacts after a revert

### 5. Add rate limiting for override applications

**Current behavior:** No limit on how many overrides can be applied per session or per time window.

**Risk:** Runaway automation (e.g., buggy agent accepts all proposals) could exclude all agents from flux-drive, disabling review coverage entirely.

**Improvement:**
- Add config in `confidence.json`: `"max_overrides_per_session": 3`
- Track overrides applied in current session (in-memory counter)
- Reject application if limit exceeded: "Override limit reached (3 per session). Review existing overrides via `/interspect:status` before applying more."

---

## Residual Risks

### 1. Manual override abuse

**Risk:** Users can hand-edit `.claude/routing-overrides.json` to exclude arbitrary agents without evidence. This bypasses interspect's threshold checks and canary monitoring.

**Mitigation:** Document in AGENTS.md that manual overrides are allowed but should be marked with `"created_by": "human"` and reviewed periodically. Flux-drive should log when manual overrides (no matching canary record) are active.

**Accept risk:** Manual overrides are a documented escape hatch for urgent cases (e.g., broken agent deployment). Monitoring via `/interspect:status` provides visibility.

### 2. Flock timeout during git hooks

**Risk:** If a pre-commit hook hangs or prompts for input, the flock lock is held indefinitely. No automatic timeout in the plan.

**Mitigation:** Add `flock -w 30` timeout (see OPS-02 fix). Document in AGENTS.md that git hooks should be non-interactive for interspect to work reliably.

**Accept risk:** Blocking hooks are a misconfiguration, not a security issue. Timeout provides a safety net but doesn't prevent the root cause.

### 3. Evidence table growth

**Risk:** Evidence table grows unbounded (one row per override event). Large tables slow down eligibility queries and classification.

**Mitigation:** Add TTL or archival for evidence older than 90 days. Or add index on `(source, event, ts)` to speed up queries.

**Accept risk:** Growth is linear with usage, not exponential. Indexing (already in plan) should keep queries fast. Archival is a future optimization.

---

## Critical Path for Approval

To approve this plan, the following P1 issues MUST be fixed:

1. **SEC-01:** Escape `reason`, `evidence_ids`, `created_by` before interpolation into bash subprocess (use heredoc or temp file)
2. **SEC-02:** Escape `agent` in all SQL queries (use `_interspect_sql_escape()` helper or parameterized queries)

P2 and P3 issues should be fixed before merging but do not block plan approval. They can be addressed in implementation.

Recommended security checklist before merging code:
- [ ] Grep for `sqlite3.*WHERE.*\$` to find unescaped SQL interpolations
- [ ] Grep for `bash -c '.*\$` to find unescaped shell interpolations
- [ ] Test with attacker-controlled input: agent name `'; DROP TABLE evidence; --`, reason `"; rm -rf /tmp/test; echo "`
- [ ] Run bats tests with `set -x` to verify escaping in actual execution
- [ ] Review all uses of `_interspect_flock_git` for blocking operations inside lock

---

## Deployment Recommendations

### Pre-deploy checks:
1. Verify interflux plugin is installed and cache path exists (`~/.claude/plugins/cache/interagency-marketplace/interflux/`)
2. Check that flux-drive agent roster is stable (no renames/deletions in flight)
3. Back up existing `.claude/routing-overrides.json` files across projects (if any manual overrides exist)
4. Run shell tests in both monorepo and installed-plugin modes

### Rollout strategy:
1. **Phase 1:** Deploy flux-drive consumer (Task 2) first — safe to read a file that doesn't exist yet
2. **Phase 2:** Deploy clavain producer (Tasks 1, 3, 4, 5) — can now create overrides
3. **Phase 3:** Enable interspect Tier 2 in `/interspect` command (Task 6, 9)
4. Monitor for:
   - Malformed JSON warnings in flux-drive output
   - Flock timeout errors in interspect commands
   - Orphaned override warnings in `/interspect:status`

### Rollback plan:
- **Code rollback:** Revert Tasks 3-9 (producer side). Flux-drive consumer (Task 2) is safe to leave deployed (degrades to no-op if file missing).
- **Data rollback:** Remove `.claude/routing-overrides.json` files manually or via script. No DB schema changes (blacklist table is additive).
- **Irreversible:** Evidence and canary records in DB persist after rollback. Acceptable — they're append-only audit logs.

### Post-deploy verification:
1. Create a test override via `/interspect:propose` in a sandbox project
2. Verify flux-drive triage output shows "N agents excluded by routing overrides: [agent-name]"
3. Run `/interspect:status` and verify override appears with canary monitoring
4. Run `/interspect:revert` and verify agent is restored to roster
5. Check `.git/log` for interspect commit messages with correct format

---

## Conclusion

This plan is architecturally sound and implements a needed feature (routing override management) with good operational safeguards (flock serialization, canary monitoring, blacklist). However, **two critical injection vulnerabilities** (shell and SQL) must be fixed before merging. These are not hypothetical — the attack vectors are straightforward and exploitable with user-controlled input.

Once SEC-01 and SEC-02 are addressed, the remaining issues (OPS-01 through OPS-04, SEC-03, SEC-04) are lower-priority hardening improvements that can be fixed during implementation review.

**Recommendation:** Fix P1 issues, document residual risks, and proceed with implementation. Schedule a follow-up code review after Task 4 is implemented to verify injection fixes are correct.
