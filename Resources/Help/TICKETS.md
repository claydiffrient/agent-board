# User-guide epic — ticket catalog

Fourteen tickets. `OUTLINE.md` decides *what the guide is*; this file decides
*who builds which part of it*. Ticket 1 is the only one with no predecessor;
everything else waits on it.

Each ticket below is written to be pasted into a task body as-is. The
`Depends on` line is the ordering the board needs, not prose for the worker.

## Board ids

Created 2026-09-16 with `propose_task`, which has no epic parameter — every one
landed in **Proposed**, not in the user-guide epic. A human has to promote them
into the epic and set the `Depends on` edges; the tool cannot do either.

| # | Ticket | Board id |
|---|---|---|
| 1 | Help window shell and page loader | `970235ab-0964-4f86-8041-137e5a1f1eab` |
| 2 | Help menu, Cmd-?, per-screen help buttons | `f0c6d36f-d71c-484c-abd9-1a2cdc69474f` |
| 3 | Welcome and Getting started pages | `82755eb9-d9b2-46d7-98de-0b0214674f4b` |
| 4 | At a Glance page | `0f3db8df-1295-4114-aab8-9f7b8bdbbea2` |
| 5 | Orchestrator page + Waiting on you | `c35902d9-eaa8-4939-be88-c324d74f8d7e` |
| 6 | Task Board page + Epics | `eda60871-310f-4752-9a5a-525bb811c8b2` |
| 7 | Status roster page + Terminals | `58090d98-064a-4866-8c85-e2ed2548b17d` |
| 8 | Notes page | `45b45bbb-b9ee-4b2f-bc99-f05f1255faba` |
| 9 | Project settings page + Caps, Notifications | `0f373165-44ab-4184-82da-58d6fb3da680` |
| 10 | Shutdown page | `7d923625-bdef-44e1-8e96-2ba88200bdb0` |
| 11 | Troubleshooting page | `3f856939-03f4-4db5-bcf8-7bde4883470a` |
| 12 | Guide search | `4af84ee5-1b9e-4b9a-9be0-f58ee3a9636d` |
| 13 | Screenshots | `8c3c7c13-1549-41a3-b062-a1cfa3ef07fd` |
| 14 | Release notes | `baecc7b3-fe78-4eda-b59a-8ac69b2938ef` |

## Ordering

```
1  Help window shell and page loader          (blocks everything)
   |
   +-- 2  Help menu, Cmd-?, contextual help buttons
   +-- 3  Welcome and Getting started
   +-- 4  At a Glance
   +-- 5  Orchestrator (+ Waiting on you)
   +-- 6  Task Board (+ Epics)
   +-- 7  Status roster (+ Terminals)
   +-- 8  Notes
   +-- 9  Project settings (+ Caps & autonomy, Notifications)
   +-- 10 Shutdown
   +-- 11 Troubleshooting
            |
            +-- 12 Guide search        (needs pages to index)
            +-- 13 Screenshots         (needs pages and shell)
                     |
                     +-- 14 Release notes
```

Tickets 3-11 are mutually independent: each writes only its own files under
`Resources/Help/pages/`, and no two touch the same file. They collide nowhere
except `git merge`'s directory listing.

---

## 1. Build the Help window shell and page loader

**Depends on:** nothing. Blocks 2-14.

Build the window the guide renders in, and the loader that turns
`Resources/Help/pages/*.md` into it. Ship it with two throwaway placeholder
pages so the window is testable the day it lands; ticket 3 replaces them.

Scope:

- A SwiftUI window registered in `Sources/AgentBoard/AgentBoardApp.swift`
  alongside the existing `terminal` and `worktree-shell` `WindowGroup`s. Layout
  copies Preview's guide: a table-of-contents sidebar on the left, a toolbar
  with back / forward / home and a search field, and the page body on the right.
  The search field may be inert in this ticket — ticket 12 makes it work — but
  it must be drawn, so the toolbar layout is not relitigated later.
- Front-matter parsing exactly as `OUTLINE.md` specifies: a leading
  `---`-delimited block of `key: value` lines, unknown keys ignored, a missing
  required key a load error that names the file. No YAML dependency.
- The table of contents is built from the parsed front-matter, sorted by
  `order` then `slug`, nested one level via `parent`. There is no manifest file.
- `help://<slug>` and `help://<slug>#<anchor>` resolve to a page and scroll
  position. An unresolvable target is a test failure, not a silent no-op.
- Markdown rendering: headings, paragraphs, lists, tables, inline code, fenced
  code, links, and images from `Resources/Help/images/`. `AttributedString`'s
  Markdown parser does not do headings or tables, so this needs a small
  block-level splitter in front of it. Do not add a Markdown package.
- Bundling: add `resources:` to the `AgentBoard` target in `Package.swift` so
  SwiftPM emits `AgentBoard_AgentBoard.bundle`. `Scripts/bundle.sh` already
  copies every `.bundle` and needs no edit. A build with no guide resource shows
  one sentence saying the guide is not bundled, not an empty sidebar.
- Tests in `Tests/AgentBoardAppTests/`, mounted offscreen through
  `OffscreenCapture.swift` like every other view test here. Cover: front-matter
  round-trip, a missing required key naming the file, TOC order and nesting,
  every `help://` target in the shipped pages resolving, and the
  no-guide-bundled sentence.
- New SPEC.md section. `SPEC.md` has 12 top-level sections; the guide is a
  screen, so it belongs as a subsection of §10 Screens. Cite it from the new
  code the way 17 files here already do (`SPEC §10.x`).

**Where:** `Sources/AgentBoard/Views/Help/` (new), `AgentBoardApp.swift`,
`Package.swift`, `SPEC.md` §10, `Tests/AgentBoardAppTests/`.

---

## 2. Reach the guide from the app: Help menu, Cmd-?, and per-screen help

**Depends on:** 1.

The window from ticket 1 has no way in. Give it three:

- A `CommandGroup(replacing: .help)` in `AgentBoardApp.swift` with
  "Agent Board Help", bound to Cmd-? (`keyboardShortcut("?", modifiers: .command)`).
- A help button on each of the six screens that opens the guide at that
  screen's page: At a Glance, Orchestrator, Terminal, Task Board, Status, Notes.
  Route it through the `help://<slug>` resolver from ticket 1, so a renamed slug
  fails a test rather than opening the wrong page.
- The project settings sheet gets one too, pointed at `help://settings`.

Test that each screen's button names a slug that exists — that is the assertion
that keeps this from rotting.

**Where:** `AgentBoardApp.swift`, `Views/MainWindow.swift`, the six screen
views, `Views/ProjectSettingsSheet.swift`.

---

## 3. Write the Welcome and Getting started pages

**Depends on:** 1. Replaces ticket 1's placeholder pages.

Two pages: `welcome` (order 10) and `get-started` (order 20).

`welcome` says what Agent Board is and defines the four words the rest of the
guide leans on — orchestrator, worker, board, worktree — in four paragraphs, no
more. It ends with cards linking into the rest of the guide.

`get-started` covers: building and bundling (`swift build`, `Scripts/bundle.sh`,
and why the `.app` matters — AppKit needs a bundle id for notifications),
first launch, adding a project, and what actually happens on the first spawn so
a new user knows whether it worked.

**Where:** `Resources/Help/pages/welcome.md`, `pages/get-started.md`.

---

## 4. Write the At a Glance page

**Depends on:** 1.

One page: `at-a-glance` (order 30). Owns the landing view and the window chrome
around it — the headline, project cards, attention dots, the workspace sidebar,
and the account usage footer.

Read `Views/AtAGlanceView.swift`, `Views/WorkspaceSidebar.swift`,
`Views/SidebarAttention.swift`, `Views/AccountUsageFooter.swift`. Describe what
those draw today, not what `SPEC.md` §10 planned.

**Where:** `Resources/Help/pages/at-a-glance.md`.

---

## 5. Write the Orchestrator page and its Waiting on you sub-page

**Depends on:** 1.

`orchestrator` (order 40) and `approvals` (order 10, parent `orchestrator`).

`orchestrator` owns the console: talking to it, what it is allowed to do on its
own, nudge / restart / stop, the report channel, compaction, and cross-project
messages.

`approvals` owns the sidebar of things waiting on a human: blocked and stalled
workers, spawn approvals, push and pull-request approvals, integration requests,
reviews, and proposals. Say for each what clicking the affirmative button
actually does, because several of them do two things.

Read `Views/Orchestrator/OrchestratorView.swift`,
`Views/Orchestrator/ApprovalsSidebar.swift`,
`Views/Orchestrator/MessageRow.swift`, `Services/OrchestratorConsole.swift`,
`Services/ReportNoticeGate.swift`, and `SPEC.md` §9.

**Where:** `Resources/Help/pages/orchestrator.md`, `pages/approvals.md`.

---

## 6. Write the Task Board page and its Epics sub-page

**Depends on:** 1.

`task-board` (order 50) and `epics` (order 10, parent `task-board`).

`task-board` owns columns, cards, drag, the inspector, creating a task,
promoting a proposal, and archiving. It also owns the app's one custom keyboard
shortcut: Cmd-S saves in the task inspector
(`Views/TaskBoard/TaskInspectorView.swift:50`). There is no shortcuts page;
that fact lives here.

`epics` owns creating an epic, lanes, dependencies, integration, and closing
versus abandoning.

Read `Views/TaskBoard/` in full and `SPEC.md` §5.

**Where:** `Resources/Help/pages/task-board.md`, `pages/epics.md`.

---

## 7. Write the Status roster page and its Terminals sub-page

**Depends on:** 1.

`agents` (order 60) and `terminals` (order 10, parent `agents`).

`agents` owns the Status roster: each state and what it means, elapsed time,
spend against cap, last tool, reconcile, the ended-session grace window, and
attaching.

`terminals` owns the project Terminal screen, worktree shells, the attach
window, and the reason they run with your authority rather than the board's —
that distinction is already decided in `SPEC.md` and is the thing users get
wrong.

Read `Views/Status/StatusView.swift`, `Views/Terminal/`,
`Services/ShellConsole.swift`, and `SPEC.md` §10.

**Where:** `Resources/Help/pages/agents.md`, `pages/terminals.md`.

---

## 8. Write the Notes page

**Depends on:** 1.

One page: `notes` (order 70). Writing a note, sections, pinning, attaching, and
— the part users cannot see from the UI — how an agent reads notes:
`search_notes`, `read_note`, and the `note://` resource route.

One measured constraint belongs here: an unattended worker can read an MCP
resource but cannot fetch an MCP prompt. Do not restate the reasoning; say what
it means for someone deciding where to put guidance.

Read `Views/Notes/`, `SPEC.md` §6.

**Where:** `Resources/Help/pages/notes.md`.

---

## 9. Write the Project settings page and its two sub-pages

**Depends on:** 1.

`settings` (order 80), `caps-autonomy` (order 10, parent `settings`),
`notifications` (order 20, parent `settings`).

`settings` walks `Views/ProjectSettingsSheet.swift` section by section, in the
order the sheet draws them: Repository, Workspace, Caps, Models, Verification,
Isolation, Publishing, Archive, Notifications, Autonomy, Permission classifier
(autoMode), Extra MCP servers, and delete. One row per field, saying what it
does and what happens when it is left empty.

Two fields need more room than a row, so they get their own pages.
`caps-autonomy` covers what spend is counted (uncached input plus output; cache
writes are never counted), what a cap does when it is hit, the idle cap, and
what autonomy on versus off changes. `notifications` covers categories, muting,
banner versus badge, and granting the system permission.

Two traps to get right, both verifiable in code before you write the sentence:
the Extra MCP servers field has a UI but its value may not reach a worker — check
`Services/WorkerSupervisor.swift` before claiming it does; and the permission
classifier does not stop a worker on its own, only `--disallowedTools` and the
PreToolUse guard do.

**Where:** `Resources/Help/pages/settings.md`, `pages/caps-autonomy.md`,
`pages/notifications.md`.

---

## 10. Write the Shutdown page

**Depends on:** 1.

One page: `shutdown` (order 90). Stop All, the global Shut Down, grace periods,
Quit Anyway, Cancel Shutdown, and — the question people actually have — where
the work ends up when a worker is stopped mid-task.

Read `Views/Orchestrator/ShutdownSheet.swift`,
`Views/Orchestrator/GlobalShutdownSheet.swift`, and the shutdown tests in
`Tests/AgentBoardAppTests/`, which pin the behaviour more precisely than the
views do.

**Where:** `Resources/Help/pages/shutdown.md`.

---

## 11. Write the Troubleshooting page

**Depends on:** 1.

One page: `troubleshooting` (order 100). Symptom first, in the words a user
would use, then the check, then the fix. Cover at minimum: a worker is blocked;
stalled; dead; killed by a cap; the laptop slept and the idle cap counted the
sleeping minutes; a worktree is gone; setup failed; the guide or the MCP server
will not load.

Two of these have measured answers in this project's notes rather than in the
code — a worker survives the board going away and recovers with no handshake,
and a laptop asleep still burns idle-cap minutes. Check a dead worker's branch
for commits before telling anyone to retry.

**Where:** `Resources/Help/pages/troubleshooting.md`.

---

## 12. Make the guide's search field work

**Depends on:** 1, and pages 3-11 for anything worth indexing.

Ticket 1 draws the search field; this makes it search. Index each page's
`title`, `summary`, and body text at load. Results list title plus the page's
`summary` — that is what the `summary` front-matter key exists for. Rank title
matches above body matches. Selecting a result opens the page and highlights the
first hit.

No new dependency and no index file on disk: fifteen pages fit in memory and
rebuild in milliseconds.

Test that a query matching only a body word finds its page, and that a query
matching a title outranks one matching a body.

**Where:** `Sources/AgentBoard/Views/Help/`, `Tests/AgentBoardAppTests/`.

---

## 13. Capture and place every screenshot

**Depends on:** 3-11 (every page's `<!-- image: ... -->` marker must exist).

Pages 3-11 leave `<!-- image: what it should show -->` where a screenshot
belongs, and ship none. This ticket captures them all in one pass so window
chrome, theme, and window size match across the whole guide.

`osascript` and `screencapture` are denied in this project's agent environment.
The route that works is mounting the view offscreen through
`Tests/AgentBoardAppTests/OffscreenCapture.swift` and writing the image out —
read the project's headless-UI-verification note before starting, because
several obvious approaches are blocked outright.

Replace each marker with the image, name files `<slug>-<n>.png`, and give every
image alt text, since alt text is what a screen reader gets.

**Where:** `Resources/Help/images/`, every file under `Resources/Help/pages/`.

---

## 14. Write release notes for the user-guide epic

**Depends on:** 13.

One pass over everything the epic shipped, written for someone who uses the app
and does not read commits. Says what is new, where to find it (Help menu,
Cmd-?), and what the guide does not yet cover.

**Where:** wherever this project keeps release notes at the time.
