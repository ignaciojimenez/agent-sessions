# Decisions

One-liners, newest first. The reasoning for each lives in `design.md`.

- **2026-10-04 — Two install channels, one tag.** Claude Code runs the hook
  from the plugin's own copy (`${CLAUDE_PLUGIN_ROOT}`), because that path is
  the only one guaranteed to exist where hooks run. The shell needs a command
  on `PATH`, which a plugin cannot provide outside Claude's Bash tool, so
  Homebrew ships the same script from the same tag. The record format is the
  contract between the two copies; keep it backward compatible.
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
