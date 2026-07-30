#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG="$REPO_ROOT/result/home-files/.config/zellij/config.kdl"

home-manager build >/dev/null

# Extract the KDL bind block whose key matches the given literal (e.g. "Alt ,").
# Indentation-anchored: trust the home-manager toKDL renderer to emit each
# bind's closing `}` at the SAME leading whitespace as the `bind "X" {` line.
# Robust against braces appearing inside string values (which would defeat
# brace counting).
extract_bind() {
  local key="$1"
  awk -v key="$key" '
    BEGIN { in_block = 0; block_ws = "" }
    {
      if (!in_block) {
        needle = "bind \"" key "\""
        if (index($0, needle) > 0) {
          match($0, /^[[:space:]]*/)
          block_ws = substr($0, 1, RLENGTH)
          in_block = 1
          print
          rest = substr($0, RLENGTH + 1)
          sub(/[[:space:]]+$/, "", rest)
          if (rest == "}") { in_block = 0; block_ws = ""; exit }
          next
        }
      } else {
        print
        line = $0
        sub(/[[:space:]]+$/, "", line)
        if (line == block_ws "}") { in_block = 0; block_ws = ""; exit }
      }
    }
  ' "$CONFIG"
}

if rg -q 'Run "/nix/store/.*/bin/bash" "/Users/paul\.garaud/dotfiles/scripts/agent-fleet-jump\.sh"' "$CONFIG"; then
  echo "PASS: Alt-y runs agent-fleet-jump with Nix bash"
else
  echo "FAIL: Alt-y must not use macOS /bin/bash for agent-fleet-jump" >&2
  rg -n 'agent-fleet-jump|bind "Alt y"|Run .*bash' "$CONFIG" >&2 || true
  exit 1
fi

if rg -q 'Run "bash" "-lc" ".*agent-fleet-jump\.sh"' "$CONFIG"; then
  echo "FAIL: Alt-y still uses PATH-dependent bash -lc" >&2
  exit 1
fi

block=$(extract_bind "Alt [")
if rg -q 'PreviousSwapLayout' <<<"$block"; then
  echo "PASS: Alt-[ -> PreviousSwapLayout"
else
  echo "FAIL: Alt-[ no longer maps to PreviousSwapLayout" >&2
  echo "$block" >&2
  exit 1
fi

block=$(extract_bind "Alt ]")
if rg -q 'NextSwapLayout' <<<"$block"; then
  echo "PASS: Alt-] -> NextSwapLayout"
else
  echo "FAIL: Alt-] no longer maps to NextSwapLayout" >&2
  echo "$block" >&2
  exit 1
fi

block=$(extract_bind "Alt ,")
if rg -q 'Run "[^"]*" "[^"]*agent-fleet-traverse\.sh" "prev"' <<<"$block"; then
  echo "PASS: Alt-, -> agent-fleet-traverse.sh prev"
else
  echo "FAIL: Alt-, block does not run agent-fleet-traverse.sh prev" >&2
  echo "$block" >&2
  exit 1
fi

block=$(extract_bind "Alt .")
if rg -q 'Run "[^"]*" "[^"]*agent-fleet-traverse\.sh" "next"' <<<"$block"; then
  echo "PASS: Alt-. -> agent-fleet-traverse.sh next"
else
  echo "FAIL: Alt-. block does not run agent-fleet-traverse.sh next" >&2
  echo "$block" >&2
  exit 1
fi

if rg -q 'Run "bash" "-lc" ".*agent-fleet-traverse\.sh"' "$CONFIG"; then
  echo "FAIL: traverse still uses PATH-dependent bash -lc" >&2
  exit 1
fi

echo "PASS: Alt-y avoids PATH-dependent bash -lc"
echo "PASS: traverse avoids PATH-dependent bash -lc"
