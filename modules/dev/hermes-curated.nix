# The shared, host-portable Hermes agent set: everything a login-user Hermes
# install needs on ANY host, in one import.
#
# Model (captain intent, 2026-09): Hermes runs as the SAME login user that runs
# firstmate on that machine - engine, curated home, fleet modules and gateway
# under $HOME - never as a dedicated user per host. The one machine-level
# exception is the alps `hermes` profile (hosts/hermes/home.nix, a dedicated
# uid 1003 running the full joy-brain); it is a separate deployment and
# deliberately does not import this module (it takes
# modules/dev/hermes-agent.nix directly with hermesAgent.standaloneDeps = true,
# since it imports no shared modules).
#
# Portability matrix (data/nix-unified-system-design/report.md section 5.2):
# everything imported below is host-agnostic - it keys off
# config.home.homeDirectory / HERMES_HOME only. What is NOT here, on purpose,
# is anything host-specific:
#   - modules/dev/browser-proxy-windows.nix   WSL interop only
#   - modules/dev/browser-proxy-linux.nix     Linux host Chrome (laptop, alps)
#   - modules/dev/joy-brain.nix               private clone, alps only
#   - modules/dev/hermes-alps-services.nix    joy-host services (vision bridge,
#                                             baileys, qmd, CUPS)
#   - modules/dev/hermes-browser-tools.nix    only for profiles importing no
#                                             shared modules (alps)
#   - hermesAgent.cuaDriver                   Windows desktop only
# Hosts that import this module already import the shared modules/dev list, so
# hermesAgent.standaloneDeps stays off (the engine's runtime deps - git,
# ripgrep, node, python3 - are declared there).
#
# Importing hosts:
#   - wsl    : + browser-proxy-windows.nix, + hermesAgent.cuaDriver
#   - laptop : + browser-proxy-linux.nix
#   - server : nothing else - headless, so no browser backend at all
#
# Credentials stay local and out of nix: the provider key lives in
# ~/.hermes/.env, written by the captain, never by activation. Activation only
# ever seeds ~/.hermes/config.yaml when it is absent and then yq-merges the
# declared keys into it (see modules/dev/hermes-home.nix), so an existing .env,
# config.yaml, auth.json, kanban.db, sessions/, memories/ or cron/ is never
# clobbered on a re-run.
{ config, lib, ... }:
let
  cfg = config.hermesCurated;

  # The stable browser contract every backend keeps: a local CDP proxy on
  # localhost:3333 (containers/systemd/browser-proxy-{linux,windows}.py, and the
  # joy host's own unit). It is the one value all of them agree on.
  cdpUrl = "http://localhost:3333";
in
{
  imports = [
    # Engine: pinned uv install of the pinned upstream revision, hermes CLI in
    # ~/.local/bin, ddgs web-search backend.
    ./hermes-agent.nix
    # Fleet guardrails: the hermesGuardrails.* tunables plus the
    # hermes-guardrails / hermes-desktop-lock / hermes-live-app-authorize CLIs.
    # Imported before hermes-home.nix, which consumes its rendered artifacts.
    ./hermes-guardrails.nix
    # Curated, self-contained HERMES_HOME (~/.hermes).
    ./hermes-home.nix
    # Vendored AXI skill set + its CLIs.
    ./hermes-skills.nix
    # Vendored native plugins (pass-enforcement, guardrails).
    ./hermes-plugins.nix
    # hermes-expert-new, the deterministic domain-expert profile helper.
    ./hermes-expert-new.nix
    # hermes-gateway user unit (kanban dispatcher) + kanban board init.
    ./hermes-gateway.nix
  ];

  options.hermesCurated = {
    browserProxyUnit = lib.mkOption {
      type = lib.types.str;
      default = "";
      example = "browser-proxy-windows.service";
      description = ''
        Name of the systemd --user unit on this host that provides the local
        CDP browser backend Hermes points at. The gateway orders itself after
        it and exports `BROWSER_CDP_URL`, and the curated config seed carries
        `browser.cdp_url` - all three only when this is set.

        Leave empty on a host with no browser backend (a headless server):
        the `browse` / `web-login` skills and the native `browser_*` tools are
        then inert by design rather than dialling a proxy that does not exist.
        The unit itself is imported by the host, not by this module.
      '';
    };
  };

  config = {
    hermesGateway.browserProxyUnit = cfg.browserProxyUnit;

    # One switch, not two: the CDP url is part of the same browser-backend
    # decision as the ordering/env above. null => the seed omits the browser
    # block entirely instead of advertising a dead endpoint.
    hermesHome.browserCdpUrl =
      if cfg.browserProxyUnit == "" then null else cdpUrl;
  };
}
