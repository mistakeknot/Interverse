# Beads 0.51+ Upgrade Plan (Interverse)

## Why this plan exists

Interverse currently runs `bd 0.50.3` with a SQLite backend at `.beads/beads.db`. Beads `0.51+` removes SQLite backend support and changes `bd sync` to a compatibility no-op. We need a staged migration before unpinning beads.

## Current state (as of 2026-02-18)

- CLI version: `bd 0.50.3`
- Backend: `sqlite` (`bd backend show`)
- Sync mode: `git-portable` (`bd config get sync.mode`)
- Active issue tracker: Interverse root `.beads/`

## High-risk compatibility changes

1. `bd sync --from-main` is removed in `0.51+`.
2. `bd sync --status` is removed in `0.51+`.
3. SQLite backend is removed in `0.51+`.
4. `bd sync` no longer performs git sync in `0.51+`.

## Migration sequence

1. Normalize commands first (while still on `0.50.3`)
- Remove `bd sync --from-main` and `bd sync --status` from active workflows.
- Keep plain `bd sync` only as compatibility glue.

2. Snapshot and backup
- Create backup branch: `git checkout -b chore/beads-upgrade-backup-<date>`.
- Backup `.beads/` directory: `cp -a .beads .beads.backup.<date>`.
- Export JSONL snapshot from current state: `bd export`.

3. Prepare Dolt target on `0.50.3`
- Run migration with existing CLI so SQLite source is still readable:
  - `bd migrate --to-dolt`
- Verify backend switch:
  - `bd backend show` (expect `dolt`)
- Run integrity checks:
  - `bd doctor --fix --yes`
  - `bd list --json | jq 'length'` (compare pre/post counts)

4. Upgrade beads binary to `0.51+`
- Install/upgrade beads binary.
- Re-run checks:
  - `bd --version`
  - `bd backend show`
  - `bd ready`
  - `bd list --json | jq 'length'`

5. Adjust operational expectations
- Treat `bd sync` as no-op compatibility command.
- Use normal git workflow for code pushes.
- If Dolt remote workflow is desired, use explicit Dolt commands (`bd dolt pull`, `bd dolt push`) where applicable.

## Validation checklist

- Issue count unchanged pre/post migration.
- Sample issue IDs/titles/statuses match pre-migration output.
- `bd ready`, `bd show <id>`, `bd update`, and `bd close` work on migrated backend.
- No active scripts or hooks still using removed sync flags.

## Rollback

If migration validation fails before binary upgrade:

1. Restore `.beads/` from backup copy.
2. Reset working tree to pre-migration commit.
3. Re-run `bd doctor --fix --yes`.

If migration fails after binary upgrade:

1. Reinstall `bd 0.50.3` temporarily.
2. Restore `.beads/` backup.
3. Re-run migration with logs captured.

## Recommended rollout

1. Land command compatibility updates first (Clavain/interphase/docs).
2. Run migration in a dedicated maintenance session.
3. Validate and then unpin beads.
4. Announce behavior change: `bd sync` is now compatibility no-op.
