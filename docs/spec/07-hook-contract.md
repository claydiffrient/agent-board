## 7. Hook contract

Generated into each managed session's `--settings`. All post to
`http://127.0.0.1:<port>/hooks?token=<session token>`.

| Event | Agent Board's reaction |
|---|---|
| `SessionStart` | Mark `agent_session.state = running`, unless its task is in `done`, or in `ready` with no other session on it; a worker row already `failed` or `completed` is not revived, and the supervisor stops its process again (§8.5); record transcript path |
| `PreToolUse` (matcher `Bash`) | Deny `git push`, `gh pr create`, `gh pr merge`; append an `error` progress row (§8) |
| `PostToolUse` | Bump `last_activity`; clear `blocked`; append a `tool` progress row; reply with a worker's post-compaction brief or queued human comments as `additionalContext` |
| `Notification` | Set `blocked` + reason on the task and session; the task appears in the orchestrator's **Blocked** section (§10) and raises the project's attention signal, which posts the banner |
| `Stop` | Mark session idle. **On the orchestrator, this is the trigger for the report notice** (§9) |
| `SessionEnd` | Mark stopped/completed; reconcile final spend from the transcript |
| `WorktreeRemove` | Chain to the user's existing hook, then clear the worktree row |

The handler must be synchronous and trivial — `PostToolUse` fires on every tool
call, and a slow handler is felt directly as agent latency. Anything expensive
goes on a queue. `PreToolUse` is matched to `Bash` alone so the round trip is
not paid on every tool call.

A `PreToolUse` reply denies by returning both shapes in one body — the current
`hookSpecificOutput.permissionDecision`/`permissionDecisionReason` pair and the
legacy `decision: "block"`/`reason` pair — so the block lands whichever the
installed CLI reads. Every other event replies `{}`.

Spend metering tails the session's JSONL transcript rather than relying on
hooks, since hooks do not carry `usage`.

**Human comments reach a running session.** A `--bg` session cannot be written
to, so a human comment is queued in `comment_delivery` for every live worker and
reviewer session on its task, in the same transaction that writes it. The
session's next `PostToolUse` replies with the queue as
`hookSpecificOutput.additionalContext` and no `decision` key: a lead saying the
human commented on your task, then each comment fenced as in the opening prompt
(§3.1 step 6), labelled from the human with its UTC time. Comments go oldest
first and together, within Claude Code's 10,000-character cap on one hook's
text; whatever does not fit waits for the next tool call, and a single comment
too long to fit is cut short with a pointer to `get_my_task`. Each is delivered
once, and a `status` progress row records it. A session queued during setup
carries its queue to the session id Claude issues, and a `/clear` fork carries
its queue to the new id: a `SessionEnd` with `reason: "clear"` keeps it for the
fork to adopt (§2). Any other `SessionEnd` drops the session's queue; the
comment stays on the task for the next spawn's prompt. A post-compaction brief
already carries the thread, so it drops the queue too.
Agents' comments are never queued. The queue is a table rather than memory
because a worker outlives an Agent Board relaunch, so undelivered comments
survive one.

The blocking `Notification` types are `permission_prompt`, `agent_needs_input`,
and anything prefixed `elicitation`. Each sets `task.blocked` with the
notification message as `blocked_reason`, moves the session to `blocked`, and
files a `blocked` report for the orchestrator. The banner comes from the
attention signal below rather than from the hook, so the badge and the banner
cannot disagree; a session with no task cannot raise that signal, and only that
case still posts its own "Agent needs input" banner. The next `PostToolUse`
clears `blocked` again, so a worker that was answered leaves the section without
anyone pressing anything.

**Attention banners.** A pending approval and a blocked worker each stop work
outright, so both notify. Both are read from `ProjectAttentionStore` — the same
per-project signal behind the sidebar badge — on the metering tick, and
`AttentionNotifier` posts each one only on the transition into that condition,
keyed by project and reason. A queue nobody has answered does not banner every
5s; a growing queue is a bigger badge, not a second banner. The key clears when
the condition clears, so the same condition occurring again notifies again, and
a relaunch re-announces whatever is still waiting. Stranded reports and an
unacknowledged shutdown badge without interrupting. Nothing notifies for the
project the human has open while Agent Board is frontmost. Every banner Agent
Board raises names its project.

**Stall detection.** Some prompts fire no hook at all — a grandchild process
reading stdin (`cp -i`, `ssh` asking for a passphrase) belongs to neither
Claude Code nor Agent Board, so nothing is posted and `last_activity` simply
stops advancing. The metering tick (already running every 5s, already reading
`last_activity`) flags a `running` worker whose activity clock has not moved
for `caps.stallSeconds` — default 120s, deliberately below the 300s idle cap so
it surfaces before the cap kills it. A worker inside a tool call that has
started and not returned is excused for 6 × `caps.stallSeconds` (720s at the
default), because `PostToolUse` fires only on return and one command can
legitimately run for minutes (§8); past that the command itself is what looks
wedged and the stall is raised. A stall is a suspicion, not a reported
state: nothing is written to the task, nothing is killed, one macOS
notification ("Worker may be stuck") is raised on the transition, and the
sidebar shows the row until activity resumes or the human acts.
