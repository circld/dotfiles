# Source Nix environment before zshrc runs
# NOTE: Don't rely on Home Manager to manage .zprofile. Let it be static and minimal, just for bootstrapping Nix.
if [ -e /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then
  . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
fi
