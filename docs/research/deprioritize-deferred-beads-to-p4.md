# Deprioritize Deferred Beads to P4

**Date:** 2026-02-19
**Author:** mk
**Purpose:** Record outcome of deprioritizing v3–v4 horizon beads per intercore vision doc.

## Summary

All 8 beads were successfully updated to P4 (lowest priority, deferred). The `bd set` syntax referenced in the task does not exist — the correct command is `bd update <id> --priority 4`.

## Command Syntax Note

- **Does NOT work:** `bd set iv-wrae --priority 4`
- **Correct syntax:** `bd update iv-wrae --priority 4`
- The `bd update` command accepts `-p` / `--priority` (0–4 or P0–P4, 0=highest).

## Results

| Bead ID  | Title                                      | Horizon | Rationale                            | Result  |
|----------|--------------------------------------------|---------|--------------------------------------|---------|
| iv-wrae  | Evaluate Container Use (Dagger) for sandboxed agent dispatch | v3 | Container/Dagger sandbox — not needed until multi-agent dispatch at scale | Success |
| iv-cam4  | Automated TUI testing                      | v4      | TUI testing infrastructure — deferred until TUI surface stabilizes | Success |
| iv-r90q  | Deployment registry                        | v3      | Plugin/module deployment registry — v3 concern | Success |
| iv-01c4  | GitHub PR integration                      | v4      | PR automation layer — deferred, not critical path | Success |
| iv-2ds5  | Interhub TUI control room                  | v4      | Full TUI dashboard — deferred, Bigend and interstatus are earlier solutions | Success |
| iv-umvq  | Health aggregation (interstatus)           | v3      | Bigend replaces this; SQLite-first approach deferred to v3 | Success |
| iv-vkjd  | Dolt hybrid backend                        | deferred | SQLite is the confirmed decision; Dolt hybrid is out of scope | Success |
| iv-zfjg  | MCP lifecycle manager                      | v3      | MCP lifecycle management — v3 horizon | Success |

**Total:** 8/8 succeeded. 0 errors.

## Verification

Spot-checked `iv-wrae` post-update:

```
○ iv-wrae · Evaluate Container Use (Dagger) for sandboxed agent dispatch   [● P4 · OPEN]
Owner: mk · Type: feature
Created: 2026-02-16 · Updated: 2026-02-19
```

Priority confirmed as P4 (lowest), status remains OPEN.

## Key Findings

1. **bd update is the correct command** — `bd set` does not exist; `bd update <id> --priority <0-4>` is the right syntax.
2. **All 8 beads deprioritized cleanly** — no errors, all confirmed P4 as of 2026-02-19.
3. **Rationales preserved** — these beads are valid ideas but deferred per the intercore vision doc's v3–v4 horizon assignments. SQLite-first (not Dolt), Bigend over interstatus, and containerization being premature are the three key architectural decisions driving the deferrals.
