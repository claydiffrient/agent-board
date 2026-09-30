## 1. Decisions

Each decision below was made explicitly. The rationale is one line; the
alternative named is the one worth reconsidering if the decision goes wrong.

| # | Decision | Rationale | Rejected |
|---|---|---|---|
| D1 | Standalone app; owns its own state | Solo's MCP surface is a tool API for agents, not a query API for a UI | Front-end over Solo |
| D2 | PTY for interaction, hooks + transcript for state | Terminal gives full Claude Code fidelity; hooks make Status honest | Headless `-p` only |
| D3 | Agent Board owns tasks in its own store | Self-contained; no coupling to `repo-tasks` file format | `repo-tasks` as backing store |
| D4 | Tiered authority enforced at the token | Prompts are not a permission system | Flat authority |
| D5 | Budgeted autonomy with caps | Recorded session ids + `--resume` make cap-kills non-destructive | Manual gate on every spawn |
| D6 | Worktree per task, branch bound to task id | A retry sees what the previous attempt built | Worktree per agent session |
| D7 | Fixed columns: Proposed → Backlog → Ready → Running → Review → Done | The orchestrator must be told which column is assignable | User-defined columns |
| D8 | Workers commit and stop. They never push. The orchestrator may push and open a pull request, but only through named tools that each wait on a human approval | Nothing reaches a shared remote unattended; the last step of an epic stops being manual without handing an agent a shell it can aim anywhere | Worker opens a draft PR; unblocking `gh` in Bash for the orchestrator |
| D9 | Reports queue in SQLite; app injects a fixed notice; orchestrator pulls | Worker text never enters the orchestrator's user-authority turn | Inject report text into PTY |
| D10 | Epics group tasks and own the integration branch | Merge scope becomes a lookup, not a judgment call | Flat tasks |
| D11 | One orchestrator per project | cwd determines which CLAUDE.md, skills, and MCP servers load | One global orchestrator |
| D12 | Notes are Agent Board's own store, Solo-scratchpad-shaped | Notes are a working surface, not Claude Code memory | View over `~/.claude/.../memory/` |
| D13 | Task/epic-attached notes injected in full at spawn; every other note indexed by title and `note://` uri, fetched on demand | Stops three workers rediscovering the same constraint without charging every worker for every pinned note | Inject pinned notes in full too |
| D14 | Workers run `--permission-mode auto` | The shipped classifier already encodes 70 soft-deny rules | Hand-rolled PreToolUse denylist |
| D15 | Blocked agents are answered by attaching to their real terminal | Auto mode's prompt text is written to be read; don't reproduce it | Native approval dialog |
| D16 | Workers are `claude --bg` background sessions | Deletes process supervision, crash recovery, and scrollback from scope | App owns the PTYs |
| D17 | Swift + SwiftUI | Literal reading of "native Mac app" | Tauri |
| D18 | Runtime spike → board → orchestrator → epics → notes | The riskiest assumption is provable in 200 lines | Build everything |
| D19 | The Terminal screen and worktree shells (§10) run with the human's own authority: `IntegrationGuard` and `--disallowedTools` deliberately do not gate them, and no Agent Board grant token may reach the shell's environment | A human typing `git push` is entitled to push — those mechanisms bound what an unattended agent may do under `--permission-mode auto`, and there is no agent here; a shell holding a grant token would let anything running in it act with that session's authority over the board | Route the shell through a worker-scoped grant |
| D20 | A cross-project roster of archetypes (§4) — board-local, or read from `.claude/agents` definitions — assigned a task with `assign_to_agent` and returned to the queue with `hand_off` (§6) | The role outlives any single task even though no session can (a `claude --bg` session cannot move to another working directory), so each assignment instantiates the archetype in a fresh session, and mediating handoff through the board queue keeps D6's worktree-per-task model instead of building a second coordination path | Hive's model: every agent works on `main`, and a privileged orchestrator arbitrates conflicts between them |

**D6 amended.** As first written, D6 said every task gets its own worktree and
its own branch bound to the task id. That now holds only under
`worktreeStrategy: worktree` (§4) — the default, so no existing project changes
on upgrade. Under `shared`, a task instead runs in the project's own checkout,
co-resident with up to `sharedCheckoutMaxAgents` others, all committing to one
branch named for their shared base rather than to `agentboard/<task-id>`
(§3.1). A task under `shared` no longer owns a branch; it owns an attributed
range of commits on a branch it shares, recorded in `task_commit` (§4) rather
than in the branch name, and acceptance waits for every task on that branch
before any of it is merged into the epic (§5). `auto` picks between the two per
spawn — share only when a compatible group already holds the checkout with
room, worktree otherwise (§3.1) — and starts no group of its own.

Two costs are the deliberate price of `shared`, not a gap in it. Per-task
revert is gone: rejecting a task after a sibling on the same branch has already
been accepted means unpicking commits, and Agent Board does not do that — the
branch waits for every member to be accepted before any of it merges (§5),
which is the epic's answer, not a fix for it. And a shared-checkout agent is
editing the human's own working copy: its writes land in whatever editor
already has that checkout open, and the branch under it moves as siblings
commit, not only as the human's own tools move it.

What the amendment leaves untouched: a worker still commits and stops — through
`commit_my_work` rather than `git commit` under `shared` (§8), but a commit
either way — and still never pushes, still refused by `IntegrationGuard` at the
`PreToolUse` layer, regardless of placement. D8 governs that refusal and is
unchanged by this amendment.

**D8 amended.** As first written, D8 said the pull request was opened by the
human and by nobody else, and §5.2 step 5 said the same. The orchestrator half
of that is now relaxed: the orchestrator may call `push_branch` and
`open_pull_request` (§6), each of which creates an approval row and stops there.
Nothing reaches the remote until a human grants it, autonomy setting regardless,
so "nothing reaches a shared remote unattended" is unchanged — what changed is
who may ask. The refusal the amendment is careful *not* to relax: unblocking
`gh` in Bash for orchestrator sessions would have been one line, and would have
granted every GitHub operation the user's token can reach, on every repository,
with no record on the board. The tools are narrow on purpose — `push_branch`
refuses any branch that is not `agentboard/<something>` or the project's base
branch, and there is no tool that merges a pull request.

**The worker half of D8 is untouched.** Workers commit on their branch and stop.
They never push, never open a pull request, and the two controls in §8 that
enforce it are unchanged for them.

Pivots named at decision time, to be designed for but not built:

- **D16 → owned PTYs.** All process interaction goes through an `AgentRuntime`
  protocol. `BackgroundSessionRuntime` ships; `OwnedPtyRuntime` is the pivot.
- **D17 → Tauri.** This is a rewrite, not a swap. The only hedge worth building
  is keeping two artifacts language-neutral: the SQLite schema (§4) and the
  localhost HTTP/MCP contract (§6, §7). A Tauri build inherits both.
