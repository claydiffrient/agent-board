# Agent Board

Native macOS app (SwiftUI) that manages work for Claude Code agents. `SPEC.md` is the design record; `IDEA.md` is the origin note.

## Build and test

```
swift build                              # ~9 min cold; passes with pre-existing warnings only, no errors
swift test                               # the whole suite, several minutes
swift test --list-tests | wc -l          # the count, without running anything
swift test --filter <TestTargetName>     # one target, e.g. AgentBoardServerTests
swift test --filter <SuiteClassName>     # one suite, e.g. ApprovalMigrationTests
```

**Measure the baseline yourself before you change anything.** No count is written down here: the suite grows every day and a number in this file would be wrong more often than right. `swift test --list-tests | wc -l` at the start, and `swift test`'s final `Executed N tests, with 0 failures` line at the end, are what you diff against.

Run both unpiped. `swift build | tail` reports the pipeline's exit status rather than swiftpm's, and piping `swift test` through `head` or `tail` throws away the name of whatever failed — redirect to a file and grep it instead.

`--filter` takes a regex matched against the fully-qualified test identifier, so a target name or a suite (XCTestCase subclass) name both work as shown above.

## Module layout

Dependency direction, from `Package.swift` and each target's actual `import` lines (verified — no target imports beyond its declared dependencies):

```
AgentBoardCore  (deps: GRDB only)
AgentBoardServer  (deps: Hummingbird/NIO/HTTPTypes/Logging only)
        ^                    ^
        |                    |
AgentBoardRuntime      (deps: AgentBoardCore)
        \                    /
         AgentBoardBridge  (deps: AgentBoardCore, AgentBoardServer, GRDB)
                    |
                 AgentBoard  (deps: all four, + SwiftTerm, SwiftUI/AppKit)
```

`AgentBoardCore` and `AgentBoardServer` are independent bases — neither imports the other. Where a new type belongs:

- Pure domain/persistence (schema, records, stores, the `Board` lifecycle facade) with no process or network concerns → `AgentBoardCore`.
- Anything that runs or manages a process (`claude --bg`, worktrees, config writing, the transcript meter) and needs Core's types but nothing from Server → `AgentBoardRuntime`.
- Pure localhost HTTP/MCP transport with no board-domain knowledge → `AgentBoardServer`. It does not import `AgentBoardCore`; keep it that way.
- Anything that connects domain to transport — the hook sink, MCP tool handlers — → `AgentBoardBridge`.
- SwiftUI views, AppKit glue, and the supervisor tying Runtime/Bridge/Core together → `AgentBoard`.

Each test target mirrors the target it tests one-to-one (`AgentBoardCoreTests` -> `AgentBoardCore`, etc.), except `AgentBoardRuntimeTests` also imports `AgentBoardCore` directly (fixtures use Core types) and `AgentBoardAppTests` imports the whole stack plus `AppKit`/`ApplicationServices`/`SwiftUI`.

## SPEC.md

`SPEC.md` has 12 numbered top-level sections (some with numbered subsections, e.g. §3.1, §5.2, §9.1). Doc comments across the codebase cite them inline at the point they matter (`SPEC §9.1`, `SPEC §5.2 step 4, D8`) — 17 source/test files do this today. When a change alters behavior a SPEC section describes, update that section's text in the same change and cite it from the new code the same way existing comments do; don't leave a doc comment citing a section whose described behavior you just changed elsewhere.

## Conventions

Comments are sparse by default (`AgentBoardCore` runs ~5% comment lines). A `///` doc comment appears only on a non-obvious type, enum case, or behavior (an invariant, a SPEC citation, a reason something is shaped as it is) — not on self-explanatory properties, initializers, or straightforward bodies. Match that density; don't add narrative comments.

## Files that collide

- `Sources/AgentBoard/Services/WorkerSupervisor.swift` (~1,600 lines) — most features add a case to `SupervisorError` and wire it into `start()`.
- `Sources/AgentBoard/Services/WorkerSupervising.swift` — the protocol; a new method here breaks every conformer at compile time, not merge time. Current stub/mock conformers, each needing the same new method: `Sources/AgentBoard/AppComposition.swift` (`StubSupervisor`, used by previews), `Tests/AgentBoardAppTests/AtAGlanceLaunchCostTests.swift`, `Tests/AgentBoardAppTests/AtAGlanceRowRenderTests.swift`, `Tests/AgentBoardAppTests/ShutdownSheetRenderTests.swift`.
- `Sources/AgentBoardCore/AppDatabase.swift`'s migration list and `Tests/AgentBoardCoreTests/ApprovalTests.swift:32` — the file registers migrations one at a time; the test pins their exact identifiers as one ordered array literal. Add a migration in one without the other and the test fails on the mismatch, not on git.
- `SPEC.md` — most features touch their own section, so branches editing adjacent sections conflict often.

This project's shared notes (`search_notes`) cover headless UI verification on a machine with no display, and why a clean git merge here often does not compile — read those before assuming either works the way you'd expect; their content is not repeated here.
