#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="${AGENT_FLEET_STATE_DIR:-$HOME/.local/state/agent-fleet}"
MODEL="${AGENT_FLEET_MODEL:-$SCRIPT_DIR/agent-fleet-model.mjs}"

# shellcheck source=agent-fleet-act.sh
. "$SCRIPT_DIR/agent-fleet-act.sh"

if (( BASH_VERSINFO[0] < 4 )); then
  echo "agent-fleet-jump: needs bash >= 4 (got $BASH_VERSION); ensure ~/.nix-profile/bin is on PATH" >&2
  exit 1
fi

emit_decision() {
  echo "$@"
  echo "$@" >&2
}

# === Pin shell time exactly. AGENT_FLEET_NOW_MS is the override seam used by
# the reconcile stale-P 2s window tests; against the real clock a fixed fixture
# ts is always ancient and the within-window branch is untestable. ===
now_ms="${AGENT_FLEET_NOW_MS:-$(($(date +%s) * 1000))}"

json="$(node "$MODEL")"

# === Derive P (the model cursor) ===
# P = MAX(selectedTs) across live instances, restricted to entries carrying
# both selectedSid AND numeric selectedTs. Instances whose state file
# predates the envelope fields drop here — P is undeterminable in that case.
P_json="$(jq -c '
  [ .instances[]
    | select((.selectedSid != null) and (.selectedTs != null)
             and ((.selectedTs | type) == "number")) ]
  | if length > 0
      then (max_by(.selectedTs) | {sid: .selectedSid, ts: .selectedTs})
      else null
    end
' <<<"$json")"

# === Read stack + reconcile BEFORE classifying the outcome ===
# Reconcile runs on every model-touching press (jump, traverse, board Enter);
# early-exit on noop/warn still persists the reconciled mutation (per plan
# step 4: "Call `stack_write` before every early exit, including noop/warn").
stack="$(stack_read)"
stack="$(stack_reconcile "$P_json" "$now_ms" <<<"$stack")"

# === Apply the new-navigation mutation for a select kind landing. ===
# Removes target from both stacks, MRU-pushes old current (no-op when null),
# clears forward, and stamps current with now_ms (post-reconcile). Caller is
# responsible for stack_write after this returns.
_apply_select_nav() {
  stack="$(jq --arg target "$1" --argjson now_ms "$now_ms" '
    . as $s
    | .back |= ((map(select(. != $target))) +
                (if ($s.current != null) and ($s.current.sid != $target)
                   then [$s.current.sid]
                   else [] end))
    | .forward |= map(select(. != $target))
    | .forward |= []
    | .current = {sid: $target, ts: $now_ms}
  ' <<<"$stack")"
}

requested_cwd="${1:-}"

# === Explicit cwd arm ===
if [ -n "$requested_cwd" ]; then
  if jq -e --arg cwd "$requested_cwd" '.ambiguous | index($cwd)' <<<"$json" >/dev/null; then
    echo "multiple opencode instances found for cwd=${requested_cwd}; use one opencode instance with multiple chat sessions" >&2
    emit_decision "DECISION:kind=warn-explicit-duplicate"
    stack_write "$stack"
    exit 0
  fi

  pane_row="$(jq -r --arg cwd "$requested_cwd" '.live[]? | select(.cwd == $cwd) | [.session, .pane, .tabId] | @tsv' <<<"$json" | head -n 1 || true)"
  if [ -z "$pane_row" ]; then
    emit_decision "DECISION:kind=noop"
    stack_write "$stack"
    exit 0
  fi
  IFS=$'\t' read -r sess pane tab <<<"$pane_row"
  top="$(jq -r --arg cwd "$requested_cwd" '[.actionable[] | select(.cwd == $cwd)][0] // empty | [.key, (.sid // "")] | @tsv' <<<"$json")"
  if [ -n "$top" ]; then
    IFS=$'\t' read -r key sid <<<"$top"
    if [ -n "$sid" ]; then
      emit_decision "DECISION:kind=select cwd=${requested_cwd} session=${sess} pane=${pane} tab_id=${tab} key=${key} sid=${sid}"
      _apply_select_nav "$sid"
      ACTION_KIND="select"
      stack_write "$stack"
      act_land "$key" "$sid" "$sess" "$pane" "$tab"
      exit 0
    fi
    emit_decision "DECISION:kind=focus-only cwd=${requested_cwd} session=${sess} pane=${pane} tab_id=${tab}"
    stack_write "$stack"
    act_land "" "" "$sess" "$pane" "$tab"
    exit 0
  fi
  emit_decision "DECISION:kind=focus-only cwd=${requested_cwd} session=${sess} pane=${pane} tab_id=${tab}"
  stack_write "$stack"
  act_land "" "" "$sess" "$pane" "$tab"
  exit 0
fi

# === Global jump arm ===
top="$(jq -r '.actionable[0] // empty | [.cwd, .session, .pane, .tabId, .key, (.sid // "")] | @tsv' <<<"$json")"
if [ -n "$top" ]; then
  IFS=$'\t' read -r cwd sess pane tab key sid <<<"$top"
  if [ -n "$sid" ]; then
    emit_decision "DECISION:kind=select cwd=${cwd} session=${sess} pane=${pane} tab_id=${tab} key=${key} sid=${sid}"
    _apply_select_nav "$sid"
    ACTION_KIND="select"
    stack_write "$stack"
    act_land "$key" "$sid" "$sess" "$pane" "$tab"
    exit 0
  fi
  emit_decision "DECISION:kind=focus-only cwd=${cwd} session=${sess} pane=${pane} tab_id=${tab}"
  stack_write "$stack"
  act_land "" "" "$sess" "$pane" "$tab"
  exit 0
fi

fallback="$(jq -r '
  . as $m
  | [.live[]? | select((.pane | test("^terminal_[0-9]+$")) and (.cwd as $cwd | ($m.ambiguous | index($cwd)) == null))]
  | sort_by(.pane | sub("^terminal_"; "") | tonumber)
  | last // empty
  | [.session, .pane, .tabId] | @tsv
' <<<"$json")"
if [ -n "$fallback" ]; then
  IFS=$'\t' read -r sess pane tab <<<"$fallback"
  emit_decision "DECISION:kind=fallback-pane session=${sess} pane=${pane} tab_id=${tab}"
  stack_write "$stack"
  act_land "" "" "$sess" "$pane" "$tab"
  exit 0
fi

emit_decision "DECISION:kind=noop"
stack_write "$stack"
