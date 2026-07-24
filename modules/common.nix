{ config, pkgs, lib, ... }:
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
    unstablePkgs.opencode
    unstablePkgs.repomix
    pkgs.shellcheck
    pkgs.shfmt
    pkgs.tldr
    pkgs.tree
    pkgs.yamlfmt
    pkgs.yq-go
    pkgs.nodejs_22
    unstablePkgs.claude-code
  ];

  # Manage plain config files (moved into /nix/store)
  home.file = {
    ".claude/agents".source = ln "external/claude/agents";
    ".claude/CLAUDE.md".source = ln "external/opencode/instructions.md";
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
    CAVEMAN_DEFAULT_MODE = "full";
  };

  # Configure HM-managed programs & configuration
  programs.home-manager.enable = true;

  # Link to externally managed configuration from XDG_CONFIG_HOME
  xdg.configFile = {
    "agent-fleet/tasks.toml".source = ln "external/agent-fleet/tasks.toml";
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
    "opencode/plugins".source = ln "external/opencode/plugins";
    "opencode/skills".source = ln "external/opencode/skills";
    "opencode/themes".source = ln "external/opencode/themes";
    "opencode/tools-lib".source = ln "external/opencode/tools-lib";
    "opencode/tools".source = ln "external/opencode/tools";
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

  # Install caveman + ponytail plugins into Claude Code. Both are distributed
  # via marketplace repos whose `.claude-plugin/marketplace.json` names the
  # plugin after the repo, yielding the `<name>@<name>` plugin id Claude Code
  # uses when plugin name == marketplace name. Idempotent: `claude plugin list`
  # is grep'd and both `marketplace add` + `install` are skipped if already
  # present, so re-running activation does no network I/O once installed.
  #
  # NOTE: home.activation blocks are spliced into one shell script that runs
  # with `set -eu` and a hardcoded, minimal PATH (no ~/.nix-profile/bin) --
  # `exit 0` here would abort the *entire* activation script, silently
  # skipping every later step (including installPackages, which is what
  # actually updates package binaries in the Nix profile). Wrap in an `if`
  # instead of exiting, and call the derivation's claude directly rather than
  # relying on PATH.
  home.activation.installClaudeCodePlugins = lib.hm.dag.entryAfter [ "writeBoundary" ] (
    let
      claude = "${unstablePkgs.claude-code}/bin/claude";
    in
    ''
      if [ -x "${claude}" ]; then
        # EXDEV workaround: Claude Code's plugin installer renames from
        # ~/.claude/plugins/cache/ into the OS temp dir, which fails cross-filesystem
        # on some setups. Pin TMPDIR/TEMP/TMP inside ~/.claude/ to keep the rename
        # on one filesystem. Mirrors caveman installer's sameFilesystemTmpEnv.
        claudeTmp="${config.home.homeDirectory}/.claude/tmp"
        mkdir -p "$claudeTmp"
        TMPDIR="$claudeTmp"
        TEMP="$claudeTmp"
        TMP="$claudeTmp"
        export TMPDIR TEMP TMP
        unset claudeTmp
        installedPlugins="$(${claude} plugin list 2>/dev/null || true)"
        for spec in \
          "caveman@caveman:JuliusBrussee/caveman" \
          "ponytail@ponytail:DietrichGebert/ponytail"; do
          plugin="''${spec%%:*}"
          repo="''${spec#*:}"
          if printf '%s\n' "$installedPlugins" | grep -qiF -- "$plugin"; then
            echo "claude plugin '$plugin' already installed; skipping marketplace + install."
            continue
          fi
          $DRY_RUN_CMD ${claude} plugin marketplace add "$repo" \
            || echo "warning: claude plugin marketplace add for '$plugin' failed; continuing." >&2
          $DRY_RUN_CMD ${claude} plugin install "$plugin" \
            || echo "warning: claude plugin install for '$plugin' failed; continuing." >&2
        done
      fi
    ''
  );
}
