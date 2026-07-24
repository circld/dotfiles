function agent-fleet-board --description 'open (or focus) the agent-fleet board tab in the notes zellij session'
  # ponytail: manual invocation, not auto-started on session create.
  # Upgrade to a zellij layout file (`programs.zellij` has no
  # per-session-start hook) if daily auto-start becomes worth it.
  # Guards: create notes if absent, and don't stack a duplicate board
  # tab. Both make the daily-reboot / run-twice paths safe; a bare
  # new-tab call handles neither.

  # 1. bootstrap notes if it isn't running (rc=1 "Session 'notes' not found" otherwise)
  if not zellij list-sessions -s 2>/dev/null | grep -qx notes
    zellij attach --create-background notes
  end

  # 2. dedup: new-tab is not idempotent — a second call stacks another
  #    fleet-board tab + a second render loop. Skip if the tab exists.
  if zellij --session notes action query-tab-names 2>/dev/null | grep -qx fleet-board
    echo "fleet-board tab already exists in notes"
    return 0
  end

  # 3. create the tab. Run the script directly (its #!/usr/bin/env bash
  #    shebang picks the Nix bash on PATH); do NOT wrap in `bash -lc`,
  #    which could resolve to macOS /bin/bash 3.2 and break the assoc-array render.
  zellij --session notes action new-tab --name fleet-board -- \
    ~/dotfiles/scripts/agent-fleet-board.sh
end
