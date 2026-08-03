#!/usr/bin/env bash
# scripts/agent-fleet-traverse.sh
#
# Alt-, (prev) / Alt-. (next) traversal of the agent-fleet traverse stack.
# Reconciles the model cursor on every press, then pops MRU back[] / LIFO
# forward[] in the requested direction, with skip-retain semantics for
# unlandable (ambiguous-cwd) entries and dead-prune for entries absent from
# every live instance. Empty direction falls back to the position-based scan of
# timeline.viewed[] / timeline.pending[] (docs/agent-fleet-jump-spec.md §Action semantics).
#
# Test seams (act layer):
#   AGENT_FLEET_DECIDE_ONLY=1   emit decision only; no mailbox, no stack write
#   AGENT_FLEET_DECIDE_ACT=1    write stack + mailbox; skip aerospace/zellij
#   AGENT_FLEET_MESSAGE_DELAY=N  user-visible linger seconds (1 in prod, 0 in tests)
#   AGENT_FLEET_NOW_MS=N        pin wall-clock ms (so stale-P window tests are deterministic)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="${AGENT_FLEET_STATE_DIR:-$HOME/.local/state/agent-fleet}"
MODEL="${AGENT_FLEET_MODEL:-$SCRIPT_DIR/agent-fleet-model.mjs}"
MESSAGE_DELAY="${AGENT_FLEET_MESSAGE_DELAY:-1}"

# shellcheck source=agent-fleet-act.sh
. "$SCRIPT_DIR/agent-fleet-act.sh"

if (( BASH_VERSINFO[0] < 4 )); then
  echo "agent-fleet-traverse: needs bash >= 4 (got $BASH_VERSION); ensure ~/.nix-profile/bin is on PATH" >&2
  exit 1
fi

# DECIDE_ONLY is a "see what would happen" seam — must be free of filesystem
# side effects (no mkdir, no writes). Writers in act.sh self-guard the same way.
if [ "${AGENT_FLEET_DECIDE_ONLY:-0}" != "1" ]; then
  mkdir -p "$STATE_DIR"
fi

cmd="${1:-}"
case "$cmd" in
  prev|next) : ;;
  *)
    echo "usage: agent-fleet-traverse.sh {prev|next}" >&2
    exit 2
    ;;
esac

emit_decision() {
  local line="$*"
  [ -n "${AF_REQUEST_ID:-}" ] && line="$line req=${AF_REQUEST_ID}"
  echo "$line"
  echo "$line" >&2
  echo "$line" | af_trace decision.txt
}

now_ms="${AGENT_FLEET_NOW_MS:-$(($(date +%s) * 1000))}"
if [ -n "${AGENT_FLEET_TRACE_DIR:-}" ]; then
  AF_REQUEST_ID="${AF_REQUEST_ID:-${now_ms}-$$}"
  export AF_REQUEST_ID
fi
source_session="${ZELLIJ_SESSION_NAME:-}"

# === Run model FIRST so empty-live guard fires before any stack mutation. ===
json="$(node "$MODEL")"
af_trace model.json <<<"$json"
if [ "$(jq '.live | length' <<<"$json")" = "0" ]; then
  msg="traverse: no live agents (zellij down or none running)"
  echo "$msg"
  echo "$msg" >&2
  sleep "$MESSAGE_DELAY" 2>/dev/null || true
  exit 1
fi

# === Derive P — physical-source-session preference, global-max fallback
#     (see stack_derive_p in act.sh; same call in jump.sh and board.sh). ===
P_json="$(stack_derive_p "$source_session" <<<"$json")"

# === Reconcile before classifying outcome (reconcile-on-every-press). ===
stack="$(stack_read)"
af_trace stack-pre.json <<<"$stack"
stack="$(stack_reconcile "$P_json" "$now_ms" <<<"$stack")"

# === Decision transform (inlined jq).
# Output shape: { decision, target_sid, new_state } ===
action_json="$(
  jq -c --arg direction "$cmd" --arg source_session "$source_session" --argjson now_ms "$now_ms" --argjson stack "$stack" '
    def classify(sid; landable; live; amb):
      if   (landable | index(sid)) != null then "landable"
      elif (amb      | index(sid)) != null then "ambiguous"
      elif (live     | index(sid)) != null then "ambiguous"
      else "dead"
      end;
    . as $model
    | $stack as $s
    | $s.current as $cur
    | ([.live[] | select(.session == $source_session)] | length > 0) as $source_has_agent
    | ([.rows[] | select(.sid != null) | .sid] | unique)              as $landable
    | ([.instances[] | .sessions[]] | unique)                          as $live
    | ([.ambiguous[]] | unique)                                        as $amb_cwds
    | ([.instances[]
        | select(([.cwd] | inside($amb_cwds)))
        | .sessions[]] | unique)                                        as $amb
     | if ($direction == "next")
           and ($source_session != "")
           and ($source_has_agent == false)
           and ($cur != null)
           and ((classify($cur.sid; $landable; $live; $amb)) == "landable") then
         {decision: "select", target_sid: $cur.sid, new_state: $s}
     elif $direction == "prev" then
        # === Walk back[] end→start: dead-prune, skip-retain unlandable, stop on landable.
        # (Same shape used in the next branch below for forward[] walking — duplicated
        # deliberately because the per-branch new_state updates diverge after the walk
        # finishes: back-pop drops backward entries from $s.back AND mutates $s.forward,
        # forward-pop drops backward entries from $s.forward AND uses back-push-mru on $s.back.
        # Not enough call sites yet to factor out a walk helper.)
        reduce range(($s.back | length) - 1; -1; -1) as $i (
          {target: null, retained_unlandable: [], dropped: []};
          if .target != null then .
          else . as $st
            | ($s.back[$i]) as $entry
            | (classify($entry; $landable; $live; $amb)) as $c
            | if   $c == "landable"  then $st + {target: $entry}
              elif $c == "ambiguous" then $st + {retained_unlandable: ($st.retained_unlandable + [$entry])}
              else                       $st + {dropped: ($st.dropped + [$entry])}
              end
          end
        ) as $walk
        | if $walk.target != null then
            # The walk stops at the LAST occurrence of target (we walked end→start).
            # Find that LAST index so pre_target = back[0:i] keeps all entries before
            # the popped target (and removes only later duplicates if any).
            (($s.back | map(. == $walk.target)) | to_entries | map(select(.value)) | max_by(.key) | .key) as $tgt_idx
            | ($s.back | .[0:$tgt_idx]) as $pre_target
            | {
                decision: "select",
                target_sid: $walk.target,
                new_state: (
                  $s
                  | .current = {sid: $walk.target, ts: $now_ms}
                  # forward.push(current_old); current-removal invariant.
                  | .forward = (($s.forward + [$cur.sid] | map(select(. != null and . != $walk.target))))
                  # back = pre_target prefix + retained_unlandable reversed to MRU order.
                  | .back = (($pre_target + ($walk.retained_unlandable | reverse)) | map(select(. != $walk.target)))
                )
              }
          else
            ($s | .back = ($walk.retained_unlandable | reverse | map(select(. != null)))) as $s_pruned
            | ($model.timeline.viewed) as $viewed
            | (
                if ($cur.sid != null) and ([$cur.sid] | inside([$viewed[] | .sid]))
                then ([$viewed[] | .sid] | index($cur.sid)) + 1
                else 0
                end
              ) as $start
            | reduce range($start; ($viewed | length)) as $j (
                {target: null};
                if .target != null then .
                else . as $st
                  | ($viewed[$j].sid) as $e
                  | if (classify($e; $landable; $live; $amb)) == "landable"
                    then $st + {target: $e} else $st end
                end
              ) as $vw
            | if $vw.target != null then
                {
                  decision: "select",
                  target_sid: $vw.target,
                  new_state: (
                    $s_pruned
                    | .current = {sid: $vw.target, ts: $now_ms}
                    | .forward = (($s_pruned.forward + [($cur.sid // $vw.target)]) | map(select(. != null and . != $vw.target)))
                    | .back = ($s_pruned.back | map(select(. != $vw.target)))
                  )
                }
              else
                { decision: "at-end", target_sid: null, new_state: $s_pruned }
              end
          end
    else
      # === Walk forward[] end→start. See prev branch above for duplication rationale.
      reduce range(($s.forward | length) - 1; -1; -1) as $i (
        {target: null, retained_unlandable: [], dropped: []};
        if .target != null then .
        else . as $st
          | ($s.forward[$i]) as $entry
          | (classify($entry; $landable; $live; $amb)) as $c
          | if   $c == "landable"  then $st + {target: $entry}
            elif $c == "ambiguous" then $st + {retained_unlandable: ($st.retained_unlandable + [$entry])}
            else                       $st + {dropped: ($st.dropped + [$entry])}
            end
        end
      ) as $walk
      | if $walk.target != null then
          # See prev branch — use LAST occurrence since walk is end→start.
          (($s.forward | map(. == $walk.target)) | to_entries | map(select(.value)) | max_by(.key) | .key) as $tgt_idx
          | ($s.forward | .[0:$tgt_idx]) as $pre_target
          | {
              decision: "select",
              target_sid: $walk.target,
              new_state: (
                $s
                | .current = {sid: $walk.target, ts: $now_ms}
                | .forward = (
                    ($pre_target + ($walk.retained_unlandable | reverse))
                    | map(select(. != $walk.target))
                  )
                | .back |= (
                    (map(select((. != $walk.target) and (. != $cur.sid))) +
                     (if ($cur != null) and ($cur.sid != $walk.target)
                        then [$cur.sid] else [] end))
                  )
              )
            }
        else
          ($s | .forward = ($walk.retained_unlandable | reverse)) as $s_pruned
          | (
              [ $model.timeline.pending[]
                | select(.sid != null)
                | select(.sid != $cur.sid) ]
              | first // null
            ) as $hit
          | if $hit != null then
              {
                decision: "select",
                target_sid: $hit.sid,
new_state: (
                  $s_pruned
                  | .current = {sid: $hit.sid, ts: $now_ms}
                  | .forward = []
                  | .back |= (
                      (map(select((. != $hit.sid) and (. != $cur.sid))) +
                       (if ($cur != null) and ($cur.sid != $hit.sid)
                          then [$cur.sid] else [] end) +
                       ($walk.retained_unlandable | map(select(. != $hit.sid))))
                    )
                  )
                }
            else
              { decision: "at-end", target_sid: null, new_state: $s_pruned }
            end
        end
    end
  ' <<<"$json"
)"
af_trace action.json <<<"$action_json"

# === Dispatch ===
decision="$(jq -r .decision <<<"$action_json")"
if [ "$decision" = "at-end" ]; then
  emit_decision "DECISION:kind=at-end"
  stack="$(jq -c .new_state <<<"$action_json")"
  stack_write "$stack"
  sleep "$MESSAGE_DELAY" 2>/dev/null || true
  exit 0
fi

target_sid="$(jq -r .target_sid <<<"$action_json")"
target_row="$(jq -c --arg sid "$target_sid" '
  ([.rows[] | select(.sid == $sid)] | first | {key, session, pane, tabId, cwd, title})
' <<<"$json")"

key="$(jq -r .key <<<"$target_row")"
sess="$(jq -r .session <<<"$target_row")"
pane="$(jq -r .pane <<<"$target_row")"
tab="$(jq -r .tabId <<<"$target_row")"
target_cwd="$(jq -r .cwd <<<"$target_row")"
title="$(jq -r '.title // empty' <<<"$target_row")"

emit_decision "DECISION:kind=select cwd=$target_cwd session=$sess pane=$pane tab_id=$tab key=$key sid=$target_sid"

stack="$(jq -c .new_state <<<"$action_json")"
stack_write "$stack"
act_land "$key" "$target_sid" "$sess" "$pane" "$tab" "$title"
