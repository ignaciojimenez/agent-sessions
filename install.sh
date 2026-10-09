#!/bin/bash
#
# install.sh — put agent-sessions on PATH and wire it into the agent CLIs on
# this machine. Idempotent, and every link points into this checkout, so
# `git pull` is the update.
#
#   ./install.sh              install, or refresh the links
#   ./install.sh --uninstall  undo all of it
#
#   ~/.local/bin/agent-sessions      -> ./agent-sessions
#   ~/.local/bin/agent-restore       -> ./agent-sessions  (run under this name, it restores)
#   ./adapters/<tool>                   wired into each agent CLI found here
#   ~/Applications/Agent Restore.app    built from ./macos (macOS): agent-restore
#                                       for Spotlight
#
# Nothing it did not make is replaced: anything in the way is left alone and
# reported, and the install exits non-zero.

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
problem() { say "$*"; problems=$((problems + 1)); }

# Every step below takes the mode first and does or undoes one thing, so an
# install and its uninstall cannot drift apart.

symlink() {  # install|uninstall <target> <link>
  if [[ "$1" == uninstall ]]; then
    case "$(readlink "$3")" in
      "$ROOT"|"$ROOT"/*) rm -f "$3" && say "removed $(tilde "$3")" ;;
    esac
    return 0
  fi
  if [[ -e "$3" && ! -L "$3" ]]; then
    problem "skip    $(tilde "$3") exists and is not a link; move it aside and re-run"; return 0
  fi
  mkdir -p "$(dirname "$3")" && ln -sfn "$2" "$3" && say "linked  $(tilde "$3") -> $(tilde "$2")"
}

# Adds the hooks in <hooks> to the hook map at <path> in <file>, or takes
# them out. Groups running the adapter's commands are dropped first, so a
# re-run changes nothing and the other hooks stay as they were.
merge_hooks() {  # install|uninstall <hooks> <file> <jq path>
  local old new
  [[ -f "$3" || "$1" == install ]] || return 0
  old=$(if [[ -f "$3" ]]; then cat "$3"; else echo '{}'; fi)
  new=$(jq --slurpfile ours "$2" --argjson p "$4" --arg mode "$1" '
    ($ours[0] | [.[][].hooks[].command] | unique) as $cmds
    | (getpath($p) // {}
       | map_values(map(select(all(.hooks[]?; .command as $c | $cmds | index($c) | not))))
       | reduce ($ours[0] | keys[]) as $k (.; if .[$k] == [] then del(.[$k]) else . end)
       | if $mode == "install"
         then reduce ($ours[0] | to_entries[]) as $e (.; .[$e.key] += $e.value)
         else . end) as $hooks
    | if $p != [] and $hooks == {} then delpaths([$p]) else setpath($p; $hooks) end
  ' <<<"$old") || { problem "error   could not read $(tilde "$3")"; return 0; }

  if [[ "$(jq -S . <<<"$old")" == "$(jq -S . <<<"$new")" ]]; then
    [[ "$1" == install ]] && say "current $(tilde "$3")"
    return 0
  fi
  # Written in place, so a settings file that is a link, or has its own
  # mode, stays that way.
  printf '%s\n' "$new" >"$3" || { problem "error   could not write $(tilde "$3")"; return 0; }
  if [[ "$1" == install ]]; then say "wired   $(tilde "$3")"; else say "unwired $(tilde "$3")"; fi
}

# ─── Adapters ────────────────────────────────────────────────────────────────
# wire_<tool> for each adapters/<tool>/. It fails when that CLI is not
# installed here.

# Claude Code loads a plugin folder found under ~/.claude/skills/, hooks
# included, with no install step.
wire_claude() {  # install|uninstall
  [[ -d "$HOME/.claude" ]] || return 1
  symlink "$1" "$ROOT/adapters/claude" "$HOME/.claude/skills/agent-sessions"
}

# Droid only loads plugins from a marketplace, so its hooks go into the user
# hooks file: ~/.factory/hooks.json if there is one. Without it, Droid reads
# the hooks key of settings.json, and creating hooks.json would hide them.
wire_droid() {  # install|uninstall
  local f="$HOME/.factory"
  [[ -d "$f" ]] || return 1
  if [[ -f "$f/hooks.json" || ! -f "$f/settings.json" ]]; then
    merge_hooks "$1" "$ROOT/adapters/droid/hooks.json" "$f/hooks.json" '[]'
  else
    merge_hooks "$1" "$ROOT/adapters/droid/hooks.json" "$f/settings.json" '["hooks"]'
  fi
}

# ─── Spotlight app (macOS) ───────────────────────────────────────────────────

as_string() {  # <text>: escaped for an AppleScript string literal
  local s=${1//\\/\\\\}
  printf '%s' "${s//\"/\\\"}"
}

app() {  # install|uninstall
  local jq git src tmp
  if [[ "$1" == uninstall ]]; then
    [[ -f "$APP/$STAMP" ]] && rm -rf "$APP" && say "removed $(tilde "$APP")"
    return 0
  fi
  if [[ "$(uname -s)" != Darwin ]] || ! command -v osacompile >/dev/null; then
    say "skip    Spotlight app (macOS only)"; return 0
  fi
  jq=$(command -v jq) && git=$(command -v git) ||
    { say "skip    Spotlight app (needs jq and git)"; return 0; }
  src=$(<"$ROOT/macos/agent-restore.applescript")
  src=${src//@@TOOL@@/$(as_string "$BIN/agent-sessions")}
  src=${src//@@PATH@@/$(as_string "${jq%/*}:${git%/*}:/usr/bin:/bin:/usr/sbin:/sbin")}
  if [[ -e "$APP" && ! -f "$APP/$STAMP" ]]; then
    problem "skip    $(tilde "$APP") exists and was not built here; move it aside and re-run"; return 0
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
    problem "error   could not build $(tilde "$APP")"
  fi
  rm -rf "$tmp"
}

# ─── Main ────────────────────────────────────────────────────────────────────

case "${1:-}" in
  "") mode=install ;;
  --uninstall) mode=uninstall ;;
  *) sed -n '3,8s/^# \{0,1\}//p' "$0"; exit 1 ;;
esac

echo "agent-sessions: $(tilde "$ROOT")"
symlink "$mode" "$ROOT/agent-sessions" "$BIN/agent-sessions"
symlink "$mode" "$ROOT/agent-sessions" "$BIN/agent-restore"
for adapter in "$ROOT"/adapters/*/; do
  adapter=$(basename "$adapter")
  declare -F "wire_$adapter" >/dev/null || { problem "error   adapters/$adapter has no wire_$adapter"; continue; }
  "wire_$adapter" "$mode" || [[ "$mode" == uninstall ]] || say "skip    $adapter adapter ($adapter is not installed)"
done
app "$mode"

if [[ "$mode" == install ]]; then
  command -v jq >/dev/null || say "warning jq not found; agent-sessions needs it (brew install jq)"
  case ":$PATH:" in
    *":$BIN:"*) ;;
    *) say "warning $(tilde "$BIN") is not on PATH; add it to run agent-restore" ;;
  esac
fi

[[ "$problems" -eq 0 ]]
