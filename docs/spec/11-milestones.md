## 11. Milestones

**M0 — runtime spike. Swift, no UI. PASSED 2026-09-11, see `spike/`.** A throwaway Swift package — Hummingbird
server, SwiftTerm, no SwiftUI — that spawns `claude --bg` with a generated
`--settings` (hooks → localhost) and `--mcp-config` (one tool, bearer token),
and proves three things:

1. Hooks fire from a background session and reach the server.
2. The HTTP MCP server's tools appear in the session's tool list.
3. `claude attach <id>` renders correctly inside a SwiftTerm PTY, and detaching
   does not kill the session.

If (1) fails, D16 flips to owned PTYs. If (3) fails, D17 comes back into
question before any SwiftUI is written. **Nothing else is built until this
passes.** Written in Swift specifically so (3) is a real test rather than a
deferred assumption.

**M1 — board. DONE 2026-09-11 (headless E2E: assign → report_complete → accept, 16/16 checks).** Project registration, SQLite store, Task Board, Status,
worktree creation with the `memory` symlink, manual assignment, spend metering,
caps. Useful without any orchestrator.

**M2 — orchestrator. DONE 2026-09-11 (report channel verified live: Stop → notice → `list_reports` → consumed).** Orchestrator PTY, per-scope MCP tokens, `spawn_worker`,
the report channel, approvals sidebar, autonomy toggle.

**M3 — epics and integration. DONE 2026-09-12 (418/418 tests pass; the
approve → spawn → merge → report → PR flow verified in `EpicIntegrationTests`
against a fixture runtime — real worktrees and git operations, a fake
`claude --bg` process): approving an integration request spawns exactly one
integrator on the epic branch with the standard worker guards
(`--permission-mode auto`, `--strict-mcp-config`, the push/PR
`--disallowedTools`); its prompt lists task branches in dependency order and
skips ones already merged into the epic branch; the epic moves `active` →
`integrating` on spawn and to `done` in the same transaction as its
`report_complete`; and nothing on the path pushes or opens a PR).** Epic
entity, epic branches cut lazily at first task spawn into them, task
branches from the epic branch, integration worktree and integrator, human-
opened PR.

**M4 — notes. DONE 2026-09-15 (70 tests across `NoteStoreTests`,
`OpeningPromptNoteTests`, `OpeningPromptNoteWritingTests`, `NoteResourceTests`,
`WorkerNoteToolTests`, `SpawnNoteIndexTests`).** Note store, section ops, FTS,
pinning, attachment, spawn-time injection.

Notes is last deliberately: it is the lowest-risk screen and it benefits most
from knowing how the agents actually behave first.
