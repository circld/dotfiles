{ config, pkgs, ... }:
let
  dotfiles = "${config.home.homeDirectory}/dotfiles";
  ln = file: config.lib.file.mkOutOfStoreSymlink "${dotfiles}/${file}";
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
{
  inherit collectModules ln;
}
