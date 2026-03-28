{ config, pkgs, ... }:
let
  utils = import ./utils.nix { inherit config pkgs; };
  ln = utils.ln;
  unstablePkgs = import ./unstable-pkgs.nix { inherit pkgs; };

  # Discover OpenCode skills for individual symlinking to Claude
  skillsDir = ../external/opencode/skills;
  skillNames = builtins.attrNames (builtins.readDir skillsDir);
  claudeSkillEntries = builtins.listToAttrs (map (name: {
    name = ".claude/skills/${name}";
    value = { source = ln "external/opencode/skills/${name}"; };
  }) skillNames);

  # Discover and transform OpenCode commands into Claude cmd-prefixed skills
  commandsDir = ../external/opencode/commands;
  commandFiles = builtins.filter (f: builtins.match ".*\\.md$" f != null)
    (builtins.attrNames (builtins.readDir commandsDir));
  commandNames = map (f: builtins.replaceStrings [ ".md" ] [ "" ] f) commandFiles;

  claudeCommandSkills = pkgs.runCommand "claude-command-skills" { } ''
    mkdir -p $out
    for file in ${commandsDir}/*.md; do
      basename=$(basename "$file" .md)
      mkdir -p "$out/cmd-$basename"
      ${pkgs.gawk}/bin/awk -f ${../scripts/transform-command-to-skill.awk} \
        "$file" > "$out/cmd-$basename/SKILL.md"
    done
  '';

  claudeCommandEntries = builtins.listToAttrs (map (name: {
    name = ".claude/skills/cmd-${name}";
    value = { source = "${claudeCommandSkills}/cmd-${name}"; };
  }) commandNames);
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
    pkgs.nodePackages.vscode-langservers-extracted
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
    pkgs.nixfmt-rfc-style
    unstablePkgs.opencode
    unstablePkgs.repomix
    pkgs.shellcheck
    pkgs.shfmt
    pkgs.tldr
    pkgs.tree
    pkgs.yamlfmt
    pkgs.yq-go
    unstablePkgs.claude-code
  ];

  # Manage plain config files (moved into /nix/store)
  home.file = {
    ".claude/agents".source = ln "external/opencode/agents";
    ".claude/CLAUDE.md".source = ln "external/opencode/AGENTS.md";
    ".lua-format".source = ln "external/lua/.lua-format";
    ".yamlfmt".source = ln "external/yaml/.yamlfmt";
    ".zprofile".source = ln "external/zsh/.zprofile";
  } // claudeSkillEntries // claudeCommandEntries;

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
    "opencode/AGENTS.md".source = ln "external/opencode/AGENTS.md";
    "opencode/agents".source = ln "external/opencode/agents";
    "opencode/commands".source = ln "external/opencode/commands";
    "opencode/skills".source = ln "external/opencode/skills";
    "opencode/themes".source = ln "external/opencode/themes";
    "opencode/tui.json".source = ln "external/opencode/tui.json";
    "taskell".source = ln "external/taskell";
    "zellij/themes".source = ln "external/zellij/themes";
  };
}
