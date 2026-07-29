# Legacy official Halium initrd — unsafe boot input

The existing `halium-initrd-arm64.*` records are retained unchanged as
historical supply-chain evidence for official asset `92015679`, SHA-256
`0bbac4577f3567aec935c958216de5d30c7355452ca56248d6728f4f2634bdb6`.
They are not an approved boot input.

That legacy initrd performs unconditional ext4-oriented `e2fsck -y` and
`resize2fs` operations before it has safely established the userdata
filesystem type. It must not be staged for RMX1901 and is especially unsafe
when userdata may be F2FS.

Task4 run-7 reached terminal status `1`. Its attempt log begins with
`staged verified Halium initrd asset 92015679 (4106247 bytes)`, proving that
the failed attempt used the unsafe legacy input. Run-7 did not publish a
verified image manifest or successful product images, so this record does not
claim or copy any run-7 image artifact.

The only approved boot input is the RMX1901 safe asset described by
`rmx1901-safe-initrd-arm64.provenance.json`.
