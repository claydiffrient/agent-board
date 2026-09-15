# Agent Board

Native macOS app that manages work for Claude Code agents. See `SPEC.md` for the
design and `IDEA.md` for the origin. Status: M0, M1, M2, and M3 complete.

## Layout

| Target | Role |
|---|---|
| `AgentBoardCore` | GRDB store: schema (SPEC §4), records, stores, `Board` lifecycle facade |
| `AgentBoardRuntime` | `AgentRuntime` protocol + `BackgroundSessionRuntime` (`claude --bg`), config writer, worktrees, memory symlink, transcript meter, pricing, caps |
| `AgentBoardServer` | Hummingbird localhost server: `/hooks` and `/mcp`, bearer-scoped tools |
| `AgentBoardBridge` | Store-backed hook sink, token resolver, and the worker and orchestrator MCP tool handlers |
| `AgentBoard` | SwiftUI app: Task Board, Status, terminal attach window, supervisor glue |
| `spike/` | M0 runtime spike, kept as the reference for the proven runtime facts |

## Build and run

```
swift build
swift test
Scripts/bundle.sh            # wraps the binary in .build/AgentBoard.app (bundle id needed for notifications)
open .build/AgentBoard.app
```

Environment overrides: `AGENTBOARD_DB` (sqlite path), `AGENTBOARD_SUPPORT_DIR`
(session configs, server port file, and worktrees). Default support dir is
`~/Library/Application Support/AgentBoard`; worktrees default to
`~/.agentboard/worktrees/<project-id>` instead, because a worktree path with a
space in it breaks any repo whose setup shells out without quoting it. Setting
`AGENTBOARD_SUPPORT_DIR` still redirects worktrees to `<dir>/worktrees`, which is
what keeps the headless check below inside its scratch directory. A worktree root
containing a space is refused, both at project registration and in the project
settings sheet; projects still recorded on the old spaced root are relocated with
`git worktree move` at launch, skipping any project with a running session.

## Headless end-to-end check

Spawns one real worker in a git repo, waits for `report_complete`, merges the
task branch, accepts, and verifies the worktree and the merged branch are gone:

```
AGENTBOARD_SUPPORT_DIR=/tmp/ab AGENTBOARD_DB=/tmp/ab/agentboard.sqlite \
AGENTBOARD_E2E_REPO=/path/to/fixture-repo .build/debug/AgentBoard
```
