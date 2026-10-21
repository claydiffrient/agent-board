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
  verification label absent. New feedback arriving here first sends the PR
  back to settling.
- **verified** *(phase 1 reads the label; phase 3's freeze is what it is
  frozen against)* — the verification label is present. The PR is frozen:
  Agent Board never pushes to it again, and any new feedback on it becomes a
  decision item rather than restarting the round. Removing the label returns
  it to watching.
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
  **Pause**.
- The row's badge counts Ready to verify plus open decision items. A decision
  also raises the owning project's attention dot (§9), the same signal a
  pending approval raises.
- At a Glance's headline (§10) gains "N PRs ready to verify" beside the
  review count, each project's card gains its own count, and clicking either
  opens the Pull Requests page filtered to that project.
- A notification banner fires when a PR enters readyToVerify (once per head
  oid) and when a decision item arrives.
- A seventh project-settings tab, **PR Follow-Through**, placed after
  Advanced (§10), holds every setting in §13.3.

### 13.5 Guardrails — phase 1 (publish guard) and planned amendments for phase 3

**The publish guard**, live from phase 1 regardless of whether follow-through
itself is enabled: `BranchPublisher` refuses any push or pull-request body
whose diff, commit messages, branch name, title, or body contains one of the
project's `privateTerms`, case-insensitively. This is what lets a public
project (this one) sit beside a private one in the same install without a
work-specific name ever reaching a shared remote by accident.

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
