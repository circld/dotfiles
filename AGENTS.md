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

## agent-fleet debugging

 - `AGENT_FLEET_TRACE_DIR=<dir>` gates per-press tracing: jump/traverse/board-Enter write `<dir>/<AF_REQUEST_ID>/` (model.json, model-trace.json, oracle.json|action.json, stack-pre/post.json, decision.txt, landing.log, landing-windows.json, landing-verify.json); the sensor appends `<dir>/consume.jsonl`. `AF_REQUEST_ID` (`<now_ms>-<script-pid>`) is stamped in the DECISION line, `.select` mailbox, and stack `writer` field; board Enter regenerates it per press (multi-press process) and suppresses it outside Enter so `d` dismissals stay untraced. Scripts inherit env from the zellij server, not your shell — to trace in prod, set the var via `modules/packages/zellij.nix` session env (needs `home-manager switch`) or wrap the keybind command. For the board, launch it with the var set (e.g. `AGENT_FLEET_TRACE_DIR=$PWD/.debug agent-fleet-board`).
 - `AGENT_FLEET_TIMING=1` (bash ≥5; on bash <5 ignored with one startup stderr note) appends `TIMING pid=… event=… ts=…` per-phase `k=v` lines (refresh: `tick_n`/`model`/`hidden` or `failed=model|invalid`; repaint: `render`/`find_hl`/`rows`; nav-only `drain`/`total`) to `$STATE_DIR/.board-timing.log`; default off, survives exit, slice by `pid=`. See `docs/plans/2026-07-31-agent-fleet-board-phase-0-timing-design.md`.
 - A fixed `AF_REQUEST_ID` reuses ONE directory: per-press files (model.json, decision.txt, …) overwrite on every press; only `consume.jsonl` appends. Let it auto-generate unless you are correlating a single replayed press.
