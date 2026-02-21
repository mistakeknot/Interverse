# Read-Set Inference in LLM Agent Systems

**Date**: 2026-02-20
**Context**: Multi-agent orchestrator (Go+SQLite+Git) where agents (Claude Code, Codex CLI) read files through opaque tool calls (Read, Grep, Glob). The kernel dispatches agents as subprocesses, agents produce code patches, and we need to know WHAT files the agent read to perform OCC (optimistic concurrency control) read-set validation before merging.

---

## Table of Contents

1. [Problem Statement](#problem-statement)
2. [Approach 1: Tool-Call Provenance Tracking](#approach-1-tool-call-provenance-tracking)
3. [Approach 2: Context Window Auditing via Hooks](#approach-2-context-window-auditing-via-hooks)
4. [Approach 3: Filesystem-Level Tracking](#approach-3-filesystem-level-tracking)
5. [Approach 4: Agent-Declared Dependencies](#approach-4-agent-declared-dependencies)
6. [Approach 5: Academic & Research Work](#approach-5-academic--research-work)
7. [Approach Comparison Matrix](#approach-comparison-matrix)
8. [Recommended Architecture for Go+SQLite+Git](#recommended-architecture-for-gosqlitegit)
9. [Sources](#sources)

---

## Problem Statement

In classic OCC (Kung-Robinson, 1981), a transaction has three phases:

1. **Read phase**: Transaction reads data, records what it touched (the read-set)
2. **Validation phase**: Before commit, verify no other transaction modified anything in the read-set
3. **Write phase**: If validation passes, apply changes

Our multi-agent system maps directly to this model:

- **Read phase**: Agent subprocess runs, reads files via tool calls, reasons, produces a patch
- **Validation phase**: Before merging the patch, verify that no other agent (or human) modified files in the read-set since dispatch time
- **Write phase**: Apply the patch (git merge/cherry-pick)

The challenge is that agents are black boxes from the kernel's perspective. The agent receives a prompt, makes opaque API calls to Claude/GPT, which internally invoke tools (Read, Grep, Glob, Bash), and the kernel only sees the final output (a diff/patch). We need to reconstruct the read-set.

---

## Approach 1: Tool-Call Provenance Tracking

### Current State of Agent Frameworks

**No major agent framework provides automatic read-set extraction.** However, most now provide tool-call logging infrastructure that could be used to build one:

#### LangChain / LangGraph + LangSmith

- LangSmith traces capture every tool call with inputs and outputs as structured spans
- Tool calls include function name, arguments (file paths, patterns), and return values
- Traces are exportable via API and can be queried programmatically
- **Read-set extraction**: Parse traces for tool calls to `ReadFileTool`, `FileSearchTool`, etc., extract `file_path` arguments
- **Limitation**: In-process Python only; no subprocess/CLI support
- **Overhead**: LangSmith claims "virtually no measurable overhead" via async callback handler

#### OpenAI Agents SDK

- Built-in tracing captures LLM generations, tool calls, handoffs, and guardrails
- Each trace has `trace_id` and structured spans with tool inputs/outputs
- Traces exportable to Langfuse, AgentOps, or OpenTelemetry
- **Read-set extraction**: Query traces for file-access tool invocations, extract paths from arguments
- **Limitation**: Python SDK only; doesn't apply to Codex CLI subprocess model

#### AgentOps

- Cross-framework monitoring SDK (CrewAI, LangChain, AutoGen, OpenAI Agents SDK)
- Records comprehensive event logs including tool calls with full request/response data
- Session replay capability for debugging
- **Read-set extraction**: Post-hoc query of session events for file-access tools
- **Limitation**: Python instrumentation library; requires in-process integration

#### Codex CLI

- Uses OS-enforced sandbox (Linux namespaces) with configurable write permissions
- Sandbox modes: `read-only` (default), `workspace-write`, `danger-full-access`
- Protected paths enforced at OS level
- **Read-set inference**: The sandbox approach means Codex can read anything in the workspace but only write to specific locations. The sandbox itself doesn't track reads, only enforces write restrictions.
- **No built-in read-set export**

### Feasibility for Go+SQLite+Git Subprocess Model

**Low direct applicability.** These frameworks are Python-native and assume in-process agent execution. Our agents run as subprocesses (claude CLI, codex CLI). We cannot instrument them with Python SDK callbacks.

**However**, the architectural pattern is clear: intercept tool calls at the framework boundary, log them to a structured store, and query post-hoc for read operations. We need to replicate this pattern at the subprocess boundary.

---

## Approach 2: Context Window Auditing via Hooks

### Claude Code Hooks (Primary Mechanism)

Claude Code provides a comprehensive hook system that fires at specific lifecycle points. The hooks most relevant to read-set tracking are:

#### PostToolUse Event

Fires after every successful tool call. The hook receives JSON on stdin with the complete tool invocation:

```json
{
  "session_id": "abc123",
  "transcript_path": "/path/to/transcript.jsonl",
  "cwd": "/working/dir",
  "hook_event_name": "PostToolUse",
  "tool_name": "Read",
  "tool_input": {
    "file_path": "/path/to/file.txt",
    "offset": 10,
    "limit": 50
  },
  "tool_response": {
    "filePath": "/path/to/file.txt",
    "success": true
  },
  "tool_use_id": "toolu_01ABC123..."
}
```

#### Tool Input Schemas Available

| Tool | Key Fields for Read-Set | What It Tells Us |
|------|------------------------|------------------|
| `Read` | `file_path`, `offset`, `limit` | Agent read this file (possibly partial) |
| `Grep` | `pattern`, `path`, `glob`, `output_mode` | Agent searched for content; `path` is the search root |
| `Glob` | `pattern`, `path` | Agent discovered files matching pattern |
| `Bash` | `command` | Agent ran a shell command (may read files opaquely) |
| `Edit` | `file_path`, `old_string`, `new_string` | Agent modified this file (write-set, but implies prior read) |
| `Write` | `file_path`, `content` | Agent created/overwrote this file (write-set) |
| `WebFetch` | `url` | External resource (not file-system) |

#### Implementation: Read-Set Collector Hook

A PostToolUse hook can collect read-set entries in real-time:

```bash
#!/bin/bash
# read-set-collector.sh — PostToolUse hook
INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name')
SESSION=$(echo "$INPUT" | jq -r '.session_id')
READSET_FILE="/tmp/readset-${SESSION}.jsonl"

case "$TOOL" in
  Read)
    FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path')
    echo "{\"tool\":\"Read\",\"path\":\"$FILE_PATH\",\"ts\":$(date +%s)}" >> "$READSET_FILE"
    ;;
  Grep)
    SEARCH_PATH=$(echo "$INPUT" | jq -r '.tool_input.path // .cwd')
    # For Grep, the read-set is conservatively the entire search path
    echo "{\"tool\":\"Grep\",\"path\":\"$SEARCH_PATH\",\"ts\":$(date +%s)}" >> "$READSET_FILE"
    ;;
  Glob)
    SEARCH_PATH=$(echo "$INPUT" | jq -r '.tool_input.path // .cwd')
    echo "{\"tool\":\"Glob\",\"path\":\"$SEARCH_PATH\",\"ts\":$(date +%s)}" >> "$READSET_FILE"
    ;;
  Bash)
    # Bash is opaque — command may read arbitrary files
    COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command')
    echo "{\"tool\":\"Bash\",\"command\":\"$COMMAND\",\"ts\":$(date +%s)}" >> "$READSET_FILE"
    ;;
esac
exit 0
```

Hook configuration in `.claude/settings.json`:

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Read|Grep|Glob|Bash|Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "/path/to/read-set-collector.sh"
          }
        ]
      }
    ]
  }
}
```

#### Strengths

- **Direct, reliable, and complete** for Read/Grep/Glob tool calls
- **No kernel modification required** — hooks are a plugin/config concern
- **Real-time collection** — entries written as agent executes
- **Low overhead** — simple jq+append; async hooks available for zero blocking
- **Precise file paths** for Read and Edit/Write tools
- **Compatible with subprocess model** — hooks run in the agent's process context, output to files the kernel can read

#### Weaknesses

- **Bash tool is opaque**: `Bash("cat foo.txt | grep bar")` reads `foo.txt` but the hook only sees the command string, not which files were actually opened. Requires heuristic parsing or conservative over-approximation.
- **Grep/Glob return sets, not individual files**: When the agent greps a directory, the read-set is conservatively the entire directory. The `tool_response` field could contain matched file paths, but responses may be large.
- **Claude Code specific**: Does not apply to Codex CLI or other agent runtimes. Each runtime needs its own hook integration.
- **Subagent complexity**: Claude Code spawns subagents via the Task tool. SubagentStart/SubagentStop hooks exist but don't expose the subagent's tool calls. The subagent has its own transcript at `agent_transcript_path` which could be parsed post-hoc.

#### Codex CLI Equivalent

Codex CLI does not have an equivalent hook system. However, it operates in a sandbox with configurable filesystem access. The `apply_patch` tool captures write-set explicitly. For read-set, alternatives:

- Parse the Codex conversation log/trace (if available via API)
- Use filesystem-level tracking (Approach 3)
- Require agent-declared dependencies (Approach 4)

### Transcript Parsing (Post-Hoc)

Both Claude Code and Codex CLI produce conversation transcripts (JSONL format). These contain every tool call with inputs and outputs. Post-hoc parsing can reconstruct the read-set:

```go
// Pseudo-code for transcript-based read-set extraction
func ExtractReadSet(transcriptPath string) ([]string, error) {
    readSet := map[string]struct{}{}
    scanner := bufio.NewScanner(file)
    for scanner.Scan() {
        var event TranscriptEvent
        json.Unmarshal(scanner.Bytes(), &event)
        if event.Type == "tool_use" {
            switch event.ToolName {
            case "Read", "Edit", "Write":
                readSet[event.Input.FilePath] = struct{}{}
            case "Grep", "Glob":
                // Conservative: add search root
                readSet[event.Input.Path] = struct{}{}
            }
        }
    }
    return keys(readSet), nil
}
```

**Trade-off**: Post-hoc parsing is simpler (no hook infrastructure) but only available after the agent completes. Real-time hooks allow early abort if a conflict is detected mid-execution.

---

## Approach 3: Filesystem-Level Tracking

### inotifywait

- Watches file events (open, read, modify, close) at the filesystem level
- Per-file granularity, but limited ability to filter by process
- **Limitation**: inotify watches are per-directory and have a system-wide limit (`/proc/sys/fs/inotify/max_user_watches`). Watching an entire project tree is feasible but resource-intensive.
- **Process attribution**: inotify events do NOT include the PID of the accessing process. This is a fatal flaw for multi-agent scenarios where multiple agents run concurrently.
- **Performance**: Low overhead for moderate watch counts. Problematic at scale (thousands of files).

### eBPF (FSProbe, Datadog approach)

- Hooks at the VFS level in the kernel, capturing all file operations with full process context (PID, comm, UID)
- FSProbe provides Go-compatible eBPF programs for file event monitoring
- Datadog's workload protection uses eBPF to filter billions of kernel events per minute
- **Process attribution**: Full PID/TID tracking, can correlate reads with specific agent subprocesses
- **Performance**: Measured in nanoseconds per operation for eBPF probe execution. Overhead comes from dentry path resolution (varies by method: 1-10 microseconds per event)
- **Go integration**: Libraries like `cilium/ebpf` and `Gui774ume/fsprobe` provide Go bindings
- **Limitation**: Requires Linux kernel 5.x+, root or `CAP_BPF` capability. The orchestrator would need to manage eBPF program lifecycle.

**Implementation sketch for Go orchestrator:**

```go
// Conceptual: eBPF-based read-set tracker
type ReadSetTracker struct {
    bpfProg  *ebpf.Collection
    events   chan FileEvent
    readSets map[int][]string  // PID -> files read
}

func (t *ReadSetTracker) StartTracking(pid int) {
    // Load eBPF program that filters for this PID
    // Attach to vfs_read, vfs_open kprobes
    // Collect events in ring buffer
}

func (t *ReadSetTracker) StopTracking(pid int) []string {
    // Return accumulated read-set for this PID
    // Includes files read by child processes (traced via fork)
}
```

### FUSE (Filesystem in Userspace)

- Create a virtual filesystem overlay that intercepts all file operations
- Agent reads files through the FUSE mount; every read is logged by the FUSE daemon
- **Process attribution**: FUSE handler receives the PID of the caller via `fuse_req_ctx()`
- **Performance**: Significantly higher overhead than native filesystem access. Each read requires user-kernel-user context switch. Measured at 2-10x slowdown for I/O-heavy workloads.
- **Complexity**: Requires mounting a FUSE filesystem for each agent session, routing agent's working directory through it
- **Go integration**: `hanwen/go-fuse` is a mature Go FUSE library

### strace

- Trace system calls of a subprocess and its children (`strace -f -e trace=openat,read`)
- Captures every `openat()` call with the full path
- **Process attribution**: Built-in, traces the specific PID tree
- **Performance**: Substantial overhead (2-5x slowdown) due to ptrace mechanism. Each syscall requires two context switches.
- **Go integration**: Launch agent subprocess under strace, parse output
- **Limitation**: ptrace is heavyweight and can interfere with agent behavior. Some runtimes (Node.js) make many syscalls unrelated to agent logic. Filtering signal from noise is challenging.

### Landlock LSM

- Linux Security Module for unprivileged filesystem sandboxing (kernel 5.13+)
- Allows declaring which paths a process can read/write
- **Key insight**: Landlock can be used not for access control but for access monitoring. If the agent tries to read a file not in the declared read-set, the kernel returns `EACCES`.
- Go libraries: `landlock-lsm/go-landlock`, `shoenig/go-landlock`
- **Process inheritance**: Landlock restrictions cascade to child processes automatically
- **Limitation**: Landlock is one-directional (restrict, not monitor). It can't tell you what the agent DID read, only enforce what it's ALLOWED to read. Use case: enforce a declared read-set, not infer one.

### Feasibility Assessment for Go+SQLite+Git

| Method | Process Attribution | Overhead | Go Integration | Complexity | Verdict |
|--------|-------------------|----------|----------------|------------|---------|
| inotifywait | No PID | Low | Easy (exec) | Low | **Rejected** — can't distinguish agents |
| eBPF | Full PID | Very low | Good (cilium/ebpf) | High | **Best for production** — requires kernel expertise |
| FUSE | PID available | High (2-10x) | Good (go-fuse) | Medium | **Viable for dev** — too slow for production |
| strace | Full PID | High (2-5x) | Easy (exec) | Low | **Viable for validation** — too slow for production |
| Landlock | Self (no monitor) | Zero | Good (go-landlock) | Low | **Complementary** — enforce, not infer |

---

## Approach 4: Agent-Declared Dependencies

### The Bazel Model

Bazel requires hermetic builds: every action must declare its inputs. Undeclared inputs are invisible in the sandbox. This creates a "declare or fail" discipline.

Applied to LLM agents, this would mean:

1. Before executing, the agent receives a prompt that says: "After completing your task, output a `READ_SET:` section listing every file you consulted"
2. The agent self-reports its read-set as structured output
3. The kernel validates the self-report against the patch

### Implementations and Precedent

**No existing agent framework requires read-set declaration.** However, several related patterns exist:

#### VS Code Background Agents (Git Worktree Isolation)
- VS Code spins up a separate Git worktree per agent session
- File changes are isolated to the worktree
- Merge back to main workspace requires explicit review
- **Read-set**: Not tracked; conflict detection happens at merge time via standard git merge

#### Clash (Worktree Conflict Detector)
- Uses `git merge-tree` to simulate three-way merges between worktree pairs
- Detects file-level conflicts between concurrent agents
- **Write-set detection only** — detects which files each agent MODIFIED, not which files it READ
- Does not detect phantom reads (agent read file X, another agent modified file X, first agent's reasoning is now based on stale data)

#### Custom Agent Protocols
- Some teams use structured output formats where agents must list their "references" or "sources"
- LLM reliability issue: agents may hallucinate or omit files from the declaration
- Trust-but-verify: use declared read-set as a hint, validate with filesystem tracking

### Self-Report Prompt Engineering

```
IMPORTANT: At the end of your response, include a machine-readable section:

```json
{"read_set": ["/path/to/file1.go", "/path/to/file2.go", ...]}
```

List EVERY file you read using the Read tool, and every file path you saw
in Grep or Glob results that influenced your decision. This is used for
conflict detection — omissions may cause your patch to be rejected.
```

### Feasibility Assessment

| Aspect | Rating | Notes |
|--------|--------|-------|
| Implementation complexity | Low | Prompt engineering + output parsing |
| Reliability | **Low-Medium** | LLMs may omit files, especially from Grep/Glob results |
| Overhead | Zero | No runtime cost |
| Coverage | Incomplete | Bash commands, subagent reads, and indirect dependencies missed |
| Go integration | Trivial | Parse JSON from agent output |

**Verdict**: Useful as a supplementary signal but insufficient as the sole mechanism. "Trust but verify" — use declared read-set as a fast-path check, fall back to hook-based or filesystem tracking for ground truth.

---

## Approach 5: Academic & Research Work

### PROV-AGENT (Souza et al., IEEE e-Science 2025)

**"Unified Provenance for Tracking AI Agent Interactions in Agentic Workflows"**

- Extends W3C PROV model with AI agent primitives: `AIAgent`, `AgentTool`, `AIModelInvocation`, `Prompt`, `ResponseData`
- Captures tool inputs, outputs, execution metadata, and model invocation parameters
- Integrates with MCP (Model Context Protocol) for tool tracking
- Uses `@flowcept_agent_tool` decorator for automatic provenance capture
- Compatible with CrewAI, LangChain, and OpenAI SDK
- **File-level tracking**: NOT explicitly addressed. Captures domain data objects but not filesystem-level reads/writes
- **Relevance**: The provenance model is architecturally informative but doesn't solve our specific read-set problem. The W3C PROV extension could be adapted to represent read-sets as provenance relationships.

### PROLIT (Gregori et al., EDBT 2025)

**"Supporting the Transparency of Data Preparation"**

- Uses LLMs to rewrite data pipelines with provenance annotations
- Captures per-operator data dependencies at three granularity levels
- Stores provenance in Neo4J for querying
- **Relevance**: The technique of using LLMs to identify data dependencies could inspire a "post-hoc read-set inference" approach where an LLM analyzes the agent's conversation to identify file dependencies. However, this adds an LLM call and is unreliable.

### AgentRR (Record & Replay, 2025)

**"Get Experience from Practice: LLM Agents with Record & Replay"**

- Records agent interaction traces including all tool calls with inputs/outputs
- Summarizes traces into structured "experiences" for future task guidance
- **Read-set inference**: Tool call recordings contain all file access operations. The replay mechanism validates that inputs match recorded values.
- **Relevance**: Direct. The recording infrastructure is exactly what we need. The replay/validation mechanism is complementary to OCC — if we record the read-set during execution, we can validate it before merge.

### Deterministic Replay for Trustworthy AI (Sakura Sky, 2025)

**"Missing Primitives for Trustworthy AI, Part 8"**

- Argues that tool call traces must capture both request and response for reproducibility
- Tools are a major source of nondeterminism because outputs depend on external state
- Recording exact tool inputs makes calls reproducible
- **Replay validation**: Replay stubs validate that inputs during replay match recorded inputs, detecting control flow divergence
- **No explicit OCC/read-set concepts**, but the recording infrastructure directly supports it
- Multi-agent coordination deferred to a future part of the series

### LLM Observability for Multi-Agent Systems (Chaukiyal, 2026)

- Practical guide to tracing and logging in multi-agent systems
- Advocates structured traces with tool call inputs/outputs
- **Key insight**: "Log the right things so you can replay the reasoning environment and compare it across time"
- Traces should capture: model parameters, tool inputs/outputs, timing, and external state dependencies

### Gap in the Literature

**No published work (as of February 2026) directly addresses OCC read-set validation for LLM agent systems.** The closest work is:

1. PROV-AGENT (provenance for agent tool calls — but no OCC validation)
2. AgentRR (recording tool calls for replay — but no conflict detection)
3. Clash (conflict detection — but only for write-sets via git merge-tree)

The combination of these ideas — record tool-call provenance, extract file-level read-sets, validate against concurrent modifications before merge — appears to be novel. This is a contribution opportunity.

---

## Approach Comparison Matrix

| Approach | Completeness | Reliability | Overhead | Go+Subprocess Compat | Implementation Cost |
|----------|-------------|-------------|----------|----------------------|-------------------|
| **Hook-based (PostToolUse)** | High for Read/Edit/Write; Medium for Grep/Glob; Low for Bash | High (deterministic) | Very low | High (file-based IPC) | Low-Medium |
| **Transcript parsing** | Same as hooks (same data source) | High | Zero (post-hoc) | High | Low |
| **eBPF filesystem** | Complete (all syscalls) | Very high | Very low | Medium (kernel requirement) | High |
| **FUSE overlay** | Complete | High | High (I/O penalty) | Medium | Medium |
| **strace** | Complete | High | High (ptrace penalty) | High | Low |
| **Agent self-report** | Incomplete | Low-Medium (LLM reliability) | Zero | High | Very low |
| **Landlock enforcement** | N/A (enforcement, not inference) | N/A | Zero | High | Low |

---

## Recommended Architecture for Go+SQLite+Git

### Layer 1: Hook-Based Read-Set Collection (Primary)

**For Claude Code agents:**

1. Deploy a PostToolUse hook that writes read-set entries to a JSONL file keyed by session ID
2. Hook matches `Read|Grep|Glob|Edit|Write|Bash`
3. For `Read`: extract exact `file_path`
4. For `Grep`/`Glob`: extract search root path, and optionally parse `tool_response` for matched file paths
5. For `Edit`/`Write`: extract `file_path` (write-set, but implies prior read)
6. For `Bash`: log the command string for post-hoc analysis (conservative: assume it reads everything in CWD)
7. On agent completion, kernel reads the JSONL file and constructs the read-set

**For Codex CLI agents:**

Since Codex CLI lacks hooks, use transcript parsing as the primary mechanism. Codex produces structured conversation logs that can be parsed for tool call records.

### Layer 2: Git-Based Validation (OCC Check)

```go
// ValidateReadSet checks if any file in the read-set was modified
// between dispatch time and merge time
func ValidateReadSet(readSet []string, dispatchCommit, currentHead string) error {
    // Get the list of files changed between dispatch and now
    changedFiles, err := gitDiffFileList(dispatchCommit, currentHead)
    if err != nil {
        return err
    }

    // Check intersection
    for _, readFile := range readSet {
        if changedFiles[readFile] {
            return fmt.Errorf("OCC conflict: %s was read by agent but modified since dispatch (at %s)",
                readFile, dispatchCommit)
        }
    }
    return nil
}
```

The validation compares the read-set against `git diff --name-only <dispatch-commit>..HEAD`. If any file in the read-set appears in the diff, the patch is rejected (agent's reasoning may be based on stale data).

### Layer 3: Filesystem Tracking (Optional, Production Hardening)

For production environments requiring complete coverage (including Bash tool reads):

1. Use eBPF-based file monitoring to track all `openat()` calls by the agent subprocess tree
2. Filter by PID (agent process and its children)
3. Exclude non-project files (system libraries, runtime files)
4. Union with hook-based read-set for a complete picture

This is the highest-fidelity approach but requires significant kernel-level engineering.

### Layer 4: Landlock Enforcement (Optional, Defense in Depth)

After the read-set is inferred (or declared), use Landlock to enforce that future agents cannot access files outside their declared scope. This creates a "sandbox of intent" — the kernel only allows the agent to read files it was expected to read.

```go
// Apply Landlock restrictions before spawning agent
import "github.com/landlock-lsm/go-landlock/landlock"

func SpawnAgentWithLandlock(readPaths, writePaths []string) {
    // Configure Landlock rules
    err := landlock.V5.BestEffort().RestrictPaths(
        landlock.RODirs(readPaths...),
        landlock.RWDirs(writePaths...),
    )
    // Then exec the agent subprocess
}
```

### Data Model (SQLite)

```sql
CREATE TABLE read_sets (
    id INTEGER PRIMARY KEY,
    dispatch_id TEXT NOT NULL,        -- links to dispatch table
    agent_session_id TEXT NOT NULL,
    file_path TEXT NOT NULL,
    tool_name TEXT NOT NULL,           -- Read, Grep, Glob, Bash, Edit, Write
    access_type TEXT NOT NULL,         -- 'read', 'write', 'search'
    timestamp INTEGER NOT NULL,
    dispatch_commit TEXT NOT NULL,     -- git commit at dispatch time
    FOREIGN KEY (dispatch_id) REFERENCES dispatches(id)
);

CREATE INDEX idx_read_sets_dispatch ON read_sets(dispatch_id);
CREATE INDEX idx_read_sets_file ON read_sets(file_path);

-- OCC validation query: find conflicts
-- Files that were in the agent's read-set AND were modified by others
SELECT rs.file_path, rs.tool_name, rs.timestamp
FROM read_sets rs
WHERE rs.dispatch_id = ?
  AND rs.file_path IN (
    SELECT file_path FROM concurrent_modifications
    WHERE commit_time > rs.timestamp
  );
```

### Handling Edge Cases

#### Grep/Glob Over-Approximation

When an agent greps a directory, the conservative approach adds the entire directory to the read-set. This creates false positives (rejecting patches when unrelated files in the directory changed). Refinements:

1. **Parse tool_response**: The Grep/Glob response contains the actual matched files. Use these instead of the search root.
2. **Path-prefix matching**: Instead of exact file match, use directory-level validation. If the agent grepped `/src/`, and `/src/unrelated.go` changed, that's probably not a real conflict.
3. **Content-hash validation**: For files the agent definitely read (via Read tool), compare content hashes rather than modification timestamps. The file may have been touched but not meaningfully changed.

#### Bash Tool Opacity

The Bash tool is fundamentally opaque. Strategies:

1. **Command parsing heuristics**: Extract file paths from common commands (`cat`, `grep`, `head`, `tail`, `git log --`, `go test ./...`)
2. **Conservative mode**: Treat any Bash invocation as reading the entire working directory. This reduces merge rates but guarantees correctness.
3. **eBPF fallback**: Use filesystem-level tracking specifically for Bash tool invocations
4. **Prompt engineering**: Instruct the agent to prefer Read/Grep/Glob tools over Bash for file access. This is already the case in Claude Code's system prompt.

#### Subagent Reads

Claude Code's Task tool spawns subagents. Subagent tool calls are recorded in a separate transcript (`agent_transcript_path`). The kernel must:

1. Parse the subagent transcript for additional read-set entries
2. Union with the parent agent's read-set
3. The `SubagentStop` hook provides `agent_transcript_path` for this purpose

---

## Sources

### Academic Papers
- [PROV-AGENT: Unified Provenance for Tracking AI Agent Interactions in Agentic Workflows (Souza et al., 2025)](https://arxiv.org/abs/2508.02866)
- [PROLIT: Supporting the Transparency of Data Preparation (EDBT 2025)](https://openproceedings.org/2025/conf/edbt/paper-336.pdf)
- [Using LLMs to Infer Provenance Information (ProvenanceWeek 2025)](https://dl.acm.org/doi/10.1145/3736229.3736261)
- [AgentRR: Get Experience from Practice: LLM Agents with Record & Replay (2025)](https://arxiv.org/abs/2505.17716)
- [R-LAM: Reproducibility-Constrained Large Action Models for Scientific Workflow Automation](https://arxiv.org/html/2601.09749)
- [LLM Agents for Interactive Workflow Provenance (ACM 2025)](https://dl.acm.org/doi/full/10.1145/3731599.3767582)
- [Optimistic Concurrency Control (Kung & Robinson, 1981)](https://www.eecs.harvard.edu/~htk/publication/1981-tods-kung-robinson.pdf)
- [LLM-Based Agents for Tool Learning: A Survey (2025)](https://link.springer.com/article/10.1007/s41019-025-00296-9)

### Agent Framework Documentation
- [Claude Code Hooks Reference](https://code.claude.com/docs/en/hooks)
- [Claude Code Hooks Guide](https://code.claude.com/docs/en/hooks-guide)
- [OpenAI Agents SDK Tracing](https://openai.github.io/openai-agents-python/tracing/)
- [Codex CLI Security](https://developers.openai.com/codex/security)
- [Codex CLI Sandbox Configuration](https://developers.openai.com/codex/config-advanced/)
- [AgentOps SDK](https://github.com/AgentOps-AI/agentops)
- [LangSmith Observability](https://www.langchain.com/langsmith/observability)
- [Langfuse LLM Observability](https://langfuse.com/docs/observability/overview)

### Filesystem & Kernel Tracking
- [FSProbe: eBPF File System Events Notifier](https://github.com/Gui774ume/fsprobe)
- [Datadog: Scaling Real-Time File Monitoring with eBPF](https://www.datadoghq.com/blog/engineering/workload-protection-ebpf-fim/)
- [eBPF File System Monitoring](https://theshoemaker.de/posts/ebpf-file-system-monitoring)
- [Landlock LSM Kernel Documentation](https://docs.kernel.org/userspace-api/landlock.html)
- [go-landlock: Go Filesystem Isolation via Linux Landlock](https://github.com/landlock-lsm/go-landlock)
- [Sandboxing AI Agents in Linux (Senko Rasic)](https://blog.senko.net/sandboxing-ai-agents-in-linux)

### Multi-Agent Conflict Detection
- [Clash: Merge Conflict Detection Across Git Worktrees](https://github.com/clash-sh/clash)
- [Git Worktrees for Multi-Feature Development with AI Agents](https://www.nrmitchi.com/2025/10/using-git-worktrees-for-multi-feature-development-with-ai-agents/)
- [Codex App Worktrees Explained](https://www.verdent.ai/guides/codex-app-worktrees-explained)

### Deterministic Replay & Trust
- [Trustworthy AI Agents: Deterministic Replay (Sakura Sky)](https://www.sakurasky.com/blog/missing-primitives-for-trustworthy-ai-part-8/)
- [LLM Observability for Multi-Agent Systems, Part 1 (Chaukiyal, 2026)](https://medium.com/@arpitchaukiyal/llm-observability-for-multi-agent-systems-part-1-tracing-and-logging-what-actually-happened-c11170cd70f9)
- [Inspect AI Sandboxing Toolkit](https://inspect.aisi.org.uk/sandboxing.html)
- [NVIDIA: Practical Security Guidance for Sandboxing Agentic Workflows](https://developer.nvidia.com/blog/practical-security-guidance-for-sandboxing-agentic-workflows-and-managing-execution-risk/)
