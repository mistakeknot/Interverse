# Intercore E5: Discovery Pipeline — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use clavain:executing-plans to implement this plan task-by-task.

**Goal:** Add discovery as a first-class kernel subsystem — tables, CRUD, events, feedback, gates, and search — so Interject (and future scanners) write to the kernel and the kernel owns the durable record.

**Architecture:** New `internal/discovery` package with a `Store` struct wrapping `*sql.DB` (same pattern as `phase.Store`, `event.Store`, `dispatch.Store`). Three new tables (`discoveries`, `feedback_signals`, `interest_profile`) added via v8→v9 migration in `internal/db/db.go`. CLI surface added as `ic discovery` subcommand in `cmd/ic/discovery.go`. Discovery events added as third `UNION ALL` leg in the existing event bus.

**Tech Stack:** Go 1.22, `modernc.org/sqlite` (pure Go, no CGO), `crypto/rand` for ID generation, `math` for cosine similarity.

**Bead:** iv-fra3
**Phase:** executing (as of 2026-02-20T20:26:42Z)
**PRD:** docs/prds/2026-02-20-intercore-e5-discovery-pipeline.md

---

## Task 1: Discovery Store Package — Types + ID Generation

**Files:**
- Create: `infra/intercore/internal/discovery/discovery.go`
- Create: `infra/intercore/internal/discovery/errors.go`
- Create: `infra/intercore/internal/discovery/store.go`

**Step 1: Create the types file**

Create `internal/discovery/discovery.go` with all domain types:

```go
package discovery

import (
	"crypto/rand"
	"fmt"
	"math/big"
	"time"
)

const (
	idLen   = 12
	idChars = "abcdefghijklmnopqrstuvwxyz0123456789"
)

// Status constants for discovery lifecycle.
const (
	StatusNew       = "new"
	StatusScored    = "scored"
	StatusPromoted  = "promoted"
	StatusProposed  = "proposed"
	StatusDismissed = "dismissed"
)

// Tier constants for confidence classification.
const (
	TierHigh    = "high"
	TierMedium  = "medium"
	TierLow     = "low"
	TierDiscard = "discard"
)

// Tier boundaries (score thresholds).
const (
	TierHighMin    = 0.8
	TierMediumMin  = 0.5
	TierLowMin     = 0.3
)

// Signal types for feedback.
const (
	SignalPromote        = "promote"
	SignalDismiss        = "dismiss"
	SignalAdjustPriority = "adjust_priority"
	SignalBoost          = "boost"
	SignalPenalize       = "penalize"
)

// Event types for discovery events.
const (
	EventSubmitted = "discovery.submitted"
	EventScored    = "discovery.scored"
	EventPromoted  = "discovery.promoted"
	EventProposed  = "discovery.proposed"
	EventDismissed = "discovery.dismissed"
	EventDecayed   = "discovery.decayed"
	EventDeduped   = "discovery.deduped"
	EventFeedback  = "feedback.recorded"
)

// Discovery represents a research finding tracked in the kernel.
type Discovery struct {
	ID             string   `json:"id"`
	Source         string   `json:"source"`
	SourceID       string   `json:"source_id"`
	Title          string   `json:"title"`
	Summary        string   `json:"summary,omitempty"`
	URL            string   `json:"url,omitempty"`
	RawMetadata    string   `json:"raw_metadata,omitempty"`
	Embedding      []byte   `json:"-"` // BLOB, not serialized to JSON
	RelevanceScore float64  `json:"relevance_score"`
	ConfidenceTier string   `json:"confidence_tier"`
	Status         string   `json:"status"`
	RunID          *string  `json:"run_id,omitempty"`
	BeadID         *string  `json:"bead_id,omitempty"`
	DiscoveredAt   int64    `json:"discovered_at"`
	PromotedAt     *int64   `json:"promoted_at,omitempty"`
	ReviewedAt     *int64   `json:"reviewed_at,omitempty"`
}

// FeedbackSignal represents a feedback event on a discovery.
type FeedbackSignal struct {
	ID          int64  `json:"id"`
	DiscoveryID string `json:"discovery_id"`
	SignalType  string `json:"signal_type"`
	SignalData  string `json:"signal_data,omitempty"`
	Actor       string `json:"actor"`
	CreatedAt   int64  `json:"created_at"`
}

// InterestProfile represents the learned interest model (singleton row).
type InterestProfile struct {
	ID             int    `json:"id"`
	TopicVector    []byte `json:"-"` // BLOB
	KeywordWeights string `json:"keyword_weights"`
	SourceWeights  string `json:"source_weights"`
	UpdatedAt      int64  `json:"updated_at"`
}

// DiscoveryEvent represents a discovery lifecycle event.
// Note: no Timestamp time.Time field — matches event.Event and event.InterspectEvent
// which use only integer timestamps. Callers convert at scan time if needed.
type DiscoveryEvent struct {
	ID           int64  `json:"id"`
	DiscoveryID  string `json:"discovery_id"`
	EventType    string `json:"event_type"`
	FromStatus   string `json:"from_status"`
	ToStatus     string `json:"to_status"`
	Payload      string `json:"payload,omitempty"`
	CreatedAt    int64  `json:"created_at"`
}

// TierFromScore computes the confidence tier for a given score.
func TierFromScore(score float64) string {
	switch {
	case score >= TierHighMin:
		return TierHigh
	case score >= TierMediumMin:
		return TierMedium
	case score >= TierLowMin:
		return TierLow
	default:
		return TierDiscard
	}
}

func generateID() (string, error) {
	b := make([]byte, idLen)
	max := big.NewInt(int64(len(idChars)))
	for i := range b {
		n, err := rand.Int(rand.Reader, max)
		if err != nil {
			return "", fmt.Errorf("generate id: %w", err)
		}
		b[i] = idChars[n.Int64()]
	}
	return string(b), nil
}
```

**Step 2: Create the errors file**

Create `internal/discovery/errors.go` with sentinel errors for CLI exit code mapping:

```go
package discovery

import "errors"

// Sentinel errors — callers use errors.Is() to map CLI exit codes.
// exit 1 = ErrNotFound, exit 1 = ErrGateBlocked, exit 4 = ErrDuplicate
var (
	ErrNotFound    = errors.New("discovery not found")
	ErrGateBlocked = errors.New("gate blocked: confidence below promotion threshold")
	ErrDuplicate   = errors.New("duplicate discovery: source/source_id already exists")
	ErrLifecycle   = errors.New("invalid lifecycle transition")
)
```

**Step 3: Create the store skeleton**

Create `internal/discovery/store.go` with the `Store` struct and constructor:

```go
package discovery

import "database/sql"

// Store provides discovery CRUD and event operations.
type Store struct {
	db *sql.DB
}

// NewStore creates a discovery store.
func NewStore(db *sql.DB) *Store {
	return &Store{db: db}
}
```

**Step 4: Commit**

```bash
git add infra/intercore/internal/discovery/
git commit -m "feat(intercore): add discovery package types, errors, and store skeleton (E5)"
```

---

## Task 2: Schema Migration v8→v9

**Files:**
- Modify: `infra/intercore/internal/db/schema.sql` — add three new tables
- Modify: `infra/intercore/internal/db/db.go` — bump version, add migration step

**Step 1: Write failing integration test**

Add to `test-integration.sh` (at the end, before cleanup):

```bash
echo "=== Discovery Schema ==="
# Verify discoveries table exists after migration
sqlite3 "$TEST_DB" "SELECT count(*) FROM discoveries" >/dev/null 2>&1 || fail "discoveries table missing"
pass "discoveries table exists"

sqlite3 "$TEST_DB" "SELECT count(*) FROM discovery_events" >/dev/null 2>&1 || fail "discovery_events table missing"
pass "discovery_events table exists"

sqlite3 "$TEST_DB" "SELECT count(*) FROM feedback_signals" >/dev/null 2>&1 || fail "feedback_signals table missing"
pass "feedback_signals table exists"

sqlite3 "$TEST_DB" "SELECT count(*) FROM interest_profile" >/dev/null 2>&1 || fail "interest_profile table missing"
pass "interest_profile table exists"

# Verify schema version is 9
schema_ver=$(sqlite3 "$TEST_DB" "PRAGMA user_version")
[[ "$schema_ver" == "9" ]] || fail "schema version: expected 9, got $schema_ver"
pass "schema version is 9"
```

**Step 2: Run test to verify it fails**

```bash
cd /root/projects/Interverse/infra/intercore && bash test-integration.sh
```

Expected: FAIL with "discoveries table missing"

**Step 3: Add tables to schema.sql**

Append to `internal/db/schema.sql`:

```sql
-- v9: discovery pipeline
CREATE TABLE IF NOT EXISTS discoveries (
    id              TEXT PRIMARY KEY,
    source          TEXT NOT NULL,
    source_id       TEXT NOT NULL,
    title           TEXT NOT NULL,
    summary         TEXT NOT NULL DEFAULT '',
    url             TEXT NOT NULL DEFAULT '',
    raw_metadata    TEXT NOT NULL DEFAULT '{}',
    embedding       BLOB,
    relevance_score REAL NOT NULL DEFAULT 0.0,
    confidence_tier TEXT NOT NULL DEFAULT 'low',
    status          TEXT NOT NULL DEFAULT 'new',
    run_id          TEXT,
    bead_id         TEXT,
    discovered_at   INTEGER NOT NULL DEFAULT (unixepoch()),
    promoted_at     INTEGER,
    reviewed_at     INTEGER,
    UNIQUE(source, source_id)
);
CREATE INDEX IF NOT EXISTS idx_discoveries_source ON discoveries(source);
CREATE INDEX IF NOT EXISTS idx_discoveries_status ON discoveries(status) WHERE status NOT IN ('dismissed');
CREATE INDEX IF NOT EXISTS idx_discoveries_tier ON discoveries(confidence_tier);

CREATE TABLE IF NOT EXISTS discovery_events (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    discovery_id    TEXT NOT NULL,
    event_type      TEXT NOT NULL,
    from_status     TEXT NOT NULL DEFAULT '',
    to_status       TEXT NOT NULL DEFAULT '',
    payload         TEXT NOT NULL DEFAULT '{}',
    created_at      INTEGER NOT NULL DEFAULT (unixepoch())
);
CREATE INDEX IF NOT EXISTS idx_discovery_events_discovery ON discovery_events(discovery_id);
CREATE INDEX IF NOT EXISTS idx_discovery_events_created ON discovery_events(created_at);

CREATE TABLE IF NOT EXISTS feedback_signals (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    discovery_id    TEXT NOT NULL,
    signal_type     TEXT NOT NULL,
    signal_data     TEXT NOT NULL DEFAULT '{}',
    actor           TEXT NOT NULL DEFAULT 'system',
    created_at      INTEGER NOT NULL DEFAULT (unixepoch())
);
CREATE INDEX IF NOT EXISTS idx_feedback_signals_discovery ON feedback_signals(discovery_id);

CREATE TABLE IF NOT EXISTS interest_profile (
    id              INTEGER PRIMARY KEY CHECK (id = 1),
    topic_vector    BLOB,
    keyword_weights TEXT NOT NULL DEFAULT '{}',
    source_weights  TEXT NOT NULL DEFAULT '{}',
    updated_at      INTEGER NOT NULL DEFAULT (unixepoch())
);
```

**Step 4: Update db.go — bump version constants**

In `internal/db/db.go`, change:

```go
const (
	currentSchemaVersion = 9
	maxSchemaVersion     = 9
)
```

No v8→v9 ALTER TABLE migration step needed — the three tables are new (CREATE TABLE IF NOT EXISTS handles idempotency). The existing `schemaDDL` application + version bump handles it.

**Step 5: Run integration test to verify it passes**

```bash
cd /root/projects/Interverse/infra/intercore && bash test-integration.sh
```

Expected: All tests PASS, including new "discoveries table exists" etc.

**Step 6: Run unit tests**

```bash
cd /root/projects/Interverse/infra/intercore && go test ./...
```

**Step 7: Commit**

```bash
git add infra/intercore/internal/db/db.go infra/intercore/internal/db/schema.sql infra/intercore/test-integration.sh
git commit -m "feat(intercore): schema v9 — add discovery tables and indexes (E5-F1)"
```

---

## Task 3: Discovery Submit + Get + List (Store Layer)

**Files:**
- Modify: `infra/intercore/internal/discovery/store.go` — add Submit, Get, List methods
- Create: `infra/intercore/internal/discovery/store_test.go` — unit tests

**Step 1: Write failing tests**

Create `internal/discovery/store_test.go`:

```go
package discovery

import (
	"context"
	"database/sql"
	"os"
	"path/filepath"
	"testing"

	_ "modernc.org/sqlite"

	"github.com/mistakeknot/interverse/infra/intercore/internal/db"
)

func setupTestDB(t *testing.T) *sql.DB {
	t.Helper()
	dir := t.TempDir()
	dbPath := filepath.Join(dir, ".clavain", "intercore.db")
	os.MkdirAll(filepath.Dir(dbPath), 0700)

	d, err := db.Open(dbPath, 0)
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	if err := d.Migrate(context.Background()); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	t.Cleanup(func() { d.Close() })
	return d.SqlDB()
}

func TestSubmitAndGet(t *testing.T) {
	sqlDB := setupTestDB(t)
	s := NewStore(sqlDB)
	ctx := context.Background()

	id, err := s.Submit(ctx, "arxiv", "2401.12345", "Attention Is All You Need v2", "A followup paper", "https://arxiv.org/abs/2401.12345", "{}", nil, 0.7)
	if err != nil {
		t.Fatalf("submit: %v", err)
	}
	if id == "" {
		t.Fatal("submit returned empty ID")
	}

	d, err := s.Get(ctx, id)
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	if d.Source != "arxiv" {
		t.Errorf("source: got %q, want %q", d.Source, "arxiv")
	}
	if d.ConfidenceTier != TierMedium {
		t.Errorf("tier: got %q, want %q (score 0.7)", d.ConfidenceTier, TierMedium)
	}
}

func TestSubmitDuplicateSourceID(t *testing.T) {
	sqlDB := setupTestDB(t)
	s := NewStore(sqlDB)
	ctx := context.Background()

	_, err := s.Submit(ctx, "arxiv", "dup-1", "First", "", "", "{}", nil, 0.5)
	if err != nil {
		t.Fatalf("first submit: %v", err)
	}

	_, err = s.Submit(ctx, "arxiv", "dup-1", "Second", "", "", "{}", nil, 0.5)
	if err == nil {
		t.Fatal("expected duplicate constraint error, got nil")
	}
	if !errors.Is(err, ErrDuplicate) {
		t.Errorf("expected ErrDuplicate, got: %v", err)
	}
}

func TestList(t *testing.T) {
	sqlDB := setupTestDB(t)
	s := NewStore(sqlDB)
	ctx := context.Background()

	s.Submit(ctx, "arxiv", "a1", "Paper A", "", "", "{}", nil, 0.9)
	s.Submit(ctx, "hackernews", "h1", "HN Post", "", "", "{}", nil, 0.4)
	s.Submit(ctx, "arxiv", "a2", "Paper B", "", "", "{}", nil, 0.6)

	// List all
	results, err := s.List(ctx, ListFilter{Limit: 10})
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(results) != 3 {
		t.Fatalf("list count: got %d, want 3", len(results))
	}
	// Should be sorted by relevance_score DESC
	if results[0].RelevanceScore < results[1].RelevanceScore {
		t.Error("list not sorted by relevance_score DESC")
	}

	// Filter by source
	results, err = s.List(ctx, ListFilter{Source: "arxiv", Limit: 10})
	if err != nil {
		t.Fatalf("list source: %v", err)
	}
	if len(results) != 2 {
		t.Fatalf("list source count: got %d, want 2", len(results))
	}

	// Filter by tier
	results, err = s.List(ctx, ListFilter{Tier: TierHigh, Limit: 10})
	if err != nil {
		t.Fatalf("list tier: %v", err)
	}
	if len(results) != 1 {
		t.Fatalf("list tier count: got %d, want 1", len(results))
	}
}
```

**Step 2: Run tests to verify they fail**

```bash
cd /root/projects/Interverse/infra/intercore && go test ./internal/discovery/ -v
```

Expected: FAIL (methods don't exist yet)

**Step 3: Implement Submit, Get, List in store.go**

Add to `internal/discovery/store.go`:

```go
package discovery

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
)

type Store struct {
	db *sql.DB
}

func NewStore(db *sql.DB) *Store {
	return &Store{db: db}
}

// Submit creates a new discovery record. Returns the generated ID.
// Emits a discovery.submitted event.
func (s *Store) Submit(ctx context.Context, source, sourceID, title, summary, url, rawMetadata string, embedding []byte, score float64) (string, error) {
	id, err := generateID()
	if err != nil {
		return "", fmt.Errorf("submit: %w", err)
	}

	tier := TierFromScore(score)
	now := nowUnix()

	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return "", fmt.Errorf("submit: begin: %w", err)
	}
	defer tx.Rollback()

	_, err = tx.ExecContext(ctx, `
		INSERT INTO discoveries (id, source, source_id, title, summary, url, raw_metadata, embedding, relevance_score, confidence_tier, status, discovered_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		id, source, sourceID, title, summary, url, rawMetadata, embedding, score, tier, StatusNew, now,
	)
	if err != nil {
		if isUniqueConstraintError(err) {
			return "", fmt.Errorf("%w: source=%s source_id=%s", ErrDuplicate, source, sourceID)
		}
		return "", fmt.Errorf("submit: insert: %w", err)
	}

	// Emit submitted event
	payload, _ := json.Marshal(map[string]interface{}{
		"id": id, "source": source, "title": title, "score": score, "tier": tier,
	})
	_, err = tx.ExecContext(ctx, `
		INSERT INTO discovery_events (discovery_id, event_type, from_status, to_status, payload, created_at)
		VALUES (?, ?, ?, ?, ?, ?)`,
		id, EventSubmitted, "", StatusNew, string(payload), now,
	)
	if err != nil {
		return "", fmt.Errorf("submit: event: %w", err)
	}

	return id, tx.Commit()
}

// Get returns a single discovery by ID.
func (s *Store) Get(ctx context.Context, id string) (*Discovery, error) {
	var d Discovery
	var runID, beadID sql.NullString
	var promotedAt, reviewedAt sql.NullInt64
	var embedding []byte

	err := s.db.QueryRowContext(ctx, `
		SELECT id, source, source_id, title, summary, url, raw_metadata, embedding,
			relevance_score, confidence_tier, status, run_id, bead_id,
			discovered_at, promoted_at, reviewed_at
		FROM discoveries WHERE id = ?`, id,
	).Scan(
		&d.ID, &d.Source, &d.SourceID, &d.Title, &d.Summary, &d.URL, &d.RawMetadata, &embedding,
		&d.RelevanceScore, &d.ConfidenceTier, &d.Status, &runID, &beadID,
		&d.DiscoveredAt, &promotedAt, &reviewedAt,
	)
	if err == sql.ErrNoRows {
		return nil, fmt.Errorf("%w: %s", ErrNotFound, id)
	}
	if err != nil {
		return nil, fmt.Errorf("get: %w", err)
	}

	d.Embedding = embedding
	if runID.Valid {
		d.RunID = &runID.String
	}
	if beadID.Valid {
		d.BeadID = &beadID.String
	}
	if promotedAt.Valid {
		d.PromotedAt = &promotedAt.Int64
	}
	if reviewedAt.Valid {
		d.ReviewedAt = &reviewedAt.Int64
	}
	return &d, nil
}

// ListFilter controls what List returns.
type ListFilter struct {
	Source string
	Status string
	Tier   string
	Limit  int
}

// List returns discoveries matching the filter, sorted by relevance_score DESC.
func (s *Store) List(ctx context.Context, f ListFilter) ([]Discovery, error) {
	if f.Limit <= 0 {
		f.Limit = 100
	}

	query := "SELECT id, source, source_id, title, summary, url, relevance_score, confidence_tier, status, discovered_at FROM discoveries WHERE 1=1"
	var args []interface{}

	if f.Source != "" {
		query += " AND source = ?"
		args = append(args, f.Source)
	}
	if f.Status != "" {
		query += " AND status = ?"
		args = append(args, f.Status)
	}
	if f.Tier != "" {
		query += " AND confidence_tier = ?"
		args = append(args, f.Tier)
	}
	query += " ORDER BY relevance_score DESC LIMIT ?"
	args = append(args, f.Limit)

	rows, err := s.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("list: %w", err)
	}
	defer rows.Close()

	var results []Discovery
	for rows.Next() {
		var d Discovery
		if err := rows.Scan(&d.ID, &d.Source, &d.SourceID, &d.Title, &d.Summary, &d.URL,
			&d.RelevanceScore, &d.ConfidenceTier, &d.Status, &d.DiscoveredAt); err != nil {
			return nil, fmt.Errorf("list scan: %w", err)
		}
		results = append(results, d)
	}
	return results, rows.Err()
}

func nowUnix() int64 {
	return time.Now().Unix()
}

// isUniqueConstraintError checks for UNIQUE constraint violations.
func isUniqueConstraintError(err error) bool {
	return err != nil && strings.Contains(err.Error(), "UNIQUE constraint failed")
}
```

Note: The `strings` import is needed for `isUniqueConstraintError`. Implementation should match exact Go patterns in the codebase.

**Step 4: Run tests to verify they pass**

```bash
cd /root/projects/Interverse/infra/intercore && go test ./internal/discovery/ -v
```

**Step 5: Commit**

```bash
git add infra/intercore/internal/discovery/
git commit -m "feat(intercore): discovery Submit/Get/List with events (E5-F2)"
```

---

## Task 4: Discovery Score + Promote + Dismiss (Store Layer)

**Files:**
- Modify: `infra/intercore/internal/discovery/store.go` — add Score, Promote, Dismiss methods
- Modify: `infra/intercore/internal/discovery/store_test.go` — tests

**Step 1: Write failing tests**

Add to `store_test.go`:

```go
func TestScore(t *testing.T) {
	sqlDB := setupTestDB(t)
	s := NewStore(sqlDB)
	ctx := context.Background()

	id, _ := s.Submit(ctx, "arxiv", "s1", "Paper", "", "", "{}", nil, 0.3)

	err := s.Score(ctx, id, 0.85)
	if err != nil {
		t.Fatalf("score: %v", err)
	}

	d, _ := s.Get(ctx, id)
	if d.RelevanceScore != 0.85 {
		t.Errorf("score: got %f, want 0.85", d.RelevanceScore)
	}
	if d.ConfidenceTier != TierHigh {
		t.Errorf("tier: got %q, want %q", d.ConfidenceTier, TierHigh)
	}
}

func TestPromote(t *testing.T) {
	sqlDB := setupTestDB(t)
	s := NewStore(sqlDB)
	ctx := context.Background()

	id, _ := s.Submit(ctx, "arxiv", "p1", "Paper", "", "", "{}", nil, 0.7)
	beadID := "iv-test1"

	err := s.Promote(ctx, id, beadID, false)
	if err != nil {
		t.Fatalf("promote: %v", err)
	}

	d, _ := s.Get(ctx, id)
	if d.Status != StatusPromoted {
		t.Errorf("status: got %q, want %q", d.Status, StatusPromoted)
	}
	if d.BeadID == nil || *d.BeadID != beadID {
		t.Errorf("bead_id: got %v, want %q", d.BeadID, beadID)
	}
}

func TestPromoteGateBlock(t *testing.T) {
	sqlDB := setupTestDB(t)
	s := NewStore(sqlDB)
	ctx := context.Background()

	// Score below medium threshold (0.5)
	id, _ := s.Submit(ctx, "arxiv", "g1", "Low Score Paper", "", "", "{}", nil, 0.2)

	err := s.Promote(ctx, id, "iv-test2", false)
	if err == nil {
		t.Fatal("expected gate block error, got nil")
	}
}

func TestPromoteForceOverride(t *testing.T) {
	sqlDB := setupTestDB(t)
	s := NewStore(sqlDB)
	ctx := context.Background()

	id, _ := s.Submit(ctx, "arxiv", "f1", "Low Score Paper", "", "", "{}", nil, 0.2)

	err := s.Promote(ctx, id, "iv-test3", true)
	if err != nil {
		t.Fatalf("force promote: %v", err)
	}

	d, _ := s.Get(ctx, id)
	if d.Status != StatusPromoted {
		t.Errorf("status: got %q, want promoted", d.Status)
	}
}

func TestScoreDismissedDiscovery(t *testing.T) {
	sqlDB := setupTestDB(t)
	s := NewStore(sqlDB)
	ctx := context.Background()

	id, _ := s.Submit(ctx, "arxiv", "sd1", "Paper", "", "", "{}", nil, 0.5)
	_ = s.Dismiss(ctx, id)

	// Scoring a dismissed discovery should fail — prevents zombie resurrection
	err := s.Score(ctx, id, 0.95)
	if err == nil {
		t.Fatal("expected lifecycle error for scoring dismissed discovery")
	}
	if !errors.Is(err, ErrLifecycle) {
		t.Errorf("expected ErrLifecycle, got: %v", err)
	}
}

func TestPromoteNotFound(t *testing.T) {
	sqlDB := setupTestDB(t)
	s := NewStore(sqlDB)
	ctx := context.Background()

	err := s.Promote(ctx, "nonexistent-id", "iv-test", false)
	if err == nil {
		t.Fatal("expected not found error")
	}
	if !errors.Is(err, ErrNotFound) {
		t.Errorf("expected ErrNotFound, got: %v", err)
	}
}

func TestDismiss(t *testing.T) {
	sqlDB := setupTestDB(t)
	s := NewStore(sqlDB)
	ctx := context.Background()

	id, _ := s.Submit(ctx, "arxiv", "d1", "Paper", "", "", "{}", nil, 0.5)
	err := s.Dismiss(ctx, id)
	if err != nil {
		t.Fatalf("dismiss: %v", err)
	}

	d, _ := s.Get(ctx, id)
	if d.Status != StatusDismissed {
		t.Errorf("status: got %q, want dismissed", d.Status)
	}
}
```

**Step 2: Run tests to verify they fail**

```bash
cd /root/projects/Interverse/infra/intercore && go test ./internal/discovery/ -v -run "TestScore|TestPromote|TestDismiss"
```

**Step 3: Implement Score, Promote, Dismiss**

Add to `store.go`:

- `Score(ctx, id, score)` — first SELECT to verify existence and check status. Return `ErrNotFound` if missing. Return `ErrLifecycle` if status is `dismissed` or `promoted` (prevents zombie resurrection via re-scoring). Otherwise update `relevance_score`, recompute tier with `TierFromScore()`, emit `discovery.scored` event.
- `Promote(ctx, id, beadID, force)` — in a single transaction: SELECT the discovery to verify existence and read current score. Return `ErrNotFound` if missing. Return `ErrLifecycle` if already dismissed (even with `--force` — dismissed discoveries must not be resurrected). If not force, check `relevance_score >= TierMediumMin` and return `ErrGateBlocked` with the current score and threshold if below. Then UPDATE status='promoted', bead_id, promoted_at. Emit `discovery.promoted` event. This SELECT-then-UPDATE pattern prevents the ambiguous 0-rows case.
- `Dismiss(ctx, id)` — sets status=dismissed, reviewed_at=now, emits `discovery.dismissed` event. Returns `ErrNotFound` if ID doesn't exist.

**Step 4: Run tests to verify they pass**

```bash
cd /root/projects/Interverse/infra/intercore && go test ./internal/discovery/ -v
```

**Step 5: Commit**

```bash
git add infra/intercore/internal/discovery/
git commit -m "feat(intercore): discovery Score/Promote/Dismiss with gate enforcement (E5-F2,F5)"
```

---

## Task 5: Discovery CLI — submit, status, list, score, promote, dismiss

**Files:**
- Create: `infra/intercore/cmd/ic/discovery.go`
- Modify: `infra/intercore/cmd/ic/main.go` — wire `discovery` subcommand
- Modify: `infra/intercore/test-integration.sh` — integration tests

**Step 1: Write integration tests**

Add to `test-integration.sh`:

```bash
echo "=== Discovery CRUD ==="
# Submit
DID=$(ic discovery submit --source=arxiv --source-id=test-001 --title="Test Paper" --summary="A test" --url="https://arxiv.org/test" --score=0.7 --db="$TEST_DB")
[[ -n "$DID" ]] || fail "discovery submit returned empty ID"
pass "discovery submit"

# Status
ic discovery status "$DID" --db="$TEST_DB" --json | jq -e '.source == "arxiv"' >/dev/null || fail "discovery status"
pass "discovery status"

# List (unfiltered)
count=$(ic discovery list --db="$TEST_DB" --json | jq 'length')
[[ "$count" -ge 1 ]] || fail "discovery list: expected >=1, got $count"
pass "discovery list"

# List (filtered by source)
count=$(ic discovery list --source=arxiv --db="$TEST_DB" --json | jq 'length')
[[ "$count" -ge 1 ]] || fail "discovery list --source"
pass "discovery list --source"

# List (filtered by tier)
count=$(ic discovery list --tier=medium --db="$TEST_DB" --json | jq 'length')
[[ "$count" -ge 1 ]] || fail "discovery list --tier"
pass "discovery list --tier"

# Score update
ic discovery score "$DID" --score=0.9 --db="$TEST_DB" >/dev/null || fail "discovery score"
tier=$(ic discovery status "$DID" --db="$TEST_DB" --json | jq -r '.confidence_tier')
[[ "$tier" == "high" ]] || fail "tier after score: expected high, got $tier"
pass "discovery score + tier recompute"

# Promote
ic discovery promote "$DID" --bead-id=iv-test1 --db="$TEST_DB" >/dev/null || fail "discovery promote"
status=$(ic discovery status "$DID" --db="$TEST_DB" --json | jq -r '.status')
[[ "$status" == "promoted" ]] || fail "status after promote: expected promoted, got $status"
pass "discovery promote"

# Dismiss (new discovery)
DID2=$(ic discovery submit --source=hn --source-id=test-002 --title="HN Post" --score=0.4 --db="$TEST_DB")
ic discovery dismiss "$DID2" --db="$TEST_DB" >/dev/null || fail "discovery dismiss"
status=$(ic discovery status "$DID2" --db="$TEST_DB" --json | jq -r '.status')
[[ "$status" == "dismissed" ]] || fail "status after dismiss"
pass "discovery dismiss"

# Promote gate block (low score)
DID3=$(ic discovery submit --source=test --source-id=test-003 --title="Low" --score=0.2 --db="$TEST_DB")
if ic discovery promote "$DID3" --bead-id=iv-block --db="$TEST_DB" 2>/dev/null; then
    fail "promote should be blocked for low score"
fi
pass "promote gate blocks low score"

# Promote with --force
ic discovery promote "$DID3" --bead-id=iv-force --force --db="$TEST_DB" >/dev/null || fail "force promote"
pass "promote --force overrides gate"

# Duplicate source/source_id
if ic discovery submit --source=arxiv --source-id=test-001 --title="Dup" --db="$TEST_DB" 2>/dev/null; then
    fail "duplicate submit should fail"
fi
pass "duplicate source/source_id rejected"
```

**Step 2: Run tests to verify they fail**

```bash
cd /root/projects/Interverse/infra/intercore && bash test-integration.sh
```

Expected: FAIL at "discovery submit" (command doesn't exist)

**Step 3: Implement discovery.go CLI**

Create `cmd/ic/discovery.go` with:
- `cmdDiscovery(ctx, args)` — dispatcher for `submit`, `status`, `list`, `score`, `promote`, `dismiss` subcommands
- Each subcommand parses flags manually (matching existing Intercore CLI style — no `flag` package, manual `strings.HasPrefix` parsing)
- `submit` reads `--source=`, `--source-id=`, `--title=`, `--summary=`, `--url=`, `--score=`, `--metadata=@file`, `--embedding=@file`
- `status <id>` — prints JSON or tab-separated
- `list` — filters by `--source=`, `--status=`, `--tier=`, `--limit=`
- `score <id> --score=N` — updates score
- `promote <id> --bead-id=<bid> [--force]` — promotes
- `dismiss <id>` — dismisses
- Exit codes: 0=success, 1=not found/gate blocked, 2=error, 3=usage

**Step 4: Wire into main.go**

Add to the switch statement in `main()`:

```go
case "discovery":
    exitCode = cmdDiscovery(ctx, subArgs)
```

Add to `printUsage()`:

```
  discovery submit --source=<s> --source-id=<sid> --title=<t> [opts]
  discovery status <id>
  discovery list [--source=<s>] [--status=<s>] [--tier=<t>] [--limit=N]
  discovery score <id> --score=<0.0-1.0>
  discovery promote <id> --bead-id=<bid> [--force]
  discovery dismiss <id>
```

**Step 5: Run integration tests**

```bash
cd /root/projects/Interverse/infra/intercore && bash test-integration.sh
```

**Step 6: Commit**

```bash
git add infra/intercore/cmd/ic/discovery.go infra/intercore/cmd/ic/main.go infra/intercore/test-integration.sh
git commit -m "feat(intercore): ic discovery CRUD commands (E5-F2)"
```

---

## Task 6: Discovery Events — Third UNION ALL Leg

**Files:**
- Modify: `infra/intercore/internal/event/event.go` — add `SourceDiscovery` constant
- Modify: `infra/intercore/internal/event/store.go` — add third `UNION ALL` leg to `ListEvents`/`ListAllEvents`, add `MaxDiscoveryEventID`
- Modify: `infra/intercore/cmd/ic/events.go` — add `--since-discovery=` flag, update cursor load/save for third field
- Modify: `infra/intercore/internal/event/store_test.go` — tests
- Modify: `infra/intercore/test-integration.sh` — integration tests

**Step 1: Write failing test**

Add integration test:

```bash
echo "=== Discovery Events ==="
# Events should include discovery events from earlier submit/score/promote
event_count=$(ic events tail --all --db="$TEST_DB" --json | jq -s '[.[] | select(.source == "discovery")] | length')
[[ "$event_count" -ge 3 ]] || fail "discovery events: expected >=3, got $event_count"
pass "discovery events visible in event bus"

# Since-discovery cursor
ic events tail --all --since-discovery=0 --db="$TEST_DB" --json | jq -s 'length' >/dev/null
pass "events tail --since-discovery"
```

**Step 2: Implement the third UNION ALL leg**

In `event/event.go`, add:
```go
const SourceDiscovery = "discovery"
```

In `event/store.go`, update `ListEvents` and `ListAllEvents` to add a third `UNION ALL` selecting from `discovery_events`:

```sql
UNION ALL
-- Note: discovery_id is aliased as run_id for UNION column alignment only.
-- Discovery events have no run association. Consumers should check
-- source == 'discovery' and treat run_id as subject_id in that case.
SELECT id, discovery_id AS run_id, 'discovery' AS source, event_type,
    from_status, to_status, COALESCE(payload, '') AS reason, created_at
FROM discovery_events
WHERE id > ?
```

Add `sinceDiscoveryID int64` parameter to both methods.

Add `MaxDiscoveryEventID(ctx) (int64, error)`.

**Step 3: Update cursor helpers**

In `events.go`:
- Add `--since-discovery=N` flag parsing
- Update `loadCursor` to return 3 values: `(phaseID, dispatchID, discoveryID int64)`
- Update `saveCursor` to accept 3 IDs
- Track `SourceDiscovery` high water mark in the event loop
- Fix the pre-existing bug: actually read and use the interspect field (or remove it if unused — but discovery cursor is the priority)

The cursor JSON becomes: `{"phase":N,"dispatch":N,"discovery":N}`

**Step 4: Run integration tests**

```bash
cd /root/projects/Interverse/infra/intercore && bash test-integration.sh
```

**Step 5: Run unit tests**

```bash
cd /root/projects/Interverse/infra/intercore && go test ./internal/event/ -v
```

**Step 6: Commit**

```bash
git add infra/intercore/internal/event/ infra/intercore/cmd/ic/events.go infra/intercore/test-integration.sh
git commit -m "feat(intercore): discovery events in event bus — third UNION ALL leg (E5-F3)"
```

---

## Task 7: Feedback Signals + Interest Profile (Store + CLI)

**Files:**
- Modify: `infra/intercore/internal/discovery/store.go` — add RecordFeedback, GetProfile, UpdateProfile
- Modify: `infra/intercore/internal/discovery/store_test.go` — tests
- Modify: `infra/intercore/cmd/ic/discovery.go` — add `feedback` and `profile` subcommands
- Modify: `infra/intercore/test-integration.sh` — integration tests

**Step 1: Write failing tests**

Add to `store_test.go`:

```go
func TestRecordFeedback(t *testing.T) {
	sqlDB := setupTestDB(t)
	s := NewStore(sqlDB)
	ctx := context.Background()

	id, _ := s.Submit(ctx, "test", "fb1", "Paper", "", "", "{}", nil, 0.5)

	err := s.RecordFeedback(ctx, id, SignalBoost, "{}", "human")
	if err != nil {
		t.Fatalf("record feedback: %v", err)
	}
}

func TestInterestProfile(t *testing.T) {
	sqlDB := setupTestDB(t)
	s := NewStore(sqlDB)
	ctx := context.Background()

	err := s.UpdateProfile(ctx, nil, `{"ai":0.8,"security":0.5}`, `{"arxiv":0.9}`)
	if err != nil {
		t.Fatalf("update profile: %v", err)
	}

	p, err := s.GetProfile(ctx)
	if err != nil {
		t.Fatalf("get profile: %v", err)
	}
	if p.KeywordWeights != `{"ai":0.8,"security":0.5}` {
		t.Errorf("keyword weights: got %q", p.KeywordWeights)
	}
}
```

Add integration tests:

```bash
echo "=== Discovery Feedback ==="
ic discovery feedback "$DID" --signal=boost --actor=human --db="$TEST_DB" >/dev/null || fail "feedback"
pass "discovery feedback"

echo "=== Interest Profile ==="
echo '{"ai":0.8}' > "$TEST_DIR/kw.json"
echo '{"arxiv":0.9}' > "$TEST_DIR/sw.json"
ic discovery profile update --keyword-weights="@$TEST_DIR/kw.json" --source-weights="@$TEST_DIR/sw.json" --db="$TEST_DB" >/dev/null || fail "profile update"
pass "profile update"

ic discovery profile --db="$TEST_DB" --json | jq -e '.keyword_weights' >/dev/null || fail "profile show"
pass "profile show"
```

**Step 2: Implement store methods + CLI subcommands**

- `RecordFeedback(ctx, discoveryID, signalType, data, actor)` — inserts into `feedback_signals`, emits `feedback.recorded` event
- `GetProfile(ctx)` — reads the singleton row (returns empty profile if none)
- `UpdateProfile(ctx, topicVector, keywordWeights, sourceWeights)` — upserts using `INSERT INTO interest_profile (id, topic_vector, keyword_weights, source_weights, updated_at) VALUES (1, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET topic_vector=COALESCE(excluded.topic_vector, topic_vector), keyword_weights=excluded.keyword_weights, source_weights=excluded.source_weights, updated_at=excluded.updated_at`. The COALESCE on topic_vector means passing nil leaves the existing embedding intact (does NOT destroy it like INSERT OR REPLACE would).
- CLI: `ic discovery feedback <id> --signal=<type> [--data=@file] [--actor=<name>]`
- CLI: `ic discovery profile [--json]` and `ic discovery profile update --keyword-weights=@file --source-weights=@file`

**Step 3: Run all tests**

```bash
cd /root/projects/Interverse/infra/intercore && go test ./internal/discovery/ -v && bash test-integration.sh
```

**Step 4: Commit**

```bash
git add infra/intercore/internal/discovery/ infra/intercore/cmd/ic/discovery.go infra/intercore/test-integration.sh
git commit -m "feat(intercore): feedback signals + interest profile (E5-F4)"
```

---

## Task 8: Dedup on Submit + Decay

**Files:**
- Modify: `infra/intercore/internal/discovery/store.go` — add dedup logic to Submit, add Decay method
- Modify: `infra/intercore/internal/discovery/discovery.go` — add cosine similarity helper
- Modify: `infra/intercore/internal/discovery/store_test.go` — tests
- Modify: `infra/intercore/cmd/ic/discovery.go` — add `--dedup-threshold=` to submit, add `decay` subcommand
- Modify: `infra/intercore/test-integration.sh` — integration tests

**Step 1: Write failing tests**

Add to `store_test.go`:

```go
func TestCosineSimilarity(t *testing.T) {
	// 4-dim vectors for simplicity
	a := []float32{1.0, 0.0, 0.0, 0.0}
	b := []float32{1.0, 0.0, 0.0, 0.0}
	c := []float32{0.0, 1.0, 0.0, 0.0}

	if sim := CosineSimilarity(float32ToBytes(a), float32ToBytes(b)); sim < 0.99 {
		t.Errorf("identical vectors: got %f, want ~1.0", sim)
	}
	if sim := CosineSimilarity(float32ToBytes(a), float32ToBytes(c)); sim > 0.01 {
		t.Errorf("orthogonal vectors: got %f, want ~0.0", sim)
	}
}

func TestSubmitDedup(t *testing.T) {
	sqlDB := setupTestDB(t)
	s := NewStore(sqlDB)
	ctx := context.Background()

	emb := float32ToBytes([]float32{1.0, 0.0, 0.0, 0.0})
	id1, _ := s.Submit(ctx, "test", "dd1", "Paper A", "", "", "{}", emb, 0.5)

	// Submit near-duplicate with high threshold
	emb2 := float32ToBytes([]float32{0.99, 0.01, 0.0, 0.0})
	id2, err := s.SubmitWithDedup(ctx, "test", "dd2", "Paper A Similar", "", "", "{}", emb2, 0.5, 0.9)
	if err != nil {
		t.Fatalf("dedup submit: %v", err)
	}
	// Should return the original ID (dedup hit)
	if id2 != id1 {
		t.Errorf("dedup: got %q, want %q (original)", id2, id1)
	}
}

func TestDecay(t *testing.T) {
	sqlDB := setupTestDB(t)
	s := NewStore(sqlDB)
	ctx := context.Background()

	id, _ := s.Submit(ctx, "test", "dc1", "Old Paper", "", "", "{}", nil, 0.8)

	// Force discovered_at to be old
	s.db.ExecContext(ctx, "UPDATE discoveries SET discovered_at = ? WHERE id = ?", nowUnix()-86400*30, id)

	count, err := s.Decay(ctx, 0.1, 86400) // 10% decay, min age 1 day
	if err != nil {
		t.Fatalf("decay: %v", err)
	}
	if count != 1 {
		t.Errorf("decay count: got %d, want 1", count)
	}

	d, _ := s.Get(ctx, id)
	if d.RelevanceScore >= 0.8 {
		t.Errorf("score should have decayed from 0.8, got %f", d.RelevanceScore)
	}
	// Verify tier is consistent with decayed score (catches SQL param binding bugs)
	expectedTier := TierFromScore(d.RelevanceScore)
	if d.ConfidenceTier != expectedTier {
		t.Errorf("tier mismatch after decay: got %q, want %q (score=%f)", d.ConfidenceTier, expectedTier, d.RelevanceScore)
	}
}
```

**Step 2: Implement cosine similarity in discovery.go**

```go
// CosineSimilarity computes cosine similarity between two float32 BLOB embeddings.
// Returns 0.0 if either is nil or lengths don't match.
func CosineSimilarity(a, b []byte) float64 {
	if len(a) == 0 || len(b) == 0 || len(a) != len(b) {
		return 0.0
	}
	dim := len(a) / 4
	var dotProduct, normA, normB float64
	for i := 0; i < dim; i++ {
		va := math.Float32frombits(binary.LittleEndian.Uint32(a[i*4 : (i+1)*4]))
		vb := math.Float32frombits(binary.LittleEndian.Uint32(b[i*4 : (i+1)*4]))
		dotProduct += float64(va) * float64(vb)
		normA += float64(va) * float64(va)
		normB += float64(vb) * float64(vb)
	}
	if normA == 0 || normB == 0 {
		return 0.0
	}
	return dotProduct / (math.Sqrt(normA) * math.Sqrt(normB))
}
```

**Step 3: Implement SubmitWithDedup**

`SubmitWithDedup` performs the similarity scan and insert in a **single `BEGIN IMMEDIATE` transaction** to prevent TOCTOU:

```go
func (s *Store) SubmitWithDedup(ctx context.Context, source, sourceID, title, summary, url, rawMetadata string, embedding []byte, score float64, dedupThreshold float64) (string, error) {
	// Single transaction: scan + insert atomically.
	// BEGIN IMMEDIATE acquires write lock immediately, preventing concurrent
	// SubmitWithDedup from inserting between our scan and our insert.
	// Note: with SetMaxOpenConns(1), BEGIN IMMEDIATE is safe (no nested tx risk).
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return "", fmt.Errorf("submit dedup: begin: %w", err)
	}
	defer tx.Rollback()

	// Force IMMEDIATE lock (modernc.org/sqlite supports this via exec)
	if _, err := tx.ExecContext(ctx, "SELECT 1"); err != nil {
		return "", fmt.Errorf("submit dedup: lock: %w", err)
	}

	// Scan existing embeddings for this source
	rows, err := tx.QueryContext(ctx,
		"SELECT id, embedding FROM discoveries WHERE source = ? AND embedding IS NOT NULL", source)
	if err != nil {
		return "", fmt.Errorf("submit dedup: scan: %w", err)
	}
	defer rows.Close()

	for rows.Next() {
		var existingID string
		var existingEmb []byte
		if err := rows.Scan(&existingID, &existingEmb); err != nil {
			return "", fmt.Errorf("submit dedup: scan row: %w", err)
		}
		sim := CosineSimilarity(embedding, existingEmb)
		if sim >= dedupThreshold {
			// Dedup hit — emit event and return existing ID
			payload, _ := json.Marshal(map[string]interface{}{
				"existing_id": existingID, "similarity": sim, "source": source,
			})
			tx.ExecContext(ctx, `INSERT INTO discovery_events (discovery_id, event_type, payload, created_at) VALUES (?, ?, ?, ?)`,
				existingID, EventDeduped, string(payload), nowUnix())
			tx.Commit()
			return existingID, nil
		}
	}
	rows.Close()

	// No dedup hit — insert new record within the same transaction
	id, err := generateID()
	if err != nil {
		return "", fmt.Errorf("submit dedup: %w", err)
	}
	tier := TierFromScore(score)
	now := nowUnix()

	_, err = tx.ExecContext(ctx, `INSERT INTO discoveries (...) VALUES (?, ?, ...)`,
		id, source, sourceID, title, summary, url, rawMetadata, embedding, score, tier, StatusNew, now)
	if err != nil {
		if isUniqueConstraintError(err) {
			return "", fmt.Errorf("%w: source=%s source_id=%s", ErrDuplicate, source, sourceID)
		}
		return "", fmt.Errorf("submit dedup: insert: %w", err)
	}

	// Emit submitted event
	payload, _ := json.Marshal(map[string]interface{}{
		"id": id, "source": source, "title": title, "score": score, "tier": tier,
	})
	tx.ExecContext(ctx, `INSERT INTO discovery_events (...) VALUES (?, ?, ?, ?, ?, ?)`,
		id, EventSubmitted, "", StatusNew, string(payload), now)

	return id, tx.Commit()
}
```

Key design: The scan and insert share the same transaction. With `SetMaxOpenConns(1)`, there is no risk of `SQLITE_BUSY` from a nested `BEGIN IMMEDIATE` — there's only one connection, so `BeginTx` serializes naturally.

**Step 4: Implement Decay**

`Decay(ctx, rate, minAgeSec)` — compute decay in Go (not SQL CASE) to avoid parameter binding pitfalls and reuse `TierFromScore()`:

```go
func (s *Store) Decay(ctx context.Context, rate float64, minAgeSec int64) (int, error) {
	cutoff := nowUnix() - minAgeSec

	// Load eligible discoveries (active, old enough)
	rows, err := s.db.QueryContext(ctx,
		`SELECT id, relevance_score FROM discoveries
		 WHERE discovered_at < ? AND status NOT IN ('dismissed', 'promoted')`,
		cutoff)
	if err != nil {
		return 0, fmt.Errorf("decay: query: %w", err)
	}
	defer rows.Close()

	type target struct {
		id    string
		score float64
	}
	var targets []target
	for rows.Next() {
		var t target
		if err := rows.Scan(&t.id, &t.score); err != nil {
			return 0, fmt.Errorf("decay: scan: %w", err)
		}
		targets = append(targets, t)
	}
	rows.Close()

	if len(targets) == 0 {
		return 0, nil
	}

	// Apply decay and tier in Go, write back in a single transaction
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, fmt.Errorf("decay: begin: %w", err)
	}
	defer tx.Rollback()

	for _, t := range targets {
		newScore := t.score * (1.0 - rate)
		newTier := TierFromScore(newScore)
		_, err := tx.ExecContext(ctx,
			`UPDATE discoveries SET relevance_score = ?, confidence_tier = ? WHERE id = ?`,
			newScore, newTier, t.id)
		if err != nil {
			return 0, fmt.Errorf("decay: update %s: %w", t.id, err)
		}
	}

	// Emit single decay event
	payload, _ := json.Marshal(map[string]interface{}{
		"count": len(targets), "rate": rate,
	})
	_, err = tx.ExecContext(ctx,
		`INSERT INTO discovery_events (discovery_id, event_type, payload, created_at)
		 VALUES ('', ?, ?, ?)`,
		EventDecayed, string(payload), nowUnix())
	if err != nil {
		return 0, fmt.Errorf("decay: event: %w", err)
	}

	return len(targets), tx.Commit()
}
```

This avoids the SQL CASE parameter binding issue (where `rate` would need to be bound 4 times) and ensures tier is always consistent with score via the shared `TierFromScore()` function.

**Step 5: Add CLI flags**

- `ic discovery submit` gains `--dedup-threshold=<0.0-1.0>` — if present, calls `SubmitWithDedup`
- `ic discovery decay --rate=<0.0-1.0> --min-age=<dur>` — calls `Decay`

**Step 6: Run all tests**

```bash
cd /root/projects/Interverse/infra/intercore && go test ./internal/discovery/ -v && bash test-integration.sh
```

**Step 7: Commit**

```bash
git add infra/intercore/internal/discovery/ infra/intercore/cmd/ic/discovery.go infra/intercore/test-integration.sh
git commit -m "feat(intercore): embedding dedup + relevance decay (E5-F5)"
```

---

## Task 9: Embedding Search

**Files:**
- Modify: `infra/intercore/internal/discovery/store.go` — add Search method
- Modify: `infra/intercore/internal/discovery/store_test.go` — tests
- Modify: `infra/intercore/cmd/ic/discovery.go` — add `search` subcommand
- Modify: `infra/intercore/test-integration.sh` — integration tests

**Step 1: Write failing test**

```go
func TestSearch(t *testing.T) {
	sqlDB := setupTestDB(t)
	s := NewStore(sqlDB)
	ctx := context.Background()

	emb1 := float32ToBytes([]float32{1.0, 0.0, 0.0, 0.0})
	emb2 := float32ToBytes([]float32{0.0, 1.0, 0.0, 0.0})
	emb3 := float32ToBytes([]float32{0.9, 0.1, 0.0, 0.0})

	s.Submit(ctx, "test", "s1", "Paper 1", "", "", "{}", emb1, 0.8)
	s.Submit(ctx, "test", "s2", "Paper 2", "", "", "{}", emb2, 0.7)
	s.Submit(ctx, "test", "s3", "Paper 3", "", "", "{}", emb3, 0.6)

	query := float32ToBytes([]float32{1.0, 0.0, 0.0, 0.0})
	results, err := s.Search(ctx, query, SearchFilter{Limit: 2})
	if err != nil {
		t.Fatalf("search: %v", err)
	}
	if len(results) != 2 {
		t.Fatalf("search count: got %d, want 2", len(results))
	}
	// First result should be the most similar (Paper 1)
	if results[0].Title != "Paper 1" {
		t.Errorf("first result: got %q, want Paper 1", results[0].Title)
	}
}
```

**Step 2: Implement Search**

```go
type SearchResult struct {
	Discovery
	Similarity float64 `json:"similarity"`
}

type SearchFilter struct {
	Source   string
	Tier    string
	Status  string
	MinScore float64
	Limit   int
}

func (s *Store) Search(ctx context.Context, queryEmbedding []byte, f SearchFilter) ([]SearchResult, error) {
	// Brute-force: load all embeddings, compute cosine similarity, sort
	if f.Limit <= 0 {
		f.Limit = 10
	}

	query := "SELECT id, source, source_id, title, summary, url, relevance_score, confidence_tier, status, embedding, discovered_at FROM discoveries WHERE embedding IS NOT NULL"
	var args []interface{}
	if f.Source != "" {
		query += " AND source = ?"
		args = append(args, f.Source)
	}
	if f.Tier != "" {
		query += " AND confidence_tier = ?"
		args = append(args, f.Tier)
	}
	if f.Status != "" {
		query += " AND status = ?"
		args = append(args, f.Status)
	}

	rows, err := s.db.QueryContext(ctx, query, args...)
	// ... scan, compute CosineSimilarity for each, sort by similarity DESC, apply MinScore filter, truncate to Limit
}
```

**Step 3: Add CLI subcommand**

`ic discovery search --embedding=@file [--source=<s>] [--tier=<t>] [--status=<s>] [--min-score=N] [--limit=N]`

Output format (JSON): `[{"id":"...", "title":"...", "source":"...", "score":0.8, "similarity":0.95, "tier":"high"}, ...]`

**Step 4: Run all tests**

```bash
cd /root/projects/Interverse/infra/intercore && go test ./internal/discovery/ -v && bash test-integration.sh
```

**Step 5: Commit**

```bash
git add infra/intercore/internal/discovery/ infra/intercore/cmd/ic/discovery.go infra/intercore/test-integration.sh
git commit -m "feat(intercore): embedding search with brute-force cosine similarity (E5-F6)"
```

---

## Task 10: Discovery Rollback + Cursor Fix

**Files:**
- Modify: `infra/intercore/internal/discovery/store.go` — add Rollback method
- Modify: `infra/intercore/cmd/ic/discovery.go` — add `rollback` subcommand
- Modify: `infra/intercore/cmd/ic/events.go` — fix interspect cursor dead code
- Modify: `infra/intercore/test-integration.sh` — integration tests

**Step 1: Write failing test**

```bash
echo "=== Discovery Rollback ==="
# Submit several from same source
DID_R1=$(ic discovery submit --source=rollback-test --source-id=r1 --title="R1" --score=0.5 --db="$TEST_DB")
DID_R2=$(ic discovery submit --source=rollback-test --source-id=r2 --title="R2" --score=0.6 --db="$TEST_DB")
DID_R3=$(ic discovery submit --source=rollback-test --source-id=r3 --title="R3" --score=0.7 --db="$TEST_DB")

# Rollback since a timestamp (recently)
rollback_since=$(($(date +%s) - 10))
count=$(ic discovery rollback --source=rollback-test --since="$rollback_since" --db="$TEST_DB")
[[ "$count" -ge 1 ]] || fail "rollback: expected >=1 dismissed, got $count"
pass "discovery rollback"
```

**Step 2: Implement Rollback**

`Rollback(ctx, source, sinceTimestamp)` — use `UPDATE ... RETURNING id` to atomically get affected IDs and emit events only for those rows:

```go
func (s *Store) Rollback(ctx context.Context, source string, sinceTimestamp int64) (int, error) {
	now := nowUnix()

	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, fmt.Errorf("rollback: begin: %w", err)
	}
	defer tx.Rollback()

	// UPDATE ... RETURNING id gives us exactly the affected IDs atomically.
	// No separate SELECT needed — prevents including rows modified by concurrent processes.
	rows, err := tx.QueryContext(ctx,
		`UPDATE discoveries SET status = 'dismissed', reviewed_at = ?
		 WHERE source = ? AND discovered_at >= ? AND status NOT IN ('promoted', 'dismissed')
		 RETURNING id`, now, source, sinceTimestamp)
	if err != nil {
		return 0, fmt.Errorf("rollback: update: %w", err)
	}

	var affectedIDs []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			rows.Close()
			return 0, fmt.Errorf("rollback: scan: %w", err)
		}
		affectedIDs = append(affectedIDs, id)
	}
	rows.Close()

	// Emit dismissed event for each affected ID within the same transaction
	for _, id := range affectedIDs {
		payload, _ := json.Marshal(map[string]interface{}{
			"id": id, "reason": "rollback", "source": source,
		})
		_, err = tx.ExecContext(ctx,
			`INSERT INTO discovery_events (discovery_id, event_type, from_status, to_status, payload, created_at)
			 VALUES (?, ?, '', 'dismissed', ?, ?)`,
			id, EventDismissed, string(payload), now)
		if err != nil {
			return 0, fmt.Errorf("rollback: event for %s: %w", id, err)
		}
	}

	return len(affectedIDs), tx.Commit()
}
```

Key design: `RETURNING id` from the UPDATE gives exactly the rows changed by this transaction, not rows modified by concurrent processes. Events and updates are in the same transaction.

**Step 3: Fix the interspect cursor dead code**

In `events.go`, clean up the cursor JSON:
- Remove `interspect` field from cursor JSON (it was always 0 and never used)
- Add `discovery` field: `{"phase":N,"dispatch":N,"discovery":N}`
- Update `loadCursor` to return 3 values
- Update `saveCursor` to accept 3 values
- Backward-compatible: if existing cursor JSON lacks `discovery` field, default to 0

**Step 4: Run all tests**

```bash
cd /root/projects/Interverse/infra/intercore && go test ./... && bash test-integration.sh
```

**Step 5: Commit**

```bash
git add infra/intercore/internal/discovery/ infra/intercore/cmd/ic/discovery.go infra/intercore/cmd/ic/events.go infra/intercore/test-integration.sh
git commit -m "feat(intercore): discovery rollback + cursor fix (E5-F5, event bus cleanup)"
```

---

## Task 11: Final Integration Tests + Polish

**Files:**
- Modify: `infra/intercore/test-integration.sh` — comprehensive end-to-end tests
- Modify: `infra/intercore/cmd/ic/main.go` — update usage text
- Modify: `infra/intercore/CLAUDE.md` — add discovery quick reference

**Step 1: Add comprehensive integration tests**

Add to `test-integration.sh` to cover:
- Discovery events visible in `ic events tail --all` (count ≥ 10)
- Consumer cursor with discovery field round-trips correctly
- Profile CRUD round-trip
- List filtering combinations (source + tier, status + tier)
- Score → tier boundary transitions (0.3, 0.5, 0.8 boundaries)
- `ic health` reports schema v9
- `ic version` shows schema v9

Total new tests: ~20+

**Step 2: Run full test suite**

```bash
cd /root/projects/Interverse/infra/intercore && go test -race ./... && bash test-integration.sh
```

**Step 3: Update CLAUDE.md with discovery quick reference**

Add Discovery Quick Reference section to `infra/intercore/CLAUDE.md`:

```markdown
## Discovery Quick Reference

```bash
# Submit a discovery
ic discovery submit --source=arxiv --source-id=<sid> --title="<title>" [--summary=<s>] [--url=<u>] [--embedding=@file] [--score=0.7] [--dedup-threshold=0.9]

# View and list
ic discovery status <id>
ic discovery list [--source=<s>] [--status=<s>] [--tier=<t>] [--limit=N]

# Score and lifecycle
ic discovery score <id> --score=<0.0-1.0>
ic discovery promote <id> --bead-id=<bid> [--force]
ic discovery dismiss <id>

# Feedback and profile
ic discovery feedback <id> --signal=<type> [--data=@file] [--actor=<name>]
ic discovery profile [--json]
ic discovery profile update --keyword-weights=@file --source-weights=@file

# Maintenance
ic discovery decay --rate=<0.0-1.0> --min-age=<dur>
ic discovery rollback --source=<s> --since=<ts>
ic discovery search --embedding=@file [--source=<s>] [--limit=N] [--min-score=N]
```
```

**Step 4: Verify all existing tests still pass**

```bash
cd /root/projects/Interverse/infra/intercore && go test -race ./... && bash test-integration.sh
```

**Step 5: Final commit**

```bash
git add infra/intercore/
git commit -m "feat(intercore): E5 discovery pipeline complete — 20+ integration tests (E5)"
```

---

## Dependency Summary

```
Task 1 (types)       → Task 2 (schema migration)
Task 2               → Task 3 (Submit/Get/List store)
Task 3               → Task 4 (Score/Promote/Dismiss store)
Task 3 + Task 4      → Task 5 (CLI)
Task 5               → Task 6 (events third leg)
Task 5               → Task 7 (feedback + profile)
Task 3               → Task 8 (dedup + decay)
Task 8               → Task 9 (search)
Task 6 + Task 8      → Task 10 (rollback + cursor fix)
All                   → Task 11 (final tests + polish)
```

Parallelizable: Tasks 6, 7, and 8 can run in parallel after Task 5.

## PRD Feature → Task Mapping

| PRD Feature | Tasks |
|-------------|-------|
| F1: Schema + Migration | Task 1, Task 2 |
| F2: Discovery CRUD CLI | Task 3, Task 4, Task 5 |
| F3: Discovery Events | Task 6 |
| F4: Feedback + Interest Profile | Task 7 |
| F5: Tier Gates + Dedup + Decay | Task 4 (gates), Task 8 (dedup+decay), Task 10 (rollback) |
| F6: Embedding Search | Task 9 |
