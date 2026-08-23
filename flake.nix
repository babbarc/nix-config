{
  description = "Personal home-manager configuration";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # fisher isn't packaged in nixpkgs and has no flake of its own — it's just
    # two plain fish files (functions/fisher.fish, completions/fisher.fish).
    # `flake = false` pulls the raw source tree instead of expecting flake outputs.
    fisher = {
      url = "github:jorgebucaran/fisher";
      flake = false;
    };
    # No nixosModules/homeManagerModules — a plain package (packages.<system>.default)
    # plus a systemd user unit copied into $out/lib/systemd/user. Its own unit's
    # ExecStart is a NixOS system-profile path, so voice-dictation.nix defines its
    # own systemd.user.services entry against this package's real store path
    # instead of linking theirs. Arch-host-only input - voice-dictation.nix is a
    # desktop-only module, never imported by the wsl host below.
    whisper-dictation.url = "github:jacopone/whisper-dictation";
    # NixOS running as the WSL2 distro itself, for the wsl host below.
    nixos-wsl = {
      url = "github:nix-community/NixOS-WSL";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Machine-specific personal values (usernames, hostnames, LAN endpoints)
    # live in ~/.config/dotfiles/env on each machine, never in this repo. Pure
    # eval forbids reading that file directly (builtins.readFile of an absolute
    # path errors, builtins.getEnv returns ""), so it is fed in as a flake
    # input instead: the committed env.example is the default, and each machine
    # overrides it at build time with
    #   --override-input dotfiles-env path:$HOME/.config/dotfiles/env
    # (verified working in pure mode; the override is not written to flake.lock).
    dotfiles-env = {
      url = "path:./env.example";
      flake = false;
    };
    # Restores the captain's GPG/SSH key material at activation time, decrypting
    # against an identity that must already exist on the host (see secrets.nix
    # and each host's age.identityPaths below - agenix never provisions that
    # first identity itself, only decrypts against it).
    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, home-manager, fisher, whisper-dictation, nixos-wsl, dotfiles-env, agenix, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        # unrar is nixpkgs' unfreeRedistributable; keep this exception list to
        # explicitly-audited packages only, don't widen it casually.
        config.allowUnfreePredicate = pkg: builtins.elem (nixpkgs.lib.getName pkg) [ "unrar" ];
      };

      # Parse the env file (KEY=VALUE lines, '#' comments and blanks ignored)
      # into an attrset so host configs can read e.g. dotfilesEnv.DOTFILES_USERNAME.
      dotfilesEnv = let
        lines = builtins.filter (l: l != "" && builtins.substring 0 1 l != "#")
          (builtins.filter builtins.isString
            (builtins.split "\n" (builtins.replaceStrings [ "\r" ] [ "" ] (builtins.readFile dotfiles-env))));
        parse = acc: line: let m = builtins.match "([^=]+)=(.*)" line; in
          if m == null then acc else acc // { ${builtins.head m} = builtins.elemAt m 1; };
      in builtins.foldl' parse {} lines;

      # Standalone home-manager (Arch has no NixOS module system to hang
      # agenix's NixOS module off of, so both Arch hosts use agenix's separate
      # homeManagerModules.default instead - see ryantm/agenix's flake.nix).
      # Unlike the wsl host below, home-manager's agenix module has no default
      # age.identityPaths (NixOS's config.services.openssh.hostKeys default is
      # a NixOS-only mechanism), so it must be set explicitly here. Uses a
      # dedicated per-machine ~/.ssh/id_agenix identity (generated once per
      # host, outside git, no passphrase - agenix has no ssh-agent
      # integration, see the migration report SS3.2) rather than the system
      # SSH host key: the host key is root-only-readable (mode 600, owned
      # root:root), which standalone home-manager's normal-user activation
      # can't read.
      agenixHomeModules = [
        agenix.homeManagerModules.default
        { age.identityPaths = [ "/home/yeti/.ssh/id_agenix" ]; }
      ];
    in
    {
      homeConfigurations.laptop = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        extraSpecialArgs = { inherit system fisher whisper-dictation dotfilesEnv; };
        modules = [ ./hosts/laptop/home.nix ] ++ agenixHomeModules;
      };

      # Arch server host - same standalone home-manager shape as the laptop
      # (Arch isn't NixOS, so no NixOS module system to hang home-manager off
      # of), but only imports the portable nix/modules/dev bucket: a server
      # has no display, so none of the laptop's desktop/GUI modules apply.
      homeConfigurations.server = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        extraSpecialArgs = { inherit fisher dotfilesEnv; };
        modules = [ ./hosts/server/home.nix ] ++ agenixHomeModules ++ [
          # Server-only: the captain's real GPG key backup, already encrypted.
          # Restored to a side path (NOT ~/.gnupg) so the captain can inspect
          # and verify it before manually importing it into any keyring - see
          # the migration report SS10.2 "Agenix-specific rollback". Deliberately
          # not in agenixHomeModules above: laptop must never receive this.
          ({ config, ... }: {
            age.secrets.gpg-server-key = {
              file = ./gpg-server-key.age;
              path = "${config.home.homeDirectory}/.agenix-verify/gpg-server-key.asc";
              mode = "0400";
            };
            # Same side-path safety pattern as gpg-server-key above: the
            # captain's real SSH private key, restored to a side path (never
            # ~/.ssh/id_ed25519) so it can be inspected and verified before
            # any manual, captain-approved move into a live path.
            age.secrets.ssh-server-key = {
              file = ./ssh-server-key.age;
              path = "${config.home.homeDirectory}/.agenix-verify/ssh-server-key";
              mode = "0400";
            };
          })
        ];
      };

      # NixOS-WSL host on the Windows machine. home-manager is wired in as a
      # NixOS module (rather than standalone, as the Arch host above uses)
      # because this output is itself a NixOS system - see hosts/wsl/configuration.nix's
      # header comment for why that's the natural fit here, not a style pick made
      # in a vacuum.
      nixosConfigurations.wsl = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit fisher dotfilesEnv; };
        modules = [
          nixos-wsl.nixosModules.default
          home-manager.nixosModules.home-manager
          # NixOS's own default (age.identityPaths defaults to
          # config.services.openssh.hostKeys) is exactly the machine's own SSH
          # host key already generated at first boot - don't override it.
          agenix.nixosModules.default
          ./hosts/wsl/configuration.nix
        ];
      };
    };
}
