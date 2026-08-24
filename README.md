# nix-config

Nix flake for a personal home-manager (and one NixOS) setup across three
hosts:

- **laptop** - Arch Linux, standalone home-manager, desktop tools included
- **server** - Arch Linux, standalone home-manager, headless
- **wsl** - NixOS-WSL, a real NixOS system config (not standalone
  home-manager)

Split out of the `dotfiles` repo (see `AGENTS.md`'s "Origin and status" for
the full history). This repo owns the Nix side: package sets, home-manager
modules, agenix-encrypted secrets, and per-host wiring. The sibling
`dotfiles` repo owns chezmoi-managed personal dotfile content (shell,
editor, terminal, agent configs, and more - see its own README) and is
applied as the last step of this repo's own bootstrap, below.

## Status

Every host config evaluates successfully and builds its full closure via
pure Nix evaluation (`nix build`/`nix flake check`, no impure inputs). No
host has been activated (`home-manager switch` / `nixos-rebuild switch`) on
a real machine from an agent session - see `AGENTS.md`'s "Validating
changes" section for why that's out of scope here and the exact commands
used to validate each host. Real activation, if and when it happens, is
driven by a human running `setup.sh` (below) on the actual machine.

## Relationship to `dotfiles`

This repo is Nix-only: package management, home-manager/NixOS module
wiring, and agenix secrets. It does not carry any dotfile *content* itself
- `pi.nix` and `git.nix` are effectively empty, and `nvim.nix`,
`lazygit.nix`, `cli-tools.nix`, `fish.nix`, and `herdr.nix` only declare
packages, not config content - because `dotfiles` completed its chezmoi
cutover and now owns that content directly (see `AGENTS.md`'s "Chezmoi
cutover" section for the exact split, including the `wezterm.nix`/
`sway.nix`/`waybar.nix` exception that hasn't been migrated yet).

The two repos are stitched together at bootstrap time: this repo's
`setup.sh` builds and activates the right host, then applies `dotfiles`'
chezmoi source against a local checkout (`$DOTFILES_CHECKOUT`, default
`~/.dotfiles`) as its final step.

## Bootstrap

Run `setup.sh` from a checkout, or fetch-and-run it directly on a bare
machine with only `nix` installed (no git, no editors required):

```sh
./setup.sh [--role <laptop|server|wsl>] [--dry-run]
```

It's a guided installer that:

1. detects the host role (laptop/server/wsl) from the environment, with a
   prompt fallback
2. asks where to fetch this repo from (a Gitea remote, the public GitHub
   mirror, or an existing local checkout) and prompts for only the
   per-machine env values that role needs
3. writes `~/.config/dotfiles/env`, builds and activates the right target
   (`homeConfigurations.laptop`/`.server` via `home-manager switch`-style
   activation, or `nixosConfigurations.wsl` via
   `switch-to-configuration` on NixOS)
4. applies the sibling `dotfiles` repo's chezmoi-managed content from
   `$DOTFILES_CHECKOUT` (default `~/.dotfiles`) - assumed to already exist;
   this repo never clones or manages that checkout itself

Use `--dry-run` to see every command it would run without changing
anything. See `setup.sh --help` and its own header comment for the full
behavior, including non-interactive/scripted use.

## Per-machine values

Machine-specific values (username, email, host role, and a handful of
laptop-only keys like the home server hostname) live in a plain
`KEY=VALUE` file at `~/.config/dotfiles/env` - never in this repo.
`env.example` documents every key. `setup.sh` writes this file for you,
asking only the keys the detected role's matrix needs; a manual copy also
works:

```sh
cp env.example ~/.config/dotfiles/env
# edit it - env.example documents every key
```

Pure Nix evaluation can't read an arbitrary path off disk, so the file is
threaded in as a flake input override at build time:

```sh
nix build path:.#homeConfigurations.laptop.activationPackage \
  --override-input dotfiles-env "path:$HOME/.config/dotfiles/env"
```

(`setup.sh` does this for you; `env.example` itself is the default when no
override is given, which is what pure-evaluation validation below relies
on.)

## Secrets

The captain's GPG/SSH key material (laptop: SSH key + GitHub deploy key,
GPG key, and a GPG AWS-Tokyo key; server: GPG key + SSH key) is
committed to this repo encrypted with [agenix](https://github.com/ryantm/agenix)
(`*.age` files at the repo root, keyed to each host in `secrets.nix`) and
decrypted back into place at home-manager activation time.

Decryption requires a dedicated, agenix-only identity that must already
exist on the host - a passphrase-less `~/.ssh/id_agenix` keypair, generated
once per laptop/server host, outside git (never committed; only the
`.pub` half goes into `secrets.nix`). This is deliberately not the
system SSH host key: standalone home-manager activates as a normal user,
which can't read root-only key material. The `wsl` host is unaffected and
uses NixOS's own default (`config.services.openssh.hostKeys`). Full
rationale in `AGENTS.md`'s "agenix bootstrap identity" section.

## Validating changes

Pure evaluation only - this is the extent of what's been proven so far,
and what any change here should be re-checked against before merging:

```sh
nix build .#homeConfigurations.laptop.activationPackage --no-link
nix build .#homeConfigurations.server.activationPackage --no-link
nix build .#nixosConfigurations.wsl.config.system.build.toplevel --no-link
nix flake check .
```

Flakes only see git-tracked files, so `git add` (even just `-N` to
stage-track a new file) before running any of the above, or evaluation
fails with "not tracked by Git" on anything newly created.

## Repo layout

```
flake.nix, flake.lock   flake definition: inputs, per-host outputs
hosts/                  per-host entry points (laptop, server, wsl)
modules/                shared home-manager modules (dev tooling, gpg-agent,
                         desktop apps, etc.)
containers/systemd/     vendored infra config (browser-proxy-firstmate),
                         permanently nix-owned - not a personal dotfile
secrets.nix             agenix secret -> public-key mapping
*.age                   agenix-encrypted secret files (committed, encrypted)
gpg-keys/               public GPG key material imported on activation
env.example             template for the per-machine ~/.config/dotfiles/env
setup.sh                guided bootstrap entry point (see "Bootstrap" above)
patches/                local patches applied to inputs, if any
```

See `AGENTS.md` for build/validate commands, architecture notes, and
sharp-edge details behind each of the above (agenix identity, chezmoi
split, session-secret/SSH-agent wiring, and more).
