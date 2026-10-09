#!/bin/bash
#
# Contract test for agent-sessions, its terminal adapters, and install.sh.
#
# Replays hook payloads shaped exactly like the ones Claude Code 2.1.27x and
# Droid 0.231.0 send (captured live — see docs/design.md) into a throwaway state dir,
# with a fixed clock, then asserts on the records and on the restore plan.
# No network, no real sessions; tmux runs on a private server. Runs on macOS
# and Linux.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
BIN="${AGENT_SESSIONS_BIN:-$ROOT/agent-sessions}"
# Resolved: a pane's shell reports its directory without symlinks, and on
# macOS $TMPDIR is usually under /var, a link to /private/var.
T="$(cd "$(mktemp -d -t agent-sessions-test.XXXXXX)" && pwd -P)"
# tmux's socket path must fit a sockaddr (104 bytes on macOS); $TMPDIR may not.
TM="$(mktemp -d /tmp/as-tmux.XXXXXX)"
FAKE_PID="" FAKE_DROID=""
trap 'kill $FAKE_PID $FAKE_DROID 2>/dev/null; tmux_ kill-server 2>/dev/null; rm -rf "$T" "$TM"' EXIT

export AGENT_SESSIONS_STATE="$T/state" TERM_PROGRAM=test CLAUDE_CODE_ENTRYPOINT=cli
unset TMUX AGENT_SESSIONS_TERMINAL FACTORY_DISABLE_SETTINGS_PERSISTENCE
PASS=0 FAIL=0
check() {  # <description> <command...>
  local desc=$1; shift
  if "$@"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "  ✗ $desc"; return 1; fi
}
has()      { grep -qF -- "$2" <<<"$1"; }
hasnt()    { ! grep -qF -- "$2" <<<"$1"; }
recorded() { [[ -f "$AGENT_SESSIONS_STATE/$1-$2.json" ]]; }  # <tool> <id>
tmux_()    { TMUX_TMPDIR="$TM" tmux "$@"; }  # a private tmux server

mkdir -p "$T/repo/sub" "$T/repo2" "$T/transcripts" "$T/agents"
git -C "$T/repo" init -q && git -C "$T/repo2" init -q

# hook <tool> <at> <payload>: sent the way the CLI runs its hooks, from the
# agent's own process (a stand-in named after it), with no terminal unless
# TTY=1. Whether the agent holds a terminal is part of what an adapter reads.
for tool in claude droid; do ln -s "$(command -v bash)" "$T/agents/$tool"; done
hook() {
  local payload="$T/payload.json" agent
  printf '%s\n' "$3" >"$payload"
  # The trailing `:` keeps bash from exec-ing the tool in its own place.
  agent=("$T/agents/$1" -c '"$0" track "$1" <"$2"; :' "$BIN" "$1" "$payload")
  if [[ "${TTY:-}" == 1 ]]; then
    if [[ "$(uname -s)" == Darwin ]]; then AGENT_SESSIONS_NOW=$2 script -q /dev/null "${agent[@]}"
    else AGENT_SESSIONS_NOW=$2 script -qec "$(printf '%q ' "${agent[@]}")" /dev/null
    fi </dev/null >/dev/null
  else
    # A session of its own, so there is no terminal to inherit.
    AGENT_SESSIONS_NOW=$2 perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV or die "exec: $!"' "${agent[@]}"
  fi
}

# Claude Code: start <at> <id> <title> [cwd] [source]   end <at> <id> <reason>
start() {
  hook claude "$1" "$(jq -n --arg id "$2" --arg title "$3" --arg cwd "${4:-$T/repo}" \
        --arg src "${5:-startup}" --arg tp "$T/transcripts/$2.jsonl" \
    '{session_id: $id, transcript_path: $tp, cwd: $cwd,
      scratchpad_dir: "/tmp/x", hook_event_name: "SessionStart",
      source: $src, model: "claude-opus-5"}
     + (if $title == "" then {} else {session_title: $title} end)')"
}
end() {
  hook claude "$1" "$(jq -n --arg id "$2" --arg reason "$3" --arg cwd "$T/repo" \
        --arg tp "$T/transcripts/$2.jsonl" \
    '{session_id: $id, transcript_path: $tp, cwd: $cwd,
      scratchpad_dir: "/tmp/x", prompt_id: "p", hook_event_name: "SessionEnd",
      reason: $reason}')"
}
transcript() {  # <id> [title...] — one custom-title record per rename
  local id=$1 t; shift
  : >"$T/transcripts/$id.jsonl"
  for t in "$@"; do
    jq -nc --arg t "$t" --arg id "$id" '{type: "custom-title", customTitle: $t, sessionId: $id}' \
      >>"$T/transcripts/$id.jsonl"
  done
}
said() {  # <id> <type> — append one conversation record to the transcript
  jq -nc --arg t "$2" --arg id "$1" '{type: $t, sessionId: $id, message: {content: "x"}}' \
    >>"$T/transcripts/$1.jsonl"
}

echo "agent-sessions contract"

# Closed on purpose: forgotten.
start 1000 aaaaaaaa-0001 "exited"; end 1010 aaaaaaaa-0001 prompt_input_exit
check "/exit forgets the session" eval '! recorded claude aaaaaaaa-0001'

# "other" (terminal closed, signal, reboot): kept as closed.
start 5000 aaaaaaaa-0002 "alpha"; end 9000 aaaaaaaa-0002 other
transcript aaaaaaaa-0002 "alpha" "alpha-renamed"
check "'other' keeps the session" recorded claude aaaaaaaa-0002
check "'other' records when it ended" \
  test "$(jq .ended_at "$AGENT_SESSIONS_STATE/claude-aaaaaaaa-0002.json")" = 9000

# /clear: the old id is forgotten, the new one inherits the title.
start 5000 aaaaaaaa-0003 "zeta"; end 6000 aaaaaaaa-0003 clear
start 6000 aaaaaaaa-0004 "zeta" "$T/repo" clear; end 9100 aaaaaaaa-0004 other
transcript aaaaaaaa-0004
check "/clear forgets the old id" eval '! recorded claude aaaaaaaa-0003'
check "/clear records the new id" recorded claude aaaaaaaa-0004

# A session in a subdirectory, and one in a second repo.
start 5000 aaaaaaaa-0005 "beta" "$T/repo/sub"; end 9050 aaaaaaaa-0005 other
transcript aaaaaaaa-0005
start 5000 aaaaaaaa-0006 "gamma" "$T/repo2"; end 9020 aaaaaaaa-0006 other
transcript aaaaaaaa-0006

# Killed before its hook ran (no end, process gone): lost, so reopened.
start 5000 aaaaaaaa-0007 "delta"; transcript aaaaaaaa-0007

# Still running: a live process named after the tool owns the record.
mkdir -p "$T/bin" && ln -s "$(command -v sleep)" "$T/bin/claude"
"$T/bin/claude" 60 & FAKE_PID=$! && disown
start 5000 aaaaaaaa-0008 "epsilon"; transcript aaaaaaaa-0008
f="$AGENT_SESSIONS_STATE/claude-aaaaaaaa-0008.json"
jq --argjson p "$FAKE_PID" '.pid = $p' "$f" >"$f.new" && mv "$f.new" "$f"

# Closed long before the last batch: not part of it.
start 1000 aaaaaaaa-0009 "old"; end 2000 aaaaaaaa-0009 other; transcript aaaaaaaa-0009

# Unnamed: one only opened and /cleared (no assistant turn), one worked in.
start 5000 aaaaaaaa-0010 ""; end 9000 aaaaaaaa-0010 other; transcript aaaaaaaa-0010
said aaaaaaaa-0010 user
start 5000 bbbbbbbb-0014 "" "$T/repo2"; end 9000 bbbbbbbb-0014 other
transcript bbbbbbbb-0014; said bbbbbbbb-0014 user; said bbbbbbbb-0014 assistant
# Named but never used (no transcript).
start 5000 aaaaaaaa-0011 "theta"; end 9000 aaaaaaaa-0011 other

# No terminal (`claude --bg`): never recorded.
TERM_PROGRAM="" start 5000 aaaaaaaa-0012 "background"
check "a session without a terminal is not recorded" eval '! recorded claude aaaaaaaa-0012'

# Headless (`claude -p` from a terminal): never recorded either.
CLAUDE_CODE_ENTRYPOINT=sdk-cli start 5000 aaaaaaaa-0015 "headless"
check "a headless session is not recorded" eval '! recorded claude aaaaaaaa-0015'

# Ids that could escape the state dir or become a shell option are refused.
start 5000 "../../escape" "evil" 2>/dev/null
start 5000 "-rf" "evil" 2>/dev/null
check "hostile ids write nothing" \
  test "$(find "$T" -name '*escape*' -o -name '*-rf*' | wc -l | tr -d ' ')" = 0

list=$(AGENT_SESSIONS_NOW=9200 "$BIN" list)
check "list shows the running session as running" has "$list" "running  claude  epsilon"
check "list shows the lost session as lost" has "$list" "lost     claude  delta"

plan=$(AGENT_SESSIONS_NOW=9200 "$BIN" restore -n)
check "plan uses the name from the last /rename" has "$plan" "alpha-renamed"
check "plan includes the last batch" has "$plan" "zeta"
check "plan includes lost sessions" has "$plan" "delta"
check "plan groups a subdirectory under its repo" \
  test "$(grep -A4 "  repo  " <<<"$plan" | grep -c beta)" = 1
check "plan opens one tab per repo" has "$plan" "6 session(s) in 2 tab(s),"
check "plan leaves running sessions alone" hasnt "$plan" "epsilon"
check "plan leaves out sessions closed before the batch" hasnt "$plan" "      old"
check "plan reopens an unnamed session that was worked in" has "$plan" "(unnamed bbbbbbbb)"
check "plan skips an unnamed session nothing happened in" \
  has "$plan" "skipping unnamed session in $T/repo: nothing in it"
check "plan reports sessions with nothing to resume" has "$plan" "theta: nothing to resume"

# Terminal adapters: which one is picked, and what each opens.
via() { AGENT_SESSIONS_NOW=9200 "$@" "$BIN" restore -n | tail -n 1; }
if [[ "$(uname -s)" == Darwin ]]; then
  check "in Ghostty on macOS, restore uses Ghostty" \
    test "$(via env TERM_PROGRAM=ghostty)" = "6 session(s) in 2 tab(s), via ghostty."
fi
check "inside tmux, restore uses tmux" test "$(via env TMUX=/tmp/x,1,0)" = "6 session(s) in 2 tab(s), via tmux."
check "in any other terminal, restore prints" test "$(via env TERM_PROGRAM=Apple_Terminal)" = "6 session(s) in 2 tab(s), via print."
check "AGENT_SESSIONS_TERMINAL picks the terminal" test "$(via env AGENT_SESSIONS_TERMINAL=tmux)" = "6 session(s) in 2 tab(s), via tmux."
check "-t overrides it" \
  test "$(AGENT_SESSIONS_TERMINAL=tmux AGENT_SESSIONS_NOW=9200 "$BIN" restore -n -t print | tail -n 1)" = "6 session(s) in 2 tab(s), via print."
check "an unknown terminal is refused" eval '! "$BIN" restore -n -t bogus 2>/dev/null'

printed=$(AGENT_SESSIONS_NOW=9200 "$BIN" restore -t print)
check "print lists each tab" has "$printed" "# repo2"
check "print gives a command per session" has "$printed" "cd $T/repo && claude --resume aaaaaaaa-0002"

# tmux, on a private server: the windows, panes and directories it opened,
# and the command typed into each pane. CI installs tmux; locally it is
# skipped, loudly, if missing.
if command -v tmux >/dev/null; then
  # A stub agent, so the panes never start a real one. The server is started
  # here, without the user's config, and every pane runs a non-login shell
  # with the stub first on an explicit PATH: neither a login profile nor
  # tmux's environment handling can put the real agent in front of it.
  mkdir -p "$T/stub" && printf '#!/bin/sh\necho "agent $* in $PWD"\n' >"$T/stub/claude" && chmod +x "$T/stub/claude"
  # Wide panes, so the long temp paths they print are not wrapped off screen.
  printf '%s\n' "set -g default-command \"exec env PATH='$T/stub:/usr/bin:/bin' /bin/sh\"" \
    'set -g default-size 400x50' >"$TM/tmux.conf"
  tmux_ -f "$TM/tmux.conf" new-session -d -s keepalive
  tmux_restore() { TMUX_TMPDIR="$TM" AGENT_SESSIONS_NOW=9200 "$BIN" restore -y -t tmux; }
  out=$(tmux_restore)
  check "tmux opens a session to attach to" has "$out" "tmux attach -t agent-sessions"
  check "tmux opens a window per repo, a pane per session" \
    test "$(tmux_ list-windows -t =agent-sessions -F '#{window_name} #{window_panes}' | tr '\n' ' ')" = "repo 4 repo2 2 "
  check "tmux starts each pane in its session's directory" \
    has "$(tmux_ list-panes -s -t =agent-sessions -F '#{pane_current_path}')" "$T/repo/sub"
  ran=""
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    ran=$(for p in $(tmux_ list-panes -s -t =agent-sessions -F '#{pane_id}'); do tmux_ capture-pane -p -J -S - -t "$p"; done)
    [[ $(grep -c '^agent --resume' <<<"$ran") -ge 6 ]] && break
    sleep 0.5
  done
  check "tmux runs every resume command, each in its own directory" \
    test "$(grep -c '^agent --resume' <<<"$ran")" = 6 ||
    grep -v '^$' <<<"$ran" | sed 's/^/      | /'
  check "tmux resumes the session in its subdirectory" has "$ran" "agent --resume aaaaaaaa-0005 in $T/repo/sub"
  out=$(tmux_restore)
  check "a second restore never reuses the session" has "$out" "tmux attach -t agent-sessions-9200"
elif [[ -n "${CI:-}" ]]; then
  check "tmux is installed in CI" false
else
  echo "  - tmux not installed: tmux adapter not tested"
fi

# Droid, in its own state dir. Every end is "other", so whether the agent
# still holds its terminal is what tells /exit from a closed one.
MAIN_STATE=$AGENT_SESSIONS_STATE
export AGENT_SESSIONS_STATE="$T/state-droid"
dhook() {  # <at> <event> <id> [reason]
  hook droid "$1" "$(jq -n --arg e "$2" --arg id "$3" --arg r "${4:-}" --arg cwd "$T/repo" \
        --arg tp "$T/transcripts/$3.jsonl" \
    '{session_id: $id, transcript_path: $tp, cwd: $cwd, permission_mode: "off",
      hook_event_name: $e}
     + (if $e == "SessionStart" then {source: "startup"} else {} end)
     + (if $r == "" then {} else {reason: $r, message_count: 1} end)')"
}
dtranscript() {  # <id> <title> <manually set: true|false> — with one answer in it
  jq -nc --arg id "$1" --arg t "$2" --argjson m "$3" \
    '{type: "session_start", id: $id, title: $t, isSessionTitleManuallySet: $m}' \
    >"$T/transcripts/$1.jsonl"
  jq -nc '{type: "message", message: {role: "assistant", content: []}}' >>"$T/transcripts/$1.jsonl"
}

dhook 5000 SessionStart dddddddd-0001
check "droid: a session is recorded" recorded droid dddddddd-0001
check "droid: the agent's pid is recorded" \
  test "$(jq -r '.pid | type' "$AGENT_SESSIONS_STATE/droid-dddddddd-0001.json")" = number
TTY=1 dhook 5010 SessionEnd dddddddd-0001 other
check "droid: an exit that leaves the terminal open forgets it" eval '! recorded droid dddddddd-0001'

dhook 5000 SessionStart dddddddd-0002; dtranscript dddddddd-0002 "droid-renamed" true
dhook 9000 SessionEnd dddddddd-0002 other
check "droid: a closed terminal keeps it, with when it ended" \
  test "$(jq .ended_at "$AGENT_SESSIONS_STATE/droid-dddddddd-0002.json")" = 9000

dhook 5000 SessionStart dddddddd-0003; dhook 6000 SessionEnd dddddddd-0003 clear
check "droid: /clear forgets the old id" eval '! recorded droid dddddddd-0003'

FACTORY_DISABLE_SETTINGS_PERSISTENCE=1 dhook 5000 SessionStart dddddddd-0004
check "droid: a headless run (droid exec) is not recorded" eval '! recorded droid dddddddd-0004'
TERM_PROGRAM="" dhook 5000 SessionStart dddddddd-0005
check "droid: a session without a terminal is not recorded" eval '! recorded droid dddddddd-0005'

# Resumed: Droid fires no SessionStart, so the first prompt records it, or,
# when there was none, its end.
dhook 6000 UserPromptSubmit dddddddd-0006; dtranscript dddddddd-0006 "prompted" true
check "droid: a resumed session is recorded on its first prompt" recorded droid dddddddd-0006
dhook 9050 SessionEnd eeeeeeee-0007 other
dtranscript eeeeeeee-0007 "Fix the flaky test in the payment service" false
check "droid: a resumed session closed unprompted is recorded at its end" recorded droid eeeeeeee-0007

dhook 5000 SessionStart "../../escape" 2>/dev/null
check "droid: hostile ids write nothing" \
  test "$(find "$T" -name '*escape*' | wc -l | tr -d ' ')" = 0

plan=$(AGENT_SESSIONS_NOW=9200 "$BIN" restore -t print)
check "droid: plan uses the name set by /rename" has "$plan" "droid-renamed"
check "droid: plan reopens a lost session" has "$plan" "prompted"
check "droid: a title Droid made up is not a name" has "$plan" "(unnamed eeeeeeee)"
check "droid: plan resumes by id" has "$plan" "cd $T/repo && droid --resume dddddddd-0002"
check "droid: plan opens all three" has "$plan" "3 session(s) in 1 tab(s),"

# Reopened by restore, not yet prompted: running, found by its command line.
mkdir -p "$T/stub-droid" && printf '#!/bin/sh\nsleep 60\n' >"$T/stub-droid/droid" && chmod +x "$T/stub-droid/droid"
"$T/stub-droid/droid" --resume dddddddd-0002 & FAKE_DROID=$! && disown
check "droid: a session resumed by command is running" \
  has "$(AGENT_SESSIONS_NOW=9200 "$BIN" list)" "running  droid   droid-renamed"
check "droid: a second restore leaves it alone" \
  hasnt "$(AGENT_SESSIONS_NOW=9200 "$BIN" restore -n)" "droid-renamed"
kill "$FAKE_DROID" 2>/dev/null
export AGENT_SESSIONS_STATE=$MAIN_STATE

# Install, into a throwaway HOME: the links, the hook command exactly as the
# Claude adapter spells it (a wrong path there records nothing, silently, in
# every session), agent-restore, and uninstall.
H="$T/home"; mkdir -p "$H/.claude" "$H/.factory"
guard='{"matcher": "Execute", "hooks": [{"type": "command", "command": "guard"}]}'
jq -n --argjson g "$guard" '{model: "m", hooks: {PreToolUse: [$g]}}' >"$H/.factory/settings.json"
HOME="$H" "$ROOT/install.sh" >/dev/null
HOME="$H" "$ROOT/install.sh" >/dev/null
check "install links agent-sessions" test "$(readlink "$H/.local/bin/agent-sessions")" = "$ROOT/agent-sessions"
check "install links agent-restore" test "$(readlink "$H/.local/bin/agent-restore")" = "$ROOT/agent-sessions"
check "install wires the Claude adapter" \
  test "$(readlink "$H/.claude/skills/agent-sessions")" = "$ROOT/adapters/claude"
hooks="$ROOT/adapters/claude/hooks/hooks.json"
hook=$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$hooks")
check "SessionStart and SessionEnd run the same command" \
  test "$hook" = "$(jq -r '.hooks.SessionEnd[0].hooks[0].command' "$hooks")"
jq -n --arg tp "$T/transcripts/cccccccc-0001.jsonl" --arg cwd "$T/repo" \
  '{session_id: "cccccccc-0001", transcript_path: $tp, cwd: $cwd,
    hook_event_name: "SessionStart", source: "startup", session_title: "hooked"}' |
  HOME="$H" AGENT_SESSIONS_NOW=9300 sh -c "$hook"
check "the Claude adapter's hook command records a session" recorded claude cccccccc-0001

settings="$H/.factory/settings.json"
dcmd=$(jq -r '.SessionStart[0].hooks[0].command' "$ROOT/adapters/droid/hooks.json")
check "install wires the Droid hooks into settings.json, once" \
  test "$(jq --arg c "$dcmd" '[.hooks[][] | select(.hooks[0].command == $c)] | length' "$settings")" = 3
check "every Droid hook runs the same command" \
  test "$(jq '[.[][].hooks[].command] | unique | length' "$ROOT/adapters/droid/hooks.json")" = 1
check "the hooks already there are kept" \
  test "$(jq -c '[.model, .hooks.PreToolUse]' "$settings")" = "$(jq -nc --argjson g "$guard" '["m", [$g]]')"
check "no hooks.json is created to shadow settings.json" test ! -e "$H/.factory/hooks.json"
jq -n --arg tp "$T/transcripts/cccccccc-0002.jsonl" --arg cwd "$T/repo" \
  '{session_id: "cccccccc-0002", transcript_path: $tp, cwd: $cwd,
    hook_event_name: "SessionStart", source: "startup"}' |
  HOME="$H" AGENT_SESSIONS_NOW=9300 sh -c "$(jq -r '.hooks.SessionStart[-1].hooks[0].command' "$settings")"
check "the Droid adapter's hook command records a session" \
  test -f "$AGENT_SESSIONS_STATE/droid-cccccccc-0002.json"
H4="$T/home4"; mkdir -p "$H4/.factory"; echo '{}' >"$H4/.factory/hooks.json"
jq -n --argjson g "$guard" '{hooks: {PreToolUse: [$g]}}' >"$H4/.factory/settings.json"
HOME="$H4" "$ROOT/install.sh" >/dev/null
check "a hooks.json, when there is one, is where Droid hooks go" \
  test "$(jq 'keys | length' "$H4/.factory/hooks.json")-$(jq '.hooks | keys | length' "$H4/.factory/settings.json")" = 3-1
plan=$(AGENT_SESSIONS_NOW=9400 "$H/.local/bin/agent-restore" -n)
check "agent-restore prints a plan" has "$plan" "session(s) in"
check "agent-restore is restore" test "$plan" = "$(AGENT_SESSIONS_NOW=9400 "$BIN" restore -n)"

# The Spotlight app (macOS). Its dialogs need a person, so this loads the
# compiled script and runs its restore command the way the app does: through
# `do shell script`, whose bare environment is what breaks apps, with the
# PATH and tool path install.sh baked in.
if [[ "$(uname -s)" == Darwin ]]; then
  app="$H/Applications/Agent Restore.app"
  check "install builds the Spotlight app" test -f "$app/Contents/Resources/Scripts/main.scpt"
  # shellcheck disable=SC2016  # $s is AppleScript, not shell
  app_plan=$(osascript \
    -e "set s to load script POSIX file \"$app/Contents/Resources/Scripts/main.scpt\"" \
    -e "do shell script \"AGENT_SESSIONS_STATE=$AGENT_SESSIONS_STATE AGENT_SESSIONS_NOW=9400 PATH=\" & quoted form of (searchPath of s) & \" \" & quoted form of (tool of s) & \" restore -n\"" \
    2>&1)
  check "the app's baked tool path is the installed link" \
    has "$(osadecompile "$app/Contents/Resources/Scripts/main.scpt")" "$H/.local/bin/agent-sessions"
  check "the app's restore command plans in an app's environment" \
    test "$(tr '\r' '\n' <<<"$app_plan")" = "$plan"
  inode=$(stat -f %i "$app/Contents/Resources/Scripts/main.scpt")
  HOME="$H" "$ROOT/install.sh" >/dev/null
  check "a re-run leaves a current app alone" \
    test "$(stat -f %i "$app/Contents/Resources/Scripts/main.scpt")" = "$inode"
  H3="$T/home3"; mkdir -p "$H3/Applications/Agent Restore.app"; touch "$H3/Applications/Agent Restore.app/theirs"
  check "install refuses to replace an app it did not build" eval '! HOME="$H3" "$ROOT/install.sh" >/dev/null'
  check "that app is left as it was" test -f "$H3/Applications/Agent Restore.app/theirs"
fi

# A real file where a link goes is never replaced, and the install says so.
H2="$T/home2"; mkdir -p "$H2/.local/bin"; echo keep >"$H2/.local/bin/agent-restore"
check "install refuses to replace a file" eval '! HOME="$H2" "$ROOT/install.sh" >/dev/null'
check "the file is left as it was" test "$(cat "$H2/.local/bin/agent-restore")" = keep

HOME="$H" "$ROOT/install.sh" --uninstall >/dev/null
check "uninstall removes every link" \
  test -z "$(find "$H/.local/bin" "$H/.claude/skills" -type l)"
check "uninstall removes the app it built" test ! -e "$H/Applications/Agent Restore.app"
check "uninstall removes the Droid hooks, and only them" \
  test "$(jq -c . "$settings")" = "$(jq -nc --argjson g "$guard" '{model: "m", hooks: {PreToolUse: [$g]}}')"

# Past the retention window: pruned on read. Last, since the clock jump
# prunes everything else too.
start 100 aaaaaaaa-0013 "ancient"; end 200 aaaaaaaa-0013 other
AGENT_SESSIONS_NOW=$((200 + 15 * 86400)) "$BIN" list >/dev/null
check "records older than 14 days are pruned" eval '! recorded claude aaaaaaaa-0013'

echo "  $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
