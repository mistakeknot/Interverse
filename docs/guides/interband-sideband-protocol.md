# Interband Sideband Protocol (v1)

## Purpose

Interband standardizes cross-plugin sideband file contracts so producers and
consumers can evolve safely without ad-hoc `/tmp` parsing.

## Default Root

- `~/.interband`
- Override with `INTERBAND_ROOT`

## Envelope Schema

All messages use this top-level envelope:

```json
{
  "version": "1.0.0",
  "namespace": "interphase",
  "type": "bead_phase",
  "session_id": "abc-123",
  "timestamp": "2026-02-17T12:00:00Z",
  "payload": {}
}
```

Rules:
- `version` MUST start with `1.` for v1 readers.
- `payload` MUST be an object.
- Writers MUST write atomically (temp file + rename).
- Known `namespace/type` payloads are schema-validated by `interband_write`.
- Unknown `namespace/type` payloads remain forward-compatible (object-only check).

## Active Channels (initial)

### `interphase/bead/<session_id>.json`

- `namespace`: `interphase`
- `type`: `bead_phase`
- `payload`:
  - `id` (string)
  - `phase` (string)
  - `reason` (string)
  - `ts` (unix seconds, number)

### `clavain/dispatch/<pid>.json`

- `namespace`: `clavain`
- `type`: `dispatch`
- `payload`:
  - `name` (string)
  - `workdir` (string)
  - `started` (unix seconds, number)
  - `activity` (string)
  - `turns` (number)
  - `commands` (number)
  - `messages` (number)

### `interlock/coordination/<project>-<agent>.json`

- `namespace`: `interlock`
- `type`: `coordination_signal`
- `payload`:
  - `layer` (string, currently `coordination`)
  - `icon` (string)
  - `text` (string)
  - `priority` (number)
  - `ts` (RFC3339 UTC timestamp)

## Compatibility Policy

- Readers SHOULD ignore unknown fields.
- Writers MAY add fields in `payload` without breaking v1 readers.
- Breaking envelope changes require a new major version and dual-read migration.

## Current Migration State

- Producers write interband files.
- Legacy `/tmp/clavain-*` files remain for backward compatibility.
- Legacy `/var/run/intermute/signals/*.jsonl` remains as fallback coordination
  stream for compatibility.
- Consumers read interband first where available, then fallback to legacy paths.

## Loader Resolution

Consumers should resolve the library in this order:

1. `INTERBAND_LIB` (explicit override)
2. Monorepo path (`.../core/interband/lib/interband.sh`)
3. Sibling checkout path (`../interband/lib/interband.sh`)
4. Local shared path (`~/.local/share/interband/lib/interband.sh`)

## Go Library

Interband now also ships a Go module (`github.com/mistakeknot/interband`) with
parity helpers for:

- Path and root resolution (`Path`, `ChannelDir`, `SafeKey`)
- Envelope/payload validation and IO (`Write`, `ReadEnvelope`, `ReadPayload`)
- Retention cleanup (`PruneChannel`, env-aware TTL/max-file controls)

## Retention Policy

Writers should prune stale sideband files with `interband_prune_channel` after
successful writes.

Default retention:

- `interphase/bead`: 24h, max 256 files
- `clavain/dispatch`: 6h, max 128 files
- `interlock/coordination`: 12h, max 256 files

Override controls:

- Global: `INTERBAND_RETENTION_SECS`, `INTERBAND_MAX_FILES`
- Per channel:
  - `INTERBAND_RETENTION_<NAMESPACE>_<CHANNEL>_SECS`
  - `INTERBAND_MAX_FILES_<NAMESPACE>_<CHANNEL>`
- Prune interval throttle: `INTERBAND_PRUNE_INTERVAL_SECS` (default 300)
