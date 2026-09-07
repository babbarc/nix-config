{ ... }:
{
  # Standalone home-manager profile for the `hermes` system user on the joy
  # host (alps). Intentionally MINIMAL: this user already has a live home
  # directory full of real, hand-managed dotfiles (pass, .ssh, .gnupg, fish
  # config) that this repo must not rewrite or collide with. The only thing
  # this profile manages is the joy-stack podman quadlets - see
  # modules/hermes-joy-stack.nix. Do not add programs.*/services.* or other
  # home-manager state here without checking it against the live home first.
  #
  # `hermes` is a fixed system account (uid 1003, gid 1004), not a per-machine
  # value, so username/homeDirectory are hardcoded rather than read from
  # dotfilesEnv the way the laptop/server hosts do.
  home.username = "hermes";
  home.homeDirectory = "/home/hermes";

  # Pin to the home-manager release this config was first created against - do
  # not bump on later nixpkgs/home-manager updates (see home-manager's
  # stateVersion docs).
  home.stateVersion = "24.11";

  programs.home-manager.enable = true;

  imports = [
    ../../modules/hermes-joy-stack.nix
  ];
}
