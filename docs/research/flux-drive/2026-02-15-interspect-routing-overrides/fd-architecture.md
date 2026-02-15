### Findings Index
- P0 | ARCH-1 | "F2: Propose Flow" | File-based contract lacks versioning and migration path
- P0 | ARCH-2 | "F3: Apply + Commit" | Atomicity claim is incomplete — file write and git commit not in single transaction
- P1 | ARCH-3 | "F1: File Format + Reader" | Coupling between cross-plugin modules through file format creates hidden dependency
- P1 | ARCH-4 | "F5: Manual Override Support" | Conservative defaults create divergent code paths (human vs interspect)
- P2 | ARCH-5 | "F2: Propose Flow" | Threshold magic number (80%) hardcoded in spec without tuning mechanism
- P2 | ARCH-6 | "Dependencies" | Protected paths manifest already includes routing-overrides but no schema enforcement

Verdict: needs-changes

### Summary

The PRD proposes a file-based contract between interspect (clavain producer) and flux-drive (interflux consumer) for agent exclusion. The core boundary is clean (JSON file as interface), but the design has three architectural weaknesses: (1) no schema versioning for the routing-overrides.json contract — future field additions will break in unknown ways, (2) atomicity is claimed but not achieved (file write + git commit are not in the same transaction, leaving opportunity for partial state), (3) the 80% threshold for routing-eligible patterns is hardcoded without observability or tuning hooks. The coupling between clavain and interflux through this file is acceptable IF the schema is versioned and consumers gracefully degrade on version mismatch. Current design does not guarantee this.

The file-based interface itself is architecturally sound for cross-plugin communication — it avoids runtime dependencies and allows independent deployment. The allow-list validation through `_interspect_validate_target()` is properly layered. However, the lack of schema versioning and the incomplete atomicity story are P0 risks that will surface under real-world concurrent usage or during schema evolution.

### Issues Found

**ARCH-1. P0: File-based contract lacks versioning and migration path**

The routing-overrides.json schema (F1) defines `version`, `overrides[]` with fields `agent`, `action`, `reason`, `evidence_ids`, `created`, `created_by`. The PRD does not specify:
- What happens when flux-drive reads a file with `version: 2` but only understands `version: 1`
- What happens when interspect writes a new field (e.g., `expires_at`) that old flux-drive versions don't expect
- Whether `version` is a single integer, semver, or a schema hash

**Evidence:**
- F1 acceptance criteria: "Schema documented: `version`, `overrides[]`..." — version field exists but no semantics
- F1 acceptance criteria: "Malformed/missing file does not break triage (graceful degradation)" — applies to parse errors, not schema version mismatch
- Dependencies section mentions "flux-drive triage reads file during Step 1.2a" but no version check mentioned

**Impact:**
When interspect evolves the schema (e.g., adding conditional routing fields in v2 per Non-goals), flux-drive will silently ignore unknown fields OR fail to parse. If flux-drive evolves first and expects new fields, interspect will write incomplete overrides. The two plugins are in separate repos with independent release cycles — schema drift is inevitable without a version negotiation protocol.

**Boundary violation:**
The file is a cross-plugin contract but has no contract governance. Compare to MCP protocol (explicit version negotiation) or HTTP (content-type + schema version headers). This design assumes synchronized deployments, which violates the "independent plugin" architecture.

**Fix:**
1. Define version semantics: `version` is an integer, starts at 1
2. Flux-drive MUST check version on read:
   - If `version > MAX_SUPPORTED_VERSION`, log warning: "Routing overrides file version {version} not supported (max {MAX}). Ignoring file." Proceed without exclusions.
   - If `version < MIN_SUPPORTED_VERSION`, log error: "Routing overrides file version {version} is obsolete. Re-run /interspect to regenerate." Proceed without exclusions.
3. Interspect MUST check for existing file version before writing:
   - If existing file has newer version, refuse to write — log error: "Cannot write routing override: file version {existing} > plugin version {mine}. Upgrade interspect."
4. Document migration path: when schema changes require version bump, provide a migration script or auto-upgrade on first write

Alternative (simpler): Use schema hash instead of version number. On read, if unknown fields exist, ignore them (forward compat). On write, preserve unknown fields from existing file (backward compat). This is the "robustness principle" approach but still needs explicit documentation.

---

**ARCH-2. P0: Atomicity claim is incomplete — file write and git commit not in single transaction**

F3 acceptance criteria: "Atomic: if commit fails, the override is not left in a partial state." The design uses `_interspect_flock_git` for git serialization and `_interspect_validate_target()` for allow-list check, but the sequence is:
1. Validate target path
2. Write/merge into routing-overrides.json
3. Record modification in SQLite
4. Create canary in SQLite
5. Git add + commit via `_interspect_flock_git`

If step 5 (git commit) fails (e.g., pre-commit hook rejects, network issue on remote push, flock timeout), steps 2-4 are already done. The file is modified, the SQLite state is updated, but there's no git commit. Next session reads the modified file but has no commit SHA to reference for revert.

**Evidence from lib-interspect.sh:**
- `_interspect_flock_git` (lines 323-342): acquires flock, runs the command, releases on exit. If the command fails (non-zero exit), the flock releases but prior file writes persist.
- No rollback mechanism in lib-interspect.sh for file writes or SQLite inserts
- F3: "Modification recorded in interspect `modifications` table with `mod_type: "routing"`" — this happens BEFORE git commit, so `commit_sha` field will be NULL if commit fails

**Impact:**
Partial state exists where routing-overrides.json is modified but no git history records it. `/interspect:revert` expects a commit SHA (F4: "revert can target... commit SHA") but the modification record has `commit_sha: NULL`. User cannot revert via SHA. Canary monitoring runs against a modification with no source-of-truth commit.

**Boundary violation:**
The atomicity boundary is drawn around the git commit (F3 wording suggests "if commit fails, the override is not left"), but the actual write boundary is "file + SQLite + git" with no transaction wrapper. The flock only serializes git operations, not the entire write sequence.

**Fix:**
1. **Option A (true atomicity):** Write to temp file first, record modification with `status: pending`, attempt git add+commit, then atomically rename temp file on commit success. On commit failure, delete temp file and mark modification as `status: failed`. This requires changing the sequence in F3.
2. **Option B (best-effort + repair):** Accept that atomicity is impossible (git commit is external), but add repair logic: on session start, check for modifications with `status: applied` but `commit_sha: NULL`. For each, check if routing-overrides.json still contains the override. If yes, offer to "finalize commit" (re-run git add+commit). If no, mark modification as `status: orphaned`.
3. **Option C (revert by content):** Allow `/interspect:revert` to target by agent name even if commit SHA is missing. Remove the override from the file, create a new "revert" commit. This is less precise but handles the partial-state case.

Recommend Option B (best-effort + repair) because git commit failure is rare and true atomicity is hard without a transactional VCS. Document the repair flow in the interspect command.

---

**ARCH-3. P1: Coupling between cross-plugin modules through file format creates hidden dependency**

Interspect (clavain) writes `.claude/routing-overrides.json`, flux-drive (interflux) reads it. The file path is hardcoded in both plugins:
- Clavain: `_interspect_validate_target()` uses the allow-list from `protected-paths.json` which includes `.claude/routing-overrides.json`
- Interflux: flux-drive Step 1.2a reads `.claude/routing-overrides.json`

If flux-drive changes the expected file path (e.g., moves to `.claude/flux-drive/routing-overrides.json` for namespacing), interspect's writes go to the wrong location. The plugins don't share a constant or config file for this path.

**Evidence:**
- PRD F1: "flux-drive Step 1.2a reads `.claude/routing-overrides.json` if it exists" — path is spec'd in PRD, not in code contract
- Clavain protected-paths.json line 12: `".claude/routing-overrides.json"` — hardcoded
- No mention of a shared constant or environment variable for path resolution

**Impact:**
Low probability (path changes are rare), but high cost when it happens (silent data loss — interspect writes to old path, flux-drive reads from new path, overrides never apply). This is a classic cross-module coupling issue where two independent plugins share state via convention, not contract.

**Boundary violation:**
The file path IS the contract, but there's no single source of truth. The PRD is documentation, not code. If one plugin updates, the other breaks silently.

**Fix:**
1. **Option A (shared constant):** Add a `routing-overrides-path.json` config file to the monorepo root or clavain plugin, consumed by both plugins. Interspect writes to path from config, flux-drive reads from path from config. Requires both plugins to read the same config file.
2. **Option B (env var override):** Allow `FLUX_ROUTING_OVERRIDES_PATH` env var to override the default `.claude/routing-overrides.json`. Both plugins check the env var first. This supports testing and future path changes.
3. **Option C (discovery mode):** Flux-drive looks for the file in multiple locations (`.claude/routing-overrides.json`, `.claude/flux-drive/routing-overrides.json`) and uses the first found. Interspect writes to the standard location. This is the most flexible but adds complexity.

Recommend Option B (env var override) because it's low-friction, supports testing, and allows per-project customization if needed. Document the default path in both plugins' AGENTS.md files.

---

**ARCH-4. P1: Conservative defaults create divergent code paths (human vs interspect)**

F5: "Overrides with `created_by: "human"` are never modified by interspect" and "Missing `created_by` field defaults to `"human"`." This creates two classes of overrides with different lifecycle rules:
- Human overrides: never monitored by canary (F5), never modified, appear as "manual routing override" in status
- Interspect overrides: monitored by canary, can be reverted, have modification records

The conservative default (missing field = human) means that if interspect writes an override but forgets to set `created_by`, it becomes a human override and escapes monitoring. The canary system depends on correct tagging.

**Evidence:**
- F5: "Missing `created_by` field defaults to `"human"` (conservative — don't assume interspect)"
- F5: "Human overrides are never monitored by canary"
- F3: No mention of `created_by` field in the write acceptance criteria — only `agent`, `action`, `reason`, `evidence_ids`, `created`, `created_by`. If the write code forgets to set it, the default applies.

**Impact:**
If interspect has a bug and writes overrides without `created_by`, those overrides become invisible to monitoring. Canary alerts won't fire, reverting by pattern won't find them (F4: "blacklists the pattern" implies interspect-created patterns only). The system degrades to manual management.

**Boundary violation:**
The default is chosen for safety (don't delete user's manual work), but it creates a failure mode where interspect's own writes are misclassified. The conservative choice is correct for reads, but writes should fail-fast if the field is missing.

**Fix:**
1. Interspect write code MUST set `created_by: "interspect"` explicitly. Add a test to verify this field is present in all written overrides.
2. On read, keep the conservative default (missing = human) for backward compat with hand-edited files.
3. Add a validation check in `/interspect:status`: if an override has `created_by: "human"` but also has a matching modification record in the SQLite DB, flag it as "inconsistent — manually verify."

This separates write-time strictness (interspect must tag its work) from read-time tolerance (accept hand-edited files).

---

**ARCH-5. P2: Threshold magic number (80%) hardcoded in spec without tuning mechanism**

F2 acceptance criteria: "Routing-eligible pattern detection: ≥80% of events for the pattern have `override_reason: agent_wrong`." The 80% threshold determines when interspect proposes an exclusion, but there's no way to adjust it per project or per user without editing code.

**Evidence:**
- F2: "≥80% of events for the pattern" — threshold is in the PRD, not a config file
- No mention of `confidence.json` (which exists for counting rules per lib-interspect.sh lines 260-280) being extended to include routing thresholds

**Impact:**
If 80% is too low, users get spammed with exclusion proposals for agents that are only occasionally wrong. If 80% is too high, agents that are wrong 70% of the time never get proposed. The threshold should be tunable based on user tolerance and project type.

**Why this is architectural:**
Thresholds are policy, not mechanism. Hardcoding policy into the interspect library (or PRD) makes it hard to learn the right value. The architecture should separate "detect patterns" (mechanism) from "propose when X% wrong" (policy).

**Fix:**
1. Add `routing_confidence_threshold` to `.clavain/interspect/confidence.json` (default 0.8)
2. Interspect propose flow reads this config instead of hardcoding 80%
3. Users can lower it (e.g., 0.6 for aggressive exclusion) or raise it (e.g., 0.9 for conservative exclusion)
4. Document the tradeoff in the config file comments

This follows the existing pattern in lib-interspect.sh (min_sessions, min_diversity, min_events are all in confidence.json).

---

**ARCH-6. P2: Protected paths manifest already includes routing-overrides but no schema enforcement**

The Dependencies section says "`.claude/routing-overrides.json` already in the allow-list" (referring to protected-paths.json line 12). This is correct for path-based access control, but there's no enforcement that the file conforms to the schema.

**Evidence:**
- protected-paths.json line 12: `".claude/routing-overrides.json"` in `modification_allow_list`
- `_interspect_validate_target()` (lib-interspect.sh lines 220-245): checks path against allow-list, does NOT check file content or schema
- F3: "File write goes through `_interspect_validate_target()` (allow-list check)" — only path validation, not schema validation

**Impact:**
If a user manually edits `.claude/routing-overrides.json` and introduces malformed JSON, flux-drive will hit the "malformed file does not break triage" graceful degradation (F1), but interspect will merge new entries into the broken file and corrupt it further. The next flux-drive run will fail to parse.

**Why P2 not P1:**
F1 already requires "malformed/missing file does not break triage (graceful degradation)," so the worst case is flux-drive ignores the file. Interspect can make it worse by appending to a broken file, but this is a data-quality issue, not a correctness issue.

**Fix:**
1. Before merging into an existing routing-overrides.json (F3: "append if file exists"), validate that the file is parseable JSON and has a `version` field.
2. If validation fails, move the broken file to `.claude/routing-overrides.json.backup-{timestamp}` and create a new file.
3. Log a warning: "Existing routing-overrides.json was malformed. Backed up to {path}. Creating fresh file."

This prevents corruption propagation and gives users a recovery path.

### Improvements

**IMP-1. Add observability for routing exclusions (canary metrics)**

The PRD correctly identifies in Open Questions #1 that "the excluded agent produces no findings (it's not running), so override rate doesn't apply." The proposed proxy metric is "session-level quality metrics" but this is vague.

**Better approach:**
1. Track "agent would have been selected but was excluded" as an event in interspect evidence. This requires flux-drive to record pre-filter agent scores even for excluded agents.
2. Canary monitors the exclusion's impact by comparing:
   - Baseline: sessions before the override (did this agent produce useful findings?)
   - Post-override: sessions after the override (did OTHER agents find issues the excluded agent would have caught?)
3. If post-override sessions show increased severity in domains ADJACENT to the excluded agent (per flux-drive's domain adjacency map in launch.md lines 154-163), flag as "possible exclusion error."

This requires a small flux-drive change: log pre-filter scores to a `.triage-audit.json` file that interspect can read.

---

**IMP-2. Support exclusion by pattern, not just by agent name**

F1 defines `agent` field in overrides, but real-world usage might want to exclude patterns like "all game-design agents for this project" or "all cross-AI agents (Oracle) when offline."

**Proposal:**
1. Extend schema: `agent` can be a glob pattern (e.g., `fd-game-*` or `oracle-*`)
2. Flux-drive Step 1.2a matches agent names against patterns using bash glob matching (same as interspect's `_interspect_matches_any()`)
3. Interspect propose flow can suggest glob patterns when multiple agents from the same category are all >80% wrong

This reduces repetition (one override for all game agents instead of 3 separate overrides) and is more maintainable.

---

**IMP-3. Add dry-run mode for /interspect propose**

F2 presents exclusion proposals via AskUserQuestion but doesn't allow users to preview the impact before applying.

**Proposal:**
Add a `--dry-run` flag to `/interspect` Tier 2 analysis:
1. Detect routing-eligible patterns as normal
2. Present proposals with simulated triage table: "If you exclude fd-game-design, here's what the triage would look like for the last 5 reviewed documents."
3. User can see which other agents would fill the gap (via domain adjacency scoring in flux-drive launch.md Step 2.2b)
4. On approval, apply as normal

This gives users confidence that exclusions won't create blind spots.

---

**IMP-4. Cross-project learning for domain-specific exclusions**

The PRD explicitly defers "cross-project propagation" to Non-goals: "Same exclusion proposed independently per project, not broadcast." This is correct for v1, but the architecture should not preclude future cross-project learning.

**Recommendation:**
When recording a routing override in the modifications table, include `project` field (already exists in evidence table). In v2, interspect Tier 3 (cross-project analysis) can detect: "fd-game-design was excluded in 8/10 game projects but not in web-api projects. This is a domain signal, not a project signal. Suggest updating the domain profile to lower fd-game-design's base score for non-game projects."

No PRD changes needed, just note this future direction so the schema design doesn't block it (it doesn't — the modifications table already has group_id which can be used for cross-project clustering).

---

**IMP-5. Add "trial period" for new overrides instead of canary window**

F3 creates a canary with "20-use window (or 14-day expiry)." The PRD notes in Open Questions that canary metrics for routing exclusions are unclear. Instead of a fixed window, consider a trial period where the override is marked `status: trial` for the first N sessions (e.g., 10 sessions or 7 days).

During trial:
- Override is active (flux-drive respects it)
- Interspect monitors session-level metrics (e.g., avg findings per session, avg severity)
- If metrics drop significantly (e.g., 30% fewer P0/P1 findings), flag for review
- After trial, promote to `status: active` or revert

This gives users a low-risk way to test exclusions without committing to them permanently.

---

**IMP-6. Document the interaction between routing overrides and /flux-gen project agents**

Flux-drive has both Plugin Agents (fd-architecture, fd-safety, etc.) and Project Agents (generated by /flux-gen, stored in `.claude/agents/fd-*.md`). The PRD refers to "agent" in overrides (F1 schema) but doesn't specify:
- Can users exclude a Project Agent (e.g., `fd-game-simulation` generated for this project)?
- If a Project Agent and Plugin Agent have the same name, which one gets excluded?
- If a user excludes `fd-game-design` (plugin agent), does it also block the project-specific `fd-game-simulation` agent?

**Recommendation:**
1. Routing override `agent` field matches against the final agent name used in triage (could be Plugin or Project)
2. If deduplication happens (flux-drive Step 1.2 rule 5: "prefer Project Agent over Plugin Agent"), the override applies to whichever agent is actually selected
3. Document this in the flux-drive triage step and in the interspect propose flow

This avoids confusion when users see "fd-game-design excluded" but a project-specific game agent still runs.

<!-- flux-drive:complete -->
