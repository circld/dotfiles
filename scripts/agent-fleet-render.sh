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

# Set of cwds that currently have a live zellij OPENCODE pane (across all sessions).
# --all is required for pane_cwd/pane_command to be present; absent on plugin/no-command
# panes. Filter on pane_command=="opencode": a fish/nvim pane sharing the agent's cwd
# must NOT keep a ghost row alive — only a live agent pane counts.
# `{ zellij ... || true; }` absorbs `zellij list-sessions -s` exiting non-zero when
# there are zero sessions (verified: zellij 0.44.3 exits 1 with "No active zellij
# sessions found." on stderr, suppressed). Without this, `set -e` + `pipefail` would
# abort on the common "no sessions yet" case. Wrapping in `{ ... ; }` is required for
# precedence: a bare `zellij ... || true | while ...` parses as `(zellij) || (true |
# while ...)` — `||` is lower-precedence than `|` — which discards zellij's output
# entirely and emits a single newline-free empty pipe into `while` (verified). The
# braces make `|| true` an argument modifier INSIDE the subshell, so the pipe still
# gets zellij's stdout. Pipeline still produces empty stdout when there are no
# sessions, which is exactly what we want: no live cwds == every state file becomes
# a ghost == empty board (verified in Step 2).
live_cwds=$(
  { zellij list-sessions -s 2>/dev/null || true; } | while IFS= read -r sess; do
    [ -n "$sess" ] || continue
    zellij --session "$sess" action list-panes --json --all 2>/dev/null \
      | jq -r '.[] | select(.is_plugin==false and .pane_command=="opencode") | .pane_cwd // empty'
  done | sort -u
)

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
# cwd -> 1 for every state file that produced a row. Built in the MAIN shell during
# the per-file build loop (NOT inside a pipe subshell), so the synthetic-row loop
# below can diff against the live-pane inventory after the build loop ends.
declare -A seen_cwd
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
  # Ghost filter (Task 5): hide any state file whose agent has no live zellij opencode
  # pane in this cwd. Join on cwd+opencode (NOT cwd alone — a fish/nvim pane can share
  # the agent's cwd and would otherwise keep a ghost row alive). Read from the already
  # decoded $obj — never re-read the file. Empty $live_cwds (no live sessions) means
  # EVERY state file is a ghost, which is the desired "board is empty" state.
  cwd=$(jq -r '.cwd' <<< "$obj")
  if ! grep -qxF "$cwd" <<< "$live_cwds"; then
    continue  # ghost entry — no live opencode pane runs in this cwd anymore
  fi
  seen_cwd["$cwd"]=1
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

# Fallback (Task 5 Step 1b): surface any live opencode pane whose cwd has NO state
# file as a synthetic `⚪ unknown` row, so the board is never blind to a running-but-
# not-yet-restarted agent. The ghost filter above already restricts $live_cwds to
# `pane_command=="opencode"`, so a separate scan would be redundant — reuse it.
# Runs in the MAIN shell (here-string into the while-read, NOT a piped subshell), so
# the `rows+=(...)` appends persist into the sort/group pipeline below.
# ponytail: synthetic unknowns land in the Standalone bucket, not their real task —
# they're transient (gone once the agent restarts into the sensor). Map them to
# their tasks.toml task only if sensor-less agents become a lasting state.
live_opencode_cwds="$live_cwds"
while IFS= read -r oc; do
  [ -n "$oc" ] || continue
  [ -n "${seen_cwd[$oc]:-}" ] && continue     # already has a state file
  # 5-field shape matches Task 2's per-file rows: task<TAB>repo<TAB>state<TAB>ts<TAB>reason
  # state=unknown -> sort_key 3 (sorts last within its task), icon_for unknown -> ⚪,
  # reason carries the hint. ts=now so a real row that later appears for this cwd
  # will sort ahead (newer ts wins within the same state rank).
  rows+=("Standalone"$'\t'"$(repo_label_for "$oc")"$'\t'"unknown"$'\t'"$(($(date +%s)*1000))"$'\t'"no sensor yet — restart agent")
done <<< "$live_opencode_cwds"

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
