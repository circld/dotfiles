#!/usr/bin/env bash
# scripts/test-agent-fleet-render.sh
#
# Hermetic test for agent-fleet-render.sh (Task 6). Drives the script with
# synthetic inputs: live-pane table text + state files + ps comm lookup, so
# no real zellij session or live opencode process is needed. Mirrors the
# injection-seam conventions of test-agent-fleet-jump.sh (same env var names
# AGENT_FLEET_LIVE_PANES_OVERRIDE / AGENT_FLEET_PS_OVERRIDE) so the render
# and jump can never silently disagree about what's live, ambiguous, or
# suppressed.
#
# Run via: bash scripts/test-agent-fleet-render.sh from repo root.
# Self-contained: no real zellij session required.
# Note: deliberately NOT `set -e` — exercises of buggy code paths (junk
# panes, partial JSON) intentionally produce warnings whose very presence
# is the test signal.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RENDER="$REPO_ROOT/scripts/agent-fleet-render.sh"

if [ ! -f "$RENDER" ]; then
  echo "FAIL: render.sh missing at $RENDER"
  exit 1
fi

if (( BASH_VERSINFO[0] < 4 )); then
  echo "FAIL: test-agent-fleet-render.sh needs bash >= 4 (got $BASH_VERSION)"
  exit 1
fi

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1"; }
fail() {
  FAIL=$((FAIL + 1))
  printf 'FAIL: %s\n' "$1"
  shift
  for arg in "$@"; do printf '  %s\n' "$arg"; done
}
assert_eq() {
  local label="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then pass "$label"; else fail "$label" "want:" "$want" "got:" "$got"; fi
}
assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    pass "$label"
  else
    fail "$label" "haystack=" "<see output above>" "expected substring:" "$needle"
  fi
}
assert_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    pass "$label"
  else
    fail "$label" "haystack unexpectedly contained:" "$needle"
  fi
}
assert_count() {
  # Count non-overlapping occurrences of $needle in $haystack across lines.
  # Used to assert RowCount and verify that ambiguity warning produces ONE
  # warning row, not two — and that per-cwd outputs don't bleed.
  local label="$1" haystack="$2" needle="$3" want="$4" got
  got=$(grep -c -F -- "$needle" <<<"$haystack" || true)
  if [ "$want" = "$got" ]; then
    pass "$label"
  else
    fail "$label" "want count:" "$want" "got count:" "$got" "needle:" "$needle"
  fi
}
line_containing() {
  local needle="$1" line
  while IFS= read -r line; do
    if [[ "$line" == *"$needle"* ]]; then
      printf '%s' "$line"
      return 0
    fi
  done <<<"$RENDER_OUT"
  return 1
}
time_column_for_line() {
  local line="${1//$'\e[K'/}"
  if [[ "$line" =~ ^(.*[[:space:]])[0-9]+:[0-9][0-9]$ ]]; then
    printf '%s' "${#BASH_REMATCH[1]}"
    return 0
  fi
  printf '%s' -1
}

# === driver: run render.sh against a synthetic sandbox ===
# $1 = sandbox STATE_DIR
# $2 = AGENT_FLEET_PS_OVERRIDE file path ("" to disable)
# $3 = live pane table text  (TAB-separated cwd<TAB>session<TAB>terminal_<id><TAB>tab_id)
# Sets globals: RENDER_OUT
run_render() {
  local sandbox="$1" pso="$2" live="$3"
  local pane_file="$ROOT/pane-${RANDOM}-$$-${RANDOM}.tsv"
  printf '%s\n' "$live" > "$pane_file"
  local env_args=(
    "AGENT_FLEET_LIVE_PANES_OVERRIDE=$pane_file"
    "AGENT_FLEET_STATE_DIR=$sandbox"
  )
  if [ -n "$pso" ]; then
    env_args+=( "AGENT_FLEET_PS_OVERRIDE=$pso" )
  fi
  local tmp_err="$ROOT/err-${RANDOM}-$$-${RANDOM}.txt"
  RENDER_OUT=""
  set +e
  RENDER_OUT="$(env "${env_args[@]}" bash "$RENDER" 2>"$tmp_err")"
  local rc=$?
  # render is read-only; rc intentionally ignored (header comment: no
  # set -e — junk-pane / partial-JSON / etc. errors are the assertion
  # signal, not script-aborts).
  : "$rc"
}

key_for() { printf '%s' "$1" | shasum -a 256 | cut -c1-16; }

# === test cases ===

# --- 1. v2 file with ONE visible session renders as a single legacy line ---
# (Step 5: "Render one visible session as current single-line format where
# possible." Collapse behavior — one session ⇒ no process header, just the row.)
test_v2_single_session_collapses_one_line() {
  local sandbox="$ROOT/case1"
  mkdir -p "$sandbox"
  local pid=10101
  local pso="$ROOT/ps1.tsv"
  printf 'OPENCODE\t%s\n' "$pid" > "$pso"
  local key; key=$(key_for "/solo")
  cat > "$sandbox/${key}-${pid}.json" <<EOF
{"repo":"solo","cwd":"/solo","session":"sx","pid":${pid},
 "sessions":{"ses_n":{"state":"needs-attention","reason":"permission","ts":300,"task":null,"title":"need perm"}}}
EOF
  run_render "$sandbox" "$pso" $'/solo\tsx\tterminal_0\t0'
  assert_contains "case1 collapse: icon for needs-attention"  "$RENDER_OUT" "🔴"
  assert_contains "case1 collapse: state:reason text present" "$RENDER_OUT" "needs-attention: permission"
  # Spec step 5: label = title (here 'need perm'); v1 falls back to repo.
  assert_contains "case1 collapse: title 'need perm' shown as label"  "$RENDER_OUT" "need perm"
  # No "pid=" header emitted (single-session collapse path):
  assert_not_contains "case1 collapse: NO pid= process header for single-session" \
    "$RENDER_OUT" "pid=${pid}"
}

# --- 2. v2 file with MULTIPLE visible sessions nests them under a process row ---
test_v2_multi_session_nests_under_process() {
  local sandbox="$ROOT/case2"
  mkdir -p "$sandbox"
  local pid=10202
  local pso="$ROOT/ps2.tsv"
  printf 'OPENCODE\t%s\n' "$pid" > "$pso"
  local key; key=$(key_for "/multi")
  cat > "$sandbox/${key}-${pid}.json" <<EOF
{"repo":"multi","cwd":"/multi","session":"sx","pid":${pid},
 "sessions":{
   "ses_d_old":{"state":"done","reason":null,"ts":50,"task":null,"title":"old d"},
   "ses_d_new":{"state":"done","reason":null,"ts":250,"task":null,"title":"new d"},
   "ses_n":{"state":"needs-attention","reason":"permission","ts":300,"task":null,"title":"new n"}
 }}
EOF
  run_render "$sandbox" "$pso" $'/multi\tsx\tterminal_0\t0'
  # Process header must appear (multi-session ⇒ process row + indented children).
  assert_contains "case2 multi: pid= process header present" "$RENDER_OUT" "pid=${pid}"
  assert_contains "case2 multi: repo label in header"       "$RENDER_OUT" "multi"
  # Three separate visible sessions should each appear with their TITLE.
  # Step 5 collapses are not in play here — multi-session ⇒ nested children;
  # label = title (priority over truncated id per spec).
  assert_contains "case2 multi: 'old d' (ses_d_old title) row"  "$RENDER_OUT" "old d"
  assert_contains "case2 multi: 'new d' (ses_d_new title) row"  "$RENDER_OUT" "new d"
  assert_contains "case2 multi: 'new n' (ses_n title) row"      "$RENDER_OUT" "new n"
  # Needs-attention icon appears at least once.
  assert_contains "case2 multi: red icon present"  "$RENDER_OUT" "🔴"
  # Done icon appears at least twice (two done sessions).
  local green_count; green_count=$(grep -c -F "🟢" <<<"$RENDER_OUT" || true)
  if [ "${green_count:-0}" -ge 2 ]; then
    pass "case2 multi: at least 2 🟢 icons for two done sessions (got $green_count)"
  else
    fail "case2 multi: at least 2 🟢 icons for two done sessions" "got" "${green_count:-0}"
  fi
}

# --- 3. Headless pid SHARING a live cwd (two usable v2 files, one cwd, one
#         live pane): RENDER emits ONE duplicate-cwd warning row, not two
#         actionable rows. Spec: "Render duplicate cwd as warning, not
#         actionable rows." ---
test_headless_share_live_cwd_renders_warning() {
  local sandbox="$ROOT/case3"
  mkdir -p "$sandbox"
  local pidA=10301
  local pidB=10302
  local pso="$ROOT/ps3.tsv"
  printf 'OPENCODE\t%s\n' "$pidA" > "$pso"
  printf 'OPENCODE\t%s\n' "$pidB" >> "$pso"
  local key; key=$(key_for "/share")
  cat > "$sandbox/${key}-${pidA}.json" <<EOF
{"repo":"a","cwd":"/share","session":"sx","pid":${pidA},
 "sessions":{"s1":{"state":"needs-attention","reason":"perm","ts":100,"task":null,"title":"a needs"}}}
EOF
  cat > "$sandbox/${key}-${pidB}.json" <<EOF
{"repo":"b","cwd":"/share","session":"sx","pid":${pidB},
 "sessions":{"s2":{"state":"done","reason":null,"ts":200,"task":null,"title":"b done"}}}
EOF
  run_render "$sandbox" "$pso" $'/share\tsx\tterminal_0\t0'
  assert_contains "case3 ambiguous: warning icon"        "$RENDER_OUT" "⚠️"
  assert_contains "case3 ambiguous: scope to /share"     "$RENDER_OUT" "/share"
  assert_contains "case3 ambiguous: warning phrase"      "$RENDER_OUT" "duplicate opencode instance"
  # The two underlying session ids must NOT appear as actionable rows.
  assert_not_contains "case3 ambiguous: s1 NOT shown as actionable" "$RENDER_OUT" "s1"
  assert_not_contains "case3 ambiguous: s2 NOT shown as actionable" "$RENDER_OUT" "s2"
  # Exactly ONE warning about /share. (No double-row accidental duplication.)
  assert_count "case3 ambiguous: exactly one /share warning row" \
    "$RENDER_OUT" "/share" 1
}

# --- 4. Pane-count ambiguity arm: two LIVE panes same cwd, no state files.
#         Pane-table arm fires alone. Renders ONE warning row. ---
test_pane_count_ambiguity_alone_warns() {
  local sandbox="$ROOT/case4"
  mkdir -p "$sandbox"
  local pso="$ROOT/ps4.tsv"  # pso present but unused (no files reference it)
  : > "$pso"
  run_render "$sandbox" "$pso" \
    $'/dup\tsx\tterminal_0\t0\n/dup\tsx\tterminal_1\t1'
  assert_contains "case4 pane-ambiguous: warning icon"      "$RENDER_OUT" "⚠️"
  assert_contains "case4 pane-ambiguous: cwd /dup shown"    "$RENDER_OUT" "/dup"
  assert_contains "case4 pane-ambiguous: warning phrase"    "$RENDER_OUT" "duplicate opencode instance"
  assert_count "case4 pane-ambiguous: exactly one /dup row" "$RENDER_OUT" "/dup" 1
}

# --- 5. Dead-pid v2 file: state file DROPPED. The dropped file's intrinsic
#         contents (actionable session id, title, reason text) MUST NOT
#         appear in the output as actionable rows. Spec step 8 keeps a
#         synthetic `⚪ unknown` row as the fallback for the live pane. ---
test_dead_pid_v2_file_dropped() {
  local sandbox="$ROOT/case5"
  mkdir -p "$sandbox"
  local pso="$ROOT/ps5.tsv"
  printf 'DEAD\t999991\n' > "$pso"
  local key; key=$(key_for "/dead_cwd")
  cat > "$sandbox/${key}-999991.json" <<EOF
{"repo":"dead","cwd":"/dead_cwd","session":"sx","pid":999991,
 "sessions":{"ses_dropped":{"state":"needs-attention","reason":"perm","ts":900,"task":null,"title":"phantom"}}}
EOF
  run_render "$sandbox" "$pso" $'/dead_cwd\tsx\tterminal_0\t0'
  # Dropped file's session id and title MUST NOT appear — those belong to
  # the dropped v2 file's CONTENT, not the live pane. (cwd basename can
  # match the dropped file's repo; that's fine because synthetic's repo is
  # derived from cwd independently.)
  assert_not_contains "case5 dead pid: dropped file's session id NOT shown" \
    "$RENDER_OUT" "ses_dropped"
  assert_not_contains "case5 dead pid: dropped file's title 'phantom' NOT shown" \
    "$RENDER_OUT" "phantom"
  # The actionable REASON 'perm' from the dropped file must not bleed through:
  # (synthetic uses 'no sensor yet', not 'perm'.)
  assert_not_contains "case5 dead pid: dropped file's reason 'perm' NOT shown" \
    "$RENDER_OUT" "perm"
  # Irrelevant here — just retained as documentation:
  # === 'dead' as a SUBSTRING may appear (cwd basename = 'dead_cwd').
}

# --- 6. Reused-pid (alive but comm != opencode): file DROPPED. Use real
#         `sleep` subprocess to exercise the REAL ps path (no override line). ---
test_reused_pid_alive_not_opencode_dropped() {
  local sandbox="$ROOT/case6"
  mkdir -p "$sandbox"
  sleep 30 &
  local reused_pid=$!
  local key; key=$(key_for "/reused_cwd")
  cat > "$sandbox/${key}-${reused_pid}.json" <<EOF
{"repo":"reused","cwd":"/reused_cwd","session":"sx","pid":${reused_pid},
 "sessions":{"ses_reused":{"state":"needs-attention","reason":"perm","ts":50,"task":null,"title":"phantom"}}}
EOF
  # valid candidate on a different cwd so we have something to render
  local key2; key2=$(key_for "/valid_cwd")
  local pso="$ROOT/ps6.tsv"
  printf 'OPENCODE\t60100\n' > "$pso"
  cat > "$sandbox/${key2}-60100.json" <<EOF
{"repo":"valid","cwd":"/valid_cwd","session":"sx2","pid":60100,
 "sessions":{"s":{"state":"needs-attention","reason":"perm","ts":100,"task":null,"title":"real"}}}
EOF
  run_render "$sandbox" "$pso" \
    $'/reused_cwd\tsx\tterminal_0\t0\n/valid_cwd\tsx2\tterminal_1\t0'
  # Dropped file's session id/title MUST NOT appear:
  assert_not_contains "case6 reused-pid: dropped session id NOT shown" \
    "$RENDER_OUT" "ses_reused"
  assert_not_contains "case6 reused-pid: dropped title 'phantom' NOT shown" \
    "$RENDER_OUT" "phantom"
  # The valid candidate (per-session title 'real' on /valid_cwd) IS shown:
  assert_contains "case6 reused-pid: 'real' title from valid v2 file IS shown" \
    "$RENDER_OUT" "real"
  kill "$reused_pid" 2>/dev/null || true
  wait "$reused_pid" 2>/dev/null || true
}

# --- 7. v1/v2 supersession (a): a USABLE v2 file suppresses v1 for the
#         same cwd. v1 produces zero rows. Migration supersession rule. ---
test_v1_v2_super_a_usable_v2_suppresses_v1() {
  local sandbox="$ROOT/case7"
  mkdir -p "$sandbox"
  local pso="$ROOT/ps7.tsv"
  printf 'OPENCODE\t70100\n' > "$pso"
  local key; key=$(key_for "/legacy_super_a")
  # v1 legacy: bare cwd-hash, top-level state.
  cat > "$sandbox/${key}.json" <<EOF
{"repo":"v1_only_repo","cwd":"/legacy_super_a","session":"sx","state":"needs-attention","reason":"perm","ts":50,"task":null}
EOF
  # v2 covers /legacy_super_a with a usable pid.
  cat > "$sandbox/${key}-70100.json" <<EOF
{"repo":"two","cwd":"/legacy_super_a","session":"sx","pid":70100,
 "sessions":{"s2":{"state":"needs-attention","reason":"perm","ts":100,"task":null,"title":"v2 n"}}}
EOF
  run_render "$sandbox" "$pso" $'/legacy_super_a\tsx\tterminal_0\t0'
  # v2 wins. Its TITLE 'v2 n' is shown (collapse path: single visible session ⇒ single line).
  assert_contains "case7 usable v2 supersedes v1: v2 TITLE 'v2 n' shown as label" \
    "$RENDER_OUT" "v2 n"
  # The v1's repo 'v1_only_repo' MUST NOT appear (v1 is superseded by v2
  # ⇒ no v1 collapse_row ⇒ 'v1_only_repo' is not emitted as label):
  assert_not_contains "case7 usable v2 supersedes v1: v1's repo 'v1_only_repo' NOT shown" \
    "$RENDER_OUT" "v1_only_repo"
  # Exactly ONE 🔴 (not 2 from v1+v2):
  local attn_count; attn_count=$(grep -c -F "🔴" <<<"$RENDER_OUT" || true)
  if [ "${attn_count:-0}" -eq 1 ]; then
    pass "case7 usable v2 supersedes v1: exactly one 🔴 (v2 only, v1 superseded)"
  else
    fail "case7 usable v2 supersedes v1: exactly one 🔴 (v2 only, v1 superseded)" \
      "got" "${attn_count:-0}"
  fi
}

# --- 8. v1/v2 supersession (b): a DEAD v2 file does NOT suppress v1. Spec:
#         "Assert stale-pid drops run BEFORE supersession." v1 still
#         produces its own row. ---
test_v1_v2_super_b_dead_v2_does_not_suppress_v1() {
  local sandbox="$ROOT/case8"
  mkdir -p "$sandbox"
  local pso="$ROOT/ps8.tsv"
  printf 'DEAD\t80100\n' > "$pso"
  local key; key=$(key_for "/legacy_super_b")
  # v1 legacy state file, fresh-ish ts.
  cat > "$sandbox/${key}.json" <<EOF
{"repo":"v1_only","cwd":"/legacy_super_b","session":"sx","state":"needs-attention","reason":"perm","ts":500,"task":null}
EOF
  # dead v2 covering /legacy_super_b — must be DROPPED by stale-pid filter.
  # If supersession ran BEFORE stale-pid drop, this file would silently
  # suppress v1 and the cwd would render empty.
  cat > "$sandbox/${key}-80100.json" <<EOF
{"repo":"v2","cwd":"/legacy_super_b","session":"sx","pid":80100,
 "sessions":{"s2":{"state":"done","reason":null,"ts":10000,"task":null,"title":"v2 d"}}}
EOF
  run_render "$sandbox" "$pso" $'/legacy_super_b\tsx\tterminal_0\t0'
  # v1 still alive → state=needs-attention; v1's repo 'v1_only' is the
  # row's label (chosen because dead v2 was dropped, NOT a v1-supersedes-v2
  # call at all — dead v2 was ineligible).
  assert_contains "case8 dead v2 does NOT suppress v1: v1's repo 'v1_only' shown as label" \
    "$RENDER_OUT" "v1_only"
  assert_contains "case8 dead v2 does NOT suppress v1: needs-attention state + reason" \
    "$RENDER_OUT" "needs-attention: perm"
  # Exactly ONE actionable row emission (no warning row since the cwd is
  # not ambiguous; v2 is dead so it's not in v2_count despite the file being
  # on disk).
  local attn_count; attn_count=$(grep -c -F "🔴" <<<"$RENDER_OUT" || true)
  if [ "${attn_count:-0}" -eq 1 ]; then
    pass "case8 dead v2 does NOT suppress v1: exactly one 🔴 from v1 only"
  else
    fail "case8 dead v2 does NOT suppress v1: exactly one 🔴 from v1 only" \
      "got" "${attn_count:-0}"
  fi
  # The dead v2's session id 's2' and title 'v2 d' MUST NOT appear:
  assert_not_contains "case8 dead v2 does NOT suppress v1: dead v2 session id s2 NOT shown" \
    "$RENDER_OUT" "s2"
  assert_not_contains "case8 dead v2 does NOT suppress v1: dead v2 title 'v2 d' NOT shown" \
    "$RENDER_OUT" "v2 d"
}

# --- 9. Per-session suppression via `.viewed.json`. Suppresses viewed
#         `done` and viewed `needs-attention`; never suppresses `working`. ---
test_suppresses_viewed_terminal_never_working() {
  local sandbox="$ROOT/case9"
  mkdir -p "$sandbox"
  local pid=90100
  local pso="$ROOT/ps9.tsv"
  printf 'OPENCODE\t%s\n' "$pid" > "$pso"
  local key; key=$(key_for "/sup")
  # 3 sessions: viewed-done (suppress), viewed-needs-attention (suppress),
  # working-forever (NEVER suppress).
  cat > "$sandbox/${key}-${pid}.json" <<EOF
{"repo":"r","cwd":"/sup","session":"sx","pid":${pid},
 "sessions":{
   "ses_done_viewed":{"state":"done","reason":null,"ts":100,"task":null,"title":"d done"},
   "ses_attn_viewed":{"state":"needs-attention","reason":"perm","ts":200,"task":null,"title":"n perm"},
   "ses_working_forever":{"state":"working","reason":null,"ts":300,"task":null,"title":"forever"}
 }}
EOF
  # viewed.json marks the terminal-session ids as viewed with ts >= entry.
  cat > "$sandbox/${key}-${pid}.viewed.json" <<'EOF'
{"ses_done_viewed": 150, "ses_attn_viewed": 250, "ses_working_forever": 99999}
EOF
  run_render "$sandbox" "$pso" $'/sup\tsx\tterminal_0\t0'
  # The two terminal sessions are SUPPRESSED. Their TITLES must NOT appear
  # (titles "d done" / "n perm" only belonged to the suppressed sessions).
  assert_not_contains "case9 suppression: viewed done TITLE 'd done' NOT shown" \
    "$RENDER_OUT" "d done"
  assert_not_contains "case9 suppression: viewed needs-attention TITLE 'n perm' NOT shown" \
    "$RENDER_OUT" "n perm"
  # working NEVER suppressed — its title 'forever' MUST appear (priority
  # over session id per spec).
  assert_contains "case9 suppression: working title 'forever' shown" \
    "$RENDER_OUT" "forever"
  # Yellow icon for working present.
  assert_contains "case9 suppression: yellow icon for working session" \
    "$RENDER_OUT" "🟡"
  # Crucially no red/green actionable icons (only yellow).
  assert_not_contains "case9 suppression: no red icon (needs-attention was suppressed)" \
    "$RENDER_OUT" "🔴"
  assert_not_contains "case9 suppression: no green icon (done was suppressed)" \
    "$RENDER_OUT" "🟢"
}
# note: assertions above reference backticks-free labels so they survive
# bash's command substitution inside double-quoted strings.

# --- 10. Synthetic row: live opencode pane, no state file. Renders the
#         `unknown / no sensor yet` fallback so the board is never blind.
test_no_state_file_synthetic_unknown_row() {
  local sandbox="$ROOT/case10"
  mkdir -p "$sandbox"
  local pso="$ROOT/ps10.tsv"; : > "$pso"
  run_render "$sandbox" "$pso" $'/ghost\tsx\tterminal_0\t0'
  assert_contains "case10 synthetic: 'unknown' state text present" "$RENDER_OUT" "unknown"
  assert_contains "case10 synthetic: 'no sensor yet' hint present" "$RENDER_OUT" "no sensor yet"
  assert_contains "case10 synthetic: repo label (basename of /ghost)" "$RENDER_OUT" "ghost"
}

# --- 11. ZERO visible sessions for a process (all suppressed): process row
#         NOT emitted. Empty contribution. ---
test_zero_visible_sessions_drops_process() {
  local sandbox="$ROOT/case11"
  mkdir -p "$sandbox"
  local pid=110100
  local pso="$ROOT/ps11.tsv"
  printf 'OPENCODE\t%s\n' "$pid" > "$pso"
  local key; key=$(key_for "/zero")
  cat > "$sandbox/${key}-${pid}.json" <<EOF
{"repo":"zero","cwd":"/zero","session":"sx","pid":${pid},
 "sessions":{
   "ses_done_viewed":{"state":"done","reason":null,"ts":100,"task":null,"title":"d"},
   "ses_attn_viewed":{"state":"needs-attention","reason":"perm","ts":200,"task":null,"title":"n"}
 }}
EOF
  cat > "$sandbox/${key}-${pid}.viewed.json" <<'EOF'
{"ses_done_viewed": 150, "ses_attn_viewed": 250}
EOF
  run_render "$sandbox" "$pso" $'/zero\tsx\tterminal_0\t0'
  # Both sessions suppressed ⇒ process row not emitted.
  # (No synthetic either — there's a USABLE v2 file (process pid alive +
  # comm opencode); the cwd is just below the visible threshold.)
  assert_not_contains "case11 zero visible: pid= header NOT emitted"    "$RENDER_OUT" "pid=${pid}"
  # The session ids and titles from the v2 file MUST NOT appear:
  assert_not_contains "case11 zero visible: session id ses_done_viewed NOT shown" \
    "$RENDER_OUT" "ses_done_viewed"
  assert_not_contains "case11 zero visible: session id ses_attn_viewed NOT shown" \
    "$RENDER_OUT" "ses_attn_viewed"
  # The cwd's basename '/zero' is 'zero'. The repo from the v2 file was also 'zero'.
  # Test that no actionable icon (red/green) is present (all suppressed):
  assert_not_contains "case11 zero visible: no red icon (all suppressed)"     "$RENDER_OUT" "🔴"
  assert_not_contains "case11 zero visible: no green icon (all suppressed)"   "$RENDER_OUT" "🟢"
}

# --- 12. The multi-cwd scenario. Multiple simultaneously-live cwds, mixing
#         clean (v2 + single session), clean (v1 only, no usable v2),
#         ambiguous (2 v2 files share a cwd), partially-suppressed (working
#         visible, two terminals viewed), synthetic (no state file). Five
#         cwds; every row is scoped to ITS OWN cwd — no cross-bleed. ---
#         This is the test that catches cross-cwd scoping bugs (Task 5
#         lesson — a global-vs-scoped mistake). ---
test_multi_cwd_independent_render() {
  local sandbox="$ROOT/case12"
  mkdir -p "$sandbox"
  # bash `local p=1, q=2` syntax assigns ONE var `p` to "1, q=2"
  # (verified: `declare -p` shows `local p="1, q=2"`). Use separate locals.
  local pidA=120001
  local pidC1=120002
  local pidC2=120003
  local pidD=120004
  local pso="$ROOT/ps12.tsv"
  printf 'OPENCODE\t%s\n' "$pidA"  > "$pso"
  printf 'OPENCODE\t%s\n' "$pidC1" >> "$pso"
  printf 'OPENCODE\t%s\n' "$pidC2" >> "$pso"
  printf 'OPENCODE\t%s\n' "$pidD"  >> "$pso"
  local keyA; keyA=$(key_for "/projA")
  local keyB; keyB=$(key_for "/projB")
  local keyC; keyC=$(key_for "/projC")   # AMBIGUOUS cwd via file-count arm
  local keyD; keyD=$(key_for "/projD")   # partially-suppressed cwd
  # /projA: clean v2, single visible session ⇒ collapse to single legacy-format line.
  cat > "$sandbox/${keyA}-${pidA}.json" <<EOF
{"repo":"a","cwd":"/projA","session":"sx","pid":${pidA},
 "sessions":{"sess_A":{"state":"needs-attention","reason":"permission","ts":1000,"task":null,"title":"A needs"}}}
EOF
  # /projB: only v1 (no v2 file present) ⇒ v1 produces one legacy row.
  cat > "$sandbox/${keyB}.json" <<EOF
{"repo":"b","cwd":"/projB","session":"sx","state":"done","reason":null,"ts":200,"task":null}
EOF
  # /projC: AMBIGUOUS — two usable v2 files share the cwd (file-count arm).
  cat > "$sandbox/${keyC}-${pidC1}.json" <<EOF
{"repo":"c1","cwd":"/projC","session":"sx","pid":${pidC1},
 "sessions":{"sess_C1":{"state":"needs-attention","reason":"perm","ts":900,"task":null,"title":"C1 needs"}}}
EOF
  cat > "$sandbox/${keyC}-${pidC2}.json" <<EOF
{"repo":"c2","cwd":"/projC","session":"sx","pid":${pidC2},
 "sessions":{"sess_C2":{"state":"done","reason":null,"ts":1100,"task":null,"title":"C2 done"}}}
EOF
  # /projD: working or partial-suppress; both terminals viewed, working stays.
  cat > "$sandbox/${keyD}-${pidD}.json" <<EOF
{"repo":"d","cwd":"/projD","session":"sx","pid":${pidD},
 "sessions":{
   "sess_D_done":{"state":"done","reason":null,"ts":100,"task":null,"title":"D d"},
   "sess_D_attn":{"state":"needs-attention","reason":"perm","ts":200,"task":null,"title":"D n"},
   "sess_D_work":{"state":"working","reason":null,"ts":300,"task":null,"title":"D w"}
 }}
EOF
  cat > "$sandbox/${keyD}-${pidD}.viewed.json" <<'EOF'
{"sess_D_done": 150, "sess_D_attn": 250}
EOF
  # /projE: live pane, no state file ⇒ synthetic unknown row.
  run_render "$sandbox" "$pso" \
    $'/projA\tsx\tterminal_0\t0\n/projB\tsx\tterminal_1\t0\n/projC\tsx\tterminal_2\t0\n/projC\tsx\tterminal_3\t1\n/projD\tsx\tterminal_4\t0\n/projE\tsx\tterminal_5\t0'
  # --- /projA: clean v2 single session, collapse ⇒ icon + label + state:reason + age ---
  # Use the unique TITLE 'A needs' (the v2 file's title for sess_A) as the
  # disambiguator — repo names 'a', 'b', 'd' might collide in substring
  # searches.
  assert_contains      "case12 /projA: title 'A needs' shown as label"       "$RENDER_OUT" "A needs"
  assert_contains      "case12 /projA: 'needs-attention: permission' text"   "$RENDER_OUT" "needs-attention: permission"
  # No pid= header (single-session collapse):
  assert_not_contains  "case12 /projA: NO pid= header (single-session path)"  "$RENDER_OUT" "pid=${pidA}"
  # --- /projB: v1 only ⇒ single legacy-form row with state=done ---
  # v1's actual reason was null ⇒ output should say just 'done' (no ':perm' suffix):
  assert_contains      "case12 /projB: v1 produces row (state done shown)"   "$RENDER_OUT" "🟢 b"
  # --- /projC: AMBIGUOUS via file-count arm ⇒ ONE warning row, scope /projC,
  #     NOT contaminate /projA or others ---
  assert_count         "case12 /projC: exactly ONE warning row for /projC"    "$RENDER_OUT" "/projC" 1
  assert_contains      "case12 /projC: warning phrase for /projC"             "$RENDER_OUT" "duplicate opencode instance"
  # /projC's underlying session titles must NOT bleed through as actionable rows:
  assert_not_contains  "case12 /projC: 'C1 needs' title NOT shown as actionable" "$RENDER_OUT" "C1 needs"
  assert_not_contains  "case12 /projC: 'C2 done' title NOT shown as actionable"  "$RENDER_OUT" "C2 done"
  # Cross-cwd isolation:
  assert_count         "case12 cross-cwd: ONE warning total (no bleed onto other cwds)" "$RENDER_OUT" "⚠️" 1
  # --- /projD: working visible; terminals suppressed. Only ONE visible
  #     session left after suppression ⇒ collapse path ⇒ NO pid= header,
  #     just `🟡 D w working <age>` (label = title 'D w' priority). ---
  assert_contains      "case12 /projD: title 'D w' shown as label"            "$RENDER_OUT" "D w"
  assert_not_contains  "case12 /projD: NO pid= header (single visible after suppress)" \
    "$RENDER_OUT" "pid=${pidD}"
  assert_contains      "case12 /projD: yellow icon for working"               "$RENDER_OUT" "🟡"
  assert_not_contains  "case12 /projD: suppressed 'D d' title NOT shown"       "$RENDER_OUT" "D d"
  assert_not_contains  "case12 /projD: suppressed 'D n' title NOT shown"       "$RENDER_OUT" "D n"
  # --- /projE: synthetic unknown row (NO state file for /projE) ---
  assert_contains      "case12 /projE: 'no sensor yet' hint present"          "$RENDER_OUT" "no sensor yet"
  assert_contains      "case12 /projE: 'projE' cwd basename / repo"           "$RENDER_OUT" "projE"
  # ----- cross-cwd scoping/counting integrity -----
  # /projA warning row? NO — /projA has 1 v2 file + 1 pane ⇒ NOT ambiguous.
  # Total ⚠️ count must be EXACTLY 1 (only /projC).
  assert_count         "case12 cross-cwd: ONE warning for /projC (no cross-bleed)" "$RENDER_OUT" "/projC" 1
  assert_count         "case12 cross-cwd: total ⚠️ count = 1 (only /projC, no other cwd)" "$RENDER_OUT" "⚠️" 1
  # Total session with -ATTENTION (🔴): must scope to ONE cwd only —
  # /projA is the lone 🔴 since /projC's needs-attention got suppressed by
  # the warning row, /projD's attn is viewed-suppressed.
  local red_count; red_count=$(grep -c -F "🔴" <<<"$RENDER_OUT" || true)
  if [ "${red_count:-0}" -eq 1 ]; then
    pass "case12 cross-cwd: exactly 1 🔴 across all cwds (no double-count)"
  else
    fail "case12 cross-cwd: exactly 1 🔴 across all cwds (no double-count)" \
      "got:" "${red_count:-0}"
  fi
}

# --- 13. Long labels are capped to their column width so age stays aligned. ---
test_long_labels_do_not_shift_age_column() {
  local sandbox="$ROOT/case13"
  mkdir -p "$sandbox"
  local pidA=130001
  local pidB=130002
  local pso="$ROOT/ps13.tsv"
  printf 'OPENCODE\t%s\n' "$pidA" > "$pso"
  printf 'OPENCODE\t%s\n' "$pidB" >> "$pso"
  local keyA; keyA=$(key_for "/wideA")
  local keyB; keyB=$(key_for "/wideB")
  cat > "$sandbox/${keyA}-${pidA}.json" <<EOF
{"repo":"wideA","cwd":"/wideA","session":"sx","pid":${pidA},
 "sessions":{"sA":{"state":"done","reason":null,"ts":100,"task":null,"title":"short-title"}}}
EOF
  cat > "$sandbox/${keyB}-${pidB}.json" <<EOF
{"repo":"wideB","cwd":"/wideB","session":"sx","pid":${pidB},
 "sessions":{"sB":{"state":"done","reason":null,"ts":100,"task":null,"title":"this-title-is-long-enough-to-overflow-the-label-column"}}}
EOF
  run_render "$sandbox" "$pso" \
    $'/wideA\tsx\tterminal_0\t0\n/wideB\tsx\tterminal_1\t0'

  local short_line long_line short_col long_col
  short_line=$(line_containing "short-title") || { fail "case13 wide labels: short row found"; return; }
  long_line=$(line_containing "this-title-is-long") || { fail "case13 wide labels: long row found"; return; }
  assert_contains "case13 wide labels: context column wider than 22 chars" "$long_line" "this-title-is-long-enough"
  short_col=$(time_column_for_line "$short_line")
  long_col=$(time_column_for_line "$long_line")
  assert_eq "case13 wide labels: age column aligned" "$short_col" "$long_col"
}

# === run all ===
run_test() {
  printf '\n--- %s ---\n' "$1"
  "$1"
  printf '  (running)\n'
}

run_test test_v2_single_session_collapses_one_line
run_test test_v2_multi_session_nests_under_process
run_test test_headless_share_live_cwd_renders_warning
run_test test_pane_count_ambiguity_alone_warns
run_test test_dead_pid_v2_file_dropped
run_test test_reused_pid_alive_not_opencode_dropped
run_test test_v1_v2_super_a_usable_v2_suppresses_v1
run_test test_v1_v2_super_b_dead_v2_does_not_suppress_v1
run_test test_suppresses_viewed_terminal_never_working
run_test test_no_state_file_synthetic_unknown_row
run_test test_zero_visible_sessions_drops_process
run_test test_multi_cwd_independent_render
run_test test_long_labels_do_not_shift_age_column

echo
echo "---"
echo "PASS: $PASS  FAIL: $FAIL"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
