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
  alongside it and registers two stdio MCP servers in it - the windows-mcp
  bridge and `hermes` (the Hermes agent gateway, entrypoint
  `hermes mcp serve`). It never installs or registers `pi`.

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

### Delegating to Hermes over MCP

The same selector also registers a `hermes` stdio MCP server (command
`hermes`, args `["mcp", "serve"]`) in the chosen harness, using the same
per-harness format as the windows-mcp entry in the table above. That is how
firstmate delegates a task to the Hermes agent: spawn a crewmate on the
chosen harness and have it call the `hermes` MCP server. `hermes mcp serve`
runs Hermes as a stdio MCP server that exposes its conversations (list/read
messages, send messages, poll events, manage approvals) to the calling
agent - no transport flags, no ports.

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

It runs as a plain systemd `--user` service (`browser-proxy-windows.service`)
that executes the proxy script (`containers/systemd/browser-proxy-windows.py`)
directly as the login user. `modules/dev/browser-proxy-windows.nix` wires the
script into the nix store and declares the unit with its env (`PROXY_PORT=3333`,
`CONTROL_PORT=3335`, `CHROME_PORT=9222`, `IDLE_TIMEOUT=3600`,
`PYTHONUNBUFFERED=1`); it is imported only by `hosts/wsl/configuration.nix` (it
needs WSL interop, so it is deliberately not in the shared `modules/dev` list
used by the Arch hosts).

The original deployment ran the script inside a rootless-podman container, but
that container's WSL interop is broken - `powershell.exe` is unreachable from
inside it, so the Windows Chrome launch looped. Running the script directly is
verified end-to-end (the CDP probe returns real Windows Chrome 152), so the
container, the podman dependency, and the interop bind mounts are gone.

The unit is `WantedBy=default.target` with `Restart=on-failure`, so it starts on
session start; manage it like any user service:

    systemctl --user status browser-proxy-windows
    systemctl --user start browser-proxy-windows

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

Because the proxy runs directly on the WSL host (not inside a container), it
has the WSL interop surface available natively - `/mnt/c` (the Windows drive),
`/init` (the binfmt interpreter), and `/run/WSL` (the interop sockets) - so
`powershell.exe` execs directly without any bind mounts.

### Control API: show / hide the managed Chrome window

The proxy also listens on a loopback-only control port (`CONTROL_PORT`, default
`3335`) that lets the agent show or hide the managed Chrome window on demand
(via Win32 `ShowWindow`, scoped to the managed Chrome's process only - never
the captain's Chrome):

```
POST http://localhost:3335/hide    # hide the managed Chrome window(s)
POST http://localhost:3335/show    # show the managed Chrome window(s)
GET  http://localhost:3335/status  # {"chrome": "OURS|FOREIGN|NONE|...", "visible": "VISIBLE|HIDDEN|NOT_RUNNING"}
```

- `POST /hide` / `POST /show` return `200` with `HIDDEN <n>` / `SHOWN <n>`
  (`<n>` is the number of top-level windows toggled), or `404 NOT_RUNNING` when
the managed Chrome is not running.
- `GET /status` reports the lifecycle state and window visibility.

Show/hide does not start or stop Chrome, so the single-instance and idle-stop
invariants are unchanged. The window search targets only the Chrome browser
process whose command line carries the `--user-data-dir` marker and no
`--type=` child flag, so the captain's browsing Chrome is never affected.
## Hermes agent (wsl)

For the `wsl` host only: installs the Nous Research
[Hermes Agent](https://hermes-agent.nousresearch.com) gateway and instantiates
the captain's private "joy" assistant as its home, driving Windows Chrome
through the CDP proxy on `http://localhost:3333` (see the PR that adds
`modules/dev/browser-proxy-windows.nix`). Two modules, both imported only by
`hosts/wsl/configuration.nix` - deliberately not the shared `modules/dev` list,
because the laptop/server hosts run no Hermes agent and no WSL interop:

- `modules/dev/hermes-agent.nix` - the engine. A pinned `uv sync` of
  `github:NousResearch/hermes-agent` into `~/.local/share/hermes-agent`, with
  the `hermes` CLI symlinked into `~/.local/bin`. Pin: tag `v2026.8.31`
  (pyproject 0.21.0, revision `29112bef099274229cadff79cdff7bf7b99c4b77`) - the
  same base the joy-stack container image builds from
  (`containers/systemd/hermes/hermes.container`), so both instances run one
  release. Upstream's own flake packaging (uv2nix + npm-built TUI/web) is not
  adopted: it drags in five extra flake inputs and, with no public binary
  cache, multi-hour from-source builds on a fresh host - this repo's
  install-at-activation convention (see `firstmate.nix`, `herdr.nix`) is the
  smaller, consistent fit. `hermes mcp serve` is the server entrypoint: it
  runs Hermes as a stdio MCP server (no transport flags), which
  `modules/dev/windows-mcp.nix` registers into the chosen
  `windowsMcp.harness` - see "Delegating to Hermes over MCP".
- `modules/dev/joy-brain.nix` - the assistant. Clones the PRIVATE
  `ssh://git@alps:2222/babbarc/joy-brain.git` (the captain's full Hermes home)
  at activation into `~/.local/share/joy-brain` and materializes `~/.hermes`
  (the `HERMES_HOME`) from it. Pin: commit
  `8c95745461bf7b01dbcc17659853bad62f35bd88` (the `joyBrainRev` constant; an
  empty value degrades to clone-HEAD-and-warn so a missing pin never
  hard-fails activation). See the "private data" notes below.

### Browser wiring

`modules/dev/joy-brain.nix` deep-merges this override into
`~/.hermes/config.yaml` on every activation:

```yaml
browser:
  cdp_url: "http://localhost:3333"
```

That is the stable contract the Windows-Chrome CDP proxy exposes (see the
proxy's own README section). The merge only forces `browser.cdp_url`; every
other config key - joy-brain's own config plus Hermes's runtime edits via
`hermes config set` / the TUI - is preserved.

### Skills: a curated subset, not the whole joy-brain

joy-brain carries ~110 skills (33 top-level dirs, some flat skills, some
categories). This repo deliberately does NOT instantiate all of them. Only the
browser skills plus the MCP workflow skill are materialized into
`~/.hermes/skills/` (as symlinks back into the clone):

| Skill | Why it is included |
| --- | --- |
| `chrome-devtools-axi` | Primary browser CLI driver - controls Chrome through the CDP proxy. |
| `web` | `blocked-page-recovery` - recover from 403/429/paywall/WAF fetch failures. |
| `software/choose-web-tool` | "Load FIRST for any web interaction" - routes curl vs browser vs scrapling. |
| `software/operate-browser` | Built-in `browser_navigate`/`click`/`type`/`scroll` tools. |
| `software/preserve-browser-session` | CDP session-preservation pattern (matches the proxy's persistent Chrome). |
| `software/use-cdp-protocol` | Raw CDP commands via the `browser_cdp` tool. |
| `software/run-cdp-scripts` | `cdp-*.py` CLI helpers (list tabs / eval / navigate / screenshot). |
| `software/recaptcha-solver` | reCAPTCHA v2 challenges on real sites. |
| `research/scrapling` | Stealth browser scraping / Cloudflare bypass. |
| `research/duckduckgo-search` | Free web search (no API key) - the default search path. |
| `mcp` | `native-mcp` - connect/register MCP servers (stdio/HTTP). |

Everything else in joy-brain's `skills/` is deliberately excluded (not copied,
not symlinked) and stays private in the clone - including all the
coding/kanban/finance/travel/home/legal/health/contacts/communication
categories, the `.archive/` skill, and the non-browser `software/*` skills
(`coding-agent-orchestrator`, `gemini-web-images`,
`signal-noise-classifier`). The list lives in a single `includedSkills` list at
the top of `modules/dev/joy-brain.nix`; extend it there if a future task needs
another joy-brain skill, rather than copying the skill into this repo.

Path caveat: several joy-brain skills hard-code `/opt/data/...` (the
production container's `HERMES_HOME`). On the wsl host that same content lives
under `~/.hermes`, so those references need adapting at use time - the skills
are still loaded and usable as references, but a script that does
`sys.path.insert(0, '/opt/data/scripts')` must be pointed at
`~/.hermes/scripts` instead. The `cdp-*.py` helpers themselves already target
`localhost:3333` (the proxy contract), so the browser path is unaffected.

### What is deliberately NOT vendored

No joy-brain content is committed to this repo. The clone is fetched at
activation from the private gitea SSH URL, exactly like `~/.firstmate` in
`modules/dev/firstmate.nix`. This repo only carries the clone URL, the pin, the
curated skill list and the `browser.cdp_url` wiring. In particular these stay
out of this repo (they live in the clone and are never copied here):

- `memory/` (personal memory) and `memories/`
- `contacts/` (private contact database)
- `profiles/` (named profiles)
- `plugins/` (e.g. the approval-gates plugin) - symlinked at activation, not vendored
- `bin/` and `scripts/` (joy's helpers, incl. the `cdp-*.py` browser scripts) - symlinked, not vendored
- `config.yaml` and `SOUL.md` - copied/symlinked from the clone at activation
- all `skills/` except the curated subset above

### MCP servers

joy-brain's MCP servers are configured in its own `config.yaml` (the
`mcp_servers` section), which the instantiation copies verbatim into
`~/.hermes/config.yaml`. joy-brain currently declares one server,
`mcp_servers.qmd` -> `http://localhost:8181/mcp` - the QMD vector-store sidecar
(see `containers/systemd/hermes/qmd.container`), which runs on **alps**, not on
the wsl host. It therefore comes along in config but is **out of scope** for
this phase: there is no qmd backend on the wsl host, and this module does not
silently half-wire one. Declaring MCP servers in Nix (the upstream module's
`mcpServers` option) is also out of scope; the browser/`chrome-devtools-axi`
path is the CDP proxy, not an MCP server.

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
