#!/usr/bin/env bash
set -euo pipefail

# Requires bash >= 4 for associative arrays (task_rank, seen_cwd). macOS /bin/bash is 3.2.
if (( BASH_VERSINFO[0] < 4 )); then
  echo "agent-fleet-render: needs bash >= 4 (got $BASH_VERSION); ensure ~/.nix-profile/bin is on PATH" >&2
  exit 1
fi

STATE_DIR="${AGENT_FLEET_STATE_DIR:-$HOME/.local/state/agent-fleet}"

icon_for() {
  case "$1" in
    needs-attention) echo "🔴" ;;
    working)         echo "🟡" ;;
    done)            echo "🟢" ;;
    *)               echo "⚪" ;;
  esac
}

# repo label from cwd — bash twin of the sensor's repoNameFromCwd (keep in sync).
# Used for SYNTHETIC (sensor-less) rows, whose label is computed here at render time
# rather than read from a state file. Real rows already carry the JS-computed label.
# Worktree (.../<repo>/.worktrees/<wt>) -> "<repo>:<wt>", else basename.
repo_label_for() {
  local cwd="$1"
  local trimmed="${cwd%/}"                 # drop a trailing slash
  case "$trimmed" in
    */.worktrees/*)
      local before="${trimmed%%/.worktrees/*}"
      local after="${trimmed##*/.worktrees/}"
      after="${after%%/*}"                 # first segment after .worktrees
      echo "$(basename "$before"):${after}"
      ;;
    *) basename "$trimmed" ;;
  esac
}

age_for() {
  local ts_ms=$1
  local now_ms=$(($(date +%s) * 1000))
  local delta_s=$(((now_ms - ts_ms) / 1000))
  printf '%d:%02d' $((delta_s / 60)) $((delta_s % 60))
}

mkdir -p "$STATE_DIR"

# Build "task<TAB>repo<TAB>state<TAB>reason<TAB>ts" rows.
# Ordering requirement (fixes duplicate task headers): rows of the SAME task must be
# CONTIGUOUS, or the group-header loop below re-emits a task's header every time the
# task reappears after an intervening different-state row. So the sort is:
#   1. task priority = the BEST (lowest) state rank present in that task  (attention-first BETWEEN tasks)
#   2. task name                                                          (keeps a task's rows together)
#   3. state rank                                                         (attention-first WITHIN a task)
#   4. ts, newest first
# Sorting by state rank first (the old bug) split a task across state groups and
# duplicated its header — verified: a task with one needs-attention + one done row
# printed the task header twice.
rows=()
for f in "$STATE_DIR"/*.json; do
  [ -e "$f" ] || continue
  # Skip any file that isn't valid JSON *right now*. Even with the plugin's atomic
  # temp+rename write, a foreign/legacy writer or a truncated leftover must never crash
  # the board: `jq` on partial JSON exits non-zero and `set -e` would kill this loop
  # (verified: partial JSON -> jq rc=5 -> render dies -> board `while true` exits).
  # One validating read, one decode; a bad file is silently skipped this frame and
  # picked up on the next render once it's whole.
  obj=$(jq -c '.' "$f" 2>/dev/null) || continue
  [ -n "$obj" ] || continue
  task=$(jq -r '.task // "Standalone"' <<< "$obj")
  repo=$(jq -r '.repo' <<< "$obj")
  state=$(jq -r '.state' <<< "$obj")
  reason=$(jq -r '.reason // ""' <<< "$obj")
  ts=$(jq -r '.ts' <<< "$obj")
  # reason is LAST because it can be empty (done/working rows): `read` treats tab as
  # IFS whitespace and COLLAPSES adjacent empty fields, so an empty field in the
  # MIDDLE silently shifts every later column left (verified). Keeping the only
  # possibly-empty field terminal makes that collapse harmless.
  rows+=("$task"$'\t'"$repo"$'\t'"$state"$'\t'"$ts"$'\t'"$reason")
done

sort_key() {
  case "$1" in
    needs-attention) echo 0 ;;
    working)         echo 1 ;;
    done)            echo 2 ;;
    *)               echo 3 ;;
  esac
}

# pass 1: per-task best (lowest) state rank, so a task with any red sorts above an all-green task
declare -A task_rank
for r in "${rows[@]:-}"; do
  [ -z "$r" ] && continue
  IFS=$'\t' read -r task _ state _ _ <<< "$r"
  sk=$(sort_key "$state")
  if [ -z "${task_rank[$task]:-}" ] || [ "$sk" -lt "${task_rank[$task]}" ]; then
    task_rank[$task]=$sk
  fi
done

# pass 2: emit "taskrank<TAB>task<TAB>staterank<TAB>ts<TAB>repo<TAB>state<TAB>reason",
# sort by taskrank, task, staterank, ts-desc, then render with contiguous groups.
# reason stays LAST (may be empty — see the collapse note above).
printf '%s\n' "${rows[@]:-}" | while IFS=$'\t' read -r task repo state ts reason; do
  [ -z "$task" ] && continue
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${task_rank[$task]}" "$task" "$(sort_key "$state")" "$ts" "$repo" "$state" "$reason"
done | sort -t $'\t' -k1,1n -k2,2 -k3,3n -k4,4nr | \
{
  current_task=""
  while IFS=$'\t' read -r _ task _ ts repo state reason; do
    if [ "$task" != "$current_task" ]; then
      [ -n "$current_task" ] && echo
      echo "── ${task^^} ──────────────"
      current_task="$task"
    fi
    icon=$(icon_for "$state")
    label="$state"
    [ -n "$reason" ] && [ "$reason" != "null" ] && label="$state: $reason"
    # repo column widened to 18: disambiguated worktree labels ("dotfiles:feat")
    # are longer than a bare basename; %-18s keeps the state column aligned.
    printf '  %s %-18s %-20s %s\n' "$icon" "$repo" "$label" "$(age_for "$ts")"
  done
}
