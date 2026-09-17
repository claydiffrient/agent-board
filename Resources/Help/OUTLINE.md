# Agent Board User Guide — outline and authoring contract

The plan for the user-guide epic: what the guide is, what each page owns, and
the conventions every page author writes against so fourteen pages written in
parallel merge and render as one book.

Nothing here is shipped content. This file is the epic's shared information
architecture; delete it when the guide is finished if it has stopped being true.

## Decisions

**The guide is an in-app SwiftUI window, not an Apple Help Book.** Preview's
guide is rendered by Help Viewer out of a `.help` bundle registered through
`CFBundleHelpBookFolder`. Rejected here for three reasons: Help Viewer resolves
a book through `helpd` and LaunchServices, which is unreliable for an ad-hoc
signed app that runs out of `.build/` rather than `/Applications`; the content
would have to be Apple-schema HTML rather than the Markdown the rest of this
repo is written in; and Help Viewer is a separate process, which this project
cannot verify at all — `osascript` and `screencapture` are denied here, and the
whole UI test corpus works by mounting views offscreen. An in-app window is
testable with `Tests/AgentBoardAppTests/OffscreenCapture.swift` on the day it is
written. It keeps the Preview layout: a table-of-contents sidebar, back /
forward / home, a title, and a search field.

**Pages are Markdown, bundled through SwiftPM, not by `Scripts/bundle.sh`.**
There is no `RELEASES.md` route to copy — the repo has no such file, and
`bundle.sh` copies only `Info.plist`, `AppIcon.icns` and every `.bundle` SwiftPM
emits. Declaring `resources: [.copy("../../Resources/Help")]` on the `AgentBoard`
target makes SwiftPM emit `AgentBoard_AgentBoard.bundle`, which `bundle.sh`'s
existing `for bundle in .build/"$config"/*.bundle` loop already copies. That path
also works for a bare `swift run`, where `Bundle.module` resolves beside the
executable. `bundle.sh` needs no edit. If a build somehow carries no guide, the
window says so in a sentence rather than showing an empty sidebar.

**The table of contents comes from page front-matter, not from a manifest.**
A manifest file is one file that fourteen tickets all append to, and this repo's
merges already break on less. Each page declares its own place; the window sorts
by `order`, then `slug`.

## Layout

```
Resources/Help/
  OUTLINE.md          this file — not bundled, not shown in the guide
  pages/<slug>.md     one page, one file
  images/<slug>-<n>.png
```

## Page front-matter

A page opens with a `---`-delimited block of `key: value` lines and nothing
else. Parsed narrowly: an unknown key is ignored, a missing required key is a
load error naming the file.

| Key | Required | Meaning |
|---|---|---|
| `title` | yes | Sidebar and page heading. Sentence case, no "Agent Board" prefix |
| `slug` | yes | Matches the filename. The deep-link anchor; never changes once shipped |
| `order` | yes | Sort key within its level. Tens, so a page can be inserted later |
| `parent` | no | The slug this page nests under. One level deep only |
| `summary` | yes | One sentence. Used on the Welcome page's cards and in search results |

## The pages

| Order | Slug | Parent | Owns |
|---|---|---|---|
| 10 | `welcome` | — | What Agent Board is; orchestrator / worker / board / worktree in four paragraphs; cards into the rest of the guide |
| 20 | `get-started` | — | Build and bundle, first launch, adding a project, what to expect from the first spawn |
| 30 | `at-a-glance` | — | The landing view, its headline, project cards, attention dots; the sidebar and workspaces |
| 40 | `orchestrator` | — | The orchestrator console: talking to it, what it may do, nudge / restart / stop, the report channel, compaction, cross-project messages |
| 10 | `approvals` | `orchestrator` | The waiting-on-you sidebar: blocked and stalled workers, spawn approvals, push and pull-request approvals, integration requests, reviews, proposals |
| 50 | `task-board` | — | Columns, cards, drag, the inspector, creating a task, promoting a proposal, archiving |
| 10 | `epics` | `task-board` | Creating an epic, lanes, dependencies, integration, closing and abandoning |
| 60 | `agents` | — | The Status roster: states, elapsed, spend against cap, last tool, reconcile, the ended-session grace window, attaching |
| 10 | `terminals` | `agents` | The project Terminal screen, worktree shells, the attach window, and why they carry your authority and not the board's |
| 70 | `notes` | — | Writing, sectioning, pinning and attaching notes; how agents read them |
| 80 | `settings` | — | Project settings, field by field: repository, workspace, caps, models, verification, isolation, publishing, archive, notifications, autonomy, classifier, extra MCP servers, delete |
| 10 | `caps-autonomy` | `settings` | What spend is counted, what a cap does when it is hit, the idle cap, and what autonomy on versus off changes |
| 20 | `notifications` | `settings` | Categories, muting, banner versus badge, and granting the system permission |
| 90 | `shutdown` | — | Stop All, the global Shut Down, grace periods, Quit Anyway, Cancel Shutdown, and where the work ends up |
| 100 | `troubleshooting` | — | A worker is blocked, stalled, dead, cap-killed, asleep; a worktree has gone; setup failed; the guide or the server will not load |

## Conventions for page authors

- **Write from the screen, not from `SPEC.md`.** The spec is a design record and
  says why; the guide says what to do. Open the source of the view you are
  documenting and describe what it actually draws today. Where the two disagree,
  the code wins and the disagreement is worth a note.
- **Second person, present tense.** "Click Attach to answer the prompt." Not
  "the user may attach" and not "we will attach".
- **One page owns a fact.** If a fact belongs to another page, link it. The page
  boundaries in the table above are the contract.
- **Link with `help://<slug>` or `help://<slug>#<heading-anchor>`.** These are
  the only internal links; the window resolves them and the drift-guard test
  fails on a target that does not exist.
- **No screenshots in the first pass.** Leave `<!-- image: what it should show -->`
  where one belongs; one later ticket captures them all so they match.
- **Headings are `##` and `###`.** The page's `title` is the `#`; do not repeat it.

## Dropped from this outline

**`shortcuts` (order 110) was cut.** The app defines exactly one custom
shortcut — ⌘S to save in the task inspector
(`Sources/AgentBoard/Views/TaskBoard/TaskInspectorView.swift:50`). Everything
else is SwiftUI's own Return/Escape on a sheet. A page would be one row and a
paragraph of Apple defaults. The ⌘S fact belongs on `task-board`, next to the
inspector it saves.

The ticket breakdown that turns this outline into work is `TICKETS.md`.
