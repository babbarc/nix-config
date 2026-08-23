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

  imports = [
    ../../modules/dev
    ../../modules/session-path.nix
    ../../modules/wezterm.nix
    ../../modules/sway.nix
    ../../modules/waybar.nix
    ../../modules/voice-dictation.nix
    ../../modules/fonts.nix
  ];
}
