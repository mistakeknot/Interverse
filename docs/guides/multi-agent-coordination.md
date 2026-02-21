# Multi-Agent Coordination Guide

Consolidated reference for multi-agent workflows, subagent dispatch, and token analysis. Read this before orchestrating parallel agents or analyzing token usage.

## Three-Tier Context Isolation (Synthesis Pattern)

When orchestrating N parallel subagents, **never read agent output files in the host context**. This floods the host with 20-40K tokens of review prose, causing context exhaustion and lost coherence.

### Architecture

```
Tier 1: Review Agents (background)    → write .md files to OUTPUT_DIR
         ↓
Tier 2: Synthesis Subagent (foreground) → reads files, deduplicates, writes verdicts + synthesis.md
         ↓
Tier 3: Host Agent                     → reads ~10-line compact return + synthesis.md (~30-50 lines)
```

### Context savings
- **Before**: Host reads 30K-40K tokens of agent prose
- **After**: Host reads ~500 tokens (compact return + synthesis.md header)
- **Reduction**: 60-80x

### Design Rules

1. **Dedicated synthesis plugin** (`intersynth`) — not inline prompts. Provides `intersynth:synthesize-review` and `intersynth:synthesize-research` as proper subagent types.

2. **File-based output contract** — agents write findings to `{OUTPUT_DIR}/{agent-name}.md` with a standard Findings Index format. They return a single line ("Findings written to...") instead of full prose.

3. **Verdict files as structured handoff** — `verdict_write()` produces ~100-byte JSON per agent with status, summary, and detail path. The orchestrator reads verdict summaries (~500 bytes total) instead of full prose (~15KB per agent).
   - Functions: `verdict_parse_all()`, `verdict_count_by_status()`
   - Located in `lib-verdict.sh`

4. **Synthesis subagent runs foreground** — the host needs the result (PASS/FAIL) to proceed. But the return value is a compact summary, not the full synthesis.

5. **Model routing** — haiku for simple synthesis (2-3 agents), sonnet for complex synthesis (8+ agents with convergence tracking).

### Agent Dispatch Gotchas

- New agent `.md` files created mid-session are NOT available as `subagent_type` until restart
- Workaround: `subagent_type: general-purpose` + paste full agent prompt
- Background agents from previous sessions survive context exhaustion — check for in-flight predecessors before launching

## Token Accounting: Billing vs Effective Context

Claude's API reports four token categories. They measure different things:

| Metric | Formula | What It Measures |
|--------|---------|-----------------|
| Billing tokens | `input + output` | What you pay for |
| Effective context | `input + cache_read + cache_creation` | What the model sees |

The difference can be 630x because cache hits are free for billing but consume context window space.

**Rule:** Never use billing tokens to reason about context window capacity. Any decision gate about "are we hitting context limits?" must use effective context.

```bash
# Billing tokens (what you pay for)
SELECT total_tokens FROM agent_runs ORDER BY total_tokens ...

# Effective context (what the model sees)
SELECT COALESCE(input_tokens,0)+COALESCE(cache_read_tokens,0)+COALESCE(cache_creation_tokens,0) as ctx
FROM agent_runs ORDER BY ctx ...
```

## Multi-Session File Coordination (interlock + intermute)

**5-layer defense** for concurrent editing:

1. **Convention** — package ownership zones, beads `Files:` annotation
2. **Blocking edit hook** — `pre-edit.sh` blocks on exclusive conflict, auto-reserves (15min TTL)
3. **Per-session GIT_INDEX_FILE** — `GIT_INDEX_FILE=.git/index-$SESSION_ID` for independent staging
4. **Commit serialization** — `mkdir` atomicity (not flock, because flock releases when hook exits)
5. **Pre-commit validation** — acquire lock → `git read-tree HEAD` → check reservations → release

### Key behaviors
- Post-commit hook: refresh index → auto-release reservations for committed files → broadcast
- `CheckExpiredNegotiations` is advisory-only — does NOT force-release reservations
- `ReleaseByPattern` treats 404 as success (idempotent concurrent DELETE via `isNotFound` guard)
- 107 structural tests in interlock cover all coordination features

## Advisory-Only Enforcement Pattern

Convert background state-mutating actors to read-only observers. Push mutation to the edges — let the state owner make explicit decisions. Read-only code cannot race. This eliminates an entire class of TOCTOU bugs by ensuring concurrent actors never write to shared state directly.

Applied in interlock: `CheckExpiredNegotiations` is advisory-only — it reports expired negotiations but does NOT force-release, letting the state owner (the holding agent) decide.

## Post-Parallel Quality Gates

After parallel agent implementation, always run quality gates with the **full unified diff** — not individual agent diffs. Schema consistency is a cross-cutting concern that no single implementing agent owns. A unified diff catches:
- Conflicting field renames across files
- Missing imports or type updates from adjacent changes
- Interface/contract violations that only surface when all changes are combined

## Detailed Solution Docs

- `docs/solutions/patterns/synthesis-subagent-context-isolation-20260216.md`
- `docs/solutions/patterns/token-accounting-billing-vs-context-20260216.md`
- `interverse/interlock/docs/solutions/2026-02-16-advisory-only-timeout-eliminates-toctou.md`
- `interverse/tldr-swinton/docs/solutions/best-practices/parallel-agents-miss-cross-cutting-schema-bugs.md`
