{ config, lib, pkgs, ... }:
{
  # Shared, non-secret GPG public keys for the captain's `pass` store
  # recipients (see that store's `.gpg-id`): phoenix (laptop), joy
  # (older identity, public-only from here on), and yeti (this repo's
  # server). Unlike the per-host private-key agenix vaults, these are
  # genuinely public data - plain nix-managed files imported on every
  # host, not secrets.
  home.packages = [ pkgs.gnupg ];

  home.activation.gpgPublicKeysImport = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    PATH="${pkgs.gnupg}/bin:$PATH"
    ${pkgs.gnupg}/bin/gpg --batch --import ${../../gpg-keys/yeti.asc}
    ${pkgs.gnupg}/bin/gpg --batch --import ${../../gpg-keys/phoenix.asc}
    ${pkgs.gnupg}/bin/gpg --batch --import ${../../gpg-keys/joy.asc}
  '';
}
