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

  services.gpg-agent.pinentry.package = pkgs.pinentry-curses;

  # Hybrid host: pacman owns the system toolchain, so nix installs no compiler
  # front end here and `cc` resolves to pacman's /usr/bin/cc (gcc). A nix gcc
  # first in PATH made default-PATH makepkg builds link nix glibc. See
  # modules/dev/dev-toolchains.nix.
  devToolchains.cCompiler = "system";

  imports = [
    ../../modules/dev

    # Hermes agent as THIS login user (yeti) - the same user that runs
    # firstmate, not the dedicated uid 1003 `hermes` account on the same
    # machine, which is a separate deployment (hosts/hermes/home.nix, the alps
    # full brain). Engine, curated ~/.hermes, guardrails, the vendored skills +
    # plugins, hermes-expert-new and the hermes-gateway unit (kanban
    # dispatcher). See modules/dev/hermes-curated.nix.
    #
    # HEADLESS HOST - no browser backend, on purpose. This host imports no
    # browser-proxy-* module, so `hermesCurated.browserProxyUnit` stays unset
    # and the shared set omits `BROWSER_CDP_URL` from the gateway and
    # re-seeds NO `browser.cdp_url`. Consequence, by design: the `browse` and
    # `web-login` skills (both CDP-driven) and the native `browser_*` tools are
    # INERT here - they fail cleanly rather than driving a Chrome that does not
    # exist. The desktop skills (`operate-desktop`, and `cua-driver` MCP) are
    # inert too: cua-driver is Windows-only. What DOES work on this host is
    # everything that needs no display: the orchestrator + kanban fleet,
    # `web_search` (keyless ddgs), `pass-access`, `recover-blocked-page`,
    # `delegated-task`, and the terminal/file/skills/memory toolsets.
    ../../modules/dev/hermes-curated.nix
  ];
}
