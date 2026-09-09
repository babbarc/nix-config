{ ... }:
{
  # Windows-Chrome variant of the lazy browser proxy for the `wsl` host (see
  # containers/systemd/browser-proxy-windows.container and
  # browser-proxy-windows.py for the full design). It is NOT in
  # modules/dev/default.nix: it only makes sense where Windows interop exists
  # (NixOS-WSL), so it is imported explicitly by hosts/wsl/configuration.nix
  # rather than being applied to the Arch laptop/server hosts, which have no
  # powershell.exe.
  #
  # Follows the hermes-joy-stack.nix / browser-proxy-firstmate.nix vendoring
  # convention: a raw xdg.configFile drop of the vendored quadlet + proxy
  # script into ~/.config/containers/systemd/, NOT home-manager's structured
  # `services.podman.containers.*` generator. podman's rootless user quadlet
  # generator reads *.container from that directory at session start and
  # turns it into a systemd --user unit - no translation into Nix attrs.
  #
  # The container image (`localhost/browser-proxy:latest`, the same image the
  # firstmate proxy uses, which ships /usr/local/bin/python3) is built
  # manually out of band, exactly like the other browser-proxy quadlets; this
  # module only drops the files. podman itself is declared at the SYSTEM level
  # in hosts/wsl/configuration.nix (environment.systemPackages + systemd.packages),
  # not here: podman's user quadlet generator (lib/systemd/user-generators/) is
  # only wired into systemd's --user generator search path when podman is
  # installed system-wide, so a home.packages-level podman drops the *.container
  # files but never generates browser-proxy-windows.service. The system-level
  # podman provides both the CLI and the generator, so no laptop-scoped
  # modules/podman.nix import is needed on wsl/server either.
  xdg.configFile."containers/systemd/browser-proxy-windows.container".source =
    ../../containers/systemd/browser-proxy-windows.container;
  xdg.configFile."containers/systemd/browser-proxy-windows.py".source =
    ../../containers/systemd/browser-proxy-windows.py;
}
