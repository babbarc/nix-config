{ config, lib, pkgs, ... }:
{
  # ~/firstmate is a plain git clone (github:kunchenguid/firstmate), not
  # nix-tracked — same posture as ~/.dotfiles itself and wezterm's upstream
  # config clone (see wezterm.nix). Update it via firstmate's own
  # /updatefirstmate skill or `git pull`, not via this module.
  #
  # Pi's firstmate-supervision watcher extension lives inside that clone
  # (~/firstmate/.pi/extensions/*.ts) and auto-loads once `pi` is launched
  # from ~/firstmate and the project trust prompt is approved once — no nix
  # wiring needed for it.
  home.packages = with pkgs; [
    gh   # firstmate requires `gh auth login` for PR creation
    jq   # required by the herdr runtime backend for JSON responses
  ];

  # home.sessionVariables only reaches interactive shells (via
  # hm-session-vars) — same gap nix/modules/session-path.nix documents for
  # PATH: systemd --user never sources that file, so anything launched
  # outside a shell wouldn't see these. Not an issue today since firstmate
  # and herdr are both terminal-launched here, not GUI-launched. If that ever
  # changes (a .desktop entry, a systemd unit), FM_HOME/FM_BACKEND would need
  # their own environment.d fix the way session-path.nix does for PATH.
  home.sessionVariables = {
    FM_HOME = "${config.home.homeDirectory}/firstmate";
    # Pins the runtime backend declaratively instead of relying on
    # HERDR_ENV auto-detection, per firstmate's backend precedence
    # (docs/configuration.md: --backend flag > FM_BACKEND > config/backend
    # file > auto-detect > default tmux).
    FM_BACKEND = "herdr";
  };

  # One-time bootstrap: clone firstmate on a fresh machine. Never touch the
  # directory again once it exists — it holds the captain's own in-progress
  # work, not something this module should ever overwrite or update.
  # `||`-guarded so a failed clone (no network) only warns on stderr instead
  # of failing the whole `home-manager switch`; see agent-cli-tools.nix for
  # the same posture applied to treehouse/no-mistakes/the axi suite.
  home.activation.firstmateClone = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    firstmate_dir="${config.home.homeDirectory}/firstmate"
    if [ ! -d "$firstmate_dir" ]; then
      $DRY_RUN_CMD ${pkgs.git}/bin/git clone https://github.com/kunchenguid/firstmate.git "$firstmate_dir" \
        || echo "warning: could not clone firstmate into $firstmate_dir (offline?) - retry later with: git clone https://github.com/kunchenguid/firstmate.git $firstmate_dir" >&2
    fi
  '';

  # gh auth login is an interactive OAuth device-code flow - it is never
  # scripted here. This only prints a one-line reminder when not yet
  # authenticated; it never blocks or fails the switch either way.
  home.activation.ghAuthReminder = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    ${pkgs.gh}/bin/gh auth status >/dev/null 2>&1 \
      || echo "hint: run 'gh auth login' to authenticate the GitHub CLI (firstmate needs it for PR creation)" >&2
  '';
}
