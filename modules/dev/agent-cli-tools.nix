{ lib, pkgs, ... }:
{
  # treehouse, no-mistakes, and the axi suite (gh-axi, chrome-devtools-axi,
  # lavish-axi, tasks-axi, quota-axi) plus gnhf follow the same posture as
  # herdr.nix: none are in nixpkgs, none have a binary cache, and each already
  # ships its own update path — building them from source in Nix would fight
  # that update path on every release instead of using it. This module
  # doesn't package the binaries; it bootstraps each one once per machine via
  # the guarded home.activation blocks below, then gets out of the way -
  # keeping them current is a manual `... update` command, not something a
  # switch does for you (see below).
  #
  # Each block only runs when its tool is missing from PATH, so a switch on
  # an already-bootstrapped machine stays a fast no-op rather than a network
  # call every time, and each is `||`-guarded so a failed curl/npm (e.g. no
  # network) only warns on stderr instead of failing the whole
  # `home-manager switch`.
  #
  # Every home-manager activation script starts by REPLACING PATH with only
  # pinned Nix store utilities (bash, coreutils, grep, sed, jq, ...) plus the
  # nix binary dir - it deliberately omits /usr/bin and ~/.local/bin. So each
  # block below re-prefixes PATH at the top: ~/.local/bin first (so the
  # `command -v` guards can see tools already bootstrapped at ~/.local/bin and
  # the block truly no-ops on an already-set-up machine, as promised above),
  # then the store-pinned tool dirs the piped installers invoke by bare name
  # (curl, plus tar and gzip for the tar.gz installers and awk for herdr's).
  #
  # npm-global.nix writes ~/.npmrc via home.file, but home.file content is
  # linked at "linkGeneration" - which runs AFTER these writeBoundary install
  # blocks on a first activation - so a first npm install cannot rely on
  # ~/.npmrc existing. That is why axiSuiteInstall passes --prefix
  # "$HOME/.local" explicitly: it keeps the install out of the read-only nix
  # store with no ordering dependency on npm-global.nix.
  #
  # Update (not automated - these tools self-update on their own cadence,
  # and re-running an installer/npm-install on every switch would turn a
  # fast no-op switch into a network call every time):
  #   treehouse update
  #   curl -fsSL https://raw.githubusercontent.com/kunchenguid/no-mistakes/main/docs/install.sh | sh   (no separate update command)
  #   npm update -g gh-axi chrome-devtools-axi lavish-axi tasks-axi quota-axi gnhf

  home.activation.treehouseInstall = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    # treehouse/install.sh needs curl and tar by bare name in the stripped
    # activation PATH (grep/sed/tr/uname are already pinned); ~/.local/bin
    # first so an already-installed treehouse is seen by the guard.
    PATH="$HOME/.local/bin:${pkgs.curl}/bin:${pkgs.gnutar}/bin:${pkgs.gzip}/bin:$PATH"
    if ! command -v treehouse >/dev/null 2>&1; then
      if [ -n "$DRY_RUN_CMD" ]; then
        echo "$DRY_RUN_CMD would install treehouse via: curl -fsSL https://kunchenguid.github.io/treehouse/install.sh | sh"
      else
        ${pkgs.curl}/bin/curl -fsSL https://kunchenguid.github.io/treehouse/install.sh | PATH="${pkgs.curl}/bin:${pkgs.gnutar}/bin:${pkgs.gzip}/bin:$PATH" sh \
          || echo "warning: treehouse install failed (offline?) - retry later with: curl -fsSL https://kunchenguid.github.io/treehouse/install.sh | sh" >&2
      fi
    fi
  '';

  home.activation.noMistakesInstall = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    # no-mistakes/install.sh needs curl and tar by bare name; ~/.local/bin
    # first so an already-installed no-mistakes is seen by the guard.
    PATH="$HOME/.local/bin:${pkgs.curl}/bin:${pkgs.gnutar}/bin:${pkgs.gzip}/bin:$PATH"
    if ! command -v no-mistakes >/dev/null 2>&1; then
      if [ -n "$DRY_RUN_CMD" ]; then
        echo "$DRY_RUN_CMD would install no-mistakes via: curl -fsSL https://raw.githubusercontent.com/kunchenguid/no-mistakes/main/docs/install.sh | sh"
      else
        ${pkgs.curl}/bin/curl -fsSL https://raw.githubusercontent.com/kunchenguid/no-mistakes/main/docs/install.sh | PATH="${pkgs.curl}/bin:${pkgs.gnutar}/bin:${pkgs.gzip}/bin:$PATH" sh \
          || echo "warning: no-mistakes install failed (offline?) - retry later with: curl -fsSL https://raw.githubusercontent.com/kunchenguid/no-mistakes/main/docs/install.sh | sh" >&2
      fi
    fi
  '';

  # A single `npm install -g` call installs the whole suite, so the guard
  # checks all six binaries and installs the whole batch if any is missing -
  # matching how the suite is installed and updated as one unit above.
  home.activation.axiSuiteInstall = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    # ~/.local/bin first so already-installed suite tools are seen by the
    # guard; curl's dir so the install can fetch if it needs to. The explicit
    # --prefix "$HOME/.local" keeps this out of the read-only nix store on a
    # first activation, without depending on ~/.npmrc (which home.file only
    # links later at linkGeneration).
    PATH="$HOME/.local/bin:${pkgs.curl}/bin:$PATH"
    axi_tools="gh-axi chrome-devtools-axi lavish-axi tasks-axi quota-axi gnhf"
    missing=0
    for t in $axi_tools; do
      command -v "$t" >/dev/null 2>&1 || missing=1
    done
    if [ "$missing" = 1 ]; then
      $DRY_RUN_CMD ${pkgs.nodejs_26}/bin/npm install --prefix "$HOME/.local" -g $axi_tools \
        || echo "warning: axi suite npm install failed (offline?) - retry later with: npm install --prefix "$HOME/.local" -g $axi_tools" >&2
    fi
  '';
}
