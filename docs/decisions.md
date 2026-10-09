# Decisions

One-liners, newest first. The reasoning for each lives in `design.md`.

- **2026-10-05 — Droid is the second agent adapter; its hooks are merged
  into the user's settings.** Droid loads plugins only from a marketplace,
  the route already dropped for Claude, so `install.sh` edits the active
  user hooks file instead, and never creates a `hooks.json` that would hide
  the hooks in `settings.json`. Droid ends `/exit` and a reboot with the same
  reason, so whether the agent still holds its terminal decides which it was.

- **2026-10-04 — Terminals are adapters too, and tmux is the portable one.**
  Ghostty keeps its native layout; tmux covers Linux and every terminal
  without an adapter; `print` is the fallback. Detection picks only the
  terminal it is running in, never a GUI it would have to guess at. No
  native iTerm2 or Terminal.app adapter: Terminal.app cannot script tabs or
  splits, and iTerm2 could not be tested.
- **2026-10-04 — Spotlight gets an AppleScript app, built on install.** Spotlight
  launches apps, not commands. `osacompile` ships with macOS and needs no
  signing identity; a Shortcuts shortcut would need its UI to create.
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
