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

Each event starts the cleanup in §14.4. Neither notification is gated by any
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
`AsyncStream` per subscriber that receives every event raised after the call.
`start()` subscribes the cleanup in §14.4 to it.

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

### 14.4 The cleanup

`WorkerSupervisor.cleanUpDisk` runs on every `lowDiskSpace` event and from
**Clean up now** in the app menu (§10), which runs it whatever the free space.
In order:

1. Measure free space on every volume holding a project's checkout or
   worktree root (as in §14).
2. Sweep every project's finished worktrees (§5, "Sweeping finished work's
   worktrees"), one project after another, in project-name order.
3. Measure again.
4. Run each project's cleanup command (§14.3), if one is set, one at a time and
   never in parallel, so two cache prunes do not compete for the disk. A
   command that fails or times out does not stop the next.
5. Measure again.
6. Write one `decision` report per project, naming the trigger ("Low disk space
   cleanup" or "Clean up now"), the worktrees removed, each worktree kept with
   its reason, and the command's result with its output tail. This is the
   sweep's own report, written once, not a second one.
7. Post one follow-up notification, "Disk cleanup finished": free space per
   volume before step 2 and after step 4, how many worktrees were removed and
   how many kept, and one line per command that failed, timed out or could not
   start, and per project whose sweep failed.

Only one cleanup runs at a time. A trigger that arrives while one runs — a
second event, or **Clean up now** — joins it and gets its result; it does not
start a second sweep.

Safety rules, all inherited from the sweep (§5) and the teardown path (§3.1):

- The project's own checkout is never removed.
- A worktree an active session holds, or a spawn is placing, is kept.
- A worktree with uncommitted changes is kept, and one that was dirty before
  its teardown hook ran is never forced.
- No branch is deleted.
- Each path is claimed in the supervisor's in-flight teardown set before it is
  removed, and one another teardown has claimed is kept, so the orphan reaper
  cannot race the cleanup.
- Every kept worktree is named in its project's report, with its reason.
- The cleanup command runs in the project's own checkout and touches nothing
  Agent Board chose; what it deletes is the human's setting (§14.3).
