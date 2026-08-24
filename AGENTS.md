# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

## Origin and status

Split fresh (no preserved history) from the `dotfiles` repo's `nix/` directory - see
that repo's migration report at
`dotfiles-nix-chezmoi-agenix-migration-plan/report.md` for full design rationale.
This repo started as Phase 1 of that plan (scaffolding + agenix wiring),
validated by pure Nix evaluation only - see "Validating changes" below for
what an agent session can itself verify. Since then, the `laptop` and
`server` hosts have been built and activated end-to-end on their real
hardware and validated there by the captain directly; real activation is
run by hand on the actual machine, not from an agent session, so it leaves
no trace in this repo's git history - don't expect a commit to corroborate
it. `wsl` has not been activated on a live system; treat it as
evaluation-only until told otherwise.

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

`setup.sh` now runs `chezmoi apply` (via the `chezmoi` package added to
`cli-tools.nix`) right after build+activate, sourced from the sibling
`dotfiles` checkout at `$DOTFILES_CHECKOUT` (default `~/.dotfiles`, assumed to
already exist - this repo doesn't clone or manage it, same posture as
`firstmate.nix`'s `~/firstmate`). This closes the gap where a real host still
running an old, pre-cutover home-manager generation would lose its
chezmoi-owned content (`.claude`, `.codex`, `.pi`, nvim, lazygit, herdr,
wezterm, fish functions) on activation with nothing there yet to replace it.

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

The identity path itself (`flake.nix`'s `agenixHomeModules`) is built from
`dotfilesEnv.DOTFILES_USERNAME`, not hardcoded to either host's real
username - each host's own build overrides the `dotfiles-env` input to its
own `~/.config/dotfiles/env`, so the same shared module list still resolves
to the right per-host path. Don't reintroduce a hardcoded username there.

`homeConfigurations.laptop` in `flake.nix` now wires its 4 secrets
(`ssh-laptop-key`, `ssh-laptop-github`, `gpg-laptop-key`,
`gpg-laptop-aws-tokyo`) the same way `homeConfigurations.server` wires its
2 - an extra module appended after `agenixHomeModules`, not folded into it,
decrypting to agenix's plain default runtime location. See the comment on
the server block for the rationale in full.

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

## Session secrets: gpg-agent is the SSH agent everywhere

`gpg-agent` (`modules/dev/gpg-agent.nix`, imported on all three hosts) is the
sole SSH-agent provider everywhere. Laptop additionally runs gnome-keyring
for Secret Service only (`services.gnome-keyring.components = [ "secrets" ]`
- never `"ssh"`, since gpg-agent already owns that role) and masks
`ssh-agent.socket`/`gcr-ssh-agent.socket` so gcr's separate SSH-agent binary
(`gcr_4`'s `gcr-ssh-agent`, independent of gnome-keyring-daemon's own
`--components` flag) can't race gpg-agent for `SSH_AUTH_SOCK`
(`modules/gpg-agent-laptop.nix`, laptop-only sibling to `wezterm.nix`/
`sway.nix`/`waybar.nix`). Server/wsl run no Secret Service at all, just a
curses pinentry set directly in their own host files. Full rationale:
migration report §3.3, decision §5.5.

Pinentry is `services.gpg-agent.pinentry.package` (a package) in this repo's
pinned home-manager - not `pinentryFlavor` (removed) or the flat
`pinentryPackage` (renamed to the nested form). Generic web docs may describe
a different version; re-verify against the actual pinned source before
trusting any option name here:
`grep -n pinentry $(nix eval --impure --raw --expr '(builtins.getFlake "path:'"$(pwd)"'").inputs.home-manager.outPath')/modules/services/gpg-agent.nix`

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
