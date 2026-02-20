# Close Superseded Interbus Beads

**Date:** 2026-02-19
**Action:** Closed 19 interbus beads (iv-psf2 tree)
**Reason:** Superseded by intercore vision: three-layer architecture replaces per-module event bus adapters

## Summary

The Intercore vision document establishes a three-layer architecture where plugins call `ic` directly, eliminating the need for per-module adapter layers (interbus). All 19 beads in the iv-psf2 tree were closed as superseded.

## Beads Closed (19 total)

| Bead ID | Status |
|---------|--------|
| iv-psf2 | Closed |
| iv-psf2.1 | Closed |
| iv-psf2.1.1 | Closed |
| iv-psf2.1.2 | Closed |
| iv-psf2.1.3 | Closed |
| iv-psf2.1.4 | Closed |
| iv-psf2.2 | Closed |
| iv-psf2.2.1 | Closed |
| iv-psf2.2.2 | Closed |
| iv-psf2.2.3 | Closed |
| iv-psf2.2.4 | Closed |
| iv-psf2.2.5 | Closed |
| iv-psf2.2.6 | Closed |
| iv-psf2.2.7 | Closed |
| iv-psf2.2.8 | Closed |
| iv-psf2.3 | Closed |
| iv-psf2.3.1 | Closed |
| iv-psf2.3.2 | Closed |
| iv-psf2.3.3 | Closed |

## Result

- Succeeded: 19/19
- Errors: 0

## Rationale

The three-layer architecture (plugins -> ic CLI -> Intercore daemon) removes the need for per-module event bus adapters. The interbus tree (iv-psf2 and all children) was a design for adapter shims that are no longer part of the target architecture.
