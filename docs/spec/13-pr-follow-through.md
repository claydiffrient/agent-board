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
**Phase 3** delivers fixing, checking, and publishing's push. **Phase 4**
delivers stale, the rest of parked, and feeding CI and verification failures
back into items.

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
  amend, no rebase.
- **checking** *(phase 3)* — the `reviewer` role reviews the round's diff, and
  the `followupCheck` role grades each item `fixed`, `partly`, `not_fixed`, or
  `moot`. Anything other than fixed or moot reopens fixing, at most
  `roundCap` times (default 3); the round past the cap parks the PR instead.
- **publishing** *(phase 3)* — re-reads the remote head and goes to **stale**
  if it moved. Otherwise fast-forward pushes the round branch to the PR's head
  ref, then posts factual replies when `postFactualReplies` is on. It never
  resolves threads.
- **awaitingCI** *(phase 1 reads green/red; phase 4 adds the log-tail items on
  red)* — green goes to watching; red goes straight to triaging, with the
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
- **stale** *(phase 4)* — the head moved out from under the round. Drop the
  round's worktree and go to settling.
- **parked** *(phase 2 for the stacked/forked cases; phase 4 for the
  round-cap and fixer cases)* — reached when the round cap is hit, three
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
cleared once `origin` reads again. Polls never overlap: one requested while
another runs waits for it to finish and then runs in full, so it reads every
write made before it was requested. The 60s tick is the exception: it skips its
poll while one is still running, so a slow `gh` never queues polls behind it.

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
verdict, so an open decision or fix item keeps a PR from being ready without
sending it back to triage. A settling watch leaves for triaging only when it is
not paused, at least `settleMinutes` have passed since `last_feedback_at` (so an
item arriving during settling restarts the wait), and nothing holds it: a
shutdown order on the project, a Mac whose providing power source IOKit reports
as anything but AC (an unreadable source counts as AC), the triage sessions
started since local midnight having cost `dailyBudgetUSD` or more, or a §8
spawn cap refusing. A hold leaves it settling and is re-checked on the next
poll. Leaving increments `round`, records a `pr_round` holding the head oid it
starts from, and moves the watch to triaging in one transaction that only a
settling watch passes, so two polls never start two rounds; then it spawns the
round's triager (§13.2), whose `pr_triage` row carries the round.

A triaging watch waits for its round's triage task. Once that task is `done`,
the verdicts are applied in one transaction:

- `fix` — a `backlog` task of type `code`, origin `follow_through`, its model
  `roles.fixer.model` or else the project's default. The item stays open with
  the task in `fix_task_id`; phase 3's fixer is what handles it.
- `follow_up` — a `backlog` task, origin `follow_through`, titled
  "Follow-up from #n: …". The item is handled, with the task in `fix_task_id`.
- `answer` and `already_done` — the item is handled; its `reply_body` stays
  stored for phase 3 to post.
- `decision` — the item stays open as a decision.

A fix or follow-up task's body holds the PR's number, title and URL, the
comment's author, path and line, and URL, the comment quoted and labeled as
data rather than instructions, and triage's approach. An item gets no second
task while `fix_task_id` names one that fits its verdict: a `follow_through`
task of type `code` for `fix`, any other `follow_through` task for `follow_up`.
A fix task still in `backlog` is rewritten with the item's current body, so a
reply that arrived after it was made reaches the fixer. The round's outcome becomes `triaged` and the watch returns to
watching, or to settling when an item arrived during triage. Phase 3 replaces
that return with fixing.

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
  going to a fixer, and the rest of the round continues around it. Each
  option carries the verdict choosing it applies, `fix` or `answer`; an
  `answer` option also carries the `reply_body` that explains the choice to
  the reviewer, so "Change the helper" is a fix and "Keep it local" is an
  answer with a short reason as its reply. Options stored before they carried
  a verdict are plain strings and read as `fix`.

A reply posts automatically only when the project's `postFactualReplies`
setting is on, and only for a factual verdict — fix, answer, already_done, or
follow_up. A decision is never auto-replied, since it is, by definition,
something argued rather than settled.

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
`fix` however large; that each decision option is `{label, verdict}`, an
`answer` option with its `reply_body`; and that triage ends only when every open item has a
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
- **Needs you (phase 2).** Each open decision is listed under its PR's row:
  the comment's author and text, triage's `decision_question`, one button per
  `decision_options` entry, and a free-text **Reply instead** field.
  `Board.answerDecision` stores the answer in `decision_answer` and moves the
  item to the next round (`round` one past the watch's) with the answer as its
  `approach`. An option button applies that option's verdict. A `fix` option
  leaves the item open with its backlog code task, made exactly as a triaged
  fix's is (§13.1), whose body quotes the question the answer was given to. An
  `answer` option handles the item with the option's `reply_body` and makes no
  task. A typed reply answers it as an `answer`: the item is handled, with the
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

### 13.5 Guardrails — phase 1 (publish guard) and planned amendments for phase 3

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

**Planned amendment to D8 (§1), not made here.** Phase 3 will add: the app,
never a worker, may fast-forward push a round branch to the head ref of an
open PR the human authored, without a human approval — but only after the
reviewer role accepts the round, every item in it is graded fixed or moot,
and the project's tests pass. Creating a branch, opening a PR, any
non-fast-forward push, and any push to a verified PR stay human-gated or
forbidden, unchanged. Until phase 3 lands, publishing's push (§13.1) is not
reachable: nothing in phases 1–2 writes to a remote.

**Planned amendment to §8, not made here.** Phase 3 will add: in a project
with the feature on, the follow-through triager and fixer spawns skip spawn
approval. Every cap in §8 — concurrent workers, the token cap, the daily
budget above, the session ceiling — still applies unchanged; only the
approval step is skipped, the same way a rostered agent is exempt from the
elapsed and idle caps today (§8) without being exempt from spend.

No agent in this feature runs with authority this section doesn't name here:
a worker still never pushes (§1, §8) until phase 3's amendment lands, and
even after it lands the fast-forward path above is the only new authority
granted — every other push and pull-request path keeps its existing human
gate.
