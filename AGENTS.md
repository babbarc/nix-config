# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

## Origin and status

Split fresh (no preserved history) from the `dotfiles` repo's `nix/` directory - see
that repo's migration report at
`dotfiles-nix-chezmoi-agenix-migration-plan/report.md` for full design rationale.
This repo is Phase 1 of that plan: scaffolding + agenix wiring, validated by pure
Nix evaluation only. Nothing here has been activated on a live system yet.

## Validating changes

Pure evaluation only - never `home-manager switch` or `nixos-rebuild switch` from an
agent session (that's real system activation, out of scope for automated work here):

```
nix build .#homeConfigurations.laptop.activationPackage --no-link
nix build .#homeConfigurations.server.activationPackage --no-link
nix build .#nixosConfigurations.wsl.config.system.build.toplevel --no-link
nix flake check .
```

Flakes only see git-tracked files - `git add` (even just `-N` to stage-track a new
file) before any of the above, or evaluation fails with "not tracked by Git" on
anything newly created.

## Chezmoi-bound module content is neutralized, not deleted

Modules that manage application dotfiles (`nvim.nix`, `wezterm.nix`, `sway.nix`,
`waybar.nix`, `lazygit.nix`, `fish.nix`'s content block, `herdr.nix`'s
`config.toml`, `cli-tools.nix`'s `starship.toml`) have their `xdg.configFile`/
`home.file`/`readFile` declarations commented out with a `TODO(phase2/chezmoi)`
marker, not removed. They used to point at sibling directories one level above
`nix/` in the old `dotfiles` repo (e.g. `../../../nvim/lua`); now that this repo's
root *is* the flake root, those paths point outside the flake source entirely,
which pure eval forbids. Per the migration report's §1.2 table, this content is
slated to move to chezmoi in Phase 2 - re-enabling these lines only makes sense
once that content actually lives somewhere reachable from this repo again (or
Phase 2 removes the need for them). Packages declared in the same modules (e.g.
`pkgs.lazygit`, the `cli-tools.nix` package list) are untouched and still active.

`browser-proxy-firstmate.nix` is the one exception: the report says it stays
permanently nix-owned (vendored infra config, not a personal dotfile), so its two
files are vendored directly into this repo at `containers/systemd/` rather than
neutralized.

## agenix bootstrap identity

The `laptop`/`server` (standalone home-manager) hosts use a dedicated,
agenix-only identity at `~/.ssh/id_agenix` (private, no passphrase - agenix has
no ssh-agent integration, see the migration report §3.2) / `~/.ssh/id_agenix.pub`
(public), generated once per host, outside git. This replaced an earlier design
that pointed `age.identityPaths` at the system SSH host key
(`/etc/ssh/ssh_host_ed25519_key`): that file is mode `600`, owned `root:root`,
and standalone home-manager's `home-manager switch` activates as a normal user,
which can't read it - a real, confirmed gap, not a hypothetical one. Only the
`.pub` half ever belongs in `secrets.nix` (see its own comment block); the
private key is never committed anywhere.

The `wsl` host is unaffected by this - its NixOS module still relies on
`config.services.openssh.hostKeys` (NixOS's own `age.identityPaths` default,
not overridden), which wasn't independently re-checked for the same
permission question.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
