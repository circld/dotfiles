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

test_notes_session_does_not_switch_to_remote_agent() {
  local sandbox="$ROOT/notes-session"
  local fake_bin="$sandbox/bin"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/aerospace" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  cat > "$fake_bin/zellij" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$AGENT_FLEET_TEST_ZELLIJ_LOG"
EOF
  chmod +x "$fake_bin/aerospace" "$fake_bin/zellij"
  STATE_DIR="$sandbox" \
    AGENT_FLEET_STATE_DIR="$sandbox" \
    AGENT_FLEET_TEST_ZELLIJ_LOG="$sandbox/zellij.log" \
    PATH="$fake_bin:$PATH" \
    ZELLIJ_SESSION_NAME=notes \
    bash -c '. "$1"; act_land key sid agent-session terminal_1 3' _ \
    "$REPO_ROOT/scripts/agent-fleet-act.sh"
  assert_file_exists "notes session: mailbox still written" "$sandbox/key.select"
  assert_file_absent "notes session: remote zellij session not selected" "$sandbox/zellij.log"
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

# ===========================================================================
# Task 3 — stack reconcile / write / land plumbing
# ===========================================================================
#
# Pin shell time exactly via AGENT_FLEET_NOW_MS so the stale-P 2s window and
# ordering of reconcile vs. navigation mutation are deterministic. The real
# clock always puts a fixture's selectedTs in the ancient past, so the
# "stale-P within window" branch is otherwise untestable.

write_stack() {
  printf '%s\n' "$2" > "$1"
}

assert_stack_eq() {
  local label="$1" want="$2" path="$3"
  if [ ! -f "$path" ]; then
    fail "$label" "missing stack file:" "$path"
    return
  fi
  local got want_norm
  got="$(jq -S . "$path")"
  want_norm="$(jq -S . <<<"$want" 2>/dev/null || echo "BAD_WANT")"
  if [ "$want_norm" = "$got" ]; then
    pass "$label"
  else
    fail "$label" "want:" "$want_norm" "got:" "$got"
  fi
}

run_jump_with_pinned_now() {
  local mode="$1" sandbox="$2" pso="$3" live="$4" cwd_arg="$5" now_ms="$6"
  local pane_file="$ROOT/pane-${RANDOM}.tsv"
  printf '%s\n' "$live" > "$pane_file"
  local env_args=(
    "AGENT_FLEET_LIVE_PANES_OVERRIDE=$pane_file"
    "AGENT_FLEET_STATE_DIR=$sandbox"
    "AGENT_FLEET_NOW_MS=$now_ms"
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

# --- 18. DECIDE_ONLY=1 writes neither .select nor traverse-stack.json ---
test_18_decide_only_no_side_effects() {
  local sandbox="$ROOT/case18"
  mkdir -p "$sandbox"
  local pid=18001
  local pso="$ROOT/ps18.tsv"
  printf 'OPENCODE\t%s\n' "$pid" > "$pso"
  local key; key=$(printf '%s' "/cb" | shasum -a 256 | cut -c1-16)
  cat > "$sandbox/${key}-${pid}.json" <<EOF
{"repo":"r","cwd":"/cb","session":"sx","pid":${pid},
 "selectedSid":"ses_past","selectedTs":1700000000000,
 "sessions":{"ses_target":{"state":"needs-attention","reason":"permission","ts":200,"task":null,"title":"t"}}}
EOF
  run_jump "decide-only" "$sandbox" "$pso" \
    $'/cb\tsx\tterminal_0\t0' ""
  assert_eq "case18 decide-only still emits select decision text" \
    "DECISION:kind=select cwd=/cb session=sx pane=terminal_0 tab_id=0 key=${key}-${pid} sid=ses_target" \
    "$JUMP_STDOUT"
  assert_file_absent "case18 decide-only: NO .select written" "$sandbox/${key}-${pid}.select"
  assert_file_absent "case18 decide-only: NO traverse-stack.json written" \
    "$sandbox/traverse-stack.json"
}

# --- 30. Select landing reconciles model cursor, MRU-pushes old current,
#         removes target from both stacks, clears forward, writes stack,
#         then writes target mailbox. Pre-existing forward gets cleared by
#         the reconcile flip AND by the new-navigation mutation. ---
test_30_select_writes_reconciled_stack() {
  local sandbox="$ROOT/case30"
  mkdir -p "$sandbox"
  local pid=30001
  local pso="$ROOT/ps30.tsv"
  printf 'OPENCODE\t%s\n' "$pid" > "$pso"
  local key; key=$(printf '%s' "/sel" | shasum -a 256 | cut -c1-16)
  # selectedSid=ses_past (the model cursor), actionable=ses_target
  cat > "$sandbox/${key}-${pid}.json" <<EOF
{"repo":"r","cwd":"/sel","session":"sx","pid":${pid},
 "selectedSid":"ses_past","selectedTs":1700000000000,
 "sessions":{
   "ses_past":{"state":"done","reason":null,"ts":50,"task":null,"title":"past"},
   "ses_target":{"state":"needs-attention","reason":"permission","ts":200,"task":null,"title":"target"}
 }}
EOF
  # Pre-existing stack: current=ses_b (ts older than P), forward=[ses_f].
  # Different from P=ses_past ⇒ passive departure during reconcile.
  write_stack "$sandbox/traverse-stack.json" \
    '{"v":1,"current":{"sid":"ses_b","ts":1500000000000},"back":[],"forward":["ses_f"]}'
  local now_ms=1800000000000
  run_jump_with_pinned_now "select-side-effect" "$sandbox" "$pso" \
    $'/sel\tsx\tterminal_0\t0' "" "$now_ms"
  assert_eq "case30 select: decision text unchanged" \
    "DECISION:kind=select cwd=/sel session=sx pane=terminal_0 tab_id=0 key=${key}-${pid} sid=ses_target" \
    "$JUMP_STDOUT"
  assert_file_exists "case30 .select written" "$sandbox/${key}-${pid}.select"
  local sel_sid; sel_sid=$(jq -r .sessionID "$sandbox/${key}-${pid}.select")
  assert_eq "case30 .select sessionID is the actionable target" "ses_target" "$sel_sid"
  assert_stack_eq "case30 stack: current=target, back MRU=old-current → reconcile-P, forward cleared, ses_target removed from stacks" \
    "{\"v\":1,\"current\":{\"sid\":\"ses_target\",\"ts\":${now_ms}},\"back\":[\"ses_b\",\"ses_past\"],\"forward\":[]}" \
    "$sandbox/traverse-stack.json"
}

# --- 31. Fresh stack (current=null) adopts model cursor with NO push ---
test_31_fresh_stack_adopts_no_push() {
  local sandbox="$ROOT/case31"
  mkdir -p "$sandbox"
  local pid=31001
  local pso="$ROOT/ps31.tsv"
  printf 'OPENCODE\t%s\n' "$pid" > "$pso"
  local key; key=$(printf '%s' "/fr" | shasum -a 256 | cut -c1-16)
  cat > "$sandbox/${key}-${pid}.json" <<EOF
{"repo":"r","cwd":"/fr","session":"sx","pid":${pid},
 "selectedSid":"ses_past","selectedTs":1700000000000,
 "sessions":{
   "ses_past":{"state":"done","reason":null,"ts":50,"task":null,"title":"p"},
   "ses_target":{"state":"needs-attention","reason":"permission","ts":200,"task":null,"title":"t"}
 }}
EOF
  # Canonical empty stack file (fresh).
  write_stack "$sandbox/traverse-stack.json" \
    '{"v":1,"current":null,"back":[],"forward":[]}'
  local now_ms=1800000000000
  run_jump_with_pinned_now "select-side-effect" "$sandbox" "$pso" \
    $'/fr\tsx\tterminal_0\t0' "" "$now_ms"
  assert_file_exists "case31 .select written" "$sandbox/${key}-${pid}.select"
  # Adopt (current null → P=ses_past) does NOT push null to back.
  # Then new-nav mutation push_mru(previous-current ses_past) → back=[ses_past].
  # Target (ses_target) was never on back/forward, so stays cleared.
  assert_stack_eq "case31 fresh stack adopts P; null NOT pushed to back; target lands as current" \
    "{\"v\":1,\"current\":{\"sid\":\"ses_target\",\"ts\":${now_ms}},\"back\":[\"ses_past\"],\"forward\":[]}" \
    "$sandbox/traverse-stack.json"
}

# --- 32. Corrupt stack file is tolerated as fresh: canonical empty adopt.
#         Cover the "corrupt" branch alongside the fresh-stack adopt path. ---
test_32_corrupt_stack_treated_as_fresh() {
  local sandbox="$ROOT/case32"
  mkdir -p "$sandbox"
  local pid=32001
  local pso="$ROOT/ps32.tsv"
  printf 'OPENCODE\t%s\n' "$pid" > "$pso"
  local key; key=$(printf '%s' "/co" | shasum -a 256 | cut -c1-16)
  cat > "$sandbox/${key}-${pid}.json" <<EOF
{"repo":"r","cwd":"/co","session":"sx","pid":${pid},
 "selectedSid":"ses_past","selectedTs":1700000000000,
 "sessions":{
   "ses_past":{"state":"done","reason":null,"ts":50,"task":null,"title":"p"},
   "ses_target":{"state":"needs-attention","reason":"permission","ts":200,"task":null,"title":"t"}
 }}
EOF
  # Corrupt payload: wrong version + missing arrays. stack_read MUST return
  # canonical empty (adopt with no push).
  write_stack "$sandbox/traverse-stack.json" \
    '{"v":99,"current":null}'
  local now_ms=1800000000000
  run_jump_with_pinned_now "select-side-effect" "$sandbox" "$pso" \
    $'/co\tsx\tterminal_0\t0' "" "$now_ms"
  assert_stack_eq "case32 corrupt stack read as fresh; adopt + new-nav ⇒ current=target, back=[ses_past]" \
    "{\"v\":1,\"current\":{\"sid\":\"ses_target\",\"ts\":${now_ms}},\"back\":[\"ses_past\"],\"forward\":[]}" \
    "$sandbox/traverse-stack.json"
}

# --- 33. Reconcile clears forward on passive departure. ---
#         Setup: cwd /pd has TWO panes (ambiguous via pane-table arm)
#         + ONE v2 file with ONLY a working session (no actionable) +
#         selectedSid=ses_z (newer than current) ⇒ noop branch (ambiguous
#         panes exclude fallback; no actionable top in pool). Pre-existing
#         stack has forward=[F, F2] ⇒ flip clears it. ---
test_33_passive_departure_clears_forward() {
  local sandbox="$ROOT/case33"
  mkdir -p "$sandbox"
  local pid=33001
  local pso="$ROOT/ps33.tsv"
  printf 'OPENCODE\t%s\n' "$pid" > "$pso"
  local key; key=$(printf '%s' "/pd" | shasum -a 256 | cut -c1-16)
  # Working-only session keeps actionable empty; selectedSid drives reconcile.
  cat > "$sandbox/${key}-${pid}.json" <<EOF
{"repo":"r","cwd":"/pd","session":"sx","pid":${pid},
 "selectedSid":"ses_z","selectedTs":1800000000001,
 "sessions":{"w":{"state":"working","reason":null,"ts":50,"task":null,"title":"w"}}}
EOF
  # Pre: current=ses_a (older ts than P), back=[], forward=[ses_f, ses_f2].
  # P.ts > current.ts ⇒ not stale-P ⇒ straightforward flip.
  write_stack "$sandbox/traverse-stack.json" \
    '{"v":1,"current":{"sid":"ses_a","ts":1700000000000},"back":[],"forward":["ses_f","ses_f2"]}'
  local now_ms=1800000000010
  run_jump_with_pinned_now "select-side-effect" "$sandbox" "$pso" \
    $'/pd\tsx_a\tterminal_5\t0\n/pd\tsx_b\tterminal_6\t0' "" "$now_ms"
  assert_eq "case33 passive departure cleared: cwd-ambiguous ⇒ noop decision" \
    "DECISION:kind=noop" \
    "$JUMP_STDOUT"
  assert_stack_eq "case33 passive departure clears forward (no nav mutation on top)" \
    '{"v":1,"current":{"sid":"ses_z","ts":1800000000010},"back":["ses_a"],"forward":[]}' \
    "$sandbox/traverse-stack.json"
  assert_file_absent "case33 noop: NO .select written (no actionable)" \
    "$sandbox/${key}-${pid}.select"
}

# --- 34. MRU dedup: when old current is already on back, the reconcile flip
#         AND select-navigation MRU push must NOT double-insert it. Fixture
#         puts ses_pre ON back twice already so the dedup is observable —
#         push without dedup leaves ses_pre on the stack twice after the flip
#         AND twice again after select nav (cumulative). With dedup each
#         MRU push collapses the prior entries so ses_pre lands at top exactly
#         once. ---
test_34_mru_dedup_no_double_insert() {
  local sandbox="$ROOT/case34"
  mkdir -p "$sandbox"
  local pid=34001
  local pso="$ROOT/ps34.tsv"
  printf 'OPENCODE\t%s\n' "$pid" > "$pso"
  local key; key=$(printf '%s' "/dp" | shasum -a 256 | cut -c1-16)
  # selectedSid=ses_past, actionable=ses_target. P != initial current → flip.
  cat > "$sandbox/${key}-${pid}.json" <<EOF
{"repo":"r","cwd":"/dp","session":"sx","pid":${pid},
 "selectedSid":"ses_past","selectedTs":1800000000005,
 "sessions":{
   "ses_past":{"state":"done","reason":null,"ts":50,"task":null,"title":"past"},
   "ses_target":{"state":"needs-attention","reason":"permission","ts":200,"task":null,"title":"target"}
 }}
EOF
  # Pre-stack: ses_pre is BOTH current AND on back (twice). The MRU push of
  # old current must dedup. ses_old_marker is on back twice already and is
  # unrelated to any push — its duplicates must survive untouched.
  write_stack "$sandbox/traverse-stack.json" \
    '{"v":1,"current":{"sid":"ses_pre","ts":1700000000000},"back":["ses_old_marker","ses_pre","ses_old_marker"],"forward":["ses_f"]}'
  local now_ms=1800000000010
  run_jump_with_pinned_now "select-side-effect" "$sandbox" "$pso" \
    $'/dp\tsx\tterminal_0\t0' "" "$now_ms"
  assert_eq "case34 dedup: select decision preserved" \
    "DECISION:kind=select cwd=/dp session=sx pane=terminal_0 tab_id=0 key=${key}-${pid} sid=ses_target" \
    "$JUMP_STDOUT"
  # Post flip + nav: back = [ses_old_marker×2, ses_pre×1, ses_past×1] (the two
  # new MRUs are dedup-collapsed; pre-existing ses_old_marker duplicates
  # untouched). current=ses_target, forward=[].
  assert_stack_eq "case34 dedup exact back sequence (MRU drops old-current's incumbency from both reconcile flip and nav)" \
    '{"v":1,"current":{"sid":"ses_target","ts":1800000000010},"back":["ses_old_marker","ses_old_marker","ses_pre","ses_past"],"forward":[]}' \
    "$sandbox/traverse-stack.json"
  # Cross-check via counts: ses_old_marker survives the pre-existing 2;
  # ses_pre (pushed by both reconcile AND select nav) lands exactly once;
  # ses_past (pushed once by select nav) lands exactly once.
  local back n_old n_pre n_past n_target
  back="$(jq -c .back "$sandbox/traverse-stack.json")"
  n_old="$(jq --arg s "ses_old_marker" '[.[]|select(.==$s)]|length' <<<"$back")"
  n_pre="$(jq --arg s "ses_pre"        '[.[]|select(.==$s)]|length' <<<"$back")"
  n_past="$(jq --arg s "ses_past"      '[.[]|select(.==$s)]|length' <<<"$back")"
  n_target="$(jq --arg s "ses_target"  '[.[]|select(.==$s)]|length' <<<"$back")"
  assert_eq "case34 ses_old_marker dedup untouched: still 2 in back" "2" "$n_old"
  assert_eq "case34 ses_pre dedup: exactly 1 in back (reconcile + nav did not double)" "1" "$n_pre"
  assert_eq "case34 ses_past dedup: exactly 1 in back (nav did not double)" "1" "$n_past"
  assert_eq "case34 ses_target NOT on back (current-removal invariant)" "0" "$n_target"
}

# --- 40a. noop branch persists reconcile mutation but adds no navigation mutation ---
test_40a_noop_persists_reconcile() {
  local sandbox="$ROOT/case40a"
  mkdir -p "$sandbox"
  local pid=40001
  local pso="$ROOT/ps40a.tsv"
  printf 'OPENCODE\t%s\n' "$pid" > "$pso"
  local key; key=$(printf '%s' "/np" | shasum -a 256 | cut -c1-16)
  # Working-only session → no actionable → noop (ambiguous panes kill fallback).
  # selectedSid is the same target as the test_33 case, but pre-stack has
  # a non-empty back entry (not "ses_a") so the push-during-flip is
  # distinguishable from any noop nav mutation.
  cat > "$sandbox/${key}-${pid}.json" <<EOF
{"repo":"r","cwd":"/np","session":"sx","pid":${pid},
 "selectedSid":"ses_z","selectedTs":1800000000001,
 "sessions":{"w":{"state":"working","reason":null,"ts":50,"task":null,"title":"w"}}}
EOF
  write_stack "$sandbox/traverse-stack.json" \
    '{"v":1,"current":{"sid":"ses_a","ts":1700000000000},"back":["ses_x"],"forward":[]}'
  local now_ms=1800000000010
  run_jump_with_pinned_now "select-side-effect" "$sandbox" "$pso" \
    $'/np\tsx_a\tterminal_5\t0\n/np\tsx_b\tterminal_6\t0' "" "$now_ms"
  assert_eq "case40a noop branch emits noop decision" \
    "DECISION:kind=noop" \
    "$JUMP_STDOUT"
  # Pre-existing back=[ses_x] PLUS reconcile's push of OLD current (ses_a).
  # If nav mutation had ALSO run, we'd see more than 2 back entries or target
  # in back. Forward is [] (no flip-induced clear needed since empty already).
  assert_stack_eq "case40a noop: reconcile persisted; back grew by exactly one (old-current MRU), no further nav mutation" \
    '{"v":1,"current":{"sid":"ses_z","ts":1800000000010},"back":["ses_x","ses_a"],"forward":[]}' \
    "$sandbox/traverse-stack.json"
}

# --- 40b. warn-explicit-duplicate branch persists reconcile, no nav mutation ---
test_40b_warn_persists_reconcile() {
  local sandbox="$ROOT/case40b"
  mkdir -p "$sandbox"
  local pidA=40101
  local pidB=40202
  local pso="$ROOT/ps40b.tsv"
  printf 'OPENCODE\t%s\n' "$pidA" > "$pso"
  printf 'OPENCODE\t%s\n' "$pidB" >> "$pso"
  local key; key=$(printf '%s' "/dup2" | shasum -a 256 | cut -c1-16)
  cat > "$sandbox/${key}-${pidA}.json" <<EOF
{"repo":"a","cwd":"/dup2","session":"sessA","pid":${pidA},
 "selectedSid":"ses_z","selectedTs":1800000000001,
 "sessions":{"s":{"state":"needs-attention","reason":"permission","ts":100,"task":null,"title":"n"}}}
EOF
  cat > "$sandbox/${key}-${pidB}.json" <<EOF
{"repo":"b","cwd":"/dup2","session":"sessB","pid":${pidB},
 "sessions":{"s":{"state":"done","reason":null,"ts":200,"task":null,"title":"d"}}}
EOF
  write_stack "$sandbox/traverse-stack.json" \
    '{"v":1,"current":{"sid":"ses_a","ts":1700000000000},"back":["ses_x"],"forward":["F_pre"]}'
  local now_ms=1800000000010
  run_jump_with_pinned_now "select-side-effect" "$sandbox" "$pso" \
    $'/dup2\tsessA\tterminal_0\t0' "/dup2" "$now_ms"
  assert_eq "case40b warn-explicit-duplicate decision" \
    "DECISION:kind=warn-explicit-duplicate" \
    "$JUMP_STDOUT"
  assert_file_absent "case40b warn: NO .select written" "$sandbox/${key}-${pidA}.select"
  assert_file_absent "case40b warn: NO .select on sibling pid either" \
    "$sandbox/${key}-${pidB}.select"
  # Flip happened (forward cleared, old current pushed to back). NO
  # further nav mutation ⇒ back=[ses_x, ses_a] with ses_z NOT present
  # (ses_z is current, never on back).
  assert_stack_eq "case40b warn persists reconcile: forward cleared by flip; back grew by exactly ses_a" \
    '{"v":1,"current":{"sid":"ses_z","ts":1800000000010},"back":["ses_x","ses_a"],"forward":[]}' \
    "$sandbox/traverse-stack.json"
}

# --- 40c. focus-only branch persists reconcile, no nav mutation ---
test_40c_focus_only_persists_reconcile() {
  local sandbox="$ROOT/case40c"
  mkdir -p "$sandbox"
  local pid=40301
  local pso="$ROOT/ps40c.tsv"
  printf 'OPENCODE\t%s\n' "$pid" > "$pso"
  local key; key=$(printf '%s' "/fo" | shasum -a 256 | cut -c1-16)
  # Working-only session ⇒ no actionable ⇒ focus-only on explicit jump.
  # selectedSid drives reconcile flip.
  cat > "$sandbox/${key}-${pid}.json" <<EOF
{"repo":"r","cwd":"/fo","session":"sx","pid":${pid},
 "selectedSid":"ses_z","selectedTs":1800000000001,
 "sessions":{"w":{"state":"working","reason":null,"ts":50,"task":null,"title":"w"}}}
EOF
  write_stack "$sandbox/traverse-stack.json" \
    '{"v":1,"current":{"sid":"ses_a","ts":1700000000000},"back":["ses_x"],"forward":["F_pre"]}'
  local now_ms=1800000000010
  run_jump_with_pinned_now "select-side-effect" "$sandbox" "$pso" \
    $'/fo\tsx\tterminal_0\t0' "/fo" "$now_ms"
  assert_eq "case40c focus-only decision" \
    "DECISION:kind=focus-only cwd=/fo session=sx pane=terminal_0 tab_id=0" \
    "$JUMP_STDOUT"
  assert_file_absent "case40c focus-only: NO .select written (no sid in actionable)" \
    "$sandbox/${key}-${pid}.select"
  assert_stack_eq "case40c focus-only persists reconcile: forward cleared, back grew by ses_a only" \
    '{"v":1,"current":{"sid":"ses_z","ts":1800000000010},"back":["ses_x","ses_a"],"forward":[]}' \
    "$sandbox/traverse-stack.json"
}

# --- 40d. fallback-pane branch persists reconcile, no nav mutation ---
test_40d_fallback_pane_persists_reconcile() {
  local sandbox="$ROOT/case40d"
  mkdir -p "$sandbox"
  local pid=40401
  local pso="$ROOT/ps40d.tsv"
  printf 'OPENCODE\t%s\n' "$pid" > "$pso"
  local key; key=$(printf '%s' "/fb" | shasum -a 256 | cut -c1-16)
  # Working-only session ⇒ no actionable ⇒ fallback-pane over alive pane.
  cat > "$sandbox/${key}-${pid}.json" <<EOF
{"repo":"r","cwd":"/fb","session":"sx","pid":${pid},
 "selectedSid":"ses_z","selectedTs":1800000000001,
 "sessions":{"w":{"state":"working","reason":null,"ts":50,"task":null,"title":"w"}}}
EOF
  write_stack "$sandbox/traverse-stack.json" \
    '{"v":1,"current":{"sid":"ses_a","ts":1700000000000},"back":["ses_x"],"forward":["F_pre"]}'
  local now_ms=1800000000010
  run_jump_with_pinned_now "select-side-effect" "$sandbox" "$pso" \
    $'/fb\tsx\tterminal_0\t0' "" "$now_ms"
  assert_eq "case40d fallback-pane decision" \
    "DECISION:kind=fallback-pane session=sx pane=terminal_0 tab_id=0" \
    "$JUMP_STDOUT"
  assert_file_absent "case40d fallback-pane: NO .select written (no sid)" \
    "$sandbox/${key}-${pid}.select"
  assert_stack_eq "case40d fallback-pane persists reconcile: forward cleared, back grew by ses_a only" \
    '{"v":1,"current":{"sid":"ses_z","ts":1800000000010},"back":["ses_x","ses_a"],"forward":[]}' \
    "$sandbox/traverse-stack.json"
}

# --- 50. Stale P older than fresh current.ts by less than 2s is IGNORED ---
#         P.ts < current.ts AND (now_ms - current.ts) < 2000ms ⇒ no change.
test_50_stale_p_within_window_ignored() {
  local sandbox="$ROOT/case50"
  mkdir -p "$sandbox"
  local pid=50001
  local pso="$ROOT/ps50.tsv"
  printf 'OPENCODE\t%s\n' "$pid" > "$pso"
  local key; key=$(printf '%s' "/sw" | shasum -a 256 | cut -c1-16)
  # Working-only session ⇒ noop branch (no actionable top). selectedSid drives
  # reconcile: P=ses_z with ts older than current.ts.
  cat > "$sandbox/${key}-${pid}.json" <<EOF
{"repo":"r","cwd":"/sw","session":"sx","pid":${pid},
 "selectedSid":"ses_z","selectedTs":1700000000500,
 "sessions":{"w":{"state":"working","reason":null,"ts":50,"task":null,"title":"w"}}}
EOF
  # current.ts = 1700000001000 (newer than P.ts by 500ms), pin now_ms such
  # that (now_ms - current.ts) = 1500ms (< 2000ms ⇒ within stale window).
  local current_ts=1700000001000
  local now_ms=1700000002500
  write_stack "$sandbox/traverse-stack.json" \
    "{\"v\":1,\"current\":{\"sid\":\"ses_a\",\"ts\":${current_ts}},\"back\":[\"ses_x\"],\"forward\":[\"F_pre\"]}"
  run_jump_with_pinned_now "select-side-effect" "$sandbox" "$pso" \
    $'/sw\tsx_a\tterminal_5\t0\n/sw\tsx_b\tterminal_6\t0' "" "$now_ms"
  assert_eq "case50 within-window stays noop" \
    "DECISION:kind=noop" \
    "$JUMP_STDOUT"
  # NO flip happened: stack must be UNCHANGED (same current.sid/ts, same
  # back, same forward; no MRU push of current onto back).
  assert_stack_eq "case50 stale P within window IGNORED: stack unchanged" \
    "{\"v\":1,\"current\":{\"sid\":\"ses_a\",\"ts\":${current_ts}},\"back\":[\"ses_x\"],\"forward\":[\"F_pre\"]}" \
    "$sandbox/traverse-stack.json"
}

# --- 51. Stale P older than current.ts by ≥ 2s FLIPS current ---
test_51_stale_p_outside_window_flips() {
  local sandbox="$ROOT/case51"
  mkdir -p "$sandbox"
  local pid=51001
  local pso="$ROOT/ps51.tsv"
  printf 'OPENCODE\t%s\n' "$pid" > "$pso"
  local key; key=$(printf '%s' "/sx" | shasum -a 256 | cut -c1-16)
  cat > "$sandbox/${key}-${pid}.json" <<EOF
{"repo":"r","cwd":"/sx","session":"sx","pid":${pid},
 "selectedSid":"ses_z","selectedTs":1700000000500,
 "sessions":{"w":{"state":"working","reason":null,"ts":50,"task":null,"title":"w"}}}
EOF
  # current.ts = 1700000001000; pin now_ms = current + 2500ms ⇒ (now-curr)=2500 ≥ 2000
  # ⇒ stale-P guard no longer protects the flip.
  local current_ts=1700000001000
  local now_ms=1700000003500
  write_stack "$sandbox/traverse-stack.json" \
    "{\"v\":1,\"current\":{\"sid\":\"ses_a\",\"ts\":${current_ts}},\"back\":[\"ses_x\"],\"forward\":[\"F_pre\"]}"
  run_jump_with_pinned_now "select-side-effect" "$sandbox" "$pso" \
    $'/sx\tsx_a\tterminal_5\t0\n/sx\tsx_b\tterminal_6\t0' "" "$now_ms"
  assert_eq "case51 outside-window still noop (cwd ambiguous)" \
    "DECISION:kind=noop" \
    "$JUMP_STDOUT"
  # current flipped to ses_z with ts=now_ms; old current pushed MRU onto back;
  # forward cleared. (Pre-existing back=[ses_x] preserved; ses_a added.)
  assert_stack_eq "case51 stale P outside window FLIPS: current=ses_z @ now_ms, back grew by ses_a, forward cleared" \
    "{\"v\":1,\"current\":{\"sid\":\"ses_z\",\"ts\":${now_ms}},\"back\":[\"ses_x\",\"ses_a\"],\"forward\":[]}" \
    "$sandbox/traverse-stack.json"
}

# --- 60. stack_write failure (rename onto an immutable target) warns but
#         the .select mailbox still lands. ---
# The plan hint suggested pre-creating traverse-stack.json AS A DIRECTORY; on
# Darwin `mv tmp dir` moves tmp INTO the dir (no rename-failure ⇒ no warning).
# chflags uchg is the macOS primitive that gives a deterministic real move
# failure on the TARGET FILE WITHOUT touching the .select path (sibling of
# stack, distinct filename). The exit trap later un-uchgs so rm -rf can clean.
test_60_stack_write_failure_select_lands() {
  local sandbox="$ROOT/case60"
  mkdir -p "$sandbox"
  local pid=60001
  local pso="$ROOT/ps60.tsv"
  printf 'OPENCODE\t%s\n' "$pid" > "$pso"
  local key; key=$(printf '%s' "/sf" | shasum -a 256 | cut -c1-16)
  cat > "$sandbox/${key}-${pid}.json" <<EOF
{"repo":"r","cwd":"/sf","session":"sx","pid":${pid},
 "selectedSid":"ses_a","selectedTs":1700000000000,
 "sessions":{
   "ses_a":{"state":"done","reason":null,"ts":50,"task":null,"title":"a"},
   "ses_target":{"state":"needs-attention","reason":"permission","ts":200,"task":null,"title":"t"}
 }}
EOF
  # Pre-create immutable target so the atomic rename fails.
  printf '%s\n' '{"v":1,"current":null,"back":[],"forward":[]}' \
    > "$sandbox/traverse-stack.json"
  chflags uchg "$sandbox/traverse-stack.json"
  local now_ms=1800000000000
  run_jump_with_pinned_now "select-side-effect" "$sandbox" "$pso" \
    $'/sf\tsx\tterminal_0\t0' "" "$now_ms"
  assert_file_exists "case60 .select mailbox STILL lands despite stack_write failure" \
    "$sandbox/${key}-${pid}.select"
  local sel_sid; sel_sid=$(jq -r .sessionID "$sandbox/${key}-${pid}.select")
  assert_eq "case60 .select sessionID is the actionable target" "ses_target" "$sel_sid"
  # Stderr carries the stack_write warning (don't pin past word "rename").
  assert_contains "case60 stderr: stack_write failure warning emitted" \
    "$JUMP_STDERR" "stack_write"
  # Drop uchg so EXIT trap's rm -rf can clean up.
  chflags nouchg "$sandbox/traverse-stack.json" 2>/dev/null || true
}

# --- 70. Mailbox sid JSON escaping: sid containing a literal double-quote and
#         backslash must round-trip through the .select mailbox as JSON-safe
#         text (no broken quoting, no injected sibling field). The selector
#         MUST point at the same exact byte sequence the sensor model emits. ---
test_70_escaped_sid_mailbox() {
  local sandbox="$ROOT/case70"
  mkdir -p "$sandbox"
  local pid=70001
  local pso="$ROOT/ps70.tsv"
  printf 'OPENCODE\t%s\n' "$pid" > "$pso"
  local key; key=$(printf '%s' "/es" | shasum -a 256 | cut -c1-16)
  # Fixture sid (literal chars: 6 chars + " + sid + \ + chars):  weird"sid\chars
  # JSON-escaped key in the v2 file: "weird\"sid\\chars"
  cat > "$sandbox/${key}-${pid}.json" <<EOF
{"repo":"r","cwd":"/es","session":"sx","pid":${pid},
 "selectedSid":"weird\"sid\\\\chars","selectedTs":1700000000000,
 "sessions":{
   "weird\"sid\\\\chars":{"state":"needs-attention","reason":"permission","ts":200,"task":null,"title":"t"}
 }}
EOF
  # Also a regular working session for comparison and to confirm rank ordering.
  local now_ms=1800000000000
  run_jump_with_pinned_now "select-side-effect" "$sandbox" "$pso" \
    $'/es\tsx\tterminal_0\t0' "" "$now_ms"
  assert_file_exists "case70 .select mailbox written for the escaped sid" \
    "$sandbox/${key}-${pid}.select"
  # jq -e over the mailbox: must parse cleanly AND the sessionID must equal
  # the EXACT byte sequence (round-trip equality).
  local got_sid
  got_sid="$(jq -r .sessionID "$sandbox/${key}-${pid}.select")"
  assert_eq "case70 .select sessionID round-trips the escaped bytes" \
    'weird"sid\chars' "$got_sid"
  # Mailbox must parse via jq -e (proves the JSON is syntactically valid).
  if jq -e . "$sandbox/${key}-${pid}.select" >/dev/null 2>&1; then
    pass "case70 .select mailbox parses as valid JSON"
  else
    fail "case70 .select mailbox FAILS JSON parse — quoting injection?"
  fi
  # The injected character must NOT have introduced a sibling field
  # (e.g., markOnly, sessionID2). Object keyset is exactly {sessionID}.
  local keys
  keys="$(jq -c 'keys_unsorted' "$sandbox/${key}-${pid}.select")"
  assert_eq "case70 .select mailbox keyset = exactly {sessionID}" \
    '["sessionID"]' "$keys"
}

# --- 71. stack_read field-level validation: bad ts TYPE on current → adopt
#         canonical empty (stack must NOT be returned as-is, downstream jq
#         would type-error under set -e). ---
test_71_bad_ts_type_canonical_empty() {
  local sandbox="$ROOT/case71"
  mkdir -p "$sandbox"
  local pid=71001
  local pso="$ROOT/ps71.tsv"
  printf 'OPENCODE\t%s\n' "$pid" > "$pso"
  local key; key=$(printf '%s' "/bt" | shasum -a 256 | cut -c1-16)
  cat > "$sandbox/${key}-${pid}.json" <<EOF
{"repo":"r","cwd":"/bt","session":"sx","pid":${pid},
 "selectedSid":"ses_past","selectedTs":1700000000000,
 "sessions":{
   "ses_past":{"state":"done","reason":null,"ts":50,"task":null,"title":"p"},
   "ses_target":{"state":"needs-attention","reason":"permission","ts":200,"task":null,"title":"t"}
 }}
EOF
  # current.ts is a STRING, not a number. Without field-type validation this
  # would pass stack_read's container check and then break stack_reconcile
  # (numeric comparison under set -e).
  write_stack "$sandbox/traverse-stack.json" \
    '{"v":1,"current":{"sid":"ses_b","ts":"bad"},"back":[],"forward":[]}'
  local now_ms=1800000000000
  run_jump_with_pinned_now "select-side-effect" "$sandbox" "$pso" \
    $'/bt\tsx\tterminal_0\t0' "" "$now_ms"
  # Canonical empty → adopt (ses_past) with no push → new-nav pushes
  # ses_past MRU. Result mirrors test_31 (fresh-stack adopt path).
  assert_stack_eq "case71 bad-ts stack treated as fresh; adopt + new-nav produces expected shape" \
    "{\"v\":1,\"current\":{\"sid\":\"ses_target\",\"ts\":${now_ms}},\"back\":[\"ses_past\"],\"forward\":[]}" \
    "$sandbox/traverse-stack.json"
  assert_file_exists "case71 .select written for actionable target" \
    "$sandbox/${key}-${pid}.select"
}

# --- 72. stack_read field-level validation: non-string entry in back[]
#         → adopt canonical empty. ---
test_72_nonstring_back_entry_canonical_empty() {
  local sandbox="$ROOT/case72"
  mkdir -p "$sandbox"
  local pid=72001
  local pso="$ROOT/ps72.tsv"
  printf 'OPENCODE\t%s\n' "$pid" > "$pso"
  local key; key=$(printf '%s' "/ns" | shasum -a 256 | cut -c1-16)
  cat > "$sandbox/${key}-${pid}.json" <<EOF
{"repo":"r","cwd":"/ns","session":"sx","pid":${pid},
 "selectedSid":"ses_past","selectedTs":1700000000000,
 "sessions":{
   "ses_past":{"state":"done","reason":null,"ts":50,"task":null,"title":"p"},
   "ses_target":{"state":"needs-attention","reason":"permission","ts":200,"task":null,"title":"t"}
 }}
EOF
  # back contains an object (not a string). stack_reconcile would compare
  # . != sid (type mismatch) under set -e.
  write_stack "$sandbox/traverse-stack.json" \
    '{"v":1,"current":null,"back":[{}],"forward":[]}'
  local now_ms=1800000000000
  run_jump_with_pinned_now "select-side-effect" "$sandbox" "$pso" \
    $'/ns\tsx\tterminal_0\t0' "" "$now_ms"
  assert_stack_eq "case72 back-object stack treated as fresh; adopt + new-nav produces expected shape" \
    "{\"v\":1,\"current\":{\"sid\":\"ses_target\",\"ts\":${now_ms}},\"back\":[\"ses_past\"],\"forward\":[]}" \
    "$sandbox/traverse-stack.json"
  assert_file_exists "case72 .select written for actionable target" \
    "$sandbox/${key}-${pid}.select"
}

# --- 73. atomic_write_select warn-and-return-0 on mailbox rename failure.
#         Pre-create the .select path as an IMMUTABLE file (chflags uchg, the
#         Darwin rename-failure primitive used by test_60) and confirm:
#           (a) jump exits 0,
#           (b) atomic_write_select warning reaches stderr,
#           (c) the stack still gets written (landing continued past write),
#           (d) the failing path is on the mailbox, NOT on the stack. ---
test_73_mailbox_write_failure_continues() {
  local sandbox="$ROOT/case73"
  mkdir -p "$sandbox"
  local pid=73001
  local pso="$ROOT/ps73.tsv"
  printf 'OPENCODE\t%s\n' "$pid" > "$pso"
  local key; key=$(printf '%s' "/mf" | shasum -a 256 | cut -c1-16)
  cat > "$sandbox/${key}-${pid}.json" <<EOF
{"repo":"r","cwd":"/mf","session":"sx","pid":${pid},
 "selectedSid":"ses_past","selectedTs":1700000000000,
 "sessions":{
   "ses_past":{"state":"done","reason":null,"ts":50,"task":null,"title":"p"},
   "ses_target":{"state":"needs-attention","reason":"permission","ts":200,"task":null,"title":"t"}
 }}
EOF
  # Pre-write a benign (immutable) .select file so the rename onto it fails.
  printf '%s\n' '{"sessionID":"pristine"}' > "$sandbox/${key}-${pid}.select"
  chflags uchg "$sandbox/${key}-${pid}.select"
  local now_ms=1800000000000
  run_jump_with_pinned_now "select-side-effect" "$sandbox" "$pso" \
    $'/mf\tsx\tterminal_0\t0' "" "$now_ms"
  # Jump must still emit the same select decision and exit 0.
  assert_eq "case73 verbatim select decision despite mailbox failure" \
    "DECISION:kind=select cwd=/mf session=sx pane=terminal_0 tab_id=0 key=${key}-${pid} sid=ses_target" \
    "$JUMP_STDOUT"
  assert_eq "case73 jump exits 0 despite mailbox failure" "0" "$JUMP_RC"
  # atomic_write_select warning reaches stderr.
  assert_contains "case73 stderr: atomic_write_select warning emitted" \
    "$JUMP_STDERR" "atomic_write_select"
  # Stack is still persisted (landing continued past the failed mailbox write).
  assert_stack_eq "case73 stack_write succeeds despite mailbox failure (act_land did not abort jump)" \
    "{\"v\":1,\"current\":{\"sid\":\"ses_target\",\"ts\":${now_ms}},\"back\":[\"ses_past\"],\"forward\":[]}" \
    "$sandbox/traverse-stack.json"
  # Drop uchg so EXIT trap can clean up.
  chflags nouchg "$sandbox/${key}-${pid}.select" 2>/dev/null || true
}

# --- 74. mktemp-failure tolerance: both stack_write AND atomic_write_select
#         self-guard so a missing/unwritable STATE_DIR doesn't abort the
#         press under set -e. We make STATE_DIR readable (model still loads
#         the v2 file from it) but NOT writable — mktemp then deterministically
#         fails on both tmpfile paths, both writers warn-and-return-0, the
#         press completes with rc=0, and the DECISION line is still emitted. ---
test_74_mktemp_failure_continues() {
  local sandbox="$ROOT/case74"
  mkdir -p "$sandbox"
  local pid=74001
  local pso="$ROOT/ps74.tsv"
  printf 'OPENCODE\t%s\n' "$pid" > "$pso"
  local key; key=$(printf '%s' "/tt" | shasum -a 256 | cut -c1-16)
  # v2 file readable so the model can populate actionable[].
  cat > "$sandbox/${key}-${pid}.json" <<EOF
{"repo":"r","cwd":"/tt","session":"sx","pid":${pid},
 "selectedSid":"ses_past","selectedTs":1700000000000,
 "sessions":{
   "ses_past":{"state":"done","reason":null,"ts":50,"task":null,"title":"p"},
   "ses_target":{"state":"needs-attention","reason":"permission","ts":200,"task":null,"title":"t"}
 }}
EOF
  # chmod 555 on STATE_DIR: existing entries stay readable + traversable
  # (model still loads v2 file) but the writers' mktemp calls for NEW
  # traverse-stack.json.tmp.XXXXXX and .select.tmp.XXXXXX fail with EACCES.
  chmod 555 "$sandbox"
  local now_ms=1800000000000
  run_jump_with_pinned_now "select-side-effect" "$sandbox" "$pso" \
    $'/tt\tsx\tterminal_0\t0' "" "$now_ms"
  # Restore WRITE bit so the EXIT trap's rm -rf can clean the sandbox.
  chmod 755 "$sandbox" 2>/dev/null || true
  # Jump exits 0 — writers self-guarded, the press continued to landing.
  assert_eq "case74 jump exits 0 despite mktemp failure" "0" "$JUMP_RC"
  # Decision text still emitted (no side-effect abort propagated).
  assert_eq "case74 decision still emitted when writers' tmpfile creation fails" \
    "DECISION:kind=select cwd=/tt session=sx pane=terminal_0 tab_id=0 key=${key}-${pid} sid=ses_target" \
    "$JUMP_STDOUT"
  # Both writers' tmpfile-creation warnings reached stderr (one each).
  assert_contains "case74 stderr: stack_write tmpfile creation warning" \
    "$JUMP_STDERR" "stack_write"
  assert_contains "case74 stderr: atomic_write_select tmpfile creation warning" \
    "$JUMP_STDERR" "atomic_write_select"
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

run_test test_18_decide_only_no_side_effects
run_test test_30_select_writes_reconciled_stack
run_test test_31_fresh_stack_adopts_no_push
run_test test_32_corrupt_stack_treated_as_fresh
run_test test_33_passive_departure_clears_forward
run_test test_34_mru_dedup_no_double_insert
run_test test_40a_noop_persists_reconcile
run_test test_40b_warn_persists_reconcile
run_test test_40c_focus_only_persists_reconcile
run_test test_40d_fallback_pane_persists_reconcile
run_test test_50_stale_p_within_window_ignored
run_test test_51_stale_p_outside_window_flips
run_test test_60_stack_write_failure_select_lands
run_test test_70_escaped_sid_mailbox
run_test test_71_bad_ts_type_canonical_empty
run_test test_72_nonstring_back_entry_canonical_empty
run_test test_73_mailbox_write_failure_continues
run_test test_74_mktemp_failure_continues
run_test test_notes_session_does_not_switch_to_remote_agent

# Print accumulated log
cat "$ROOT/log"
echo "---"
echo "PASS: $PASS  FAIL: $FAIL"

if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
