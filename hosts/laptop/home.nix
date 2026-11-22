{ config, pkgs, dotfilesEnv, ... }:
let
  # Per-machine username from ~/.config/dotfiles/env (see env.example); the
  # committed example/placeholder keeps eval working on a fresh clone.
  username = dotfilesEnv.DOTFILES_USERNAME or "user";
in
{
  home.username = username;
  home.homeDirectory = "/home/${username}";

  # Pin to the home-manager release this config was first created against.
  # Do not bump this when nixpkgs/home-manager update later — see home-manager's
  # documentation on stateVersion for why.
  home.stateVersion = "24.11";

  programs.home-manager.enable = true;

  imports = [
    ../../modules/dev
    ../../modules/session-path.nix
    ../../modules/wezterm.nix
    ../../modules/sway.nix
    ../../modules/waybar.nix
    ../../modules/gpg-agent-laptop.nix
    ../../modules/voice-dictation.nix
    ../../modules/fonts.nix
    ../../modules/podman.nix

    # Hermes agent as THIS login user - the same user that runs firstmate, not
    # a dedicated user (captain intent, 2026-09). Engine, curated ~/.hermes,
    # guardrails, the vendored skills + plugins, hermes-expert-new and the
    # hermes-gateway unit (kanban dispatcher). See
    # modules/dev/hermes-curated.nix for exactly what the shared set covers and
    # why the host-specific pieces stay out of it.
    ../../modules/dev/hermes-curated.nix
    # This host's browser backend: the Linux-host-Chrome CDP proxy on
    # localhost:3333, driving the captain's real google-chrome-stable
    # non-headlessly (see containers/systemd/browser-proxy-linux.py). The wsl
    # host uses the Windows equivalent instead; the headless server has none.
    ../../modules/dev/browser-proxy-linux.nix
  ];

  # Tell the shared Hermes set which backend this host has: the gateway orders
  # itself after it and exports BROWSER_CDP_URL, and the config seed carries
  # browser.cdp_url.
  hermesCurated.browserProxyUnit = "hermes-browser-proxy.service";
}
