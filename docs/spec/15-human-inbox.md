## 15. Human inbox and rulings

Agents and the board put questions to the human: a blocked worker, a pending
approval, a task waiting in review for a person, a pull request decision, a
parked watch. The human's answer to one asking is a **ruling**: a row in the
`ruling` table (§4), scoped to one subject, recording what was asked, which
verdict was given, and the human's note.

A ruling has three properties no other table here has together:

- **Only the human writes one.** `RulingStore.record` is the only writer, and
  only the app's UI calls it. No token scope — worker, reviewer, orchestrator,
  Coordinator, triager, verifier — has a tool that writes a ruling, and no MCP
  handler in `AgentBoardBridge` calls `RulingStore.record`. A terminal path is
  ruled out too: it would need a credential on disk that any worker's shell
  could read and replay.
- **It is append-only.** The `ruling_immutable` trigger aborts any UPDATE.
  Changing one's mind is a new row whose `supersedes` names the old one, so
  the history stays whole. Nothing deletes a ruling except the cascade from
  deleting its subject or its project; the archive sweep never touches the
  table.
- **It lives apart from every per-run column.** Triage verdicts, approaches,
  block reasons, parked reasons and review findings are overwritten by later
  runs. A ruling is in its own table, so no later run can overwrite it.

Answering is not approving. A ruling never pushes, opens or edits a pull
request, merges, integrates, accepts, lands, spawns or resumes a worker,
grants an approval, posts to GitHub, labels, resumes a watch, or closes
anything. Those stay separate actions with their own buttons.

### 15.1 Question episodes

A ruling answers one asking, not its subject forever. Each surface that asks
the human carries a stamp for its current asking, and a ruling records the
stamp it answered in `question_at`:

| Surface | Episode stamp | Written by |
|---|---|---|
| Blocked task | `task.blocked_at` | `TaskStore.setBlocked` on every block, through `Board.block` and the Notification hook's block; strictly later than the previous stamp, and kept on unblock |
| Task held in review for a person | `task.review_entered_at`, with `task.human_review_reason` | `TaskStore.enterHumanReview`, from `humanReview` routing (including protected paths and a failed completion check), a reviewer that will not take the task, and the agent review round cap |
| Parked PR watch | `pr_watch.parked_at` | `PRWatch.park`, which every park site calls: the round cap, a stacked PR, a fork, failed triages, a failed check, a refused publish |
| Approval | the approval's id | One row per asking already |
| PR decision item | `pr_item.decision_notified_at`, else the item's `created_at` | Already present |

A question is answered while a ruling exists whose `question_at` is at or
after the current stamp. When the worker blocks again, `blocked_at` advances,
so the new block is a new question and the earlier ruling stays beside it.

### 15.2 Verdicts and subjects

`RulingStore.record` refuses a verdict its subject does not take, and refuses
an empty note for every verdict marked *note*:

| Subject | Verdicts |
|---|---|
| `task` | `proceed`, `instead` (note), `hold` (note), `reopen` (note) |
| `approval` | `deny` (note) |
| `pr_item` | `choose` (the option label in `choice`), `reply`, `dismiss` (note) |
| `pr_watch` | `keep_parked` |
| `review_finding` | `overrule` (note), `uphold`; the subject is `task_id` plus `finding_ref`, `"<round>:<n>"`, where `n` is the finding's 1-based number as reviewers see it (`ReviewRound.findingRef`) |

`choice` is set for `choose` and for nothing else. A note is at most 10,000
characters. `dismiss` is not offered as an answer; it holds the human's PR item
dismissals that §15.4 carried over.

### 15.3 Standing rulings

A ruling is **standing** while no later ruling supersedes it.
`RulingStore.standing(subject)` returns a subject's standing rulings, newest
first; a subject can carry several, one per episode, and every consumer reads
them all. `RulingStore.history(subject)` returns every ruling on the subject,
superseded or not, newest first. A ruling may supersede only an earlier ruling
on the same subject that nothing has superseded yet.

### 15.4 Carried-over answers

The `ruling` migration copies the human answers that already existed into
rulings on their PR item:

- A `pr_item.decision_answer` that names one of the item's options becomes
  `choose` with that label; any other answer becomes `reply` with the text as
  its note. `question` is the item's `decision_question`.
- A dismissal with `dismissed_by = 'human'` becomes `dismiss` with
  `dismiss_reason` as its note. A dismissal an orchestrator requested is not
  carried over: its reason is the orchestrator's text, not the human's.

Deny reasons from before this section existed lived only in `decision`
reports, which have all been consumed, so they cannot be recovered.

### 15.5 Membership

`InboxStore` derives the inbox from the database alone, across projects or
for one: each surface's open-question predicate, minus every row a ruling has
answered for the current episode (§15.1). `observe(projectId:)` and
`items(projectId:)` return the rows, oldest asking first; `count` and
`observeCount` count those same rows, so the badge and the page cannot
disagree.

| Row | Waiting while | Answered by a ruling with |
|---|---|---|
| Approval | `resolved_at IS NULL` | any ruling on the approval |
| Blocked task | `task.blocked = 1`, from `report_blocked` or a Claude Code prompt | `question_at >= blocked_at` |
| Human review | in `review` with no `reviewer_agent_id` | `question_at >= review_entered_at` |
| Reviewer stopped | in `review` under a rostered reviewer whose session is the task's newest and is idle or ended | `question_at >=` that session's `started_at` |
| Proposal | in `proposed` while the project's autonomy is off | — (Promote or Dismiss) |
| PR decision | open item with verdict `decision` on a watch not merged, closed, stopped or paused, follow-through on | `question_at >= COALESCE(decision_notified_at, created_at)` |
| Parked watch | `state = parked`, follow-through on | `question_at >= parked_at` |

A row stays out while its ruling stands for the episode: a `hold` takes a
blocked task out while `task.blocked` stays 1, and the next block advances
`blocked_at` and brings it back. A missing stamp, on a row from before §15.1
existed, reads as 0.

Out, by construction: a task in `review` while its rostered reviewer is
working, Coordinator requests (they wait on an orchestrator), Ready to verify,
and the machine conditions — stalled workers, overdue shutdowns, stranded
reports, an unavailable poll, takeover failures, unlanded `done` tasks — which
each already raise the attention signal.

### 15.6 Enforcement

The board reads standing rulings inside the same write that would act on an
agent's request, so a ruling holds even against an orchestrator that misreads
it. Each refusal quotes the ruling: its verdict, when it was given, and the
human's note.

- **Deny.** Pending Approvals' Deny… needs a reason, and `Board.denyApproval`
  resolves the approval and records a `deny` ruling on it, with the reason as
  its note, in one transaction. A request identical to a denied one is then
  refused:
  - `push_branch` and `open_pull_request` (`Board.requestPublish`): the same
    approval kind, local branch and head commit: the `headOid` every publish
    request carries (§6), which a grant also checks the branch against
    (§4). A row from before `headOid` existed has none and matches nothing.
    The same branch at a new commit is a new request and creates an approval
    as before.
  - `spawn_worker` and `assign_to_agent` (`Board.requestSpawn`): a spawn of
    the same task, until the task changes at or after the ruling's
    `answered_at`. A change is an edit to its title, body, acceptance, model,
    effort or dependencies, a human comment on it, or a reopen; each moves
    `task.changed_at`, which no column move, block or landing touches.
  - `request_integration` (`Board.requestIntegration`): the same epic, until
    a task in the epic is accepted, closed or added at or after the ruling,
    or the epic branch's tip differs from the one the denied request
    recorded. The orchestrator's request records the tip in the approval's
    payload; a request without one cannot lift the deny by tip.
  - A deny stands only for the request as it was when denied, so a spawn or
    integration deny lapses as above rather than being withdrawn; there is no
    `withdraw` verdict. The refusal names the ruling's id and what lifts it.
    The human can still start the task or integrate from the board at any
    time; only the orchestrator's request is refused.
- **Hold.** A `hold` is in force while the task is blocked and the ruling's
  `question_at` is at or after `task.blocked_at`, so it covers the block it
  answered and lapses when the worker blocks again. While it is in force:
  - `Board.requestSpawn` refuses the task, whatever the autonomy setting.
  - `WorkerSupervisor.resume` refuses every resume of a session on the task
    except the shutdown wind-down (§8.1), which tells the worker to stop.
  - `StoreHookSink` does not clear the block on `PostToolUse`, so the task
    stays `blocked = 1` while the worker keeps making tool calls.
- **Reopen.** The inbox's Reopen calls `Board.reopen` with the human's note,
  which records a `reopen` ruling on the task, answering the current
  `review_entered_at`, before the task goes back to `ready`. The `decision`
  report quotes it. The board's existing Reopen buttons record nothing.
- **Keep parked.** `resume_pr_watch` is refused while a `keep_parked` ruling
  answers the watch's current `parked_at`. The human's own Resume on the Pull
  Requests page, and granting a resume approval, are unaffected: both are the
  human acting.
- **Worker prompts.** The spawn prompt (`OpeningPrompt.compose`) and the
  resume prompt open with a "Your human's rulings on this task" section
  listing the task's standing rulings, newest first, each with the question
  it answered. It sits above the task body and the comment thread, and says a
  ruling outranks the worker's own judgment, the task body, any comment and
  any reviewer finding.

### 15.7 Overruled review findings

A person can overrule a finding an agent reviewer raised in a `review_round`
(§5.1), or uphold it. A finding is overruled while the newest standing ruling
on it is `overrule`; an `uphold` written after it, superseding or not, puts the
finding back. `ReviewRound.overruled` reads this for one round, and the board
enforces it in code:

- `ReviewRound.checkGrades` drops overruled findings from the set the next
  round must grade, and refuses a grade that names one.
- `ReviewPrompt` lists them in the re-review section as settled, each with the
  person's note.
- `Board.reviewReopen` refuses a reopen whose every finding cites only
  overruled findings of the previous round ("finding 2"), and the refusal says
  a person overruled them. A reopen with any finding that cites nothing, or
  cites a finding still open, goes through.

An overrule moves nothing: the task stays where it is, and accepting it is
still a separate action.
