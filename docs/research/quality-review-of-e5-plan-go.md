# Quality Review: E5 Discovery Pipeline Implementation Plan

**Date:** 2026-02-20
**Plan:** `docs/plans/2026-02-20-intercore-e5-discovery-pipeline.md`
**Reviewer:** Flux-drive Quality & Style Reviewer
**Scope:** Go 1.22, `modernc.org/sqlite`, `internal/discovery` package, CLI wiring

---

## Summary

The plan is architecturally sound and consistent with the existing Intercore patterns in most
respects. The Store struct, constructor naming, and transaction model all follow what is already
in `phase`, `event`, and `sentinel`. However, there are five distinct areas where the plan
deviates from codebase conventions or introduces correctness risks that will need to be fixed
during implementation.

---

## Finding 1 — Constructor Naming Inconsistency (HIGH)

**Severity:** Medium — breaks naming consistency with adjacent packages.

### Observation

The plan uses `NewStore(db)` as the constructor for the discovery package. However, the canonical
pattern in this codebase is non-uniform and must be checked against direct neighbors:

- `phase.Store` constructor is `New(db)` (not `NewStore`)
- `event.Store` constructor is `NewStore(db)`
- `sentinel` constructor is `New(db)`

The plan specifies `NewStore` for discovery, which matches `event` but not `phase`. This is not
a bug, but it creates a split convention. The `event` package is the closer structural analog
(discovery is also an event-emitting store with `AUTOINCREMENT` ID tables), so `NewStore` is
defensible — but the implementer must be aware that `phase.New` exists and not accidentally mix
the two styles.

### Recommendation

Use `NewStore(db)` to match the `event` package (same structural role). Add a comment to
`discovery/store.go` noting this follows `event.NewStore`, not `phase.New`, so the deviation is
intentional. Do not silently create `New` here and cause a third variant.

---

## Finding 2 — `DiscoveryEvent.Timestamp` Dual Field is Redundant and Inconsistent (HIGH)

**Severity:** High — structural inconsistency with existing Event types and silent data duplication.

### Observation

The `DiscoveryEvent` struct in the plan (Task 1, `discovery.go`) declares:

```go
type DiscoveryEvent struct {
    // ...
    CreatedAt    int64     `json:"created_at"`
    Timestamp    time.Time `json:"timestamp"` // populated from CreatedAt
}
```

This stores the same moment twice: once as a Unix integer (`CreatedAt`) and once as a `time.Time`
(`Timestamp`). Compare with how the existing codebase handles this:

- `event.Event` uses only `Timestamp time.Time` (populated from `createdAt int64` during `Scan`)
- `event.InterspectEvent` uses only `Timestamp time.Time`
- `phase.PhaseEvent` uses only `CreatedAt int64` (no Timestamp field)

The plan's `DiscoveryEvent` type is an internal/store-layer struct (not a domain type surfaced
directly to CLI consumers). Carrying both fields creates a JSON output with two representations
of the same timestamp, which will confuse downstream consumers and differ from the `Event` struct
they already know.

### Recommendation

Remove the `Timestamp time.Time` field from `DiscoveryEvent`. Follow the `event.Event` pattern:
store `CreatedAt int64` in the struct and populate a synthesized `Timestamp` only in the scan
helper if the type is ever exposed to JSON consumers. If `DiscoveryEvent` is only used internally
(not serialized), keep `CreatedAt int64` only.

---

## Finding 3 — `Get` Uses String Formatting for Not-Found Instead of Sentinel Error (HIGH)

**Severity:** High — callers cannot distinguish "not found" from other errors programmatically.

### Observation

The plan's `Get` implementation returns:

```go
if err == sql.ErrNoRows {
    return nil, fmt.Errorf("discovery %q not found", id)
}
```

Compare with `phase.Store.Get`:

```go
if errors.Is(err, sql.ErrNoRows) {
    return nil, ErrNotFound
}
```

And `event.Store` methods, which similarly use sentinel errors from `phase.ErrNotFound`.

Returning a formatted string for not-found breaks the ability of callers (including CLI code and
integration tests) to do `if err == discovery.ErrNotFound` checks. The plan's CLI in Task 5
specifies exit code 1 for "not found/gate blocked" — this requires inspectable sentinel errors.
A string error makes that check fragile (substring matching or silent fall-through to exit 2).

Additionally, the comparison uses `==` rather than `errors.Is`. The codebase uses `errors.Is`
consistently (see `phase/store.go:112`).

### Recommendation

1. Create `internal/discovery/errors.go` with:

```go
package discovery

import "errors"

var (
    ErrNotFound    = errors.New("discovery not found")
    ErrGateBlocked = errors.New("promotion blocked: score below threshold")
    ErrDuplicate   = errors.New("discovery already exists for source/source_id")
)
```

2. In `Get`, use:

```go
if errors.Is(err, sql.ErrNoRows) {
    return nil, ErrNotFound
}
```

3. In `Promote`, use `ErrGateBlocked` when the score check fails.

4. In the CLI (Task 5), map `errors.Is(err, discovery.ErrNotFound)` to exit 1, and
   `errors.Is(err, discovery.ErrGateBlocked)` to exit 1, all other errors to exit 2.

---

## Finding 4 — `nowUnix()` Is Duplicated, Not Shared (MEDIUM)

**Severity:** Medium — violates DRY, risks drift in timestamp semantics.

### Observation

The plan defines `nowUnix()` in `discovery/store.go` (Task 3, end of code block):

```go
func nowUnix() int64 {
    return __import_time__.Now().Unix()
}
```

(The `__import_time__` placeholder aside, this is structurally a duplicate.) The exact same
function exists in `internal/phase/phase.go`:

```go
func nowUnix() int64 {
    return time.Now().Unix()
}
```

And `CLAUDE.md` for the project has an explicit note:

> TTL computation in Go (`time.Now().Unix()`) not SQL (`unixepoch()`) to avoid float promotion

The plan is correct to use Go-side time, but the function needs to live in `discovery/discovery.go`
alongside the domain types (not `store.go`), matching the pattern where `phase/phase.go` holds
`nowUnix()` and `strPtr()` helpers.

### Recommendation

Define `nowUnix()` once in `internal/discovery/discovery.go` and call it from `store.go`. Do not
define it in `store.go`. The plan currently puts it at the bottom of the store file, which
scatters helpers across files.

---

## Finding 5 — `idLen = 12` Diverges from Existing `idLen = 8` Without Justification (MEDIUM)

**Severity:** Medium — collision-space expansion without documentation.

### Observation

The plan sets `idLen = 12` in `discovery.go`:

```go
const (
    idLen   = 12
    idChars = "abcdefghijklmnopqrstuvwxyz0123456789"
)
```

The existing `phase/store.go` defines:

```go
const idChars = "abcdefghijklmnopqrstuvwxyz0123456789"
const idLen = 8
```

The `generateID()` implementations are otherwise identical. Using a different ID length without
explanation will cause readers to wonder whether this is intentional (larger ID space for
discoveries since many are expected?) or accidental. The inconsistency also means that in test
output, discovery IDs will have a different visual length than run IDs, which can be confusing
when reading logs.

The plan does not document the rationale. 12 chars gives ~2.2 trillion combinations versus ~2.8
trillion for 8 chars in base-36 — both are sufficient for this workload. Length is not a
correctness issue, but it is an undocumented deviation.

### Recommendation

Either use `idLen = 8` to match the existing convention, or add a comment:

```go
// idLen is 12 (vs 8 for runs) because discovery volume is expected to be
// significantly higher, providing additional collision headroom.
const idLen = 12
```

If the team has not established a rationale for 12, default to 8 to avoid the inconsistency.

---

## Finding 6 — `generateID` Is Copy-Pasted, Not Shared (MEDIUM)

**Severity:** Medium — three identical functions will diverge.

### Observation

`phase/store.go` has `generateID()`. The plan proposes adding an identical `generateID()` in
`discovery/discovery.go`. This is the second duplicate already in the codebase (the function is
also present in `sentinel` or similar). Each copy can drift independently.

### Recommendation

Extract a shared `internal/idgen` package (or `internal/ids`) with a single `Generate(length)
string` function and have both `phase` and `discovery` call it. If package creation is deferred,
at minimum annotate the copy with:

```go
// generateID is duplicated from internal/phase/store.go — extract to shared package when convenient.
```

This is not a blocker for shipping, but should be tracked.

---

## Finding 7 — `TestList` Discards Errors on `Submit` Calls (MEDIUM)

**Severity:** Medium — test setup failures are silent and will produce confusing failures downstream.

### Observation

In Task 3's `TestList`:

```go
s.Submit(ctx, "arxiv", "a1", "Paper A", "", "", "{}", nil, 0.9)
s.Submit(ctx, "hackernews", "h1", "HN Post", "", "", "{}", nil, 0.4)
s.Submit(ctx, "arxiv", "a2", "Paper B", "", "", "{}", nil, 0.6)
```

All three `Submit` return values are discarded (including the error). This is a deviation from
the codebase test style. In `event/store_test.go`, the convention is either to check errors
(`store.AddInterspectEvent` calls in filter tests do discard, but only for setup after a
verified-passing call). For the primary test data setup, unchecked errors can cause tests to
pass vacuously.

The same pattern appears in `TestCosineSimilarity` (Task 8) and `TestSearch` (Task 9).

### Recommendation

For setup calls that are not the subject under test but whose success is required, assign and
check:

```go
if _, err := s.Submit(ctx, "arxiv", "a1", "Paper A", "", "", "{}", nil, 0.9); err != nil {
    t.Fatalf("setup submit a1: %v", err)
}
```

Alternatively, extract a `mustSubmit(t, s, ctx, ...)` helper matching the `insertTestRun`
pattern in `event/store_test.go`.

---

## Finding 8 — `Decay` SQL Uses Rate Parameter Three Times (CORRECTNESS RISK)

**Severity:** High — the SQL as written in Task 8 has a subtle duplication that produces wrong
tier boundaries.

### Observation

The plan's `Decay` SQL:

```sql
confidence_tier = CASE
  WHEN relevance_score * (1.0 - ?) >= 0.8 THEN 'high'
  WHEN relevance_score * (1.0 - ?) >= 0.5 THEN 'medium'
  WHEN relevance_score * (1.0 - ?) >= 0.3 THEN 'low'
  ELSE 'discard'
END
```

This uses `?` three times for the rate, and the update also uses `?` once for the score update.
SQLite's positional parameters require the rate to be bound once per `?`. The SQL as written
requires the rate to appear four times in the args slice: once for the score update and three
times for the tier CASE — easy to get wrong when constructing the args.

A more idiomatic and correct approach: compute the new score first, then derive the tier.
In SQLite you can use a subexpression:

```sql
UPDATE discoveries
SET
    relevance_score = relevance_score * (1.0 - ?),
    confidence_tier = CASE
        WHEN relevance_score * (1.0 - ?) >= 0.8 THEN 'high'
        WHEN relevance_score * (1.0 - ?) >= 0.5 THEN 'medium'
        WHEN relevance_score * (1.0 - ?) >= 0.3 THEN 'low'
        ELSE 'discard'
    END
WHERE discovered_at < ? AND status NOT IN ('dismissed', 'promoted')
```

Or, safer: use a CTE or compute the decayed value as a named column with a window. The CLAUDE.md
note says `CTE wrapping UPDATE ... RETURNING is NOT supported` — but a standard CTE with SELECT
before UPDATE is fine. The safest approach is to load affected IDs into Go, compute new scores
and tiers there using `TierFromScore`, then UPDATE in a transaction.

### Recommendation

Implement `Decay` by loading matching rows in Go, computing `newScore = score * (1.0 - rate)` and
`newTier = TierFromScore(newScore)` for each, then issuing individual or batched `UPDATE` calls
within a transaction. This avoids the multi-bind issue and reuses `TierFromScore` from
`discovery.go` rather than duplicating the tier logic in SQL.

---

## Finding 9 — `SubmitWithDedup` Concurrency Model Needs Tightening (MEDIUM)

**Severity:** Medium — the plan specifies `BEGIN IMMEDIATE` for dedup, which is correct, but the
implementation note omits the key detail about how the existing `Submit` already uses
`BeginTx(ctx, nil)` (a deferred transaction).

### Observation

Task 8 states: "`BEGIN IMMEDIATE` (prevents TOCTOU between similarity check and insert)".

The existing `Submit` uses:

```go
tx, err := s.db.BeginTx(ctx, nil)
```

`nil` options means the default isolation level for `modernc.org/sqlite`, which is `DEFERRED`.
`SubmitWithDedup` requires `IMMEDIATE` to prevent a race between the similarity scan and the
insert. This is a different transaction kind and must be opened as:

```go
tx, err := s.db.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelSerializable})
```

Note that `modernc.org/sqlite` maps `LevelSerializable` to `BEGIN IMMEDIATE`. The plan mentions
this requirement but the code skeleton for `Submit` in Task 3 uses `BeginTx(ctx, nil)` —
`SubmitWithDedup` must use a different options value and the plan should make this explicit.

### Recommendation

Add to the Task 8 implementation note:

```go
tx, err := s.db.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelSerializable})
// modernc.org/sqlite maps LevelSerializable to BEGIN IMMEDIATE
```

---

## Finding 10 — `TierHighMin` Constant Group Has Trailing Space Alignment (MINOR)

**Severity:** Minor — cosmetic, but inconsistent with codebase style.

### Observation

```go
const (
    TierHighMin    = 0.8
    TierMediumMin  = 0.5
    TierLowMin     = 0.3
)
```

The alignment spaces after `TierHighMin` and `TierMediumMin` use tab-stop padding that differs
from the phase constants block style. The existing codebase uses `goimports` formatting without
manual column alignment in constant groups. `gofmt` will remove this padding. This is
cosmetically harmless but may cause a noisy diff on first `gofmt` run.

---

## Finding 11 — Event Bus Third Leg: `--since-discovery` vs Existing Cursor JSON Shape (MEDIUM)

**Severity:** Medium — backward compatibility risk with existing cursor files.

### Observation

Task 6 proposes changing the cursor JSON from `{"phase":N,"dispatch":N}` to
`{"phase":N,"dispatch":N,"discovery":N}`. The plan notes this is backward-compatible ("if
existing cursor JSON lacks `discovery` field, default to 0"). However, the plan also says:

> Fix the pre-existing bug: actually read and use the interspect field (or remove it if unused

The existing cursor JSON (as seen in `event/store.go` and `events.go` context) may already have
an `interspect` field that is silently written but never read. Removing it while adding
`discovery` in the same commit means any consumer that has a saved cursor file will have their
cursor silently reset to 0 for the interspect dimension. This is probably acceptable since the
interspect field was never used, but the plan should document this explicitly as a known
migration behavior.

### Recommendation

In Task 6, add an explicit note: "Saved cursor files that contain `interspect:N` will silently
drop that field on next read/write. This is safe because the interspect cursor was never
consumed. Document in commit message."

---

## Finding 12 — `SearchFilter` Field Alignment Diverges from `ListFilter` (MINOR)

**Severity:** Minor — inconsistency within the same package.

### Observation

Task 9's `SearchFilter` uses inconsistent field alignment:

```go
type SearchFilter struct {
    Source   string
    Tier    string
    Status  string
    MinScore float64
    Limit   int
}
```

The `Tier`, `Status`, and `Limit` fields have fewer spaces than `Source` and `MinScore`, creating
misaligned columns. The `ListFilter` (Task 3) has clean alignment. After `gofmt` these will be
normalized, but the plan itself presents inconsistent code, which may cause copy-paste errors.

---

## Summary Table

| # | Finding | Severity | Task |
|---|---------|----------|------|
| 1 | Constructor name inconsistency (`NewStore` vs `New`) | Medium | Task 1 |
| 2 | `DiscoveryEvent` has redundant `Timestamp` + `CreatedAt` fields | High | Task 1 |
| 3 | `Get` uses string error for not-found instead of sentinel | High | Task 3 |
| 4 | `nowUnix()` defined in `store.go` instead of `discovery.go` | Medium | Task 3 |
| 5 | `idLen = 12` diverges from codebase `idLen = 8` without justification | Medium | Task 1 |
| 6 | `generateID` is copy-pasted, not shared | Medium | Task 1 |
| 7 | Test setup discards `Submit` errors silently | Medium | Tasks 3, 8, 9 |
| 8 | `Decay` SQL binds rate three times — correctness risk | High | Task 8 |
| 9 | `SubmitWithDedup` needs `BEGIN IMMEDIATE` explicitly stated | Medium | Task 8 |
| 10 | Trailing space alignment in constant group | Minor | Task 1 |
| 11 | Cursor backward-compat for dropped `interspect` field undocumented | Medium | Task 6 |
| 12 | `SearchFilter` field misalignment | Minor | Task 9 |

## Blockers Before Implementation

The following must be addressed before Tasks 3, 4, and 8 are implemented:

1. **Finding 3** (sentinel errors file) — create `errors.go` before writing any store method
   that can return not-found or gate-blocked.
2. **Finding 2** (dual timestamp fields) — fix the `DiscoveryEvent` struct in Task 1 before any
   code references it.
3. **Finding 8** (Decay SQL correctness) — the SQL as written will bind the rate variable
   incorrectly; switch to Go-side computation before implementing `Decay`.
