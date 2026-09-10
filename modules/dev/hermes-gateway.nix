# Hermes gateway as a systemd --user unit on the `wsl` host.
#
# Why this exists (captain decision #1, data/hermes-orchestrator-design/report.md
# sections 0 and 7.1): the kanban dispatcher - the thing that promotes
# dependency-satisfied cards and spawns the assignee expert - runs INSIDE the
# gateway (`kanban.dispatch_in_gateway: true`, the default). The `wsl` host had
# no gateway unit and no gateway process, so a fleet of experts could never
# drain a board. This unit is the dispatcher's host.
#
# Deliberately NOT the alps module: modules/dev/hermes-alps-services.nix owns
# the full-brain services (vision-bridge, baileys-watch, qmd, host CUPS) that
# only exist on the joy host. This one is the single unit the wsl curated home
# needs, and it is imported only by hosts/wsl/configuration.nix.
#
# Shape follows the repo's other wsl user service
# (modules/dev/browser-proxy-windows.nix): a plain systemd --user service the
# login user runs, Restart=always, WantedBy=default.target. It is NOT installed
# with `hermes gateway install`: the declarative unit is the source of truth,
# and `hermes` recognizes it as its own service (get_systemd_unit_path() is
# ~/.config/systemd/user/hermes-gateway.service for the default profile).
#
# `--external-supervisor` is required, matching the alps unit: systemd owns
# the process, so in-chat restarts / updates exit back to the unit instead of
# spawning a detached replacement. systemd also sets INVOCATION_ID, which the
# engine's supervised-gateway conflict guard uses to recognize it is not an
# orphan shell-spawned second dispatcher.
{ config, lib, pkgs, ... }:
let
  homeDir = config.home.homeDirectory;
  username = config.home.username;
  hermesHome = "${homeDir}/.hermes";

  # `hermes gateway run` is exec'd through the CLI symlink the engine
  # activation creates (~/.local/bin/hermes -> the pinned venv).
  hermesBin = "${homeDir}/.local/bin/hermes";

  # systemd --user units do not read the login shell profile, so PATH is
  # declared explicitly: ~/.local/bin first (the hermes CLI, npm globals,
  # curl-installed tools), then the NixOS per-user profile where
  # home.packages land on this host (useUserPackages = true - hermes-expert-new,
  # pass-axi, hermes-browse, recover-page, jq, python3, ...), then the rest of
  # the nix/userland dirs. Without /etc/profiles/per-user/<user>/bin the
  # dispatcher-spawned workers could not find hermes-expert-new or the pass /
  # browse CLIs.
  pathEnv = lib.concatStringsSep ":" [
    "${homeDir}/.local/bin"
    "${homeDir}/bin"
    "/etc/profiles/per-user/${username}/bin"
    "/run/wrappers/bin"
    "${homeDir}/.nix-profile/bin"
    "/nix/var/nix/profiles/default/bin"
    "/run/current-system/sw/bin"
    "/usr/local/bin"
    "/usr/bin"
    "/bin"
  ];
in
{
  systemd.user.services.hermes-gateway = {
    Unit = {
      Description = "Hermes AI Agent Gateway (wsl) - kanban dispatcher + messaging";
      After = [
        "network-online.target"
        "browser-proxy-windows.service"
      ];
    };

    Service = {
      ExecStart = "${hermesBin} gateway run --external-supervisor";
      Environment = [
        "HOME=${homeDir}"
        "HERMES_HOME=${hermesHome}"
        "PATH=${pathEnv}"
        # Route browser automation to the Windows-Chrome CDP proxy, same
        # contract as browser.cdp_url in the config seed.
        "BROWSER_CDP_URL=http://localhost:3333"
      ];
      Restart = "always";
      RestartSec = 5;
    };

    Install = {
      WantedBy = [ "default.target" ];
    };
  };
}
