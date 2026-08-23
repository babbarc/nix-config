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

  # TODO(phase2/chezmoi): starship.toml stays in the dotfiles repo, migrating
  # to chezmoi (migration report SS1.2) - neutralized here since the
  # sibling-path reference broke pure eval once nix/ became this repo's own
  # root instead of being nested one level inside dotfiles. The packages
  # above are unaffected and stay nix-managed.
  # xdg.configFile."starship.toml".source = ../../../starship.toml;
}
