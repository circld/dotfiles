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
      default_shell = "fish";
      mouse_mode = true;
      theme = "space-vim-dark";
      keybinds = {
        normal = binds {
          "Ctrl f" = { ToggleFocusFullscreen = []; };
        }
        # conflict w/ghostty + fish workaround
        # see external/fish/functions/fish_user_key_bindings.fish
        // unbinds [ "Alt f" ];
      };
    };
    themes = {
      "space-vim-dark" = ''
        themes {
          space-vim-dark {
            bg "#262626"
            fg "#d358d5"
            red "#262626"
            green "#af87d7"
            blue "#4083cd"
            yellow "#e89e0f"
            magenta "#4083cd"
            orange "#d358d5"
            cyan "#22abbb"
            black "#262626"
            white "#b2b2b2"
          }
        }
        '';
    };
  };
}
