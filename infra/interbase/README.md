# interbase

Shared integration SDK for Interverse plugins. Enables dual-mode operation: plugins work standalone via Claude Code marketplace and gain additional features when the Interverse ecosystem is present.

## Install

```bash
bash install.sh
```

Installs `interbase.sh` to `~/.intermod/interbase/`.

## How Plugins Use It

Each plugin ships `interbase-stub.sh` in its hooks directory. The stub:

1. Checks for the centralized copy at `~/.intermod/interbase/interbase.sh`
2. If found: sources it (full ecosystem features)
3. If not found: defines inline no-op stubs (standalone mode)

Plugins call `ib_*` functions without worrying about whether the ecosystem is present — all functions return safe defaults when dependencies are missing.

## For Plugin Authors

See `AGENTS.md` for the full function reference and adoption guide.
