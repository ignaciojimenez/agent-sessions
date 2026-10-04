#!/bin/bash
#
# install.sh — put agent-sessions on PATH and wire it into the agent CLIs on
# this machine. Idempotent, and every link points into this checkout, so
# `git pull` is the update.
#
#   ./install.sh              install, or refresh the links
#   ./install.sh --uninstall  remove the links this checkout made
#
#   ~/.local/bin/agent-sessions      -> ./agent-sessions
#   ~/.local/bin/agent-restore       -> ./agent-sessions  (run under this name, it restores)
#   ~/.claude/skills/agent-sessions  -> ./adapters/claude (when ~/.claude exists)
#
# A link replaces an older link. Anything that is not a link is left alone and
# reported, and the install exits non-zero.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# Fixed, not configurable: the adapters' hook commands name this path.
BIN="$HOME/.local/bin"
conflicts=0

say() { echo "  $*"; }
tilde() { echo "${1/#$HOME/~}"; }

link() {  # <target> <link>
  if [[ -e "$2" && ! -L "$2" ]]; then
    say "skip    $(tilde "$2") exists and is not a link; move it aside and re-run"
    conflicts=$((conflicts + 1))
    return 0
  fi
  mkdir -p "$(dirname "$2")" && ln -sfn "$1" "$2" &&
    say "linked  $(tilde "$2") -> $(tilde "$1")"
}

unlink_ours() {  # <link>
  local to
  [[ -L "$1" ]] || return 0
  to=$(readlink "$1")
  [[ "$to" == "$ROOT" || "$to" == "$ROOT"/* ]] || return 0
  rm -f "$1" && say "removed $(tilde "$1")"
}

case "${1:-}" in
  --uninstall)
    unlink_ours "$BIN/agent-sessions"
    unlink_ours "$BIN/agent-restore"
    unlink_ours "$HOME/.claude/skills/agent-sessions"
    exit 0
    ;;
  "") ;;
  *) sed -n '3,9s/^# \{0,1\}//p' "$0"; exit 1 ;;
esac

echo "agent-sessions: $(tilde "$ROOT")"
link "$ROOT/agent-sessions" "$BIN/agent-sessions"
link "$ROOT/agent-sessions" "$BIN/agent-restore"

# Adapters: one per agent CLI, wired only where that CLI lives.
if [[ -d "$HOME/.claude" ]]; then
  # Claude Code loads a plugin folder found under ~/.claude/skills/, hooks
  # included, with no install step.
  link "$ROOT/adapters/claude" "$HOME/.claude/skills/agent-sessions"
else
  say "skip    Claude Code adapter (no ~/.claude)"
fi

command -v jq >/dev/null || say "warning jq not found; agent-sessions needs it (brew install jq)"
case ":$PATH:" in
  *":$BIN:"*) ;;
  *) say "warning $(tilde "$BIN") is not on PATH; add it to run agent-restore" ;;
esac

[[ "$conflicts" -eq 0 ]]
