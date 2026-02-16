# Interlock Reservation Negotiation Protocol Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use clavain:executing-plans to implement this plan task-by-task.

**Goal:** Add a structured reservation negotiation protocol to interlock so agents can request, respond to, and track file ownership handoffs with urgency levels, auto-release, visibility, and timeout escalation.

**Architecture:** Extend interlock's Go MCP server with new tools and client methods that layer negotiation conventions on top of Intermute's existing message infrastructure (threading, ack tracking, importance). Extend the bash pre-edit hook with throttled inbox checking for auto-release. No changes to Intermute service are needed.

**Tech Stack:** Go 1.24 (interlock MCP server), bash (hooks), Python (structural tests), Intermute HTTP API

**Flux-drive findings incorporated:**
- Drop `low` urgency level (YAGNI) — only `normal` (10min) and `urgent` (5min)
- Drop `no-force` flag from F5 (YAGNI, no enforcement layer)
- Add blocking `wait_seconds` mode to `negotiate_release`
- Deprecate `request_release` as thin wrapper over `negotiate_release`
- Add timeout + circuit breaker to pre-edit hook inbox check
- All-or-nothing auto-release for glob reservations
- Staged rollout: Task 1-3 (F1+F3) → Task 4 (F2) → Task 5 (F4) → Task 6 (F5)

**Beads:**
- Epic: `iv-d72t` — Phase 4a: Reservation Negotiation Protocol
- F1: `iv-1aug` — Release Response Protocol
- F2: `iv-gg8v` — Auto-Release on Clean Files
- F3: `iv-5ijt` — Structured negotiate_release MCP Tool
- F4: `iv-6u3s` — Sprint Scan Release Visibility
- F5: `iv-2jtj` — Escalation Timeout

---

## Task 1: Extend Client with Threaded Message Support (F1 foundation)

**Bead:** `iv-1aug`
**Phase:** executing (as of 2026-02-16T03:46:22Z)

**Files:**
- Modify: `plugins/interlock/internal/client/client.go:106-113` (Message struct)
- Modify: `plugins/interlock/internal/client/client.go:223-232` (SendMessage)
- Test: `plugins/interlock/internal/client/client_test.go` (create if not exists)

**Context:** The current `SendMessage` only accepts `to` and `body`. We need `thread_id`, `subject`, `importance`, and `ack_required` to support the negotiation protocol. The `Message` struct also needs these fields for inbox parsing.

**Step 1: Write the failing test**

```go
// client_test.go
package client

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestSendMessageFull(t *testing.T) {
	var received map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		json.NewDecoder(r.Body).Decode(&received)
		w.WriteHeader(200)
		w.Write([]byte(`{"message_id":"m1","cursor":1}`))
	}))
	defer srv.Close()

	c := NewClient(WithBaseURL(srv.URL), WithAgentID("a1"), WithProject("p1"))
	opts := MessageOptions{
		ThreadID:    "t1",
		Subject:     "release-request",
		Importance:  "urgent",
		AckRequired: true,
	}
	err := c.SendMessageFull(context.Background(), "a2", "body", opts)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if received["thread_id"] != "t1" {
		t.Errorf("thread_id = %v, want t1", received["thread_id"])
	}
	if received["subject"] != "release-request" {
		t.Errorf("subject = %v, want release-request", received["subject"])
	}
	if received["importance"] != "urgent" {
		t.Errorf("importance = %v, want urgent", received["importance"])
	}
	if received["ack_required"] != true {
		t.Errorf("ack_required = %v, want true", received["ack_required"])
	}
}

func TestFetchThread(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"messages": []map[string]any{
				{"id": "m1", "from": "a1", "body": `{"type":"release-request"}`, "subject": "release-request", "thread_id": "t1"},
				{"id": "m2", "from": "a2", "body": `{"type":"release-ack"}`, "subject": "release-ack", "thread_id": "t1"},
			},
		})
	}))
	defer srv.Close()

	c := NewClient(WithBaseURL(srv.URL), WithAgentID("a1"), WithProject("p1"))
	msgs, err := c.FetchThread(context.Background(), "t1")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(msgs) != 2 {
		t.Fatalf("got %d messages, want 2", len(msgs))
	}
	if msgs[0].Subject != "release-request" {
		t.Errorf("msg[0].Subject = %q, want release-request", msgs[0].Subject)
	}
}
```

**Step 2: Run test to verify it fails**

Run: `cd plugins/interlock && go test ./internal/client/ -run TestSendMessageFull -v`
Expected: FAIL — `SendMessageFull` and `MessageOptions` not defined

**Step 3: Write minimal implementation**

Add to `client.go`:

```go
// MessageOptions provides optional fields for SendMessageFull.
type MessageOptions struct {
	ThreadID    string
	Subject     string
	Importance  string
	AckRequired bool
}
```

Update `Message` struct to include new fields:

```go
type Message struct {
	ID          string `json:"id,omitempty"`
	MessageID   string `json:"message_id,omitempty"` // alias used by some endpoints
	From        string `json:"from"`
	To          []string `json:"to,omitempty"`
	Body        string `json:"body"`
	ThreadID    string `json:"thread_id,omitempty"`
	Subject     string `json:"subject,omitempty"`
	Importance  string `json:"importance,omitempty"`
	AckRequired bool   `json:"ack_required,omitempty"`
	Timestamp   string `json:"timestamp,omitempty"`
	CreatedAt   string `json:"created_at,omitempty"`
	Read        bool   `json:"read,omitempty"`
}
```

Add `SendMessageFull`:

```go
// SendMessageFull sends a message with full options (threading, importance, etc).
func (c *Client) SendMessageFull(ctx context.Context, to, body string, opts MessageOptions) error {
	msg := map[string]any{
		"project": c.project,
		"from":    c.agentID,
		"to":      []string{to},
		"body":    body,
	}
	if opts.ThreadID != "" {
		msg["thread_id"] = opts.ThreadID
	}
	if opts.Subject != "" {
		msg["subject"] = opts.Subject
	}
	if opts.Importance != "" {
		msg["importance"] = opts.Importance
	}
	if opts.AckRequired {
		msg["ack_required"] = true
	}
	return c.doJSON(ctx, "POST", "/api/messages", msg, nil)
}
```

Add `FetchThread`:

```go
// FetchThread fetches all messages in a thread.
func (c *Client) FetchThread(ctx context.Context, threadID string) ([]Message, error) {
	q := url.Values{}
	q.Set("project", c.project)
	path := "/api/threads/" + url.PathEscape(threadID) + "?" + q.Encode()
	var result struct {
		Messages []Message `json:"messages"`
	}
	if err := c.doJSON(ctx, "GET", path, nil, &result); err != nil {
		return nil, err
	}
	return result.Messages, nil
}
```

**Step 4: Run tests to verify they pass**

Run: `cd plugins/interlock && go test ./internal/client/ -v`
Expected: PASS

**Step 5: Run full Go tests**

Run: `cd plugins/interlock && go test ./...`
Expected: PASS (no regressions)

**Step 6: Commit**

```bash
git add plugins/interlock/internal/client/client.go plugins/interlock/internal/client/client_test.go
git commit -m "feat(interlock): extend client with threaded message support

Add SendMessageFull with thread_id, subject, importance, ack_required.
Add FetchThread for retrieving thread conversations.
Extend Message struct with negotiation-relevant fields."
```

---

## Task 2: Add negotiate_release MCP Tool (F3)

**Bead:** `iv-5ijt`
**Phase:** executing (as of 2026-02-16T03:46:22Z)

**Files:**
- Modify: `plugins/interlock/internal/tools/tools.go:16-27` (RegisterAll)
- Modify: `plugins/interlock/internal/tools/tools.go:274-315` (replace requestRelease)
- Test: Go test in `plugins/interlock/internal/tools/` or structural test update

**Context:** Add `negotiate_release` tool that sends a threaded `release-request` message with urgency and optional blocking wait. Deprecate `request_release` as a thin wrapper. Tool count goes from 9 to 10.

**Step 1: Write the negotiate_release tool**

Add after `requestRelease` in `tools.go`:

```go
func negotiateRelease(c *client.Client) server.ServerTool {
	return server.ServerTool{
		Tool: mcp.NewTool("negotiate_release",
			mcp.WithDescription("Request another agent to release their file reservation. Supports urgency levels and optional blocking wait."),
			mcp.WithString("agent_name",
				mcp.Description("Name or ID of the agent holding the reservation"),
				mcp.Required(),
			),
			mcp.WithString("file",
				mcp.Description("The file pattern you need released"),
				mcp.Required(),
			),
			mcp.WithString("reason",
				mcp.Description("Why you need the file"),
				mcp.Required(),
			),
			mcp.WithString("urgency",
				mcp.Description("Urgency level: 'normal' (10min timeout) or 'urgent' (5min timeout). Default: normal"),
			),
			mcp.WithNumber("wait_seconds",
				mcp.Description("If >0, block and poll for response up to this many seconds. 0 = return immediately with thread_id. Default: 0"),
			),
		),
		Handler: func(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
			args := req.GetArguments()
			agentName, _ := args["agent_name"].(string)
			file, _ := args["file"].(string)
			reason, _ := args["reason"].(string)
			urgency := stringOr(args["urgency"], "normal")
			waitSec := intOr(args["wait_seconds"], 0)

			if agentName == "" || file == "" || reason == "" {
				return mcp.NewToolResultError("agent_name, file, and reason are required"), nil
			}
			if urgency != "normal" && urgency != "urgent" {
				return mcp.NewToolResultError("urgency must be 'normal' or 'urgent'"), nil
			}

			// Validate: target agent exists and holds the file
			conflicts, err := c.CheckConflicts(ctx, file)
			if err != nil {
				return mcp.NewToolResultError(fmt.Sprintf("check conflicts: %v", err)), nil
			}
			var holderID string
			for _, cd := range conflicts {
				if cd.AgentID == agentName || cd.HeldBy == agentName {
					holderID = cd.AgentID
					break
				}
			}
			if holderID == "" {
				return mcp.NewToolResultError(fmt.Sprintf("agent %q does not hold a reservation matching %q", agentName, file)), nil
			}

			// Generate thread ID for this negotiation
			threadID := fmt.Sprintf("negotiate-%s-%d", file, time.Now().UnixMilli())

			// Build message body
			body, _ := json.Marshal(map[string]any{
				"type":      "release-request",
				"file":      file,
				"reason":    reason,
				"requester": c.AgentName(),
				"urgency":   urgency,
			})

			// Map urgency to importance
			importance := "normal"
			ackRequired := false
			if urgency == "urgent" {
				importance = "urgent"
				ackRequired = true
			}

			opts := client.MessageOptions{
				ThreadID:    threadID,
				Subject:     "release-request",
				Importance:  importance,
				AckRequired: ackRequired,
			}
			if err := c.SendMessageFull(ctx, holderID, string(body), opts); err != nil {
				return mcp.NewToolResultError(fmt.Sprintf("send negotiation request: %v", err)), nil
			}

			// Non-blocking mode: return immediately
			if waitSec <= 0 {
				return jsonResult(map[string]any{
					"sent":      true,
					"to":        holderID,
					"thread_id": threadID,
					"urgency":   urgency,
					"status":    "pending",
				})
			}

			// Blocking mode: poll for response
			deadline := time.Now().Add(time.Duration(waitSec) * time.Second)
			pollInterval := 2 * time.Second
			for time.Now().Before(deadline) {
				msgs, err := c.FetchThread(ctx, threadID)
				if err == nil {
					for _, m := range msgs {
						var parsed map[string]any
						if json.Unmarshal([]byte(m.Body), &parsed) == nil {
							msgType, _ := parsed["type"].(string)
							if msgType == "release-ack" {
								return jsonResult(map[string]any{
									"status":      "released",
									"thread_id":   threadID,
									"released_by": m.From,
									"reason":      parsed["reason"],
								})
							}
							if msgType == "release-defer" {
								return jsonResult(map[string]any{
									"status":      "deferred",
									"thread_id":   threadID,
									"eta_minutes": parsed["eta_minutes"],
									"reason":      parsed["reason"],
								})
							}
						}
					}
				}
				time.Sleep(pollInterval)
			}

			return jsonResult(map[string]any{
				"status":    "timeout",
				"thread_id": threadID,
				"waited":    waitSec,
			})
		},
	}
}
```

**Step 2: Deprecate request_release as thin wrapper**

Replace the existing `requestRelease` function body to delegate to `negotiateRelease` logic:

```go
func requestRelease(c *client.Client) server.ServerTool {
	return server.ServerTool{
		Tool: mcp.NewTool("request_release",
			mcp.WithDescription("[DEPRECATED: use negotiate_release] Ask another agent to release their file reservation."),
			mcp.WithString("agent_name",
				mcp.Description("Name or ID of the agent holding the reservation"),
				mcp.Required(),
			),
			mcp.WithString("pattern",
				mcp.Description("The file pattern you need released"),
				mcp.Required(),
			),
			mcp.WithString("reason",
				mcp.Description("Why you need the files"),
				mcp.Required(),
			),
		),
		Handler: func(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
			args := req.GetArguments()
			agentName, _ := args["agent_name"].(string)
			pattern, _ := args["pattern"].(string)
			reason, _ := args["reason"].(string)
			if agentName == "" || pattern == "" || reason == "" {
				return mcp.NewToolResultError("agent_name, pattern, and reason are required"), nil
			}
			// Fire-and-forget: send with normal urgency, no thread tracking
			body, _ := json.Marshal(map[string]string{
				"type":      "release-request",
				"pattern":   pattern,
				"reason":    reason,
				"requester": c.AgentName(),
			})
			if err := c.SendMessage(ctx, agentName, string(body)); err != nil {
				return mcp.NewToolResultError(fmt.Sprintf("send release request: %v", err)), nil
			}
			return jsonResult(map[string]any{
				"sent":       true,
				"to":         agentName,
				"type":       "release-request",
				"deprecated": "Use negotiate_release for structured negotiation with response tracking.",
			})
		},
	}
}
```

**Step 3: Register the new tool**

Update `RegisterAll` to add `negotiateRelease`:

```go
func RegisterAll(s *server.MCPServer, c *client.Client) {
	s.AddTools(
		reserveFiles(c),
		releaseFiles(c),
		releaseAll(c),
		checkConflicts(c),
		myReservations(c),
		sendMessage(c),
		fetchInbox(c),
		listAgents(c),
		requestRelease(c),
		negotiateRelease(c),
	)
}
```

Update comment: `// RegisterAll registers all 10 MCP tools with the server.`

**Step 4: Add helper imports**

Add `"time"` to the imports in `tools.go`.

Add `stringOr` helper if not present:

```go
func stringOr(v any, def string) string {
	if s, ok := v.(string); ok && s != "" {
		return s
	}
	return def
}
```

**Step 5: Run Go tests**

Run: `cd plugins/interlock && go test ./...`
Expected: PASS (compilation + existing tests)

**Step 6: Update structural tests**

Modify `tests/structural/test_structure.py`:
- Update `EXPECTED_TOOLS` to include `"negotiate_release"` (10 tools total)
- Update `test_tool_count` to expect 10

**Step 7: Run structural tests**

Run: `cd plugins/interlock && python3 -m pytest tests/structural/ -v`
Expected: PASS

**Step 8: Commit**

```bash
git add plugins/interlock/internal/tools/tools.go plugins/interlock/tests/structural/test_structure.py
git commit -m "feat(interlock): add negotiate_release tool with blocking wait mode

New MCP tool with urgency levels (normal/urgent) and optional
blocking wait_seconds param. Deprecate request_release as thin wrapper.
Tool count: 9 -> 10."
```

---

## Task 3: Add Response Tools — respond_to_release (F1)

**Bead:** `iv-1aug`
**Phase:** executing (as of 2026-02-16T03:46:22Z)

**Files:**
- Modify: `plugins/interlock/internal/tools/tools.go` (add respondToRelease tool)
- Modify: `plugins/interlock/skills/conflict-recovery/SKILL.md` (update with new tools)
- Modify: `plugins/interlock/skills/coordination-protocol/SKILL.md` (update with new tools)

**Context:** Agents need a tool to send structured `release_ack` and `release_defer` responses. This completes the protocol.

**Step 1: Add respond_to_release tool**

```go
func respondToRelease(c *client.Client) server.ServerTool {
	return server.ServerTool{
		Tool: mcp.NewTool("respond_to_release",
			mcp.WithDescription("Respond to a release request: acknowledge (release the file) or defer (need more time)."),
			mcp.WithString("thread_id",
				mcp.Description("Thread ID from the release request"),
				mcp.Required(),
			),
			mcp.WithString("requester",
				mcp.Description("Agent who requested the release"),
				mcp.Required(),
			),
			mcp.WithString("action",
				mcp.Description("'release' to release the file, 'defer' to request more time"),
				mcp.Required(),
			),
			mcp.WithString("file",
				mcp.Description("The file pattern being negotiated"),
				mcp.Required(),
			),
			mcp.WithNumber("eta_minutes",
				mcp.Description("For 'defer': estimated minutes until you can release (max 60)"),
			),
			mcp.WithString("reason",
				mcp.Description("Why you're deferring (for 'defer' action)"),
			),
		),
		Handler: func(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
			args := req.GetArguments()
			threadID, _ := args["thread_id"].(string)
			requester, _ := args["requester"].(string)
			action, _ := args["action"].(string)
			file, _ := args["file"].(string)
			etaMin := intOr(args["eta_minutes"], 0)
			reason, _ := args["reason"].(string)

			if threadID == "" || requester == "" || action == "" || file == "" {
				return mcp.NewToolResultError("thread_id, requester, action, and file are required"), nil
			}
			if action != "release" && action != "defer" {
				return mcp.NewToolResultError("action must be 'release' or 'defer'"), nil
			}

			if action == "release" {
				// Release the reservation first
				reservations, err := c.ListReservations(ctx, map[string]string{
					"agent":   c.AgentID(),
					"project": c.Project(),
				})
				if err != nil {
					return mcp.NewToolResultError(fmt.Sprintf("list reservations: %v", err)), nil
				}
				released := false
				for _, r := range reservations {
					if r.IsActive && patternsOverlap(r.PathPattern, file) {
						if err := c.DeleteReservation(ctx, r.ID); err == nil {
							released = true
						}
					}
				}

				// Send release_ack
				body, _ := json.Marshal(map[string]any{
					"type":        "release-ack",
					"file":        file,
					"released":    true,
					"released_by": c.AgentName(),
				})
				opts := client.MessageOptions{
					ThreadID: threadID,
					Subject:  "release-ack",
				}
				_ = c.SendMessageFull(ctx, requester, string(body), opts)
				emitSignal("release", fmt.Sprintf("released %s to %s", file, requester))

				return jsonResult(map[string]any{
					"action":      "released",
					"file":        file,
					"released_to": requester,
					"reservation_deleted": released,
				})
			}

			// Defer
			if etaMin > 60 {
				etaMin = 60
			}
			body, _ := json.Marshal(map[string]any{
				"type":        "release-defer",
				"file":        file,
				"released":    false,
				"eta_minutes": etaMin,
				"reason":      reason,
			})
			opts := client.MessageOptions{
				ThreadID: threadID,
				Subject:  "release-defer",
			}
			_ = c.SendMessageFull(ctx, requester, string(body), opts)

			return jsonResult(map[string]any{
				"action":      "deferred",
				"file":        file,
				"eta_minutes": etaMin,
				"reason":      reason,
			})
		},
	}
}
```

Note: `patternsOverlap` is in `client.go` — export it or duplicate the logic. Simplest: copy the same prefix logic as a package-level helper in `tools.go`.

**Step 2: Register — tool count goes to 11**

Update `RegisterAll`:
```go
func RegisterAll(s *server.MCPServer, c *client.Client) {
	s.AddTools(
		reserveFiles(c),
		releaseFiles(c),
		releaseAll(c),
		checkConflicts(c),
		myReservations(c),
		sendMessage(c),
		fetchInbox(c),
		listAgents(c),
		requestRelease(c),
		negotiateRelease(c),
		respondToRelease(c),
	)
}
```

Update comment to 11 tools.

**Step 3: Update structural tests**

Update `EXPECTED_TOOLS` in `test_structure.py` to include `"negotiate_release"` and `"respond_to_release"` (11 tools). Update `test_tool_count` to 11. Update `test_coordination_references_all_tools` tool list.

**Step 4: Update skills**

Update `skills/conflict-recovery/SKILL.md` Step 3 to reference `negotiate_release` instead of `request_release`, and add Step 3b for checking response via `fetch_inbox` or using `wait_seconds`.

Update `skills/coordination-protocol/SKILL.md` tool table to add `negotiate_release` and `respond_to_release`.

**Step 5: Build and test**

Run: `cd plugins/interlock && go test ./... && python3 -m pytest tests/structural/ -v`
Expected: PASS

**Step 6: Rebuild binary**

Run: `cd plugins/interlock && bash scripts/build.sh`
Expected: Binary builds successfully

**Step 7: Commit**

```bash
git add plugins/interlock/
git commit -m "feat(interlock): add respond_to_release tool and update skills

Complete F1+F3 negotiation protocol. Agents can now:
- negotiate_release: request a file with urgency + optional blocking wait
- respond_to_release: ack (release) or defer with ETA
Tool count: 9 -> 11. Skills updated."
```

---

## Task 4: Auto-Release in Pre-Edit Hook (F2)

**Bead:** `iv-gg8v`
**Phase:** executing (as of 2026-02-16T03:46:22Z)

**Files:**
- Modify: `plugins/interlock/hooks/pre-edit.sh:24-63` (add release-request inbox check)
- Modify: `plugins/interlock/hooks/lib.sh` (add helper functions)
- Test: Manual testing with two sessions

**Context:** After checking for commit notifications (existing logic), also check for `release-request` messages targeting files this agent holds. If file is clean (no uncommitted changes for ANY file in the reservation pattern), auto-release and send `release_ack`. Feature-flagged via `INTERLOCK_AUTO_RELEASE=1` env var (default: off for staged rollout).

**Step 1: Add helper to lib.sh**

```bash
# negotiation_check_path returns the throttle flag for release-request inbox checks.
# Separate from commit check to allow different cache TTLs.
negotiation_check_path() {
    echo "/tmp/interlock-negotiate-checked-${1}"
}
```

**Step 2: Add auto-release logic to pre-edit.sh**

Insert after the commit notification block (after line 63, before line 65 `# Make file path relative`), guarded by feature flag:

```bash
# --- Check inbox for release-request messages (throttled, feature-flagged) ---
if [[ "${INTERLOCK_AUTO_RELEASE:-0}" == "1" ]]; then
    NEG_FLAG=$(negotiation_check_path "$SESSION_ID")
    if [[ ! -f "$NEG_FLAG" ]] || ! find "$NEG_FLAG" -mmin -0.5 -print -quit 2>/dev/null | grep -q .; then
        touch "$NEG_FLAG" 2>/dev/null || true

        # Fetch inbox with --max-time 2 (circuit breaker: fail-open)
        NEG_INBOX=$(intermute_curl GET "/api/messages/inbox?agent=${INTERMUTE_AGENT_ID}&unread=true&limit=50" 2>/dev/null) || NEG_INBOX=""

        if [[ -n "$NEG_INBOX" ]]; then
            # Find release-request messages for files we hold
            RELEASE_REQS=$(echo "$NEG_INBOX" | jq -r '
                [.messages[]? | select(
                    (.subject // "") == "release-request" or
                    ((.body // "") | try fromjson | .type) == "release-request"
                )] | if length > 0 then . else empty end
            ' 2>/dev/null) || RELEASE_REQS=""

            if [[ -n "$RELEASE_REQS" && "$RELEASE_REQS" != "null" ]]; then
                # Get our reservations
                MY_RES=$(intermute_curl GET "/api/reservations?agent=${INTERMUTE_AGENT_ID}&project=${PROJECT:-}" 2>/dev/null) || MY_RES=""
                # Get dirty files
                DIRTY_FILES=$(git diff --name-only 2>/dev/null; git diff --cached --name-only 2>/dev/null) || DIRTY_FILES=""

                echo "$RELEASE_REQS" | jq -c '.[]' 2>/dev/null | while IFS= read -r req_msg; do
                    REQ_BODY=$(echo "$req_msg" | jq -r '.body // ""' 2>/dev/null) || continue
                    REQ_FILE=$(echo "$REQ_BODY" | jq -r 'try fromjson | .file // .pattern // empty' 2>/dev/null) || continue
                    REQ_THREAD=$(echo "$req_msg" | jq -r '.thread_id // empty' 2>/dev/null) || REQ_THREAD=""
                    REQ_FROM=$(echo "$req_msg" | jq -r '.from // empty' 2>/dev/null) || REQ_FROM=""
                    REQ_MSG_ID=$(echo "$req_msg" | jq -r '.id // .message_id // empty' 2>/dev/null) || REQ_MSG_ID=""

                    [[ -z "$REQ_FILE" ]] && continue

                    # Check if ANY file matching our reservation pattern is dirty
                    HAS_DIRTY=false
                    if [[ -n "$DIRTY_FILES" ]]; then
                        while IFS= read -r dirty; do
                            case "$dirty" in
                                $REQ_FILE) HAS_DIRTY=true; break ;;
                            esac
                        done <<< "$DIRTY_FILES"
                    fi

                    if [[ "$HAS_DIRTY" == "false" ]]; then
                        # All clean — auto-release matching reservations
                        echo "$MY_RES" | jq -r ".reservations[]? | select(.path_pattern == \"$REQ_FILE\" or .is_active == true) | .id" 2>/dev/null | while IFS= read -r res_id; do
                            [[ -n "$res_id" ]] && intermute_curl DELETE "/api/reservations/${res_id}" 2>/dev/null || true
                        done

                        # Send release_ack on the thread
                        if [[ -n "$REQ_THREAD" && -n "$REQ_FROM" ]]; then
                            ACK_BODY=$(jq -nc --arg file "$REQ_FILE" --arg by "${INTERMUTE_AGENT_NAME:-$INTERMUTE_AGENT_ID}" \
                                '{"type":"release-ack","file":$file,"released":true,"released_by":$by}')
                            ACK_MSG=$(jq -nc \
                                --arg project "${PROJECT:-}" \
                                --arg from "$INTERMUTE_AGENT_ID" \
                                --arg to "$REQ_FROM" \
                                --arg body "$ACK_BODY" \
                                --arg thread_id "$REQ_THREAD" \
                                --arg subject "release-ack" \
                                '{project:$project,from:$from,to:[$to],body:$body,thread_id:$thread_id,subject:$subject}')
                            intermute_curl POST "/api/messages" -H "Content-Type: application/json" -d "$ACK_MSG" 2>/dev/null || true
                        fi

                        # Ack the original message so we don't reprocess
                        [[ -n "$REQ_MSG_ID" ]] && intermute_curl POST "/api/messages/${REQ_MSG_ID}/ack" 2>/dev/null || true

                        PULL_CONTEXT="${PULL_CONTEXT:-}INTERLOCK: auto-released $REQ_FILE to $REQ_FROM (file was clean). "
                    fi
                done

                if [[ -n "${PULL_CONTEXT:-}" ]]; then
                    cat <<ENDJSON
{"additionalContext": "${PULL_CONTEXT}"}
ENDJSON
                fi
            fi
        fi
    fi
fi
```

**Step 3: Test manually**

1. Start intermute: `systemctl start intermute`
2. In Session A: `/interlock:join`, edit a file (auto-reserves)
3. In Session B: `/interlock:join`, call `negotiate_release` for the file
4. In Session A (with `INTERLOCK_AUTO_RELEASE=1`): edit any file → pre-edit hook should auto-release
5. Verify: Session B's `fetch_inbox` shows `release_ack`

**Step 4: Run structural tests**

Run: `cd plugins/interlock && python3 -m pytest tests/structural/ -v`
Expected: PASS (no structural regressions)

**Step 5: Commit**

```bash
git add plugins/interlock/hooks/pre-edit.sh plugins/interlock/hooks/lib.sh
git commit -m "feat(interlock): auto-release clean files on release-request (F2)

Pre-edit hook checks inbox for release-request messages (throttled 30s).
If requested file has no uncommitted changes, auto-releases and sends
release_ack on the thread. Feature-flagged: INTERLOCK_AUTO_RELEASE=1.
Includes --max-time 2 circuit breaker on inbox check."
```

---

## Task 5: Sprint Status Negotiation Visibility (F4)

**Bead:** `iv-6u3s`
**Phase:** executing (as of 2026-02-16T03:46:22Z)

**Files:**
- Modify: `plugins/interlock/commands/status.md` (add negotiation section)

**Context:** Extend the `/interlock:status` command output to show pending negotiations. The command is a markdown instruction file that agents follow — it queries Intermute APIs and formats output.

**Step 1: Update status.md**

Add step 5 (before "Show own status"):

```markdown
5. **Fetch pending negotiations** via `GET /api/inbox/{agent_id}?unread=true&limit=100` for each agent. Filter messages where `subject` starts with `release-request`. For each, check the thread for responses:

   ```
   Pending Negotiations:
   | Requester        | Holder           | File             | Urgency | Age    | Status              |
   |------------------|------------------|------------------|---------|--------|---------------------|
   ```

   Status values:
   - "Pending (no response)" — release-request with no ack/defer in thread
   - "Deferred (eta: Nm)" — release-defer received
   - "Resolved (Nm ago)" — release-ack received recently (< 15 min)
   - "Timeout approaching (Nm left)" — pending + age > 50% of urgency timeout

   Only show negotiations from the last hour. Skip if no negotiations found.
```

**Step 2: Update structural tests if needed**

Check that the status command test still passes.

Run: `cd plugins/interlock && python3 -m pytest tests/structural/ -v`

**Step 3: Commit**

```bash
git add plugins/interlock/commands/status.md
git commit -m "feat(interlock): show pending negotiations in status command (F4)

Status output now includes Pending Negotiations table with requester,
holder, file, urgency, age, and resolution status."
```

---

## Task 6: Escalation Timeout with Force-Release (F5)

**Bead:** `iv-2jtj`
**Phase:** executing (as of 2026-02-16T03:46:22Z)

**Files:**
- Modify: `plugins/interlock/internal/tools/tools.go` (add timeout check to fetch_inbox and negotiate_release)
- Modify: `plugins/interlock/internal/client/client.go` (add ReleaseByPattern helper)

**Context:** When an agent calls `fetch_inbox` or `negotiate_release`, check for expired negotiations and force-release the reservation. Timeout: 5min for urgent, 10min for normal. Force-release is idempotent (check reservation still exists before deleting). Per flux-drive: no `no-force` flag.

**Step 1: Add ReleaseByPattern client method**

```go
// ReleaseByPattern releases all reservations matching a pattern held by a specific agent.
// Returns the count of released reservations. Idempotent: returns 0 if none found.
func (c *Client) ReleaseByPattern(ctx context.Context, agentID, pattern string) (int, error) {
	reservations, err := c.ListReservations(ctx, map[string]string{
		"agent":   agentID,
		"project": c.project,
	})
	if err != nil {
		return 0, err
	}
	count := 0
	for _, r := range reservations {
		if r.IsActive && patternsOverlap(r.PathPattern, pattern) {
			if err := c.DeleteReservation(ctx, r.ID); err == nil {
				count++
			}
		}
	}
	return count, nil
}
```

**Step 2: Add timeout check function in tools.go**

```go
// checkNegotiationTimeouts scans inbox for expired negotiations and force-releases.
func checkNegotiationTimeouts(ctx context.Context, c *client.Client) []map[string]any {
	var results []map[string]any
	msgs, _, err := c.FetchInbox(ctx, "")
	if err != nil {
		return nil
	}
	now := time.Now()
	for _, m := range msgs {
		var body map[string]any
		if json.Unmarshal([]byte(m.Body), &body) != nil {
			continue
		}
		msgType, _ := body["type"].(string)
		if msgType != "release-request" {
			continue
		}
		urgency, _ := body["urgency"].(string)
		if urgency == "" {
			continue // Legacy request_release, no timeout
		}
		// Parse timestamp
		ts, err := time.Parse(time.RFC3339Nano, m.CreatedAt)
		if err != nil {
			if ts2, err2 := time.Parse(time.RFC3339, m.CreatedAt); err2 == nil {
				ts = ts2
			} else {
				continue
			}
		}
		timeoutMinutes := 10 // normal
		if urgency == "urgent" {
			timeoutMinutes = 5
		}
		if now.Sub(ts) < time.Duration(timeoutMinutes)*time.Minute {
			continue // Not expired yet
		}

		// Check if already resolved (look for release-ack in thread)
		threadID, _ := body["thread_id"].(string)
		if threadID == "" {
			threadID = m.ThreadID
		}
		if threadID != "" {
			threadMsgs, err := c.FetchThread(ctx, threadID)
			if err == nil {
				resolved := false
				for _, tm := range threadMsgs {
					var tb map[string]any
					if json.Unmarshal([]byte(tm.Body), &tb) == nil {
						if t, _ := tb["type"].(string); t == "release-ack" {
							resolved = true
							break
						}
					}
				}
				if resolved {
					continue // Already handled
				}
			}
		}

		// Force-release
		file, _ := body["file"].(string)
		if file == "" {
			file, _ = body["pattern"].(string)
		}
		holder := m.From
		if holder == "" {
			continue
		}
		count, _ := c.ReleaseByPattern(ctx, holder, file)

		// Send timeout ack
		ackBody, _ := json.Marshal(map[string]any{
			"type":        "release-ack",
			"file":        file,
			"released":    true,
			"released_by": "timeout",
			"reason":      "timeout",
		})
		if threadID != "" {
			opts := client.MessageOptions{ThreadID: threadID, Subject: "release-ack"}
			_ = c.SendMessageFull(ctx, holder, string(ackBody), opts)
		}

		results = append(results, map[string]any{
			"file":         file,
			"holder":       holder,
			"released":     count,
			"reason":       "timeout",
			"urgency":      urgency,
			"age_minutes":  int(now.Sub(ts).Minutes()),
		})
	}
	return results
}
```

**Step 3: Hook into fetch_inbox tool**

In the `fetchInbox` handler, after fetching messages, add:

```go
// Check for expired negotiations (lazy timeout enforcement)
timeouts := checkNegotiationTimeouts(ctx, c)
```

Include timeouts in the result if any fired.

**Step 4: Run Go tests**

Run: `cd plugins/interlock && go test ./...`
Expected: PASS

**Step 5: Run structural tests**

Run: `cd plugins/interlock && python3 -m pytest tests/structural/ -v`
Expected: PASS

**Step 6: Rebuild binary**

Run: `cd plugins/interlock && bash scripts/build.sh`

**Step 7: Commit**

```bash
git add plugins/interlock/internal/client/client.go plugins/interlock/internal/tools/tools.go
git commit -m "feat(interlock): add escalation timeout with force-release (F5)

Lazy timeout enforcement: fetch_inbox checks for expired negotiations
and force-releases reservations. Timeouts: 5min urgent, 10min normal.
Force-release is idempotent (checks reservation exists before delete).
Holder notified via release-ack with reason='timeout'."
```

---

## Task 7: Update Documentation and Final Validation

**Files:**
- Modify: `plugins/interlock/docs/PRD.md` (update tool count, add negotiation section)
- Modify: `plugins/interlock/CLAUDE.md` (add negotiation commands reference)
- Modify: `plugins/interlock/AGENTS.md` (add negotiation protocol docs)

**Step 1: Update PRD.md tool count**

Change "9 tools" references to "11 tools". Add negotiation protocol to feature list.

**Step 2: Update CLAUDE.md quick commands**

Add:
```
# Negotiation protocol
negotiate_release  — request file with urgency + optional blocking wait
respond_to_release — ack (release) or defer with ETA
```

**Step 3: Full test suite**

Run: `cd plugins/interlock && go test ./... && python3 -m pytest tests/structural/ -v && bash scripts/build.sh`
Expected: All pass, binary builds

**Step 4: Commit**

```bash
git add plugins/interlock/
git commit -m "docs(interlock): update documentation for negotiation protocol

Update PRD, CLAUDE.md, AGENTS.md with new tool count (11),
negotiation protocol documentation, and updated skill references."
```

---

## Plan Review Amendments (Flux-Drive 2026-02-15)

Reviews: `docs/research/architecture-review-of-plan.md`, `docs/research/correctness-review-of-plan.md`, `docs/research/quality-review-of-plan.md`

### Amendment A1: Thread ID Generation (affects Task 2)
**Finding:** Millisecond timestamp can collide if two agents request same file simultaneously.
**Fix:** Use UUID: `threadID := fmt.Sprintf("negotiate-%s", uuid.New().String())`. Add `github.com/google/uuid` dependency (or use `crypto/rand` to avoid new dep).

### Amendment A2: Lost Wakeup in Poll Loop (affects Task 2)
**Finding:** Response can arrive during `time.Sleep`, causing false timeout.
**Fix:** Add final `FetchThread` check after deadline expires, before returning `status: timeout`. Also cap sleep to `min(pollInterval, remaining)`.

### Amendment A3: Auto-Release Strategy Change (affects Task 4)
**Finding:** TOCTOU race — file can become dirty between `git diff` check and reservation delete. Also, concurrent sessions can double-release.
**Fix:** Change auto-release to **advisory-only mode**: instead of deleting reservation and sending ack, emit `additionalContext` telling the agent to call `respond_to_release` manually. This eliminates the race entirely.

### Amendment A4: Move Business Logic to Client Layer (affects Tasks 1, 3, 6)
**Finding:** `respondToRelease` duplicates pattern overlap logic; `checkNegotiationTimeouts` has 100+ lines of business logic in tools.go.
**Fix:**
- Move `ReleaseByPattern` to Task 1 (client.go), use in Task 3
- Export `PatternsOverlap` from client.go (or use `ReleaseByPattern` which wraps it)
- Move timeout logic to `client.CheckExpiredNegotiations() ([]NegotiationTimeout, error)` in Task 6

### Amendment A5: Timeout Enforcement — Add Background Goroutine (affects Task 6)
**Finding:** Lazy-only timeout via `fetch_inbox` is insufficient — if no agent polls, timeouts never fire.
**Fix:** Start a background goroutine on first `negotiate_release` call using `sync.Once`. Goroutine calls `CheckExpiredNegotiations` every 30 seconds. Add `stopTimeoutChecker` for clean shutdown.

### Amendment A6: FetchThread API Verification (affects Task 1)
**Finding:** Plan assumes `GET /api/threads/{threadID}` exists in Intermute. This must be verified.
**Fix:** Check Intermute handlers. If endpoint doesn't exist, implement client-side fallback: `FetchInbox` filtered by `thread_id`. Add `isNotFound` error check to try endpoint first, fallback if 404.

### Amendment A7: Go Code Quality (affects Tasks 1-3, 6)
**Findings:**
- Use `%w` not `%v` for error wrapping (preserves error chain)
- Add nil guard to `FetchThread` return (return empty slice, not nil)
- Add `CreatedAt` field to `Message` struct in Task 1 (Task 6 uses it)
- Extract timeout constants: `normalTimeoutMinutes = 10`, `urgentTimeoutMinutes = 5`, `negotiationPollInterval = 2 * time.Second`
- Add `stringOr` helper to match existing `intOr`, `boolOr` pattern

### Amendment A8: Bash Safety (affects Task 4)
**Findings:**
- Use `jq --arg` for safe variable injection in reservation pattern match (prevents jq injection)
- Add `intermute_curl_fast` helper to lib.sh with `--max-time 2` for hook API calls
- Existing `|| true` fail-open pattern is correct, keep it

### Amendment A9: Test Coverage (affects Tasks 1-6)
**Missing tests to add:**
- Task 1: `TestFetchThread_NotFound`, `TestFetchThread_EmptyMessages`
- Task 2: `TestNegotiateRelease_BlockingTimeout` (mock server that never responds)
- Task 4: Structural test for `INTERLOCK_AUTO_RELEASE` presence in pre-edit.sh
- Task 6: `TestReleaseByPattern_Idempotent` (empty reservation list)
- Integration: Full round-trip test (request → response → ack verified)

---

## Plan Review Round 2 — Consolidated Flux-Drive Findings (2026-02-16)

Reviews: `docs/research/architecture-review-of-plan.md`, `docs/research/safety-review-of-plan.md`, `docs/research/correctness-review-interlock-negotiation-plan.md`, `docs/research/quality-review-of-plan.md`

**Note:** Implementation is ~85% complete from a previous session. Amendments A1-A6 are already in code. This review validates the existing implementation against the amended plan.

### P0 Blockers (must fix during execution)

**B1: Double-release race in timeout enforcement** (Correctness C1)
- `CheckExpiredNegotiations` sends ack messages even when `released == 0` (lazy check + background goroutine + multi-session overlap can all trigger)
- **Fix:** Add `if released > 0` guard before sending ack in `CheckExpiredNegotiations`

**B2: Idempotency violation in ReleaseByPattern** (Correctness H2)
- `DeleteReservation` 404 treated as error → aborts loop, leaves remaining reservations undeleted
- **Fix:** `if !isNotFound(err) { return released, fmt.Errorf(...) }` — treat 404 as success

**B3: Task 6 force-release without consent** (Safety CRITICAL)
- Force-release deletes reservations without holder consent, conflating abandoned vs active-but-busy agents
- **Fix:** Convert Task 6 timeout to **advisory-only** (align with A3 philosophy):
  - `CheckExpiredNegotiations` returns `{status: "timeout-eligible"}` instead of deleting
  - Requester agent decides whether to force-release via explicit tool call
  - Holder gets `additionalContext` on next edit about timeout-eligible negotiation
  - No automatic reservation deletion by timeout enforcement

**B4: Goroutine lifecycle leak** (Correctness H1, Safety MEDIUM)
- `StopTimeoutChecker()` defined but never called — goroutine orphaned on session end
- **Fix:** Either (a) drop background goroutine entirely, rely on lazy enforcement in `fetch_inbox`, OR (b) wire `StopTimeoutChecker` to MCP server shutdown
- **Preferred:** Option (a) — simpler, lazy enforcement is sufficient since reservation TTLs provide hard expiry

### P1 Fixes (must fix during execution)

**P1-1: Constants location** (Architecture A7 partial)
- Timeout constants in `tools.go` but duplicated in `client.CheckExpiredNegotiations`
- **Fix:** Move to `client.go`, export as `NormalTimeoutMinutes`, `UrgentTimeoutMinutes`, `NegotiationPollInterval`

**P1-2: Circuit breaker missing** (Architecture A8 partial)
- Pre-edit hook inbox fetch has no `--max-time` timeout protection
- **Fix:** Add `intermute_curl_fast` to `lib.sh`, use in pre-edit hook

**P1-3: Error wrapping %v→%w** (Quality critical)
- 4 locations use `%v` instead of `%w`: Task 2 lines 280/320, Task 3 line 558, Task 6 line 882
- **Fix:** Replace with `%w` for error chain preservation

**P1-4: jq injection in Task 4** (Quality critical)
- Raw `$REQ_FILE` in jq pattern match
- **Fix:** Use `jq --arg file "$REQ_FILE"` for safe interpolation

### P2 Fixes (before production)

**P2-1: Test coverage gaps** (A9 + Quality)
- Missing: `TestFetchThread_Fallback`, `TestCheckExpiredNegotiations_Idempotent`, `TestReleaseByPattern_NoReservations`, structural test for `INTERLOCK_AUTO_RELEASE`

**P2-2: Goroutine error backoff** (Safety MEDIUM)
- Background goroutine (if kept) needs panic recovery and error backoff (slow to 5min after 3 consecutive failures)

**P2-3: Structural test count split**
- Task 2 should expect 10 tools, Task 3 should expect 11 tools (not both 11)
