{ config, pkgs, ... }:
let
  importModules = import ../modules/utils.nix { inherit config pkgs; };
  managedModules = importModules ../modules/shared;
  exclusiveModules = importModules ../modules/personal;
  sharedGit = import ../modules/shared/git.nix { inherit config pkgs; };
in
{
  # expects list of module paths
  imports =
    [ ../modules/common.nix ]
    ++ (builtins.map (mod: import mod) managedModules)
    ++ (builtins.map (mod: import mod) exclusiveModules);

  home.username = "paul.grow";
  home.homeDirectory = "/Users/paul.grow";

  programs.git = sharedGit.programs.git // {
    userEmail = "circld1@gmail.com";
    userName = "circld";
  };
}
