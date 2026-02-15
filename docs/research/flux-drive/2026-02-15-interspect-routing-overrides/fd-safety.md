# Flux-Drive Safety Review: Interspect Routing Overrides (Type 2)

**Reviewer:** fd-safety (Flux-drive Safety Reviewer)
**Date:** 2026-02-15
**PRD:** `/tmp/flux-drive-2026-02-15-interspect-routing-overrides-1771188763.md`

---

## Findings Index

| Severity | ID | Section | Title |
|----------|----|---------|----|
| P1 | S1 | F3 | Routing override can disable safety agents without explicit warning |
| P1 | S2 | F1 | No consumer validation that routing-overrides.json was created by allowed producer |
| P2 | S3 | F2 | Evidence-based proposal can be biased by attack traffic during collection |
| P2 | S4 | F3 | Git commit failure leaves override in working tree without canary |
| P2 | S5 | Deployment | No verification that excluded agents aren't masking real defects |
| P3 | S6 | F1 | Malformed JSON graceful degradation may hide persistent corruption |
| P3 | S7 | F5 | Human overrides bypass all canary monitoring indefinitely |

**Verdict:** needs-changes

---

## Summary

The PRD describes a mechanism for interspect to propose and apply agent exclusions based on evidence patterns, with routing-overrides.json as the contract between producer (clavain/interspect) and consumer (interflux/flux-drive). The safety model depends on:
1. Protected paths enforcement (interspect can only write to `.claude/routing-overrides.json`)
2. Propose-mode user approval gate
3. Canary monitoring for 20 uses post-application
4. Evidence quality (counting rules: ≥3 sessions, ≥2 projects, ≥N events)

**Primary risks:** The cross-cutting agent exclusion warning (F1) is passive and does not block. An attacker (or well-meaning user) accepting an interspect proposal to exclude fd-safety from a project removes a critical security boundary. The canary monitoring does not measure "defects that would have been caught" — it measures downstream quality via Galiana integration, which is deferred and not a hard dependency. The file format has no integrity verification, so a compromised consumer plugin or malicious `.claude/` file edit could exclude safety agents without going through the evidence+proposal flow.

**Deployment risks:** The consumer (flux-drive) reads the file during triage but has no contract version enforcement beyond "version: 1" — a future breaking schema change could cause silent misinterpretation. Git commit failure leaves the override file in an uncommitted state but applied to the next flux-drive run, creating state drift. Rollback depends on manual `/interspect:revert` and does not auto-trigger even when canary shows degradation.

---

## Issues Found

### P1-S1: Routing override can disable safety agents without explicit warning

**Location:** F1 acceptance criteria

**Evidence:**
```
F1: "Cross-cutting agent exclusions (fd-architecture, fd-quality) trigger a warning in the triage log"
Brainstorm: "fd-architecture and fd-quality are excluded from routing overrides unless explicitly marked as overridable... but the file format allows it (no schema restriction) but the triage consumer should warn"
```

**Impact:**
- A user approving an interspect proposal can exclude fd-safety or fd-architecture from a public-facing service project
- The warning is passive (logged to triage output) and does not require explicit acknowledgment
- An attacker with write access to `.claude/routing-overrides.json` (e.g., via compromised local session) can exclude safety agents entirely
- The canary monitoring baseline for a safety agent may not exist (agent runs infrequently), so the canary expires with "insufficient data" and the exclusion persists

**Why this matters to threat model:**
- interspect's threat model (per design doc §3.8) assumes protected paths prevent modification of safety-critical logic (hooks, confidence gates, agent prompts)
- However, excluding fd-safety from a project via routing override has the same effect as deleting the agent — the boundary is removed
- The design doc notes "Which inputs are untrusted?" — if the project under review processes external input (web API, file upload, network protocol), excluding fd-safety removes validation checks for injection/escaping/auth bugs

**Why the proposed mitigation is insufficient:**
- The PRD lists "cross-cutting agent exclusion warning" as acceptance criteria but does not require blocking or explicit opt-in
- The warning is buried in triage logs, which are large multi-agent outputs
- No enforcement mechanism — warning can be ignored or missed

**Recommendation:**
- **Hard block:** Prevent routing overrides for agents tagged as `safety_critical: true` in agent metadata (fd-safety, fd-architecture)
- **Explicit opt-in:** If safety-critical exclusions must be allowed, require a separate confirmation step: "This override removes security coverage. Type 'exclude fd-safety' to confirm."
- **Deployment gate:** Before accepting a safety-critical exclusion, require the user to describe what alternative verification they will use (e.g., "project is internal-only and does not handle auth")

**Residual risk after mitigation:** Human can still explicitly opt to exclude safety agents. Operational discipline required.

---

### P1-S2: No consumer validation that routing-overrides.json was created by allowed producer

**Location:** F1 (file format), consumer integration

**Evidence:**
```json
{
  "created_by": "interspect"
}
```

The consumer (flux-drive Step 1.2a.0) is described as:
```
- Check if .claude/routing-overrides.json exists
- If yes, parse and remove excluded agents from the candidate pool
```

**Impact:**
- Any process or human with write access to `.claude/routing-overrides.json` can exclude agents
- The `created_by` field is not cryptographically verified — a malicious edit can set `"created_by": "interspect"` to bypass human-override detection
- The protected paths manifest only constrains what **interspect** can modify; it does not prevent other sources (compromised plugins, user edits, external scripts) from writing to `.claude/`

**Attack scenario:**
1. Attacker gains write access to project `.claude/` directory (e.g., via malicious Claude Code plugin, shell injection in a hook, or direct filesystem access)
2. Attacker writes routing-overrides.json excluding fd-safety and fd-architecture
3. Next flux-drive run silently excludes safety agents
4. Attacker introduces malicious code that would have been flagged by excluded agents
5. No canary monitoring (canary table has no baseline for this override — it was never created via interspect pipeline)

**Why the proposed mitigation is insufficient:**
- The design doc §3.8 discusses protected paths and privilege separation (Phase 3) but only for interspect's own modifications
- The consumer has no enforcement — it trusts the file unconditionally
- The PRD says "malformed file does not break triage" but does not address forged/malicious well-formed files

**Recommendation:**
- **File integrity:** Store a hash of the override entry in the interspect modifications table and validate it at consumer read time
- **Require canary record:** flux-drive should check that each `"created_by": "interspect"` override has a corresponding canary record in `interspect.db`; if missing, log error and treat as untrusted human override
- **Signed overrides (Phase 2):** Use a signing key stored in protected interspect directory to sign override entries; consumer validates signature before applying
- **Least-surprise fallback:** If validation fails, log error and **skip the override** (do not exclude the agent) rather than proceeding silently

**Residual risk after mitigation:** Attacker with write access to both `.claude/routing-overrides.json` and `.clavain/interspect/interspect.db` can forge both. File-system level isolation (privilege separation) required for full defense.

---

### P2-S3: Evidence-based proposal can be biased by attack traffic during collection

**Location:** F2 (propose flow), evidence collection

**Evidence:**
From design doc §3.1.2:
```
Evidence fields that contain user-controlled strings are sanitized before insertion:
1. Strip control characters and ANSI escapes
2. Truncate strings to 500 chars
3. Reject entries with embedded instruction-like patterns
4. Tag entries with hook_id proving origin from a legitimate interspect hook
```

From PRD F2:
```
Routing-eligible pattern detection: ≥80% of events for the pattern have override_reason: agent_wrong
```

**Impact:**
- If an attacker can cause fd-safety to produce many false positives (e.g., by submitting crafted pull requests or file changes that look like vulnerabilities but aren't), a human repeatedly overriding those findings creates evidence for `agent_wrong`
- Once the counting-rule threshold is met (≥3 sessions, ≥2 projects, ≥5 events), interspect proposes excluding fd-safety
- The evidence is legitimate (real override events) but strategically created by an attacker to manipulate the improvement system

**Attack scenario:**
1. Attacker submits PRs across multiple projects with code patterns that trigger fd-safety false positives (e.g., parameterized SQL queries flagged as SQL injection)
2. Developer overrides findings with `/interspect:correction fd-safety "parameterized query, not an injection"`
3. Interspect accumulates `agent_wrong` evidence across sessions and projects
4. Interspect proposes excluding fd-safety from the project
5. Developer accepts (the overrides were real), not realizing the pattern was induced
6. Attacker now submits real SQL injection; fd-safety is excluded and does not flag it

**Why the proposed mitigation is insufficient:**
- Sanitization (§3.1.2) prevents prompt injection but does not prevent legitimate-looking evidence from biased inputs
- The evidence quality gate (≥3 sessions, ≥2 projects) makes the attack harder but not impossible for a persistent attacker
- No anomaly detection for "sudden spike in overrides for this agent"

**Recommendation:**
- **Baseline deviation alert:** Before proposing an exclusion, check if the override rate for this agent spiked recently (e.g., >2x the historical rate within the last 30 days). If yes, flag for human review: "Evidence pattern is recent — may be temporary or induced."
- **Cross-project correlation:** If the same evidence pattern appears across multiple projects within a short time window (e.g., 7 days), flag as "coordinated pattern — manual review recommended"
- **Diversity requirement:** Require evidence from ≥3 different human users (tracked via session metadata or git author) to prevent a single compromised account from creating the pattern
- **Canary pre-check:** Before proposing exclusion, show the user a projection: "If fd-safety had been excluded in the last 20 runs, these N findings would not have been surfaced. Proceed?"

**Residual risk after mitigation:** Sophisticated attacker with access to multiple accounts and long time horizon can still induce the pattern. Detection requires anomaly monitoring, not just static thresholds.

---

### P2-S4: Git commit failure leaves override in working tree without canary

**Location:** F3 (apply + commit), atomicity

**Evidence:**
From PRD F3 acceptance criteria:
```
- Atomic: if commit fails, the override is not left in a partial state
```

From design doc §3.4:
```
4. Apply — ... atomic git commit with structured message (§3.9), serialized via flock
5. Monitor — Insert canary record in SQLite
```

**Issue:**
The PRD says "atomic: if commit fails, the override is not left in partial state" but does not specify **how** atomicity is enforced. The typical flow is:

1. Write routing-overrides.json to working tree
2. Insert canary record to interspect.db
3. Git add + commit via `_interspect_flock_git`
4. If commit fails (e.g., flock timeout, pre-commit hook rejection, git error), rollback?

**Impact:**
If the commit fails after step 1 or 2:
- The override file exists in `.claude/` and will be read by the next flux-drive run
- The canary record may or may not exist (depends on failure point)
- If canary exists but commit failed, the canary's `commit_sha` field is invalid
- If canary does not exist, the override is applied with no monitoring

**Why this matters to deployment:**
- Pre-commit hooks can fail for many reasons (network timeout, linter failure, Git LFS issues)
- The user may not notice the commit failed (especially if running in background or non-interactive mode)
- Next flux-drive run uses the uncommitted override, changing agent behavior without a revertible commit
- Manual recovery required to detect and fix

**Recommendation:**
- **Write-commit-activate pattern:** Write override to a staging location (`.clavain/interspect/staging/routing-overrides-pending.json`), commit that file, then atomically move/merge into `.claude/routing-overrides.json` in a post-commit hook
- **Rollback on failure:** Wrap the apply step in a function that reverts working tree changes if commit fails:
  ```bash
  apply_override() {
    local backup="/tmp/routing-overrides-backup-$$.json"
    cp .claude/routing-overrides.json "$backup" 2>/dev/null || true

    write_override_to_file || return 1
    insert_canary_record || { restore_from_backup; return 1; }

    if ! _interspect_flock_git git add .claude/routing-overrides.json; then
      restore_from_backup
      delete_canary_record
      return 1
    fi

    if ! _interspect_flock_git git commit -m "[interspect] ..."; then
      restore_from_backup
      delete_canary_record
      return 1
    fi
  }
  ```
- **Canary commit_sha validation:** On canary verdict computation, check that the commit exists and touches the expected file. If not, invalidate canary with status `expired_commit_missing`.

**Residual risk after mitigation:** Multi-step rollback can fail partway (e.g., canary delete fails). Requires transactional SQLite or compensating cleanup on session start.

---

### P2-S5: No verification that excluded agents aren't masking real defects

**Location:** Deployment, canary monitoring, rollback

**Evidence:**
From PRD Open Questions:
```
1. Canary metrics for routing exclusions. The excluded agent produces no findings (it's not running), so override rate doesn't apply. Best candidate: Galiana's defect_escape_rate — but Galiana integration is a separate bead. For v1, canary monitors session-level quality metrics as a proxy.
```

From design doc §3.6:
```
Recall cross-check: Check Galiana's defect_escape_rate for the affected agent's domain. If escape rate increased during the canary window, escalate alert severity — but still do not auto-revert.
```

**Issue:**
The canary monitoring for routing exclusions is explicitly deferred to "session-level quality metrics as a proxy" because Galiana integration is a separate bead. This means:
- V1 ships without a way to detect that excluding an agent caused real defects to slip through
- The canary may never trigger even if the exclusion is harmful (no baseline to compare, no metrics to measure)
- The design says "escalate alert severity" but Galiana integration is not a hard dependency

**Impact:**
- User accepts a routing override based on evidence (fd-game-design flagged zero relevant issues in 8 sessions)
- The override is valid for the sessions observed, but fd-game-design would have caught a defect in session 9
- Session 9 runs without fd-game-design, defect is not flagged
- Defect ships to production or merges to main
- No canary alert because there's no recall metric

**Why this matters to deployment:**
- Routing overrides are irreversible by design until manually reverted
- Without recall measurement, harmful exclusions persist indefinitely
- User has no signal that the exclusion was a mistake until a production incident

**Recommendation:**
- **Block v1 routing overrides on high-risk agents:** Do not allow exclusion of agents that cover security, correctness, or data-integrity domains until recall metrics exist
- **Manual recall check before acceptance:** When proposing an exclusion, show the user the agent's last 20 findings and ask: "Review these findings. If this agent had been excluded, would any real issues have been missed?"
- **Post-deployment audit:** After N sessions with an exclusion active, run the excluded agent in shadow mode (non-blocking) and compare findings against what was shipped. If shadow finds defects, alert.
- **Canary fallback for v1:** Track "number of findings from ALL agents decreased by >50% after exclusion" as a proxy — if total findings drop drastically, the exclusion may have removed useful signal (not just noise).

**Residual risk after mitigation:** Shadow testing adds latency and token cost. Manual recall check depends on human judgment. Full defense requires Galiana integration (out of scope for PRD v1).

---

### P3-S6: Malformed JSON graceful degradation may hide persistent corruption

**Location:** F1 acceptance criteria

**Evidence:**
```
- Malformed/missing file does not break triage (graceful degradation)
```

**Issue:**
Graceful degradation is correct for **missing** files but risky for **malformed** files. If routing-overrides.json exists but is corrupted (invalid JSON, truncated write, filesystem corruption), flux-drive proceeds without overrides and logs a warning. However:
- The warning may not be visible to the user (buried in agent output)
- The corruption persists across runs (no auto-repair)
- User may not realize overrides are not being applied

**Impact:**
- User approved exclusion of fd-game-design
- File write succeeds but is interrupted (power loss, kill -9, filesystem full)
- File is left with trailing garbage: `{"version":1,"overrides":[{...}]}��`
- Every flux-drive run logs "malformed routing-overrides.json, proceeding without overrides"
- fd-game-design runs on every review (user expects it to be excluded)
- User submits feedback that interspect isn't working; debugging friction

**Recommendation:**
- **Validate on write:** After writing routing-overrides.json, immediately read it back and parse to confirm validity. If invalid, delete the file and error out (do not commit).
- **Repair on read:** If flux-drive detects malformed JSON, move the file to `.claude/routing-overrides.json.corrupted` and log an error directing the user to `/interspect:status` for recovery.
- **Schema validation:** Use a JSON schema to validate structure beyond parse-ability (e.g., required fields, allowed values for `action`).
- **Visible error:** If corruption is detected, inject a session-start warning (same mechanism as "Interspect: 2 agents adapted") so the user sees it immediately.

**Residual risk after mitigation:** Filesystem-level corruption (bit flips, silent disk errors) cannot be detected without checksums. Low-probability risk.

---

### P3-S7: Human overrides bypass all canary monitoring indefinitely

**Location:** F5 (manual override support)

**Evidence:**
From PRD F5:
```
- Overrides with "created_by": "human" are never modified by interspect
- Human overrides are never monitored by canary
```

**Issue:**
A human manually creating a routing override (editing `.claude/routing-overrides.json` directly) bypasses the evidence collection, counting-rule gate, and canary monitoring. This is by design (human intent takes precedence) but creates a safety gap:
- Human excludes fd-safety based on a misunderstanding (e.g., "my project doesn't use SQL")
- No baseline exists, no canary monitoring, no alert if quality degrades
- The override persists indefinitely unless human manually revisits

**Impact:**
- Human creates override excluding fd-safety from a web API project
- Project introduces SQL query feature 6 months later
- fd-safety would have flagged SQL injection, but it's excluded
- Defect ships to production
- No mechanism to detect the override is now harmful

**Why this is lower priority (P3):**
- This is an explicit human decision, not an automation failure
- User has full control and visibility (they edited the file)
- Interspect's role is improvement automation, not enforcement of human decisions

**Recommendation:**
- **Periodic review prompt:** On session start, if human overrides exist and are >90 days old, inject a reminder: "Manual routing overrides active. Run `/interspect:review-overrides` to confirm they're still relevant."
- **Shadow testing opt-in:** Allow human to flag a manual override as `monitor: true` to enable canary-like monitoring even for human overrides
- **Documentation:** AGENTS.md should warn that manual overrides are permanent and unmonitored

**Residual risk after mitigation:** Human can ignore prompts. Operational discipline required.

---

## Improvements

### I1: Add contract version enforcement to consumer

**Rationale:** The file format has `"version": 1` but the PRD does not specify what the consumer does if it encounters `"version": 2` or an unknown schema. Future schema changes could introduce fields with safety implications (e.g., `"override_priority"` that affects cross-cutting agents). Without version enforcement, old consumers may misinterpret new schemas.

**Recommendation:**
- flux-drive Step 1.2a.0 should check the `version` field and error if `version > 1`
- Error message should direct user to upgrade interflux plugin
- Schema versioning should follow semver: major version bump = breaking change

---

### I2: Add dry-run mode to routing override proposal

**Rationale:** Users may want to see what would happen if they accepted an exclusion before committing to it. The current flow is binary (accept/reject) with no preview.

**Recommendation:**
- When presenting routing override proposal via AskUserQuestion, add a third option: `[Show impact]`
- If selected, run flux-drive triage on the current document with the proposed exclusion active (shadow mode) and show the difference in agent roster
- User can then make an informed decision

---

### I3: Log routing override application to a separate audit file

**Rationale:** Git commits are the primary audit trail, but they require `git log` access and may be rebased/squashed. An append-only audit log provides a second source of truth.

**Recommendation:**
- On successful override application, append to `.clavain/interspect/audit/routing-overrides.log`:
  ```
  2026-02-15T14:32:00Z | apply | fd-game-design | exclude | commit:abc123 | evidence:[12,15,23] | session:xyz
  ```
- On revert:
  ```
  2026-02-16T09:00:00Z | revert | fd-game-design | exclude | commit:def456 | reason:canary-alert | session:xyz
  ```
- Log is never modified by interspect, only appended (append-only semantics)

---

### I4: Add consumer-side telemetry for excluded agent impact

**Rationale:** Canary monitoring in interspect.db is producer-side. The consumer (flux-drive) can also collect metrics: how many agents were excluded per run, how long triage took with exclusions active, etc. This provides cross-plugin validation.

**Recommendation:**
- flux-drive logs excluded agent count to a telemetry file: `.claude/flux-drive-triage.log`
- Format: `timestamp | agents_excluded | agents_run | triage_duration_ms`
- Interflux can use this to correlate exclusions with triage performance changes
- If interflux and interspect disagree on active overrides (e.g., file was manually edited), log a warning

---

### I5: Require evidence diversity before proposing safety-critical exclusions

**Rationale:** Issue S3 (attack traffic bias) is higher risk for safety-critical agents (fd-safety, fd-architecture). Raising the evidence bar for these agents reduces attack surface.

**Recommendation:**
- Tag agents as `safety_critical: true` in agent metadata
- For safety-critical agents, require ≥5 sessions (not 3), ≥3 projects (not 2), and ≥10 events (not 5)
- Require evidence from ≥3 different users (tracked via session metadata)
- Document in AGENTS.md that safety-critical agents have higher exclusion thresholds

---

## Domain-Specific Context

**Threat model for claude-code-plugin domain:**

1. **Plugin hook execution:** Interspect's propose and apply logic runs in PostToolUse hooks (triggered by `/interspect` command). Hooks execute user-provided bash scripts in the user's environment. The protected paths manifest is enforced by a pre-commit hook, which can be bypassed via `git commit --no-verify` or direct `.git/` manipulation.

2. **Cross-plugin file access:** The routing-overrides.json file is in `.claude/`, which is writable by any Claude Code plugin (not just interspect). A malicious plugin could write to this file to exclude safety agents from another plugin's agent roster.

3. **User environment privileges:** Claude Code runs with the user's filesystem permissions. If the user is `root` or has write access to protected system directories, interspect modifications could affect global state (though the PRD limits modifications to `.claude/` and `.clavain/` directories).

4. **Evidence injection via tool arguments:** The evidence collection hook reads session_id, agent names, and override reasons from user-provided tool calls (e.g., `/interspect:correction <agent> <reason>`). The sanitization function (lib-interspect.sh `_interspect_sanitize`) strips control chars and rejects instruction-like patterns, but does not prevent valid-looking evidence from adversarial inputs.

**Protected paths validation:** The PRD states that `.claude/routing-overrides.json` is in the modification allow-list (already confirmed by reading `/root/projects/Interverse/hub/clavain/.clavain/interspect/protected-paths.json`). The validation function `_interspect_validate_target()` checks both the protected list (hard block) and the allow-list (must match). However, this validation only applies to interspect's own writes — it does not prevent other sources from writing to `.claude/`.

**Safety-relevant agents:** fd-safety, fd-architecture, fd-correctness are safety-relevant. Excluding fd-safety from a project that handles untrusted input (web API, file upload, network protocol) removes checks for injection, escaping, and auth boundary bugs. Excluding fd-architecture removes checks for state management, error handling, and concurrency issues. Excluding fd-correctness removes logic and data-flow validation.

**Routing override usage in flux-drive:** Flux-drive Step 1.2a (file input) and Step 1.0 (directory input) do not currently implement the routing override reader. The PRD adds Step 1.2a.0 as a new pre-filter. The step runs before domain detection and scoring, so excluded agents are never scored and never appear in the agent roster table.

---

<!-- flux-drive:complete -->
