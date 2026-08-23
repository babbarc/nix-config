{ pkgs, ... }:
{
  home.packages = with pkgs; [
    ripgrep
    fd
    bat
    fzf
    starship
    htop
    bottom
    ncdu
    gdu
    git
    git-crypt
    git-filter-repo
    tree-sitter
    yq-go
    screen
    wget
    aria2
    unzip
    unrar
    p7zip
    lbzip2
    yt-dlp
    translate-shell
    speedtest-cli
    ssh-audit
    qrencode
    zbar
    netcat-gnu
    nerdfix
    sysz
    presenterm
    fortune
  ];

  # Raise starship's directory-scan timeout (see repo-root starship.toml for
  # why) by landing it at ~/.config/starship.toml.
  xdg.configFile."starship.toml".source = ../../../starship.toml;
}
