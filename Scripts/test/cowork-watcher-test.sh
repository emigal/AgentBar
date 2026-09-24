#!/bin/bash
# Integration test for CoworkWatcher against the RUNNING AgentBar app: stages a
# synthetic Cowork session under the Claude desktop app's session store and
# asserts the state.d upserts walk thinking -> permission -> thinking ->
# question -> done. Further fixtures cover the Cowork-tab path: a
# remote-session-spaces.json entry plus a `[remote-bash] user=rcw-…` line in
# the desktop app's main.log (VM tool calls), the same remote-bash with no
# spaces card, and a reconnect-failure line in claude.ai-web.log that must
# NOT create a row (those errors used to mark dead tabs as thinking). The
# watcher lives inside the app process bound to the real HOME, so like the
# Antigravity test this cannot run in a throwaway HOME — it skips (exit 0)
# when the app isn't up.
#
# Claude.app must be running too: the watcher stamps its pid on every row so a
# quit of the desktop app clears the sessions through SessionStore's normal
# dead-pid prune, and it does nothing at all while the app is closed.
#
# The fixture goes under an account id of its own (`agentbar-test-*`), never the
# user's: the desktop app only ever reads the account/org path it is signed in
# to, so a session parked outside it can't surface in the Cowork UI.
set -uo pipefail

if [ "$(uname)" != "Darwin" ] || ! pgrep -xq AgentBar; then
  echo "skip: AgentBar app not running (this test needs the live watcher)"
  exit 0
fi
if ! pgrep -xq Claude; then
  echo "skip: Claude desktop not running (the watcher is idle without it)"
  exit 0
fi

pass=0; fail=0
check() {
  if eval "$2"; then echo "ok   $1"; pass=$((pass+1)); else echo "FAIL $1"; fail=$((fail+1)); fi
}

ROOT="$HOME/Library/Application Support/Claude/local-agent-mode-sessions/agentbar-test-$$/org"
ID="local_agbwtest$$"
DIR="$ROOT/$ID"
A="$DIR/audit.jsonl"
S="$HOME/.agentbar/state.d/$ID.json"
RID="session_01agbwtest$$"
RCW="rcw-01agbwtest$$"
RS="$HOME/.agentbar/state.d/$RID.json"
LOG="$HOME/Library/Logs/Claude/main.log"
WEB="$HOME/Library/Logs/Claude/claude.ai-web.log"
WID="cse_01agbwwebtest$$"
WSID="session_01agbwwebtest$$"
WS="$HOME/.agentbar/state.d/$WSID.json"
NID="session_01agbwnospc$$"
NCW="rcw-01agbwnospc$$"
NS="$HOME/.agentbar/state.d/$NID.json"
trap 'rm -rf "$HOME/Library/Application Support/Claude/local-agent-mode-sessions/agentbar-test-$$" "$S" "$RS" "$WS" "$NS"' EXIT
mkdir -p "$DIR"
printf '{"sessionId":"%s","title":"Watcher fixture","processName":"test-process"}\n' "$ID" > "$ROOT/$ID.json"

state() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get(sys.argv[2],""))' "$S" "$1" 2>/dev/null; }
rstate() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get(sys.argv[2],""))' "$RS" "$1" 2>/dev/null; }
wstate() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get(sys.argv[2],""))' "$WS" "$1" 2>/dev/null; }
nstate() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get(sys.argv[2],""))' "$NS" "$1" 2>/dev/null; }

# Bounded poll until the session state equals $1 (seconds in $2).
wait_state() {
  for _ in $(seq $(($2 * 2))); do
    [ "$(state state)" = "$1" ] && return 0
    sleep 0.5
  done
  return 1
}
wait_rstate() {
  for _ in $(seq $(($2 * 2))); do
    [ "$(rstate state)" = "$1" ] && return 0
    sleep 0.5
  done
  return 1
}
wait_nstate() {
  for _ in $(seq $(($2 * 2))); do
    [ "$(nstate state)" = "$1" ] && return 0
    sleep 0.5
  done
  return 1
}

echo "-- local mode (audit.jsonl)"

# 1. a live turn: audit events flowing, no `result` yet
echo '{"type":"assistant","uuid":"a1","session_id":"cli1"}' > "$A"
check "live audit -> thinking"        'wait_state thinking 8'
check "project is the session title"  '[ "$(state project)" = "Watcher fixture" ]'
check "entrypoint is claude-desktop"  '[ "$(state entrypoint)" = "claude-desktop" ]'
check "row is anchored to Claude.app" '[ "$(state pid)" = "$(pgrep -xn Claude)" ]'
check "no terminal is claimed"        '[ -z "$(state term_program)" ]'
check "local url targets the session" '[ "$(state url)" = "claude://claude.ai/local_sessions/'"$ID"'" ]'

# 2. an unanswered permission_request: the app is holding a prompt open
echo '{"type":"system","subtype":"permission_request","uuid":"p1","tool_name":"mcp__cowork__request_cowork_directory","tool_input":{"path":"~/Downloads"}}' >> "$A"
check "open request -> permission"    'wait_state permission 8'
check "label is the bare tool name"   '[ "$(state label)" = "request_cowork_directory" ]'

# 3. answered, and the turn continues
echo '{"type":"system","subtype":"permission_response","uuid":"p1","tool_name":"mcp__cowork__request_cowork_directory","decision":"once","granted":true}' >> "$A"
echo '{"type":"assistant","uuid":"a2","session_id":"cli1"}' >> "$A"
check "answered request -> thinking"  'wait_state thinking 8'

# 4. AskUserQuestion is Claude asking the human, not asking for permission
echo '{"type":"system","subtype":"permission_request","uuid":"q1","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which layout?"}]}}' >> "$A"
check "AskUserQuestion -> question"   'wait_state question 8'
check "label carries the question"    '[ "$(state label)" = "❓ Which layout?" ]'

# 5. a tool result carrying a base64 image is one line, megabytes long — longer
#    than the whole tail window. The session must stay visible (regression: a
#    fixed-size tail held no complete line, `inspect` bailed, the row vanished).
echo '{"type":"system","subtype":"permission_response","uuid":"q1","tool_name":"AskUserQuestion","decision":"once","granted":true}' >> "$A"
python3 -c 'import sys;sys.stdout.write("{\"type\":\"user\",\"uuid\":\"big\",\"message\":\""+"x"*2_000_000+"\"}\n")' >> "$A"
check "oversized line -> still live"  'wait_state thinking 8'

# 6. turn end
echo '{"type":"result","subtype":"success","uuid":"r1","is_error":false}' >> "$A"
check "result event -> done"          'wait_state done 8'

echo "-- cowork tab (remote-bash + remote-session-spaces.json)"

# 7. VM tool calls have no audit.jsonl on the host. The watcher matches a
#    remote-session-spaces.json card to a `[remote-bash] user=rcw-…` line.
#    Skip if the log isn't there (don't fail the local-mode walk over it).
if [ -f "$LOG" ]; then
  printf '{"entries":[{"sessionId":"%s","folders":["/tmp/agentbar-vm-fixture"]}]}\n' "$RID" > "$ROOT/remote-session-spaces.json"
  printf '%s [info] [remote-bash] user=%s mounts=fixture cmdLen=12\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$RCW" >> "$LOG"
  check "remote-bash -> thinking"           'wait_rstate thinking 8'
  check "project is the folder basename"    '[ "$(rstate project)" = "agentbar-vm-fixture" ]'
  check "remote entrypoint is claude-desktop" '[ "$(rstate entrypoint)" = "claude-desktop" ]'
  check "remote row is anchored to Claude"  '[ "$(rstate pid)" = "$(pgrep -xn Claude)" ]'
  check "cwd is the granted folder"         '[ "$(rstate cwd)" = "/tmp/agentbar-vm-fixture" ]'
  check "remote url is the cowork thread"   '[ "$(rstate url)" = "claude://claude.ai/cowork/cse_01agbwtest$$" ]'
else
  echo "skip: $LOG missing (remote-bash path not exercised)"
fi

echo "-- cowork tab (reconnect failure is not a live session)"

# 8. Opening a dead Cowork VM writes sign_for_session_header_failed / MCP 400s
#    with a cse_01* id. That is not liveness — scraping it used to mark the
#    row thinking and a click then asked Claude to reconnect the dead VM.
if [ -f "$WEB" ]; then
  printf '%s [warn] [LOCAL_SESSION] remote_cowork.sign_for_session_header_failed {"sessionId":"%s"}\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$WID" >> "$WEB"
  sleep 4
  check "failure log does not create a row" '[ ! -f "$WS" ]'
else
  echo "skip: $WEB missing (failure-path not exercised)"
fi

echo "-- cowork tab (remote-bash, no spaces card)"

# 9. Chat-only / no folder grant: a tool-call line is enough. No
#    remote-session-spaces.json, no web-log scrape.
if [ -f "$LOG" ]; then
  printf '%s [info] [remote-bash] user=%s mounts= cmdLen=12\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$NCW" >> "$LOG"
  check "no-spaces remote-bash -> thinking"     'wait_nstate thinking 8'
  check "no-spaces project is generic"          '[ "$(nstate project)" = "Cowork session" ]'
  check "no-spaces entrypoint is claude-desktop" '[ "$(nstate entrypoint)" = "claude-desktop" ]'
  check "no-spaces row is anchored to Claude"   '[ "$(nstate pid)" = "$(pgrep -xn Claude)" ]'
  check "no-spaces has no cwd"                  '[ -z "$(nstate cwd)" ]'
  check "no-spaces url is the cowork thread"    '[ "$(nstate url)" = "claude://claude.ai/cowork/cse_01agbwnospc$$" ]'
else
  echo "skip: $LOG missing (no-spaces remote-bash path not exercised)"
fi

echo "---"
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
