{ ... }:
{
  # Portable dev tooling: shell, editor, language toolchains, git/CLI
  # utilities, and agent-CLI config. No display server, GUI app, or
  # Arch-specific system integration assumptions - safe to import from any
  # home-manager host, including a headless NixOS-WSL one.
  imports = [
    ./cli-tools.nix
    ./dev-toolchains.nix
    ./fish.nix
    ./git.nix
    ./nvim.nix
    ./lazygit.nix
    ./firstmate.nix
    ./browser-proxy-firstmate.nix
    ./npm-global.nix
    ./agent-cli-tools.nix
    ./herdr.nix
    ./pi.nix
  ];
}
