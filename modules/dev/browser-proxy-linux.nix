{ config, lib, pkgs, ... }:
let
  # Vendored proxy script (containers/systemd/browser-proxy-linux.py). It runs
  # directly as the local `hermes` user - NOT inside a podman container -
  # because Q1a is the fully-direct browser backend: the existing
  # browser-proxy.py pattern as a systemd --user service, with Google Chrome
  # installed on the Arch host (not the hermes-browser container image). See
  # the scoping report section 2.3 item 3 for the Q1a shape and rationale.
  script = ../../containers/systemd/browser-proxy-linux.py;

  # The script resolves the host Chrome binary (`google-chrome-stable`) via
  # PATH. The python3 interpreter is an absolute nix-store path, so the PATH
  # here only has to make the host Chrome reachable - but include the nix
  # profile dirs too so any future PATH-resolved tool the script shells out to
  # works the same as the other alps units.
  pathEnv = lib.concatStringsSep ":" [
    "${config.home.homeDirectory}/.local/bin"
    "${config.home.homeDirectory}/.nix-profile/bin"
    "/nix/var/nix/profiles/default/bin"
    "/usr/local/bin"
    "/usr/bin"
    "/bin"
  ];
in
{
  # Linux-host-Chrome variant of the lazy browser proxy for the alps `hermes`
  # host (see containers/systemd/browser-proxy-linux.py for the full design).
  # It mirrors modules/dev/browser-proxy-windows.nix exactly in shape - a plain
  # systemd --user service running the script directly - but with no Windows
  # interop (no powershell.exe, no reverse tunnel) and no podman sidecar:
  # Chrome 152 binds DevTools to 127.0.0.1, and proxy + Chrome are on the same
  # host, so the proxy connects straight to 127.0.0.1:BROWSER_PORT.
  #
  # Deliberately NOT in modules/dev/default.nix: it only makes sense on the
  # alps hermes host (a Linux host with Google Chrome installed), so it is
  # imported explicitly by hosts/hermes/home.nix.
  systemd.user.services.hermes-browser-proxy = {
    Unit = {
      Description = "Hermes Browser Proxy (host Chrome) - lazy CDP on port 3333";
      After = [ "network-online.target" ];
    };

    Service = {
      ExecStart = "${pkgs.python3}/bin/python3 -u ${script}";
      Environment = [
        "PYTHONUNBUFFERED=1"
        "PATH=${pathEnv}"

        # Stable external contract: Hermes points browser.cdp_url at localhost:3333.
        "PROXY_PORT=3333"
        # Chrome's own DevTools port (loopback; the proxy forwards 3333 -> 3334).
        "BROWSER_PORT=3334"
        # Chrome profile root == the agent's ~/chrome-downloads/ (see the script
        # docstring for why this keeps joy-brain's documented download paths true).
        "CHROME_USER_DATA_DIR=${config.home.homeDirectory}/chrome-downloads"
        # Stop Chrome after this many seconds with no active connections.
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
