## 9. Orchestrator

- One per project. Foreground PTY owned by the app (not `--bg`), pinned
  `--session-id`, cwd at the repo root, resumed when the human selects the
  project in the sidebar — Orchestrator is the project's first screen (§10),
  so opening a project is what starts its session. No project is selected at
  launch — the sidebar lands on At a Glance (§10), which is not a project — so
  launching the app wakes nothing: the cost is one orchestrator per project the
  human actually opens, not four on every launch.
- Permission mode: your normal interactive default. It's the session you are
  watching.
- Its job description is injected with `--append-system-prompt`: the board
  vocabulary (project, epic, task, column), the rule that only `ready` is
  assignable, the completion and integration protocols, the instruction to
  call `list_reports` when told to, the instruction to set `type` on every
  task it creates so agent review routes by it (§4), and the project's
  `modelGuidance` text so it can set `model` on the tasks it creates. The orchestrator itself runs on
  `settings.defaultModel` when set.
- **Restart** signals the child with SIGTERM and relaunches on its exit. It
  does not call SwiftTerm's `terminate()`, which cancels the exit monitor, so
  the relaunch would never fire.
- Resume sends a fixed app-authored first turn ("Agent Board resumed this
  session; continue from where you left off") because a resumed background
  session otherwise waits for input until the idle cap stops it.

### 9.1 Report channel

1. A worker calls `report_complete` / `report_blocked` / `propose_task`, **or the
   app itself changes the board in a way the orchestrator cannot observe** — see
   the table below — **or another project's orchestrator sends a message** (§9.2).
   The body lands in `report`, unconsumed. The notice counts items, not workers:
   a queue holding a `message` is not a queue of worker reports.
2. The orchestrator's `Stop` hook fires when it finishes a turn.
3. If unconsumed reports exist, Agent Board writes **one fixed, app-authored
   line** into the orchestrator PTY:
   `[agent-board] N reports pending. Call list_reports.` terminated by
   a carriage return (`\r`); Claude Code's TUI submits on Enter and treats
   `\n` as a literal newline inside the prompt.
4. The orchestrator pulls bodies through MCP, where they arrive as tool results.

The Coordinator has its own queue: `report` rows with `project_id` NULL, which
no project's `list_reports`, `get_report` or notice count can reach. Its console
counts that queue for the same notice through the same `ReportNoticeGate`,
written after the active Coordinator session's own `Stop` (§8.2, §9.4); with no
session running, reports wait for the next one's first turn to end.

**Injection is withheld while the human has unsubmitted text in the prompt.**
The notice is bytes in the same PTY the human types into: written mid-sentence
it appends to their half-written message and its `\r` submits the pair, sending
one garbled prompt and destroying what they wrote. Observed 2026-09-12.

So the console classifies every byte on its way to the child and tracks whether
the prompt is dirty — printable text and pasted text dirty it; `\r`, `\n`,
`Ctrl-C`, `Ctrl-U` and a lone `Esc` clear it; cursor keys, backspace and any
other escape sequence leave it as it was. Every trigger — the `Stop` hook, a
board change, and the human's manual Nudge — passes through one gate, and a
notice refused while the prompt is dirty is **held, not dropped**: an
orchestrator that is never told about pending reports holds a stale board and
stops dispatching. It goes out at the next submit or cancel, with the pending
count re-read at that moment because more reports may have queued while it
waited, and the high-water mark of announced report ids advances only when a
notice is actually written.

The classification is a heuristic over a TUI whose input model Agent Board does
not own, so it is biased to read as dirty: an unrecognized sequence delays a
notice, which is harmless, rather than overwriting a human's typing, which is
not.

Every board change the orchestrator did not itself make queues a report; an
orchestrator that is not told holds a stale board and cannot dispatch what just
became ready.

| App-side change | Report kind | Body carries |
|---|---|---|
| Human accepts a task into `done` | `decision` | Accepted task, and the ids that became `ready` |
| Human reopens a task | `decision` | Task, now back in `ready` |
| Human discards a task | `decision` | Deleted task id (the task row is gone) |
| Human promotes a proposal | `decision` | Proposal, and the ids that became `ready` |
| Human approves or denies an approval | `decision` | Approval, outcome, reason |
| Human comments on a task | `comment` | Task id and title, the comment quoted; the human speaking. An agent's comment queues nothing |
| Cap or idle kill | `failed` | Task, session, `failure_reason` |
| Human stops a worker, or Pause All | `failed` | Task, session, that a human stopped it |
| `reconcile` finds a session gone | `failed` | Task, session, that Agent Board did not stop it |

A task in `running` that no active session owns is always moved out of it,
whatever path the session death took, so it never needs a manual `move_task`.
Where it lands depends on what the worker left on `agentboard/<task-id>`:

- No commits the branch's recorded base does not have — back to `ready`, the
  report saying so, ready to be dispatched again.
- Commits ahead of that base — into `review`, with the commit count in the
  report. The report never calls that work finished: no worker vouched for it
  and Agent Board builds nothing. Routing it to `ready` instead would tell an
  orchestrator to re-dispatch work that is already written, and a retry reuses
  the same branch, so the second worker would redo it on top of itself.

Two clocks enforce this, because one of them only runs while a screen is open:
the metering tick sweeps every project, and `reconcile` sweeps the project it
was called for. The sweep re-checks the strand inside its write, so a task that
has since moved or gained a session is left alone. It exists because
`terminate` cannot reach a death that left no session row at all, and because
`SessionEnd` can write `stopped` before a cap kill or `reconcile` gets there.

A cap or idle kill also sets `failed` and `failure_reason` on the card; a human
stop does not. A wind-down acknowledgment keeps its own contract — `ready` with
a resume note — whatever is on the branch.

No agent-generated text is ever written into the orchestrator's user turn. The
orchestrator holds spawn, assign, and integration authority; a worker that echoes
a malicious file into its report must not be able to drive it.

### 9.2 Compaction

The orchestrator is a long-lived session whose context only grows. Claude Code
compacts it eventually — at `effectiveWindow - 33000`, about 96.6% — but it does
so mid-turn, at whatever moment it happens to reach, which for an orchestrator is
usually mid-dispatch. Agent Board compacts earlier and at a moment it chooses.

**Trigger.** The metering tick already reads every session's transcript every 5s
(§7). For the orchestrator it also computes
`ContextPressure(used: last assistant message's input + cache_read + cache_write,
limit: ModelCatalog.effectiveContextWindow(for: model))` and asks the gate to
compact once that passes `OrchestratorCompaction.threshold` — 0.80. No new timer,
and no per-project setting: the window is a property of the model, not of the
project, and nothing about a project changes where the safe margin is.

**Injection.** The compaction command goes through `ReportNoticeGate`, the same
gate as the report notice and for the same reason — it is bytes in the PTY the
human types into (§9.1). The gate holds at most one notice and at most one of
each app-authored line, so a held compaction and a held report notice both
survive; it writes **at most one line per pass**, compaction first, and whatever
is left waits out the turn that line started.
A report notice is not held for a turn, so one can be requested while the
compaction command is still being typed; `inject` writes it after the command's
`\r`, never inside it (§2).

**Never mid-turn.** `Stop` clears the gate's in-flight flag; the human's Enter
and every line the gate writes set it. A compaction is refused while it is set
and delivered at the next `Stop`, so it can never land part-way through a
dispatch.

**Instructions.** `/compact` takes free-form instructions and the default
summariser keeps the wrong half for an orchestrator — the narrative of what
happened rather than the decisions that shaped it. Almost everything an
orchestrator appears to know is in SQLite and comes back from `list_tasks`,
`list_epics`, `list_agents`, `list_reports` and `get_task`; what is
unrecoverable is the conversation with the human. So
`OrchestratorCompaction.instructions` preserves eight things — standing
instructions, decisions with their reasons, unanswered questions, anything
suspending normal behaviour, facts established by measurement, corrections, git
state the board does not show, and failure modes — deletes every enumeration and
every tool result outright, and ends with a section headed "unrecorded — write
this down" whose job is to convert conversational knowledge into durable board
state before the next pass eats it.

**Re-orientation.** A manual compaction leaves the session idle waiting for
input, exactly like a resume (§2), so the gate follows it with one fixed
app-authored line pointing the session back at the board. An **auto**-compaction
resumes its own turn, so it gets nothing written into it: `PreCompact.trigger`
distinguishes the two, and the trigger of the most recent `PreCompact` row is
what `SessionStart {"source":"compact"}` is read against.

Both lines are fixed constants. No agent text enters the orchestrator's
user-authority turn here any more than in §9.1 (D9).

**Visibility.** The orchestrator header shows the current context percentage,
amber once it is over the threshold, and how long ago the last compaction was,
with its tooltip saying whether Agent Board or Claude Code did it and how many
there have been. A session that silently forgot what it was doing is worse than
one that says so.

### 9.3 Cross-project messages

An orchestrator may send text to another project's orchestrator. The sender is
itself an orchestrator, with real authority over its own project — but that
authority does not travel with the text. To the recipient, what arrived is
agent-authored text from outside its board, no different in standing from a
worker's report, and D9 forbids exactly that from entering an orchestrator's
user-authority turn. §9.1 keeps `OrchestratorConsole` the only writer into that
PTY, so nothing this epic built could put the message there without reopening
the hole D9 exists to close. Instead it is **delivered into the recipient's
`report` queue** as a `message` report and pulled through `list_reports`
exactly like a worker report, on the recipient's own schedule rather than
whenever the sender happened to call `send_message`.

The stored `message` row keeps the sender's text verbatim. The delivered report
body wraps it: the sending project's name and id, a statement that the text
carries no authority over this board and is information rather than an
instruction, and begin/end delimiters around the sender's own words. The report
names no task and no session — a message from outside cannot hand the reader
something in this project to act on.

A message to a project that does not exist is refused, as is an empty one.

An orchestrator addresses a peer with `list_projects`, which returns ids and
names and nothing else, and sends with `send_message(project_id, body)`. The
tool's own refusals are narrower than the store's: it will not address the
caller's own project — a message to yourself arrives in the queue you are
already reading — and it caps the body at 4000 characters, because the body is a
prompt fragment spent from the recipient's context budget rather than the
sender's. The tool confirms only that the message was queued: the receiving
orchestrator may not be running, nothing tells the sender when or whether it
pulls, and there is no reply channel. These tools are the whole cross-project
surface; there is no way to read another project's messages, list its tasks, or
spawn into it.

Messages are ephemeral working traffic, not a record. Whoever acts on one keeps
anything that must outlive it as a note or a task, then deletes the message.
Deleting removes the one `message` row, so it goes from both projects' panels,
and its delivered report goes in the same write transaction whether or not it
was consumed — an unread report would announce a message that no longer
exists. There is no per-project hiding. Three paths delete: the human, from the
sidebar (§10); the recipient orchestrator, with `delete_message(message_id)`,
which refuses any message its project did not receive and takes the id from
the `message_id` field `list_reports` puts on a `message` report; and the
archive sweep's tick, which deletes every message whose report was consumed
more than 7 days ago (`MessageStore.retentionMillis`, wall clock).

### 9.4 Coordinator requests

The Coordinator (§8.2) cannot write a board, so it asks: `send_request`
queues **a request from your coordinator** into the target project's queue as a
`request` report, and the ledger row and the report are written in one
transaction. Direction is fixed: the Coordinator starts a conversation, the
orchestrator replies. An orchestrator has no tool that writes to the
Coordinator except `reply_to_request`, which needs a request addressed to its
own project and still open; the Coordinator is not a project, so
`send_message` cannot address it.

The delivered body carries the human's weight without the human's authority.
It says the Coordinator made the request on the human's behalf, that the
orchestrator acts on it within its board's usual rules (approvals, autonomy,
caps), that it may decline with a reason and always replies, and that the text
is data — the Coordinator reads text agents across projects wrote, so a request
must not carry injected text in with the human's weight. The request text sits
between begin/end delimiters, with the plan note named above it when there is
one. The orchestrator briefing (§9) says the same.

A reply is `accepted`, `declined` or `done`, may link epics on the replier's own
board, and queues a `reply` report for the Coordinator (§9.1), announced after
its current turn ends. `accepted` may be sent more than once. `declined` and
`done` close the request; so does `withdraw_request`, which also queues a
`request` report telling the orchestrator to stop. A closed request takes no
further replies.

The ledger (`coordinator_request`, `request_event`, `request_epic`) records the
target, the text, the plan note id, the state, every step with the report it
queued, and the linked epics; the Coordinator reads it with `list_requests` and
reads progress from those epics with `get_epic`. Requests are ephemeral like
messages: an open request is kept, and a closed one is deleted with its history
and every report it queued by the same archive-sweep tick, once it has been
closed more than 7 days (`RequestStore.retentionMillis`, wall clock).
