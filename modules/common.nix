{
  config,
  pkgs,
  lib,
  ...
}:
let
  utils = import ./utils.nix { inherit config pkgs; };
  ln = utils.ln;
  unstablePkgs = import ./unstable-pkgs.nix { inherit pkgs; };

  # caveman (https://github.com/JuliusBrussee/caveman) is referenced by absolute
  # path from opencode/opencode.json but isn't fetched by Nix (no fixed-output
  # hash available) — activation clones/pins it into ~/code/caveman instead.
  # Skips silently if that path is already a dirty/non-caveman checkout, so it
  # never clobbers local hacking on the clone.
  cavemanCheckoutDir = "${config.home.homeDirectory}/code/caveman";
  cavemanRev = "v1.9.1";
in
{
  # You should not change this value, even if you update Home Manager. If you do
  # want to update the value, then make sure to first check the Home Manager
  # release notes.
  home.stateVersion = "25.05";

  # Install Nix-managed packages into your environment.
  # https://search.nixos.org/packages
  home.packages = [
    pkgs.actionlint
    pkgs.aerospace
    pkgs.bash-language-server
    pkgs.bruno
    pkgs.vscode-langservers-extracted
    pkgs.coreutils
    pkgs.exercism
    pkgs.entr
    pkgs.gh
    pkgs.htop
    pkgs.jnv
    pkgs.jq
    pkgs.gnumake
    pkgs.luaformatter
    pkgs.nerd-fonts.hasklug
    pkgs.nil
    pkgs.nixfmt
    (unstablePkgs.opencode.overrideAttrs (old: {
      node_modules = old.node_modules.overrideAttrs (deps: {
        # Nix builders do not inherit the shell's certificate configuration.
        env = (deps.env or { }) // {
          NODE_EXTRA_CA_CERTS = builtins.path {
            path =
              config.home.sessionVariables.NIX_SSL_CERT_FILE or "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
            name = "opencode-ca-bundle.crt";
          };
        };
      });
    }))
    unstablePkgs.repomix
    pkgs.shellcheck
    pkgs.shfmt
    (pkgs.tldr.override { python3Packages = pkgs.python312Packages; })
    pkgs.tree
    pkgs.yamlfmt
    pkgs.nodejs_22
  ];

  # Manage plain config files (moved into /nix/store)
  home.file = {
    ".lua-format".source = ln "external/lua/.lua-format";
    ".yamlfmt".source = ln "external/yaml/.yamlfmt";
    ".zprofile".source = ln "external/zsh/.zprofile";
  };

  # Environment variables
  home.sessionVariables = {
    # assumes nix-channels:
    #   home-manager https://github.com/nix-community/home-manager/archive/release-25.05.tar.gz
    #   nixpkgs https://nixos.org/channels/nixpkgs-25.05-darwin
    # to explicitly set the nixpkgs version (and avoid caching):
    NIX_PATH = "nixpkgs=$HOME/.nix-defexpr/channels/nixpkgs";
    XDG_CONFIG_HOME = "${config.home.homeDirectory}/.config";
    EDITOR = "nvim";
    MANPAGER = "nvim +Man!";
    TERM = "xterm-256color"; # xterm-ghostty may not be recognized
    # nixpkgs builds opencode with OPENCODE_CHANNEL="stable", which causes it
    # to use a separate database (opencode-stable.db) from non-nix installs
    # (opencode.db). This flag forces a single db regardless of channel.
    OPENCODE_DISABLE_CHANNEL_DB = "1";
    CAVEMAN_DEFAULT_MODE = "full";
  };

  # Configure HM-managed programs & configuration
  programs.home-manager.enable = true;

  # Link to externally managed configuration from XDG_CONFIG_HOME
  xdg.configFile = {
    "fish/completions".source = ln "external/fish/completions";
    "fish/functions".source = ln "external/fish/functions";
    "fish/themes".source = ln "external/fish/themes";
    # ghostty must be manually installed & managed until derivation is no longer marked as broken
    "ghostty".source = ln "external/ghostty";
    "nvim".source = ln "external/nvim";
    "opencode/AGENTS.md".source = ln "external/opencode/instructions.md";
    "opencode/agents".source = ln "external/opencode/agents";
    "opencode/commands".source = ln "external/opencode/commands";
    "opencode/opencode.json".source = ln "external/opencode/base-opencode.json";
    "opencode/skills".source = ln "external/opencode/skills";
    "opencode/themes".source = ln "external/opencode/themes";
    "opencode/tui.json".source = ln "external/opencode/tui.json";
    "taskell".source = ln "external/taskell";
    "zellij/themes".source = ln "external/zellij/themes";
  };

  home.activation.cloneCaveman = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    if [ ! -e "${cavemanCheckoutDir}/.git" ]; then
      $DRY_RUN_CMD ${pkgs.git}/bin/git clone --branch ${cavemanRev} --depth 1 \
        https://github.com/JuliusBrussee/caveman.git "${cavemanCheckoutDir}"
    fi
  '';

  # Vendored from QingYunA/answer-me-with-html at af0239c9f1d1f061870d6c592f09f87acec920d1.
  # Pinned: update_check off stops the background GitHub fetch and update prompts.
  home.activation.configureAnswerMeWithHtml = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    am=${../external/opencode/skills/answer-me-with-html/scripts/am.mjs}
    $DRY_RUN_CMD ${pkgs.nodejs_22}/bin/node "$am" config set open off
    $DRY_RUN_CMD ${pkgs.nodejs_22}/bin/node "$am" config set update_check off
  '';
}
