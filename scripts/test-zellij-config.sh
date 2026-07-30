#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG="$REPO_ROOT/result/home-files/.config/zellij/config.kdl"

home-manager build >/dev/null

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

if rg -q "bind \"Alt \\[\"" "$CONFIG"; then
  echo "PASS: Alt-[ swap-layout unchanged"
else
  echo "FAIL: Alt-[ swap-layout bind missing" >&2
  exit 1
fi

if rg -q "bind \"Alt \\]\"" "$CONFIG"; then
  echo "PASS: Alt-] swap-layout unchanged"
else
  echo "FAIL: Alt-] swap-layout bind missing" >&2
  exit 1
fi

if rg -q 'Run "/nix/store/.*/bin/bash" "/Users/paul\.garaud/dotfiles/scripts/agent-fleet-traverse\.sh" "prev"' "$CONFIG"; then
  echo "PASS: Alt-, runs agent-fleet-traverse.sh prev with Nix bash"
else
  echo "FAIL: Alt-, must use Nix bash for agent-fleet-traverse.sh prev" >&2
  rg -n 'agent-fleet-traverse|bind "Alt ,"|Run .*bash' "$CONFIG" >&2 || true
  exit 1
fi

if rg -q 'Run "/nix/store/.*/bin/bash" "/Users/paul\.garaud/dotfiles/scripts/agent-fleet-traverse\.sh" "next"' "$CONFIG"; then
  echo "PASS: Alt-. runs agent-fleet-traverse.sh next with Nix bash"
else
  echo "FAIL: Alt-. must use Nix bash for agent-fleet-traverse.sh next" >&2
  rg -n 'agent-fleet-traverse|bind "Alt ."|Run .*bash' "$CONFIG" >&2 || true
  exit 1
fi

if rg -q 'Run "bash" "-lc" ".*agent-fleet-traverse\.sh"' "$CONFIG"; then
  echo "FAIL: traverse still uses PATH-dependent bash -lc" >&2
  exit 1
fi

echo "PASS: Alt-y avoids PATH-dependent bash -lc"
echo "PASS: traverse avoids PATH-dependent bash -lc"
