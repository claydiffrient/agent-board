# Board-unreachable probe (2026-09-16, Claude Code 2.1.273)

What a live `claude --bg` worker does when the board's HTTP server — MCP at
`/mcp` and the hook sink at `/hooks` — stops answering, and whether it recovers
when the endpoint returns. Sizing input for the remote-worker/SSH-tunnel epic.

`board.py` is a stand-in for `BoardServer`: same wire shape (bearer token on
`/mcp`, `?token=` on `/hooks`, `Mcp-Session-Id` set on `initialize`), on a fixed
port so it can be killed and rebound. Two failure modes:

```
python3 board.py serve        # answers normally
python3 board.py blackhole    # accepts the TCP connection, never writes a byte
```

`serve` killed = **connection refused** (the tunnel process died and released the
port). `blackhole` = **the tunnel is up but its far end is gone** — the realistic
wifi-change / lid-close failure, and the expensive one.

The workers are real. `prompt-persevere.txt` tells the model to keep going
through failures; `prompt-neutral.txt` says nothing about failure at all, so it
measures what the model does unprompted.

## Setup

```
BOARD_PORT=8791 BOARD_TOKEN=spiketoken BOARD_LOG=$J/events.jsonl \
  python3 board.py serve &

cd $J/repo && claude "$(cat prompt-persevere.txt)" --bg -n outage-a \
  --permission-mode auto --strict-mcp-config \
  --mcp-config $J/config/mcp.json --settings $J/config/settings.json
```

`settings.json` is what `SessionConfigWriter.settingsObject` writes: `type: "http"`,
`timeout: 5`, `PreToolUse` matched to `Bash`, plus the `curl -m 5` `SessionStart` hook.

## Run A — connection refused, 2m12s outage

Down at 16:55:50, back on the same port at 16:58:02. Transcript
`974c0f27-0105-40bd-b3c2-e361bb6924dc.jsonl`:

```
16:55:20 USE  Bash {"command": "date \"+%H:%M:%S\" && sleep 4"}     <- baseline
16:55:31 RES  ok  16:55:25
16:55:48 USE  mcp__agent-board__agent_board_ping {"message": "3"}
16:55:51 RES  ERR Unable to connect. Is the computer able to access the url?
16:55:52 USE  Bash {"command": "date \"+%H:%M:%S\" && sleep 4"}
16:56:03 RES  ok  16:55:55
16:56:21 USE  mcp__agent-board__agent_board_ping {"message": "4"}
16:56:25 RES  ERR Unable to connect. Is the computer able to access the url?
...
16:58:24 USE  mcp__agent-board__agent_board_ping {"message": "7"}
16:58:32 RES  ok  pong from agent board: 7
```

- The MCP call **errors in ~3s** (16:55:48 -> 16:55:51) with `is_error: true` and the
  text `Unable to connect. Is the computer able to access the url?`. It does not
  hang, and the session does not die: `claude agents --json` reported
  `status busy state working` throughout.
- Bash kept running at the **unchanged** rate — 16:55:52 -> 16:56:03 is 11s, the same
  11s as the pre-outage 16:55:20 -> 16:55:31. A refused `PreToolUse` costs nothing.
- Four consecutive failures (pings 3-6), then the first call after the server came
  back **succeeded on the first attempt**, 22s after rebind (server up 16:58:02,
  call at 16:58:24).

### Every hook in the outage window was dropped, none replayed

```
$ python3 -c "... print rows where '16:55:50' <= iso <= '16:58:30' ..."
16:58:08.386 PostToolUse Bash
16:58:11.947 PreToolUse Bash
16:58:16.874 Smoke2 None
16:58:20.054 PostToolUse Bash
```

Nothing between 16:55:50 and 16:58:02. The transcript shows 7 `Bash` tool_use and
4 MCP calls in that window, i.e. ~18 hook POSTs, all lost. The first hook after
rebind (16:58:08) is the *current* event; there is no backlog. Hooks are
fire-and-forget with no client-side retry or queue.

### The client never re-initializes, and the board never checks the session id

```
$ every `initialize` and every server bind
16:51:25.588 server-up
16:51:26.273 mcp initialize        <- my own curl smoke test
16:53:39.017 mcp initialize        <- the worker, once
16:58:02.048 server-up             <- restart; no initialize follows

$ distinct Mcp-Session-Id the client sent
4b0cbeb9-a701-4b40-a8da-9aa875506a37 first 16:53:47.526 last 17:00:55.127 count 10
```

One handshake for the whole session. The client kept sending the pre-outage
`Mcp-Session-Id` across the restart and the stand-in ignored it.

The real board ignores it too, and that is what makes recovery work:
`Sources/AgentBoardServer/BoardServer.swift:154` **writes** the header on
`initialize` and no line anywhere **reads** it off a request — `grep -n
'Mcp-Session-Id\|sessionIdHeader' Sources/AgentBoardServer/*.swift` returns only
the declaration at :21 and the write at :154. Authorization is the bearer token
alone, and that token is DB-backed (`StoreTokenResolver` -> `TokenGrantStore`), so
it survives an app relaunch. There is no per-session server state for a restart
to invalidate. If anyone ever adds `Mcp-Session-Id` validation, every worker
alive across a board restart breaks instantly.

## Run B — blackhole (tunnel up, far end dead), 10 min

Swapped at 17:23:23 with the worker mid-loop. Baseline immediately before, then
the swap, from `de2f7a0a-e56c-4238-b2f3-ce3d39cc0755.jsonl`:

```
17:23:10.372 USE  Bash {"command": "date \"+%H:%M:%S\""}        <- server up
17:23:12.202 RES  ok  17:23:11                                   = 1.83s
17:23:19.039 USE  mcp__agent-board__agent_board_ping {"message": "8"}
17:23:21.779 RES  ok  pong from agent board: 8                   = 2.74s
--- blackhole up 17:23:23.377 ---
17:23:23.440 USE  Bash {"command": "date \"+%H:%M:%S\""}
17:23:33.705 RES  ok  17:23:28                                   = 10.3s
17:23:48.885 USE  mcp__agent-board__agent_board_ping {"message": "9"}
17:24:50.716 RES  ERR The operation timed out.                   = 61.8s
17:24:55.274 USE  Bash {"command": "date \"+%H:%M:%S\""}
17:25:05.646 RES  ok  17:25:00                                   = 10.4s
```

- **The MCP call hangs ~62s**, not 5s, before returning `The operation timed out.`
  A different error string from the refused case, and 20x the cost.
- **A `Bash` call costs +8.5s**: 1.83s -> 10.3s. Read the inner `date` to see where
  it goes — the tool_use is at 17:23:23.440 and the command actually ran at
  17:23:28, ~4.6s later (`PreToolUse` held to its 5s timeout, then abandoned and
  the tool ran), and the result came back at 17:23:33.705, ~5.7s after the command
  finished (`PostToolUse`, same 5s). Both hooks fail open **at their declared
  timeout**. Reproduced exactly on the next iteration: 17:24:55.274 USE,
  `date` printed 17:25:00, RES 17:25:05.646.
- Direct confirmation the endpoint really is a blackhole and not just slow:
  ```
  $ time curl -s -m 5 ... 'http://127.0.0.1:8791/hooks?token=spiketoken'
  curl code 000 exit
  ... 0% cpu 5.045 total
  ```

So **unreachable behaves the same as slow**: the already-known `PreToolUse`
fail-open (`FileLockPolicy.hookTimeoutSeconds`' doc comment, measured against
2.1.272) holds for an unreachable endpoint too. Connection-refused is the cheap
case — the hook fails instantly and costs nothing.

### Recovery from a 9m46s blackhole

Blackhole up 17:23:23.377, killed and `serve` rebound on the same port at
17:33:09.891. Pings 9-14 timed out; ping 15 landed on the socket as it was torn
down and produced a third, distinct error string; ping 16 was the first attempt
after the rebind and succeeded.

```
$ sed -n '8,20p' probe.log
8 | pong from agent board: 8
9 | The operation timed out.
10 | The operation timed out.
11 | The operation timed out.
12 | The operation timed out.
13 | The operation timed out.
14 | The operation timed out.
15 | The socket connection was closed unexpectedly. For more information, pass `verbose: true` in the second argument to fetch()
16 | pong from agent board: 16
17 | pong from agent board: 17
...
```

First success 6.5s after rebind (server up 17:33:09.891, `tools/call` for "16" at
17:33:16.439), then 25 consecutive successes to iteration 40 at 17:36:18. Same
one handshake for the whole 32 minutes:

```
$ distinct Mcp-Session-Id, run B
2bcb7db2-8c95-4721-b8de-4af189ece021 first 17:03:58.773 last 17:36:18.595 count 35
$ every initialize after 17:00
initialize at 17:03:53.190
```

One `initialize`, 35 requests, a 9m46s hole in the middle. The worker finished
all 40 iterations of its task.

### The model does not retry and does not abandon

`prompt-neutral.txt` says nothing about what to do on failure. The worker logged
the error verbatim and moved to the next iteration, every time:

`claude agents --json --all` reported `status busy state working` for the whole
10 minutes, across seven consecutive failures. It never re-issued a failed call,
and it never gave up on the task — it logged each error and ran the next
iteration, the same as it did with the explicit "do not stop" instruction in
run A.

## Question 4 — the board's view

**A local worker is not reaped.** `WorkerSupervisor.meter` (`:1741`) computes
`lastActivity` as `max(session.lastActivityDate, TranscriptMeter.summarize(...).lastActivity)`.
The DB half comes only from hooks (`recordActivity` is called from
`StoreHookSink.swift:187,380,399` and the early-hook replay at
`WorkerSupervisor.swift:1872` — nowhere else), so during an outage it freezes. The
transcript half does not: `TranscriptAccumulator.ingest` takes the timestamp of
every `assistant` line, and run B's transcript kept gaining assistant messages
throughout the blackhole (17:24:50, 17:25:24, ...). The cap therefore sees a live
worker.

**A remote worker is reaped, and this is the load-bearing finding for the tunnel.**
`session.transcriptPath` is taken from the `SessionStart` hook payload:

```
16:53:39.165 SessionStart /Users/claydiffrient/.claude/projects/-Users-...-outage-repo/974c0f27-....jsonl
```

An absolute path in the *worker's* `$HOME`. Run the worker on a Linux box and that
path is `/home/<user>/.claude/projects/...`, which does not exist on the Mac.
`try? await offMain({ try TranscriptMeter.summarize(...) })` yields nil, the
transcript half of the `max` disappears, and `lastActivity` is hook-derived only.
Then, from `Caps` (`ProjectSettings.swift:7,11`): a "Worker may be stuck" notice
at `stallSeconds = 120`, and `CapEvaluator` returns `.idle` at
`maxIdleSeconds = 300`, whereupon `enforce` calls `runtime.stop(shortId:)` and
`board.terminate(cause: .capBreach)`. **A remote worker whose tunnel is down for
five minutes is killed by the board even though it is working perfectly.**

## Question 5 — how long an outage is survivable

Worker-side: every outage tested was survivable. 2m12s refused and 9m46s
blackhole both ended with the worker still `busy`/`working`, the next MCP call
succeeding on its first attempt, and the task run to completion. Nothing in the client gives up, times out the session, or drops the
MCP server from its tool list.

The limits are the board's, and they are:

| outage | refused | blackhole |
|---|---|---|
| per MCP call | ~3s, error | ~62s, error |
| per Bash tool call | +0s | +10s (5s PreToolUse + 5s PostToolUse) |
| per Write/Edit, shared checkout | +0s | +240s (2 x `FileLockPolicy.hookTimeoutSeconds` = 120) |
| hook events | all lost, never replayed | all lost, never replayed |
| board's idle cap (remote worker) | kills at 300s | kills at 300s |

The `Write`/`Edit` row is the sharpest: with file locks on, a blackholed tunnel
makes every write take four extra minutes **and the lock is not actually held** —
the hook that would have serialized two workers in a shared checkout is abandoned
and the write proceeds. That is a correctness hazard, not a slowdown.

## Design consequence for the tunnel

A crude tunnel is fine for the worker and not fine for the board. The worker
tolerates a refused endpoint for free and a blackholed one at ~62s per MCP call
and ~10s per tool call, recovers on the first attempt with no handshake, and ran
its task to completion across a 9m46s hole. What does not tolerate it is Agent
Board's own idle cap: on a remote worker the meter cannot read the transcript,
`lastActivity` becomes hook-derived only, and the board kills a perfectly healthy
worker at `maxIdleSeconds` = 300. So the tunnel does not need second-scale
reconnection, but the remote-worker feature does need one of: the transcript
shipped back (rsync/`ssh cat` on the meter tick), `lastActivity` fed from
something other than hooks, or the idle cap exempted while a host is
known-unreachable. Prefer a tunnel that reconnects within the 5s hook timeout
anyway — `autossh`, or `ServerAliveInterval 5 ServerAliveCountMax 2` with a
restart loop — because that keeps refused (free) rather than blackhole
(expensive), and blackhole is what a shared checkout cannot survive: the file
lock hook is abandoned at 120s and the write proceeds unlocked.

## Not determined

- Whether the MCP ~62s timeout is a fixed client constant or derived from
  something. One measurement (61.8s), one blackhole.
- Whether an outage longer than ~10 minutes is still survivable. 9m46s was the
  longest tested and showed no degradation, but nothing here rules out a limit
  further out.
- What a `SessionEnd`/`Stop` hook lost during an outage costs the board in
  practice. The probe never ended its turn inside an outage window, so the board's
  "worker finished" path was not exercised; the hook is fire-and-forget with no
  retry, so it would simply be lost.
- Real SSH. Every failure here was synthesized locally, as the task allowed. A
  real `ssh -R` drop may present as refused, blackhole, or something in between
  depending on `TCPKeepAlive`/`ServerAliveInterval` and how the forward dies.
