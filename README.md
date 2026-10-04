# agent-sessions

Reopen the Claude Code sessions a reboot closed, laid out the way you worked
them: one Ghostty window, a tab per repo, a split per session.

```
$ agent-restore

  webapp  ~/src/webapp
      auth-refactor
      flaky-tests
  infra  ~/src/infra
      dns-migration

3 session(s) in 2 tab(s).
Reopen? [y/N]
```

Claude Code hooks keep a small record of every session in a terminal. After
a reboot, `agent-restore` reopens the ones that were still open — and leaves
alone the ones you closed on purpose with `/exit`.

## Requirements

macOS, [Ghostty](https://ghostty.org), `jq`, and an agent CLI with an
adapter: today, Claude Code.

## Install

```bash
git clone https://github.com/ignaciojimenez/agent-sessions.git
cd agent-sessions && ./install.sh
```

`install.sh` links the script into `~/.local/bin` as `agent-sessions` and
`agent-restore`, and wires an adapter for each agent CLI it finds. Every link
points into the clone, so `git pull` updates it; `./install.sh --uninstall`
removes them. Start agent sessions afresh afterwards: hooks load at startup.

## Use

Name sessions as you start them (`claude -n <name>`, or `/rename` later) so
the plan reads well; unnamed sessions you worked in come back too.

```bash
agent-restore             # after a reboot: show the plan, ask, reopen
agent-restore -n          # plan only
agent-restore -y          # no prompt
agent-sessions list       # every recorded session: running, closed or lost
```

Records live in `~/.local/state/agent-sessions/` (`0700`) and hold paths and
session names only, never conversation content. They are pruned after 14 days.

## Docs

- [`docs/design.md`](docs/design.md) — what gets reopened and why, the
  measured hook behaviour behind each rule, security, adding another CLI
- [`docs/decisions.md`](docs/decisions.md) — architecture calls, newest first

## Layout

```
agent-sessions        the tool: records sessions, plans and reopens them
adapters/<cli>/       how one agent CLI reports its sessions to it
install.sh            links the tool onto PATH and wires the adapters
tests/contract.sh     replays real hook payloads; also tests install.sh
```
