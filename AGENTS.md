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

## Chezmoi cutover: this repo now matches dotfiles' real, landed state

`dotfiles` has since completed its real chezmoi cutover for every applicable
dotfile, and this repo's modules were synced to match that landed end state
(not re-derived independently - see git log for the sync commit). Result:

- `pi.nix` and `git.nix` are packages-only / empty, respectively - settings.json
  merging, the `.pi`/`.claude`/`.codex` symlinks, and git identity config all
  moved to chezmoi in `dotfiles`.
- `nvim.nix`, `lazygit.nix`, `cli-tools.nix` (`starship.toml`), `fish.nix`
  (its second, dotfiles-content `xdg.configFile` block), and `herdr.nix`
  (`config.toml`) had their content declarations removed outright - no
  `TODO(phase2/chezmoi)` markers remain in any of these. Packages declared in
  the same modules (e.g. `pkgs.lazygit`, the `cli-tools.nix` package list,
  `fish.nix`'s `nix-path.fish`/`interactiveShellInit`) are untouched and still
  active.

`wezterm.nix`, `sway.nix`, and `waybar.nix` are the deliberate exception:
`dotfiles` never migrated these to chezmoi (laptop-only desktop tools, never
exercised on the `server` host), so they're intentionally left as-is here too
- still fully commented-out/neutralized pending a real `dotfiles`-side cutover
that hasn't happened yet. Don't "finish" these to match the other modules;
resync them only once `dotfiles` itself lands a real chezmoi migration for
them (confirm via `git log -- nix/modules/{wezterm,sway,waybar}.nix` in
`dotfiles` for a "relinquish ... to chezmoi" commit before touching them).

`browser-proxy-firstmate.nix` is a separate, permanent exception: the
migration report says it stays permanently nix-owned (vendored infra config,
not a personal dotfile), so its two files are vendored directly into this
repo at `containers/systemd/`.

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

## pass password-store sync

`modules/dev/pass-git-sync.nix` (imported by all three hosts via
`modules/dev/default.nix`) auto-syncs the captain's `pass` store
(`~/.password-store`) after every mutation, via a `post-commit` git hook -
deliberately not a wrapper around the `pass` binary, since `pass` already
runs `git commit` internally on every mutating command. The activation only
wires the hook into a store that's already cloned onto the host; it never
creates or initializes one. `setup.sh`'s "Password store" step (after
build+activate) is the separate, independent piece that clones a fresh store
onto a brand-new host that doesn't have one yet - a warn-not-die step, same
posture as `firstmate.nix`'s clone-on-first-boot.

## setup.sh is this repo's own root-level script

`setup.sh` lives at the flake root (no `nix/` subdirectory - that layout was
`dotfiles`' `nix/` submodule, not this repo's). Its self-fetch logic clones
to `~/.nix-config` and builds `path:<repo>#<attr>` with no `?dir=nix`. The
`DOTFILES_*` env-var names, the `dotfiles-env` flake input, and the
`~/.config/dotfiles/env` file path are a deliberate, unchanged-on-purpose
naming choice carried over from before the split (same rationale as the
Chezmoi cutover section above) - don't "fix" those to match the repo rename.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
