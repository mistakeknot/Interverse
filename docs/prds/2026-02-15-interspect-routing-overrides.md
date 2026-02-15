# PRD: Interspect Routing Overrides

**Bead:** iv-nkak
**Brainstorm:** `docs/brainstorms/2026-02-15-interspect-routing-overrides-brainstorm.md`
**Flux-drive review:** `docs/research/flux-drive/2026-02-15-interspect-routing-overrides/`

## Problem

Flux-drive dispatches agents based on content analysis, but has no mechanism to learn from repeated irrelevance. If fd-game-design never produces useful findings for a Go backend project, it still runs every time — wasting tokens and adding noise to synthesis. Users can't exclude agents without editing flux-drive's triage logic.

**Evidence dependency:** This feature requires active evidence collection via `/interspect:correction`. Users must manually override irrelevant findings for patterns to emerge. Without corrections, routing proposals never trigger.

## Solution

A per-project `.claude/routing-overrides.json` file that interspect writes (on human approval) and flux-drive reads during triage. Closes the feedback loop: evidence collection detects irrelevant agents, proposes exclusions, and flux-drive honors them.

**Cross-plugin contract:** The routing-overrides.json file is the interface between interspect (clavain, producer) and flux-drive (interflux, consumer). The file path can be overridden via `FLUX_ROUTING_OVERRIDES_PATH` env var (default: `.claude/routing-overrides.json`).

## Features

### F1: File Format + Reader (Consumer)

**What:** Define the `routing-overrides.json` schema and add a pre-triage reader to flux-drive that excludes agents before scoring.

**Acceptance criteria:**
- [ ] Schema documented: `version` (integer, starts at 1), `overrides[]` with `agent`, `action`, `reason`, `evidence_ids`, `created`, `created_by`
- [ ] Flux-drive Step 1.2a.0 reads routing-overrides.json (path from `FLUX_ROUTING_OVERRIDES_PATH` env var or default `.claude/routing-overrides.json`)
- [ ] **Version check:** If `version > 1`, log warning "Routing overrides version {N} not supported (max 1). Ignoring file." and proceed without exclusions. If `version < 1`, log error and proceed without exclusions.
- [ ] Excluded agents are removed before scoring (never appear in triage table)
- [ ] **Graceful degradation:** If file is malformed JSON, log warning in triage output ("routing-overrides.json malformed, ignoring overrides"), move file to `.claude/routing-overrides.json.corrupted`, and proceed without exclusions
- [ ] **Cross-cutting agent exclusions** (fd-architecture, fd-quality, fd-safety, fd-correctness) trigger a prominent warning in triage output — not just a log line
- [ ] **Unknown agent warning:** If an override references an agent not in the roster, log: "WARNING: Routing override for unknown agent {name} — check spelling or remove entry." Ignored, not treated as error.
- [ ] Triage table includes a note: "N agents excluded by routing overrides"

### F2: Propose Flow (Producer)

**What:** Interspect detects routing-eligible patterns from evidence and presents exclusion proposals via AskUserQuestion with evidence summaries.

**Acceptance criteria:**
- [ ] Routing-eligible pattern detection: ≥`min_agent_wrong_pct`% (default 80, configurable in `confidence.json`) of events for the `(source, event)` tuple have `override_reason: agent_wrong`
- [ ] Pattern must also meet existing counting rules (≥`min_sessions`, ≥`min_diversity`, ≥`min_events` from confidence.json)
- [ ] **Cross-cutting check:** Agent is not tagged `cross_cutting: true` in agent metadata. Cross-cutting agents (fd-architecture, fd-quality, fd-safety, fd-correctness) require explicit confirmation with warning: "This removes structural/security coverage. Are you sure?"
- [ ] **Dedup check:** Before proposing, check if override already exists in routing-overrides.json for this agent. If yes, skip proposal.
- [ ] **Proposal format:** AskUserQuestion presents three options:
  - "Accept" — apply the override
  - "Decline" — skip for this session (re-proposes next session if still eligible)
  - "Show evidence details" — expand evidence inline (timestamps, reasons, context) then re-present Accept/Decline
- [ ] Proposal includes: agent name, event count, session count, project count, representative evidence excerpts
- [ ] **Timing:** Proposals appear after pattern analysis table is shown. Multiple proposals are presented sequentially with a preamble: "Interspect found N routing-eligible patterns."
- [ ] **Progress display:** For non-ready patterns, show progress toward threshold: "fd-game-design: 3/5 events, 2/3 sessions (needs 1 more session)"
- [ ] Proposal runs when `/interspect` command triggers Tier 2 analysis

### F3: Apply + Commit (Producer)

**What:** On user approval, write the override to `routing-overrides.json`, record the modification, create a canary, and git commit.

**Acceptance criteria:**
- [ ] **Entire read-modify-write wrapped in `_interspect_flock_git`:** Acquire lock, read file, merge override, write, git add, git commit — all inside the flock
- [ ] **Dedup at write time:** Use `unique_by(.agent)` when merging — if override for same agent exists, update metadata (last-write-wins). Log: "Override for {agent} already exists, updated metadata."
- [ ] File write goes through `_interspect_validate_target()` (allow-list check)
- [ ] **Agent existence check:** Before writing, validate the agent exists in the flux-drive roster (`agents/review/{agent}.md` or `.claude/agents/{agent}.md`). Error if not found.
- [ ] Interspect MUST set `created_by: "interspect"` explicitly on all written overrides (write-time strictness)
- [ ] **Atomicity via compensating action:** Write file → git add → git commit. On commit failure, `git restore .claude/routing-overrides.json` to revert to HEAD. Show error: "Could not commit routing override: {git error}. Override not applied. Check git status and retry."
- [ ] **DB inserts after commit:** Modification record (`mod_type: "routing"`) and canary record (20-use window or 14-day expiry) are inserted AFTER successful git commit. If canary insert fails, log warning: "Canary monitoring failed — override active but unmonitored."
- [ ] **Write validation:** After writing, read back and parse JSON to confirm validity. If invalid, delete and abort.
- [ ] Git commit via `_interspect_flock_git` with `[interspect]` prefix and structured message including `commit_sha`
- [ ] Failed proposals are not re-offered in the same session

### F4: Status + Revert

**What:** Show active routing overrides in `/interspect:status` and support reverting them via `/interspect:revert`.

**Acceptance criteria:**
- [ ] `/interspect:status` shows routing overrides per project with actionable context:
  - Agent name, reason, created date, `created_by`
  - Canary verdict if available ("PASSED", "ALERT: quality degraded", "monitoring: 8/20 uses")
  - Next-action hint ("Run `/interspect:revert fd-game-design` to undo" or "Canary monitoring active, 12 uses remaining")
  - **Inconsistency flag:** If override has `created_by: "human"` but also has a modification record in SQLite, flag as "inconsistent — manually verify"
  - **Orphan flag:** If override references an agent not in the current roster, flag: "Override for {agent} (agent removed from roster)"
  - Override count with governance warning if ≥3 overrides: "High exclusion rate — review agent roster"
- [ ] `/interspect:revert` can target by agent name or commit SHA
- [ ] **Idempotency:** If override not found, report "Override for {agent} not found. Already removed or never existed." and exit 0 (no empty git commit)
- [ ] Revert removes entry, blacklists pattern in `interspect.db` `blacklist` table (`pattern_key`, `blacklisted_at`, `reason`)
- [ ] Blacklisted patterns never re-proposed unless user runs `/interspect:unblock <agent>`
- [ ] If canary is still monitoring when revert happens, close canary with `status: reverted`
- [ ] Status footer: "You can also hand-edit `.claude/routing-overrides.json` — set `created_by: \"human\"` for custom overrides."

### F5: Manual Override Support

**What:** Users can create routing overrides by hand. Human-created overrides are respected but not monitored.

**Acceptance criteria:**
- [ ] Overrides with `"created_by": "human"` are never modified by interspect
- [ ] Human overrides are never monitored by canary (unless user sets `"monitor": true`)
- [ ] Human overrides appear in `/interspect:status` as "manual routing override"
- [ ] Missing `created_by` field defaults to `"human"` on read (conservative — don't assume interspect)
- [ ] **Staleness reminder:** On session start, if human overrides exist and are >90 days old, inject reminder: "Manual routing overrides active (>90 days old). Run `/interspect:status` to review."
- [ ] Document manual override workflow in Clavain AGENTS.md with example JSON
- [ ] Generated `routing-overrides.json` includes comment header explaining manual editing

## Non-goals

- **Model overrides** — Changing which model an agent uses (e.g., haiku vs sonnet). Deferred to v2.
- **Conditional routing** — Rules like "exclude fd-X only when project language is Go". Per-project files handle this.
- **Auto-revert** — Canary alerts but does not auto-remove overrides. Human reverts manually.
- **Cross-project propagation** — Same exclusion proposed independently per project, not broadcast.
- **Agent inclusion overrides** — Forcing an agent to run when triage would skip it. Only exclusions in v1.
- **Suppression mode** — Agent runs but findings hidden. Deferred to v2 based on user feedback.
- **Hard caps on override count** — Users can exclude as many agents as needed; interspect warns at ≥3.
- **Automatic staleness detection** — Domain-shift invalidation of overrides deferred; users review via `/interspect:status`.

## Dependencies

- **Interspect Phase 1 (evidence store)** — Evidence collection must be active. Beads iv-2nt4 (counting rules), iv-i03k (protected paths), iv-jkce (flock) are all closed.
- **Flux-drive triage** — Consumer reads file during Step 1.2a.0 (new pre-filter step). No changes to scoring algorithm.
- **Protected paths manifest** — `.claude/routing-overrides.json` already in the allow-list.
- **Evidence contract:** Flux-drive must emit `(agent_name, "override")` events with `override_reason: agent_wrong` via `/interspect:correction`. Other `override_reason` values (`agent_noisy`, `agent_late`) do NOT count toward routing-eligibility.
- **Confidence.json extension:** Add `min_agent_wrong_pct: 80` to `.clavain/interspect/confidence.json`.
- **Blacklist table:** Add `blacklist` table to interspect.db schema (F4 revert flow).

## Open Questions

1. **Canary metrics for routing exclusions.** The excluded agent produces no findings (it's not running), so override rate doesn't apply. V1 canary monitors user override rate (overrides/session) for 20 sessions after exclusion. If override rate increases >20% relative to baseline, alert: "Routing override for {agent} may have degraded review quality." Full recall measurement deferred to v2 (Galiana integration).
2. **Override count governance.** Resolved: warn at ≥3 overrides per project (see F4 status display). No hard cap.
3. **Safety-critical agent exclusion.** Resolved: require explicit confirmation with warning text (see F2 cross-cutting check). No hard block in v1.

## Success Metrics (v1)

- **Token savings:** Median flux-drive token cost decreases by ≥10% for projects with routing overrides
- **Accuracy:** <5% of routing overrides reverted within 20 sessions
- **Adoption:** ≥1 routing override created per 10 active flux-drive projects within 30 days of release
- **No defect escapes:** 0 reported incidents where excluded agent would have caught a real issue
