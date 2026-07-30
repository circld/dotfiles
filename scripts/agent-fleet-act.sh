#!/usr/bin/env bash
# scripts/agent-fleet-act.sh
# Shared helper layer for agent-fleet scripts (jump, traverse, board).
# Sourced — never executed on its own. Public shell functions only.
#
# Writer contract (per design):
#   - Every side-effecting helper self-guards against AGENT_FLEET_DECIDE_ONLY.
#   - atomic_write_select / act_land begin with the same DECIDE_ONLY check as
#     stack_write so jump.sh's removal of goto_act's external guard doesn't
#     leak .select writes under the decide-only seam; board dismiss looks up
#     atomic_write_select directly with no other guard on that path.
#   - stack_write is the SOLE writer of traverse-stack.json. Failure must
#     warn-and-return-0 so callers continue to landing; the stack file is a
#     disposable breadcrumb (the reconcile flip re-detects on the next press).
#
# stack JSON shape (v1):
#   {"v":1,"current":<object {sid,ts}>|null,"back":[<sid>...],"forward":[<sid>...]}
# Canonical empty:
#   {"v":1,"current":null,"back":[],"forward":[]}

# === stack_read: tolerant v1 read; canonical empty stack on bad input. ===
# Any of: missing file, non-object, unrecognized version, missing/non-array
# stacks, non-object-or-null current, non-string current.sid, non-numeric
# current.ts, or any non-string entry in back/forward ⇒ canonical empty on
# stdout. Field-level validation keeps malformed shapes from cascading into
# jq type errors under `set -euo pipefail` downstream.
stack_read() {
  local path="${1:-$STATE_DIR/traverse-stack.json}"
  local canonical='{"v":1,"current":null,"back":[],"forward":[]}'
  if [ ! -f "$path" ]; then
    printf '%s\n' "$canonical"
    return 0
  fi
  if ! jq -e '
      type == "object"
      and (.v == 1)
      and (
        (.current == null)
        or (
          (.current | type == "object")
          and (.current.sid | type == "string")
          and (.current.ts  | type == "number")
        )
      )
      and (.back    | (type == "array") and all(. != null and type == "string"))
      and (.forward | (type == "array") and all(. != null and type == "string"))
    ' "$path" >/dev/null 2>&1; then
    printf '%s\n' "$canonical"
    return 0
  fi
  cat "$path"
}

# === stack_write: atomic tmp+rename; DECIDE_ONLY no-op; warn-and-return-0 on failure. ===
# Caller passes JSON. Failure is non-fatal: caller continues to landing.
stack_write() {
  local stack_json="${1:-}"
  if [ "${AGENT_FLEET_DECIDE_ONLY:-0}" = "1" ]; then
    return 0
  fi
  if [ -n "${AF_REQUEST_ID:-}" ]; then
    local stamped
    if stamped="$(jq -c --arg w "$AF_REQUEST_ID" '.writer=$w' <<<"$stack_json" 2>/dev/null)"; then
      stack_json="$stamped"
    else
      echo "agent-fleet-act: stack_write: writer stamp failed; continuing unstamped" >&2
    fi
  fi
  if [ -n "${AGENT_FLEET_TRACE_DIR:-}" ] && [ -n "${AF_REQUEST_ID:-}" ]; then
    printf '%s\n' "$stack_json" | af_trace stack-post.json
  fi
  local path="${2:-$STATE_DIR/traverse-stack.json}"
  local tmp
  if ! tmp="$(mktemp "${path}.tmp.XXXXXX" 2>/dev/null)"; then
    echo "agent-fleet-act: stack_write: tmpfile creation failed for $path" >&2
    return 0
  fi
  if ! printf '%s\n' "$stack_json" > "$tmp" 2>/dev/null; then
    echo "agent-fleet-act: stack_write: failed to write tmp $tmp" >&2
    rm -f "$tmp" 2>/dev/null || true
    return 0
  fi
  if ! mv "$tmp" "$path" 2>/dev/null; then
    echo "agent-fleet-act: stack_write: failed to rename $tmp -> $path (target may be locked or non-empty dir)" >&2
    rm -f "$tmp" 2>/dev/null || true
    return 0
  fi
}

# === stack_push_mru: pure jq transform — remove sid from both stacks, append sid to back. ===
# Reads stack JSON on stdin, prints new stack JSON to stdout.
stack_push_mru() {
  jq --arg sid "$1" '
    .back |= ((map(select(. != $sid))) + [$sid])
    | .forward |= map(select(. != $sid))
  '
}

# === stack_derive_p: pure jq transform. Inputs: model JSON (stdin), source
#     zellij session ($1, may be ""). Emits P = {sid, ts} | null on stdout. ===
# Physical-presence preference: when the press comes from a zellij session
# hosting agent instance(s) with a cursor, P is the newest such cursor — the
# user IS there. Global max(selectedTs) lags native zellij session switches
# (sensor cursors only advance on mailbox consumes), leaving the stack current
# pinned to wherever the last fleet landing went; the next alt-, then "pops"
# the session the user is already sitting in (reads as a duplicate node).
# Falls back to global max when the source session hosts no instance with a
# cursor. Instance↔session join is by cwd (instances carry no session field);
# an ambiguous cwd shared across zellij sessions counts toward both — harmless.
stack_derive_p() {
  jq -c --arg src "${1:-}" '
    def cursor: select(.selectedSid != null and (.selectedTs | type) == "number")
                | {sid: .selectedSid, ts: .selectedTs};
    ([ .live[]? | select(.session == $src) | .cwd ] | unique) as $src_cwds
    | ([ .instances[]? | select(.cwd as $c | ($src_cwds | index($c)) != null) | cursor ]
       | if length > 0 then max_by(.ts) else null end) as $local
    | if $local != null then $local
       else ([ .instances[]? | cursor ] | if length > 0 then max_by(.ts) else null end)
       end
  '
}

# === stack_reconcile: pure jq transform. Inputs: stack JSON (stdin), P (--argjson), now_ms ($(($now_ms))). ===
# Semantics per design `Traverse stack semantics` (§Reconcile on every press):
#   - P undeterminable (null)                       → no change
#   - current.sid == P.sid                          → no change
#   - current == null AND P != null                 → adopt (current := P, ts := now_ms; NO push)
#   - P.ts < current.ts AND (now_ms - current.ts) < 2000  → no change (stale-P within window)
#   - otherwise                                     → flip: remove P from both stacks; push old current
#                                                      MRU onto back; clear forward; current = {P, now_ms}
stack_reconcile() {
  local p_json="$1" now_ms="$2"
  jq --argjson now_ms "$now_ms" --argjson p "$p_json" '
    . as $s
    | (
        if ($p == null) or (($p | type) != "object")
          then null
        elif ($s.current != null) and ($s.current.sid == $p.sid)
          then null
        elif $s.current == null
          then {kind: "adopt"}
        elif ($p.ts < $s.current.ts) and (($now_ms - $s.current.ts) < 2000)
          then null
        else {kind: "flip"}
      end) as $decision
    | if $decision == null
        then $s
      elif $decision.kind == "adopt"
        then ($s | .current = {sid: $p.sid, ts: $now_ms})
      else
        ($s
         | .back |= ((map(select((. != $p.sid) and (. != $s.current.sid))) +
                     (if ($s.current != null) and ($s.current.sid != $p.sid)
                        then [$s.current.sid]
                        else [] end)))
         | .forward |= []
         | .current = {sid: $p.sid, ts: $now_ms})
      end
  '
}

# === atomic_write_select: DECIDE_ONLY no-op; else atomic-write {sessionID}
#     (or {sessionID, markOnly: true} when third arg is literal `true`).
# Body is built with jq -n --arg so the sid is JSON-escaped (quotes,
# backslashes, control chars cannot break the mailbox or inject sibling
# fields). Atomicity mirrors stack_write: tmp + rename, warn-and-return-0
# on failure so callers continue to landing. The markOnly variant is
# reserved for board dismiss (Task 10); jump/traverse always omit it.
# Default "${3:-false}" so two-arg callers under `set -u` don't abort.
# Tolerates "1" in addition to "true" for symmetry with numeric-flag callers.
atomic_write_select() {
  if [ "${AGENT_FLEET_DECIDE_ONLY:-0}" = "1" ]; then
    return 0
  fi
  local target="$1" sid="$2" mark_only="${3:-false}" request_id="${4:-${AF_REQUEST_ID:-}}"
  local mo_flag=0
  if [ "$mark_only" = "true" ] || [ "$mark_only" = "1" ]; then
    mo_flag=1
  fi
  local tmp
  if ! tmp="$(mktemp "${target}.tmp.XXXXXX" 2>/dev/null)"; then
    echo "agent-fleet-act: atomic_write_select: tmpfile creation failed for $target" >&2
    return 0
  fi
  if ! jq -n --arg sid "$sid" --argjson mo "$mo_flag" --arg rid "$request_id" \
       '({sessionID: $sid}
         + (if $mo == 1 then {markOnly: true} else {} end)
         + (if $rid != "" then {requestId: $rid} else {} end))' \
       > "$tmp" 2>/dev/null; then
    echo "agent-fleet-act: atomic_write_select: failed to build body for $target" >&2
    rm -f "$tmp" 2>/dev/null || true
    return 0
  fi
  if ! mv "$tmp" "$target" 2>/dev/null; then
    echo "agent-fleet-act: atomic_write_select: failed to rename $tmp -> $target (target may be locked)" >&2
    rm -f "$tmp" 2>/dev/null || true
    return 0
  fi
}

# === act_land: DECIDE_ONLY no-op; optional mailbox; aerospace workspace;
#     zellij tab/pane focus. Skips focus tail when AGENT_FLEET_DECIDE_SELECT=1
#     or AGENT_FLEET_DECIDE_ACT=1 (board and rear-poll consumers). ===
# Usage: act_land <key> <sid> <session> <pane> <tab> [chat-title]
# Writes mailbox <STATE_DIR>/<key>.select when BOTH key and sid are non-empty
# (focus-only / fallback-pane callers pass empty key, so no mailbox).
# Focus-tail routing by presser session ($ZELLIJ_SESSION_NAME):
#   1. presser == target            → in-context go-to-tab + focus-pane (Alt-y same-session)
#   2. presser == notes (board path) → act_land_from_notes (never moves the
#      notes client unless no other window exists to land on)
#   3. otherwise                    → in-context switch-session (Alt-y cross-session)
# Client probe: client rows start with a numeric CLIENT_ID; exited/missing
# sessions dump "not found" text (never digit-leading) on stdout with rc=0.
act_land() {
  local key="$1" sid="$2" sess="$3" pane="$4" tab="$5" title="${6:-}"
  if [ "${AGENT_FLEET_DECIDE_ONLY:-0}" = "1" ]; then
    return 0
  fi
  if [ -n "$key" ] && [ -n "$sid" ]; then
    atomic_write_select "${STATE_DIR}/${key}.select" "$sid"
  fi
  if [ "${AGENT_FLEET_DECIDE_SELECT:-0}" = "1" ] \
      || [ "${AGENT_FLEET_DECIDE_ACT:-0}" = "1" ]; then
    return 0
  fi
  local presser="${ZELLIJ_SESSION_NAME:-}"
  if [ "$presser" = "notes" ] && [ -n "$sess" ] && [ -n "$pane" ]; then
    act_land_from_notes "$sess" "$pane" "$tab" "$title"
    return 0
  fi
  af_act_log aerospace-ws aerospace workspace 1
  if [ -n "$sess" ] && [ -n "$pane" ]; then
    if [ "$sess" = "$presser" ]; then
      af_act_log go-to-tab zellij action go-to-tab-by-id "$tab"
      af_act_log focus-pane zellij action focus-pane-id "$pane"
    else
      af_act_log switch-session zellij action switch-session --pane-id "$pane" "$sess"
    fi
    af_landing_verify "$sess" "$pane"
  fi
}

# === act_land_from_notes: board landing (presser == notes). ===
# $1 session, $2 pane, $3 tab, $4 chat title (window-match hint, may be "").
#   a. target has a client  → drive its own client by --session
#   b. target clientless    → first non-notes session with a client ("home")
#     ponytail: first-match home heuristic; refine if 2 agent windows ever run
#   c. no home client       → move the notes client and STAY PUT: an aerospace
#                             workspace jump here would strand the user away
#                             from the just-switched window.
# a/b then raise the exact window (see act_focus_window) — `aerospace
# workspace 1` alone focuses the MRU window, which with ≥2 agent windows is
# whichever was used last, not the jump target.
act_land_from_notes() {
  local sess="$1" pane="$2" tab="$3" title="${4:-}"
  if zellij --session "$sess" action list-clients 2>/dev/null | grep -qE '^[0-9]+[[:space:]]'; then
    af_act_log go-to-tab zellij --session "$sess" action go-to-tab-by-id "$tab"
    af_act_log focus-pane zellij --session "$sess" action focus-pane-id "$pane"
  else
    local home="" s
    while IFS= read -r s; do
      [ -n "$home" ] && break
      [ "$s" = "notes" ] && continue
      if zellij --session "$s" action list-clients 2>/dev/null | grep -qE '^[0-9]+[[:space:]]'; then
        home="$s"
      fi
    done < <(zellij list-sessions -s -n 2>/dev/null)
    if [ -n "$home" ]; then
      af_act_log home-switch zellij --session "$home" action switch-session --pane-id "$pane" "$sess"
    else
      af_act_log notes-switch zellij action switch-session --pane-id "$pane" "$sess"
      return 0
    fi
  fi
  act_focus_window "$title"
  af_landing_verify "$sess" "$pane"
}

# === act_focus_window: raise the Ghostty window showing the landed pane. ===
# No session→window map exists, so match the window title: opencode writes
# "OC | <chat title>" and zellij forwards the focused pane's title (verified
# live; same trick as isRepoVisible in agent-fleet-sensor-core.mjs). 32-char
# prefix survives opencode's own title truncation.
# ponytail: 0.2s settle for the title to propagate after a hijack/refocus;
# first title match wins (two windows on one chat collide); empty title or no
# match → MRU workspace focus (pre-fix behavior).
act_focus_window() {
  local t="${1:0:32}" wid wins
  if [ -z "$t" ]; then
    af_act_log aerospace-ws aerospace workspace 1
    return 0
  fi
  sleep 0.2
  wins="$(aerospace list-windows --all --json 2>/dev/null)" || true
  wid="$(jq -r --arg t "$t" \
    '[.[] | select(."app-name" == "Ghostty" and ((."window-title" // "") | contains($t)))][0]."window-id" // empty' \
    <<<"$wins" 2>/dev/null || true)"
  if [ -n "${AGENT_FLEET_TRACE_DIR:-}" ] && [ -n "${AF_REQUEST_ID:-}" ]; then
    jq -c --arg t "$t" --arg wid "${wid:-}" \
      '{ prefix: $t, chosen: (if $wid == "" then null else ($wid | tonumber) end),
        candidates: [.[] | select(."app-name" == "Ghostty" and ((."window-title" // "") | contains($t)))
                     | {wid: ."window-id", title: ."window-title"}] }' \
      <<<"$wins" 2>/dev/null | af_trace landing-windows.json || true
  fi
  if [ -n "$wid" ]; then
    af_act_log aerospace-focus aerospace focus --window-id "$wid"
  else
    af_act_log aerospace-ws aerospace workspace 1
  fi
}

# === af_trace: env-gated per-press trace write. $1 = filename; content on stdin. ===
# Writes $AGENT_FLEET_TRACE_DIR/$AF_REQUEST_ID/$1. When either var is unset it
# DRAINS stdin to /dev/null and returns 0, so callers may pipe into it unguarded
# (a no-read early return races the writer and can SIGPIPE it under pipefail).
# Observability only: never fails the caller. It writes whenever invoked with
# the env set, including under DECIDE_ONLY — but call sites inside
# DECIDE_ONLY-guarded writers (stack-post, landing ledger) are never reached in
# that mode, so a DECIDE_ONLY press captures model/stack-pre/decision only.
# That asymmetry is intended: decide-only suppresses state mutations, not
# observability of what ran.
af_trace() {
  if [ -z "${AGENT_FLEET_TRACE_DIR:-}" ] || [ -z "${AF_REQUEST_ID:-}" ]; then
    cat >/dev/null 2>&1 || true
    return 0
  fi
  local dir="${AGENT_FLEET_TRACE_DIR}/${AF_REQUEST_ID}"
  mkdir -p "$dir" 2>/dev/null || { cat >/dev/null 2>&1 || true; return 0; }
  cat > "${dir}/$1" 2>/dev/null || true
}

# === af_trace_line: append to per-press file $1 (created on demand). Line on stdin. ===
# Same drain-when-disabled contract as af_trace.
af_trace_line() {
  if [ -z "${AGENT_FLEET_TRACE_DIR:-}" ] || [ -z "${AF_REQUEST_ID:-}" ]; then
    cat >/dev/null 2>&1 || true
    return 0
  fi
  local dir="${AGENT_FLEET_TRACE_DIR}/${AF_REQUEST_ID}"
  mkdir -p "$dir" 2>/dev/null || { cat >/dev/null 2>&1 || true; return 0; }
  cat >> "${dir}/$1" 2>/dev/null || true
}

# === af_act_log: run cmd, append "label rc=N argv out" to landing.log; always rc 0. ===
af_act_log() {
  local label="$1"; shift
  local out rc=0
  out="$("$@" 2>&1)" || rc=$?
  if [ -n "${AGENT_FLEET_TRACE_DIR:-}" ] && [ -n "${AF_REQUEST_ID:-}" ]; then
    printf '%s rc=%s argv=[%s] out=%s\n' "$label" "$rc" "$*" \
      "$(printf '%s' "$out" | tr '\n' ' ' | tail -c 400)" | af_trace_line landing.log
  fi
  return 0
}

# === af_landing_verify: post-landing zellij-side ground truth (env-gated). ===
af_landing_verify() {
  [ -n "${AGENT_FLEET_TRACE_DIR:-}" ] && [ -n "${AF_REQUEST_ID:-}" ] || return 0
  local sess="$1" pane="$2"
  [ -n "$sess" ] && [ -n "$pane" ] || return 0
  sleep 0.2   # ponytail: settle so is_focused reflects the post-switch state
              # (same 0.2s as act_focus_window); trace-only, best-effort anyway.
  local out
  out="$(zellij --session "$sess" action list-panes --json --all)" || true
  printf '%s' "$out" | jq -c --arg pane "$pane" '
    (if type == "array" then . else [] end)
    | map(select(("terminal_\(.id)") == $pane))
    | first // {}
    | {is_focused, tab_id, tab_name, title, pane_command, pane_cwd}
  ' 2>/dev/null | af_trace landing-verify.json || true
  return 0
}
