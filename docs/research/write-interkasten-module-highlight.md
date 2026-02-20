# Module Highlight Analysis: interkasten

**Module**: interkasten (plugins/interkasten)
**Version**: 0.4.2
**Status**: Operational with 12 open beads

## Factual Summary

Interkasten is a bidirectional Notion sync companion for Claude Code that maintains local markdown files in sync with Notion pages. It provides 21 MCP tools for project CRUD, bidirectional sync (push local → Notion, pull Notion → local with 60-second polling), and three-way merge conflict resolution using `node-diff3`. The plugin integrates beads issue tracking with Notion, implements WAL-based crash recovery (pending → target_written → committed → delete), and uses SHA-256 content hashing to avoid no-op syncs.

## Key Capabilities (from AGENTS.md v0.4.0)

1. **Sync Engine**: Bidirectional sync with three-way merge, circuit breaker pattern for API resilience, content-addressed base snapshots
2. **Database**: SQLite with 5-table schema (entity_map, base_content, sync_log, sync_wal, beads_snapshot) via Drizzle ORM
3. **Tools**: 21 MCP tools covering project CRUD, hierarchy, signals, sync operations, and health checks
4. **Skills**: 3 user-facing skills (layout, onboard, doctor) + 2 lifecycle hooks (SessionStart, Stop)
5. **Design**: Agent-native (tools expose signals, AI decides logic); no hardcoded classification or cascade automation
6. **Safety**: Soft-delete retention (30-day), path validation on all pull operations, execFileSync for beads sync (no shell injection)

## Test Coverage

130 tests total: 121 unit tests + 9 integration tests (skipped without `INTERKASTEN_TEST_TOKEN`). Test structure mirrors source tree across config, store, sync, and integration suites.

## Documentation

- **README.md**: Feature overview, installation, onboard/doctor commands
- **CLAUDE.md**: Quick start, MCP tool listing, hierarchy rules, key patterns
- **AGENTS.md**: 330-line comprehensive reference including schema, tool signatures, design decisions, common tasks, gotchas, operational notes

## Known Limitations / Open Work

12 open beads tracked locally. Phase 0-3 complete (scaffold, foundation, push sync, bidirectional sync). Deferred candidates: webhook receiver (P2), interphase context integration (P2).

## Architecture Fit

Sits in the plugin layer as an MCP server. Bridges local development (filesystem, git, beads) with Notion as a persistent, shared documentation store. Agent-native design means intelligence about what to sync and how to classify lives in Claude Code skills, not the plugin.

## Version History

- **0.4.0** (current): Bidirectional sync, three-way merge, circuit breaker, @notionhq/client upgraded v2→v5
- Earlier: Push-only sync, scaffold, foundation

---

## Module Highlight (Final Output)

### interkasten (plugins/interkasten)
v0.4.2. Bidirectional Notion sync companion with 21 MCP tools for project CRUD, push/pull sync (60s polling), and three-way merge via node-diff3. Implements WAL-based crash recovery, content hashing for no-op detection, and soft-delete safety (30-day retention); integrates beads issue tracking and uses agent-native design (no hardcoded classification). 130 tests (121 unit + 9 integration), 3 skills (layout, onboard, doctor), circuit breaker for API resilience, and path validation guards on all pull operations.
