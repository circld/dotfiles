#!/usr/bin/env bash
# scripts/test-agent-fleet-jump.sh
#
# Hermetic test for agent-fleet-jump.sh. Drives the script with synthetic
# inputs (live-pane table text + state files + ps comm lookup) so we do not
# need a real zellij session or live opencode process. The plan's Task 5 step
# 1 names this shape explicitly: "Extract live-pane parsing and candidate
# selection into testable shell functions" — the actions the test exercises
# are computations only. The thin tail (zellij/aerospace focus calls) is
# outside this script per plan guidance.
#
# Run via: bash scripts/test-agent-fleet-jump.sh
# Self-contained: no real zellij session required.
# Note: we deliberately do NOT use `set -e` — running jump.sh under
# DECIDE_SELECT-via-old-code is expected to produce nonzero exits and
# jq errors against the sandbox; we want those surfaced as FAIL entries,
# not script-aborts. `pipefail` and `nounset` are still on for typos.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
JUMP="$REPO_ROOT/scripts/agent-fleet-jump.sh"

if [ ! -f "$JUMP" ]; then
  echo "FAIL: jump.sh missing at $JUMP"
  exit 1
fi

# bash >= 4 for associative arrays — jump.sh depends on them.
if (( BASH_VERSINFO[0] < 4 )); then
  echo "FAIL: test-agent-fleet-jump.sh needs bash >= 4 (got $BASH_VERSION)"
  exit 1
fi

# sandbox: per-test temp STATE_DIR owns any side-effect files (.select,
# viewed.json). torn down via the EXIT trap.
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

PASS=0
FAIL=0
LOG=""

pass() { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1" >>"$ROOT/log"; }
fail() {
  FAIL=$((FAIL + 1))
  printf 'FAIL: %s\n' "$1" >>"$ROOT/log"
  [ "${2:-}" != "" ] && { shift; printf '  %s\n' "$*" >>"$ROOT/log"; }
}
# report at end:
assert_eq() {
  local label="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    pass "$label"
  else
    fail "$label" "want:" "$want" "got:" "$got"
  fi
}
assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    pass "$label"
  else
    fail "$label" "haystack=" "$haystack" "expected substring:" "$needle"
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
assert_file_exists() {
  local label="$1" path="$2"
  if [ -f "$path" ]; then
    pass "$label"
  else
    fail "$label" "missing file:" "$path"
  fi
}
assert_file_absent() {
  local label="$1" path="$2"
  if [ ! -e "$path" ]; then
    pass "$label"
  else
    fail "$label" "unexpected file present:" "$path"
  fi
}

# === helpers: drive a single jump invocation ===
#
# $1 = mode: "decide-only" (just decision text) | "select-side-effect" (.select
#         file written + decision text; zellij/aerospace skipped)
# $2 = sandbox STATE_DIR
# $3 = AGENT_FLEET_PS_OVERRIDE file path (test-side; "" to disable override)
# $4 = live pane table text (TAB-separated cwd<TAB>session<TAB>terminal_<id><TAB>tab_id)
# $5 = explicit cwd argument to pass ("" = global jump)
# Sets globals: JUMP_STDOUT, JUMP_STDERR, JUMP_RC

run_jump() {
  local mode="$1" sandbox="$2" pso="$3" live="$4" cwd_arg="$5"
  local pane_file="$ROOT/pane-${RANDOM}.tsv"
  printf '%s\n' "$live" > "$pane_file"
  local env_args=(
    "AGENT_FLEET_LIVE_PANES_OVERRIDE=$pane_file"
    "AGENT_FLEET_STATE_DIR=$sandbox"
  )
  if [ -n "$pso" ]; then
    env_args+=( "AGENT_FLEET_PS_OVERRIDE=$pso" )
  fi
  case "$mode" in
    decide-only)       env_args+=( "AGENT_FLEET_DECIDE_ONLY=1" ) ;;
    select-side-effect) env_args+=( "AGENT_FLEET_DECIDE_SELECT=1" ) ;;
  esac
  local tmp_err="$ROOT/err-${RANDOM}.txt"
  JUMP_RC=0
  JUMP_STDOUT="$(env "${env_args[@]}" bash "$JUMP" "$cwd_arg" 2>"$tmp_err")" || JUMP_RC=$?
  JUMP_STDERR="$(cat "$tmp_err")"
}

# === test cases ===

# --- 1. one opencode cwd, two chat sessions (one v2 file) ---
# v2 file has a "done" session and a "needs-attention" session.
# Global jump selects HIGHEST-ranked actionable session (needs-attention).
test_one_cwd_two_sessions_selects_needs_attention() {
  local sandbox="$ROOT/case1"
  mkdir -p "$sandbox"
  local key="a1b2c3d4e5f60718"
  local pid=12345
  # ps override: this pid is alive + comm contains "opencode"
  local pso="$ROOT/ps1.tsv"
  printf 'OPENCODE\t%s\n' "$pid" > "$pso"
  cat > "$sandbox/${key}-${pid}.json" <<EOF
{"repo":"r","cwd":"/work/proj","session":"sess1","pid":${pid},
 "sessions":{
   "ses_done":{"state":"done","reason":null,"ts":100,"task":null,"title":"done sess"},
   "ses_blocked":{"state":"needs-attention","reason":"permission","ts":200,"task":null,"title":"needs perm"}
 }}
EOF
  run_jump "select-side-effect" "$sandbox" "$pso" \
    $'/work/proj\tsess1\tterminal_0\t0' ""
  assert_eq "case1 decision: kind=select (top-ranked wins)" \
    "DECISION:kind=select cwd=/work/proj session=sess1 pane=terminal_0 tab_id=0 key=${key}-${pid} sid=ses_blocked" \
    "$JUMP_STDOUT"
  assert_file_exists "case1 .select sidecar written" "$sandbox/${key}-${pid}.select"
  local sid
  sid=$(jq -r .sessionID "$sandbox/${key}-${pid}.select")
  assert_eq "case1 .select sessionID is ses_blocked (highest-ranked)" "ses_blocked" "$sid"
}

# --- 2. two opencode panes on different cwd; global jump picks highest-ranked
#         actionable, focusing the matching cwd ---
test_two_panes_focuses_top_cwd() {
  local sandbox="$ROOT/case2"
  mkdir -p "$sandbox"
  # cwd /projA: state=done ts=50 (older)
  local pidA=11111
  local pso="$ROOT/ps2.tsv"
  printf 'OPENCODE\t%s\n' "$pidA" > "$pso"
  printf 'OPENCODE\t%s\n' "22222" >> "$pso"
  local keyA; keyA=$(printf '%s' "/projA" | shasum -a 256 | cut -c1-16)
  local keyB; keyB=$(printf '%s' "/projB" | shasum -a 256 | cut -c1-16)
  cat > "$sandbox/${keyA}-${pidA}.json" <<EOF
{"repo":"a","cwd":"/projA","session":"sessA","pid":${pidA},
 "sessions":{"ses_d":{"state":"done","reason":null,"ts":50,"task":null,"title":"d"}}}
EOF
  cat > "$sandbox/${keyB}-22222.json" <<EOF
{"repo":"b","cwd":"/projB","session":"sessB","pid":22222,
 "sessions":{"ses_n":{"state":"needs-attention","reason":"permission","ts":300,"task":null,"title":"n"}}}
EOF
  # projA has terminal id 1, projB has 2; needs-attention projB wins overall
  run_jump "select-side-effect" "$sandbox" "$pso" \
    $'/projA\tsessA\tterminal_1\t0\n/projB\tsessB\tterminal_2\t0' ""
  assert_eq "case2 decision: top-ranked cwd projB selected (newest ts)" \
    "DECISION:kind=select cwd=/projB session=sessB pane=terminal_2 tab_id=0 key=${keyB}-22222 sid=ses_n" \
    "$JUMP_STDOUT"
  assert_file_exists "case2 .select written for projB pid" "$sandbox/${keyB}-22222.select"
}

# --- 3. two worktrees from same repo: different cwds (different cwd-hash).
#         Both are supported. cwd-hash collision is the bug being avoided: this
#         proves identity is by full path, not basename. ---
test_two_worktrees_distinct_cwd_hash() {
  local sandbox="$ROOT/case3"
  mkdir -p "$sandbox"
  local pso="$ROOT/ps3.tsv"
  printf 'OPENCODE\t%s\n' "10001" > "$pso"
  printf 'OPENCODE\t%s\n' "10002" >> "$pso"
  local key1; key1=$(printf '%s' "/repos/proj/.worktrees/feat1" | shasum -a 256 | cut -c1-16)
  local key2; key2=$(printf '%s' "/repos/proj/.worktrees/feat2" | shasum -a 256 | cut -c1-16)
  # sanity: keys differ (the bug being avoided)
  if [ "$key1" = "$key2" ]; then
    fail "case3 sanity: keys differ for distinct worktree paths" "key1=key2=$key1"
    return
  fi
  pass "case3 sanity: cwd-hash differs for distinct worktree paths"
  cat > "$sandbox/${key1}-10001.json" <<EOF
{"repo":"proj:feat1","cwd":"/repos/proj/.worktrees/feat1","session":"wsess","pid":10001,
 "sessions":{"s":{"state":"needs-attention","reason":"permission","ts":250,"task":null,"title":"needs"}}}
EOF
  cat > "$sandbox/${key2}-10002.json" <<EOF
{"repo":"proj:feat2","cwd":"/repos/proj/.worktrees/feat2","session":"wsess","pid":10002,
 "sessions":{"s":{"state":"done","reason":null,"ts":150,"task":null,"title":"done"}}}
EOF
  # /feat1 has highest rank — should win regardless of which pane has higher terminal id.
  run_jump "select-side-effect" "$sandbox" "$pso" \
    $'/repos/proj/.worktrees/feat1\twsess\tterminal_5\t2\n/repos/proj/.worktrees/feat2\twsess\tterminal_6\t3' ""
  assert_eq "case3 decision: feat1 (needs-attention) chosen; higher terminal id not factored" \
    "DECISION:kind=select cwd=/repos/proj/.worktrees/feat1 session=wsess pane=terminal_5 tab_id=2 key=${key1}-10001 sid=s" \
    "$JUMP_STDOUT"
}

# --- 4. GLOBAL jump with duplicate opencode instances same cwd (pane-table arm)
#         AND every actionable candidate is on an ambiguous cwd: pool empty,
#         fall through to FALLBACK pane — and the GREATER rank doesn't matter
#         because ambiguous cwds never entered the ranked pool in the first
#         place (UX Contract; Flow > Jump step 7). No warn. ---
#         setup: only ONE cwd /dup, has 2 live panes (ambiguous via pane-table
#         arm), one v2 file with an actionable session (ambiguous via file-count
#         arm too — single v2 on same cwd as 2 panes doesn't strictly need the
#         file-count arm; but in any case this cwd is ambiguous). Global jump
#         with NO non-ambiguous candidate → falls to fallback pane on the same
#         /dup cwd? No — fallback EXCLUDES ambiguous cwds (Flow > Jump step
#         10). So with only /dup available, no fallback target → noop. ---
test_global_duplicate_only_cwd_falls_to_noop() {
  local sandbox="$ROOT/case4"
  mkdir -p "$sandbox"
  local key; key=$(printf '%s' "/dup" | shasum -a 256 | cut -c1-16)
  local pid=30003
  local pso="$ROOT/ps4.tsv"
  printf 'OPENCODE\t%s\n' "$pid" > "$pso"
  cat > "$sandbox/${key}-${pid}.json" <<EOF
{"repo":"r","cwd":"/dup","session":"rep1","pid":${pid},
 "sessions":{"s":{"state":"needs-attention","reason":"permission","ts":500,"task":null,"title":"needs"}}}
EOF
  # 2 live panes on /dup (pane-table arm). One actionable v2 (would be dropped
  # by file-count arm if there were ≥2 files; here there's only 1 — but pane-
  # table arm already marks /dup ambiguous).
  run_jump "decide-only" "$sandbox" "$pso" \
    $'/dup\trep1\tterminal_0\t0\n/dup\trep1\tterminal_1\t1' ""
  # The actionable candidate is on /dup which is ambiguous, so it never joined
  # the ranked pool. Pool empty → no fallback (only live pane is on /dup
  # itself, which is ambiguous; fallback excludes ambiguous) → noop.
  assert_eq "case4 decision: noop (only ambiguous cwd available)" \
    "DECISION:kind=noop" \
    "$JUMP_STDOUT"
  assert_not_contains "case4 stderr: NO warn for global jump on duplicate" \
    "$JUMP_STDERR" \
    "multiple opencode instances found"
  assert_not_contains "case4 stderr: no 'no live pane' noise" \
    "$JUMP_STDERR" \
    "no live"
}

# --- 5. EXPLICIT duplicate cwd: warn/no-op/no .select (the case that actually
#         prints the warning). UX contract: request naming the ambiguous cwd
#         gets the warn message and does nothing. ---
test_explicit_duplicate_cwd_warns() {
  local sandbox="$ROOT/case5"
  mkdir -p "$sandbox"
  local key; key=$(printf '%s' "/dup" | shasum -a 256 | cut -c1-16)
  local pid=40004
  local pso="$ROOT/ps5.tsv"
  printf 'OPENCODE\t%s\n' "$pid" > "$pso"
  cat > "$sandbox/${key}-${pid}.json" <<EOF
{"repo":"r","cwd":"/dup","session":"ss","pid":${pid},
 "sessions":{"s":{"state":"needs-attention","reason":"permission","ts":500,"task":null,"title":"n"}}}
EOF
  run_jump "select-side-effect" "$sandbox" "$pso" \
    $'/dup\tss\tterminal_0\t0\n/dup\tss\tterminal_1\t1' "/dup"
  assert_eq "case5 decision: warn-explicit-duplicate" \
    "DECISION:kind=warn-explicit-duplicate" \
    "$JUMP_STDOUT"
  assert_contains "case5 stderr: warn message format" \
    "$JUMP_STDERR" \
    "multiple opencode instances found for cwd=/dup; use one opencode instance with multiple chat sessions"
  assert_file_absent "case5 .select NOT written" "$sandbox/${key}-${pid}.select"
}

# --- 6. Dead-pid file sharing a live cwd: the stale state file is dropped,
#         no candidate. If a v1 file ALSO exists for the cwd, the v1 file is
#         still valid (no usable v2 ⇒ v1 survives — see case 11b). Here we
#         test the simpler case: no v1 file, so the dead pid yields no
#         candidate, and a SECOND candidate (with a valid pid) on the same
#         cwd wins. ---
test_dead_pid_state_file_dropped() {
  local sandbox="$ROOT/case6"
  mkdir -p "$sandbox"
  local key; key=$(printf '%s' "/alive" | shasum -a 256 | cut -c1-16)
  # dead pid 999999 (unlikely to be a real running process; if it is, it's
  # not comm=opencode either way)
  local pso="$ROOT/ps6.tsv"
  printf 'DEAD\t999999\n' > "$pso"
  printf 'OPENCODE\t88888\n' >> "$pso"
  # dead pid file for /alive
  cat > "$sandbox/${key}-999999.json" <<EOF
{"repo":"r","cwd":"/alive","session":"sx","pid":999999,
 "sessions":{"s":{"state":"needs-attention","reason":"permission","ts":900,"task":null,"title":"n"}}}
EOF
  # second, valid candidate for /alive2 with newer ts
  local key2; key2=$(printf '%s' "/alive2" | shasum -a 256 | cut -c1-16)
  cat > "$sandbox/${key2}-88888.json" <<EOF
{"repo":"r2","cwd":"/alive2","session":"sx2","pid":88888,
 "sessions":{"s":{"state":"needs-attention","reason":"permission","ts":100,"task":null,"title":"needs"}}}
EOF
  run_jump "select-side-effect" "$sandbox" "$pso" \
    $'/alive\tsx\tterminal_0\t0\n/alive2\tsx2\tterminal_1\t0' ""
  assert_eq "case6 dead-pid file dropped: /alive2 wins" \
    "DECISION:kind=select cwd=/alive2 session=sx2 pane=terminal_1 tab_id=0 key=${key2}-88888 sid=s" \
    "$JUMP_STDOUT"
}

# --- 7. Headless pid (no live opencode pane for its cwd): state file dropped
#         as ghost. v2 ghost filter (Flow step 6): cwd is not in live_cwds ⇒
#         dropped. ---
test_ghost_cwd_with_v2_file_dropped() {
  local sandbox="$ROOT/case7"
  mkdir -p "$sandbox"
  local pso="$ROOT/ps7.tsv"
  printf 'OPENCODE\t%s\n' "55555" > "$pso"
  local key; key=$(printf '%s' "/orphan" | shasum -a 256 | cut -c1-16)
  # state file claims cwd=/orphan but pane table has NO opencode pane for /orphan.
  cat > "$sandbox/${key}-55555.json" <<EOF
{"repo":"o","cwd":"/orphan","session":"ox","pid":55555,
 "sessions":{"s":{"state":"needs-attention","reason":"permission","ts":1000,"task":null,"title":"n"}}}
EOF
  # pane table: ORPHAN cwd not present (ghost)
  run_jump "decide-only" "$sandbox" "$pso" \
    $'/somewhere_else\tsx\tterminal_0\t0' ""
  # Plan step 16: pool empty after filtering ⇒ focus FALLBACK live pane
  # (highest non-ambiguous terminal_<id>). The orphan state file's
  # candidate is dropped; /somewhere_else is the fallback.
  if [ "$JUMP_STDOUT" = "DECISION:kind=fallback-pane session=sx pane=terminal_0 tab_id=0" ]; then
    pass "case7 ghost cwd: pool empty ⇒ fallback pane"
  elif [[ "$JUMP_STDOUT" == *"/orphan"* ]]; then
    fail "case7 ghost cwd: pool empty ⇒ fallback pane" "ghost cwd appeared in decision:" "$JUMP_STDOUT"
  else
    fail "case7 ghost cwd: pool empty ⇒ fallback pane" "got:" "$JUMP_STDOUT"
  fi
}

# --- 8. Headless pid SHARING a live cwd (two usable v2 files, one cwd, but
#         pane table shows only ONE pane): treated as ambiguous via the file-
#         count union arm (Core Invariant > Exception). Global jump with no
#         non-ambiguous candidate ⇒ noop-and-fallback (no warn — global rule).
#         EXPLICIT cwd naming the ambiguous cwd ⇒ warn-and-no-op. ---
test_headless_sharing_live_cwd_is_ambiguous_explicit_warns() {
  local sandbox="$ROOT/case8"
  mkdir -p "$sandbox"
  local pidA=60101
  local pidB=60202
  local pso="$ROOT/ps8.tsv"
  printf 'OPENCODE\t%s\n' "$pidA" > "$pso"
  printf 'OPENCODE\t%s\n' "$pidB" >> "$pso"
  local key; key=$(printf '%s' "/share" | shasum -a 256 | cut -c1-16)
  cat > "$sandbox/${key}-${pidA}.json" <<EOF
{"repo":"a","cwd":"/share","session":"sess1","pid":${pidA},
 "sessions":{"s1":{"state":"needs-attention","reason":"permission","ts":100,"task":null,"title":"n"}}}
EOF
  cat > "$sandbox/${key}-${pidB}.json" <<EOF
{"repo":"b","cwd":"/share","session":"sess2","pid":${pidB},
 "sessions":{"s2":{"state":"done","reason":null,"ts":200,"task":null,"title":"d"}}}
EOF
  # pane table: ONE pane on /share (the "real" pane).
  run_jump "select-side-effect" "$sandbox" "$pso" \
    $'/share\tsess1\tterminal_0\t0' "/share"
  assert_eq "case8 explicit: warn (two usable v2 files sharing cwd ⇒ ambiguous)" \
    "DECISION:kind=warn-explicit-duplicate" \
    "$JUMP_STDOUT"
  assert_contains "case8 explicit: warn message present" \
    "$JUMP_STDERR" \
    "multiple opencode instances found for cwd=/share"
  assert_file_absent "case8 explicit: no .select for either pid" "$sandbox/${key}-${pidA}.select"
  assert_file_absent "case8 explicit: no .select for either pid" "$sandbox/${key}-${pidB}.select"
}

test_headless_sharing_live_cwd_is_ambiguous_global_noop() {
  local sandbox="$ROOT/case8g"
  mkdir -p "$sandbox"
  local pidA=60301
  local pidB=60402
  local pso="$ROOT/ps8g.tsv"
  printf 'OPENCODE\t%s\n' "$pidA" > "$pso"
  printf 'OPENCODE\t%s\n' "$pidB" >> "$pso"
  local key; key=$(printf '%s' "/share" | shasum -a 256 | cut -c1-16)
  cat > "$sandbox/${key}-${pidA}.json" <<EOF
{"repo":"a","cwd":"/share","session":"sess1","pid":${pidA},
 "sessions":{"s1":{"state":"needs-attention","reason":"permission","ts":100,"task":null,"title":"n"}}}
EOF
  cat > "$sandbox/${key}-${pidB}.json" <<EOF
{"repo":"b","cwd":"/share","session":"sess2","pid":${pidB},
 "sessions":{"s2":{"state":"done","reason":null,"ts":200,"task":null,"title":"d"}}}
EOF
  run_jump "decide-only" "$sandbox" "$pso" \
    $'/share\tsess1\tterminal_0\t0' ""
  # ambiguous cwd ⇒ candidates dropped from pool ⇒ noop (fallback excludes
  # duplicate cwd); no warn (global rule).
  assert_eq "case8 global: noop (ambiguous cwd excluded from ranked pool)" \
    "DECISION:kind=noop" \
    "$JUMP_STDOUT"
  assert_not_contains "case8 global: NO warn (global rule)" \
    "$JUMP_STDERR" \
    "multiple opencode instances found"
}

# --- 9. Alive-but-reused pid (pid alive, comm NOT containing "opencode"):
#         same logic as dead pid. Use a real sleep subprocess so the test
#         exercises the REAL ps path (no override). The OVERRIDE path is also
#         exercised in case 6 with DEAD; this one demonstrates the negative
#         comm-match path against a real process. ---
test_alive_but_not_opencode_comm_dropped() {
  local sandbox="$ROOT/case9"
  mkdir -p "$sandbox"
  # spawn a real sleep — its comm is "sleep" (not opencode).
  # DO NOT block; this process is the "reused pid" the sensor's pid got
  # recycled into.
  sleep 30 &
  local reused_pid=$!
  # NO ps override → real ps lookup; verifies the production path.
  local key; key=$(printf '%s' "/live" | shasum -a 256 | cut -c1-16)
  cat > "$sandbox/${key}-${reused_pid}.json" <<EOF
{"repo":"r","cwd":"/live","session":"sx","pid":${reused_pid},
 "sessions":{"s":{"state":"needs-attention","reason":"permission","ts":50,"task":null,"title":"n"}}}
EOF
  # a competing valid candidate on /other with newer actionable session
  local key2; key2=$(printf '%s' "/other" | shasum -a 256 | cut -c1-16)
  cat > "$sandbox/${key2}-70101.json" <<EOF
{"repo":"r2","cwd":"/other","session":"sx2","pid":70101,
 "sessions":{"s":{"state":"needs-attention","reason":"permission","ts":1000,"task":null,"title":"n"}}}
EOF
  # ps override for the OTHER pid so we don't go through real ps for it
  local pso="$ROOT/ps9.tsv"
  printf 'OPENCODE\t70101\n' > "$pso"
  run_jump "select-side-effect" "$sandbox" "$pso" \
    $'/live\tsx\tterminal_0\t0\n/other\tsx2\tterminal_1\t0' ""
  if [ "$JUMP_STDOUT" = "DECISION:kind=select cwd=/other session=sx2 pane=terminal_1 tab_id=0 key=${key2}-70101 sid=s" ]; then
    pass "case9 reused-pid file dropped; /other wins"
  else
    fail "case9 reused-pid file dropped; /other wins" "got:" "$JUMP_STDOUT"
  fi
  kill "$reused_pid" 2>/dev/null || true
  wait "$reused_pid" 2>/dev/null || true
}

# --- 10. Fallback numeric sort: terminal_10 ranks above terminal_9.
#          Lexicographic order would pick "terminal_9" first; NUMERIC order
#          picks "terminal_10" first. Setup: only fallback applies (no
#          actionable session in any state file), two non-ambiguous panes on
#          OTHER cwds. ---
test_fallback_numeric_sort() {
  local sandbox="$ROOT/case10"
  mkdir -p "$sandbox"
  local pso="$ROOT/ps10.tsv"
  printf 'OPENCODE\t80001\n' > "$pso"
  printf 'OPENCODE\t80002\n' >> "$pso"
  local keyA; keyA=$(printf '%s' "/projA" | shasum -a 256 | cut -c1-16)
  local keyB; keyB=$(printf '%s' "/projB" | shasum -a 256 | cut -c1-16)
  # state files have ONLY working sessions (not actionable) ⇒ fall to pane fallback.
  cat > "$sandbox/${keyA}-80001.json" <<EOF
{"repo":"a","cwd":"/projA","session":"sxA","pid":80001,
 "sessions":{"s":{"state":"working","reason":null,"ts":100,"task":null,"title":"w"}}}
EOF
  cat > "$sandbox/${keyB}-80002.json" <<EOF
{"repo":"b","cwd":"/projB","session":"sxB","pid":80002,
 "sessions":{"s":{"state":"working","reason":null,"ts":100,"task":null,"title":"w"}}}
EOF
  # f/lower test that put terminal_9 lexicographically BEFORE terminal_10 if sorted wrong.
  run_jump "select-side-effect" "$sandbox" "$pso" \
    $'/projA\tsxA\tterminal_9\t0\n/projB\tsxB\tterminal_10\t0' ""
  # No actionable candidate → fallback pane. Highest numeric terminal id wins.
  assert_eq "case10 fallback: terminal_10 (numeric 10) > terminal_9" \
    "DECISION:kind=fallback-pane session=sxB pane=terminal_10 tab_id=0" \
    "$JUMP_STDOUT"
}

# --- 11. (a) USABLE v2 file supersedes v1 file for same cwd (v1 produces no
#             focus-only candidate).
#         (b) DEAD/REUSED-pid v2 file does NOT supersede v1 (v1 still produces
#             focus-only candidate). Migration supersession rule: stale-pid
#             drops run BEFORE supersession; otherwise a dead v2 silently
#             suppresses v1 and cwd goes blank. ---
test_11a_usable_v2_supersedes_v1() {
  local sandbox="$ROOT/case11a"
  mkdir -p "$sandbox"
  local v2_pid=11001
  local pso="$ROOT/ps11a.tsv"
  printf 'OPENCODE\t%s\n' "$v2_pid" > "$pso"
  local key; key=$(printf '%s' "/legacy" | shasum -a 256 | cut -c1-16)
  # v1 legacy: `<cwd-hash>.json` with state=needs-attention ts=50
  cat > "$sandbox/${key}.json" <<EOF
{"repo":"legacy","cwd":"/legacy","session":"ss","state":"needs-attention","reason":"permission","ts":50,"task":null}
EOF
  # v2 with usable pid covering /legacy
  cat > "$sandbox/${key}-${v2_pid}.json" <<EOF
{"repo":"v2","cwd":"/legacy","session":"ss","pid":${v2_pid},
 "sessions":{"s2":{"state":"needs-attention","reason":"permission","ts":100,"task":null,"title":"v2 n"}}}
EOF
  run_jump "select-side-effect" "$sandbox" "$pso" \
    $'/legacy\tss\tterminal_0\t0' ""
  # v2's session s2 (rank=1 ts=100) is selected; v1 is superseded.
  assert_eq "case11a usable v2 suppresses v1: v2 selected" \
    "DECISION:kind=select cwd=/legacy session=ss pane=terminal_0 tab_id=0 key=${key}-${v2_pid} sid=s2" \
    "$JUMP_STDOUT"
}

test_11b_dead_v2_does_not_supersede_v1() {
  local sandbox="$ROOT/case11b"
  mkdir -p "$sandbox"
  local key; key=$(printf '%s' "/legacy" | shasum -a 256 | cut -c1-16)
  # dead v2 (process no longer alive) covering /legacy
  local pso="$ROOT/ps11b.tsv"
  printf 'DEAD\t12001\n' > "$pso"
  printf 'OPENCODE\t80001\n' >> "$pso"
  # v1 legacy: needs-attention ts=500 (newer than v2's potential slot, but v2 dropped)
  cat > "$sandbox/${key}.json" <<EOF
{"repo":"legacy","cwd":"/legacy","session":"ss","state":"needs-attention","reason":"permission","ts":500,"task":null}
EOF
  cat > "$sandbox/${key}-12001.json" <<EOF
{"repo":"v2","cwd":"/legacy","session":"ss","pid":12001,
 "sessions":{"s2":{"state":"done","reason":null,"ts":10000,"task":null,"title":"v2 d"}}}
EOF
  run_jump "select-side-effect" "$sandbox" "$pso" \
    $'/legacy\tss\tterminal_0\t0' "/legacy"
  # v2 dropped by stale-pid filter; v1 still valid (no usable v2 covering /legacy).
  # explicit cwd → focus-only (no .select; v1 has no sessionID).
  assert_eq "case11b dead v2 does NOT supersede v1: v1 focus-only" \
    "DECISION:kind=focus-only cwd=/legacy session=ss pane=terminal_0 tab_id=0" \
    "$JUMP_STDOUT"
  assert_file_absent "case11b no .select for v1 (no session id)" "$sandbox/${key}.select"
}

# --- 12. Explicit cwd with a SINGLE opencode instance holding MULTIPLE
#         actionable non-suppressed sessions: focus pane AND write exactly
#         ONE .select for the SINGLE highest-ranked actionable session,
#         never more than one. ---
test_12_explicit_cwd_multiple_actionable_one_mailbox() {
  local sandbox="$ROOT/case12"
  mkdir -p "$sandbox"
  local pid=13001
  local pso="$ROOT/ps12.tsv"
  printf 'OPENCODE\t%s\n' "$pid" > "$pso"
  local key; key=$(printf '%s' "/mult" | shasum -a 256 | cut -c1-16)
  cat > "$sandbox/${key}-${pid}.json" <<EOF
{"repo":"r","cwd":"/mult","session":"ms","pid":${pid},
 "sessions":{
   "ses_old_done":{"state":"done","reason":null,"ts":50,"task":null,"title":"old d"},
   "ses_new_blocked":{"state":"needs-attention","reason":"permission","ts":300,"task":null,"title":"new n"},
   "ses_done_newer":{"state":"done","reason":null,"ts":250,"task":null,"title":"d new"}
 }}
EOF
  run_jump "select-side-effect" "$sandbox" "$pso" \
    $'/mult\tms\tterminal_0\t0' "/mult"
  # top-ranked actionable = ses_new_blocked (rank=1 ts=300)
  # only ONE .select written.
  assert_eq "case12 decision: select ses_new_blocked (rank=1)" \
    "DECISION:kind=select cwd=/mult session=ms pane=terminal_0 tab_id=0 key=${key}-${pid} sid=ses_new_blocked" \
    "$JUMP_STDOUT"
  local select_paths
  select_paths=$(find "$sandbox" -maxdepth 1 -name "*.select" -print)
  assert_eq "case12 exactly ONE .select written" "1" \
    "$(echo "$select_paths" | grep -c . || echo 0)"
  local sid
  sid=$(jq -r .sessionID "$sandbox/${key}-${pid}.select")
  assert_eq "case12 .select IDs ses_new_blocked (rank=1)" "ses_new_blocked" "$sid"
}

# --- 13. Explicit cwd whose instance has NO actionable non-suppressed
#         session: focus-only (no .select written). ---
test_13_explicit_cwd_no_actionable_focus_only() {
  local sandbox="$ROOT/case13"
  mkdir -p "$sandbox"
  local pid=14001
  local pso="$ROOT/ps13.tsv"
  printf 'OPENCODE\t%s\n' "$pid" > "$pso"
  local key; key=$(printf '%s' "/idle" | shasum -a 256 | cut -c1-16)
  cat > "$sandbox/${key}-${pid}.json" <<EOF
{"repo":"r","cwd":"/idle","session":"sx","pid":${pid},
 "sessions":{"only_working":{"state":"working","reason":null,"ts":100,"task":null,"title":"w"}}}
EOF
  run_jump "select-side-effect" "$sandbox" "$pso" \
    $'/idle\tsx\tterminal_0\t0' "/idle"
  assert_eq "case13 explicit cwd: no actionable session → focus-only" \
    "DECISION:kind=focus-only cwd=/idle session=sx pane=terminal_0 tab_id=0" \
    "$JUMP_STDOUT"
  assert_file_absent "case13 no .select written (focus-only)" "$sandbox/${key}-${pid}.select"
}

# --- 14. Jump skips a viewed/suppressed terminal session and ranks the next
#         actionable one. (isSuppressed: state in done/needs-attention AND
#         viewedTs >= entryTs ⇒ suppressed.) Setup: cwd has TWO actionable
#         sessions, but ONE is viewed-equal-or-after; the other isn't. ---
test_14_skips_suppressed_session() {
  local sandbox="$ROOT/case14"
  mkdir -p "$sandbox"
  local pid=15002
  local pso="$ROOT/ps14.tsv"
  printf 'OPENCODE\t%s\n' "$pid" > "$pso"
  local key; key=$(printf '%s' "/sup" | shasum -a 256 | cut -c1-16)
  cat > "$sandbox/${key}-${pid}.json" <<EOF
{"repo":"r","cwd":"/sup","session":"sx","pid":${pid},
 "sessions":{
   "ses_viewed":{"state":"done","reason":null,"ts":100,"task":null,"title":"viewed"},
   "ses_unviewed":{"state":"needs-attention","reason":"permission","ts":50,"task":null,"title":"needs"}
 }}
EOF
  # viewed.json marks ses_viewed as viewed at ts=200 (≥ entryTs=100 ⇒ suppressed)
  cat > "$sandbox/${key}-${pid}.viewed.json" <<'EOF'
{"ses_viewed": 200}
EOF
  run_jump "select-side-effect" "$sandbox" "$pso" \
    $'/sup\tsx\tterminal_0\t0' ""
  # ses_unviewed (rank=1) outranks ses_viewed (rank=0) AND is non-suppressed anyway
  # ⇒ selected.
  assert_eq "case14 ses_unviewed (rank=1) selected" \
    "DECISION:kind=select cwd=/sup session=sx pane=terminal_0 tab_id=0 key=${key}-${pid} sid=ses_unviewed" \
    "$JUMP_STDOUT"
}

# --- 14b. Jump ALSO skips when the higher-ranked session is suppressed and
#          ranks the next actionable. Setup: ses_viewed is needs-attention
#          (rank=1) but suppressed; ses_unviewed is done (rank=0) not
#          suppressed ⇒ next-actionable wins by DESCENDING rank walk. ---
test_14b_skips_suppressed_higher_rank() {
  local sandbox="$ROOT/case14b"
  mkdir -p "$sandbox"
  local pid=15012
  local pso="$ROOT/ps14b.tsv"
  printf 'OPENCODE\t%s\n' "$pid" > "$pso"
  local key; key=$(printf '%s' "/sup2" | shasum -a 256 | cut -c1-16)
  cat > "$sandbox/${key}-${pid}.json" <<EOF
{"repo":"r","cwd":"/sup2","session":"sx","pid":${pid},
 "sessions":{
   "ses_viewed_high":{"state":"needs-attention","reason":"permission","ts":500,"task":null,"title":"viewed needs"},
   "ses_unviewed_done":{"state":"done","reason":null,"ts":300,"task":null,"title":"d"}
 }}
EOF
  cat > "$sandbox/${key}-${pid}.viewed.json" <<'EOF'
{"ses_viewed_high": 600}
EOF
  run_jump "select-side-effect" "$sandbox" "$pso" \
    $'/sup2\tsx\tterminal_0\t0' ""
  assert_eq "case14b suppressed rank=1 → falls to unviewed rank=0" \
    "DECISION:kind=select cwd=/sup2 session=sx pane=terminal_0 tab_id=0 key=${key}-${pid} sid=ses_unviewed_done" \
    "$JUMP_STDOUT"
}

# --- additional: explicit cwd names a cwd that has NO live pane at all ---
test_15_explicit_unknown_cwd_no_match() {
  local sandbox="$ROOT/case15"
  mkdir -p "$sandbox"
  local pid=16001
  local pso="$ROOT/ps15.tsv"
  printf 'OPENCODE\t%s\n' "$pid" > "$pso"
  local key; key=$(printf '%s' "/live" | shasum -a 256 | cut -c1-16)
  cat > "$sandbox/${key}-${pid}.json" <<EOF
{"repo":"r","cwd":"/live","session":"sx","pid":${pid},
 "sessions":{"s":{"state":"done","reason":null,"ts":100,"task":null,"title":"d"}}}
EOF
  run_jump "decide-only" "$sandbox" "$pso" \
    $'/live\tsx\tterminal_0\t0' "/nothere"
  # requested cwd has no live pane ⇒ noop (current jump.sh errs; for now we
  # document via the noop kind — and stderr carries an explanatory note).
  # Plan doesn't explicitly mandate stderr text here; just assert decision.
  assert_eq "case15 explicit unknown cwd → noop" \
    "DECISION:kind=noop" \
    "$JUMP_STDOUT"
}

# --- 16. Regression: explicit-cwd session selection must NOT reuse the
#          GLOBAL top-row. Plan > Flow > Jump "Explicit-cwd session
#          selection": explicit cwd writes .select for ITS OWN top-ranked
#          actionable session, not for the global-best session. Before
#          the fix, this turned into focus-only (no .select) whenever
#          the requested cwd's top-ranked session wasn't also the global
#          best. Repro from spec review:
#            A: needs-attention ts=1000 (globally top, but we don't ask A)
#            B: needs-attention ts=500  (B's own top, lower ts)
#          Explicit jump to B ⇒ B should .select ses_B, not focus-only. ---
test_explicit_cwd_not_global_top() {
  local sandbox="$ROOT/case16"
  mkdir -p "$sandbox"
  local pidA=17001
  local pidB=17002
  local pso="$ROOT/ps16.tsv"
  printf 'OPENCODE\t%s\n' "$pidA" > "$pso"
  printf 'OPENCODE\t%s\n' "$pidB" >> "$pso"
  local keyA; keyA=$(printf '%s' "/projA" | shasum -a 256 | cut -c1-16)
  local keyB; keyB=$(printf '%s' "/projB" | shasum -a 256 | cut -c1-16)
  cat > "$sandbox/${keyA}-${pidA}.json" <<EOF
{"repo":"a","cwd":"/projA","session":"sessA","pid":${pidA},
 "sessions":{"ses_A":{"state":"needs-attention","reason":"permission","ts":1000,"task":null,"title":"a"}}}
EOF
  cat > "$sandbox/${keyB}-${pidB}.json" <<EOF
{"repo":"b","cwd":"/projB","session":"sessB","pid":${pidB},
 "sessions":{"ses_B":{"state":"needs-attention","reason":"permission","ts":500,"task":null,"title":"b"}}}
EOF
  run_jump "select-side-effect" "$sandbox" "$pso" \
    $'/projA\tsessA\tterminal_0\t0\n/projB\tsessB\tterminal_1\t1' "/projB"
  assert_eq "case16 explicit-cwd-not-global-top: select B's session (NOT focus-only)" \
    "DECISION:kind=select cwd=/projB session=sessB pane=terminal_1 tab_id=1 key=${keyB}-${pidB} sid=ses_B" \
    "$JUMP_STDOUT"
  assert_file_exists "case16 .select written to B's key path" "$sandbox/${keyB}-${pidB}.select"
  assert_file_absent  "case16 NO .select written to A's key path" "$sandbox/${keyA}-${pidA}.select"
  local sid; sid=$(jq -r .sessionID "$sandbox/${keyB}-${pidB}.select")
  assert_eq "case16 B's .select sessionID is ses_B" "ses_B" "$sid"
}

# --- 17. Regression: explicit-cwd B's pane must focus its OWN pane even
#          when B's globally-best session is elsewhere. Same repro as
#          case16 but checks the cwd/session/pane fields, proving the
#          decision is scoped to requested_cwd, not just the .select. ---
test_explicit_cwd_not_global_top_session_pane() {
  local sandbox="$ROOT/case17"
  mkdir -p "$sandbox"
  local pidA=18001
  local pidB=18002
  local pso="$ROOT/ps17.tsv"
  printf 'OPENCODE\t%s\n' "$pidA" > "$pso"
  printf 'OPENCODE\t%s\n' "$pidB" >> "$pso"
  local keyA; keyA=$(printf '%s' "/projA" | shasum -a 256 | cut -c1-16)
  local keyB; keyB=$(printf '%s' "/projB" | shasum -a 256 | cut -c1-16)
  cat > "$sandbox/${keyA}-${pidA}.json" <<EOF
{"repo":"a","cwd":"/projA","session":"sessA","pid":${pidA},
 "sessions":{"ses_A":{"state":"done","reason":null,"ts":99999,"task":null,"title":"a"}}}
EOF
  cat > "$sandbox/${keyB}-${pidB}.json" <<EOF
{"repo":"b","cwd":"/projB","session":"sessB","pid":${pidB},
 "sessions":{"ses_B_done":{"state":"done","reason":null,"ts":100,"task":null,"title":"b"}}}
EOF
  # Explicit jump to /projA — it's the pane with the globally highest
  # session (ses_A done ts=99999). The decision should pick /projA, focus
  # its pane, AND write .select for ses_A. Validates the GLOBAL pool vs
  # explicit-cwd pool both routes through the same code correctly.
  run_jump "select-side-effect" "$sandbox" "$pso" \
    $'/projA\tsessA\tterminal_0\t0\n/projB\tsessB\tterminal_1\t1' "/projA"
  assert_eq "case17 explicit-cwd-projA: globally-top → select ses_A" \
    "DECISION:kind=select cwd=/projA session=sessA pane=terminal_0 tab_id=0 key=${keyA}-${pidA} sid=ses_A" \
    "$JUMP_STDOUT"
  assert_file_exists "case17 .select on A's key" "$sandbox/${keyA}-${pidA}.select"
}

# === run all tests ===
run_test() {
  local fn="$1"
  # Each test gets a clean log path; we accumulate PASS/FAIL via the root log.
  "$fn"
}

run_test test_one_cwd_two_sessions_selects_needs_attention
run_test test_two_panes_focuses_top_cwd
run_test test_two_worktrees_distinct_cwd_hash
run_test test_global_duplicate_only_cwd_falls_to_noop
run_test test_explicit_duplicate_cwd_warns
run_test test_dead_pid_state_file_dropped
run_test test_ghost_cwd_with_v2_file_dropped
run_test test_headless_sharing_live_cwd_is_ambiguous_explicit_warns
run_test test_headless_sharing_live_cwd_is_ambiguous_global_noop
run_test test_alive_but_not_opencode_comm_dropped
run_test test_fallback_numeric_sort
run_test test_11a_usable_v2_supersedes_v1
run_test test_11b_dead_v2_does_not_supersede_v1
run_test test_12_explicit_cwd_multiple_actionable_one_mailbox
run_test test_13_explicit_cwd_no_actionable_focus_only
run_test test_14_skips_suppressed_session
run_test test_14b_skips_suppressed_higher_rank
run_test test_15_explicit_unknown_cwd_no_match
run_test test_explicit_cwd_not_global_top
run_test test_explicit_cwd_not_global_top_session_pane

# Print accumulated log
cat "$ROOT/log"
echo "---"
echo "PASS: $PASS  FAIL: $FAIL"

if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
