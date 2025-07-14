# dotfiles

## directory structure

```
.
├── external/
├── home/
│   ├── personal.nix
│   └── work.nix
└── modules/
    ├── common.nix
    ├── packages/
    ├── personal/
    │   └── packages/
    └── work/
        └── packages/
```

## design

1. use Home Manager to manage global packages & dotfile installation in `home.nix`
2. use Home Manager to manage slowly changing configuration stored in `modules/`
3. manage frequently changing configuration outside of Home Manager in `external/` and use Home Manager to symlink to $HOME or $XDG_CONFIG_HOME as needed

## initial setup

1. pre-requisites: `nix` and `home-manager` are installed
2. clone this repo in `$HOME`: `cd ~ && nix-shell -p git --run 'git clone https://github.com/circld/dotfiles'`
3. symlink `dotfiles/home.nix`: `mkdir -p ~/.config/home-manager && ln -s ~/dotfiles/home/{personal,work}.nix ~/.config/home-manager/home.nix`
4. apply the environment: `home-manager switch`

## To Do

- [x] neovim: add rustfmt + language server
- [ ] neovim: add markdown linter + formatter
- [ ] create `gf` variants for opening in vert/horiz/tabsplit
- [ ] neovim: configure remaining plugins: https://github.com/circld/kickstart.nvim/blob/b3765acc86187b18431f275905e964e71d32be95/init.lua (esp LSP keymaps, highlight word under cursor, diagnostic config, etc)
- [ ] neovim: add todo/fixme search picker
- [ ] neovim: figure out how to avoid docstring getting cut off near bottom of buffer

### nice-to-have

- [ ] neovim: tab bar aesthetics
- [ ] zellij: add date/clock to interface (requires plugins)
- [ ] configure & alias `eza`
- [ ] attempt to integrate with lazy.nvim: https://nixalted.com/
- [ ] thunderbird?

## resources

- [home manager manual](https://nix-community.github.io/home-manager/)
- [inspiration](https://github.com/nix-community/home-manager/blob/901f8fef7f349cf8a8e97b3230b22fd592df9160/tests/integration/standalone/alice-home-init.nix#L8)
