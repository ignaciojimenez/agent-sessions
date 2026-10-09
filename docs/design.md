# Design

How agent-sessions decides what to reopen, how its adapters work, and the
measurements behind each rule. Install and use are in the
[README](../README.md).

## How it works

The tool sits between two kinds of adapter. An **agent adapter** turns one
CLI's session hooks into records and knows how to resume a session. A
**terminal adapter** opens the planned layout.

Each interactive session gets one JSON record in
`~/.local/state/agent-sessions/` (`0700`): tool, id, name, directory,
transcript path, the agent's pid, and when it started and ended. One file
per session, so concurrent hooks never contend for a file.

A session closed on purpose is forgotten. Any other end (a closed terminal,
Ctrl-C, a signal, a reboot) cannot be told apart when it happens, so the
record is kept with its end time and `restore` decides afterwards. It
reopens:

- every **lost** session: never ended, process gone (killed before its hook
  could run), and
- every **closed** session that ended within 5 minutes of the most recent
  close (`AGENT_SESSIONS_WINDOW`), which is the batch a reboot or quitting
  the terminal leaves behind.

Running sessions are never touched, so running it twice duplicates nothing.
Records older than 14 days are pruned.

For each session it resolves the current name, skips unnamed sessions
nothing happened in and sessions with nothing to resume, groups the rest by
git repository root, and hands the layout to a terminal adapter. The
`Reopen?` prompt is the filter for anything else you don't want back.

## Claude Code adapter

`adapters/claude/` is a plugin folder whose `SessionStart` and `SessionEnd`
hooks run `agent-sessions track claude`.

| Hook event | Record |
|---|---|
| `SessionStart` (startup, resume, clear) | written; a resume overwrites the closed record, so it counts as running again |
| `SessionEnd` `prompt_input_exit`, `logout`, `clear`, `resume` | deleted: closed on purpose, or handed over to a new session |
| `SessionEnd` `other` | kept, stamped with its end time |
| no `TERM_PROGRAM` (`claude --bg`) | never written: nothing to reopen in a terminal |
| `CLAUDE_CODE_ENTRYPOINT` other than `cli` (`claude -p`, the SDK) | never written: a headless run, even one started from a terminal |

The current name is the last `custom-title` record in the transcript, since
no hook fires on `/rename`. "Nothing happened in it" means no assistant turn
in the transcript. A session is resumed with `claude --resume <id>`.

Measured on 2026-09-18 with Claude Code 2.1.276–2.1.277, using throwaway
sessions:

- `/exit` ends with `prompt_input_exit`. SIGHUP, SIGTERM, closing the pty,
  double Ctrl-C and `claude stop` all end with `other`, and the hook runs.
- `SessionStart` carries `session_title` from `-n`, and the renamed title on
  resume. `/rename` fires no hook but appends `custom-title` and
  `agent-name` records to the transcript.
- `--resume <id>` keeps the id. `/clear` ends the old id (`clear`) and starts
  a new one carrying the title.
- Hook commands are direct children of the `claude` process, so the hook's
  parent is the agent's pid.
- A session killed before its first exchange may have no transcript and
  cannot be resumed, hence the check.
- Background sessions fire the same hooks without `TERM_PROGRAM`.
- `claude -p` from a terminal fires both hooks with `TERM_PROGRAM` set and
  ends with `other`, like a session a reboot closed. Claude sets
  `CLAUDE_CODE_ENTRYPOINT` in the hook's environment: `cli` for an
  interactive session, `sdk-cli` for `-p` (2.1.289, measured both ways with
  the inherited value unset).
- A folder with `.claude-plugin/plugin.json` symlinked into
  `~/.claude/skills/` loads with its hooks, with no install step and no
  `settings.json` change.

Installed by `install.sh` (2026-10-04, Claude Code 2.1.289): the adapter
loads, its hook runs `~/.local/bin/agent-sessions` and records an
interactive session (a hang-up ends it as `other`), a headless one is never
recorded, and `agent-restore` plans from the same records. A real reboot
followed by `agent-restore` reopened the sessions (2026-10-04). The design
does not depend on the hook running at shutdown: a record that never ended
is reopened as lost.

## Droid adapter

`adapters/droid/hooks.json` holds three hooks, each running
`agent-sessions track droid`. Droid has no plugin folder it loads unasked,
so `install.sh` merges them into the user hooks file: `~/.factory/hooks.json`
if it exists, otherwise the `hooks` key of `~/.factory/settings.json`.
Droid reads `settings.json` hooks only when there is no `hooks.json`, so
creating one would silently drop the hooks declared there. The merge drops
any group that runs the adapter's command and appends the adapter's, so a
re-run changes nothing; uninstall drops them and leaves the rest as it was.

| Hook event | Record |
|---|---|
| `SessionStart` (startup) | written |
| `UserPromptSubmit`, no record from this process | written: a resumed or `/clear`ed session, which gets no `SessionStart` |
| `SessionEnd` `clear`, `logout`, `prompt_input_exit` | deleted |
| `SessionEnd` `other`, agent still holds its terminal | deleted: exited from inside (`/exit`, Ctrl-C) |
| `SessionEnd` `other`, terminal gone | kept, stamped with its end time; written first if there was no record |
| no `TERM_PROGRAM` | never written |
| `FACTORY_DISABLE_SETTINGS_PERSISTENCE` set (`droid exec`) | never written: a headless run |

The current name is the transcript's first-line `title` when
`isSessionTitleManuallySet` is true; a title Droid derived from the first
prompt is not used. "Nothing happened in it" means no `"role":"assistant"`
message. A session is resumed with `droid --resume <id>`; since that fires
no `SessionStart`, a live `droid --resume <id>` process also counts as
running, so a second restore does not reopen it again.

Measured on 2026-10-05 with Droid 0.231.0, using throwaway sessions run
with `--settings` (a per-process settings file, so the user's config was
not touched):

- The payload is Claude's shape (`session_id`, `transcript_path`, `cwd`,
  `hook_event_name`, `source`/`reason`), with no session title.
- Every end is `other`: `/exit`, double Ctrl-C, a closed tmux window,
  SIGHUP and SIGTERM. `/clear` ends the old id with `clear`, then again with
  `other`.
- The hook runs with no controlling terminal, but its parent, the `droid`
  process, keeps one: at the end of `/exit` and Ctrl-C it still has its tty;
  when the window is closed it has none (`??`), since the hangup comes first.
- `SessionStart` fires on startup only: not after `--resume <id>` (which
  keeps the id), nor for the session `/clear` starts. `UserPromptSubmit`
  fires in both.
- `/rename` fires no hook; it rewrites `title` in the transcript's first line
  and sets `isSessionTitleManuallySet`.
- `droid exec`, run in a terminal, fires both hooks with `TERM_PROGRAM` set;
  only it sets `FACTORY_DISABLE_SETTINGS_PERSISTENCE` in the hook's
  environment.
- Hook commands are direct children of the `droid` process.

A shutdown that sends SIGTERM to `droid` while its terminal is still open
looks like `/exit`, and that session is forgotten. Quitting the terminal
first, which is what a restart asks apps to do, hangs it up and keeps it.
Unverified with a real reboot.

## Terminal adapters

Every adapter takes the same layout: `--tab <label>`, then a directory and
a command per session. The directory is set as a property of the new pane,
never typed. The command is typed into the pane's shell, so the shell is
still there when the agent exits.

The adapter is `-t <terminal>`, else `AGENT_SESSIONS_TERMINAL`, else
detected: tmux when `TMUX` is set, Ghostty when `TERM_PROGRAM` is `ghostty`
on macOS, otherwise `print`. Detection never guesses at a GUI terminal it
is not running in.

- **Ghostty** (macOS) is driven over AppleScript: one window, a tab per
  repository, splits to the right, equalized. Its `+new-window` CLI action
  is unsupported on macOS. Verified with Ghostty 1.3.1: a window, tabs and
  splits, each pane with its own directory and command, and `restore -y`
  reproduced a 3 + 2 layout across two repositories.
- **tmux** opens a window per repository and a pane per session
  (`new-window -c`, `split-window -h -c`, `even-horizontal`). Inside tmux
  the windows join the current session. Outside, they go in a new session
  named `agent-sessions` (with a suffix if one exists), attached when there
  is a terminal. This is the adapter for Linux, and for terminals without
  their own (iTerm2, Terminal.app, a remote shell). Verified with tmux 3.7c
  on macOS: both paths, and tmux sets `TERM_PROGRAM=tmux` in its panes, so
  sessions started there are recorded.
- **print** writes `cd <directory> && <command>` per session, grouped by
  repository, and opens nothing, so it does not ask first.

iTerm2 and Terminal.app have no native adapter. Terminal.app cannot script
tabs or splits without accessibility access, and an iTerm2 adapter could not
be tested here. Both work through tmux.

## Tests

`tests/contract.sh` replays the Claude Code payload shapes above against a
fixed clock and asserts on the records and the plan. It checks terminal
detection and the `print` output, and runs the tmux adapter on a private
tmux server with a stub agent, asserting on the windows, panes and
directories it opened and the command each pane ran. CI installs tmux, and
fails if it is missing. The Ghostty adapter needs a GUI session and is not
run in tests.

Droid payloads are sent from a stand-in process named `droid`, with a
terminal (`script`) or in a session of its own without one (`setsid`), since
that is what separates `/exit` from a closed terminal.

It also runs `install.sh` into a throwaway `HOME`, then the hook commands
exactly as the Claude and Droid adapters spell them, so a wrong path fails
the test instead of silently recording nothing. The Droid wiring is checked
against a `settings.json` with hooks of its own: they are kept, the adapter's
are added once, and uninstall restores the file.

## Spotlight app

`install.sh` compiles `macos/agent-restore.applescript` with `osacompile`
into `~/Applications/Agent Restore.app`, which Spotlight indexes. It runs
`agent-sessions restore -t ghostty -n`, shows the plan in a dialog, and runs
it with `-y` on **Reopen**. An app has no terminal to detect, so it names
Ghostty. Three things an app does differently from a terminal:

- **A bare `PATH`.** `do shell script` gets `/usr/bin:/bin:/usr/sbin:/sbin`.
  `install.sh` bakes in the tool's path and the directories it found `jq`
  and `git` in, rather than guessing at Homebrew prefixes.
- **Automation permission.** The app sends Apple Events to Ghostty, so macOS
  asks once. Its ad-hoc signature changes with every build, which may ask
  again, so `install.sh` rebuilds only when the generated source changes.
- **No terminal to report to.** Failures are shown in an alert.

The tests load the compiled script and run a restore through
`do shell script` with the baked values. The dialogs and the permission
prompt need a person: run from Spotlight on 2026-10-04, it showed the plan,
asked once, and opened one Ghostty window. Ghostty was already running; a
cold start from the app is untested.

## Security

- The session id names a file and is typed into a shell, so it must match
  `^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`: no path traversal, no leading dash,
  no shell syntax. Anything else is refused.
- The working directory is a pane property (a Ghostty surface setting,
  tmux's `-c`), never typed. `print` shell-quotes it.
- Records hold paths and session names only, no conversation content.

## Extending

**An agent CLI.** Everything agent-specific sits in the adapter block at
the top of `agent-sessions`: `track_<tool>`, plus a case in
`resume_command`, `resumable`, `worked_in` and `current_name`. Add an
`adapters/<tool>/` folder that makes the CLI's hooks run
`~/.local/bin/agent-sessions track <tool>`, and a line in `install.sh` that
wires it where that CLI keeps its config. The CLI must be able to resume a
session by id: Gemini CLI 0.18.4 resumes only by index or `latest`, so it
cannot be supported yet.

**A terminal.** Add an `open_<terminal>` function that takes the layout
described above, and a rule in `detect_terminal` if it can be recognized
from the environment.
