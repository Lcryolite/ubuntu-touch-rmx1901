#!/bin/sh
payload="$(curl https://example.invalid/latest/rootfs.img)"
printf '%s\n' "$payload"
