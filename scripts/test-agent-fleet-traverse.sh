#!/usr/bin/env bash
# scripts/test-agent-fleet-traverse.sh
#
# Hermetic test for agent-fleet-traverse.sh. Mirrors the jump harness shape:
# sandbox state dir, real model with sandboxed inputs (live-pane + ps
# overrides), synthetic stack/viewed files. AGENT_FLEET_MESSAGE_DELAY=0
# disables the production 1-second linger on user-visible shortcuts.
#
# Run via: bash scripts/test-agent-fleet-traverse.sh
# Self-contained: no real zellij session required.
# Deliberately does NOT use `set -e`: some scenarios intentionally drive the
# script into error paths and we want them surfaced as FAIL entries rather
# than script aborts. pipefail + nounset stay on for typo safety.
#
# Acceptance scenarios come straight from the design doc (Traverse stack
# semantics > Acceptance traces).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TRAVERSE="$REPO_ROOT/scripts/agent-fleet-traverse.sh"

if [ ! -f "$TRAVERSE" ]; then
  echo "FAIL: traverse.sh missing at $TRAVERSE"
  exit 1
fi

if (( BASH_VERSINFO[0] < 4 )); then
  echo "FAIL: test-agent-fleet-traverse.sh needs bash >= 4 (got $BASH_VERSION)"
  exit 1
fi

# Sandbox torn down by EXIT trap; each test gets a fresh subdir.
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

PASS=0
FAIL=0
LOG=""

pass() { PASS=$((PASS + 1)); LOG+="PASS: $1"$'\n'; }
fail() {
  FAIL=$((FAIL + 1))
  LOG+="FAIL: $1"$'\n'
  shift
  [ "${1:-}" != "" ] && { LOG+="  $*$"$'\n'; shift; while [ "${1:-}" != "" ]; do LOG+="  $1"$'\n'; shift; done; }
}
assert_eq() {
  local label="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then pass "$label"; else fail "$label" "want=$want" "got=$got"; fi
}
assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then pass "$label"
  else fail "$label" "haystack=$haystack" "expected_substring=$needle"; fi
}
assert_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then pass "$label"
  else fail "$label" "haystack_unexpectedly_contained=$needle"; fi
}
assert_file_exists() {
  local label="$1" path="$2"
  if [ -f "$path" ]; then pass "$label"
  else fail "$label" "missing=$path"; fi
}
assert_file_absent() {
  local label="$1" path="$2"
  if [ ! -e "$path" ]; then pass "$label"
  else fail "$label" "unexpected_file=$path"; fi
}
assert_stack_eq() {
  local label="$1" want="$2" path="$3"
  if [ ! -f "$path" ]; then fail "$label" "missing=$path"; return; fi
  local got want_norm
  got="$(jq -S . "$path")"
  want_norm="$(jq -S . <<<"$want" 2>/dev/null || echo "BAD_WANT")"
  if [ "$want_norm" = "$got" ]; then pass "$label"
  else fail "$label" "want=$want_norm" "got=$got"; fi
}

# === drive a single traverse invocation ===
# $1 mode: "decide-only" | "decide-act" | "act"  (decide-only = no side effects;
#         decide-act = stack+mailbox but no aerospace/zellij; act = same as
#         decide-act in this harness — focus path is outside hermetic coverage)
# $2 sandbox STATE_DIR
# $3 ps override path ("" = no override)
# $4 live pane table text (TAB-separated cwd<TAB>session<TAB>terminal_<id><TAB>tab_id)
# $5 subcommand to traverse.sh ("prev" | "next")
# $6 AGENT_FLEET_NOW_MS pin ("" = real clock)
# $7 pre-existing stack JSON to write at $sandbox/traverse-stack.json ("" = no pre-stack)
# Sets: TRAV_STDOUT, TRAV_STDERR, TRAV_RC
run_trav() {
  local mode="$1" sandbox="$2" pso="$3" live="$4" cmd="$5" now_ms="$6"
  local pre_stack="${7:-}"
  local source_session="${8:-}"
  local pane_file="$ROOT/pane-${RANDOM}.tsv"
  printf '%s\n' "$live" > "$pane_file"
  # If pre_stack explicitly passed (non-empty), write it. Otherwise, leave the
  # sandbox's stack file alone — subsequent presses in a multi-press scenario
  # inherit the prior press's stack mutation. Pass `-` as 7th arg to clear.
  case "$pre_stack" in
    "-") rm -f "$sandbox/traverse-stack.json" ;;
    "")  : ;;
    *)   printf '%s\n' "$pre_stack" > "$sandbox/traverse-stack.json" ;;
  esac
  local env_args=(
    "AGENT_FLEET_LIVE_PANES_OVERRIDE=$pane_file"
    "AGENT_FLEET_STATE_DIR=$sandbox"
    "AGENT_FLEET_MESSAGE_DELAY=0"
    "ZELLIJ_SESSION_NAME=$source_session"
  )
  [ -n "$pso" ] && env_args+=( "AGENT_FLEET_PS_OVERRIDE=$pso" )
  [ -n "$now_ms" ] && env_args+=( "AGENT_FLEET_NOW_MS=$now_ms" )
  case "$mode" in
    decide-only) env_args+=( "AGENT_FLEET_DECIDE_ONLY=1" ) ;;
    decide-act)  env_args+=( "AGENT_FLEET_DECIDE_ACT=1" ) ;;
    act)         : ;;
  esac
  local tmp_err="$ROOT/err-${RANDOM}.txt"
  TRAV_RC=0
  TRAV_STDOUT="$(env "${env_args[@]}" bash "$TRAVERSE" "$cmd" 2>"$tmp_err")" || TRAV_RC=$?
  TRAV_STDERR="$(cat "$tmp_err")"
}

# === When invoked from a zellij session with no opencode pane, next first
# returns to the traversal current instead of skipping ahead to pending. ===
test_next_from_non_agent_session_lands_current() {
  local sandbox="$ROOT/non-agent-next"
  mkdir -p "$sandbox"
  local key; key=$(key_for "/non-agent-next")
  local pid=15001
  local pso="$ROOT/ps_non_agent_next.tsv"
  printf 'OPENCODE\t%s\n' "$pid" > "$pso"
  write_v2 "$sandbox" "$key" "$pid" "/non-agent-next" "agent" "current" 2000000000000 \
    "current" "done"            100 null \
    "next"    "needs-attention" 200 null
  local now_ms=2000000000500
  local pre_stack='{"v":1,"current":{"sid":"current","ts":1990000000000},"back":[],"forward":[]}'
  run_trav "decide-only" "$sandbox" "$pso" \
    $'/non-agent-next\tagent\tterminal_2\t0' "next" "$now_ms" "$pre_stack" "notes"
  assert_eq "non-agent next: lands traversal current" \
    "DECISION:kind=select cwd=/non-agent-next session=agent pane=terminal_2 tab_id=0 key=${key}-${pid} sid=current" \
    "$TRAV_STDOUT"
}

# === fixtures: shared read helpers for compact fixture construction ===
key_for() { printf '%s' "$1" | shasum -a 256 | cut -c1-16; }

# write_viewed: merge viewed.json marks per (key, pid) pair so suppressions
# pre-apply at model time.
write_viewed() {
  local sandbox="$1" key="$2" pid="$3"; shift 3
  local body="{"
  local first=1
  while [ $# -gt 0 ]; do
    [ "$first" = "1" ] && first=0 || body+=","
    body+="\"$1\":$2"
    shift 2
  done
  body+="}"
  printf '%s\n' "$body" > "$sandbox/${key}-${pid}.viewed.json"
}

# write_v2: emit a v2 state file (sandboxed). Built with jq -n --arg / --argjson so
# sids containing "/" or "\" or """ round-trip safely through JSON quoting (heredoc
# string-interpolation cannot represent those characters without breaking the JSON).
# Args: sandbox key pid cwd session selectedSid|"null" selectedTs|"null"  then
# pairs of (sid state ts reason|"null").
write_v2() {
  local sandbox="$1" key="$2" pid="$3" cwd="$4" session="$5"
  local selectedSid="$6" selectedTs="$7"; shift 7
  local repo="$cwd"; repo="${repo##*/}"
  # Build sessions map via a single jq -n invocation. Each row is JSON-encoded
  # before being concatenated into the pairs array — state and reason strings are
  # passed through jq so any punctuation (including backslash and double quote) is
  # JSON-quoted automatically.
  local pairs="[" first=1
  while [ $# -ge 4 ]; do
    local sid="$1" state="$2" ts="$3" reason="$4"; shift 4
    [ "$first" = "1" ] && first=0 || pairs+=","
    local entry_json
    entry_json="$(jq -n \
        --arg sid "$sid" \
        --arg state "$state" \
        --argjson ts "$ts" \
        --argjson reason "$(jq -n --arg r "$reason" 'if $r == "null" then null else $r end')" \
        '{sid:$sid,state:$state,ts:$ts,reason:$reason,title:($sid + "_t"),task:null}')"
    pairs+="$entry_json"
  done
  pairs+="]"
  if [ "$selectedSid" = "null" ]; then
    jq -n --arg cwd "$cwd" --arg session "$session" --argjson pid "$pid" \
          --arg repo "$repo" --argjson sessions "$pairs" \
          '{repo:$repo,cwd:$cwd,session:$session,pid:$pid,selectedSid:null,selectedTs:null,sessions:([$sessions[] | . as $e | {($e.sid): ($e | del(.sid, .title, .task))}] | add // {})}' \
      > "$sandbox/${key}-${pid}.json"
  else
    jq -n --arg cwd "$cwd" --arg session "$session" --argjson pid "$pid" \
          --arg repo "$repo" --arg selectedSid "$selectedSid" --argjson selectedTs "$selectedTs" \
          --argjson sessions "$pairs" \
          '{repo:$repo,cwd:$cwd,session:$session,pid:$pid,selectedSid:$selectedSid,selectedTs:$selectedTs,sessions:([$sessions[] | . as $e | {($e.sid): ($e | del(.sid, .title, .task))}] | add // {})}' \
      > "$sandbox/${key}-${pid}.json"
  fi
}

# === DESIGN ACCEPTANCE: Scenario 1 ===
# Pre-state: current=C (old ts), back=[some_prior_marker], forward=[]
# v2 file records P=Z (very fresh ts) ⇒ reconcile flips before alt-] processes.
# pending=[A, A0] (A FIFO oldest). Three presses → A → Z → A.
test_scenario_1_acceptance_next_prev_next() {
  local sandbox="$ROOT/scn1"
  mkdir -p "$sandbox"
  local key; key=$(key_for "/scn1")
  local pid=11001
  local pso="$ROOT/ps_scn1.tsv"
  printf 'OPENCODE\t%s\n' "$pid" > "$pso"
  # P=Z (sid Z, ts fresh); session timestamps driven by ts asc so A is FIFO oldest
  # in pending. old_marker uses state="working" so stateRank() returns null and
  # the model drops it from actionable/pending (it stays in instance.sessions
  # only for landscape completeness; if a back-press tried to land it, classify
  # would skip it as ambiguous-unlandable since no row matches it).
  write_v2 "$sandbox" "$key" "$pid" "/scn1" "sxS" "Z" 2000000000000 \
    "Z"          "done"            500 null \
    "A"          "needs-attention"  10 null \
    "A0"         "done"            900 null \
    "old_marker" "working"           1 null
  # pre-stack: current=C with timestamp OLD (well outside 2s window vs now_ms),
  # P.ts (2000000000000) > current.ts ⇒ straight flip, no stale guard.
  local now_ms=2000000000500
  local pre_stack='{"v":1,"current":{"sid":"C","ts":1800000000000},"back":["old_marker"],"forward":[]}'
  # alt-] #1: land A
  run_trav "decide-act" "$sandbox" "$pso" \
    $'/scn1\tsxS\tterminal_2\t0' "next" "$now_ms" "$pre_stack"
  assert_eq "scenario1 next#1: select A landed" \
    "DECISION:kind=select cwd=/scn1 session=sxS pane=terminal_2 tab_id=0 key=${key}-${pid} sid=A" \
    "$TRAV_STDOUT"
  assert_file_exists "scenario1 next#1: .select written" "$sandbox/${key}-${pid}.select"
  assert_stack_eq "scenario1 next#1: reconciled+new-nav stack" \
    "{\"v\":1,\"current\":{\"sid\":\"A\",\"ts\":${now_ms}},\"back\":[\"old_marker\",\"C\",\"Z\"],\"forward\":[]}" \
    "$sandbox/traverse-stack.json"
  # alt-[ #2: back-pop Z
  run_trav "decide-act" "$sandbox" "$pso" \
    $'/scn1\tsxS\tterminal_2\t0' "prev" "$now_ms"
  assert_eq "scenario1 prev#2: select Z landed" \
    "DECISION:kind=select cwd=/scn1 session=sxS pane=terminal_2 tab_id=0 key=${key}-${pid} sid=Z" \
    "$TRAV_STDOUT"
  assert_stack_eq "scenario1 prev#2: back-pop Z, forward=[A]" \
    "{\"v\":1,\"current\":{\"sid\":\"Z\",\"ts\":${now_ms}},\"back\":[\"old_marker\",\"C\"],\"forward\":[\"A\"]}" \
    "$sandbox/traverse-stack.json"
  # alt-] #3: forward-pop A
  run_trav "decide-act" "$sandbox" "$pso" \
    $'/scn1\tsxS\tterminal_2\t0' "next" "$now_ms"
  assert_eq "scenario1 next#3: select A re-landed (forward-pop)" \
    "DECISION:kind=select cwd=/scn1 session=sxS pane=terminal_2 tab_id=0 key=${key}-${pid} sid=A" \
    "$TRAV_STDOUT"
  assert_stack_eq "scenario1 next#3: forward-pop A, back=[..,C,Z]" \
    "{\"v\":1,\"current\":{\"sid\":\"A\",\"ts\":${now_ms}},\"back\":[\"old_marker\",\"C\",\"Z\"],\"forward\":[]}" \
    "$sandbox/traverse-stack.json"
}

# === DESIGN ACCEPTANCE: Scenario 2 ===
# Simulates the design's "nav Z · alt-y · alt-[ · alt-] · alt-]" sequence by
# starting FROM the post-alt-y stack state (the only part that the alt-y
# step produces). Three subsequent traverse.sh presses then play back the
# alt-[ / alt-] / alt-] phase:
#   press 1 alt-[ : back-pop Z, forward=[A0]
#   press 2 alt-] : forward-pop A0, back=[..,C,Z]
#   press 3 alt-] : forward empty → pending[0]=A (A0 viewed)
test_scenario_2_acceptance_prev_next_next() {
  local sandbox="$ROOT/scn2"
  mkdir -p "$sandbox"
  local key; key=$(key_for "/scn2")
  local pid=12001
  local pso="$ROOT/ps_scn2.tsv"
  printf 'OPENCODE\t%s\n' "$pid" > "$pso"
  write_v2 "$sandbox" "$key" "$pid" "/scn2" "sxS" "Z" 2000000000000 \
    "Z"          "done"            500 null \
    "A"          "needs-attention"  10 null \
    "A0"         "needs-attention" 900  null \
    "old_marker" "working"           1 null
  # mark A0 viewed (high viewedTs) so it's suppressed → not in pending. Without
  # this mark, A0 would be a higher-priority pending[0] than A (rank=1 wins over
  # FIFO oldest) and the third alt-] would land A0, not A as the design specifies.
  write_viewed "$sandbox" "$key" "$pid" "A0" 950
  # Post-alt-y state: current=A0 (top-ranked), back=[old_marker,C,Z], forward=[].
  # P was Z — but here we time-travel: current.ts > P.ts (so stale-P guard
  # suppresses passive-departure flip on the three subsequent presses) AND
  # (now_ms - current.ts) < 2000ms.
  local now_ms=2000000001000
  local pre_stack='{"v":1,"current":{"sid":"A0","ts":2000000000500},"back":["old_marker","C","Z"],"forward":[]}'
  # alt-: back-pop Z. current=Z, back=[old_marker,C], forward=[A0].
  run_trav "decide-act" "$sandbox" "$pso" \
    $'/scn2\tsxS\tterminal_3\t1' "prev" "$now_ms" "$pre_stack"
  assert_eq "scenario2 prev#1: back-pop Z landed" \
    "DECISION:kind=select cwd=/scn2 session=sxS pane=terminal_3 tab_id=1 key=${key}-${pid} sid=Z" \
    "$TRAV_STDOUT"
  assert_stack_eq "scenario2 prev#1: Z popped from back, A0 pushed to forward" \
    "{\"v\":1,\"current\":{\"sid\":\"Z\",\"ts\":${now_ms}},\"back\":[\"old_marker\",\"C\"],\"forward\":[\"A0\"]}" \
    "$sandbox/traverse-stack.json"

  # alt-] #2: forward-pop A0. current=A0, back=[old_marker,C,Z], forward=[].
  run_trav "decide-act" "$sandbox" "$pso" \
    $'/scn2\tsxS\tterminal_3\t1' "next" "$now_ms"
  assert_eq "scenario2 next#2: forward-pop A0 re-landed" \
    "DECISION:kind=select cwd=/scn2 session=sxS pane=terminal_3 tab_id=1 key=${key}-${pid} sid=A0" \
    "$TRAV_STDOUT"
  assert_stack_eq "scenario2 next#2: A0 popped forward, Z (back_push_mru) appended" \
    "{\"v\":1,\"current\":{\"sid\":\"A0\",\"ts\":${now_ms}},\"back\":[\"old_marker\",\"C\",\"Z\"],\"forward\":[]}" \
    "$sandbox/traverse-stack.json"

  # alt-] #3: forward empty → pending[0]. A0 viewed (write_viewed), A is FIFO oldest.
  run_trav "decide-act" "$sandbox" "$pso" \
    $'/scn2\tsxS\tterminal_3\t1' "next" "$now_ms"
  assert_eq "scenario2 next#3: pending[0]=A wins (A0 viewed ⇒ pending-wins excludes A0)" \
    "DECISION:kind=select cwd=/scn2 session=sxS pane=terminal_3 tab_id=1 key=${key}-${pid} sid=A" \
    "$TRAV_STDOUT"
  assert_stack_eq "scenario2 next#3: new-nav forward cleared, A0 (back_push_mru) appended" \
    "{\"v\":1,\"current\":{\"sid\":\"A\",\"ts\":${now_ms}},\"back\":[\"old_marker\",\"C\",\"Z\",\"A0\"],\"forward\":[]}" \
    "$sandbox/traverse-stack.json"
}

# === prev pops MRU order; next pops LIFO ===
# Two prior history entries (back=[B0,B1]) — that's MRU order: B0 oldest, B1
# most recent. Two prev-pops return B1 then B0. forward mirror.
test_back_pops_mru_forward_pops_lifo() {
  local sandbox="$ROOT/mru"
  mkdir -p "$sandbox"
  local key; key=$(key_for "/mru")
  local pid=13001
  local pso="$ROOT/ps_mru.tsv"
  printf 'OPENCODE\t%s\n' "$pid" > "$pso"
  write_v2 "$sandbox" "$key" "$pid" "/mru" "sxS" "B1" 2000000000000 \
    "B0" "done" 100 null \
    "B1" "done" 200 null
  local now_ms=2000000000500
  # current=B1 (matches P), back=[B0,cur_target_old]. forward empty. (We want
  # current=B1 and back contains B0. After alt-[ we'd pop last-of-back, here B0.)
  local pre_stack='{"v":1,"current":{"sid":"B1","ts":1990000000000},"back":["B0"],"forward":[]}'
  run_trav "decide-act" "$sandbox" "$pso" \
    $'/mru\tsxS\tterminal_0\t0' "prev" "$now_ms" "$pre_stack"
  assert_eq "mru-prev: low stack-entry selection (B0)" \
    "DECISION:kind=select cwd=/mru session=sxS pane=terminal_0 tab_id=0 key=${key}-${pid} sid=B0" \
    "$TRAV_STDOUT"
  assert_stack_eq "mru-prev: back=[], forward=[B1]" \
    "{\"v\":1,\"current\":{\"sid\":\"B0\",\"ts\":${now_ms}},\"back\":[],\"forward\":[\"B1\"]}" \
    "$sandbox/traverse-stack.json"
  # now current=B0, forward=[B1]. alt-] pops forward[last] = B1 (LIFO).
  run_trav "decide-act" "$sandbox" "$pso" \
    $'/mru\tsxS\tterminal_0\t0' "next" "$now_ms"
  assert_eq "mru-next: forward-pop highest (B1)" \
    "DECISION:kind=select cwd=/mru session=sxS pane=terminal_0 tab_id=0 key=${key}-${pid} sid=B1" \
    "$TRAV_STDOUT"
  assert_stack_eq "mru-next: back=[B0], forward=[] (B1 popped LIFO)" \
    "{\"v\":1,\"current\":{\"sid\":\"B1\",\"ts\":${now_ms}},\"back\":[\"B0\"],\"forward\":[]}" \
    "$sandbox/traverse-stack.json"
}

# === recency uniqueness: target lands and is removed from current/back/forward ===
# Pre: target T is BOTH current AND on back — back-pop lands T, dedup removes
# all T copies.
test_recency_uniqueness_no_double_insertion() {
  local sandbox="$ROOT/uniq"
  mkdir -p "$sandbox"
  local key; key=$(key_for "/uniq")
  local pid=14001
  local pso="$ROOT/ps_uniq.tsv"
  printf 'OPENCODE\t%s\n' "$pid" > "$pso"
  write_v2 "$sandbox" "$key" "$pid" "/uniq" "sxS" "T" 2000000000000 \
    "T" "done" 100 null
  local now_ms=2000000000500
  # current=T (matches P); back contains T twice already. After prev pop,
  # T is removed everywhere and becomes the new current.
  local pre_stack='{"v":1,"current":{"sid":"T","ts":1990000000000},"back":["T","other_marker","T"],"forward":["T"]}'
  run_trav "decide-act" "$sandbox" "$pso" \
    $'/uniq\tsxS\tterminal_0\t0' "prev" "$now_ms" "$pre_stack"
  assert_eq "uniq-prev: lands T (it's on back even though current==T; reconcile no-op)" \
    "DECISION:kind=select cwd=/uniq session=sxS pane=terminal_0 tab_id=0 key=${key}-${pid} sid=T" \
    "$TRAV_STDOUT"
  # After back-pop: current=T, all T copies removed from back/forward.
  # back_push_mru(old current=T) is a no-op since T == old.
  assert_stack_eq "uniq-prev: T removed from back and forward entirely (recency uniqueness)" \
    "{\"v\":1,\"current\":{\"sid\":\"T\",\"ts\":${now_ms}},\"back\":[\"other_marker\"],\"forward\":[]}" \
    "$sandbox/traverse-stack.json"
}

# === Back exhaustion scans viewed from current position toward older tail ===
# Setup: empty back[]; current=V (in viewed); viewed=[V (head, newest), X (target, middle), Y (oldest)].
# Expect: prev picks X (next-older from V at the head).
test_back_exhaustion_scans_viewed_positionally() {
  local sandbox="$ROOT/viewpos"
  mkdir -p "$sandbox"
  local key; key=$(key_for "/viewpos")
  local pid=15001
  local pso="$ROOT/ps_viewpos.tsv"
  printf 'OPENCODE\t%s\n' "$pid" > "$pso"
  write_v2 "$sandbox" "$key" "$pid" "/viewpos" "sxS" "V" 2000000000000 \
    "V" "done"          100 null \
    "X" "needs-attention" 500 null \
    "Y" "needs-attention" 700 null
  # viewed marked: V newest (head, index 0); X middle, suppressed (viewedTs ≥ entryTs);
  # Y oldest in viewed list (NOT actionable to avoid pending-wins dropping it).
  # To keep Y UTTERLY absent from pending, use state="working" (rank=null).
  write_v2 "$sandbox" "$key" "$pid" "/viewpos" "sxS" "V" 2000000000000 \
    "V" "done"          100 null \
    "X" "needs-attention" 500 null \
    "Y" "working"          1   null
  # viewed marked so that sorted viewedTs-DESC places V at index 0 (newest),
# X at index 1 (suppressed to drop from pending), Y at index 2 (also suppressed).
# X viewedTs (500) ≥ X entryTs (500) ⇒ suppressed ⇒ pending-wins drops from pending;
# Y viewedTs (300) ≥ Y entryTs (1) ⇒ suppressed.
# Walk from V's index 0 toward older (higher index) ⇒ first landable = X at idx 1.
write_viewed "$sandbox" "$key" "$pid" "V" 700 "X" 500 "Y" 300
  local now_ms=2000000000500
  local pre_stack='{"v":1,"current":{"sid":"V","ts":1990000000000},"back":[],"forward":[]}'
  run_trav "decide-act" "$sandbox" "$pso" \
    $'/viewpos\tsxS\tterminal_0\t0' "prev" "$now_ms" "$pre_stack"
  assert_eq "viewpos-prev: lands X (next-older than current V)" \
    "DECISION:kind=select cwd=/viewpos session=sxS pane=terminal_0 tab_id=0 key=${key}-${pid} sid=X" \
    "$TRAV_STDOUT"
  assert_stack_eq "viewpos-prev: forward=[V], current=X (NOT new navigation: forward preserved)" \
    "{\"v\":1,\"current\":{\"sid\":\"X\",\"ts\":${now_ms}},\"back\":[],\"forward\":[\"V\"]}" \
    "$sandbox/traverse-stack.json"
}

# === Absent current starts scan at head of viewed ===
# Setup: current=K (NOT in viewed); viewed=[A0, X (target), B]. X is older than
# A0 by position but newer than B. prev should land X.
test_back_exhaustion_absent_current_starts_head() {
  local sandbox="$ROOT/viewabs"
  mkdir -p "$sandbox"
  local key; key=$(key_for "/viewabs")
  local pid=16001
  local pso="$ROOT/ps_viewabs.tsv"
  printf 'OPENCODE\t%s\n' "$pid" > "$pso"
  # K lives in sessions but IS NOT in viewed (no viewed mark → it's actionable
  # and in pending). selectedSid=Z ⇒ P=Z matches pre_stack current=Z ⇒
  # reconcile is a no-op. viewed sorted desc = [A0(idx 0 /head), X(1), B(2)].
  write_v2 "$sandbox" "$key" "$pid" "/viewabs" "sxS" "Z" 2000000000000 \
    "Z" "done"          100 null \
    "K" "done"          150 null \
    "A0" "needs-attention" 500 null \
    "X"  "needs-attention" 700 null \
    "B"  "needs-attention" 900 null
  write_viewed "$sandbox" "$key" "$pid" "A0" 900 "X" 700 "B" 500
  local now_ms=2000000000500
  local pre_stack='{"v":1,"current":{"sid":"Z","ts":1990000000000},"back":[],"forward":[]}'
  run_trav "decide-act" "$sandbox" "$pso" \
    $'/viewabs\tsxS\tterminal_0\t0' "prev" "$now_ms" "$pre_stack"
  assert_eq "viewabs-prev: lands A0 (head of viewed, current Z absent ⇒ start at head)" \
    "DECISION:kind=select cwd=/viewabs session=sxS pane=terminal_0 tab_id=0 key=${key}-${pid} sid=A0" \
    "$TRAV_STDOUT"
}

# === Pending guard: forward→pending[0] skips sid == current.sid ===
# Setup: only one pending sid, which == current. Forward empty ⇒ dry ⇒
# `traverse: at end` exit 0.
test_pending_guard_skips_equal_to_current() {
  local sandbox="$ROOT/pguard"
  mkdir -p "$sandbox"
  local key; key=$(key_for "/pguard")
  local pid=17001
  local pso="$ROOT/ps_pguard.tsv"
  printf 'OPENCODE\t%s\n' "$pid" > "$pso"
  # Make Z suppressed so it's only in viewed[] (its current-removal role); the
  # ONLY actionable+pending sid becomes onlyA. The current=sid-equals-pending[0]
  # guard then trips: pending[0] == current.sid, filtered out, pending empty, at-end.
  # selectedSid=onlyA so reconcile is a no-op (P matches current).
  write_v2 "$sandbox" "$key" "$pid" "/pguard" "sxS" "onlyA" 2000000000000 \
    "Z"      "done"          100 null \
    "onlyA"  "needs-attention" 500 null
  write_viewed "$sandbox" "$key" "$pid" "Z" 200
  local now_ms=2000000000500
  local pre_stack='{"v":1,"current":{"sid":"onlyA","ts":1990000000000},"back":[],"forward":[]}'
  run_trav "decide-act" "$sandbox" "$pso" \
    $'/pguard\tsxS\tterminal_0\t0' "next" "$now_ms" "$pre_stack"
  assert_eq "pguard-next: at-end decision (forward empty, pending[0]==current)" \
    "DECISION:kind=at-end" "$TRAV_STDOUT"
  assert_eq "pguard-next: at-end exits 0" "0" "$TRAV_RC"
  assert_file_absent "pguard-next: NO .select written" "$sandbox/${key}-${pid}.select"
}

# === Dead popped entries are pruned; at-end press persists prune ===
# Setup: current=Y (matches P — reconcile is a no-op); back=[X_dead (dead), Y_target].
# alt- walks back from end, sees X_dead (idle/sentinel: keep walking because X_dead
# is BEFORE the target) — actually dead entries BEFORE the target stay on
# back[]; the design's pristine stop-on-first-landable means pre_target =
# back[0:k] (everything before Y) and we don't sweep X_dead out here. That's OK
# because the test asserts back=[X_dead] after — but only because the entry BEFORE
# Y truly IS pruned under design §Alt-[ : "Dead entry → skip, pop next; the
# pop loop walks the whole tail". Closest faithful interpretation: we POP LAST,
# drop dead, retain unlandable — when Y is at end, X_dead (earlier) is unwalked.
# To assert the prune path: set pre_stack back=[Y, X_dead] so X_dead is BEYOND
# the target — popped past during the walk, dead-pruned. ===
test_dead_entries_pruned_AND_at_end_persists() {
  local sandbox="$ROOT/dead_a"
  mkdir -p "$sandbox"
  local key; key=$(key_for "/dead_a")
  local pid=18001
  local pso="$ROOT/ps_dead_a.tsv"
  printf 'OPENCODE\t%s\n' "$pid" > "$pso"
  # selectedSid=Y so reconcile is a no-op (P matches current=Y).
  write_v2 "$sandbox" "$key" "$pid" "/dead_a" "sxS" "Y" 2000000000000 \
    "Y" "done" 100 null
  local now_ms=2000000000500
  # back=[Y_target (last/MRU), X_dead (older)]. alt- walks from end:
  # X_dead at i=1 is dead → pruned; Y at i=0 landable → target. pre_target
  # = back[0:last_index_of_Y] = back[0:0] = []. Net back=[].
  local pre_stack='{"v":1,"current":{"sid":"Y","ts":1990000000000},"back":["Y","X_dead"],"forward":[]}'
  run_trav "decide-act" "$sandbox" "$pso" \
    $'/dead_a\tsxS\tterminal_0\t0' "prev" "$now_ms" "$pre_stack"
  assert_eq "deadA-prev: lands Y (X_dead pruned first)" \
    "DECISION:kind=select cwd=/dead_a session=sxS pane=terminal_0 tab_id=0 key=${key}-${pid} sid=Y" \
    "$TRAV_STDOUT"
  # current was Y (pre-reconcile matches P). After back-pop, current is still Y;
  # forward.push(current_old) = forward.push(Y), but current-removal invariant
  # filters out the duplicate ⇒ forward stays empty.
  assert_stack_eq "deadA-prev: X_dead pruned, Y stays current, forward empty (current-removal invariance when target == current)" \
    "{\"v\":1,\"current\":{\"sid\":\"Y\",\"ts\":${now_ms}},\"back\":[],\"forward\":[]}" \
    "$sandbox/traverse-stack.json"

  # at-end press: all dead
  # To avoid reconcile flipping current to Z, set pre_stack current=Z and
  # set P=Z (selectedSid=Z) so the noop reconcile path applies.
  local sandbox2="$ROOT/dead_b"
  mkdir -p "$sandbox2"
  write_v2 "$sandbox2" "$key" "$pid" "/dead_b" "sxS" "Z" 2000000000000 \
    "Z" "done" 100 null
  local pre_stack2='{"v":1,"current":{"sid":"Z","ts":1990000000000},"back":["X_dead1","X_dead2"],"forward":[]}'
  run_trav "decide-act" "$sandbox2" "$pso" \
    $'/dead_b\tsxS\tterminal_0\t0' "prev" "$now_ms" "$pre_stack2"
  assert_eq "deadB-prev: at-end (no landable)" \
    "DECISION:kind=at-end" "$TRAV_STDOUT"
  assert_eq "deadB-prev: at-end exits 0" "0" "$TRAV_RC"
  assert_stack_eq "deadB-prev: dead entries pruned + persist (no landing mutation beyond the dead-sweep)" \
    '{"v":1,"current":{"sid":"Z","ts":1990000000000},"back":[],"forward":[]}' \
    "$sandbox2/traverse-stack.json"
}

# === Ambiguous entries are skipped but retained ===
# Setup: cwd /amb. Two v2 files (ambiguous via pane-table OR file-count arm).
# Both instances share cwd /amb ⇒ ambiguous. Their sids X and Y are in
# instances[].sessions but rows[] collapses to one warning row (no per-sid row).
# Put a third live instance cwd=/solo with sid=S_target, also on back.
# Fixture: alt-[ with back=[S_target, X_amb, Y_amb] (amb-on-top so they're
# try-popped first). Expected: skip past X and Y (RETAINED), pop S_target.
test_ambiguous_entries_skipped_but_retained() {
  local sandbox="$ROOT/amb"
  mkdir -p "$sandbox"
  local key; key=$(key_for "/amb")
  local pidS=19001  # solo target
  local pidX=19002  # ambiguous pid X
  local pidY=19003  # ambiguous pid Y
  local pso="$ROOT/ps_amb.tsv"
  printf 'OPENCODE\t%s\n' "$pidS" > "$pso"
  printf 'OPENCODE\t%s\n' "$pidX" >> "$pso"
  printf 'OPENCODE\t%s\n' "$pidY" >> "$pso"
  # /amb: two v2 files for ambiguous; sids X and Y live in instances.
  write_v2 "$sandbox" "$key" "$pidX" "/amb" "sxX" "null" "null" \
    "X" "needs-attention" 100 null
  write_v2 "$sandbox" "$key" "$pidY" "/amb" "sxY" "null" "null" \
    "Y" "needs-attention" 200 null
  # /solo: only one v2 file, with sid S_target.
  write_v2 "$sandbox" "$key" "$pidS" "/solo" "sxS" "S" 2000000000000 \
    "S" "needs-attention" 500 null
  local now_ms=2000000000500
  # Move ambiguous-pop logic to test fixture: pre_stack current=S so reconcile
  # matches P=S (=no-op). back=[X, Y, S]: X is most recent (idx 2 / newest),
  # then Y (idx 1), then S (idx 0 / oldest). alt- walks from i=2 X (ambiguous,
  # skip, retain), i=1 Y (skip, retain), i=0 S (landable, target). pre_target =
  # back[0:0]=[] ⇒ retained_unlandable (X,Y reversed, MRU order) becomes new back.
  local pre_stack='{"v":1,"current":{"sid":"S","ts":1990000000000},"back":["S","Y","X"],"forward":[]}'
  run_trav "decide-act" "$sandbox" "$pso" \
    $'/solo\tsxS\tterminal_0\t0
/amb\tsxX\tterminal_1\t1
/amb\tsxY\tterminal_2\t1' "prev" "$now_ms" "$pre_stack"
  assert_eq "amb-prev: lands S (skipped over X and Y)" \
    "DECISION:kind=select cwd=/solo session=sxS pane=terminal_0 tab_id=0 key=${key}-${pidS} sid=S" \
    "$TRAV_STDOUT"
  # S's pre-reconcile current is also S — back-pop pushes S onto forward,
  # then current-removal filter drops it (invariant). forward stays empty.
  assert_stack_eq "amb-prev: X+Y retained on back, S removed (new current), forward stays empty (current-removal)" \
    "{\"v\":1,\"current\":{\"sid\":\"S\",\"ts\":${now_ms}},\"back\":[\"Y\",\"X\"],\"forward\":[]}" \
    "$sandbox/traverse-stack.json"
}

# === Corrupt or v != 1 stack resets to empty and adopts P ===
test_corrupt_stack_resets_to_empty() {
  local sandbox="$ROOT/corrupt"
  mkdir -p "$sandbox"
  local key; key=$(key_for "/corrupt")
  local pid=20001
  local pso="$ROOT/ps_corrupt.tsv"
  printf 'OPENCODE\t%s\n' "$pid" > "$pso"
  write_v2 "$sandbox" "$key" "$pid" "/corrupt" "sxS" "P_sid" 2000000000000 \
    "P_sid" "done" 100 null \
    "T"     "needs-attention" 500 null
  local now_ms=2000000000500
  # v != 1
  printf '%s\n' '{"v":99,"current":null,"back":[],"forward":[]}' > \
    "$sandbox/traverse-stack.json"
  run_trav "decide-act" "$sandbox" "$pso" \
    $'/corrupt\tsxS\tterminal_0\t0' "next" "$now_ms"
  # stack_read should treat as fresh (canonical empty). Reconcile adopts P_sid
  # (no push since current was null). Then alt-] processes: forward empty →
  # pending[0]=T ⇒ new-nav. push P_sid onto back MRU.
  assert_eq "corrupt-next: select T lands" \
    "DECISION:kind=select cwd=/corrupt session=sxS pane=terminal_0 tab_id=0 key=${key}-${pid} sid=T" \
    "$TRAV_STDOUT"
  assert_stack_eq "corrupt-next: ignored v=99, adopt P then new-nav" \
    "{\"v\":1,\"current\":{\"sid\":\"T\",\"ts\":${now_ms}},\"back\":[\"P_sid\"],\"forward\":[]}" \
    "$sandbox/traverse-stack.json"
}

# === Empty live list exits non-zero before any stack mutation ===
test_empty_live_list_exits_nonzero() {
  local sandbox="$ROOT/empty"
  mkdir -p "$sandbox"
  # NO live pane entries ⇒ .live length 0 ⇒ abort.
  local pso="$ROOT/ps_empty.tsv"
  : > "$pso"  # empty ps file just to satisfy override env if needed
  local pre_stack='{"v":1,"current":{"sid":"cur","ts":1990000000000},"back":["x"],"forward":["y"]}'
  run_trav "decide-act" "$sandbox" "$pso" $'' "prev" "2000000000500" "$pre_stack"
  assert_eq "empty-live exits nonzero" "1" "$TRAV_RC"
  assert_contains "empty-live message" "$TRAV_STDOUT" "no live agents"
  assert_stack_eq "empty-live: stack untouched (no mutation, no write even)" \
    "$pre_stack" "$sandbox/traverse-stack.json"
}

# === No landable target exits zero with "at end" and no mailbox ===
test_no_landable_target_at_end_no_mailbox() {
  local sandbox="$ROOT/atend"
  mkdir -p "$sandbox"
  local key; key=$(key_for "/atend")
  local pid=21001
  local pso="$ROOT/ps_atend.tsv"
  printf 'OPENCODE\t%s\n' "$pid" > "$pso"
  # current=Z (matches P=Z ⇒ reconcile no-op); back entries all dead.
  write_v2 "$sandbox" "$key" "$pid" "/atend" "sxS" "Z" 2000000000000 \
    "Z" "done" 100 null
  local now_ms=2000000000500
  local pre_stack='{"v":1,"current":{"sid":"Z","ts":1990000000000},"back":["dead1","dead2"],"forward":[]}'
  run_trav "decide-act" "$sandbox" "$pso" \
    $'/atend\tsxS\tterminal_0\t0' "prev" "$now_ms" "$pre_stack"
  assert_eq "atend-prev: no landable → at-end" \
    "DECISION:kind=at-end" "$TRAV_STDOUT"
  assert_eq "atend-prev: at-end exits 0" "0" "$TRAV_RC"
  assert_file_absent "atend-prev: NO .select written" "$sandbox/${key}-${pid}.select"
  # Stack file IS still written (dead entries pruned), but no current mutation.
  assert_stack_eq "atend-prev: dead entries pruned; no current change" \
    '{"v":1,"current":{"sid":"Z","ts":1990000000000},"back":[],"forward":[]}' \
    "$sandbox/traverse-stack.json"
}

# === DECIDE_ONLY emits decision without side effects ===
test_decide_only_no_side_effects() {
  local sandbox="$ROOT/decideonly"
  mkdir -p "$sandbox"
  local key; key=$(key_for "/decideonly")
  local pid=22001
  local pso="$ROOT/ps_decideonly.tsv"
  printf 'OPENCODE\t%s\n' "$pid" > "$pso"
  write_v2 "$sandbox" "$key" "$pid" "/decideonly" "sxS" "Z" 2000000000000 \
    "Z" "done"          100 null \
    "T" "needs-attention" 500 null
  local now_ms=2000000000500
  local pre_stack='{"v":1,"current":{"sid":"Z","ts":1990000000000},"back":["old"],"forward":[]}'
  run_trav "decide-only" "$sandbox" "$pso" \
    $'/decideonly\tsxS\tterminal_0\t0' "next" "$now_ms" "$pre_stack"
  assert_eq "decide-only next: select decision emitted" \
    "DECISION:kind=select cwd=/decideonly session=sxS pane=terminal_0 tab_id=0 key=${key}-${pid} sid=T" \
    "$TRAV_STDOUT"
  assert_file_absent "decide-only: NO .select written" "$sandbox/${key}-${pid}.select"
  assert_stack_eq "decide-only: stack file matches pre_stack (decide-only suppresses stack_write)" \
    "$pre_stack" "$sandbox/traverse-stack.json"
}

# === DECIDE_ONLY against a NONEXISTENT state dir ===
# Prove: no mkdir, no file write. Pre-run rm -rf removes any prior dir. The
# harness's `run_trav` sets env vars but the script must NOT create the dir
# under DECIDE_ONLY. Pre-existing traverse-stack.json is also absent so we can
# assert the script did not synthesize one (it would need stack_write).
test_decide_only_no_state_dir_no_side_effects() {
  local sandbox="$ROOT/decideonly_absent"
  rm -rf "$sandbox"
  # $sandbox must NOT exist on entry — script under DECIDE_ONLY must not create it.
  # Build stack target + live-pane fixture + ps override in TMP_DIR (NOT state dir).
  local pso="$ROOT/ps_dabsent.tsv"
  printf 'OPENCODE\t23001\n' > "$pso"
  # Build a state file via env that the script could read — but since we want
  # zero side-effects under DECIDE_ONLY, run a script-internal sandbox via
  # AGENT_FLEET_STATE_DIR but ONLY on a tmpfs path we know to be absent.
  # Empty-live guard fires first (no live pane), exits 1 BEFORE any stack read →
  # also exercises the empty-live guard under DECIDE_ONLY (it should also be
  # suppressed).
  TRAV_RC=0
  TRAV_STDOUT="$(
    env \
      AGENT_FLEET_DECIDE_ONLY=1 \
      AGENT_FLEET_STATE_DIR="$sandbox" \
      AGENT_FLEET_LIVE_PANES_OVERRIDE="$ROOT/pane-${RANDOM}.tsv" \
      AGENT_FLEET_PS_OVERRIDE="$pso" \
      AGENT_FLEET_MESSAGE_DELAY=0 \
      AGENT_FLEET_NOW_MS=2000000000500 \
      AGENT_FLEET_MODEL="$SCRIPT_DIR/agent-fleet-model.mjs" \
      bash "$TRAVERSE" "next" 2>"$ROOT/err_dabsent.txt")" || TRAV_RC=$?
  TRAV_STDERR="$(cat "$ROOT/err_dabsent.txt")"
  assert_eq "decide-only no-state-dir exits 1 (empty-live guard)" "1" "$TRAV_RC"
  # The state-dir dir must not have been created by the script.
  assert_eq "decide-only: state dir NOT created (mkdir guarded)" "" \
    "$(test -d "$sandbox" && echo 'exists' || echo '')"
}

# === DECIDE_ONLY at-end case: no landable target, no stack mutation ===
test_decide_only_at_end_no_side_effects() {
  local sandbox="$ROOT/decideonly_atend"
  mkdir -p "$sandbox"
  local key; key=$(key_for "/decideonly_atend")
  local pid=24001
  local pso="$ROOT/ps_dt_atend.tsv"
  printf 'OPENCODE\t%s\n' "$pid" > "$pso"
  # current=Z (matches P=Z ⇒ reconcile no-op); back all dead ⇒ at-end.
  write_v2 "$sandbox" "$key" "$pid" "/decideonly_atend" "sxS" "Z" 2000000000000 \
    "Z" "done" 100 null
  local now_ms=2000000000500
  local pre_stack='{"v":1,"current":{"sid":"Z","ts":1990000000000},"back":["dead1","dead2"],"forward":[]}'
  # Snapshot mtime pre-press so we can assert no rewrite.
  local pre_mtime
  printf '%s\n' "$pre_stack" > "$sandbox/traverse-stack.json"
  # Use date -r (portable BSD/GNU) for mtime in epoch seconds.
  pre_mtime="$(date -r "$sandbox/traverse-stack.json" +%s 2>/dev/null || echo 0)"
  run_trav "decide-only" "$sandbox" "$pso" \
    $'/decideonly_atend\tsxS\tterminal_0\t0' "prev" "$now_ms" "" # don't overwrite pre_stack
  assert_eq "decide-only at-end: at-end decision emitted" \
    "DECISION:kind=at-end" "$TRAV_STDOUT"
  assert_file_absent "decide-only at-end: NO .select written" "$sandbox/${key}-${pid}.select"
  # Stack file unchanged (no mtime reset, no content rewrite).
  local post_mtime
  post_mtime="$(date -r "$sandbox/traverse-stack.json" +%s 2>/dev/null || echo 0)"
  assert_eq "decide-only at-end: stack file mtime unchanged" "$pre_mtime" "$post_mtime"
  assert_stack_eq "decide-only at-end: stack file content unchanged" \
    "$pre_stack" "$sandbox/traverse-stack.json"
}

# === DECIDE_ACT writes stack + mailbox but does NOT call focus tools ===
# (we cannot directly observe aerospace/zellij absence without side-effects;
# but the parent's DECIDE_ACT guard skips the tail — we trust the inherited
# act_land's behavior and assert stack+select exist).
test_decide_act_writes_stack_and_mailbox() {
  local sandbox="$ROOT/decideact"
  mkdir -p "$sandbox"
  local key; key=$(key_for "/decideact")
  local pid=23001
  local pso="$ROOT/ps_decideact.tsv"
  printf 'OPENCODE\t%s\n' "$pid" > "$pso"
  write_v2 "$sandbox" "$key" "$pid" "/decideact" "sxS" "Z" 2000000000500 \
    "Z" "done"          100 null \
    "T" "needs-attention" 500 null
  local now_ms=2000000000500
  local pre_stack='{"v":1,"current":{"sid":"Z","ts":1990000000000},"back":["old"],"forward":[]}'
  run_trav "decide-act" "$sandbox" "$pso" \
    $'/decideact\tsxS\tterminal_0\t0' "next" "$now_ms" "$pre_stack"
  assert_eq "decide-act next: select decision emitted" \
    "DECISION:kind=select cwd=/decideact session=sxS pane=terminal_0 tab_id=0 key=${key}-${pid} sid=T" \
    "$TRAV_STDOUT"
  assert_file_exists "decide-act: .select written" "$sandbox/${key}-${pid}.select"
  assert_file_exists "decide-act: stack persists" "$sandbox/traverse-stack.json"
  assert_stack_eq "decide-act: stack matches reconcile+new-nav shape (reconcile no-op: P=Z == current=Z; alt- lands T with new-nav push of Z onto back)" \
    "{\"v\":1,\"current\":{\"sid\":\"T\",\"ts\":${now_ms}},\"back\":[\"old\",\"Z\"],\"forward\":[]}" \
    "$sandbox/traverse-stack.json"
}

# === All-dead forward stack + clean pending[0] → land via pending (new nav) ===
# Pending[0]=A (rank=1, oldest ts after dead-prune consumed forward entries).
# Forward has [dead1, dead2]; alt-] prunes both, falls to pending → land A.
test_forward_all_dead_falls_to_pending() {
  local sandbox="$ROOT/fw_dead"
  mkdir -p "$sandbox"
  local key; key=$(key_for "/fw_dead")
  local pid=25001
  local pso="$ROOT/ps_fw_dead.tsv"
  printf 'OPENCODE\t%s\n' "$pid" > "$pso"
  write_v2 "$sandbox" "$key" "$pid" "/fw_dead" "sxS" "Z" 2000000000000 \
    "Z" "done"            500 null \
    "A" "needs-attention"  10 null
  local now_ms=2000000000500
  # current=Z (matches P=Z ⇒ reconcile no-op). Forward has only dead sids.
  local pre_stack='{"v":1,"current":{"sid":"Z","ts":1990000000000},"back":[],"forward":["dead1","dead2"]}'
  run_trav "decide-act" "$sandbox" "$pso" \
    $'/fw_dead\tsxS\tterminal_0\t0' "next" "$now_ms" "$pre_stack"
  assert_eq "forward-all-dead next: lands pending[0]=A (forward dry, dead pruned, fall to pending)" \
    "DECISION:kind=select cwd=/fw_dead session=sxS pane=terminal_0 tab_id=0 key=${key}-${pid} sid=A" \
    "$TRAV_STDOUT"
  # Forward cleared (new-nav), Z (old current) pushed MRU onto back.
  assert_stack_eq "forward-all-dead: stack matches forward-empty + new-nav shape" \
    "{\"v\":1,\"current\":{\"sid\":\"A\",\"ts\":${now_ms}},\"back\":[\"Z\"],\"forward\":[]}" \
    "$sandbox/traverse-stack.json"
}

# === Model failure: AGENT_FLEET_MODEL points at a failing stub. The script
# should `set -euo pipefail` abort before stack mutation, exit nonzero. ===
# Jump's test_60 follows the same chflags-uchg pattern for stack_write —
# mirror it here for traverse. Both files share the act layer. ===
test_model_failure_propagates() {
  local sandbox="$ROOT/modelfail"
  mkdir -p "$sandbox"
  # Failing model: a JSON module that throws on require. node exits nonzero,
  # set -euo pipefail aborts the traverse script BEFORE stack read/write.
  local stub="$ROOT/fail-model.cjs"
  cat > "$stub" <<'EOF'
throw new Error("stub-model: failing on purpose");
EOF
  TRAV_RC=0
  TRAV_STDOUT="$(
    env \
      AGENT_FLEET_DECIDE_ACT=1 \
      AGENT_FLEET_STATE_DIR="$sandbox" \
      AGENT_FLEET_LIVE_PANES_OVERRIDE="$ROOT/pane-${RANDOM}.tsv" \
      AGENT_FLEET_PS_OVERRIDE="$sandbox/ps.tsv" \
      AGENT_FLEET_NOW_MS=2000000000500 \
      AGENT_FLEET_MESSAGE_DELAY=0 \
      AGENT_FLEET_MODEL="$stub" \
      bash "$TRAVERSE" "prev" 2>"$ROOT/err_modelfail.txt")" || TRAV_RC=$?
  TRAV_STDERR="$(cat "$ROOT/err_modelfail.txt")"
  # Spec: RC != 0 (model failure aborts the press). We don't pin a specific
  # nonzero code — node may exit 1 from syntax error or 7-ish for uncaught.
  # Critically: no traverse-stack.json should appear (script aborted pre-read).
  if [ "${TRAV_RC:-0}" -ne 0 ]; then pass "model-failure: rc nonzero (script aborted pre-mutation)"
  else fail "model-failure: rc zero (model failure should abort)" "rc=$TRAV_RC"; fi
  assert_file_absent "model-failure: no traverse-stack.json written" "$sandbox/traverse-stack.json"
  # Enumerate glob BEFORE asserting: a quoted glob in assert_file_absent would
  # match a literal `*.select` filename and pass vacuously.
  local -a mailboxes_found
  mapfile -t mailboxes_found < <(compgen -G "$sandbox/*.select" 2>/dev/null)
  if [ "${#mailboxes_found[@]}" -eq 0 ]; then
    pass "model-failure: no .select mailbox written"
  else
    fail "model-failure: .select mailbox leaked despite model abort" \
      "found: ${mailboxes_found[*]}"
  fi
}

# === Stack-write failure: chflags uchg the stack file, but the press still
# lands: the .select mailbox must be written (stack_write warns-and-returns-0,
# just like jump's case60). ===
test_stack_write_failure_landing_still_happens() {
  local sandbox="$ROOT/swfail"
  mkdir -p "$sandbox"
  local key; key=$(key_for "/swfail")
  local pid=26001
  local pso="$ROOT/ps_swfail.tsv"
  printf 'OPENCODE\t%s\n' "$pid" > "$pso"
  write_v2 "$sandbox" "$key" "$pid" "/swfail" "sxS" "Z" 2000000000000 \
    "Z" "done"          100 null \
    "T" "needs-attention" 500 null
  local now_ms=2000000000500
  printf '%s\n' '{"v":1,"current":{"sid":"Z","ts":1990000000000},"back":[],"forward":[]}' \
    > "$sandbox/traverse-stack.json"
  # Pre-create the SAME immutable target so the atomic rename fails.
  chflags uchg "$sandbox/traverse-stack.json"
  run_trav "decide-act" "$sandbox" "$pso" \
    $'/swfail\tsxS\tterminal_0\t0' "next" "$now_ms" "" # don't overwrite pre_stack
  assert_file_exists "stack-write-failure: .select mailbox STILL lands despite stack_write failure" \
    "$sandbox/${key}-${pid}.select"
  # stderr MUST carry a stack_write warning (jump case60 pattern).
  assert_contains "stack-write-failure: stderr stack_write warning emitted" \
    "$TRAV_STDERR" "stack_write"
  # Drop uchg so the EXIT trap can rm -rf cleanly.
  chflags nouchg "$sandbox/traverse-stack.json" 2>/dev/null || true
}

# === Escaped sid round-trip: sid containing both " and \\ must (a) parse as
# valid v2 JSON to the model and (b) round-trip through the .select mailbox
# without quoting injection. Mirrors jump's test_70 for traverse.sh. ===
# Use a sid whose bash single-quoted form is unambiguous about contents
# (no double-escaping inside the shell variable). The literal characters
# `weird"quote\slash` are exactly 17 bytes — quote is literal in single-quoted
# bash strings, and a single `\` is exactly one character.
test_escaped_sid_traversal_round_trip() {
  local sandbox="$ROOT/escsid"
  mkdir -p "$sandbox"
  local key; key=$(key_for "/escsid")
  local pid=27001
  local pso="$ROOT/ps_escsid.tsv"
  printf 'OPENCODE\t%s\n' "$pid" > "$pso"
  # Sid containing a double-quote AND a backslash — single-quoted bash literal
  # gives 17 chars (no shell-escape ambiguity inside `''`).
  local sid_lit='weird"quote\slash'
  [[ ${#sid_lit} -eq 17 ]] || {
    fail "escaped-sid sid_lit fixture not exactly 17 chars" "char count: ${#sid_lit}"
    return
  }
  # Build v2 directly (write_v2 operates on pairs after selectedSid/selectedTs).
  # We want selectedSid = "T" (so reconcile no-op with pre_stack current=T)
  # but the escaped-sid MUST be in sessions so the model surfaces it as
  # pending. pending[0] = escaped-sid when sorted ts asc (escaped ts=500, T ts=10
  # ⇒ escaped is NEWER, T is oldest... actually we want T oldest so escaped lands).
  # Reverse: escaping won't be pending[0] oldest, but current=T ≠ escaped ⇒
  # pending guard keeps escaped ⇒ land escaped.
  jq -n \
    --arg sid "$sid_lit" \
    --arg repo "escsid" \
    --arg cwd "/escsid" \
    --arg session "sxS" \
    --argjson pid "$pid" \
    --arg selectedSid "T" \
    --argjson selectedTs 2000000000000 \
    '{
      repo:$repo, cwd:$cwd, session:$session, pid:$pid,
      selectedSid:$selectedSid, selectedTs:$selectedTs,
      sessions: {
        ($sid): { state:"needs-attention", reason:null, ts:500,   task:null, title:"e_t" },
        "T":     { state:"needs-attention", reason:null, ts:10,    task:null, title:"t_t" }
      }
    }' \
    > "$sandbox/${key}-${pid}.json"
  # Sanity: the v2 file parses as valid JSON.
  if jq -e . "$sandbox/${key}-${pid}.json" >/dev/null 2>&1; then
    pass "escaped-sid v2 parses as valid JSON"
  else
    fail "escaped-sid v2 fails to parse" "file=$sandbox/${key}-${pid}.json"
  fi
  local decoded_sid
  decoded_sid="$(jq -r '.sessions | keys[] | select(. != "T")' "$sandbox/${key}-${pid}.json")"
  assert_eq "escaped-sid: v2 sid round-trips through JSON" "$sid_lit" "$decoded_sid"
  local now_ms=2000000000500
  # pre_stack: current=T (reconcile no-op). After alt-, pending[0]=escaped-sid
  # (because T is current and filtered out). New nav: clear forward, push T MRU.
  local pre_stack
  pre_stack='{"v":1,"current":{"sid":"T","ts":1990000000000},"back":[],"forward":[]}'
  run_trav "decide-act" "$sandbox" "$pso" \
    $'/escsid\tsxS\tterminal_0\t0' "next" "$now_ms" "$pre_stack"
  assert_eq "escaped-sid next: select decision emits escaped sid verbatim" \
    "DECISION:kind=select cwd=/escsid session=sxS pane=terminal_0 tab_id=0 key=${key}-${pid} sid=${sid_lit}" \
    "$TRAV_STDOUT"
  assert_file_exists "escaped-sid: .select mailbox written" "$sandbox/${key}-${pid}.select"
  # Mailbox JSON parses cleanly AND sessionID round-trips.
  if jq -e . "$sandbox/${key}-${pid}.select" >/dev/null 2>&1; then
    pass "escaped-sid: mailbox parses as valid JSON"
  else
    fail "escaped-sid: mailbox fails to parse"
  fi
  local got_sid
  got_sid="$(jq -r .sessionID "$sandbox/${key}-${pid}.select")"
  assert_eq "escaped-sid: .select sessionID round-trips the escaped bytes" \
    "$sid_lit" "$got_sid"
  # Mailbox keyset = exactly {sessionID} — escape injection must not have
  # introduced siblings (markOnly, sessionID2, etc).
  local keys
  keys="$(jq -c 'keys_unsorted' "$sandbox/${key}-${pid}.select")"
  assert_eq "escaped-sid: .select mailbox keyset = {sessionID} only" '["sessionID"]' "$keys"
}

# === Argument validation: invalid arg exits 2 ===
test_argument_validation() {
  local sandbox="$ROOT/args"
  mkdir -p "$sandbox"
  local pso="$ROOT/ps_args.tsv"
  : > "$pso"
  # missing arg
  TRAV_RC=0
  TRAV_STDOUT="$(env \
    AGENT_FLEET_STATE_DIR="$sandbox" \
    AGENT_FLEET_LIVE_PANES_OVERRIDE="$ROOT/pane-${RANDOM}.tsv" \
    AGENT_FLEET_MESSAGE_DELAY=0 \
    bash "$TRAVERSE" 2>"$ROOT/err_a.txt")" || TRAV_RC=$?
  TRAV_STDERR="$(cat "$ROOT/err_a.txt")"
  assert_eq "args: missing arg exits 2 (usage)" "2" "$TRAV_RC"
  assert_contains "args: stderr mentions usage" "$TRAV_STDERR" "usage"

  TRAV_RC=0
  TRAV_STDOUT="$(env \
    AGENT_FLEET_STATE_DIR="$sandbox" \
    AGENT_FLEET_LIVE_PANES_OVERRIDE="$ROOT/pane-${RANDOM}.tsv" \
    AGENT_FLEET_MESSAGE_DELAY=0 \
    bash "$TRAVERSE" "bogus" 2>"$ROOT/err_b.txt")" || TRAV_RC=$?
  TRAV_STDERR="$(cat "$ROOT/err_b.txt")"
  assert_eq "args: invalid subcommand exits 2 (usage)" "2" "$TRAV_RC"
  assert_contains "args: stderr mentions usage" "$TRAV_STDERR" "usage"
}

# === run all tests ===
run_test() { "$1"; }

run_test test_scenario_1_acceptance_next_prev_next
run_test test_scenario_2_acceptance_prev_next_next
run_test test_back_pops_mru_forward_pops_lifo
run_test test_recency_uniqueness_no_double_insertion
run_test test_back_exhaustion_scans_viewed_positionally
run_test test_back_exhaustion_absent_current_starts_head
run_test test_pending_guard_skips_equal_to_current
run_test test_dead_entries_pruned_AND_at_end_persists
run_test test_ambiguous_entries_skipped_but_retained
run_test test_corrupt_stack_resets_to_empty
run_test test_forward_all_dead_falls_to_pending
run_test test_model_failure_propagates
run_test test_stack_write_failure_landing_still_happens
run_test test_escaped_sid_traversal_round_trip
run_test test_empty_live_list_exits_nonzero
run_test test_no_landable_target_at_end_no_mailbox
run_test test_decide_only_no_side_effects
run_test test_decide_only_no_state_dir_no_side_effects
run_test test_decide_only_at_end_no_side_effects
run_test test_decide_act_writes_stack_and_mailbox
run_test test_next_from_non_agent_session_lands_current
run_test test_argument_validation

printf '%s' "$LOG"
echo "---"
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
