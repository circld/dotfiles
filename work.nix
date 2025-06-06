{ config, pkgs, lib, ... }:
{
  imports = (import ./core.nix { inherit config pkgs; });

  home.username = "paulgrow-octane";
  home.homeDirectory = "/Users/paul.garaud";
}
