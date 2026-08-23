{ ... }:
{
  # TODO(phase2/chezmoi): nvim/ stays in the dotfiles repo, migrating to
  # chezmoi (migration report SS1.2) - neutralized here since the
  # sibling-path references broke pure eval once nix/ became this repo's own
  # root instead of being nested one level inside dotfiles.
  # xdg.configFile = {
  #   "nvim/init.lua".source = ../../../nvim/init.lua;
  #   "nvim/lazyvim.json".source = ../../../nvim/lazyvim.json;
  #   "nvim/stylua.toml".source = ../../../nvim/stylua.toml;
  #   "nvim/lua" = {
  #     source = ../../../nvim/lua;
  #     recursive = true;
  #   };
  #   "nvim/snippets" = {
  #     source = ../../../nvim/snippets;
  #     recursive = true;
  #   };
  # };
}
