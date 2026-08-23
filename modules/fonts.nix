{ pkgs, ... }:
{
  # ttf-jetbrains-mono-nerd stays on pacman for now (coexistence) — same
  # pattern as every other migrated tool. fontconfig doesn't care which
  # source a font came from, so wezterm (and anything else) sees whichever
  # copy fontconfig indexes; both can coexist without conflict.
  fonts.fontconfig.enable = true;

  home.packages = with pkgs; [
    nerd-fonts.jetbrains-mono
  ];
}
