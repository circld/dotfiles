{
  pkgs,
  config,
  ...
}:
{
  programs.aerospace = {
    enable = true;
    # https://nikitabobko.github.io/AeroSpace/guide#default-config
    userSettings = {
      start-at-login = true;
      mode.main.binding = {
        # nav
        ctrl-shift-h = "focus left";
        ctrl-shift-j = "focus down";
        ctrl-shift-k = "focus up";
        ctrl-shift-l = "focus right";
        # moving
        ctrl-alt-shift-h = "move left";
        ctrl-alt-shift-j = "move down";
        ctrl-alt-shift-k = "move up";
        ctrl-alt-shift-l = "move right";
        # resizing
        ctrl-alt-shift-minus = "resize smart -50";
        ctrl-alt-shift-equal = "resize smart +50";
        # workspaces
        ctrl-1 = "workspace 1";
        ctrl-2 = "workspace 2";
        ctrl-3 = "workspace 3";
        ctrl-alt-shift-1 = "move-node-to-workspace 1";
        ctrl-alt-shift-2 = "move-node-to-workspace 2";
        ctrl-alt-shift-3 = "move-node-to-workspace 3";
      };
    };
  };
}
