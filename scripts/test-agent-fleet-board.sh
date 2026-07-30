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

cat > "$FAKES/model-pause-six.sh" <<'EOF'
#!/usr/bin/env bash
state_dir="${AGENT_FLEET_STATE_DIR:-}"
calls_file="$state_dir/.model-calls"
calls=0
[ -f "$calls_file" ] && calls="$(cat "$calls_file")"
calls=$((calls + 1))
printf '%s\n' "$calls" > "$calls_file"
printf 'model ok ts=%s\n' "$(date +%s%N)" >> "${AGENT_FLEET_TEST_LOG_M:-/dev/null}"
if (( calls == 6 )); then
  while [ ! -f "$state_dir/.release-six" ]; do sleep 0.05; done
fi
cat "$state_dir/.fake-model.json"
EOF
chmod +x "$FAKES/model-pause-six.sh"

# Fake model that succeeds once, then fails on every later invocation.
cat > "$FAKES/model-then-fail.sh" <<'EOF'
#!/usr/bin/env bash
log="${AGENT_FLEET_TEST_LOG_M:-}"
state_dir="${AGENT_FLEET_STATE_DIR:-}"
calls_file="$state_dir/.model-calls"
calls=0
if [ -f "$calls_file" ]; then calls="$(cat "$calls_file")"; fi
calls=$((calls + 1))
printf '%s\n' "$calls" > "$calls_file"
if (( calls == 1 )); then
  [ -n "$log" ] && printf 'model ok ts=%s\n' "$(date +%s%N)" >> "$log"
  cat "$state_dir/.fake-model.json"
else
  [ -n "$log" ] && printf 'model FAIL ts=%s\n' "$(date +%s%N)" >> "$log"
  exit 7
fi
EOF
chmod +x "$FAKES/model-then-fail.sh"

# Fake non-executable Node model.
cat > "$FAKES/model.mjs" <<'EOF'
console.log(JSON.stringify({rows: []}));
EOF


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
done < <(jq -r '.rows[] | select(.suppressed != true) | [(.key // ""), (.sid // ""), (.cwd // "")] | @tsv' < "$cache" 2>/dev/null)
mv -f "$tmp" "$linemap"
printf 'FRAME\n'
EOF
chmod +x "$FAKES/renderer.sh"
cat > "$FAKES/renderer-stderr.sh" <<EOF
#!/usr/bin/env bash
printf 'renderer diagnostic\n' >&2
exec "$FAKES/renderer.sh"
EOF
chmod +x "$FAKES/renderer-stderr.sh"

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
    AGENT_FLEET_DECIDE_ONLY="${CASE_DECIDE_ONLY:-0}" \
    AGENT_FLEET_DECIDE_ACT="${CASE_DECIDE_ACT:-0}" \
    AGENT_FLEET_REFRESH_SECS=1 \
    bash "$BOARD" < "$BOARD_FIFO" > "$sandbox/stdout" 2> "$sandbox/stderr" &
  BOARD_PID=$!
}

decision_lines() { tr '\r' '\n' < "$1/stdout" | grep -oE 'DECISION:[^[:space:]]+([^\r\n]*)?' || true; }

write_model_with_instances() {
  local path="$1" rows="$2" instances="${3:-[]}"
  printf '{"rows":[%s],"instances":%s}' "$rows" "$instances" > "$path"
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

wait_log_count() {
  local log="$1" pattern="$2" target="$3" max="${4:-3}"
  local start=$SECONDS count
  while (( SECONDS - start < max )); do
    count="$(grep -cE "$pattern" "$log" 2>/dev/null || true)"
    if (( count >= target )); then return 0; fi
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
     "$(mk_row v2 "$key" ses_init /init_tick sx "done" "" $NOW_MS)"
  launch_board_async "$sandbox" "$FAKES/model.sh" "$FAKES/renderer.sh"
  feed_forever "$BOARD_FIFO"
  if ! wait_first_render "$sandbox/log-render" 3; then
    fail_msg "case01: initial render recorded" "no first render"
    stop_feeder; wait_board 3; return 0
  fi
  if cmp -s "$sandbox/.fake-model.json" "$sandbox/.board-cache.json"; then
    pass "case01: cache bytes match model output"
  else
    fail_msg "case01: cache bytes match model output" "cache was not written atomically from model output"
  fi
  local leftovers
  local tmp_start=$SECONDS
  while (( SECONDS - tmp_start < 2 )); do
    leftovers="$(compgen -G "$sandbox/.board-cache.json.tmp*" || true)"
    leftovers+="$(compgen -G "$sandbox/.board-linemap.tsv.tmp*" || true)"
    [ -z "$leftovers" ] && break
    sleep 0.05
  done
  if [ -z "$leftovers" ]; then
    pass "case01: no cache or linemap temp files remain after initial tick"
  else
    fail_msg "case01: no cache or linemap temp files remain after initial tick" "$leftovers"
  fi
  stop_feeder
  wait_board 6
  assert_eq "case01: board exited 0" "0" "$?"
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

# --- 2. Non-executable .mjs model runs through node. ---
test_non_executable_node_model_refreshes_cache() {
  local sandbox="$ROOT/case02_node_model"
  mkdir -p "$sandbox"
  launch_board_async "$sandbox" "$FAKES/model.mjs" "$FAKES/renderer.sh"
  feed_forever "$BOARD_FIFO"
  if ! wait_first_render "$sandbox/log-render" 3; then
    fail_msg "case02: non-executable Node model rendered" "no first render"
    stop_feeder; wait_board 3; return 0
  fi
  if [ -f "$sandbox/.board-cache.json" ] && [ "$(cat "$sandbox/.board-cache.json")" = '{"rows":[]}' ]; then
    pass "case02: non-executable .mjs model refreshed cache through node"
  else
    fail_msg "case02: non-executable .mjs model refreshed cache through node" "cache missing or incorrect"
  fi
  stop_feeder
  wait_board 6
}

# --- 3. Renderer stderr is retained in explicit diagnostic log. ---
test_renderer_stderr_is_logged() {
  local sandbox="$ROOT/case03_renderer_log"
  mkdir -p "$sandbox"
  printf '{"rows":[]}' > "$sandbox/.fake-model.json"
  launch_board_async "$sandbox" "$FAKES/model.sh" "$FAKES/renderer-stderr.sh"
  feed_close "$BOARD_FIFO" "" 1.2
  wait_board 6
  if grep -qF 'renderer diagnostic' "$sandbox/.board-render.log" 2>/dev/null; then
    pass "case03: renderer stderr reached diagnostic log"
  else
    fail_msg "case03: renderer stderr reached diagnostic log" "diagnostic log missing line"
  fi
}

# --- 4. Highlight identity with a backslash survives repaint reorder. ---
test_backslash_identity_survives_reorder() {
  local sandbox="$ROOT/case04_backslash_identity"
  mkdir -p "$sandbox"
  local kA; kA=$(key_for "/slash-a")
  local kB; kB=$(key_for "/slash-b")
  local sidB='s\id'
  write_cache "$sandbox/.fake-model.json" \
    "$(mk_row v2 "$kA" sA /slash-a sx "done" "" $NOW_MS)" \
    "$(mk_row v2 "$kB" "$sidB" '/slash\cwd' sx "done" "" $NOW_MS)"
  launch_board_async "$sandbox" "$FAKES/model.sh" "$FAKES/renderer.sh"
  feed_forever "$BOARD_FIFO" j
  sleep 0.3
  if ! grep -qE 'hl=\[2\]' "$sandbox/log-render" 2>/dev/null; then
    fail_msg "case04: backslash row selected before reorder" "$(hls_in_log "$sandbox/log-render")"
    stop_feeder; wait_board 3; return 0
  fi
  write_cache "$sandbox/.fake-model.json" \
    "$(mk_row v2 "$kB" "$sidB" '/slash\cwd' sx "done" "" $NOW_MS)" \
    "$(mk_row v2 "$kA" sA /slash-a sx "done" "" $NOW_MS)"
  sleep 1.2
  if grep -qE 'hl=\[1\]' "$sandbox/log-render"; then
    pass "case04: backslash identity followed row across reorder"
  else
    fail_msg "case04: backslash identity followed row across reorder" \
      "$(hls_in_log "$sandbox/log-render")"
  fi
  stop_feeder
  wait_board 3
}

# --- 5. Every repaint starts at cursor home before renderer output. ---
test_repaint_returns_cursor_home() {
  local sandbox="$ROOT/case02_cursor_home"
  mkdir -p "$sandbox"
  local key; key=$(key_for "/cursor")
  write_cache "$sandbox/.fake-model.json" \
     "$(mk_row v2 "$key" sCursor /cursor sx "done" "" $NOW_MS)"
  launch_board_async "$sandbox" "$FAKES/model.sh" "$FAKES/renderer.sh"
  feed_forever "$BOARD_FIFO" j
  if ! wait_first_render "$sandbox/log-render" 3; then
    fail_msg "case02: initial render recorded" "no first render"
    stop_feeder; wait_board 3; return 0
  fi
  local start=$SECONDS renders=0
  while (( SECONDS - start < 3 )); do
    renders="$(grep -cE '^render hl=' "$sandbox/log-render" 2>/dev/null || true)"
    if (( renders >= 2 )); then break; fi
    sleep 0.05
  done
  stop_feeder
  wait_board 6
  assert_eq "case02: board exited 0" "0" "$?"
  local frames homes
  frames="$(grep -oF 'FRAME' "$sandbox/stdout" 2>/dev/null | wc -l | tr -d ' ')"
  homes="$(grep -oF $'\e[H' "$sandbox/stdout" 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$frames" -ge 2 ] && [ "$homes" = "$frames" ] && grep -qF $'\e[HFRAME' "$sandbox/stdout"; then
    pass "case02: every rendered frame follows cursor-home escape (frames=$frames homes=$homes)"
  else
    fail_msg "case02: every rendered frame follows cursor-home escape" \
      "frames=$frames homes=$homes stdout=$(cat "$sandbox/stdout")"
  fi
}

# --- 6. JSON false is valid input and must replace the cache. ---
test_false_json_updates_cache() {
  local sandbox="$ROOT/case03_false_json"
  mkdir -p "$sandbox"
  printf 'false' > "$sandbox/.fake-model.json"
  launch_board_async "$sandbox" "$FAKES/model.sh" "$FAKES/renderer.sh"
  feed_forever "$BOARD_FIFO"
  if ! wait_first_render "$sandbox/log-render" 3; then
    fail_msg "case03: renderer ran for JSON false" "valid JSON was rejected"
    stop_feeder; wait_board 3; return 0
  fi
  if cmp -s "$sandbox/.fake-model.json" "$sandbox/.board-cache.json"; then
    pass "case03: valid JSON false replaced cache"
  else
    fail_msg "case03: valid JSON false replaced cache" "cache missing or changed"
  fi
  stop_feeder
  wait_board 6
}

# --- 7. JSON null is valid input and must replace the cache. ---
test_null_json_updates_cache() {
  local sandbox="$ROOT/case04_null_json"
  mkdir -p "$sandbox"
  printf 'null' > "$sandbox/.fake-model.json"
  launch_board_async "$sandbox" "$FAKES/model.sh" "$FAKES/renderer.sh"
  feed_forever "$BOARD_FIFO"
  if ! wait_first_render "$sandbox/log-render" 3; then
    fail_msg "case04: renderer ran for JSON null" "valid JSON was rejected"
    stop_feeder; wait_board 3; return 0
  fi
  if cmp -s "$sandbox/.fake-model.json" "$sandbox/.board-cache.json"; then
    pass "case04: valid JSON null replaced cache"
  else
    fail_msg "case04: valid JSON null replaced cache" "cache missing or changed"
  fi
  stop_feeder
  wait_board 6
}

# --- 8. Invalid JSON must leave the prior cache untouched. ---
test_invalid_json_preserves_prior_cache() {
  local sandbox="$ROOT/case05_invalid_json"
  mkdir -p "$sandbox"
  write_cache "$sandbox/.fake-model.json" \
     "$(mk_row v2 "$(key_for "/invalid")" sInvalid /invalid sx "done" "" $NOW_MS)"
  launch_board_async "$sandbox" "$FAKES/model.sh" "$FAKES/renderer.sh"
  feed_forever "$BOARD_FIFO"
  if ! wait_first_render "$sandbox/log-render" 3; then
    fail_msg "case05: valid cache rendered before invalid JSON" "no initial render"
    stop_feeder; wait_board 3; return 0
  fi
  local prior_cache before_models
  prior_cache="$(cat "$sandbox/.board-cache.json")"
  before_models="$(grep -cE '^model ok' "$sandbox/log-model" 2>/dev/null || true)"
  printf '{broken' > "$sandbox/.fake-model.json"
  if ! wait_log_count "$sandbox/log-model" '^model ok' "$((before_models + 1))" 3; then
    fail_msg "case05: invalid JSON refresh attempted" "no model tick after invalid input"
  fi
  if [ -f "$sandbox/.board-cache.json" ] && [ "$prior_cache" = "$(cat "$sandbox/.board-cache.json")" ]; then
    pass "case05: invalid JSON preserved prior cache"
  else
    fail_msg "case05: invalid JSON preserved prior cache" "cache was replaced or removed"
  fi
  stop_feeder
  wait_board 6
}

# --- 9. j / down arrow moves to next mapped row; k / up arrow moves previous; bounds clamp. ---
test_jk_arrow_navigation_bounds_clamp() {
  local sandbox="$ROOT/case02_nav_bounds"
  mkdir -p "$sandbox"
  local k1; k1=$(key_for "/nav1")
  local k2; k2=$(key_for "/nav2")
  local k3; k3=$(key_for "/nav3")
  write_cache "$sandbox/.fake-model.json" \
     "$(mk_row v2 "$k1" s1 /nav1 sx "done" "" $NOW_MS)" \
     "$(mk_row v2 "$k2" s2 /nav2 sx "done" "" $NOW_MS)" \
     "$(mk_row v2 "$k3" s3 /nav3 sx "done" "" $NOW_MS)"
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

# --- 10. Highlight identity survives row reorder; vanished identity falls to same prior index or last row. ---
test_identity_survives_reorder_and_falls_on_vanish() {
  local sandbox="$ROOT/case03_identity_reorder"
  mkdir -p "$sandbox"
  local kA; kA=$(key_for "/reA")
  local kB; kB=$(key_for "/reB")
  local kC; kC=$(key_for "/reC")
  # Initial: A,B,C in that order (line 1=A, 2=B, 3=C).
  write_cache "$sandbox/.fake-model.json" \
     "$(mk_row v2 "$kA" sA /reA sx "done" "" $NOW_MS)" \
     "$(mk_row v2 "$kB" sB /reB sx "done" "" $NOW_MS)" \
     "$(mk_row v2 "$kC" sC /reC sx "done" "" $NOW_MS)"
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
     "$(mk_row v2 "$kB" sB /reB sx "done" "" $NOW_MS)" \
     "$(mk_row v2 "$kA" sA /reA sx "done" "" $NOW_MS)" \
     "$(mk_row v2 "$kC" sC /reC sx "done" "" $NOW_MS)"
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
     "$(mk_row v2 "$kA" sA /reA sx "done" "" $NOW_MS)" \
     "$(mk_row v2 "$kC" sC /reC sx "done" "" $NOW_MS)"
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

# --- 11. Sid-less identity uses cwd even when its model key changes. ---
test_sidless_identity_uses_cwd() {
  local sandbox="$ROOT/case04_sidless_identity"
  mkdir -p "$sandbox"
  local old_key; old_key=$(key_for "/sidless-old")
  local new_key; new_key=$(key_for "/sidless-new")
  local other_key; other_key=$(key_for "/sidless-other")
  write_cache "$sandbox/.fake-model.json" \
     "$(mk_row v1 "$old_key" "" /sidless sx "done" "" $NOW_MS)" \
     "$(mk_row v2 "$other_key" sOther /other sx "done" "" $NOW_MS)"
  launch_board_async "$sandbox" "$FAKES/model.sh" "$FAKES/renderer.sh"
  feed_forever "$BOARD_FIFO"
  if ! wait_first_render "$sandbox/log-render" 3; then
    fail_msg "case04: sid-less identity initial render" "no first render"
    stop_feeder; wait_board 3; return 0
  fi
  write_cache "$sandbox/.fake-model.json" \
     "$(mk_row v2 "$other_key" sOther /other sx "done" "" $NOW_MS)" \
     "$(mk_row v1 "$new_key" "" /sidless sx "done" "" $NOW_MS)"
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

# --- 12. Bare ESC, SPACE, TAB, backslash are ignored; SPACE/TAB never become Enter. ---
test_garbage_keys_ignored_no_enter() {
  local sandbox="$ROOT/case04_garbage_keys"
  mkdir -p "$sandbox"
  local k1; k1=$(key_for "/gk")
  write_cache "$sandbox/.fake-model.json" \
     "$(mk_row v2 "$k1" sGK /gk sx "done" "" $NOW_MS)"
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

# --- 13. EOF exits 0 instead of busy-spinning. ---
test_eof_exits_zero() {
  local sandbox="$ROOT/case05_eof"
  mkdir -p "$sandbox"
  local k1; k1=$(key_for "/eof")
  write_cache "$sandbox/.fake-model.json" \
     "$(mk_row v2 "$k1" sEOF /eof sx "done" "" $NOW_MS)"
  launch_board_async "$sandbox" "$FAKES/model.sh" "$FAKES/renderer.sh"
  # Open the FIFO briefly then close → board sees EOF immediately.
  exec 9>"$BOARD_FIFO"
  exec 9>&-
  wait_board 5
  assert_eq "case05: board exited cleanly on EOF (rc=0)" "0" "$?"
}

# --- 14. Deadline tick still runs under sustained key input. ---
test_deadline_tick_under_sustained_keys() {
  local sandbox="$ROOT/case06_deadline"
  mkdir -p "$sandbox"
  local k1; k1=$(key_for "/dl")
  write_cache "$sandbox/.fake-model.json" \
     "$(mk_row v2 "$k1" sDL /dl sx "done" "" $NOW_MS)"
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

# --- 15. Model failure keeps prior cache/frame. ---
test_model_failure_preserves_prior_cache() {
  local sandbox="$ROOT/case07_model_fail"
  mkdir -p "$sandbox"
  local k1; k1=$(key_for "/mf")
  write_cache "$sandbox/.fake-model.json" \
     "$(mk_row v2 "$k1" sMF /mf sx "done" "" $NOW_MS)"
  launch_board_async "$sandbox" "$FAKES/model-then-fail.sh" "$FAKES/renderer.sh"
  feed_forever "$BOARD_FIFO"
  if ! wait_first_render "$sandbox/log-render" 3; then
    fail_msg "case07: successful frame precedes model failure" "no initial render"
    stop_feeder; kill -KILL "$BOARD_PID" 2>/dev/null || true; wait "$BOARD_PID" 2>/dev/null || true
    return 0
  fi
  local preloaded_bytes; preloaded_bytes="$(cat "$sandbox/.board-cache.json")"
  local renders_before; renders_before="$(grep -cE '^render hl=' "$sandbox/log-render" 2>/dev/null || true)"
  # Change source after the successful frame; subsequent model calls fail.
  write_cache "$sandbox/.fake-model.json" \
    "$(mk_row v2 "$k1" sMF /mf sx needs-attention permission $NOW_MS)"
  if ! wait_log_count "$sandbox/log-model" '^model FAIL' 2 5; then
    fail_msg "case07: model was called and failed ≥2 times" \
      "timed out waiting for 2 failures"
  fi
  # SIGKILL the board (skip EXIT trap, keep cache on disk for inspection).
  kill -KILL "$BOARD_PID" 2>/dev/null || true
  stop_feeder
  wait "$BOARD_PID" 2>/dev/null || true
  local fail_count
  fail_count="$(grep -cE '^model FAIL' "$sandbox/log-model" 2>/dev/null || true)"
  if (( fail_count >= 2 )); then
    pass "case07: model was called and failed ≥2 times (got $fail_count)"
  else
    fail_msg "case07: model was called and failed ≥2 times" "got=$fail_count"
  fi
  if [ -f "$sandbox/.board-cache.json" ]; then
    assert_eq "case07: cache bytes preserved across model failures" \
      "$preloaded_bytes" "$(cat "$sandbox/.board-cache.json")"
  else
    fail_msg "case07: cache bytes preserved across model failures" \
      "cache file absent (EXIT trap shouldn't have run on SIGKILL)"
  fi
  local renders_after
  renders_after="$(grep -cE '^render hl=' "$sandbox/log-render" 2>/dev/null || true)"
  if [ "$renders_after" = "$renders_before" ]; then
    pass "case07: prior rendered frame preserved on failed refresh (renders=$renders_after)"
  else
    fail_msg "case07: prior rendered frame preserved on failed refresh" \
      "before=$renders_before after=$renders_after"
  fi
}

# --- 16. WINCH-interrupted read becomes repaint tick. ---
test_winch_repaint() {
  local sandbox="$ROOT/case08_winch"
  mkdir -p "$sandbox"
  local k1; k1=$(key_for "/winch")
  write_cache "$sandbox/.fake-model.json" \
     "$(mk_row v2 "$k1" sW /winch sx "done" "" $NOW_MS)"
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

# --- 17. Exit removes .board-cache.json and .board-linemap.tsv. ---
test_exit_cleans_state_files() {
  local sandbox="$ROOT/case09_cleanup"
  mkdir -p "$sandbox"
  local k1; k1=$(key_for "/clean")
  write_cache "$sandbox/.fake-model.json" \
     "$(mk_row v2 "$k1" sC /clean sx "done" "" $NOW_MS)"
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

# --- 18. Non-TTY input tolerates failed stty calls. ---
test_non_tty_stty_tolerated() {
  local sandbox="$ROOT/case10_stty"
  mkdir -p "$sandbox"
  local k1; k1=$(key_for "/stty")
  local k2; k2=$(key_for "/stty2")
  write_cache "$sandbox/.fake-model.json" \
     "$(mk_row v2 "$k1" sS1 /stty sx "done" "" $NOW_MS)" \
     "$(mk_row v2 "$k2" sS2 /stty2 sx "done" "" $NOW_MS)"
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

# === Task 9: board actions ===
test_enter_sid_emits_select_decision_without_persistence() {
  local sandbox="$ROOT/case11_enter_select" key; mkdir -p "$sandbox"
  key=$(key_for "/enter")
  local row; row=$(mk_row v2 "$key" sid-enter /enter sess done "" $NOW_MS)
  write_model_with_instances "$sandbox/.fake-model.json" "$row" '[{"selectedSid":"sid-old","selectedTs":1}]'
  CASE_DECIDE_ONLY=1; launch_board_async "$sandbox" "$FAKES/model.sh" "$FAKES/renderer.sh"; feed_close "$BOARD_FIFO" $'\n' 1.2; wait_board 6; CASE_DECIDE_ONLY=0
  if grep -qF "DECISION:kind=select" "$sandbox/stdout" && [ ! -f "$sandbox/traverse-stack.json" ] && [ ! -f "$sandbox/${key}.select" ]; then
    pass "case11: Enter sid row selects without persistence"
  else fail_msg "case11: Enter sid row selects without persistence" "$(cat "$sandbox/stdout")"; fi
}

test_enter_sid_decide_act_persists_stack_and_mailbox() {
  local sandbox="$ROOT/case18_enter_act" key; mkdir -p "$sandbox"; key=$(key_for "/enter-act")
  local row; row=$(mk_row v2 "$key" sid-act /enter-act sess done "" $NOW_MS)
  write_model_with_instances "$sandbox/.fake-model.json" "$row" '[{"selectedSid":"sid-old","selectedTs":1}]'
  printf '%s\n' '{"v":1,"current":{"sid":"sid-old","ts":1},"back":[],"forward":[]}' > "$sandbox/traverse-stack.json"
  CASE_DECIDE_ACT=1; launch_board_async "$sandbox" "$FAKES/model.sh" "$FAKES/renderer.sh"; feed_close "$BOARD_FIFO" $'\n' 1.2; wait_board 6; CASE_DECIDE_ACT=0
  if [ "$(jq -r '.current.sid' "$sandbox/traverse-stack.json" 2>/dev/null)" = sid-act ] && [ "$(jq -r '.sessionID' "$sandbox/${key}.select" 2>/dev/null)" = sid-act ]; then pass "case18: Enter sid row persists stack and mailbox"; else fail_msg "case18: Enter sid row persists stack and mailbox"; fi
}

test_enter_sid_decide_act_matches_navigation_mutation() {
  local sandbox="$ROOT/case19_enter_parity" key; mkdir -p "$sandbox"; key=$(key_for "/enter-parity")
  local row; row=$(mk_row v2 "$key" sid-target /enter-parity sess done "" $NOW_MS)
  write_model_with_instances "$sandbox/.fake-model.json" "$row" '[{"selectedSid":"sid-p","selectedTs":200}]'
  printf '%s\n' '{"v":1,"current":{"sid":"sid-current","ts":1},"back":["sid-target","sid-old","sid-target"],"forward":["sid-target","sid-forward"]}' > "$sandbox/traverse-stack.json"
  CASE_DECIDE_ACT=1; launch_board_async "$sandbox" "$FAKES/model.sh" "$FAKES/renderer.sh"; feed_close "$BOARD_FIFO" $'\n' 1.2; wait_board 6; CASE_DECIDE_ACT=0
  if jq -e --arg sid sid-target --arg old sid-current --arg p sid-p '
      .current.sid == $sid and (.forward | length == 0) and
      (.back | index($sid) == null) and (.back | index($old) != null) and
      (.back | index($p) != null)' "$sandbox/traverse-stack.json" >/dev/null 2>&1 &&
      [ "$(jq -r '.sessionID' "$sandbox/${key}.select" 2>/dev/null)" = sid-target ]; then
    pass "case19: Enter mutation matches navigation and writes mailbox"
  else fail_msg "case19: Enter mutation matches navigation and writes mailbox"; fi
}

test_enter_sidless_focus_only() {
  local sandbox="$ROOT/case12_enter_sidless" key; mkdir -p "$sandbox"; key=$(key_for "/idle")
  local row; row=$(mk_row v1 "$key" "" /idle sess idle "" $NOW_MS)
  write_model_with_instances "$sandbox/.fake-model.json" "$row"
  CASE_DECIDE_ONLY=1; launch_board_async "$sandbox" "$FAKES/model.sh" "$FAKES/renderer.sh"; feed_close "$BOARD_FIFO" $'\n' 1.2; wait_board 6; CASE_DECIDE_ONLY=0
  if grep -qF "DECISION:kind=focus-only" "$sandbox/stdout" && ! grep -qF 'DECISION:kind=select' "$sandbox/stdout"; then pass "case12: Enter sid-less row focuses only"; else fail_msg "case12: Enter sid-less row focuses only"; fi
}

test_enter_sidless_idle_focus_only() {
  local sandbox="$ROOT/case20_enter_idle" key; mkdir -p "$sandbox"; key=$(key_for "/idle-enter")
  local row; row=$(mk_row idle "$key" "" /idle-enter sess idle "" $NOW_MS)
  write_model_with_instances "$sandbox/.fake-model.json" "$row"
  CASE_DECIDE_ACT=1; launch_board_async "$sandbox" "$FAKES/model.sh" "$FAKES/renderer.sh"; feed_close "$BOARD_FIFO" $'\n' 1.2; wait_board 6; CASE_DECIDE_ACT=0
  if grep -qF 'DECISION:kind=focus-only' "$sandbox/stdout" && [ ! -f "$sandbox/traverse-stack.json" ] && ! compgen -G "$sandbox/*.select" >/dev/null; then pass "case20: Enter idle sid-less row focuses only"; else fail_msg "case20: Enter idle sid-less row focuses only"; fi
}

test_enter_sidless_synthetic_focus_only() {
  local sandbox="$ROOT/case21_enter_synthetic" key; mkdir -p "$sandbox"; key=$(key_for "/synthetic-enter")
  local row; row=$(mk_row synthetic "$key" "" /synthetic-enter sess unknown "" $NOW_MS)
  write_model_with_instances "$sandbox/.fake-model.json" "$row"
  CASE_DECIDE_ACT=1; launch_board_async "$sandbox" "$FAKES/model.sh" "$FAKES/renderer.sh"; feed_close "$BOARD_FIFO" $'\n' 1.2; wait_board 6; CASE_DECIDE_ACT=0
  if grep -qF 'DECISION:kind=focus-only' "$sandbox/stdout" && [ ! -f "$sandbox/traverse-stack.json" ] && ! compgen -G "$sandbox/*.select" >/dev/null; then pass "case21: Enter synthetic sid-less row focuses only"; else fail_msg "case21: Enter synthetic sid-less row focuses only"; fi
}

test_enter_vanished_row_noops_without_replacement_landing() {
  local sandbox="$ROOT/case22_enter_vanished" key_a key_b; mkdir -p "$sandbox"; key_a=$(key_for "/vanish-a"); key_b=$(key_for "/vanish-b")
  local row_a row_b; row_a=$(mk_row v2 "$key_a" sid-a /vanish-a sess done "" $NOW_MS); row_b=$(mk_row v2 "$key_b" sid-b /vanish-b sess done "" $NOW_MS)
  write_model_with_instances "$sandbox/.fake-model.json" "$row_a,$row_b"
  CASE_DECIDE_ONLY=1; launch_board_async "$sandbox" "$FAKES/model.sh" "$FAKES/renderer.sh"; feed_forever "$BOARD_FIFO" j
  if ! wait_log_count "$sandbox/log-render" 'render hl=\[2\]' 1 3; then stop_feeder; wait_board 3; fail_msg "case22: highlight moved to vanished row"; CASE_DECIDE_ONLY=0; return; fi
  write_model_with_instances "$sandbox/.fake-model.json" "$row_a"
  printf '\n' > "$BOARD_FIFO"; sleep 0.4; stop_feeder; wait_board 6; CASE_DECIDE_ONLY=0
  if grep -qF 'DECISION:kind=noop' "$sandbox/stdout" && ! grep -qF 'sid=sid-a' "$sandbox/stdout" && ! compgen -G "$sandbox/*.select" >/dev/null; then pass "case22: vanished Enter noops without replacement landing"; else fail_msg "case22: vanished Enter noops without replacement landing" "$(cat "$sandbox/stdout")"; fi
}

test_enter_refinds_reordered_identity() {
  local sandbox="$ROOT/case23_enter_reorder" key_a key_b; mkdir -p "$sandbox"; key_a=$(key_for "/order-a"); key_b=$(key_for "/order-b")
  local row_a row_b; row_a=$(mk_row v2 "$key_a" sid-a /order-a sess done "" $NOW_MS); row_b=$(mk_row v2 "$key_b" sid-b /order-b sess done "" $NOW_MS)
  write_model_with_instances "$sandbox/.fake-model.json" "$row_a,$row_b"
  CASE_DECIDE_ONLY=1; launch_board_async "$sandbox" "$FAKES/model.sh" "$FAKES/renderer.sh"; feed_forever "$BOARD_FIFO" j
  if ! wait_log_count "$sandbox/log-render" 'render hl=\[2\]' 1 3; then stop_feeder; wait_board 3; fail_msg "case23: highlight moved before reorder"; CASE_DECIDE_ONLY=0; return; fi
  write_model_with_instances "$sandbox/.fake-model.json" "$row_b,$row_a"
  printf '\n' > "$BOARD_FIFO"; sleep 0.4; stop_feeder; wait_board 6; CASE_DECIDE_ONLY=0
  if grep -qF 'DECISION:kind=select' "$sandbox/stdout" && grep -qF 'sid=sid-b' "$sandbox/stdout" && ! grep -qF 'sid=sid-a' "$sandbox/stdout"; then pass "case23: Enter refinds reordered identity"; else fail_msg "case23: Enter refinds reordered identity" "$(cat "$sandbox/stdout")"; fi
}

test_enter_reruns_model_immediately() {
  local sandbox="$ROOT/case24_enter_refresh" key; mkdir -p "$sandbox"; key=$(key_for "/refresh-enter")
  local row; row=$(mk_row v2 "$key" sid-refresh /refresh-enter sess done "" $NOW_MS)
  write_model_with_instances "$sandbox/.fake-model.json" "$row"
  CASE_DECIDE_ONLY=1; launch_board_async "$sandbox" "$FAKES/model.sh" "$FAKES/renderer.sh"; feed_forever "$BOARD_FIFO"
  if ! wait_log_count "$sandbox/log-model" '^model ok' 1 3; then stop_feeder; wait_board 3; fail_msg "case24: initial model call"; CASE_DECIDE_ONLY=0; return; fi
  printf '\n' > "$BOARD_FIFO"
  if wait_log_count "$sandbox/log-model" '^model ok' 2 2; then pass "case24: Enter reruns model before landing"; else fail_msg "case24: Enter reruns model before landing"; fi
  stop_feeder; wait_board 6; CASE_DECIDE_ONLY=0
}

test_enter_duplicate_and_vanished_are_noop() {
  local sandbox="$ROOT/case13_enter_noop" key; mkdir -p "$sandbox"; key=$(key_for "/dup")
  local row; row=$(mk_row warning "" "" /dup sess duplicate duplicate $NOW_MS)
  write_model_with_instances "$sandbox/.fake-model.json" "$row"
  CASE_DECIDE_ONLY=1; launch_board_async "$sandbox" "$FAKES/model.sh" "$FAKES/renderer.sh"; feed_close "$BOARD_FIFO" $'\n' 1.2; wait_board 6; CASE_DECIDE_ONLY=0
  if grep -qF 'DECISION:kind=noop' "$sandbox/stdout" && ! grep -qF 'DECISION:kind=focus-only' "$sandbox/stdout"; then pass "case13: Enter duplicate row noops"; else fail_msg "case13: Enter duplicate row noops"; fi
}

test_board_keys_do_not_reconcile_and_space_tab_do_not_enter() {
  local sandbox="$ROOT/case14_board_keys" key; mkdir -p "$sandbox"; key=$(key_for "/keys")
  local row; row=$(mk_row v2 "$key" sid-keys /keys sess done "" $NOW_MS)
  write_model_with_instances "$sandbox/.fake-model.json" "$row" '[{"selectedSid":"sid-old","selectedTs":1}]'
  CASE_DECIDE_ONLY=1; launch_board_async "$sandbox" "$FAKES/model.sh" "$FAKES/renderer.sh"; feed_close "$BOARD_FIFO" $'jk\e[A\e[B \t' 1.2; wait_board 6; CASE_DECIDE_ONLY=0
  if ! grep -qF 'DECISION:kind=' "$sandbox/stdout" && [ ! -f "$sandbox/traverse-stack.json" ]; then pass "case14: navigation and space/tab do not act"; else fail_msg "case14: navigation and space/tab do not act" "$(cat "$sandbox/stdout")"; fi
}

test_dismiss_done_writes_mark_only_and_hides() {
  local sandbox="$ROOT/case15_dismiss" key; mkdir -p "$sandbox"; key=$(key_for "/dismiss")
  local row; row=$(mk_row v2 "$key" sid-dismiss /dismiss sess done "" $NOW_MS)
  write_model_with_instances "$sandbox/.fake-model.json" "$row"
  CASE_DECIDE_ACT=1; launch_board_async "$sandbox" "$FAKES/model.sh" "$FAKES/renderer.sh"; feed_close "$BOARD_FIFO" d 1.2; wait_board 6; CASE_DECIDE_ACT=0
  if [ "$(jq -c . "$sandbox/${key}.select" 2>/dev/null)" = '{"sessionID":"sid-dismiss","markOnly":true}' ]; then pass "case15: d writes mark-only mailbox"; else fail_msg "case15: d writes mark-only mailbox" "$(cat "$sandbox/stdout")"; fi
}

test_dismiss_needs_attention_writes_mark_only() {
  local sandbox="$ROOT/case25_dismiss_attention" key; mkdir -p "$sandbox"; key=$(key_for "/attention")
  local row; row=$(mk_row v2 "$key" sid-attention /attention sess needs-attention reason $NOW_MS)
  write_model_with_instances "$sandbox/.fake-model.json" "$row"
  CASE_DECIDE_ACT=1; launch_board_async "$sandbox" "$FAKES/model.sh" "$FAKES/renderer.sh"; feed_close "$BOARD_FIFO" d 1.2; wait_board 6; CASE_DECIDE_ACT=0
  if [ "$(jq -c . "$sandbox/${key}.select" 2>/dev/null)" = '{"sessionID":"sid-attention","markOnly":true}' ]; then pass "case25: d needs-attention writes mark-only mailbox"; else fail_msg "case25: d needs-attention writes mark-only mailbox"; fi
}

test_dismiss_idle_is_noop() {
  local sandbox="$ROOT/case26_dismiss_idle" key; mkdir -p "$sandbox"; key=$(key_for "/dismiss-idle")
  local row; row=$(mk_row idle "$key" "" /dismiss-idle sess idle "" $NOW_MS); write_model_with_instances "$sandbox/.fake-model.json" "$row"
  CASE_DECIDE_ONLY=1; launch_board_async "$sandbox" "$FAKES/model.sh" "$FAKES/renderer.sh"; feed_close "$BOARD_FIFO" d 1.2; wait_board 6; CASE_DECIDE_ONLY=0
  if grep -qF 'DECISION:kind=noop' "$sandbox/stdout" && ! compgen -G "$sandbox/*.select" >/dev/null && ! grep -qF 'DECISION:hidden='"$key" "$sandbox/stdout"; then pass "case26: d idle row noops"; else fail_msg "case26: d idle row noops"; fi
}

test_dismiss_v1_sidless_is_noop() {
  local sandbox="$ROOT/case27_dismiss_v1" key; mkdir -p "$sandbox"; key=$(key_for "/dismiss-v1")
  local row; row=$(mk_row v1 "$key" "" /dismiss-v1 sess done "" $NOW_MS); write_model_with_instances "$sandbox/.fake-model.json" "$row"
  CASE_DECIDE_ONLY=1; launch_board_async "$sandbox" "$FAKES/model.sh" "$FAKES/renderer.sh"; feed_close "$BOARD_FIFO" d 1.2; wait_board 6; CASE_DECIDE_ONLY=0
  if grep -qF 'DECISION:kind=noop' "$sandbox/stdout" && ! compgen -G "$sandbox/*.select" >/dev/null; then pass "case27: d v1 sid-less row noops"; else fail_msg "case27: d v1 sid-less row noops"; fi
}

test_dismiss_synthetic_is_noop() {
  local sandbox="$ROOT/case28_dismiss_synthetic" key; mkdir -p "$sandbox"; key=$(key_for "/dismiss-synthetic")
  local row; row=$(mk_row synthetic "$key" "" /dismiss-synthetic sess unknown "" $NOW_MS); write_model_with_instances "$sandbox/.fake-model.json" "$row"
  CASE_DECIDE_ONLY=1; launch_board_async "$sandbox" "$FAKES/model.sh" "$FAKES/renderer.sh"; feed_close "$BOARD_FIFO" d 1.2; wait_board 6; CASE_DECIDE_ONLY=0
  if grep -qF 'DECISION:kind=noop' "$sandbox/stdout" && ! compgen -G "$sandbox/*.select" >/dev/null; then pass "case28: d synthetic row noops"; else fail_msg "case28: d synthetic row noops"; fi
}

test_dismiss_duplicate_is_noop() {
  local sandbox="$ROOT/case29_dismiss_duplicate"; mkdir -p "$sandbox"
  local row; row=$(mk_row warning "" "" /dismiss-duplicate sess duplicate duplicate $NOW_MS); write_model_with_instances "$sandbox/.fake-model.json" "$row"
  CASE_DECIDE_ONLY=1; launch_board_async "$sandbox" "$FAKES/model.sh" "$FAKES/renderer.sh"; feed_close "$BOARD_FIFO" d 1.2; wait_board 6; CASE_DECIDE_ONLY=0
  if grep -qF 'DECISION:kind=noop' "$sandbox/stdout" && ! compgen -G "$sandbox/*.select" >/dev/null; then pass "case29: d duplicate row noops"; else fail_msg "case29: d duplicate row noops"; fi
}

test_board_internal_keys_do_not_reconcile_with_fresh_p() {
  local sandbox="$ROOT/case30_internal_keys" key; mkdir -p "$sandbox"; key=$(key_for "/internal")
  local row; row=$(mk_row v2 "$key" sid-internal /internal sess done "" $NOW_MS); write_model_with_instances "$sandbox/.fake-model.json" "$row" '[{"selectedSid":"sid-fresh","selectedTs":999}]'
  CASE_DECIDE_ONLY=1; launch_board_async "$sandbox" "$FAKES/model.sh" "$FAKES/renderer.sh"
  feed_forever "$BOARD_FIFO" j 0.1 k 0.1 "$(printf '\e[A')" 0.1 "$(printf '\e[B')" 0.1 "$(printf '\e')" 0.1 d 0.1 q
  wait_board 6; stop_feeder; CASE_DECIDE_ONLY=0
  if [ ! -f "$sandbox/traverse-stack.json" ] && ! grep -qF 'DECISION:kind=select' "$sandbox/stdout"; then pass "case30: board-internal keys never reconcile"; else fail_msg "case30: board-internal keys never reconcile" "$(cat "$sandbox/stdout")"; fi
}

test_hidden_set_confirms_on_suppressed_model_row() {
  local sandbox="$ROOT/case31_hidden_confirm" key; mkdir -p "$sandbox"; key=$(key_for "/confirm")
  local row; row=$(mk_row v2 "$key" sid-confirm /confirm sess done "" $NOW_MS); write_model_with_instances "$sandbox/.fake-model.json" "$row"
  CASE_DECIDE_ONLY=1; launch_board_async "$sandbox" "$FAKES/model.sh" "$FAKES/renderer.sh"; feed_forever "$BOARD_FIFO"
  wait_first_render "$sandbox/log-render" 3; printf d > "$BOARD_FIFO"
  if ! wait_log_count "$sandbox/log-model" '^model ok' 2 3; then stop_feeder; wait_board 3; fail_msg "case31: model refreshed after dismiss"; CASE_DECIDE_ONLY=0; return; fi
  jq '.rows[0].suppressed = true' "$sandbox/.fake-model.json" > "$sandbox/.next-model.json"; mv "$sandbox/.next-model.json" "$sandbox/.fake-model.json"
  wait_log_count "$sandbox/log-model" '^model ok' 3 3
  printf ' ' > "$BOARD_FIFO"; sleep 0.4
  local confirmed_cache=0 confirmed_map=0
  [ "$(jq -r '.rows[0].suppressed' "$sandbox/.board-cache.json" 2>/dev/null)" = true ] && confirmed_cache=1
  ! grep -qF sid-confirm "$sandbox/.board-linemap.tsv" 2>/dev/null && confirmed_map=1
  stop_feeder; wait_board 6; CASE_DECIDE_ONLY=0
  if grep -qF 'DECISION:hidden=sid-confirm' "$sandbox/stdout" && grep -qF 'DECISION:hidden=' "$sandbox/stdout" && ! grep -qF 'DECISION:hidden=sid-confirm' <(tail -n 1 "$sandbox/stdout") &&
       (( confirmed_cache == 1 && confirmed_map == 1 )); then
    pass "case31: suppressed row confirms and clears hide"
  else fail_msg "case31: suppressed row confirms and clears hide" "$(cat "$sandbox/stdout")" "cache=$(cat "$sandbox/.board-cache.json" 2>/dev/null || true)" "linemap=$(cat "$sandbox/.board-linemap.tsv" 2>/dev/null || true)" "confirmed_cache=$confirmed_cache confirmed_map=$confirmed_map"; fi
}

test_hidden_set_expires_on_exact_fifth_refresh_tick() {
  local sandbox="$ROOT/case32_hidden_precision" key; mkdir -p "$sandbox"; key=$(key_for "/precision")
  local row; row=$(mk_row v2 "$key" sid-precision /precision sess done "" $NOW_MS); write_model_with_instances "$sandbox/.fake-model.json" "$row"
  CASE_DECIDE_ONLY=1; launch_board_async "$sandbox" "$FAKES/model-pause-six.sh" "$FAKES/renderer.sh"; feed_forever "$BOARD_FIFO"
  wait_first_render "$sandbox/log-render" 3; printf d > "$BOARD_FIFO"; wait_log_count "$sandbox/log-model" '^model ok' 2 3
  wait_log_count "$sandbox/log-model" '^model ok' 5 6
  local absent=0 present=0
  if ! jq -e --arg sid sid-precision '.rows[]? | select(.sid == $sid)' "$sandbox/.board-cache.json" >/dev/null 2>&1; then absent=1; fi
  : > "$sandbox/.release-six"
  wait_log_count "$sandbox/log-model" '^model ok' 6 3
  wait_log_count "$sandbox/log-render" '^render hl=' 6 3
  if jq -e --arg sid sid-precision '.rows[]? | select(.sid == $sid)' "$sandbox/.board-cache.json" >/dev/null 2>&1; then present=1; fi
  stop_feeder; wait_board 6; CASE_DECIDE_ONLY=0
  if (( absent == 1 && present == 1 )); then pass "case32: unconfirmed hide returns on fifth refresh tick"; else fail_msg "case32: unconfirmed hide returns on fifth refresh tick"; fi
}

test_hidden_set_expires_when_sensor_never_suppresses() {
  local sandbox="$ROOT/case33_hidden_failure_safety" key; mkdir -p "$sandbox"; key=$(key_for "/failure-safety")
  local row; row=$(mk_row v2 "$key" sid-safety /failure-safety sess done "" $NOW_MS); write_model_with_instances "$sandbox/.fake-model.json" "$row"
  CASE_DECIDE_ONLY=1; launch_board_async "$sandbox" "$FAKES/model.sh" "$FAKES/renderer.sh"; feed_forever "$BOARD_FIFO"
  wait_first_render "$sandbox/log-render" 3; printf d > "$BOARD_FIFO"; wait_log_count "$sandbox/log-model" '^model ok' 6 8
  wait_log_count "$sandbox/log-render" '^render hl=' 6 3
  if jq -e --arg sid sid-safety '.rows[]? | select(.sid == $sid)' "$sandbox/.board-cache.json" >/dev/null 2>&1; then pass "case33: sensor without suppression cannot hide permanently"; else fail_msg "case33: sensor without suppression cannot hide permanently"; fi
  stop_feeder; wait_board 6; CASE_DECIDE_ONLY=0
}

test_decision_hidden_emits_each_processed_key_and_transitions() {
  local sandbox="$ROOT/case34_hidden_decisions" key; mkdir -p "$sandbox"; key=$(key_for "/hidden-decisions")
  local row; row=$(mk_row v2 "$key" sid-decisions /hidden-decisions sess done "" $NOW_MS); write_model_with_instances "$sandbox/.fake-model.json" "$row"
  CASE_DECIDE_ONLY=1; launch_board_async "$sandbox" "$FAKES/model.sh" "$FAKES/renderer.sh"; feed_close "$BOARD_FIFO" $' jd ' 1.2; wait_board 6; CASE_DECIDE_ONLY=0
  local empty_count contains_count
  empty_count=$(grep -cF 'DECISION:hidden=' "$sandbox/stdout" || true); contains_count=$(grep -cF 'DECISION:hidden=sid-decisions' "$sandbox/stdout" || true)
  if (( empty_count >= 2 && contains_count >= 1 )); then pass "case34: DECISION:hidden tracks every processed key"; else fail_msg "case34: DECISION:hidden tracks every processed key" "$(cat "$sandbox/stdout")"; fi
}

test_dismiss_ineligible_is_noop() {
  local sandbox="$ROOT/case16_dismiss_noop" key; mkdir -p "$sandbox"; key=$(key_for "/working")
  local row; row=$(mk_row v2 "$key" sid-working /working sess working "" $NOW_MS)
  write_model_with_instances "$sandbox/.fake-model.json" "$row"
  CASE_DECIDE_ONLY=1; launch_board_async "$sandbox" "$FAKES/model.sh" "$FAKES/renderer.sh"; feed_close "$BOARD_FIFO" d 1.2; wait_board 6; CASE_DECIDE_ONLY=0
  if grep -qF 'DECISION:kind=noop' "$sandbox/stdout" && ! grep -qF "DECISION:hidden=sid-working" "$sandbox/stdout"; then pass "case16: d working row noops"; else fail_msg "case16: d working row noops" "$(cat "$sandbox/stdout")"; fi
}

test_dismiss_hide_expires_after_five_ticks() {
  local sandbox="$ROOT/case17_dismiss_expiry" key; mkdir -p "$sandbox"; key=$(key_for "/expiry")
  local row; row=$(mk_row v2 "$key" sid-expiry /expiry sess done "" $NOW_MS)
  write_model_with_instances "$sandbox/.fake-model.json" "$row"
  CASE_DECIDE_ONLY=1; launch_board_async "$sandbox" "$FAKES/model.sh" "$FAKES/renderer.sh"; feed_close "$BOARD_FIFO" d 6.3; wait_board 8; CASE_DECIDE_ONLY=0
  if grep -qF 'DECISION:hidden=sid-expiry' "$sandbox/stdout" && grep -qF 'render hl=' "$sandbox/log-render"; then pass "case17: dismiss hide expires after refresh ticks"; else fail_msg "case17: dismiss hide expires after refresh ticks" "$(cat "$sandbox/stdout")"; fi
}

# === run all ===
test_initial_tick_writes_cache_and_renders
test_non_executable_node_model_refreshes_cache
test_renderer_stderr_is_logged
test_backslash_identity_survives_reorder
test_repaint_returns_cursor_home
test_false_json_updates_cache
test_null_json_updates_cache
test_invalid_json_preserves_prior_cache
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
test_enter_sid_emits_select_decision_without_persistence
test_enter_sidless_focus_only
test_enter_sid_decide_act_matches_navigation_mutation
test_enter_sidless_idle_focus_only
test_enter_sidless_synthetic_focus_only
test_enter_vanished_row_noops_without_replacement_landing
test_enter_refinds_reordered_identity
test_enter_reruns_model_immediately
test_enter_sid_decide_act_persists_stack_and_mailbox
test_enter_duplicate_and_vanished_are_noop
test_board_keys_do_not_reconcile_and_space_tab_do_not_enter
test_dismiss_done_writes_mark_only_and_hides
test_dismiss_needs_attention_writes_mark_only
test_dismiss_idle_is_noop
test_dismiss_v1_sidless_is_noop
test_dismiss_synthetic_is_noop
test_dismiss_duplicate_is_noop
test_dismiss_ineligible_is_noop
test_board_internal_keys_do_not_reconcile_with_fresh_p
test_hidden_set_confirms_on_suppressed_model_row
test_hidden_set_expires_on_exact_fifth_refresh_tick
test_hidden_set_expires_when_sensor_never_suppresses
test_decision_hidden_emits_each_processed_key_and_transitions
test_dismiss_hide_expires_after_five_ticks

echo
echo "---"
printf 'PASS: %d  FAIL: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
