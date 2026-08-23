{ config, ... }:
{
  # Nix-provided node's default prefix is the nix store (read-only), so any
  # `npm install -g` against it fails outright. Point the prefix at ~/.local
  # instead — already first on PATH (session-path.nix / the shell's default),
  # and already where herdr.nix and firstmate.nix's tools land.
  home.file.".npmrc".text = ''
    prefix=${config.home.homeDirectory}/.local
  '';
}
