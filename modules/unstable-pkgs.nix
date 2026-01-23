{ pkgs }:
import
  (builtins.fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/nixpkgs-unstable.tar.gz";
  })
  {
    system = pkgs.system;
    config.allowUnfree = true;
    config.allowBroken = true;
  }
