# Cross-module integration opportunities (tracked via parent bead)

**Parent bead:** `iv-z1a0` (`Cross-module integration opportunity program`)

**Status (Feb 15, 2026):** Parent + children created in `.beads/issues.jsonl`.

This is intentionally tracked as a root-owned cross-cutting program (`iv-z1a0`) with module-tagged child issues.

## Sub-issues

- `iv-z1a1` — Inter-module event bus + event contracts
- `iv-z1a2` — Interline as unified operations HUD
- `iv-z1a3` — Doc drift auto-fix and execution re-plan loop
- `iv-z1a4` — Interkasten context into discovery and sprint intake
- `iv-z1a5` — Cross-module quality feedback loop
- `iv-z1a6` — Release coupling between interpub and operational modules
- `iv-z1a7` — Terminal UI regression signal integration

## Scope

- Purpose: convert isolated module signals into shared workflows across hubs and plugins.
- Integration edges: intermute / interphase / interlock / interline / interwatch / interpath / interdoc / interpub / interflux / interspect / interkasten / tuivision / interline.
- Tracking model: each child bead has `dependencies` entry `{ "issue_id": "<child>", "depends_on_id": "iv-z1a0", "type": "parent-child" }`.
