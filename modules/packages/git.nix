{
  pkgs,
  config,
  ...
}:
{
  programs.git = {
    enable = true;
    aliases = {
      st = "status";
      ci = "commit";
      co = "checkout";
      rco = "!f(){ git fetch origin \"$1\" && git checkout \"$1\"; };f";
      hist = "log --pretty=format:'%h %ad | %s%d [%an]' --graph --date=short";
      type = "cat-file -t";
      dump = "cat-file -p";
      br = "!f(){ export count=$1; git for-each-ref --sort=-committerdate refs/heads --format='%(HEAD)%(color:yellow)%(refname:short)|%(color:bold green)%(committerdate:relative)|%(color:blue)%(subject)|%(color:magenta)%(authorname)%(color:reset)' --color=always --count=\"\${count:=10}\" | column -ts'|'; };f";
      nbr = "!f(){ git checkout -b \"$1\" && git push --set-upstream origin \"$1\"; };f";
      root = "rev-parse --show-toplevel";
    };
    delta.enable = true;
    delta.options = {
      features = "villsau";
      navigate = true;
      side-by-side = true;
      # villsau from https://github.com/dandavison/delta/blob/main/themes.gitconfig
      dark = true;
      file-style = "omit";
      hunk-header-decoration-style = "omit";
      hunk-header-file-style = "magenta";
      hunk-header-line-number-style = "dim magenta";
      hunk-header-style = "file line-number syntax";
      line-numbers = false;
      minus-emph-style = "bold red 52";
      minus-empty-line-marker-style = "normal \"#3f0001\"";
      minus-non-emph-style = "dim red";
      minus-style = "bold red";
      plus-emph-style = "bold green 22";
      plus-empty-line-marker-style = "normal \"#002800\"";
      plus-non-emph-style = "dim green";
      plus-style = "bold green";
      syntax-theme = "OneHalfDark";
      whitespace-error-style = "reverse red";
      zero-style = "dim syntax";
    };
    extraConfig = {
      core = {
        editor = "nvim";
      };
      color = {
        ui = true;
        pager = true;
      };
      init = {
        defaultBranch = "main";
      };
      push = {
        default = "simple";
        autoSetupRemote = true;
      };
    };
    ignores = [
      ".DS_Store"
      "**/.env"
      "**/.env.*"
      "**/credentials.json"
      "**/secret.json"
      "**/secrets.json"
      "**/credentials.nix"
      "**/secret.nix"
      "**/secrets.nix"
      "**/*.key"
      "**/*.pem"
      "**/*.pfx"
      "**/*.p12"
      "**/*.crt"
      "**/*.cer"
      "**/id_rsa"
      "**/id_dsa"
      "**/.ssh/id_*"
      "*.pyc"
      ".claude"
    ];
    userEmail = "circld1@gmail.com";
    userName = "circld";
  };
}
