## agenix secret -> public-key mapping.
##
## Fill this in by hand as hosts are added: one entry per `.age` file, listing
## the SSH/age public keys (host keys and/or personal keys) allowed to decrypt
## it. See https://github.com/ryantm/agenix for the `agenix -e` workflow that
## creates the corresponding `.age` files.
##
## Example shape (uncomment and adapt - no real keys are populated here):
# let
#   wsl = "ssh-ed25519 AAAA...clef... wsl-host-key";
#   laptop = "ssh-ed25519 AAAA...clef... laptop-host-key";
#   server = "ssh-ed25519 AAAA...clef... server-host-key";
# in
# {
#   "example-secret.age".publicKeys = [ wsl laptop server ];
# }
{ }
