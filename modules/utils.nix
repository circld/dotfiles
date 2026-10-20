{ config, pkgs, ... }:
let
  dotfiles = "${config.home.homeDirectory}/dotfiles";
  ln = file: config.lib.file.mkOutOfStoreSymlink "${dotfiles}/${file}";
  collectModules =
    dir:
    if builtins.pathExists dir then
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
      )
    else
      [ ];
in
{
  inherit collectModules ln;
}
