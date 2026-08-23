{ pkgs, ... }:
{
  # lazygit is now Nix-provided via pkgs.lazygit, superseding the pacman
  # copy that a fresh machine used to rely on (a removed pacman lazygit
  # silently lost the binary). Only its config is managed below.
  home.packages = [ pkgs.lazygit ];

  # ~/.config/lazygit used to be a whole-directory symlink to
  # ~/.dotfiles/lazygit, which held both config.yml (user config) and
  # state.yml (lazygit's own runtime state — recent repos, command history;
  # confirmed actively written to by checking its mtime). Only config.yml is
  # genuinely user config, so only it is brought under home-manager management
  # here. state.yml is deliberately left out: it's a plain, gitignored local
  # file at ~/.config/lazygit/state.yml (not symlinked anywhere) so lazygit
  # can keep writing to it on every run without hitting a read-only Nix-store
  # symlink. No activation hook is needed for it either — home-manager only
  # ever manages the config.yml path here, so it never touches state.yml.
  xdg.configFile."lazygit/config.yml".source = ../../../lazygit/config.yml;
}
