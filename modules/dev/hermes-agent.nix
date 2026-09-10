{ config, lib, pkgs, ... }:
let
  # Pinned upstream release. v2026.8.31 == pyproject 0.21.0 == revision
  # 29112bef099274229cadff79cdff7bf7b99c4b77 - the same base the joy-stack
  # container image builds from (see containers/systemd/hermes/hermes.container
  # and modules/hermes-joy-stack.nix). Do not bump casually: a newer base needs
  # the same review the joy-stack DEPLOY.md describes before adoption.
  hermesRev = "29112bef099274229cadff79cdff7bf7b99c4b77";
  hermesRepo = "https://github.com/NousResearch/hermes-agent.git";
  checkout = "${config.home.homeDirectory}/.local/share/hermes-agent";
  venv = "${checkout}/venv";
  hermesHome = "${config.home.homeDirectory}/.hermes";

  # Windows path of the Cua computer-use driver, installed per-user (no admin,
  # autostart off) by cua-driver-bootstrap.ps1 on the Windows host. This is
  # the captain's Windows user; %LOCALAPPDATA%\Programs\Cua is the fixed
  # install root the cua.ai installer uses. Change the `palla` segment for a
  # different Windows user.
  cuaDriverExe = ''C:\Users\palla\AppData\Local\Programs\Cua\cua-driver\bin\cua-driver.exe'';
in
{
  options.hermesAgent = {
    # The wsl host imports the shared modules/dev list (cli-tools.nix /
    # dev-toolchains.nix), so git/ripgrep/nodejs/python3/etc. are already
    # declared there and must not be repeated. The alps `hermes` host imports
    # NO shared modules (hosts/hermes/home.nix carries only its own modules),
    # so it opts into declaring the full runtime dependency set itself.
    standaloneDeps = lib.mkEnableOption "declare the full Hermes runtime dependency set (for hosts that do not import the shared modules/dev list)";

    # wsl-only: the Hermes agent there operates the Windows desktop through
    # cua-driver (registered as a Hermes MCP server, reached over
    # powershell.exe interop). Off elsewhere - the alps host has no Windows
    # side. See README "Hermes desktop control (Cua driver)".
    cuaDriver = lib.mkEnableOption "register the Cua computer-use driver as a Hermes MCP server (wsl host only)";
  };

  config = lib.mkMerge [ {
    # Hermes Agent engine, imported by two hosts:
    #   - wsl (hosts/wsl/configuration.nix, alongside modules/dev/joy-brain.nix)
    #   - alps hermes (hosts/hermes/home.nix, alongside modules/dev/joy-brain.nix
    #     with joyBrain.full = true)
    # Never the shared modules/dev list, which the laptop/server hosts also
    # import.
    #
    # Install model: a pinned `uv sync` of the upstream repo into a writable
    # checkout at ~/.local/share/hermes-agent, mirroring upstream's own
    # install.sh (clone + `uv sync --extra all --locked`) but with the revision
    # pinned here instead of a floating `curl | bash`. The checkout must be
    # writable: uv's setuptools editable build writes `hermes_agent.egg-info`
    # into the project tree, so a read-only nix-store source fails with
    # "could not create 'hermes_agent.egg-info': Permission denied" (verified).
    #
    # Deliberately NOT upstream's flake packages.default/homeManagerModules
    # (nix/*.nix): that builds the sealed venv through uv2nix plus the npm-built
    # TUI/web frontends, dragging in flake-parts/pyproject-nix/uv2nix/
    # pyproject-build-systems/npm-lockfile-fix and, with no public binary cache,
    # multi-hour from-source builds on a fresh host. This repo's standing
    # convention is install-at-activation with a pinned revision
    # (firstmate.nix, herdr.nix, agent-cli-tools.nix), so a pinned uv sync is
    # the consistent, simpler choice here.
    #
    # HERMES_HOME is ~/.hermes, the joy-brain instantiation materialized by
    # modules/dev/joy-brain.nix (curated on wsl, full on alps) - keep those two
    # paths in sync.
    home.packages = with pkgs; [
      uv      # drives the pinned install below (and later `hermes update`)
      ffmpeg  # runtime dep of several hermes tools/skills
    ] ++ lib.optionals config.hermesAgent.standaloneDeps [
      # Runtime deps the shared modules/dev list normally supplies
      # (cli-tools.nix / dev-toolchains.nix), plus the joy-brain scripts'
      # needs - the direct-install mirror of the joy-stack Containerfile.hermes
      # apt extras (git-lfs, sqlite3, netcat, pass+otp, poppler-utils,
      # python3-pil/imagemagick, Node LTS).
      #
      # nodejs_24 (not the repo's usual nodejs_26): the container's qmd image
      # built on NodeSource "latest LTS" (node 24 in this cycle), and qmd's
      # native deps (better-sqlite3, sqlite-vec) ship prebuilt binaries for the
      # LTS ABI - node 26 prebuilds are not guaranteed, which would force a
      # node-gyp compile at activation.
      git
      ripgrep
      nodejs_24
      python3
      poppler-utils
      imagemagick
      sqlite
      netcat-gnu
      (pass.withExtensions (exts: [ exts.pass-otp ]))
      git-lfs
    ];

    home.sessionVariables = {
      HERMES_HOME = hermesHome;
    };

    home.activation.hermesAgentInstall = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      _git=${pkgs.git}/bin/git
      _uv=${pkgs.uv}/bin/uv

      # 1. Materialize the pinned checkout (clone once, then enforce the pin on
      # every activation - a re-pin is a one-line edit to `hermesRev` above).
      if [ ! -d "${checkout}/.git" ]; then
        $DRY_RUN_CMD mkdir -p "$(dirname "${checkout}")"
        $DRY_RUN_CMD "$_git" clone --depth 1 ${lib.escapeShellArg hermesRepo} "${checkout}" \
          || echo "warning: could not clone hermes-agent into ${checkout} (offline?) - retry later: git clone ${hermesRepo} ${checkout}" >&2
      fi
      if [ -d "${checkout}/.git" ]; then
        $DRY_RUN_CMD "$_git" -C "${checkout}" fetch --depth 1 origin ${lib.escapeShellArg hermesRev} 2>/dev/null || true
        $DRY_RUN_CMD "$_git" -C "${checkout}" checkout --detach ${lib.escapeShellArg hermesRev} 2>/dev/null \
          || echo "warning: could not pin hermes-agent to ${hermesRev}" >&2
      fi

      # 2. uv sync the locked environment (idempotent; near-instant once the uv
      # cache is warm). Isolate ambient uv config the way upstream's install.sh
      # does, so a stray uv.toml cannot redirect the index or break --locked.
      if [ -f "${checkout}/pyproject.toml" ]; then
        _uv_conf="$(mktemp -d)" || _uv_conf=""
        (
          [ -n "$_uv_conf" ] && export XDG_CONFIG_HOME="$_uv_conf" XDG_CONFIG_DIRS="$_uv_conf"
          cd "${checkout}"
          UV_PROJECT_ENVIRONMENT="${venv}" "$_uv" sync --extra all --locked --python 3.11
        ) || echo "warning: hermes-agent uv sync failed (offline?) - retry later with: cd ${checkout} && uv sync --extra all --locked --python 3.11" >&2
        [ -n "$_uv_conf" ] && rmdir "$_uv_conf" 2>/dev/null || true
      fi

      # 3. Expose the CLI on PATH (~/.local/bin is prepended by
      # modules/dev/fish.nix on the wsl host; on the alps hermes host the
      # systemd --user units prepend it via their own Environment=PATH=).
      if [ -x "${venv}/bin/hermes" ]; then
        $DRY_RUN_CMD mkdir -p "${config.home.homeDirectory}/.local/bin"
        $DRY_RUN_CMD ln -sfn "${venv}/bin/hermes" "${config.home.homeDirectory}/.local/bin/hermes"
      fi
    '';

    # Native keyless web search for the Hermes agent. The `web` toolset is
    # enabled but ships no backend, so `web_search` returns nothing until one
    # is wired. `web-brave-free` is bundled but NOT keyless (it needs
    # BRAVE_SEARCH_API_KEY, unset here - its is_available() is False); `web-ddgs`
    # is the only bundled keyless backend, and all it needs is the `ddgs` Python
    # package importable in the Hermes venv - exactly what `hermes tools`
    # installs through its own post-setup hook (`uv pip install -U ddgs`). We do
    # the same, declaratively:
    #
    #   1. install `ddgs` into the venv - plain install, no `-U`, so it does not
    #      drift the uv.lock-pinned deps (ddgs only needs click>=8.1.8, which
    #      the lock already satisfies). This runs after hermesAgentInstall, so
    #      the `uv sync --locked` there - which prunes anything outside the lock,
    #      ddgs included - has already run; this step re-adds it every rebuild.
    #   2. enable the web-ddgs plugin (idempotent) so it shows in
    #      `hermes plugins list`.
    #   3. pin `web.search_backend: ddgs` so `web_search` selects it directly
    #      instead of laddering toward a managed/paid backend.
    #
    # Runs after joyBrainInstantiate so the seeded ~/.hermes/config.yaml is the
    # file that gets the plugin + backend entries. Warn-not-die, guarded on the
    # hermes CLI and the venv being present - same posture as hermesCuaDriver.
    home.activation.hermesWebSearch =
      lib.hm.dag.entryAfter [ "joyBrainInstantiate" "hermesAgentInstall" ] ''
        PATH="$HOME/.local/bin:$PATH"
        export HERMES_HOME=${lib.escapeShellArg hermesHome}
        _uv=${pkgs.uv}/bin/uv
        _py=${lib.escapeShellArg "${venv}/bin/python"}
        if [ ! -x "$_py" ]; then
          echo "warning: hermes venv not built yet - web-ddgs setup skipped (rerun activation once hermes has installed)" >&2
        elif ! command -v hermes >/dev/null 2>&1; then
          echo "warning: hermes CLI not on PATH yet - web-ddgs setup skipped (rerun activation once hermes has installed)" >&2
        else
          $DRY_RUN_CMD "$_uv" pip install --python "$_py" ddgs \
            || echo "warning: could not install ddgs into the hermes venv (offline?) - retry later with: $_uv pip install --python $_py ddgs" >&2
          $DRY_RUN_CMD hermes plugins enable web-ddgs \
            || echo "warning: could not enable the web-ddgs plugin - retry later with: hermes plugins enable web-ddgs" >&2
          if [ "$(hermes config get web.search_backend 2>/dev/null || true)" != "ddgs" ]; then
            $DRY_RUN_CMD hermes config set web.search_backend ddgs \
              || echo "warning: could not set web.search_backend=ddgs - retry later with: hermes config set web.search_backend ddgs" >&2
          fi
        fi
      '';
  }

  (lib.mkIf config.hermesAgent.cuaDriver {
    # Register the Cua computer-use driver as a Hermes MCP server so the Hermes
    # agent on this host can operate the Windows desktop (screenshot,
    # mouse/keyboard, window control - e.g. Lightroom). cua-driver.exe is
    # installed on the Windows side by cua-driver-bootstrap.ps1 (per-user, no
    # admin); Hermes reaches it over WSL interop by spawning powershell.exe.
    # GUI/desktop only - no shell/filesystem/registry (reachable directly from
    # WSL when needed). Runs after joyBrainInstantiate so the seeded
    # ~/.hermes/config.yaml is the file that gets the new mcp_servers entry.
    # Idempotent (skip when already present) and warn-not-die, matching the
    # repo's other activation steps.
    home.activation.hermesCuaDriver = lib.hm.dag.entryAfter [ "joyBrainInstantiate" ] ''
      PATH="$HOME/.local/bin:$PATH"
      export HERMES_HOME=${lib.escapeShellArg hermesHome}
      _cfg="${hermesHome}/config.yaml"
      if ! command -v hermes >/dev/null 2>&1; then
        echo "warning: hermes CLI not on PATH yet - cua-driver MCP registration skipped (rerun activation once hermes has installed)" >&2
      elif [ -f "$_cfg" ] && grep -q 'cua-driver' "$_cfg" 2>/dev/null; then
        : # already registered
      else
        $DRY_RUN_CMD hermes mcp add cua-driver \
          --command powershell.exe \
          --args -NoProfile -Command "& '${cuaDriverExe}' mcp" \
          || echo "warning: could not register cua-driver as a Hermes MCP server - retry later (after cua-driver-bootstrap.ps1 on Windows) with: hermes mcp add cua-driver --command powershell.exe --args -NoProfile -Command \"& '${cuaDriverExe}' mcp\"" >&2
      fi
    '';
  })
  ];
}
