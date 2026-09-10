{ config, lib, pkgs, ... }:
let
  # Claude Code auto-compacts when context usage approaches its "auto-compact
  # window". The effective threshold is `min(autoCompactWindow, the model's
  # real max context window)` (verified against the installed CLI, 2.1.267:
  # "The actual threshold is the minimum of this setting and your model's
  # maximum context window"). The default `auto` picks a window tuned for
  # cost/performance that sits well below the model's real capacity, i.e. it
  # compacts early.
  #
  # Pinning the window to the top of the accepted range (100k-1M) makes the
  # `min()` collapse to the model's own context window on every model - so
  # compaction fires at real capacity, never prematurely, and never past what
  # the model can hold. This is the "correct the window" approach: match the
  # model's real window rather than trimming it.
  #
  # Persistence: the CLI stores this as the numeric `autoCompactWindow` key in
  # ~/.claude/settings.json (the `/config` flow writes `undefined` for `auto`
  # and the token count otherwise; `--autocompact` is the per-run form and
  # CLAUDE_CODE_AUTO_COMPACT_WINDOW the hard env override). settings.json also
  # holds keys Claude Code writes at runtime (theme, tui, ...) and the herdr
  # SessionStart hook (added by modules/dev/herdr.nix's `herdr integration
  # install claude`), so this merges the one managed key in with jq rather
  # than owning the file with a read-only symlink - same pattern the pi
  # settings.json merge used before it moved to chezmoi.
  autoCompactWindow = 1000000;
  claudeDefaults = { inherit autoCompactWindow; };
  claudeDefaultsFile =
    (pkgs.formats.json { }).generate "claude-settings-defaults.json" claudeDefaults;
  settingsPath = "${config.home.homeDirectory}/.claude/settings.json";
in
{
  # entryAfter "herdrIntegrations" so that on a fresh machine herdr's own
  # settings.json edit lands first and this merge preserves it; the merge is
  # additive either way (jq `*`, existing on the left, managed key on the
  # right), so the ordering is for determinism, not correctness.
  home.activation.claudeSettings =
    lib.hm.dag.entryAfter [ "writeBoundary" "herdrIntegrations" ] ''
      settings_file="${settingsPath}"
      $DRY_RUN_CMD mkdir -p "$(dirname "$settings_file")"
      if [ -f "$settings_file" ]; then
        if [ -n "$DRY_RUN_CMD" ]; then
          $DRY_RUN_CMD ${pkgs.jq}/bin/jq -s '.[0] * .[1]' "$settings_file" ${claudeDefaultsFile}
        else
          # Guarded by the DRY_RUN_CMD check above so --dry-run never writes:
          # the shell's `>` redirect would create the .tmp file regardless of
          # what $DRY_RUN_CMD prefixes. On jq failure, drop the truncated tmp
          # instead of leaving it for the next switch.
          ${pkgs.jq}/bin/jq -s '.[0] * .[1]' \
            "$settings_file" ${claudeDefaultsFile} \
            > "$settings_file.tmp" || { rm -f "$settings_file.tmp"; exit 1; }
          mv "$settings_file.tmp" "$settings_file"
        fi
      else
        # install -m 644, not cp: ${claudeDefaultsFile} is a nix-store file
        # (mode 0444), and plain cp would propagate that read-only mode and
        # hand Claude Code a read-only settings.json on first run.
        $DRY_RUN_CMD install -m 644 ${claudeDefaultsFile} "$settings_file"
      fi
    '';
}
