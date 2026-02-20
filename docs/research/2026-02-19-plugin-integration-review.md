# Final Plugin Integration Review & Recommendations

This document outlines the evaluation of the 31 Interverse ecosystem plugins against the core vision architectures of **Intercore** (Kernel), **Clavain** (OS / Interverse Core), and **Autarch** (Apps).

## Goal
Evaluate the 31 Interverse ecosystem plugins to identify integration and consolidation opportunities, strictly adhering to the fundamental design principles of the ecosystem, primarily focusing on **state consolidation** and avoiding **code consolidation** where it violates independent installability.

---

## 🏗️ The Governing Architectural Constraints

### 1. Independent Installability
This is the North Star (Principle #4). Every plugin driver must be independently installable in a vanilla Claude Code environment—without Clavain, without Intercore, and without the rest of the stack. Code consolidation (e.g., pulling a mature plugin back into the Clavain `skills` folder) is strictly forbidden. It reverses the intended maturity model where capabilities start loosely coupled in Clavain and are promoted into independent companion tools upon proving their usefulness.

### 2. The Process Model Boundary
Intercore is a zero-ops Go CLI binary backed by SQLite. It is stateless between calls. It does NOT own long-running daemon processes (like `intermute`). Merging daemonized service plugins into the CLI kernel violates the basic architectural pattern of Intercore. 

### 3. Mechanism vs. Policy 
The Kernel (Intercore) owns mechanisms and data records (Gates, Phases, Tokens spent, Artifact paths). The OS (Clavain) owns policies (e.g., "A brainstorm phase requires an artifact"). The Apps (Autarch) consume this state for TUI rendering. Plugins consume state or feed into policies but do not belong in the layers they serve. 

---

## 🛠️ Integration Strategy: State Consolidation

Instead of folding plugins into parent layers, the focus must shift entirely toward **State Consolidation**. 

Plugins currently managing their own state (e.g., via temp files, individual `.db` files, or proprietary logic) should integrate with Intercore's primitives (`sc`, `state`, `sentinels`, `locks`) *when Intercore is present*.

### 1. Kernel (Intercore) Synergy
*   **Actionable Insight:** Modify plugins to conditionally detect `ic`.
    *   **If `ic` is present:** Route state reads/writes/events through the kernel to ensure durability and visibility across the ecosystem.
    *   **If `ic` is absent:** Fall back to the legacy/local state mechanisms (temp files/local SQLite). This ensures independent installability remains intact.
*   **What THIS Means for Specific Plugins:**
    *   `interlock`: Do not absorb into Intercore. `interlock` uses `intermute` (a WebSockets daemon) for cross-agent coordination. Intercore uses `mkdir` locks for database serialization. These are different abstractions for different consumers. It should remain independent, just using `ic` for persisting metadata when possible.
    *   `intersearch`: Do not absorb into Intercore. The kernel should record embedding vectors for discovery pipelines, but the embedding models themselves must remain outside the kernel to preserve the mechanism/policy boundary.
    *   `intermute`: Do not absorb into Intercore. It is a daemon service; Intercore is a CLI. 

### 2. OS (Clavain) Synergy
*   **Actionable Insight:** Preserve the outward extraction trajectory.
    *   **What THIS Means for Specific Plugins:**
        *   `interflux`, `tldr-swinton`, `interdoc`, and all other mature plugins: Leave them as standalone plugins in the `plugins/` directory. They have earned their independence. Folding them back into `hub/clavain/skills` would create a massive, tightly-coupled monolith and ruin their cross-platform usefulness.
        *   When Clavain runs, its hooks must leverage `ic` for their state, and these independent plugins will tie into the same shared `ic` state boundary, creating a unified orchestration flow without merging codebases.

### 3. Apps (Autarch) Synergy
*   **Actionable Insight:** Surface rendering must remain decoupled.
    *   **What THIS Means for Specific Plugins:**
        *   `interline`: Keep it decoupled from Bigend. `interline` handles Claude Code statuslines. Bigend is a standalone TUI app. Merging them would break statusline rendering for users running vanilla Claude Code sessions without Autarch installed.
        *   `interslack`: Keep as an ecosystem driver. Tying notifications strictly to Autarch means Slack updates would incorrectly require an Autarch TUI install. 
        *   `tool-time`: Keep independent. It acts as an observatory layer gathering analytics across tools. Its parsed data can perfectly feed Bigend via `ic` log events, but its core code shouldn't move into Autarch.

---

## ⏭️ Next Steps for Execution

The roadmap should progress away from file-movement based refactoring and prioritize the **Big-Bang Hook Cutover** to State Consolidation:

1.  **State Audit:** For every mature plugin (e.g., `interflux`, `interkasten`, `tldr-swinton`), map out where it uses temporary files or local SQLite databases.
2.  **`ic` Wrappers:** Author lightweight wrapper functions in these plugins that test for `$PATH/ic`. 
3.  **Kernel Handoff:** Swap out local `fs.writeFileSync` or `sqlite` calls for commands like `ic state set` or `ic lock acquire` dynamically. 
4.  **Clavain Core Cutover:** Execute the planned hook migration inside Clavain itself, completely ripping out `/tmp` based Bash variables and handing complete phase tracking and execution state back to the Intercore DB.
