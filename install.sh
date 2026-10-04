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
#   ~/Applications/Agent Restore.app    built from ./macos (macOS): agent-restore
#                                       for Spotlight
#
# A link replaces an older link, and the app one this script built. Anything
# else in the way is left alone and reported, and the install exits non-zero.

set -uo pipefail
# Bash 5.2 reads & in a ${var//pattern/replacement} replacement as the match.
shopt -u patsub_replacement 2>/dev/null || true

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# Fixed, not configurable: the adapters' hook commands name this path.
BIN="$HOME/.local/bin"
APP="$HOME/Applications/Agent Restore.app"
# The source the app was compiled from. Marks the app as built here, and tells
# a re-run whether it is current.
STAMP="Contents/Resources/agent-restore.applescript"
problems=0

say() { echo "  $*"; }
tilde() { echo "${1/#$HOME/~}"; }

link() {  # <target> <link>
  if [[ -e "$2" && ! -L "$2" ]]; then
    say "skip    $(tilde "$2") exists and is not a link; move it aside and re-run"
    problems=$((problems + 1))
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

as_string() {  # <text>: escaped for an AppleScript string literal
  local s=${1//\\/\\\\}
  printf '%s' "${s//\"/\\\"}"
}

build_app() {
  local jq git src tmp
  if [[ "$(uname -s)" != Darwin ]] || ! command -v osacompile >/dev/null; then
    say "skip    Spotlight app (macOS only)"; return 0
  fi
  jq=$(command -v jq) && git=$(command -v git) ||
    { say "skip    Spotlight app (needs jq and git)"; return 0; }
  src=$(<"$ROOT/macos/agent-restore.applescript")
  src=${src//@@TOOL@@/$(as_string "$BIN/agent-sessions")}
  src=${src//@@PATH@@/$(as_string "${jq%/*}:${git%/*}:/usr/bin:/bin:/usr/sbin:/sbin")}
  if [[ -e "$APP" && ! -f "$APP/$STAMP" ]]; then
    say "skip    $(tilde "$APP") exists and was not built here; move it aside and re-run"
    problems=$((problems + 1)); return 0
  fi
  # Rebuilt only when its source changes: new code makes macOS ask again for
  # permission to control Ghostty.
  if [[ -f "$APP/$STAMP" && "$(<"$APP/$STAMP")" == "$src" ]]; then
    say "current $(tilde "$APP")"; return 0
  fi
  tmp=$(mktemp -d) || return 1
  printf '%s\n' "$src" >"$tmp/agent-restore.applescript"
  if rm -rf "$APP" && mkdir -p "${APP%/*}" &&
     osacompile -o "$APP" "$tmp/agent-restore.applescript" &&
     printf '%s' "$src" >"$APP/$STAMP"; then
    say "built   $(tilde "$APP")"
  else
    say "error   could not build $(tilde "$APP")"
    problems=$((problems + 1))
  fi
  rm -rf "$tmp"
}

case "${1:-}" in
  --uninstall)
    unlink_ours "$BIN/agent-sessions"
    unlink_ours "$BIN/agent-restore"
    unlink_ours "$HOME/.claude/skills/agent-sessions"
    if [[ -f "$APP/$STAMP" ]]; then rm -rf "$APP" && say "removed $(tilde "$APP")"; fi
    exit 0
    ;;
  "") ;;
  *) sed -n '3,8s/^# \{0,1\}//p' "$0"; exit 1 ;;
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

build_app

command -v jq >/dev/null || say "warning jq not found; agent-sessions needs it (brew install jq)"
case ":$PATH:" in
  *":$BIN:"*) ;;
  *) say "warning $(tilde "$BIN") is not on PATH; add it to run agent-restore" ;;
esac

[[ "$problems" -eq 0 ]]
