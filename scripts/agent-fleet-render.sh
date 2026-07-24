#!/usr/bin/env bash
set -euo pipefail

# Requires bash >= 4 for associative arrays (session_rank, seen_cwd). macOS /bin/bash is 3.2.
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

# Set of cwds that currently have a live zellij OPENCODE pane (across all sessions),
# paired with the session each lives in. --all is required for pane_cwd/pane_command
# to be present; absent on plugin/no-command panes. Filter on pane_command=="opencode":
# a fish/nvim pane sharing the agent's cwd must NOT keep a ghost row alive — only a
# live agent pane counts.
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
#
# Session is read HERE, from the live pane table, rather than trusted from the state
# record's cached `.session` field: cwd is the only stable identity (session/repo/tab
# names all diverge and can change — a session can be renamed, or a record predates
# this feature and carries a stale/null session). Deriving group membership from the
# live pane table keeps grouping self-correcting, same rationale as the existing
# render-time repo-label fallback below.
live_table=$(
  { zellij list-sessions -s 2>/dev/null || true; } | while IFS= read -r sess; do
    [ -n "$sess" ] || continue
    # A session can die between `list-sessions` and this call (poll-loop race).
    # On a missing session zellij prints "Session '<x>' not found..." + an
    # ANSI-colored session list to STDOUT (not stderr) with exit 0 — 2>/dev/null
    # doesn't catch it and jq chokes on the ANSI escape as invalid JSON
    # (verified: "Invalid numeric literal at line 1, column 2"). Only hand
    # output to jq once we've confirmed it's actually JSON.
    panes=$(zellij --session "$sess" action list-panes --json --all 2>/dev/null) || continue
    [[ "$panes" == \[* ]] || continue
    jq -r --arg sess "$sess" \
      '.[] | select(.is_plugin==false and .pane_command=="opencode" and (.pane_cwd // "") != "")
       | "\(.pane_cwd)\t\($sess)"' <<< "$panes"
  done
)

live_cwds=$(cut -f1 <<< "$live_table" | sort -u)

# cwd -> session, for grouping. Populated from the SAME live_table (one source of
# truth for both the ghost filter and the group key), in the MAIN shell so the lookup
# survives past this block.
declare -A cwd_session
while IFS=$'\t' read -r lc ls; do
  [ -n "$lc" ] || continue
  cwd_session["$lc"]="$ls"
done <<< "$live_table"

# Build "session<TAB>repo<TAB>state<TAB>reason<TAB>ts" rows.
# Ordering requirement (fixes duplicate session headers): rows of the SAME session must
# be CONTIGUOUS, or the group-header loop below re-emits a session's header every time
# the session reappears after an intervening different-state row. So the sort is:
#   1. session priority = the BEST (lowest) state rank present in that session (attention-first BETWEEN sessions)
#   2. session name                                                            (keeps a session's rows together)
#   3. state rank                                                              (attention-first WITHIN a session)
#   4. ts, newest first
# Sorting by state rank first (the old bug) split a session across state groups and
# duplicated its header — verified: a session with one needs-attention + one done row
# printed the session header twice.
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
  repo=$(jq -r '.repo' <<< "$obj")
  # Group key is the LIVE session from the pane table, not the state record's cached
  # `.session` field — see the live_table comment above. A cwd with no live entry here
  # can't happen (the ghost filter above already required cwd in $live_cwds), except
  # when the live pane's session env var was empty; that falls into Standalone too.
  session="${cwd_session[$cwd]:-}"
  [ -n "$session" ] || session="Standalone"
  state=$(jq -r '.state' <<< "$obj")
  reason=$(jq -r '.reason // ""' <<< "$obj")
  ts=$(jq -r '.ts' <<< "$obj")
  # reason is LAST because it can be empty (done/working rows): `read` treats tab as
  # IFS whitespace and COLLAPSES adjacent empty fields, so an empty field in the
  # MIDDLE silently shifts every later column left (verified). Keeping the only
  # possibly-empty field terminal makes that collapse harmless.
  rows+=("$session"$'\t'"$repo"$'\t'"$state"$'\t'"$ts"$'\t'"$reason")
done

# Fallback (Task 5 Step 1b): surface any live opencode pane whose cwd has NO state
# file as a synthetic `⚪ unknown` row, so the board is never blind to a running-but-
# not-yet-restarted agent. The ghost filter above already restricts $live_cwds to
# `pane_command=="opencode"`, so a separate scan would be redundant — reuse it.
# Runs in the MAIN shell (here-string into the while-read, NOT a piped subshell), so
# the `rows+=(...)` appends persist into the sort/group pipeline below.
live_opencode_cwds="$live_cwds"
while IFS= read -r oc; do
  [ -n "$oc" ] || continue
  [ -n "${seen_cwd[$oc]:-}" ] && continue     # already has a state file
  session="${cwd_session[$oc]:-}"
  [ -n "$session" ] || session="Standalone"
  # 5-field shape matches Task 2's per-file rows: session<TAB>repo<TAB>state<TAB>ts<TAB>reason
  # state=unknown -> sort_key 3 (sorts last within its session), icon_for unknown -> ⚪,
  # reason carries the hint. ts=now so a real row that later appears for this cwd
  # will sort ahead (newer ts wins within the same state rank).
  rows+=("$session"$'\t'"$(repo_label_for "$oc")"$'\t'"unknown"$'\t'"$(($(date +%s)*1000))"$'\t'"no sensor yet — restart agent")
done <<< "$live_opencode_cwds"

sort_key() {
  case "$1" in
    needs-attention) echo 0 ;;
    working)         echo 1 ;;
    done)            echo 2 ;;
    *)               echo 3 ;;
  esac
}

# pass 1: per-session best (lowest) state rank, so a session with any red sorts above an all-green session
declare -A session_rank
for r in "${rows[@]:-}"; do
  [ -z "$r" ] && continue
  IFS=$'\t' read -r session _ state _ _ <<< "$r"
  sk=$(sort_key "$state")
  if [ -z "${session_rank[$session]:-}" ] || [ "$sk" -lt "${session_rank[$session]}" ]; then
    session_rank[$session]=$sk
  fi
done

# pass 2: emit "sessionrank<TAB>session<TAB>staterank<TAB>ts<TAB>repo<TAB>state<TAB>reason",
# sort by sessionrank, session, staterank, ts-desc, then render with contiguous groups.
# reason stays LAST (may be empty — see the collapse note above).
printf '%s\n' "${rows[@]:-}" | while IFS=$'\t' read -r session repo state ts reason; do
  [ -z "$session" ] && continue
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${session_rank[$session]}" "$session" "$(sort_key "$state")" "$ts" "$repo" "$state" "$reason"
done | sort -t $'\t' -k1,1n -k2,2 -k3,3n -k4,4nr | \
{
  current_session=""
  while IFS=$'\t' read -r _ session _ ts repo state reason; do
    if [ "$session" != "$current_session" ]; then
      [ -n "$current_session" ] && echo
      echo "── ${session^^} ──────────────"
      current_session="$session"
    fi
    icon=$(icon_for "$state")
    label="$state"
    [ -n "$reason" ] && [ "$reason" != "null" ] && label="$state: $reason"
    # repo column widened to 18: disambiguated worktree labels ("dotfiles:feat")
    # are longer than a bare basename; %-18s keeps the state column aligned.
    printf '  %s %-18s %-20s %s\n' "$icon" "$repo" "$label" "$(age_for "$ts")"
  done
}
