# Declares podman itself as a laptop-scoped package: podman (6.1.0) was found
# ambiently present at /usr/bin/podman on the laptop host, not declared
# anywhere in this repo (coming from the Arch base/distro, outside this
# config's control). podman-compose is added alongside it as the real
# standalone compose provider - without it, `podman compose` on this host
# falls back to shelling out to Docker's compose plugin (docker-compose),
# which is an accidental dependency, not a deliberate choice.
#
# Laptop-only, like sway.nix/waybar.nix/wezterm.nix/gpg-agent-laptop.nix:
# podman usage here has only been observed on the laptop host, so this stays
# out of modules/dev (shared by all three hosts) rather than adding it
# unconditionally to server/wsl.
#
# Plain home.packages, not home-manager's `services.podman` module: that
# module's job is generating registries.conf/storage.conf/containers.conf
# and (optionally) declarative services.podman.containers.* quadlets - a much
# bigger footprint than "have the binaries on PATH", and
# browser-proxy-firstmate.nix already deliberately opted out of that
# quadlet-generation path in favor of a raw vendored quadlet file. Declaring
# the packages directly avoids introducing a second, competing
# quadlet-management pattern for that unrelated firstmate module to collide
# with.
{ pkgs, ... }:
{
  home.packages = with pkgs; [
    podman
    podman-compose
  ];
}
