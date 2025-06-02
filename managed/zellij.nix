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
        # reserve Ctrl G for neovim
        unbind = [ "Ctrl g" ];
        normal = binds {
          "Ctrl f" = { ToggleFocusFullscreen = []; };
          "Ctrl b" = { SwitchToMode = "locked"; };
        }
        # conflict w/ghostty + fish workaround
        # see external/fish/functions/fish_user_key_bindings.fish
        //
        unbinds [
          "Alt f"
        ];
        locked = binds {
          "Ctrl b" = { SwitchToMode = "normal"; };
        };
      };
    };
  };
}
