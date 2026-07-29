# Safe device baseline

`scripts/capture-device-baseline.sh` writes this directory only when exactly one
ADB device is in the `device` state.  It records filtered Android properties,
the block-device name listing, the three pinned source revisions, and a
rollback-proof placeholder.

The script must not be extended to read or copy modem, EFS, IMEI, or user-data
partitions.  It filters property lines containing `serial`, `imei`, `meid`,
`subscriber`, or `phone` before saving them.  Do not commit capture artifacts
until they have been reviewed for sensitive identifiers.

`RUI 2 rollback verified` remains pending until a known-good recovery image is
booted and its filename and SHA-256 are recorded in `rollback-proof.txt`.
