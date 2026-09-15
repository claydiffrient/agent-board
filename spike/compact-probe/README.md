# Compaction probe (2026-09-12, Claude Code 2.1.269)

Harness behind the compaction facts in SPEC §2. `sink.py` is an HTTP hook
sink writing the real `hook_event` schema into a scratch SQLite file;
`drive.py` runs `claude` under a PTY and types a scripted sequence.

```
python3 sink.py /tmp/probe.sqlite 8919 &
python3 drive.py <repo> <settings.json> <ptylog> '<script-json>' '<env-json>' '<extra-argv-json>'
```

## Manual /compact — same session id, no SessionEnd

```
id  sid       event             source   trigger
--  --------  ----------------  -------  -------
1   39742488  SessionStart      startup         
2   39742488  UserPromptSubmit                  
3   39742488  PostToolUse                       
4   39742488  Stop                              
5   39742488  UserPromptSubmit                  
6   39742488  Stop                              
7   39742488  PreCompact                 manual 
8   39742488  SessionStart      compact         
9   39742488  Notification                      
10  39742488  UserPromptSubmit                  
11  39742488  Stop                              
12  39742488  SessionEnd                        
```

TUI status line across that run: `10% until auto-compact` before,
`19% until auto-compact` after (session started `--autocompact 100k`,
so the trigger is 100k - 20k - 13k = 67,000 tokens).

Last assistant `usage` either side of the compaction boundary:

```
before  in=2   cache_read=60173  cache_creation=69      -> 60244   (10% left => 59995..60664)
after   in=2   cache_read=32593  cache_creation=21624   -> 54219   (19% left => 53935..54605)
```

## Auto-compact fires on its own, mid-turn

Same harness, `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=3` so the threshold is reachable
in a few turns. The scratch `hook_event` table for that run (since overwritten
by the manual run above):

```
id  sid       event             source   trigger  at
1   a727814a  SessionStart      startup           11:33:59
2   a727814a  UserPromptSubmit                    11:34:24
3   a727814a  Stop                                11:34:27
4   a727814a  UserPromptSubmit                    11:35:24
5   a727814a  PreCompact                 auto     11:35:24
6   a727814a  Stop                                11:35:26
7   a727814a  Notification                        11:36:26
8   a727814a  UserPromptSubmit                    11:36:54
9   a727814a  PreCompact                 auto     11:36:54
10  a727814a  SessionStart      compact           11:37:17
11  a727814a  Stop                                11:37:19
12  a727814a  SessionEnd                          11:37:54
```

`PreCompact` lands between `UserPromptSubmit` and `Stop` — mid-turn — and the
turn finishes by itself afterwards. Contrast the manual run, where the session
went idle (`Notification notification_type=idle_prompt`) and waited.

## Gotcha: transcripts are off inside a Claude child session

`CLAUDE_CODE_CHILD_SESSION=1` is inherited by anything `claude` spawns, and it
disables transcript persistence — the TUI banner says so, no JSONL is written,
and the hook payload's `transcript_path` points at a file that never appears.
`drive.py` scrubs the marker and sets
`CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1`.
