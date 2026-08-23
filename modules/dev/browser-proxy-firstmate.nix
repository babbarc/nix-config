{ ... }:
{
  # Firstmate's dedicated browser-proxy podman quadlet (see the captain's
  # hermes-agent repo, browser-proxy-firstmate.container): a second,
  # port-distinct browser-automation instance (proxy 3343, CDP 3344) for
  # firstmate's own testing/QA use, independent of the captain's production
  # instance on 3333/3334 (which is NOT managed by this repo — it runs
  # under a separate system user account on this host, set up by hand
  # outside of nix entirely, confirmed by inspecting the running host: no
  # quadlet/podman/hermes/browser-proxy declaration exists anywhere else in
  # this repo).
  #
  # This is the first quadlet vendored through this repo, so it follows
  # herdr.nix's config-vendoring pattern (a plain xdg.configFile whose
  # source is a copy of the upstream file kept in this repo) rather than
  # home-manager's newer structured `services.podman.containers.*` module —
  # that module builds unit files at eval time via the podman package's own
  # user-generator into $XDG_CONFIG_HOME/systemd/user/, which would mean
  # translating every quadlet field into Nix attrs; a raw file drop is
  # simpler and matches what's already vendored elsewhere in this repo.
  #
  # Confirmed on this host (podman 6.1.0): the rootless/user quadlet
  # generator reads *.container files from
  # $XDG_CONFIG_HOME/containers/systemd/ (~/.config/containers/systemd/,
  # which already exists but was empty) and turns them into a systemd
  # --user unit at session start — no home-manager systemd.user.services
  # translation needed.
  #
  # Building the container image (`podman build -f Containerfile.browser
  # ...`) that this quadlet depends on stays a manual, occasional step —
  # deliberately not scripted here.
  #
  # The quadlet's Volume= line bind-mounts the proxy script itself
  # (browser-proxy.py, from the captain's hermes-agent repo) into the
  # container. Rather than requiring a full live clone of hermes-agent on
  # this host just to supply that one file, a synced copy of the script is
  # vendored into this repo (same pattern as herdr/config.toml and the
  # quadlet unit above) and materialized alongside the quadlet unit at
  # ~/.config/containers/systemd/browser-proxy-firstmate.py. The quadlet's
  # Volume= line points at that materialized path instead of
  # ~/hermes-agent/browser-proxy.py.
  xdg.configFile."containers/systemd/browser-proxy-firstmate.container".source =
    ../../../containers/systemd/browser-proxy-firstmate.container;
  xdg.configFile."containers/systemd/browser-proxy-firstmate.py".source =
    ../../../containers/systemd/browser-proxy-firstmate.py;
}
