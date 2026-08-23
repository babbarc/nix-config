{ config, lib, pkgs, ... }:
let
  managedDefaults = {
    theme = "rose-pine-moon";
    hideThinkingBlock = true;
    steeringMode = "all";
    followUpMode = "all";
  };
  settingsDefaultsFile = pkgs.writeText "pi-settings-defaults.json" (builtins.toJSON managedDefaults);
  settingsPath = "${config.home.homeDirectory}/.pi/agent/settings.json";
  dotfiles = "${config.home.homeDirectory}/.dotfiles";
in
{
  home.packages = with pkgs; [
    pi-coding-agent
  ];

  # settings.json mixes genuinely-user fields (theme, hideThinkingBlock,
  # steeringMode, followUpMode) with fields pi itself writes at runtime
  # (defaultProvider/defaultModel on interactive model switches;
  # lastChangelogVersion on changelog view). A home.file symlink would make
  # the whole file read-only and break those writes, so this merges the
  # managed defaults into the existing file on every switch instead of
  # replacing it — jq's `*` keeps the right-hand object's keys, and any
  # left-hand key not present on the right (i.e. every pi-written field)
  # survives untouched.
  home.activation.piSettings = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    settings_file="${settingsPath}"
    $DRY_RUN_CMD mkdir -p "$(dirname "$settings_file")"
    if [ -f "$settings_file" ]; then
      if [ -n "$DRY_RUN_CMD" ]; then
        $DRY_RUN_CMD ${pkgs.jq}/bin/jq -s '.[0] * .[1]' "$settings_file" ${settingsDefaultsFile}
      else
        # Guarded by the DRY_RUN_CMD check above so --dry-run never touches the
        # filesystem here: the shell's `>` redirection would otherwise create
        # $settings_file.tmp regardless of what $DRY_RUN_CMD prefixes the
        # command with. On jq failure, clean up the (truncated) tmp file
        # instead of leaving it to clutter/interfere on the next switch.
        ${pkgs.jq}/bin/jq -s '.[0] * .[1]' \
          "$settings_file" ${settingsDefaultsFile} \
          > "$settings_file.tmp" || { rm -f "$settings_file.tmp"; exit 1; }
        mv "$settings_file.tmp" "$settings_file"
      fi
    else
      # install -m 644, not cp: ${settingsDefaultsFile} is a pkgs.writeText
      # output (mode 0444 in the nix store), and plain `cp` propagates that
      # read-only mode to the fresh destination on this machine's coreutils —
      # which would hand pi a read-only settings.json on first run, the exact
      # failure mode this activation-script design exists to avoid.
      $DRY_RUN_CMD install -m 644 ${settingsDefaultsFile} "$settings_file"
    fi
  '';

  # Self-authored extensions/themes only - never third-party package code.
  # Out-of-store symlinks (not xdg.configFile) so editing a file here and
  # running Pi's `/reload` picks it up immediately, no `home-manager switch`
  # needed, while still keeping the source git-tracked and reproducible.
  #
  # Third-party Pi packages are deliberately NOT vendored through Nix: pin them
  # by exact npm version / git commit in a `packages` array added to
  # managedDefaults above (merged in the same way as the other fields), and
  # let Pi's own installer manage the downloaded trees in its unmanaged
  # ~/.pi/agent/npm and ~/.pi/agent/git - don't try to wrap that in a
  # derivation.
  home.file.".pi/agent/extensions".source =
    config.lib.file.mkOutOfStoreSymlink "${dotfiles}/pi/extensions";
  home.file.".pi/agent/themes".source =
    config.lib.file.mkOutOfStoreSymlink "${dotfiles}/pi/themes";

  # Single source of truth for agent instructions, consumed by every agent
  # runtime on this machine: pi reads ~/.pi/agent/AGENTS.md for its global
  # context, claude reads ~/.claude/CLAUDE.md, codex reads ~/.codex/AGENTS.md.
  # Same out-of-store symlink pattern as the extensions/themes above, so an
  # edit here is picked up on the next session (pi: /reload, claude/codex:
  # restart) without a home-manager switch. Adapted from kunchenguid/dotfiles
  # home.nix; opencode is deliberately omitted, it is not installed here.
  home.file.".pi/agent/AGENTS.md".source =
    config.lib.file.mkOutOfStoreSymlink "${dotfiles}/pi/AGENTS.md";
  home.file.".claude/CLAUDE.md".source =
    config.lib.file.mkOutOfStoreSymlink "${dotfiles}/pi/AGENTS.md";
  home.file.".codex/AGENTS.md".source =
    config.lib.file.mkOutOfStoreSymlink "${dotfiles}/pi/AGENTS.md";
}
