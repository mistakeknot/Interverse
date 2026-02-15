# Interject — Ambient Discovery & Research Engine

**Date:** 2026-02-15
**Status:** Approved for implementation
**Type:** New plugin (MCP server)
**Location:** `plugins/interject/`

## Overview

Interject is a Python MCP server that continuously discovers, evaluates, and recommends new capabilities, workflows, tools, and research relevant to the engineering ecosystem. It scans external sources (arXiv, Hacker News, GitHub, Anthropic docs), cross-references against internal gaps, and produces confidence-tiered outputs — from silent records to beads to briefing docs to draft implementation plans.

## Operating Modes

1. **Daemon** (systemd timer, default every 6 hours) — deep crawls across all configured sources
2. **Session hook** (SessionStart) — lightweight inbox check, surfaces only high-confidence discoveries above a learned threshold. Silent when nothing important.
3. **On-demand** (`/interject:scan`, `/interject:discover`, `/interject:inbox`) — manual deep dives, topic-specific searches, inbox review

## Source Adapter System

Pluggable adapters conforming to a standard interface:

```python
class SourceAdapter:
    name: str
    async def fetch(self, since: datetime, topics: list[str]) -> list[RawDiscovery]
    async def enrich(self, discovery: RawDiscovery) -> EnrichedDiscovery
```

### v1 Adapters

| Adapter | Source | Access Method | What it finds |
|---------|--------|---------------|---------------|
| `arxiv` | arxiv.org | REST API (XML) | Papers in cs.AI, cs.SE, cs.MA, cs.CL matching interest profile |
| `hackernews` | hn.algolia.com | Algolia API | Show HN posts, trending discussions on agent tooling, MCP, Claude |
| `github` | GitHub | `gh` CLI / REST API | Trending repos, new MCP servers, Claude Code plugins, relevant tool releases |
| `anthropic` | docs.anthropic.com | Web scrape / changelog RSS | API changes, new features, model releases, plugin marketplace updates |

Adding a new adapter is dropping a Python file into `sources/` that implements the interface. The daemon discovers adapters at startup. Each adapter has its own config section (rate limits, categories, keywords) in `.interject/config.yaml`.

### Deferred Adapters (v2+)

npm, PyPI, Reddit, Discord.

## Data Model

SQLite tables in `.interject/interject.db`:

### `discoveries`

| Column | Type | Purpose |
|--------|------|---------|
| `id` | text PK | e.g., `ij-arxiv-2402.1234` |
| `source` | text | adapter name |
| `source_id` | text | original ID (arXiv paper ID, HN item ID, GitHub repo slug) |
| `title` | text | |
| `summary` | text | |
| `url` | text | |
| `raw_metadata` | json | source-specific fields (authors, stars, comments, etc.) |
| `embedding` | blob | sentence-transformer vector, shared model with tldr-swinton |
| `relevance_score` | float | computed similarity to interest profile |
| `confidence_tier` | text | `low`, `medium`, `high` |
| `status` | text | `new`, `reviewed`, `promoted`, `dismissed`, `decayed` |
| `discovered_at` | timestamp | |
| `reviewed_at` | timestamp | |

### `promotions`

| Column | Type | Purpose |
|--------|------|---------|
| `discovery_id` | text FK | |
| `bead_id` | text | created bead's ID |
| `bead_priority` | int | 0-4, the key learning signal |
| `promoted_at` | timestamp | |

### `interest_profile`

| Column | Type | Purpose |
|--------|------|---------|
| `topic_vector` | blob | running average embedding of promoted discoveries, weighted by priority |
| `keyword_weights` | json | explicit topic weights, boosted/decayed over time |
| `source_weights` | json | per-adapter trust scores |
| `updated_at` | timestamp | |

### `scan_log`

| Column | Type | Purpose |
|--------|------|---------|
| `source` | text | |
| `last_scan_at` | timestamp | |
| `items_found` | int | |
| `items_above_threshold` | int | |

### Decay Function

Every 24 hours, unreviewed items get `relevance_score *= 0.95`. After dropping below 0.1, status flips to `decayed`. Decay rate is configurable.

## Recommendation Engine

Three stages: **score**, **rank**, **learn**.

### Scoring (new discovery arrives)

1. Embed title + summary using shared sentence-transformer model (same as tldr-swinton)
2. Cosine similarity against `interest_profile.topic_vector`
3. Apply multipliers:
   - `keyword_weight` boost for explicit topic matches
   - `source_weight` from per-adapter trust scores
   - `recency_boost` — 1.0 at day 0, decays to 0.8 over a week
   - `gap_bonus` — significant boost when discovery fills a detected gap in plugin ecosystem
4. Final `relevance_score` = weighted combination

### Ranking (confidence tier assignment)

- `high` (> 0.8) → bead + briefing doc + draft plan
- `medium` (0.5–0.8) → bead + briefing doc
- `low` (0.2–0.5) → discovery record only, queryable but silent
- Below 0.2 → discarded

Thresholds are **adaptive** — shift based on promotion rate. High ignore rate raises thresholds; high promotion rate lowers them.

### Learning (feedback loop)

- Bead promotion updates topic vector. P0 = 5x weight, P4 = 1x weight.
- Dismissed discoveries are negative signals — topic vector moves away.
- Source weights update proportionally to promotion rates.

### Gap Detection

- Scans installed plugins, beads history, `docs/plans/` to build capability map
- Compares against taxonomy of common engineering capabilities
- Gaps become search queries fed into adapters

## MCP Tools

| Tool | Purpose |
|------|---------|
| `interject_scan` | Trigger full or per-source scan. Args: `source`, `topic` (optional) |
| `interject_inbox` | Discoveries above threshold since last review. Args: `limit`, `min_score`, `source` |
| `interject_detail` | Full detail on a discovery. Args: `discovery_id` |
| `interject_promote` | Promote to bead + briefing + optional plan. Args: `discovery_id`, `priority` |
| `interject_dismiss` | Negative signal. Args: `discovery_id`, `reason` (optional) |
| `interject_profile` | View/edit interest profile. Args: `action` (`view`, `add_topic`, `remove_topic`, `reset`) |
| `interject_status` | Health check — scan times, queue depth, profile stats |
| `interject_search` | Semantic search across discoveries. Args: `query`, `source`, `min_score`, `limit` |

## Skills

| Skill | What it does |
|-------|-------------|
| `/interject:scan` | Full scan, reports findings inline |
| `/interject:discover <topic>` | Deep dive on specific topic across all sources |
| `/interject:inbox` | Review pending discoveries, promote/dismiss interactively |
| `/interject:profile` | View and tune interest profile |
| `/interject:status` | Dashboard of scan health and recommendation stats |

## Session Hook

SessionStart hook:
1. Calls `interject_inbox` with `min_score` at learned high-confidence threshold
2. If results > 0: prints brief summary with one-line descriptions
3. If results == 0: silent

## Daemon

Systemd timer (every 6 hours):
1. Runs all adapters
2. Scores and tiers discoveries
3. High tier: auto-creates bead (type=research), writes briefing + draft plan
4. Medium tier: auto-creates bead + briefing
5. Logs to `scan_log`

## Embedding Sharing

Interject calls tldr-swinton's embedding MCP tool rather than loading its own model. Falls back to local model if tldr-swinton isn't running.

## File Structure

```
plugins/interject/
├── .claude-plugin/
│   └── plugin.json
├── pyproject.toml
├── uv.lock
├── CLAUDE.md
├── AGENTS.md
├── src/interject/
│   ├── __init__.py
│   ├── server.py          # MCP server entrypoint (FastMCP)
│   ├── db.py              # SQLite schema, migrations, queries
│   ├── engine.py          # recommendation engine
│   ├── embeddings.py      # shared embedding client
│   ├── scanner.py         # daemon loop, adapter orchestration
│   ├── gaps.py            # capability gap detection
│   ├── outputs.py         # bead creation, briefing/plan generation
│   └── config.py          # YAML config loader
├── sources/
│   ├── __init__.py
│   ├── base.py            # SourceAdapter protocol
│   ├── arxiv.py
│   ├── hackernews.py
│   ├── github.py
│   └── anthropic.py
├── skills/
│   ├── scan.md
│   ├── discover.md
│   ├── inbox.md
│   ├── profile.md
│   └── status.md
├── hooks/
│   └── session-start.sh
├── config/
│   └── default.yaml
├── scripts/
│   ├── bump-version.sh
│   └── post-bump.sh
└── tests/
    ├── test_engine.py
    ├── test_sources.py
    └── test_db.py
```

## v1 Scope

**Ships:**
- MCP server with SQLite state
- 4 source adapters (arXiv, HN, GitHub, Anthropic)
- Recommendation engine with embeddings, keyword boosts, source weights, decay
- Confidence-tiered output pipeline
- Gap detection
- Feedback loop from bead promotions/dismissals
- Adaptive thresholds
- Session hook (priority-gated)
- Systemd timer daemon
- 5 skills
- Embedding sharing with tldr-swinton

**Deferred:**
- npm/PyPI adapters
- Reddit/Discord adapters
- Multi-user profiles
- Plan quality scoring
- Cross-discovery clustering
- Slack/email notifications
- Web dashboard
- Third-party adapter contribution guide
