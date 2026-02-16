# Token-Efficient Skill Loading — PRD

**Bead:** Clavain-1lri
**Date:** 2026-02-15
**Status:** Strategy complete, ready for planning
**Brainstorm:** [`docs/brainstorms/2026-02-15-token-efficient-skill-loading.md`](../brainstorms/2026-02-15-token-efficient-skill-loading.md)

---

## 1. Problem

Inter-* plugin skills load 300-1,954 lines of instruction docs on every invocation. Most of this is ceremony (reading phase files, reference docs, signal definitions) — the same content every time. This wastes 60-70% of loaded tokens on instructions the agent doesn't need to re-read.

**Impact:** A single `/sprint` pipeline loads flux-drive 2-3 times + interwatch once + interpath once, consuming thousands of context tokens before any real work begins.

## 2. Solution

Two complementary strategies:

### 2A. Compact SKILL Files (tiered loading)

Each high-overhead skill gets a `SKILL-compact.md` alongside the existing `SKILL.md`:

- **SKILL.md** — full modular version (for editing, debugging, reference)
- **SKILL-compact.md** — LLM-generated summary (~50-100 lines) with the essential algorithm, decision points, and output contracts. No examples, no rationale, no verbose descriptions.

Skills load `SKILL-compact.md` by default. The full phase docs remain available for edge cases.

### 2B. Pre-computation Scripts (move work out of LLM)

Shell scripts handle deterministic computation that currently happens in LLM context:

- **`scripts/interwatch-scan.sh`** — evaluates all configured signals, outputs JSON with scores, confidence tiers, and recommended actions
- Component counting, version comparison, and dependency checking already exist in scripts — wire them into the pre-computation pipeline

The LLM reads the pre-computed JSON and makes decisions. No signal evaluation loops in context.

## 3. Scope

### In Scope

| Deliverable | Plugin | Description |
|-------------|--------|-------------|
| `SKILL-compact.md` | interwatch/doc-watch | Compact drift scan instructions |
| `SKILL-compact.md` | interpath/artifact-gen | Compact artifact generation instructions |
| `SKILL-compact.md` | interflux/flux-drive | Compact review instructions |
| `scripts/gen-compact.sh` | Interverse (shared) | LLM-powered compact file generator |
| `scripts/interwatch-scan.sh` | interwatch | Pre-computed drift scan JSON output |
| Skill loader convention | All | SKILL.md detects and delegates to SKILL-compact.md |

### Out of Scope

- Compact files for low-overhead skills (brainstorming, writing-plans — already inline)
- Cross-session caching (requires Claude Code platform changes)
- Rewriting flux-drive scoring as Python (too complex for v1)
- Per-invocation token budgets

## 4. Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Compact file location | Same directory as SKILL.md | Simple, discoverable, no path changes |
| Generation method | LLM summarization | Higher quality than mechanical extraction; generated once, committed as static |
| Rollout scope | Top 3 plugins | Prove the pattern on highest-overhead skills before expanding |
| Compact file format | Markdown, same structure as SKILL.md | No tooling changes needed; skills just read a different file |

## 5. Loader Convention

Each `SKILL.md` gets a preamble that checks for compact mode:

```markdown
<!-- compact: SKILL-compact.md -->
```

When a skill is invoked, the agent checks for `SKILL-compact.md` in the same directory. If it exists, load that instead of following the multi-file read chain in SKILL.md.

The full SKILL.md remains the canonical source. `SKILL-compact.md` is a derived artifact.

## 6. Pre-computation: interwatch-scan.sh

```bash
# Output format:
{
  "scan_date": "2026-02-15T15:30:00",
  "watchables": {
    "roadmap": {
      "path": "docs/roadmap.md",
      "exists": true,
      "score": 9,
      "confidence": "High",
      "signals": {
        "bead_closed": {"count": 2, "weight": 2, "score": 4},
        "version_bump": {"detected": true, "weight": 3, "score": 3},
        "brainstorm_created": {"count": 1, "weight": 1, "score": 1}
      },
      "recommended_action": "auto-refresh"
    }
  }
}
```

The LLM reads this JSON and acts on it — no signal evaluation, no SQLite queries, no git log parsing.

## 7. Success Metrics

| Metric | Current | Target |
|--------|---------|--------|
| Interwatch drift scan token overhead | ~364 lines read | <100 lines (compact + JSON) |
| Interpath artifact-gen token overhead | ~300 lines read | <80 lines (compact + JSON) |
| Interflux flux-drive token overhead | ~1,954 lines read | <250 lines (compact) |
| Total /sprint pipeline overhead | ~3,000+ lines | <500 lines |

## 8. Risks

| Risk | Impact | Mitigation |
|------|--------|-----------|
| Compact file drifts from source | Agent follows stale instructions | gen-compact.sh tracks source file hashes; test validates freshness |
| LLM summarization loses critical detail | Edge cases fail | Full SKILL.md always available as fallback; compact includes "for edge cases, read SKILL.md" |
| Pre-computation script bugs | Wrong drift scores | Unit tests for interwatch-scan.sh; compare against LLM-evaluated scores |
