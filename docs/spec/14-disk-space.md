## 14. Disk-space monitoring

Workers fill disks: every task gets its own worktree, and a build in each one
leaves its own output behind. Agent Board watches free space on every distinct
volume that holds a project's checkout (`repo_path`) or its worktree root
(`worktree_root`) — usually one volume — and tells the human when one runs low.

The supervisor checks from the metering tick (§8), but measures only once a
check interval of awake time has passed, timed on `CLOCK_UPTIME_RAW` (§8, the
awake clock). A Mac that slept through several intervals owes one check on wake,
not a burst. The first tick after launch measures at once. Free space is
`URLResourceKey.volumeAvailableCapacityForImportantUsageKey`, the figure the
Finder reports; a path that does not exist yet is measured at its nearest
existing ancestor, and two paths on one volume (same mount point) count once.

A volume that falls below the **low threshold** fires one `lowDiskSpace` event
and one macOS notification, "Low disk space", whose body names the volume and
its free GB. That volume then stays quiet until a check finds it above the
**rearm threshold**; the next drop below the low threshold fires again. The gap
between the two is the point: a volume hovering at the low threshold does not
notify on every check. The rearm threshold is never treated as lower than the
low threshold. The armed state is in memory, so a relaunch while a volume is
still low notifies once more.

This section covers noticing only. The notification is not gated by any
project's notification preferences (§10, Project settings): the volume is not
any one project's.

### 14.1 Settings

App-wide, on **Settings → Disk Space** (§10), stored in `UserDefaults`:

| Setting | Key | Default |
|---|---|---|
| Notify when free disk space is low | `diskSpace.enabled` | on |
| Low threshold | `diskSpace.lowThresholdGB` | 25 GB |
| Notify again after rising above | `diskSpace.rearmThresholdGB` | 35 GB |
| Check every | `diskSpace.checkIntervalMinutes` | 5 minutes |

GB here is 10⁹ bytes, as the Finder counts. Turning the switch off stops
measuring and forgets which volumes have fired, so turning it back on while a
volume is low notifies once.

### 14.2 The event

Each `lowDiskSpace` event is a `LowDiskSpaceEvent` carrying the volume's mount
point, name and free bytes. `WorkerSupervisor.lowDiskSpaceEvents()` returns an
`AsyncStream` per subscriber that receives every event raised after the call;
this is what a later cleanup sweep subscribes to.

### 14.3 The project cleanup command

Each project may set a **cleanup command** in Project settings (`cleanupCommand`,
§4), for what builds leave behind outside any one worktree — a build cache, a
package store. It lives in Project settings rather than a file in the repository
for the same reason the teardown hook does (§3.1): it runs unattended, so it is
the human's choice, not something a branch can change. Empty by default, and an
empty or blank command runs nothing. Example: `make clean-cache`.

`ProjectCleanupRunner` runs it the way `WorktreeManager` runs the teardown hook:
`/bin/zsh -c <command>` with the project's own checkout (`repo_path`) as its
working directory and `PWD`, under `ChildEnvironment.sanitized()`, off the main
thread, as the leader of its own process group (`BoundedCommand`). One that
outlives `cleanupCommandTimeoutSeconds` (default 1800, clamped to 1 second
through 24 hours, like the teardown timeout) has its whole process group sent
`SIGTERM`, then `SIGKILL` five seconds later. The deadline is measured on
`CLOCK_UPTIME_RAW`, so a sleeping Mac does not use it up.

The run returns a `ProjectCleanupResult`: the command, the checkout, how it
ended (an exit status, a timeout, or a failure to start) and the last 2,000
characters of its combined output. A command that fails is a result, never a
thrown error, so it cannot stop the rest of a cleanup; its `summary` is the
text for the notification and the `decision` report.
