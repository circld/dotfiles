# dotfiles repo — agent ramp-up

Nix + Home Manager dotfiles for macOS (no flake, no CI). Cloned at `~/dotfiles`.

## Key commands

- `home-manager switch` — apply and activate (most common)
- `home-manager build` — build without activating; output at `./result`
- `bash scripts/test-transform-commands.sh` — only automated test (7 assertions)
- Profile switch: `ln -sf ~/dotfiles/home/<profile>.nix ~/.config/home-manager/home.nix && home-manager switch`

## Directory structure (non-obvious parts)

- `external/` — live config symlinked out of the nix store; edits take effect immediately without a rebuild. Everything else requires `home-manager switch`.
- `external/opencode/` — AI tool config; see `AGENTS.md` in that directory.
- `modules/packages/` — per-tool HM modules; auto-discovered via `collectModules` in `utils.nix`. Drop a `.nix` file here and it's imported automatically.
- `docs/agentic-component-spec.md` — reference spec for authoring skills/commands/agents.

## Gotchas

- **Do not change `home.stateVersion = "25.05"`** in `modules/common.nix` — frozen at initial creation.
- **Do not add info about secret provisioning here**
- `OPENCODE_DISABLE_CHANNEL_DB=1` is set by HM to force a single opencode DB regardless of install method.
- Git work account is activated by a `gitdir:~/work/` conditional include; credential helper uses `gh auth token`, not the system keychain.
