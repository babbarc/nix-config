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
  # place. The activation treats pi as installed only when that exact layout
  # is present at ~/.local/bin/pi (see the guard below) - a different pi that
  # merely satisfies `command -v`, e.g. a stale nix-store one earlier on PATH,
  # is not a managed install and no longer short-circuits the bootstrap.
  #
  # The launcher execs the release's node script, so pi needs node and
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
    # ~/.local/bin first so the installer links pi there and the validity
    # check below looks at the same entry point the login PATH resolves;
    # node/npm so its preflight passes without prompting (and for its
    # `npm ci`); curl for its release downloads.
    PATH="$HOME/.local/bin:${pkgs.nodejs_26}/bin:${pkgs.curl}/bin:$PATH"

    # The guard asks "is pi's MANAGED install present and sound?", not "is
    # some pi on PATH?" - a different pi that satisfies `command -v` (the
    # read-only /nix/store one this host used to carry, or a leftover
    # launcher with no release behind it) is exactly how a host drifts into
    # running a pi that `pi update --self` can never touch. So: the
    # ~/.local/bin/pi entry point must exist and resolve into pi's own
    # managed tree under ~/.pi/agent/.
    #
    # Two layouts count (both written by the official installer):
    # - entry point -> ~/.pi/agent/bin/pi, the launcher, which execs
    #   ~/.pi/agent/install/releases/$version/node_modules/.bin/pi (the usual
    #   one - the launcher lives next to, not inside, releases/), so the
    #   release named by install/current-version is checked for real;
    # - entry point -> a release build directly.
    # Anything else - missing, dangling, a plain file, a store path - is not
    # a managed install: (re)install it. On a healthy host this costs a few
    # readlinks and no network call.
    #
    # This guard is the single source of truth for "what is a managed pi
    # install?": setup.sh's verify_readiness() mirrors it (same two layouts,
    # same store/dangling/plain-file rejections) as pi_managed_install_ok() -
    # keep the two in lockstep when either layout changes.
    pi_agent_dir="$HOME/.pi/agent"
    pi_entrypoint="$HOME/.local/bin/pi"
    pi_managed_install_ok() {
      pi_real="$(${pkgs.coreutils}/bin/readlink -f "$pi_entrypoint" 2>/dev/null)" || return 1
      case "$pi_real" in
        "$pi_agent_dir"/install/releases/*)
          [ -x "$pi_real" ]
          ;;
        "$pi_agent_dir"/bin/pi)
          pi_version_file="$pi_agent_dir/install/current-version"
          [ -r "$pi_version_file" ] || return 1
          IFS= read -r pi_version < "$pi_version_file" || return 1
          case "$pi_version" in
            "" | . | .. | *[!0-9A-Za-z._+-]*) return 1 ;;
          esac
          [ -x "$pi_agent_dir/install/releases/$pi_version/node_modules/.bin/pi" ]
          ;;
        *)
          return 1
          ;;
      esac
    }

    if ! pi_managed_install_ok; then
      if [ -n "$DRY_RUN_CMD" ]; then
        echo "$DRY_RUN_CMD would install pi via: curl -fsSL ${piInstallUrl} | sh"
      else
        if command -v pi >/dev/null 2>&1; then
          echo "note: $(command -v pi) is not a managed pi install - installing/repairing $pi_entrypoint" >&2
        fi
        ${pkgs.curl}/bin/curl -fsSL ${piInstallUrl} \
          | TERM=dumb ${pkgs.util-linux}/bin/setsid -w sh \
          || echo "warning: pi install failed (offline?) - retry later with: curl -fsSL ${piInstallUrl} | sh" >&2
      fi
    fi
  '';
}
