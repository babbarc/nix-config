{ config, lib, pkgs, ... }:
let
  hermesHome = "${config.home.homeDirectory}/.hermes";

  # Repo-vendored native Hermes plugins for the curated (wsl) instance,
  # restored on every rebuild - same posture as modules/dev/hermes-skills.nix
  # and modules/dev/hermes-soul.md.
  #
  # pass-enforcement: a `pre_tool_call` hook that structurally blocks the
  # secret-dumping `pass` forms (`pass show <path>` and a bare `pass <path>`,
  # which `pass` treats as show) in the `terminal` toolset. Defense-in-depth
  # for the pass-access / web-login design (captain decision #8, DD7 cap.3 of
  # data/hermes-axi-skills-design/report.md): the operating agent cannot dump a
  # stored secret to stdout / the transcript even outside the sanctioned
  # `pass-axi` (pass-access) and `hermes-web-login` (web-login) paths. The
  # config shell-hook mechanism only expresses block/modify, so a plugin hook
  # is the correct owner.
  pluginsSrc = ./hermes-plugins;
  pluginNames = builtins.attrNames
    (lib.filterAttrs (_: t: t == "directory") (builtins.readDir pluginsSrc));
in
{
  # Hermes discovers directory plugins under {HERMES_HOME}/plugins/<name>/
  # (each a dir with plugin.yaml + __init__.py). Unlike skills, a plugin is
  # opt-in: it must also be listed in config.yaml `plugins.enabled` to load -
  # hence the `hermes plugins enable` step below.
  #
  # Runs after hermesHomeInstantiate (creates ~/.hermes and its real plugins/
  # dir) and after hermesAgentInstall (puts the `hermes` CLI on PATH).
  home.activation.hermesPluginsInstall =
    lib.hm.dag.entryAfter [ "hermesHomeInstantiate" "hermesAgentInstall" ] ''
      PATH="$HOME/.local/bin:$PATH"
      export HERMES_HOME=${lib.escapeShellArg hermesHome}
      _home=${lib.escapeShellArg hermesHome}

      $DRY_RUN_CMD mkdir -p "$_home/plugins"

      # Drop plugin symlinks left by an older clone-instantiated generation
      # (e.g. the private approval-gates / gemini-web plugins), so nothing under
      # ~/.hermes references the clone. Only symlinks whose target is the legacy
      # clone are removed - real plugin dirs and this repo's plugins are never
      # touched.
      find "$_home/plugins" -maxdepth 1 -type l 2>/dev/null | while read -r _link; do
        case "$(readlink "$_link" 2>/dev/null)" in
          *joy-brain*) $DRY_RUN_CMD rm -f "$_link" ;;
        esac
      done

      # Materialize this repo's plugins as child symlinks into the nix store.
      for _p in ${lib.escapeShellArgs pluginNames}; do
        $DRY_RUN_CMD ln -sfn "${pluginsSrc}/$_p" "$_home/plugins/$_p"
      done

      # Enable pass-enforcement idempotently. --no-allow-tool-override: the
      # plugin only registers a pre_tool_call hook, it never replaces a
      # built-in tool, so the privileged tool-override grant is declined (this
      # also skips the interactive consent prompt). Warn-not-die and guarded on
      # the hermes CLI existing - same posture as the other hermes activations.
      if ! command -v hermes >/dev/null 2>&1; then
        echo "warning: hermes CLI not on PATH yet - pass-enforcement enable skipped (rerun activation once hermes has installed)" >&2
      else
        $DRY_RUN_CMD hermes plugins enable pass-enforcement --no-allow-tool-override \
          || echo "warning: could not enable the pass-enforcement plugin - retry later with: hermes plugins enable pass-enforcement --no-allow-tool-override" >&2
      fi
    '';
}
