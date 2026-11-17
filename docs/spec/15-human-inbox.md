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
| Task held in review for a person | `task.review_entered_at`, with `task.human_review_reason` | `Board.leaveReviewToPerson`, from `humanReview` routing and from a reviewer that will not take the task |
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
| `review_finding` | `overrule` (note), `uphold`; the subject is `task_id` plus `finding_ref`, `"<round>:<index>"` |

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
