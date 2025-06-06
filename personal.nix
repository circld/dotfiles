{ config, pkgs, lib, ... }:
{
  imports = (import ./core.nix { inherit config pkgs; });

  home.username = "paul.grow";
  home.homeDirectory = "/Users/paul.grow";
}
