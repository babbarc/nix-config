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
  # is the correct owner. Precedent for the hook shape: the bundled
  # `approval-gates` plugin.
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
  # Runs after joyBrainInstantiate (creates ~/.hermes and, on the curated
  # instance, symlinks the whole ~/.hermes/plugins dir into the joy-brain
  # clone) and after hermesAgentInstall (puts the `hermes` CLI on PATH).
  home.activation.hermesPluginsInstall =
    lib.hm.dag.entryAfter [ "joyBrainInstantiate" "hermesAgentInstall" ] ''
      PATH="$HOME/.local/bin:$PATH"
      export HERMES_HOME=${lib.escapeShellArg hermesHome}
      _home=${lib.escapeShellArg hermesHome}

      # joyBrainInstantiate symlinks {HERMES_HOME}/plugins as ONE dir symlink
      # into the joy-brain clone (its `for _d in ... plugins ...` loop). That
      # makes the parent read-only for our purposes, so convert it once to a
      # real directory that keeps the clone's plugins as individual child
      # symlinks - exactly the shape the curated instance's skills/ dir already
      # has post-cutover. Idempotent: only fires while plugins/ is still a
      # symlink.
      if [ -L "$_home/plugins" ]; then
        _clone_plugins="$(readlink -f "$_home/plugins" 2>/dev/null || true)"
        $DRY_RUN_CMD rm "$_home/plugins"
        $DRY_RUN_CMD mkdir -p "$_home/plugins"
        if [ -n "$_clone_plugins" ] && [ -d "$_clone_plugins" ]; then
          find "$_clone_plugins" -mindepth 1 -maxdepth 1 -type d | while read -r _p; do
            $DRY_RUN_CMD ln -sfn "$_p" "$_home/plugins/$(basename "$_p")"
          done
        fi
      fi
      $DRY_RUN_CMD mkdir -p "$_home/plugins"

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
