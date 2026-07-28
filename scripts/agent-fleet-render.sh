#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODEL="${AGENT_FLEET_MODEL:-$SCRIPT_DIR/agent-fleet-model.mjs}"

if (( BASH_VERSINFO[0] < 4 )); then
  echo "agent-fleet-render: needs bash >= 4 (got $BASH_VERSION); ensure ~/.nix-profile/bin is on PATH" >&2
  exit 1
fi

icon_for() {
  case "$1" in
    needs-attention) echo "🔴" ;;
    working)         echo "🟡" ;;
    done)            echo "🟢" ;;
    unknown)         echo "⚪" ;;
    *)               echo "⚪" ;;
  esac
}

session_label_for() {
  local title="$1" sid="$2"
  if [ -n "$title" ] && [ "$title" != "null" ]; then
    printf '%s' "$title"
    return
  fi
  local short="${sid:0:8}"
  if [ "${#sid}" -gt 8 ]; then
    printf '%s…' "$short"
  else
    printf '%s' "$sid"
  fi
}

age_for() {
  local ts_ms=$1
  local now_ms
  now_ms=$(($(date +%s) * 1000))
  local delta_s=$(((now_ms - ts_ms) / 1000))
  if [ "$delta_s" -lt 0 ]; then delta_s=0; fi
  printf '%d:%02d' $((delta_s / 60)) $((delta_s % 60))
}

json="$(node "$MODEL")"
declare -a emit_rows

add_row() { emit_rows+=( "$1" ); }

while IFS=$'\t' read -r sess cwd reason; do
  [ -n "$sess" ] || continue
  add_row "$(printf '%s\t0\t0\t%s\twarning\t%s' "$sess" "$cwd" "$reason")"
done < <(jq -r '.rows[] | select(.source == "warning") | [.session, .cwd, "duplicate opencode instance — pick one"] | @tsv' <<<"$json")

while IFS= read -r cwd; do
  [ -n "$cwd" ] || continue
  count="$(jq -r --arg cwd "$cwd" '[.rows[] | select(.cwd == $cwd and .suppressed == false and .source != "warning")] | length' <<<"$json")"
  [ "$count" -gt 0 ] || continue
  first="$(jq -r --arg cwd "$cwd" '[.rows[] | select(.cwd == $cwd and .suppressed == false and .source != "warning")][0] | [.session, .source, (.pid // "-"), .repo] | @tsv' <<<"$json")"
  IFS=$'\t' read -r sess source pid repo <<<"$first"
  [ "$pid" = "-" ] && pid=""
  if [ "$source" = "v2" ] && [ "$count" -ge 2 ]; then
    add_row "$(printf '%s\t1\t1\t%s\tprocess_header\tpid=%s\t%s' "$sess" "$cwd" "$pid" "$repo")"
  fi
  while IFS=$'\t' read -r sid state reason ts title label; do
    [ -n "$state" ] || continue
    [ "$sid" = "-" ] && sid=""
    [ "$reason" = "-" ] && reason=""
    [ "$title" = "-" ] && title=""
    [ "$label" = "-" ] && label=""
    if [ "$source" = "v2" ]; then
      label="$(session_label_for "$title" "$sid")"
    fi
    [ -z "$label" ] && label="$(basename "${cwd%/}")"
    icon="$(icon_for "$state")"
    [ -z "$reason" ] && reason="-"
    if [ "$source" = "v2" ] && [ "$count" -ge 2 ]; then
      add_row "$(printf '%s\t3\t1\t%s\tchild_row\t%s\t%s\t%s\t%s\t%s' "$sess" "$cwd" "$label" "$state" "$reason" "$ts" "$icon")"
    else
      add_row "$(printf '%s\t2\t2\t%s\tcollapse_row\t%s\t%s\t%s\t%s\t%s' "$sess" "$cwd" "$label" "$state" "$reason" "$ts" "$icon")"
    fi
  done < <(jq -r --arg cwd "$cwd" '.rows[] | select(.cwd == $cwd and .suppressed == false and .source != "warning") | [(.sid // "-"), .state, (.reason // "-"), .ts, (.title // "-"), (.label // "-")] | @tsv' <<<"$json")
done < <(jq -r '[.rows[] | select(.suppressed == false and .source != "warning") | .cwd] | unique[]' <<<"$json")

printf '%s\n' "${emit_rows[@]:-}" | sort -t $'\t' -k1,1 -k3,3n -k4,4 -k2,2n \
  | {
    current_session=""
    while IFS=$'\t' read -r sess kind_idx group cwd kind payload; do
      [ -n "$sess" ] || continue
      if [ "$sess" != "$current_session" ]; then
        [ -n "$current_session" ] && echo
        echo "── ${sess^^} ──────────────"
        current_session="$sess"
      fi
      case "$kind" in
        warning)
          printf '  ⚠️  %-32s %s\n' "$cwd" "$payload"
          ;;
        process_header)
          IFS=$'\t' read -r pidlabel repo <<<"$payload"
          printf '  %s · %s\n' "$pidlabel" "$repo"
          ;;
        collapse_row)
          IFS=$'\t' read -r label state reason ts icon <<<"$payload"
          [ "$reason" = "-" ] && reason=""
          state_col="$state"
          [ -n "$reason" ] && [ "$reason" != "null" ] && state_col="$state: $reason"
          printf '  %s %-22s %-32s %s\n' "$icon" "$label" "$state_col" "$(age_for "$ts")"
          ;;
        child_row)
          IFS=$'\t' read -r label state reason ts icon <<<"$payload"
          [ "$reason" = "-" ] && reason=""
          state_col="$state"
          [ -n "$reason" ] && [ "$reason" != "null" ] && state_col="$state: $reason"
          printf '    %s %-22s %-32s %s\n' "$icon" "$label" "$state_col" "$(age_for "$ts")"
          ;;
      esac
    done
  }
