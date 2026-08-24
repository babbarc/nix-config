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
    chezmoi
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
    glab
    (pass.withExtensions (exts: [ exts.pass-otp ]))
    pinentry-curses
    tea
    shellcheck
    # gnupg and pass (base) are already pulled in elsewhere in the active
    # module set - gnupg via modules/dev/gpg-public-keys.nix's
    # home.packages, and the pass binary as part of the withExtensions
    # wrapper above - don't duplicate either as bare home.packages entries.
  ];
}
