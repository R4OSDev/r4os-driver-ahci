# AHCI.R4D

`AHCI.R4D` is an independent R4OS driver implemented in Zig.

## Package

- Version: `0.2.0`
- Image target: `/R4OS/DRIVERS/AHCI.R4D`
- Image scope: `slim`
- Canonical project manifest: `module.R4MF`

The manifest is the single source of truth for the artifact, imports, image
target, and package metadata.

Version 0.2.0 is the canonical AHCI storage owner. It identifies every
supported SATA disk, derives capacity, logical sector size, transfer limits,
NCQ support and queue depth from the HBA/drive intersection, and registers a
version-2 asynchronous block backend. Up to 16 generation-owned command tags
and 64 PRDT entries per request are supported. Non-NCQ devices retain a safe
depth-one path, and missing IRQ routing retains bounded polling. MSI/INTx is
configured only during driver initialization; HBA interrupt sources remain
masked during the synchronous pre-LAPIC boot path and are armed by the first
asynchronous runtime request. Deferred completion work is finite per pass.
PxCI and PxSACT are authoritative; a non-zero PRDBC must match the complete
transfer, while zero is accepted as unreported for compatible NCQ HBAs.

Timeout, cancellation, Error-FIS and link failures close admission before a
port reset. A successful reset re-identifies the same disk before reopening;
otherwise an HBA reset is attempted and the backend remains closed on any
identity or quiescence uncertainty.

## Build

On Windows:

    Build.bat

On Linux or macOS:

    ./Build.sh

Run the deterministic IDENTIFY, queue, FIS, PRDT and recovery-state tests with:

    ./Build.sh test

The build starters resolve the current local R4OS dependency checkouts through
`Settings.R4S`. The URL and hash entries in `build.zig.zon` record the
last verified standalone dependency identities; workspace builds use the
mapped local checkouts.

## Documentation

Detailed German technical notes from the migration are preserved in
`DOCUMENTATION.de.txt`. Source-transfer provenance is recorded in
`PROVENANCE.txt`.

## License

Original R4OS material is licensed under Apache License 2.0. See `LICENSE`
and `NOTICE`. Any repository-specific external material is documented in
`THIRD_PARTY_NOTICES.md`.
