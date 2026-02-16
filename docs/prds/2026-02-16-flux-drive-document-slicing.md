# PRD: Flux-Drive Document Slicing via Codex Spark Classifier

**Bead:** iv-7o7n
**Brainstorm:** `docs/brainstorms/2026-02-16-flux-drive-document-slicing-brainstorm.md`
**Reviewed:** 2026-02-16 (fd-architecture, fd-correctness, fd-user-product)

## Problem

Each flux-drive review agent receives the FULL document, consuming 50-75k tokens for a typical 5-agent review. Only ~10% of content is relevant to each agent's domain. This is the single largest token sink in the system and the P0 optimization identified by the token flow audit.

## Solution

Build a clodex MCP server (stdio mode, launched on-demand) that classifies document sections per agent domain using Codex spark via `dispatch.sh`, then generate per-agent temp files with only relevant sections in full + 1-line summaries for the rest. Wire this into flux-drive's Phase 2 launch. Update `slicing.md` as the authoritative spec for both semantic (Codex spark) and keyword-based (fallback) classification methods.

## Features

### F0: Clodex MCP Server

**What:** An on-demand MCP server (stdio mode) that exposes Codex spark as a tool for lightweight classification tasks. Delegates all tier resolution to `dispatch.sh`.

**Acceptance criteria:**
- [ ] MCP server runs in stdio mode, launched on-demand by Claude Code (no systemd, no sockets)
- [ ] Registers `classify_sections` and `extract_sections` tools via MCP protocol
- [ ] Delegates Codex invocation to `dispatch.sh --tier fast` — does NOT hardcode model names
- [ ] Consumes `tiers.yaml` indirectly through dispatch.sh (single source of truth for tier resolution)
- [ ] Returns structured JSON: `{status: "success" | "no_classification", sections: [...], slicing_map: {...}}`
- [ ] `slicing_map` contains: `{agent: {priority_sections: [...], context_sections: [...], total_priority_lines, total_context_lines}}`
- [ ] Each section assignment includes confidence score (0.0-1.0)
- [ ] When Codex spark is unreachable, returns `{status: "no_classification", sections: [], error: "..."}` — caller decides fallback
- [ ] Logs classification requests and latency to stderr for observability
- [ ] Lives in new plugin directory: `plugins/clodex/`

**Language decision:** Go (matches interlock-mcp pattern, lightweight binary, fast startup).

**Phased rollout:** Start with stdio mode. Promote to systemd only when other tools are added (summary extraction, complexity routing) or invocation frequency increases beyond 10/day.

### F1: Section Extraction + Classification Prompt

**What:** Extract document sections by `##` headings (handling code blocks) and build a classification prompt that maps sections to fd-* agent domains. All markdown parsing lives in the MCP server (single implementation).

**Acceptance criteria:**
- [ ] Splits markdown by `##` headings, correctly skipping `##` inside fenced code blocks (``` and ~~~)
- [ ] Handles edge cases: unclosed code blocks (treat rest of doc as code), empty sections (0-line body), YAML frontmatter (skip `---` delimited blocks at file start)
- [ ] Adaptive section sampling: first 50 lines for sections ≤100 lines; first 25 + last 25 lines for sections >100 lines
- [ ] Classification prompt includes: agent domain descriptions (from `config/flux-drive/domains/*.md`), section headings + previews, expected JSON output format
- [ ] Prompt fits within spark tier input limits (<8K tokens for typical 500-line documents)
- [ ] Returns per-section assignment: `{section_id, heading, line_count, assignments: [{agent, relevance: "priority"|"context", confidence: 0.0-1.0}]}`
- [ ] 80% threshold: if `agent_priority_lines * 100 / total_lines >= 80` (integer arithmetic, avoids float edge cases), mark all sections as priority for that agent
- [ ] Cross-cutting exemption: fd-architecture and fd-quality always get `"priority"` for all sections
- [ ] Domain mismatch guard: if no agent receives >10% of total lines as priority, fall back to full document for all agents (classification likely failed)
- [ ] Zero priority sections for an agent → skip dispatching that agent entirely (save the Task call)

### F2: Per-Agent Temp File Generation

**What:** Given classification output, generate per-agent temp files with priority sections in full and context sections as 1-line summaries.

**Acceptance criteria:**
- [ ] Writes to `/tmp/flux-drive-{hash}-{timestamp}-fd-{agent}.md` (timestamp prevents collision on rapid re-reviews)
- [ ] Cross-cutting agents (fd-architecture, fd-quality) get the original unsliced file
- [ ] Agents with zero priority sections are NOT dispatched (orchestrator skips them)
- [ ] Sliced files have metadata header: `[Document slicing active: X priority sections (Y lines), Z context sections (W lines summarized)]`
- [ ] Priority sections preserve original markdown formatting with `##` headings
- [ ] Context sections appear as: `- **{heading}**: {first_sentence} ({line_count} lines)`
- [ ] Footer: `> If you need full content for a context section, note it as "Request full section: {name}" in your findings.`
- [ ] Fallback on classification failure: use Case 1 behavior (all agents get original file via shared path) — NOT per-agent copies of the full document

### F3: Flux-Drive Integration

**What:** Wire the classifier and file generator into flux-drive's Phase 2 launch, replacing the current single-file-for-all-agents pattern.

**Acceptance criteria:**
- [ ] launch.md Step 2.1c Case 2 (docs >=200 lines) invokes `classify_sections` MCP tool
- [ ] Each agent's Task dispatch references its per-agent temp file path
- [ ] SKILL.md Step 1.2c (Section Mapping) triggers classification for docs >200 lines
- [ ] Documents <200 lines skip slicing entirely (existing behavior preserved)
- [ ] Diff slicing (existing diff-routing.md) is NOT affected — only document slicing changes
- [ ] Phase 3 (synthesis) handles `"Request full section"` annotations: v1 = include verbatim in synthesis output (NO re-dispatch or re-read); future versions may re-read sections
- [ ] Update `slicing.md` to document both classification methods (see Spec Update below)
- [ ] Update `synthesize.md` to accept `slicing_map` for convergence scoring: if 2+ agents agree on a finding AND reviewed different sections, boost convergence score
- [ ] Quality validation target: ≤5% of agent outputs contain "Request full section" after 10 reviews (indicates classification accuracy is sufficient)

### Spec Update: slicing.md

**What:** Update `skills/flux-drive/phases/slicing.md` (the authoritative spec) to incorporate semantic classification.

**Changes:**
- Add "Classification Methods" section:
  - **Method 1: Semantic (Codex Spark)** — preferred when clodex MCP available. Invokes `classify_sections` tool with agent domain keywords.
  - **Method 2: Keyword Matching** — fallback when Codex spark unavailable or returns low-confidence (<0.6 average). Uses existing keyword algorithm (lines 181-212).
- Document the composition rule: try Method 1 first; if status is `no_classification` or average confidence < 0.6, fall back to Method 2.
- Update section classification to reference the MCP tool interface.

## Non-goals

- Diff slicing changes (already handled by diff-routing.md)
- Knowledge layer integration with classification
- Multi-document reviews (repo-level scanning)
- Agent scoring model or dynamic agent selection
- Other clodex MCP tools (summary extraction, complexity routing) — future beads
- Re-dispatching agents when "Request full section" annotations appear (v1 = verbatim inclusion only)

## Dependencies

- Codex CLI installed and configured (`codex exec` working)
- `gpt-5.3-codex-spark` model available via Codex CLI
- Go toolchain for MCP server build
- interflux plugin source (`plugins/interflux/`)
- Clavain dispatch infrastructure (`hub/clavain/scripts/dispatch.sh`, `config/dispatch/tiers.yaml`)

## Resolved Questions

1. **Codex CLI invocation pattern** — Via `dispatch.sh --tier fast`. Keeps tier resolution centralized in Clavain. MCP server is pure protocol translation + markdown parsing.
2. **MCP server location** — New plugin (`plugins/clodex/`). Classification is reusable infrastructure, not flux-drive-specific.
3. **MCP server mode** — Stdio mode (on-demand). Systemd deferred until usage justifies it.
4. **Fallback behavior** — MCP returns `{status: "no_classification"}`, orchestrator falls back to Case 1 (shared file). Explicit status field, not error-based branching.
5. **slicing.md authority** — slicing.md remains authoritative spec. Updated to document both semantic and keyword classification methods with composition rule.
6. **Markdown parsing ownership** — Centralized in MCP server (Go). Both `extract_sections` and `classify_sections` share the same parser. No duplication in orchestrator or Python fallback.

## Open Questions

1. **Classification prompt tuning** — How much section body to include? Starting with adaptive sampling (50 lines for small sections, 25+25 for large). May need tuning after first 10 reviews.
2. **Confidence threshold** — Starting with 0.6 average confidence as fallback trigger. May need adjustment based on observed classification quality.
