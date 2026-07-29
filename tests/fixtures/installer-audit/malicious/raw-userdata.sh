#!/bin/sh
adb shell 'dd if=/tmp/payload of=/dev/block/by-name/userdata'
