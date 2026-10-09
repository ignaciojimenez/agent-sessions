# agent-sessions

Reopen the coding-agent sessions a reboot closed, laid out the way you left
them: a tab per repository, a split per session.

```
$ agent-restore

  webapp  ~/src/webapp
      auth-refactor
      flaky-tests
  infra  ~/src/infra
      dns-migration

3 session(s) in 2 tab(s), via ghostty.
Reopen? [y/N]
```

The agent CLI's session hooks keep a small record of each interactive
session: its id, name and directory. After a reboot, `agent-restore` reopens
the sessions that were still open, and leaves out the ones you closed on
purpose. Records never hold conversation content.

## Supported

Both sides are adapters, so another agent CLI or terminal is one function
away ([extending](docs/design.md#extending)).

| Agent CLI | |
|---|---|
| Claude Code | sessions recorded by its `SessionStart`/`SessionEnd` hooks, resumed by id |
| Droid (Factory) | sessions recorded by its `SessionStart`/`UserPromptSubmit`/`SessionEnd` hooks, resumed by id |

| Terminal | Layout | Platforms |
|---|---|---|
| Ghostty | native window, tabs and splits | macOS |
| tmux | a window per repo, a pane per session, in any terminal emulator | macOS, Linux |
| print | the commands to run, for any other terminal | any |

## Requirements

`bash`, `jq` and `git`, a supported agent CLI, and Ghostty or tmux for
anything beyond printing the commands. A session is recorded when it runs
in a terminal that sets `TERM_PROGRAM`, as Ghostty and tmux do; on Linux,
run agents inside tmux.

## Install

```bash
git clone https://github.com/ignaciojimenez/agent-sessions.git
cd agent-sessions && ./install.sh
```

`install.sh` links the tool into `~/.local/bin` as `agent-sessions` and
`agent-restore`, wires the adapter of each agent CLI it finds, and on macOS
builds the **Agent Restore** app. For Droid, that means adding its three hooks
to `~/.factory/settings.json` (or `~/.factory/hooks.json`, if you have one);
the hooks already there are kept. Every link points into the clone, so
`git pull` updates it, and `./install.sh --uninstall` removes it all.
Restart running agent sessions afterwards so they load the hooks.

## Use

```bash
agent-restore                 # after a reboot: show the plan, ask, reopen
agent-restore -n              # show the plan only
agent-restore -y              # reopen without asking
agent-restore -t tmux         # choose the terminal: ghostty, tmux or print
agent-sessions list           # every recorded session: running, closed or lost
```

The terminal is detected: tmux when run inside tmux, Ghostty when run in
Ghostty on macOS, otherwise `print`. Set `AGENT_SESSIONS_TERMINAL` to change
the default.

Named sessions make the plan easier to read (in Claude Code: `claude -n
<name>`, or `/rename`; in Droid: `/rename`); unnamed ones you worked in are
reopened too.

On macOS, **Agent Restore** in Spotlight shows the same plan in a dialog and
reopens in Ghostty. The first run asks for permission to control Ghostty.

Records live in `~/.local/state/agent-sessions/` (mode `0700`) and are
pruned after 14 days.

## Docs

- [Design](docs/design.md): what gets reopened and why, the adapters,
  what was verified, security
- [Decisions](docs/decisions.md): architecture decisions, newest first

## Layout

```
agent-sessions       the tool: records sessions, plans and reopens them
adapters/<agent>/    hooks for one agent CLI (claude, droid)
macos/               source of the Spotlight app, compiled by install.sh
install.sh           installs the tool, the adapters and the app
tests/contract.sh    contract tests: real hook payloads, terminals, install
```

## License

[MIT](LICENSE)
