{ pkgs, ... }:
let
  # Vendored proxy script (containers/systemd/browser-proxy-windows.py). It
  # runs directly as the local user - NOT inside a podman container - because
  # the container's WSL interop is broken: powershell.exe is unreachable from
  # inside the container, so the Windows Chrome launch loops. Run directly,
  # the script's /mnt/c powershell.exe path and outbound WSL2 localhost
  # forwarding work end-to-end (verified: the CDP probe returns real Windows
  # Chrome 152). The script path is wired through the nix store, not a bind
  # mount, so no podman/quadlet/container image is involved at all.
  script = ../../containers/systemd/browser-proxy-windows.py;
in
{
  # Windows-Chrome variant of the lazy browser proxy for the `wsl` host (see
  # containers/systemd/browser-proxy-windows.py for the full design). It is
  # NOT in modules/dev/default.nix: it only makes sense where Windows interop
  # exists (NixOS-WSL), so it is imported explicitly by
  # hosts/wsl/configuration.nix rather than being applied to the Arch
  # laptop/server hosts, which have no powershell.exe.
  #
  # Deployed as a plain systemd --user service that runs the proxy script
  # directly as the login user. No podman, quadlet, or container image is
  # involved - the original podman quadlet was dropped because its WSL
  # interop is broken, and running the script directly is verified to work.
  systemd.user.services.browser-proxy-windows = {
    Unit = {
      Description = "Hermes Browser Proxy (Windows Chrome) - lazy CDP on port 3333";
      After = [ "network-online.target" ];
    };

    Service = {
      ExecStart = "${pkgs.python3}/bin/python3 -u ${script}";
      Environment = [
        "PYTHONUNBUFFERED=1"

        # Stable external contract: Hermes points browser.cdp_url at localhost:3333.
        "PROXY_PORT=3333"
        # Loopback control API for show/hide: POST /show, POST /hide, GET /status.
        "CONTROL_PORT=3335"
        # Internal reverse-pipe ingress: the Windows helper connects here (WSL2
        # localhost forwarding) to hand Chrome traffic back into the proxy.
        "PIPE_PORT=9223"
        # Windows Chrome remote debugging port (bound to 127.0.0.1 on Windows).
        "CHROME_PORT=9222"
        # Isolated Chrome profile (see browser-proxy-windows.py). Must not
        # contain spaces; must be writable by the Windows user without elevation.
        "CHROME_USER_DATA_DIR=C:\\Users\\Public\\Hermes\\ChromeProfile"
        # Stop Windows Chrome after this many seconds with no active connections.
        "IDLE_TIMEOUT=3600"
      ];
      Restart = "on-failure";
      RestartSec = 5;
    };

    Install = {
      WantedBy = [ "default.target" ];
    };
  };
}
