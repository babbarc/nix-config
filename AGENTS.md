# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

## Origin and status

Split fresh (no preserved history) from the `dotfiles` repo's `nix/` directory - see
that repo's migration report at
`dotfiles-nix-chezmoi-agenix-migration-plan/report.md` for full design rationale.
This repo started as Phase 1 of that plan (scaffolding + agenix wiring),
validated by pure Nix evaluation only - see "Validating changes" below for
what an agent session can itself verify. Since then, the `laptop`,
`server`, and `wsl` hosts have all been built and activated end-to-end on
their real hardware and validated there by the captain directly; real
activation is run by hand on the actual machine, not from an agent
session, so it leaves no trace in this repo's git history - don't expect a
commit to corroborate it. For `wsl` this covers repeated `nixos-rebuild
switch` runs on a real NixOS-WSL machine with the Hermes agent, the
Windows-Chrome CDP proxy, the cua-driver desktop path, the vendored skill
set, and the `pass-enforcement` plugin all live and exercised.

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

`setup.sh` now runs `nix shell nixpkgs#git nixpkgs#jq nixpkgs#curl nixpkgs#chezmoi
-c chezmoi init "$DOTFILES_REPO_URL" --apply --force --no-tty --purge` right
after build+activate. `--purge` is chezmoi's own one-command
fetch+apply+purge: it clones the sibling `dotfiles` repo's chezmoi source
into a throwaway directory, applies it, and purges that directory again, all
in one invocation - no persistent `~/.dotfiles` checkout is left on the host.
The four tools come from nixpkgs because fresh NixOS-WSL images carry none of
them, and the dotfiles' own chezmoi scripts need git (clone + externals), jq
(modify_settings.json) and curl (run_once_install-fisher.sh). `--one-shot` is
deliberately NOT used: it implies `--purge-binary`, which tries to unlink
chezmoi's own binary - impossible from the read-only nix store
('unlinkat ...: read-only file system'). This is a deliberate trade, not
an oversight: every apply (initial or later) redoes the full clone+apply+purge
cycle rather than reusing a local checkout. It closes the gap where a real
host still running an old, pre-cutover home-manager generation would lose its
chezmoi-owned content (`.claude`, `.codex`, `.pi`, nvim, lazygit, herdr,
wezterm, fish functions) on activation with nothing there yet to replace it.

The single `init --apply --purge` invocation passes both `--no-tty` and
`--force`: chezmoi's default behavior on a target file that drifted
since it last wrote it (herdr rewrites its own `~/.config/herdr/config.toml`
at runtime, so this isn't hypothetical) is to prompt
`diff/overwrite/all-overwrite/skip/quit` - with no TTY attached that prompt
just fails immediately (`chezmoi: <file>: EOF`), confirmed by hand against
this repo's pinned chezmoi (2.72.0). `--force` is chezmoi's own documented
flag for exactly this ("make all changes without prompting") - it always
overwrites the drifted file with the source's target state, never skips or
excludes it. This is a deliberate captain decision, not a default worth
reconsidering casually.

`browser-proxy-firstmate.nix` is a separate, permanent exception: the
migration report says it stays permanently nix-owned (vendored infra config,
not a personal dotfile), so its two files are vendored directly into this
repo at `containers/systemd/`.

## hermes joy-stack (Phase 6)

`homeConfigurations.hermes` (`flake.nix` -> `hosts/hermes/home.nix` ->
`modules/hermes-joy-stack.nix`) is a second, independent standalone
home-manager config for the `hermes` system user (uid 1003) on the joy host,
alongside `homeConfigurations.server` (yeti) on the same machine - needed
because standalone home-manager activates per-user and the joy-stack quadlets
must land in `/home/hermes/.config/`. It vendors three quadlets
(`containers/systemd/hermes/{hermes,browser-proxy,qmd}.container`) synced
verbatim from the joy-stack overlay (`gitea:babbarc/joy-stack.git`) with
`Image=` pinned to `localhost/*:v2026.8.31-babbarc.1`; re-sync from the
overlay when it bumps the tag. Deliberately does NOT adopt upstream
`nix/nixosModules.nix` (builds a different image). Named volumes, image
build/pull, and the root-only pieces (user creation,
`loginctl enable-linger hermes`, `/mnt/nebula` ACL) stay imperative and out
of this repo - all three root pieces are already live on the host. Activation
is captain-run as the hermes user: `nix run home-manager -- switch -b hm-bak
--flake ~/.nix-config#hermes` (the `-b` is required on first activation - the
`.container` files pre-exist as plain files).

Direct-install migration (Phase B, 2026-09-09) now declares the future
container-free shape ALONGSIDE the quadlets in the same profile
(`hosts/hermes/home.nix` imports `modules/dev/{hermes-agent,joy-brain,browser-proxy-linux,hermes-alps-services}.nix`
with `hermesAgent.standaloneDeps = true`): engine
(same `hermesRev`), full-brain instantiation, a Linux host-Chrome browser
proxy (`containers/systemd/browser-proxy-linux.py`, Q1a), and systemd --user
units for gateway/vision-bridge/baileys-watch/qmd (Q2a native @tobilu/qmd,
Q3a host CUPS is a documented root step, not a unit). Both paths build green
and coexist until the captain's Phase C/D cut-over - the direct units are
deliberately named `hermes-*` to avoid colliding with the podman
quadlet-generated `hermes.service`/`browser-proxy.service`/`qmd.service`.
See the scoping report (firstmate data dir) for the full design; do NOT
retire the quadlets (Phase E) until the direct install is proven.

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

## Hermes desktop control: Cua driver (wsl host)

The `wsl` host's Hermes agent drives the Windows desktop through
[cua-driver](https://cua.ai/cua-driver), registered as a Hermes MCP server.
`modules/dev/hermes-agent.nix` (option `hermesAgent.cuaDriver`, enabled in
`hosts/wsl/configuration.nix`; off on the alps `hermes` host, which has no
Windows side) runs at activation, after `hermesHomeInstantiate` so it edits
the seeded `~/.hermes/config.yaml`:

    hermes mcp add cua-driver --command powershell.exe \
      --args -NoProfile -Command "& 'C:\Users\<DOTFILES_WINDOWS_USER>\AppData\Local\Programs\Cua\cua-driver\bin\cua-driver.exe' mcp"

The `C:\Users\<user>` segment is not hardcoded: `hermes-agent.nix` reads
`dotfilesEnv.DOTFILES_WINDOWS_USER` (default: the `env.example` placeholder,
which keeps pure eval working) and `setup.sh` detects the real Windows
account on the `wsl` role via WSL interop (`powershell.exe`/`cmd.exe`, then
a `/mnt/c/Users` scan) and writes it to `~/.config/dotfiles/env`.

The registration is idempotent (skipped when `~/.hermes/config.yaml` already
lists `cua-driver`) and warn-not-die. The Windows-side install (per-user, no
admin, autostart off) is `cua-driver-bootstrap.ps1` at the repo root, which
invokes the
official `https://cua.ai/driver/install.ps1` with `-NoAutoStart`. Hermes
reaches the driver over WSL interop (`powershell.exe`), so the interop pins
in `hosts/wsl/configuration.nix` are load-bearing. cua-driver is
GUI/desktop-only (no shell/filesystem/registry) - a deliberate capability
drop from the removed windows-mcp bridge; PowerShell and `/mnt/c` are
reachable directly from WSL. Full usage in README "Hermes desktop control
(Cua driver)".

## Herdr runtime backend

Herdr is the runtime backend (firstmate's `FM_BACKEND=herdr`) and is now
pinned, not curl-installed: `modules/dev/herdr.nix` fetches the exact
v0.8.2 release binary (protocol 20, `github.com/herdrdev/herdr`) via
`fetchurl` with per-arch sha256 from `herdr.dev/latest.json`, installs once
under `~/.local/bin/herdr` when missing, and leaves `herdr update` to
self-update. No nixpkgs package exists (no binary cache; single Go binary).
That module also installs herdr integrations for pi + the five extra agent
harnesses (claude, codex, kimi, opencode, grok) via `herdr integration
install`, after `mkdir -p`ing each config dir herdr requires to pre-exist.
firstmate's herdr backend floor is protocol 14 (needs `herdr` + `jq`;
`python3` only for optional protocol-16 event push/ordering); all three are
already declared on every host (jq in `firstmate.nix`, python3 in
`dev-toolchains.nix`). Fish is the default shell everywhere; on wsl it lands
at `/etc/profiles/per-user/<user>/bin/fish` (`programs.fish.enable` +
`useUserPackages`), which herdr's chezmoi `default_shell` points at, and the
integration hooks are POSIX `sh` + `python3` so they are shell-agnostic.

## Harness auto-compaction windows

Pi and Claude Code are pinned to auto-compact at the model's *real* context
window instead of an early default ("correct the window" approach).

- **Pi** (`modules/dev/pi.nix`): `~/.pi/agent/models.json` is a read-only
  home-manager symlink declaring `contextWindow`/`maxTokens` (and the
  captain's pre-existing `cost` overrides) under
  `providers.deepseek.modelOverrides` for the three active deepseek v4
  models (1M / 384K - verify with `pi --list-models deepseek`). Pi compacts
  off the resolved model's `contextWindow`. models.json has no runtime
  writer (unlike settings.json), so a symlink is safe.
- **Claude Code** (`modules/dev/claude-code.nix`): a `claudeSettings`
  activation script jq-merges `autoCompactWindow: 1000000` into
  `~/.claude/settings.json` (same merge pattern the old pi settings.json
  used; the file also holds runtime-written keys and the herdr SessionStart
  hook, so it is not symlinked). Claude's effective threshold is
  `min(autoCompactWindow, model real context window)`, so 1M (the max of
  the accepted 100k-1M range) collapses to each model's own window. Verified
  against CLI 2.1.267.

## Windows Chrome CDP proxy (wsl host)

`modules/dev/browser-proxy-windows.nix` (imported only by
`hosts/wsl/configuration.nix`, NOT the shared `modules/dev` list - it needs WSL
interop) deploys `containers/systemd/browser-proxy-windows.py` as a plain
systemd --user service (`browser-proxy-windows.service`) that runs the proxy
directly as the login user. The script path is wired through the nix store, not
a bind mount. It exposes `http://localhost:3333` for a Hermes agent's
`browser.cdp_url`; the proxy lazily launches the captain's Windows Chrome on
`127.0.0.1:9222` and stops it after `IDLE_TIMEOUT`. It owns exactly one Chrome
via a `--user-data-dir=C:\Users\Public\Hermes\ChromeProfile` marker and never
touches the captain's browsing Chrome. No podman, quadlet, or container image
is involved: the original podman quadlet was dropped because its WSL interop is
broken (`powershell.exe` unreachable from inside the container -> Chrome launch
loop), and running the script directly is verified end-to-end (real Chrome 152).
Manage it as any user service: `systemctl --user status/start
browser-proxy-windows` (WantedBy=default.target, Restart=on-failure starts it
at session start).

Sharp edges that forced the reverse-tunnel design (all verified live):
- Chrome 152 removed `--remote-debugging-address` (string absent from chrome.dll;
only `remote-debugging-port`/`-pipe`/`-targets` remain), so Chrome binds DevTools
to `127.0.0.1` and ignores `0.0.0.0`.
- WSL2 NAT inbound to Windows is firewalled (Public profile), and `netsh
portproxy` needs elevation the interop user lacks.
- So the proxy never dials the WSL gateway. It spawns a detached Windows-side
helper (`powershell.exe` + `Add-Type` C# socket bridge, embedded in the .py) that
connects OUTBOUND back into WSL via WSL2 localhost forwarding and bridges to
Chrome `127.0.0.1:9222`. Gateway IP is resolved at runtime for diagnostics only.
- Running directly on the WSL host (not in a container), the proxy has the WSL
interop surface natively: `/mnt/c`, `/init`, and `/run/WSL`, so
`powershell.exe` execs directly - no bind mounts. The dropped podman container
required those mounts and still failed interop, which is why it was removed.
- Control API on loopback `CONTROL_PORT` (default 3335): `POST /show` and
`POST /hide` toggle the managed Chrome window via Win32 `ShowWindow` (scoped to
the marker process, never the captain's Chrome), and `GET /status` reports
`{chrome, visible}`. It does not start/stop Chrome, so single-instance +
idle-stop invariants hold.
## Hermes agent on wsl (install + self-contained home)

`modules/dev/hermes-agent.nix` and `modules/dev/hermes-home.nix` (imported only
by `hosts/wsl/configuration.nix`, never the shared `modules/dev` list) install
the Hermes agent and materialize a generic, self-contained Hermes home - no
private clone and no SSH to `alps`. Full rationale + the curated skill subset
+ the not-vendored list live in README "Hermes agent (wsl)"; the sharp edges
worth knowing here:

- Hermes is a pinned `uv sync --extra all --locked --python 3.11` of
  `github:NousResearch/hermes-agent` at tag `v2026.8.31` (revision
  `29112bef099274229cadff79cdff7bf7b99c4b77`), into the writable checkout
  `~/.local/share/hermes-agent`. The checkout MUST be writable: uv's setuptools
  editable build writes `hermes_agent.egg-info` into the project tree, so a
  read-only nix-store source fails ("could not create 'hermes_agent.egg-info':
  Permission denied" - verified). Upstream's flake packaging (uv2nix + npm
  TUI/web) is deliberately not adopted (5 extra inputs, no binary cache,
  multi-hour builds) - see the module header.
- `modules/dev/hermes-home.nix` materializes `~/.hermes` (HERMES_HOME) from
  repo-owned content only: a minimal `config.yaml` seed (provider/model,
  `web.search_backend: ddgs`, `browser.cdp_url`) that is deep-merged with
  `browser.cdp_url` on every activation (yq `*`, so runtime edits survive);
  `~/.hermes/SOUL.md` re-pinned to `modules/dev/hermes-soul.md` (the
  firstmate-delegated browsing + Windows-desktop specialist role); the vendored
  `~/.hermes/bin` pass helpers (`pass-to`/`pass-inspect`/`pass-env`, byte-for-byte
  from the private clone's `scripts/`, committed under `modules/dev/hermes-bin/`);
  and real `skills/` + `plugins/` dirs. It also removes any stale clone-pointing
  dir symlink left by an older generation. The private clone now lives only on
  the alps full brain (`modules/dev/joy-brain.nix`, `joyBrainRev` pin
  `8c95745461bf7b01dbcc17659853bad62f35bd88`; empty degrades to clone HEAD + warn),
  which the wsl host does not import.
- The curated instance runs a purpose-built, AXI-shaped skill set vendored in
  this repo at
  `modules/dev/hermes-skills/<skill>/SKILL.md` (`axi-authoring`, `browse`,
  `web-login`, `pass-access`, `operate-desktop`, `recover-blocked-page`,
  `delegated-task`), symlinked into `~/.hermes/skills/` by
  `modules/dev/hermes-skills.nix` (imported only by
  `hosts/wsl/configuration.nix`, `entryAfter hermesHomeInstantiate`).
  `axi-authoring` is the spec for building a missing capability as a reusable
  AXI artifact (CLI / plugin / skill, the 10 AXI principles, artifact layout,
  validation checklist); both SOULs point at it.
  `pass-axi` (the `pass-access` CLI) is packaged by `hermes-skills.nix`
  (`pkgs.writeShellApplication`, on PATH): metadata-only by construction (no
  show/get/cat), `inspect`/`otp` decrypt only via the `~/.hermes/bin` helpers +
  the `pass-otp` extension, `doctor` is the GPG/env pass-fail matrix. It reads
  the captain's real store at `~/.password-store`. `hermes-web-login` (the
  `web-login` CLI) is packaged the same way (`writeShellApplication` execing a
  vendored python3+websockets script,
  `modules/dev/hermes-skills/web-login/scripts/hermes-web-login`): the secret
  is read inside the script via the `~/.hermes/bin/pass-to` helper and pushed
  GPG -> pipe -> memory -> CDP `Runtime.evaluate` -> DOM (never an arg, stdout,
  or tool-call record); CDP target auto-discovered from
  `http://localhost:3333/json/version`. `hermes-browse` (the `browse` CLI) is
  packaged the same way (`writeShellApplication` reading
  `modules/dev/hermes-skills/browse/scripts/hermes-browse`): a thin launcher
  that points `chrome-devtools-axi` at the CDP proxy, does the cold-start
  warm-up (`POST :3335/show`, poll `:3333/json/version` for
  `webSocketDebuggerUrl`), and retries once on a lost target. `chrome-devtools-axi`
  is resolved from PATH at runtime (npm global pinned by
  `modules/dev/agent-cli-tools.nix`), deliberately not a nix runtimeInput, and
  the wrapper never installs it. Standalone web search is the native
  `web_search` tool: `modules/dev/hermes-agent.nix` (`hermesWebSearch`
  activation) `uv pip install`s `ddgs` into the Hermes venv - re-added every
  rebuild since the preceding `uv sync --locked` prunes it - enables the
  bundled keyless `web-ddgs` plugin, and pins `web.search_backend: ddgs`
  (`web-brave-free` is bundled but needs `BRAVE_SEARCH_API_KEY`, so it stays
  disabled). `recover-page` (the `recover-blocked-page` CLI) is packaged the
  same way (`writeShellApplication`, `python3`-only): the recovery logic is
  `modules/dev/hermes-skills/recover-blocked-page/scripts/recover_page.py`,
  vendored BYTE-IDENTICAL from Hermes core (MIT) - re-sync from a fresh Hermes
  install, do not fork - and the thin `recover-page` wrapper beside it only
  reshapes the output (content-first no-arg view, one-line `ok: {route,
  provenance, snapshot_date, saved}` with snapshot-age disclosure,
  `ALL_ROUTES_FAILED` route trace on total failure). All the SKILL.md interim
  notes are now gone; every skill's wrapper binary ships.
  Skill discovery needs NO trust
  step: Hermes scans
  `~/.hermes/skills/` recursively (`os.walk` follows symlinks) and any
  `SKILL.md` dir registers as a `local` skill; `hermes skills trust` is only
  for repo-local `./.hermes/skills`. Verify after activation with `hermes
  skills list` (source `local`, must show the seven). Design report:
  `firstmate/data/hermes-axi-skills-design/report.md`. The alps full brain is
  unaffected - `modules/dev/joy-brain.nix` still symlinks its whole tree.
- On alps, joy-brain's `config.yaml` declares `mcp_servers.qmd` ->
  `http://localhost:8181/mcp` (the QMD sidecar), and the full-brain
  instantiation carries it along. That is alps-only: the wsl seed declares no
  MCP servers, and `modules/dev/hermes-agent.nix` adds the one it uses
  (`cua-driver`) itself. See README "MCP servers".
- `HERMES_HOME` is `home.sessionVariables`, so it reaches interactive shells
  only (same gap firstmate.nix documents). The gateway is now a declared unit
  (`modules/dev/hermes-gateway.nix`, see the fleet section below); other
  long-running `hermes` subcommands are still launched by hand.
- `hermes mcp serve` runs Hermes as a stdio MCP server (no transport flags)
  that exposes its conversations to other agents. Nothing in this repo
  registers it now that the windows-mcp harness selector is gone; a caller
  that wants to delegate to Hermes over MCP wires up that entry itself
  (`<harness> mcp add hermes -- hermes mcp serve` or equivalent).

## Hermes orchestrator + domain-expert fleet (wsl)

The default profile is the captain-facing ORCHESTRATOR; each domain expert is a
runtime-created Hermes profile. Authoritative design (read before changing any
of this): `firstmate/data/hermes-orchestrator-design/report.md` (captain
approved all ten calls 2026-09-09). What the code shows plus the sharp edges:

- **SOULs.** `modules/dev/hermes-soul.md` -> `~/.hermes/SOUL.md` is the
  orchestrator (intake -> classify -> delegate via the board; never executes).
  Creating an expert is a captain decision: when no existing expert fits, the
  orchestrator proposes one to three candidate profiles (name, domain, scope)
  with a recommendation and waits - it only runs `hermes-expert-new` after the
  captain agrees on name and scope. Candidates are sized broadly (a whole
  capability domain, not a task-specific sliver), and an existing broad expert
  that plausibly covers the task is delegated to, not replaced by a narrow one.
  `modules/dev/hermes-expert-soul.md` ->
  `~/.hermes/templates/domain-expert-SOUL.md` is the domain-expert template,
  stamped per expert by `hermes-expert-new` (placeholders `{{EXPERT_NAME}}`,
  `{{DOMAIN}}`, `{{DOMAIN_SCOPE}}`).
- **Kanban enablement is a two-key gate.** `tools/kanban_tools.py`
  `_profile_has_kanban_toolset()` gates the kanban tools on the TOP-LEVEL
  `toolsets` key, while the actual CLI schema comes from
  `platform_toolsets.cli`. `modules/dev/hermes-home.nix` deep-merges an
  orchestrator override (yq `*`, arrays replaced) forcing
  `toolsets: [kanban, terminal, file, skills, memory, web]`,
  `platform_toolsets.cli` to the same list, `kanban.auto_decompose: false`, and
  `kanban.max_in_progress_per_profile: 1`. Verified with the engine probe: gate
  true, resolved CLI set = those six + the MCP-derived `cua-driver` toolset.
- **Dispatcher lives in the gateway.** `modules/dev/hermes-gateway.nix` declares
  `hermes-gateway.service` (`hermes gateway run --external-supervisor`, PATH
  must include `/etc/profiles/per-user/<user>/bin` because home.packages land
  there on this host, plus `~/.local/bin` for the CLI). systemd's INVOCATION_ID
  (or `--external-supervisor`) satisfies the engine's supervised-gateway
  conflict guard, so no `--force` is needed. Without the unit, ready cards never
  spawn workers.
- **`hermes-expert-new`** (`modules/dev/hermes-expert-new.nix` packaging
  `modules/dev/hermes-expert-new`, runtimeInputs python3): the deterministic
  profile provisioning flow - clone, drop `toolsets`/`platform_toolsets`, set
  `skills.external_dirs` to the DEFAULT home's `skills/`, empty the cloned local
  skills, clear cloned `memories/MEMORY.md`/`USER.md`, gate the credential
  skills (`skills.disabled` is read by the engine but absent from the config
  defaults table, hence `config set --force`), stamp SOUL from the template,
  copy + enable `pass-enforcement` (`--clone` never copies plugins). Credential
  skills are opt-in via `--with-credentials`. Refuses an existing profile
  without `--force` (which deletes and recreates). Run it from the
  orchestrator's shell: `--clone` copies the ACTIVE profile.
- **Experts are self-contained; no shared AXI registry.** An expert's built
  AXIs live in its own writable area (profile `skills/`, `plugins/`, or a
  writable PATH dir such as `~/.local/bin` for a CLI) and are not shared across
  experts. `axi-authoring` is the shared spec. Every expert sees the shared
  base skills read-only via `skills.external_dirs`; a rebuilt host or deleted
  profile loses runtime-created experts and their learned skills.

## Hermes pass-enforcement plugin (wsl host)

`modules/dev/hermes-plugins.nix` (imported only by
`hosts/wsl/configuration.nix`) vendors native Hermes plugins under
`modules/dev/hermes-plugins/<name>/` (`plugin.yaml` + `__init__.py`,
`provides_hooks: [pre_tool_call]` + a `register(ctx)`) and materializes them
into `~/.hermes/plugins/`. Currently one: `pass-enforcement`, a `pre_tool_call`
hook that structurally blocks the secret-dumping `pass` forms
(`pass show <path>` and a bare `pass <path>`, incl. `-c`/`-q`, pipes,
`sudo`/env/`bash -c` wrappers) in the `terminal` toolset - captain decision #8,
DD7 cap.3 of the Hermes AXI-skills design. It deliberately does NOT touch
`pass-axi`/`pass-to`/`pass-env`, `pass otp|ls|find|grep|insert|edit|git|init`,
`hermes-web-login`, or unrelated commands containing "pass". Precedent for the
hook shape: Hermes's bundled `approval-gates` plugin (alps full brain).
Validate a plugin dir with `hermes plugins doctor <path>`;
the runtime dispatch entry point is
`hermes_cli.plugins._dispatch_pre_tool_call_hooks`.

`modules/dev/hermes-home.nix` creates `~/.hermes/plugins` as a real directory,
so `modules/dev/hermes-plugins.nix` simply symlinks this repo's plugin in.
Unlike skills, a plugin also needs `hermes plugins enable <name>` (activation
does this idempotently with `--no-allow-tool-override`, warn-not-die).

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
