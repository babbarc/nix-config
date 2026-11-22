# Hermes gateway as a systemd --user unit for a login-user Hermes install.
#
# Why this exists (captain decision #1, data/hermes-orchestrator-design/report.md
# sections 0 and 7.1): the kanban dispatcher - the thing that promotes
# dependency-satisfied cards and spawns the assignee expert - runs INSIDE the
# gateway (`kanban.dispatch_in_gateway: true`, the default). The `wsl` host had
# no gateway unit and no gateway process, so a fleet of experts could never
# drain a board. This unit is the dispatcher's host.
#
# Shipped on every host that imports modules/dev/hermes-curated.nix (wsl,
# laptop, server) - one unit per login user, same as firstmate.
#
# The board itself (~/.hermes/kanban.db) is declared here too - see the
# hermesKanbanInit activation below. A fresh host has no board, and nothing
# else in the repo creates one.
#
# Deliberately NOT the alps module: modules/dev/hermes-alps-services.nix owns
# the full-brain services (vision-bridge, baileys-watch, qmd, host CUPS) that
# only exist on the joy host. This is the single unit the curated home needs.
#
# Shape follows the repo's browser-proxy user services
# (modules/dev/browser-proxy-{linux,windows}.nix): a plain systemd --user
# service the login user runs, Restart=always, WantedBy=default.target. It is
# NOT installed with `hermes gateway install`: the declarative unit is the
# source of truth, and `hermes` recognizes it as its own service
# (get_systemd_unit_path() is ~/.config/systemd/user/hermes-gateway.service for
# the default profile).
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

  # PATH is declared explicitly because systemd --user units do not read the
  # login shell profile: ~/.local/bin first (the hermes CLI, npm globals,
  # curl-installed tools), then the NixOS per-user profile where home.packages
  # land on the wsl host (useUserPackages = true - hermes-expert-new, pass-axi,
  # hermes-browse, recover-page, jq, python3, ...), then the rest of the
  # nix/userland dirs. On the standalone-home-manager Arch hosts (laptop,
  # server) ~/.nix-profile/bin is where home.packages land and
  # /etc/profiles/per-user/<user>/bin simply does not exist - harmless. Without
  # these the dispatcher-spawned workers could not find hermes-expert-new or
  # the pass / browse CLIs.
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

  # Browser backend, declared by the host through
  # modules/dev/hermes-curated.nix (hermesCurated.browserProxyUnit). Empty on a
  # headless host (server): no ordering dependency and no BROWSER_CDP_URL, so
  # the unit never advertises a CDP endpoint that cannot exist.
  browserProxyUnit = config.hermesGateway.browserProxyUnit;
in
{
  options.hermesGateway.browserProxyUnit = lib.mkOption {
    type = lib.types.str;
    default = "";
    example = "browser-proxy-windows.service";
    description = ''
      The systemd --user unit providing this host's local CDP browser backend.
      When set, the gateway orders itself `After` that unit and exports
      `BROWSER_CDP_URL`; when empty (headless host) neither is declared.
    '';
  };

  config.systemd.user.services.hermes-gateway = {
    Unit = {
      Description = "Hermes AI Agent Gateway - kanban dispatcher + messaging";
      After = [ "network-online.target" ] ++ lib.optional (browserProxyUnit != "") browserProxyUnit;
    };

    Service = {
      ExecStart = "${hermesBin} gateway run --external-supervisor";
      Environment = [
        "HOME=${homeDir}"
        "HERMES_HOME=${hermesHome}"
        "PATH=${pathEnv}"
      ] ++ lib.optional (browserProxyUnit != "") (
        # Route browser automation to the local CDP proxy, same contract as
        # browser.cdp_url in the config seed.
        "BROWSER_CDP_URL=http://localhost:3333"
      );
      Restart = "always";
      RestartSec = 5;
    };

    Install = {
      WantedBy = [ "default.target" ];
    };
  };

  # The dispatcher drains a board: `hermes gateway run` promotes ready cards
  # and spawns their assignee workers, and the orchestrator's kanban tools all
  # read `~/.hermes/kanban.db`. A fresh host has none, so the board must be
  # created on first activation or the fleet has nothing to drain. Declared
  # here, next to the dispatcher it exists for - the alps full brain keeps its
  # own lifecycle and does not import this module.
  #
  # `hermes kanban init` is documented idempotent ("Create kanban.db if
  # missing") and also re-runs the additive migration pass, so an existing
  # board is preserved and an older one is brought current; re-running on every
  # activation is safe. Runs after hermesAgentInstall (which exposes the
  # `hermes` CLI) and hermesHomeInstantiate (which creates ~/.hermes), and is
  # warn-not-die like the repo's other hermes activations, so an offline or
  # first-run install never breaks activation.
  config.home.activation.hermesKanbanInit =
    lib.hm.dag.entryAfter [ "hermesAgentInstall" "hermesHomeInstantiate" ] ''
      PATH="$HOME/.local/bin:$PATH"
      export HERMES_HOME=${lib.escapeShellArg hermesHome}
      if ! command -v hermes >/dev/null 2>&1; then
        echo "warning: hermes CLI not on PATH yet - kanban board init skipped (rerun activation once hermes has installed)" >&2
      else
        $DRY_RUN_CMD hermes kanban init \
          || echo "warning: could not initialize the kanban board - retry later with: hermes kanban init" >&2
      fi
    '';
}
