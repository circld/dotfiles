#!/usr/bin/env bash
# scripts/test-agent-fleet-render.sh
#
# Hermetic test for agent-fleet-render.sh (Task 7). The renderer is paint-only:
# it reads `$STATE_DIR/.board-cache.json` (written by Task 8's board) and never
# invokes the model. Tests therefore write cache JSON fixtures directly and
# inspect stdout plus `$STATE_DIR/.board-linemap.tsv` (the line map the board
# uses to translate screen lines into row identities for keyboard navigation).
#
# Visual invariants (collapse/nested rows, duplicate warning, suppression
# filtering, synthetic/idle rows, label widths, age alignment) are retained
# from the pre-cache harness below.
#
# Run via: bash scripts/test-agent-fleet-render.sh from repo root.
# Self-contained: no real zellij session, no model invocation.
# Note: deliberately NOT `set -e` — exercises of buggy code paths (missing
# cache, partial JSON, etc.) intentionally rely on RC semantics that strict
# mode would mask.
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

# === helper: extract a tab-separated field from a TSV line via awk ===
# Bash read -ra collapses empty middle fields; awk preserves them so we can
# verify that null key/sid fields really landed in the linemap as empty.
# Args: $1=line, $2=1-based field index.
linemap_field() {
  awk -F $'\t' -v f="$2" 'NR==1 {print (f<=NF ? $f : "")}' <<<"$1"
}
# === driver: run render.sh against a synthetic cache in a sandbox ===
# $1 = sandbox STATE_DIR (will hold .board-cache.json and .board-linemap.tsv)
# Sets globals: RENDER_OUT, LINEMAP_OUT, LINEMAP_PATH, RC.
# Optional env in caller scope, picked up and forwarded:
#   AGENT_FLEET_HIGHLIGHT_LINE  — forward to renderer for highlight tests
#   AGENT_FLEET_MODEL           — forward for never-invokes-model test
#   AGENT_FLEET_NOW_MS          — forward to pin the renderer's wall clock
#                                  (lets highlight/no-highlight tests compare
#                                  byte-identical output regardless of drift)
run_render() {
  local sandbox="$1"
  local linemap_path="$sandbox/.board-linemap.tsv"
  local tmp_err="$ROOT/err-${RANDOM}-$$-${RANDOM}.txt"
  RENDER_OUT=""
  LINEMAP_OUT=""
  LINEMAP_PATH="$linemap_path"
  local env_args=( "AGENT_FLEET_STATE_DIR=$sandbox" )
  if [ -n "${AGENT_FLEET_HIGHLIGHT_LINE:-}" ]; then
    env_args+=( "AGENT_FLEET_HIGHLIGHT_LINE=$AGENT_FLEET_HIGHLIGHT_LINE" )
  fi
  if [ -n "${AGENT_FLEET_MODEL:-}" ]; then
    env_args+=( "AGENT_FLEET_MODEL=$AGENT_FLEET_MODEL" )
  fi
  if [ -n "${AGENT_FLEET_NOW_MS:-}" ]; then
    env_args+=( "AGENT_FLEET_NOW_MS=$AGENT_FLEET_NOW_MS" )
  fi
  # Save & restore errexit around the call so a non-zero RC from the
  # renderer (mid-paint failure tests) doesn't abort the harness suite;
  # callers (and the run_test wrapper) expect run_render to ALWAYS return.
  local _was_errexit=0
  case "$-" in *e*) _was_errexit=1 ;; esac
  set +e
  RENDER_OUT="$(env "${env_args[@]}" bash "$RENDER" 2>"$tmp_err")"
  RC=$?
  [ "$_was_errexit" -eq 1 ] && set -e
  if [ -f "$linemap_path" ]; then
    LINEMAP_OUT="$(cat "$linemap_path")"
  fi
}

# Round the inputs we use a lot so each fixture stays compact.
NOW_MS="$(($(date +%s) * 1000))"
key_for() { printf '%s' "$1" | shasum -a 256 | cut -c1-16; }

# Build cache JSON from explicit row objects. Drops the assembled payload at
# $1 (file path). Subsequent args are pre-built row JSON strings; they become
# body of `.rows[]`. Use `mk_row` below for the common shape.
write_cache() {
  local path="$1"; shift
  local joined=""
  for r in "$@"; do
    if [ -z "$joined" ]; then joined="$r"; else joined="$joined,$r"; fi
  done
  printf '{"rows":[%s]}' "$joined" > "$path"
}

# mk_row produces a single JSON row object in the model's row[] shape.
# Empty optional fields → null. Source determines which downstream paths
# activate (label rules, idle append, etc.).
#
# args in order:
#   1 source        2 key        3 sid          4 cwd         5 session
#   6 state         7 reason     8 ts           9 title      10 label
#  11 suppressed   12 rank       13 repo       14 pid       15 pane
#  16 tabId
mk_row() {
  local source="$1" key="$2" sid="$3" cwd="$4" session="$5"
  local state="$6" reason="$7" ts="$8" title="$9" label="${10}"
  local suppressed="${11}" rank="${12}" repo="${13}" pid="${14}"
  local pane="${15}" tabId="${16}"
  jq -c -n \
    --arg source "$source" --arg cwd "$cwd" --arg session "$session" \
    --arg state "$state" --argjson ts "$ts" \
    --arg repo "$repo" --arg pane "$pane" --arg tabId "$tabId" \
    --arg key "$key" --arg sid "$sid" --arg reason "$reason" \
    --arg title "$title" --arg label "$label" \
    --arg suppressed "$suppressed" --arg rank "$rank" --arg pid "$pid" \
    '{
      source: $source,
      cwd: $cwd,
      session: $session,
      state: $state,
      ts: $ts,
      repo: $repo,
      pane: $pane,
      tabId: $tabId,
      key: (if $key == "" then null else $key end),
      sid: (if $sid == "" then null else $sid end),
      reason: (if $reason == "" then null else $reason end),
      title: (if $title == "" then null else $title end),
      label: (if $label == "" then null else $label end),
      suppressed: ($suppressed == "true"),
      rank: (if $rank == "" then null else ($rank | tonumber) end),
      pid: (if $pid == "" then null else ($pid | tonumber) end)
    }'
}

# === CACHE-INPUT VISUAL TESTS (preserve pre-cache behaviors) ===

# --- 1. v2 file with ONE visible session renders as a single legacy line. ---
test_v2_single_session_collapses_one_line() {
  local sandbox="$ROOT/case1"
  mkdir -p "$sandbox"
  local key; key=$(key_for "/solo")
  write_cache "$sandbox/.board-cache.json" \
    "$(mk_row v2 "$key" ses_n /solo sx needs-attention permission $((NOW_MS - 300000)) "need perm" "need perm" false 3 solo 10101 terminal_0 0)"
  run_render "$sandbox"
  assert_contains "case1 collapse: icon for needs-attention"  "$RENDER_OUT" "🔴"
  assert_contains "case1 collapse: state:reason text present" "$RENDER_OUT" "needs-attention: permission"
  assert_contains "case1 collapse: title 'need perm' shown as label"  "$RENDER_OUT" "need perm"
  assert_not_contains "case1 collapse: NO pid= process header for single-session" \
    "$RENDER_OUT" "pid=${pid:-10101}"
  # linemap: 1 navigable row, 1 mapped entry.
  assert_eq "case1 linemap: 1 mapped row" "1" "$(printf '%s\n' "$LINEMAP_OUT" | grep -c .)"
}

# --- 2. v2 file with MULTIPLE visible sessions nests them under a process row. ---
test_v2_multi_session_nests_under_process() {
  local sandbox="$ROOT/case2"
  mkdir -p "$sandbox"
  local key; key=$(key_for "/multi")
  local pid=10202
  write_cache "$sandbox/.board-cache.json" \
    "$(mk_row v2 "$key" ses_d_old /multi sx done "" $((NOW_MS - 950000)) "old d" "old d" false 0 multi $pid terminal_0 0)" \
    "$(mk_row v2 "$key" ses_d_new /multi sx done "" $((NOW_MS - 750000)) "new d" "new d" false 0 multi $pid terminal_0 0)" \
    "$(mk_row v2 "$key" ses_n /multi sx needs-attention permission $((NOW_MS - 700000)) "new n" "new n" false 1 multi $pid terminal_0 0)"
  run_render "$sandbox"
  assert_contains "case2 multi: pid= process header present" "$RENDER_OUT" "pid=${pid}"
  assert_contains "case2 multi: repo label in header"       "$RENDER_OUT" "multi"
  assert_contains "case2 multi: 'old d' (ses_d_old title) row"  "$RENDER_OUT" "old d"
  assert_contains "case2 multi: 'new d' (ses_d_new title) row"  "$RENDER_OUT" "new d"
  assert_contains "case2 multi: 'new n' (ses_n title) row"      "$RENDER_OUT" "new n"
  assert_contains "case2 multi: red icon present"  "$RENDER_OUT" "🔴"
  local green_count; green_count=$(grep -c -F "🟢" <<<"$RENDER_OUT" || true)
  if [ "${green_count:-0}" -ge 2 ]; then
    pass "case2 multi: at least 2 🟢 icons for two done sessions (got $green_count)"
  else
    fail "case2 multi: at least 2 🟢 icons for two done sessions" "got" "${green_count:-0}"
  fi
  # linemap: 1 process row is NOT navigable; 3 children → 3 mapped entries.
  assert_eq "case2 multi: linemap row count (3 children only)" "3" \
    "$(printf '%s\n' "$LINEMAP_OUT" | grep -c .)"
}

# --- 3. Two usable v2 files share a live cwd: ONE warning row, not two actionable rows. ---
test_duplicate_cwd_renders_warning() {
  local sandbox="$ROOT/case3"
  mkdir -p "$sandbox"
  local key; key=$(key_for "/share")
  write_cache "$sandbox/.board-cache.json" \
    "$(mk_row warning "" "" /share sx duplicate "duplicate opencode instance" 0 "" "/share" false "" "/share" "" terminal_0 0)"
  run_render "$sandbox"
  assert_contains "case3 ambiguous: warning icon"        "$RENDER_OUT" "⚠️"
  assert_contains "case3 ambiguous: scope to /share"     "$RENDER_OUT" "/share"
  assert_contains "case3 ambiguous: warning phrase"      "$RENDER_OUT" "duplicate opencode instance"
  assert_count "case3 ambiguous: exactly one /share warning row" \
    "$RENDER_OUT" "/share" 1
  # linemap: only the warning row; key="" sid="" cwd="/share".
  assert_eq "case3 linemap: 1 mapped row (warning)" "1" \
    "$(printf '%s\n' "$LINEMAP_OUT" | grep -c .)"
  # Spot-check: linemap entry has line=1, two empty fields, then cwd=/share.
  assert_eq "case3 linemap: warning line=1"   "1"          "$(linemap_field "$LINEMAP_OUT" 1)"
  assert_eq "case3 linemap: empty key"        ""           "$(linemap_field "$LINEMAP_OUT" 2)"
  assert_eq "case3 linemap: empty sid"        ""           "$(linemap_field "$LINEMAP_OUT" 3)"
  assert_eq "case3 linemap: cwd /share"       "/share"     "$(linemap_field "$LINEMAP_OUT" 4)"
}

# --- 4. Synthetic row: live pane, no state file, no v1/v2 → unknown/no sensor yet fallback. ---
test_no_state_file_synthetic_unknown_row() {
  local sandbox="$ROOT/case4"
  mkdir -p "$sandbox"
  write_cache "$sandbox/.board-cache.json" \
    "$(mk_row synthetic "" "" /ghost sx unknown "no sensor yet" $NOW_MS "" "ghost" false "" ghost "" terminal_0 0)"
  run_render "$sandbox"
  assert_contains "case4 synthetic: 'unknown' state text present" "$RENDER_OUT" "unknown"
  assert_contains "case4 synthetic: 'no sensor yet' hint present" "$RENDER_OUT" "no sensor yet"
  assert_contains "case4 synthetic: repo label (basename of /ghost)" "$RENDER_OUT" "ghost"
  # linemap: only synthetic unknown row.
  assert_eq "case4 linemap: 1 mapped row (synthetic)" "1" \
    "$(printf '%s\n' "$LINEMAP_OUT" | grep -c .)"
}

# --- 5. Suppression: viewed terminal sessions filtered by `suppressed` flag. ---
# The renderer reads cache rows and only emits those with `suppressed == false`
# (no model-side filter needed; cache already carries the flag's verdict).
# This case proves the filter discriminates on the FLAG, not on state, by
# mixing suppressed and unsuppressed rows of the same state kind.
test_suppresses_viewed_terminal_never_working() {
  local sandbox="$ROOT/case5"
  mkdir -p "$sandbox"
  local key; key=$(key_for "/sup")
  local pid=90100
  # Four rows for one cwd:
  #   ses_done_viewed     done          suppressed=true  → MUST NOT paint or map
  #   ses_attn_viewed     needs-attention suppressed=true  → MUST NOT paint or map
  #   ses_done_kept       done          suppressed=false → control: proves flag
  #                                                     (not state) drives filter
  #   ses_working         working       suppressed=false → working is never
  #                                                     suppressed regardless of flag
  write_cache "$sandbox/.board-cache.json" \
    "$(mk_row v2 "$key" ses_done_viewed /sup sx done "" $((NOW_MS - 800000)) "viewed d" "viewed d" true 0 r $pid terminal_0 0)" \
    "$(mk_row v2 "$key" ses_attn_viewed /sup sx needs-attention perm $((NOW_MS - 700000)) "viewed n" "viewed n" true 1 r $pid terminal_0 0)" \
    "$(mk_row v2 "$key" ses_done_kept /sup sx done "" $((NOW_MS - 600000)) "kept d" "kept d" false 0 r $pid terminal_0 0)" \
    "$(mk_row v2 "$key" ses_working /sup sx working "" $((NOW_MS - 100000)) "forever" "forever" false "" r $pid terminal_0 0)"
  AGENT_FLEET_NOW_MS="$NOW_MS" run_render "$sandbox"
  # Suppressed entries never reach the painted frame.
  assert_not_contains "case5 suppression: viewed done TITLE 'viewed d' NOT painted" \
    "$RENDER_OUT" "viewed d"
  assert_not_contains "case5 suppression: viewed needs-attention TITLE 'viewed n' NOT painted" \
    "$RENDER_OUT" "viewed n"
  assert_not_contains "case5 suppression: viewed done sid 'ses_done_viewed' NOT painted" \
    "$RENDER_OUT" "ses_done_viewed"
  assert_not_contains "case5 suppression: viewed needs-attention sid 'ses_attn_viewed' NOT painted" \
    "$RENDER_OUT" "ses_attn_viewed"
  # Same-state unsuppressed row paints (control proves the filter reads flag, not state).
  assert_contains "case5 suppression: kept done (same state, NOT suppressed) paints" \
    "$RENDER_OUT" "kept d"
  assert_contains "case5 suppression: kept done green icon paints" "$RENDER_OUT" "🟢"
  # Working paints regardless of suppressed flag (working is never suppressed).
  assert_contains "case5 suppression: working title 'forever' shown" "$RENDER_OUT" "forever"
  assert_contains "case5 suppression: yellow icon for working" "$RENDER_OUT" "🟡"
  assert_not_contains "case5 suppression: NO red icon (viewed needs-attention was suppressed)" \
    "$RENDER_OUT" "🔴"
  # Suppressed rows never reach the linemap either.
  assert_not_contains "case5 linemap: viewed-done sid NOT mapped" \
    "$LINEMAP_OUT" "ses_done_viewed"
  assert_not_contains "case5 linemap: viewed-needs-attention sid NOT mapped" \
    "$LINEMAP_OUT" "ses_attn_viewed"
  # Only the two unsuppressed rows map (count == 2).
  assert_eq "case5 linemap: 2 mapped rows (kept-done + working)" "2" \
    "$(printf '%s\n' "$LINEMAP_OUT" | grep -c .)"
  assert_contains "case5 linemap: kept done sid mapped" "$LINEMAP_OUT" "ses_done_kept"
  assert_contains "case5 linemap: working sid mapped" "$LINEMAP_OUT" "ses_working"
}

# --- 5b. All-suppressed siblings + model-issued idle summary: idle surrogate paints. ---
# The model issues an `idle` row (state="idle", reason="all chats viewed")
# when every session in a usable v2 file has been viewed past its entry ts.
# This case verifies the renderer doesn't drop that surrogate just because its
# siblings are suppressed — the row's own `suppressed: false` flag is what
# matters, not "all peers were suppressed".
test_idle_paints_with_suppressed_done_siblings() {
  local sandbox="$ROOT/case_idle_with_suppressed_siblings"
  mkdir -p "$sandbox"
  local key; key=$(key_for "/idle_sup")
  local pid=110100
  # Two view-marked done rows (suppressed=true) plus the model-issued idle
  # surrogate (suppressed=false). Only the idle row should reach the frame.
  write_cache "$sandbox/.board-cache.json" \
    "$(mk_row v2 "$key" ses_d_a /idle_sup sx done "" $((NOW_MS - 700000)) "viewed a" "viewed a" true 0 idle_sup $pid terminal_0 0)" \
    "$(mk_row v2 "$key" ses_d_b /idle_sup sx done "" $((NOW_MS - 600000)) "viewed b" "viewed b" true 0 idle_sup $pid terminal_0 0)" \
    "$(mk_row idle "$key" "" /idle_sup sx idle "all chats viewed" $((NOW_MS - 500000)) "" "idle_sup" false "" idle_sup $pid terminal_0 0)"
  AGENT_FLEET_NOW_MS="$NOW_MS" run_render "$sandbox"
  # Idle summary paints: label, state, hint.
  assert_contains "case_idle_sups: idle repo label 'idle_sup' paints" \
    "$RENDER_OUT" "idle_sup"
  assert_contains "case_idle_sups: 'idle' state surfaces" "$RENDER_OUT" "idle"
  assert_contains "case_idle_sups: 'all chats viewed' hint paints" \
    "$RENDER_OUT" "all chats viewed"
  # Suppressed siblings stay absent from both painted frame and the linemap.
  assert_not_contains "case_idle_sups: viewed done A title 'viewed a' NOT painted" \
    "$RENDER_OUT" "viewed a"
  assert_not_contains "case_idle_sups: viewed done B title 'viewed b' NOT painted" \
    "$RENDER_OUT" "viewed b"
  local combined
  combined="$(printf '%s\n%s' "$RENDER_OUT" "$LINEMAP_OUT")"
  assert_not_contains "case_idle_sups: viewed done A sid 'ses_d_a' absent from frame+linemap" \
    "$combined" "ses_d_a"
  assert_not_contains "case_idle_sups: viewed done B sid 'ses_d_b' absent from frame+linemap" \
    "$combined" "ses_d_b"
  # Idle row is navigable per the spec (sid-less but in rows[]); 1 mapped entry.
  assert_eq "case_idle_sups: linemap count (only idle row)" "1" \
    "$(printf '%s\n' "$LINEMAP_OUT" | grep -c .)"
  # Linemap row carries the cwd; sid field is empty (null → empty per spec).
  assert_contains "case_idle_sups: linemap carries idle cwd" "$LINEMAP_OUT" "/idle_sup"
}

# --- 6. v1-only legacy row: no v2, v1 file alone produces one collapse row. ---
test_v1_only_legacy_row() {
  local sandbox="$ROOT/case6"
  mkdir -p "$sandbox"
  local key; key=$(key_for "/legacy")
  write_cache "$sandbox/.board-cache.json" \
    "$(mk_row v1 "$key" "" /legacy sx done "" $((NOW_MS - 800000)) "" "legacy" false 0 legacy "" terminal_0 0)"
  AGENT_FLEET_NOW_MS="$NOW_MS" run_render "$sandbox"
  assert_contains "case6 v1: green icon for done" "$RENDER_OUT" "🟢"
  assert_contains "case6 v1: legacy label shown" "$RENDER_OUT" "legacy"
  assert_not_contains "case6 v1: no pid= header (single cwd under session)" "$RENDER_OUT" "pid="
  # linemap: 1 mapped row; key set, sid empty. Use read -ra for field
  # positions 2 and 3 to stay correct against bash empty-field collapse.
  assert_eq "case6 v1 linemap: 1 mapped row" "1" \
    "$(printf '%s\n' "$LINEMAP_OUT" | grep -c .)"
  assert_eq "case6 v1 linemap: key set"       "$key"    "$(linemap_field "$LINEMAP_OUT" 2)"
  assert_eq "case6 v1 linemap: sid empty"     ""        "$(linemap_field "$LINEMAP_OUT" 3)"
  assert_eq "case6 v1 linemap: cwd"           "/legacy" "$(linemap_field "$LINEMAP_OUT" 4)"
}

# --- 7. v1/v2 supersession (only v2 row remains; v1 was superseded by usable v2). ---
test_v1_v2_super_a_usable_v2_suppresses_v1() {
  local sandbox="$ROOT/case7"
  mkdir -p "$sandbox"
  local key; key=$(key_for "/legacy_super_a")
  local pid=70100
  write_cache "$sandbox/.board-cache.json" \
    "$(mk_row v2 "$key" s2 /legacy_super_a sx needs-attention perm $((NOW_MS - 900000)) "v2 n" "v2 n" false 1 two $pid terminal_0 0)"
  run_render "$sandbox"
  assert_contains "case7 usable v2 supersedes v1: v2 title 'v2 n' shown" "$RENDER_OUT" "v2 n"
  assert_not_contains "case7 usable v2 supersedes v1: v1's repo 'v1_only_repo' NOT shown" \
    "$RENDER_OUT" "v1_only_repo"
  local attn_count; attn_count=$(grep -c -F "🔴" <<<"$RENDER_OUT" || true)
  if [ "${attn_count:-0}" -eq 1 ]; then
    pass "case7 usable v2 supersedes v1: exactly one 🔴"
  else
    fail "case7 usable v2 supersedes v1: exactly one 🔴" "got:" "${attn_count:-0}"
  fi
}

# --- 8. v1/v2 supersession (v2 dead, didn't suppress v1). Cache shows only v1 row. ---
test_v1_v2_super_b_dead_v2_does_not_suppress_v1() {
  local sandbox="$ROOT/case8"
  mkdir -p "$sandbox"
  local key; key=$(key_for "/legacy_super_b")
  write_cache "$sandbox/.board-cache.json" \
    "$(mk_row v1 "$key" "" /legacy_super_b sx needs-attention perm $((NOW_MS - 500000)) "" "v1_only" false 1 v1_only "" terminal_0 0)"
  run_render "$sandbox"
  assert_contains "case8 dead v2: v1's repo 'v1_only' shown as label" "$RENDER_OUT" "v1_only"
  assert_contains "case8 dead v2: needs-attention state + reason" "$RENDER_OUT" "needs-attention: perm"
  local attn_count; attn_count=$(grep -c -F "🔴" <<<"$RENDER_OUT" || true)
  if [ "${attn_count:-0}" -eq 1 ]; then
    pass "case8 dead v2: exactly one 🔴 from v1 only"
  else
    fail "case8 dead v2: exactly one 🔴 from v1 only" "got:" "${attn_count:-0}"
  fi
}

# --- 9. Idle row: all chats viewed+done, one idle row keeps live pane visible. ---
test_viewed_done_sessions_show_idle_process() {
  local sandbox="$ROOT/case9"
  mkdir -p "$sandbox"
  local key; key=$(key_for "/zero")
  local pid=110100
  write_cache "$sandbox/.board-cache.json" \
    "$(mk_row idle "$key" "" /zero sx idle "all chats viewed" $((NOW_MS - 200000)) "" "zero" false "" zero $pid terminal_0 0)"
  AGENT_FLEET_NOW_MS="$NOW_MS" run_render "$sandbox"
  assert_contains "case9 idle: repo label shown" "$RENDER_OUT" "zero"
  assert_contains "case9 idle: idle state shown" "$RENDER_OUT" "idle"
  assert_not_contains "case9 idle: no red icon"     "$RENDER_OUT" "🔴"
  assert_not_contains "case9 idle: no green icon"   "$RENDER_OUT" "🟢"
  # linemap: 1 mapped row; sid empty.
  assert_eq "case9 idle linemap: 1 mapped row" "1" \
    "$(printf '%s\n' "$LINEMAP_OUT" | grep -c .)"
  IFS=$'\t' read -ra f <<<"$LINEMAP_OUT"
  assert_eq "case9 idle linemap: key set"   "$key" "$(linemap_field "$LINEMAP_OUT" 2)"
  assert_eq "case9 idle linemap: sid empty" ""     "$(linemap_field "$LINEMAP_OUT" 3)"
  assert_eq "case9 idle linemap: cwd"       "/zero" "$(linemap_field "$LINEMAP_OUT" 4)"
}

# --- 10. Multi-cwd interaction: cleanup, scope, no bleed. Five cwds, every row is scoped. ---
test_multi_cwd_independent_render() {
  local sandbox="$ROOT/case10"
  mkdir -p "$sandbox"
  local keyA; keyA=$(key_for "/projA")
  local keyB; keyB=$(key_for "/projB")
  local keyD; keyD=$(key_for "/projD")
  local pidA=120001
  local pidD=120004
  write_cache "$sandbox/.board-cache.json" \
    "$(mk_row v2 "$keyA" sess_A /projA sx needs-attention permission $((NOW_MS - 1000)) "A needs" "A needs" false 1 a $pidA terminal_0 0)" \
    "$(mk_row v1 "$keyB" "" /projB sx done "" $((NOW_MS - 800000)) "" "b" false -1 b "" terminal_1 0)" \
    "$(mk_row warning "" "" /projC sx duplicate "duplicate opencode instance" 0 "" "/projC" false "" "/projC" "" terminal_2 0)" \
    "$(mk_row v2 "$keyD" sess_D_work /projD sx working "" $((NOW_MS - 700000)) "D w" "D w" false "" d $pidD terminal_4 0)" \
    "$(mk_row synthetic "" "" /projE sx unknown "no sensor yet" $NOW_MS "" "projE" false "" projE "" terminal_5 0)"
  run_render "$sandbox"
  assert_contains     "case10 /projA: title 'A needs' shown"         "$RENDER_OUT" "A needs"
  assert_contains     "case10 /projA: 'needs-attention: permission'" "$RENDER_OUT" "needs-attention: permission"
  assert_not_contains "case10 /projA: NO pid= header (single-session)" "$RENDER_OUT" "pid=${pidA}"
  assert_contains     "case10 /projB: v1 row (🟢 b done)"             "$RENDER_OUT" "🟢 b"
  assert_count        "case10 /projC: ONE warning row for /projC"     "$RENDER_OUT" "/projC" 1
  assert_contains     "case10 /projC: warning phrase"                  "$RENDER_OUT" "duplicate opencode instance"
  assert_not_contains "case10 /projC: 'C1 needs' NOT shown"             "$RENDER_OUT" "C1 needs"
  assert_not_contains "case10 /projC: 'C2 done' NOT shown"              "$RENDER_OUT" "C2 done"
  assert_count        "case10 cross-cwd: ONE warning total"            "$RENDER_OUT" "⚠️" 1
  assert_contains     "case10 /projD: title 'D w' shown"               "$RENDER_OUT" "D w"
  assert_not_contains "case10 /projD: NO pid= header (single visible)"  "$RENDER_OUT" "pid=${pidD}"
  assert_contains     "case10 /projE: 'no sensor yet' hint"            "$RENDER_OUT" "no sensor yet"
  assert_contains     "case10 /projE: 'projE' cwd basename"            "$RENDER_OUT" "projE"
  local red_count; red_count=$(grep -c -F "🔴" <<<"$RENDER_OUT" || true)
  if [ "${red_count:-0}" -eq 1 ]; then
    pass "case10 cross-cwd: exactly 1 🔴 (only /projA)"
  else
    fail "case10 cross-cwd: exactly 1 🔴" "got:" "${red_count:-0}"
  fi
  # linemap: 5 navigable rows (A, B, C warning, D, E synthetic); session header NOT in map.
  assert_eq "case10 linemap: 5 mapped rows" "5" \
    "$(printf '%s\n' "$LINEMAP_OUT" | grep -c .)"
  # session header text must NOT appear in linemap.
  local hdr_marker="──"
  if [[ "$LINEMAP_OUT" != *"$hdr_marker"* ]]; then
    pass "case10 linemap: NO session header text"
  else
    fail "case10 linemap: session header leaked into linemap" "found: $hdr_marker"
  fi
}

# --- 11. Long labels capped; age column aligned across collapse and nested rows. ---
test_long_labels_do_not_shift_age_column() {
  local sandbox="$ROOT/case11"
  mkdir -p "$sandbox"
  local keyA; keyA=$(key_for "/wideA")
  local keyB; keyB=$(key_for "/wideB")
  local pidA=130001
  local pidB=130002
  write_cache "$sandbox/.board-cache.json" \
    "$(mk_row v2 "$keyA" sA /wideA sx done "" $((NOW_MS - 900000)) "short-title" "short-title" false "" wideA $pidA terminal_0 0)" \
    "$(mk_row v2 "$keyB" sB /wideB sx done "" $((NOW_MS - 900000)) "this-title-is-long-enough-to-overflow-the-label-column" "this-title-is-long-enough-to-overflow-the-label-column" false "" wideB $pidB terminal_1 0)"
  run_render "$sandbox"
  local short_line long_line short_col long_col
  short_line=$(line_containing "short-title") || { fail "case11 wide labels: short row found"; return; }
  long_line=$(line_containing "this-title-is-long") || { fail "case11 wide labels: long row found"; return; }
  assert_contains "case11 wide labels: context column wider than 22 chars" "$long_line" "this-title-is-long-enough"
  short_col=$(time_column_for_line "$short_line")
  long_col=$(time_column_for_line "$long_line")
  assert_eq "case11 wide labels: age column aligned" "$short_col" "$long_col"
}

# --- 12. Nested rows keep shared columns aligned with non-nested rows. ---
test_nested_rows_keep_columns_aligned() {
  local sandbox="$ROOT/case12"
  mkdir -p "$sandbox"
  local keyA; keyA=$(key_for "/single")
  local keyB; keyB=$(key_for "/multi")
  local pidA=140001
  local pidB=140002
  write_cache "$sandbox/.board-cache.json" \
    "$(mk_row v2 "$keyA" sA /single sx working "" $((NOW_MS - 900000)) "single-row" "single-row" false "" single $pidA terminal_0 0)" \
    "$(mk_row v2 "$keyB" sB1 /multi sx working "" $((NOW_MS - 900000)) "multi-row-1" "multi-row-1" false "" multi $pidB terminal_1 0)" \
    "$(mk_row v2 "$keyB" sB2 /multi sx done "" $((NOW_MS - 900000)) "multi-row-2" "multi-row-2" false "" multi $pidB terminal_1 0)"
  run_render "$sandbox"
  local single_line nested_line single_col nested_col
  single_line=$(line_containing "single-row") || { fail "case12 alignment: single row found"; return; }
  nested_line=$(line_containing "multi-row-1") || { fail "case12 alignment: nested row found"; return; }
  single_col=$(time_column_for_line "$single_line")
  nested_col=$(time_column_for_line "$nested_line")
  assert_eq "case12 alignment: nested age column matches single row" "$single_col" "$nested_col"
}

# === CACHE-INPUT ISOLATION TESTS (Task 7's new behavior surface) ===

# --- 13. Missing cache file: empty frame, exits 0, atomic empty linemap. ---
test_missing_cache_prints_empty_frame() {
  local sandbox="$ROOT/case_missing"
  mkdir -p "$sandbox"
  # No .board-cache.json written.
  run_render "$sandbox"
  assert_eq "case13 missing cache: rc=0" "0" "$RC"
  assert_eq "case13 missing cache: empty stdout" "" "$RENDER_OUT"
  assert_eq "case13 missing cache: linemap exists" "yes" \
    "$([ -f "$LINEMAP_PATH" ] && [ ! -s "$LINEMAP_PATH" ] && echo yes || echo no)"
}

# --- 14. Invalid cache JSON: same as missing — empty frame, empty linemap, exit 0. ---
test_invalid_cache_prints_empty_frame() {
  local sandbox="$ROOT/case_invalid"
  mkdir -p "$sandbox"
  printf 'this is not json at all {' > "$sandbox/.board-cache.json"
  run_render "$sandbox"
  assert_eq "case14 invalid cache: rc=0" "0" "$RC"
  assert_eq "case14 invalid cache: empty stdout" "" "$RENDER_OUT"
  assert_eq "case14 invalid cache: linemap empty" "yes" \
    "$([ -f "$LINEMAP_PATH" ] && [ ! -s "$LINEMAP_PATH" ] && echo yes || echo no)"
}

# --- 15. Renderer never invokes the model (cache-input contract). ---
test_renderer_never_invokes_model() {
  local sandbox="$ROOT/case_nomodel"
  mkdir -p "$sandbox"
  local key; key=$(key_for "/solo")
  write_cache "$sandbox/.board-cache.json" \
    "$(mk_row v2 "$key" ses_n /solo sx needs-attention permission $((NOW_MS - 300000)) "need perm" "need perm" false 3 solo 10101 terminal_0 0)"
  # Sentinel model that touches a file if invoked. If the renderer ever
  # executes it, the sentinel lands and the assertion fails.
  local sentinel="$ROOT/never_called.sh"
  cat > "$sentinel" <<EOF
#!/usr/bin/env bash
touch "$sandbox/AGENT_FLEET_MODEL_WAS_CALLED"
exit 0
EOF
  chmod +x "$sentinel"
  RC="$(env AGENT_FLEET_STATE_DIR="$sandbox" AGENT_FLEET_MODEL="$sentinel" bash "$RENDER" 2>/dev/null)"
  if [ ! -e "$sandbox/AGENT_FLEET_MODEL_WAS_CALLED" ]; then
    pass "case15 renderer never invokes model (sentinel not touched)"
  else
    fail "case15 renderer never invokes model" "sentinel touched; child ran node \$MODEL"
  fi
  # Source-level: no `node` invocations in the script body.
  if grep -E '\bnode\b' "$RENDER" >/dev/null 2>&1; then
    fail "case15 renderer source has node invocation" "matched: $(grep -nE '\bnode\b' "$RENDER")"
  else
    pass "case15 renderer source has no node invocation"
  fi
}

# --- 16. Linemap excludes session/group headers and blank separators. ---
test_linemap_excludes_headers_and_blanks() {
  local sandbox="$ROOT/case_linemap_filter"
  mkdir -p "$sandbox"
  local keyA; keyA=$(key_for "/solo")
  local keyB; keyB=$(key_for "/multi")
  local pidB=999
  write_cache "$sandbox/.board-cache.json" \
    "$(mk_row v2 "$keyA" ses_n /solo sxA needs-attention permission $((NOW_MS - 300000)) "need perm" "need perm" false 1 solo 100 terminal_0 0)" \
    "$(mk_row v2 "$keyB" ses1 /multi sxB working "" $((NOW_MS - 100000)) "m1" "m1" false "" multi $pidB terminal_0 0)" \
    "$(mk_row v2 "$keyB" ses2 /multi sxB done "" $((NOW_MS - 100000)) "m2" "m2" false "" multi $pidB terminal_0 0)"
  run_render "$sandbox"
  # Output should contain TWO session headers, process_header, blank separator, 3 navigable rows.
  local header_count; header_count=$(grep -c -F $'──' <<<"$RENDER_OUT" || true)
  if [ "${header_count:-0}" -ge 2 ]; then
    pass "case16: 2 session headers painted"
  else
    fail "case16: 2 session headers painted" "got" "${header_count:-0}"
  fi
  # linemap contains exactly 3 navigable rows (keyA collapse, keyB process=NOT, keyB x2 children).
  assert_eq "case16 linemap: 3 mapped rows" "3" \
    "$(printf '%s\n' "$LINEMAP_OUT" | grep -c .)"
  # No session header text in linemap.
  if [[ "$LINEMAP_OUT" != *"──"* ]]; then
    pass "case16 linemap: NO session header text"
  else
    fail "case16 linemap: NO session header text" "found ──"
  fi
  # No `pid=NNN · repo` row content in linemap.
  if [[ "$LINEMAP_OUT" != *"pid="* ]]; then
    pass "case16 linemap: NO process header content"
  else
    fail "case16 linemap: NO process header content" "found pid="
  fi
}

# --- 17. Linemap rows carry line number + key + sid + cwd fields. ---
test_linemap_carries_required_fields() {
  local sandbox="$ROOT/case_linemap_fields"
  mkdir -p "$sandbox"
  local key; key=$(key_for "/solo")
  write_cache "$sandbox/.board-cache.json" \
    "$(mk_row v2 "$key" ses_n /solo sx needs-attention permission $((NOW_MS - 300000)) "need perm" "need perm" false 1 solo 100 terminal_0 0)"
  AGENT_FLEET_NOW_MS="$NOW_MS" run_render "$sandbox"
  # Every non-empty linemap line must have exactly 4 fields
  # (line<TAB>key<TAB>sid<TAB>cwd). Previously this assertion only counted
  # consecutive 4-field rows on one fixture; it now audits the whole file
  # so an accidental extra-column row cannot slip past.
  local bad_rows
  bad_rows="$(awk -F $'\t' 'NF != 4 && NF > 0 {print NR": ["$0"]"}' <<<"$LINEMAP_OUT")"
  if [ -z "$bad_rows" ]; then
    pass "case17 linemap: EVERY non-empty line is 4-column-shape"
  else
    fail "case17 linemap: rows missing or extra columns" "$bad_rows"
  fi
  # Pick the mapped row and decode its 4 fields with awk (positional read
  # collapses consecutive empty cells in bash, while awk preserves them).
  local mapped_line; mapped_line="$(printf '%s\n' "$LINEMAP_OUT")"
  assert_eq "case17 linemap: line number" "1" "$(linemap_field "$mapped_line" 1)"
  assert_eq "case17 linemap: key"        "$key" "$(linemap_field "$mapped_line" 2)"
  assert_eq "case17 linemap: sid"        "ses_n" "$(linemap_field "$mapped_line" 3)"
  assert_eq "case17 linemap: cwd"        "/solo" "$(linemap_field "$mapped_line" 4)"
}

# --- 18. Linemap nulls use empty fields (v1 row, warning row). ---
test_linemap_nulls_use_empty_fields() {
  local sandbox="$ROOT/case_linemap_nulls"
  mkdir -p "$sandbox"
  local keyV; keyV=$(key_for "/legacy")
  local keyW; keyW=$(key_for "/warn")
  write_cache "$sandbox/.board-cache.json" \
    "$(mk_row v1 "$keyV" "" /legacy sx done "" $((NOW_MS - 50000)) "" "legacy" false "" legacy "" terminal_0 0)" \
    "$(mk_row warning "$keyW" "" /warn sx duplicate "duplicate opencode instance" 0 "" "/warn" false "" "/warn" "" terminal_0 0)"
  AGENT_FLEET_NOW_MS="$NOW_MS" run_render "$sandbox"
  local mapped_line; mapped_line="$(printf '%s\n' "$LINEMAP_OUT")"
  assert_eq "case18 linemap: 2 mapped rows" "2" \
    "$(printf '%s\n' "$LINEMAP_OUT" | grep -c .)"
  # Sort puts warnings first (group=0 vs collapse group=2) within a single
  # session, so warning is line 1 and the v1 collapse row is line 2.
  local w_line; w_line="$(grep -F -e $'\t/warn' <<<"$mapped_line" | head -n1)"
  # bash `read w_num w_key w_sid w_cwd` collapses consecutive empty fields
  # before positional vars; use array read so empty cells stay where they
  # belong (the array's indices mirror field positions).
  assert_eq "case18 warning linemap: line=1"    "1" "$(linemap_field "$w_line" 1)"
  assert_eq "case18 warning linemap: key EMPTY" "" "$(linemap_field "$w_line" 2)"
  assert_eq "case18 warning linemap: sid EMPTY" "" "$(linemap_field "$w_line" 3)"
  assert_eq "case18 warning linemap: cwd"       "/warn" "$(linemap_field "$w_line" 4)"
  # v1 row (line=2, cwd=/legacy, key=$keyV, sid="").
  local v1_line
  v1_line="$(grep -F -e $'\t/legacy' <<<"$mapped_line" | head -n1)"
  assert_eq "case18 v1 linemap: line=2"        "2" "$(linemap_field "$v1_line" 1)"
  assert_eq "case18 v1 linemap: key set"       "$keyV" "$(linemap_field "$v1_line" 2)"
  assert_eq "case18 v1 linemap: sid EMPTY"     "" "$(linemap_field "$v1_line" 3)"
  assert_eq "case18 v1 linemap: cwd"           "/legacy" "$(linemap_field "$v1_line" 4)"
}

# --- 19. AGENT_FLEET_HIGHLIGHT_LINE wraps only mapped target row in reverse video. ---
test_highlight_wraps_mapped_target_row() {
  local sandbox="$ROOT/case_highlight"
  mkdir -p "$sandbox"
  local k1; k1=$(key_for "/solo")
  local k2; k2=$(key_for "/dual")
  write_cache "$sandbox/.board-cache.json" \
    "$(mk_row v2 "$k1" ses_a /solo sxA done "" $((NOW_MS - 5000)) "rowA" "rowA" false 0 solo 100 terminal_0 0)" \
    "$(mk_row v2 "$k2" ses_b /dual sxB done "" $((NOW_MS - 5000)) "rowB" "rowB" false 0 dual 200 terminal_0 0)"
  AGENT_FLEET_HIGHLIGHT_LINE="2" run_render "$sandbox"
  # The second mapped row (line 2) must contain \e[7m ... \e[27m.
  if [[ "$RENDER_OUT" == *$'\e[7m'* ]] && [[ "$RENDER_OUT" == *$'\e[27m'* ]]; then
    pass "case19 highlight: reverse-video escapes present"
  else
    fail "case19 highlight: reverse-video escapes present" \
      "want: \\e[7m and \\e[27m" "got escapes not both in output"
  fi
  # Assert wrap+reset count is exactly 1 (not 2). Reverse video is a toggle,
  # so wrap and reset must appear in pairs.
  local rev_count; rev_count=$(grep -c -F $'\e[7m' <<<"$RENDER_OUT" || true)
  assert_eq "case19 highlight: exactly 1 reverse-video wrap" "1" "$rev_count"
  local off_count; off_count=$(grep -c -F $'\e[27m' <<<"$RENDER_OUT" || true)
  assert_eq "case19 highlight: exactly 1 reverse-video reset" "1" "$off_count"
}

# --- 20. Unmapped highlight line is no-op (output identical to no-highlight run). ---
test_unmapped_highlight_line_no_change() {
  local sandbox="$ROOT/case_highlight_unmapped"
  mkdir -p "$sandbox"
  local key; key=$(key_for "/solo")
  write_cache "$sandbox/.board-cache.json" \
    "$(mk_row v2 "$key" ses_a /solo sx done "" $((NOW_MS - 5000)) "rowA" "rowA" false 0 solo 100 terminal_0 0)"
  AGENT_FLEET_NOW_MS="$NOW_MS" run_render "$sandbox"
  local out_plain="$RENDER_OUT"
  # HIGHLIGHT_LINE=99 (way past mapped rows) must produce identical output.
  AGENT_FLEET_NOW_MS="$NOW_MS" AGENT_FLEET_HIGHLIGHT_LINE="99" run_render "$sandbox"
  assert_eq "case20 unmapped highlight: stdout identical" "$out_plain" "$RENDER_OUT"
  # HIGHLIGHT_LINE=0 must NOT highlight either (lines start at 1).
  AGENT_FLEET_NOW_MS="$NOW_MS" AGENT_FLEET_HIGHLIGHT_LINE="0" run_render "$sandbox"
  assert_eq "case20 zero highlight: stdout identical" "$out_plain" "$RENDER_OUT"
  # HIGHLIGHT_LINE="abc" (non-numeric) must NOT highlight either.
  AGENT_FLEET_NOW_MS="$NOW_MS" AGENT_FLEET_HIGHLIGHT_LINE="abc" run_render "$sandbox"
  assert_eq "case20 non-numeric highlight: stdout identical" "$out_plain" "$RENDER_OUT"
  # HIGHLIGHT_LINE="01" (leading zero — fails ^[1-9][0-9]*$) must be no-op too.
  AGENT_FLEET_NOW_MS="$NOW_MS" AGENT_FLEET_HIGHLIGHT_LINE="01" run_render "$sandbox"
  assert_eq "case20 leading-zero highlight: stdout identical" "$out_plain" "$RENDER_OUT"
}

# --- 22. Sentinel-`-` collision: literal `-` key and sid survive identity. ---
# jq `@json` encodes `"-"` as the literal 4-byte token `"-".` (the string with
# its quotes), null as `null`, and every key/sid byte from the prior render
# path. A row whose identities ARE `-` must not be aliased onto the
# `null`/absent cell, nor onto any other NULLable-field sentinel/`-`.
test_legitimate_dash_identity_survives() {
  local sandbox="$ROOT/case_dash_identity"
  mkdir -p "$sandbox"
  # Row with key="-" and sid="-", legitimately produced (in this fixture).
  # The linemap must preserve those literal `-` bytes — not collapse them
  # to empty / null.
  printf '{"rows":[{"source":"v2","key":"-","sid":"-","cwd":"/dash_cwd","session":"sx","state":"done","reason":null,"ts":1000,"title":"dashy","label":"dashy","suppressed":false,"rank":0,"pid":0,"pane":"x","tabId":"0","repo":"dash"}]}' > "$sandbox/.board-cache.json"
  AGENT_FLEET_NOW_MS="$NOW_MS" run_render "$sandbox"
  # Linemap entry: line=1, key="-", sid="-", cwd=/dash_cwd.
  assert_eq "case22 dash: linemap key field is literal '-'" "-" "$(linemap_field "$LINEMAP_OUT" 2)"
  assert_eq "case22 dash: linemap sid field is literal '-'" "-" "$(linemap_field "$LINEMAP_OUT" 3)"
  assert_eq "case22 dash: linemap cwd is /dash_cwd" "/dash_cwd" "$(linemap_field "$LINEMAP_OUT" 4)"
  # Painted frame shows the row title ("dashy" — derived from title field,
  # not from the `-`-key fallback).
  assert_contains "case22 dash: 'dashy' title paints" "$RENDER_OUT" "dashy"
}

# --- 25. JSON-encoded identity cells decode back to their exact bytes. ---
test_json_encoded_identity_decodes_exactly() {
  local sandbox="$ROOT/case_json_identity"
  mkdir -p "$sandbox"
  write_cache "$sandbox/.board-cache.json" \
    "$(mk_row v2 'k"x' 's\x' /json_identity sx done "" $((NOW_MS - 5000)) "identity" "identity" false 0 json 25001 terminal_0 0)"
  AGENT_FLEET_NOW_MS="$NOW_MS" run_render "$sandbox"
  local expected
  expected="$(jq -nr \
    --arg key 'k"x' \
    --arg sid 's\x' \
    --arg cwd '/json_identity' \
    '"1\t" + $key + "\t" + $sid + "\t" + $cwd')"
  assert_eq "case25 JSON identity: linemap preserves quote and backslash bytes" \
    "$expected" "$LINEMAP_OUT"
}

# --- 23. Partial-frame failure leaves an EMPTY linemap (NOT the stale one). ---
# Renderer pre-installs an empty `.board-linemap.tsv` BEFORE painting. A
# mid-paint failure (jq or `printf %d` choking on a non-numeric ts) leaves
# that empty map in place — keyboard nav then sees no identity matches
# against the new (partial) frame, never stale rows from the previous
# frame that no longer correspond to anything on screen.
test_partial_frame_failure_leaves_empty_linemap() {
  local sandbox="$ROOT/case_partial_failure"
  mkdir -p "$sandbox"
  # Pre-populate a stale linemap (e.g. from a previous frame) so we can
  # assert it gets replaced after a failure.
  printf 'STALE-LINE-1\tkey_a\tsid_a\t/x\nSTALE-LINE-2\tkey_b\tsid_b\t/y\n' > "$sandbox/.board-linemap.tsv"
  # Cache fixture with rows whose `ts` is a STRING, not a number. The
  # renderer's `age_for` aborts on non-numeric inputs, tripping the paint
  # mid-frame.
  printf '{"rows":[{"source":"v2","key":"abc","sid":"ses_x","cwd":"/cwd_x","session":"sx","state":"done","reason":null,"ts":"not_a_number","title":"t","label":"t","suppressed":false,"rank":0,"pid":0,"pane":"x","tabId":"0","repo":"x"}]}' > "$sandbox/.board-cache.json"
  run_render "$sandbox"
  # 1) renderer exits non-zero on mid-paint failure.
  if [ "$RC" -ne 0 ]; then
    pass "case_partial: renderer exits non-zero on mid-paint failure"
  else
    fail "case_partial: renderer exits non-zero on mid-paint failure" "rc=$RC"
  fi
  # 2) The stale linemap content must NOT survive.
  if [[ "$LINEMAP_OUT" == *"STALE-LINE-1"* ]]; then
    fail "case_partial: stale linemap kept after failure" "STALE content visible"
  else
    pass "case_partial: stale linemap replaced by empty after failure"
  fi
  if [[ "$LINEMAP_OUT" == *"STALE-LINE-2"* ]]; then
    fail "case_partial: stale linemap kept after failure" "STALE content visible"
  else
    pass "case_partial: stale linemap entirely gone"
  fi
  # 3) The linemap file exists AND is empty (pre-install survived the
  # abort; nothing partial was mis-installed by the painter's tmp).
  if [ -f "$LINEMAP_PATH" ] && [ ! -s "$LINEMAP_PATH" ]; then
    pass "case_partial: empty linemap present after failure"
  else
    fail "case_partial: empty linemap present after failure" "size=$(wc -c <"$LINEMAP_PATH")"
  fi
  # 4) The painter's tmp file must NOT have mis-installed partial content.
  if ! ls "$sandbox"/.board-linemap.tsv.tmp.* >/dev/null 2>&1; then
    pass "case_partial: no leftover painter tmp from partial frame"
  else
    fail "case_partial: leftover painter tmp(s)" "$(ls "$sandbox"/.board-linemap.tsv.tmp.* 2>/dev/null)"
  fi
}

# --- 24. Control character in identity field: skipped with stderr warning. ---
# Linux bash's `while read -r` and jq `@tsv` both treat TAB/LF/CR as field
# separators and would alias distinct identities after round-trip. The
# renderer rejects offending rows in jq (.rows[].key/sid/cwd test($bad)),
# prints a `skipping row with control char in …` warning per row to
# stderr, and keeps the LINEMAP clean. Clean (non-offending) rows still
# map byte-exact.
test_control_chars_in_identity_skip_and_warn() {
  local sandbox="$ROOT/case_ctrl_char"
  mkdir -p "$sandbox"
  # Build the cache fixture with python (bypasses shell-level TAB escaping
  # — jq refuses raw TAB bytes in JSON input).
  python3 -c '
import json, sys
rows = [
  {"source":"v2","key":"abc","sid":"ses1","cwd":"/good","session":"sxA",
   "state":"done","reason":None,"ts":1000,"title":"good","label":"good",
   "suppressed":False,"rank":0,"pid":0,"pane":"x","tabId":"0","repo":"good"},
  # bad row: literal TAB inside the cwd string.
   {"source":"v2","key":"abc","sid":"ses2","cwd":"/has\ttab","session":"sxB",
    "state":"done","reason":None,"ts":2000,"title":"badtitle","label":"badlabel",
    "suppressed":False,"rank":0,"pid":0,"pane":"x","tabId":"0","repo":"bad"},
   # bad warning row: literal TAB inside cwd must warn and stay filtered.
   {"source":"warning","key":None,"sid":None,"cwd":"/warn\ttab","session":"sxW",
    "state":"unknown","reason":"duplicate","ts":0,"title":None,"label":"/warn",
    "suppressed":False,"rank":None,"pid":None,"pane":"x","tabId":"0","repo":"warn"},
]
print(json.dumps({"rows": rows}))
' > "$sandbox/.board-cache.json"
  local tmp_err="$ROOT/err-ctrl.txt"
  set +e
  AGENT_FLEET_STATE_DIR="$sandbox" AGENT_FLEET_NOW_MS="$NOW_MS" \
    bash "$RENDER" > "$sandbox/stdout.txt" 2> "$tmp_err"
  set -e
  # Refresh linemap path to this sandbox's actual file: test 24's run_render
  # was bypassed, so we read the sandbox's linemap directly.
  local sandbox_linemap="$sandbox/.board-linemap.tsv"
  # 1) stderr warning names the offending field.
  if grep -F "control char" "$tmp_err" >/dev/null && grep -F "[bad=cwd]" "$tmp_err" >/dev/null; then
    pass "case_ctrl: stderr names control char + field=cwd"
  else
    fail "case_ctrl: stderr names control char + field=cwd" "stderr=$(cat $tmp_err)"
  fi
  # 2) stderr warning mentions the BAD row's identity, not the good one.
  if grep -F "key=abc sid=ses2" "$tmp_err" >/dev/null; then
    pass "case_ctrl: stderr names the bad row"
  else
    fail "case_ctrl: stderr names the bad row" "stderr=$(cat $tmp_err)"
  fi
  # 3) warning-source rows get the same rejection warning before filtering.
  if grep -F "key=<null> sid=<null> cwd=/warn" "$tmp_err" >/dev/null \
    && grep -F "[bad=cwd]" "$tmp_err" >/dev/null; then
    pass "case_ctrl: warning-source row emits control-char warning"
  else
    fail "case_ctrl: warning-source row emits control-char warning" "stderr=$(cat $tmp_err)"
  fi
  # 4) stdout does NOT include the bad row's identity.
  local stdout; stdout="$(cat "$sandbox/stdout.txt")"
  if [[ "$stdout" != *"badtitle"* ]] && [[ "$stdout" != *"badlabel"* ]] && [[ "$stdout" != *"/has"* ]]; then
    pass "case_ctrl: bad row filtered from painted frame"
  else
    fail "case_ctrl: bad row filtered from painted frame" "stdout=$stdout"
  fi
  # 5) The warning row is also absent from the painted frame and linemap.
  local linemap; linemap="$(cat "$sandbox_linemap")"
  if [[ "$stdout" != *"/warn"* ]] && [[ "$linemap" != *"/warn"* ]]; then
    pass "case_ctrl: warning-source row filtered from frame and linemap"
  else
    fail "case_ctrl: warning-source row filtered from frame and linemap" \
      "stdout=$stdout" "linemap=$linemap"
  fi
  # 6) The good row still maps by exact byte identity in the linemap.
  if grep -qF "/good" <<<"$linemap"; then
    pass "case_ctrl: clean row mapped byte-exact"
  else
    fail "case_ctrl: clean row mapped byte-exact" "linemap=$linemap"
  fi
}

# --- 21. Linemap write is atomic — pre-existing stale map is replaced, not appended. ---
test_linemap_atomic_replaces_stale() {
  local sandbox="$ROOT/case_linemap_atomic"
  mkdir -p "$sandbox"
  # Pre-write stale garbage to the linemap path so we can verify a fully
  # replaced file (no leftover bytes from the stale content).
  printf 'stale-line-1\nstale-line-2\n' > "$sandbox/.board-linemap.tsv"
  local key; key=$(key_for "/solo")
  write_cache "$sandbox/.board-cache.json" \
    "$(mk_row v2 "$key" ses_a /solo sx done "" $((NOW_MS - 5000)) "rowA" "rowA" false "" solo 100 terminal_0 0)"
  run_render "$sandbox"
  # Stale content must NOT survive.
  assert_not_contains "case21 linemap: stale 'stale-line-1' purged" "$LINEMAP_OUT" "stale-line-1"
  assert_not_contains "case21 linemap: stale 'stale-line-2' purged" "$LINEMAP_OUT" "stale-line-2"
  # Fresh content must ITS fresh row.
  assert_contains "case21 linemap: fresh row visible" "$LINEMAP_OUT" "/solo"
  # Length consistency: 1 mapped row.
  assert_eq "case21 linemap: exactly 1 mapped row" "1" \
    "$(printf '%s\n' "$LINEMAP_OUT" | grep -c .)"
}

# --- 22. Footer exposes board controls, including dismissal. ---
test_help_footer_shows_dismiss_key() {
  local sandbox="$ROOT/case_help_footer"
  mkdir -p "$sandbox"
  local key; key=$(key_for "/help")
  write_cache "$sandbox/.board-cache.json" \
    "$(mk_row v2 "$key" ses_help /help sx done "" "$NOW_MS" "help" "help" false 0 help 100 terminal_0 0)"
  run_render "$sandbox"
  assert_contains "case22 footer: dismiss key shown" "$RENDER_OUT" "d: dismiss"
  assert_contains "case22 footer: open key shown" "$RENDER_OUT" "Enter: open"
  assert_count "case22 footer: rendered once" "$RENDER_OUT" \
    "j/k or arrows: move | Enter: open | d: dismiss | q: quit" "1"
  assert_eq "case22 footer: one renderer emission" "1" \
    "$(grep -c -F 'j/k or arrows: move | Enter: open | d: dismiss | q: quit' "$RENDER")"
}

# --- 23. Live instance header remains when it has no visible chat rows. ---
test_live_instance_header_without_rows() {
  local sandbox="$ROOT/case_live_header"
  mkdir -p "$sandbox"
  printf '%s\n' '{"rows":[],"live":[{"session":"fresh-zellij","cwd":"/fresh","pane":"terminal_0","tabId":"0"}]}' \
    > "$sandbox/.board-cache.json"
  run_render "$sandbox"
  assert_contains "case23 live header: session name shown" "$RENDER_OUT" "FRESH-ZELLIJ"
  assert_eq "case23 live header: exactly one session header" "1" \
    "$(grep -c -F '── FRESH-ZELLIJ ──────────────' <<<"$RENDER_OUT" || true)"
}

# --- 24. Footer separator clears rows removed by a shorter redraw. ---
test_footer_separator_clears_removed_row() {
  local sandbox="$ROOT/case_footer_separator"
  mkdir -p "$sandbox"
  local key_a; key_a=$(key_for "/footer-a")
  local key_b; key_b=$(key_for "/footer-b")
  write_cache "$sandbox/.board-cache.json" \
    "$(mk_row v2 "$key_a" sid-a /footer-a sx done "" "$NOW_MS" "row-a" "row-a" false 0 footer-a 100 terminal_0 0)" \
    "$(mk_row v2 "$key_b" sid-b /footer-b sx done "" "$NOW_MS" "row-b" "row-b" false 0 footer-b 101 terminal_1 0)"
  run_render "$sandbox"

  write_cache "$sandbox/.board-cache.json" \
    "$(mk_row v2 "$key_a" sid-a /footer-a sx done "" "$NOW_MS" "row-a" "row-a" false 0 footer-a 100 terminal_0 0)"
  run_render "$sandbox"

  assert_contains "case24 footer separator: clears removed row" "$RENDER_OUT" \
    $'\e[K\n\e[K\n  j/k or arrows: move | Enter: open | d: dismiss | q: quit'
}

# === run all ===
run_test() {
  printf '\n--- %s ---\n' "$1"
  "$1"
  printf '  (running)\n'
}

run_test test_v2_single_session_collapses_one_line
run_test test_v2_multi_session_nests_under_process
run_test test_duplicate_cwd_renders_warning
run_test test_no_state_file_synthetic_unknown_row
run_test test_suppresses_viewed_terminal_never_working
run_test test_idle_paints_with_suppressed_done_siblings
run_test test_v1_only_legacy_row
run_test test_v1_v2_super_a_usable_v2_suppresses_v1
run_test test_v1_v2_super_b_dead_v2_does_not_suppress_v1
run_test test_viewed_done_sessions_show_idle_process
run_test test_multi_cwd_independent_render
run_test test_long_labels_do_not_shift_age_column
run_test test_nested_rows_keep_columns_aligned
run_test test_missing_cache_prints_empty_frame
run_test test_invalid_cache_prints_empty_frame
run_test test_renderer_never_invokes_model
run_test test_linemap_excludes_headers_and_blanks
run_test test_linemap_carries_required_fields
run_test test_linemap_nulls_use_empty_fields
run_test test_highlight_wraps_mapped_target_row
run_test test_unmapped_highlight_line_no_change
run_test test_linemap_atomic_replaces_stale
run_test test_help_footer_shows_dismiss_key
run_test test_live_instance_header_without_rows
run_test test_footer_separator_clears_removed_row
run_test test_legitimate_dash_identity_survives
run_test test_json_encoded_identity_decodes_exactly
run_test test_partial_frame_failure_leaves_empty_linemap
run_test test_control_chars_in_identity_skip_and_warn

echo
echo "---"
echo "PASS: $PASS  FAIL: $FAIL"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
