#!/usr/bin/env bash
# agent-fleet-render.sh — paint-only.
#
# Reads `$AGENT_FLEET_STATE_DIR/.board-cache.json` (written by the board from
# the model output) and paints a frame to stdout. NEVER invokes the model —
# that lives one rung up in the board (Task 8's loop). Writes a line map to
# `.board-linemap.tsv` so the board can translate painted screen lines into
# row identities for keyboard navigation (Task 8/9).
#
# Cache-absent / invalid ⇒ atomic empty line map, no frame, exit 0
# (cache-absent standalone mode — nothing has written the cache yet).
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 )); then
  echo "agent-fleet-render: needs bash >= 4 (got $BASH_VERSION); ensure ~/.nix-profile/bin is on PATH" >&2
  exit 1
fi

STATE_DIR="${AGENT_FLEET_STATE_DIR:-$HOME/.local/state/agent-fleet}"
mkdir -p "$STATE_DIR"
CACHE="$STATE_DIR/.board-cache.json"
LINEMAP="$STATE_DIR/.board-linemap.tsv"
HIGHLIGHT_LINE="${AGENT_FLEET_HIGHLIGHT_LINE:-}"

icon_for() {
  case "$1" in
    needs-attention) echo "🔴" ;;
    working)         echo "🟡" ;;
    done)            echo "🟢" ;;
    unknown)         echo "⚪" ;;
    idle)            echo "⚪" ;;
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
  now_ms="${AGENT_FLEET_NOW_MS:-$(($(date +%s) * 1000))}"
  local delta_s=$(((now_ms - ts_ms) / 1000))
  if [ "$delta_s" -lt 0 ]; then delta_s=0; fi
  printf '%d:%02d' $((delta_s / 60)) $((delta_s % 60))
}

# -- read cache (paint-only: never invokes model) --
json=""
if [ -f "$CACHE" ]; then
  json="$(cat "$CACHE" 2>/dev/null || true)"
fi

# -- empty / invalid cache → atomic empty linemap, no frame, exit 0 --
# (cache-absent standalone mode: between Tasks 7 and 8 the board hasn't been
# taught to write the cache yet, so the live board paints empty frames by
# design agreement rather than emitting a half-truthful one.)
if [ -z "$json" ] || ! jq -e . >/dev/null 2>&1 <<<"$json"; then
  tmpmap="$(mktemp "$LINEMAP.tmp.XXXXXX")"
  : > "$tmpmap"
  mv -f "$tmpmap" "$LINEMAP"
  exit 0
fi

# -- build emit_rows from cache JSON --
# Each emit row is `sess\tkind_idx\tgroup\tcwd\tkind\tkey\tsid\tsource\t<payload>`.
# Sort keys (cols 1-4) preserve the pre-cache pipeline ordering. The added
# cols 6-8 thread row identity (key/sid/source) so the paint loop can both
# decide navigability AND emit the linemap.
#
# Empty fields would let bash's `read -ra` drop them (it ignores trailing
# empty fields after non-empty neighbors), so we sentinel nulls as `-` and
# convert them back to empty during linemap emission. This mirrors how the
# upstream model emits nulls (`.foo // "-"`).
declare -a emit_rows
add_row() { emit_rows+=( "$1" ); }

while IFS=$'\t' read -r sess cwd; do
  [ -n "$sess" ] || continue
  # warning row: key=null, sid=null, source="warning" (non-null literal).
  add_row "$(printf '%s\t0\t0\t%s\twarning\t-\t-\twarning\tduplicate opencode instance — pick one' "$sess" "$cwd")"
done < <(jq -r '.rows[] | select(.source == "warning") | [.session, .cwd] | @tsv' <<<"$json")

while IFS= read -r cwd; do
  [ -n "$cwd" ] || continue
  count="$(jq -r --arg cwd "$cwd" '[.rows[] | select(.cwd == $cwd and .suppressed == false and .source != "warning")] | length' <<<"$json")"
  [ "$count" -gt 0 ] || continue
  first="$(jq -r --arg cwd "$cwd" '[.rows[] | select(.cwd == $cwd and .suppressed == false and .source != "warning")][0] | [.session, .source, (.pid // "-"), .repo, .key] | @tsv' <<<"$json")"
  IFS=$'\t' read -r first_session first_source first_pid first_repo first_key <<<"$first"
  [ "$first_pid" = "-" ] && first_pid=""
  if [ "$first_source" = "v2" ] && [ "$count" -ge 2 ]; then
    # process_header: 5 substitutions, 10 fields, no empties.
    # key=first_key (non-null because v2 files always have a key); sid=null;
    # source=null (process_header is internal, not row-sourced); pid and
    # repo are non-null. Sentinels: sid="-", source="-".
    [ -z "$first_key" ] && first_key="-"
    add_row "$(printf '%s\t1\t1\t%s\tprocess_header\t%s\t-\t-\tpid=%s\t%s' "$first_session" "$cwd" "$first_key" "$first_pid" "$first_repo")"
  fi
  while IFS=$'\t' read -r sid state reason ts title label row_key; do
    [ -n "$state" ] || continue
    [ "$sid" = "-" ] && sid=""
    [ "$reason" = "-" ] && reason=""
    [ "$title" = "-" ] && title=""
    [ "$label" = "-" ] && label=""
    # Sentinels so read -ra never sees an empty cell:
    [ -z "$sid" ]    && sid="-"
    [ -z "$row_key" ] && row_key="-"
    source="$first_source"
    label_for_render="$label"
    if [ "$source" = "v2" ]; then
      label_for_render="$(session_label_for "$title" "$sid")"
    fi
    [ -z "$label_for_render" ] && label_for_render="$(basename "${cwd%/}")"
    icon="$(icon_for "$state")"
    [ -z "$reason" ] && reason="-"
    if [ "$source" = "v2" ] && [ "$count" -ge 2 ]; then
      add_row "$(printf '%s\t3\t1\t%s\tchild_row\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' "$first_session" "$cwd" "$row_key" "$sid" "$source" "$label_for_render" "$state" "$reason" "$ts" "$icon")"
    else
      add_row "$(printf '%s\t2\t2\t%s\tcollapse_row\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' "$first_session" "$cwd" "$row_key" "$sid" "$source" "$label_for_render" "$state" "$reason" "$ts" "$icon")"
    fi
  done < <(jq -r --arg cwd "$cwd" '.rows[] | select(.cwd == $cwd and .suppressed == false and .source != "warning") | [(.sid // "-"), .state, (.reason // "-"), .ts, (.title // "-"), (.label // "-"), (.key // "-")] | @tsv' <<<"$json")
done < <(jq -r '[.rows[] | select(.suppressed == false and .source != "warning") | .cwd] | unique[]' <<<"$json")

# -- atomic linemap tmp --
tmpmap="$(mktemp "$LINEMAP.tmp.XXXXXX")"
: > "$tmpmap"

if [ "${#emit_rows[@]}" -eq 0 ]; then
  mv -f "$tmpmap" "$LINEMAP"
  exit 0
fi

# -- paint --
# line_no ticks ONLY on navigable rows (session headers, blank separators,
# and process_header rows do not). HIGHLIGHT_LINE matches against this
# counter — unmapped highlight values skip cleanly because line_no never
# reaches them. We use read -ra (array) because bash's positional read drops
# trailing empty fields, which would collapse our key/sid/source identity
# columns at variable-field boundaries.
line_no=0
printf '%s\n' "${emit_rows[@]}" \
  | sort -t $'\t' -k1,1 -k3,3n -k4,4 -k2,2n \
  | {
    current_session=""
    while IFS=$'\t' read -ra fields; do
      sess="${fields[0]}"
      [ -n "$sess" ] || continue
      kind="${fields[4]:-}"
      cwd="${fields[3]}"
      key="${fields[5]:-}"
      sid="${fields[6]:-}"
      source="${fields[7]:-}"
      if [ "$sess" != "$current_session" ]; then
        [ -n "$current_session" ] && printf '\e[K\n'
        printf '── %s ──────────────\e[K\n' "${sess^^}"
        current_session="$sess"
      fi
case "$kind" in
        warning)
          line_no=$((line_no + 1))
          printf '  ⚠️  %-32.32s duplicate opencode instance — pick one\e[K\n' "$cwd"
          # Translate sentinel "-" back to empty per spec ("nulls use empty fields").
          printf '%s\t%s\t%s\t%s\n' "$line_no" \
            "$([ "$key" = "-" ] && echo "" || echo "$key")" \
            "$([ "$sid" = "-" ] && echo "" || echo "$sid")" \
            "$cwd" >> "$tmpmap"
          ;;
        process_header)
          # Not navigable — skip both print mapping and line counter.
          printf '  pid=%s · %s\e[K\n' "${fields[8]:-}" "${fields[9]:-}"
          ;;
        collapse_row)
          line_no=$((line_no + 1))
          lab="${fields[8]:-}"
          st="${fields[9]:-}"
          reason="${fields[10]:-}"
          ts="${fields[11]:-}"
          icon="${fields[12]:-}"
          if [ "$reason" = "-" ]; then reason=""; fi
          state_col="$st"
          if [ -n "$reason" ] && [ "$reason" != "null" ]; then state_col="$st: $reason"; fi
          painted="$(printf '  %s %-34.34s %-27.27s %s\e[K' "$icon" "$lab" "$state_col" "$(age_for "$ts")")"
          if [ -n "$HIGHLIGHT_LINE" ] && [ "$line_no" = "$HIGHLIGHT_LINE" ]; then
            printf '\e[7m%s\e[27m\e[K\n' "$painted"
          else
            printf '%s\e[K\n' "$painted"
          fi
          printf '%s\t%s\t%s\t%s\n' "$line_no" \
            "$([ "$key" = "-" ] && echo "" || echo "$key")" \
            "$([ "$sid" = "-" ] && echo "" || echo "$sid")" \
            "$cwd" >> "$tmpmap"
          ;;
        child_row)
          line_no=$((line_no + 1))
          lab="${fields[8]:-}"
          st="${fields[9]:-}"
          reason="${fields[10]:-}"
          ts="${fields[11]:-}"
          icon="${fields[12]:-}"
          if [ "$reason" = "-" ]; then reason=""; fi
          state_col="$st"
          if [ -n "$reason" ] && [ "$reason" != "null" ]; then state_col="$st: $reason"; fi
          painted="$(printf '    %s %-32.32s %-27.27s %s\e[K' "$icon" "$lab" "$state_col" "$(age_for "$ts")")"
          if [ -n "$HIGHLIGHT_LINE" ] && [ "$line_no" = "$HIGHLIGHT_LINE" ]; then
            printf '\e[7m%s\e[27m\e[K\n' "$painted"
          else
            printf '%s\e[K\n' "$painted"
          fi
          printf '%s\t%s\t%s\t%s\n' "$line_no" \
            "$([ "$key" = "-" ] && echo "" || echo "$key")" \
            "$([ "$sid" = "-" ] && echo "" || echo "$sid")" \
            "$cwd" >> "$tmpmap"
          ;;
      esac
    done
  }

mv -f "$tmpmap" "$LINEMAP"
