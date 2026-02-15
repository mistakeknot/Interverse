### Findings Index

- P0 | C1 | F3 | Race condition: JSON read-modify-write without file lock
- P0 | C2 | F3 | Partial state on commit failure breaks atomicity requirement
- P1 | C3 | F1 | Malformed JSON breaks triage instead of graceful degradation
- P1 | C4 | F2 | Proposal race: concurrent sessions can propose same exclusion
- P2 | C5 | F3 | Missing validation: routing override can exclude non-existent agent
- P2 | C6 | F2 | Evidence-to-proposal window: pattern can change under you
- P2 | C7 | F4 | Revert idempotency check missing for already-removed entries
- P3 | I1 | F1 | Cross-cutting agent warning logic duplicates triage exclusion logic
- P3 | I2 | F3 | Canary creation failure leaves orphaned git commit

**Verdict:** needs-changes

Critical atomicity and concurrency issues in F3 (apply+commit flow). The PRD states "atomic: if commit fails, the override is not left in a partial state" but provides no mechanism to achieve this. JSON file operations race without synchronization.

### Summary

The routing override system extends interspect's modification pipeline to configure flux-drive triage. The consumer side (F1) is straightforward read-only logic with minor error handling gaps. The producer side (F2, F3) has **two critical correctness failures**: (1) no file-level locking for the JSON read-modify-write operation, allowing concurrent sessions to corrupt or lose overrides; (2) no atomic commit mechanism — if git commit fails after writing the file, the override persists uncommitted, violating the stated atomicity requirement.

Both issues already have solutions in the codebase: `_interspect_flock_git` for serialization (lib-interspect.sh:320-342) and flock-wrapped commit patterns from interspect design §3.4. The PRD simply doesn't reference them.

Additional findings: proposal-time races (concurrent sessions proposing the same exclusion), missing schema validation (can exclude non-existent agents), and incomplete revert idempotency for manual file edits.

### Issues Found

#### P0-C1: Race condition: JSON read-modify-write without file lock (F3)

**Location:** F3 acceptance criteria line 44-45: "Writes/merges into `.claude/routing-overrides.json` (append if file exists, create if new)"

**Failure scenario:**

Session A and B both detect the same pattern (fd-game-design irrelevant in a Go backend project) at T=0.

```
T=1  Session A: jq reads routing-overrides.json → [ ]
T=2  Session B: jq reads routing-overrides.json → [ ]
T=3  Session A: jq adds {agent: fd-game-design, ...} → writes temp file
T=4  Session B: jq adds {agent: fd-game-design, ...} → writes temp file
T=5  Session A: mv temp → routing-overrides.json
T=6  Session B: mv temp → routing-overrides.json (clobbers A's write)
```

**Result:** Session A's override is lost. The file contains only B's entry. This is the exact race pattern identified in interspect design §3.1 (SQLite rationale) — atomic rename without file-level serialization loses concurrent writes.

**Evidence from codebase:**

lib-interspect.sh already provides `_interspect_flock_git` (lines 320-342) specifically for this:

```bash
_interspect_flock_git() {
    local lockfile="${lockdir}/.git-lock"
    if ! flock -w "$_INTERSPECT_GIT_LOCK_TIMEOUT" 9; then
        echo "ERROR: interspect git lock timeout"
        return 1
    fi
    "$@"
} 9>"$lockfile"
```

Design doc §3.4 states: "All git add/commit operations use `flock .clavain/interspect/.git-lock` to prevent concurrent session races."

**Required fix:**

Wrap the entire read-modify-write sequence for routing-overrides.json in `_interspect_flock_git`:

```bash
_interspect_flock_git bash -c '
    current=$(jq . .claude/routing-overrides.json 2>/dev/null || echo "[]")
    new=$(echo "$current" | jq ". += [{agent: \"$agent\", ...}]")
    echo "$new" | jq . > .claude/routing-overrides.json
'
```

This serializes all JSON operations on the file across concurrent sessions (same lock as git commits).

**Why this matters:** Routing overrides directly control which agents run in flux-drive. Lost overrides mean excluded agents re-appear in triage, re-triggering the irrelevance that caused the exclusion — wasting tokens and re-introducing noise. If the same pattern is detected by multiple sessions within the same day (common during active development), this race is **deterministic**, not probabilistic.

---

#### P0-C2: Partial state on commit failure breaks atomicity requirement (F3)

**Location:** F3 acceptance criteria line 49: "Atomic: if commit fails, the override is not left in a partial state"

**Failure scenario:**

1. Interspect writes new override to `.claude/routing-overrides.json`
2. `git add .claude/routing-overrides.json` succeeds
3. `git commit` fails (pre-commit hook rejects, disk full, git lock timeout)
4. File remains modified in working tree, staged

**Result:** Override is active (flux-drive reads the file) but uncommitted. Violates the stated atomicity requirement. On next `git reset --hard` or checkout, the override vanishes. Canary record in SQLite references a commit SHA that doesn't exist.

**PRD provides no mechanism to achieve atomicity.** The acceptance criteria states the requirement but doesn't specify how to implement it. The apply step (F3) would need to:

- Write file
- Stage and commit in a single serialized operation
- On commit failure: revert the file write OR leave it unstaged

**Corrective paths:**

**Option A (transactional):** Write to a temp file, commit the temp file, then atomically rename only after commit succeeds:

```bash
_interspect_flock_git bash -c '
    jq . > .claude/routing-overrides.json.tmp
    git add .claude/routing-overrides.json.tmp
    git commit -m "[interspect] ..." || { rm .claude/routing-overrides.json.tmp; exit 1; }
    mv .claude/routing-overrides.json.tmp .claude/routing-overrides.json
'
```

**Problem:** Git commits the `.tmp` file path, not the final name. Post-commit rename creates a new uncommitted change. Doesn't work.

**Option B (compensating action):** Write file, stage, commit. On commit failure, revert the working tree change:

```bash
_interspect_flock_git bash -c '
    jq . > .claude/routing-overrides.json
    git add .claude/routing-overrides.json
    if ! git commit -m "[interspect] ..."; then
        git restore .claude/routing-overrides.json  # revert to HEAD
        return 1
    fi
'
```

This is the standard pattern for git-backed atomic operations. Used in interlock's pre-commit hook for reservation commits.

**Option C (two-phase with staging file):** Interspect design §3.8.1 (privilege separation) proposes a staging directory approach — write to `.clavain/interspect/staging/routing-overrides.json`, commit that, then an applier script copies to `.claude/routing-overrides.json`. This defers the atomicity problem to Phase 3.

**Recommended:** Option B for v1 (simple, works with existing git-commit-as-undo design). Option C is over-engineered for a single JSON file.

**Interaction with C1:** The flock wrapper from C1 prevents races *during* the read-modify-write. This issue (C2) is about what happens *after* the write when commit fails. Both fixes are required — they address different failure modes.

---

#### P1-C3: Malformed JSON breaks triage instead of graceful degradation (F1)

**Location:** F1 acceptance criteria line 24: "Malformed/missing file does not break triage (graceful degradation)"

**Gap:** The PRD states the requirement but doesn't specify **what** graceful degradation means. If `routing-overrides.json` contains invalid JSON (corrupted by a crash mid-write, hand-edited incorrectly, or clobbered by the C1 race), what should flux-drive do?

**Failure scenario:**

1. User hand-edits `.claude/routing-overrides.json` and forgets a trailing comma
2. Flux-drive Step 1.2a runs `jq .overrides[] .claude/routing-overrides.json`
3. `jq` exits with error code 4 (parse error)
4. Bash script doesn't check exit code → empty exclusion list
5. All agents run (including excluded ones)

**Alternatively:** Script uses `set -e`, `jq` error propagates, flux-drive triage aborts entirely.

Both outcomes violate "does not break triage." First case is silent data loss (exclusions ignored). Second case is a hard failure (no triage at all).

**Required behavior:**

```bash
if ! overrides=$(jq -e '.overrides[]? // empty' .claude/routing-overrides.json 2>/dev/null); then
    echo "WARN: routing-overrides.json parse error, ignoring overrides" >&2
    overrides=""
fi
# Continue with empty exclusion list (no agents excluded)
```

This matches the "missing file" case (line 24) — triage proceeds with all agents.

**Log the warning to triage output** (not just stderr) so it appears in the summary table note: "N agents excluded by routing overrides (WARNING: override file malformed, exclusions ignored)."

**Schema validation strengthening (P2-C5) would prevent some malformed-JSON cases but not all** (typos, truncated writes). This error handling is still required.

---

#### P1-C4: Proposal race: concurrent sessions can propose same exclusion (F2)

**Location:** F2 acceptance criteria line 33-37: pattern detection and proposal presentation

**Failure scenario:**

1. Sessions A and B both run `/interspect` at T=0 (user opens two terminals)
2. Both query evidence store, find same pattern (fd-game-design, 80% agent_wrong rate)
3. Both present AskUserQuestion proposals to the user (two prompts in two terminal windows)
4. User approves both (doesn't realize they're duplicates)
5. Both sessions proceed to F3, writing the same override twice

**Result depends on C1 fix:**

- **Without C1 fix:** Race condition, one override is lost (covered by C1)
- **With C1 fix:** Both writes succeed sequentially, creating duplicate entries in the overrides array:

```json
{
  "version": 1,
  "overrides": [
    {"agent": "fd-game-design", "action": "exclude", ...},
    {"agent": "fd-game-design", "action": "exclude", ...}
  ]
}
```

Flux-drive reads both entries, excludes fd-game-design twice (harmless but indicates broken deduplication).

**Corrective logic (two parts):**

**Part 1 (proposal-time):** Before presenting AskUserQuestion, check if the pattern is already in `routing-overrides.json`:

```bash
existing=$(jq -e --arg agent "$agent" '.overrides[] | select(.agent == $agent)' .claude/routing-overrides.json 2>/dev/null)
if [[ -n "$existing" ]]; then
    echo "Override for ${agent} already exists (created $(jq -r .created <<< "$existing")). Skipping proposal."
    continue
fi
```

**Part 2 (apply-time, inside flock):** Re-check after acquiring lock, before writing:

```bash
_interspect_flock_git bash -c '
    if jq -e --arg agent "$agent" ".overrides[] | select(.agent == \$agent)" .claude/routing-overrides.json >/dev/null 2>&1; then
        echo "Override for ${agent} already applied by another session. Skipping."
        exit 0
    fi
    # Proceed with read-modify-write
    ...
'
```

The apply-time check (Part 2) closes the TOCTOU window between proposal and apply. A concurrent session may approve and apply the same override between the proposal check and the flock acquisition. The locked re-check ensures idempotency.

**Alternative (simpler):** Make the apply logic idempotent by design — always use `jq` to merge, with `unique_by(.agent)`:

```bash
new=$(jq --argjson override "$override_json" '. + [$override] | unique_by(.agent)' .claude/routing-overrides.json)
```

This deduplicates at write time. Both sessions write the same final array (last-write-wins on duplicate, but result is identical). Simpler than double-checking, but loses creation timestamp from the first write (last write's timestamp is kept).

**Recommendation:** Use the `unique_by` approach for F3. Add a note in the commit message if an override was deduplicated: "Override for fd-game-design already exists, updated metadata."

---

#### P2-C5: Missing validation: routing override can exclude non-existent agent (F3)

**Location:** F3 acceptance criteria line 44-49 (write and validation)

**Failure scenario:**

1. Interspect proposes excluding `fd-game-design`
2. User approves
3. Interspect writes override to `routing-overrides.json`, commits
4. Between sessions, flux-drive is updated and `fd-game-design` is renamed to `fd-gaming-systems`
5. Flux-drive Step 1.2a reads override, tries to exclude `fd-game-design`, agent not found
6. Triage proceeds (agent no longer exists, so exclusion is a no-op)

**This is not a corruption failure** — triage doesn't break. But the override is now a no-op, wasting space in the file and creating confusion in `/interspect:status` (shows active override for non-existent agent).

**Schema validation at apply time (F3):**

Before writing the override, validate that the agent exists in the flux-drive roster:

```bash
# Check interflux agents
if ! ls "${INTERFLUX_PLUGIN_ROOT}/agents/review/${agent}.md" >/dev/null 2>&1 &&
   ! ls "${PROJECT_ROOT}/.claude/agents/${agent}.md" >/dev/null 2>&1; then
    echo "ERROR: Agent ${agent} not found in flux-drive roster or project agents. Cannot create override."
    return 1
fi
```

**Edge case:** Project-specific agents generated by flux-gen (Step 1.0.4 in flux-drive SKILL.md) live in `{PROJECT_ROOT}/.claude/agents/fd-*.md`. These can be orphaned when domain detection changes (design doc case b: agents exist AND domains changed). Orphaned agents are excluded from triage but still exist as files.

**Validation should allow orphaned agents** (they exist, just not dispatched). The check is "does the .md file exist," not "is the agent in the active roster."

**Separate concern (status display, F4):** `/interspect:status` should flag overrides for orphaned agents with a warning: "Override active for fd-cli-tool (orphaned agent, domain no longer detected)."

---

#### P2-C6: Evidence-to-proposal window: pattern can change under you (F2)

**Location:** F2 acceptance criteria line 33-34: "Routing-eligible pattern detection: ≥80% of events for the pattern have `override_reason: agent_wrong`"

**Timing failure scenario:**

1. At T=0, evidence store shows fd-safety: 8/10 events are `agent_wrong` → 80%, meets threshold
2. `/interspect` runs pattern query, computes 80%, proposes exclusion
3. User reviews the proposal for 10 minutes (reading evidence summaries)
4. During those 10 minutes, 5 new sessions add evidence: 4 events are `agent_wrong`, 1 is `deprioritized`
5. User approves at T=600
6. Interspect applies override based on stale 80% calculation
7. Actual rate at apply time: 12/15 = 80% (still meets threshold in this case)

**Edge case where it matters:**

1. T=0: 8/10 events `agent_wrong` → 80%
2. Proposal presented
3. T=60 to T=600: 10 new events added, all `deprioritized` (not quality issues)
4. T=600: User approves
5. Actual rate: 8/20 = 40% → **below threshold**

**Result:** Override is applied based on a pattern that no longer meets the confidence gate. The evidence shifted from "agent is wrong" to "agent is right but findings are low-priority" during the approval window.

**This is a known TOCTOU (time-of-check-time-of-use) issue.** Standard mitigations:

**Option A:** Re-check the pattern threshold at apply time (inside the flock, after user approval):

```bash
current_rate=$(sqlite3 "$db" "SELECT COUNT(CASE WHEN override_reason='agent_wrong' THEN 1 END)*1.0 / COUNT(*) FROM evidence WHERE source='$agent' AND event='override'")
if (( $(echo "$current_rate < 0.8" | bc -l) )); then
    echo "WARN: Pattern no longer meets threshold (was 80%, now ${current_rate}). Override not applied."
    return 1
fi
```

**Option B:** Snapshot the evidence set at proposal time, include the snapshot metadata in the proposal, and apply based on the snapshot (not live query). This is what the design doc calls "evidence window" (§3.6 baseline_window).

**Option C (interspect design choice):** Accept the TOCTOU risk. The canary monitoring (F3 line 48, 20-use window) will detect if the override made things worse. The window between proposal and apply is human-bounded (minutes), not system-bounded (days).

**PRD doesn't specify which approach to use.** F2 computes the percentage, F3 applies, but there's no "re-check" step.

**Recommendation:** Log the pattern stats at both proposal and apply time. If they diverged significantly (>10pp), include a note in the commit message: "Pattern threshold at proposal: 80% (8/10). At apply: 40% (8/20). Override applied based on user approval; canary will monitor."

This makes the TOCTOU window visible in git history without blocking the apply (user already approved).

---

#### P2-C7: Revert idempotency check missing for already-removed entries (F4)

**Location:** F4 acceptance criteria line 59: "Revert is idempotent (reverting an already-removed override is a no-op)"

**Scenario:**

1. User applies override for fd-game-design
2. Later, user hand-edits `.claude/routing-overrides.json` to remove the entry (doesn't use `/interspect:revert`)
3. User runs `/interspect:revert fd-game-design`

**Expected behavior (idempotent):** Command reports "Override for fd-game-design not found, already removed."

**Failure if not handled:**

```bash
jq 'del(.overrides[] | select(.agent == "fd-game-design"))' .claude/routing-overrides.json
# If agent not in array, jq still succeeds (del() on empty selection is no-op)
git add .claude/routing-overrides.json
git commit -m "[interspect] Revert routing override for fd-game-design"
# Commits an empty diff (no changes to file)
```

Result: Empty git commit in history. Canary record may reference the wrong commit (the original apply commit was already manually reverted, so reverting again tries to revert something that's not there).

**Required idempotency check:**

```bash
if ! jq -e --arg agent "$agent" '.overrides[] | select(.agent == $agent)' .claude/routing-overrides.json >/dev/null 2>&1; then
    echo "Override for ${agent} not found. Already removed or never existed."
    return 0
fi
# Proceed with removal
```

**Also check modifications table:** If the override was applied by interspect (has a `mod_type: routing` record), check if it's already been reverted (`status: reverted`). If so, return early with "Already reverted at [timestamp]."

This prevents double-revert and makes the revert operation truly idempotent.

---

### Improvements

#### P3-I1: Cross-cutting agent warning logic duplicates triage exclusion logic (F1)

**Location:** F1 acceptance criteria line 25: "Cross-cutting agent exclusions (fd-architecture, fd-quality) trigger a warning in the triage log"

**Issue:** The PRD treats "cross-cutting" as a static property of certain agents (architecture, quality are always cross-cutting). But domain detection (flux-drive Step 1.0.1) and agent auto-generation (Step 1.0.4) mean the set of relevant agents is dynamic.

**What if:** A claude-code-plugin project excludes `fd-architecture` (user decides they don't want architecture review for this plugin). That's a valid per-project choice — plugins are often small, focused, and don't need architecture review. Should that trigger a warning?

**The warning logic should use the same relevance criteria as triage scoring:**

- Domain-specific agents (generated by flux-gen, have `domain:` in frontmatter) are safe to exclude without warning
- Core review agents (fd-architecture, fd-quality, fd-correctness, fd-safety) should warn when excluded, regardless of project type
- The "cross-cutting" property is: "agent applies to all project types, not domain-specific"

**Implementation:** When generating the warning, check agent frontmatter:

```bash
if jq -e '.generated_by == "flux-gen"' < agents/review/${agent}.md >/dev/null 2>&1; then
    # Domain-specific, skip warning
else
    echo "WARN: Excluded ${agent} (cross-cutting agent). May miss important findings."
fi
```

**Alternative (simpler):** Maintain a static list of core agents in the flux-drive SKILL or in interspect config. Any override for a core agent triggers the warning. Simpler, but less maintainable if the agent roster changes.

**Recommendation:** Use the `generated_by` frontmatter check. It's future-proof and aligns with flux-drive's existing agent classification.

---

#### P3-I2: Canary creation failure leaves orphaned git commit (F3)

**Location:** F3 acceptance criteria line 47: "Canary record created with 20-use window (or 14-day expiry)"

**Scenario:**

1. Interspect writes routing override, stages, commits successfully (git commit returns 0)
2. Proceeds to canary creation: `sqlite3 "$db" "INSERT INTO canary (file, commit_sha, ...) VALUES (...)"`
3. SQLite insert fails (disk full, DB locked, schema mismatch)
4. Canary record is not created

**Result:** Git commit exists, modification record exists (`modifications` table, inserted before commit), but no canary. The override is active but unmonitored.

**From interspect design §3.4:** "Monitor — Insert canary record in SQLite. Next N uses compared against rolling baseline."

The design doc doesn't specify what happens if canary creation fails. Is the modification still valid? Should it be reverted?

**Two interpretations:**

1. **Canary is required** — if canary creation fails, the modification is incomplete, revert the git commit
2. **Canary is monitoring infrastructure** — if it fails, the modification is still valid, just unmonitored

**Recommended (design intent suggests #2):** The modification is valid. Canary failure should:

- Log the failure prominently: "WARN: Canary monitoring failed for routing override (fd-game-design). Override is active but unmonitored. Run /interspect:health to check."
- Insert a degraded canary record with `status: monitoring_failed`, so `/interspect:status` can show it
- Flag the modification in `modifications` table: add a `monitoring_status` column (active, failed, disabled)

**This is not a P0 because the modification itself succeeded** (override is active, committed). But lack of monitoring means the canary safety net doesn't exist — if the override makes things worse, it won't be detected automatically. User would need to manually notice degradation.

**Atomic transaction option (stronger fix):** Wrap git commit + canary insert in a logical transaction:

```bash
_interspect_flock_git bash -c '
    git commit -m "[interspect] ..." || return 1
    commit_sha=$(git rev-parse HEAD)
    if ! sqlite3 "$db" "INSERT INTO canary (...) VALUES (...)"; then
        git reset --soft HEAD~1  # undo commit, keep working tree changes
        echo "ERROR: Canary creation failed, commit rolled back"
        return 1
    fi
'
```

This makes canary creation a hard requirement — modification is not applied if canary can't be created. Stronger correctness guarantee, but more brittle (SQLite issues block all modifications).

**Decision for PRD:** Clarify whether canary failure is a blocking error or a degraded-monitoring state. Current wording implies it's required but provides no failure handling.

---

## Additional Observations (Non-Blocking)

**F5 (manual overrides) interacts with all of the above:**

- Manual overrides bypass validation (C5) — user can exclude non-existent agents
- Manual overrides are never monitored by canary, so C2 (canary creation failure) doesn't apply
- Manual overrides can still trigger C1 (JSON race) if user hand-edits while interspect is running

**The `created_by: human` field is the safety valve** — interspect never modifies entries with that field (F5 line 66). But if a user creates an override by hand and *forgets* the `created_by` field, interspect may later try to modify/revert it. The default-to-human behavior (line 69) is correct.

**Missing from PRD: What happens when flux-drive is updated and an agent is removed from the roster?**

Scenario: fd-game-design is removed from interflux (deprecated, functionality merged elsewhere). Routing override for fd-game-design still exists. Triage reads the override, tries to exclude fd-game-design, agent not found → no-op (harmless, covered by C5 as a validation gap).

But `/interspect:status` would show an active override for a deleted agent. Should there be a cleanup pass? Or is this expected behavior (user decides when to clean up stale overrides)?

Design decision needed: **Orphaned routing overrides** (agent no longer in roster). Similar to orphaned project agents from domain shifts (flux-drive Step 1.0.4 case b), but for routing overrides instead of agent files.

Recommendation: `/interspect:status` flags orphaned overrides with a note: "Override for fd-game-design (agent removed from roster). Delete manually if no longer needed." No auto-cleanup.

<!-- flux-drive:complete -->
