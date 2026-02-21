# Demarch Ecosystem Reorganization Plan

**Objective:** Rename the overarching project to **Demarch** (a nod to Alastair Reynolds' Democratic Anarchists, reflecting the continuous polling and consensus-driven architecture of the multi-agent system) while preserving **Interverse** as the specific name for the ecosystem of `inter-*` companion plugins. Restructure the monorepo to explicitly reflect the 3-Layer Architecture defined in the vision documents.

## Key Architectural Facts

This is a **multi-git monorepo** — each subproject has its own `.git` directory and GitHub remote. The root repo tracks only the skeleton: directory structure, docs, scripts, beads, and `.gitignore`. Subproject directories (`hub/`, `plugins/`, `services/`, `infra/`, `sdk/`) are gitignored at the root level.

**Implications:**
- `git mv` at the root level is irrelevant for subproject code — use filesystem `mv`
- Each subproject's internal git history is unaffected by the restructure
- Go modules use their own repo paths (e.g., `github.com/mistakeknot/intermute`), not the monorepo path — no Go import rewrites needed
- The root repo only needs its `.gitignore`, docs, and scripts updated

## Current State vs. Target State

**Current Structure (44 `.git` repos):**
```text
Interverse/                    ← root repo (skeleton only)
├── .beads/                    ← work tracking DB
├── .clavain/                  ← agent state
├── hub/
│   ├── autarch/               ← own .git
│   ├── clavain/               ← own .git
│   └── Intermute -> ../services/intermute  ← symlink
├── infra/
│   ├── agent-rig/             ← own .git
│   ├── interband/             ← own .git
│   ├── interbench/            ← own .git
│   ├── intercore/             ← own .git
│   └── marketplace/           ← own .git
├── plugins/                   ← 33 dirs, each own .git
├── sdk/
│   └── interbase/             ← own .git
├── services/
│   └── intermute/             ← own .git
├── Interforge/                ← untracked, own .git
├── frankentui-research/       ← gitignored research
├── scripts/                   ← tracked in root repo
└── docs/                      ← tracked in root repo

External symlinks:
  /root/projects/Autarch      -> Interverse/hub/autarch
  /root/projects/interlock    -> Interverse/plugins/interlock
  /root/projects/Linsenkasten -> Interverse/plugins/linsenkasten
```

**Target Structure:**
```text
Demarch/                       ← renamed root repo
├── apps/                      # Layer 3: Swappable TUI interfaces
│   └── autarch/
├── os/                        # Layer 2: Workflow & Policy
│   └── clavain/
├── core/                      # Layer 1: Mechanism & Infrastructure
│   ├── intercore/
│   ├── intermute/
│   ├── agent-rig/
│   ├── interband/
│   ├── interbench/
│   └── marketplace/
├── interverse/                # Ecosystem: 33+ Claude Code plugins
│   ├── interchart/
│   ├── intercheck/
│   ├── interflux/
│   └── ... (all former plugins/)
├── sdk/                       # Shared libraries (unchanged)
│   └── interbase/
├── Interforge/                # Stays at root (untracked)
├── frankentui-research/       # Stays at root (gitignored research)
├── scripts/
└── docs/
```

**What's NOT changing:**
- `sdk/` stays in place
- `.beads/`, `.clavain/` stay in place
- Each subproject's internal `.git` and repo identity
- Go module paths (they use their own repo names, not the monorepo path)
- `Interforge/` stays at root (untracked, own repo)
- `frankentui-research/` stays at root (gitignored)

**Removed from original plan:**
- `interspect/` — does not exist as a standalone directory (lives under `intercore/docs`). Can be promoted later if/when it becomes its own module.

---

## Execution Phases

### Phase 1: Directory Restructure (Filesystem Moves)

Since subprojects are gitignored at the root, these are plain filesystem moves. Each subproject's `.git` directory moves with it — no history impact.

**1.1 Create target directories:**
```bash
mkdir -p apps os core
```

**1.2 Move the Plugin Ecosystem:**
```bash
mv plugins interverse
```

**1.3 Move the Application Layer (Layer 3):**
```bash
mv hub/autarch apps/autarch
```

**1.4 Move the OS Layer (Layer 2):**
```bash
mv hub/clavain os/clavain
```

**1.5 Move Core Infrastructure (Layer 1):**
```bash
mv infra/agent-rig core/agent-rig
mv infra/interband core/interband
mv infra/interbench core/interbench
mv infra/intercore core/intercore
mv infra/marketplace core/marketplace
mv services/intermute core/intermute
```
Note: `mv infra/*` would also move `infra/.gitignore` or other hidden files — enumerate explicitly.

**1.6 Clean up legacy directories and stale symlinks:**
```bash
# Remove the Intermute convenience symlink (points to old location)
rm hub/Intermute
# Remove empty legacy directories
rmdir hub infra services
```

### Phase 2: Root Repo Updates

These are the files tracked by the root repo that reference the old directory structure.

**2.1 Update `.gitignore`:**
Replace the subproject ignore block:
```gitignore
# OLD:
hub/
plugins/
services/
infra/*
sdk/*

# NEW:
apps/
os/
core/
interverse/
sdk/*
```

**2.2 Update `CLAUDE.md`:**
Change the structure listing from `hub/clavain/`, `plugins/`, `services/`, `infra/` to `os/clavain/`, `interverse/`, `core/`, `apps/autarch/`. Update the naming to clarify Demarch vs Interverse.

**2.3 Update `AGENTS.md`:**
The module table (lines 33-64) references all old paths. Update every row:
- `hub/clavain/` → `os/clavain/`
- `plugins/<name>/` → `interverse/<name>/`
- `services/intermute/` → `core/intermute/`
- `infra/<name>/` → `core/<name>/`

Also update the docs convention note and roadmap script reference.

**2.4 Update scripts:**

`scripts/consolidate-module-docs.sh` — hardcoded path map:
- `hub/clavain/docs` → `os/clavain/docs`
- `infra/intercore/docs` → `core/intercore/docs`
- `plugins/<name>/docs` → `interverse/<name>/docs`
- `plugins/interlens/docs/` → `interverse/interlens/docs/`

`scripts/install-index-hooks.sh` — references `hub/`, `plugins/`, `services/`, `infra/`:
- Update search directories to `apps/`, `os/`, `core/`, `interverse/`
- Update `INDEXER` path from `plugins/interlearn/` to `interverse/interlearn/`

`scripts/gen-skill-compact.sh` — hardcoded `plugins/` paths:
- `plugins/interwatch/` → `interverse/interwatch/`
- `plugins/interpath/` → `interverse/interpath/`
- `plugins/interflux/` → `interverse/interflux/`

`scripts/sync-roadmap-json.sh` — references `hub/`, `plugins/`, `services/`:
- Update to `apps/`, `os/`, `interverse/`, `core/`

**2.5 Update docs:**

`docs/interverse-vision.md` — rename to `docs/demarch-vision.md`. Update content to clarify Demarch as the project name, Interverse as the plugin ecosystem.

`docs/diagrams/ecosystem.html` — update `repoUrl` from `Interverse` to `Demarch`.

`docs/architecture.md`, `docs/interverse-roadmap.md` — update any structural references.

184 docs files reference old paths — most are in `docs/research/` and `docs/solutions/` which are historical records. **Do NOT mass-replace** in research docs (they describe the state at the time of writing). Only update living docs:
- `docs/guides/*.md`
- `docs/architecture.md`
- `docs/interverse-roadmap.md` (rename to `docs/demarch-roadmap.md`)
- Root `README.md`

### Phase 3: Fix External Symlinks

Update compatibility symlinks in `/root/projects/`:

```bash
# Fix Autarch
ln -sfn /root/projects/Demarch/apps/autarch /root/projects/Autarch

# Fix interlock
ln -sfn /root/projects/Demarch/interverse/interlock /root/projects/interlock

# Fix Linsenkasten (if the plugin still exists after rename to interlens)
ln -sfn /root/projects/Demarch/interverse/linsenkasten /root/projects/Linsenkasten
```

Also create a backward-compat symlink for the old monorepo path:
```bash
ln -sfn /root/projects/Demarch /root/projects/Interverse
```

### Phase 4: Plugin Infrastructure Updates

Claude Code plugins reference paths internally. Check and update:

**4.1 Marketplace registry** (`core/marketplace/`):
- Plugin entries may reference installation paths or repo structure. Audit `marketplace.json` for any `plugins/` path references.

**4.2 Plugin `plugin.json` files:**
- Most plugins are self-contained (paths relative to their own root). Unlikely to need changes, but grep `interverse/` directory for any cross-references to `plugins/` or `hub/`:
  ```bash
  grep -r '"plugins/' interverse/*/plugin.json
  grep -r '"hub/' interverse/*/plugin.json
  ```

**4.3 Beads configuration:**
- `.beads/` stays at the root. The `bd` CLI uses CWD to find `.beads/`. As long as the working directory is still the monorepo root, beads are unaffected.

**4.4 `.claude/settings.local.json`:**
- May contain paths to plugins. Check for `plugins/` references and update to `interverse/`.

### Phase 5: Branding Updates

**5.1 Rename identity in root docs:**
- Project name: **Demarch** (the overall system)
- **Interverse**: the ecosystem of `inter-*` plugins in `/interverse`
- **Clavain**: the autonomous agency at `os/clavain/` (proper noun, capitalized)
- **Autarch**: the TUI layer at `apps/autarch/`

**5.2 Update naming in `CLAUDE.md` header:**
```markdown
# Demarch

Monorepo for the Demarch autonomous software agency.
Interverse (`/interverse`) is the ecosystem of 33+ Claude Code companion plugins.
```

**5.3 Update `docs/interverse-vision.md`** → `docs/demarch-vision.md`:
- Introduce the Demarch name and philosophy
- Redefine Interverse as the plugin ecosystem layer

**5.4 Review TUI strings in Autarch:**
- Grep `apps/autarch/` for "Interverse" references that should become "Demarch"

### Phase 6: Repository Rename (Manual, Last)

**Do this last**, after everything works internally. GitHub creates a redirect from the old URL automatically.

1. **Rename on GitHub:** `mistakeknot/Interverse` → `mistakeknot/Demarch`
2. **Update root repo remote:**
   ```bash
   git remote set-url origin https://github.com/mistakeknot/Demarch.git
   ```
3. **Subproject repos are unaffected** — they have their own GitHub repos (e.g., `mistakeknot/intermute`, `mistakeknot/interflux`) and don't reference the monorepo URL.

### Phase 7: Validation

1. **Root repo:** `git status` — verify `.gitignore` correctly ignores the new directory names.
2. **Scripts:** Run each script in `scripts/` and verify no path errors.
3. **Beads:** `bd list` — verify beads DB is accessible from the new root.
4. **Symlinks:** Verify `/root/projects/Autarch`, `/root/projects/interlock`, and `/root/projects/Interverse` (compat) all resolve.
5. **Plugin loading:** Start a new Claude Code session and verify plugins load from `interverse/` paths (check `/doctor` output).
6. **Go builds:** `cd core/intermute && go build ./...` — verify build still works.
7. **Commit:** Stage root repo changes and commit:
   ```
   refactor: restructure monorepo to 3-layer Demarch architecture

   apps/   — Layer 3 (Autarch TUI)
   os/     — Layer 2 (Clavain agency)
   core/   — Layer 1 (intercore, intermute, infra)
   interverse/ — Ecosystem (33+ plugins, formerly plugins/)
   ```

---

## Risk Mitigation

| Risk | Mitigation |
|------|------------|
| Broken symlinks | Phase 3 explicitly handles all known symlinks. Backward-compat symlink at old path. |
| Plugin loading failures | Plugins are self-contained with relative paths. Validate in Phase 7. |
| Beads DB inaccessible | `.beads/` doesn't move. `bd` finds it by CWD traversal. |
| Scripts break | Phase 2.4 enumerates every script with path references. |
| Mass path-replace corrupts historical docs | Only update living docs. Research/solution docs are historical records — leave as-is. |
| `.claude/settings.local.json` stale paths | Phase 4.4 audits and updates. |
| Filesystem move fails mid-way | All moves are independent — can resume from any point. No atomic requirement. |

## Execution Order Summary

```
Phase 1: mv directories        (filesystem, reversible)
Phase 2: update root repo files (gitignore, docs, scripts)
Phase 3: fix external symlinks  (/root/projects/*)
Phase 4: plugin infrastructure  (marketplace, settings)
Phase 5: branding updates       (naming, vision docs)
Phase 6: GitHub repo rename     (manual, last)
Phase 7: validation             (tests, builds, plugin loading)
```

All phases except 6 can be executed by an agent. Phase 6 requires a human admin in the GitHub UI.
