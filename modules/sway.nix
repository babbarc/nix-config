{ ... }:
{
  # TODO(phase2/chezmoi): sway/ stays in the dotfiles repo, migrating to
  # chezmoi (migration report SS1.2) - neutralized here since the
  # sibling-path reference broke pure eval once nix/ became this repo's own
  # root instead of being nested one level inside dotfiles.
  # xdg.configFile = {
  #   "sway/config".source = ../../sway/config;
  # };
}
