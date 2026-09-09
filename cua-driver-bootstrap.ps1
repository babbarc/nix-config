# cua-driver-bootstrap.ps1
#
# One-time Windows-side setup for the Cua computer-use driver that the Hermes
# agent on the `wsl` host uses to operate the Windows desktop (screenshots,
# mouse/keyboard, window control - e.g. Lightroom). Run this on the WINDOWS
# host (from PowerShell), not inside WSL:
#
#   powershell.exe -ExecutionPolicy Bypass -File .\cua-driver-bootstrap.ps1
#
# It installs cua-driver per-user (NO administrator required) with autostart
# DISABLED (-NoAutoStart): the Hermes agent launches `cua-driver mcp` on
# demand over WSL interop, so no logon Scheduled Task is wanted. Idempotent:
# skips the install when cua-driver.exe is already present.
#
# cua-driver is GUI/desktop-only (screenshot, click, type, window control) -
# it has no shell, filesystem, or registry tools. Those are reachable
# directly from WSL (powershell.exe / /mnt/c) when needed; that capability
# drop is a deliberate captain decision (this replaces the old windows-mcp
# bridge).
#
# The WSL/NixOS side (registering cua-driver as a Hermes MCP server) is
# declarative in this repo: modules/dev/hermes-agent.nix runs, at activation
# when hermesAgent.cuaDriver is set (the wsl host sets it):
#
#   hermes mcp add cua-driver --command powershell.exe `
#     --args -NoProfile -Command "& '<cua-driver.exe>' mcp"
#
# A fresh host is ready after a rebuild + one run of this script, in either
# order. See README "Hermes desktop control (Cua driver)".

$ErrorActionPreference = "Stop"

$CuaDriverExe = Join-Path $env:LOCALAPPDATA "Programs\Cua\cua-driver\bin\cua-driver.exe"

Write-Host "==> Checking for cua-driver..." -ForegroundColor Cyan

if (Test-Path $CuaDriverExe) {
  Write-Host "    cua-driver found: $CuaDriverExe"
}
else {
  Write-Host "    cua-driver not found - installing per-user (no admin, no autostart)..."
  # Official installer (https://cua.ai/docs/how-to-guides/driver/install).
  # Fetched and invoked as a scriptblock so -NoAutoStart reaches the param
  # block: it skips the logon Scheduled Task (Hermes launches the driver on
  # demand). Installs under %LOCALAPPDATA%\Programs and touches only the
  # User-scope PATH - no elevation.
  & ([scriptblock]::Create((Invoke-RestMethod https://cua.ai/driver/install.ps1))) -NoAutoStart

  if (-not (Test-Path $CuaDriverExe)) {
    throw "cua-driver.exe not found at $CuaDriverExe after install. Open a new terminal and re-run this script."
  }
  Write-Host "    cua-driver installed: $CuaDriverExe"
}

Write-Host "==> Verifying cua-driver runs..." -ForegroundColor Cyan
try {
  $null = & $CuaDriverExe --help 2>&1
  Write-Host "    cua-driver is callable."
}
catch {
  Write-Warning "    cua-driver did not run cleanly: $($_.Exception.Message)"
}

Write-Host ""
Write-Host "Windows side is ready." -ForegroundColor Green
Write-Host ""
Write-Host "Next, on the WSL/NixOS side:" -ForegroundColor Cyan
Write-Host "  1. Rebuild the wsl host (setup.sh or nixos-rebuild switch) - activation"
Write-Host "     registers cua-driver as a Hermes MCP server automatically."
Write-Host "  2. Or register it by hand from WSL:"
Write-Host "       hermes mcp add cua-driver --command powershell.exe \"
Write-Host "         --args -NoProfile -Command `"& '$CuaDriverExe' mcp`""
Write-Host ""
Write-Host "See README 'Hermes desktop control (Cua driver)' for details."
