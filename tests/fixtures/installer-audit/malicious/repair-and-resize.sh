#!/bin/sh
e2fsck -y /dev/block/by-name/userdata
resize2fs /dev/block/by-name/userdata
