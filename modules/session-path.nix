{ config, ... }:
{
  # systemd --user never sources ~/.profile or fish's hm-session-vars shim, so
  # anything launched outside a shell (wezterm via its .desktop entry, other
  # app launchers) never got ~/.nix-profile/bin on PATH. This went unnoticed
  # pre-migration because pacman's fish sat directly on systemd's default PATH
  # (/usr/local/bin:/usr/bin); once fish became Nix-only, GUI-launched wezterm
  # could no longer find it. environment.d supports referencing the existing
  # $PATH (systemd-managed, read at session start), so just prepend here.
  xdg.configFile."environment.d/15-nix-profile-path.conf".text = ''
    PATH=${config.home.homeDirectory}/.nix-profile/bin:$PATH
  '';
}
