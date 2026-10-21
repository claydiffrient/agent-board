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
to make. **Phase 2** delivers triaging and parking on a stacked or forked PR.
**Phase 3** delivers fixing, checking, and publishing's push. **Phase 4**
delivers stale, the rest of parked, and feeding CI and verification failures
back into items.

- **watching** — polled every 60s. Leaves on new feedback (an unresolved
  thread, a review body, a failed required check, a merge conflict) or when
  the PR becomes ready to verify.
- **settling** *(phase 1 holds the wait; phase 2 is what the wait is for)* —
  waits until no new item has arrived for `settleMinutes` (default 10). Holds
  for the daily budget, AC power, and the concurrency cap (§8) before leaving.
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
  verification label absent. The checks on the head commit reduce to one
  of success, pending or failure, and only success is green:
  - When the base branch requires checks — the contexts its branch
    protection (`refUpdateRule.requiredStatusCheckContexts`) or a ruleset's
    required status checks name — only those count. A required check that
    has not reported yet is pending, so a PR is never ready in the moment
    after a push before CI has registered anything.
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
  The required checks and each check's result come from the same per-repo
  `gh api graphql` query as the rest of the poll, so no `gh` call is added
  per PR. New feedback arriving here first sends the PR back to settling.
- **verified** *(phase 1 reads the label; phase 3's freeze is what it is
  frozen against)* — the verification label is present. The PR is frozen:
  Agent Board never pushes to it again, and any new feedback on it becomes a
  decision item rather than restarting the round. Removing the label
  re-evaluates it: readyToVerify if it still qualifies, otherwise watching.
- **stale** *(phase 4)* — the head moved out from under the round. Drop the
  round's worktree and go to settling.
- **parked** *(phase 2 for the stacked/forked cases; phase 4 for the
  round-cap and failed-session cases)* — reached when the round cap is hit,
  three fixer sessions fail in a row, the PR is stacked (its base is not the
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
never resolved and an approving body is not feedback. Phase 1 moves a watch
only among watching, readyToVerify and verified, by the rules above, and a
watch whose PR has left the open list settles to merged or closed by
`gh pr view`. A PR converted back to draft still appears in the search, marked
draft; its watch is deleted with its items, and undrafting it brings it back
through the search as a new watch. A `gh` that is missing or not logged in
records one `pr_poll_problem` row per enabled project, which raises that
project's attention badge until a poll succeeds; it is written once, not on
every poll. Any other search failure (network, rate limit) is logged; after 10
in a row it records the same row with a reason saying the search is failing,
and the next successful search clears it.

Items are keyed by the GitHub node id of the thread or check they came from,
so each is handled once per round; a new reply on a thread already handled
reopens it. The human's own comments, resolved threads, and outdated threads
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
  Advanced (§10), holds every setting in §13.3 except `roles`, whose agent
  pickers arrive in phase 2. Its sections are **Watch** (`enabled`, settle
  window, round cap, daily budget — empty means the spawn caps),
  **Verification** (label — empty means the merge verifies — required
  approval, and the verify command with its `{url}` placeholder),
  **Replies** (`postFactualReplies`, captioned with which verdicts count as
  factual), and **Publish guard** (the `privateTerms` list: each term a row
  with a remove button, plus a field that adds one on Return). Save trims
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
