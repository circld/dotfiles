#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="${AGENT_FLEET_STATE_DIR:-$HOME/.local/state/agent-fleet}"
MODEL="${AGENT_FLEET_MODEL:-$SCRIPT_DIR/agent-fleet-model.mjs}"

if (( BASH_VERSINFO[0] < 4 )); then
  echo "agent-fleet-jump: needs bash >= 4 (got $BASH_VERSION); ensure ~/.nix-profile/bin is on PATH" >&2
  exit 1
fi

_atomic_write_select() {
  local target="$1" sid="$2"
  local tmp="${target}.tmp.$$"
  printf '{\n  "sessionID": "%s"\n}\n' "$sid" > "$tmp"
  mv "$tmp" "$target"
}

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
      zellij action go-to-tab-by-id "$tab" || true
      zellij action focus-pane-id "$pane" || true
    else
      zellij action switch-session --pane-id "$pane" "$sess" || true
    fi
  fi
}

emit_decision() {
  echo "$@"
  echo "$@" >&2
}

json="$(node "$MODEL")"
requested_cwd="${1:-}"

if [ -n "$requested_cwd" ]; then
  if jq -e --arg cwd "$requested_cwd" '.ambiguous | index($cwd)' <<<"$json" >/dev/null; then
    echo "multiple opencode instances found for cwd=${requested_cwd}; use one opencode instance with multiple chat sessions" >&2
    emit_decision "DECISION:kind=warn-explicit-duplicate"
    exit 0
  fi

  pane_row="$(jq -r --arg cwd "$requested_cwd" '.live[]? | select(.cwd == $cwd) | [.session, .pane, .tabId] | @tsv' <<<"$json" | head -n 1 || true)"
  if [ -z "$pane_row" ]; then
    emit_decision "DECISION:kind=noop"
    exit 0
  fi
  IFS=$'\t' read -r sess pane tab <<<"$pane_row"
  top="$(jq -r --arg cwd "$requested_cwd" '[.actionable[] | select(.cwd == $cwd)][0] // empty | [.key, (.sid // "")] | @tsv' <<<"$json")"
  if [ -n "$top" ]; then
    IFS=$'\t' read -r key sid <<<"$top"
    if [ -n "$sid" ]; then
      emit_decision "DECISION:kind=select cwd=${requested_cwd} session=${sess} pane=${pane} tab_id=${tab} key=${key} sid=${sid}"
      ACTION_KIND="select"
      ACTION_SELECT_PATH="$STATE_DIR/${key}.select"
      ACTION_SELECT_SID="$sid"
    else
      emit_decision "DECISION:kind=focus-only cwd=${requested_cwd} session=${sess} pane=${pane} tab_id=${tab}"
      ACTION_KIND="focus-only"
    fi
  else
    emit_decision "DECISION:kind=focus-only cwd=${requested_cwd} session=${sess} pane=${pane} tab_id=${tab}"
    ACTION_KIND="focus-only"
  fi
  ACTION_TARGET_SESSION="$sess"
  ACTION_TARGET_PANE="$pane"
  ACTION_TARGET_TAB="$tab"
  goto_act
  exit $?
fi

top="$(jq -r '.actionable[0] // empty | [.cwd, .session, .pane, .tabId, .key, (.sid // "")] | @tsv' <<<"$json")"
if [ -n "$top" ]; then
  IFS=$'\t' read -r cwd sess pane tab key sid <<<"$top"
  if [ -n "$sid" ]; then
    emit_decision "DECISION:kind=select cwd=${cwd} session=${sess} pane=${pane} tab_id=${tab} key=${key} sid=${sid}"
    ACTION_KIND="select"
    ACTION_SELECT_PATH="$STATE_DIR/${key}.select"
    ACTION_SELECT_SID="$sid"
  else
    emit_decision "DECISION:kind=focus-only cwd=${cwd} session=${sess} pane=${pane} tab_id=${tab}"
    ACTION_KIND="focus-only"
  fi
  ACTION_TARGET_SESSION="$sess"
  ACTION_TARGET_PANE="$pane"
  ACTION_TARGET_TAB="$tab"
  goto_act
  exit $?
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
  ACTION_KIND="fallback-pane"
  ACTION_TARGET_SESSION="$sess"
  ACTION_TARGET_PANE="$pane"
  ACTION_TARGET_TAB="$tab"
  goto_act
  exit $?
fi

emit_decision "DECISION:kind=noop"
