# Intermem Dogfood Results — Phase 1 + 2A on Real Projects

**Date:** 2026-02-18
**Bead:** iv-zl98
**Projects tested:** Autarch, Typhon, agmodb, Interverse

---

## Summary

Ran intermem synthesis (with validation) and sweep against 4 real projects. Pipeline works correctly end-to-end. Citation validation catches real stale entries. No crashes, no data loss. One argparse bug discovered (iv-gbgj).

## Results by Project

| Project | Total Entries | Stable | Promoted | Stale Filtered | Citations Found | Valid | Broken | Avg Confidence |
|---------|--------------|--------|----------|----------------|-----------------|-------|--------|----------------|
| Autarch | 106 | 106 | 91 | 15 | 34 | 19 | 42 | 0.45 |
| Typhon | 124 | 124 | 104 | 2 | 7 | 8 | 4 | 0.50 |
| agmodb | 44 | 44 | 39 | 5 | 11 | 12 | 10 | 0.49 |
| Interverse | 50 | 50 | 39 | 0 | 24 | 38 | 25 | 0.71 |
| **Total** | **324** | **324** | **273** | **22** | **76** | **77** | **81** | — |

### Key Metrics

- **Promotion rate:** 84% (273/324 stable entries promoted)
- **Stale filter rate:** 7% (22/324 entries correctly blocked by broken citations)
- **Citation coverage:** 23% of entries have extractable citations (76/324)
- **Citation accuracy:** Entries with citations split roughly 50/50 valid/broken — validation is doing real work
- **Interverse advantage:** Higher avg confidence (0.71) because it had prior synthesis history (more snapshots)

## Stale Entry Analysis

Stale entries (confidence < 0.3) had broken file path citations pointing to:
- Moved/renamed directories (e.g., `gurgeh-plugin` → `interagency-marketplace`)
- Outdated tool paths (e.g., `~/.codex/config.toml` referencing old Codex versions)
- Changed data directory structures

This is exactly the behavior we want — entries referencing files that no longer exist get flagged as stale and excluded from promotion.

## AGENTS.md Growth

| Project | AGENTS.md Before | AGENTS.md After | Lines Added | % Growth |
|---------|-----------------|-----------------|-------------|----------|
| Autarch | ~784 | 875 | ~91 | 12% |
| Typhon | ~182 | 286 | ~104 | 57% |
| agmodb | ~64 | 103 | ~39 | 61% |
| Interverse | ~391 | 431 | ~40 | 10% |

Typhon and agmodb had relatively small AGENTS.md files, so the percentage growth looks large, but the absolute line counts (286, 103) are reasonable. Autarch and Interverse, which had larger existing docs, show modest growth.

## Auto-Memory Pruning

| Project | MEMORY.md Before | MEMORY.md After | Reduction |
|---------|-----------------|-----------------|-----------|
| Autarch | 15,971B | 1,878B | 88% |
| Typhon | 14,472B | ~5,000B* | ~65% |
| agmodb | 5,496B | ~500B* | ~91% |
| Interverse | 4,323B | ~2,500B* | ~42% |

*Estimated from remaining line counts. Pruner creates `.bak` files preserving originals.

## Sweep Results

Sweep (decay + demotion) found 0 entries to decay — correct, since all entries were freshly created. Decay requires entries to be >14 days since last_seen. This confirms the 14-day grace period works.

## Topic Distribution (Most Interesting)

**Autarch** (15 sections): "Lessons Learned" dominates (21 entries), followed by "Interclode Plugin" (16), "Hook System Knowledge" (14). Shows agent memory is heavily weighted toward gotchas and plugin behavior — exactly the high-value content.

**Typhon** (6 sections): "Gotchas" dominates (56 entries!). This is a strong signal that gotcha-type knowledge is what agents naturally accumulate.

**Interverse** (6 sections): "Cross-Cutting Lessons" (23) + "Where Knowledge Lives" (11). Higher confidence across the board (avg 0.71) because entries reference many real file paths that still exist.

## Bugs Found

### iv-gbgj: argparse `parents=[shared]` overwrite (P2)

When running `intermem --project-dir /path query --topics`, the `query` subparser inherits the `shared` parent and re-defaults `project_dir` to `.`, silently ignoring the value parsed by the main parser. Workaround: put `--project-dir` after the subcommand name.

## Decision Gate Answers

### F3: Is AGENTS.md getting too large for agents?

**Not yet.** The largest post-promotion AGENTS.md is Autarch at 875 lines. This is within the comfortable range for Claude Code (CLAUDE.md can be up to ~1500 lines before truncation warnings). However, the 57-61% growth on smaller projects (Typhon, agmodb) suggests that repeated synthesis runs could push AGENTS.md past comfortable limits within a few months.

**Recommendation:** Defer F3. Monitor AGENTS.md sizes over the next 2-4 weeks of natural usage. If any project exceeds ~500 lines of intermem-promoted content (currently max is ~104), then F3 becomes justified.

### Phase 3: Do agents look up cross-project knowledge >10x/week?

**Can't measure yet.** This requires instrumentation that doesn't exist. The evidence from topic distribution suggests cross-project potential — "Hook System Knowledge" and "Plugin Version Resolution" in Autarch are generic Claude Code insights that would be valuable in any project. But there's no mechanism to detect cross-project lookups today.

**Recommendation:** Defer Phase 3 until intermem has been running for 2+ weeks and we can observe whether agents naturally reference knowledge from other projects' AGENTS.md files.

## Next Steps

1. **Let it run naturally** — don't force more synthesis runs. Wait for real sessions to generate new auto-memory entries.
2. **Run sweep in ~2 weeks** — to validate decay works on entries with real age.
3. **Fix iv-gbgj** — the argparse bug is annoying but has a workaround.
4. **Monitor AGENTS.md sizes** — if any project exceeds ~600 lines of promoted content, revisit F3.
