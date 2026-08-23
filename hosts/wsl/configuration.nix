# NixOS-WSL host for the Windows machine's WSL2 distro. Unlike the Arch host
# (nix/home.nix), which runs home-manager standalone because Arch isn't NixOS
# and has nothing for a home-manager NixOS module to attach to, this host IS a
# NixOS system - so home-manager is wired in here as a NixOS module
# (home-manager.nixosModules.home-manager, imported in flake.nix) instead.
# That gives one `nixos-rebuild switch` for both system and home, which is the
# standard pattern for a single-user NixOS-WSL machine and avoids running two
# separate switch commands for one host.
#
# Only the shared nix/modules/dev - portable dev tooling with no display
# server or Arch-specific assumptions - is imported here. Secrets and machine
# identity (SSH/GPG keys) are not managed by this repo on any host; set those
# up on the WSL machine itself, same as the Arch host.
{ config, lib, pkgs, fisher, dotfilesEnv, ... }:
let
  # Per-machine username from ~/.config/dotfiles/env (see env.example); the
  # committed example/placeholder keeps eval working on a fresh clone.
  username = dotfilesEnv.DOTFILES_USERNAME or "user";
  # Optional directory of corporate root CAs to trust (see env.example):
  # every regular cert file (.pem/.crt/.cer/.cert) found directly inside it
  # is fed to security.pki.certificateFiles - however many are dropped in,
  # no fixed count or filename expected. Empty/unset on machines with no
  # TLS-intercepting proxy, and a missing or empty directory degrades to no
  # certs rather than a hard eval error (a captain typo'ing the path
  # shouldn't break the whole build). Each file path is converted from a
  # bare string to a real Nix path value via `/. + path` (not left as a bare
  # string): security.pki.certificateFiles feeds cacert's build, which runs
  # sandboxed with no access to arbitrary host paths, so each file must be
  # imported into the Nix store at eval time (a bare string builds the CA
  # bundle from that literal path at build time and fails with "No such file
  # or directory" inside the sandbox - confirmed by hand). Importing an
  # out-of-flake path also needs `nix build --impure` (flakes evaluate pure
  # by default, which otherwise refuses the path outright) - nix/setup.sh
  # adds that flag automatically, only when this key is set. This is only
  # the DECLARATIVE side, trusted by the activated system going forward
  # (e.g. lazy.nvim's later clone) - it cannot help nix/setup.sh's OWN
  # fetches of this flake's inputs, since those happen before this system
  # generation exists; setup.sh handles that earlier moment separately with
  # an ephemeral NIX_SSL_CERT_FILE/SSL_CERT_FILE export (see its comments).
  certDirStr = dotfilesEnv.DOTFILES_CORPORATE_CA_DIR or "";
  certExtensions = [ ".pem" ".crt" ".cer" ".cert" ];
  certFiles =
    if certDirStr == "" then
      [ ]
    else
      let
        certDirPath = /. + certDirStr;
      in
      if !(builtins.pathExists certDirPath) then
        [ ]
      else
        let
          entries = builtins.readDir certDirPath;
          isCertFile = name: type:
            type == "regular" && lib.any (ext: lib.hasSuffix ext name) certExtensions;
          certNames = builtins.attrNames (lib.filterAttrs isCertFile entries);
        in
        map (name: certDirPath + "/${name}") certNames;
in
{
  imports = [
    # nixos-wsl.nixosModules.default and home-manager.nixosModules.home-manager
    # are imported at the flake level (nix/flake.nix), not here.
  ];

  wsl.enable = true;
  wsl.defaultUser = username;

  # Keep flakes enabled on the system itself: the flake-built system generates
  # /etc/nix/nix.conf from this config (it is read-only by hand), and without
  # this the installed NixOS-WSL system loses flakes after the bootstrap
  # session's NIX_CONFIG export goes away.
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # SECURITY-SENSITIVE: grants this login user "trusted" status with the
  # nix-daemon (in addition to nixpkgs' own default of `[ "root" ]`, which
  # this list ADDS to rather than replaces - `nix.settings.trusted-users` is
  # a listOf-typed option, and NixOS's module system concatenates multiple
  # plain-priority definitions of a list option instead of the last one
  # winning, confirmed by reading nixpkgs' nixos/modules/config/nix.nix,
  # which sets its `[ "root" ]` default the same way, not via mkDefault).
  # A trusted user can pass arbitrary extra nix.conf settings to the daemon
  # (e.g. --option substituters/ssl-cert-file) AND submit pre-built,
  # unsandboxed store paths the daemon will accept without rebuilding them -
  # i.e. this is effectively root-equivalent access to the nix store, a
  # standard and well-known nix privilege grant, not a cosmetic setting.
  # This is deliberate here: it is what lets nix/setup.sh's
  # `--option ssl-cert-file <path>` (see the DOTFILES_CORPORATE_CA_DIR
  # comment above) actually take effect on a corporate network, since the
  # daemon otherwise silently ignores a client-specified option from an
  # untrusted user (confirmed by hand against nix 2.35.2).
  #
  # Deliberately the named user, not `@wheel`: nixos-wsl's own
  # `wsl.defaultUser` module (nixos-wsl's modules/wsl-distro.nix) already
  # puts this user in `wheel` unconditionally, for sudo, not as a
  # nix-trust decision - piggybacking on that would trust anyone else later
  # added to wheel for sudo-only reasons. On this single-user personal
  # machine, naming the user directly keeps the grant scoped to an explicit
  # decision instead of an incidental group membership.
  #
  # Bootstrap sequencing: this is a DECLARATIVE setting, so - like
  # security.pki.certificateFiles above - it only takes effect after a
  # successful activation. It does nothing for the very first bootstrap on
  # a fresh corporate-network machine (nix/setup.sh's own process, run as
  # the login user, is not yet trusted at that point). The captain's
  # workaround for that one-time first run is `sudo nix/setup.sh`, since
  # root is trusted by default; this setting is what makes every
  # subsequent run (updates, re-provisioning) work without sudo once the
  # first activation has succeeded.
  nix.settings.trusted-users = [ username ];

  # nixos-wsl's defaultUser account creation (isNormalUser/uid/extraGroups)
  # does not set a shell, so this is the only place the login shell is
  # decided - without it, opening a WSL2 terminal lands in bash even though
  # modules/dev/fish.nix's `programs.fish.enable` is home-manager's own
  # option, scoped to PATH/config, not the system login shell.
  # `programs.fish.enable` here is the NixOS-level option (registers fish in
  # /etc/shells, gives it the nix directories in PATH) - NixOS asserts it's
  # on whenever a user's shell is set to fish, so both lines are required.
  programs.fish.enable = true;
  users.users.${username}.shell = pkgs.fish;

  # curl-installed generic Linux binaries (treehouse, no-mistakes, herdr - see
  # nix/modules/dev/agent-cli-tools.nix and nix/modules/dev/herdr.nix, none
  # built through Nix) fail to run on NixOS: there is no
  # /lib64/ld-linux-x86-64.so.2 at the path a normal Linux binary expects,
  # since NixOS is not an FHS distro. The Arch laptop host never hits this
  # (Arch is a normal FHS distro); nix-ld provides that dynamic-linker shim
  # so these binaries execute unmodified.
  programs.nix-ld.enable = true;

  # Matches nix/flake.nix's allowUnfreePredicate for the Arch host's own pkgs
  # instance (unrar, pulled in by modules/dev/cli-tools.nix) - this host has
  # no custom `pkgs` passed to nixosSystem, so the same exception has to be
  # set here instead, via the module system.
  nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [ "unrar" ];

  security.pki.certificateFiles = certFiles;

  # Matches nix/home.nix's home.stateVersion - do not bump either without
  # reading home-manager's stateVersion documentation first.
  system.stateVersion = "24.11";

  home-manager.useGlobalPkgs = true;
  home-manager.useUserPackages = true;
  home-manager.extraSpecialArgs = { inherit fisher dotfilesEnv; };
  home-manager.users.${username} = {
    home.username = username;
    home.homeDirectory = "/home/${username}";
    home.stateVersion = "24.11";
    programs.home-manager.enable = true;

    imports = [ ../../modules/dev ];
  };
}
