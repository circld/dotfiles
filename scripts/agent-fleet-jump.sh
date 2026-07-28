#!/usr/bin/env bash
# scripts/agent-fleet-jump.sh
#
# Jump to the opencode session that needs attention (or just finished): focus
# the right zellij pane AND write a JSON mailbox atomically to the live
# opencode PID's <key>.select so the sensor's poll loop switches the in-TUI
# session.
#
# Plan > Flow > Jump: pane focus is cwd-keyed; .select carries the top-ranked
# session id within that pane. Each cwd has at most ONE live opencode
# instance — duplicate-detection is the UNION of (a) >=2 live opencode panes
# on a cwd and (b) >=2 USABLE v2 state files sharing a cwd (Plan > Core
# Invariant > Exception; Plan > Flow > Jump step 7). Either condition marks
# the cwd ambiguous; ambiguous cwds contribute ZERO ranked candidates, so a
# global jump never warns on duplicates and falls through to the non-
# ambiguous fallback pane (Flow step 16). An EXPLICIT-cwd request naming an
# ambiguous cwd DOES warn (UX Contract — written to stderr verbatim).
#
# Test seams (Plan > Task 5 step 1 + Plan > Task 5 testing approach):
#   AGENT_FLEET_LIVE_PANES_OVERRIDE   file path: synthetic live-pane table
#                                    (cwd<TAB>session<TAB>terminal_<id><TAB>tab_id)
#                                    when set, replaces the real zellij call.
#   AGENT_FLEET_PS_OVERRIDE          file path: lines "OPENCODE<TAB><pid>"
#                                    (alive + comm matches) or "DEAD<TAB><pid>"
#                                    (pid dead). Drives the pid-reuse guard.
#   AGENT_FLEET_DECIDE_ONLY=1        print decision, no side effects.
#   AGENT_FLEET_DECIDE_SELECT=1      print decision AND write .select
#                                    atomically; skip zellij/aerospace.
#
# Decision line (single line on stdout in DECIDE_* modes, on stderr in
# production for diagnostics):
#   DECISION:kind=select cwd=... session=... pane=terminal_<id> tab_id=<n> key=<state_key> sid=<session_id>
#   DECISION:kind=focus-only cwd=... session=... pane=terminal_<id> tab_id=<n>
#   DECISION:kind=fallback-pane session=... pane=terminal_<id> tab_id=<n>
#   DECISION:kind=warn-explicit-duplicate
#   DECISION:kind=noop
set -euo pipefail

STATE_DIR="${AGENT_FLEET_STATE_DIR:-$HOME/.local/state/agent-fleet}"

# bash >= 4 for associative arrays. macOS /bin/bash is 3.2 — bail early so
# the user gets a clear error instead of `declare -A` failing silently.
if (( BASH_VERSINFO[0] < 4 )); then
  echo "agent-fleet-jump: needs bash >= 4 (got $BASH_VERSION); ensure ~/.nix-profile/bin is on PATH" >&2
  exit 1
fi

# === action: live opencode pane table ===
# Override seam: when AGENT_FLEET_LIVE_PANES_OVERRIDE is set to a readable
# file, return its contents verbatim. Tests drive the pane-table without a
# real zellij session. Production ignores the env var.
# Columns: cwd<TAB>session<TAB>terminal_<id><TAB>tab_id
# `tab_id` keys `go-to-tab-by-id` (Plan > Flow step 1 comment in original
# jump.sh: same-session `focus-pane-id` alone does NOT change tabs).
_live_panes() {
  if [ -n "${AGENT_FLEET_LIVE_PANES_OVERRIDE:-}" ] && [ -r "${AGENT_FLEET_LIVE_PANES_OVERRIDE}" ]; then
    cat "${AGENT_FLEET_LIVE_PANES_OVERRIDE}"
    return
  fi
  while IFS= read -r sess; do
    [ -n "$sess" ] || continue
    zellij --session "$sess" action list-panes --json --all 2>/dev/null \
      | jq -r --arg sess "$sess" \
          '.[] | select(.is_plugin==false and .pane_command=="opencode" and (.pane_cwd // "") != "")
           | "\(.pane_cwd)\t\($sess)\tterminal_\(.id)\t\(.tab_id)"'
  done < <(zellij list-sessions -s 2>/dev/null)
}

# === action: ps lookup for pid-reuse guard ===
# Override seam: lines "OPENCODE<TAB><pid>" → alive + comm matches;
# "DEAD<TAB><pid>" → dead. Lines whose pid isn't in the override fall
# through to the real `kill -0` + `ps -o comm= -p <pid>` check (which
# requires the pid's command to contain "opencode" — Plan > Open
# Assumptions > Hard, verified: `process.pid`'s comm inside the plugin
# contains "opencode").
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
  fi
  kill -0 "$pid" 2>/dev/null || return 1
  local comm
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  [[ "$comm" == *opencode* ]]
}

# === calculation: tolerant JSON file read ===
# Returns the JSON on stdout on success; nothing on parse failure (jq exits
# non-zero and the caller's `|| continue` skips). Mirrors sensor.js's
# readTolerantJSON (no-op on any failure).
_read_json() {
  local f="$1"
  [ -f "$f" ] || return 1
  jq -c '.' "$f" 2>/dev/null || return 1
}

# === calculation: rank for a state value ===
# needs-attention=1 (highest); done=0; anything else is non-actionable.
_state_rank() {
  case "$1" in
    needs-attention) echo 1 ;;
    done)            echo 0 ;;
    *)               return 1 ;;
  esac
}

# === calculation: is a session entry suppressed? ===
# Reimplementation of core.mjs isSuppressed (Task 2). Suppression means
# done|needs-attention AND viewedTs >= entryTs. `working` is NEVER
# suppressed (a long-running agent's age advancing past the viewer's
# last-seen ts is normal — Plan > Flow > Jump isSuppressed comment).
# Fresh arrivals (no viewedTs) NEVER suppress.
_is_suppressed() {
  local state="$1" entry_ts="$2" viewed_ts="$3"
  case "$state" in
    needs-attention|done) ;;
    *) return 1 ;;
  esac
  [ "${viewed_ts:-0}" -ge "${entry_ts:-0}" ] 2>/dev/null
}

# === calculation: tolerant read of <key>.viewed.json ===
# Returns a JSON object (possibly empty {}) on stdout; never crashes on
# missing/partial/malformed input (Plan > Data Model).
_read_viewed_for() {
  local p="$1"
  [ -f "$p" ] || { echo "{}"; return 0; }
  jq -c '.' "$p" 2>/dev/null || echo "{}"
}

# === action: atomic write of <key>.select ===
# rename(2) is atomic on the same filesystem, so the sensor's ~400ms poll
# NEVER reads a partial file. Plain in-place writes truncate-then-write
# (verified crash mode under jq + set -e in render.sh's earlier gh).
_atomic_write_select() {
  local target="$1" sid="$2"
  local tmp="${target}.tmp.$$"
  printf '{\n  "sessionID": "%s"\n}\n' "$sid" > "$tmp"
  mv "$tmp" "$target"
}

# === action tail: zellij focus + aerospace + atomic .select ===
# Three modes:
#   - default: production runs the real zellij/aerospace switches AND
#     writes `.select` atomically (the normal interactive path).
#   - AGENT_FLEET_DECIDE_SELECT=1: skip zellij/aerospace; still write
#     `.select` atomically so tests can observe the side-effect.
#   - AGENT_FLEET_DECIDE_ONLY=1: skip zellij/aerospace AND skip the
#     `.select` write — pure read-only "what would jump do?".
# The thin tail (zellij/aerospace calls) is outside the automated test
# scope per Plan > Task 5 step 1's engineering room.
goto_act() {
  if [ "${AGENT_FLEET_DECIDE_ONLY:-0}" = "1" ]; then
    return 0
  fi
  if [ "${ACTION_KIND:-noop}" = "select" ] \
      && [ -n "${ACTION_SELECT_PATH:-}" ] \
      && [ -n "${ACTION_SELECT_SID:-}" ]; then
    _atomic_write_select "$ACTION_SELECT_PATH" "$ACTION_SELECT_SID"
  fi
  if [ "${AGENT_FLEET_DECIDE_SELECT:-0}" = "1" ]; then
    return 0
  fi
  aerospace workspace 1 || true
  local sess="${ACTION_TARGET_SESSION:-}" pane="${ACTION_TARGET_PANE:-}" tab="${ACTION_TARGET_TAB:-}"
  if [ -n "$sess" ] && [ -n "$pane" ]; then
    if [ "$sess" = "${ZELLIJ_SESSION_NAME:-}" ]; then
      zellij action go-to-tab-by-id "$tab"
      zellij action focus-pane-id "$pane"
    else
      zellij action switch-session --pane-id "$pane" "$sess"
    fi
  fi
  return 0
}

# === main ===

live_table="$(_live_panes)"

# Live opencode panes per cwd, used by both the duplicate-detection pane-
# table arm AND the v2 ghost filter (Plan > Flow > Jump steps 6 + 7).
declare -A live_count        # cwd -> count of live opencode panes
declare -A live_session      # cwd -> session name (focus target)
declare -A live_pane         # cwd -> terminal_<id>
declare -A live_tab          # cwd -> tab_id
if [ -n "$live_table" ]; then
  while IFS=$'\t' read -r cwd sess pane tab; do
    if [ -n "$cwd" ]; then
      live_count["$cwd"]=$(( ${live_count["$cwd"]:-0} + 1 ))
      live_session["$cwd"]="$sess"
      live_pane["$cwd"]="$pane"
      live_tab["$cwd"]="$tab"
    fi
  done <<< "$live_table"
fi

# Scan STATE_DIR. Two state-file naming conventions:
#   <cwd-hash>.json           v1 legacy (top-level .state, no .sessions, no .pid)
#   <cwd-hash>-<pid>.json     v2 per-process/per-session
# Plus two non-state sidecars that MUST be excluded before any version
# check (Plan > Data Model): <key>.viewed.json carries a per-session ts
# map; <key>.select carries the JSON mailbox. Bare *.json matches both
# the state files AND the .viewed.json sidecar (also ends .json); we
# filter on the name first.
#
# Per-file classifications stored by cwd:
#   v2_count[cwd]   count of USABLE (liveness-passing) v2 files on this cwd
#                   (feeds the duplicate-detection FILE-count arm — Plan >
#                   Core Invariant > Exception; ≥ 2 marks cwd ambiguous)
#   v2_obj[cwd]     JSON string of the LAST surviving v2 file (the cwd is
#                   already ambiguous on collision so we never rank it)
#   v2_key[cwd]     state key (basename minus .json); used to build the
#                   .select path
#   v1_obj[cwd]     v1 obj string. KEPT ONLY when no USABLE v2 covers this
#                   cwd (Migration supersession — Plan > Data Model).
#   v1_key[cwd]     v1 state key (bare cwd-hash).
declare -A v2_count v2_obj v2_key v1_obj v1_key

shopt -s nullglob
state_paths=( "$STATE_DIR"/*.json )
shopt -u nullglob

for sp in "${state_paths[@]:-}"; do
  [ -e "$sp" ] || continue
  case "$sp" in
    *.viewed.json|*.select) continue ;;
  esac
  obj="$(_read_json "$sp")" || continue
  [ -n "$obj" ] || continue
  # version detection (Plan > Data Model): .sessions object ⇒ v2.
  if jq -e '.sessions | type == "object"' <<< "$obj" >/dev/null 2>&1; then
    pid=$(jq -r '.pid // ""' <<< "$obj")
    cwd=$(jq -r '.cwd // ""' <<< "$obj")
    if [ -z "$pid" ] || [ -z "$cwd" ]; then
      continue
    fi
    # stale-pid filter (Flow steps 4 + 5): BOTH kill -0 and comm=opencode
    # are required. Order matters: doing this BEFORE the v2 ghost filter
    # and BEFORE the supersession check means a dead/reused-pid file is
    # dropped and can NOT silently suppress v1 (Plan > Test case 11b).
    if ! _pid_alive_opencode "$pid"; then
      continue
    fi
    # ghost filter (Flow step 6): v2 cwd must have a live opencode pane
    # (mirrors render.sh's filter so jump and board agree).
    if [ "${live_count[$cwd]:-0}" -lt 1 ]; then
      continue
    fi
    key="${sp##*/}"
    key="${key%.json}"
    v2_obj["$cwd"]="$obj"
    v2_key["$cwd"]="$key"
    v2_count["$cwd"]=$(( ${v2_count["$cwd"]:-0} + 1 ))
  else
    # v1 legacy file. No .pid → no stale-pid filter.
    cwd=$(jq -r '.cwd // ""' <<< "$obj")
    [ -n "$cwd" ] || continue
    if [ "${live_count[$cwd]:-0}" -lt 1 ]; then
      continue
    fi
    key="${sp##*/}"
    key="${key%.json}"
    v1_obj["$cwd"]="$obj"
    v1_key["$cwd"]="$key"
  fi
done

# === duplicate-cwd detection (Plan > Flow > Jump step 7) ===
# UNION of (a) ≥ 2 live panes per cwd (pane-table arm — catches a duplicate
# PANE even with zero/one state files) AND (b) ≥ 2 usable v2 files per
# cwd (file-count arm — Plan > Core Invariant > Exception: catches a
# headless `opencode run` sharing a live cwd).
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

# === ranked candidate pool ===
# Flatten v2 sessions into actionable (needs-attention|done) non-suppressed
# candidate rows; v1 files become focus-only candidates (no .select
# target — Plan > Data Model: v1 has no per-session id).
# Each row TSV: rank<TAB>ts<TAB>cwd<TAB>session<TAB>pane<TAB>tab_id<TAB>state<TAB>key<TAB>sessionID
# Added via printf into a single accumulator string with explicit
# TAB/NEWLINE separators (avoids fragile $'\n' concatenation under bash
# lexers that vary across 3.2/4/5). At most ONE row per (cwd,sessionID)
# is added because the source `sessions` map has unique keys per `cwd` —
# the loop iterates non-ambiguous cwds exactly once each, and within a
# cwd each session id appears once in `.sessions`. So the per-key
# `.select` write at most once per jump call is guaranteed by the input
# shape, not by a runtime dedup table.
candidates=""

for cwd in "${!live_session[@]}"; do
  [ "${ambiguous[$cwd]:-0}" -eq 1 ] && continue   # Plan > UX Contract: zero candidates from ambiguous cwds
  sess="${live_session[$cwd]}"
  pane="${live_pane[$cwd]}"
  tab="${live_tab[$cwd]}"
  if [ -n "${v2_obj[$cwd]:-}" ]; then
    obj="${v2_obj[$cwd]}"
    key="${v2_key[$cwd]}"
    viewed_path="$STATE_DIR/${key}.viewed.json"
    viewed_obj="$(_read_viewed_for "$viewed_path")"
    while IFS=$'\t' read -r sid state ts; do
      [ -n "$sid" ] || continue
      [ "$sid" = "__pane__" ] && continue   # Plan > Flow step 4: never a .select target
      rank="$(_state_rank "$state")" || continue
      viewed_ts="$(jq -r --arg sid "$sid" '.[$sid] // 0' <<< "$viewed_obj")"
      if _is_suppressed "$state" "$ts" "$viewed_ts"; then continue; fi
      candidates+="$(printf '\n%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' "$rank" "$ts" "$cwd" "$sess" "$pane" "$tab" "$state" "$key" "$sid")"
    done < <(jq -r '.sessions | to_entries[] | [.key, .value.state // "", .value.ts // 0] | @tsv' <<< "$obj")
  elif [ -n "${v1_obj[$cwd]:-}" ]; then
    obj="${v1_obj[$cwd]}"
    key="${v1_key[$cwd]}"
    state="$(jq -r '.state // ""' <<< "$obj")"
    ts="$(jq -r '.ts // 0' <<< "$obj")"
    rank="$(_state_rank "$state")" || continue
    # v1 has no per-session map — no viewed suppression. Hidden by
    # `v1 supersession` before this branch (no usable v2 covers cwd).
    candidates+="$(printf '\n%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t' "$rank" "$ts" "$cwd" "$sess" "$pane" "$tab" "$state" "$key")"
  fi
done

# Strip the leading newline.
candidates="${candidates#$'\n'}"

# Sort by rank DESC, ts DESC. `|| true` swallows SIGPIPE under pipefail.
top="$(printf '%s\n' "$candidates" | sort -t $'\t' -k1,1nr -k2,2nr | head -n 1 || true)"

requested_cwd="${1:-}"

# === emit helpers ===
emit_stdout() { echo "$@"; }
emit_stderr() { echo "$@" >&2; }
emit_decision() {
  echo "$@"
  echo "$@" >&2
}

# Explicit cwd duplicate (UX Contract): warn + no-op.
if [ -n "$requested_cwd" ] && [ -n "${ambiguous[$requested_cwd]:-}" ]; then
  msg="multiple opencode instances found for cwd=${requested_cwd}; use one opencode instance with multiple chat sessions"
  emit_stderr "$msg"
  emit_decision "DECISION:kind=warn-explicit-duplicate"
  exit 0
fi

# Explicit cwd resolution.
if [ -n "$requested_cwd" ]; then
  if [ -z "${live_session[$requested_cwd]:-}" ]; then
    # requested cwd has no live pane (or zero actionable sessions wiped
    # out everything); plain noop, no stderr noise.
    emit_decision "DECISION:kind=noop"
    exit 0
  fi
  sess="${live_session[$requested_cwd]}"
  pane="${live_pane[$requested_cwd]}"
  tab="${live_tab[$requested_cwd]}"
  # Explicit-cwd selection ranks SCOPED to requested_cwd — Plan > Flow > Jump
  # "Explicit-cwd session selection": the requested pane's top-ranked
  # actionable session is the .select target. Reusing the global $top and
  # merely checking if its cwd matches would silently drop this pane's own
  # candidate whenever some OTHER pane held the globally best session
  # (regression: then the pane had actionable sessions but no .select was
  # written). Filter + sort + head scoped to requested_cwd.
  top_in_cwd="$(printf '%s\n' "$candidates" | awk -F $'\t' -v c="$requested_cwd" '$3 == c' | sort -t $'\t' -k1,1nr -k2,2nr | head -n 1 || true)"
  if [ -n "$top_in_cwd" ] && [ "$(printf '%s\n' "$top_in_cwd" | cut -f9)" != "" ]; then
    IFS=$'\t' read -r _rank _ts _cwd _sess _pane _tab _state key sid <<<"$top_in_cwd"
    select_path="$STATE_DIR/${key}.select"
    emit_decision "DECISION:kind=select cwd=${requested_cwd} session=${sess} pane=${pane} tab_id=${tab} key=${key} sid=${sid}"
    ACTION_KIND="select"
    ACTION_TARGET_SESSION="$sess"
    ACTION_TARGET_PANE="$pane"
    ACTION_TARGET_TAB="$tab"
    ACTION_SELECT_PATH="$select_path"
    ACTION_SELECT_SID="$sid"
  else
    emit_decision "DECISION:kind=focus-only cwd=${requested_cwd} session=${sess} pane=${pane} tab_id=${tab}"
    ACTION_KIND="focus-only"
    ACTION_TARGET_SESSION="$sess"
    ACTION_TARGET_PANE="$pane"
    ACTION_TARGET_TAB="$tab"
  fi
  goto_act
  exit $?
fi

# === global jump ===

# Top-ranked candidate has a real session id → focus + write .select.
if [ -n "$top" ] && [ "$(printf '%s\n' "$top" | cut -f9)" != "" ]; then
  IFS=$'\t' read -r _rank _ts cwd sess pane tab _state key sid <<<"$top"
  select_path="$STATE_DIR/${key}.select"
  emit_decision "DECISION:kind=select cwd=${cwd} session=${sess} pane=${pane} tab_id=${tab} key=${key} sid=${sid}"
  ACTION_KIND="select"
  ACTION_TARGET_SESSION="$sess"
  ACTION_TARGET_PANE="$pane"
  ACTION_TARGET_TAB="$tab"
  ACTION_SELECT_PATH="$select_path"
  ACTION_SELECT_SID="$sid"
  goto_act
  exit $?
fi

# Top-ranked candidate is a v1 focus-only.
if [ -n "$top" ]; then
  IFS=$'\t' read -r _rank _ts cwd sess pane tab _state _key "" <<<"$top"
  emit_decision "DECISION:kind=focus-only cwd=${cwd} session=${sess} pane=${pane} tab_id=${tab}"
  ACTION_KIND="focus-only"
  ACTION_TARGET_SESSION="$sess"
  ACTION_TARGET_PANE="$pane"
  ACTION_TARGET_TAB="$tab"
  goto_act
  exit $?
fi

# No actionable candidates → fallback pane. Lexicographic sort would pick
# terminal_9 before terminal_10 (Plan > Flow > Jump step 10); parse the
# integer after `terminal_` and compare NUMERICALLY. EXCLUDES ambiguous
# cwds (Plan > UX Contract: a duplicated cwd never gets pane focus).
fallback_sess=""
fallback_pane=""
fallback_tab=""
best_nid=-1
for cwd in "${!live_session[@]}"; do
  [ "${ambiguous[$cwd]:-0}" -eq 1 ] && continue
  pane="${live_pane[$cwd]}"
  nid="${pane#terminal_}"
  # If pane isn't shaped "terminal_<n>" we still get a comparable string;
  # numeric compare ignores non-numeric suffixes inside (( )) only with
  # arithmetic. Cheap fail-safe: skip non-numeric.
  case "$nid" in
    ''|*[!0-9]*) continue ;;
  esac
  if [ "$nid" -gt "$best_nid" ] 2>/dev/null; then
    best_nid="$nid"
    fallback_sess="${live_session[$cwd]}"
    fallback_pane="$pane"
    fallback_tab="${live_tab[$cwd]}"
  fi
done
if [ -n "$fallback_sess" ]; then
  emit_decision "DECISION:kind=fallback-pane session=${fallback_sess} pane=${fallback_pane} tab_id=${fallback_tab}"
  ACTION_KIND="fallback-pane"
  ACTION_TARGET_SESSION="$fallback_sess"
  ACTION_TARGET_PANE="$fallback_pane"
  ACTION_TARGET_TAB="$fallback_tab"
  goto_act
  exit $?
fi

emit_decision "DECISION:kind=noop"
exit 0

