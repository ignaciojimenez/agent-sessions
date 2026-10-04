# Decisions

One-liners, newest first. The reasoning for each lives in `design.md`.

- **2026-10-04 — The tool is the centre; each agent CLI is an adapter.** The
  script sits at the root and is installed by `git clone` + `install.sh`,
  which links it into `~/.local/bin` and wires `adapters/<cli>/` for the CLIs
  present. Adapters call that fixed path, so there is one copy and `git pull`
  updates it. Tried first and dropped the same day: shipping the repo as a
  Claude Code marketplace plugin plus a Homebrew formula. It made the whole
  repo a Claude plugin, and a release tag and formula are machinery a single
  bash script does not need.
- **2026-10-04 — `agent-restore` is the script under a second name**, not a
  shell alias, so it works without anyone's dotfiles.
- **2026-10-04 — Extracted from
  [dotfiles](https://github.com/ignaciojimenez/dotfiles)** with its history,
  once a real reboot had confirmed it.
- **2026-09-18 — Sessions are reopened from a record the hooks keep, not from
  anything Claude Code stores about itself.** `~/.claude/sessions/<pid>.json`
  lists live sessions, but it is undocumented and Claude-only;
  `SessionStart`/`SessionEnd` are documented, and a tool-neutral record lets
  another CLI plug in with one adapter. `SessionEnd` cannot tell a reboot from
  a closed window (both are `other`), so the batch is inferred at restore time.
