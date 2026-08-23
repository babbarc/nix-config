{ ... }:
{
  # TODO(phase2/chezmoi): waybar/ stays in the dotfiles repo, migrating to
  # chezmoi (migration report SS1.2) - neutralized here since the
  # sibling-path references broke pure eval once nix/ became this repo's own
  # root instead of being nested one level inside dotfiles.
  # xdg.configFile = {
  #   "waybar/config".source = ../../waybar/config;
  #   "waybar/style.css".source = ../../waybar/style.css;
  #   "waybar/mocha.css".source = ../../waybar/mocha.css;
  # };
}
