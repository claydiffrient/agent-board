## 2. Platform facts this spec depends on

Verified against Claude Code **2.1.269** on macOS. Items marked *M0* were
proven by the runtime spike in `spike/` on 2026-09-11.

- `claude --bg` backgrounds a session and prints a short id. `claude agents`,
  `attach`, `logs`, `stop`, `rm`, `respawn` manage them. The supervisor is a
  per-cwd daemon with a control socket at `/tmp/cc-daemon-<uid>/<hash>/control.sock`.
- `claude agents --json --all` returns `{id, cwd, kind, startedAt, sessionId,
  name, status|state}` per session — interactive and background.
- *M0:* `--bg` with `--settings`, `--mcp-config`, `--strict-mcp-config`,
  `--permission-mode auto`, `--disallowedTools` and `-n` together starts a
  healthy session that honors the injected hooks and MCP config. Stdout is
  `backgrounded · <short-id> · <name>`; the short id is the first 8 hex chars of
  the session uuid, and `claude agents --json` lists the full uuid immediately.
- *M0:* **`--bg` ignores `--session-id`** (`warning: --bg manages the session
  id`). The id is therefore recorded after spawn, not assigned before it.
  `claude --bg --resume <uuid>` wakes a stopped session under the same id and
  **reuses its saved options** (`-n`, `--permission-mode`, `--strict-mcp-config`,
  `--mcp-config`, `--settings`, `--disallowedTools`, `--model`) by path. The
  per-session config files must stay at their original paths and be rewritten
  with the current server port before a resume, or the woken worker talks to a
  dead port.
- *M0:* Hooks of `type: "http"` fire from a background session for
  `PostToolUse`, `Notification`, `Stop` and `SessionEnd`. **`SessionStart`
  silently skips `http` hooks** (foreground and background); a `command` hook
  that pipes stdin to `curl` fires and is the workaround.
- **`/clear` forks the session under a new id.** The old id gets `SessionEnd`
  with `"reason": "clear"`, and ~18s later a new id gets `SessionStart` with `"source": "fork"`. The fork
  payload does not name its parent — no parent session id anywhere in it — so
  the hook token grant is the only link back. `StoreHookSink` treats an unknown
  payload `session_id` on a live grant bound to a known session as the fork
  signal: it inserts a row for the new id, rebinds the grant, and re-pins
  `project.orch_session_id` for an orchestrator grant. The old row keeps its
  terminal state and its spend — the fork writes its own transcript, and
  metering reads transcripts.
- *M0:* The MCP client sends a non-standard `server/discover` request before
  `initialize`; answering it with JSON-RPC `-32601` is fine. `tools/list` is
  fetched at startup and the tool is callable in the first turn.
- *M0:* `claude attach <id>` renders the full TUI inside a SwiftTerm
  `LocalProcessTerminalView` (truecolor, layout, status line). Closing the
  window sends SIGTERM to the attach client (exit 143); the background session
  is still listed afterwards. SwiftTerm logs unhandled DECSET 2031 (theme
  change queries), harmless.
- MCP supports `--transport http` with per-server `--header`, so one server can
  identify callers by bearer token.
- Permission mode `auto` runs a classifier: 17 allow rules, 70 soft-deny
  (ask-the-user), 1 hard-deny (data exfiltration across the trust boundary),
  and a 21-rule environment block. Configurable under the `autoMode` settings
  key. `claude auto-mode critique` reviews a custom rule set.
- Session transcripts are JSONL under `~/.claude/projects/<slug>/`, carrying
  per-message `usage` with `input_tokens`, `output_tokens`,
  `cache_creation_input_tokens`, `cache_read_input_tokens`, `service_tier`.
- **`/compact` does not fork the session id.** Measured 2026-09-12 by driving a
  real `claude` PTY with hooks pointed at a scratch `hook_event` table. Manual
  `/compact` emits, all under the *same* `session_id` and the same
  `transcript_path`, and with no `SessionEnd`:
  `PreCompact {"trigger":"manual"}` → `SessionStart {"source":"compact"}`.
  Re-measured 2026-09-15 on 2.1.272 with the same result. `/clear` forks and
  `/compact` does not, so there is no fork to adopt: the `agent_session` row,
  its bound grant and `project.orch_session_id` all survive untouched, and
  Agent Board's whole reaction to that `SessionStart` is to tell the console
  (`CompactedSessionTests` pins each of those three).
- **Claude Code auto-compacts on its own, mid-turn.** Measured with
  `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=3` to pull the threshold down to a reachable
  value: `UserPromptSubmit` → `PreCompact {"trigger":"auto"}` → (later)
  `SessionStart {"source":"compact"}` → `Stop`, same session id throughout. The
  turn *continues by itself* after an auto-compaction. A manual `/compact` at
  rest does not: it ends with a `Notification {"notification_type":
  "idle_prompt","message":"Claude is waiting for your input"}` and the session
  sits there, exactly like a resume (§9). An app-driven compaction therefore
  has to send the next turn itself.
- **Auto-compact fires very late.** From the 2.1.269 binary: the trigger is
  `contextWindow - 20000 - 13000` tokens, i.e. 13k of headroom below the
  effective window; `blocked` is 3k below that. `--debug` on a Fable 5.1
  session logs `autocompact: tokens=… level=ok effectiveWindow=980000` at each
  turn start, so the window is 1M and the auto trigger is 967k. `/autocompact`,
  the `autoCompactWindow` setting, `--autocompact <auto|tokens>` and
  `CLAUDE_CODE_AUTO_COMPACT_WINDOW` move it; `DISABLE_COMPACT` turns it off.
  Agent Board compacting at a chosen fraction fires *before* this and at a
  moment it picks, rather than mid-dispatch.
- **`effectiveWindow` is 980,000 for every model measured.** Measured
  2026-09-15 on 2.1.272 by running one turn per model under `--debug` and
  grepping the debug file (`~/.claude/debug/<session>.txt`, *not* the PTY) for
  `autocompact: tokens=… level=ok effectiveWindow=`:

  | Model | `effectiveWindow` |
  |---|---|
  | `claude-fable-5-1` | 980000 |
  | `claude-opus-5` | 980000 |
  | `claude-opus-5-5` | 980000 (measured 2026-09-22 on 2.1.280, `claude -p --debug`) |
  | `claude-sonnet-5` | 980000 |
  | `claude-haiku-4-5` | not measured — the run died on `Error: Refresh token is invalid or has already been claimed by another client` before any turn completed |

  `ModelCatalog.effectiveContextWindow(for:)` carries the four measured values
  and reads anything else, Haiku included, as the same 980,000 rather than
  guessing a smaller one.
- **A slash command injected into a PTY needs its Enter as a separate write.**
  Measured 2026-09-15, three runs in the same harness. Writing
  `"/compact <instructions>\r"` as **one** burst leaves the carriage return in
  the prompt as a literal `^M`: no compaction fires, and the following
  injection is appended to it — the `PreCompact` payload that eventually
  arrived carried
  `custom_instructions: "…write this down'.^MReply with only the word mango."`.
  Writing the text and then `"\r"` as **two** writes fires it cleanly, with
  `custom_instructions` exactly the instruction text and the next turn its own
  `UserPromptSubmit`. It is the leading slash, not the length: a 470-character
  plain message with a trailing `\r` in one burst submitted normally, while a
  short `"/compact keep decisions\r"` in one burst produced no `PreCompact` at
  all — only `Notification {"notification_type":"idle_prompt"}`. Claude Code's
  slash-command autocomplete consumes the Enter. The existing report notice
  (§9.1) has no leading slash and is unaffected, but `OrchestratorConsole`
  splits every injection the same way so nothing depends on remembering this.
- **A long injected line arrives as pasted content, and a pasted `/compact`
  runs no command.** Measured 2026-09-26 on 2.1.283 with `spike/compact-probe/`.
  Claude Code treats any single stdin read over 800 characters as a paste: an
  800-character burst submitted as typed text, 801 arrived wrapped in
  `<pasted_content>`. The macOS PTY hands the reader about 1 KiB per read, so
  the 1,839-byte `/compact <instructions>` written in one burst reached it as
  two reads — two pasted blocks split at byte 1022 — and no `PreCompact` fired.
  Chunks under 800 with a pause of 20 ms or more between them were typed; with
  no pause they queue in the PTY and re-merge into ~1 KiB reads. `inject` writes
  `PromptBursts` of at most 256 characters, 50 ms apart, then the `\r`; the same
  command then fired `PreCompact {"trigger":"manual"}` with `custom_instructions`
  equal to `OrchestratorCompaction.instructions`, followed by
  `SessionStart {"source":"compact"}`.
  At that pace the compaction command takes about 400 ms to write, and a report
  notice or a Nudge can be requested inside that window (§9.2), so `inject`
  serializes lines: each waits for the previous line's `\r` before its first
  burst. Interleaved, the notice's `\r` would submit
  `/compact <partial instructions>[agent-board]…` and the rest of the
  instructions would go in as a plain message. A notice requested
  mid-compaction is written right after the command's `\r` rather than held
  until `SessionStart {"source":"compact"}`, because a compaction that fails
  sends no `SessionStart` and would strand it; the re-orientation line names
  `list_reports` either way.
- **Context pressure = `input_tokens + cache_read_input_tokens +
  cache_creation_input_tokens` of the last assistant message.** Calibrated
  against the TUI's own `N% until auto-compact` readout on a session started
  with `--autocompact 100k` (threshold 67,000 = 100k − 20k − 13k). Before
  compaction the readout said 10% (implying 59,995–60,664 tokens) and the last
  assistant message carried `in=2 cr=60,173 cc=69` → 60,244. After compaction
  it said 19% (implying 53,935–54,605) and the message carried
  `in=2 cr=32,593 cc=21,624` → 54,219. Dropping `cache_creation_input_tokens`
  gives 32,595 there — 40% low, and outside the band. `TranscriptMeter` already
  parses all three fields.
- **A session started as a child of another Claude session writes no
  transcript.** `CLAUDE_CODE_CHILD_SESSION=1` in the environment turns
  persistence off (the TUI says so in its banner) and no
  `~/.claude/projects/<slug>/<id>.jsonl` ever appears, while
  `transcript_path` in the hook payload still points at the file that is never
  written. `CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1` overrides it. Agent Board
  is not a Claude child so this does not bite in production, but any harness
  that spawns `claude` from inside `claude` must scrub the marker or it will
  measure nothing.
- **A Finder or Dock launch gets launchd's PATH, `/usr/bin:/bin:/usr/sbin:/sbin`.**
  No install location of `claude` (`~/.local/bin`, `/opt/homebrew/bin`) is on
  it, nor are `gh`, `node` or `npx`. Agent Board looks `claude` up at its known
  install paths, and gives every agent process the PATH printed by the user's
  interactive login shell (`$SHELL -i -l -c`), resolved once per launch off the
  main thread; a terminal awaits it before starting its process. A
  human shell builds its own PATH and keeps the inherited one.
- **No programmatic read of account-wide remaining subscription quota exists.**
  Every budget in this spec is a self-imposed ceiling over what Agent Board
  itself spawned, not a real-quota ceiling.
- `~/.claude/projects/<worktree-slug>/memory/` is created empty for each new
  worktree. The existing convention on this machine symlinks it to the canonical
  project memory dir (confirmed across ~20 Derivita checkouts).
- **A worker survives its board endpoint going away, and recovers with no
  handshake.** Measured 2026-09-16 against 2.1.273 by `spike/outage-probe/`.
  With the port refused an MCP tool call returns `is_error` in ~3s carrying
  `Unable to connect. Is the computer able to access the url?`; with the socket
  accepted but never answered it hangs ~62s and returns `The operation timed
  out.`. The session stays `busy`/`working` through either, the model records
  the error and moves to its next step without retrying the call or abandoning
  the task, and the first call after the endpoint returns succeeds. The client
  handshakes once and reuses the `Mcp-Session-Id` it was given before the outage
  for the life of the session; `BoardServer` writes that header and never reads
  it, so no board restart invalidates a live worker, and adding validation would
  break every worker alive across one.
- **An unreachable hook endpoint fails open exactly like a slow one**, and every
  hook posted during an outage is lost with none replayed. A hook held open is
  abandoned at its declared `timeout` and the tool then runs, so a blackholed
  endpoint costs 5s per `PreToolUse` and 5s per `PostToolUse` — and
  `FileLockPolicy.hookTimeoutSeconds` (120) twice per write in a shared
  checkout, with the lock not actually held. A refused endpoint costs nothing
  measurable.
- **AppKit refuses `NSApplication.terminate` while any window has an attached
  sheet, and says nothing about it.** Measured 2026-09-17 against the shipped
  binary by `QuitProbe` (`AGENTBOARD_QUIT_PROBE`, the same shape as the
  `AGENTBOARD_E2E_REPO` hook). No delegate is consulted — this app implements no
  `applicationShouldTerminate` — no `NSApplication.willTerminateNotification` is
  posted, nothing is logged, and the call returns as if it had worked. It is the
  attached sheet specifically: a second ordinary window does not block, and the
  same app quits once the sheet has ended. A SwiftUI sheet cannot be cleared
  with `endSheet` behind its binding's back — it re-attaches while
  `isPresented` is still true, and the refusal stands; only dismissing it
  through the binding clears the way. So any control that quits the app from
  inside a sheet must dismiss first and wait for the detachment.
