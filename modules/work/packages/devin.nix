{ pkgs, ... }:
# Devin CLI (https://cli.devin.ai). Nix-packaged from the prebuilt tarball so
# the curl|bash installer never touches ~/.local. To upgrade: bump `version`,
# then pull new sha256s from
#   curl -fsSL https://static.devin.ai/cli/current/manifest.json
# Self-update via `devin update` will fight the nix store; don't.
let
  version = "3000.4.25";
  sources = {
    aarch64-darwin = {
      target = "aarch64-apple-darwin";
      sha256 = "7b3ea98d2f50defde532c870009d77d4c72d711e97cd8c31fb8b4edb3a72792c";
    };
    x86_64-darwin = {
      target = "x86_64-apple-darwin";
      sha256 = "00b138492a0f844ec4e0c141ad33ae879153c00f27413d2d225a49b4d932f1f4";
    };
  };
  src = sources.${pkgs.stdenv.hostPlatform.system};
  devin = pkgs.stdenvNoCC.mkDerivation {
    pname = "devin";
    inherit version;
    src = pkgs.fetchurl {
      url = "https://static.devin.ai/cli/${version}/devin-${version}-${src.target}.tar.gz";
      inherit (src) sha256;
    };
    sourceRoot = "."; # tarball has bin/ + share/ at top level
    dontFixup = true; # prebuilt signed Mach-O; stripping/re-signing can break it
    installPhase = ''
      mkdir -p $out
      cp -r bin share $out/
    '';
  };
in
{
  home.packages = [ devin ];
}
