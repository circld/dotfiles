#!/usr/bin/env bash
set -uo pipefail

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
  MODEL_OUT="$(env \
    AGENT_FLEET_STATE_DIR="$sandbox" \
    AGENT_FLEET_LIVE_PANES_OVERRIDE="$pane_file" \
    AGENT_FLEET_PS_OVERRIDE="$pso" \
    node "$MODEL" 2>"$ROOT/model.err")"
  MODEL_RC=$?
  MODEL_ERR="$(cat "$ROOT/model.err")"
}

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

test_model_classifies_once

echo "---"
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
