# Intermute Service Architecture & Coordination Capabilities

**Date:** 2026-02-15  
**Service Location:** `/root/projects/Interverse/services/intermute`  
**Service Status:** Development-stage (v0.0.x), operational  
**Language:** Go 1.24, SQLite (modernc.org/sqlite, pure Go, no CGO)  
**Default Port:** 7338

---

## Executive Summary

Intermute is a real-time coordination service for multi-agent systems. It provides deterministic, project-scoped primitives for agent lifecycle management, message routing with threading, and file advisory locks. The service uses SQLite with event sourcing for durability, HTTP for commands, and WebSocket for real-time event broadcast. It's designed to be the central hub for agent orchestration in the Interverse constellation (used by Clavain, Autarch, and other agents).

**Core value:** Preventing overlapping edits through advisory file reservations, explicit message routing with thread views, and coordination across multiple agents without distributed-state complexity.

---

## 1. What Intermute Currently Does

### 1.1 Agent Lifecycle

**API:**
- `POST /api/agents` – Register agent with `project`, `session_id`, `name`, `capabilities[]`, metadata, status
- `GET /api/agents?project=...` – List registered agents for a project
- `POST /api/agents/{id}/heartbeat` – Update `last_seen` timestamp
- `POST /api/agents/{id}/heartbeat?project=...` – Heartbeat with optional project filter

**Data Model:**
```go
type Agent struct {
    ID           string
    SessionID    string          // Stable session identity; reusable after 5min stale threshold
    Name         string
    Project      string          // Hard multi-tenant boundary
    Capabilities []string        // e.g., ["python", "go", "bash"]
    Metadata     map[string]string
    Status       string          // e.g., "running", "idle", "error"
    LastSeen     time.Time       // Updated by heartbeat
    CreatedAt    time.Time
}
```

**Key behaviors:**
- `session_id` prevents concurrent agents in same session (conflict within 5min stale threshold `SessionStaleThreshold`)
- Re-posting same `session_id` updates existing agent (idempotent); reuse allowed after 5min silence
- All queries scoped by `(project, agent_id)` composite key

### 1.2 Message Coordination

**API:**
- `POST /api/messages` – Send message with optional `thread_id`, recipients (`to[]`, `cc[]`, `bcc[]`), subject, body
- `GET /api/inbox/{agent}?since_cursor=...` – Fetch messages with cursor-based pagination (uses `>` not `>=`)
- `POST /api/messages/{id}/ack` – Record acknowledgement event
- `POST /api/messages/{id}/read` – Record read event
- `GET /api/inbox/{agent}/counts` – Get unread/total counts for operator dashboards

**Message Structure:**
```go
type Message struct {
    ID          string
    ThreadID    string          // Optional; only threaded messages indexed
    Project     string
    From        string          // Sender agent
    To          []string        // Primary recipients
    CC          []string        // Carbon copy
    BCC         []string        // Blind carbon copy
    Subject     string
    Body        string
    Metadata    map[string]string
    Attachments []Attachment    // Name + Path
    Importance  string
    AckRequired bool
    Status      string
    CreatedAt   time.Time
    Cursor      uint64          // Global ordering key
}

type RecipientStatus struct {
    AgentID string
    Kind    string              // "to", "cc", or "bcc"
    ReadAt  *time.Time
    AckAt   *time.Time
}
```

**Deduplication & Idempotency:**
- By `(project, message_id)` composite key
- Re-posting same `message_id` overwrites `thread_id` and `body` safely (useful for retries)

**Threading:**
- Only messages with `thread_id` indexed in `thread_index`
- Non-threaded messages excluded from thread views but still in inbox

**Read/Ack Tracking:**
- Per-recipient status tracked in database (not just event log)
- Supports multi-recipient inbox with individual read/ack states

### 1.3 Threading & Conversation History

**API:**
- `GET /api/threads?agent=...&cursor=...` – List thread summaries (paginated DESC by `last_cursor`)
- `GET /api/threads/{thread_id}?cursor=...` – Fetch all messages in thread (ASC by cursor)

**ThreadSummary:**
```go
type ThreadSummary struct {
    ThreadID     string
    LastCursor   uint64
    MessageCount int
    LastFrom     string
    LastBody     string
    LastAt       time.Time
}
```

**Indexing:**
- `thread_index` tracks `(project, thread_id, agent) → last_cursor`
- Participants = sender + all recipients (To, CC, BCC)
- Cursor semantics: `>` (strictly after), not `>=`

---

## 2. Coordination Features

### 2.1 File Reservations (Advisory Locks)

**API:**
- `POST /api/reservations` – Create reservation with TTL (default 30min)
- `GET /api/reservations?project=...` – List active reservations
- `GET /api/reservations?agent=...` – List by agent
- `GET /api/reservations/check?project=...&pattern=...&exclusive=...` – Check conflicts
- `DELETE /api/reservations/{id}` – Release reservation

**Reservation Model:**
```go
type Reservation struct {
    ID          string          // UUID
    AgentID     string
    Project     string
    PathPattern string          // Glob pattern (e.g., "pkg/events/*.go")
    Exclusive   bool            // True = exclusive; false = shared
    Reason      string          // Audit: why reserved
    TTL         time.Duration   // Used at creation time
    CreatedAt   time.Time
    ExpiresAt   time.Time       // Computed from CreatedAt + TTL
    ReleasedAt  *time.Time      // Explicit release time (nil if active)
}

type ConflictDetail struct {
    ReservationID string
    AgentID       string
    AgentName     string
    Pattern       string
    Reason        string
    ExpiresAt     time.Time
}

type ConflictError struct {
    Conflicts []ConflictDetail
}
```

**Conflict Detection:**
- Glob pattern overlap using `internal/glob` package
- Exclusive reservations conflict with any other active reservation on overlapping paths
- Shared reservations co-exist with other shared reservations on same path (but not exclusive)
- Returns `409 Conflict` with conflict details; client can retry or handle

**Expiration & Cleanup:**
- Sweeper background job runs every 60s
- Releases stale reservations based on agent heartbeat (default: 5min grace)
- If agent hasn't heartbeated in 5min, its reservations are auto-released

**Design philosophy:**
- Advisory (not hard process locks) — agents choose to respect conflicts
- Conflict checking before creation (not after)
- Keeps service lightweight; avoids single point of catastrophic blocking

### 2.2 Heartbeat-Driven Lifecycle

**Implicit Behaviors:**
1. Agents must heartbeat regularly (typical: every 30s) to keep status alive
2. After 5min silence, `session_id` becomes reusable (session_stale_threshold)
3. Reservations auto-released after 5min agent silence (sweeper job)
4. Task/session status inferred from heartbeat (idle vs. running) in consumer apps

**Event Types (core/models.go):**
```go
EventMessageCreated = "message.created"
EventMessageAck     = "message.ack"
EventMessageRead    = "message.read"
EventAgentHeartbeat = "agent.heartbeat"
```

---

## 3. Domain Entities & CRUD APIs

Intermute stores workflow-related entities for orchestration. All fully implemented with CRUD endpoints.

### 3.1 Spec (Product Requirement Document)

**Status flow:** `draft` → `research` → `validated` → `archived`

**Endpoints:**
- `POST /api/specs`
- `GET /api/specs?project=...&status=...`
- `GET /api/specs/{id}?project=...`
- `PUT /api/specs/{id}`
- `DELETE /api/specs/{id}?project=...`

**Fields:**
```go
type Spec struct {
    ID        string
    Project   string
    Title     string
    Vision    string
    Users     string      // User personas
    Problem   string      // Problem statement
    Status    SpecStatus
    Version   int64       // Optimistic locking
    CreatedAt, UpdatedAt time.Time
}
```

### 3.2 Epic (Feature Container)

**Status flow:** `open` → `in_progress` → `done`

**Endpoints:**
- `POST /api/epics`
- `GET /api/epics?project=...&status=...`
- `GET /api/epics/{id}?project=...`
- `PUT /api/epics/{id}`
- `DELETE /api/epics/{id}?project=...`

**Fields:**
```go
type Epic struct {
    ID          string
    Project     string
    SpecID      string      // Foreign key to spec
    Title       string
    Description string
    Status      EpicStatus
    Version     int64
    CreatedAt, UpdatedAt time.Time
}
```

### 3.3 Story (User Story)

**Status flow:** `todo` → `in_progress` → `review` → `done`

**Endpoints:**
- `POST /api/stories`
- `GET /api/stories?project=...&status=...`
- `GET /api/stories/{id}?project=...`
- `PUT /api/stories/{id}`
- `DELETE /api/stories/{id}?project=...`

**Fields:**
```go
type Story struct {
    ID                 string
    Project            string
    EpicID             string
    Title              string
    AcceptanceCriteria []string    // AC array
    Status             StoryStatus
    Version            int64
    CreatedAt, UpdatedAt time.Time
}
```

### 3.4 Task (Execution Unit)

**Status flow:** `pending` → `running` → `blocked` → `done`

**Endpoints:**
- `POST /api/tasks`
- `GET /api/tasks?project=...&status=...`
- `GET /api/tasks/{id}?project=...`
- `PUT /api/tasks/{id}`
- `DELETE /api/tasks/{id}?project=...`

**Fields:**
```go
type Task struct {
    ID        string
    Project   string
    StoryID   string      // Foreign key
    Title     string
    Agent     string      // Assigned agent ID
    SessionID string      // Execution session
    Status    TaskStatus
    Version   int64
    CreatedAt, UpdatedAt time.Time
}
```

### 3.5 Insight (Research Finding)

**No status field — used for research data.**

**Endpoints:**
- `POST /api/insights`
- `GET /api/insights?project=...`
- `GET /api/insights/{id}?project=...`
- `PUT /api/insights/{id}`
- `DELETE /api/insights/{id}?project=...`

**Fields:**
```go
type Insight struct {
    ID        string
    Project   string
    SpecID    string      // Foreign key to spec
    Source    string      // e.g., "research-agent", "user-feedback"
    Category  string      // e.g., "market", "technical"
    Title     string
    Body      string      // Detailed finding
    URL       string      // Source reference
    Score     float64     // Relevance/confidence score
    CreatedAt time.Time
}
```

### 3.6 Session (Agent Execution Context)

**Status flow:** `running` → `idle` → `error`

**Endpoints:**
- `POST /api/sessions`
- `GET /api/sessions?project=...`
- `GET /api/sessions/{id}?project=...`
- `PUT /api/sessions/{id}`
- `DELETE /api/sessions/{id}?project=...`

**Fields:**
```go
type Session struct {
    ID        string
    Project   string
    Name      string          // e.g., "clavain-session-001"
    Agent     string          // Agent ID
    TaskID    string          // Current task
    Status    SessionStatus
    StartedAt, UpdatedAt time.Time
}
```

### 3.7 Critical User Journey (CUJ)

**Status flow:** `draft` → `validated` → `archived`  
**Priority:** `high`, `medium`, `low`

**Endpoints:**
- `POST /api/cujs`
- `GET /api/cujs?project=...`
- `GET /api/cujs/{id}?project=...`
- `PUT /api/cujs/{id}`
- `DELETE /api/cujs/{id}?project=...`

**Fields:**
```go
type CriticalUserJourney struct {
    ID              string
    SpecID          string      // Foreign key
    Project         string
    Title           string
    Persona         string      // e.g., "admin", "end-user"
    Priority        CUJPriority
    EntryPoint      string      // Start of journey
    ExitPoint       string      // End of journey
    Steps           []CUJStep   // Ordered steps
    SuccessCriteria []string
    ErrorRecovery   []string
    Status          CUJStatus
    Version         int64
    CreatedAt, UpdatedAt time.Time
}

type CUJStep struct {
    Order        int
    Action       string          // What user does
    Expected     string          // Expected result
    Alternatives []string        // Alternative paths
}
```

---

## 4. HTTP API Endpoints Summary

### Health
- `GET /api/health` – Server readiness

### Agent Management
- `POST /api/agents` – Register
- `GET /api/agents?project=...` – List
- `POST /api/agents/{id}/heartbeat` – Heartbeat

### Messaging
- `POST /api/messages` – Send message
- `GET /api/inbox/{agent}?since_cursor=...&limit=...` – Inbox
- `GET /api/inbox/{agent}/counts` – Counts
- `POST /api/messages/{id}/ack` – Acknowledge
- `POST /api/messages/{id}/read` – Mark read

### Threading
- `GET /api/threads?agent=...&cursor=...&limit=...` – List threads
- `GET /api/threads/{thread_id}?cursor=...` – Get thread

### File Reservations
- `POST /api/reservations` – Create reservation
- `GET /api/reservations?project=...` or `?agent=...` – List
- `GET /api/reservations/check?project=...&pattern=...&exclusive=...` – Check conflicts
- `DELETE /api/reservations/{id}` – Release

### Domain Entities (Specs, Epics, Stories, Tasks, Insights, Sessions, CUJs)
- `POST /api/{entity}` – Create
- `GET /api/{entity}?project=...` – List
- `GET /api/{entity}/{id}?project=...` – Get
- `PUT /api/{entity}/{id}` – Update
- `DELETE /api/{entity}/{id}?project=...` – Delete

### WebSocket
- `WS /ws/agents/{agent_id}?project=...` – Real-time message stream

---

## 5. Go Service Architecture

### 5.1 Directory Structure

```
cmd/intermute/
  main.go              Entry point; wires all components
  main_test.go

client/
  client.go            Go SDK for agent communication
  domain.go            SDK helper types
  websocket.go         WebSocket client
  client_test.go

internal/
  auth/
    config.go          Auth configuration
    middleware.go      Bearer token validation
    bootstrap.go       Dev key generation
  
  core/
    models.go          Message, Agent, Event, Reservation
    domain.go          Spec, Epic, Story, Task, Insight, Session, CUJ
  
  http/
    service.go         Core HTTP service
    router.go          Multiplexer for REST endpoints
    router_domain.go   Domain entity route registration
    handlers_agents.go
    handlers_messages.go
    handlers_threads.go
    handlers_reservations.go
    handlers_domain.go  All domain entity handlers
    handlers_health.go
    auth_test.go
    *_test.go
  
  storage/
    storage.go         Store interface + InMemory impl
    domain.go          DomainStore interface
    sqlite/
      sqlite.go        SQLite implementation
      domain.go        Domain entity operations
      schema.sql       DDL (embedded)
      migrations.go    Schema migration functions
      retry.go         Retry logic for transient failures
      circuitbreaker.go Circuit breaker for cascading failures
      resilient.go     Wraps store with retry + CB
      sweeper.go       Background job: release stale reservations
      querylog.go      Query logging for debugging
  
  ws/
    gateway.go         WebSocket hub + connection management
  
  server/
    server.go          Server startup + shutdown
  
  names/
    culture.go         Culture-based name generator
  
  glob/
    overlap.go         Glob pattern intersection detection
  
  cli/
    init.go            CLI for key initialization
  
  pkg/
    embedded/
      server.go        Embedded server for binary builds

internal/smoke_test.go  Integration test suite
```

### 5.2 HTTP Handler Pattern

All handlers follow a consistent pattern:

```go
// Method dispatch
func (s *Service) handleXxx(w http.ResponseWriter, r *http.Request) {
    switch r.Method {
    case http.MethodGet:
        s.listXxx(w, r)
    case http.MethodPost:
        s.createXxx(w, r)
    // ...
    }
}

// Per-operation handlers
func (s *Service) createXxx(w http.ResponseWriter, r *http.Request) {
    // Parse JSON
    // Extract auth info
    // Call store method
    // Broadcast event via hub (if set)
    // Write response
}
```

**Request flow:**
1. HTTP request → auth middleware → handler
2. Handler deserializes JSON → validates → calls store
3. Store persists + returns
4. If broadcaster set: handler calls `Broadcast(project, agent, event)`
5. Hub broadcasts to all WebSocket clients subscribed to (project, agent)

### 5.3 Storage Layer

**Store Interface:**
```go
type Store interface {
    // Events
    AppendEvent(ctx, event) (cursor, error)
    
    // Messages & Inbox
    InboxSince(ctx, project, agent, cursor, limit) ([]Message, error)
    ThreadMessages(ctx, project, threadID, cursor) ([]Message, error)
    ListThreads(ctx, project, agent, cursor, limit) ([]ThreadSummary, error)
    MarkRead(ctx, project, messageID, agentID) error
    MarkAck(ctx, project, messageID, agentID) error
    RecipientStatus(ctx, project, messageID) (map[string]*RecipientStatus, error)
    InboxCounts(ctx, project, agentID) (total, unread, error)
    
    // Agents
    RegisterAgent(ctx, agent) (Agent, error)
    Heartbeat(ctx, project, agentID) (Agent, error)
    ListAgents(ctx, project) ([]Agent, error)
    
    // Reservations
    Reserve(ctx, r) (*Reservation, error)
    GetReservation(ctx, id) (*Reservation, error)
    ReleaseReservation(ctx, id, agentID) error
    ActiveReservations(ctx, project) ([]Reservation, error)
    AgentReservations(ctx, agentID) ([]Reservation, error)
    CheckConflicts(ctx, project, pathPattern, exclusive) ([]ConflictDetail, error)
}

type DomainStore interface {
    // Specs
    CreateSpec(ctx, spec) (Spec, error)
    GetSpec(ctx, project, id) (Spec, error)
    ListSpecs(ctx, project, status) ([]Spec, error)
    UpdateSpec(ctx, spec) (Spec, error)
    DeleteSpec(ctx, project, id) error
    
    // Epics, Stories, Tasks, Insights, Sessions, CUJs (similar)
    // ...
}
```

**Implementations:**
1. **InMemory** (tests only) – Minimal in-memory store; no durability
2. **SQLite** (production) – Full schema with migrations, optimized queries, indexes

### 5.4 SQLite Schema Overview

**Core tables:**
- `events` – Append-only event log (cursor PK)
- `messages` – Indexed messages with project/message_id composite key
- `inbox_index` – Materialized view: agent → messages (cursor ordered)
- `thread_index` – Materialized view: agent → threads (last_cursor ordered)
- `agents` – Agent registry with heartbeat tracking
- `recipient_status` – Per-recipient read/ack tracking

**Domain tables:**
- `specs`, `epics`, `stories`, `tasks`, `insights`, `sessions`, `cujs`
- Each has `(project, id)` composite PK + `version` for optimistic locking

**Reservation tables:**
- `reservations` – Reservation records with TTL/expiration
- `reservation_events` – Audit log of reservation lifecycle

**Indexes:**
- Project-scoped lookups: `(project, id)`, `(project, agent)`, `(project, thread_id)`
- Cursor ordering: `(project, cursor DESC)`, `(thread_id, cursor ASC)`
- Session uniqueness: `UNIQUE (session_id)` with `WHERE session_id IS NOT NULL`

**Migrations:**
- Applied sequentially at startup via `applySchema()`
- Adds new columns/indexes idempotently
- Respects SQLite limitations (no ALTER COLUMN, uses CREATE IF NOT EXISTS)

### 5.5 Resilience Layer

**Retry Logic (`sqlite/retry.go`):**
- Exponential backoff for transient failures (busy errors, lock timeouts)
- Default: 3 attempts, max 100ms delay
- Only retries known-recoverable errors (sqlite.ErrBusy, ErrIOErr)

**Circuit Breaker (`sqlite/circuitbreaker.go`):**
- Prevents cascading failures during sustained DB unavailability
- States: Closed (normal) → Open (failing fast) → Half-Open (test recovery)
- Configurable thresholds: failure count, success threshold, timeout

**Resilient Wrapper (`sqlite/resilient.go`):**
- Wraps store operations with retry + circuit breaker
- Used in production (see `main.go` line 59: `sqlite.NewResilient(store)`)

**Sweeper (`sqlite/sweeper.go`):**
- Background goroutine: runs every 60s
- Releases reservations for agents without recent heartbeat
- Reports released counts to hub (can broadcast cleanup events)

### 5.6 WebSocket Gateway

**Hub (`internal/ws/gateway.go`):**
```go
type Hub struct {
    conns map[string]map[string]map[*websocket.Conn]struct{}  // project → agent → connections
}

func (h *Hub) Broadcast(project, agent string, event any)
```

**Handler:**
- Path: `GET /ws/agents/{agent_id}?project=...`
- Auth: validates project scope via middleware
- Subscribe: adds connection to hub[project][agent]
- Unsubscribe: removes connection on disconnect
- No echo back: server-side only (receives client messages but ignores them)

**Real-time Flow:**
1. Client (agent) connects to `WS /ws/agents/{agent_id}?project=...`
2. Handler spawns subscriber in hub
3. When message posted via `POST /api/messages`, handler calls `hub.Broadcast(project, agent, event)`
4. Hub sends JSON event to all connected WebSocket clients for that (project, agent)

---

## 6. Agent Interaction Patterns

### 6.1 Agent Registration & Heartbeat

```
Agent A sends:   POST /api/agents
                 { "name": "research-agent-1", "project": "acme", "capabilities": ["python"] }
Server creates:  Agent ID = "research-agent-1" (or random if not provided)
                 SessionID = "research-agent-1-session" (auto-generated if not provided)

Agent A then:    POST /api/agents/{id}/heartbeat (every 30s)
                 Updates last_seen; keeps agent "alive" for session/reservation cleanup
```

### 6.2 Message Routing

```
Agent A sends:   POST /api/messages
                 { "from": "agent-a", "to": ["agent-b"], "thread_id": "conv-001", "body": "..." }
Server appends:  Event (type=message.created) + materializes to messages/inbox_index
Server returns:  { "message_id": "msg-123", "cursor": 42 }

Agent B polls:   GET /api/inbox/agent-b?since_cursor=0
Server returns:  [{ message details, cursor: 42 }]

OR Agent B real-time subscribes:
                 WS /ws/agents/agent-b?project=acme
                 Receives message event broadcast instantly
```

### 6.3 Reservation Workflow

```
Agent A plans:   I need to edit pkg/handlers/core.go
                 POST /api/reservations
                 { "agent_id": "agent-a", "project": "acme", "path_pattern": "pkg/handlers/*.go", "exclusive": true }

Server checks:   Any active reservation overlap on "pkg/handlers/*.go"?
If conflict:     409 Conflict { "conflicts": [...] }
If clear:        201 Created { "id": "res-uuid", "expires_at": "...", "is_active": true }

Agent A edits:   (now safe; other agents won't claim overlapping files)

Agent A done:    DELETE /api/reservations/{id}
Server releases: Explicit release; freeing path for peers

OR auto-expired: If agent-a doesn't heartbeat for 5min → sweeper auto-releases
```

### 6.4 Domain Entity Coordination

```
Orchestrator:    POST /api/specs
                 { "title": "V2 Roadmap", "vision": "...", "project": "acme" }
Server:          Creates spec + broadcasts EventSpecCreated to WebSocket hub

Agent (research):
                 GET /api/specs/spec-id-123?project=acme
                 (fetches latest spec)

Agent (dev):     PUT /api/specs/spec-id-123
                 { ..., "status": "validated", "version": 1 }
Server:          Checks version = 1; updates to version 2; broadcasts EventSpecUpdated
                 Concurrent updater with stale version gets 409 Conflict

Task assignment: POST /api/tasks
                 { "story_id": "story-456", "agent": "dev-agent", "status": "pending" }
Server:          Creates task; broadcasts EventTaskCreated; dev-agent can poll /api/tasks?project=acme or subscribe via WS
```

---

## 7. Multi-Session & Multi-Agent Features

### 7.1 Session Conflict Prevention

**Scenario:** Two agent instances try to use same session_id simultaneously.

```go
// Constraint
UNIQUE INDEX ON agents(session_id) WHERE session_id IS NOT NULL AND session_id != ''

// Behavior
PostAgent(agent: { session_id: "session-xyz" })

// If another agent already has "session-xyz" with recent heartbeat (<5min):
→ 409 Conflict: ErrActiveSessionConflict
→ Agent must wait 5min or use different session_id

// If the other agent is stale (>5min no heartbeat):
→ 200 OK: Updates existing agent record (idempotent re-registration)
```

### 7.2 Distributed Message Threading

All participants (sender + all recipients) are indexed in the thread:

```go
Message { from: "a", to: ["b", "c"], thread_id: "t1" }
→ Indexes: thread_index[(project, t1, a)], thread_index[(project, t1, b)], thread_index[(project, t1, c)]

GET /api/threads?agent=a → Shows threads where agent-a is participant
GET /api/threads?agent=b → Shows same threads
GET /api/threads/{t1}?cursor=0 → All messages in thread (all agents see same order)
```

### 7.3 File Reservation Conflict Detection

```go
// Agent A reserves
POST /api/reservations { pattern: "pkg/foo/*.go", exclusive: true, agent: "agent-a" }
→ 201 OK

// Agent B tries to reserve overlapping path
POST /api/reservations { pattern: "pkg/foo/bar.go", exclusive: true, agent: "agent-b" }
→ 409 Conflict { "conflicts": [{ "agent_id": "agent-a", "pattern": "pkg/foo/*.go", ... }] }

// Agent B tries shared (non-exclusive) on same pattern
POST /api/reservations { pattern: "pkg/foo/bar.go", exclusive: false, agent: "agent-b" }
→ 409 Conflict (because agent-a has exclusive; exclusive blocks all)

// Agent A changes to shared
DELETE /api/reservations/res-a-id
POST /api/reservations { pattern: "pkg/foo/*.go", exclusive: false, agent: "agent-a" }

// Now agent-b can claim shared
POST /api/reservations { pattern: "pkg/foo/bar.go", exclusive: false, agent: "agent-b" }
→ 201 OK (both have non-exclusive; can coexist)
```

### 7.4 Optimistic Locking for Domain Entities

All domain entities have a `version` field for conflict detection:

```go
// Agent A fetches spec
GET /api/specs/spec-123 → { "id": "spec-123", "title": "...", "version": 1 }

// Agent A tries update
PUT /api/specs/spec-123 { "title": "Updated", "version": 1 }
→ 200 OK; version auto-incremented to 2

// Agent B (with stale version)
PUT /api/specs/spec-123 { "title": "Other update", "version": 1 }
→ 409 Conflict (version mismatch; no rows affected)
```

---

## 8. Current Limitations & Gotchas

### 8.1 Advisory Nature of Reservations

Intermute **does not enforce** file locks at the filesystem level. It's a coordination layer:
- Agents must voluntarily check conflicts before editing
- Intermute reports conflicts; it doesn't prevent writes
- Intended for cooperative multi-agent environments

### 8.2 Cursor Semantics

```go
// Fetch messages AFTER cursor 42 (not including 42)
GET /api/inbox/agent?since_cursor=42
→ Returns messages where cursor > 42

// First fetch should use cursor=0 to get all
GET /api/inbox/agent?since_cursor=0
```

### 8.3 Non-Threaded Messages Excluded

```go
// This message won't appear in thread views
POST /api/messages { "from": "a", "to": ["b"], "body": "...", "thread_id": "" }

// But it will appear in inbox
GET /api/inbox/b
→ Includes all messages, threaded or not
```

### 8.4 Ack/Read Tracking

- Events logged for ack/read
- Per-recipient status tracked in database
- But no automatic status updates (agents explicitly call ack/read endpoints)

### 8.5 Localhost Bypass

- `127.0.0.1` requests allowed without auth by default
- Non-localhost requests require `Authorization: Bearer <key>`
- LAN origin (e.g., 192.168.x.x) requires API key

### 8.6 No Session Awareness in Beads

Current multi-session coordination docs are in planning. Script-based conflict checks exist but don't filter by session (warns about ALL in-progress beads, not just current session's).

---

## 9. Deployment & Configuration

### 9.1 Starting the Server

```bash
go run ./cmd/intermute serve
  --host 127.0.0.1 (default)
  --port 7338 (default)
  --db intermute.db (default)
```

### 9.2 Environment Variables

**Client-side:**
- `INTERMUTE_URL` – e.g., `http://localhost:7338`
- `INTERMUTE_API_KEY` – Bearer token for non-localhost
- `INTERMUTE_PROJECT` – Project name (required with API key)
- `INTERMUTE_AGENT_NAME` – Override agent name

**Server-side:**
- `INTERMUTE_KEYS_FILE` – Path to keys.yaml (fallback: `./intermute.keys.yaml`)

### 9.3 Authentication

**Keys file (`intermute.keys.yaml`):**
```yaml
default_policy:
  allow_localhost_without_auth: true
projects:
  acme:
    keys:
      - secret-key-1
      - secret-key-2
  dev:
    keys:
      - dev-key-xyz
```

**Initialization:**
```bash
go run ./cmd/intermute init --project acme
→ Writes new key entry to keys.yaml; logs generated key
```

**Bootstrap:** If keys file missing, server auto-generates dev key on startup.

---

## 10. Testing

**Test suite:**
```bash
go test ./...              # All tests
go test -v ./...           # Verbose
go test -cover ./...       # Coverage
go test ./internal/storage/sqlite  # Single package
```

**Test patterns:**
- `sqlite_test.go` – In-memory SQLite with cursor/thread/migration tests
- `handlers_*_test.go` – httptest.Server integration tests
- `client_test.go` – Mock server for SDK validation
- `smoke_test.go` – End-to-end scenario tests

---

## 11. Downstream Dependencies

**Autarch** (`/root/projects/Autarch`) consumes:
- `pkg/embedded/` – Embedded server binary (builds into Autarch)
- Domain APIs – Specs, tasks, sessions
- Agent coordination – Registration, heartbeats, messages
- Reservation system – File conflict avoidance

**After changes to core APIs**, notify:
```bash
cd /root/projects/Autarch
go get github.com/mistakeknot/intermute@latest
go build ./cmd/autarch  # Verify compile
```

---

## 12. Key Architectural Decisions

| Decision | Rationale |
|----------|-----------|
| **Cursor-based pagination** | Resilient to insertions; avoids offset drift |
| **Composite PKs (project, id)** | Enforces multi-tenant isolation at schema level |
| **Event sourcing** | Append-only guarantees; audit trail; recovery |
| **Thread indexing by participants** | All agents see same view; no lost conversations |
| **Advisory locks** | Lightweight; cooperative; avoids process-level blocking |
| **SQLite + Event sourcing** | Pragmatic persistence; no distributed consensus |
| **HTTP commands + WebSocket events** | Clean separation: commands idempotent, events broadcast |
| **Project as hard boundary** | Multi-tenancy explicit; accidental cross-talk low |
| **Glob-based path patterns** | Flexible reservation scopes; matches developer mental model |
| **Optimistic locking (version)** | Detects concurrent modification; fails safe (409) |
| **Heartbeat-driven cleanup** | Implicit session/reservation lifecycle; no manual cleanup |
| **Circuit breaker + retry** | Resilience layer; fails gracefully under contention |

---

## 13. Future Extensions (Planned)

From docs/plans/2026-02-14-multi-session-coordination.md:

1. **Multi-session coordination hooks** – Pre-edit file conflict warnings via Claude Code
2. **Worktree isolation** – Scripts for parallel development branches
3. **Session awareness** – Beads integration for work partitioning
4. **CUJ feature linking** – Many-to-many links between CUJs and features (schema ready; handlers TBD)

---

## Conclusion

Intermute is a stable, operationally-sound coordination service designed for multi-agent workflows. It trades enterprise features (distributed consensus, hard locks, granular auth) for simplicity and pragmatism. Its sweet spot is cooperative teams of agents on the same codebase using advisory locks, explicit messaging, and heartbeat-driven lifecycle management.

The service is ready for production use in Interverse deployments (Clavain, Autarch, Pollard) and can be extended as coordination patterns mature.
