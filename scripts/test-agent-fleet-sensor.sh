#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_FILE="$REPO_ROOT/external/opencode/plugins/agent-fleet-sensor.js"

if [ ! -f "$PLUGIN_FILE" ]; then
  echo "expected sensor plugin file is missing"
  exit 1
fi

# run the pure-logic unit check first — this is the one that guards feedback #4
node "$REPO_ROOT/external/opencode/plugins/agent-fleet-sensor.test.mjs"

SANDBOX_ROOT="$(mktemp -d)"
SANDBOX_HOME="$SANDBOX_ROOT/home"
SANDBOX_XDG="$SANDBOX_ROOT/xdg"
SANDBOX_CONFIG="$SANDBOX_XDG/opencode"
SANDBOX_REPO="$SANDBOX_ROOT/repo/test-repo"
LOG_FILE="$SANDBOX_ROOT/opencode.log"

cleanup() { rm -rf "$SANDBOX_ROOT"; }
trap cleanup EXIT

mkdir -p "$SANDBOX_HOME" "$SANDBOX_CONFIG" "$SANDBOX_REPO"
cp -a "$HOME/.config/opencode/." "$SANDBOX_CONFIG/"
rm -rf "$SANDBOX_CONFIG/plugins"
mkdir -p "$SANDBOX_CONFIG/plugins"
ln -s "$PLUGIN_FILE" "$SANDBOX_CONFIG/plugins/agent-fleet-sensor.js"

cd "$SANDBOX_REPO"
# state-file key is a sha256 prefix of the absolute cwd, so derive it the same way the plugin does.
# On macOS /var/folders/... is a symlink to /private/var/folders/...; opencode's `directory` reports
# the realpath (verified: `creating instance directory=/private/var/folders/...`). Also strip the
# trailing newline that `pwd -P` prints (verified: piping `pwd -P | shasum` produces a different
# hash than `printf '%s' "/path" | shasum`, because the JS plugin's sha256 only sees the path
# string with no trailing newline). SHA the realpath explicitly to keep both sides in sync.
SANDBOX_REPO_REAL="$(cd "$SANDBOX_REPO" && pwd -P)"
STATE_KEY="$(printf '%s' "$SANDBOX_REPO_REAL" | shasum -a 256 | cut -c1-16)"
STATE_FILE="$SANDBOX_HOME/.local/state/agent-fleet/${STATE_KEY}.json"

# NO `|| true` here. The established sibling test (scripts/test-opencode-custom-tool-layout.sh)
# lets `opencode run` fail the script under `set -e`, and so must this one: masking a non-zero
# exit would let the test pass after a partial hook write while opencode itself crashed. If
# opencode exits non-zero, fail loudly with the log. `if !` captures the failure without
# `set -e` aborting before we can print the log.
if ! XDG_CONFIG_HOME="$SANDBOX_XDG" HOME="$SANDBOX_HOME" \
  opencode run "Reply with exactly OK" --print-logs --log-level DEBUG >"$LOG_FILE" 2>&1; then
  echo "FAIL: opencode run exited non-zero"
  cat "$LOG_FILE"
  exit 1
fi

if [ ! -f "$STATE_FILE" ]; then
  echo "FAIL: sensor plugin did not write a state file at $STATE_FILE"
  echo "--- opencode log ---"
  cat "$LOG_FILE"
  exit 1
fi

if ! jq -e '.repo == "test-repo"' "$STATE_FILE" >/dev/null; then
  echo "FAIL: state file has wrong repo field"
  cat "$STATE_FILE"
  exit 1
fi
if ! jq -e '.cwd == "'"$SANDBOX_REPO_REAL"'"' "$STATE_FILE" >/dev/null; then
  echo "FAIL: state file cwd is not the absolute agent cwd"
  cat "$STATE_FILE"
  exit 1
fi

echo "PASS: sensor plugin wrote state file: $(cat "$STATE_FILE")"
