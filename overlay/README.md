# RMX1901 overlay

The overlay carries only the immutable Ed25519 public key used by the
initramfs diagnostic bridge.  That bridge is enabled only by the boot-time
diagnostic token and keeps its host key and all state in tmpfs; it never uses
a userdata marker.  Password authentication, root login, forwarding, and
ADB are disabled.

The overlay masks ADB at `/lib/systemd/system`; no rootfs `usb-moded` SSH
unit is shipped.  The initramfs bridge reads the pinned public key directly
from the immutable `/opt/halium-overlay` tree.

The pinned UBports tarball builder copies `overlay/system/*` into the device
tarball and, in overlaystore mode, installs it below
`system/opt/halium-overlay/`.  This README is copied only to the temporary
build root because the device tarball includes only `partitions/` and
`system/`; it is not shipped on the phone.
