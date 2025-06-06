{
  pkgs,
  config,
  lib,
  ...
}:
# workaround while home manager config -> kdl for keymaps gets hashed out
# https://github.com/nix-community/home-manager/issues/4659#issuecomment-2574906923
let
  binds = bindings:
    let
      bindStr = key: value: lib.attrsets.nameValuePair "bind \"${key}\"" value;
    in
      lib.attrsets.mapAttrs' bindStr bindings;
  unbinds = unbindList:
    let
      len = builtins.length unbindList;
      sub = lib.lists.sublist 0 (len - 1) unbindList;
    in {
      ${"unbind" + (lib.strings.concatStrings (lib.lists.map (x: " \"${x}\"") sub))} = lib.lists.last unbindList;
    };
in
{
  programs.zellij = {
    enable = true;
    # https://zellij.dev/documentation/configuration.html
    settings = {
      default_mode = "locked";
      default_shell = "fish";
      mouse_mode = true;
      theme = "space-vim-dark";
      # defaults: https://github.com/zellij-org/zellij/blob/main/zellij-utils/assets/config/default.kdl
      keybinds = {
        "normal clear-defaults=true" = binds {
          "Esc" = { SwitchToMode = "locked"; };
          "p" = { SwitchToMode = "pane"; };
          "t" = { SwitchToMode = "tab"; };
          "r" = { SwitchToMode = "resize"; };
          "m" = { SwitchToMode = "move"; };
          "s" = { SwitchToMode = "session"; };
        };
        "pane clear-defaults=true" = binds {
          "Esc" = { SwitchToMode = "Normal"; };
          "Alt h" = { MoveFocus = "Left"; };
          "Alt l" = { MoveFocus = "Right"; };
          "Alt j" = { MoveFocus = "Down"; };
          "Alt k" = { MoveFocus = "Up"; };
          "n" = { NewPane = []; };
          "j" = { NewPane = "Down"; };
          "l" = { NewPane = "Right"; };
          "x" = { CloseFocus = []; };
          "f" = { ToggleFocusFullscreen = []; };
          "z" = { TogglePaneFrames = []; };
          "w" = { ToggleFloatingPanes = []; };
          "e" = { TogglePaneEmbedOrFloating = []; };
          "r" = { SwitchToMode = "RenamePane"; };
          "p" = { TogglePanePinned = []; };
        };
        "locked clear-defaults=true" = binds {
          "Alt n" = { NewPane = []; };
          "Alt t" = { NewTab = []; };
          "Alt h" = { MoveFocusOrTab = "Left"; };
          "Alt l" = { MoveFocusOrTab = "Right"; };
          "Alt j" = { MoveFocus = "Down"; };
          "Alt k" = { MoveFocus = "Up"; };
          "Alt ]" = { NextSwapLayout = []; };
          "Alt [" = { PreviousSwapLayout = []; };
          "Alt =" = { Resize = "Increase"; };
          "Alt -" = { Resize = "Decrease"; };
          "Ctrl b" = { SwitchToMode = "normal"; };
          "Ctrl f" = { ToggleFocusFullscreen = []; };
        };
      };
    };
  };
}
