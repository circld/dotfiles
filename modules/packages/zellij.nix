{
  pkgs,
  config,
  lib,
  ...
}:
# workaround while home manager config -> kdl for keymaps gets hashed out
# https://github.com/nix-community/home-manager/issues/4659#issuecomment-2574906923
let
  binds =
    bindings:
    let
      bindStr = key: value: lib.attrsets.nameValuePair "bind \"${key}\"" value;
    in
    lib.attrsets.mapAttrs' bindStr bindings;
  unbinds =
    unbindList:
    let
      len = builtins.length unbindList;
      sub = lib.lists.sublist 0 (len - 1) unbindList;
    in
    {
      ${"unbind" + (lib.strings.concatStrings (lib.lists.map (x: " \"${x}\"") sub))} =
        lib.lists.last unbindList;
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
        "session" = binds {
          "w" = {
            "LaunchOrFocusPlugin \"session-manager\"" = {
              floating = true;
              move_to_focused_tab = true;
            };
            SwitchToMode = "locked";
          };
        };
        "normal clear-defaults=true" = binds {
          "Esc" = {
            SwitchToMode = "Locked";
          };
          "Backspace" = {
            SwitchToMode = "Locked";
          };
          "p" = {
            SwitchToMode = "Pane";
          };
          "t" = {
            SwitchToMode = "Tab";
          };
          "r" = {
            SwitchToMode = "Resize";
          };
          "s" = {
            SwitchToMode = "Session";
          };
        };
        "pane clear-defaults=true" = binds {
          "Esc" = {
            SwitchToMode = "Locked";
          };
          "Backspace" = {
            SwitchToMode = "Normal";
          };
          "h" = {
            MoveFocus = "Left";
          };
          "l" = {
            MoveFocus = "Right";
          };
          "j" = {
            MoveFocus = "Down";
          };
          "k" = {
            MoveFocus = "Up";
          };
          "Shift h" = {
            MovePane = "Left";
          };
          "Shift l" = {
            MovePane = "Right";
          };
          "Shift j" = {
            MovePane = "Down";
          };
          "Shift k" = {
            MovePane = "Up";
          };
          "n" = {
            NewPane = [ ];
          };
          "Alt j" = {
            NewPane = "Down";
          };
          "Alt l" = {
            NewPane = "Right";
          };
          "x" = {
            CloseFocus = [ ];
          };
          "f" = {
            ToggleFocusFullscreen = [ ];
          };
          "z" = {
            TogglePaneFrames = [ ];
          };
          "w" = {
            ToggleFloatingPanes = [ ];
          };
          "r" = {
            SwitchToMode = "RenamePane";
            PaneNameInput = 0;
          };
          "e" = {
            SwitchToMode = "RenamePane";
          };
          "p" = {
            TogglePanePinned = [ ];
          };
          "t" = {
            TogglePaneEmbedOrFloating = [ ];
          };
        };
        "tab clear-defaults=true" = binds {
          "Esc" = {
            SwitchToMode = "Locked";
          };
          "Backspace" = {
            SwitchToMode = "Normal";
          };
          "r" = {
            SwitchToMode = "RenameTab";
            TabNameInput = 0;
          };
          "e" = {
            SwitchToMode = "RenameTab";
          };
          "h" = {
            GoToPreviousTab = [ ];
          };
          "l" = {
            GoToNextTab = [ ];
          };
          "Shift h" = {
            MoveTab = "Left";
          };
          "Shift l" = {
            MoveTab = "Right";
          };
          "n" = {
            NewTab = [ ];
          };
          "x" = {
            CloseTab = [ ];
          };
          "s" = {
            ToggleActiveSyncTab = [ ];
          };
          "b" = {
            BreakPane = [ ];
          };
          "]" = {
            BreakPaneRight = [ ];
          };
          "[" = {
            BreakPaneLeft = [ ];
          };
          "1" = {
            GoToTab = 1;
          };
          "2" = {
            GoToTab = 2;
          };
          "3" = {
            GoToTab = 3;
          };
          "4" = {
            GoToTab = 4;
          };
          "5" = {
            GoToTab = 5;
          };
          "6" = {
            GoToTab = 6;
          };
          "7" = {
            GoToTab = 7;
          };
          "8" = {
            GoToTab = 8;
          };
          "9" = {
            GoToTab = 9;
          };
          "Tab" = {
            ToggleTab = [ ];
          };
        };
        "renamepane clear-defaults=true" = binds {
          "Enter" = {
            SwitchToMode = "Pane";
          };
          "Esc" = {
            UndoRenamePane = [ ];
            SwitchToMode = "Pane";
          };
        };
        "renametab clear-defaults=true" = binds {
          "Enter" = {
            SwitchToMode = "Tab";
          };
          "Esc" = {
            UndoRenameTab = [ ];
            SwitchToMode = "Tab";
          };
        };
        "locked clear-defaults=true" = binds {
          "Alt n" = {
            NewPane = [ ];
          };
          "Alt t" = {
            NewTab = [ ];
          };
          "Alt h" = {
            MoveFocusOrTab = "Left";
          };
          "Alt l" = {
            MoveFocusOrTab = "Right";
          };
          "Alt j" = {
            MoveFocus = "Down";
          };
          "Alt k" = {
            MoveFocus = "Up";
          };
          "Alt ]" = {
            NextSwapLayout = [ ];
          };
          "Alt [" = {
            PreviousSwapLayout = [ ];
          };
          "Alt =" = {
            Resize = "Increase";
          };
          "Alt -" = {
            Resize = "Decrease";
          };
          "Ctrl b" = {
            SwitchToMode = "normal";
          };
          "Ctrl f" = {
            ToggleFocusFullscreen = [ ];
          };
        };
        "shared_except \"locked\"" = binds {
          "Esc" = {
            SwitchToMode = "Locked";
          };
        };
        "shared_except \"normal\"" = binds {
          "Backspace" = {
            SwitchToMode = "Normal";
          };
        };
      };
    };
  };
}
