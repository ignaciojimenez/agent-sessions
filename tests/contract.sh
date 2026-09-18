#!/bin/bash
#
# Contract test for thefiles/.scripts/agent-sessions.
#
# Replays hook payloads shaped exactly like the ones Claude Code 2.1.27x sends
# (captured live — see docs/agent-sessions.md) into a throwaway state dir,
# with a fixed clock, then asserts on the records and on the restore plan.
# No terminal, no network, no real sessions; runs on macOS and Linux.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
BIN="${AGENT_SESSIONS_BIN:-$ROOT/thefiles/.scripts/agent-sessions}"
T="$(mktemp -d -t agent-sessions-test.XXXXXX)"
FAKE_PID=""
trap '[[ -n "$FAKE_PID" ]] && kill "$FAKE_PID" 2>/dev/null; rm -rf "$T"' EXIT

export AGENT_SESSIONS_STATE="$T/state" TERM_PROGRAM=test
PASS=0 FAIL=0
check() {  # <description> <command...>
  local desc=$1; shift
  if "$@"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "  ✗ $desc"; fi
}
has()    { grep -qF -- "$2" <<<"$1"; }
hasnt()  { ! grep -qF -- "$2" <<<"$1"; }
record() { [[ -f "$AGENT_SESSIONS_STATE/claude-$1.json" ]]; }

mkdir -p "$T/repo/sub" "$T/repo2" "$T/transcripts"
git -C "$T/repo" init -q && git -C "$T/repo2" init -q

# start <at> <id> <title> [cwd] [source]   end <at> <id> <reason>
start() {
  jq -n --arg id "$2" --arg title "$3" --arg cwd "${4:-$T/repo}" \
        --arg src "${5:-startup}" --arg tp "$T/transcripts/$2.jsonl" \
    '{session_id: $id, transcript_path: $tp, cwd: $cwd,
      scratchpad_dir: "/tmp/x", hook_event_name: "SessionStart",
      source: $src, model: "claude-opus-5"}
     + (if $title == "" then {} else {session_title: $title} end)' |
    AGENT_SESSIONS_NOW=$1 "$BIN" track claude
}
end() {
  jq -n --arg id "$2" --arg reason "$3" --arg cwd "$T/repo" \
        --arg tp "$T/transcripts/$2.jsonl" \
    '{session_id: $id, transcript_path: $tp, cwd: $cwd,
      scratchpad_dir: "/tmp/x", prompt_id: "p", hook_event_name: "SessionEnd",
      reason: $reason}' |
    AGENT_SESSIONS_NOW=$1 "$BIN" track claude
}
transcript() {  # <id> [title...] — one custom-title record per rename
  local id=$1 t; shift
  : >"$T/transcripts/$id.jsonl"
  for t in "$@"; do
    jq -nc --arg t "$t" --arg id "$id" '{type: "custom-title", customTitle: $t, sessionId: $id}' \
      >>"$T/transcripts/$id.jsonl"
  done
}

echo "agent-sessions contract"

# Closed on purpose: forgotten.
start 1000 aaaaaaaa-0001 "exited"; end 1010 aaaaaaaa-0001 prompt_input_exit
check "/exit forgets the session" eval '! record aaaaaaaa-0001'

# "other" (terminal closed, signal, reboot): kept as closed.
start 5000 aaaaaaaa-0002 "alpha"; end 9000 aaaaaaaa-0002 other
transcript aaaaaaaa-0002 "alpha" "alpha-renamed"
check "'other' keeps the session" record aaaaaaaa-0002
check "'other' records when it ended" \
  test "$(jq .ended_at "$AGENT_SESSIONS_STATE/claude-aaaaaaaa-0002.json")" = 9000

# /clear: the old id is forgotten, the new one inherits the title.
start 5000 aaaaaaaa-0003 "zeta"; end 6000 aaaaaaaa-0003 clear
start 6000 aaaaaaaa-0004 "zeta" "$T/repo" clear; end 9100 aaaaaaaa-0004 other
transcript aaaaaaaa-0004
check "/clear forgets the old id" eval '! record aaaaaaaa-0003'
check "/clear records the new id" record aaaaaaaa-0004

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

# Unnamed, and named but never used (no transcript).
start 5000 aaaaaaaa-0010 ""; end 9000 aaaaaaaa-0010 other; transcript aaaaaaaa-0010
start 5000 aaaaaaaa-0011 "theta"; end 9000 aaaaaaaa-0011 other

# No terminal (`claude --bg`): never recorded.
TERM_PROGRAM="" start 5000 aaaaaaaa-0012 "background"
check "a session without a terminal is not recorded" eval '! record aaaaaaaa-0012'

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
check "plan opens one tab per repo" has "$plan" "5 session(s) in 2 tab(s)."
check "plan leaves running sessions alone" hasnt "$plan" "epsilon"
check "plan leaves out sessions closed before the batch" hasnt "$plan" "      old"
check "plan reports unnamed sessions" has "$plan" "skipping unnamed session"
check "plan reports sessions with nothing to resume" has "$plan" "theta: nothing to resume"

# Past the retention window: pruned on read. Last, since the clock jump
# prunes everything else too.
start 100 aaaaaaaa-0013 "ancient"; end 200 aaaaaaaa-0013 other
AGENT_SESSIONS_NOW=$((200 + 15 * 86400)) "$BIN" list >/dev/null
check "records older than 14 days are pruned" eval '! record aaaaaaaa-0013'

echo "  $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
