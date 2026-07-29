# RMX1901 Halium arm64 initrd provenance

The production boot input is the RMX1901-specific safe initrd described by
`rmx1901-safe-initrd-arm64.provenance.json`. It is pinned simultaneously to:

- `Lcryolite/initramfs-tools-halium-rmx1901` source commit
  `91cad415103265f7103ea30b191d4deada907cf4`;
- immutable release `360740515`, tag `rmx1901-safe-initrd-91cad41-r2`;
- immutable asset-ID API endpoint `491999765`;
- size `3,949,738` and SHA-256
  `d396d8da1dc6800a8520dbd0e6b775b469292a882d2598410fcfc34a36e8927c`;
- exact hashes for `scripts/halium` and the F2FS-aware userdata policy.

The fetch and boot gates use a fixed validator and do not accept caller
metadata overrides. They also inspect the archive semantics before staging or
accepting an embedded ramdisk.

## Historical official artifact

Captured from the official GitHub release and asset APIs on 2026-07-27. `halium-initrd-arm64.asset.json` is the minimized asset response; `halium-initrd-arm64.provenance.json` joins the release identity, immutable asset-ID API URL, uploader, size, timestamps and verification records used by the fetch gate.

GitHub reported `digest: null` for both the binary and checksum assets. The recorded SHA-256 is therefore not described as a GitHub metadata digest. It was read from official checksum asset 92015681 through its asset-ID API URL, then independently matched against the complete 4,106,247-byte binary downloaded through asset 92015679. `halium-initrd-arm64.sha256` preserves the publisher checksum content.

The release tag itself is mutable (`continuous`, release `immutable: false`). Consumers must use only the recorded asset-ID API URL and must reject the browser URL under `/releases/download/continuous/`.

This official artifact is retained only as historical evidence. It contains
unsafe unconditional ext4 repair/resize behavior and must never be staged as
the RMX1901 boot initrd. See `LEGACY-OFFICIAL-INITRD-UNSAFE.md`.
