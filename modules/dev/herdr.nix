{ config, lib, pkgs, ... }:

let
  # herdr has no nixpkgs package (no binary cache; a from-source build would
  # duplicate upstream's own release pipeline). It ships as a single binary on
  # GitHub releases, so the cleanest reproducible path is a pinned fetchurl of
  # the exact release asset. The pin only governs the fresh-machine bootstrap:
  # the installed copy self-updates at runtime via `herdr update`, which this
  # module never fights (it only installs when herdr is missing).
  #
  # Pinned to 0.8.2 (protocol 20) - the version running live on the NixOS-WSL
  # host and verified against firstmate's herdr backend, whose floor is
  # protocol 14 (jq + herdr; python3 only for the optional protocol-16 event
  # push/presentation ordering). Both hashes come from herdr.dev/latest.json's
  # per-release asset manifest (github.com/herdrdev/herdr).
  herdrVersion = "0.8.2";
  herdrArch = if pkgs.stdenv.hostPlatform.isAarch64 then "aarch64" else "x86_64";
  herdrBin = pkgs.fetchurl {
    url = "https://github.com/herdrdev/herdr/releases/download/v${herdrVersion}/herdr-linux-${herdrArch}";
    sha256 = if herdrArch == "aarch64"
      then "sha256-9VYQZY4cLg0qrvcwtLKriF9/i6AChas3K/sU8uPVtA0="
      else "sha256-l2FQoU1JDJSyQ+ouGn6y37Z/EuNrGC25CTb2co5q7PQ=";
  };
in
{
  # session.json, .plugins.lock, and the two .log files are runtime-written
  # and stay unmanaged plain files - same split already used for lazygit's
  # config.yml/state.yml. herdr's own config.toml is chezmoi-managed (see
  # chezmoi/dot_config/herdr/config.toml.tmpl), not this module.
  #
  # Fish is the default shell on every host (modules/dev/fish.nix). On the wsl
  # host `programs.fish.enable` + `home-manager.useUserPackages = true` put
  # fish at /etc/profiles/per-user/<user>/bin/fish, which is what herdr's
  # chezmoi-managed [terminal] default_shell points at. The integration hook
  # scripts below are deliberately POSIX `sh` + `python3` (invoked via
  # explicit `bash`/`sh` in each harness's own hook wiring), so they resolve
  # regardless of the pane shell being fish. Their runtime deps are declared
  # elsewhere and imported on every host: python3
  # (modules/dev/dev-toolchains.nix) and jq (modules/dev/firstmate.nix, which
  # firstmate's herdr backend also requires).

  # One-time bootstrap: install the pinned herdr binary into ~/.local/bin only
  # when it is not already on PATH, so a fresh machine's first switch doesn't
  # need a manual command and a later `herdr update` is never overwritten by a
  # switch. Activation scripts replace PATH with pinned store utils only, so
  # prepend ~/.local/bin so an already-installed herdr is seen by the guard.
  home.activation.herdrInstall = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    PATH="$HOME/.local/bin:$PATH"
    if ! command -v herdr >/dev/null 2>&1; then
      if [ -n "$DRY_RUN_CMD" ]; then
        echo "$DRY_RUN_CMD would install pinned herdr ${herdrVersion} to $HOME/.local/bin/herdr"
      else
        mkdir -p "$HOME/.local/bin"
        install -m 755 ${herdrBin} "$HOME/.local/bin/herdr" \
          || echo "warning: herdr install failed - retry later with: curl -fsSL https://herdr.dev/install.sh | sh" >&2
      fi
    fi
  '';

  # Install herdr's per-harness integration files (hook scripts/plugins and
  # the small harness-config edits that wire them) for every harness the
  # windows-mcp selector supports plus pi, so a fresh machine gets them
  # without a manual `herdr integration install <target>` per harness. Same
  # guard posture as herdrInstall above: skip cleanly (don't fail the switch)
  # if `herdr` isn't on PATH yet or if an individual install errors.
  #
  # Per-target notes (verified against herdr 0.8.2 and its integrations doc):
  #   pi       -> ~/.pi/agent/extensions/herdr-agent-state.ts   (lifecycle authority)
  #   claude   -> ~/.claude/hooks/ + settings.json              (session identity)
  #   codex    -> ~/.codex/ + hooks.json + config.toml          (session identity)
  #   kimi     -> ~/.kimi-code/hooks/ + config.toml [[hooks]]   (lifecycle + session)
  #   opencode -> ~/.config/opencode/plugins/ + tui.jsonc       (lifecycle + session)
  #   grok     -> ~/.grok/hooks/ (herdr.json + .sh)             (session identity)
  # Each target's config dir must already exist; herdr creates the leaf
  # subdir itself but not the config dir, and on a fresh machine those dirs
  # don't exist until chezmoi materializes dotfiles AFTER activation.
  home.activation.herdrIntegrations = lib.hm.dag.entryAfter [ "herdrInstall" ] ''
    PATH="$HOME/.local/bin:$PATH"
    if command -v herdr >/dev/null 2>&1; then
      mkdir -p \
        "$HOME/.pi/agent/extensions" \
        "$HOME/.claude/hooks" \
        "$HOME/.codex" \
        "$HOME/.kimi-code/hooks" \
        "$HOME/.config/opencode/plugins" \
        "$HOME/.grok/hooks"
      herdrStatus="$(herdr integration status 2>/dev/null)"
      for target in pi claude codex kimi opencode grok; do
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
