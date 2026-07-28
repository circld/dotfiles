#!/usr/bin/env bash
# scripts/agent-fleet-render.sh
#
# Format (v2 / Jump-aware):
#
#   ── SESSIONNAME ──
#     ⚠️  /duplicate-cwd                duplicate opencode instance — pick one
#
#     🟡 worktree-name                 state[: reason]              age
#     🔴 worktree-name                 state[: reason]              age
#
#     pid=12345 · multi-session-repo
#       🔴 ses_blocked               state[: reason]              age
#       🟢 ses_done_older            state[: reason]              age
#       🟡 ses_working               state[: reason]              age
#
#     ⚪ ghost-worktree              unknown: no sensor yet — restart agent  age
#
# Design notes — why each decision (logged so future readers don't have to
# re-derive):
#
#   Single visible session (after suppression) ⇒ COLLAPSE to one
#   legacy-style "🟡 repo state[:reason] age" line (no pid row, no indent
#   beyond the normal two-space margin). Multi visible sessions ⇒ emit a
#   process row "pid=<pid> · <repo>" + indented children
#     "    <icon> <label> <state[:reason]> <age>".
#   This matches Step 5 (one visible session collapses) and Step 6
#   (multiple nest under a process row).
#
#   working NEVER suppressed (a long-running agent's age advancing past
#   viewedTs is normal; suppress is for terminal states only). Suppression
#   rule mirrors sensor-core.isSuppressed and jump.sh's _is_suppressed:
#   done|needs-attention AND viewedTs >= entryTs ⇒ suppress; working &
#   unknown ⇒ never suppress.
#
#   Per-cwd rows are grouped under their zellij session header (read
#   from the LIVE pane table, not the state file's cached `.session`
#   field — same rationale as the existing pre-Task-5 render: cwd is the
#   only stable identity).
#
#   Within a session group: warning rows first (highest-signal), then in
#   alphabetical cwd order so duplicates of an ambiguous cwd are obvious,
#   then per-cwd rows interleaved.
#
#   All per-cwd data ($live_count, $v2_obj, $v1_obj, $live_session,
#   $ambiguous) is indexed by cwd and is never read across cwds during
#   the build pass — a global-vs-scoped mistake is structurally
#   impossible (lesson from the previous review cycle).
#
# Test injection seams (mirror agent-fleet-jump.sh so the two never
# silently disagree about what's live / ambiguous / suppressed / dead):
#
#   AGENT_FLEET_LIVE_PANES_OVERRIDE   file: cwd<TAB>sess<TAB>terminal_<id><TAB>tab_id
#                                    (replaces the real zellij lookup).
#   AGENT_FLEET_PS_OVERRIDE          file: lines "OPENCODE<TAB><pid>" (alive + opencode
#                                    comm) or "DEAD<TAB><pid>" (dead). Drives the
#                                    pid-reuse guard without a real ps process.
#   AGENT_FLEET_STATE_DIR            sandbox STATE_DIR (default ~/.local/state/agent-fleet).
set -euo pipefail

# bash >= 4 for associative arrays.
if (( BASH_VERSINFO[0] < 4 )); then
  echo "agent-fleet-render: needs bash >= 4 (got $BASH_VERSION); ensure ~/.nix-profile/bin is on PATH" >&2
  exit 1
fi

STATE_DIR="${AGENT_FLEET_STATE_DIR:-$HOME/.local/state/agent-fleet}"

# --- icons / labels (pure) ---
icon_for() {
  case "$1" in
    needs-attention) echo "🔴" ;;
    working)         echo "🟡" ;;
    done)            echo "🟢" ;;
    unknown)         echo "⚪" ;;
    *)               echo "⚪" ;;
  esac
}

# repo label from cwd — bash twin of sensor-core.repoNameFromCwd.
# Worktree (.../<repo>/.worktrees/<wt>) -> "<repo>:<wt>", else basename.
repo_label_for() {
  local cwd="$1"
  local trimmed="${cwd%/}"
  case "$trimmed" in
    */.worktrees/*)
      local before="${trimmed%%/.worktrees/*}"
      local after="${trimmed##*/.worktrees/}"
      after="${after%%/*}"
      echo "$(basename "$before"):${after}"
      ;;
    *) basename "$trimmed" ;;
  esac
}

# Session label: title if present/non-empty/non-null, else truncated id.
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

# --- action: live opencode pane table (overridable for tests) ---
_live_panes() {
  if [ -n "${AGENT_FLEET_LIVE_PANES_OVERRIDE:-}" ] && [ -r "${AGENT_FLEET_LIVE_PANES_OVERRIDE}" ]; then
    cat "${AGENT_FLEET_LIVE_PANES_OVERRIDE}"
    return
  fi
  while IFS= read -r sess; do
    [ -n "$sess" ] || continue
    panes=$(zellij --session "$sess" action list-panes --json --all 2>/dev/null) || continue
    [[ "$panes" == \[* ]] || continue
    jq -r --arg sess "$sess" \
      '.[] | select(.is_plugin==false and .pane_command=="opencode" and (.pane_cwd // "") != "")
       | "\(.pane_cwd)\t\($sess)\tterminal_\(.id)\t\(.tab_id)"' <<< "$panes"
  done < <({ zellij list-sessions -s 2>/dev/null || true; })
}

# --- action: ps lookup for pid-reuse guard ---
_pid_alive_opencode() {
  local pid="$1"
  if [ -n "${AGENT_FLEET_PS_OVERRIDE:-}" ] && [ -r "${AGENT_FLEET_PS_OVERRIDE}" ]; then
    while IFS=$'\t' read -r status p; do
      [ "$p" = "$pid" ] || continue
      case "$status" in
        OPENCODE) return 0 ;;
        DEAD)     return 1 ;;
      esac
    done < "${AGENT_FLEET_PS_OVERRIDE}"
    # No explicit entry in override for this pid → fall through to real ps.
  fi
  kill -0 "$pid" 2>/dev/null || return 1
  local comm
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  [[ "$comm" == *opencode* ]]
}

# --- calculation: tolerant JSON read ---
_read_json() {
  local f="$1"
  [ -f "$f" ] || return 1
  jq -c '.' "$f" 2>/dev/null || return 1
}

# --- calculation: tolerant .viewed.json read. Always returns {} on any
#     failure (Step 7 explicit: never crash render). ---
_read_viewed_for() {
  local p="$1"
  [ -f "$p" ] || { echo "{}"; return 0; }
  jq -c '.' "$p" 2>/dev/null || echo "{}"
}

# --- calculation: is a session entry suppressed? (mirrors sensor-core
#     isSuppressed and jump.sh _is_suppressed: done|needs-attention AND
#     viewedTs >= entryTs ⇒ suppress; working & unknown NEVER suppressed.) ---
_is_suppressed() {
  local state="$1" entry_ts="$2" viewed_ts="$3"
  case "$state" in
    needs-attention|done) ;;
    *) return 1 ;;
  esac
  [ "${viewed_ts:-0}" -ge "${entry_ts:-0}" ] 2>/dev/null
}

mkdir -p "$STATE_DIR"

# === parse live pane table ===
live_table=$(_live_panes)
declare -A live_count live_session
if [ -n "$live_table" ]; then
  while IFS=$'\t' read -r cwd sess pane tab; do
    [ -n "$cwd" ] || continue
    live_count["$cwd"]=$(( ${live_count[$cwd]:-0} + 1 ))
    live_session["$cwd"]="$sess"
  done <<< "$live_table"
fi

# === scan STATE_DIR ===
# v1: <cwd-hash>.json (top-level .state, no .sessions, no .pid)
# v2: <cwd-hash>-<pid>.json (.sessions object)
# Sidecars (excluded before classifying): *.viewed.json, *.select.
#
# Step-1 supersession safety: stale-pid drop runs BEFORE the live-count
# ghost filter AND BEFORE supersession — a dead v2 cannot silently
# suppress v1's fallback row for the same cwd.
declare -A v2_count v2_obj v2_key v1_obj v1_key

shopt -s nullglob
state_paths=( "$STATE_DIR"/*.json )
shopt -u nullglob

for sp in "${state_paths[@]:-}"; do
  [ -e "$sp" ] || continue
  case "$sp" in
    *.viewed.json|*.select) continue ;;
  esac
  obj=$(_read_json "$sp") || continue
  [ -n "$obj" ] || continue
  if jq -e '.sessions | type == "object"' <<< "$obj" >/dev/null 2>&1; then
    pid=$(jq -r '.pid // ""' <<< "$obj")
    cwd=$(jq -r '.cwd // ""' <<< "$obj")
    [ -n "$pid" ] && [ -n "$cwd" ] || continue
    # Step 2: pid-reuse guard. alive + comm contains "opencode" required.
    if ! _pid_alive_opencode "$pid"; then
      continue
    fi
    # ghost filter (matches jump.sh): v2 cwd must have a live opencode pane.
    if [ "${live_count[$cwd]:-0}" -lt 1 ]; then
      continue
    fi
    key="${sp##*/}"
    key="${key%.json}"
    v2_obj["$cwd"]="$obj"
    v2_key["$cwd"]="$key"
    v2_count["$cwd"]=$(( ${v2_count[$cwd]:-0} + 1 ))
  else
    cwd=$(jq -r '.cwd // ""' <<< "$obj")
    [ -n "$cwd" ] || continue
    # ghost filter for v1 too — same rule as v2 (matches jump.sh).
    if [ "${live_count[$cwd]:-0}" -lt 1 ]; then
      continue
    fi
    key="${sp##*/}"
    key="${key%.json}"
    v1_obj["$cwd"]="$obj"
    v1_key["$cwd"]="$key"
  fi
done

# === ambiguity detection (Step 3) ===
# UNION of (a) ≥ 2 live opencode panes per cwd AND (b) ≥ 2 USABLE v2
# files per cwd. Identical rule to jump.sh so the board and jump agree.
declare -A ambiguous
for cwd in "${!live_count[@]}"; do
  if [ "${live_count[$cwd]}" -ge 2 ]; then
    ambiguous["$cwd"]=1
  fi
done
for cwd in "${!v2_count[@]}"; do
  if [ "${v2_count[$cwd]}" -ge 2 ]; then
    ambiguous["$cwd"]=1
  fi
done

# === build row stream ===
# Each emitted row is a single TAB-separated line:
#   sess<TAB>kind_idx<TAB>group<TAB>cwd<TAB>kind<TAB>payload
# kind_idx drives intra-group ordering:
#   0 = warning, 1 = process_header, 2 = collapse_row, 3 = child_row
# group keeps process_header + its child_row contiguous (both carry
# group=1) so they always sort as a single block; collapse_row gets
# group=2 so it interleaves correctly between cwd groups when a single
# cwd has only one visible session. Sort: sess, group, cwd, kind_idx.
# Per-kind payload (TAB-separated):
#   warning:        msg
#   process_header: pidlabel<TAB>repo
#   collapse_row:   repo<TAB>label<TAB>state<TAB>reason<TAB>ts<TAB>icon
#   child_row:      label<TAB>state<TAB>reason<TAB>ts<TAB>icon
# Column 4 (cwd) is repeated for every row so the render pass has it
# available without looking across cwds.
declare -a emit_rows
now_ms=$(($(date +%s) * 1000))
row=""

emit_warning() {
  local sess="$1" cwd="$2" msg="$3"
  printf -v row '%s\t0\t0\t%s\twarning\t%s' "$sess" "$cwd" "$msg"
  emit_rows+=( "$row" )
}

emit_process_header() {
  local sess="$1" cwd="$2" pidlabel="$3" repo="$4"
  printf -v row '%s\t1\t1\t%s\tprocess_header\t%s\t%s' "$sess" "$cwd" "$pidlabel" "$repo"
  emit_rows+=( "$row" )
}

emit_collapse_row() {
  local sess="$1" cwd="$2" label="$3" state="$4" reason="$5" ts="$6" icon="$7"
  # Spec step 5: single-line collapse shows the SESSION LABEL (title else
  # sid fallback else repo for legacy v1). NOT the repo of the cwd.
  # Process header carries repo separately for multi-session cases.
  # Field order: label<TAB>state<TAB>reason<TAB>ts<TAB>icon
  printf -v row '%s\t2\t2\t%s\tcollapse_row\t%s\t%s\t%s\t%s\t%s' \
    "$sess" "$cwd" "$label" "$state" "$reason" "$ts" "$icon"
  emit_rows+=( "$row" )
}

emit_child_row() {
  local sess="$1" cwd="$2" label="$3" state="$4" reason="$5" ts="$6" icon="$7"
  printf -v row '%s\t3\t1\t%s\tchild_row\t%s\t%s\t%s\t%s\t%s\t%s' \
    "$sess" "$cwd" "$label" "$state" "$reason" "$ts" "$icon"
  emit_rows+=( "$row" )
}

for cwd in "${!live_session[@]}"; do
  sess="${live_session[$cwd]}"
  # Step 4: ambiguous cwd ⇒ ONE warning, no actionable / synthetic rows.
  if [ "${ambiguous[$cwd]:-0}" -eq 1 ]; then
    emit_warning "$sess" "$cwd" "duplicate opencode instance — pick one"
    continue
  fi
  if [ -n "${v2_obj[$cwd]:-}" ]; then
    obj="${v2_obj[$cwd]}"
    key="${v2_key[$cwd]}"
    pid=$(jq -r '.pid' <<< "$obj")
    repo=$(jq -r '.repo // ""' <<< "$obj")
    [ -n "$repo" ] || repo=$(repo_label_for "$cwd")
    viewed_path="$STATE_DIR/${key}.viewed.json"
    viewed_obj=$(_read_viewed_for "$viewed_path")
    # Two-pass: collect visible FIRST so we know visible_count before
    # deciding collapse vs nest. TSV row shape (session ids / titles are
    # alphanumeric+underscore in practice; tabs in titles would already
    # have broken the legacy render).
    declare -a visible
    visible=()
    while IFS=$'\t' read -r sid state reason ts title; do
      [ -n "$sid" ] || continue
      state=$(printf '%s' "$state" | tr -d '\r\n')
      ts=$(printf '%s' "$ts" | tr -d '\r\n')
      reason=$(printf '%s' "$reason" | tr -d '\r\n')
      title=$(printf '%s' "$title" | tr -d '\r\n')
      viewed_ts=$(jq -r --arg sid "$sid" '.[$sid] // 0' <<< "$viewed_obj" 2>/dev/null || echo 0)
      if _is_suppressed "$state" "$ts" "$viewed_ts"; then
        continue
      fi
      # Sentinel roundtrip: bash's `read` with `IFS=\t` collapses runs of
      # empty middle fields into a single field (verified: `a\t\tb` reads
      # as 2 vars, not 3). jq emits `""` for null fields, which would
      # trigger collapse. Replace empty values with `-` (a string that
      # never appears in real sensor data — '-' IS NOT a valid state,
      # reason, or title) so the row is always 5 distinct fields; reverse
      # at consumer.
      [ -n "$reason" ] || reason='-'
      [ -n "$title" ] || title='-'
      visible+=( "$(printf '%s\t%s\t%s\t%s\t%s' "$sid" "$state" "$reason" "$ts" "$title")" )
    done < <(jq -r '.sessions | to_entries[]? | [.key, (.value.state // "-"), (.value.reason // "-"), (.value.ts // 0), (.value.title // "-")] | @tsv' <<< "$obj")
    if [ "${#visible[@]}" -eq 0 ]; then
      # Step 7 + 8: process with zero visible sessions drops entirely.
      continue
    fi
    if [ "${#visible[@]}" -ge 2 ]; then
      # Multi visible session ⇒ emit process_header BEFORE children.
      emit_process_header "$sess" "$cwd" "pid=${pid}" "$repo"
    fi
    for vrow in "${visible[@]}"; do
      IFS=$'\t' read -r sid state reason ts title <<<"$vrow"
      # Reverse the empty→sentinel translation from the producer. After
      # this point reason/title are restored to "" if originally empty.
      [ "$reason" = "-" ] && reason=""
      [ "$title"  = "-" ] && title=""
      label=$(session_label_for "$title" "$sid")
      icon=$(icon_for "$state")
      if [ "${#visible[@]}" -eq 1 ]; then
        # Spec step 5: collapse path shows LABEL (title else sid).
        # Empty reason (no middle field) becomes "-" sentinel — the
        # render pass needs no empty middle fields either (same bash
        # `read` quirk).
        [ -z "$reason" ] && reason='-'
        emit_collapse_row "$sess" "$cwd" "$label" "$state" "$reason" "$ts" "$icon"
      else
        [ -z "$reason" ] && reason='-'
        emit_child_row "$sess" "$cwd" "$label" "$state" "$reason" "$ts" "$icon"
      fi
    done
  elif [ -n "${v1_obj[$cwd]:-}" ]; then
    # v1 legacy. Only present when no USABLE v2 covers this cwd (Step 1
    # migration supersession). No per-session map → no viewed
    # suppression. Label = repo (no per-session data exists).
    obj="${v1_obj[$cwd]}"
    state=$(jq -r '.state // ""' <<< "$obj")
    reason=$(jq -r '.reason // ""' <<< "$obj")
    ts=$(jq -r '.ts // 0' <<< "$obj")
    repo=$(jq -r '.repo // ""' <<< "$obj")
    [ -n "$repo" ] || repo=$(repo_label_for "$cwd")
    icon=$(icon_for "$state")
    label="$repo"
    # Sentinel roundtrip: bash read collapses empty middle fields; if
    # reason is empty in the v1 file (common: state=done reason=null ⇒
    # jq prints ""), we substitute "-" so the row stays 5 distinct
    # fields end to end. The render pass reverses.
    [ -z "$reason" ] && reason='-'
    emit_collapse_row "$sess" "$cwd" "$label" "$state" "$reason" "$ts" "$icon"
  fi
done

# === synthetic rows (Step 8) ===
  # Live opencode pane on a cwd that contributed NO row above (state file
  # missing/sensor-less). Use repo_label_for to synthesize the label so the
  # row is legible even without `.repo`.
  declare -A cwd_covered
  for cwd in "${!ambiguous[@]}";  do cwd_covered["$cwd"]=1; done
  for cwd in "${!v2_obj[@]}";    do cwd_covered["$cwd"]=1; done
  for cwd in "${!v1_obj[@]}";    do cwd_covered["$cwd"]=1; done
  for cwd in "${!live_session[@]}"; do
    [ -n "${cwd_covered[$cwd]:-}" ] && continue
    sess="${live_session[$cwd]}"
    repo=$(repo_label_for "$cwd")
    label="$repo"
    # reason is always non-empty for synthetic (it carries the hint); no
    # sentinel needed here.
    emit_collapse_row "$sess" "$cwd" "$label" "unknown" "no sensor yet — restart agent" "$now_ms" "⚪"
  done

# === sort + render ===
# Sort: session ASC, group ASC, cwd ASC, kind_idx ASC. With group=1
# holding both process_header and child_row (same cwd ⇒ ties break on
# kind_idx, header<children), every process's children sort immediately
# under its own header.
printf '%s\n' "${emit_rows[@]:-}" | sort -t $'\t' -k1,1 -k3,3n -k4,4 -k2,2n \
  | {
    current_session=""
    while IFS=$'\t' read -r sess kind_idx group cwd kind payload; do
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
          # Defensive: spec says "Render never emits a blank label".
          # session_label_for always returns non-empty; v1 uses repo.
          # Synthetic uses repo-from-cwd. If somehow empty, fall back to
          # the cwd basename.
          if [ -z "$label" ] || [ "$label" = "null" ]; then
            label=$(basename "${cwd%/}")
          fi
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
