# Host optimization evidence

`scripts/prepare-speed-build.sh` records each approved process-group cleanup
decision in a timestamped `process-cleanup-*.log` file in this directory.

Set `KEEP_CODEX_PID` to the root PID of the Codex session that must remain
alive and `PORT_ROOT` to this port repository. Preview every selection first:

```bash
KEEP_CODEX_PID=1234 PORT_ROOT="$PWD" DRY_RUN=1 scripts/prepare-speed-build.sh
```

Live mode sends only `SIGTERM` to verified process groups whose root command
is an additional Codex process, `node ... okx-a2a run`, or `gh run watch ...`.
The current Codex ancestry and subtree, shared process groups, proxies, and KDE
desktop core processes are excluded. The script waits at most 15 seconds and
records survivors; it never escalates to `SIGKILL`.

`SIGNAL_COMMAND`, `MONOTONIC_SECONDS_COMMAND`, and `SLEEP_COMMAND` exist only to
make signal delivery and the 15-second wait observable in tests. Leave them
unset during normal use so Bash's `kill`, its monotonic `SECONDS` counter, and
the system `sleep` command are used.
