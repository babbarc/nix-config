{ config, pkgs, dotfilesEnv, ... }:
let
  # Per-machine username from ~/.config/dotfiles/env (see env.example); the
  # committed example/placeholder keeps eval working on a fresh clone.
  username = dotfilesEnv.DOTFILES_USERNAME or "user";
in
{
  home.username = username;
  home.homeDirectory = "/home/${username}";

  # Pin to the home-manager release this config was first created against.
  # Do not bump this when nixpkgs/home-manager update later — see home-manager's
  # documentation on stateVersion for why.
  home.stateVersion = "24.11";

  programs.home-manager.enable = true;

  services.gpg-agent.pinentry.package = pkgs.pinentry-curses;

  # Hybrid host: pacman owns the system toolchain, so nix installs no compiler
  # front end here and `cc` resolves to pacman's /usr/bin/cc (gcc). A nix gcc
  # first in PATH made default-PATH makepkg builds link nix glibc. See
  # modules/dev/dev-toolchains.nix.
  devToolchains.cCompiler = "system";

  imports = [
    ../../modules/dev
  ];
}
