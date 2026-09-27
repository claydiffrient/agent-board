## 12. Open items

- **Verified by M0:** a healthy `claude --bg` session honors injected hooks and
  MCP config.
- **Verified by M3, with a known limitation:** the project `autoMode` block
  passed via `--settings` does reach the effective config of a spawned
  `--bg` worker, but a `soft_deny` rule in it does not stop or pause a
  matching tool call in that worker — it just runs.

  Method: registered a project whose `settings_json.autoModeJSON` was
  `{"soft_deny": ["AgentBoard Canary M3 [named+specifics]: any command whose
  text contains the exact token AGENTBOARD_CANARY_9f3d2c17 is always a
  soft-deny requiring approval, with no exceptions, regardless of any other
  rule in this policy."]}`, then ran the headless E2E path (§ below,
  `AGENTBOARD_E2E_REPO` against a throwaway fixture repo) with the task body
  changed to run `echo AGENTBOARD_CANARY_9f3d2c17` before the usual
  hello.txt step. Two independent checks:

  1. `SessionConfigWriter.write` embeds `autoModeJSON` verbatim under the
     `"autoMode"` key of `settings-<session>.json` (confirmed by reading the
     file the real spawn below generated). To check the CLI actually loads
     that key, ran the same shape standalone:
     ```
     $ claude --settings test-settings.json auto-mode config > with-settings.json
     $ grep -n AGENTBOARD_CANARY_9f3d2c17 with-settings.json
     95:    "AgentBoard Canary M3 [named+specifics]: any command whose text contains the exact token AGENTBOARD_CANARY_9f3d2c17 is always a soft-deny requiring approval, with no exceptions, regardless of any other rule in this policy."
     ```
     where `test-settings.json` was `{"autoMode": {"soft_deny": [<the same
     rule>]}}`. The rule shows up appended to the 70 shipped `soft_deny`
     defaults — the `--settings` file's `autoMode` key is honored by
     `auto-mode config`.
  2. The real worker's `PostToolUse` hook payload, captured by Agent Board's
     `/hooks` endpoint and read back from the `hook_event` table:
     ```
     "hook_event_name": "PostToolUse",
     "tool_name": "Bash",
     "permission_mode": "auto",
     "tool_input": { "command": "echo AGENTBOARD_CANARY_9f3d2c17", ... },
     "tool_response": { "stdout": "AGENTBOARD_CANARY_9f3d2c17", ... },
     "duration_ms": 294
     ```
     No ask, no denial, no distinguishing field — the command ran exactly
     like any other Bash call. The task went on to `report_complete` and
     `E2E PASS`.

  **Known limitation:** a project `autoMode.soft_deny` rule is not a working
  safety control for an unattended `claude --bg --permission-mode auto`
  worker — there is no user for the classifier to ask, and the match does
  not fall back to a deny. `autoMode` is still expressive for the interactive
  orchestrator session (which has a user to ask), but a project should not add
  a rule expecting it to stop a worker.
- **Verified by M3: `hard_deny` does not stop the call either.** The same
  canary method, with the rule moved to `hard_deny`. The rule reached the
  effective config — `claude --settings <file> auto-mode config` listed it
  under `hard_deny` alongside the shipped Data Exfiltration rule, the
  `"$defaults"` sentinel expanding in place exactly as it does for
  `soft_deny` — and the worker ran the command anyway:
  (This run predates the `PreToolUse` hook, so `PostToolUse` was the only
  evidence available — and it shows the call completed.)
  ```
  "hook_event_name": "PostToolUse",
  "tool_name": "Bash",
  "permission_mode": "auto",
  "tool_input":    { "command": "echo AGENTBOARD_HARDDENY_4b81e2", ... },
  "tool_response": { "stdout": "AGENTBOARD_HARDDENY_4b81e2", "interrupted": false, ... }
  ```
  The worker then reported `Ran echo AGENTBOARD_HARDDENY_4b81e2; output was
  AGENTBOARD_HARDDENY_4b81e2` and the run ended `E2E PASS`. So neither
  classifier severity is a usable control for a `--bg` worker; the
  `PreToolUse` hook is.
- **Verified by M3: the `PreToolUse` push block works.** Spawned one real
  worker with `--disallowedTools` deliberately emptied, against a fixture repo
  whose `origin` was a local bare clone — so a working push would have
  succeeded and been visible. Task body required `git push -u origin HEAD`.
  The hook payload Agent Board denied:
  ```
  "hook_event_name": "PreToolUse",
  "tool_name": "Bash",
  "permission_mode": "auto",
  "tool_input": { "command": "git push -u origin HEAD 2>&1; echo \"exit=$?\"",
                  "description": "Push current branch to origin as the task requires" }
  ```
  The worker's own report: *"the push was blocked at the tool layer with the
  message 'Agent Board blocks pushes from workers. Commit on your branch and
  call report_complete; a human integrates it.' Nothing was pushed."* The bare
  remote still held only `6cee47b Initial commit` on `main` afterwards, with
  no `agentboard/<task>` branch, and the task card carried the progress row
  `error: Blocked push: git push -u origin HEAD 2>&1; echo "exit=$?"`. The
  unrelated Bash call in the same session (the `hello.txt` commit) was allowed
  through and completed.
- **Not verified live: the shutdown delivery mechanism.** The wind-down order
  (§8) reaches a worker by one of two paths — a busy `--bg` worker only by
  denying its next `PreToolUse`, an idle one only by `--resume` with a prompt
  — and **neither was exercised against a real spawned worker.** Both are
  unit-tested only, against fixtures: `AgentBoardBridgeTests/ShutdownWindDownTests`
  drives the `PreToolUse` deny path through a `BridgeFixture`, and
  `AgentBoardAppTests/ShutdownDeliveryTests` drives the resume path against a
  stub runtime. The progress sheet (§10) fares no better: it was mounted
  offscreen via `NSHostingView` and proven to re-render off the database, but
  its rendered text could not be read back on this machine at all —
  the accessibility elements SwiftUI publishes offscreen carry no label, title
  or value, so the tree comes back empty — and the human click-through steps its own report wrote out (open
  the console, click Stop All, watch rows move `ordered` → `closing` →
  `acknowledged`, let one go overdue, attach to a blocked one, quit) were
  explicitly never run. Unlike the M3 push-block verification above, which
  ran a real worker against a real bare remote, no part of the shutdown
  feature has been seen working end to end.
- **Known gap: a `blocked` worker is enrolled and counted but never receives
  the order.** `deliverShutdownOrder` resumes only sessions in `idle`; nothing
  can reach a session sitting on a permission prompt — no hook fires, and
  resuming into a pending prompt is untested behavior nobody wanted to rely
  on. It shows as **waiting on you** in the progress sheet (§10), never
  miscounted as unresponsive, and the fix is a human answering the prompt (or
  Attach), not automatic delivery.
- **Fixed during M3:** `claude --bg` colorizes the `backgrounded · <id>` line
  even when stdout is a pipe, so `ClaudeCLI.parseShortId` rejected the hex id
  and every spawn failed with "exited 0 but no short id was found" while the
  session kept running orphaned. ANSI escapes are now stripped before parsing.
- **Resolved: abandoning an epic is built.** `EpicState.abandoned`, present
  since M3's schema, is now reachable: `Board.closeEpic(epicId:as:)` writes
  it, exposed both as the `close_epic` MCP tool (`state: "abandoned"`) and as
  the epic lane header's **Abandon** menu action (§10, §5.2). A decomposition
  that turns out wrong has a real path off the board instead of its tasks
  sitting unfinished forever. See `EpicClosureTests`, `CloseEpicToolTests`,
  `EpicCloseTests`, `EpicLaneTests`.
- **Resolved: the port problem is solved by rewriting config files before
  every resume, plus a persisted preferred port.** `WorkerSupervisor`'s
  private `resume(_:prompt:)` calls `SessionConfigWriter.write` with the
  session's current `serverPort` immediately before every `claude --bg
  --resume`, so a worker's `--settings`/`--mcp-config` paths always point at
  wherever the server is actually listening this launch, regardless of where
  it listened when the worker was spawned. `BoardServer.start(preferredPort:)`
  additionally persists the last bound port to an `appSupportDir`-relative
  `server-port` file and tries that port first on the next app launch, falling
  back to an ephemeral one only if it's taken — so the port is usually stable
  across relaunches, and the resume rewrite covers it when it isn't. See
  `SessionConfigTests.testRewriteOverwritesInPlaceWithNewPort`.
- **Unresolved:** which globally configured MCP servers should be allowlisted
  back into workers past `--strict-mcp-config`. Starting position: none — and
  still none reach a worker in practice. `ProjectSettings.extraMcpServers` and
  a matching Project Settings field exist, and `SessionConfigWriter.write` can
  merge named servers into a worker's `mcpServers` block, but every real
  spawn/resume call site (`WorkerSupervisor`'s `launch` and `resume`,
  `OrchestratorConsole`'s session start) hardcodes `extraMcpServers: nil`, so
  the setting is stored and rendered but never consumed. The policy question
  is still open; only the plumbing for acting on an answer has been started.
- **Unresolved:** whether the `PostToolUse` round trip is cheap enough to leave
  on permanently, or needs a matcher narrowing it to interesting tools.
- **Was an accepted limitation, now readable:** budgets still meter only what
  Agent Board spawned, but account headroom against the 5-hour and weekly caps
  *is* readable programmatically. Claude Code caches it in the
  `cachedUsageUtilization` block of `~/.claude.json`: `utilization.five_hour`
  and `utilization.seven_day`, each carrying a 0-100 `utilization` percentage
  and an RFC3339 `resets_at`, under a `fetchedAtMs` stamp. Sibling keys
  (`seven_day_opus`, `nimbus_quill`, `limits`, and others) are usually null and
  are ignored. `AccountUsageReader` parses it and the sidebar shows both windows
  below "Add Project…". The two numbers answer different questions — a green
  budget with a 90% five-hour bar means the account cap, not the budget, is what
  stops the next spawn.

  **The caveat is staleness.** That block is a cache, not a live reading:
  Claude Code refetches it on its own TTL, and ordinary session traffic does not
  keep it warm (measured below), so it can be hours old. Every reading
  therefore carries its age on screen, and one older than 30 minutes
  (`AccountUsageSnapshot.staleAfter`) is dimmed and labelled `stale` rather than
  presented as current. A block with no `fetchedAtMs` counts as stale —
  freshness has to be proven, not assumed.
- **Verified 2026-09-12: `claude -p "/usage"` does refresh the cache, and only
  when it is already stale.** Three measurements on this machine:

  | cache age before | after `claude -p "/usage"` |
  |---|---|
  | 1265 s | 0.7 s — refetched |
  | 869 s  | fresh — refetched |
  | 21 s / 28 s | unchanged — no-op |

  The run reports `num_turns: 0` and `total_cost_usd: 0`: `/usage` is a local
  command, so it costs no inference. Claude Code applies its own TTL before
  refetching, so an eager call on a fresh cache is simply a wasted process.
  `AccountUsageRefresher` therefore fires only past the 30-minute staleness
  threshold, at most once every 10 minutes, doubling that wait per consecutive
  failure up to 80 minutes. It runs `claude -p`, never `--bg`, so it writes no
  `agent_session` row, is never metered as project spend, and never appears in
  `claude agents --json --all`. It runs detached from the UI, and a failure
  leaves the stale reading and its age on screen rather than blanking the bars.

  **Unexpected, and the reason the fallback earns its place:** ordinary session
  traffic does *not* keep the cache warm. A Claude Code session making API calls
  continuously for 21 minutes left `fetchedAtMs` untouched the whole time — the
  cache moved only when `/usage` forced it. So "workers are running" is not a
  reason to expect a fresh reading.
- **Accepted limitation:** "native Mac app" means native chrome around embedded
  terminals. The agent conversation is Claude Code's TUI, not a SwiftUI rendering
  of it.
- **Partly solved: a child process blocking on stdin.** Observed 2026-09-12 —
  session `b2b3848d` on task `61da923d` ran `cp -i` (the shell's interactive
  alias) inside its worktree and wedged waiting for a y/n that never arrived.
  The prompt belonged to a grandchild process, not to Claude Code, so no
  `Notification` hook fired, `blocked` was never set, and the session looked
  healthy until the idle cap killed it.

  **Solved:** it is now visible. The metering tick flags a `running` worker
  whose `last_activity` has not moved for `caps.stallSeconds` and the
  orchestrator's Blocked section shows it as `stalled`, with a macOS
  notification on the transition (§7). **Still unsolved:** the signal is a
  heuristic, not a report — a worker legitimately inside one very long tool
  call is indistinguishable from a wedged one, so the threshold trades false
  positives against how late the wedge is caught. And there is no way to answer
  a grandchild's prompt from Agent Board: the only remedy is Attach (D15) or
  Stop. A `PreToolUse` matcher that rejected known-interactive commands
  (`cp -i`, `rm -i`, `ssh` without `BatchMode`) would prevent the class rather
  than detect it, but has not been built.
- **Deliberate gap: a standalone `done` task never auto-archives under
  `afterEpicMerge`.** That policy's only trigger is `Board.complete` merging an
  epic (§5.2); a task with no `epic_id` has no merge event to ride, so it
  accumulates on the board until archived by hand with the Task Board button.
  There is intentionally no age fallback for this case — a policy that quietly
  behaves like a different policy (`afterDays`) is worse than one that does
  nothing, per the workers' own reasoning in `bf81e80`. If this project's done
  work is mostly standalone rather than epic-scoped, `afterEpicMerge`'s default
  archives almost nothing automatically; `afterDays` is the policy that fits.
- **Not built: any UI for the `afterDays` sweep's cadence or backlog.** The
  sweep only runs while the app is open (it rides `WorkerSupervisor`'s existing
  metering tick, throttled to once per 5 minutes) and there is no indicator of
  when it last ran or how many tasks are currently past their threshold and
  waiting for the next tick — you only see the effect once a card disappears.
- **Landed late, and what that cost: the Roster screen (§10).** Task
  `53622b86` ("Add the Roster tab and per-project agent selection") showed
  `done` like every other task in the Agent roster epic, but its commit
  `46bd2e6` was never merged into the epic branch, by that task or by any task
  after it. For the length of the epic the roster's data model, spawn path,
  hand-off and agent-review routing all shipped and were exercised by tests
  while there was no way — in the app or over MCP — to create a rostered agent
  or enable one for a project. `46bd2e6` has since been merged rather than
  rebuilt, and the screen is reachable.
  Two things survive that gap. A task reading `done` can mean "committed on a
  branch nobody merged", which only an audit of `git branch --contains` finds,
  not the board. And `46bd2e6` was written against a `MainWindow` that has
  since gained workspaces and At a Glance, so the `Projects`/`Roster` segmented
  switch it specified became a `SidebarSelection.roster` row instead — porting
  a view that sat unmerged costs a rewrite of its host, not just a merge.
- **Settled by reasoning, not by measurement: which `roster_agent` schema to
  keep, and what its deny-list column means.** Two epic tasks independently
  built incompatible schemas for `roster_agent`/`project_roster_agent` (one
  with `ordering REAL`, one with an orderless `opted_in` boolean; one
  documenting `tool_scope` as an allow-list, one treating it as a deny-list in
  working code) before either was merged. The reconciliation
  (commit `3df54d5`) picked a side by reading which behavior was already
  wired — `ReviewPolicy.routing` needs `ordering` to pick a reviewer
  deterministically, and only the deny-list interpretation has a consumer
  (`WorkerSupervisor` appending `disallowed_tools` to `--disallowedTools`) —
  not by running both and observing a difference. No database had ever
  applied either migration, which is what made the choice cheap rather than a
  live-data migration; had one been live, "which one matches production" would
  have been the actual answer, and reasoning about the code would not have
  been enough. See the "two roster_agent schemas" project note for the full
  comparison.
