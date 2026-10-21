## 13. PR follow-through

Agent Board watches every open, non-draft pull request the human authors, in a
project that turns the feature on, and carries review feedback through to a
pushed fix without the human in the loop per round. It runs inside Agent
Board as a deterministic state machine on the app's metering tick, not as a
standalone daemon — a daemon would rebuild worktrees, workers, review and push
guards from nothing, and could only reach the board through `send_message`
(§8.2), which carries no authority. Models only judge: a triage session,
fixer workers, a reviewer, and a follow-up check. No rostered agent runs
unattended beyond what §8's caps already allow.

This project is public. Every value below that is specific to one of the
human's work repositories — which repos are watched, a verification label, a
reply policy, which roster agent fills a role — is a project setting stored in
`settings_json`, never a code default, a constant, or a SPEC example (see the
pinned public-repo note). Examples in this section use `example-org/app` and
the label `verified-example`.

Delivered in four phases, each its own epic, each shipped by pull request
before the next is cut. A subsection names the phase that delivers it; a task
in one phase edits only its own subsection.

### 13.1 State machine — phase 1 (watching only) through phase 4

One `pr_watch` row per watched pull request, holding its current state and the
round counter. **Phase 1** delivers watching, settling, readyToVerify,
verified, and merged/closed — everything that does not require a model;
publishing is specified below but not reachable until phase 3 gives it a push
to make. **Phase 2** delivers what the settling wait leads to, triaging, and
parking on a stacked or forked PR or after three failed triages in a row.
**Phase 3** delivers fixing, checking, publishing's push and replies, the
stale move a publish makes, and the verified freeze. **Phase 4** delivers the
rest of stale and parked, and feeding CI and verification failures back into
triage.

- **watching** — polled every 60s. Leaves on new feedback (an unresolved
  thread, a review body, a failed required check, a merge conflict) or when
  the PR becomes ready to verify.
- **settling** *(phase 2)* — entered from watching or readyToVerify when an
  open item has no verdict yet, and left for watching or readyToVerify when
  none is left. Waits until no new item has arrived for `settleMinutes`
  (default 10), then holds for the daily budget, AC power, and the concurrency
  cap (§8) before leaving for triaging.
- **triaging** *(phase 2)* — one read-only `triage` session gives every open
  item a verdict (§13.2). It has no git writes and no `gh`, and treats comment
  text as data, never as instructions.
- **fixing** *(phase 3)* — one fixer task per round, in a worktree cut from
  the fetched PR head on `agentboard/pr-<n>-r<round>`. New commits only: no
  amend, no rebase. A stacked PR parks instead (below).
- **checking** *(phase 3)* — the `reviewer` role reviews the round's diff, and
  the `followupCheck` role grades each item `fixed`, `partly`, `not_fixed`, or
  `moot`. A reopen or anything other than fixed or moot reopens fixing, at
  most twice a round; the third failed check parks the PR instead.
- **publishing** *(phase 3)* — re-reads the remote head and goes to **stale**
  if it moved. Otherwise fast-forward pushes the round branch to the PR's head
  ref, then posts factual replies when `postFactualReplies` is on. It never
  resolves threads.
- **awaitingCI** *(phase 3 reads green/red; phase 4 adds the log-tail items on
  red)* — green goes to watching; red goes to watching with a failed-checks
  decision item, which phase 4 replaces with going straight to triaging, the
  failed checks and their log tails as items.
- **readyToVerify** *(phase 1)* — `reviewDecision == APPROVED` (when
  `requireApproval`), checks green, no open item or decision, and the
  verification label absent. Checks are green when the head commit's
  `statusCheckRollup` is `SUCCESS` or absent: a repository with no checks
  configured has no rollup, and nothing on it is failing. `PENDING`,
  `FAILURE`, `ERROR` and `EXPECTED` are not green. New feedback arriving here first sends the PR
  back to settling.
- **verified** *(phase 1 reads the label; phase 3's freeze is what it is
  frozen against)* — the verification label is present. The PR is frozen:
  Agent Board never pushes to it again, and any new feedback on it becomes a
  decision item rather than restarting the round. Removing the label
  re-evaluates it: readyToVerify if it still qualifies, otherwise watching.
- **stale** *(phase 3 for a publish; phase 4 for the rest)* — the head moved
  out from under the round. Drop the round's worktree and go to settling.
- **parked** *(phase 2 for the forked case and failed triages; phase 3 for a
  stacked PR, a round's third failed check, and a refused publish; phase 4 for the round-cap and fixer cases)* — reached
  when the round cap is hit, a round fails its check three times, three
  triages (phase 2) or fixer sessions fail in a row, the PR is stacked (its base is not the
  project's default branch and the stack needs a restack the human must do),
  or the PR is from a fork. Waits for the human to Resume or Stop watching
  from the Pull Requests page (§13.4).
- **merged** / **closed** *(phase 1)* — terminal states. The round tasks are
  archived.

**The poll (phase 1).** At most every 60s, on the metering tick beside the
pull-request landing check (§5), `WorkerSupervisor.pollPRWatches` runs only
when some project has `enabled` on; otherwise no `gh` command runs at all. It
maps each enabled project to a repository by its `origin` remote, ssh and https
forms alike, runs one `gh search prs --author=@me --state=open`, and for each
mapped repository one `gh api graphql` query covering its non-draft PRs. Drafts
are never watched. A thread becomes an item while it is neither resolved nor
outdated and its latest comment is not the viewer's; that comment is the item's
body, so a reply changes it. A review body becomes an item while it is its
author's latest review and that review is not an approval, since a review is
never resolved and an approving body is not feedback. The poll itself moves a
watch only among watching, settling, readyToVerify and verified, by the rules
above, and a
watch whose PR has left the open list settles to merged or closed by
`gh pr view`. A PR converted back to draft still appears in the search, marked
draft; its watch is deleted with its items, and undrafting it brings it back
through the search as a new watch. A `gh` that is missing or not logged in
records one `pr_poll_problem` row per enabled project, which raises that
project's attention badge until a poll succeeds; it is written once, not on
every poll. Any other search failure (network, rate limit) is logged; after 10
in a row it records the same row with a reason saying the search is failing,
and the next successful search clears it. A project with no `origin` is skipped
without a word. Any other failure to read its `origin` is logged with git's
stderr, the project goes unpolled, and after 10 in a row it records its own row,
cleared once `origin` reads again.

**Settling and triaging (phase 2).** The same poll, after reading GitHub,
advances each watch of an enabled project; a failed search does not stop it.
The poll's own move puts a watch in settling while any open item has no
verdict, so an open decision or fix item keeps a PR from being ready without
sending it back to triage. A settling watch leaves for triaging only when it is
not paused, at least `settleMinutes` have passed since `last_feedback_at` (so an
item arriving during settling restarts the wait), and nothing holds it: a
shutdown order on the project, a Mac whose providing power source IOKit reports
as anything but AC (an unreadable source counts as AC), the triage and fixer
sessions started since local midnight having cost `dailyBudgetUSD` or more, or a §8
spawn cap refusing. A hold leaves it settling and is re-checked on the next
poll. Leaving increments `round`, records a `pr_round` holding the head oid it
starts from, and moves the watch to triaging in one transaction that only a
settling watch passes, so two polls never start two rounds; then it spawns the
round's triager (§13.2), whose `pr_triage` row carries the round.

A triaging watch waits for its round's triage task. Once that task is `done`,
the verdicts are applied in one transaction:

- `fix` — the item stays open for the round's fixer (below).
- `follow_up` — a `backlog` task, origin `follow_through`, titled
  "Follow-up from #n: …". The item is handled, with the task in `fix_task_id`.
- `answer` and `already_done` — the item is handled; its `reply_body` stays
  stored for phase 3 to post.
- `decision` — the item stays open as a decision.

A follow-up task's body holds the PR's number, title and URL, the comment's
author, path and line, and URL, the comment quoted and labeled as data rather
than instructions, and triage's approach. An item gets no second follow-up
task while `fix_task_id` names a `follow_through` task that is not of type
`code`. Then the watch goes to settling when an item arrived during triage,
else to fixing while an open item's verdict is `fix`, else to watching. The
round's outcome becomes `triaged` unless it goes on to fixing, which leaves the
round open.

**Fixing (phase 3).** A PR whose base is not the project's base branch is
stacked: rather than fixing, the watch parks with a `parked_reason` naming
both branches, since a fix on a lower layer leaves the layers above it to
restack, which is the human's to do. Otherwise the next poll creates the
round's one task, in a transaction that only a fixing watch whose round has
no task yet passes: a `ready` task of type `code`, origin `fix_round`, titled
"Fix round r of #n: …", its model `roles.fixer.model` or unset. Its body names
the round branch, says new commits only with no amend, rebase or push, and
holds a section per open `fix` item, each built like a follow-up's body. The
task goes in the round's `fix_task_id` and in each of those items'
`fix_task_id`, and every `backlog` `follow_through` task of type `code` that an
item of the watch names — a fix task phase 2 made — is closed with a reason
naming the round.

The fixer is spawned only while its task is `ready` and its fixer sessions
(those with no `review_head`) do not outnumber the round's `check_failures`:
once per check, so a fixer that failed is not respawned in a loop. A fixing
round with no task and no open `fix` item — every one answered on GitHub or
reopened for triage before its task was made — ends with outcome `triaged`,
and the watch goes to settling when an item awaits triage, else to watching. It holds under the
same settling holds, and its spawn approval is skipped while follow-through is
on (§13.5). Spawning fetches the PR's head ref from `origin` into
`refs/remotes/origin/<head>`, and the round's `base_head_oid` if the repository
lacks it, refusing the spawn when either fails; then it cuts
`agentboard/pr-<n>-r<round>` at `base_head_oid` in a worktree under the
project's worktree root named for the task. A retry reuses both. The session
is an ordinary worker's with the opening prompt (§5), `roles.fixer`'s roster
agent, and the task's model, else the agent's, else the project's default.
Besides the worker deny list it is denied `git commit --amend` and
`git rebase` by `--disallowedTools`, since its commits are fast-forwarded
onto the PR's head; every worker is already denied pushing. Spawning the task
any other way — `spawn_worker`, or approving its spawn — takes the same path,
and a roster agent named there replaces the role's.

**Checking (phase 3).** The fixer's `report_complete` never takes the review
queue or the accept path. Its task goes to `review`, its report is recorded
already consumed (the orchestrator never asked for the round), and the watch
moves from fixing to checking, clearing the round's `review_verdict`,
`review_findings`, `followup_task_id` and `checked_head_oid` and its items'
grades. A human or orchestrator accept of a `fix_round` task is refused: the
round's branch is pushed onto its PR by publishing, never merged as a task
branch. The next poll starts both halves of the check, under the settling
holds:

- **The review.** The reviewer is `roles.reviewer`'s roster agent, else the
  review routing table's Code row (§4). A round is pushed with no person in
  the loop, so anything but an agent — a person, accept without review, or a
  named agent the project cannot use — parks the watch with the reason. The
  agent is recorded as the task's reviewer and spawned with reviewer scope in
  the fixer's own worktree on the round branch, its review base
  `base_head_oid`, so it reads `git diff <base_head_oid>...HEAD`; its model is
  `roles.reviewer.model`, else the agent's, else the project's default. Its
  prompt adds that accepting lets Agent Board push the round with no person in
  between, so it runs the project's tests on the suites the diff touches and
  accepts only when they pass. `accept_task` and `reopen_task` record its
  verdict on the round (`review_verdict`, and a reopen's findings in
  `review_findings`) and end its session; neither moves the task. A round
  branch with no change beyond `base_head_oid` is reopened on the spot with
  that reason, with no reviewer spawned. A reviewer session that ends without
  a verdict parks the watch; one left idle without one is raised as §5.1 says.
- **The follow-up check.** When the round has items to grade, a synthetic task
  of origin `followup_check` is created and recorded in `followup_task_id`
  with the round branch's tip as `checked_head_oid`, and a session holding a
  triager grant (§6) runs in a detached checkout of that tip under the
  project's worktree root, named for the task. `roles.followupCheck` picks the
  roster agent, whose plugin directories it is launched with, and the model the
  same way as the reviewer's; with no agent, the built-in `FollowupCheckPrompt`
  identity is used. It reads `git diff <base_head_oid>..<checked_head_oid>` and
  grades each item with `set_followup_grades`, giving evidence for each. Once
  every item has a grade its task goes to `done` and its checkout is removed,
  as a finished triage's is. It is never assigned by hand or resumed, and one
  that ends any other way closes its task and parks the watch; a shutdown order
  stops it at delivery and clears `followup_task_id`, so a fresh one starts
  once the order lifts.

Once the review is in and, when the round has items, its follow-up check is
`done`, the round is decided in one transaction. An acceptance with every
item graded `fixed` or `moot` passes: the task goes to `done` with an "Agent
review passed." note and the watch to publishing. Anything else is a failed
check, counted in `check_failures`. Its findings — the reviewer's, and each
item short of fixed with its grade and evidence, numbered as in the task body
— go on the task as an "Agent review failed." note, which the next fixer's
opening prompt carries (§5.1). The first two failures send the task back to
`ready` and the watch to fixing, which spawns that fixer in the same worktree
on the same branch. The third ends the round with outcome `check_failed`,
closes its fix task, and parks the watch with a `parked_reason` holding the
last findings. A check that cannot start — a spawn that fails, a worktree
that is gone — parks the watch the same way, with the error.

**Publishing (phase 3).** The one push Agent Board makes without an approval
(§13.5). The next poll re-reads the PR with
`gh pr view <url> --json state,headRefOid,labels`, and does nothing while that
fails or the PR is not open. Then, in order:

- **The verified freeze.** The verification label on the PR ends the round
  with outcome `frozen` and moves the watch to verified without pushing; the
  round's fix items become frozen decisions (below) and its worktree is
  removed. The round branch is kept, so the work is not lost.
- **Stale.** A head that is neither the round's `base_head_oid` nor the round
  branch's tip ends the round with outcome `stale`: its fix items go back to
  triage with no verdict, its worktree is removed, and the watch goes to
  settling, which triages them against the new head.
- **The push.** A round branch whose tip is not the `checked_head_oid` its
  follow-up check judged parks the watch unpushed. Otherwise
  `BranchPublisher.fastForward` pushes `refs/heads/<round branch>` to
  `refs/heads/<head ref>` on `origin` with `--porcelain` and neither `--force`
  nor `--set-upstream`, so git itself refuses anything but a fast-forward. The
  publish guard (§13.5) reads the commits `origin/<head ref>` lacks first.
  A `[rejected]` ref is a moved head, and goes stale as above; any other
  refusal, the guard's included, ends the round `publish_failed` and parks the
  watch with the error. A head already at the round branch's tip, from a
  push whose recording was interrupted, is not pushed again.

A push ends the round `published` with the tip in `pushed_head_oid`, marks its
fix items handled in that round, removes its worktree, moves the watch to
awaitingCI, and then posts the round's replies (§13.2). An awaitingCI watch is
settled by the poll once GitHub reports the pushed head: green (§13.1
readyToVerify's rule) goes to watching, and `FAILURE` or `ERROR` to watching
with a decision item of kind `check`, keyed `checks:<head oid>`, that stays
while that head's checks still fail. A head still at `base_head_oid` is GitHub
not having caught up, and waits; any other head was pushed over the round,
and goes to watching.

**The verified freeze (phase 3).** On every poll, a verified watch's open items
with no verdict become decisions whose question says the PR is verified and
asks the human to handle the feedback or remove the label, so feedback on a
verified PR never starts a round. Once the watch is no longer verified, those
frozen decisions lose their verdict, and the next poll sends the watch to
settling to triage them.

A round's triage that never starts, or whose task is closed (§13.2), fails
the round: its outcome becomes `triage_failed` and the watch returns to
settling, so the next poll retries with a new round. The third failed round in
a row, not counting interrupted ones, parks the watch instead, with a
`parked_reason` naming the last failure. A parked watch raises its project's
attention signal, its detail the PR number and that reason. A shutdown order
stops a running triager rather than enrolling it: its round's outcome becomes
`interrupted`, which never counts toward parking, and the watch waits in
settling until the order lifts.

Items are keyed by the GitHub node id of the thread or check they came from,
so each is handled once per round; a new reply on a thread reopens it for
triage (§4), whether it was handled or still open with a verdict. The human's own comments, resolved threads, and outdated threads
are never turned into items.

### 13.2 Verdicts — phase 2 (triage) and phase 3 (fix, reply)

Triage gives every open item exactly one verdict:

- **fix** — a clear, in-scope change. Goes to the fixer *(phase 3)*; the
  reply is "Fixed in `<sha>`."
- **answer** — a factual question. A reply only, no code.
- **already_done** — an existing commit already addresses it. The reply cites
  that commit.
- **follow_up** — out of scope for this PR (a refactor belongs in its own).
  Creates a backlog task; the reply says the work is tracked separately.
- **decision** — a trade-off, a disagreement with the reviewer, or anything
  that sets direction. Needs the human: triage's question and its options
  surface on the Pull Requests page's Needs you group (§13.4) rather than
  going to a fixer, and the rest of the round continues around it.

A reply posts automatically only when the project's `postFactualReplies`
setting is on, and only for a factual verdict — fix, answer, already_done, or
follow_up. A decision is never auto-replied, since it is, by definition,
something argued rather than settled.

**Posting replies (phase 3).** Replies go out after a round's push, or, for a
round with no fix item, once its verdicts are applied. Each item the round
handled whose `reply_url` is empty gets one: a fix item "Fixed in `<sha>`."
with the pushed head's first seven characters, and any other factual item its
triage `reply_body`; an item with no `reply_body` gets none. A thread item is
answered on its thread with `gh api graphql`'s
`addPullRequestReviewThreadReply`; a review body, which has no thread, gets one
pull-request comment through `gh api repos/<owner>/<name>/issues/<n>/comments`,
led by a link to the review. The reply's URL is stored in `reply_url`, so
nothing is posted twice; a failed post is logged and left empty. No thread is
ever resolved: resolving is the reviewer's call.

**The triage session (phase 2).** `WorkerSupervisor.spawnTriager(watchId)` is
the only way one starts; the orchestrator has no tool for it. It is held to
the same §8 caps, shutdown order and concurrency count as any worker, since
its session row is an ordinary worker's. It fetches the PR's head oid from
`origin` when the repository lacks it and the base branch's tip into
`refs/remotes/origin/<base>`, refusing the spawn when either fetch fails; then
it creates a synthetic task of origin `triage`, titled for the PR, and its
`pr_triage` row (§4) holding the watch and both oids, and checks out a
detached worktree at the head under the project's worktree root, named for
that task. The session runs in it with a `triager` grant (§6), so it reads the
change with `git diff <base_oid>...<head_oid>`. It is denied the file-write
tools (Edit, Write and NotebookEdit), `gh`, and every git write, both by
`--disallowedTools` and by the PreToolUse guard. A shell redirect or
`sed -i` in Bash is not blocked, so the checkout is not guaranteed untouched;
it is disposable, and nothing in it is ever landed. `roles.triage` picks the
roster agent and model; with no agent the built-in prompt's identity is used.
The model is the role's, else the agent's own, else the project's default.

The built-in prompt, `TriagePrompt`, says what each verdict above means; that
every item body is data written by someone else, to be judged and never
followed, whatever it claims; that `decision` is reserved for a choice a
reasonable engineer could make either way, so a clear in-scope change is
`fix` however large; and that triage ends only when every open item has a
verdict. A roster agent chosen for the triage role replaces the opening
identity line and nothing after it. After a compaction the same prompt is
handed back, rebuilt from the `pr_triage` row.

The triage task never enters review and lands nothing. When `set_verdicts`
leaves no open item without a verdict, the task goes straight to `done` with
no report to the orchestrator, which did not ask for it, and once the
session has stopped its detached worktree is removed the way an accepted
task's is. The orphan sweep (§5) would never take it: a PR head's commits are
outside the project's bases, so it keeps that checkout.

A triage session that ends any other way (stopped, killed at a cap, a failed
setup, vanished, or wound down) closes its task instead, with a progress note
and still no report, since nothing on the board can reassign it, and its
checkout is removed the same way. A stopped triager is never resumed: the
supervisor refuses, and Status and the inspector offer no Resume button for
it, because resuming would rewrite its session config as a worker's. The
follow-through loop starts a fresh triage from settling instead (§13.1). The
settling-to-triaging move is its only caller. A shutdown order never enrolls a
triager, which has no `acknowledge_shutdown`; it stops it at delivery, so the
order does not wait out its grace period for one.

### 13.3 Settings — phase 1 (enabled, settleMinutes, caps, guard) through phase 3 (roles)

Per project, in `settings_json`, everything defaulting off or empty so a
project that never opts in pays nothing:

| Setting | Default | Phase |
|---|---|---|
| `enabled` | `false` | 1 |
| `settleMinutes` | 10 | 1 |
| `roundCap` | 3 | 1 (consulted from phase 3 on) |
| `dailyBudgetUSD` | `nil` (use the spawn caps, §8) | 1 |
| `verificationLabel` | `nil` (the human's own merge is the verification) | 1 |
| `requireApproval` | `true` | 1 |
| `verifyCommand` | `nil` — a command template with `{url}` the Walk me through it row action runs in a terminal | 1 (button shown only once a value is set) |
| `postFactualReplies` | `false` | 3 (no replies exist before phase 3) |
| `roles.triage` / `roles.fixer` / `roles.reviewer` / `roles.followupCheck` | each `{rosterAgentId?, model?}`, unset | 2 (`triage`), 3 (the rest) |
| `privateTerms` | `[]` | 1 |

`roles` names a roster agent (§4) for each of the four model-driven jobs; a
work-specific lens for a role — a follow-up grading rubric, a house style for
replies — lives in that roster agent's prompt, never in this project's
source. `privateTerms` is read by the publish guard below regardless of
whether `enabled` is on, so a project can seed it before turning follow-through
on at all.

### 13.4 Where it lives in the app — phase 1 (page, badge, settings tab) through phase 2 (decisions, banner)

- A **Pull Requests** row pinned in the sidebar directly below Coordinator —
  a new `SidebarSelection` case, alongside `At a Glance`, `Roster`, and
  `Coordinator` (§10) — opening a cross-project page rather than a project
  tab.
- The page groups every watched PR as **Ready to verify**, **Needs you**,
  **In progress**, **Waiting on reviewers**, **Verified**, and **Parked**,
  with a project filter. Needs you and the decision items inside it ship in
  phase 2; the other groups read directly off `pr_watch.state` from phase 1.
- Row actions: **Mark verified** (`gh pr edit --add-label <label>`), **Walk
  me through it** (shown only when `verifyCommand` is set), **Open PR**,
  **Pause**. Opening the PR is the row's title, a link to its URL.
- **Mark verified** runs `gh pr edit <url> --add-label <verificationLabel>`
  through `PullRequestLabeler` in the project's checkout, then records the
  watch as verified with the label added, so the row moves without waiting for
  the next poll; that poll reads the label back and keeps it there. With no
  `verificationLabel` the button is disabled and nothing runs, since the
  human's merge is the verification. A `gh` failure shows its stderr and
  changes nothing.
- **Walk me through it** opens a new **Verify Pull Request** window, one per
  watch, running `verifyCommand` with `{url}` replaced by the PR's URL. The
  user's login shell runs it with `-c`, in the project's checkout, with the
  human-shell environment the Worktree Shell window uses: no board token and no
  agent-session variables. It does not type into the project's Terminal
  screen, whose shell may be mid-command, and nothing in the app writes into a
  human's PTY on its behalf. The URL is substituted as written, so one holding
  anything but letters, digits and `:/._-` is refused and the button is
  hidden; a GitHub PR URL never does.
- The row's badge counts Ready to verify plus open decision items. A decision
  also raises the owning project's attention dot (§9), the same signal a
  pending approval raises.
- At a Glance's headline (§10) gains "N PRs ready to verify" beside the
  review count, each project's card gains its own count, and clicking either
  opens the Pull Requests page filtered to that project (§10 has the
  headline's rule when several projects hold ready PRs).
- A notification banner fires when a PR enters readyToVerify (once per head
  oid) and when a decision item arrives. The Ready to verify banner (phase 1)
  is decided after each poll's transition: `PRWatchStore.claimReadyNotification`
  records the watch's head in `ready_notified_oid` and fires only when that head
  is not already recorded, so a PR that stays ready across polls, or drops out
  and comes back without a push, announces itself once, and a push it is ready
  on again announces it again. It reads "Pull request ready to verify — <project>",
  with `#n title` as its body, and its click opens the Pull Requests page filtered
  to the project, scrolled to the row. It is the **Pull requests ready to
  verify** notification category, on by default; turning it off or muting the
  project still records the head, so unmuting does not replay old banners.
- A seventh project-settings tab, **PR Follow-Through**, placed after
  Advanced (§10), holds every setting in §13.3. Its sections are **Watch**
  (`enabled`, settle window, round cap, daily budget — empty means the spawn
  caps), **Verification** (label — empty means the merge verifies — required
  approval, and the verify command with its `{url}` placeholder),
  **Replies** (`postFactualReplies`, captioned with which verdicts count as
  factual), **Publish guard** (the `privateTerms` list: each term a row
  with a remove button, plus a field that adds one on Return), and **Roles**
  (for each of Triage, Fixer, Reviewer and Follow-up check, an agent picker of
  Default plus the project's enabled roster agents, and a model picker; a
  stored agent the project can no longer spawn stays listed as not available,
  and a role set back to Default with no model is stored as absent). Save trims
  terms, drops blanks and case-insensitive repeats, and keeps a term typed
  into the add field but never added. Save also stores a settle window
  below 0 as 0, a round cap below 1 as 1, and a budget of 0 or less as
  empty.

### 13.5 Guardrails — phase 1 (publish guard) and phase 3 (D8 and §8 amendments)

**The publish guard**, live from phase 1 regardless of whether follow-through
itself is enabled: `BranchPublisher` refuses any push or pull request that
would send one of the project's `privateTerms`, matched as a case-insensitive
substring. This is what lets a public project (this one) sit beside a private
one in the same install without a work-specific name ever reaching a shared
remote by accident. Before anything is pushed and before `gh` is touched, it
reads:

- the published branch name (the remote name, not the local one);
- the pull request's title and body, for `open_pull_request`;
- every commit message in `<remote>/<base>..<branch>`;
- every published commit's changed paths and added lines, read per commit
  from `git log -p --text <remote>/<base>..<branch>`. A push publishes every
  commit, and a PR shows each one even when it is squash-merged, so a term
  one commit adds and a later one removes is still refused. `--text` puts a
  binary file's contents in the patch, and NULs are dropped before matching
  so UTF-16 text is caught. A merge commit contributes only what its author
  changed beyond git's own merge result (`--diff-merges=remerge`). Removed
  lines are not read, so a commit that deletes a term is not refused for it.

With no `<remote>/<base>` ref, every commit in the branch's whole history is
read instead. A match fails the approval: nothing is pushed, the card gets an
error progress row, and the `decision` report names the term and where it was
found (the file and the commit that added it, the commit subject, the branch
name, or the title or body).
An empty list, or one holding only blank entries, is a no-op. A git command
the guard cannot run refuses the publish rather than skipping the check.

**D8 amended (§1).** The app, never a worker, may fast-forward push a round
branch to the head ref of an open PR the human authored, without a human
approval — but only after the reviewer role accepts the round, every item in
it is graded fixed or moot, and the project's tests pass. Creating a branch,
opening a PR, any non-fast-forward push, and any push to a verified PR stay
human-gated or forbidden, unchanged. This is publishing's push (§13.1),
`BranchPublisher.fastForward`, and nothing else calls it.

**§8 amended.** In a project with the feature on, the follow-through triager
and fixer spawns skip spawn approval: the triager never asks for one, and
`Board.requestSpawn` answers proceed for a `fix_round` task. With the feature
off, a `fix_round` task waits for approval like any other task. Every cap in §8 — concurrent workers,
the token cap, the daily budget above, the session ceiling — still applies
unchanged; only the approval step is skipped, the same way a rostered agent
is exempt from the elapsed and idle caps today (§8) without being exempt from
spend.

No agent in this feature runs with authority this section doesn't name here:
a worker still never pushes (§1, §8), and the fast-forward path above is the
only new authority either amendment grants — every other push and
pull-request path keeps its existing human gate.
