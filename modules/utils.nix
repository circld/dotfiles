{ config, pkgs, ... }:
let
  collectModules =
    dir:
    builtins.concatLists (
      builtins.attrValues (
        builtins.mapAttrs (
          basename: type:
          let
            path = "${dir}/${basename}";
          in
          if type == "regular" && builtins.match ".*\\.nix$" basename != null then
            [ path ]
          else if type == "directory" then
            collectModules path
          else
            [ ]
        ) (builtins.readDir dir)
      )
    );
in
collectModules
