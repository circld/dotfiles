#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="${AGENT_FLEET_STATE_DIR:-$HOME/.local/state/agent-fleet}"
RENDER="$SCRIPT_DIR/agent-fleet-render.sh"
INTERVAL="${AGENT_FLEET_REFRESH_SECS:-2}"

mkdir -p "$STATE_DIR"

# ponytail: fixed-interval poll, not a file-watcher. The board's live-pane inventory
# and age columns change WITHOUT any state-file write (pane exit, wall-clock), so an
# entr/fswatch trigger would freeze them (ghosts linger, sensor-less agents never
# appear, age stops). Poll upgrade path: event-driven refresh only if a zellij pane
# lifecycle hook and a per-second age source both exist — neither does today, so poll.
while true; do
  clear
  "$RENDER" || true   # a transient render error (e.g. zellij daemon blip) must not kill the board
  sleep "$INTERVAL"
done
