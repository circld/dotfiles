#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if (( BASH_VERSINFO[0] < 4 )); then
  echo "agent-fleet-board: needs bash >= 4 (got $BASH_VERSION); ensure ~/.nix-profile/bin is on PATH" >&2
  exit 1
fi

STATE_DIR="${AGENT_FLEET_STATE_DIR:-$HOME/.local/state/agent-fleet}"
MODEL="${AGENT_FLEET_MODEL:-$SCRIPT_DIR/agent-fleet-model.mjs}"
RENDER="${AGENT_FLEET_RENDER:-$SCRIPT_DIR/agent-fleet-render.sh}"
INTERVAL="${AGENT_FLEET_REFRESH_SECS:-2}"
CACHE="$STATE_DIR/.board-cache.json"
LINEMAP="$STATE_DIR/.board-linemap.tsv"

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
#
# ponytail: `stty -icanon -echo` on a non-TTY returns failure; guard all tty/tput
# calls with `2>/dev/null || true` so piped stdin (test harnesses, scripted
# invocations) doesn't crash the board.
saved_tty="$(stty -g 2>/dev/null || true)"
stty -icanon -echo 2>/dev/null || true
tput smcup 2>/dev/null || true   # alt-screen: dashboard, no scrollback needed
tput civis 2>/dev/null || true   # hide cursor (blinks at render tail every frame otherwise)
trap 'if [ -n "$saved_tty" ]; then stty "$saved_tty" 2>/dev/null || true; fi; tput cnorm 2>/dev/null || true; tput rmcup 2>/dev/null || true; rm -f "$CACHE" "$LINEMAP"' EXIT
trap 'printf "\e[2J"' WINCH

# --- helpers ---

# Run the model into a tmp file, validate JSON, atomic rename on success.
# Failure: leave the prior cache untouched.
refresh_model() {
  local tmp rc
  tmp="$(mktemp "$CACHE.tmp.XXXXXX")"
  if "$MODEL" > "$tmp" 2>/dev/null; then
    if jq -e . >/dev/null 2>&1 < "$tmp"; then
      mv -f "$tmp" "$CACHE"
      return 0
    fi
  fi
  rm -f "$tmp"
  return 1
}

# Re-find the highlighted identity in the current linemap; fall back to the
# last-seen line index if the identity disappeared. Returns empty when there
# are no mapped rows at all.
#
# HL_KEY/SDL/CWD are the LAST OBSERVED identity atoms. We re-derive them from
# any line we land on (success or fallback), so the next repaint inherits
# the IDENTITY, not a stale line number — survivors ride row reorders.
find_hl_line() {
  local want_idx="${1-}"  # hint: last-seen line (clamped to last row on miss)
  if [ ! -s "$LINEMAP" ]; then
    HL_KEY=""; HL_SID=""; HL_CWD=""; HL_LINE=""
    return 0
  fi
  local found
  if [ -n "$HL_SID" ]; then
    # sid row: match (key,sid).
    found="$(awk -F $'\t' -v k="$HL_KEY" -v s="$HL_SID" \
      '$2 == k && $3 == s {print $1; exit}' "$LINEMAP")"
  elif [ -n "$HL_CWD" ]; then
    # sid-less row: match cwd.
    found="$(awk -F $'\t' -v c="$HL_CWD" \
      '$4 == c {print $1; exit}' "$LINEMAP")"
  else
    found=""
  fi
  if [ -n "$found" ]; then
    HL_LINE="$found"
    return 0
  fi
  # Identity vanished. Fall back: same prior index clamped to last mapped row.
  local last_idx
  last_idx="$(awk -F $'\t' 'END{if(NF>0) print $1; else print ""}' "$LINEMAP")"
  if [ -z "$last_idx" ]; then
    HL_KEY=""; HL_SID=""; HL_CWD=""; HL_LINE=""
    return 0
  fi
  local target="$want_idx"
  if [ -z "$target" ] || ! [[ "$target" =~ ^[0-9]+$ ]] || (( target > last_idx )); then
    target="$last_idx"
  fi
  HL_LINE="$target"
  # Re-derive identity atoms from the line we landed on (fallback may have
  # been clamped downward).
  HL_KEY="$(awk -F $'\t' -v ln="$HL_LINE" '$1 == ln {print $2; exit}' "$LINEMAP")"
  HL_SID="$(awk -F $'\t' -v ln="$HL_LINE" '$1 == ln {print $3; exit}' "$LINEMAP")"
  HL_CWD="$(awk -F $'\t' -v ln="$HL_LINE" '$1 == ln {print $4; exit}' "$LINEMAP")"
  return 0
}

# Repaint: invoke renderer with the highlight line, then refresh identity.
repaint() {
  local hl_line="${1-}"
  AGENT_FLEET_STATE_DIR="$STATE_DIR" \
    AGENT_FLEET_HIGHLIGHT_LINE="$hl_line" \
    "$RENDER" >/dev/null 2>&1 || true   # transient render errors must not kill the board
  printf '\e[J'   # erase from render tail down: clears rows a shorter frame left behind
  find_hl_line "$HL_LINE"
}

# Refresh + repaint one tick. Model failure is silent (cache preserved).
tick() {
  if refresh_model; then
    repaint "$HL_LINE"
  fi
}

# Nanosecond wall-clock since epoch. macOS date(1) supports +%s%N; on a
# pathological fallback (whole-second-only platform) we still get
# deadline ticks at second-granularity, just slightly less frequent.
ns_now() {
  local raw
  raw="$(date +%s%N 2>/dev/null)"
  if [[ "$raw" == *N* ]] || [ -z "$raw" ]; then
    # date doesn't support %N — fall back to whole seconds, padded to ns.
    raw="$(( $(date +%s) * 1000000000 ))"
  fi
  printf '%s' "$raw"
}

# Move highlight up/down by 1 within the mapped row count.
navigate() {
  local delta="$1"
  if [ ! -s "$LINEMAP" ]; then
    return 0
  fi
  local last
  last="$(awk -F $'\t' 'END{if(NF>0) print $1; else print ""}' "$LINEMAP")"
  [ -n "$last" ] || return 0
  local current="$HL_LINE"
  if [ -z "$current" ]; then
    if (( delta > 0 )); then
      HL_LINE=1
    else
      HL_LINE="$last"
    fi
  else
    HL_LINE=$(( current + delta ))
    if (( HL_LINE < 1 )); then HL_LINE=1; fi
    if (( HL_LINE > last )); then HL_LINE="$last"; fi
  fi
  # Re-derive identity atoms for the new line (so reorder preserves us).
  HL_KEY="$(awk -F $'\t' -v ln="$HL_LINE" '$1 == ln {print $2; exit}' "$LINEMAP")"
  HL_SID="$(awk -F $'\t' -v ln="$HL_LINE" '$1 == ln {print $3; exit}' "$LINEMAP")"
  HL_CWD="$(awk -F $'\t' -v ln="$HL_LINE" '$1 == ln {print $4; exit}' "$LINEMAP")"
  repaint "$HL_LINE"
}

# --- highlight state (globals) ---
HL_KEY=""; HL_SID=""; HL_CWD=""; HL_LINE="1"

# Initial tick — anchor highlight on the first mapped row, if any. We
# pre-seed HL_LINE=1 so the first find_hl_line(1) targets row 1 (the
# conventional top-of-list focus) when no prior identity exists.
tick

# Last successful tick wall-clock (nanoseconds since epoch). Pre-seeded
# NOW so the loop's first deadline check doesn't fire spuriously.
last_tick_ns="$(ns_now)"

while true; do
  # Pre-read deadline check — refresh+repaint on schedule even with no keys.
  now_ns="$(ns_now)"
  if (( now_ns - last_tick_ns >= INTERVAL * 1000000000 )); then
    tick
    last_tick_ns="$(ns_now)"
  fi

  # Read a single byte with the INTERVAL timeout. This is also where a
  # trapped WINCH returns >128: we treat that like a tick deadline (next
  # iteration's repaint picks up any stale frame).
  key=""
  if IFS= read -rsn1 -t "$INTERVAL" key; then
    rc=0
  else
    rc=$?
  fi

  # rc==1 is `read`'s canonical EOF exit; we end the loop cleanly.
  if (( rc == 1 )); then exit 0; fi

  # rc>128 includes INTERVAL timeout AND signal-interrupted reads (e.g.
  # trapped WINCH mid-`read`). Either way: refresh+repaint, reset deadline.
  if (( rc > 128 )); then
    tick
    last_tick_ns="$(ns_now)"
    continue
  fi

  # rc==0 — a key arrived. Pre-process deadline check so sustained input
  # cannot starve the model refresh.
  now_ns="$(ns_now)"
  if (( now_ns - last_tick_ns >= INTERVAL * 1000000000 )); then
    tick
    last_tick_ns="$(ns_now)"
  fi

  case "$key" in
    $'\e')
      # Escape sequence: read the next 2 bytes with a small timeout to
      # disambiguate ESC-alone (timeout) from arrow keys (\e[A, \e[B).
      # `|| true` because timeout is a normal "bare ESC" outcome, not a
      # failure of our keyboard intent.
      IFS= read -rsn2 -t 0.05 seq || true
      case "$seq" in
        '[A') navigate -1 ;;
        '[B') navigate  1 ;;
        *) : ;;  # bare ESC / unknown — ignore
      esac
      ;;
    j) navigate  1 ;;
    k) navigate -1 ;;
    *) : ;;   # SPACE / TAB / backslash / etc. — intentionally ignored here
              # (Task 9 will wire q / Enter / d).
  esac
done
