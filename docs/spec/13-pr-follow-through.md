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
  thread, a review body, a conversation comment, a failed required check, a
  merge conflict) or when
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
  ref, then posts factual replies when `postFactualReplies` is on and
  re-requests review when `reRequestReviews` is on (§13.2). It never
  resolves threads.
- **awaitingCI** *(phase 3 reads green/red; phase 4 adds the log-tail items on
  red)* — green goes to watching; red goes straight to triaging, with each
  failed check and its log tail as an item (below).
- **readyToVerify** *(phase 1)* — approved (when `requireApproval`), checks
  green, no open item or decision, and the verification label absent. Approved
  means GitHub's `reviewDecision` is `APPROVED`: that is where branch
  protection's required approval count and code owner reviews are enforced, so
  `REVIEW_REQUIRED` is not approved however many reviewers have approved, and a
  `CHANGES_REQUESTED` keeps the PR out of Ready to verify until that reviewer
  reviews again, even after their review is re-requested — it lists under
  Waiting on reviewers meanwhile, since it is still watching. Only a repository
  with no review requirement, where `reviewDecision` is null, falls back to a
  per-reviewer rule: at least one reviewer approves and none still blocks. Each
  reviewer stands by their latest `APPROVED` or `CHANGES_REQUESTED` review (a
  comment review changes nothing, a dismissal clears it); a review request for
  that reviewer made after their `CHANGES_REQUESTED` leaves them pending —
  neither approving nor blocking — until a later removal of that request
  restores the block. The checks on the head commit reduce to one
  of success, pending or failure, and only success is green:
  - When the PR requires checks, only those count. The required set is the
    union of the reported contexts whose own
    `isRequired(pullRequestNumber:)` is true — the source of truth, since it
    needs only read access — and the contexts the base branch's protection
    (`refUpdateRule.requiredStatusCheckContexts`) or a ruleset's required
    status checks name. Those two reads can come back empty for a token
    without admin access or a rule set at the organization, but they are the
    only source for a required check that has not reported yet. A required
    check that has not reported is pending, so a PR is never ready in the
    moment after a push before CI has registered anything.
  - Otherwise every reported check counts, along with the
    `statusCheckRollup` state.
  - Failure outweighs pending, and pending outweighs success. A commit
    status is pending while `PENDING` or `EXPECTED` and failed on `ERROR`
    or `FAILURE`. A check run is pending until `COMPLETED`, passes on
    `SUCCESS` or `SKIPPED`, and fails on any other conclusion, `NEUTRAL`
    included.
  - Only the latest run of each check counts, so a passing rerun clears
    the failure it reran. Runs of one name are ordered by `startedAt`, then
    `completedAt`, then the order GitHub lists them in.
  - The query reads the first 100 of the head commit's contexts and does
    not page further, since paging would add a `gh` call per page. Past
    100, a required check that is not among them reads as pending, and a
    rerun that is not among them cannot clear its failure. Either way the
    PR is held out of ready rather than shown green, and the rollup state,
    which GitHub computes over every context, still counts when nothing is
    required.
  - A head with no rollup is green only when the base branch requires no
    checks and none has registered within a grace period of 5 minutes after
    the head changed (`head_changed_at`, or the watch's `created_at` for the
    head watching began on). A repository with no CI at all becomes ready
    once the grace period has passed.
  - The checks named in `checksAwaitingVerification` (§13.3), by exact
    check-run name or status context, are dropped from both the required
    and the reported set before any of the above, for awaitingCI as for
    readyToVerify: such a check goes green only once a human has verified
    the PR, so counting it would hold the PR out of ready forever. Once one
    of them has reported, the rollup state no longer counts either, since
    GitHub computed it over that check too; a head where nothing else has
    reported then has no state, and waits out the grace period like a head
    with no rollup. An unlisted pending check still holds the PR.
  The required checks and each check's result come from the same per-repo
  `gh api graphql` query as the rest of the poll, so no `gh` call is added
  per PR. New feedback arriving here first sends the PR back to settling.
- **verified** *(phase 1 reads the label; phase 3's freeze is what it is
  frozen against)* — the verification label is present. The PR is frozen:
  Agent Board never pushes to it again, and any new feedback on it becomes a
  decision item rather than restarting the round. Removing the label
  re-evaluates it: readyToVerify if it still qualifies, otherwise watching.
- **stale** *(phase 3 for a publish; phase 4 for the rest)* — the head moved
  out from under the round. Drop the round's worktree; the next poll goes on to
  settling, so the page shows the restart under In progress until then.
- **parked** *(phase 2 for the forked case and failed triages; phase 3 for a
  stacked PR, a round's third failed check, and a refused publish; phase 4 for the round-cap and fixer cases)* — reached
  when the round cap is hit, a round fails its check three times, a round's
  check never runs three times or its branch is gone, three
  triages (phase 2) or fixer sessions fail in a row, the PR is stacked (its base is not the
  project's default branch and the stack needs a restack the human must do),
  or the PR is from a fork. Waits for the human to Resume or Stop watching
  from the Pull Requests page (§13.4).
- **stopped** *(phase 4)* — the human chose Stop watching on a parked PR. Its
  open items are dismissed, the poll records nothing more on it, and the page
  lists it nowhere; the row stays so the next poll's search does not start a new
  watch. A PR that merges or closes still settles to merged or closed.
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
never resolved and an approving body is not feedback. A conversation comment
on the PR (the query's last 100 `comments`) becomes an item of kind `comment`
when its author is not the viewer, bots included, and it was created after the
head commit's `committedDate`, so turning this on, or a new watch, does not send
a PR's whole old conversation to triage. A comment from before that cutoff
creates no item, but one already stored keeps updating from it, so a push does
not mark an untriaged comment handled by moving the cutoff past it. Every
`<!-- … -->` HTML comment is removed from a thread's latest comment, a review
body and a conversation comment first (an unterminated `<!--` hides the rest,
as GitHub renders it), so the stored body, triage and the Pull Requests page see
only what a reader on GitHub sees; a thread, review or comment whose remaining
text is blank is not an item, with one exception: a `CHANGES_REQUESTED` review
with a blank body is still an item, whose body says its author requested changes
without a comment and that their requests may be in a conversation comment, so
triage looks for them there. A stored body
that differs from the incoming one only by those comments, kept from before
they were stripped, is rewritten to the incoming text without counting as a
change: the item keeps its state, verdict, reply and `handled_at`, and is not
reopened. The same query reads
each PR's reviews with their submission times and its review requests
and their removals (`timelineItems(itemTypes: [REVIEW_REQUESTED_EVENT,
REVIEW_REQUEST_REMOVED_EVENT])`) with theirs, which is all the per-reviewer
fallback above needs. The poll itself moves a watch only among watching,
settling, readyToVerify and verified, by the rules above, and a
watch whose PR has left the open list settles to merged or closed by
`gh pr view`. A PR whose GitHub `mergeable` is `CONFLICTING` gets one item of
kind `conflict`, keyed `conflict:<head oid>`, which is handled once GitHub can
merge that head or the head moves. A PR whose head branch lives in another
repository (`isCrossRepository`) is a fork: the poll parks its watch from
watching, settling, readyToVerify or verified, with a `parked_reason` naming
the fork, since publishing pushes only to the project's `origin`. Resuming a
fork parks it again at the next poll. A PR converted back to draft still appears in the search, marked
draft; its watch is deleted with its items, and undrafting it brings it back
through the search as a new watch. A `gh` that is missing or not logged in
records one `pr_poll_problem` row per enabled project, which raises that
project's attention badge until a poll succeeds; it is written once, not on
every poll. Any other search failure (network, rate limit) is logged; after 10
in a row it records the same row with a reason saying the search is failing,
and the next successful search clears it. A project with no `origin` is skipped
without a word. Any other failure to read its `origin` is logged with git's
stderr, the project goes unpolled, and after 10 in a row it records its own row,
cleared once `origin` reads again. Polls never overlap: one requested while
another runs waits for it to finish and then runs in full, so it reads every
write made before it was requested. The 60s tick is the exception: it skips its
poll while one is still running, so a slow `gh` never queues polls behind it.
A section's **Refresh** (§13.4) is the same poll scoped to that section's watches
(`pollPRWatches(watchIds:)`): the one search, a snapshot of only those pull
requests, and the advance step for only those watches. A Refresh requested while
a poll runs that already covers its watches — the tick's always does — joins it
and reports that poll's outcome instead of starting another.

**Pause.** A paused watch keeps following its pull request: every poll still
records its items, head, checks and labels and moves it among watching,
settling, readyToVerify and verified, so the page stays true and resuming acts
on the PR as it is now. What pause withholds is everything that acts or asks
for the human: it never leaves settling for triaging, it is left out of the
sidebar badge and At a Glance (§13.4), its open decisions do not raise the
project's attention dot, and it fires no Ready to verify or decision banner.
Those banners are still claimed while paused, so resuming replays none of
them.

**Settling and triaging (phase 2).** The same poll, after reading GitHub,
advances each watch of an enabled project; a failed search does not stop it.
The poll's own move puts a watch in settling while any open item has no
verdict or is a `fix` answer to a decision whose `round` is past the watch's
(§13.4), so any other open decision or fix item keeps a PR from being ready
without sending it back to triage. A settling watch leaves for triaging only when it is
not paused, at least `settleMinutes` have passed since `last_feedback_at` (so an
item arriving during settling restarts the wait) or a `check` item awaits
triage (phase 4, below), and nothing holds it: a
shutdown order on the project, a Mac whose providing power source IOKit reports
as anything but AC (an unreadable source counts as AC), the triage and fixer
sessions started since local midnight having cost `dailyBudgetUSD` or more, or a §8
spawn cap refusing. A hold leaves it settling and is re-checked on the next
poll. Once `roundCap` rounds have started since the watch was last resumed
(`resumed_at`, or ever), interrupted and failed triages aside, leaving parks it
instead, with a `parked_reason` naming the cap; this applies to the answered-fix
round below as well. Leaving increments `round`, records a `pr_round` holding the head oid it
starts from, and moves the watch to triaging in one transaction that only a
settling watch passes, so two polls never start two rounds; then it spawns the
round's triager (§13.2), whose `pr_triage` row carries the round. A watch
whose only waiting items are answered fixes needs no triage: under the same
conditions its new round goes straight to fixing (parked instead when the PR
is stacked, below), and the fixer starts on that poll.

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
holds a section per open `fix` item, each built like a follow-up's body; a
`conflict` item's section says to resolve it by merging `origin/<base>` into
the round branch and committing the merge, never by rebasing, and its fixer's
spawn also fetches the base into `refs/remotes/origin/<base>`. The
task goes in the round's `fix_task_id` and in each of those items'
`fix_task_id`, and every `backlog` `follow_through` task of type `code` that an
item of the watch names — a fix task phase 2 made — is closed with a reason
naming the round.

The fixer is spawned only while its task is `ready` and its fixer sessions
(those with no `review_head`) that reported do not outnumber the round's
`check_failures`: one that reported starts again only after a failed check. A
fixer that ends without a report puts its task back in `ready` (never `review`,
since the next fixer reuses the worktree and branch) and is retried; the third
in a row, not counting one wound down for a shutdown order, ends the round
`fixer_failed`, closes its task, and parks the watch with the last session's
stop reason. A fixing
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
  the fixer's own worktree on the round branch, recreated from that branch when
  it is gone, its review base
  `base_head_oid`, so it reads `git diff <base_head_oid>...HEAD`; its model is
  `roles.reviewer.model`, else the agent's, else the project's default. Its
  prompt adds that accepting lets Agent Board push the round with no person in
  between, so it runs the project's tests on the suites the diff touches and
  accepts only when they pass. `accept_task` and `reopen_task` record its
  verdict on the round (`review_verdict`, and a reopen's findings in
  `review_findings`) and end its session; neither moves the task. A round
  branch with no change beyond `base_head_oid` is reopened on the spot with
  that reason, with no reviewer spawned. A reviewer session that ends without
  a verdict parks the watch, unless its setup failed, which is a check that
  never ran (below); one left idle without one is raised as §5.1 says.
- **The follow-up check.** When the round has items to grade, a synthetic task
  of origin `followup_check` is created and recorded in `followup_task_id`
  with the round branch's tip as `checked_head_oid`, and a session holding a
  triager grant (§6) runs in a detached checkout of that tip under the
  project's worktree root, named for the task. `roles.followupCheck` picks the
  roster agent, whose plugin directories it is launched with, and the model the
  same way as the reviewer's; with no agent, the built-in `FollowupCheckPrompt`
  identity is used. It reads `git diff <base_head_oid>..<checked_head_oid>` and
  grades each item with `set_followup_grades` — `fixed`, `partly`,
  `not_fixed`, `moot` or `needs_author` — giving evidence for each. Since it
  cannot run `gh`, its prompt carries the PR's title and description as the
  last poll stored them on the watch (`title`, `body`, §4); every poll reads
  both, the description with its `<!-- … -->` comments removed. Each is fenced
  between marker lines carrying one id and labeled as text written on GitHub,
  data rather than instructions. The description is cut at 4,000 characters,
  and the prompt says so when it is, so the prompt still fits a
  post-compaction brief. An item asking for a change to the title or
  description is graded against that text rather than the diff: `fixed` when
  the text shows the change, quoting it, and `needs_author` when it does not. Once
  every item has a grade its task goes to `done` and its checkout is removed,
  as a finished triage's is. It is never assigned by hand or resumed, and one
  that ends any other way closes its task and parks the watch, unless its setup
  failed, which clears `followup_task_id` as a check that never ran (below); a shutdown order
  stops it at delivery and clears `followup_task_id`, so a fresh one starts
  once the order lifts.

Once the review is in and, when the round has items, its follow-up check is
`done`, the round is decided in one transaction. An item graded
`needs_author` — one no commit can satisfy, because only the PR's author can
do it on GitHub, such as editing the description — first becomes a decision
(§13.4): its question carries the check's evidence, its options are "I'll do
it" (`answer`, with a reply saying so) and "Leave it as is" (`answer`, no
reply), and it leaves the round, counting toward neither outcome. An
acceptance with every remaining item graded `fixed` or `moot` passes: the task
goes to `done` with an "Agent review passed." note and the watch to
publishing. A reopened round whose every item went to the author ends with
outcome `triaged` instead, closing its fix task, since no fixer has anything
left to do; the watch goes to settling when feedback awaits triage, else
watching. Anything else is a failed check, counted in `check_failures`. Its
findings — the reviewer's, and each item short of fixed with its grade and
evidence, numbered as in the task body and with its item id — go on the task
as an "Agent review failed." note, which the next fixer's opening prompt
carries (§5.1). The first two failures send the task back to `ready` and the
watch to fixing, which spawns that fixer in the same worktree on the same
branch. The third ends the round with outcome `check_failed`, closes its fix
task, and parks the watch. Its `parked_reason` leads with the cause on one
line, because the Pull Requests page and the orchestrator's report (§13.6)
show only that line: "Round 8 failed its check 3 times: item 47 not fixed
(Rename the helper)", naming up to three items by id, each with its grade and
the first line of triage's approach (never the comment, which is untrusted),
and "the reviewer reopened it" when it did. The last findings follow after a
blank line.

A check that never ran is not a failed check and never counts in
`check_failures`. That is a reviewer or follow-up check whose spawn throws or
whose setup fails, or one that cannot start for a reason a later poll may
clear: a worktree that cannot be recreated, a git failure, a checkout still
held or being set up. A §8 cap or a shutdown order is a hold instead. The watch
stays checking and the next poll retries the half that never ran, counting
each attempt in `unavailable_checks` (a reviewer whose setup failed counts
through its session). An attempt counts even when git cannot read the round
branch's tip. The third since the watch was last resumed ends the round with
outcome `check_unavailable`, keeps its fix task in review, and parks the watch
with a `parked_reason` whose first line names the unpushed commit and its
branch — "Round N's commit <sha> on `<branch>` is unpushed", or "Round N's
branch `<branch>` could not be read" when the tip could not be read — so the
author can push or discard it. A check that fails on configuration no retry can
fix — a roster agent the project cannot use, the board's server not running,
the project, the fix task or its round gone, a repository that is not git —
parks the same way on its first attempt, its own error as the first line of
`parked_reason`. A round branch that is gone ends the round the same way at
once, closing its fix task, since nothing is left to push. Until a round
pushes or is abandoned, no later round takes its items: their fixes are in its
unpushed commit. The watch does not leave checking while it retries, and
Resume (§13.4) sends a `check_unavailable` round whose fix task is still in
review back to checking with its count cleared, rather than moving its items
on to a new round.

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
  settling, which triages them against the new head. Replies still owed are
  then posted (§13.2).
- **The push.** A round branch whose tip is not the `checked_head_oid` its
  follow-up check judged parks the watch unpushed. Otherwise
  `BranchPublisher.fastForward` pushes `refs/heads/<round branch>` to
  `refs/heads/<head ref>` on `origin` with `--porcelain` and neither `--force`
  nor `--set-upstream`, so git itself refuses anything but a fast-forward. The
  publish guard (§13.5) reads the commits `origin/<head ref>` lacks first.
  A `[rejected]` ref is a moved head, and goes stale as above; any other
  refusal, the guard's included, ends the round `publish_failed` and parks the
  watch with the error. Every park here, like stale, then posts the replies
  still owed (§13.2). A head already at the round branch's tip, from a
  push whose recording was interrupted, is not pushed again.

A push ends the round `published` with the tip in `pushed_head_oid`, marks its
fix items handled in that round, removes its worktree, moves the watch to
awaitingCI, and then posts the round's replies (§13.2). An awaitingCI watch is
settled by the poll once GitHub reports the pushed head: green (§13.1
readyToVerify's rule) goes to watching, and `FAILURE` or `ERROR` as below. A
head still at `base_head_oid` is GitHub not having caught up, and waits; any
other head was pushed over the round, and goes to watching.

**Failed checks (phase 4).** On red, each counted check (readyToVerify's rule:
the required ones, else every reported one, latest run only, so a passing
rerun leaves nothing, and never one in `checksAwaitingVerification`) whose latest run failed becomes one untriaged item of
kind `check`, keyed by the check run's or commit status's node id, so a run
already recorded adds nothing on a later poll. Its body names the check and
the head and links the run (`url`). For a GitHub Actions run (its check suite's
app is `github-actions`) the body holds the last 200 lines of
`gh run view --job <check run id> --log-failed`, read once, when the item is
first recorded; the job, not the whole workflow run, so two failed jobs of one
run each carry only their own log. Any other check, or a log `gh` cannot read,
carries the check's summary instead. The watch goes to settling, stamping
`last_feedback_at`, and leaves for triaging on the same poll without the settle
wait, under the same holds and the same round cap, so a red, fix, push, red
loop parks once `roundCap` rounds have run. Red with no new failed check to
record goes to watching. A check item becomes handled once its run is no longer
a failed check on the head the poll reads (a rerun, or a new head); the
triager is told it is usually `fix`, or `decision` when the failure looks
unrelated to the change. Phase 3's single decision item per red head, keyed
`checks:<head oid>`, is gone: migration `pr_item_failed_checks` dismisses any
still open.

**The verified freeze (phase 3).** On every poll, a verified watch's open items
with no verdict become decisions whose question says the PR is verified and
asks the human to handle the feedback or remove the label, so feedback on a
verified PR never starts a round. "Handle it myself" is an `answer` option
with no reply; "Remove the label and let follow-through fix it" is a `fix`
option, so once the label is gone the item goes to the next fix round. Once the watch is no longer verified, those
frozen decisions lose their verdict, and the next poll sends the watch to
settling to triage them.

**Verify failures (phase 4).** What the human finds while verifying a PR by
hand re-enters the loop as an item of kind `verify_failure`, recorded either by
the **Send back** row action (§13.4) or by an agent through the orchestrator's
`add_pr_item(pr_url, body, answers?)` (§6), which a manual-verification skill's agent
calls. The item has no author, path or URL, and its node id is
`verify:<uuid>`, so it never collides with a GitHub id. An orchestrator that
files a reviewer's requests this way, because they never became an item of
their own, passes `answers`: the review's node id or the reviewer's login,
stored on the item so triage of that reviewer's blank change request finds it
(§13.2). Nothing reads a review URL or `@login` out of the body, so an item
filed without `answers` stays unlinked. The poll never sees the item
on GitHub and so never marks it handled for leaving the snapshot. On a
verified watch it becomes a frozen decision at once, as above, and the watch
stays verified until the human removes the label. From watching, settling or
readyToVerify the watch goes to settling, with the settle wait restarted; in
any later state it waits, like any feedback that arrives mid-round, for the
next round. No reply is ever posted for it (§13.2).

A round's triage that never starts, or whose task is closed (§13.2), fails
the round: its outcome becomes `triage_failed` and the watch returns to
settling, so the next poll retries with a new round. The third failed round in
a row since the watch was last resumed, not counting interrupted ones, parks
the watch instead, with a `parked_reason` naming the last failure. A parked watch raises its project's
attention signal, its detail the PR number and that reason. A shutdown order
stops a running triager rather than enrolling it: its round's outcome becomes
`interrupted`, which never counts toward parking, and the watch waits in
settling until the order lifts.

Items are keyed by the GitHub node id of the thread, review, comment or check they came from,
so each is handled once per round; a new reply on a thread reopens it for
triage (§4), whether it was handled or still open with a verdict. The human's own comments, resolved threads, and outdated threads
are never turned into items.

**Dismissed items.** An open item can be retired by hand, with a required
reason, when it was settled outside follow-through — a description edited with
`gh pr edit`, say, which no round can commit. The human does it from the Pull
Requests page (§13.4); an orchestrator asks with `dismiss_pr_item` (§6), which
waits on the human's approval. `PRWatchStore.dismissItem` sets the item
`dismissed` with `dismiss_reason`, `dismissed_by` and `dismissed_at` (§4). A
dismissed item is never triaged, never graded by a follow-up check (a grade a
running check sends for one is dropped), never counted as unfixed, and never
replied to. If its round is fixing or checking and the dismissal leaves the
round's fix task no open item, the round ends as `triaged`, its fix and
follow-up check tasks close, and the watch goes to settling when feedback
awaits a round, else watching. A watch parked by that round's failure —
`check_failed`, `check_unavailable` or `fixer_failed` — unparks the same way
once the round has no open item left, and reports `unparked` (§13.6); a park
for any other cause stays. Both the page and a granted approval go through the
supervisor, which first stops any session still holding one of those tasks — a
running fixer, follow-up check or round reviewer. That stop neither moves the
task nor reports: the dismissal closes the task next, and its own report is the
only one. A stop that fails leaves the item open; the page shows the error, and
a granted approval writes the "Item N was not dismissed" `decision` report
naming it. A `report_complete` that still reaches a closed task records the report,
already consumed, ends the session and leaves the task closed. A new reply on a
dismissed thread reopens it like any other (§4).

### 13.2 Verdicts — phase 2 (triage) and phase 3 (fix, reply)

Triage gives every open item exactly one verdict:

- **fix** — a clear, in-scope change. Goes to the fixer *(phase 3)*; the
  reply is "Fixed in `<sha>`."
- **answer** — a factual question. A reply only, no code. An item that asks
  for nothing (a status banner, a verdict line, a pointer to feedback posted
  elsewhere, a plain approval note) is an answer with no `reply_body`, so
  nothing is posted for it.
- **already_done** — an existing commit already addresses it. The reply cites
  that commit.
- **follow_up** — out of scope for this PR (a refactor belongs in its own).
  Creates a backlog task; the reply says the work is tracked separately.
A `conflict` item is always `fix`: the built-in prompt says the fixer merges
the base into the branch.
A blank `CHANGES_REQUESTED` review's item carries no requests itself:
`get_pr_items` lists, as its `linked_items`, every item whose `answers` names
that review's node id or its author, open or handled, and the built-in prompt
has triage look for the requests there and in that author's other items,
usually a `comment` item. A review whose linked item is already handled is
`already_done` with no `reply_body`; one whose requests another open item
carries is `answer` with no `reply_body`, or `already_done` when a commit
already addresses them; and one whose requests no item carries is `decision`.

- **decision** — a trade-off, a disagreement with the reviewer, or anything
  that sets direction. Needs the human: triage's question and its options
  surface on the Pull Requests page's Needs you group (§13.4) rather than
  going to a fixer, and the rest of the round continues around it. Each
  option carries the verdict choosing it applies, `fix` or `answer`; an
  `answer` option also carries the `reply_body` that explains the choice to
  the reviewer, so "Change the helper" is a fix and "Keep it local" is an
  answer with a short reason as its reply. Options stored before they carried
  a verdict are plain strings and read as `fix`.
A request only the PR's author can carry out on GitHub rather than by a
commit — editing the description or title, changing labels or reviewers,
replying elsewhere — is never `fix`, since a fixer can only commit and neither
it nor the follow-up check can run `gh`. The built-in prompt makes it a
`decision` asking the author to do it, with options such as "I'll do it" as an
`answer` with a short reply, or an `answer` when it is already done, which
triage reads from the current title and description in its prompt. One that
reaches a fix round anyway is graded by the check from the same text (§13.1):
`fixed` when the author has made the edit, `needs_author` when not.

A reply posts automatically only when the project's `postFactualReplies`
setting is on, and only for a factual verdict — fix, answer, already_done, or
follow_up. A decision is never auto-replied, since it is, by definition,
something argued rather than settled.

**Posting replies (phase 3).** Replies go out after a round's push, when a
publishing round goes stale or parks, or, for a round with no fix item, once its
verdicts are applied. Each time, every handled thread, review or comment item whose
`reply_url` is empty gets one, whatever round handled it, so an answer from a
round that never pushed is still replied to at the next of those points. Only an
item whose `handled_at` is at or after `postFactualRepliesSince` qualifies:
`ProjectStore.updateSettings` stamps that time when `postFactualReplies` turns
on and clears it when it turns off, so turning replies on never posts the
backlog triage wrote while they were off, and an item handled before
`handled_at` existed never posts. A fix item gets "Fixed in `<sha>`." with the
first seven characters of the head its own round pushed, and only once that
round pushed it under its fix task, matched with `IS` so a fix task deleted
after the push still counts; a fix whose round went stale, froze or parked
claims nothing. Any other factual item
gets its triage `reply_body`; an item with no `reply_body` gets none. A frozen
round posts nothing itself; its owed replies wait for the next point. A thread
item is answered on its thread with `gh api graphql`'s
`addPullRequestReviewThreadReply`; a review body or a conversation comment,
which has no thread, gets one pull-request comment through
`gh api repos/<owner>/<name>/issues/<n>/comments`, led by a link to the review
or comment it answers. Every post, thread reply or pull-request comment, ends
with a blank line and `**Posted by PR follow-through agent**`: it goes out under
the user's own account, and readers must be able to tell it from something the
user wrote. `PRItem.postedBody` builds the whole posted text, so the mark is
added in one place; nothing hidden marks it, since the watcher already skips
the viewer's own comments. The reply's URL is stored in `reply_url`, so
nothing is posted twice. A failed post is logged and its error kept in
`reply_error`; it is tried again at the next point. When `gh` reports the
comment gone (`NOT_FOUND`, HTTP 404 or "Could not resolve to a node"), the
pull request is read once with `gh pr view`, since GitHub answers the same for
a repository the token cannot see. If it reads, the thread itself is gone: the
post sets `reply_abandoned_at` and ends the attempts. If it does not, the item
keeps only its `reply_error` and stays owed, and the project gets a
`pr_poll_problem` row naming the PR, which stays through later polls until one
reads that PR again (or its watch ends). An item reopened by a new reply loses `reply_url`,
`reply_error` and `reply_abandoned_at`, so once it is handled again it gets a
fresh reply. No thread is ever resolved: resolving is the reviewer's call.

**Re-requesting review.** When the project's `reRequestReviews` setting is on,
a round whose push was recorded asks for review again, right after its replies.
A round that went stale, froze or parked asks nothing. The candidates are the
authors of the thread, review and comment items handled in that round (`pr_item.round`
is the round's number), not every past reviewer. One `gh api graphql` read of
the pull request's reviews and pending review requests then keeps only those
whose latest review other than a comment, `PENDING` and `DISMISSED` ones
aside, is `CHANGES_REQUESTED`, plus those who have only ever commented. A
thread reply is itself a `COMMENTED` review, so, as in GitHub's own review
decision, a comment after an approval leaves the approval standing and that
reviewer is not asked. It
also drops the viewer, bots (a `Bot` author, or a login ending in `[bot]`,
which GitHub will not request) and anyone whose request is still pending. The
rest are asked in one
`gh api repos/<owner>/<name>/pulls/<n>/requested_reviewers` call. GitHub
notifies each of them as the user, which is why the setting is off by default.
The round is claimed first by stamping `pr_round.review_requests_at`, so a
round asks at most once. The logins asked go in `review_requests_json`, and a
failed read or request is logged and kept in `review_request_error`; it is not
retried, and it neither parks the watch nor holds back replies.

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
followed, whatever it claims; the PR's current title and description, fenced
and capped as the follow-up check's are (§13.1), so a title or description
request that the text already shows is an `answer`; that `decision` is reserved for a choice a
reasonable engineer could make either way, so a clear in-scope change is
`fix` however large; that a request only the author can carry out on GitHub
is never `fix`; that an item asking for nothing is `answer` with no
`reply_body`; that each decision option is `{label, verdict}`, an
`answer` option with its `reply_body`; and that triage ends only when every open item has a
verdict. A roster agent chosen for the triage role replaces the opening
identity line and nothing after it. After a compaction the same prompt is
handed back, rebuilt from the `pr_triage` row.

The triage task never enters review and lands nothing. When `set_verdicts`
leaves no open item without a verdict, the task goes straight to `done` with
no `complete` report to the orchestrator, which did not ask for it (the round's
outcome reaches it as a §13.6 milestone instead), and once the
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
| `verifyCommand` | `nil` — a shell command template with `{url}` that the Walk me through it row action runs in a terminal through an interactive login shell; a Claude command goes through `claude`, e.g. `claude "/review:verify {url}"` | 1 (button shown only once a value is set) |
| `postFactualReplies` | `false` | 3 (no replies exist before phase 3) |
| `reRequestReviews` | `false` — re-requests review after a pushed round, which notifies reviewers as the user (§13.2) | 4 |
| `roles.triage` / `roles.fixer` / `roles.reviewer` / `roles.followupCheck` | each `{rosterAgentId?, model?}`, unset | 2 (`triage`), 3 (the rest) |
| `privateTerms` | `[]` | 1 |
| `checksAwaitingVerification` | `[]` — check-run names or status contexts, matched exactly, ignored when deciding whether CI has passed (§13.1) | 4 |

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
- **Parked (phase 4).** A parked row shows its `parked_reason`, and offers
  **Resume** and **Stop watching** in place of Pause. Resume
  (`PRWatchStore.resume`) returns the watch to settling, clears the reason, and
  stamps `resumed_at`, which restarts both the round cap and the failed-session
  streak, so a resumed watch's next single failure does not park it again. Each
  open `fix` item moves to the round after the watch's, so the next round takes
  it up without a fresh triage. A watch parked on a `check_unavailable` round
  whose fix task is still in review goes back to checking instead, reopening
  that round and keeping its items (§13.1). Stop watching (`PRWatchStore.stopWatching`)
  dismisses the open items and moves the watch to stopped (§13.1). A stale row
  shows "restarted: head moved" while it waits for the next poll. An
  orchestrator that has dealt with the parked reason asks for Resume with
  `resume_pr_watch` (§6). It shows on Pending Approvals as "Resume a parked
  pull request", with the PR, the parked reason and the orchestrator's reason
  beneath, and granting it runs the same `PRWatchStore.resume`.
- **Dismiss one item.** Under a row with open items, a collapsed "N open
  items" list shows each one's author, kind, first line, and "graded partly" or
  "graded not fixed" when its last check fell short. Each has **Dismiss…**,
  which asks why in a popover; the reason is required. Dismissing retires that
  item alone, as §13.1's dismissed items describe, and may end its round or
  unpark the watch. An orchestrator's `dismiss_pr_item` shows on Pending
  Approvals as "Dismiss a pull request item", with the PR, the item and the
  reason beneath.
- **Refresh (phase 4).** Each group's header has a **Refresh** button that
  polls GitHub now for the watches in that group and applies their transitions
  (§13.1's poll, scoped), so CI settling or new feedback shows without waiting
  for the tick. While that refresh or any poll runs the header shows a spinner,
  and a press then joins the running poll. A refresh that cannot read the
  group's pull requests shows why inline at the top of the group. VoiceOver
  hears the button as "Refresh <group>" and is told when the refresh starts,
  finishes or fails.
- **Last polled.** Each row adds "polled …" from `last_polled_at`, stamped
  each time a poll reads the PR from GitHub whether or not anything changed,
  so a row that is current but unchanged can be told from a stale one.
- **Attach to its agents.** Before its other actions, a row shows one attach
  button per active session (`SessionState.isActive`) on the watch's triage
  tasks (`pr_triage.task_id`) and fix-round tasks (`pr_round.fix_task_id`),
  oldest first, titled **Triage**, **Fixer** or **Reviewer** with the Status
  page's attach symbol. A session on a fix task is its reviewer when it has a
  review baseline (`review_head`, §5.1), and its fixer otherwise; a round's
  follow-up check runs on its own task and gets no button. Clicking one opens
  that session's terminal window, as the Status page's attach does. There is no
  worktree-shell button. `PRWatchStore.observePage` reads the sessions in the
  same fetch as the rows, so buttons appear and disappear as sessions start
  and end; a row with no active session shows none.
- Row actions: **Mark verified** (`gh pr edit --add-label <label>`), **Walk
  me through it** (shown only when `verifyCommand` is set), **Send back**
  (phase 4; shown only while the watch is readyToVerify or verified), **Open
  PR**, **Pause**. Opening the PR is the row's title, a link to its URL.
- **Send back** opens a popover asking what failed and records the text as a
  `verify_failure` item (§13.1): a readyToVerify PR goes to settling, and a
  verified one stays frozen with the failure as a decision.
- **Mark verified** runs `gh pr edit <url> --add-label <verificationLabel>`
  through `PullRequestLabeler` in the project's checkout, then records the
  watch as verified with the label added, so the row moves without waiting for
  the next poll; that poll reads the label back and keeps it there. With no
  `verificationLabel` the button is disabled and nothing runs, since the
  human's merge is the verification. A `gh` failure shows its stderr and
  changes nothing.
- **Walk me through it** opens a new **Verify Pull Request** window, one per
  watch, running `verifyCommand` with `{url}` replaced by the PR's URL. The
  user's login shell runs it interactively (`-i -c`, with a `-` on argv0), so it
  reads `.zshrc` and finds what a terminal would — `claude` in `~/.local/bin`
  included — in the project's checkout, with the
  human-shell environment the Worktree Shell window uses: no board token and no
  agent-session variables. It does not type into the project's Terminal
  screen, whose shell may be mid-command, and nothing in the app writes into a
  human's PTY on its behalf. The URL is substituted as written, so one holding
  anything but letters, digits and `:/._-` is refused and the button is
  hidden; a GitHub PR URL never does.
- `verifyCommand` is a shell command, so a Claude Code slash command typed
  there (`/review:verify {url}`) is run as a file path and fails. The
  settings field notes any value whose first word starts with `/` and holds
  no other `/` — an absolute path such as `/usr/local/bin/verify` is not
  flagged — and offers **Use claude "…"**, which rewrites the field to
  `claude "/review:verify {url}"` (`PRFollowThroughSettings.claudeForm`).
  The Verify Pull Request window never rewrites the command at run time;
  when such a command exits non-zero within its first second and no file
  exists at its first word, the window shows the same `claude "…"` form
  above the exit line, under the shell's own error.
- **Needs you (phase 2).** Each open decision is listed under its PR's row:
  the comment's author and text, triage's `decision_question`, one button per
  `decision_options` entry, and a free-text **Reply instead** field.
  `Board.answerDecision` stores the answer in `decision_answer` and moves the
  item to the next round (`round` one past the watch's) with the answer as its
  `approach`. An option button applies that option's verdict. A `fix` option
  leaves the item open, with no task, for the next round's fixer (§13.1),
  whose section for it quotes the question the answer was given to. An
  `answer` option handles the item with the option's `reply_body` and makes no
  task; the app's own decisions (the verified freeze, §13.1)
  carry `answer` options with no reply, which handle it with nothing to post. A typed reply answers it as an `answer`: the item is handled, with the
  reply as its `reply_body`. Either way it is no longer a decision.
- The row's badge counts Ready to verify plus open decision items, both only in
  projects with follow-through on and only on watches that are not paused —
  one rule, read by the badge and At a Glance alike from
  `PRWatchStore.badgeCounts`. Under the same rule an open decision raises the
  owning project's attention dot (§9) as `pullRequestDecision`, its detail
  `#n: <question>` for the most recent one. A parked PR's attention also counts
  only in a project with follow-through on.
- At a Glance's headline (§10) gains "N PRs ready to verify" beside the
  review count, each project's card gains its own count, and clicking either
  opens the Pull Requests page filtered to that project (§10 has the
  headline's rule when several projects hold ready PRs).
- A notification banner fires when a PR enters readyToVerify (once per head
  oid) and once per decision item. The decision banner (phase 2) is decided
  on every poll: `PRWatchStore.claimDecisionNotifications` stamps each open
  decision's `decision_notified_at` and returns those it stamped, so each
  decision announces itself once, and a new reply on its thread, which clears
  the verdict, clears the stamp too. It reads "Pull request decision waiting —
  <project>", with `#n: <question>` as its body, routes like the Ready to
  verify banner, and is the **Pull request decisions** category, on by
  default. The Ready to verify banner (phase 1)
  is decided after each poll's transition: `PRWatchStore.claimReadyNotification`
  records the watch's head in `ready_notified_oid` and fires only when that head
  is not already recorded, so a PR that stays ready across polls, or drops out
  and comes back without a push, announces itself once, and a push it is ready
  on again announces it again. It reads "Pull request ready to verify — <project>",
  with `#n title` as its body, and its click opens the Pull Requests page filtered
  to the project, scrolled to the row. It is the **Pull requests ready to
  verify** notification category, on by default; turning it off or muting the
  project still records the head, so unmuting does not replay old banners.
  Both claims also queue the orchestrator's report (§13.6), so it hears of
  each once too.
- A seventh project-settings tab, **PR Follow-Through**, placed after
  Advanced (§10), holds every setting in §13.3. Its sections are **Watch**
  (`enabled`, settle window, round cap, daily budget — empty means the spawn
  caps), **Verification** (label — empty means the merge verifies — required
  approval, the verify command with its `{url}` placeholder, and **Checks
  that wait on verification**, a comma-separated `checksAwaitingVerification`
  field whose save trims names and drops blanks and repeats),
  **Replies** (`postFactualReplies`, captioned with which verdicts count as
  factual, and `reRequestReviews`, captioned that GitHub notifies reviewers as
  the user), **Publish guard** (the `privateTerms` list: each term a row
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

### 13.6 Reports to the orchestrator

Follow-through runs inside the app, but the owning project's orchestrator
hears what it did: each milestone below queues one `pr_follow_through` report
in that project's queue, the one `list_reports` drains (§6), and the poll ends
by announcing it (§9.1). The report is written in the same transaction as the
transition it reports, so a milestone is never reported without happening or
twice for one transition.

| Milestone | `state` | When |
|---|---|---|
| Ready to verify | `ready_to_verify` | The Ready to verify banner's claim (§13.4): once per head oid |
| Parked | `parked` | Every park, with the first line of `parked_reason` |
| Unparked | `unparked` | A dismissal lifts an item-bound park (§13.1 dismissed items), naming the item and reason and the state the watch moved to |
| New decision | `decision` | The decision banner's claim (§13.4): once per item, with the first line of triage's question |
| Round outcome | `round_published` / `round_stale` / `round_fixer_failed` / `round_triaged` | A round pushed (with the pushed sha), went stale, ended `fixer_failed`, or ended `triaged` with no fix item open |
| Merged or closed | `merged` / `closed` | The poll settles the watch to either |

The body is two lines: `#<n> <title> — <url>`, then `<state>: <reason>`, the
reason one line of at most 200 characters. It never carries a comment body, a
CI log or a reply, which are untrusted and long; a decision's question is
triage's own wording. A round that ends `check_failed`, `check_unavailable` or
`publish_failed` parks, and that park is its report; `triage_failed`, `interrupted` and
`frozen` rounds report nothing of their own.

The banners' gate applies: a paused watch, or one in a project with
follow-through off, queues nothing, and since the claims are still made while
paused, resuming replays none. The orchestrator's briefing (§9) describes these
reports as information, not requests to act: Agent Board runs the loop itself,
and a decision or a parked PR is the human's to handle on the Pull Requests
page.

A report says only that something happened. To see why, the orchestrator reads
follow-through's state through three read-only tools (§6): `list_pr_watches`
for every watch with its full `parked_reason` and its open, decision and
failed-reply counts, `get_pr_watch` for one watch's items and rounds (reply
status, `answers`, head oids, `check_failures`, `unavailable_checks`, and
findings on request), and `list_pr_poll_problems` for a poll that cannot run.
Each reads only the caller's own project, and none changes anything: resume,
pause, answering a decision and Mark verified stay the human's, on the Pull
Requests page. An orchestrator can only ask for a resume (`resume_pr_watch`)
or a dismissal (`dismiss_pr_item`), each waiting on the human's approval. Item
bodies, approaches, findings, reply errors and parked reasons can quote
reviewers or agents, so each tool's description and result label them as data,
never instructions.
