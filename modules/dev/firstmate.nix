{ config, lib, pkgs, ... }:
{
  # ~/firstmate is a plain git clone (github:babbarc/firstmate), not
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

  # One-time bootstrap: clone firstmate on a fresh machine. Never touch an
  # existing clone - it holds the captain's own in-progress work, not
  # something this module should ever overwrite, stash, or update.
  #
  # The guard is the clone itself (a `.git` dir), not just the directory: a
  # partial clone or a same-named non-git directory is repaired by cloning,
  # where an `-d` guard would leave it broken forever. A clone that exists but
  # points at a different upstream is only *reported* and left alone - this
  # module never rewrites a remote, and only the canonical https URL counts as
  # the expected upstream (an equivalent ssh-form clone therefore warns rather
  # than being silently accepted).
  # `||`-guarded so a failed clone (no network) only warns on stderr instead
  # of failing the whole `home-manager switch`; see agent-cli-tools.nix for
  # the same posture applied to treehouse/no-mistakes/the axi suite.
  home.activation.firstmateClone = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    firstmate_dir="${config.home.homeDirectory}/firstmate"
    firstmate_url="https://github.com/babbarc/firstmate.git"
    # Repo identity, not spelling: a trailing slash or ".git" is not a
    # different upstream.
    firstmate_expected="https://github.com/babbarc/firstmate"
    if [ ! -d "$firstmate_dir/.git" ]; then
      $DRY_RUN_CMD ${pkgs.git}/bin/git clone "$firstmate_url" "$firstmate_dir" \
        || echo "warning: could not clone firstmate into $firstmate_dir (offline?) - retry later with: git clone $firstmate_url $firstmate_dir" >&2
    else
      firstmate_remote="$(${pkgs.git}/bin/git -C "$firstmate_dir" config --get remote.origin.url 2>/dev/null \
        | ${pkgs.gnused}/bin/sed -e 's#/*$##' -e 's#\.git$##')"
      if [ -z "$firstmate_remote" ]; then
        echo "warning: $firstmate_dir exists but has no remote.origin.url - leaving it untouched (expected $firstmate_url)" >&2
      elif [ "$firstmate_remote" != "$firstmate_expected" ]; then
        echo "warning: $firstmate_dir is a clone of '$firstmate_remote', not $firstmate_url - leaving it untouched" >&2
      fi
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
