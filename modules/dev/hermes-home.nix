# Curated Hermes home for the wsl host - GENERIC and fully self-contained:
# every piece is generated here or vendored in this repo, with no dependency on
# a private external clone (and therefore no SSH to `alps` at deploy time). It
# is the wsl counterpart to modules/dev/joy-brain.nix, which keeps materializing
# the full private brain on alps - same `~/.hermes` (HERMES_HOME) contract,
# different source of truth.
#
# What it materializes, all repo-tracked or generated:
#   ~/.hermes/config.yaml   minimal seed (provider/model, web.search_backend,
#                           browser.cdp_url) then a per-rebuild deep-merge of
#                           browser.cdp_url so Hermes's runtime edits survive
#   ~/.hermes/SOUL.md       -> modules/dev/hermes-soul.md (re-pinned each run)
#   ~/.hermes/bin/pass-*    -> modules/dev/hermes-bin/ (vendored byte-for-byte
#                           from the clone's scripts/; the pass-access and
#                           web-login CLIs call these by absolute path)
#   ~/.hermes/{skills,plugins}  real dirs; hermes-skills.nix /
#                           hermes-plugins.nix fill them with the vendored,
#                           repo-tracked content
#
# The wsl host imports this INSTEAD of joy-brain.nix; the alps full brain does
# not import it. Nothing here references an SSH URL or the private clone.
{ config, lib, pkgs, ... }:
let
  hermesHome = "${config.home.homeDirectory}/.hermes";

  # Minimal seed for ~/.hermes/config.yaml. Deliberately the smallest set the
  # curated instance genuinely needs to run:
  #   - model: the LLM provider the agent calls (deepseek)
  #   - agent.max_turns: the operating budget
  #   - web.search_backend: the keyless ddgs backend (hermes-agent.nix installs
  #     `ddgs` into the Hermes venv and enables the plugin)
  #   - browser.cdp_url: the Windows-Chrome CDP proxy contract
  # Everything else Hermes fills from its own defaults, and any runtime edit
  # Hermes persists is preserved by the merge below. No personal keys
  # (memory, contacts, profiles, mcp_servers.qmd) ride along.
  minimalConfig = pkgs.writeText "hermes-home-config.yaml" ''
    model:
      default: deepseek-v4-flash
      provider: deepseek
      base_url: https://api.deepseek.com/
    agent:
      max_turns: 150
    web:
      search_backend: ddgs
    browser:
      cdp_url: "http://localhost:3333"
  '';

  # Deep-merged into ~/.hermes/config.yaml on every activation. `*` is yq's
  # merge operator (right-hand side wins), so only browser.cdp_url is forced
  # and every other key - the seed above plus Hermes's own runtime edits via
  # `hermes config set` / the TUI - survives a rebuild.
  browserOverride = pkgs.writeText "hermes-browser-cdp-override.yaml" ''
    browser:
      cdp_url: "http://localhost:3333"
  '';

  # Vendored byte-for-byte from the private clone's scripts/{pass-to.sh,
  # pass-inspect,pass-env.sh}. The pass-access (pass-axi) and web-login
  # (hermes-web-login) CLIs resolve them at $HERMES_HOME/bin/<name>.
  binSrc = ./hermes-bin;
  helperNames = [ "pass-to" "pass-inspect" "pass-env" ];
in
{
  home.activation.hermesHomeInstantiate = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    _home=${lib.escapeShellArg hermesHome}
    _yq=${pkgs.yq-go}/bin/yq

    # Drop clone-pointing dir symlinks left by an older clone-instantiated
    # generation, so this host carries no reference to the private clone.
    # Only symlinks whose target is the clone are removed - real dirs Hermes
    # or the agent created are never touched, and the clone's data itself is
    # left on disk (removing a symlink deletes nothing).
    for _d in bin contacts memory memories profiles scripts .hermes.md; do
      if [ -L "$_home/$_d" ]; then
        case "$(readlink "$_home/$_d" 2>/dev/null)" in
          *joy-brain*) $DRY_RUN_CMD rm -f "$_home/$_d" ;;
        esac
      fi
    done

    $DRY_RUN_CMD mkdir -p "$_home/bin" "$_home/skills" "$_home/plugins"

    # Drop stale skill symlinks from an older clone-instantiated generation, so
    # `hermes skills list` reflects only the repo-vendored set materialized by
    # modules/dev/hermes-skills.nix. Only links whose target is the legacy clone
    # are removed - never the vendored skills or anything the agent created.
    find "$_home/skills" -maxdepth 2 -type l 2>/dev/null | while read -r _link; do
      case "$(readlink "$_link" 2>/dev/null)" in
        *joy-brain*) $DRY_RUN_CMD rm -f "$_link" ;;
      esac
    done

    # config.yaml: first activation seeds the minimal config above; every
    # activation then deep-merges ONLY the browser.cdp_url override, so
    # Hermes's own runtime edits survive.
    if [ ! -e "$_home/config.yaml" ]; then
      $DRY_RUN_CMD cp ${lib.escapeShellArg minimalConfig} "$_home/config.yaml"
    fi
    if [ -e "$_home/config.yaml" ]; then
      $_yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' \
        "$_home/config.yaml" ${lib.escapeShellArg browserOverride} > "$_home/config.yaml.tmp" \
        && $DRY_RUN_CMD mv "$_home/config.yaml.tmp" "$_home/config.yaml"
    fi

    # Default-profile SOUL.md: the firstmate-delegated browser + Windows-desktop
    # specialist role tracked in this repo, re-pinned on every activation.
    $DRY_RUN_CMD ln -sfn ${./hermes-soul.md} "$_home/SOUL.md"

    # Materialize the vendored pass helpers the packaged CLIs call.
    for _h in ${lib.escapeShellArgs helperNames}; do
      $DRY_RUN_CMD ln -sfn "${binSrc}/$_h" "$_home/bin/$_h"
    done
  '';
}
