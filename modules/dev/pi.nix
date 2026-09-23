{ lib, pkgs, ... }:
let
  piInstallUrl = "https://pi.dev/install.sh";
in
{
  # pi follows the same posture as treehouse, no-mistakes, and the axi suite
  # in agent-cli-tools.nix: bootstrapped once per machine by the guarded
  # activation below, then kept current by the host itself with
  # `pi update --self` (or `pi update --all`). It used to be
  # `home.packages = [ pkgs.pi-coding-agent ]`, which put a read-only
  # /nix/store pi first on PATH: `pi update --self` could not replace it, so
  # every host sat on whatever nixpkgs happened to pin.
  #
  # The official installer does a "managed install": releases land under
  # ~/.pi/agent/install/releases/<version>, a launcher at ~/.pi/agent/bin/pi,
  # and a symlink at ~/.local/bin/pi (it picks ~/.local/bin because it is
  # first on the PATH below). That layout is what `pi update --self` swaps in
  # place. The launcher execs the release's node script, so pi needs node and
  # npm on the login PATH at runtime and during `pi update`; the shared
  # modules/dev list provides both via dev-toolchains.nix (nodejs_26).
  #
  # The installer must never prompt during a switch:
  # - Without node/npm on PATH it offers an interactive "install Node.js"
  #   flow, so the pinned nodejs_26 is put on its PATH.
  # - Every prompt it has (install/reinstall menu, "add to PATH?") reads
  #   /dev/tty, not stdin, so redirecting stdin is not enough on its own.
  #   `setsid` detaches it from the controlling terminal: /dev/tty then fails
  #   to open and the installer takes its documented non-interactive defaults.
  # - TERM=dumb skips the full-screen logo animation and progress spinner,
  #   which would otherwise clear the terminal mid-switch.
  #
  # ~/.pi/agent/settings.json and ~/.pi/agent/models.json are now both
  # chezmoi-owned (see AGENTS.md "Chezmoi cutover"). models.json is the one
  # deliberate exception to "chezmoi owns the content outright": chezmoi
  # seeds it CREATE-ONLY (a starting point matching this module's former
  # `providers.deepseek.modelOverrides`), and the captain edits it freely
  # afterward - nix never touches it again. This module used to manage
  # models.json directly as a read-only `home.file` symlink (`force = true`);
  # that block is retired outright, not replaced, so a future `home-manager
  # switch` removes the symlink it used to own (home-manager only ever
  # cleans up paths present in a PREVIOUS generation's own manifest, never an
  # arbitrary plain file at the same path) and leaves chezmoi's seeded file
  # - or, on hosts that already carried a hand-written models.json predating
  # this module, that pre-existing plain file - untouched either way.
  #
  # The guide's three third-party extensions (pi-web-access,
  # @ryan_nookpi/pi-extension-codex-fast-mode, and the git source
  # algal/pi-openai-server-compaction) are pi-managed: `dotfiles` seeds them
  # into settings.json `packages`, so `pi update` keeps them current. Nothing
  # here packages them.
  home.activation.piInstall = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    # ~/.local/bin first so an already-installed pi is seen by the guard and
    # the installer links pi there; node/npm so its preflight passes without
    # prompting (and for its `npm ci`); curl for its release downloads.
    PATH="$HOME/.local/bin:${pkgs.nodejs_26}/bin:${pkgs.curl}/bin:$PATH"
    if ! command -v pi >/dev/null 2>&1; then
      if [ -n "$DRY_RUN_CMD" ]; then
        echo "$DRY_RUN_CMD would install pi via: curl -fsSL ${piInstallUrl} | sh"
      else
        ${pkgs.curl}/bin/curl -fsSL ${piInstallUrl} \
          | TERM=dumb ${pkgs.util-linux}/bin/setsid -w sh \
          || echo "warning: pi install failed (offline?) - retry later with: curl -fsSL ${piInstallUrl} | sh" >&2
      fi
    fi
  '';
}
