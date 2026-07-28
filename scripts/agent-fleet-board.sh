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
#
# ponytail: redraw in-place (\e[H home, \e[J erase-below) instead of clear, to kill the
# blank-gap flicker. render.sh appends \e[K per line so a shrinking field leaves no
# stale right-edge chars. WINCH does one full clear so a resize can't smear old content.
tput smcup 2>/dev/null || true   # alt-screen: dashboard, no scrollback needed
tput civis 2>/dev/null || true   # hide cursor (blinks at render tail every frame otherwise)
trap 'tput cnorm 2>/dev/null || true; tput rmcup 2>/dev/null || true' EXIT
trap 'printf "\e[2J"' WINCH
while true; do
  printf '\e[H'
  "$RENDER" || true   # a transient render error (e.g. zellij daemon blip) must not kill the board
  printf '\e[J'       # erase from render tail down: clears rows a shorter frame left behind
  sleep "$INTERVAL"
done
