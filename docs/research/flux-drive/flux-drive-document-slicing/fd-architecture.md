# Flux-Drive Document Slicing — Architecture Review

**Bead:** iv-7o7n
**PRD:** `docs/prds/2026-02-16-flux-drive-document-slicing.md`
**Reviewed:** 2026-02-16
**Verdict:** needs-changes

---

## Findings Index

- P1 | ARCH-001 | "F0: Clodex MCP Server" | New MCP server duplicates existing dispatch infrastructure
- P1 | ARCH-002 | "F3: Flux-Drive Integration" | Classification request path bypasses slicing.md authority
- P2 | ARCH-003 | "F1: Section Extraction" | Markdown parsing duplicated across three components
- P2 | ARCH-004 | "Dependencies" | Missing boundary specification for Codex CLI invocation
- P3 | ARCH-005 | "F0: Clodex MCP Server" | Systemd service for classification is premature optimization
- P3 | ARCH-006 | "F2: Per-Agent Temp File Generation" | Fallback behavior creates hidden coupling to classification layer

---

## Summary

The PRD proposes a three-layer architecture (clodex MCP server → classification → temp file generation) that duplicates existing infrastructure and creates unclear ownership boundaries. The critical issues are: (1) the new MCP server replicates `dispatch.sh` tier resolution without justification, (2) classification bypasses the existing `slicing.md` specification which already defines the section-to-agent mapping algorithm, and (3) markdown parsing logic will exist in three places (MCP server, flux-drive orchestrator, potential Python fallback). The proposal is architecturally sound at the boundary level but needs consolidation to avoid structural drift.

---

## Issues Found

### ARCH-001. P1: New MCP server duplicates existing dispatch infrastructure

**Location:** F0: Clodex MCP Server

The PRD proposes building a new MCP server (`clodex`) that "invokes Codex spark tier" as a standalone systemd service. However, Clavain already has `scripts/dispatch.sh` which resolves tier names to model IDs via `config/dispatch/tiers.yaml` and handles Codex CLI invocation. The PRD does not justify why this tier-resolution logic needs to move into a separate MCP server rather than being invoked as a library or subprocess.

**Evidence:**
- PRD F0: "Invokes Codex spark tier (`gpt-5.3-codex-spark`) for classification"
- Existing: `hub/clavain/config/dispatch/tiers.yaml` defines `fast: gpt-5.3-codex-spark`
- Existing: `hub/clavain/scripts/dispatch.sh` already handles tier resolution + Codex CLI execution

**Structural concern:** This creates parallel tier-resolution paths. If a model name changes in `tiers.yaml` (which the file explicitly says callers should inherit), the clodex MCP server's hardcoded tier name won't update automatically. The dispatch layer exists to centralize this exact concern.

**Recommendation:** The MCP server should either (a) delegate tier invocation to `dispatch.sh` entirely, or (b) consume `tiers.yaml` directly as a library dependency. If (a), the server becomes a thin protocol adapter. If (b), you need to define ownership: does the MCP server own tier resolution, or does dispatch.sh? Cannot have both without drift risk.

**Alternatives:**
1. **No MCP server:** flux-drive calls `dispatch.sh --tier fast --prompt "$(cat /tmp/classify-prompt.txt)"` directly via Bash tool. Output goes to temp file. This is 5 lines of bash, not 200 lines of Go.
2. **Thin MCP wrapper:** Server just exposes `classify_sections` tool, which shells out to `dispatch.sh`. All tier logic stays in dispatch.sh. MCP server is pure protocol translation.
3. **Shared library extraction:** Move tier resolution into a Go package (`pkg/tiers`) consumed by both interlock-mcp and clodex-mcp. Then both servers inherit tier changes automatically.

**Why this matters:** Structural duplication is the seed of architectural drift. Six months from now, someone updates `tiers.yaml` to use `gpt-5.4-codex-spark` and flux-drive slicing breaks because the MCP server hardcoded the old tier name. This is a maintainability tax.

---

### ARCH-002. P1: Classification request path bypasses slicing.md authority

**Location:** F3: Flux-Drive Integration, launch.md Step 2.1c

The PRD proposes that launch.md Step 2.1c "invokes `classify_sections` MCP tool" for documents ≥200 lines. However, `slicing.md` already defines the complete classification algorithm in the "Document Slicing → Section Classification" section (lines 181-212). The PRD introduces a new classification source (Codex spark) without specifying how it relates to the existing authority.

**Evidence:**
- PRD F3: "Step 2.1c Case 2 (docs >=200 lines) invokes `classify_sections` MCP tool"
- Existing: `skills/flux-drive/phases/slicing.md` lines 181-212 define section classification as keyword matching against agent heading/hunk keywords
- Existing: `slicing.md` line 5: "This file is the single source of truth for all slicing logic"

**Conflict:** The PRD proposes Codex spark semantic classification, but `slicing.md` specifies deterministic keyword matching. These are different algorithms with different output characteristics (semantic vs syntactic, probabilistic vs deterministic). The PRD does not address which is authoritative or how they compose.

**Architectural question:** Is Codex spark classification replacing the keyword-based algorithm in `slicing.md`, or augmenting it? If replacing, `slicing.md` needs a major rewrite. If augmenting, you need a composition rule (e.g., "spark classification with keyword-based fallback for low-confidence sections").

**Recommendation:** Make the relationship explicit:
1. **Option A (replacement):** Codex spark IS the classification algorithm. Rewrite `slicing.md` Section Classification to say "Invoke clodex MCP `classify_sections` tool with agent domain keywords." Move keyword lists into the MCP prompt as classification hints.
2. **Option B (fallback chain):** Try Codex spark first; if unavailable or low-confidence, fall back to keyword matching from `slicing.md`. Document the confidence threshold and fallback trigger in `slicing.md`.
3. **Option C (composition):** Codex spark does initial section grouping, keyword matching validates/refines. This is complex and likely unnecessary.

**Why this matters:** `slicing.md` is load-bearing documentation. Multiple components reference it as the spec. If you introduce a parallel classification path without updating the spec, you create hidden behavior that future maintainers won't discover until it breaks.

---

### ARCH-003. P2: Markdown parsing duplicated across three components

**Location:** F1: Section Extraction, flux-drive SKILL.md Step 1.2c, potential Python fallback

The PRD proposes section extraction logic that "splits markdown by `##` headings, correctly skipping `##` inside fenced code blocks" (F1). However, this same logic must also exist in:
1. The clodex MCP server (to extract section previews for classification)
2. The flux-drive orchestrator (SKILL.md Step 1.2c, which currently references `slicing.md` but doesn't implement extraction)
3. Potentially a Python fallback if the MCP server is unavailable (per Open Question 4)

**Evidence:**
- PRD F1: "Splits markdown by `##` headings, correctly skipping `##` inside fenced code blocks"
- Brainstorm line 43: "Python script (Variant D): ... fails on `##` inside code blocks"
- PRD Open Question 4: "Should low-confidence classifications trigger fallback to full document"

**Structural concern:** Markdown structure parsing is non-trivial (code block state tracking, nested structures, YAML frontmatter skipping). Duplicating this logic across Go (MCP server), bash/Claude context (orchestrator), and Python (fallback) creates three independent implementations that will drift.

**Recommendation:**
1. **Centralize extraction:** The MCP server should expose both `classify_sections` AND `extract_sections` as separate tools. `extract_sections` returns structured JSON with section boundaries, headings, line counts. Classification consumes this. Orchestrator can call `extract_sections` standalone if it needs section structure without classification.
2. **Or: Single source of truth:** If extraction happens in the orchestrator, the MCP server receives already-extracted sections as input. Then classification is purely "given these N sections with previews, assign to agents."

**Why this matters:** The brainstorm explicitly called out that code-block edge cases broke the Python script. You don't want to debug the same fence-handling bug in three languages.

---

### ARCH-004. P2: Missing boundary specification for Codex CLI invocation

**Location:** Dependencies, Open Question 2

The PRD lists `codex exec` as a dependency and asks "Direct `codex exec` or via dispatch.sh wrapper?" but does not specify ownership of the Codex CLI invocation boundary. This leaves unclear whether the MCP server shells out to `codex`, uses a Go SDK, or delegates entirely to `dispatch.sh`.

**Evidence:**
- PRD Dependencies: "Codex CLI installed and configured (`codex exec` working)"
- PRD Open Question 2: "Codex CLI invocation pattern — Direct `codex exec` or via dispatch.sh?"

**Architectural gap:** The MCP server will be a long-running systemd service. If it shells out to `codex exec` for every classification, you need to handle:
- Subprocess lifecycle (timeout, zombie cleanup, signal propagation)
- Error parsing from `codex` stderr
- Environment variable inheritance (PATH, CODEX_CONFIG, etc.)
- Shell escaping for prompt content

Alternatively, if using `dispatch.sh`, you inherit its error handling but add a bash subprocess layer.

**Recommendation:** Define the invocation boundary explicitly in the PRD:
1. **Direct invocation:** MCP server uses Go `exec.Command("codex", "exec", "--tier", "fast", ...)` with explicit timeout, stderr capture, and exit-code handling. All tier logic lives in the server.
2. **Dispatch delegation:** MCP server calls `dispatch.sh --tier fast --prompt-file /tmp/prompt.txt` and parses JSON output. All tier logic stays in dispatch.sh.
3. **Go Codex SDK:** If one exists, use it. But no evidence of this in the codebase.

**Why this matters:** Subprocess invocation is a failure boundary. You need to know where responsibility for retries, logging, and error translation lives before you start building.

---

## Improvements

### ARCH-005. P3: Systemd service for classification is premature optimization

**Location:** F0: Clodex MCP Server acceptance criteria

The PRD specifies "MCP server runs as a systemd service, auto-starts on boot" and "Health check endpoint responds within 1s." However, classification is invoked once per flux-drive review (not per agent, per review). For a 5-agent review, that's 1 classification call. Even at 10 reviews per day, that's 10 invocations. A systemd service optimizes for high-frequency, low-latency requests. Classification is low-frequency, latency-tolerant (happens during Phase 2 prep, not on the critical path).

**Evidence:**
- PRD F0: "MCP server runs as a systemd service, auto-starts on boot"
- PRD F3: "launch.md Step 2.1c Case 2 invokes `classify_sections`" — one call per review, not per agent
- Existing: interlock-mcp is a systemd service because it handles real-time file reservations (low-latency, high-frequency)

**Cost of systemd service:**
- One more process competing for startup time
- One more failure mode (service crashes, needs restart)
- One more component in `/doctor` health checks
- Deployment complexity (service file, socket permissions, restart policies)

**Alternative:** MCP stdio mode, launched on-demand by Claude Code. The MCP framework already supports this. Server starts when `classify_sections` is first called, terminates when session ends. No systemd, no sockets, no health checks.

**When systemd makes sense:** If clodex grows to handle other frequent tasks (summary extraction, complexity routing per Open Questions), then always-on makes sense. But for a single low-frequency tool, it's over-architected.

**Recommendation:** Start with stdio mode. If usage grows (other tools, other consumers like interpath or interdoc), migrate to systemd later. The PRD should note this as a phased rollout.

---

### ARCH-006. P3: Fallback behavior creates hidden coupling to classification layer

**Location:** F2: Per-Agent Temp File Generation acceptance criteria

The PRD specifies "If classification fails (MCP error), falls back to writing full document for all agents (no slicing)." This fallback path creates coupling: the temp file generator must know whether classification succeeded or failed, which means it depends on the MCP layer's error signaling.

**Evidence:**
- PRD F2: "If classification fails (MCP error), falls back to writing full document for all agents"
- PRD F0: "Graceful degradation: if Codex spark is unreachable, returns error (caller decides fallback)"

**Coupling chain:**
1. MCP server errors → returns error to orchestrator
2. Orchestrator detects error → skips temp file generation → writes full document
3. Temp file generator must handle both modes (sliced vs full)

**Simpler boundary:** The MCP tool returns a classification result with a status field: `{status: "success" | "no_classification", sections: [...]}`. When status is `no_classification`, the sections array is empty. The orchestrator always calls the temp file generator with the same interface; the generator checks if sections is empty and writes full document accordingly. This decouples error detection from file generation.

**Why this matters:** Fallback logic in the middle of a pipeline is a hidden state transition. Explicit status fields make the state observable and testable.

---

## Architectural Recommendations

### 1. Consolidate tier resolution into a single source of truth

Either consume `tiers.yaml` as a library dependency in the MCP server, or delegate all Codex invocation to `dispatch.sh`. Do not hardcode tier names in the MCP server.

**Preferred approach:** Thin MCP server that calls `dispatch.sh --tier fast --prompt-file /tmp/classify.txt`. This keeps tier ownership in Clavain's config, not buried in a plugin MCP server.

### 2. Update `slicing.md` to be the authoritative spec for classification

The existing `slicing.md` is marked as "single source of truth for all slicing logic." If Codex spark classification is replacing keyword matching, rewrite `slicing.md` to specify the new algorithm. If it's augmenting, define the composition rule explicitly.

**Concrete change:** Add a new section to `slicing.md`:
```markdown
## Classification Methods

### Method 1: Semantic (Codex Spark) — preferred when available
Invokes clodex MCP `classify_sections` tool with agent domain keywords.
Handles ambiguous sections, code blocks, markdown structure.

### Method 2: Keyword Matching — fallback
[existing algorithm from lines 181-212]
Used when Codex spark unavailable or returns low-confidence (<0.6).
```

### 3. Extract markdown parsing into a reusable component

Do not duplicate fence-aware `##` splitting across Go, Python, and orchestrator logic. Options:
- MCP server exposes `extract_sections` tool (Go implementation)
- Or: orchestrator extracts sections, MCP server only classifies (orchestrator owns parsing)

Pick one and document it as the boundary.

### 4. Defer systemd service until usage justifies it

Start with stdio-mode MCP server. Promote to systemd only when other tools are added or invocation frequency increases. Document this as a phased rollout in the PRD.

### 5. Make fallback behavior explicit via status fields

MCP server returns `{status: "success" | "no_classification", sections: [...]}`. Orchestrator always calls temp file generator with the same interface. Generator checks sections array length to decide full vs sliced.

---

## Open Questions from PRD (Architecture Lens)

**Q1: Classification prompt tuning — How much section body to include?**

Architectural answer: This is a prompt engineering question, but the boundary decision is: does the MCP server extract sections, or does the orchestrator extract and pass them to the server? If the server extracts, prompt tuning is internal to the server. If the orchestrator extracts, it decides how much context to send. Pick the boundary first.

**Q2: Codex CLI invocation pattern — Direct `codex exec` or via dispatch.sh wrapper?**

Covered in ARCH-001 and ARCH-004. Recommendation: Use `dispatch.sh` to keep tier resolution centralized.

**Q3: MCP server location — New plugin or embedded in interflux?**

Architectural answer: New plugin (`plugins/clodex/`) is correct. Classification is infrastructure (reusable by interpath, interdoc, future routing), not a flux-drive-specific concern. Embedding in interflux would couple classification to the review engine.

**Q4: Confidence threshold — Should low-confidence classifications trigger fallback?**

Architectural answer: Yes, with explicit thresholds. The MCP server should return confidence scores per section assignment. Orchestrator applies a threshold (e.g., 0.6) and falls back to keyword matching for low-confidence sections. This composes semantic + syntactic classification without rewriting `slicing.md`.

---

## Verdict Justification

**needs-changes:** The proposal is architecturally viable but needs consolidation to avoid structural duplication. The key risks are:
1. Parallel tier-resolution paths (MCP server vs dispatch.sh) will drift
2. Classification bypassing `slicing.md` creates hidden spec divergence
3. Markdown parsing duplication across three components will cause edge-case bugs

Fix these boundary issues before implementation. The core idea (semantic classification via Codex spark) is sound and well-justified by the brainstorm experiments.
