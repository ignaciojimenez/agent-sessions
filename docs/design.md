# Design

How agent-sessions decides what to reopen, and the measurements behind each
rule. Install and quick use are in the [README](../README.md).

## Use

1. Name sessions: `claude -n <name>`, or `/rename` later. A name is what the
   plan shows you; an unnamed session still comes back, as
   `(unnamed <id prefix>)`, provided the agent ever answered in it.
2. After a reboot, open Ghostty and run `agent-restore`. It prints the plan
   and asks before opening anything.

```
agent-restore -n          # plan only
agent-restore -y          # no prompt
agent-sessions list       # every recorded session: running, closed or lost
```

## How it works

`SessionStart` and `SessionEnd` hooks call `agent-sessions track claude`,
which keeps one JSON record per session in
`~/.local/state/agent-sessions/` (`0700`): id, name, directory, transcript,
the agent's pid, and when it started and ended.

| Hook event | Record |
|---|---|
| `SessionStart` (startup, resume, clear) | written; a resume overwrites the closed record, so it counts as running again |
| `SessionEnd` `prompt_input_exit`, `logout`, `clear`, `resume` | deleted: closed on purpose, or handed over to a new session |
| `SessionEnd` `other` | kept, stamped with its end time |
| no `TERM_PROGRAM` (`claude --bg`) | never written: nothing to reopen in a terminal |
| `CLAUDE_CODE_ENTRYPOINT` other than `cli` (`claude -p`, the SDK) | never written: a headless run, even one started from a terminal |

`other` covers a closed terminal, Ctrl-C, SIGHUP, SIGTERM, `claude stop` —
and a reboot. They cannot be told apart when they happen, so `restore` tells
them apart afterwards. It reopens:

- every **lost** session: never ended, process gone (killed before its hook
  could run), and
- every **closed** session that ended within 5 minutes of the most recent
  close (`AGENT_SESSIONS_WINDOW`) — the batch a reboot or quitting the
  terminal leaves behind.

Running sessions are never touched, so running it twice duplicates nothing.
Records older than 14 days are pruned.

For each session it resolves the current name (the last `custom-title`
record in the transcript, since no hook fires on `/rename`), skips unnamed
ones with no assistant turn in the transcript (opened and closed again, or
only local commands like `/clear`) and ones without a transcript, groups the
rest by git repo root, and drives Ghostty over AppleScript. The `Reopen?`
prompt is the filter for anything else you don't want back.

## What was verified

Measured on 2026-09-18 with Claude Code 2.1.276–2.1.277 and Ghostty 1.3.1,
using throwaway sessions:

- `/exit` ends with `prompt_input_exit`. SIGHUP, SIGTERM, closing the pty,
  double Ctrl-C and `claude stop` all end with `other`, and the hook runs.
- `SessionStart` carries `session_title` from `-n`, and the renamed title on
  resume. `/rename` itself fires no hook but appends `custom-title` and
  `agent-name` records to the transcript.
- `--resume <id>` keeps the id. `/clear` ends the old id (`clear`) and starts
  a new one carrying the title.
- Hook commands are direct children of the `claude` process.
- A session killed before its first exchange may have no transcript and
  cannot be resumed — hence the check.
- Background sessions fire the same hooks without `TERM_PROGRAM`.
- `claude -p` from a terminal fires both hooks with `TERM_PROGRAM` set and
  ends with `other`, so it looked like a session a reboot closed. Claude sets
  `CLAUDE_CODE_ENTRYPOINT` in the hook's environment itself: `cli` for an
  interactive session, `sdk-cli` for `-p` (2.1.289, measured both ways with
  the inherited value unset).
- A folder with `.claude-plugin/plugin.json` symlinked into
  `~/.claude/skills/` loads with its hooks, no install step, no
  `settings.json` change.
- Ghostty's `+new-window` is unsupported on macOS; AppleScript opened a
  window, tabs and splits, each pane with its own directory and command,
  and `restore -y` reproduced a 3 + 2 layout across two repos.

A real reboot followed by `agent-restore` reopened the sessions (reported
by the author on 2026-10-04, on the version extracted here). The design does
not depend on whether the hook gets to run at shutdown: a record that never
ended is reopened as lost.

Installed by `install.sh` (2026-10-04, Claude Code 2.1.289): the adapter
loads from `~/.claude/skills/`, its hook runs `~/.local/bin/agent-sessions`
and records an interactive session (a hang-up ends it as `other`), a
headless one is never recorded, and `agent-restore` on PATH plans from the
same records.

`tests/contract.sh` replays those payload shapes against a fixed clock. It
also runs `install.sh` into a throwaway `HOME` and then the hook command
exactly as the Claude adapter spells it, so a wrong path fails the test
rather than silently recording nothing.

## Security

- The session id names a file and is typed into a shell, so it must match
  `^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`: no path traversal, no leading dash,
  no shell syntax. Anything else is refused.
- The working directory is set as a Ghostty surface property, never typed.
- Records hold paths and session names only — no conversation content.

## Extending

Everything tool-specific sits in the adapter block at the top of
`agent-sessions`: `track_<tool>`, `resume_command`, `resumable`,
`worked_in`, `current_name`. A new CLI needs those, plus an
`adapters/<tool>/` folder that makes its hooks run
`~/.local/bin/agent-sessions track <tool>`, and a line in `install.sh` that
wires it where that CLI lives.
Gemini CLI 0.18.4 has hook code but resumes only by index or `latest`, not
by id, so it cannot be restored this way yet.

The terminal side is one function, `open_ghostty`.
