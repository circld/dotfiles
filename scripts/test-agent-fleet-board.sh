#!/usr/bin/env bash
# scripts/test-agent-fleet-board.sh
#
# Behavior harness for agent-fleet-board.sh (Task 8): cache refresh,
# tick-rate deadline, keyboard navigation identity-stability, EOF /
# Escape semantics, WINCH repaint, model-failure cache preservation,
# non-TTY stty tolerance, and EXIT cleanup. Drives the board over
# piped key streams so stty is expected to fail — the board must
# tolerate it.
#
# `set -u` is on but NOT `set -e`: a buggy board path should not abort
# the whole suite under strict mode; tests assert RCs explicitly. (-u
# stays on so unset-variable references are caught early — we just
# guard them via initialization at the top of each test.)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BOARD="$REPO_ROOT/scripts/agent-fleet-board.sh"

if [ ! -f "$BOARD" ]; then
  printf 'FAIL: board.sh missing at %s\n' "$BOARD"; exit 1
fi
if (( BASH_VERSINFO[0] < 4 )); then
  printf 'FAIL: bash >= 4 required (got %s)\n' "$BASH_VERSION"; exit 1
fi

ROOT="$(mktemp -d)"

BOARD_PID=""
FEEDER_PID=""
cleanup() {
  if [ -n "$FEEDER_PID" ]; then
    kill "$FEEDER_PID" 2>/dev/null || true
    wait "$FEEDER_PID" 2>/dev/null || true
  fi
  if [ -n "$BOARD_PID" ]; then
    kill "$BOARD_PID" 2>/dev/null || true
    wait "$BOARD_PID" 2>/dev/null || true
  fi
  rm -rf "$ROOT"
}
trap cleanup EXIT

# Fake executables: rebuilt per test run, fixed path.
FAKES="$ROOT/fakes"
mkdir -p "$FAKES"

# Fake model succeeds and cats the bytes at `$STATE/.fake-model.json` —
# the harness mutates that file between ticks to drive reorder / vanish
# assertions.
cat > "$FAKES/model.sh" <<'EOF'
#!/usr/bin/env bash
log="${AGENT_FLEET_TEST_LOG_M:-}"
state_dir="${AGENT_FLEET_STATE_DIR:-}"
[ -n "$log" ] && printf 'model ok ts=%s\n' "$(date +%s%N)" >> "$log"
if [ -f "$state_dir/.fake-model.json" ]; then
  cat "$state_dir/.fake-model.json"
fi
EOF
chmod +x "$FAKES/model.sh"

# Fake model that ALWAYS fails (exit 7, stderr noise).
cat > "$FAKES/model-fail.sh" <<'EOF'
#!/usr/bin/env bash
log="${AGENT_FLEET_TEST_LOG_M:-}"
[ -n "$log" ] && printf 'model FAIL ts=%s\n' "$(date +%s%N)" >> "$log"
echo "garbage model stderr noise" >&2
exit 7
EOF
chmod +x "$FAKES/model-fail.sh"

# Fake renderer: emits a deterministic line-numbered TSV from any cache
# rows. Logs every invocation with the received HIGHLIGHT_LINE so the
# harness can assert navigation sequences.
cat > "$FAKES/renderer.sh" <<'EOF'
#!/usr/bin/env bash
log="${AGENT_FLEET_TEST_LOG_R:-}"
state_dir="${AGENT_FLEET_STATE_DIR:-}"
hl="${AGENT_FLEET_HIGHLIGHT_LINE-(unset)}"
[ -n "$log" ] && printf 'render hl=[%s] ts=%s\n' "$hl" "$(date +%s%N)" >> "$log"
linemap="$state_dir/.board-linemap.tsv"
cache="$state_dir/.board-cache.json"
# Atomic empty linemap BEFORE any work that could fail.
tmp="$(mktemp "$linemap.tmp.XXXXXX")"
: > "$tmp"
mv -f "$tmp" "$linemap"
if [ ! -f "$cache" ]; then exit 0; fi
tmp="$(mktemp "$linemap.tmp.XXXXXX")"
: > "$tmp"
n=0
# .rows[] → (key,sid,cwd) tab-joined; emit deterministic line_no.
while IFS= read -r row; do
  key="$(awk -F $'\t' '{print $1}' <<<"$row")"
  sid="$(awk -F $'\t' '{print $2}' <<<"$row")"
  cwd="$(awk -F $'\t' '{print $3}' <<<"$row")"
  n=$((n + 1))
  printf '%d\t%s\t%s\t%s\n' "$n" "$key" "$sid" "$cwd" >> "$tmp"
done < <(jq -r '.rows[] | [(.key // ""), (.sid // ""), (.cwd // "")] | @tsv' < "$cache" 2>/dev/null)
mv -f "$tmp" "$linemap"
EOF
chmod +x "$FAKES/renderer.sh"

# === harness plumbing ===
NOW_MS="$(($(date +%s) * 1000))"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1"; }
fail_msg() {
  FAIL=$((FAIL + 1))
  printf 'FAIL: %s\n' "$1" >&2
  shift
  for arg in "$@"; do printf '  %s\n' "$arg" >&2; done
}
assert_eq() {
  local label="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then pass "$label"
  else fail_msg "$label" "want=[$want]" "got=[$got]"; fi
}
assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then pass "$label"
  else fail_msg "$label" "haystack=" "<see test output>" "expected substring:" "$needle"; fi
}
assert_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then pass "$label"
  else fail_msg "$label" "haystack unexpectedly contained:" "$needle"; fi
}

key_for() { printf '%s' "$1" | shasum -a 256 | cut -c1-16; }

# mk_row: emit a JSON row matching the renderer's expected shape.
mk_row() {
  local source="$1" key="$2" sid="$3" cwd="$4" session="$5"
  local state="$6" reason="$7" ts="$8"
  jq -c -n \
    --arg source "$source" --arg key "$key" --arg sid "$sid" \
    --arg cwd "$cwd" --arg session "$session" \
    --arg state "$state" --arg reason "$reason" --argjson ts "$ts" \
    '{
      source: $source,
      cwd: $cwd,
      session: $session,
      state: $state,
      ts: $ts,
      sid: (if $sid == "" then null else $sid end),
      key: (if $key == "" then null else $key end),
      reason: (if $reason == "" then null else $reason end),
      repo: ($cwd | sub(".*/";"")),
      title: (if $sid == "" then null else $sid end),
      label: null,
      suppressed: false,
      rank: 0,
      pid: null,
      pane: "x", tabId: "0"
    }'
}

# write_cache: write a cache JSON with N row strings.
write_cache() {
  local path="$1"; shift
  local joined=""
  for r in "$@"; do
    if [ -z "$joined" ]; then joined="$r"; else joined="$joined,$r"; fi
  done
  printf '{"rows":[%s]}' "$joined" > "$path"
}

# In bash, every command in a pipeline runs in a subshell by default
# (variable writes do not propagate to the caller). We set `lastpipe`
# so the LAST command of a pipeline runs in the harness's main shell —
# `launch_board_async` writes BOARD_PID, and the caller sees it.
shopt -s lastpipe

# Launch the board in the background, reading stdin from a fresh FIFO.
#
# Why FIFO and not `(feeder) | board`: pipelines BLOCK the harness's
# main shell until BOTH sides close. With a feeder like `(sleep 60)`,
# that means the harness can't move forward for 60s — including its
# next `sleep 3.0` assertion. FIFOs decouple the two: feeder writes
# asynchronously, harness drives forward, board reads from the FIFO
# until the feeder closes (EOF).
launch_board_async() {
  local sandbox="$1" model="$2" renderer="$3"
  mkdir -p "$sandbox"
  : > "$sandbox/stdout"; : > "$sandbox/stderr"
  : > "$sandbox/log-model"; : > "$sandbox/log-render"
  BOARD_FIFO="$sandbox/.board-input.fifo"
  rm -f "$BOARD_FIFO"
  mkfifo "$BOARD_FIFO"
  AGENT_FLEET_STATE_DIR="$sandbox" \
    AGENT_FLEET_MODEL="$model" \
    AGENT_FLEET_RENDER="$renderer" \
    AGENT_FLEET_TEST_LOG_M="$sandbox/log-model" \
    AGENT_FLEET_TEST_LOG_R="$sandbox/log-render" \
    AGENT_FLEET_REFRESH_SECS=1 \
    bash "$BOARD" < "$BOARD_FIFO" > "$sandbox/stdout" 2> "$sandbox/stderr" &
  BOARD_PID=$!
}

# Feed bytes to the board's FIFO, then close (board sees EOF). Use the
# pattern `feed_close "$fifo" "bytes" "$board_active_secs"` so the pipe
# stays open exactly as long as we need it before EOF.
feed_close() {
  local fifo="$1" bytes="$2" active_secs="$3"
  (
    exec 9>"$fifo"
    printf '%s' "$bytes" >&9
    sleep "$active_secs"
    exec 9>&-
  )
}

# Long-lived feeder: write bytes with delays between segments, then
# sleep forever (kept open). Caller kills FEEDER_PID via `stop_feeder`
# when ready for the board to see EOF.
feed_forever() {
  local fifo="$1"
  shift
  (
    local sleep_pid=""
    trap 'kill "$sleep_pid" 2>/dev/null || true; exit 0' TERM INT
    exec 9>"$fifo"
    while [ "$#" -gt 0 ]; do
      printf '%s' "$1" >&9
      shift
      if [ "$#" -gt 0 ]; then
        sleep "$1"
        shift
      fi
    done
    while :; do
      sleep 3600 &
      sleep_pid=$!
      wait "$sleep_pid" || true
    done
  ) &
  FEEDER_PID=$!
}

stop_feeder() {
  if [ -n "$FEEDER_PID" ]; then
    kill "$FEEDER_PID" 2>/dev/null || true
    wait "$FEEDER_PID" 2>/dev/null || true
    FEEDER_PID=""
  fi
}

# Wait for board to exit (after stdin pipe closes); bounded by max_secs.
# Returns the board's RC; 124 = forced kill on harness timeout.
wait_board() {
  local max_secs="$1"
  local start=$SECONDS
  while kill -0 "$BOARD_PID" 2>/dev/null; do
    if (( SECONDS - start >= max_secs )); then
      kill -TERM "$BOARD_PID" 2>/dev/null || true
      sleep 0.2
      kill -KILL "$BOARD_PID" 2>/dev/null || true
      wait "$BOARD_PID" 2>/dev/null
      return 124
    fi
    sleep 0.05
  done
  wait "$BOARD_PID"
  return $?
}

# hls_in_log: collect every hl= value from a render log in order.
hls_in_log() {
  local log="$1"
  if [ -f "$log" ]; then
    grep -oE 'hl=\[[^]]*\]' "$log" | sed -E 's/^hl=\[//;s/\]$//' | tr '\n' ','
  else
    printf ''
  fi
}

# --- helper: synchronize with the board's first tick before issuing keys.
# board included the initial tick before the read loop, so 1 second is
# ample for the cache to land and the renderer to log. ---
wait_first_render() {
  local log="$1" max="${2:-2}"
  local start=$SECONDS
  while (( SECONDS - start < max )); do
    if [ -f "$log" ] && grep -qF 'render hl=' "$log" 2>/dev/null; then return 0; fi
    sleep 0.05
  done
  return 1
}

# === TESTS ===

# --- 1. Initial tick writes model JSON atomically, then renders. ---
test_initial_tick_writes_cache_and_renders() {
  local sandbox="$ROOT/case01_init_tick"
  mkdir -p "$sandbox"
  local key; key=$(key_for "/init_tick")
  write_cache "$sandbox/.fake-model.json" \
    "$(mk_row v2 "$key" ses_init /init_tick sx done "" $NOW_MS)"
  launch_board_async "$sandbox" "$FAKES/model.sh" "$FAKES/renderer.sh"
  # Open FIFO for write then close after a pause → board sees EOF after
  # the initial tick has had time to fire.
  ( exec 9>"$BOARD_FIFO"; sleep 1.2; exec 9>&- )
  wait_board 6
  assert_eq "case01: board exited 0" "0" "$?"
  # Post-exit, .board-cache.json was removed by EXIT trap (verified in case09);
  # here, prove the cache and linemap DID exist mid-run by inspecting logs.
  if [ -f "$sandbox/log-render" ] && grep -qF "render hl=" "$sandbox/log-render"; then
    pass "case01: renderer was invoked (cache existed mid-run)"
  else
    fail_msg "case01: renderer was invoked (cache existed mid-run)" "log-render missing render hl= lines"
    return 0
  fi
  if [ -f "$sandbox/log-model" ] && grep -qE '^model ok' "$sandbox/log-model"; then
    pass "case01: model was invoked at least once"
  else
    fail_msg "case01: model was invoked at least once" "log-model empty"
  fi
}

# --- 2. j / down arrow moves to next mapped row; k / up arrow moves previous; bounds clamp. ---
test_jk_arrow_navigation_bounds_clamp() {
  local sandbox="$ROOT/case02_nav_bounds"
  mkdir -p "$sandbox"
  local k1; k1=$(key_for "/nav1")
  local k2; k2=$(key_for "/nav2")
  local k3; k3=$(key_for "/nav3")
  write_cache "$sandbox/.fake-model.json" \
    "$(mk_row v2 "$k1" s1 /nav1 sx done "" $NOW_MS)" \
    "$(mk_row v2 "$k2" s2 /nav2 sx done "" $NOW_MS)" \
    "$(mk_row v2 "$k3" s3 /nav3 sx done "" $NOW_MS)"
  launch_board_async "$sandbox" "$FAKES/model.sh" "$FAKES/renderer.sh"
  # Feed: 1.4s pause, then \e[B jj jjj 0.4s pause, then kkkk k k 2.0s, EOF.
  feed_close "$BOARD_FIFO" "$(printf '\e[Bjjjj')kkkk" 1.5
  wait_board 7
  assert_eq "case02: board exited 0" "0" "$?"
  local hls; hls="$(hls_in_log "$sandbox/log-render")"
  # 1) Every numeric HL must be in 1..3 (map size 3).
  local bad
  bad="$(awk -F, '{for(i=1;i<=NF;i++){v=$i; if(v~/^[0-9]+$/ && (v<1||v>3)) print v}}' <<<"$hls")"
  if [ -z "$bad" ]; then pass "case02: every numeric HL is in 1..3 (map size 3)"
  else fail_msg "case02: every numeric HL is in 1..3 (map size 3)" "out-of-range: $bad"; fi
  # 2) After jjjj: HL clamped at 3.
  if [[ "$hls" == *",3,"* || "$hls" == *",3"* ]]; then
    pass "case02: jjjj clamped to HL=3"
  else
    fail_msg "case02: jjjj clamped to HL=3" "hls=$hls"
  fi
  # 3) After kkkk from 3: 2,1,1,1 — HL=1 must appear.
  if [[ "$hls" == *",1,"* || "$hls" == "1"* || "$hls" == *",1"* ]]; then
    pass "case02: kkkk clamped to HL=1"
  else
    fail_msg "case02: kkkk clamped to HL=1" "hls=$hls"
  fi
  # 4) Down arrow path proved HL advanced past 1 (we saw HL=2 or 3).
  if [[ "$hls" == *",2,"* || "$hls" == "2"* || "$hls" == *",2"* ]]; then
    pass "case02: down arrow / j moved past HL=1"
  else
    fail_msg "case02: down arrow / j moved past HL=1" "hls=$hls"
  fi
}

# --- 3. Highlight identity survives row reorder; vanished identity falls to same prior index or last row. ---
test_identity_survives_reorder_and_falls_on_vanish() {
  local sandbox="$ROOT/case03_identity_reorder"
  mkdir -p "$sandbox"
  local kA; kA=$(key_for "/reA")
  local kB; kB=$(key_for "/reB")
  local kC; kC=$(key_for "/reC")
  # Initial: A,B,C in that order (line 1=A, 2=B, 3=C).
  write_cache "$sandbox/.fake-model.json" \
    "$(mk_row v2 "$kA" sA /reA sx done "" $NOW_MS)" \
    "$(mk_row v2 "$kB" sB /reB sx done "" $NOW_MS)" \
    "$(mk_row v2 "$kC" sC /reC sx done "" $NOW_MS)"
  launch_board_async "$sandbox" "$FAKES/model.sh" "$FAKES/renderer.sh"
  feed_forever "$BOARD_FIFO" "j"
  sleep 0.3
  # Verify j's effect mid-stream: render emitted hl=2.
  if ! grep -qE 'hl=\[2\]' "$sandbox/log-render" 2>/dev/null; then
    fail_msg "case03: initial j moved to HL=2 (cache reorder hasn't fired yet)" \
      "$(hls_in_log "$sandbox/log-render")"
    stop_feeder; wait_board 3; return 0
  fi
  pass "case03: initial j moved to HL=2"
  # Snapshot the second cache file: B,A,C (B now at line 1).
  write_cache "$sandbox/.fake-model.json" \
    "$(mk_row v2 "$kB" sB /reB sx done "" $NOW_MS)" \
    "$(mk_row v2 "$kA" sA /reA sx done "" $NOW_MS)" \
    "$(mk_row v2 "$kC" sC /reC sx done "" $NOW_MS)"
  # Let the next deadline tick pick up the new file.
  sleep 1.2
  # Now post-reorder, B's identity must be re-discovered at line 1.
  if grep -qE 'hl=\[1\]' "$sandbox/log-render"; then
    pass "case03: post-reorder HL re-discovered by identity (B at line 1)"
  else
    fail_msg "case03: post-reorder HL re-discovered by identity (B at line 1)" \
      "$(hls_in_log "$sandbox/log-render")"
  fi
  # Vanish B: cache only has A,C (B removed).
  write_cache "$sandbox/.fake-model.json" \
    "$(mk_row v2 "$kA" sA /reA sx done "" $NOW_MS)" \
    "$(mk_row v2 "$kC" sC /reC sx done "" $NOW_MS)"
  sleep 1.2
  # B vanished → fallback to "same prior index, clamped to last row".
  # Last mapped line is now 2 (rows reduced). HL was 1 before vanish
  # (clamped target), so post-vanish HL should be 1 (clamped to last 2
  # = 2? – Depends on impl; spec accepts "same prior index" OR "last row"
  # → accept any HL in 1..2 as the fallback landed somewhere valid).
  local recent; recent="$(grep -E 'hl=\[' "$sandbox/log-render" | tail -5)"
  if [[ "$recent" =~ hl=\[[12]\] ]]; then
    pass "case03: vanished identity falls to a valid mapped line in {1,2}"
  else
    fail_msg "case03: vanished identity falls to a valid mapped line in {1,2}" \
      "recent hls: $(echo "$recent" | tr '\n' '|')"
  fi
  stop_feeder
  wait_board 3
}

# --- 4. Sid-less identity uses cwd even when its model key changes. ---
test_sidless_identity_uses_cwd() {
  local sandbox="$ROOT/case04_sidless_identity"
  mkdir -p "$sandbox"
  local old_key; old_key=$(key_for "/sidless-old")
  local new_key; new_key=$(key_for "/sidless-new")
  local other_key; other_key=$(key_for "/sidless-other")
  write_cache "$sandbox/.fake-model.json" \
    "$(mk_row v1 "$old_key" "" /sidless sx done "" $NOW_MS)" \
    "$(mk_row v2 "$other_key" sOther /other sx done "" $NOW_MS)"
  launch_board_async "$sandbox" "$FAKES/model.sh" "$FAKES/renderer.sh"
  feed_forever "$BOARD_FIFO"
  if ! wait_first_render "$sandbox/log-render" 3; then
    fail_msg "case04: sid-less identity initial render" "no first render"
    stop_feeder; wait_board 3; return 0
  fi
  write_cache "$sandbox/.fake-model.json" \
    "$(mk_row v2 "$other_key" sOther /other sx done "" $NOW_MS)" \
    "$(mk_row v1 "$new_key" "" /sidless sx done "" $NOW_MS)"
  sleep 2.6
  if grep -qE 'hl=\[2\]' "$sandbox/log-render"; then
    pass "case04: sid-less highlight followed cwd across key change"
  else
    fail_msg "case04: sid-less highlight followed cwd across key change" \
      "$(hls_in_log "$sandbox/log-render")"
  fi
  stop_feeder
  wait_board 3
}

# --- 4. Bare ESC, SPACE, TAB, backslash are ignored; SPACE/TAB never become Enter. ---
test_garbage_keys_ignored_no_enter() {
  local sandbox="$ROOT/case04_garbage_keys"
  mkdir -p "$sandbox"
  local k1; k1=$(key_for "/gk")
  write_cache "$sandbox/.fake-model.json" \
    "$(mk_row v2 "$k1" sGK /gk sx done "" $NOW_MS)"
  launch_board_async "$sandbox" "$FAKES/model.sh" "$FAKES/renderer.sh"
  feed_close "$BOARD_FIFO" "$(printf '\e \t\\\\dq\n')" 1.5
  wait_board 7
  assert_eq "case04: board exited 0 on EOF" "0" "$?"
  # 1) Last hl event should be 1 (initial anchor). Anything else (including
  # empty) means a garbage key moved the highlight.
  local last_hl; last_hl="$(grep -oE 'hl=\[[^]]*\]' "$sandbox/log-render" | tail -1)"
  if [[ "$last_hl" == "hl=[1]" ]]; then
    pass "case04: HL stayed at 1 after garbage keys (last hl event: $last_hl)"
  else
    fail_msg "case04: HL stayed at 1 after garbage keys (last hl event: $last_hl)" \
      "expected hl=[1]; ESC/SPACE/TAB/backslash/d/q all ignored"
  fi
  # 2) No navigation occurred to rows 2 or 3.
  if ! grep -qE 'hl=\[[23]\]' "$sandbox/log-render"; then
    pass "case04: never navigated to rows 2 or 3"
  else
    fail_msg "case04: never navigated to rows 2 or 3" \
      "$(hls_in_log "$sandbox/log-render")"
  fi
}

# --- 5. EOF exits 0 instead of busy-spinning. ---
test_eof_exits_zero() {
  local sandbox="$ROOT/case05_eof"
  mkdir -p "$sandbox"
  local k1; k1=$(key_for "/eof")
  write_cache "$sandbox/.fake-model.json" \
    "$(mk_row v2 "$k1" sEOF /eof sx done "" $NOW_MS)"
  launch_board_async "$sandbox" "$FAKES/model.sh" "$FAKES/renderer.sh"
  # Open the FIFO briefly then close → board sees EOF immediately.
  exec 9>"$BOARD_FIFO"
  exec 9>&-
  wait_board 5
  assert_eq "case05: board exited cleanly on EOF (rc=0)" "0" "$?"
}

# --- 6. Deadline tick still runs under sustained key input. ---
test_deadline_tick_under_sustained_keys() {
  local sandbox="$ROOT/case06_deadline"
  mkdir -p "$sandbox"
  local k1; k1=$(key_for "/dl")
  write_cache "$sandbox/.fake-model.json" \
    "$(mk_row v2 "$k1" sDL /dl sx done "" $NOW_MS)"
  launch_board_async "$sandbox" "$FAKES/model.sh" "$FAKES/renderer.sh"
  # Long-lived feeder: write 'j' every 0.2s for ~3s. INTERVAL=1 means
  # the deadline-driven refresh must still fire even though `read`
  # returns immediately on every key (rc==0).
  feed_forever "$BOARD_FIFO" \
    'j' 0.2 'j' 0.2 'j' 0.2 'j' 0.2 'j' 0.2 'j' 0.2 \
    'j' 0.2 'j' 0.2 'j' 0.2 'j' 0.2 'j' 0.2 'j' 0.2
  sleep 2.5
  stop_feeder
  wait_board 5
  local model_calls
  model_calls="$(grep -cE '^model ok' "$sandbox/log-model" 2>/dev/null || true)"
  if (( model_calls >= 3 )); then
    pass "case06: model ran ≥3 times under sustained keystrokes (got $model_calls)"
  else
    fail_msg "case06: model ran ≥3 times under sustained keystrokes" "got=$model_calls"
  fi
}

# --- 7. Model failure keeps prior cache/frame. ---
test_model_failure_preserves_prior_cache() {
  local sandbox="$ROOT/case07_model_fail"
  mkdir -p "$sandbox"
  local k1; k1=$(key_for "/mf")
  write_cache "$sandbox/.fake-model.json" \
    "$(mk_row v2 "$k1" sMF /mf sx done "" $NOW_MS)"
  # Pre-load the cache the failing model must NOT overwrite.
  cp "$sandbox/.fake-model.json" "$sandbox/.board-cache.json"
  local preloaded_bytes; preloaded_bytes="$(cat "$sandbox/.board-cache.json")"
  launch_board_async "$sandbox" "$FAKES/model-fail.sh" "$FAKES/renderer.sh"
  # Hold stdin open indefinitely (just sleep 60s; we'll KILL before then).
  (
    exec 9>"$BOARD_FIFO"
    sleep 30
  ) &
  FEEDER_PID=$!
  sleep 2.2
  # SIGKILL the board (skip EXIT trap, keep cache on disk for inspection).
  kill -KILL "$BOARD_PID" 2>/dev/null || true
  kill "$FEEDER_PID" 2>/dev/null || true
  wait "$BOARD_PID" 2>/dev/null || true
  wait "$FEEDER_PID" 2>/dev/null || true
  # 1) Model was called and failed at least twice.
  local fail_count
  fail_count="$(grep -cE '^model FAIL' "$sandbox/log-model" 2>/dev/null || true)"
  if (( fail_count >= 2 )); then
    pass "case07: model was called and failed ≥2 times (got $fail_count)"
  else
    fail_msg "case07: model was called and failed ≥2 times" "got=$fail_count"
  fi
  # 2) Cache file must STILL hold the preloaded bytes (model didn't
  #    overwrite) — bytes-identical, byte-for-byte.
  if [ -f "$sandbox/.board-cache.json" ]; then
    assert_eq "case07: cache bytes preserved across model failures" \
      "$preloaded_bytes" "$(cat "$sandbox/.board-cache.json")"
  else
    fail_msg "case07: cache bytes preserved across model failures" \
      "cache file absent (EXIT trap shouldn't have run on SIGKILL)"
  fi
  # 3) No renderer repaints on FAIL ticks (the board only repaints on
  #    SUCCESSFUL refreshes — model failure must NOT trigger repaint).
  local renders
  renders="$(grep -cE '^render hl=' "$sandbox/log-render" 2>/dev/null || true)"
  if (( renders <= fail_count )); then
    pass "case07: renderer log not bloated by failures (renders=$renders, fails=$fail_count)"
  else
    fail_msg "case07: renderer log not bloated by failures" \
      "renders=$renders > fails=$fail_count"
  fi
}

# --- 8. WINCH-interrupted read becomes repaint tick. ---
test_winch_repaint() {
  local sandbox="$ROOT/case08_winch"
  mkdir -p "$sandbox"
  local k1; k1=$(key_for "/winch")
  write_cache "$sandbox/.fake-model.json" \
    "$(mk_row v2 "$k1" sW /winch sx done "" $NOW_MS)"
  launch_board_async "$sandbox" "$FAKES/model.sh" "$FAKES/renderer.sh"
  # Hold stdin open long enough to interact (send WINCH).
  feed_forever "$BOARD_FIFO"
  # Wait for first render recorded.
  if ! wait_first_render "$sandbox/log-render" 3; then
    fail_msg "case08: pre-WINCH first render recorded" "no first render"
    stop_feeder; wait_board 6; return 0
  fi
  pass "case08: pre-WINCH first render recorded"
  # Snapshot model-log size.
  local before_models
  before_models="$(wc -l < "$sandbox/log-model" 2>/dev/null | tr -d ' ')"
  # Send WINCH while board is in `read`. The trap fires `printf "\e[2J"`
  # and the in-flight `read` returns >128, which the board treats as
  # a refresh+repaint tick.
  kill -WINCH "$BOARD_PID"
  sleep 1.2
  local after_models
  after_models="$(wc -l < "$sandbox/log-model" 2>/dev/null | tr -d ' ')"
  if (( after_models > before_models )); then
    pass "case08: model log grew after WINCH (refresh+repaint fired) (before=$before_models after=$after_models)"
  else
    fail_msg "case08: model log grew after WINCH (refresh+repaint fired)" \
      "before=$before_models after=$after_models"
  fi
  # New renders observed post-WINCH.
  local renders_total; renders_total="$(wc -l < "$sandbox/log-render" 2>/dev/null | tr -d ' ')"
  if (( renders_total >= 2 )); then
    pass "case08: ≥2 renders observed (one pre-WINCH, one post-WINCH) (count=$renders_total)"
  else
    fail_msg "case08: ≥2 renders observed (one pre-WINCH, one post-WINCH)" "got $renders_total"
  fi
  stop_feeder
  wait_board 6
}

# --- 9. Exit removes .board-cache.json and .board-linemap.tsv. ---
test_exit_cleans_state_files() {
  local sandbox="$ROOT/case09_cleanup"
  mkdir -p "$sandbox"
  local k1; k1=$(key_for "/clean")
  write_cache "$sandbox/.fake-model.json" \
    "$(mk_row v2 "$k1" sC /clean sx done "" $NOW_MS)"
  launch_board_async "$sandbox" "$FAKES/model.sh" "$FAKES/renderer.sh"
  feed_close "$BOARD_FIFO" "" 1.2
  wait_board 5
  assert_eq "case09: board exited cleanly" "0" "$?"
  if [ ! -f "$sandbox/.board-cache.json" ]; then
    pass "case09: EXIT trap removed .board-cache.json"
  else
    fail_msg "case09: EXIT trap removed .board-cache.json" "still present after exit"
  fi
  if [ ! -f "$sandbox/.board-linemap.tsv" ]; then
    pass "case09: EXIT trap removed .board-linemap.tsv"
  else
    fail_msg "case09: EXIT trap removed .board-linemap.tsv" "still present after exit"
  fi
}

# --- 10. Non-TTY input tolerates failed stty calls. ---
test_non_tty_stty_tolerated() {
  local sandbox="$ROOT/case10_stty"
  mkdir -p "$sandbox"
  local k1; k1=$(key_for "/stty")
  local k2; k2=$(key_for "/stty2")
  write_cache "$sandbox/.fake-model.json" \
    "$(mk_row v2 "$k1" sS1 /stty sx done "" $NOW_MS)" \
    "$(mk_row v2 "$k2" sS2 /stty2 sx done "" $NOW_MS)"
  launch_board_async "$sandbox" "$FAKES/model.sh" "$FAKES/renderer.sh"
  feed_close "$BOARD_FIFO" "$(printf '\e[B')" 1.5
  wait_board 6
  assert_eq "case10: board exited 0 on non-TTY stdin" "0" "$?"
  # stderr must not contain "unbound variable" or kill noise from the
  # failed stty call.
  if grep -qiE 'unbound|stty:|set -u' "$sandbox/stderr" 2>/dev/null; then
    fail_msg "case10: stderr is quiet about stty failure" "$(cat "$sandbox/stderr")"
  else
    pass "case10: stderr is quiet about stty failure"
  fi
  if grep -qE 'hl=\[2\]' "$sandbox/log-render"; then
    pass "case10: non-TTY ESC[B moved highlight to line 2"
  else
    fail_msg "case10: non-TTY ESC[B moved highlight to line 2" \
      "$(hls_in_log "$sandbox/log-render")"
  fi
}

# === run all ===
test_initial_tick_writes_cache_and_renders
test_jk_arrow_navigation_bounds_clamp
test_identity_survives_reorder_and_falls_on_vanish
test_sidless_identity_uses_cwd
test_garbage_keys_ignored_no_enter
test_eof_exits_zero
test_deadline_tick_under_sustained_keys
test_model_failure_preserves_prior_cache
test_winch_repaint
test_exit_cleans_state_files
test_non_tty_stty_tolerated

echo
echo "---"
printf 'PASS: %d  FAIL: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
