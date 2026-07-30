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
  if [ "${AGENT_FLEET_DECIDE_ONLY:-0}" = "1" ]; then
    return 0
  fi
  local stack_json="$1"
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
  local target="$1" sid="$2" mark_only="${3:-false}"
  local mo_flag=0
  if [ "$mark_only" = "true" ] || [ "$mark_only" = "1" ]; then
    mo_flag=1
  fi
  local tmp
  if ! tmp="$(mktemp "${target}.tmp.XXXXXX" 2>/dev/null)"; then
    echo "agent-fleet-act: atomic_write_select: tmpfile creation failed for $target" >&2
    return 0
  fi
  if ! jq -n --arg sid "$sid" --argjson mo "$mo_flag" \
       'if $mo == 1 then {sessionID: $sid, markOnly: true} else {sessionID: $sid} end' \
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
# Usage: act_land <key> <sid> <session> <pane> <tab>
# Writes mailbox <STATE_DIR>/<key>.select when BOTH key and sid are non-empty
# (focus-only / fallback-pane callers pass empty key, so no mailbox).
# Focus-tail routing by presser session ($ZELLIJ_SESSION_NAME):
#   1. presser == target            → in-context go-to-tab + focus-pane (Alt-y same-session)
#   2. presser == notes (board path) — never move the notes client (workspace 5):
#      a. target has a client       → zellij --session <target> go-to-tab + focus-pane
#      b. target clientless         → first non-notes session with a client ("home")
#                                     runs switch-session --pane-id <pane> <target>
#      c. no home client at all     → plain switch-session from notes (last resort)
#   3. otherwise                    → in-context switch-session (Alt-y cross-session)
# Client probe: client rows start with a numeric CLIENT_ID; exited/missing
# sessions dump "not found" text (never digit-leading) on stdout with rc=0.
act_land() {
  local key="$1" sid="$2" sess="$3" pane="$4" tab="$5"
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
  aerospace workspace 1 || true
  if [ -n "$sess" ] && [ -n "$pane" ]; then
    local presser="${ZELLIJ_SESSION_NAME:-}"
    if [ "$sess" = "$presser" ]; then
      zellij action go-to-tab-by-id "$tab" || true
      zellij action focus-pane-id "$pane" || true
    elif [ "$presser" = "notes" ]; then
      if zellij --session "$sess" action list-clients 2>/dev/null | grep -qE '^[0-9]+[[:space:]]'; then
        zellij --session "$sess" action go-to-tab-by-id "$tab" || true
        zellij --session "$sess" action focus-pane-id "$pane" || true
      else
        # ponytail: first-match home heuristic; refine if 2 agent windows ever run
        local home="" s
        while IFS= read -r s; do
          [ -n "$home" ] && break
          [ "$s" = "notes" ] && continue
          if zellij --session "$s" action list-clients 2>/dev/null | grep -qE '^[0-9]+[[:space:]]'; then
            home="$s"
          fi
        done < <(zellij list-sessions -s -n 2>/dev/null)
        if [ -n "$home" ]; then
          zellij --session "$home" action switch-session --pane-id "$pane" "$sess" || true
        else
          zellij action switch-session --pane-id "$pane" "$sess" || true
        fi
      fi
    else
      zellij action switch-session --pane-id "$pane" "$sess" || true
    fi
  fi
}
