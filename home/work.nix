{ config, pkgs, ... }:
let
  importModules = import ../modules/utils.nix { inherit config pkgs; };
  managedModules = importModules ../modules/shared;
  exclusiveModules = importModules ../modules/work;
  sharedGit = import ../modules/shared/git.nix { inherit config pkgs; };
  common = import ../modules/common.nix { inherit config pkgs; };
in
{
  # expects list of module paths
  imports =
    [ ../modules/common.nix ]
    ++ (builtins.map (mod: import mod) managedModules)
    ++ (builtins.map (mod: import mod) exclusiveModules);

  home.username = "paul.garaud";
  home.homeDirectory = "/Users/paul.garaud";

  home.sessionVariables = common.home.sessionVariables // {
    # TODO to add
  };

  programs.git = sharedGit.programs.git // {
    userEmail = "paul.garaud@octanelending.com";
    userName = "paulgrow-octane";
  };
}
