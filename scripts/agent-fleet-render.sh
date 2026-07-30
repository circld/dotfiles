#!/usr/bin/env bash
# agent-fleet-render.sh — paint-only.
#
# Reads `$AGENT_FLEET_STATE_DIR/.board-cache.json` (written by the board from
# the model output) and paints a frame to stdout. NEVER invokes the model —
# that lives one rung up in the board (Task 8's loop). Writes a line map to
# `.board-linemap.tsv` so the board can translate painted screen lines into
# row identities for keyboard navigation (Task 8/9).
#
# Failure modes:
#   - cache missing or invalid JSON: empty linemap, no frame, exit 0.
#   - mid-frame failure (jq error, paint bug, …): the EMPTY linemap was
#     installed BEFORE painting, so the board sees no navigable rows
#     instead of stale rows from the previous frame that don't match the
#     new (partial) paint.
#
# Identity encoding (`key`/`sid` columns carried through the sort pipeline):
#   - jq `@json` produces a literal `null` for absent rows, and a quoted
#     `"<value>"` for present ones. The encoding is unambiguous by
#     construction — `"-"` and `null` are byte-distinct, so a row whose
#     identity happens to BE `-` round-trips as identity (no `-` collision
#     that any value would alias).
#
# Driver suppression: rows whose `key`, `sid`, or `cwd` contains ASCII
# control bytes (TAB / LF / CR) are skipped with a stderr warning. Those
# bytes would shred `while read -r` grouping and `@tsv` round-tripping,
# aliasing distinct identities and producing phantom rows after the
# board's reverse-mapping read-back.
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 )); then
  echo "agent-fleet-render: needs bash >= 4 (got $BASH_VERSION); ensure ~/.nix-profile/bin is on PATH" >&2
  exit 1
fi

STATE_DIR="${AGENT_FLEET_STATE_DIR:-$HOME/.local/state/agent-fleet}"
mkdir -p "$STATE_DIR"
CACHE="$STATE_DIR/.board-cache.json"
LINEMAP="$STATE_DIR/.board-linemap.tsv"

# Cleanup the painter's tmp on any abnormal exit so we don't leave stale
# files behind if an error stops the linemap write mid-frame. The
# pre-installed empty linemap is the recovery path the partial-frame
# failure test asserts.
_paint_tmp=""
trap '[ -n "$_paint_tmp" ] && [ -e "$_paint_tmp" ] && rm -f "$_paint_tmp" || true' EXIT

# Validate HIGHLIGHT_LINE: only positive non-zero integers (no `0`, `01`,
# `-5`, `abc`). Anything else is treated as unset.
_HIGHLIGHT_RAW="${AGENT_FLEET_HIGHLIGHT_LINE:-}"
if [ -n "$_HIGHLIGHT_RAW" ] && ! [[ "$_HIGHLIGHT_RAW" =~ ^[1-9][0-9]*$ ]]; then
  _HIGHLIGHT_RAW=""
fi
HIGHLIGHT_LINE="$_HIGHLIGHT_RAW"

icon_for() {
  case "$1" in
    needs-attention) echo "🔴" ;;
    working)         echo "🟡" ;;
    done)            echo "🟢" ;;
    unknown|done-synthetic) echo "⚪" ;;
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
  if [ -z "$sid" ]]; then return; fi
  local short="${sid:0:8}"
  if [ "${#sid}" -gt 8 ]; then
    printf '%s…' "$short"
  else
    printf '%s' "$sid"
  fi
}

# Decode a JSON-encoded pipe cell: literal `null` -> "", `"x"` -> `x`.
# Other values (impossible by construction since this is only called for
# jq-encoded JSON output) pass through.
decode_json_cell() {
  local v="$1"
  case "$v" in
    null) printf '' ;;
    \"*\")
      local r="${v#\"}"
      r="${r%\"}"
      printf '%s' "$r"
      ;;
    *) printf '%s' "$v" ;;
  esac
}

age_for() {
  local ts_ms=$1
  # Model rows always carry a numeric `ts`; defend against cache corruption
  # by refusing to fractionally paint against a non-numeric timestamp. Quiet
  # in well-formed input; loud + abort in cache-corruption so the pre-installed
  # empty linemap is what the board reads instead of a stale one.
  case "$ts_ms" in
    ''|*[!0-9]*) echo "agent-fleet-render: non-numeric ts: $ts_ms" >&2; return 1 ;;
  esac
  local now_ms="${AGENT_FLEET_NOW_MS:-$(($(date +%s) * 1000))}"
  local delta_s=$(((now_ms - ts_ms) / 1000))
  if [ "$delta_s" -lt 0 ]; then delta_s=0; fi
  printf '%d:%02d' $((delta_s / 60)) $((delta_s % 60))
}

# -- read cache --
json=""
if [ -f "$CACHE" ]; then
  json="$(cat "$CACHE" 2>/dev/null || true)"
fi

# -- pre-install ATOMIC empty linemap BEFORE any work that could fail. --
# If anything below dies (jq error, paint abort, …), the empty map is what
# the board sees for this tick. Keyboard nav then has no identity matches
# against the new (partial) frame — clean failure mode.
_empty_tmp="$(mktemp "$LINEMAP.tmp.XXXXXX")"
: > "$_empty_tmp"
mv -f "$_empty_tmp" "$LINEMAP"

# -- cache-absent / invalid ⇒ exit 0 (empty linemap already installed) --
if [ -z "$json" ] || ! jq -e . >/dev/null 2>&1 <<<"$json"; then
  exit 0
fi

# Helper: jq filter expression that excludes rows whose key/sid/cwd has TAB,
# LF, or CR. Used in every jq filter below.
_bad_re=$'[\t\n\r]'
_clean_filter='select(
  ((((.key // "") | test($bad_re) | not)) and true)
  and ((((.sid // "") | test($bad_re) | not)) and true)
  and ((((.cwd // "") | test($bad_re) | not)) and true)
)'

# -- reject rows whose key/sid/cwd contains TAB / LF / CR --
while IFS= read -r bad_msg; do
  [ -n "$bad_msg" ] || continue
  echo "agent-fleet-render: skipping row with control char in ${bad_msg}" >&2
done < <(jq -r --arg bad_re "$_bad_re" '
  .rows[]
  | select((.suppressed == false) and (.source != "warning"))
  | . as $r
  | select(
      (((.key // "") | test($bad_re)))
      or (((.sid // "") | test($bad_re)))
      or (((.cwd // "") | test($bad_re)))
    )
  | "key=\(($r.key // "<null>")) sid=\(($r.sid // "<null>")) cwd=\(($r.cwd // "<empty>")) [bad=\(["key","sid","cwd"] | map(select((($r[.]) // "") | test($bad_re))) | join(","))]"
' <<<"$json")

# -- build emit_rows from cache JSON --
# Each emit row has 14 cells:
#   sess, kind_idx, group, cwd, kind, jkey, jsid, source,
#   payload[0..5]
# jkey/jsid are jq `@json`-encoded: literal `null` for absent, `"<v>"`
# for present. The rest stay as literals. Payload cells meaning varies by
# kind — see paint loop.
emit_rows=()
add_row() { emit_rows+=( "$1" ); }

# Warning rows: 14 cells with payload all null. (Painter hardcodes the
# "duplicate opencode instance" text.)
while IFS=$'\t' read -r sess cwd; do
  [ -n "$sess" ] || continue
  add_row "$(printf '%s\t0\t0\t%s\twarning\tnull\tnull\twarning\t-\t-\twarning\t-\t0\t!' "$sess" "$cwd")"
done < <(jq -r --arg bad_re "$_bad_re" '
  .rows[]
  | select(.source == "warning")
  | select(
      ((((.key // "") | test($bad_re) | not)) and true)
      and ((((.sid // "") | test($bad_re) | not)) and true)
      and ((((.cwd // "") | test($bad_re) | not)) and true)
    )
  | [.session, .cwd]
  | @tsv
' <<<"$json")

# Per-cwd visible rows.
while IFS= read -r cwd; do
  [ -n "$cwd" ] || continue
  count="$(jq -r --arg cwd "$cwd" --arg bad_re "$_bad_re" '
    .rows
    | map(select(
        (.cwd == $cwd)
        and ((.suppressed == false))
        and (.source != "warning")
        and (((.key // "") | test($bad_re) | not))
        and (((.sid // "") | test($bad_re) | not))
      ))
    | length
  ' <<<"$json")"
  [ "$count" -gt 0 ] || continue
  first="$(jq -r --arg cwd "$cwd" --arg bad_re "$_bad_re" '
    (.rows
     | map(select(
         (.cwd == $cwd)
         and ((.suppressed == false))
         and (.source != "warning")
         and (((.key // "") | test($bad_re) | not))
         and (((.sid // "") | test($bad_re) | not))
       )))[0]
    | [
        .session,
        .source,
        (.pid // ""),
        .repo,
        (.key | if type == "null" then "null" else @json end)
      ]
    | @tsv
  ' <<<"$json")"
  IFS=$'\t' read -r first_session first_source first_pid first_repo first_key_enc <<<"$first"
  if [ "$first_source" = "v2" ] && [ "$count" -ge 2 ]; then
    # Process_header: kind_idx=1, group=1, kind="process_header".
    #   cells 8..9: "pid=<val>"/repo (literal payload consumed by paint);
    #   cells 10-13: null padding to match the per-cwd 14-col layout.
    add_row "$(printf '%s\t1\t1\t%s\tprocess_header\t%s\tnull\tnull\tpid=%s\t%s\t-\t-\t0\t·' \
      "$first_session" "$cwd" "$first_key_enc" "$first_pid" "$first_repo")"
  fi
  while IFS=$'\t' read -r jsid state jreason ts jtitle jlabel jkey key_padding; do
    [ -n "$state" ] || continue
    source="$first_source"
    title="$(decode_json_cell "$jtitle")"
    label_raw="$(decode_json_cell "$jlabel")"
    sid="$(decode_json_cell "$jsid")"
    reason="$(decode_json_cell "$jreason")"
    label_for_render="$label_raw"
    if [ "$source" = "v2" ]; then
      label_for_render="$(session_label_for "$title" "$sid")"
    fi
    [ -z "$label_for_render" ] && label_for_render="$(basename "${cwd%/}")"
    icon="$(icon_for "$state")"
    if [ -z "$reason" ]; then reason="-"; fi
    if [ "$source" = "v2" ] && [ "$count" -ge 2 ]; then
      # child_row: payload [8..13] = label, state, reason, ts, icon, "".
      add_row "$(printf '%s\t3\t1\t%s\tchild_row\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t-' \
        "$first_session" "$cwd" "$jkey" "$jsid" "$source" \
        "$label_for_render" "$state" "$jreason" "$ts" "$icon")"
    else
      # collapse_row: payload [8..13] = label, state, reason, ts, icon, "".
      add_row "$(printf '%s\t2\t2\t%s\tcollapse_row\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t-' \
        "$first_session" "$cwd" "$jkey" "$jsid" "$source" \
        "$label_for_render" "$state" "$jreason" "$ts" "$icon")"
    fi
  done < <(jq -r --arg cwd "$cwd" --arg bad_re "$_bad_re" '
    .rows[]
    | select(
        (.cwd == $cwd)
        and ((.suppressed == false))
        and (.source != "warning")
        and (((.key // "") | test($bad_re) | not))
        and (((.sid // "") | test($bad_re) | not))
      )
    | [
        (.sid   | if type == "null" then "null" else @json end),
        .state,
        (.reason | if type == "null" then "null" else @json end),
        .ts,
        (.title | if type == "null" then "null" else @json end),
        (.label | if type == "null" then "null" else @json end),
        (.key   | if type == "null" then "null" else @json end),
        ""
      ]
    | @tsv
  ' <<<"$json")
done < <(jq -r --arg bad_re "$_bad_re" '
  ([.rows[]
   | select(((.suppressed == false)) and (.source != "warning"))
   | select(
       (((.key // "") | test($bad_re) | not))
       and (((.sid // "") | test($bad_re) | not))
       and (((.cwd // "") | test($bad_re) | not))
     )
   | .cwd] | unique[])
' <<<"$json")

# -- if no rows to paint, exit 0 (empty linemap already installed) --
if [ "${#emit_rows[@]}" -eq 0 ]; then
  exit 0
fi

# -- paint --
# line_no ticks ONLY on navigable rows. A single-use tmp gets atomic-renamed
# into place on success; on any failure (set -e triggers mid-loop), the
# pre-installed empty linemap remains as the board sees.
_paint_tmp="$(mktemp "$LINEMAP.tmp.XXXXXX")"
: > "$_paint_tmp"

line_no=0
printf '%s\n' "${emit_rows[@]}" \
  | sort -t $'\t' -k1,1 -k3,3n -k4,4 -k2,2n \
  | {
    current_session=""
    while IFS=$'\t' read -ra fields; do
      sess="${fields[0]:-}"
      [ -n "$sess" ] || continue
      kind="${fields[4]:-}"
      cwd="${fields[3]:-}"
      # Identity columns: jq @json — `null` for absent, `"<v>"` for present.
      jkey="${fields[5]:-}"
      jsid="${fields[6]:-}"
      key="$(decode_json_cell "$jkey")"
      sid="$(decode_json_cell "$jsid")"
      if [ "$sess" != "$current_session" ]; then
        [ -n "$current_session" ] && printf '\e[K\n'
        printf '── %s ──────────────\e[K\n' "${sess^^}"
        current_session="$sess"
      fi
      case "$kind" in
        warning)
          line_no=$((line_no + 1))
          printf '  ⚠️  %-32.32s duplicate opencode instance — pick one\e[K\n' "$cwd"
          printf '%s\t%s\t%s\t%s\n' "$line_no" "$key" "$sid" "$cwd" >> "$_paint_tmp"
          ;;
        process_header)
          # Payload cells 8 and 9 — literal "pid=<val>" and repo.
          printf '  %s · %s\e[K\n' "${fields[8]:-}" "${fields[9]:-}"
          ;;
        collapse_row)
          line_no=$((line_no + 1))
          lab="${fields[8]:-}"
          st="${fields[9]:-}"
          reason_enc="${fields[10]:-}"
          ts="${fields[11]:-}"
          icon="${fields[12]:-}"
          # Cache corruption defense: pass through Paint only if every byte of
          # ts is a digit. Substituting a non-numeric here would silently
          # corrupt the age column and would propagate through command
          # substitution without triggering set -e in the assignment. We
          # exit 1 explicitly so the pre-installed empty linemap survives
          # for the partial-frame failure test.
          case "$ts" in *[!0-9]*) echo "agent-fleet-render: non-numeric ts (collapse): $ts" >&2; exit 1 ;; esac
          reason="$(decode_json_cell "$reason_enc")"
          if [ "$reason" = "-" ]; then reason=""; fi
          state_col="$st"
          if [ -n "$reason" ] && [ "$reason" != "null" ]; then state_col="$st: $reason"; fi
          painted="$(printf '  %s %-34.34s %-27.27s %s\e[K' "$icon" "$lab" "$state_col" "$(age_for "$ts")")"
          if [ -n "$HIGHLIGHT_LINE" ] && [ "$line_no" = "$HIGHLIGHT_LINE" ]; then
            printf '\e[7m%s\e[27m\e[K\n' "$painted"
          else
            printf '%s\e[K\n' "$painted"
          fi
          printf '%s\t%s\t%s\t%s\n' "$line_no" "$key" "$sid" "$cwd" >> "$_paint_tmp"
          ;;
        child_row)
          line_no=$((line_no + 1))
          lab="${fields[8]:-}"
          st="${fields[9]:-}"
          reason_enc="${fields[10]:-}"
          ts="${fields[11]:-}"
          icon="${fields[12]:-}"
          case "$ts" in *[!0-9]*) echo "agent-fleet-render: non-numeric ts (child): $ts" >&2; exit 1 ;; esac
          reason="$(decode_json_cell "$reason_enc")"
          if [ "$reason" = "-" ]; then reason=""; fi
          state_col="$st"
          if [ -n "$reason" ] && [ "$reason" != "null" ]; then state_col="$st: $reason"; fi
          painted="$(printf '    %s %-32.32s %-27.27s %s\e[K' "$icon" "$lab" "$state_col" "$(age_for "$ts")")"
          if [ -n "$HIGHLIGHT_LINE" ] && [ "$line_no" = "$HIGHLIGHT_LINE" ]; then
            printf '\e[7m%s\e[27m\e[K\n' "$painted"
          else
            printf '%s\e[K\n' "$painted"
          fi
          printf '%s\t%s\t%s\t%s\n' "$line_no" "$key" "$sid" "$cwd" >> "$_paint_tmp"
          ;;
      esac
    done
  }

# Atomic install: overwrite the (currently empty) linemap with the new map.
# On failure above this line never runs — the empty linemap remains.
mv -f "$_paint_tmp" "$LINEMAP"
