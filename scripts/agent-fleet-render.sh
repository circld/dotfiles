#!/usr/bin/env bash
# agent-fleet-render.sh — paint-only.
#
# Reads `$AGENT_FLEET_STATE_DIR/.board-cache.json` (written by the board from
# the model output) and paints a frame to stdout. NEVER invokes the model.
# Writes a line map to `.board-linemap.tsv` so the board can translate
# painted screen lines into row identities for keyboard navigation.
#
# Cost design (Phase 1 render collapse): exactly 2 jq forks per frame —
# one validate, one transform that owns filtering/grouping/sorting/labels/
# icons/state columns. Bash keeps only a zero-fork paint loop (builtins:
# printf, printf -v, arithmetic) plus the mv pair the atomic linemap
# contract requires (PID-named tmps — one renderer per state dir). The
# old pipeline paid ~5.2 jq forks per row (34 forks at 4 rows,
# ~41ms/row); this pays ~2 per frame.
#
# Transport: the transform emits one record per line, fields joined by
# U+001F (unit separator). U+001F is not IFS whitespace, so empty fields
# survive `read -ra` (TAB is IFS whitespace and would collapse them),
# and key/sid/cwd bytes need no encoding round-trip: control chars
# (TAB/LF/CR, plus U+001F itself) are rejected before transport, so no
# field can contain the separator.
#
# Failure modes (contract, pinned by tests):
#   - cache missing or invalid JSON: empty linemap, no frame, exit 0.
#   - mid-frame failure (jq error, non-numeric ts, …): the EMPTY linemap
#     was installed BEFORE painting, so the board sees no navigable rows
#     instead of stale rows from the previous frame.
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 )); then
  echo "agent-fleet-render: needs bash >= 4 (got $BASH_VERSION); ensure ~/.nix-profile/bin is on PATH" >&2
  exit 1
fi

STATE_DIR="${AGENT_FLEET_STATE_DIR:-$HOME/.local/state/agent-fleet}"
mkdir -p "$STATE_DIR"
CACHE="$STATE_DIR/.board-cache.json"
LINEMAP="$STATE_DIR/.board-linemap.tsv"

# Cleanup the painter's tmp on any abnormal exit. The pre-installed empty
# linemap is the recovery path the partial-frame failure test asserts.
_paint_tmp=""
trap '[ -n "$_paint_tmp" ] && [ -e "$_paint_tmp" ] && rm -f "$_paint_tmp" || true' EXIT

# Validate HIGHLIGHT_LINE: only positive non-zero integers (no `0`, `01`,
# `-5`, `abc`). Anything else is treated as unset.
_HIGHLIGHT_RAW="${AGENT_FLEET_HIGHLIGHT_LINE:-}"
if [ -n "$_HIGHLIGHT_RAW" ] && ! [[ "$_HIGHLIGHT_RAW" =~ ^[1-9][0-9]*$ ]]; then
  _HIGHLIGHT_RAW=""
fi
HIGHLIGHT_LINE="$_HIGHLIGHT_RAW"

# One clock per frame. Ages are minute-granularity, so the old per-row
# `date` fork bought nothing; NOW_MS stays pinnable by tests.
NOW_MS="${AGENT_FLEET_NOW_MS:-$(($(date +%s) * 1000))}"

US=$'\x1f'

# Sets AGE. Returns 1 on non-numeric ts (cache-corruption defense): under
# set -e that aborts the paint mid-frame, leaving the pre-installed empty
# linemap in place — the partial-frame failure contract.
age_for() {
  local ts_ms=$1 delta_s delta_m
  case "$ts_ms" in
    ''|*[!0-9]*) echo "agent-fleet-render: non-numeric ts: $ts_ms" >&2; return 1 ;;
  esac
  delta_s=$(((NOW_MS - ts_ms) / 1000))
  if [ "$delta_s" -lt 0 ]; then delta_s=0; fi
  delta_m=$((delta_s / 60))
  if [ "$delta_m" -lt 1 ]; then AGE='<1m';
  elif [ "$delta_m" -lt 60 ]; then AGE="${delta_m}m";
  else AGE="$((delta_m / 60))h"; fi
}

# -- pre-install ATOMIC empty linemap BEFORE any work that could fail. --
# ponytail: PID-named tmp, not mktemp — one renderer per state dir is
# already the board's assumption, and this saves ~7ms/frame in forks.
# `: >` truncates any stale same-PID leftover, so contents can't leak.
_empty_tmp="$LINEMAP.tmp.empty.$$"
: > "$_empty_tmp"
mv -f "$_empty_tmp" "$LINEMAP"

# -- fork 1: cache-absent / invalid ⇒ exit 0 (empty linemap installed) --
if [ ! -s "$CACHE" ] || ! jq -e . >/dev/null 2>&1 < "$CACHE"; then
  exit 0
fi

# -- fork 2: the whole frame as one transform. --
# Record kinds: E (stderr warning), H (session header), P (process
# header), W (warning row), R (navigable row: collapse `c` / child `n`).
# A jq failure here aborts under set -e before _paint_tmp exists; the
# empty linemap stays. jq's sort is stable, so .rows order survives
# inside a cwd group; the payload tiebreak makes equal-key order
# deterministic (GNU sort's whole-line fallback was locale-sensitive).
frame="$(jq -r --arg bad_re $'[\t\n\r\u001f]' '
  def clean: ((.key // "") | test($bad_re) | not)
             and ((.sid // "") | test($bad_re) | not)
             and ((.cwd // "") | test($bad_re) | not);
  def flat: gsub("[\n\r\u001f]"; " ");
  def icon: if . == "needs-attention" then "🔴"
            elif . == "working" then "🟡"
            elif . == "done" then "🟢"
            else "⚪" end;
  def rowlabel($v2):
    . as $row
    | (if $v2 then
       (if (.title != null and .title != "" and .title != "null") then .title
        elif (.sid != null and .sid != "") then
          (.sid | if (length > 8) then .[0:8] + "…" else . end)
        else "" end)
     else (.label // "") end)
    # `.` is the label string here, not the row — cwd comes from $row.
    | if . == "" then ($row.cwd | sub("/$"; "") | sub(".*/"; "")) else . end;
  def statecol:
    # Literal "null" reason renders bare state, matching the old decoder
    # (JSON null and the string "null" both collapsed to no reason).
    if (.reason // "") == "" or .reason == "-" or .reason == "null" then .state
    else .state + ": " + .reason end;

  # Offenders first (stderr warnings precede painting, as before).
  ((.rows // []) | map(select(clean and (.source == "warning")))) as $warn
  | (((.rows // []) | map(select(clean and (.source != "warning") and (.suppressed == false))))) as $vis
  | ([(.rows // [])[] | select(clean | not) | . as $r
     | ["E", ("key=\($r.key // "<null>") sid=\($r.sid // "<null>") cwd=\($r.cwd // "<empty>") [bad=\(["key","sid","cwd"] | map(select(($r[.]) // "" | test($bad_re))) | join(","))]") | flat]])
    +
    (# Session headers: union of live-pane sessions and sessions of rows
     # that actually paint (clean warning/visible only — a session whose
     # rows were all rejected/suppressed gets NO header, as before).
     ([$warn[].session] + [$vis[].session] + [(.live // [])[]?.session])
     | map(select(type == "string" and length > 0 and (test($bad_re) | not)))
     | unique | map({s: ., g: -1, k: -1, c: "-", id: ["", ""], r: ["H", (. | flat)]})
     # Warning rows (duplicate instances).
     + [$warn[] | {s: (.session // ""), g: 0, k: 0, c: .cwd,
                   id: ["", ""], r: ["W", .cwd]}]
     # Visible rows grouped per cwd; ≥2 visible v2 rows nest under a
     # process header painted from the first row in .rows order.
     + (($vis | group_by(.cwd)) | map(. as $grp
         | ($grp[0]) as $first
         | ($first.source == "v2" and ($grp | length) >= 2) as $nested
         | (if $nested then
              [{s: ($first.session // ""), g: 1, k: 1, c: $first.cwd,
                id: [($first.key // ""), ""],
                r: ["P", ("pid=" + (($first.pid // "") | tostring)),
                    (($first.repo // "") | tostring | flat)]}]
            else [] end)
           + [$grp[] | {s: ($first.session // ""),
                        g: (if $nested then 1 else 2 end),
                        k: (if $nested then 3 else 2 end),
                        c: .cwd,
                        id: [(.key | @json), (.sid | @json)],
                        r: ["R", (if $nested then "n" else "c" end),
                            (.state | icon),
                            (rowlabel($first.source == "v2") | flat),
                            (statecol | flat),
                            (.ts | tostring),
                            (.key // ""), (.sid // ""), .cwd]}])
        | add // [])
     # id tiebreak mirrors the old whole-line GNU sort fallback (the
     # key/sid cells preceded payload), keeping child order stable.
     # Identities sorted @json-encoded (null/quoting byte-faithful to old); payload tail stays decoded (plan-listed divergence, identical for ASCII).
     | sort_by([.s, .g, .c, .k, .id, (.r | join("\u001f"))])
     | map(.r))
  | .[] | join("\u001f")
' "$CACHE")"

# -- zero-fork paint loop (builtins only) --
_paint_tmp="$LINEMAP.tmp.paint.$$"
: > "$_paint_tmp"

line_no=0
current_session=""
painted=""
while IFS="$US" read -ra f; do
  case "${f[0]:-}" in
    E) echo "agent-fleet-render: skipping row with control char in ${f[1]:-}" >&2 ;;
    H) sess="${f[1]:-}"
       if [ -n "$current_session" ]; then printf '\e[K\n'; fi
       printf '── %s ──────────────\e[K\n' "${sess^^}"
       current_session="$sess" ;;
    P) printf '  %s · %s\e[K\n' "${f[1]:-}" "${f[2]:-}" ;;
    W) line_no=$((line_no + 1))
       printf '  ⚠️  %-32.32s duplicate opencode instance — pick one\e[K\n' "${f[1]:-}"
       printf '%s\t%s\t%s\t%s\n' "$line_no" "" "" "${f[1]:-}" >> "$_paint_tmp" ;;
    R) line_no=$((line_no + 1))
       age_for "${f[5]:-}"   # returns 1 on non-numeric ts → set -e aborts
       if [ "${f[1]}" = "n" ]; then
         printf -v painted '    %s %-32.32s %-27.27s %s\e[K' "${f[2]}" "${f[3]}" "${f[4]}" "$AGE"
       else
         printf -v painted '  %s %-34.34s %-27.27s %s\e[K' "${f[2]}" "${f[3]}" "${f[4]}" "$AGE"
       fi
       if [ -n "$HIGHLIGHT_LINE" ] && [ "$line_no" = "$HIGHLIGHT_LINE" ]; then
         printf '\e[7m%s\e[27m\e[K\n' "$painted"
       else
         printf '%s\e[K\n' "$painted"
       fi
       printf '%s\t%s\t%s\t%s\n' "$line_no" "${f[6]:-}" "${f[7]:-}" "${f[8]:-}" >> "$_paint_tmp" ;;
  esac
done <<<"$frame"

# Atomic install: overwrite the (currently empty) linemap with the new
# map. On any failure above, this never runs — the empty linemap remains.
mv -f "$_paint_tmp" "$LINEMAP"
# Clear separator line before advancing to footer; erase-below cannot
# remove stale row text left there when a shorter frame follows a longer.
printf '\e[K\n  j/k or arrows: move | Enter: open | d: dismiss | q: quit\e[K\n'
