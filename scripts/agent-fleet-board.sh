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
. "$SCRIPT_DIR/agent-fleet-act.sh"
# ponytail: one board per state dir assumed; use flock on state dir if concurrent boards matter.

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

declare -A HIDDEN_AT=()
TICK_COUNT=0

hidden_json() {
  local sid
  for sid in "${!HIDDEN_AT[@]}"; do
    jq -n --arg sid "$sid" --argjson age "${HIDDEN_AT[$sid]}" '{($sid): $age}'
  done | jq -s 'add // {}'
}

filter_hidden_rows() {
  local path="$1" hidden sid suppressed age
  ((${#HIDDEN_AT[@]})) || return 0
  while IFS=$'\t' read -r sid suppressed; do
    [ -n "$sid" ] || continue
    if [ "$suppressed" = true ]; then
      unset 'HIDDEN_AT[$sid]'
    elif [ -n "${HIDDEN_AT[$sid]+x}" ]; then
      age=$((TICK_COUNT - HIDDEN_AT[$sid]))
      if (( age >= 5 )); then unset 'HIDDEN_AT[$sid]'; fi
    fi
  done < <(jq -r '.rows[]? | select(.sid != null) | [.sid, (.suppressed == true)] | @tsv' "$path" 2>/dev/null || true)
  hidden="$(hidden_json)"
  jq --argjson hidden "$hidden" '
    if (.rows | type) != "array" then .
    else .rows |= map(select(.sid == null or .suppressed == true or $hidden[.sid] == null))
    end
  ' "$path" > "${path}.filtered"
  mv -f "${path}.filtered" "$path"
}

# Run the model into a tmp file, validate JSON, atomic rename on success.
# Failure: leave the prior cache untouched.
refresh_model() {
  local tmp
  tmp="$(mktemp "$CACHE.tmp.XXXXXX")"
  if [ -x "$MODEL" ]; then
    if ! "$MODEL" > "$tmp" 2>/dev/null; then
      rm -f "$tmp"
      return 1
    fi
  else
    if ! node "$MODEL" > "$tmp" 2>/dev/null; then
      rm -f "$tmp"
      return 1
    fi
  fi
  if jq -e type >/dev/null 2>&1 < "$tmp"; then
    TICK_COUNT=$((TICK_COUNT + 1))
    filter_hidden_rows "$tmp"
    mv -f "$tmp" "$CACHE"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

emit_decision() {
  printf '%s\n' "$1"
  printf '%s\n' "$1" >&2
}

emit_hidden() {
  local ids=() sid
  for sid in "${!HIDDEN_AT[@]}"; do ids+=("$sid"); done
  if ((${#ids[@]})); then
    emit_decision "DECISION:hidden=$(IFS=,; printf '%s' "${ids[*]}")"
  elif [ "${AGENT_FLEET_DECIDE_ONLY:-0}" = 1 ]; then
    emit_decision "DECISION:hidden="
  fi
}

apply_select_nav() {
  local stack="$1" target="$2" now_ms
  now_ms="${AGENT_FLEET_NOW_MS:-$(($(date +%s) * 1000))}"
  jq --arg target "$target" --argjson now_ms "$now_ms" '
    . as $s
    | .back |= ((map(select((. != $target) and (. != $s.current.sid))) +
                (if ($s.current != null) and ($s.current.sid != $target)
                 then [$s.current.sid] else [] end)))
    | .forward |= []
    | .current = {sid: $target, ts: $now_ms}
  ' <<<"$stack"
}

enter() {
  local row key sid cwd sess pane tab p stack
  if ! refresh_model; then
    emit_decision 'DECISION:kind=noop'; repaint "$HL_LINE"; return
  fi
  if [ -n "$HL_SID" ]; then
    row="$(jq -c --arg key "$HL_KEY" --arg sid "$HL_SID" '.rows[]? | select(.key == $key and .sid == $sid)' "$CACHE" | head -n 1 || true)"
  else
    row="$(jq -c --arg cwd "$HL_CWD" '.rows[]? | select(.sid == null and .cwd == $cwd)' "$CACHE" | head -n 1 || true)"
  fi
  if [ -z "$row" ]; then emit_decision 'DECISION:kind=noop'; repaint "$HL_LINE"; return; fi
  if [ "$(jq -r '(.state == "duplicate") or (.source == "warning") or (.duplicate == true) or (.ambiguous == true)' <<<"$row")" = true ]; then
    emit_decision 'DECISION:kind=noop'; repaint "$HL_LINE"; return
  fi
  key="$(jq -r '.key // empty' <<<"$row")"; sid="$(jq -r '.sid // empty' <<<"$row")"
  cwd="$(jq -r '.cwd // empty' <<<"$row")"; sess="$(jq -r '.session // empty' <<<"$row")"
  pane="$(jq -r '.pane // empty' <<<"$row")"; tab="$(jq -r '.tabId // empty' <<<"$row")"
  if [ -z "$sid" ]; then
    emit_decision "DECISION:kind=focus-only cwd=${cwd} session=${sess} pane=${pane} tab_id=${tab}"
    act_land "" "" "$sess" "$pane" "$tab"; repaint "$HL_LINE"; return
  fi
  p="$(jq -c '[.instances[]? | select(.selectedSid != null and (.selectedTs | type) == "number") ] | if length == 0 then null else max_by(.selectedTs) | {sid:.selectedSid,ts:.selectedTs} end' "$CACHE")"
  stack="$(stack_reconcile "$p" "${AGENT_FLEET_NOW_MS:-$(($(date +%s) * 1000))}" <<<"$(stack_read)")"
  stack="$(apply_select_nav "$stack" "$sid")"
  emit_decision "DECISION:kind=select cwd=${cwd} session=${sess} pane=${pane} tab_id=${tab} key=${key} sid=${sid}"
  stack_write "$stack"
  act_land "$key" "$sid" "$sess" "$pane" "$tab"
  repaint "$HL_LINE"
}

dismiss() {
  local row sid key state
  if [ -n "$HL_SID" ]; then row="$(jq -c --arg key "$HL_KEY" --arg sid "$HL_SID" '.rows[]? | select(.key == $key and .sid == $sid)' "$CACHE" | head -n 1 || true)"; else row=""; fi
  row="${row:-null}"
  sid="$(jq -r '.sid // empty' <<<"$row")"; key="$(jq -r '.key // empty' <<<"$row")"; state="$(jq -r '.state // empty' <<<"$row")"
  if [ -n "$sid" ] && [ -n "$key" ] && { [ "$state" = done ] || [ "$state" = needs-attention ]; }; then
    atomic_write_select "$STATE_DIR/${key}.select" "$sid" true
    HIDDEN_AT["$sid"]="$TICK_COUNT"
  else
    emit_decision 'DECISION:kind=noop'
  fi
  return 0
}

linemap_read_row() {
  local row="$1" rest
  LM_LINE="${row%%$'\t'*}"
  rest="${row#*$'\t'}"
  LM_KEY="${rest%%$'\t'*}"
  rest="${rest#*$'\t'}"
  LM_SID="${rest%%$'\t'*}"
  LM_CWD="${rest#*$'\t'}"
}

linemap_field_for_line() {
  local want="$1" field="$2" row
  while IFS= read -r row; do
    linemap_read_row "$row"
    if [ "$LM_LINE" = "$want" ]; then
      case "$field" in
        key) printf '%s' "$LM_KEY" ;;
        sid) printf '%s' "$LM_SID" ;;
        cwd) printf '%s' "$LM_CWD" ;;
      esac
      return 0
    fi
  done < "$LINEMAP"
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
    found=""
    while IFS= read -r row; do
      linemap_read_row "$row"
      if [ "$LM_KEY" = "$HL_KEY" ] && [ "$LM_SID" = "$HL_SID" ]; then
        found="$LM_LINE"
        break
      fi
    done < "$LINEMAP"
  elif [ -n "$HL_CWD" ]; then
    # sid-less row: match cwd.
    found=""
    while IFS= read -r row; do
      linemap_read_row "$row"
      if [ "$LM_CWD" = "$HL_CWD" ]; then
        found="$LM_LINE"
        break
      fi
    done < "$LINEMAP"
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
  HL_KEY="$(linemap_field_for_line "$HL_LINE" key)"
  HL_SID="$(linemap_field_for_line "$HL_LINE" sid)"
  HL_CWD="$(linemap_field_for_line "$HL_LINE" cwd)"
  return 0
}

# Repaint: invoke renderer with the highlight line, then refresh identity.
repaint() {
  local hl_line="${1-}"
  printf '\e[H'
  AGENT_FLEET_STATE_DIR="$STATE_DIR" \
    AGENT_FLEET_HIGHLIGHT_LINE="$hl_line" \
    "$RENDER" 2>>"$STATE_DIR/.board-render.log" || true   # transient render errors must not kill the board
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
  HL_KEY="$(linemap_field_for_line "$HL_LINE" key)"
  HL_SID="$(linemap_field_for_line "$HL_LINE" sid)"
  HL_CWD="$(linemap_field_for_line "$HL_LINE" cwd)"
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
    ''|$'\r'|$'\n') enter ;;
    d) dismiss ;;
    q) emit_hidden; exit 0 ;;
    *) : ;;   # SPACE / TAB / backslash / etc. — intentionally ignored here
              # Unknown keys stay inert.
  esac
  emit_hidden
done
