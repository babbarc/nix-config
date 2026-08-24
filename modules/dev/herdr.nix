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
  # session.json, .plugins.lock, and the two .log files are runtime-written
  # and stay unmanaged plain files — same split already used for lazygit's
  # config.yml/state.yml. config.toml itself is now chezmoi-managed (see
  # chezmoi/dot_config/herdr/config.toml.tmpl), not this module.
  #
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

  # Install herdr's per-harness integration files (e.g.
  # ~/.pi/agent/extensions/herdr-agent-state.ts,
  # ~/.claude/hooks/herdr-agent-state.sh,
  # ~/.codex/herdr-agent-state.sh) for the three agent harnesses this repo
  # manages, so a fresh machine gets them without a manual `herdr
  # integration install <target>` per harness. Same guard posture as
  # herdrInstall above: skip cleanly (don't fail `home-manager switch`) if
  # `herdr` isn't on PATH yet (e.g. right after a fresh-machine bootstrap,
  # before herdrInstall above has run) or if an individual install errors.
  home.activation.herdrIntegrations = lib.hm.dag.entryAfter [ "herdrInstall" ] ''
    PATH="$HOME/.local/bin:$PATH"
    if command -v herdr >/dev/null 2>&1; then
      herdrStatus="$(herdr integration status 2>/dev/null)"
      for target in pi claude codex; do
        if echo "$herdrStatus" | grep -qi "^$target: not installed"; then
          if [ -n "$DRY_RUN_CMD" ]; then
            echo "$DRY_RUN_CMD would install herdr integration: herdr integration install $target"
          else
            herdr integration install "$target" \
              || echo "warning: herdr integration install $target failed - retry later with: herdr integration install $target" >&2
          fi
        fi
      done
    fi
  '';
}
