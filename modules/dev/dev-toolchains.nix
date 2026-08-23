{ pkgs, ... }:
{
  home.packages = with pkgs; [
    nodejs_26
    python3
    # jdk resolves to OpenJDK 21 (nixpkgs' current default) rather than the
    # newer major pacman has (jdk-openjdk 26) — no matching nixpkgs build
    # exists yet; not a mistake, see migration design doc.
    jdk
    maven
    cmake
    rust-analyzer
    luarocks
    # awscli is AWS CLI v1, deliberately — pacman's installed aws-cli on this
    # machine is also v1 (1.44.x). Do not "fix" this to awscli2 (v2) without
    # checking pacman's version first.
    awscli
    influxdb2-cli
    neovim
    # nvim-treesitter compiles parser C sources at runtime; without a C
    # compiler `:checkhealth nvim-treesitter` fails its C-compiler requirement.
    # pkgs.gcc (the wrapper) provides the `cc` symlink treesitter looks for.
    gcc
  ];
}
