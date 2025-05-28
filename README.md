# dotfiles

## directory structure

```
.
├── external/
├── managed/
└── home.nix
```

## design

1. use Home Manager to manage global packages & dotfile installation in `home.nix`
2. use Home Manager to manage slowly changing configuration stored in `managed/`
3. manage quickly changing configuration outside of Home Manager in `external/`

## initial setup

1. pre-requisites: `nix` and `home-manager` are installed
2. clone this repo in `$HOME`: `cd ~ && nix-shell -p git --run 'git clone https://github.com/circld/dotfiles'`
3. symlink `dotfiles/home.nix`: `mkdir -p ~/.config/home-manager && ln -s ~/dotfiles/home.nix ~/.config/home-manager/home.nix`
4. apply the environment: `home-manager switch`
