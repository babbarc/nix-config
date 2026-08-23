{ config, lib, pkgs, ... }:
{
  # herdr itself is deliberately outside Nix (not in nixpkgs, no binary
  # cache, would require a from-source build — see the parent nix-migration
  # project's Task 9). It stays installed via its own curl installer at
  # ~/.local/bin/herdr, self-updating via `herdr update` / `herdr channel
  # set`. This module never touches the binary beyond the one-time bootstrap
  # below - re-running the installer on every switch is left to `herdr
  # update`, not this module.
  #
  # Only config.toml is genuinely user config. session.json, .plugins.lock,
  # and the two .log files are runtime-written and stay unmanaged plain
  # files — same split already used for lazygit's config.yml/state.yml.
  #
  # Unlike lazygit's state.yml, though, config.toml itself isn't purely user
  # config either: herdr's own binary writes to it at runtime — logs a
  # `config.write` event, overlays settings changed from the in-app `prefix+s`
  # settings UI (onboarding/sound/toast/theme.auto_switch/agent-border-labels
  # toggles), and `herdr config reset-keys` explicitly backs up and rewrites
  # it. (`onboarding = false` on line 1 of this repo's copy is itself
  # evidence — herdr wrote that after first run.) Those writes will fail
  # against this read-only nix-store symlink, or, if herdr writes via
  # temp-file-then-rename, will silently replace the symlink with a plain
  # file that gets reverted back to the nix-managed version on the next
  # `home-manager switch`.
  #
  # Unlike pi.nix's settings.json — which has a clean split between a
  # handful of nix-managed fields and "everything else is runtime", making a
  # jq merge script viable — config.toml is ~325 lines of hand-customized
  # settings with only a few fields herdr occasionally rewrites, and the
  # exact full set of those fields isn't confirmed. A partial-merge script
  # against an incompletely-known field set risks silently dropping user
  # settings, which is worse than the current symlink, so the whole-file
  # symlink stays as a deliberate, documented tradeoff: to change any herdr
  # setting, edit ~/.dotfiles/herdr/config.toml directly and run
  # `home-manager switch` — don't rely on herdr's own settings UI or
  # `reset-keys` to persist changes.
  #
  # The shell path in config.toml is templated per-host: the repo's copy
  # carries a `__FISH_SHELL_PATH__` placeholder for `default_shell`, which
  # we substitute with this host's Nix-managed fish. We use the store path
  # ${pkgs.fish}/bin/fish rather than a profile-relative path: the store
  # path is absolute, hermetic, and identical on every host. The classic
  # ~/.nix-profile/bin/fish only exists on non-NixOS home-manager installs
  # (where packages land in the user's default nix profile); on NixOS
  # home-manager installs into /etc/profiles/per-user/<user>/bin instead,
  # so a profile-relative default_shell would break herdr panes on
  # NixOS-WSL. Because the config is regenerated on every switch, a fish
  # version bump in nixpkgs regenerates the path - no staleness.
  xdg.configFile."herdr/config.toml".text = builtins.replaceStrings
    [ "__FISH_SHELL_PATH__" ]
    [ "${pkgs.fish}/bin/fish" ]
    (builtins.readFile ../../../herdr/config.toml);

  # One-time bootstrap: install herdr itself via its curl installer if it's
  # not already on PATH, so a fresh machine's first switch doesn't need the
  # manual command from the README. `||`-guarded so a failed curl (no
  # network) only warns on stderr instead of failing the whole
  # `home-manager switch`.
  # Activation scripts replace PATH with pinned store utils only (no
  # /usr/bin, no ~/.local/bin), so prepend ~/.local/bin (so an already-
  # installed herdr is seen by the guard) plus curl and awk (gawk) - which
  # install.sh needs by bare name (`need curl; need awk`).
  home.activation.herdrInstall = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    PATH="$HOME/.local/bin:${pkgs.curl}/bin:${pkgs.gawk}/bin:$PATH"
    if ! command -v herdr >/dev/null 2>&1; then
      if [ -n "$DRY_RUN_CMD" ]; then
        echo "$DRY_RUN_CMD would install herdr via: curl -fsSL https://herdr.dev/install.sh | sh"
      else
        ${pkgs.curl}/bin/curl -fsSL https://herdr.dev/install.sh | PATH="${pkgs.curl}/bin:${pkgs.gawk}/bin:$PATH" sh \
          || echo "warning: herdr install failed (offline?) - retry later with: curl -fsSL https://herdr.dev/install.sh | sh" >&2
      fi
    fi
  '';
}
