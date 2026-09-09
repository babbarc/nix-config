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
pure Nix evaluation (`nix build`/`nix flake check`, no impure inputs) - see
`AGENTS.md`'s "Validating changes" section for the exact commands, which
is the extent of what any agent session here can itself verify.

Beyond that: **laptop** and **server** have been built and activated
end-to-end on their real hardware and validated there by the captain
directly (real activation is run by hand, not from an agent session per
this repo's own posture, so it leaves no trace in this repo's git
history). **wsl** has not - nothing indicates it has been activated on a
real machine yet, so treat it as evaluation-only until proven otherwise.

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
chezmoi source with chezmoi's own `init --apply --purge` as its
final step - a single command that clones, applies, and purges its own
source directory, leaving no persistent local checkout behind. (`--purge`,
not `--one-shot`: the latter also deletes the chezmoi binary itself, which
fails from the read-only nix store.)

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
4. applies the sibling `dotfiles` repo's chezmoi-managed content via
   chezmoi's own init+apply+purge (`--purge`) - no persistent checkout is
   cloned or left behind on the host

Use `--dry-run` to see every command it would run without changing
anything. See `setup.sh --help` and its own header comment for the full
behavior, including non-interactive/scripted use.

### One command

On a host that already runs NixOS-WSL (or any NixOS/Nix host), the whole
bootstrap can run non-interactively in a single command:

```sh
curl -fsSL https://raw.githubusercontent.com/babbarc/nix-config/master/setup.sh | \
  SETUP_SOURCE=2 SETUP_USERNAME=your-user SETUP_USER_EMAIL=you@example.com SETUP_YES=1 \
  bash -s -- --role wsl
```

`SETUP_SOURCE=2` picks the public GitHub mirror, `SETUP_USERNAME`/
`SETUP_USER_EMAIL` answer the two required prompts, and `SETUP_YES=1`
auto-confirms. `SETUP_SYSTEM` is normally detected from `uname -m` but can
be forced (`x86_64-linux` or `aarch64-linux`).

### From scratch on bare Windows

A pre-built WSL tarball is published as a release asset (push a `v*` tag to
trigger the build, or run the `Build WSL tarball` workflow manually). Import
it on any machine with WSL2 enabled, then run the one-command step above to
personalize the machine:

```powershell
wsl --import NixOS C:\WSL\NixOS nixos.wsl --version 2
```

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

## Windows-MCP bridge

The Windows-MCP GUI-control bridge lets an agent running in the `wsl` host
drive the Windows machine (screenshots, mouse/keyboard, PowerShell,
file/registry access). The server, [windows-mcp](https://github.com/CursorTouch/Windows-MCP),
runs on the Windows host; the WSL side reaches it over stdio by spawning
`powershell.exe` (WSL interop) - no ports, firewall rules, or auth.

Two halves, one of which is Nix-managed:

- **Windows side** (not Nix-managed, because it runs on Windows): run the
  checked-in bootstrap script once from Windows PowerShell. It installs `uv`
  (which provides `uvx`) and pre-fetches `windows-mcp` from PyPI:

  ```powershell
  powershell.exe -ExecutionPolicy Bypass -File .\windows-mcp-bootstrap.ps1
  ```

- **WSL/NixOS side** (declarative): `hosts/wsl/configuration.nix` pins the
  WSL interop settings (`wsl.interop.register`, `wsl.wslConf.interop`, ...)
  so `powershell.exe`/`pwsh.exe` are reachable, and
  `modules/dev/windows-mcp.nix` exposes the single option that controls the
  whole bridge:

  ```nix
  windowsMcp.harness = "claude"; # one harness, chosen explicitly
  ```

  `pi` is always present on every host (`modules/dev/pi.nix`) and is the
  default runtime; the selector adds ONE additional GUI-control harness
  alongside it and writes that harness's windows-mcp MCP registration. It
  never installs or registers `pi`.

  `herdr` is the runtime backend that spawns and manages each harness pane.
  It is installed declaratively too (`modules/dev/herdr.nix`, pinned to
  v0.8.2 via `fetchurl` - there is no nixpkgs package; the single binary is
  fetched from GitHub releases and self-updates via `herdr update` at
  runtime). That module also installs the herdr integration for every
  supported harness (pi, claude, codex, kimi, opencode, grok), so each pane
  reports native busy/idle/blocked state and session identity to firstmate's
  herdr backend out of the box.

  Fish is the default shell on all three hosts (`modules/dev/fish.nix`). On
  `wsl`, `programs.fish.enable` + `home-manager.useUserPackages` put fish at
  `/etc/profiles/per-user/<user>/bin/fish`, which is the path herdr's
  chezmoi-managed `default_shell` uses; the integration hook scripts are
  POSIX `sh` + `python3` (invoked via explicit `bash`/`sh`), so they work
  regardless of the pane shell being fish. Their dependencies (`python3`,
  `jq`) are already declared on every host via `modules/dev/dev-toolchains.nix`
  and `modules/dev/firstmate.nix`.

### Choosing the harness

Set `windowsMcp.harness` to one of the supported values below. The normal
way is the per-machine env file (see "Per-machine values"), rebuilt with
`setup.sh`; you can also hardcode it in `hosts/wsl/configuration.nix`:

```sh
# ~/.config/dotfiles/env
DOTFILES_WINDOWS_MCP_HARNESS=claude
```

Supported harnesses (each entry's MCP registration path was verified against
that harness's real config format):

| Harness  | Install path                                  | windows-mcp registration                                   | Tradeoffs |
| -------- | --------------------------------------------- | ---------------------------------------------------------- | --------- |
| `claude` | npm `@anthropic-ai/claude-code` (pinned)        | user scope `~/.claude.json` via `claude mcp add-json`       | Most mature MCP client; needs an Anthropic account. Not in nixpkgs as a free package (non-free license), so installed once under `~/.local` via npm - matching the captain's existing native install. Registration goes through Claude Code's own CLI because `.claude.json` is its state file. |
| `codex`  | nixpkgs `codex`                               | `[mcp_servers.windows]` in `~/.codex/config.toml`           | OpenAI's agent; needs ChatGPT/OpenAI auth. No MCP-add CLI, so the module appends the TOML block (preserves other settings). |
| `opencode` | nixpkgs `opencode`                          | `mcp.windows` in `~/.config/opencode/opencode.json`          | Open source, multi-provider. Config is merged with jq so other keys survive. |
| `grok`   | official npm `@xai-official/grok` (pinned)    | `[mcp_servers.windows]` in `~/.grok/config.toml`             | xAI's agent; not in nixpkgs, so installed once under `~/.local` via npm. Needs an xAI account. |
| `kimi`   | official single-binary installer (pinned)     | `mcpServers.windows` in `~/.kimi-code/mcp.json`              | Moonshot's agent; not in nixpkgs, installed once under `~/.local` via the official installer. `mcp.json` is dedicated to MCP, so it is managed as a whole file. |

`cursor` was evaluated and deliberately excluded: it supports MCP clients
(`~/.cursor/mcp.json`) but is a Windows GUI IDE, not a WSL-side CLI harness,
so it cannot be installed or registered declaratively on the `wsl` host.

Changing the harness later is just editing `DOTFILES_WINDOWS_MCP_HARNESS` and
rebuilding; the old harness's registration is left in place (only the chosen
one is written) so you can keep both around, or remove the other manually.

## Windows Chrome CDP proxy

For the `wsl` host only: a lazy CDP proxy that gives a Hermes agent running in
NixOS-WSL a stable `http://localhost:3333` endpoint driving the captain's real
Windows Chrome (installed on the Windows host, not a Linux Chromium container).

Set the Hermes agent's browser endpoint to:

```
browser.cdp_url=http://localhost:3333
```

It runs as a rootless-podman quadlet (`browser-proxy-windows.container`, host
networking) that drops the proxy script
(`containers/systemd/browser-proxy-windows.py`) and unit file into
`~/.config/containers/systemd/` via `modules/dev/browser-proxy-windows.nix`,
imported only by `hosts/wsl/configuration.nix` (it needs WSL interop, so it is
deliberately not in the shared `modules/dev` list used by the Arch hosts).

Lifecycle: the proxy listens on `3333`, lazily launches Windows Chrome with
`--remote-debugging-port=9222` on the first CDP request, tracks active
connections, and stops that Chrome after `IDLE_TIMEOUT` seconds of inactivity.
It owns exactly one Chrome, identified by a dedicated
`--user-data-dir=C:\Users\Public\Hermes\ChromeProfile` marker, and never touches
the captain's browsing Chrome. Before launching it checks - under a lock - for an
existing Chrome with that marker or already on port 9222 and reuses it, so there
is never more than one remote-debugging Chrome.

Two Chrome/Windows facts matter here and shape the design:

- **Chrome 152 removed `--remote-debugging-address`.** The flag is gone from
  `chrome.dll` (only `remote-debugging-port`/`remote-debugging-pipe`/
  `remote-debugging-targets` remain), so Chrome always binds its DevTools HTTP
  server to `127.0.0.1` and ignores `0.0.0.0`. WSL2 cannot reach Windows's
  loopback. The `--remote-debugging-address=0.0.0.0` flag is still passed (a
  harmless no-op here, useful on older Chrome), but it is not what makes the
  connection work.
- **WSL2 NAT inbound is firewalled.** Windows Firewall (Public profile) drops
  WSL->Windows inbound connections, and `netsh portproxy` needs elevation the
  interop user does not have. So the proxy never dials the WSL gateway.

Instead the proxy drives a small Windows-side helper (launched via
`powershell.exe`) that makes an *outbound* connection back into WSL over WSL2's
localhost forwarding and bridges it to Chrome's `127.0.0.1:9222`. The helper is
embedded in the proxy script (an `Add-Type` C# socket bridge) and is spawned
detached per CDP connection. The WSL gateway IP is still resolved at runtime,
but for diagnostics only; nothing in the data path hardcodes it.

Because the proxy must exec `powershell.exe` from inside its container, the
quadlet bind-mounts the WSL interop surface: `/mnt/c` (the Windows drive),
`/init` (the binfmt interpreter), and `/run/WSL` (the interop sockets). These
mounts are required - without them `powershell.exe` cannot run from inside the
container.

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
windows-mcp-bootstrap.ps1  Windows-side one-time setup for the windows-mcp bridge
patches/                local patches applied to inputs, if any
```

See `AGENTS.md` for build/validate commands, architecture notes, and
sharp-edge details behind each of the above (agenix identity, chezmoi
split, session-secret/SSH-agent wiring, and more).
