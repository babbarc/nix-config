{ config, lib, dotfilesEnv, ... }:
{
  # Global git identity, shared across all three hosts. userName reuses
  # config.home.username rather than reading dotfilesEnv.DOTFILES_USERNAME
  # directly - every host's home.nix/configuration.nix already sets
  # home.username to that same per-machine value (it's also what
  # nix/hosts/wsl/configuration.nix feeds to wsl.defaultUser for the WSL
  # user account), so this stays in sync with the WSL username by
  # construction instead of duplicating the env lookup.
  #
  # userEmail comes from dotfilesEnv.DOTFILES_USER_EMAIL (see env.example) -
  # unlike the username, no other option already carries an email, so this
  # reads the env value directly. nix/setup.sh prompts for it the same way
  # it prompts for DOTFILES_USERNAME. lib.optionalAttrs drops the key
  # entirely rather than writing an empty user.email when it's unset.
  programs.git = {
    enable = true;
    settings.user = {
      name = config.home.username;
    } // lib.optionalAttrs (dotfilesEnv.DOTFILES_USER_EMAIL or "" != "") {
      email = dotfilesEnv.DOTFILES_USER_EMAIL;
    };
  };
}
