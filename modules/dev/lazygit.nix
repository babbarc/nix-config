{ pkgs, ... }:
{
  # lazygit is now Nix-provided via pkgs.lazygit, superseding the pacman
  # copy that a fresh machine used to rely on (a removed pacman lazygit
  # silently lost the binary). Only its config is managed below.
  home.packages = [ pkgs.lazygit ];
}
