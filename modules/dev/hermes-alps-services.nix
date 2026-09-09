{ config, lib, pkgs, ... }:
let
  homeDir = config.home.homeDirectory;
  hermesHome = "${homeDir}/.hermes";
  joyBrainDir = "${homeDir}/.local/share/joy-brain";
  # The engine module (modules/dev/hermes-agent.nix) symlinks the venv CLI
  # here; the gateway unit execs that same entry point a human would run.
  hermesBin = "${homeDir}/.local/bin/hermes";

  # The direct-install PATH fixup (replaces the container's cont-init.d/
  # 03-hermes-path). systemd --user units do NOT read the login shell profile,
  # so every unit below declares this PATH explicitly. Prepend joy's per-user
  # tool dirs (~/.npm-global/bin holds the Claude Code CLI vision-bridge tries
  # first; ~/.local/bin holds the hermes CLI, qmd and other npm-installed
  # tools; ~/bin is the container's legacy user-bin dir) ahead of the nix
  # profile dirs (home.packages: node, python3, git, pass, ...) and the FHS
  # host paths (host Chrome, host binaries).
  pathEnv = lib.concatStringsSep ":" [
    "${homeDir}/.npm-global/bin"
    "${homeDir}/.local/bin"
    "${homeDir}/bin"
    "${homeDir}/.nix-profile/bin"
    "/nix/var/nix/profiles/default/bin"
    "/usr/local/bin"
    "/usr/bin"
    "/bin"
  ];

  # The baileys watcher dumps libsignal SessionEntry key material (ratchet
  # root/chain keys, ephemeral/identity/pairing/noise keys, advSecretKey) to
  # stdout on every WhatsApp session rotation - a key-disclosure path to anyone
  # who can read the service journal (F9). The watcher code is not ours to
  # change from this repo, so filter its stdout exactly like the container's
  # baileys-watch-log s6 consumer: drop whole lines carrying Signal-protocol
  # key material, pass everything else through unbuffered. Replicating the s6
  # producer->consumer pair as one pipeline is fine because systemd restarts
  # the whole unit when the watcher exits.
  baileysWatchScript = pkgs.writeShellScript "hermes-baileys-watch" ''
    ${pkgs.nodejs_24}/bin/node ${joyBrainDir}/scripts/whatsapp-poll/baileys-watch.js \
      | ${pkgs.gnugrep}/bin/grep --line-buffered -a -v -E 'SessionEntry|_sessions|currentRatchet|ephemeralKeyPair|pairingEphemeralKeyPair|noiseKey|advSecretKey|adv_secret_key|signedIdentityKey|signedPreKey|pendingPreKey|"(root|chain|base|priv)Key"|myAppStateKeyId'
  '';

  # qmd is installed at activation (below) via `npm install -g --prefix
  # ~/.local`, which lands the package at ~/.local/lib/node_modules/@tobilu/qmd
  # and a ~/.local/bin/qmd shim. Invoking node on the package's bin directly
  # avoids relying on the shim's `#!/usr/bin/env node` PATH lookup.
  qmdBin = "${homeDir}/.local/lib/node_modules/@tobilu/qmd/bin/qmd";
in
{
  # The alps direct-install long-running services, one systemd --user unit per
  # s6 longrun the joy-stack container supervised (see the overlay's
  # Containerfile.hermes and DEPLOY.md for the source-of-truth run scripts):
  #
  #   main-hermes (gateway)   -> hermes-gateway.service
  #   vision-bridge           -> hermes-vision-bridge.service
  #   baileys-watch(-log)     -> hermes-baileys-watch.service (filter inlined)
  #   qmd                     -> hermes-qmd.service (native @tobilu/qmd, Q2a)
  #   cupsd                   -> host system CUPS (Q3a, root one-time - NOT a
  #                              per-user unit; see the PR body)
  #
  # Unit names are deliberately distinct from the podman quadlet-generated
  # units (hermes.service / browser-proxy.service / qmd.service) so the direct
  # units and the still-running container units can coexist until the Phase D
  # cut-over (stop container units, start direct units).

  # ---------------------------------------------------------------------------
  # qmd - native @tobilu/qmd (Q2a). Pinned to the same major line the joy-stack
  # qmd image built at BASE_TAG=v2026.8.31. `qmd mcp --http` binds
  # localhost:8181, matching joy-brain config.yaml's
  # mcp_servers.qmd.url = http://localhost:8181/mcp. State lives under
  # ~/.cache/qmd and ~/.config/qmd (index.yml points at the host joy-brain dir;
  # migrated from the qmd-data volume in Phase C/D - not this repo's job).
  home.activation.hermesQmdInstall = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    $DRY_RUN_CMD ${pkgs.nodejs_24}/bin/npm install --prefix "${homeDir}/.local" -g @tobilu/qmd@2.8.3 \
      || echo "warning: could not install @tobilu/qmd (offline?) - retry later: npm install --prefix ${homeDir}/.local -g @tobilu/qmd@2.8.3" >&2
  '';

  systemd.user.services.hermes-qmd = {
    Unit = {
      Description = "QMD Vector Store - local semantic search MCP server";
      After = [ "network-online.target" ];
    };
    Service = {
      ExecStart = "${pkgs.nodejs_24}/bin/node ${qmdBin} mcp --http";
      Environment = [
        "HOME=${homeDir}"
        "PATH=${pathEnv}"
        # node-llama-cpp keeps its native log noise off the MCP stdio channel;
        # over the HTTP transport this only quiets the journal.
        "LLAMA_LOG_LEVEL=error"
        "GGML_LOG_LEVEL=error"
      ];
      Restart = "always";
      RestartSec = 5;
    };
    Install = { WantedBy = [ "default.target" ]; };
  };

  # ---------------------------------------------------------------------------
  # Gateway - the main agent process. Mirrors the container's `Exec=gateway run`
  # (routed to `hermes gateway run`), with --external-supervisor so systemd
  # owns it and in-chat restarts/updates exit back to the unit instead of
  # spawning a detached replacement.
  systemd.user.services.hermes-gateway = {
    Unit = {
      Description = "Hermes AI Agent Gateway";
      After = [
        "network-online.target"
        "hermes-browser-proxy.service"
        "hermes-qmd.service"
      ];
    };
    Service = {
      ExecStart = "${hermesBin} gateway run --external-supervisor";
      Environment = [
        "HOME=${homeDir}"
        "HERMES_HOME=${hermesHome}"
        "PATH=${pathEnv}"
        # Route all browser automation to the local browser proxy.
        "BROWSER_CDP_URL=http://localhost:3333"
      ];
      Restart = "always";
      RestartSec = 5;
    };
    Install = { WantedBy = [ "default.target" ]; };
  };

  # ---------------------------------------------------------------------------
  # vision-bridge - OpenAI-compatible vision proxy at 127.0.0.1:9877. Tries the
  # Claude Code CLI (~/.npm-global/bin/claude) first, falls back to the Gemini
  # API via pass (pallav/gemini.key). Pure-stdlib script; needs python3, pass
  # and (optionally) the Claude Code CLI on PATH.
  systemd.user.services.hermes-vision-bridge = {
    Unit = {
      Description = "Hermes Vision Bridge - OpenAI-compatible vision proxy :9877";
      After = [ "network-online.target" ];
    };
    Service = {
      ExecStart = "${pkgs.python3}/bin/python3 ${joyBrainDir}/scripts/vision-bridge.py";
      Environment = [
        "HOME=${homeDir}"
        "PATH=${pathEnv}"
      ];
      Restart = "on-failure";
      RestartSec = 5;
    };
    Install = { WantedBy = [ "default.target" ]; };
  };

  # ---------------------------------------------------------------------------
  # baileys-watch - persistent WhatsApp connection. The watcher's node deps
  # (@whiskeysockets/baileys etc.) live in the joy-brain tree's gitignored
  # node_modules/ (scripts/whatsapp-poll/node_modules), which is runtime state
  # migrated from the hermes-data volume in Phase C/D, not installed here.
  systemd.user.services.hermes-baileys-watch = {
    Unit = {
      Description = "Hermes WhatsApp Watch - persistent Baileys connection";
      After = [ "network-online.target" ];
    };
    Service = {
      ExecStart = "${baileysWatchScript}";
      Environment = [
        "HOME=${homeDir}"
        "HERMES_HOME=${hermesHome}"
        "PATH=${pathEnv}"
      ];
      Restart = "always";
      RestartSec = 5;
    };
    Install = { WantedBy = [ "default.target" ]; };
  };
}
