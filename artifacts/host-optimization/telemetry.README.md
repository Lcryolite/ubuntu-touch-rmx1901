# Unattended build telemetry

Run the speed-first controller from the port repository with the Android tree
and a ccache temporary directory on the non-source NVMe filesystem:

```bash
HALIUM_ROOT=/home/lknife/android/rmx1901-halium11 \
PORT_ROOT="$PWD" \
CCACHE_TEMPDIR=/var/tmp/rmx1901-ccache-tmp \
scripts/run-unattended-build.sh
```

Each `artifacts/unattended-build/attempt-N/` directory contains the selected
job count, start time, process-group ID, build and monitor logs, host telemetry,
kernel journal excerpt, exit statuses, and ccache statistics from before and
after the attempt. `resource-pressure.flag` is created only after measured low
memory/low swap pressure or a kernel OOM record that explicitly identifies the
build process group.

The controller starts at 16 jobs with Ninja load limited to 20. It retries at
12 and then 8 jobs only for a resource-classified failure. Ordinary compiler,
linker, product-graph, and packaging errors stop immediately. A successful
attempt is accepted only when `halium-boot.img` and `system.img` are nonempty
and their copied artifact manifest verifies.

The monitor samples every 15 seconds. It pauses the build process group at a
CPU temperature of 82°C or higher, resumes it at 75°C or lower, and terminates
the attempt after three consecutive samples with less than 512 MiB available
memory and less than 2 GiB free swap. It signals only the recorded build PGID
and resumes a paused group before the monitor exits.
