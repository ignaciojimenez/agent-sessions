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
#   ~/.factory/settings.json            + the hooks in ./adapters/droid (when
#                                       ~/.factory exists; hooks.json if it has one)
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
FACTORY="$HOME/.factory"
DROID_HOOKS="$ROOT/adapters/droid/hooks.json"
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

# Droid has no plugin folder it loads unasked, so its hooks go into the user
# hooks file. That is ~/.factory/hooks.json if there is one; without it,
# Droid reads the hooks key of settings.json, and creating hooks.json would
# hide every hook declared there.
droid_hooks() {  # install|uninstall
  local file path old new
  if [[ -f "$FACTORY/hooks.json" || ! -f "$FACTORY/settings.json" ]]; then
    file="$FACTORY/hooks.json" path='[]'
  else
    file="$FACTORY/settings.json" path='["hooks"]'
  fi
  [[ -f "$file" || "$1" == install ]] || return 0
  old=$(if [[ -f "$file" ]]; then cat "$file"; else echo '{}'; fi)
  # Every group running our command is dropped, then the adapter's appended,
  # so a re-run changes nothing and uninstall leaves the others as they were.
  new=$(jq --argjson p "$path" --slurpfile ours "$DROID_HOOKS" --arg mode "$1" '
    ($ours[0] | [.[][].hooks[].command] | unique) as $cmds
    | (getpath($p) // {}
       | map_values(map(select(all(.hooks[]?; .command as $c | $cmds | index($c) | not))))
       | reduce ($ours[0] | keys[]) as $k (.; if .[$k] == [] then del(.[$k]) else . end)
       | if $mode == "install"
         then reduce ($ours[0] | to_entries[]) as $e (.; .[$e.key] += $e.value)
         else . end) as $hooks
    | if $p != [] and $hooks == {} then delpaths([$p]) else setpath($p; $hooks) end
  ' <<<"$old") || { say "error   could not read $(tilde "$file")"; problems=$((problems + 1)); return 0; }

  if [[ "$(jq -S . <<<"$old")" == "$(jq -S . <<<"$new")" ]]; then
    [[ "$1" == install ]] && say "current $(tilde "$file") (Droid hooks)"
    return 0
  fi
  # Written in place, so a settings file that is a link, or has its own
  # mode, stays that way.
  mkdir -p "$FACTORY" && printf '%s\n' "$new" >"$file" || {
    say "error   could not write $(tilde "$file")"; problems=$((problems + 1)); return 0; }
  if [[ "$1" == install ]]; then say "wired   $(tilde "$file") (Droid hooks)"
  else say "removed Droid hooks from $(tilde "$file")"
  fi
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
    [[ -d "$FACTORY" ]] && droid_hooks uninstall
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
if [[ -d "$FACTORY" ]]; then
  droid_hooks install
else
  say "skip    Droid adapter (no ~/.factory)"
fi

build_app

command -v jq >/dev/null || say "warning jq not found; agent-sessions needs it (brew install jq)"
case ":$PATH:" in
  *":$BIN:"*) ;;
  *) say "warning $(tilde "$BIN") is not on PATH; add it to run agent-restore" ;;
esac

[[ "$problems" -eq 0 ]]
