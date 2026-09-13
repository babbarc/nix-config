{ config, lib, pkgs, dotfilesEnv, ... }:
let
  # env.example's committed placeholders - a switch without a real
  # ~/.config/dotfiles/env override must never stamp these into git config.
  placeholderUsername = "your-username";
  placeholderEmail = "your-email@example.com";

  username = dotfilesEnv.DOTFILES_USERNAME or "";
  email = dotfilesEnv.DOTFILES_USER_EMAIL or "";

  identityUsable =
    username != "" && username != placeholderUsername
    && email != "" && email != placeholderEmail;
in
{
  # `git config --global` deliberately, not `--file ~/.config/git/config`:
  # --global targets whichever file git itself resolves as global (that file
  # on a real host, because it exists), which is the same file
  # `gh auth setup-git` writes its credential helper into. Using `--global`
  # means this activation edits that file in place alongside the helper,
  # rather than owning or templating the whole file.
  #
  # identityUsable is resolved at eval time (dotfilesEnv is static per
  # build), so the placeholder guard is a build-time branch, not a runtime
  # bash check - a build without a real env override never even emits the
  # git config invocations.
  home.activation.gitIdentity = lib.hm.dag.entryAfter [ "writeBoundary" ] (
    if identityUsable then ''
      $DRY_RUN_CMD ${pkgs.git}/bin/git config --global user.name "${username}"
      $DRY_RUN_CMD ${pkgs.git}/bin/git config --global user.email "${email}"
    '' else ''
      echo "gitIdentity: DOTFILES_USERNAME/DOTFILES_USER_EMAIL missing or still the env.example placeholder - skipping git identity activation" >&2
    ''
  );
}
