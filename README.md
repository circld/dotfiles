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

## todo

- [ ] *figure out how best to separate personal & work configurations while sharing core (see README for ideas)*
- [ ] add nix lang server + add nixfmt to conform
- [ ] move gitconfig into file + add extraConfig for things that vary
- [ ] symlink personal gitconfig for work computer
- [ ] neovim (gitsigns): add jump to git chunk ]c/[c (add example config from https://github.com/lewis6991/gitsigns.nvim?tab=readme-ov-file#%EF%B8%8F-installation--usage
- [ ] neovim (snacks.picker): fix highlight color in picker window for Grep matches
- [ ] neovim: configure remaining plugins: https://github.com/circld/kickstart.nvim/blob/b3765acc86187b18431f275905e964e71d32be95/init.lua
- [ ] neovim: figure out how to avoid docstring getting cut off near bottom of buffer
- nice-to-have
- [ ] neovim: add undotree replacement
- [ ] configure fzf
- [ ] attempt to integrate with lazy.nvim: https://nixalted.com/

## resources

- [home manager manual](https://nix-community.github.io/home-manager/)
- [inspiration](https://github.com/nix-community/home-manager/blob/901f8fef7f349cf8a8e97b3230b22fd592df9160/tests/integration/standalone/alice-home-init.nix#L8)
