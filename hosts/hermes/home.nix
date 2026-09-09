{ ... }:
{
  # Standalone home-manager profile for the `hermes` system user on the joy
  # host (alps). Intentionally MINIMAL in what it rewrites: this user already
  # has a live home directory full of real, hand-managed dotfiles (pass, .ssh,
  # .gnupg, fish config) that this repo must not rewrite or collide with. The
  # profile manages the joy-stack deployment declaration and - since Phase B of
  # the direct-install migration - the direct-install modules that will replace
  # the container/quadlet path at cut-over (Phase D). Both paths are declared
  # side by side until then: the quadlet drop (hermes-joy-stack.nix) keeps the
  # running container stack declared, and the direct modules below are the
  # new, inactive-until-activated shape. See the scoping report section 2.6 for
  # the phasing.
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

  # The hermes profile imports NO shared modules/dev list (that list carries
  # laptop/server dev tooling this user does not need and must not collide with
  # the hand-managed dotfiles), so the direct-install modules declare their own
  # dependencies via the options below - see modules/dev/hermes-agent.nix and
  # modules/dev/joy-brain.nix for the two options.
  hermesAgent.standaloneDeps = true;
  joyBrain.full = true;

  imports = [
    # The joy-stack podman quadlets (hermes/browser-proxy/qmd containers).
    # Stays declared until the Phase E retirement after the direct install is
    # proven and soaked - do NOT remove here. See modules/hermes-joy-stack.nix.
    ../../modules/hermes-joy-stack.nix

    # Direct-install engine: the pinned uv sync of upstream hermes-agent into
    # ~/.local/share/hermes-agent (same hermesRev as the container base), with
    # standaloneDeps so it declares git/ripgrep/nodejs/python3/etc. itself.
    ../../modules/dev/hermes-agent.nix

    # Full-brain instantiation of ~/.hermes from the private joy-brain clone
    # (full skill tree, not the wsl curated subset).
    ../../modules/dev/joy-brain.nix

    # Linux browser backend (Q1a): browser-proxy.py as a systemd --user service
    # driving host Chrome on alps. See modules/dev/browser-proxy-linux.nix.
    ../../modules/dev/browser-proxy-linux.nix

    # The direct-install long-running services (gateway, vision-bridge,
    # baileys-watch, qmd) plus the native qmd install. See
    # modules/dev/hermes-alps-services.nix.
    ../../modules/dev/hermes-alps-services.nix
  ];
}
