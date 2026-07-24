#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="${AGENT_FLEET_STATE_DIR:-$HOME/.local/state/agent-fleet}"
ARG="${1:-}"

# -- action: build "cwd<TAB>session<TAB>terminal_<id>" for every live OPENCODE pane, once --
live_panes() {
  while IFS= read -r sess; do
    [ -n "$sess" ] || continue
    zellij --session "$sess" action list-panes --json --all 2>/dev/null \
      | jq -r --arg sess "$sess" \
          '.[] | select(.is_plugin==false and .pane_command=="opencode" and (.pane_cwd // "") != "")
           | "\(.pane_cwd)\t\($sess)\tterminal_\(.id)"'
  done < <(zellij list-sessions -s 2>/dev/null)
}

# -- calculation: resolve (session, pane) for a target cwd from the live-pane table --
resolve_live() {
  local want_cwd="$1" table="$2"
  awk -F '\t' -v c="$want_cwd" '$1==c {print $2 "\t" $3; exit}' <<< "$table"
}

# -- calculation: ordered list of needs-attention cwds, newest ts first --
red_cwds_newest_first() {
  for f in "$STATE_DIR"/*.json; do
    [ -e "$f" ] || continue
    obj=$(jq -c '.' "$f" 2>/dev/null) || continue
    [ "$(jq -r '.state' <<< "$obj")" = "needs-attention" ] || continue
    printf '%s\t%s\n' "$(jq -r '.ts // 0' <<< "$obj")" "$(jq -r '.cwd' <<< "$obj")"
  done | sort -t $'\t' -k1,1nr | cut -f2-
}

live_table="$(live_panes)"

target_session=""
target_pane=""
if [ -n "$ARG" ]; then
  IFS=$'\t' read -r target_session target_pane < <(resolve_live "$ARG" "$live_table") || true
  if [ -z "$target_session" ]; then
    echo "no live zellij pane found with cwd=$ARG" >&2
    exit 1
  fi
else
  while IFS= read -r cwd; do
    [ -n "$cwd" ] || continue
    IFS=$'\t' read -r target_session target_pane < <(resolve_live "$cwd" "$live_table") || true
    [ -n "$target_session" ] && break
  done < <(red_cwds_newest_first)
  if [ -z "$target_session" ]; then
    echo "no live agent needs attention (all red state files are stale/ghosts)" >&2
    exit 1
  fi
fi

# -- axis 1: OS/aerospace — raise the dev workspace (works detached) --
aerospace workspace 1 || true

# Focus the matched pane. switch-session --pane-id is a NO-OP when the target
# session equals the client's current session, so branch:
if [ "$target_session" = "${ZELLIJ_SESSION_NAME:-}" ]; then
  zellij action focus-pane-id "$target_pane"
else
  zellij action switch-session --pane-id "$target_pane" "$target_session"
fi
