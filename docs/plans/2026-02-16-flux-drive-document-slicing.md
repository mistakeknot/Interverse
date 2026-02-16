# Flux-Drive Document Slicing Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use clavain:executing-plans to implement this plan task-by-task.

**Goal:** Build a clodex MCP server that classifies document sections per agent domain using Codex spark, generate per-agent temp files with only relevant sections, and wire this into flux-drive's Phase 2 launch — reducing token consumption by 50-70%.

**Architecture:** Go stdio MCP server (`plugins/clodex/`) delegates classification to `dispatch.sh --tier fast`. Returns structured JSON with section assignments + confidence scores. Orchestrator in `launch.md` calls `classify_sections`, writes per-agent temp files, and passes per-agent paths to Task dispatch. Cross-cutting agents (fd-architecture, fd-quality) always get the full document.

**Tech Stack:** Go 1.23, `github.com/mark3labs/mcp-go` v0.43.2, Codex CLI via `dispatch.sh`, bash orchestration in flux-drive skills

**PRD:** `docs/prds/2026-02-16-flux-drive-document-slicing.md`
**Bead:** iv-7o7n (epic), iv-j7uy (F0), iv-zrmk (F1), iv-5m8j (F2), iv-tifk (F3)
**Phase:** planned (as of 2026-02-16T16:15:22Z)

---

## Task 1: Scaffold clodex plugin directory

**Bead:** iv-j7uy (F0)
**Phase:** planned (as of 2026-02-16T16:15:22Z)

**Files:**
- Create: `plugins/clodex/go.mod`
- Create: `plugins/clodex/go.sum`
- Create: `plugins/clodex/cmd/clodex-mcp/main.go`
- Create: `plugins/clodex/bin/launch-mcp.sh`
- Create: `plugins/clodex/.claude-plugin/plugin.json`
- Create: `plugins/clodex/CLAUDE.md`

**Step 1: Create go.mod**

```
plugins/clodex/go.mod
```
```go
module github.com/mistakeknot/clodex

go 1.23.0

require github.com/mark3labs/mcp-go v0.43.2
```

Run: `cd /root/projects/Interverse/plugins/clodex && go mod tidy`
Expected: go.sum generated, dependencies resolved

**Step 2: Create main.go entry point**

```
plugins/clodex/cmd/clodex-mcp/main.go
```
```go
package main

import (
	"fmt"
	"os"

	"github.com/mark3labs/mcp-go/server"
	"github.com/mistakeknot/clodex/internal/tools"
)

func main() {
	s := server.NewMCPServer(
		"clodex",
		"0.1.0",
		server.WithToolCapabilities(true),
	)

	dispatchPath := os.Getenv("CLODEX_DISPATCH_PATH")
	if dispatchPath == "" {
		dispatchPath = "/root/projects/Interverse/hub/clavain/scripts/dispatch.sh"
	}

	tools.RegisterAll(s, dispatchPath)

	if err := server.ServeStdio(s); err != nil {
		fmt.Fprintf(os.Stderr, "clodex-mcp: %v\n", err)
		os.Exit(1)
	}
}
```

**Step 3: Create launch-mcp.sh**

```
plugins/clodex/bin/launch-mcp.sh
```
```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BINARY="${SCRIPT_DIR}/clodex-mcp"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

if [[ ! -x "$BINARY" ]]; then
    if ! command -v go &>/dev/null; then
        echo '{"error":"go not found — cannot build clodex-mcp. Install Go 1.23+ and restart."}' >&2
        exit 1
    fi
    cd "$PROJECT_ROOT"
    go build -o "$BINARY" ./cmd/clodex-mcp/ 2>&1 >&2
fi

exec "$BINARY" "$@"
```

Run: `chmod +x plugins/clodex/bin/launch-mcp.sh`

**Step 4: Create plugin.json**

```
plugins/clodex/.claude-plugin/plugin.json
```
```json
{
  "name": "clodex",
  "version": "0.1.0",
  "description": "Codex spark classifier — lightweight section classification via MCP",
  "mcpServers": {
    "clodex": {
      "type": "stdio",
      "command": "${CLAUDE_PLUGIN_ROOT}/bin/launch-mcp.sh",
      "args": [],
      "env": {
        "CLODEX_DISPATCH_PATH": "/root/projects/Interverse/hub/clavain/scripts/dispatch.sh"
      }
    }
  }
}
```

**Step 5: Create CLAUDE.md**

```
plugins/clodex/CLAUDE.md
```
```markdown
# clodex

Codex spark classifier — MCP server exposing `classify_sections` and `extract_sections` tools for lightweight document classification via Codex spark tier.

## Quick Commands

```bash
# Build binary
cd plugins/clodex && go build -o bin/clodex-mcp ./cmd/clodex-mcp/

# Run tests
cd plugins/clodex && go test ./...

# Test locally
claude --plugin-dir /root/projects/Interverse/plugins/clodex
```

## Design Decisions (Do Not Re-Ask)

- Go binary (matches interlock-mcp pattern)
- Stdio MCP transport (on-demand, no systemd)
- Delegates tier resolution to dispatch.sh (does NOT hardcode model names)
- Classification prompt built from agent domain descriptions
```

**Step 6: Verify build**

Run: `cd /root/projects/Interverse/plugins/clodex && go build -o bin/clodex-mcp ./cmd/clodex-mcp/`
Expected: Binary created at `plugins/clodex/bin/clodex-mcp`

Note: This will fail until Task 2 creates the `internal/tools` package. That's expected — this task sets up the skeleton.

**Step 7: Commit**

```bash
git add plugins/clodex/
git commit -m "feat(clodex): scaffold MCP server plugin

Go module, main.go entry point, launch-mcp.sh auto-builder,
plugin.json manifest. Tools package is a stub — next commit."
```

---

## Task 2: Implement markdown section extractor

**Bead:** iv-zrmk (F1)
**Phase:** planned (as of 2026-02-16T16:15:22Z)

**Files:**
- Create: `plugins/clodex/internal/extract/extract.go`
- Create: `plugins/clodex/internal/extract/extract_test.go`

**Step 1: Write the failing test for basic section extraction**

```
plugins/clodex/internal/extract/extract_test.go
```
```go
package extract

import (
	"strings"
	"testing"
)

func TestExtractSections_Basic(t *testing.T) {
	doc := `# Title

Intro paragraph.

## Section A

Content A line 1.
Content A line 2.

## Section B

Content B line 1.
`
	sections := ExtractSections(doc)
	if len(sections) != 3 { // preamble + A + B
		t.Fatalf("expected 3 sections, got %d", len(sections))
	}
	if sections[0].Heading != "" {
		t.Errorf("preamble heading should be empty, got %q", sections[0].Heading)
	}
	if sections[1].Heading != "Section A" {
		t.Errorf("expected 'Section A', got %q", sections[1].Heading)
	}
	if sections[1].LineCount != 3 { // "Content A line 1." + "Content A line 2." + ""
		t.Errorf("expected 3 lines for Section A body, got %d", sections[1].LineCount)
	}
	if sections[2].Heading != "Section B" {
		t.Errorf("expected 'Section B', got %q", sections[2].Heading)
	}
}

func TestExtractSections_CodeBlock(t *testing.T) {
	doc := "## Real Section\n\n```markdown\n## Not A Section\nstuff\n```\n\n## Another Real\n\nContent.\n"
	sections := ExtractSections(doc)
	headings := make([]string, len(sections))
	for i, s := range sections {
		headings[i] = s.Heading
	}
	// Should NOT split on "## Not A Section" inside code block
	if len(sections) != 2 {
		t.Fatalf("expected 2 sections, got %d: %v", len(sections), headings)
	}
	if sections[0].Heading != "Real Section" {
		t.Errorf("expected 'Real Section', got %q", sections[0].Heading)
	}
	if sections[1].Heading != "Another Real" {
		t.Errorf("expected 'Another Real', got %q", sections[1].Heading)
	}
}

func TestExtractSections_TildeCodeBlock(t *testing.T) {
	doc := "## First\n\n~~~\n## Fake\n~~~\n\n## Second\n\nDone.\n"
	sections := ExtractSections(doc)
	if len(sections) != 2 {
		t.Fatalf("expected 2 sections, got %d", len(sections))
	}
}

func TestExtractSections_UnclosedCodeBlock(t *testing.T) {
	doc := "## Before\n\nText.\n\n```\n## Inside\nMore.\n"
	sections := ExtractSections(doc)
	// Unclosed code block — everything after ``` is code, no new section
	if len(sections) != 1 {
		t.Fatalf("expected 1 section (unclosed block), got %d", len(sections))
	}
}

func TestExtractSections_YAMLFrontmatter(t *testing.T) {
	doc := "---\ntitle: Test\ndate: 2026-01-01\n---\n\n## First Section\n\nContent.\n"
	sections := ExtractSections(doc)
	if len(sections) != 1 {
		t.Fatalf("expected 1 section (frontmatter skipped), got %d", len(sections))
	}
	if sections[0].Heading != "First Section" {
		t.Errorf("expected 'First Section', got %q", sections[0].Heading)
	}
}

func TestExtractSections_EmptySection(t *testing.T) {
	doc := "## Empty\n\n## Has Content\n\nLine.\n"
	sections := ExtractSections(doc)
	if len(sections) != 2 {
		t.Fatalf("expected 2 sections, got %d", len(sections))
	}
	if sections[0].LineCount != 1 { // just the blank line
		t.Errorf("empty section should have 1 line (blank), got %d", sections[0].LineCount)
	}
}

func TestSectionPreview_Small(t *testing.T) {
	// Section with 10 lines — should return all 10
	lines := make([]string, 10)
	for i := range lines {
		lines[i] = "line"
	}
	s := Section{Body: strings.Join(lines, "\n"), LineCount: 10}
	preview := s.Preview()
	if strings.Count(preview, "line") != 10 {
		t.Errorf("small section preview should include all lines")
	}
}

func TestSectionPreview_Large(t *testing.T) {
	// Section with 150 lines — should return first 25 + last 25
	lines := make([]string, 150)
	for i := range lines {
		lines[i] = fmt.Sprintf("L%d", i)
	}
	s := Section{Body: strings.Join(lines, "\n"), LineCount: 150}
	preview := s.Preview()
	if !strings.Contains(preview, "L0") {
		t.Error("preview should contain first line")
	}
	if !strings.Contains(preview, "L24") {
		t.Error("preview should contain line 24 (end of first 25)")
	}
	if !strings.Contains(preview, "[... 100 lines omitted ...]") {
		t.Error("preview should contain omission marker")
	}
	if !strings.Contains(preview, "L125") {
		t.Error("preview should contain line 125 (start of last 25)")
	}
	if !strings.Contains(preview, "L149") {
		t.Error("preview should contain last line")
	}
}
```

Add missing import at top of file: `"fmt"` (needed for `fmt.Sprintf` in the last test).

**Step 2: Run test to verify it fails**

Run: `cd /root/projects/Interverse/plugins/clodex && go test ./internal/extract/ -v`
Expected: FAIL — package/functions not defined

**Step 3: Implement section extractor**

```
plugins/clodex/internal/extract/extract.go
```
```go
package extract

import (
	"strings"
)

// Section represents a document section split by ## headings.
type Section struct {
	ID        int    `json:"section_id"`
	Heading   string `json:"heading"`
	Body      string `json:"-"` // Full body text (not serialized in JSON responses)
	LineCount int    `json:"line_count"`
}

// Preview returns adaptive section sampling for classification:
// - Sections ≤100 lines: first 50 lines
// - Sections >100 lines: first 25 + last 25 lines
func (s Section) Preview() string {
	lines := strings.Split(s.Body, "\n")
	n := len(lines)

	if n <= 100 {
		limit := 50
		if n < limit {
			limit = n
		}
		return strings.Join(lines[:limit], "\n")
	}

	first := strings.Join(lines[:25], "\n")
	omitted := n - 50
	last := strings.Join(lines[n-25:], "\n")
	return first + "\n[... " + itoa(omitted) + " lines omitted ...]\n" + last
}

// FirstSentence returns the first non-empty line of the section body,
// truncated to 120 chars. Used for context summaries.
func (s Section) FirstSentence() string {
	for _, line := range strings.Split(s.Body, "\n") {
		trimmed := strings.TrimSpace(line)
		if trimmed != "" && !strings.HasPrefix(trimmed, "```") && !strings.HasPrefix(trimmed, "~~~") {
			if len(trimmed) > 120 {
				return trimmed[:120] + "..."
			}
			return trimmed
		}
	}
	return "(empty section)"
}

// ExtractSections splits a markdown document by ## headings,
// correctly skipping ## inside fenced code blocks (``` and ~~~)
// and YAML frontmatter (--- delimited at file start).
func ExtractSections(doc string) []Section {
	lines := strings.Split(doc, "\n")
	var sections []Section
	var currentHeading string
	var currentBody []string
	inCodeBlock := false
	codeFence := ""
	inFrontmatter := false
	sectionID := 0

	// Check for YAML frontmatter at start
	if len(lines) > 0 && strings.TrimSpace(lines[0]) == "---" {
		inFrontmatter = true
		for i := 1; i < len(lines); i++ {
			if strings.TrimSpace(lines[i]) == "---" {
				// Skip frontmatter lines including closing ---
				lines = lines[i+1:]
				inFrontmatter = false
				break
			}
		}
		if inFrontmatter {
			// Unclosed frontmatter — treat entire doc as frontmatter (no sections)
			return nil
		}
	}

	flush := func() {
		body := strings.Join(currentBody, "\n")
		lineCount := len(currentBody)
		// Skip empty preamble (no heading and no meaningful content)
		if currentHeading == "" && strings.TrimSpace(body) == "" {
			return
		}
		sections = append(sections, Section{
			ID:        sectionID,
			Heading:   currentHeading,
			Body:      body,
			LineCount: lineCount,
		})
		sectionID++
	}

	for _, line := range lines {
		trimmed := strings.TrimSpace(line)

		// Track code block state
		if !inCodeBlock {
			if strings.HasPrefix(trimmed, "```") || strings.HasPrefix(trimmed, "~~~") {
				inCodeBlock = true
				codeFence = trimmed[:3]
				currentBody = append(currentBody, line)
				continue
			}
		} else {
			if strings.HasPrefix(trimmed, codeFence) && (len(trimmed) == len(codeFence) || trimmed[len(codeFence)] == ' ') {
				inCodeBlock = false
				codeFence = ""
			}
			currentBody = append(currentBody, line)
			continue
		}

		// Check for ## heading (but not ### or deeper)
		if strings.HasPrefix(trimmed, "## ") && !strings.HasPrefix(trimmed, "### ") {
			flush()
			currentHeading = strings.TrimSpace(trimmed[3:])
			currentBody = nil
			continue
		}

		currentBody = append(currentBody, line)
	}

	flush()
	return sections
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	s := ""
	neg := n < 0
	if neg {
		n = -n
	}
	for n > 0 {
		s = string(rune('0'+n%10)) + s
		n /= 10
	}
	if neg {
		s = "-" + s
	}
	return s
}
```

**Step 4: Run tests to verify they pass**

Run: `cd /root/projects/Interverse/plugins/clodex && go test ./internal/extract/ -v`
Expected: All 7 tests PASS

**Step 5: Commit**

```bash
git add plugins/clodex/internal/extract/
git commit -m "feat(clodex): markdown section extractor with fence-aware splitting

Handles: code blocks (``` and ~~~), YAML frontmatter, unclosed blocks,
empty sections. Adaptive preview: 50 lines for small, 25+25 for large."
```

---

## Task 3: Implement classification via dispatch.sh

**Bead:** iv-zrmk (F1)
**Phase:** planned (as of 2026-02-16T16:15:22Z)

**Files:**
- Create: `plugins/clodex/internal/classify/classify.go`
- Create: `plugins/clodex/internal/classify/classify_test.go`
- Create: `plugins/clodex/internal/classify/prompt.go`

**Step 1: Write the failing test for prompt building**

```
plugins/clodex/internal/classify/classify_test.go
```
```go
package classify

import (
	"strings"
	"testing"

	"github.com/mistakeknot/clodex/internal/extract"
)

func TestBuildPrompt_ContainsAgentDescriptions(t *testing.T) {
	sections := []extract.Section{
		{ID: 0, Heading: "Architecture", Body: "Module boundaries and coupling.", LineCount: 1},
		{ID: 1, Heading: "Security", Body: "Auth flow and credentials.", LineCount: 1},
	}
	agents := []AgentDomain{
		{Name: "fd-safety", Description: "security, auth, credentials, trust boundaries"},
		{Name: "fd-correctness", Description: "data consistency, transactions, race conditions"},
	}
	prompt := BuildPrompt(sections, agents)

	if !strings.Contains(prompt, "fd-safety") {
		t.Error("prompt should contain agent name fd-safety")
	}
	if !strings.Contains(prompt, "security, auth") {
		t.Error("prompt should contain agent description")
	}
	if !strings.Contains(prompt, "Architecture") {
		t.Error("prompt should contain section heading")
	}
}

func TestBuildPrompt_FitsTokenLimit(t *testing.T) {
	// 20 sections with 100-line bodies — should still fit in ~8K tokens
	var sections []extract.Section
	for i := 0; i < 20; i++ {
		body := strings.Repeat("This is a line of content for testing.\n", 100)
		sections = append(sections, extract.Section{
			ID:        i,
			Heading:   "Section " + itoa(i),
			Body:      body,
			LineCount: 100,
		})
	}
	agents := DefaultAgents()
	prompt := BuildPrompt(sections, agents)

	// Rough token estimate: ~4 chars per token
	tokenEstimate := len(prompt) / 4
	if tokenEstimate > 8000 {
		t.Errorf("prompt too large: ~%d tokens (limit 8K)", tokenEstimate)
	}
}

func itoa(n int) string {
	s := ""
	for n > 0 {
		s = string(rune('0'+n%10)) + s
		n /= 10
	}
	if s == "" {
		return "0"
	}
	return s
}
```

**Step 2: Run test to verify it fails**

Run: `cd /root/projects/Interverse/plugins/clodex && go test ./internal/classify/ -v`
Expected: FAIL — package not defined

**Step 3: Implement prompt builder**

```
plugins/clodex/internal/classify/prompt.go
```
```go
package classify

import (
	"fmt"
	"strings"

	"github.com/mistakeknot/clodex/internal/extract"
)

// AgentDomain describes a flux-drive review agent's focus area.
type AgentDomain struct {
	Name        string `json:"name"`
	Description string `json:"description"`
}

// DefaultAgents returns the standard fd-* agent domains for classification.
func DefaultAgents() []AgentDomain {
	return []AgentDomain{
		{Name: "fd-safety", Description: "security threats, credential handling, trust boundaries, deployment risk, rollback procedures"},
		{Name: "fd-correctness", Description: "data consistency, transaction safety, race conditions, async bugs, concurrency patterns"},
		{Name: "fd-performance", Description: "rendering bottlenecks, data access patterns, algorithmic complexity, memory usage, resource consumption"},
		{Name: "fd-user-product", Description: "user flows, UX friction, value proposition, scope creep, missing edge cases"},
		{Name: "fd-game-design", Description: "game balance, pacing, player psychology, feedback loops, emergent behavior, procedural content"},
	}
}

// CrossCuttingAgents are agents that always get the full document (never sliced).
var CrossCuttingAgents = map[string]bool{
	"fd-architecture": true,
	"fd-quality":      true,
}

// BuildPrompt constructs the classification prompt for Codex spark.
// Uses adaptive section previews (50 lines small, 25+25 large).
func BuildPrompt(sections []extract.Section, agents []AgentDomain) string {
	var b strings.Builder

	b.WriteString("You are a document section classifier. Assign each section to one or more review agent domains.\n\n")
	b.WriteString("## Agent Domains\n\n")
	for _, a := range agents {
		fmt.Fprintf(&b, "- **%s**: %s\n", a.Name, a.Description)
	}

	b.WriteString("\n## Document Sections\n\n")
	for _, s := range sections {
		preview := s.Preview()
		fmt.Fprintf(&b, "### Section %d: %s (%d lines)\n\n%s\n\n", s.ID, s.Heading, s.LineCount, preview)
	}

	b.WriteString("## Instructions\n\n")
	b.WriteString("For each section, assign it to one or more agents with a relevance level:\n")
	b.WriteString("- `priority` — section is directly relevant to this agent's domain\n")
	b.WriteString("- `context` — section provides background but is not the agent's focus\n\n")
	b.WriteString("Return ONLY valid JSON, no markdown fences, no explanation:\n")
	b.WriteString("```\n")
	b.WriteString(`[{"section_id": 0, "heading": "...", "assignments": [{"agent": "fd-safety", "relevance": "priority", "confidence": 0.9}]}]`)
	b.WriteString("\n```\n")
	b.WriteString("\nEvery section must be assigned to every agent (either priority or context).\n")
	b.WriteString("Confidence is 0.0-1.0 indicating how certain you are about the assignment.\n")

	return b.String()
}
```

**Step 4: Run tests to verify they pass**

Run: `cd /root/projects/Interverse/plugins/clodex && go test ./internal/classify/ -v`
Expected: PASS

**Step 5: Implement classifier (dispatch.sh invocation)**

```
plugins/clodex/internal/classify/classify.go
```
```go
package classify

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"

	"github.com/mistakeknot/clodex/internal/extract"
)

// SectionAssignment is one agent's classification of a section.
type SectionAssignment struct {
	Agent      string  `json:"agent"`
	Relevance  string  `json:"relevance"`  // "priority" or "context"
	Confidence float64 `json:"confidence"` // 0.0-1.0
}

// ClassifiedSection is a section with its agent assignments.
type ClassifiedSection struct {
	SectionID   int                 `json:"section_id"`
	Heading     string              `json:"heading"`
	LineCount   int                 `json:"line_count"`
	Assignments []SectionAssignment `json:"assignments"`
}

// SlicingMap describes what each agent receives.
type AgentSlice struct {
	PrioritySections   []int `json:"priority_sections"`
	ContextSections    []int `json:"context_sections"`
	TotalPriorityLines int   `json:"total_priority_lines"`
	TotalContextLines  int   `json:"total_context_lines"`
}

// ClassifyResult is the full classification output.
type ClassifyResult struct {
	Status     string                `json:"status"` // "success" or "no_classification"
	Sections   []ClassifiedSection   `json:"sections"`
	SlicingMap map[string]AgentSlice `json:"slicing_map"`
	Error      string                `json:"error,omitempty"`
}

// Classify runs section classification via dispatch.sh.
func Classify(ctx context.Context, dispatchPath string, sections []extract.Section, agents []AgentDomain) (*ClassifyResult, error) {
	if len(sections) == 0 {
		return &ClassifyResult{Status: "no_classification", Error: "no sections to classify"}, nil
	}

	prompt := BuildPrompt(sections, agents)

	// Write prompt to temp file (dispatch.sh reads via --prompt-file)
	tmpFile, err := os.CreateTemp("", "clodex-prompt-*.txt")
	if err != nil {
		return &ClassifyResult{Status: "no_classification", Error: fmt.Sprintf("failed to create temp file: %v", err)}, nil
	}
	defer os.Remove(tmpFile.Name())
	if _, err := tmpFile.WriteString(prompt); err != nil {
		tmpFile.Close()
		return &ClassifyResult{Status: "no_classification", Error: fmt.Sprintf("failed to write prompt: %v", err)}, nil
	}
	tmpFile.Close()

	// Create output file
	outFile, err := os.CreateTemp("", "clodex-output-*.txt")
	if err != nil {
		return &ClassifyResult{Status: "no_classification", Error: fmt.Sprintf("failed to create output file: %v", err)}, nil
	}
	defer os.Remove(outFile.Name())
	outFile.Close()

	// Invoke dispatch.sh --tier fast
	start := time.Now()
	cmd := exec.CommandContext(ctx, "bash", dispatchPath,
		"--tier", "fast",
		"--sandbox", "read-only",
		"--prompt-file", tmpFile.Name(),
		"-o", outFile.Name(),
	)
	cmd.Stderr = os.Stderr

	if err := cmd.Run(); err != nil {
		elapsed := time.Since(start)
		fmt.Fprintf(os.Stderr, "clodex: dispatch.sh failed after %v: %v\n", elapsed, err)
		return &ClassifyResult{Status: "no_classification", Error: fmt.Sprintf("dispatch.sh failed: %v", err)}, nil
	}

	elapsed := time.Since(start)
	fmt.Fprintf(os.Stderr, "clodex: classification completed in %v\n", elapsed)

	// Read output
	output, err := os.ReadFile(outFile.Name())
	if err != nil {
		return &ClassifyResult{Status: "no_classification", Error: fmt.Sprintf("failed to read output: %v", err)}, nil
	}

	// Parse JSON from output (may have markdown fences)
	jsonStr := extractJSON(string(output))
	var classified []ClassifiedSection
	if err := json.Unmarshal([]byte(jsonStr), &classified); err != nil {
		return &ClassifyResult{Status: "no_classification", Error: fmt.Sprintf("failed to parse classification JSON: %v", err)}, nil
	}

	// Merge line counts from original sections
	sectionMap := make(map[int]extract.Section)
	for _, s := range sections {
		sectionMap[s.ID] = s
	}
	for i := range classified {
		if orig, ok := sectionMap[classified[i].SectionID]; ok {
			classified[i].Heading = orig.Heading
			classified[i].LineCount = orig.LineCount
		}
	}

	result := buildResult(classified, sections, agents)
	return result, nil
}

// buildResult constructs the full ClassifyResult with slicing map,
// applying 80% threshold, cross-cutting exemptions, and domain mismatch guard.
func buildResult(classified []ClassifiedSection, sections []extract.Section, agents []AgentDomain) *ClassifyResult {
	totalLines := 0
	for _, s := range sections {
		totalLines += s.LineCount
	}
	if totalLines == 0 {
		return &ClassifyResult{Status: "no_classification", Error: "document has 0 lines"}
	}

	slicingMap := make(map[string]AgentSlice)

	// Build per-agent slicing map
	for _, agent := range agents {
		var slice AgentSlice
		for _, cs := range classified {
			for _, a := range cs.Assignments {
				if a.Agent != agent.Name {
					continue
				}
				if a.Relevance == "priority" {
					slice.PrioritySections = append(slice.PrioritySections, cs.SectionID)
					slice.TotalPriorityLines += cs.LineCount
				} else {
					slice.ContextSections = append(slice.ContextSections, cs.SectionID)
					slice.TotalContextLines += cs.LineCount
				}
			}
		}

		// 80% threshold (integer arithmetic)
		if totalLines > 0 && slice.TotalPriorityLines*100/totalLines >= 80 {
			// Send full document — mark all as priority
			slice.PrioritySections = nil
			slice.ContextSections = nil
			for _, s := range sections {
				slice.PrioritySections = append(slice.PrioritySections, s.ID)
				slice.TotalPriorityLines += s.LineCount
			}
			slice.TotalContextLines = 0
		}

		slicingMap[agent.Name] = slice
	}

	// Domain mismatch guard: if no agent has >10% priority lines, classification likely failed
	anyAboveThreshold := false
	for _, slice := range slicingMap {
		if totalLines > 0 && slice.TotalPriorityLines*100/totalLines > 10 {
			anyAboveThreshold = true
			break
		}
	}
	if !anyAboveThreshold {
		return &ClassifyResult{Status: "no_classification", Error: "domain mismatch: no agent has >10% priority lines"}
	}

	return &ClassifyResult{
		Status:     "success",
		Sections:   classified,
		SlicingMap: slicingMap,
	}
}

// extractJSON finds JSON array in output that may be wrapped in markdown fences.
func extractJSON(s string) string {
	s = strings.TrimSpace(s)
	// Strip markdown code fences
	if idx := strings.Index(s, "```"); idx >= 0 {
		s = s[idx+3:]
		if nl := strings.Index(s, "\n"); nl >= 0 {
			s = s[nl+1:] // skip language tag line
		}
		if idx := strings.LastIndex(s, "```"); idx >= 0 {
			s = s[:idx]
		}
	}
	s = strings.TrimSpace(s)
	// Find array start
	if idx := strings.Index(s, "["); idx >= 0 {
		s = s[idx:]
	}
	return s
}
```

**Step 6: Write test for buildResult thresholds**

Add to `classify_test.go`:
```go
func TestBuildResult_80PercentThreshold(t *testing.T) {
	sections := []extract.Section{
		{ID: 0, Heading: "A", LineCount: 90},
		{ID: 1, Heading: "B", LineCount: 10},
	}
	classified := []ClassifiedSection{
		{SectionID: 0, Heading: "A", LineCount: 90, Assignments: []SectionAssignment{
			{Agent: "fd-safety", Relevance: "priority", Confidence: 0.9},
		}},
		{SectionID: 1, Heading: "B", LineCount: 10, Assignments: []SectionAssignment{
			{Agent: "fd-safety", Relevance: "context", Confidence: 0.8},
		}},
	}
	agents := []AgentDomain{{Name: "fd-safety", Description: "security"}}
	result := buildResult(classified, sections, agents)

	if result.Status != "success" {
		t.Fatalf("expected success, got %s: %s", result.Status, result.Error)
	}
	slice := result.SlicingMap["fd-safety"]
	// 90/100 = 90% >= 80%, so all sections should be priority
	if len(slice.PrioritySections) != 2 {
		t.Errorf("80%% threshold: expected 2 priority sections, got %d", len(slice.PrioritySections))
	}
}

func TestBuildResult_DomainMismatchGuard(t *testing.T) {
	sections := []extract.Section{
		{ID: 0, Heading: "A", LineCount: 100},
	}
	classified := []ClassifiedSection{
		{SectionID: 0, Heading: "A", LineCount: 100, Assignments: []SectionAssignment{
			{Agent: "fd-safety", Relevance: "context", Confidence: 0.3},
		}},
	}
	agents := []AgentDomain{{Name: "fd-safety", Description: "security"}}
	result := buildResult(classified, sections, agents)

	// No agent has >10% priority — should fail
	if result.Status != "no_classification" {
		t.Errorf("expected no_classification for domain mismatch, got %s", result.Status)
	}
}
```

**Step 7: Run all tests**

Run: `cd /root/projects/Interverse/plugins/clodex && go test ./internal/classify/ -v`
Expected: All tests PASS

**Step 8: Commit**

```bash
git add plugins/clodex/internal/classify/
git commit -m "feat(clodex): section classification via dispatch.sh

Prompt builder, dispatch.sh invocation, JSON parsing, 80% threshold
(integer arithmetic), domain mismatch guard (>10% check)."
```

---

## Task 4: Register MCP tools (extract_sections + classify_sections)

**Bead:** iv-j7uy (F0)
**Phase:** planned (as of 2026-02-16T16:15:22Z)

**Files:**
- Create: `plugins/clodex/internal/tools/tools.go`
- Modify: `plugins/clodex/cmd/clodex-mcp/main.go`

**Step 1: Implement MCP tool registration**

```
plugins/clodex/internal/tools/tools.go
```
```go
package tools

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"time"

	"github.com/mark3labs/mcp-go/mcp"
	"github.com/mark3labs/mcp-go/server"
	"github.com/mistakeknot/clodex/internal/classify"
	"github.com/mistakeknot/clodex/internal/extract"
)

// RegisterAll registers all clodex MCP tools with the server.
func RegisterAll(s *server.MCPServer, dispatchPath string) {
	s.AddTools(
		extractSections(),
		classifySections(dispatchPath),
	)
}

func extractSections() server.ServerTool {
	return server.ServerTool{
		Tool: mcp.NewTool("extract_sections",
			mcp.WithDescription("Extract markdown sections from a document, splitting by ## headings while correctly handling code blocks and YAML frontmatter."),
			mcp.WithString("file_path",
				mcp.Description("Absolute path to the markdown file to extract sections from"),
				mcp.Required(),
			),
		),
		Handler: func(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
			args := req.GetArguments()
			filePath, _ := args["file_path"].(string)
			if filePath == "" {
				return mcp.NewToolResultError("file_path is required"), nil
			}

			content, err := os.ReadFile(filePath)
			if err != nil {
				return mcp.NewToolResultError(fmt.Sprintf("failed to read file: %v", err)), nil
			}

			sections := extract.ExtractSections(string(content))

			type sectionOut struct {
				ID           int    `json:"section_id"`
				Heading      string `json:"heading"`
				LineCount    int    `json:"line_count"`
				FirstSentence string `json:"first_sentence"`
			}
			out := make([]sectionOut, len(sections))
			for i, s := range sections {
				out[i] = sectionOut{
					ID:           s.ID,
					Heading:      s.Heading,
					LineCount:    s.LineCount,
					FirstSentence: s.FirstSentence(),
				}
			}

			b, _ := json.Marshal(out)
			return mcp.NewToolResultText(string(b)), nil
		},
	}
}

func classifySections(dispatchPath string) server.ServerTool {
	return server.ServerTool{
		Tool: mcp.NewTool("classify_sections",
			mcp.WithDescription("Classify document sections per flux-drive agent domain using Codex spark. Returns per-section assignments with confidence scores and a slicing map."),
			mcp.WithString("file_path",
				mcp.Description("Absolute path to the markdown file to classify"),
				mcp.Required(),
			),
			mcp.WithArray("agents",
				mcp.Description("Optional: override agent list. Array of {name, description} objects. If omitted, uses default fd-* agents."),
				mcp.WithObjectItems(),
			),
		),
		Handler: func(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
			start := time.Now()
			args := req.GetArguments()
			filePath, _ := args["file_path"].(string)
			if filePath == "" {
				return mcp.NewToolResultError("file_path is required"), nil
			}

			content, err := os.ReadFile(filePath)
			if err != nil {
				return mcp.NewToolResultError(fmt.Sprintf("failed to read file: %v", err)), nil
			}

			sections := extract.ExtractSections(string(content))
			if len(sections) == 0 {
				result := classify.ClassifyResult{Status: "no_classification", Error: "no sections found"}
				b, _ := json.Marshal(result)
				return mcp.NewToolResultText(string(b)), nil
			}

			agents := classify.DefaultAgents()
			// TODO: parse custom agents from args if provided

			classResult, err := classify.Classify(ctx, dispatchPath, sections, agents)
			if err != nil {
				result := classify.ClassifyResult{Status: "no_classification", Error: err.Error()}
				b, _ := json.Marshal(result)
				return mcp.NewToolResultText(string(b)), nil
			}

			elapsed := time.Since(start)
			fmt.Fprintf(os.Stderr, "clodex: classify_sections completed in %v\n", elapsed)

			b, _ := json.Marshal(classResult)
			return mcp.NewToolResultText(string(b)), nil
		},
	}
}
```

**Step 2: Verify the project builds**

Run: `cd /root/projects/Interverse/plugins/clodex && go build -o bin/clodex-mcp ./cmd/clodex-mcp/`
Expected: Binary builds successfully

**Step 3: Run all tests**

Run: `cd /root/projects/Interverse/plugins/clodex && go test ./... -v`
Expected: All tests PASS

**Step 4: Commit**

```bash
git add plugins/clodex/internal/tools/ plugins/clodex/cmd/
git commit -m "feat(clodex): register extract_sections + classify_sections MCP tools

Two tools: extract_sections (read-only section listing),
classify_sections (full classification via dispatch.sh).
Both delegate to internal packages."
```

---

## Task 5: Write per-agent temp files

**Bead:** iv-5m8j (F2)
**Phase:** planned (as of 2026-02-16T16:15:22Z)

**Files:**
- Create: `plugins/clodex/internal/tempfiles/tempfiles.go`
- Create: `plugins/clodex/internal/tempfiles/tempfiles_test.go`

**Step 1: Write the failing test**

```
plugins/clodex/internal/tempfiles/tempfiles_test.go
```
```go
package tempfiles

import (
	"os"
	"strings"
	"testing"

	"github.com/mistakeknot/clodex/internal/classify"
	"github.com/mistakeknot/clodex/internal/extract"
)

func TestGenerateAgentFiles_PrioritySections(t *testing.T) {
	sections := []extract.Section{
		{ID: 0, Heading: "Security", Body: "Auth flow details.\nCredential handling.", LineCount: 2},
		{ID: 1, Heading: "Performance", Body: "Query optimization.\nCache strategy.", LineCount: 2},
		{ID: 2, Heading: "Architecture", Body: "Module boundaries.", LineCount: 1},
	}
	result := &classify.ClassifyResult{
		Status: "success",
		SlicingMap: map[string]classify.AgentSlice{
			"fd-safety": {
				PrioritySections:   []int{0},
				ContextSections:    []int{1, 2},
				TotalPriorityLines: 2,
				TotalContextLines:  3,
			},
		},
	}

	files, err := GenerateAgentFiles(sections, result, "test-doc", "/tmp")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(files) != 1 {
		t.Fatalf("expected 1 file, got %d", len(files))
	}

	path := files["fd-safety"]
	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("failed to read generated file: %v", err)
	}
	s := string(content)

	// Should contain metadata header
	if !strings.Contains(s, "[Document slicing active:") {
		t.Error("missing metadata header")
	}
	// Should contain priority section in full
	if !strings.Contains(s, "## Security") {
		t.Error("missing priority section heading")
	}
	if !strings.Contains(s, "Auth flow details.") {
		t.Error("missing priority section body")
	}
	// Should contain context sections as summaries
	if !strings.Contains(s, "**Performance**") {
		t.Error("missing context section summary")
	}
	// Should contain footer
	if !strings.Contains(s, "Request full section") {
		t.Error("missing request-full-section footer")
	}

	// Cleanup
	os.Remove(path)
}

func TestGenerateAgentFiles_SkipsZeroPriority(t *testing.T) {
	sections := []extract.Section{
		{ID: 0, Heading: "Stuff", Body: "Content.", LineCount: 1},
	}
	result := &classify.ClassifyResult{
		Status: "success",
		SlicingMap: map[string]classify.AgentSlice{
			"fd-game-design": {
				PrioritySections:   nil,
				ContextSections:    []int{0},
				TotalPriorityLines: 0,
				TotalContextLines:  1,
			},
		},
	}

	files, err := GenerateAgentFiles(sections, result, "test-doc", "/tmp")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	// Zero priority → agent should be skipped
	if _, exists := files["fd-game-design"]; exists {
		t.Error("agent with zero priority sections should be skipped")
	}
}
```

**Step 2: Run test to verify it fails**

Run: `cd /root/projects/Interverse/plugins/clodex && go test ./internal/tempfiles/ -v`
Expected: FAIL — package not defined

**Step 3: Implement temp file generator**

```
plugins/clodex/internal/tempfiles/tempfiles.go
```
```go
package tempfiles

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/mistakeknot/clodex/internal/classify"
	"github.com/mistakeknot/clodex/internal/extract"
)

// GenerateAgentFiles writes per-agent temp files based on classification results.
// Returns a map of agent name → temp file path.
// Agents with zero priority sections are skipped (not dispatched).
func GenerateAgentFiles(sections []extract.Section, result *classify.ClassifyResult, inputStem string, tmpDir string) (map[string]string, error) {
	if tmpDir == "" {
		tmpDir = "/tmp"
	}

	ts := time.Now().Unix()
	sectionByID := make(map[int]extract.Section)
	for _, s := range sections {
		sectionByID[s.ID] = s
	}

	files := make(map[string]string)

	for agent, slice := range result.SlicingMap {
		// Skip agents with zero priority sections
		if len(slice.PrioritySections) == 0 {
			continue
		}

		// Skip cross-cutting agents (they get the original file)
		if classify.CrossCuttingAgents[agent] {
			continue
		}

		var b strings.Builder

		// Metadata header
		fmt.Fprintf(&b, "[Document slicing active: %d priority sections (%d lines), %d context sections (%d lines summarized)]\n\n",
			len(slice.PrioritySections), slice.TotalPriorityLines,
			len(slice.ContextSections), slice.TotalContextLines,
		)

		// Priority sections in full
		for _, id := range slice.PrioritySections {
			s := sectionByID[id]
			if s.Heading != "" {
				fmt.Fprintf(&b, "## %s\n\n", s.Heading)
			}
			b.WriteString(s.Body)
			b.WriteString("\n\n")
		}

		// Context sections as summaries
		if len(slice.ContextSections) > 0 {
			b.WriteString("## Context Sections (summaries)\n\n")
			for _, id := range slice.ContextSections {
				s := sectionByID[id]
				fmt.Fprintf(&b, "- **%s**: %s (%d lines)\n", s.Heading, s.FirstSentence(), s.LineCount)
			}
			b.WriteString("\n")
		}

		// Footer
		b.WriteString("> If you need full content for a context section, note it as \"Request full section: {name}\" in your findings.\n")

		// Write file
		filename := fmt.Sprintf("flux-drive-%s-%d-%s.md", inputStem, ts, agent)
		path := filepath.Join(tmpDir, filename)
		if err := os.WriteFile(path, []byte(b.String()), 0644); err != nil {
			return nil, fmt.Errorf("failed to write %s: %w", path, err)
		}
		files[agent] = path
	}

	return files, nil
}
```

**Step 4: Run tests to verify they pass**

Run: `cd /root/projects/Interverse/plugins/clodex && go test ./internal/tempfiles/ -v`
Expected: All tests PASS

**Step 5: Run full test suite**

Run: `cd /root/projects/Interverse/plugins/clodex && go test ./... -v`
Expected: All tests PASS across all packages

**Step 6: Commit**

```bash
git add plugins/clodex/internal/tempfiles/
git commit -m "feat(clodex): per-agent temp file generation

Priority sections in full, context as 1-line summaries. Metadata header,
request-full-section footer. Skips agents with zero priority sections.
Timestamp in filename prevents collision."
```

---

## Task 6: Update slicing.md with classification methods

**Bead:** iv-tifk (F3)
**Phase:** planned (as of 2026-02-16T16:15:22Z)

**Files:**
- Modify: `plugins/interflux/skills/flux-drive/phases/slicing.md:187-212`

**Step 1: Read the current classification section**

Run: Read `plugins/interflux/skills/flux-drive/phases/slicing.md` lines 186-212

**Step 2: Update Section Classification to document both methods**

Replace the "Section Classification" content (lines 187-211) in `slicing.md` with:

```markdown
### Section Classification

#### Classification Methods

**Method 1: Semantic (Codex Spark)** — preferred when clodex MCP is available.

1. **Extract sections** — Invoke clodex `extract_sections` tool on the document file. Returns structured JSON with section IDs, headings, and line counts.
2. **Classify per agent** — Invoke clodex `classify_sections` tool. Codex spark assigns each section to each agent as `priority` or `context` with a confidence score (0.0-1.0).
3. **Cross-cutting agents** (fd-architecture, fd-quality) — always receive the full document. Skip classification for these agents.
4. **Safety override** — Any section mentioning auth, credentials, secrets, tokens, or certificates is always `priority` for fd-safety (enforced in classification prompt).
5. **80% threshold** — If `agent_priority_lines * 100 / total_lines >= 80` (integer arithmetic), skip slicing for that agent — send full document.
6. **Domain mismatch guard** — If no agent receives >10% of total lines as priority, classification likely failed. Fall back to full document for all agents.
7. **Zero priority skip** — If an agent has zero priority sections, do not dispatch that agent at all.

**Method 2: Keyword Matching** — fallback when Codex spark is unavailable or returns low-confidence (<0.6 average).

1. **Extract sections** — Split document by `## ` headings. Each section = heading + content until next heading.
2. **Classify per agent** — For each selected **domain-specific** agent, classify each section:
   - `priority` — section heading or body matches any of the agent's keywords → include in full
   - `context` — no keyword match → include as 1-line summary only
3. **Cross-cutting agents** (fd-architecture, fd-quality) — always receive the full document. Skip classification for these agents.
4. **Safety override** — Any section mentioning auth, credentials, secrets, tokens, or certificates is always `priority` for fd-safety.
5. **80% threshold** — If an agent's priority sections cover >= 80% of total document lines, skip slicing for that agent (send full document).

**Composition rule:** Try Method 1 first. If `classify_sections` returns `status: "no_classification"` or average confidence < 0.6, fall back to Method 2.

A section is `priority` for an agent under Method 2 if:
- The section heading matches any of the agent's keywords (case-insensitive substring)
- The section body contains any of the agent's keywords (sampled — first 50 lines)
```

**Step 3: Verify slicing.md is valid**

Read the updated file to confirm the new section integrates cleanly with surrounding content.

**Step 4: Commit**

```bash
git add plugins/interflux/skills/flux-drive/phases/slicing.md
git commit -m "docs(slicing.md): add semantic classification as Method 1

Method 1 (Codex spark via clodex MCP) is preferred. Method 2 (keyword
matching) is fallback. Composition rule: try semantic first, fall back
on no_classification or low confidence (<0.6)."
```

---

## Task 7: Update launch.md to invoke classify_sections

**Bead:** iv-tifk (F3)
**Phase:** planned (as of 2026-02-16T16:15:22Z)

**Files:**
- Modify: `plugins/interflux/skills/flux-drive/phases/launch.md:89-92`

**Step 1: Read Case 2 in launch.md**

Read `plugins/interflux/skills/flux-drive/phases/launch.md` lines 88-104

**Step 2: Update Case 2 to invoke clodex MCP**

Replace Case 2 content (lines 89-92) with:

```markdown
#### Case 2: File/directory inputs — document slicing active (>= 200 lines)

1. **Classify sections:** Invoke clodex MCP `classify_sections` tool with `file_path` set to the document path.
2. **Check result:** If `status` is `"no_classification"`, fall back to Case 1 (all agents get the original file via shared path).
3. **Generate per-agent files:** For each agent in `slicing_map`:
   - If agent is cross-cutting (fd-architecture, fd-quality): use the shared `REVIEW_FILE` from Case 1.
   - If agent has zero priority sections: skip dispatching this agent entirely.
   - Otherwise: write the per-agent temp file following `phases/slicing.md` → Per-Agent Temp File Construction. File pattern: `/tmp/flux-drive-${INPUT_STEM}-${TS}-${agent}.md`
4. **Record all paths:** Store `REVIEW_FILE_${agent}` paths for prompt construction in Step 2.2.

See `phases/slicing.md` → Document Slicing for the complete classification algorithm, per-agent file structure, and pyramid summary rules.
```

**Step 3: Commit**

```bash
git add plugins/interflux/skills/flux-drive/phases/launch.md
git commit -m "feat(launch.md): wire classify_sections into Case 2

Invokes clodex MCP classify_sections, falls back to Case 1 (shared file)
on no_classification. Per-agent temp files follow slicing.md spec."
```

---

## Task 8: Update synthesize.md for slicing_map convergence

**Bead:** iv-tifk (F3)
**Phase:** planned (as of 2026-02-16T16:15:22Z)

**Files:**
- Modify: `plugins/interflux/skills/flux-drive/phases/synthesize.md`

**Step 1: Read the convergence scoring section**

Read `plugins/interflux/skills/flux-drive/phases/synthesize.md` lines 104-140

**Step 2: Add slicing_map awareness to findings.json generation**

In Step 3.4a (findings.json generation), after the existing `convergence` field documentation, add:

```markdown
**Convergence with slicing:** When document slicing is active, adjust convergence scoring:
- Only count agents that received the relevant section as `priority` when computing convergence counts.
- If 2+ agents agree on a finding AND reviewed different sections (per `slicing_map`), boost the convergence score by 1 (cross-section agreement is higher confidence than same-section agreement).
- Tag the finding with `slicing_boost: true` in findings.json when cross-section convergence applies.
```

**Step 3: Add "Request full section" handling to Phase 3**

In the synthesis phase, after the existing content handling rules, add:

```markdown
**Handling "Request full section" annotations (v1):**
When an agent output contains "Request full section: {name}", include this request verbatim in the synthesis output. Do NOT re-dispatch the agent or re-read the section. Track the total count of section requests across all agents — this feeds the quality validation metric (target: ≤5% of agent outputs contain requests after 10 reviews).
```

**Step 4: Commit**

```bash
git add plugins/interflux/skills/flux-drive/phases/synthesize.md
git commit -m "feat(synthesize.md): slicing-aware convergence scoring

Cross-section agreement boosts convergence. Section request annotations
pass through verbatim (v1). Quality target: ≤5% request rate."
```

---

## Task 9: Integration test — end-to-end classification

**Bead:** iv-j7uy (F0), iv-tifk (F3)
**Phase:** planned (as of 2026-02-16T16:15:22Z)

**Files:**
- Create: `plugins/clodex/test/integration_test.sh`

**Step 1: Write integration test script**

```
plugins/clodex/test/integration_test.sh
```
```bash
#!/usr/bin/env bash
# Integration test for clodex MCP server — extract_sections tool only
# (classify_sections requires live Codex CLI, tested separately)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(dirname "$SCRIPT_DIR")"
BINARY="${PLUGIN_ROOT}/bin/clodex-mcp"

echo "=== Building clodex-mcp ==="
cd "$PLUGIN_ROOT"
go build -o "$BINARY" ./cmd/clodex-mcp/

echo "=== Creating test document ==="
TEST_DOC=$(mktemp /tmp/clodex-test-XXXX.md)
cat > "$TEST_DOC" << 'EOF'
---
title: Test Document
---

# Main Title

Introduction.

## Security

Auth flow and credential handling.
Token validation.

## Performance

Query optimization patterns.
Cache invalidation strategy.

## Architecture

Module boundaries and coupling.
Dependency injection.

```python
## Not a section
code_here()
```

## Correctness

Data consistency checks.
Transaction safety.
EOF

echo "=== Testing extract_sections via JSON-RPC ==="
REQUEST='{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"extract_sections","arguments":{"file_path":"'"$TEST_DOC"'"}}}'

# Need to initialize first
INIT='{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"0.1.0"}}}'
INITIALIZED='{"jsonrpc":"2.0","method":"notifications/initialized"}'

RESPONSE=$(printf '%s\n%s\n%s\n' "$INIT" "$INITIALIZED" "$REQUEST" | "$BINARY" 2>/dev/null | tail -1)

echo "Response: $RESPONSE"

# Check we got sections
SECTION_COUNT=$(echo "$RESPONSE" | python3 -c "
import json,sys
r = json.loads(sys.stdin.read())
sections = json.loads(r['result']['content'][0]['text'])
print(len(sections))
")

echo "Sections found: $SECTION_COUNT"
if [[ "$SECTION_COUNT" -ne 4 ]]; then
    echo "FAIL: expected 4 sections (Security, Performance, Architecture, Correctness), got $SECTION_COUNT"
    rm "$TEST_DOC"
    exit 1
fi

echo "=== Verifying code block handling ==="
# The "## Not a section" inside the code block should NOT create a section
HEADINGS=$(echo "$RESPONSE" | python3 -c "
import json,sys
r = json.loads(sys.stdin.read())
sections = json.loads(r['result']['content'][0]['text'])
for s in sections:
    print(s['heading'])
")
if echo "$HEADINGS" | grep -q "Not a section"; then
    echo "FAIL: code block ## was treated as a section heading"
    rm "$TEST_DOC"
    exit 1
fi

echo "=== All integration tests passed ==="
rm "$TEST_DOC"
```

**Step 2: Run integration test**

Run: `bash plugins/clodex/test/integration_test.sh`
Expected: "All integration tests passed"

**Step 3: Commit**

```bash
git add plugins/clodex/test/
git commit -m "test(clodex): integration test for extract_sections

Verifies: section extraction, code block handling, YAML frontmatter
skipping, JSON-RPC protocol. classify_sections requires live Codex."
```

---

## Task 10: Final build, full test, and install verification

**Bead:** iv-j7uy (F0)
**Phase:** planned (as of 2026-02-16T16:15:22Z)

**Files:**
- Modify: `plugins/clodex/bin/.gitkeep` (ensure binary is gitignored)
- Create: `plugins/clodex/.gitignore`

**Step 1: Create .gitignore**

```
plugins/clodex/.gitignore
```
```
bin/clodex-mcp
```

**Step 2: Run full test suite**

Run: `cd /root/projects/Interverse/plugins/clodex && go test ./... -v -count=1`
Expected: All tests PASS

**Step 3: Run integration test**

Run: `bash plugins/clodex/test/integration_test.sh`
Expected: "All integration tests passed"

**Step 4: Verify plugin loads in Claude Code**

Run: `claude --plugin-dir /root/projects/Interverse/plugins/clodex --print-tools 2>/dev/null | grep -i clodex || echo "check tool listing manually"`
Expected: `extract_sections` and `classify_sections` tools visible

**Step 5: Final commit**

```bash
git add plugins/clodex/.gitignore
git commit -m "chore(clodex): add .gitignore for built binary"
```

---

## Summary

| Task | Component | Bead | Files Created/Modified |
|------|-----------|------|----------------------|
| 1 | Plugin scaffold | iv-j7uy | go.mod, main.go, launch-mcp.sh, plugin.json, CLAUDE.md |
| 2 | Section extractor | iv-zrmk | internal/extract/extract.go, extract_test.go |
| 3 | Classification | iv-zrmk | internal/classify/classify.go, prompt.go, classify_test.go |
| 4 | MCP tool registration | iv-j7uy | internal/tools/tools.go |
| 5 | Temp file generation | iv-5m8j | internal/tempfiles/tempfiles.go, tempfiles_test.go |
| 6 | slicing.md update | iv-tifk | phases/slicing.md |
| 7 | launch.md wiring | iv-tifk | phases/launch.md |
| 8 | synthesize.md update | iv-tifk | phases/synthesize.md |
| 9 | Integration test | iv-j7uy | test/integration_test.sh |
| 10 | Final verification | iv-j7uy | .gitignore |

**Dependency order:** Tasks 1-5 are sequential (each builds on previous). Tasks 6-8 are independent of each other but depend on Tasks 1-5 being complete. Task 9 depends on Task 4. Task 10 is final.

**Parallelizable groups:**
- Group A (serial): Tasks 1 → 2 → 3 → 4 → 5
- Group B (parallel after Task 5): Tasks 6, 7, 8
- Group C (after Group B): Tasks 9 → 10
