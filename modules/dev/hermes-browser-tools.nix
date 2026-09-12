{ lib, pkgs, ... }:
{
  # Mirrors the joy-stack container's browser-automation CLI/MCP pair (PR #3,
  # 2026-09-10: chrome-devtools-axi@0.1.34 + chrome-devtools-mcp@1.9.0), so the
  # `hermes` user's native direct-install environment on alps doesn't lose
  # browser automation at the Phase C/D cut-over. The hermes profile
  # deliberately imports no shared modules/dev list (see hosts/hermes/home.nix),
  # so this is a small dedicated module rather than reusing
  # modules/dev/agent-cli-tools.nix's axiSuiteInstall directly - same guarded
  # activation shape, scoped to just these two packages.
  #
  # chrome-devtools-axi is the CLI the browse skill's launcher drives (see
  # modules/dev/hermes-skills.nix's hermes-browse, wsl-only - the alps full
  # brain's own joy-brain skill tree calls chrome-devtools-axi directly, so
  # having it on PATH plus CHROME_DEVTOOLS_AXI_BROWSER_URL (set on the gateway
  # unit in modules/dev/hermes-alps-services.nix) is what it needs).
  # chrome-devtools-mcp ships real npm bin entries (chrome-devtools,
  # chrome-devtools-mcp) - confirmed via `npm view chrome-devtools-mcp bin` -
  # so, unlike an npx-only MCP server, it installs the same way; it is Hermes's
  # own mcp_servers.chrome-devtools-mcp stdio server if joy-brain's private
  # config.yaml declares one.
  home.activation.hermesBrowserToolsInstall = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    # ~/.local/bin first so an already-installed pair is seen by the guard
    # (home-manager activation scripts start with a stripped PATH that omits
    # ~/.local/bin - see modules/dev/agent-cli-tools.nix's header comment for
    # the same pattern).
    PATH="$HOME/.local/bin:${pkgs.curl}/bin:$PATH"
    if ! command -v chrome-devtools-axi >/dev/null 2>&1 || ! command -v chrome-devtools-mcp >/dev/null 2>&1; then
      $DRY_RUN_CMD ${pkgs.nodejs_24}/bin/npm install --prefix "$HOME/.local" -g chrome-devtools-axi@0.1.34 chrome-devtools-mcp@1.9.0 \
        || echo "warning: chrome-devtools-axi/chrome-devtools-mcp npm install failed (offline?) - retry later with: npm install --prefix \"\$HOME/.local\" -g chrome-devtools-axi@0.1.34 chrome-devtools-mcp@1.9.0" >&2
    fi
  '';
}
