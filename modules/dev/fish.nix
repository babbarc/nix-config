{ fisher, ... }:
{
  programs.fish.enable = true;

  # fisher itself: originally left pacman-managed since it isn't packaged in
  # nixpkgs. Revisited later — fisher's entire pacman package is just two
  # plain fish files (functions/fisher.fish, completions/fisher.fish), no
  # binary, no build. pacman only blocked removing its own `fish` package
  # because *its* fisher package declares a `fish` dependency in pacman's
  # metadata — a packaging artifact, not a real technical requirement (fisher
  # is plain fish scripting, no fish-version-specific internals). So instead
  # of relying on nixpkgs packaging fisher, its two files are fetched directly
  # from upstream via the `fisher` flake input (a non-flake source fetch, see
  # flake.nix) and placed exactly where pacman's package used to put them.
  # Fisher's actual plugin-management behavior (fisher install/update writing
  # into conf.d/functions/completions) is unchanged — only fisher's own
  # bootstrap moved to Nix.

  # NOTE ON A REAL REGRESSION FOUND AND FIXED HERE: this module originally used
  # `xdg.configFile."fish/config.fish".source = lib.mkForce ../../fish/config.fish;`
  # to fully replace home-manager's own generated config.fish with the user's
  # original file. That silently dropped the PATH-setup sourcing home-manager's
  # fish integration normally writes into config.fish (the bit that adds
  # ~/.nix-profile/bin to PATH) — so no Nix-installed package's binary was
  # reachable by bare name in ANY fish shell, interactive or login, for as long
  # as that mkForce was in place. It went unnoticed because every fish-based
  # `which <tool>` check in earlier tasks happened to hit a pacman-installed
  # fallback of the same tool. Fixed by using `programs.fish.interactiveShellInit`
  # instead, which lets home-manager keep generating config.fish (PATH setup
  # included) while still injecting the user's own two lines into it.
  programs.fish.interactiveShellInit = ''
    starship init fish | source
    fzf --fish | source
    set -g fish_greeting
  '';

  # fish cannot rely on the Nix installer's /etc/fish/conf.d/nix.fish hook: its
  # nix-daemon.fish add_path for $NIX_LINK/bin (the per-user profile) silently
  # fails during fish login startup, so ~/.nix-profile/bin never lands on PATH in
  # a clean ssh login. home-manager-path installs into the user's default nix
  # profile (~/.nix-profile), so add both profile dirs explicitly. conf.d runs
  # for interactive AND non-interactive shells. ~/.local/bin is included too:
  # herdr.nix and agent-cli-tools.nix curl-install their tools there, and
  # nothing else on any of the three hosts ever added it to the shell PATH.
  xdg.configFile."fish/conf.d/nix-path.fish".text = ''
    fish_add_path --prepend --global "$HOME/.nix-profile/bin" /nix/var/nix/profiles/default/bin "$HOME/.local/bin"
  '';
}
