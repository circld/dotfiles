#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MODEL="$REPO_ROOT/scripts/agent-fleet-model.mjs"

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n  %s\n' "$1" "$2"; }
assert_eq() {
  local label="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then pass "$label"; else fail "$label" "want=$want got=$got"; fi
}

key_for() { printf '%s' "$1" | shasum -a 256 | cut -c1-16; }

run_model() {
  local sandbox="$1" pso="$2" live="$3"
  local pane_file="$ROOT/panes-${RANDOM}.tsv"
  printf '%s\n' "$live" > "$pane_file"
  # `node` is allowed to exit nonzero (some tests deliberately feed junk
  # fixtures); disable -e around the call so we capture RC rather than aborting
  # the whole suite under strict mode. Re-enable for the rest of the function.
  set +e
  MODEL_OUT="$(env \
    AGENT_FLEET_STATE_DIR="$sandbox" \
    AGENT_FLEET_LIVE_PANES_OVERRIDE="$pane_file" \
    AGENT_FLEET_PS_OVERRIDE="$pso" \
    node "$MODEL" 2>"$ROOT/model.err")"
  MODEL_RC=$?
  MODEL_ERR="$(cat "$ROOT/model.err")"
  set -e
}

# --- regression: existing row/actionable behavior preserved ---
test_model_classifies_once() {
  local sandbox="$ROOT/state"
  mkdir -p "$sandbox"
  local pso="$ROOT/ps.tsv"
  printf 'OPENCODE\t1001\nOPENCODE\t1002\nDEAD\t1003\n' > "$pso"
  local keyA; keyA=$(key_for "/repoA")
  local keyB; keyB=$(key_for "/repoB")
  local keyC; keyC=$(key_for "/repoC")
  local keyD; keyD=$(key_for "/repoD")

  cat > "$sandbox/${keyA}-1001.json" <<EOF
{"repo":"repoA","cwd":"/repoA","session":"sx","pid":1001,
 "sessions":{
   "blocked":{"state":"needs-attention","reason":"permission","ts":300,"task":null,"title":"Blocked"},
   "viewed":{"state":"done","reason":null,"ts":100,"task":null,"title":"Viewed"},
   "work":{"state":"working","reason":null,"ts":200,"task":null,"title":"Work"}
 }}
EOF
  cat > "$sandbox/${keyA}-1001.viewed.json" <<'EOF'
{"viewed":150}
EOF
  cat > "$sandbox/${keyB}.json" <<EOF
{"repo":"legacy","cwd":"/repoB","session":"sx","state":"done","reason":null,"ts":50,"task":null}
EOF
  cat > "$sandbox/${keyC}-1002.json" <<EOF
{"repo":"c","cwd":"/repoC","session":"sx","pid":1002,
 "sessions":{"c1":{"state":"needs-attention","reason":"permission","ts":500,"task":null,"title":"C1"}}}
EOF
  cat > "$sandbox/${keyC}-1003.json" <<EOF
{"repo":"c","cwd":"/repoC","session":"sx","pid":1003,
 "sessions":{"dead":{"state":"needs-attention","reason":"permission","ts":900,"task":null,"title":"Dead"}}}
EOF
  cat > "$sandbox/${keyD}-1002.json" <<EOF
{"repo":"ghost","cwd":"/repoD","session":"sx","pid":1002,
 "sessions":{"ghost":{"state":"needs-attention","reason":"permission","ts":700,"task":null,"title":"Ghost"}}}
EOF

  run_model "$sandbox" "$pso" $'/repoA\tsx\tterminal_1\t0\n/repoB\tsx\tterminal_2\t0\n/repoC\tsx\tterminal_3\t0\n/repoE\tsx\tterminal_4\t0'
  assert_eq "model exits 0" "0" "$MODEL_RC"
  assert_eq "one suppressed row reported" "1" "$(jq '[.rows[] | select(.suppressed == true)] | length' <<<"$MODEL_OUT")"
  assert_eq "visible rows include v2, v1, and synthetic" "5" "$(jq '[.rows[] | select(.suppressed == false)] | length' <<<"$MODEL_OUT")"
  assert_eq "dead/ghost state files are dropped" "0" "$(jq '[.rows[] | select(.sid == "dead" or .sid == "ghost")] | length' <<<"$MODEL_OUT")"
  assert_eq "highest actionable candidate is newest attention" "c1" "$(jq -r '.actionable[0].sid' <<<"$MODEL_OUT")"
  assert_eq "legacy row has focus-only sid" "null" "$(jq -r '.rows[] | select(.cwd == "/repoB") | .sid' <<<"$MODEL_OUT")"
  assert_eq "synthetic row emitted for live pane without state" "unknown" "$(jq -r '.rows[] | select(.cwd == "/repoE") | .state' <<<"$MODEL_OUT")"
}

# --- instances[].shape: live v2 emits {key,cwd,selectedSid,selectedTs,sessions} ---
test_instances_shape() {
  local sandbox="$ROOT/inst_shape"
  mkdir -p "$sandbox"
  local pso="$ROOT/ps_inst_shape.tsv"
  printf 'OPENCODE\t50001\n' > "$pso"
  local key; key=$(key_for "/inst1")
  cat > "$sandbox/${key}-50001.json" <<EOF
{"repo":"i","cwd":"/inst1","session":"sx","pid":50001,
 "selectedSid":"selX","selectedTs":7777,
 "sessions":{
   "ses_a":{"state":"needs-attention","reason":"perm","ts":200,"task":null,"title":"a"},
   "ses_b":{"state":"done","reason":null,"ts":100,"task":null,"title":"b"}
 }}
EOF
  run_model "$sandbox" "$pso" $'/inst1\tsx\tterminal_0\t0'
  assert_eq "instances shape: rc=0" "0" "$MODEL_RC"
  assert_eq "instances shape: exactly 1 instance" "1" "$(jq '.instances | length' <<<"$MODEL_OUT")"
  assert_eq "instances shape: key" "${key}-50001" "$(jq -r '.instances[0].key' <<<"$MODEL_OUT")"
  assert_eq "instances shape: cwd" "/inst1" "$(jq -r '.instances[0].cwd' <<<"$MODEL_OUT")"
  assert_eq "instances shape: selectedSid" "selX" "$(jq -r '.instances[0].selectedSid' <<<"$MODEL_OUT")"
  assert_eq "instances shape: selectedTs" "7777" "$(jq -r '.instances[0].selectedTs' <<<"$MODEL_OUT")"
  assert_eq "instances shape: only real sessions (sorted)" "ses_a,ses_b" \
    "$(jq -r '.instances[0].sessions | sort | join(",")' <<<"$MODEL_OUT")"
}

# Seeded sessions stay in instances[] for traversal liveness, but their
# unknown/sensor-restarted rows are not attention-board entries.
test_seeded_unknown_rows_hidden_from_board() {
  local sandbox="$ROOT/seeded_unknown"
  mkdir -p "$sandbox"
  local pso="$ROOT/ps_seeded_unknown"
  printf 'OPENCODE\t50002\n' > "$pso"
  local key; key=$(key_for "/seeded")
  cat > "$sandbox/${key}-50002.json" <<EOF
{"repo":"s","cwd":"/seeded","session":"sx","pid":50002,
 "sessions":{
   "old_chat":{"state":"unknown","reason":"sensor restarted","ts":100,"task":null,"title":"old chat"},
   "active_chat":{"state":"working","reason":null,"ts":200,"task":null,"title":"active chat"}
 }}
EOF
  run_model "$sandbox" "$pso" $'/seeded\tsx\tterminal_0\t0'
  assert_eq "seeded unknown: model exits 0" "0" "$MODEL_RC"
  assert_eq "seeded unknown: old chat not rendered as row" "0" \
    "$(jq '[.rows[] | select(.sid == "old_chat")] | length' <<<"$MODEL_OUT")"
  assert_eq "seeded unknown: active chat remains rendered" "1" \
    "$(jq '[.rows[] | select(.sid == "active_chat")] | length' <<<"$MODEL_OUT")"
  assert_eq "seeded unknown: old chat remains traversable" "active_chat,old_chat" \
    "$(jq -r '.instances[0].sessions | sort | join(",")' <<<"$MODEL_OUT")"
}

# --- instances skip __pane__ sentinel in sessions list ---
test_instances_skip_pane_sentinel() {
  local sandbox="$ROOT/inst_pane_skip"
  mkdir -p "$sandbox"
  local pso="$ROOT/ps_pane_skip.tsv"
  printf 'OPENCODE\t50011\n' > "$pso"
  local key; key=$(key_for "/pane_skip")
  cat > "$sandbox/${key}-50011.json" <<EOF
{"repo":"p","cwd":"/pane_skip","session":"sx","pid":50011,
 "sessions":{
   "__pane__":{"state":"unknown","reason":null,"ts":1,"task":null,"title":"ignored"},
   "ses_only":{"state":"needs-attention","reason":"perm","ts":10,"task":null,"title":"only"}
 }}
EOF
  run_model "$sandbox" "$pso" $'/pane_skip\tsx\tterminal_0\t0'
  assert_eq "instances skip __pane__: only ses_only" "ses_only" \
    "$(jq -r '.instances[0].sessions | join(",")' <<<"$MODEL_OUT")"
}

# --- ambiguous cwd: instances[] keeps both v2 files (rows collapses to warning) ---
test_instances_keeps_ambiguous() {
  local sandbox="$ROOT/inst_amb"
  mkdir -p "$sandbox"
  local pso="$ROOT/ps_inst_amb.tsv"
  printf 'OPENCODE\t50101\n' > "$pso"
  printf 'OPENCODE\t50102\n' >> "$pso"
  local key; key=$(key_for "/dup_inst")
  cat > "$sandbox/${key}-50101.json" <<EOF
{"repo":"a","cwd":"/dup_inst","session":"sx","pid":50101,
 "sessions":{"sA":{"state":"needs-attention","reason":"perm","ts":100,"task":null,"title":"A"}}}
EOF
  cat > "$sandbox/${key}-50102.json" <<EOF
{"repo":"b","cwd":"/dup_inst","session":"sx","pid":50102,
 "sessions":{"sB":{"state":"done","reason":null,"ts":200,"task":null,"title":"B"}}}
EOF
  run_model "$sandbox" "$pso" $'/dup_inst\tsx\tterminal_0\t0'
  assert_eq "ambiguous: 2 instances kept" "2" "$(jq '.instances | length' <<<"$MODEL_OUT")"
  assert_eq "ambiguous: only one warning row in rows" "1" \
    "$(jq '[.rows[] | select(.source == "warning")] | length' <<<"$MODEL_OUT")"
  assert_eq "ambiguous: rows total = 1 (no session rows)" "1" "$(jq '.rows | length' <<<"$MODEL_OUT")"
  assert_eq "ambiguous: cwd marked ambiguous" "1" \
    "$(jq '[.ambiguous[] | select(. == "/dup_inst")] | length' <<<"$MODEL_OUT")"
}

# --- timeline.pending: FIFO oldest first, ignores rank ---
test_timeline_pending_fifo() {
  local sandbox="$ROOT/pending_fifo"
  mkdir -p "$sandbox"
  local pso="$ROOT/ps_pending_fifo.tsv"
  printf 'OPENCODE\t60101\n' > "$pso"
  local key; key=$(key_for "/fifo")
  cat > "$sandbox/${key}-60101.json" <<EOF
{"repo":"f","cwd":"/fifo","session":"sx","pid":60101,
 "sessions":{
   "ses_old_done":{"state":"done","reason":null,"ts":50,"task":null,"title":"old d"},
   "ses_new_attention":{"state":"needs-attention","reason":"perm","ts":300,"task":null,"title":"new n"},
   "ses_mid_done":{"state":"done","reason":null,"ts":150,"task":null,"title":"mid d"}
 }}
EOF
  run_model "$sandbox" "$pso" $'/fifo\tsx\tterminal_0\t0'
  assert_eq "pending FIFO ignores rank" \
    "ses_old_done,ses_mid_done,ses_new_attention" \
    "$(jq -r '.timeline.pending | map(.sid) | join(",")' <<<"$MODEL_OUT")"
}

# --- timeline.pending: excludes null-sid rows ---
# Setup uses a v1-LEGACY shape: state at top level, no `sessions` object.
# baseRow for v1 produces sid=null with rank assigned from top-level state,
# so it lands in actionable (suppressed=false, rank!=null, source!='warning').
# The pending filter MUST drop it. If the filter were missing, this row
# would survive into timeline.pending and the assertions would fail.
test_timeline_pending_excludes_null_sid() {
  local sandbox="$ROOT/pending_null"
  mkdir -p "$sandbox"
  local pso="$ROOT/ps_pending_null.tsv"
  printf 'OPENCODE\t60201\n' > "$pso"
  local key; key=$(key_for "/nullsid")
  # v1 legacy: top-level state, no `sessions` object, low pid (does not matter
  # because v1 doesn't carry pid). NO v2 file: cwd is v1-only so the legacy
  # row survives and emits sid=null.
  cat > "$sandbox/${key}.json" <<EOF
{"repo":"legacy","cwd":"/nullsid","session":"sx","state":"needs-attention","reason":"perm","ts":200,"task":null}
EOF
  run_model "$sandbox" "$pso" $'/nullsid\tsx\tterminal_0\t0'
  # v1 row IS in rows[] and IS in actionable[] (rank!=null, suppressed=false).
  assert_eq "null-sid v1: row emitted in rows" "1" \
    "$(jq '[.rows[] | select(.sid == null and .source == "v1")] | length' <<<"$MODEL_OUT")"
  assert_eq "null-sid v1: row in actionable" "1" \
    "$(jq '[.actionable[] | select(.sid == null and .source == "v1")] | length' <<<"$MODEL_OUT")"
  # But MUST be excluded from pending (sid != null filter).
  assert_eq "null-sid v1: dropped from pending" "0" \
    "$(jq '[.timeline.pending[] | select(.sid == null)] | length' <<<"$MODEL_OUT")"
  assert_eq "null-sid v1: timeline.pending empty (no v1 sid to surface)" "0" \
    "$(jq '.timeline.pending | length' <<<"$MODEL_OUT")"
}

# --- timeline.viewed: joined to live instance, newest viewedTs first ---
test_timeline_viewed_newest_first() {
  local sandbox="$ROOT/viewed_newest"
  mkdir -p "$sandbox"
  local pso="$ROOT/ps_viewed_newest.tsv"
  printf 'OPENCODE\t70101\n' > "$pso"
  local key; key=$(key_for "/vn")
  cat > "$sandbox/${key}-70101.json" <<EOF
{"repo":"v","cwd":"/vn","session":"sx","pid":70101,
 "sessions":{
   "ses_old":{"state":"done","reason":null,"ts":100,"task":null,"title":"old"},
   "ses_new":{"state":"done","reason":null,"ts":200,"task":null,"title":"new"}
 }}
EOF
  cat > "$sandbox/${key}-70101.viewed.json" <<'EOF'
{"ses_old": 300, "ses_new": 500}
EOF
  run_model "$sandbox" "$pso" $'/vn\tsx\tterminal_0\t0'
  assert_eq "viewed newest-first by viewedTs" "ses_new,ses_old" \
    "$(jq -r '.timeline.viewed | map(.sid) | join(",")' <<<"$MODEL_OUT")"
  assert_eq "viewed payload: viewedTs column preserved" "500" \
    "$(jq -r '[.timeline.viewed[] | select(.sid == "ses_new")] | first | .viewedTs' <<<"$MODEL_OUT")"
}

# --- timeline.viewed: pending sids win (sids in pending are removed from viewed) ---
# ses_new_attention is also recorded in viewed.json at ts=100 (BELOW its entryTs=300,
# so 100 >= 300 is false -> not suppressed -> lands in pending). The viewed merge
# MUST drop it from timeline.viewed because pending-wins. This proves the
# pending-exclusion filter is actually wired: if it were missing, the
# ses_new_attention entry would survive into viewed. ---
test_timeline_viewed_pending_wins() {
  local sandbox="$ROOT/pending_wins"
  mkdir -p "$sandbox"
  local pso="$ROOT/ps_pending_wins.tsv"
  printf 'OPENCODE\t70201\n' > "$pso"
  local key; key=$(key_for "/pw")
  cat > "$sandbox/${key}-70201.json" <<EOF
{"repo":"p","cwd":"/pw","session":"sx","pid":70201,
 "sessions":{
   "ses_old_done":{"state":"done","reason":null,"ts":50,"task":null,"title":"old d"},
   "ses_new_attention":{"state":"needs-attention","reason":"perm","ts":300,"task":null,"title":"new n"},
   "ses_suppressed_done":{"state":"done","reason":null,"ts":150,"task":null,"title":"sup d"}
 }}
EOF
  # viewed marks BOTH suppressed sids (>= entryTs -> suppressed) AND
  # ses_new_attention at 100 (< entryTs=300 -> NOT suppressed -> pending).
  cat > "$sandbox/${key}-70201.viewed.json" <<'EOF'
{"ses_old_done": 80, "ses_suppressed_done": 200, "ses_new_attention": 100}
EOF
  run_model "$sandbox" "$pso" $'/pw\tsx\tterminal_0\t0'
  # ses_old_done: 80 >= 50 -> suppressed -> not actionable -> not in pending.
  # ses_suppressed_done: 200 >= 150 -> suppressed -> not in pending.
  # ses_new_attention: 100 < 300 -> NOT suppressed -> lands in pending.
  assert_eq "pending: only unsuppressed actionable (ses_new_attention)" "ses_new_attention" \
    "$(jq -r '.timeline.pending | map(.sid) | join(",")' <<<"$MODEL_OUT")"
  # viewed includes both suppressed done sids (not pending, viewed marks applied).
  assert_eq "viewed includes ses_old_done" "ses_old_done" \
    "$(jq -r '[.timeline.viewed[] | select(.sid == "ses_old_done")] | first | .sid' <<<"$MODEL_OUT")"
  assert_eq "viewed includes ses_suppressed_done" "ses_suppressed_done" \
    "$(jq -r '[.timeline.viewed[] | select(.sid == "ses_suppressed_done")] | first | .sid' <<<"$MODEL_OUT")"
  # pending wins: ses_new_attention IS in pending AND IS in the merged viewed
  # source map (viewedTs=100 < entryTs=300 means it's still recorded). The
  # pending-exclusion filter MUST drop it. If the filter is missing,
  # ses_new_attention will appear in timeline.viewed and the next assertion
  # fails.
  assert_eq "pending wins over viewed (ses_new_attention absent in viewed)" "0" \
    "$(jq '[.timeline.viewed[] | select(.sid == "ses_new_attention")] | length' <<<"$MODEL_OUT")"
}

# --- timeline.viewed: prunes entries not present in any live instance ---
test_timeline_viewed_pruned_absent() {
  local sandbox="$ROOT/viewed_pruned"
  mkdir -p "$sandbox"
  local pso="$ROOT/ps_viewed_pruned.tsv"
  printf 'OPENCODE\t70301\n' > "$pso"
  local key; key=$(key_for "/pr")
  cat > "$sandbox/${key}-70301.json" <<EOF
{"repo":"p","cwd":"/pr","session":"sx","pid":70301,
 "sessions":{"ses_present":{"state":"done","reason":null,"ts":100,"task":null,"title":"p"}}}
EOF
  cat > "$sandbox/${key}-70301.viewed.json" <<'EOF'
{"ses_present": 200, "ses_ghost": 500}
EOF
  run_model "$sandbox" "$pso" $'/pr\tsx\tterminal_0\t0'
  assert_eq "viewed prune: no ghost sid in viewed" "0" \
    "$(jq '[.timeline.viewed[] | select(.sid == "ses_ghost")] | length' <<<"$MODEL_OUT")"
  assert_eq "viewed prune: only ses_present" "ses_present" \
    "$(jq -r '.timeline.viewed | map(.sid) | join(",")' <<<"$MODEL_OUT")"
}

# --- corrupt / non-object viewed.json acts as empty map ---
test_timeline_viewed_corrupt_handles() {
  local sandbox="$ROOT/viewed_corrupt"
  mkdir -p "$sandbox"
  local pso="$ROOT/ps_viewed_corrupt.tsv"
  printf 'OPENCODE\t70401\n' > "$pso"
  local key; key=$(key_for "/corrupt")
  cat > "$sandbox/${key}-70401.json" <<EOF
{"repo":"c","cwd":"/corrupt","session":"sx","pid":70401,
 "sessions":{"ses_x":{"state":"done","reason":null,"ts":100,"task":null,"title":"x"}}}
EOF
  cat > "$sandbox/${key}-70401.viewed.json" <<'EOF'
{not valid json at all
EOF
  run_model "$sandbox" "$pso" $'/corrupt\tsx\tterminal_0\t0'
  assert_eq "corrupt viewed: rc=0" "0" "$MODEL_RC"
  assert_eq "corrupt viewed: timeline.viewed empty" "0" \
    "$(jq '.timeline.viewed | length' <<<"$MODEL_OUT")"
  assert_eq "corrupt viewed: ses_x not suppressed (no viewed)" "false" \
    "$(jq -r '.rows[] | select(.sid == "ses_x") | .suppressed' <<<"$MODEL_OUT")"
}

# --- merge edge cases: bare + per-pid files together; numeric max wins;
#     corrupt sibling ignored; non-numeric ts rejected; stray
#     `<hash>-backup.viewed.json` (non-numeric pid suffix) MUST be ignored. ---
test_timeline_viewed_merge_edge_cases() {
  local sandbox="$ROOT/viewed_merge"
  mkdir -p "$sandbox"
  local pso="$ROOT/ps_viewed_merge.tsv"
  printf 'OPENCODE\t90001\n' > "$pso"
  local key; key=$(key_for "/merge")

  # Bare legacy viewed.json: ses_old=50, ses_dup=100 (lower than the per-pid
  # file's 200 — proves max wins), ses_str="NaN" (non-numeric ts — rejected).
  cat > "$sandbox/${key}.viewed.json" <<'EOF'
{"ses_old": 50, "ses_dup": 100, "ses_str": "NaN"}
EOF
  # Per-pid viewed.json: ses_dup upgraded to 200 (numeric max wins vs bare's 100),
  # ses_new appears only here.
  cat > "$sandbox/${key}-90001.viewed.json" <<'EOF'
{"ses_dup": 200, "ses_new": 300}
EOF
  # Corrupt sibling file: pid-suffix file with broken JSON. Filter accepts the
  # name (numeric pid 90002 matches), but readJson fallback {null} is non-object,
  # so the merge loop ignores it. Useful to PROVE the valid file's data still wins.
  cat > "$sandbox/${key}-90002.viewed.json" <<'EOF'
{not valid json at all
EOF
  # STRAY file: `${key}-backup.viewed.json` (non-numeric suffix). The fix's
  # regex `^<hash>(-[0-9]+)?\.viewed\.json$` MUST reject this name entirely.
  # If the filter were loose (current pre-fix code accepts any `<hash>-*.viewed.json`),
  # ses_old would jump to 99999999 (suppressing it) and timeline.viewed would
  # admit ses_old. Both wrong.
  cat > "$sandbox/${key}-backup.viewed.json" <<'EOF'
{"ses_old": 99999999, "ses_dup": 99999999, "ses_new": 99999999}
EOF

  cat > "$sandbox/${key}-90001.json" <<EOF
{"repo":"m","cwd":"/merge","session":"sx","pid":90001,
 "sessions":{
   "ses_old":{"state":"done","reason":null,"ts":200,"task":null,"title":"o"},
   "ses_dup":{"state":"done","reason":null,"ts":150,"task":null,"title":"d"},
   "ses_new":{"state":"needs-attention","reason":"perm","ts":10,"task":null,"title":"n"}
 }}
EOF
  run_model "$sandbox" "$pso" $'/merge\tsx\tterminal_0\t0'

  # --- filter correctness (Issues 1 & 3): stray MUST be excluded ---
  assert_eq "merge: rc=0" "0" "$MODEL_RC"
  assert_eq "merge: ses_old NOT suppressed by stray 99999999 (kept at bare=50 < 200)" "false" \
    "$(jq -r '.rows[] | select(.sid == "ses_old") | .suppressed' <<<"$MODEL_OUT")"
  assert_eq "merge: ses_str absent from rows (NEVER in instance.sessions)" "0" \
    "$(jq '[.rows[] | select(.sid == "ses_str")] | length' <<<"$MODEL_OUT")"

  # --- merge correctness (Issue 3): numeric max across files + pid per-file pick up ---
  assert_eq "merge: ses_dup suppressed (200 >= 150, max of bare's 100 vs pid's 200)" "true" \
    "$(jq -r '.rows[] | select(.sid == "ses_dup") | .suppressed' <<<"$MODEL_OUT")"
  assert_eq "merge: ses_new suppressed (300 >= 10)" "true" \
    "$(jq -r '.rows[] | select(.sid == "ses_new") | .suppressed' <<<"$MODEL_OUT")"

  # --- corrupt-sibling survives intact (Issue 3) ---
  # If corrupt sibling had crashed/poisoned the cache, ses_new's suppress would
  # differ. Confirm via row presence AND no extra instance pollution.
  assert_eq "merge: 1 instance (no poison from corrupt/stray files)" "1" \
    "$(jq '.instances | length' <<<"$MODEL_OUT")"

  # --- timeline.viewed filters pending + drops non-numeric-ts + drops stray ---
  # pending = [ses_old ts=200] (only unsuppressed actionable).
  # viewed candidates {ses_old:50, ses_dup:200, ses_new:300} -> drop ses_old
  # (in pending) and drop ses_str (already absent). Final:
  #   newest-first: [{ses_new, 300}, {ses_dup, 200}].
  assert_eq "merge: timeline.viewed count = 2" "2" \
    "$(jq '.timeline.viewed | length' <<<"$MODEL_OUT")"
  assert_eq "merge: timeline.viewed[0] = ses_new (300)" "ses_new" \
    "$(jq -r '.timeline.viewed[0].sid' <<<"$MODEL_OUT")"
  assert_eq "merge: timeline.viewed[0].viewedTs = 300" "300" \
    "$(jq -r '.timeline.viewed[0].viewedTs' <<<"$MODEL_OUT")"
  assert_eq "merge: timeline.viewed[1] = ses_dup (200)" "ses_dup" \
    "$(jq -r '.timeline.viewed[1].sid' <<<"$MODEL_OUT")"
  assert_eq "merge: timeline.viewed[1].viewedTs = 200 (numeric max, NOT stray 99999999)" "200" \
    "$(jq -r '.timeline.viewed[1].viewedTs' <<<"$MODEL_OUT")"
  assert_eq "merge: timeline.viewed absent of ses_old (pending-excludes)" "0" \
    "$(jq '[.timeline.viewed[] | select(.sid == "ses_old")] | length' <<<"$MODEL_OUT")"
  assert_eq "merge: timeline.viewed absent of ses_str (non-numeric rejected)" "0" \
    "$(jq '[.timeline.viewed[] | select(.sid == "ses_str")] | length' <<<"$MODEL_OUT")"
}

# --- missing viewed.json file acts as empty map ---
# Distinct from the corrupt case: nothing on disk at all. merge must produce
# {} so rows are unsuppressed and timeline.viewed is empty. ---
test_timeline_viewed_missing_file_handles() {
  local sandbox="$ROOT/viewed_missing"
  mkdir -p "$sandbox"
  local pso="$ROOT/ps_viewed_missing.tsv"
  printf 'OPENCODE\t90001\n' > "$pso"
  local key; key=$(key_for "/no_viewed")
  cat > "$sandbox/${key}-90001.json" <<EOF
{"repo":"n","cwd":"/no_viewed","session":"sx","pid":90001,
 "sessions":{
   "ses_a":{"state":"needs-attention","reason":"perm","ts":200,"task":null,"title":"a"},
   "ses_b":{"state":"done","reason":null,"ts":100,"task":null,"title":"b"}
 }}
EOF
  # Confirm: no viewed.json files exist for /no_viewed's cwd-hash.
  run_model "$sandbox" "$pso" $'/no_viewed\tsx\tterminal_0\t0'
  assert_eq "missing viewed: rc=0" "0" "$MODEL_RC"
  assert_eq "missing viewed: timeline.viewed empty" "0" \
    "$(jq '.timeline.viewed | length' <<<"$MODEL_OUT")"
  assert_eq "missing viewed: ses_a unsuppressed" "false" \
    "$(jq -r '.rows[] | select(.sid == "ses_a") | .suppressed' <<<"$MODEL_OUT")"
  assert_eq "missing viewed: ses_b unsuppressed" "false" \
    "$(jq -r '.rows[] | select(.sid == "ses_b") | .suppressed' <<<"$MODEL_OUT")"
  # Sanity: view of on-disk state shows NO viewed files for this cwd-hash.
  local key_hash; key_hash=$(key_for "/no_viewed")
  assert_eq "missing viewed: state-dir has no viewed files for cwd-hash" "0" \
    "$(find "$sandbox" -maxdepth 1 -name "${key_hash}*.viewed.json" | wc -l | tr -d ' ')"
}

# --- restarted process inherits max viewed ts from dead pid sibling;
#     fresh event on previously-viewed sid NOT newly suppressed. ---
test_timeline_inherits_dead_pid_sibling() {
  local sandbox="$ROOT/inherit"
  mkdir -p "$sandbox"
  local pso="$ROOT/ps_inherit.tsv"
  printf 'DEAD\t90001\n' > "$pso"
  printf 'OPENCODE\t90002\n' >> "$pso"
  local key; key=$(key_for "/inherit")
  # Dead pid 90001 state file (carries stale sA/sB sessions from prior process).
  cat > "$sandbox/${key}-90001.json" <<EOF
{"repo":"prev","cwd":"/inherit","session":"sx","pid":90001,
 "sessions":{
   "sA":{"state":"done","reason":null,"ts":50,"task":null,"title":"prev a"},
   "sB":{"state":"done","reason":null,"ts":40,"task":null,"title":"prev b"}
 }}
EOF
  # Old process viewed sA at 800, sB at 900. These are the inherited marks.
  cat > "$sandbox/${key}-90001.viewed.json" <<'EOF'
{"sA": 800, "sB": 900}
EOF
  # NEW live process (pid 90002): sA arrives with a FRESH ts=2000 (> 800);
  # sB carries over the OLD ts=40; sC is a brand-new attention row.
  cat > "$sandbox/${key}-90002.json" <<EOF
{"repo":"new","cwd":"/inherit","session":"sy","pid":90002,
 "sessions":{
   "sA":{"state":"done","reason":null,"ts":2000,"task":null,"title":"new a"},
   "sB":{"state":"done","reason":null,"ts":40,"task":null,"title":"new b"},
   "sC":{"state":"needs-attention","reason":"perm","ts":1500,"task":null,"title":"new c"}
 }}
EOF
  run_model "$sandbox" "$pso" $'/inherit\tsy\tterminal_0\t0'
  # Dead pid state file is dropped from v2 (pid not alive); only LIVE v2 remains.
  # 1 v2 + 1 pane => NOT ambiguous. Standard session-row path.
  assert_eq "inherit: exactly 1 instance (dead dropped)" "1" "$(jq '.instances | length' <<<"$MODEL_OUT")"
  # fresh-event NOT newly suppressed: sA entryTs=2000 > viewedTs=800
  assert_eq "inherit: sA (fresh ts=2000) NOT suppressed by stale 800" "false" \
    "$(jq -r '.rows[] | select(.sid == "sA") | .suppressed' <<<"$MODEL_OUT")"
  # restart-warm inheritance: sB entryTs=40 <= viewedTs=900 -> suppressed
  assert_eq "inherit: sB (old ts=40) IS suppressed by inherited 900" "true" \
    "$(jq -r '.rows[] | select(.sid == "sB") | .suppressed' <<<"$MODEL_OUT")"
  # inheritance observable in timeline.viewed: sB survives pending-exclusion.
  # sA drops out (pending-sid wins), sB stays in viewed (not pending, viewed mark inherited).
  assert_eq "inherit: timeline.viewed contains sB (inherited from dead pid sibling)" \
    "sB" "$(jq -r '[.timeline.viewed[] | select(.sid == "sB")] | first | .sid' <<<"$MODEL_OUT")"
  assert_eq "inherit: timeline.viewed empty of sA (pending wins)" "0" \
    "$(jq '[.timeline.viewed[] | select(.sid == "sA")] | length' <<<"$MODEL_OUT")"
  assert_eq "inherit: pending has sA and sC (both unsuppressed actionable)" \
    "sC,sA" "$(jq -r '.timeline.pending | map(.sid) | join(",")' <<<"$MODEL_OUT")"
}

# --- files without cwd (board-cache, traverse-stack) excluded via missing-cwd guard ---
test_timeline_ignores_meta_files() {
  local sandbox="$ROOT/meta"
  mkdir -p "$sandbox"
  local pso="$ROOT/ps_meta.tsv"
  printf 'OPENCODE\t80001\n' > "$pso"
  cat > "$sandbox/traverse-stack.json" <<'EOF'
{"cwd":null,"kind":"traverse","data":[]}
EOF
  cat > "$sandbox/board-cache.json" <<'EOF'
{"cwd":null,"kind":"board","data":[]}
EOF
  local key; key=$(key_for "/only_one")
  cat > "$sandbox/${key}-80001.json" <<EOF
{"repo":"o","cwd":"/only_one","session":"sx","pid":80001,
 "sessions":{"only":{"state":"needs-attention","reason":"perm","ts":100,"task":null,"title":"only"}}}
EOF
  run_model "$sandbox" "$pso" $'/only_one\tsx\tterminal_0\t0'
  assert_eq "meta: rc=0" "0" "$MODEL_RC"
  assert_eq "meta: only 1 instance (no junk)" "1" "$(jq '.instances | length' <<<"$MODEL_OUT")"
  assert_eq "meta: single session row for /only_one" "/only_one" \
    "$(jq -r '.rows[] | select(.source != "warning") | .cwd' <<<"$MODEL_OUT")"
  assert_eq "meta: no traverse-stack key" "0" \
    "$(jq '[.instances[] | select(.key == "traverse-stack")] | length' <<<"$MODEL_OUT")"
}

# --- model-trace sidecar: provenance, rejection reasons, identity ---
test_model_trace_sidecar() {
  local sandbox="$ROOT/state-mt"; mkdir -p "$sandbox"
  local pso="$ROOT/pso-mt"; printf 'OPENCODE\t1001\nDEAD\t1003\n' > "$pso"
  local keyA; keyA=$(key_for "/repoA")
  cat > "$sandbox/${keyA}-1001.json" <<'EOF'
{"repo":"a","cwd":"/repoA","session":"sx","pid":1001,"sessions":{"s1":{"state":"done","reason":null,"ts":100,"task":null,"title":"A1"}}}
EOF
  cat > "$sandbox/${keyA}-1003.json" <<'EOF'
{"repo":"a","cwd":"/repoA","session":"sx","pid":1003,"sessions":{"d":{"state":"done","reason":null,"ts":100,"task":null,"title":"D"}}}
EOF
  local keyZ; keyZ=$(key_for "/repoZ")
  cat > "$sandbox/${keyZ}-1001.json" <<'EOF'
{"repo":"z","cwd":"/repoZ","session":"sx","pid":1001,"sessions":{"z":{"state":"done","reason":null,"ts":100,"task":null,"title":"Z"}}}
EOF
  printf 'not json' > "$sandbox/corrupt.json"
  printf '{"pid":1001,"sessions":{}}' > "$sandbox/nocwd.json"
  local tree="$ROOT/pstree-mt"; printf '1001 900 opencode\n900 1 zellij\n' > "$tree"
  local lsof="$ROOT/lsof-mt"; printf 'p1001\nn/repoA\n' > "$lsof"
  local trace="$ROOT/trace-mt"
  local pane_file="$ROOT/panes-mt.tsv"; printf '/repoA\tsx\tterminal_1\t0\n' > "$pane_file"
  set +e
  env AGENT_FLEET_STATE_DIR="$sandbox" \
    AGENT_FLEET_LIVE_PANES_OVERRIDE="$pane_file" AGENT_FLEET_PS_OVERRIDE="$pso" \
    AGENT_FLEET_PS_TREE_OVERRIDE="$tree" AGENT_FLEET_LSOF_OVERRIDE="$lsof" \
    AGENT_FLEET_TRACE_DIR="$trace" AF_REQUEST_ID="mt-req" node "$MODEL" >/dev/null
  local rc=$?
  set -e
  assert_eq "mt: model exits 0" "0" "$rc"
  local side="$trace/mt-req/model-trace.json"
  assert_eq "mt: sidecar exists" "yes" "$([ -f "$side" ] && echo yes || echo no)"
  assert_eq "mt: dead-pid rejection" "dead-pid" "$(jq -r '.files[] | select(.name | endswith("-1003.json")) | .reason' "$side")"
  assert_eq "mt: not-live rejection" "not-live" "$(jq -r --arg p "$keyZ" '.files[] | select(.name | startswith($p)) | .reason' "$side")"
  assert_eq "mt: corrupt rejection" "parse-fail" "$(jq -r '.files[] | select(.name == "corrupt.json") | .reason' "$side")"
  assert_eq "mt: no-cwd rejection" "no-cwd" "$(jq -r '.files[] | select(.name == "nocwd.json") | .reason' "$side")"
  assert_eq "mt: used verdict" "v2-used" "$(jq -r --arg n "${keyA}-1001.json" '.files[] | select(.name == $n) | .verdict' "$side")"
  assert_eq "mt: sha1 recorded" "40" "$(jq -r --arg n "${keyA}-1001.json" '.files[] | select(.name == $n) | .sha1 | length' "$side")"
  assert_eq "mt: ps check recorded (dead pid 1003)" "false" "$(jq -r '[.ps[] | select(.pid == 1003)][0].alive' "$side")"
  assert_eq "mt: zellij descendant" "true" "$(jq -r '.identity[] | select(.pid == 1001) | .zellijDescendant' "$side")"
  assert_eq "mt: cwd match" "true" "$(jq -r '.identity[] | select(.pid == 1001) | .cwdMatch' "$side")"
}

test_model_classifies_once
test_instances_shape
test_seeded_unknown_rows_hidden_from_board
test_instances_skip_pane_sentinel
test_instances_keeps_ambiguous
test_timeline_pending_fifo
test_timeline_pending_excludes_null_sid
test_timeline_viewed_newest_first
test_timeline_viewed_pending_wins
test_timeline_viewed_pruned_absent
test_timeline_viewed_corrupt_handles
test_timeline_viewed_merge_edge_cases
test_timeline_viewed_missing_file_handles
test_timeline_inherits_dead_pid_sibling
test_timeline_ignores_meta_files
test_model_trace_sidecar

echo "---"
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
