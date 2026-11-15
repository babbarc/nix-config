{ config, lib, pkgs, ... }:
{
  # Where the C toolchain (cc/gcc/c++/g++/cpp and the binutils the gcc wrapper
  # brings: ar/as/ld/nm/objcopy/strip/...) comes from. One explicit per-host
  # signal, so each host file states which side owns the compiler.
  options.devToolchains.cCompiler = lib.mkOption {
    type = lib.types.enum [ "nix" "system" ];
    default = "nix";
    example = "system";
    description = ''
      "nix" (default): pkgs.gcc is in home.packages. Right for a NixOS host,
      where nix owns the whole system and there is no other compiler.

      "system": no nix compiler in the home profile; the distro's own
      /usr/bin/cc serves instead. Right for a hybrid host where pacman owns the
      system toolchain and system libraries: a nix cc first in PATH makes a
      default-PATH makepkg link against nix glibc with a nix RUNPATH,
      producing binaries that cannot load system libraries (a locally rebuilt
      yay could not dlopen the system libalpm.so).
    '';
  };

  config.home.packages = with pkgs; [
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
  ]
  # nvim-treesitter compiles parser C sources at runtime (`tree-sitter build`
  # runs `cc`; LazyVim's health check looks for `cc` or $CC), so every host
  # needs a C compiler on PATH. With cCompiler = "nix", pkgs.gcc (the
  # wrapper) provides that `cc`; with "system", the host's own /usr/bin/cc
  # does, and nix must not shadow it.
  ++ lib.optional (config.devToolchains.cCompiler == "nix") pkgs.gcc;
}
