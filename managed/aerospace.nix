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
        ctrl-shift-h = "focus left";
        ctrl-shift-j = "focus down";
        ctrl-shift-k = "focus up";
        ctrl-shift-l = "focus right";
        ctrl-alt-shift-h = "move left";
        ctrl-alt-shift-j = "move down";
        ctrl-alt-shift-k = "move up";
        ctrl-alt-shift-l = "move right";
      };
    };
  };
}
