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

Beyond that: **laptop**, **server**, and **wsl** have all been built and
activated end-to-end on their real hardware and validated there by the
captain directly (real activation is run by hand, not from an agent
session per this repo's own posture, so it leaves no trace in this repo's
git history). For **wsl** specifically this covers repeated
`nixos-rebuild switch` runs on a real NixOS-WSL machine, with the Hermes
agent, the Windows-Chrome CDP proxy, the cua-driver desktop path, the
vendored skill set, and the `pass-enforcement` plugin all live and
exercised.

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

Machine-specific values (username, email, host role, a handful of
laptop-only keys like the home server hostname, and on `wsl` the Windows
account name for the Cua driver path) live in a plain
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

## Hermes desktop control (Cua driver)

The `wsl` host's Hermes agent operates the Windows desktop (screenshots,
mouse/keyboard, window control - e.g. Lightroom) through
[cua-driver](https://cua.ai/cua-driver), registered as a Hermes MCP server.
The driver runs on the Windows host; Hermes reaches it over WSL interop by
spawning `powershell.exe` - no ports, firewall rules, or auth.

cua-driver is GUI/desktop-only: it has no shell, filesystem, or registry
tools. Those are reachable directly from WSL (`powershell.exe`, `/mnt/c`)
when needed - dropping them is a deliberate trade for the simpler driver
(this replaces the earlier windows-mcp bridge).

Two halves:

- **Windows side** (not Nix-managed - it runs on Windows): run the
  checked-in bootstrap once from Windows PowerShell. It installs cua-driver
  per-user (no admin) with autostart disabled, via the official
  `https://cua.ai/driver/install.ps1` installer:

  ```powershell
  powershell.exe -ExecutionPolicy Bypass -File .\cua-driver-bootstrap.ps1
  ```

  Installed path: `%LOCALAPPDATA%\Programs\Cua\cua-driver\bin\cua-driver.exe`,
  i.e. `C:\Users\<user>\AppData\Local\Programs\Cua\...`.

- **WSL/NixOS side** (declarative): `hosts/wsl/configuration.nix` pins the
  WSL interop settings (`wsl.interop.register`, `wsl.wslConf.interop`, ...)
  so `powershell.exe` is reachable and sets `hermesAgent.cuaDriver = true`.
  `modules/dev/hermes-agent.nix` then registers the driver with Hermes at
  activation:

  ```sh
  hermes mcp add cua-driver --command powershell.exe \
    --args -NoProfile -Command "& '<cua-driver.exe path>' mcp"
  ```

  The `C:\Users\<user>` segment of that path is the one per-machine piece,
  so it is not hardcoded: it comes from `DOTFILES_WINDOWS_USER` in
  `~/.config/dotfiles/env`, which `setup.sh` fills in on the `wsl` role by
  detecting the Windows account over WSL interop (`powershell.exe`, then
  `cmd.exe`, then a `/mnt/c/Users` scan). The committed `env.example`
  placeholder keeps pure evaluation working; a real host carries its actual
  value.

  The registration is idempotent (skipped when `~/.hermes/config.yaml`
  already lists `cua-driver`) and warn-not-die, matching the repo's other
  activation steps. A fresh host is ready after a rebuild + one bootstrap
  run, in either order.

On the `wsl` host the raw `cua-driver` MCP tools are the working desktop
surface. Hermes's native `computer_use` wrapper cannot run there (it needs
an X11 client library that is absent on NixOS-WSL), so the
`operate-desktop` skill drives the `cua-driver` tools directly; the wrapper
stays enabled only as a no-op fallback. When the agent works out how to
drive a new app it saves that as its own `operate-<app>` skill in the
writable `~/.hermes/skills/` (the vendored skills are read-only Nix
symlinks and cannot be patched) - those learned skills persist across
rebuilds.

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
[Hermes Agent](https://hermes-agent.nousresearch.com) gateway and materializes
a **generic, self-contained** Hermes home (browser + Windows-desktop operator)
driving Windows Chrome through the CDP proxy on `http://localhost:3333` (see
the PR that adds `modules/dev/browser-proxy-windows.nix`). It depends on no
private external clone and no SSH to `alps`: every piece of its home is
generated by Nix or vendored in this repo. These modules are imported only by
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
  smaller, consistent fit. On the `wsl` host this module also registers the
  Cua desktop driver as a Hermes MCP server (`hermesAgent.cuaDriver`) - see
  "Hermes desktop control (Cua driver)". `hermes mcp serve` (Hermes as a
  stdio MCP server, no transport flags) still exists as an entrypoint but
  nothing in this repo registers it.
- `modules/dev/hermes-home.nix` - the curated home. Materializes `~/.hermes`
  (the `HERMES_HOME`) from repo-owned content only: a minimal `config.yaml`
  seed (provider/model, `web.search_backend: ddgs`, `browser.cdp_url`), the
  repo-tracked orchestrator `SOUL.md`, the domain-expert SOUL template at
  `~/.hermes/templates/domain-expert-SOUL.md`, the vendored `~/.hermes/bin`
  pass helpers, and real `skills/` + `plugins/` dirs. No clone, no SSH, no
  `alps`. The alps full brain is a separate module
  (`modules/dev/joy-brain.nix`, see "What is deliberately NOT vendored" below)
  that the wsl host does not import.
- `modules/dev/hermes-expert-new.nix` - packages `hermes-expert-new`, the
  deterministic profile-provisioning helper the orchestrator runs to create a
  domain expert. See "Orchestrator + domain-expert fleet (wsl)".
- `modules/dev/hermes-gateway.nix` - the `hermes-gateway` systemd `--user`
  unit. It hosts the kanban dispatcher, so the fleet can actually drain the
  board. See "Orchestrator + domain-expert fleet (wsl)".

### Browser wiring

Hermes treats `{HERMES_HOME}/config.yaml` as optional per-user state (its own
first runtime persist creates it from defaults when absent).
`modules/dev/hermes-home.nix` therefore seeds `~/.hermes/config.yaml` on first
activation from a minimal config - provider/model, `web.search_backend: ddgs`,
and this override - and deep-merges this override into it on every activation
(the alps full brain does the same from its clone's own `config.yaml` when it
carries one):

```yaml
browser:
  cdp_url: "http://localhost:3333"
```

That is the stable contract the Windows-Chrome CDP proxy exposes (see the
proxy's own README section). The merge only forces `browser.cdp_url`; every
other config key - the seed's provider/web settings plus Hermes's runtime edits
via `hermes config set` / the TUI - is preserved.

### Skills: a purpose-built set, vendored in this repo

The curated wsl instance no longer borrows any skills from joy-brain - it
fetches no clone at all (see the `hermes-home.nix` note above). It runs a
small, purpose-built, [AXI](https://axi.md/)-shaped set tailored to the
delegated-orchestrator/expert role, **vendored in this repo** under
`modules/dev/hermes-skills/<skill>/SKILL.md` (same posture as
`modules/dev/hermes-soul.md`) and symlinked into `~/.hermes/skills/` by
`modules/dev/hermes-skills.nix`:

| Skill | Purpose |
| --- | --- |
| `axi-authoring` | The spec for building a missing capability as a reusable AXI artifact (an executable CLI, a Hermes plugin, and/or a skill): the 10 AXI principles, where each artifact kind lives, and the build -> validate -> use -> refine loop. Loaded when a task needs a capability that does not exist yet. |
| `browse` | Drive the captain's real Windows Chrome for authenticated web tasks via the `hermes-browse` wrapper (the `chrome-devtools-axi` CLI over the CDP proxy); curl-vs-browser routing; automatic proxy warm-up; verify-each-step discipline; stop points. Searches go through the native `web_search` tool (keyless `web-ddgs` backend), not Chrome. |
| `web-login` | Zero-exposure credential/OTP entry into a browser form - the secret is read from `pass` internally, never through a tool parameter. Owns the entire login surface. |
| `pass-access` | Safe `pass` store access - find / ls / inspect / otp / doctor - metadata only, the secret never reaches stdout. |
| `operate-desktop` | Guide (no CLI) for operating the Windows desktop through the raw `cua-driver` MCP tools with an observe -> act -> verify loop. On `wsl` the native `computer_use` wrapper cannot run (no X11 client lib), so these MCP tools are the working surface. When the agent learns an app it saves an `operate-<app>` skill of its own in the writable `~/.hermes/skills/`. |
| `recover-blocked-page` | Recover a 403/429/paywall/WAF page via the archive ladder (Wayback -> archive.today -> reader -> API pivot -> browser), with provenance. Ships the `recover-page` wrapper. |
| `delegated-task` | The operating contract as a checklist - scope pre-flight, the irreversible-action gate, secret hygiene, outcome-report format. |

The set is the shared **base capability set**: every domain-expert profile sees it
read-only through `skills.external_dirs` (see "Orchestrator + domain-expert fleet
(wsl)"), and its `SOUL.md`/CLIs define the AXI shape new artifacts follow.

Skill discovery needs **no** trust/enable step: Hermes scans
`~/.hermes/skills/` recursively and any dir with a `SKILL.md` registers as a
"local" skill (`hermes skills list`, source `local`). `hermes skills trust` is
only for repo-local project skills (`./.hermes/skills` in a git checkout).

Native toolsets stay enabled: Hermes's built-in `browser_*` tools remain as a
fallback behind `browse`. Native `computer_use` also stays enabled, but on the
`wsl` host it cannot actually run (it needs an X11 client library absent on
NixOS-WSL), so `operate-desktop` drives the raw `cua-driver` MCP tools directly
and the wrapper is only a no-op fallback (captain decisions, 2026-09-09).

`pass-access`'s `pass-axi` CLI is packaged by `hermes-skills.nix`
(`pkgs.writeShellApplication`, on PATH) and reads the captain's real store at
`~/.password-store`. It is metadata-only by construction - there is no
`show`/`get`/`cat`; `inspect` and `otp` decrypt only through the
`~/.hermes/bin` helpers plus the `pass-otp` extension, and `doctor` prints a
GPG/env/`.gpg-id`/secret-key/decrypt-probe pass-fail matrix. Those helpers
(`pass-to`, `pass-inspect`, `pass-env`) are vendored byte-for-byte from the
private clone's `scripts/` into `modules/dev/hermes-bin/` and materialized into
`~/.hermes/bin/` by `modules/dev/hermes-home.nix` - so `pass-axi inspect`/`otp`
and `hermes-web-login` work with no clone present. The `web-login`
(`hermes-web-login`) and `browse` (`hermes-browse`) CLIs are packaged the same
way. `hermes-browse` is a thin launcher: it points `chrome-devtools-axi` at the
CDP proxy, does the cold-start warm-up (`POST :3335/show`, poll
`:3333/json/version`), and retries once on a lost target - `chrome-devtools-axi`
itself is resolved from PATH (npm global, pinned by
`modules/dev/agent-cli-tools.nix`), never installed by the wrapper. Standalone
web search is the native `web_search` tool: `modules/dev/hermes-agent.nix`
installs `ddgs` into the Hermes venv and enables the keyless `web-ddgs` backend
(`web-brave-free` is bundled but needs an API key, so it stays disabled).
`recover-blocked-page` ships its `recover-page` wrapper too (a thin output
reshaper over the byte-identical, vendored Hermes-core `recover_page.py`), so
every skill in the set now has its CLI - there are no remaining follow-up
wrappers.

The alps full brain (`hosts/hermes`) is unaffected - `modules/dev/joy-brain.nix`
still symlinks that clone's entire skill tree, and the wsl host does not import
it.

### SOUL: the orchestrator role + the domain-expert template (wsl)

The curated wsl instance does not run the private brain's persona. Its
default-profile `SOUL.md` is tracked in this repo at `modules/dev/hermes-soul.md`
and re-pinned to `~/.hermes/SOUL.md` on every activation. It is the captain's
**orchestrator**: intake a task, classify its domain, delegate to an existing
domain-expert profile through the kanban board (or create the expert when the
domain is new), own the design/intake decisions, and **never execute the domain
work itself**. It also expects experts to *build* capability - it can dispatch an
"author an AXI" card when a task needs a tool the fleet does not have. The full
brain (alps) is unaffected - it keeps joy-brain's own `SOUL.md`.

The repo also tracks the **domain-expert SOUL template** at
`modules/dev/hermes-expert-soul.md`, materialized to
`~/.hermes/templates/domain-expert-SOUL.md`. `hermes-expert-new` stamps it onto
each new expert (substituting name / domain / scope), so the delegated-worker
contract lives in one reviewable file.

### Orchestrator + domain-expert fleet (wsl)

The default profile is the orchestrator; each domain expert is a separate Hermes
profile (`~/.hermes/profiles/<name>/`), created at runtime. Nothing about this
needs new orchestration code - it is built on Hermes primitives (captain
decisions 2026-09-09, `data/hermes-orchestrator-design/report.md`):

- **The board** is `hermes kanban` (SQLite, `~/.hermes/kanban.db`). The
  orchestrator creates cards with a named `assignee`; the dispatcher promotes
  dependency-satisfied cards and spawns `hermes -p <assignee>` workers.
- **Kanban enablement is declarative.** `modules/dev/hermes-home.nix`
  deep-merges an orchestrator override into `~/.hermes/config.yaml` on every
  activation: both `toolsets` and `platform_toolsets.cli` name `kanban` (the
  engine's two-key gate - otherwise the kanban tools stay hidden), the CLI
toolset list is restricted to `kanban, terminal, file, skills, memory, web`
(so the orchestrator keeps only what it needs to classify, provision, and route),
`kanban.auto_decompose: false` (routing stays with the orchestrator), and
`kanban.max_in_progress_per_profile: 1` (decision #8 - one worker per expert
profile, so two workers never write one memory).
- **The gateway unit is the dispatcher's host.**
  `modules/dev/hermes-gateway.nix` declares a `hermes-gateway` systemd `--user`
  service (`hermes gateway run --external-supervisor`). The kanban dispatcher
  runs inside the gateway (`kanban.dispatch_in_gateway` defaults true), so
  without the unit ready cards never spawn workers. It is a plain user service
  like `browser-proxy-windows`; `hermes` recognizes it as its own unit.
- **`hermes-expert-new` provisions an expert deterministically.**
  `modules/dev/hermes-expert-new.nix` packages the repo-tracked helper
  (`modules/dev/hermes-expert-new`, usage in its `--help`): it runs
  `hermes profile create <name> --clone --no-alias --description ...`, then
  removes the cloned orchestrator `toolsets`/`platform_toolsets` gate, points
  `skills.external_dirs` at the shared `~/.hermes/skills`, empties the cloned
  local skills dir, clears the cloned orchestrator memory, disables the
  credential skills unless `--with-credentials` is passed (decision #6), stamps
  `SOUL.md` from the template, and copies + enables the `pass-enforcement`
  plugin (`--clone` does not copy plugins). It refuses a bad name or an existing
  profile; `--force` recreates one (wipes its memory and learned skills).
- **Built artifacts are the expert's own runtime state, not Nix state.**
  Experts are self-contained: a CLI/plugin/skill an expert builds lives in that
expert's own writable area (its profile's `skills/` and `plugins/`, or a
  writable PATH dir such as `~/.local/bin` for a tool) and is **not** shared
  through any fleet-wide registry or catalog. The shared Nix base skills stay
  read-only symlinks. A rebuilt host (or a deleted profile) loses runtime-created
  experts, their memory, and their learned skills; the base set survives.

### Plugins: `pass-enforcement` (wsl)

`modules/dev/hermes-plugins.nix` vendors native Hermes plugins under
`modules/dev/hermes-plugins/<name>/` and materializes them into
`~/.hermes/plugins/`. The one plugin so far is **`pass-enforcement`**: a
`pre_tool_call` hook that structurally blocks the secret-dumping `pass` forms -
`pass show <path>` and a bare `pass <path>` (which `pass` treats as show),
including the `-c`/`-q` variants and forms reached through a pipe, `sudo`/env
prefix, or `bash -c` - in the `terminal` toolset. This is defense-in-depth for
the `pass-access` / `web-login` design: even outside the sanctioned `pass-axi`
and `hermes-web-login` paths, the operating agent cannot dump a stored secret
to stdout / the transcript. The block message points the agent at
`pass-axi inspect <path>` (metadata) or `hermes-web-login <path>` (into a form).
It is deliberately precise - `pass-axi`/`pass-to`/`pass-env`,
`pass otp|ls|find|grep|insert|edit|git|init`, `hermes-web-login`, `recover-page`
and unrelated commands that merely contain "pass" all still run.

Unlike skills, a plugin is opt-in: the activation also runs
`hermes plugins enable pass-enforcement --no-allow-tool-override` (idempotent,
warn-not-die). `modules/dev/hermes-home.nix` creates `~/.hermes/plugins` as a
real directory, so this repo's plugin is symlinked straight in. Validate a
plugin dir with `hermes plugins doctor modules/dev/hermes-plugins/pass-enforcement`.
The alps full brain does not import this module.

### What is deliberately NOT vendored

No private joy-brain content is committed to this repo. On the `wsl` host the
curated Hermes home is fully self-contained and imports no clone at all - the
config is synthesized by `modules/dev/hermes-home.nix`, the `~/.hermes/bin`
pass helpers and the `SOUL.md` are vendored here, and the skills/plugins are
the repo-tracked sets described above. On the alps full brain,
`modules/dev/joy-brain.nix` still clones the private
`ssh://git@alps:2222/babbarc/joy-brain.git` at activation into
`~/.local/share/joy-brain` (pin: commit
`8c95745461bf7b01dbcc17659853bad62f35bd88`, the `joyBrainRev` constant) and
materializes the full `~/.hermes` from it - same posture as `~/.firstmate` in
`modules/dev/firstmate.nix`. Its private content is never copied into this
repo:

- `memory/` (personal memory) and `memories/`
- `contacts/` (private contact database)
- `profiles/` (named profiles)
- its `plugins/` (e.g. `approval-gates`) - the wsl path does not carry them
- its `bin/` and `scripts/` - the `pass-*` helpers are vendored byte-for-byte
  under `modules/dev/hermes-bin/` (see the pass-access note above), and the
  `cdp-*.py` browser helpers are **not** used on wsl: the vendored `hermes-browse`
  drives `chrome-devtools-axi` over the CDP proxy instead
- its `config.yaml` and `SOUL.md` - the wsl path synthesizes its own config
  (`modules/dev/hermes-home.nix`) and pins the repo-tracked
  `modules/dev/hermes-soul.md`
- its `skills/` tree - the wsl path runs the repo-vendored set instead (see
  "Skills: a purpose-built set" above)

### MCP servers

On the `wsl` host the `config.yaml` seed declares no MCP servers. The one the
instance genuinely uses - the Cua desktop driver - is registered at activation
by `modules/dev/hermes-agent.nix` (`hermesAgent.cuaDriver`, wsl-only), which
merges the `mcp_servers.cua-driver` entry into the seeded file.

On the alps full brain the clone's own `config.yaml` declares
`mcp_servers.qmd` -> `http://localhost:8181/mcp`, the QMD vector-store sidecar
(see `containers/systemd/hermes/qmd.container`). That is **alps-only** and is
not part of the wsl seed: there is no qmd backend on the wsl host, and nothing
here half-wires one. Declaring MCP servers in Nix (the upstream module's
`mcpServers` option) is also out of scope; the browser/`chrome-devtools-axi`
path is the CDP proxy, not an MCP server.

## Deploying to a new machine

`setup.sh` builds, activates, and applies chezmoi. Everything below is
per-machine or out-of-band - it is not in the flake and `setup.sh` cannot
do it for you:

1. **Per-machine env** - `~/.config/dotfiles/env`. `setup.sh` writes it,
   prompting only the keys the role needs (`env.example` documents them
   all). On `wsl` it auto-detects `DOTFILES_WINDOWS_USER` over WSL interop.
2. **agenix identity** - on `laptop`/`server`, generate the passphrase-less
   `~/.ssh/id_agenix` keypair once and add its `.pub` to `secrets.nix`
   (see "Secrets"). `wsl` uses the NixOS host key and needs nothing here.
3. **SSH access to the private Gitea on `alps`** (`ssh://git@alps:2222`) -
   `hermes` (alps) only: `modules/dev/joy-brain.nix` clones
   `babbarc/joy-brain.git` from it at activation. Add this machine's key to
   that Gitea account and confirm `ssh -p 2222 git@alps` works. The `wsl`
   host needs nothing here - its Hermes home is repo-owned.
4. **GPG + `pass`** - import the captain's GPG private key
   (`gpg --import`) and clone the `pass` store to `~/.password-store`
   (`setup.sh` prompts for its remote URL). Needed by `pass-git-sync` and,
   on `wsl`, the `pass-access` / `web-login` Hermes skills.
5. **`gh auth login`** - GitHub CLI auth for `gh` / `gh-axi`.
6. **Hermes provider auth** (`wsl` only) - after the first rebuild, give
   the Hermes agent its model-provider credentials (`hermes` config / the
   provider's own login); the engine installs declaratively but ships no
   keys. The default-profile credentials are inherited by every expert the
   orchestrator creates (its config and `.env` are what `--clone` copies).
   The `hermes-gateway` user unit starts with the session and hosts the
   kanban dispatcher; check it with `systemctl --user status hermes-gateway`.
7. **Windows side** (`wsl` only, run from Windows, not WSL):
   - a working Windows **Chrome** install for the CDP proxy
     (`browser-proxy-windows` drives the captain's real Chrome);
   - `cua-driver-bootstrap.ps1` once from Windows PowerShell to install
     the Cua desktop driver (per-user, no admin) - see "Hermes desktop
     control (Cua driver)".

## Validating changes

Pure evaluation is the extent of what an agent session here can itself
verify, and what any change should be re-checked against before merging:

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
cua-driver-bootstrap.ps1   Windows-side one-time setup for the Hermes Cua desktop driver
patches/                local patches applied to inputs, if any
```

See `AGENTS.md` for build/validate commands, architecture notes, and
sharp-edge details behind each of the above (agenix identity, chezmoi
split, session-secret/SSH-agent wiring, and more).
