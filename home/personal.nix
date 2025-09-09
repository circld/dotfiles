{ config, pkgs, ... }:
let
  importModules = import ../modules/utils.nix { inherit config pkgs; };
  managedModules = importModules ../modules/packages;
  exclusiveModules = importModules ../modules/personal/packages;
  common = import ../modules/common.nix { inherit config pkgs; };
in
{
  # expects list of module paths
  imports =
    [ ../modules/common.nix ]
    ++ (builtins.map (mod: import mod) managedModules)
    ++ (builtins.map (mod: import mod) exclusiveModules);

  home.username = "paul.grow";
  home.homeDirectory = "/Users/paul.grow";

  home.packages = common.home.packages ++ [
    pkgs.ffmpeg
  ];
}
