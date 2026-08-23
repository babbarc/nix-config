## agenix secret -> public-key mapping.
##
## Fill this in by hand as hosts are added: one entry per `.age` file, listing
## the SSH/age public keys (host keys and/or personal keys) allowed to decrypt
## it. See https://github.com/ryantm/agenix for the `agenix -e` workflow that
## creates the corresponding `.age` files.
##
## Only PUBLIC keys ever belong here - never a private key. Per host:
## - laptop/server (standalone home-manager, flake.nix's agenixHomeModules):
##   a dedicated, agenix-only identity at ~/.ssh/id_agenix (private,
##   generated once per host, outside git, no passphrase - agenix has no
##   ssh-agent integration, see the migration report SS3.2) /
##   ~/.ssh/id_agenix.pub (public - its contents is exactly what belongs
##   below). Not the system SSH host key: that file is root-only-readable
##   (mode 600, owned root:root) and standalone home-manager activates as a
##   normal user, which can't read it.
## - wsl (NixOS module): still the machine's own SSH host key, via NixOS's
##   own default (age.identityPaths = config.services.openssh.hostKeys,
##   unaffected by the laptop/server identity change above).
##
## Example shape (uncomment and adapt - server's real agenix public key is
## shown below for illustration since it's just a public key; laptop's and
## wsl's own keys still need to be filled in for real as those hosts are
## added):
# let
#   laptop = "ssh-ed25519 AAAA...clef... laptop-agenix-identity";
#   server = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGG9npME6C/jYabHnjnRDgGS2HuF3O67hT/0WUJsWw8h agenix-identity";
#   wsl = "ssh-ed25519 AAAA...clef... wsl-host-key";
# in
# {
#   "example-secret.age".publicKeys = [ wsl laptop server ];
# }
let
  server = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGG9npME6C/jYabHnjnRDgGS2HuF3O67hT/0WUJsWw8h agenix-identity";
in
{
  "gpg-server-key.age".publicKeys = [ server ];
}
