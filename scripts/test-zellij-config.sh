#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG="$REPO_ROOT/result/home-files/.config/zellij/config.kdl"

home-manager build >/dev/null

# Extract the KDL bind block whose key matches the given literal (e.g. "Alt ,").
# Brace-balanced so subsequent rg assertions are scoped to that bind alone.
extract_bind() {
  local key="$1"
  awk -v key="$key" '
    function count_chars(s,    c, i, ch) {
      c = 0
      for (i = 1; i <= length(s); i++) {
        ch = substr(s, i, 1)
        if (ch == "{") c++
        if (ch == "}") c--
      }
      return c
    }
    BEGIN { in_block = 0; depth = 0 }
    {
      if (!in_block) {
        needle = "bind \"" key "\""
        if (index($0, needle) > 0) {
          in_block = 1
          depth = count_chars($0)
          block = $0 ORS
          if (depth <= 0) { print block; in_block = 0; block = ""; depth = 0 }
          next
        }
      }
      if (in_block) {
        block = block $0 ORS
        depth += count_chars($0)
        if (depth <= 0) { print block; in_block = 0; block = ""; depth = 0 }
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
