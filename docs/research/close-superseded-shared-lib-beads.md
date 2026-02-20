# Close Superseded Shared-Lib Beads

**Date:** 2026-02-19
**Task:** Close beads superseded by the Intercore vision doc

## Results: 9/9 Succeeded

All 9 beads were closed successfully with no errors.

### Shared Library Beads

| Bead | Reason |
|------|--------|
| iv-jmua | Superseded by intercore vision: modules call `ic` directly, no shared SQLite lib needed |
| iv-tkc6 | Superseded by intercore vision: big-bang hook cutover eliminates shared bash hook library |
| iv-lwsf | Superseded by intercore vision: not relevant when kernel is CLI-based |

### State Management Beads

| Bead | Reason |
|------|--------|
| iv-38c9 | Superseded by intercore vision: `ic state` + `ic events` provide state-persisted orchestration |
| iv-gvpq | Superseded by intercore vision: `ic run` + `ic state` replace session handoff files |
| iv-fnvw | Superseded by intercore vision: `ic run` with custom phase chains |

### Other Superseded Items

| Bead | Reason |
|------|--------|
| iv-dm1a | Superseded by intercore vision: token budget controls are kernel-native (Cost and Billing section) |
| iv-b6k1 | Superseded by intercore vision: lane-based scheduling + dispatch subsystem |
| iv-oijz | Superseded by intercore vision: kernel event bus replaces MCP-to-MCP communication |

## Summary

The Intercore vision (`ic` CLI kernel) supersedes three categories of prior work:

1. **Shared libraries** — direct `ic` calls replace any need for a shared SQLite lib or shared bash hook library; kernel-based approach makes these unnecessary.
2. **State management** — `ic state`, `ic run`, and `ic events` provide native state persistence and orchestration, replacing earlier handoff file patterns and custom phase chain concepts.
3. **Cross-cutting concerns** — token budget controls, lane-based scheduling, and the kernel event bus are now first-class kernel features, eliminating the need for MCP-to-MCP communication workarounds or standalone scheduling beads.
