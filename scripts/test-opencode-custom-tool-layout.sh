#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TOOL_DIR="$REPO_ROOT/external/opencode/tools"
TOOLS_LIB_DIR="$REPO_ROOT/external/opencode/tools-lib"
ENTRYPOINT_FILE="$TOOL_DIR/web_search.ts"
CORE_FILE="$TOOLS_LIB_DIR/ol-core.ts"

if [ ! -f "$ENTRYPOINT_FILE" ] || [ ! -f "$CORE_FILE" ]; then
  echo "expected opencode tool files are missing"
  exit 1
fi

SANDBOX_ROOT="$(mktemp -d)"
SANDBOX_HOME="$SANDBOX_ROOT/home"
SANDBOX_XDG="$SANDBOX_ROOT/xdg"
SANDBOX_CONFIG="$SANDBOX_XDG/opencode"
LOG_FILE="$SANDBOX_ROOT/opencode.log"

cleanup() {
  rm -rf "$SANDBOX_ROOT"
}
trap cleanup EXIT

mkdir -p "$SANDBOX_HOME" "$SANDBOX_CONFIG"
cp -a "$HOME/.config/opencode/." "$SANDBOX_CONFIG/"
rm -rf "$SANDBOX_CONFIG/tools" "$SANDBOX_CONFIG/tools-lib"
ln -s "$TOOL_DIR" "$SANDBOX_CONFIG/tools"
ln -s "$TOOLS_LIB_DIR" "$SANDBOX_CONFIG/tools-lib"

XDG_CONFIG_HOME="$SANDBOX_XDG" \
HOME="$SANDBOX_HOME" \
opencode run "Reply with exactly OK" --print-logs --log-level DEBUG \
  >"$LOG_FILE" 2>&1

if rg -q "Cannot find module '@opencode-ai/plugin'" "$LOG_FILE"; then
  echo "custom tool could not resolve @opencode-ai/plugin from symlinked config"
  exit 1
fi

if ! rg -q "tool\.registry status=started web_search" "$LOG_FILE"; then
  echo "expected web_search tool to be registered"
  exit 1
fi

if rg -q "tool\.registry status=started core_" "$LOG_FILE"; then
  echo "unexpected helper exports were registered as tools"
  exit 1
fi

if rg -q "tool\.registry status=started web-search" "$LOG_FILE"; then
  echo "unexpected hyphenated web-search tool was registered"
  exit 1
fi

if ! rg -q '^OK$' "$LOG_FILE"; then
  echo "opencode did not complete a basic prompt successfully"
  exit 1
fi

echo "PASS: opencode loads the custom tool from symlinked config"
