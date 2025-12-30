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
      default-root-container-layout = "accordion";
      default-root-container-orientation = "auto";
      automatically-unhide-macos-hidden-apps = true;
      mode.main.binding = {
        # nav
        ctrl-shift-h = "focus left";
        ctrl-shift-j = "focus down";
        ctrl-shift-k = "focus up";
        ctrl-shift-l = "focus right";
        alt-tab = "workspace-back-and-forth";
        # moving
        ctrl-alt-shift-h = "move left";
        ctrl-alt-shift-j = "move down";
        ctrl-alt-shift-k = "move up";
        ctrl-alt-shift-l = "move right";
        # resizing
        ctrl-alt-shift-minus = "resize smart -50";
        ctrl-alt-shift-equal = "resize smart +50";
        ctrl-alt-shift-f = "fullscreen";
        ctrl-alt-shift-leftSquareBracket = "layout v_accordion h_accordion";
        ctrl-alt-shift-rightSquareBracket = "layout v_tiles h_tiles";
        # workspaces
        ctrl-1 = "workspace 1";
        ctrl-2 = "workspace 2";
        ctrl-3 = "workspace 3";
        ctrl-4 = "workspace 4";
        ctrl-5 = "workspace 5";
        ctrl-6 = "workspace 6";
        ctrl-7 = "workspace 7";
        ctrl-8 = "workspace 8";
        ctrl-9 = "workspace 9";
        ctrl-alt-shift-1 = "move-node-to-workspace 1";
        ctrl-alt-shift-2 = "move-node-to-workspace 2";
        ctrl-alt-shift-3 = "move-node-to-workspace 3";
        ctrl-alt-shift-4 = "move-node-to-workspace 4";
        ctrl-alt-shift-5 = "move-node-to-workspace 5";
        ctrl-alt-shift-6 = "move-node-to-workspace 6";
        ctrl-alt-shift-7 = "move-node-to-workspace 7";
        ctrl-alt-shift-8 = "move-node-to-workspace 8";
        ctrl-alt-shift-9 = "move-node-to-workspace 9";
      };
      # sanity w/external monitors
      workspace-to-monitor-force-assignment = {
        "1" = "U2717D";
        "2" = "U2717D";
        "3" = "U2717D";
        "4" = "U2717D";
        "5" = "P2419H";
        "6" = "P2419H";
        "7" = "P2419H";
        "8" = "Retina Display";
        "9" = "Retina Display";
      };
    };
  };
}
