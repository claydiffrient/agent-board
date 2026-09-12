# M0 runtime spike

Throwaway Swift package that proves the three runtime assumptions in SPEC.md §11.
Not part of the app.

```
swift build
.build/debug/Spike no-attach      # (1) hooks and (2) MCP; leaves the probe session running
.build/debug/Spike                # same, then opens a SwiftTerm window on `claude attach`; close it for (3)
.build/debug/Spike attach <id>    # just the terminal window on an existing background session
.build/debug/Spike shell          # terminal window running zsh, no Claude involved
.build/debug/Spike serve [token]  # server only; prints PORT= for curl testing
```

`SPIKE_AUTOCLOSE=<seconds>` closes the attach window automatically.
Paths are hard-coded to a session scratchpad in `main.swift`; adjust `scratch`
before running elsewhere. Each run spawns a real Claude Code session in the
fixture repo; stop and remove it with the `cleanup:` line the run prints.
