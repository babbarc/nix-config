# windows-mcp-bootstrap.ps1
#
# One-time Windows-side setup for the windows-mcp GUI-control bridge described
# in the repo README ("Windows-MCP bridge"). Run this on the WINDOWS host
# (from PowerShell), not inside WSL:
#
#   powershell.exe -ExecutionPolicy Bypass -File .\windows-mcp-bootstrap.ps1
#
# It installs uv (which provides uvx) if missing and pre-fetches the
# windows-mcp Python package so the first `uvx windows-mcp serve` launch from
# WSL is fast. Idempotent: safe to re-run.
#
# Everything it does:
#   1. Install uv via Astral's official installer (lands at ~\.local\bin,
#      which the installer also appends to the user PATH) - pinned by the
#      installer script itself, not by us.
#   2. Pre-cache windows-mcp from PyPI with `uvx windows-mcp --help` so the
#      MCP server resolves without a slow first-time download.
#   3. Verify `uvx windows-mcp serve` resolves from a WSL-invokable
#      PowerShell invocation shape (the exact command the harness runs).
#
# The WSL/NixOS side (harness install + MCP registration) is declarative in
# this repo: see modules/dev/windows-mcp.nix and hosts/wsl/configuration.nix.

$ErrorActionPreference = "Stop"

function Test-Command($name) {
  $cmd = Get-Command $name -ErrorAction SilentlyContinue
  return ($null -ne $cmd)
}

Write-Host "==> Checking for uv..." -ForegroundColor Cyan

if (Test-Command uv) {
  Write-Host "    uv found: $((Get-Command uv).Source)"
}
else {
  Write-Host "    uv not found - installing via Astral's official installer..."
  # The official installer downloads the uv release baked into the script at
  # fetch time, so this is a pinned install without us hardcoding a version.
  Invoke-RestMethod https://astral.sh/uv/install.ps1 | Invoke-Expression

  # The installer appends ~\.local\bin to the user PATH in the registry; make
  # it visible to THIS session too (new terminals pick it up automatically).
  $uvBin = Join-Path $HOME ".local\bin"
  if (Test-Path $uvBin) {
    $env:PATH = "$uvBin;$env:PATH"
  }

  if (-not (Test-Command uv)) {
    throw "uv is still not on PATH after install. Open a new terminal and re-run this script."
  }
  Write-Host "    uv installed: $((Get-Command uv).Source)"
}

Write-Host "==> Pre-fetching windows-mcp from PyPI..." -ForegroundColor Cyan
# First run downloads the package + its dependencies; do it now so the
# harness's first MCP launch doesn't hit MCP startup timeouts.
try {
  uvx windows-mcp --help | Out-Null
  Write-Host "    windows-mcp resolved and cached."
}
catch {
  Write-Warning "    Could not pre-fetch windows-mcp (offline?): $($_.Exception.Message)"
  Write-Warning "    It will be fetched on the first `uvx windows-mcp serve` launch instead."
}

Write-Host "==> Verifying the exact WSL invocation shape..." -ForegroundColor Cyan
# This is the single command the WSL-side harness runs over interop. It must
# resolve uvx.exe on the Windows PATH; serve --help proves the binary is
# callable without actually starting a server.
try {
  $null = & uvx.exe windows-mcp serve --help 2>&1
  Write-Host "    'uvx.exe windows-mcp serve' resolves correctly."
}
catch {
  Write-Warning "    'uvx.exe windows-mcp serve' did not run cleanly: $($_.Exception.Message)"
}

Write-Host ""
Write-Host "Windows side is ready." -ForegroundColor Green
Write-Host ""
Write-Host "Next, on the WSL/NixOS side:" -ForegroundColor Cyan
Write-Host "  1. Set your harness in ~/.config/dotfiles/env:" -ForegroundColor White
Write-Host "       DOTFILES_WINDOWS_MCP_HARNESS=claude   # or codex | opencode | grok | kimi"
Write-Host "  2. Rebuild the wsl host (setup.sh or nixos-rebuild switch)."
Write-Host "  3. Launch the harness and confirm the windows-mcp tools are available."
Write-Host ""
Write-Host "See README 'Windows-MCP bridge' for each harness's tradeoffs."
