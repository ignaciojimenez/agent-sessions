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

| Agent CLI | Reopened with |
|---|---|
| Claude Code | `claude --resume <id>` |
| Droid (Factory) | `droid --resume <id>` |

| Terminal | Layout | Platforms |
|---|---|---|
| Ghostty | native window, tabs and splits | macOS |
| tmux | a window per repo, a pane per session, in any terminal emulator | macOS, Linux |
| print | the commands to run, for any other terminal | any |

Agent CLIs and terminals are adapters; adding one is described in
[extending](docs/design.md#extending).

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
`agent-restore`, wires each agent CLI it finds, and on macOS builds the
**Agent Restore** app. Droid's hooks are added to `~/.factory/settings.json`,
keeping the ones already there. Links point into the clone, so `git pull`
updates it; `./install.sh --uninstall` removes it all. Restart running Claude
Code sessions to load the hooks; Droid loads them on the next prompt.

## Use

```bash
agent-restore                 # after a reboot: show the plan, ask, reopen
agent-restore -n              # show the plan only
agent-restore -y              # reopen without asking
agent-restore -t tmux         # choose the terminal: ghostty, tmux or print
agent-sessions list           # every recorded session: running, closed or lost
```

The terminal is detected: tmux inside tmux, Ghostty in Ghostty on macOS,
otherwise `print`. Set `AGENT_SESSIONS_TERMINAL` to change the default.

Named sessions make the plan easier to read (`/rename` in either CLI);
unnamed ones you worked in are reopened too.

On macOS, **Agent Restore** in Spotlight shows the same plan in a dialog and
reopens in Ghostty.

Records live in `~/.local/state/agent-sessions/` (mode `0700`) and are
pruned after 14 days.

## Limitations

- If a shutdown stops Droid while its terminal is still open, the session
  looks like `/exit` and is not reopened. Quitting the terminal first
  avoids it.
- iTerm2 and Terminal.app work through tmux only.

## Development

Run the tests with `tests/contract.sh` (needs `jq` and `git`; `tmux` is
optional locally).

## Docs

- [Design](docs/design.md): what gets reopened and why, the adapters,
  what was verified, security
- [Decisions](docs/decisions.md): architecture decisions, newest first

## License

[MIT](LICENSE)
