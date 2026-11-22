#!/usr/bin/env bash
# setup.sh - the one entry point for every host (laptop, server, wsl, hermes).
#
# Two lifecycles, one script (design: data/nix-unified-system-design/report.md
# sections 4.2/4.3 in the firstmate repo):
#
#   setup.sh              install - interactive, once per machine
#   setup.sh update       update  - non-interactive, repeatable
#
# INSTALL takes a bare machine (nix only - no git, no editors, no checkout) to
# a fully configured dotfiles setup on any of the flake's four targets:
#
#   1. detects the role (laptop / server / wsl / hermes) from the environment,
#      with a prompt fallback and a --role / SETUP_ROLE / positional override
#   2. asks where to get the repo from (home LAN Gitea / public GitHub mirror /
#      an existing local checkout) and walks through only the per-machine env
#      values that role needs (Enter accepts the [default]; Enter on an
#      optional machine-specific key omits it with a warning). The `hermes`
#      role reads no env file, so it skips every env question.
#   3. fetches the repo to ~/.nix-config, writes ~/.config/dotfiles/env with
#      exactly the role's keys, then builds + activates the right host:
#      - laptop/server: homeConfigurations.<role>.activationPackage, then
#        env HOME_MANAGER_BACKUP_EXT=backup ./result/activate
#      - wsl on NixOS: nixosConfigurations.wsl.config.system.build.toplevel,
#        then point /nix/var/nix/profiles/system at the result (so the next
#        WSL boot uses this generation, mirroring nixos-rebuild's profile
#        step), then sudo ./result/bin/switch-to-configuration switch
#      - wsl on any other distro: the portable dev-only home-manager profile
#        (homeConfigurations.server) + env HOME_MANAGER_BACKUP_EXT=backup
#        ./result/activate
#      - hermes: nix run home-manager -- switch -b hm-bak --flake
#        <checkout>#hermes, run AS the hermes user from that user's own
#        checkout (homeConfigurations.hermes manages /home/hermes, so this
#        role refuses to run as any other account; that profile must not
#        touch the hermes user's hand-managed dotfiles, so no chezmoi)
#      then (except for `hermes`) applies the sibling `dotfiles` repo's
#      chezmoi-managed dotfile content (nvim, lazygit, herdr, fish functions,
#      wezterm, etc. - see AGENTS.md's "Chezmoi cutover" section) via
#      chezmoi's own init+apply --purge, which clones, applies, and purges its
#      source directory in a single command - no persistent local checkout is
#      left behind (and no binary purge: --one-shot would delete chezmoi
#      itself, which fails from the read-only nix store)
#   4. prints a readiness report (checkout drift, pi/hermes/firstmate
#      resolution, hermes units, gh/gpg/pass, per-role env keys) - report
#      only, it never fails the run
#
# UPDATE runs the same converging phases with none of the install-only ones:
# it pulls the checkout (git pull --ff-only; nix flake update only with
# --bump), builds + activates with the exact same per-host command, re-applies
# chezmoi the same way, refreshes the self-updating agent runtimes (pi, hermes,
# herdr, the npm axi suite, firstmate), then prints the same readiness report.
# It never prompts and never writes ~/.config/dotfiles/env - a missing env
# file means install never ran, and update refuses instead of inventing one.
# `-b hm-bak`/`--role hermes` is the joy-host profile: no chezmoi, no runtime
# refresh, no env file, and it is invoked only as the hermes account itself.
#
# Role detection: distro NixOS (os-release ID=nixos) -> wsl; hostname "laptop"
# -> laptop; login user "hermes" -> hermes; otherwise prompted (laptop/server/
# wsl, default server) on install, and an error on update (which never
# prompts). The role decides which env keys are asked for and written: every
# role except `hermes` gets DOTFILES_USERNAME + DOTFILES_USER_EMAIL +
# DOTFILES_HOST_ROLE (the latter fixed to the role); laptop also gets its
# server / joy-console / stereo-transcode keys; wsl also gets the optional
# corporate-CA key and DOTFILES_WINDOWS_USER (auto-detected via WSL interop -
# the Windows account name that the Cua desktop-driver path in
# modules/dev/hermes-agent.nix is built from). WEZTERM_*
# keys are Windows-side only and never prompted or written here - the Windows
# machine maintains its own env file (see env.example). An existing env file's
# keys outside the role's matrix are dropped on rewrite (the final summary
# says so) - the file is deterministic per role.
#
# Only nix is required: nix fetches the repo itself (nix-prefetch-url --unpack
# for archives, libgit2 for git). git is only used when present and chosen for
# a clone. Flakes are enabled per-invocation via NIX_CONFIG - on NixOS the
# generated /etc/nix/nix.conf is read-only, so never instruct editing it.
#
# The build evaluates the flake from the remote URL without a checkout, with
# the per-machine env file fed in as an input override (pure evaluation stays
# intact; the override is not written to flake.lock). LOCAL filesystem refs
# must carry the path: scheme; remote URLs need no prefix:
#   nix build 'path:<url>#<attr>' \
#     --override-input dotfiles-env "path:$HOME/.config/dotfiles/env"
#
# Usage:
#   setup.sh [install|update] [--role <laptop|server|wsl|hermes>] [--dry-run]
#   setup.sh update [--bump] [--allow-dirty] [--skip-runtime]
#
#   --role <role>  force the host role instead of detecting it
#   --dry-run      print every command that would run - nothing is fetched,
#                  written, pulled, built or activated
#
# Non-interactive / testing: pipe answers on stdin (empty line accepts the
# default, EOF accepts defaults for the rest) and set SETUP_YES=1 to
# auto-confirm, e.g.:
#   printf '1\n\n\n\n...\n' | SETUP_YES=1 ./setup.sh
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: setup.sh [install|update] [--role <laptop|server|wsl|hermes>] [--dry-run]
       setup.sh update [--bump] [--allow-dirty] [--skip-runtime]

One entry point for this nix-config repo on any host (laptop, server, wsl,
hermes).

  install        (default) interactive guided bootstrap, once per machine:
                 detect the role, ask for the per-machine values, write
                 ~/.config/dotfiles/env, build + activate, apply chezmoi.
  update         non-interactive: pull the checkout, build + activate with
                 the same command, re-apply chezmoi, refresh the
                 self-updating agent runtimes, print a readiness report.
                 Never prompts and never rewrites the env file.

  --role <role>  force the host role (default: detect from the environment,
                 then prompt on install; on update detection must succeed).
                 `hermes` only works when run as the hermes account itself.
  --dry-run      print every command that would run - change nothing
  --bump         (update) also run `nix flake update` in the checkout
  --allow-dirty  (update) proceed despite uncommitted tracked changes
  --skip-runtime (update) skip the pi/hermes/herdr/npm/firstmate refresh
  --help         show this help

Environment (all optional):
  SETUP_YES=1      auto-confirm the final yes/no (testing/scripts)
  SETUP_ENV_FILE   where to write the env file
                   (default ~/.config/dotfiles/env)
  SETUP_OS_ID      pretend /etc/os-release ID is this value, e.g. nixos
                   (test hook - normally read from /etc/os-release)
  SETUP_ROLE       force the host role, same as --role
  SETUP_SOURCE     repo source: 1=Gitea, 2=GitHub, 3=local checkout
                   (skips the source prompt)
  SETUP_USERNAME   machine username (skips the username prompt)
  SETUP_USER_EMAIL git identity email (skips the email prompt)
  SETUP_WINDOWS_USER  Windows account name for the wsl role (skips
                   auto-detection of C:\Users\<user>)
  SETUP_SYSTEM     force the Nix system (x86_64-linux|aarch64-linux);
                   normally auto-detected from uname -m
EOF
  exit 1
}

log()  { printf '\n== %s ==\n' "$*"; }
info() { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# retry <cmd...>: retry a command up to 3 times with a short backoff, for
# network calls that can transiently fail early after a fresh boot (e.g. a
# WSL2 VM's network/DNS taking a few seconds to stabilize). Prints a warning
# between attempts; the final failure still propagates normally.
retry() {
  local attempts=3 delay=5 n=1
  until "$@"; do
    if [ "$n" -ge "$attempts" ]; then
      return 1
    fi
    warn "command failed (attempt $n/$attempts) - retrying in ${delay}s: $*"
    sleep "$delay"
    n=$((n + 1))
  done
}

DRY_RUN=0
MODE=install
MODE_EXPLICIT=0
ROLE=""
BUMP=0
ALLOW_DIRTY=0
SKIP_RUNTIME=0
while [ "$#" -gt 0 ]; do
  arg="$1"
  case "$arg" in
    --dry-run | --check) DRY_RUN=1 ;;
    --bump) BUMP=1 ;;
    --allow-dirty) ALLOW_DIRTY=1 ;;
    --skip-runtime) SKIP_RUNTIME=1 ;;
    --role)
      shift
      [ "$#" -ge 1 ] || die "option --role needs a value (laptop|server|wsl|hermes)"
      ROLE="$1"
      ;;
    --role=*) ROLE="${arg#--role=}" ;;
    --help | -h) usage ;;
    -*)
      echo "error: unknown option: $arg" >&2
      usage
      ;;
    install | update)
      if [ "$MODE_EXPLICIT" -eq 1 ] && [ "$MODE" != "$arg" ]; then
        die "only one mode may be given ('$MODE' and '$arg')"
      fi
      MODE="$arg"
      MODE_EXPLICIT=1
      ;;
    *)
      if [ -n "$ROLE" ]; then
        echo "error: only one role may be given ('$ROLE' and '$arg')" >&2
        usage
      fi
      ROLE="$arg"
      ;;
  esac
  shift
done
[ -z "$ROLE" ] && [ -n "${SETUP_ROLE:-}" ] && ROLE="$SETUP_ROLE"
if [ -n "$ROLE" ]; then
  case "$ROLE" in
    laptop | server | wsl | hermes) : ;;
    *) die "invalid role '$ROLE' - valid roles: laptop, server, wsl, hermes" ;;
  esac
fi
# The update-only flags are meaningless (and a sign of a typo) on install.
if [ "$MODE" != update ]; then
  if [ "$BUMP" -eq 1 ] || [ "$ALLOW_DIRTY" -eq 1 ] || [ "$SKIP_RUNTIME" -eq 1 ]; then
    die "--bump, --allow-dirty and --skip-runtime only apply to 'setup.sh update'"
  fi
fi

# Repo root is this script's directory (setup.sh lives at the flake root).
# When piped via `curl | bash -s`, BASH_SOURCE[0] is unset - fall back to the
# current directory (REPO is only used to guess a local-checkout default).
REPO="$(cd "$(dirname "${BASH_SOURCE[0]:-}")" && pwd)"
# Per-machine env file location (override for testing).
ENV_FILE="${SETUP_ENV_FILE:-$HOME/.config/dotfiles/env}"
# Persistent corporate CA bundle assembled for this script's own fetches (see
# the "Bootstrap" section below) - lives next to $ENV_FILE, not under /tmp:
# mktemp's default TMPDIR is /tmp, and a sandboxed nix build gets its own
# private, empty /tmp, so a /tmp path is not a reliable place to put a file
# that anything sandbox-adjacent needs to see. Overwritten fresh on every run.
CA_BUNDLE_FILE="${SETUP_CA_BUNDLE_FILE:-$HOME/.config/dotfiles/bootstrap-ca.crt}"
# Sibling `dotfiles` repo, which owns the actual chezmoi source state (gated
# by its own .chezmoiroot) - NOT this repo's own ~/.nix-config checkout.
# Applied via chezmoi's own init+apply --purge (see the "chezmoi" step
# below), which clones, applies, and purges its own source directory in a
# single command - no persistent local checkout is left on the host.
DOTFILES_REPO_URL="https://github.com/babbarc/dotfiles.git"
# The `hermes` role targets `homeConfigurations.hermes`, a standalone profile
# that fixes home.username = "hermes" and home.homeDirectory = /home/hermes
# (hosts/hermes/home.nix). Standalone home-manager activates a profile as the
# invoking user and writes that user's home, so this role can only be applied
# by this account - see the guard in the environment section below.
HERMES_PROFILE_USER="hermes"
# Resolved by `update` (and by verify when running from a checkout); empty on
# an install that fetched a tarball.
CHECKOUT=""
# Flake ref recorded by set_role_plan - the only thing build_and_activate logs
# from, so neither lifecycle can read a variable the other one never set.
PLAN_FLAKE=""

# ask <prompt> <default>: prints the prompt (with "[default]: " when a
# default exists) on stderr and echoes the answer on stdout. Empty input takes
# the default; with no default, empty input echoes empty (the caller decides
# whether that means skip or re-prompt). Prompts go to stderr so the answer can
# be captured with $(ask ...).
ask() {
  local prompt="$1" default="$2" answer
  if [ -n "$default" ]; then
    printf '%s [%s]: ' "$prompt" "$default" >&2
  else
    printf '%s: ' "$prompt" >&2
  fi
  IFS= read -r answer || answer=""
  printf '%s\n' "${answer:-$default}"
}

# ask_skip <prompt> <default>: like ask, but 'skip' or '-' echoes nothing so
# the caller can omit a machine-specific key entirely. With an empty default,
# pressing Enter also omits it (the caller warns) - a fresh machine never
# silently gets a made-up value.
ask_skip() {
  local prompt="$1" default="$2" answer
  if [ -n "$default" ]; then
    printf '%s [%s]: ' "$prompt" "$default" >&2
  else
    printf '%s: ' "$prompt" >&2
  fi
  IFS= read -r answer || answer=""
  case "$answer" in
    skip | SKIP | -) printf '\n' ;;
    *) printf '%s\n' "${answer:-$default}" ;;
  esac
}

confirm() {
  local answer
  if [ "${SETUP_YES:-0}" = 1 ]; then
    printf 'proceeding (SETUP_YES=1)\n'
    return 0
  fi
  printf '%s [y/N]: ' "$1" >&2
  IFS= read -r answer || answer="n"
  case "$answer" in
    [yY] | [yY][eE][sS]) return 0 ;;
    *) return 1 ;;
  esac
}

# --- shared lifecycle helpers ---------------------------------------------------
# Install and update run the same converging phases (design report sections
# 4.2/4.3). These are the single implementations of each phase; the two
# lifecycles only differ in the install-shaped steps they add or skip.

# The target user of the machine (the env file's DOTFILES_USERNAME). setup.sh
# may be invoked by a different (image/bootstrap) user before that account
# exists, so every user-specific step (env placement, chezmoi, password store,
# runtime refresh) runs as this user; the build and switch stay as the invoking
# user because they are root/system operations.
ENV_USERNAME="${USER:-$(id -un)}"
TARGET_HOME="$HOME"

run_as_target() {
  if [ "$(id -un)" = "$ENV_USERNAME" ]; then
    "$@"
  else
    sudo -u "$ENV_USERNAME" -H env NIX_CONFIG="${NIX_CONFIG:-}" "$@"
  fi
}

# repo_present_at <dir>: non-empty dir that looks like this repo.
repo_present_at() {
  [ -f "$1/flake.nix" ] && [ -f "$1/env.example" ]
}

# is_git_checkout <dir>: true for a normal clone AND a linked worktree (where
# .git is a file, not a directory).
is_git_checkout() {
  git -C "$1" rev-parse --git-dir >/dev/null 2>&1
}

# DEF holds the existing env file's values (later lines win), used as install
# prompt defaults and read directly by update/verify.
declare -A DEF=()
load_env() {
  local line key
  ENV_EXISTED=0
  if [ -f "$ENV_FILE" ]; then
    ENV_EXISTED=1
    while IFS= read -r line; do
      line="${line%$'\r'}"
      case "$line" in
        '' | '#'*) continue ;;
      esac
      key="${line%%=*}"
      DEF["$key"]="${line#*=}"
    done < "$ENV_FILE"
  fi
}

# set_role_plan <flake-ref>: fill PLAN_FLAKE, ATTR, BUILD_CMD, ACTIVATE,
# HOST_LABEL and SET_SYSTEM_PROFILE for $ROLE. `flake-ref` is what nix is
# pointed at (a tarball URL or path:<checkout> - install picks it from the
# repo source, update from its resolved checkout) and is recorded HERE, not in
# the install path, so the shared build_and_activate logs the same ref on both
# lifecycles. `local flake` is still used below for the hermes activation.
set_role_plan() {
  local flake="$1"
  PLAN_FLAKE="$flake"
  SET_SYSTEM_PROFILE=0
  ATTR=""
  BUILD_CMD=()
  case "$ROLE" in
    laptop)
      ATTR="homeConfigurations.laptop.activationPackage"
      ACTIVATE=(env HOME_MANAGER_BACKUP_EXT=backup ./result/activate)
      HOST_LABEL="home-manager profile (homeConfigurations.laptop)"
      ;;
    server)
      ATTR="homeConfigurations.server.activationPackage"
      ACTIVATE=(env HOME_MANAGER_BACKUP_EXT=backup ./result/activate)
      HOST_LABEL="home-manager profile (homeConfigurations.server)"
      ;;
    wsl)
      if [ "$IS_NIXOS" -eq 1 ]; then
        ATTR="nixosConfigurations.wsl.config.system.build.toplevel"
        # switch-to-configuration alone activates the new system for the
        # CURRENT session only - nixos-rebuild's other half (setting
        # /nix/var/nix/profiles/system, which NixOS-WSL's systemd shim boots)
        # is skipped when calling it directly, so without this the next boot
        # reverts to the previous generation. Mirror nixos-rebuild-ng's two
        # steps: set_profile, then switch_to_configuration.
        SET_SYSTEM_PROFILE=1
        ACTIVATE=(sudo ./result/bin/switch-to-configuration switch)
        HOST_LABEL="NixOS-WSL system (nixosConfigurations.wsl)"
      else
        ATTR="homeConfigurations.server.activationPackage"
        ACTIVATE=(env HOME_MANAGER_BACKUP_EXT=backup ./result/activate)
        HOST_LABEL="portable home-manager profile (homeConfigurations.server)"
      fi
      ;;
    hermes)
      # Standalone home-manager activated by the home-manager CLI itself - no
      # ./result profile step. `-b hm-bak` is required on the first activation
      # because the joy-stack .container files already exist as plain files.
      # The environment-section guard already refused any invoking user other
      # than HERMES_PROFILE_USER, so this always applies /home/hermes as its
      # own account.
      ACTIVATE=(nix run home-manager -- switch -b hm-bak --flake "$flake#hermes")
      HOST_LABEL="home-manager profile for the $HERMES_PROFILE_USER account (homeConfigurations.hermes)"
      ;;
  esac

  if [ "$ROLE" != hermes ]; then
    BUILD_CMD=(nix build "$flake#$ATTR" --override-input dotfiles-env "path:$ENV_FILE")
    # DOTFILES_CORPORATE_CA_DIR points at an arbitrary on-disk path outside the
    # flake's inputs; flakes evaluate in pure mode by default, which forbids
    # importing such a path into the store, so --impure is required only when
    # that key is actually set (confirmed by hand: a plain path string in
    # security.pki.certificateFiles fails in the sandboxed cacert build with
    # "No such file or directory" since the sandbox has no access to it, and
    # even after converting it to a real Nix path so it's imported into the
    # store at eval time, pure eval itself then refuses with "access to
    # absolute path ... is forbidden in pure evaluation mode" - only --impure
    # resolves both).
    if [ "$ROLE" = wsl ] && [ -n "${DOTFILES_CORPORATE_CA_DIR:-}" ]; then
      BUILD_CMD+=(--impure)
    fi
  fi
}

# assemble_ca_bundle: on a corporate network, DOTFILES_CORPORATE_CA_DIR's
# declarative security.pki.certificateFiles wiring
# (hosts/wsl/configuration.nix) only takes effect on the ACTIVATED system - it
# cannot help this script's own network calls (nix-prefetch-url/git clone in
# fetch_repo, the nix build itself fetching flake inputs, and on update the
# git pull/nix flake update), because the system generation that would set it
# hasn't built yet. So before any of that, build a CA bundle for this script's
# own fetches (system default bundle + every file in the given directory) at a
# persistent path under $HOME (not mktemp's /tmp - a sandboxed nix build gets
# its own private, empty /tmp, so a /tmp path is not reliably visible where it
# might be needed) and export it via the env vars Nix/git/curl actually honor.
# Regenerated (overwritten, not appended) on every run rather than trying to
# detect staleness; left in place afterwards since it's a plain, inspectable,
# non-secret CA bundle - a missing/unset directory changes nothing.
assemble_ca_bundle() {
  local base f
  mkdir -p "$(dirname "$CA_BUNDLE_FILE")"
  : > "$CA_BUNDLE_FILE"
  for base in /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-bundle.crt /etc/pki/tls/certs/ca-bundle.crt; do
    if [ -f "$base" ]; then
      cat "$base" >> "$CA_BUNDLE_FILE"
      break
    fi
  done
  if [ -d "$DOTFILES_CORPORATE_CA_DIR" ]; then
    for f in "$DOTFILES_CORPORATE_CA_DIR"/*; do
      [ -f "$f" ] && cat "$f" >> "$CA_BUNDLE_FILE"
    done
  else
    warn "DOTFILES_CORPORATE_CA_DIR ($DOTFILES_CORPORATE_CA_DIR) does not exist - proceeding with only the system default CA bundle, if any"
  fi
  export NIX_SSL_CERT_FILE="$CA_BUNDLE_FILE"
  export SSL_CERT_FILE="$CA_BUNDLE_FILE"
  export GIT_SSL_CAINFO="$CA_BUNDLE_FILE"
  info "corporate CA bundle assembled at $CA_BUNDLE_FILE for this run's own fetches (NIX_SSL_CERT_FILE/SSL_CERT_FILE/GIT_SSL_CAINFO)"
  # NIX_SSL_CERT_FILE/SSL_CERT_FILE cover fetches this script's own process
  # makes directly (nix-prefetch-url, git clone/pull, and flake-input
  # evaluation inside `nix build`). They do NOT reach a multi-user nix-daemon's
  # own fetches (substituter/binary-cache downloads, and fixed-output-derivation
  # builds) - confirmed by hand against this repo's own nix (2.35.2): the
  # daemon resolves its ssl-cert-file setting from ITS OWN process
  # environment (the systemd service's, not the connecting client's), and a
  # client-side env var never even reaches the client/daemon settings
  # handshake. Passing --option ssl-cert-file explicitly on the build command
  # DOES reach the daemon and takes effect - but ONLY if this account is in
  # nix.settings.trusted-users (NixOS default: root only); otherwise the daemon
  # logs "ignoring the client-specified setting 'ssl-cert-file' ... you are not
  # a trusted user" and keeps using its own default.
  #
  # hosts/wsl/configuration.nix now declares this login user as a trusted user
  # (see its nix.settings.trusted-users comment for the security tradeoff), so
  # this stops being a problem from the SECOND activation onward. It cannot help
  # the very first run on a fresh corporate-network machine, though: that
  # declarative setting only takes effect once a generation built with it has
  # been activated, and this script's own process is what builds/activates that
  # first generation - chicken-and-egg. For that one-time first run, invoke this
  # script with `sudo` (root is trusted by default) if package/binary-cache
  # downloads during the build below hit SSL errors.
  BUILD_CMD+=(--option ssl-cert-file "$CA_BUNDLE_FILE")
}

# build_and_activate: the one build + activation implementation, used by install
# and update alike. For `hermes` BUILD_CMD is empty (nix run builds + activates
# in one step) and only the activation command runs.
build_and_activate() {
  # Build + activation run from $HOME so ./result lands somewhere sensible
  # regardless of where the script was invoked from.
  cd "$HOME"
  if [ "${#BUILD_CMD[@]}" -gt 0 ]; then
    log "Build"
    info "building $HOST_LABEL from $PLAN_FLAKE"
    info "  (first run downloads nixpkgs + home-manager - a few hundred MB and a few minutes; later runs are fast)"
    info "running: ${BUILD_CMD[*]}"
    retry "${BUILD_CMD[@]}"
  fi

  log "Activate"
  if [ "${SET_SYSTEM_PROFILE:-0}" -eq 1 ]; then
    # Point the boot profile at the freshly built toplevel BEFORE activating:
    # switch-to-configuration switches /run/current-system and /etc for this
    # session, but NixOS-WSL's systemd shim boots /nix/var/nix/profiles/system
    # on the next start - without this the new generation never becomes
    # boot-default and every reboot reverts to the previous one.
    local -a PROFILE_SET
    PROFILE_SET=(sudo nix-env --profile /nix/var/nix/profiles/system --set "$(readlink -f ./result)")
    info "running: ${PROFILE_SET[*]}"
    retry "${PROFILE_SET[@]}"
  fi
  info "running: ${ACTIVATE[*]}"
  "${ACTIVATE[@]}"
}

# apply_chezmoi: apply the sibling dotfiles repo, identical in install and
# update. --force + --no-tty make `apply` unattended-safe: chezmoi's default
# behavior on a target that drifted since it last wrote it (e.g. herdr
# rewriting its own ~/.config/herdr/config.toml at runtime) is to prompt
# diff/overwrite/all-overwrite/skip/quit, which with no TTY just fails
# ("chezmoi: .testfile: EOF") instead of applying - confirmed by hand against
# this repo's pinned chezmoi (2.72.0). --force is chezmoi's own documented
# escape hatch ("Make all changes without prompting"): it always overwrites
# the drifted file with the source's target state, never skips or excludes it,
# per the captain's explicit call on this.
# Tooling is provided from nixpkgs via `nix shell`: fresh NixOS-WSL images carry
# no system git/jq/curl, and the dotfiles repo's own chezmoi scripts need them -
# chezmoi needs git for the initial clone plus the repo's .chezmoiexternal.toml
# git-repo externals, modify_settings.json calls jq, and
# run_once_install-fisher.sh calls curl. So this step must not depend on a
# preinstalled toolset. (All four closures are already in the store once the
# system above has been built, so the shell resolves instantly.)
# --purge (not --one-shot): one-shot also deletes the chezmoi BINARY after the
# run (init --one-shot implies purge + purge-binary), which fails from the
# read-only nix store with 'unlinkat ...: read-only file system'. --purge keeps
# the no-trace behavior (source dir, config, cache, state) without touching the
# binary.
apply_chezmoi() {
  log "chezmoi"
  info "running chezmoi init+apply from $DOTFILES_REPO_URL"
  if run_as_target nix shell nixpkgs#git nixpkgs#jq nixpkgs#curl nixpkgs#chezmoi -c chezmoi init "$DOTFILES_REPO_URL" --apply --force --no-tty --purge; then
    info "chezmoi apply complete"
  else
    warn "chezmoi init --apply --purge failed - nix activation above still succeeded. Retry with:"
    warn "  nix shell nixpkgs#git nixpkgs#jq nixpkgs#curl nixpkgs#chezmoi -c chezmoi init $DOTFILES_REPO_URL --apply --force --no-tty --purge"
  fi
}

# run_refresh <label> <cmd...>: warn-not-die wrapper for one runtime refresh.
run_refresh() {
  local label="$1"
  shift
  info "running: $*"
  if "$@"; then
    info "$label: refreshed"
  else
    warn "$label: refresh failed - continuing (retry later: $*)"
  fi
}

# refresh_runtimes: update-only. Every step is guarded (skip cleanly when the
# tool or clone is absent) and warn-not-die - the machine is already built,
# activated and re-applied by this point.
refresh_runtimes() {
  log "Refresh runtimes"
  # pi: prefer the managed install's launcher; `pi update --all` updates pi
  # itself plus every installed extension (pi rejects --self combined with
  # --all, so --all is the complete form).
  if [ -x "$HOME/.local/bin/pi" ]; then
    run_refresh "pi" "$HOME/.local/bin/pi" update --all
  elif command -v pi >/dev/null 2>&1; then
    run_refresh "pi" pi update --all
  else
    info "pi: not installed - skipping (install creates it via piInstall)"
  fi

  # hermes: --yes keeps the update non-interactive (config migration, stash
  # restore). It only exists on hosts whose profile installs the engine.
  if command -v hermes >/dev/null 2>&1; then
    run_refresh "hermes" hermes update --yes
  else
    info "hermes: not installed on this role - skipping"
  fi

  if command -v herdr >/dev/null 2>&1; then
    run_refresh "herdr" herdr update
  else
    info "herdr: not installed - skipping (install creates it via herdrInstall)"
  fi

  # npm axi suite: only the packages agent-cli-tools.nix already installed
  # under ~/.local, so a host that never ran that activation is left alone.
  if command -v npm >/dev/null 2>&1; then
    local -a axi_tools=()
    local t
    for t in gh-axi chrome-devtools-axi lavish-axi tasks-axi quota-axi gnhf; do
      if [ -d "$HOME/.local/lib/node_modules/$t" ]; then
        axi_tools+=("$t")
      fi
    done
    if [ "${#axi_tools[@]}" -gt 0 ]; then
      run_refresh "axi suite" npm update --prefix "$HOME/.local" -g "${axi_tools[@]}"
    else
      info "npm axi suite: not installed - skipping"
    fi
  else
    info "npm: not on PATH - skipping the axi suite"
  fi

  # firstmate fast-forwards tracked files only (never data/state/config/
  # projects) - see ~/firstmate/bin/fm-update.sh.
  if is_git_checkout "$HOME/firstmate" && [ -f "$HOME/firstmate/bin/fm-update.sh" ]; then
    run_refresh "firstmate" bash "$HOME/firstmate/bin/fm-update.sh"
  elif [ -d "$HOME/firstmate" ]; then
    warn "firstmate: $HOME/firstmate exists but is not a git clone - skipping (move it aside and re-run install)"
  else
    info "firstmate: not cloned - skipping (install clones it via firstmateClone)"
  fi
}

# pi_managed_install_ok <resolved-path>: true only for the two layouts the
# official pi installer writes and modules/dev/pi.nix's pi_managed_install_ok()
# accepts (the install-time guard and the single source of truth this mirrors -
# keep the two in lockstep):
#   - entry point -> ~/.pi/agent/install/releases/<version> (a release build,
#     resolved directly), or
#   - entry point -> ~/.pi/agent/bin/pi (the launcher), whose
#     install/current-version names a release that really contains an
#     executable node_modules/.bin/pi.
pi_managed_install_ok() {
  local real="${1:-}" v
  case "$real" in
    "$HOME"/.pi/agent/install/releases/*)
      [ -x "$real" ]
      ;;
    "$HOME"/.pi/agent/bin/pi)
      [ -r "$HOME/.pi/agent/install/current-version" ] || return 1
      IFS= read -r v < "$HOME/.pi/agent/install/current-version" || return 1
      case "$v" in
        "" | . | .. | *[!0-9A-Za-z._+-]*) return 1 ;;
      esac
      [ -x "$HOME/.pi/agent/install/releases/$v/node_modules/.bin/pi" ]
      ;;
    *)
      return 1
      ;;
  esac
}

# verify_readiness: shared by install and update. Reports pass/fail per item,
# each FAIL naming the one command that fixes it. It never fails the run.
verify_readiness() {
  log "Verify"
  local failures=0
  vpass() { printf '  PASS  %s\n' "$*"; }
  vfail() {
    printf '  FAIL  %s\n' "$*"
    failures=$((failures + 1))
  }
  vskip() { printf '  SKIP  %s\n' "$*"; }

  # Checkout drift: the property that (silently) failed for 66 days.
  local co="$CHECKOUT"
  if [ -z "$co" ] && repo_present_at "$HOME/.nix-config" && is_git_checkout "$HOME/.nix-config"; then
    co="$HOME/.nix-config"
  fi
  if [ -z "$co" ] && repo_present_at "$REPO" && is_git_checkout "$REPO"; then
    co="$REPO"
  fi
  if [ "$HAS_GIT" -eq 0 ]; then
    vskip "checkout: git is not on PATH - cannot inspect drift"
  elif [ -z "$co" ]; then
    vskip "checkout: no git checkout found (~/.nix-config is a tarball or absent)"
  elif ! git -C "$co" rev-parse --short HEAD >/dev/null 2>&1; then
    vfail "checkout: $co is not a readable git checkout (fix: git -C $co status)"
  else
    local head upstream behind ahead
    head="$(git -C "$co" rev-parse --short HEAD)"
    upstream="$(git -C "$co" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
    if [ -z "$upstream" ]; then
      vfail "checkout: $co has no upstream (fix: git -C $co branch --set-upstream-to=origin/master)"
    else
      behind="$(git -C "$co" rev-list --count "HEAD..$upstream" 2>/dev/null || echo '?')"
      ahead="$(git -C "$co" rev-list --count "$upstream..HEAD" 2>/dev/null || echo '?')"
      if [ "$behind" = 0 ] && [ "$ahead" = 0 ]; then
        vpass "checkout: $co at $head, level with $upstream"
      else
        vfail "checkout: $co is $behind behind / $ahead ahead of $upstream (fix: $co/setup.sh update)"
      fi
    fi
  fi

  if [ "$ROLE" = hermes ]; then
    # The joy-host profile deliberately carries none of the dev tooling.
    vskip "pi/firstmate/gh/gpg/pass: not part of the hermes profile"
  else
    # pi must be the managed (self-updating) install, never the old nix-store
    # binary - the exact drift this entry point exists to prevent. The two
    # accepted layouts live in pi_managed_install_ok() above and mirror the
    # install-time guard of the same name in modules/dev/pi.nix.
    local pi_link="$HOME/.local/bin/pi" pi_real="" pi_path="" pi_resolved=""
    [ -e "$pi_link" ] && pi_real="$(readlink -f "$pi_link" 2>/dev/null || true)"
    pi_path="$(command -v pi 2>/dev/null || true)"
    [ -n "$pi_path" ] && pi_resolved="$(readlink -f "$pi_path" 2>/dev/null || true)"
    if pi_managed_install_ok "$pi_real"; then
      vpass "pi: $pi_link -> managed install ($pi_real)"
    elif pi_managed_install_ok "$pi_resolved"; then
      vpass "pi: $pi_path -> managed install ($pi_resolved)"
    else
      local store_path=""
      case "$pi_real" in /nix/store/*) store_path="$pi_real" ;; esac
      case "$pi_resolved" in /nix/store/*) store_path="$pi_resolved" ;; esac
      if [ -n "$store_path" ]; then
        vfail "pi: resolves into the nix store ($store_path) - the managed install never ran (fix: run ./setup.sh (install) to re-run piInstall, then open a new shell)"
      elif [ -L "$pi_link" ] && [ ! -e "$pi_link" ]; then
        vfail "pi: $pi_link is a dangling symlink, not a managed install (fix: run ./setup.sh (install) to re-run piInstall)"
      elif [ -f "$pi_link" ] && [ ! -L "$pi_link" ]; then
        vfail "pi: $pi_link is a plain file, not a managed install (fix: run ./setup.sh (install) to re-run piInstall)"
      elif [ ! -e "$pi_link" ] && [ ! -L "$pi_link" ]; then
        vfail "pi: not installed (fix: run ./setup.sh (install) - piInstall bootstraps it)"
      else
        vfail "pi: $pi_link is not a managed install (fix: run ./setup.sh (install) to re-run piInstall)"
      fi
    fi

    local fm="$HOME/firstmate" fm_remote=""
    if [ ! -d "$fm" ]; then
      vfail "firstmate: not cloned (fix: run ./setup.sh (install) - firstmateClone bootstraps it)"
    elif [ ! -e "$fm/.git" ]; then
      vfail "firstmate: $fm exists but is not a git clone (fix: move it aside and re-run ./setup.sh (install))"
    elif [ "$HAS_GIT" -eq 0 ]; then
      vpass "firstmate: $fm/.git present (git not on PATH - remote not checked)"
    else
      fm_remote="$(git -C "$fm" remote get-url origin 2>/dev/null || true)"
      case "$fm_remote" in
        *babbarc/firstmate*) vpass "firstmate: $fm (origin $fm_remote)" ;;
        '')
          vfail "firstmate: $fm/.git has no origin (fix: git -C $fm remote add origin https://github.com/babbarc/firstmate.git)"
          ;;
        *)
          vfail "firstmate: origin is $fm_remote, expected babbarc/firstmate (fix: git -C $fm remote set-url origin https://github.com/babbarc/firstmate.git)"
          ;;
      esac
    fi

    if ! command -v gh >/dev/null 2>&1; then
      vfail "gh: not on PATH (fix: run ./setup.sh (install))"
    elif gh auth status >/dev/null 2>&1; then
      vpass "gh: authenticated"
    else
      vfail "gh: not authenticated (fix: gh auth login)"
    fi

    local gpg_out
    if command -v gpg >/dev/null 2>&1 && gpg_out="$(gpg --list-secret-keys 2>/dev/null)" && printf '%s\n' "$gpg_out" | grep -q '^sec'; then
      vpass "gpg: secret key present"
    else
      vfail "gpg: no secret key for this user (fix: gpg --import <captain-key>; see README 'Deploying to a new machine' step 4)"
    fi

    if [ -e "$TARGET_HOME/.password-store" ]; then
      vpass "pass: $TARGET_HOME/.password-store present"
    else
      vfail "pass: $TARGET_HOME/.password-store missing (fix: git clone <pass-remote> $TARGET_HOME/.password-store)"
    fi
  fi

  # Hermes engine + curated home: only the roles whose profile installs it.
  local hermes_target=""
  if command -v hermes >/dev/null 2>&1; then
    hermes_target="$(readlink -f "$(command -v hermes)" 2>/dev/null || true)"
  fi
  case "$ROLE" in
    wsl | hermes)
      if [ -z "$hermes_target" ]; then
        vfail "hermes: not installed (fix: run ./setup.sh update - hermesAgentInstall installs the pinned engine)"
      else
        case "$hermes_target" in
          */.local/share/hermes-agent/*) vpass "hermes: $hermes_target (pinned venv)" ;;
          *)
            vfail "hermes: $hermes_target is not the pinned venv (fix: run ./setup.sh update to re-run hermesAgentInstall)"
            ;;
        esac
        local hermes_version=""
        if hermes_version="$(hermes --version 2>/dev/null | head -n 1)" && [ -n "$hermes_version" ]; then
          vpass "hermes --version: $hermes_version"
        else
          vfail "hermes --version failed (fix: cd ~/.local/share/hermes-agent && uv sync --extra all --locked --python 3.11)"
        fi

        local skills_out="" missing_skills="" s
        if skills_out="$(hermes skills list 2>/dev/null)"; then
          for s in axi-authoring browse delegated-task operate-desktop pass-access recover-blocked-page web-login; do
            if ! printf '%s\n' "$skills_out" | sed 's/\xe2\x94\x82/|/g' | awk -F'|' -v name="$s" '$2 ~ " " name " " && $6 ~ /enabled/ { found = 1 } END { exit !found }'; then
              missing_skills="$missing_skills $s"
            fi
          done
          if [ -z "$missing_skills" ]; then
            vpass "hermes skills: all curated skills installed and enabled"
          else
            vfail "hermes skills: missing/disabled:$missing_skills (fix: run ./setup.sh update to re-link ~/.hermes/skills)"
          fi
        else
          vfail "hermes skills list failed (fix: hermes skills list)"
        fi

        local plugins_out="" missing_plugins="" p
        if plugins_out="$(hermes plugins list 2>/dev/null)"; then
          for p in guardrails pass-enforcement; do
            if ! printf '%s\n' "$plugins_out" | sed 's/\xe2\x94\x82/|/g' | awk -F'|' -v name="$p" '$2 ~ " " name " " && $3 ~ /^ *enabled *$/ { found = 1 } END { exit !found }'; then
              missing_plugins="$missing_plugins $p"
            fi
          done
          if [ -z "$missing_plugins" ]; then
            vpass "hermes plugins: guardrails + pass-enforcement enabled"
          else
            vfail "hermes plugins: not enabled:$missing_plugins (fix: hermes plugins enable <name>; or run hermes-expert-new --sync-plugins)"
          fi
        else
          vfail "hermes plugins list failed (fix: hermes plugins list)"
        fi

        if command -v hermes-guardrails >/dev/null 2>&1; then
          if hermes-guardrails show >/dev/null 2>&1; then
            vpass "hermes guardrails: tunables readable"
          else
            vfail "hermes guardrails: 'hermes-guardrails show' failed (fix: run ./setup.sh update - hermes-guardrails.nix writes ~/.hermes/guardrails.yaml)"
          fi
        else
          vskip "hermes guardrails: hermes-guardrails CLI not installed on this host"
        fi
      fi
      ;;
    *) vskip "hermes engine: not installed on role $ROLE" ;;
  esac

  # systemd user units: the host's long-running Hermes services.
  local -a units=()
  local u
  case "$ROLE" in
    wsl) units=(hermes-gateway browser-proxy-windows) ;;
    hermes) units=(hermes-gateway hermes-qmd hermes-vision-bridge hermes-baileys-watch hermes-browser-proxy hermes browser-proxy qmd) ;;
  esac
  if [ "${#units[@]}" -eq 0 ]; then
    vskip "systemd --user units: none declared for role $ROLE"
  elif ! command -v systemctl >/dev/null 2>&1; then
    vskip "systemd --user units: systemctl not available"
  else
    local found_units=0
    for u in "${units[@]}"; do
      if ! systemctl --user cat "$u.service" >/dev/null 2>&1; then
        continue
      fi
      found_units=$((found_units + 1))
      if systemctl --user is-active --quiet "$u.service" 2>/dev/null; then
        vpass "unit: $u.service is active"
      else
        vfail "unit: $u.service is not active (fix: systemctl --user start $u.service; see journalctl --user -u $u.service)"
      fi
    done
    if [ "$found_units" -eq 0 ]; then
      vfail "systemd --user units: no Hermes unit installed for role $ROLE (fix: run ./setup.sh update)"
    fi
  fi

  # Per-role env keys: the D5 class of drift (a role key silently missing).
  if [ "$ROLE" = hermes ]; then
    vskip "env: role hermes reads no ~/.config/dotfiles/env"
  else
    load_env
    local -a required=(DOTFILES_USERNAME DOTFILES_USER_EMAIL DOTFILES_HOST_ROLE DOTFILES_SYSTEM)
    case "$ROLE" in
      laptop) required+=(DOTFILES_SERVER_HOST DOTFILES_SERVER_USER) ;;
      wsl) required+=(DOTFILES_WINDOWS_USER) ;;
    esac
    local missing_env="" key
    for key in "${required[@]}"; do
      if [ -z "${DEF[$key]:-}" ]; then
        missing_env="$missing_env $key"
      fi
    done
    if [ -z "$missing_env" ]; then
      vpass "env: $ENV_FILE has all $ROLE keys"
    else
      vfail "env: $ENV_FILE is missing:$missing_env (fix: run ./setup.sh --role $ROLE and provide them - install is the only path that writes it)"
    fi
    local env_role="${DEF[DOTFILES_HOST_ROLE]:-}"
    if [ -n "$env_role" ] && [ "$env_role" != "$ROLE" ]; then
      vfail "env: DOTFILES_HOST_ROLE=$env_role but this is a $ROLE run (fix: run ./setup.sh --role $ROLE)"
    fi
  fi

  echo
  if [ "$failures" -eq 0 ]; then
    info "verify: all checks passed"
  else
    info "verify: $failures check(s) failed - each FAIL line names the command that fixes it"
  fi
}

# update_main: non-interactive pull + rebuild + re-apply + refresh + verify.
# Never prompts (a sudo that would prompt is refused before activation) and
# never writes ~/.config/dotfiles/env.
update_main() {
  log "Update"
  [ "$HAS_GIT" -eq 1 ] || die "update needs git on PATH (it pulls the checkout) - install git and re-run"

  # Checkout: the checkout this script runs from, else the standard install
  # target. Update only ever pulls an existing checkout; it never clones.
  # The `hermes` role additionally requires the checkout to be the hermes
  # user's own (under its home), so update never runs inside another user's
  # checkout - the environment guard already established we ARE that user.
  if repo_present_at "$REPO" && is_git_checkout "$REPO"; then
    CHECKOUT="$REPO"
  elif repo_present_at "$HOME/.nix-config" && is_git_checkout "$HOME/.nix-config"; then
    CHECKOUT="$HOME/.nix-config"
  else
    if [ "$ROLE" = hermes ]; then
      die "role hermes needs the $HERMES_PROFILE_USER user's own checkout (looked at '$REPO' and '$HOME/.nix-config') - clone it as that user: git clone https://github.com/babbarc/nix-config.git $HOME/.nix-config"
    fi
    die "no nix-config git checkout found (looked at '$REPO' and '$HOME/.nix-config') - run update from a checkout, or install first (install clones it)"
  fi
  if [ "$ROLE" = hermes ]; then
    case "$CHECKOUT" in
      "$HOME"/*) : ;;
      *)
        die "role hermes must use the $HERMES_PROFILE_USER user's own checkout, but resolved '$CHECKOUT' (outside $HOME) - run '$HOME/.nix-config/setup.sh update --role hermes' instead"
        ;;
    esac
  fi
  info "checkout: $CHECKOUT"

  # Env file: install owns it; update only reads it, and refuses when it is
  # missing because that means install never ran on this machine.
  if [ "$ROLE" != hermes ]; then
    if [ ! -f "$ENV_FILE" ]; then
      die "no env file at $ENV_FILE - this machine has never run setup.sh (install); run './setup.sh' first (or pass --role hermes for the joy-host profile, which reads no env file)"
    fi
    load_env
    ENV_USERNAME="${DEF[DOTFILES_USERNAME]:-}"
    if [ -z "$ENV_USERNAME" ]; then
      die "$ENV_FILE has no DOTFILES_USERNAME - re-run ./setup.sh (install) to write it"
    fi
    if [ "$(id -un)" != "$ENV_USERNAME" ]; then
      die "$ENV_FILE belongs to '$ENV_USERNAME' but update is running as '$(id -un)'; update never prompts, so it cannot sudo - run it as $ENV_USERNAME"
    fi
    TARGET_HOME="$(getent passwd "$ENV_USERNAME" 2>/dev/null | cut -d: -f6 || true)"
    [ -n "$TARGET_HOME" ] || TARGET_HOME="$HOME"
    ENV_ROLE="${DEF[DOTFILES_HOST_ROLE]:-}"
    if [ -n "$ENV_ROLE" ] && [ "$ENV_ROLE" != "$ROLE" ]; then
      warn "$ENV_FILE says DOTFILES_HOST_ROLE=$ENV_ROLE but this update is for '$ROLE' - building the $ROLE profile as asked (only install rewrites the env file; verify reports the mismatch)"
    fi
    DOTFILES_CORPORATE_CA_DIR="${DEF[DOTFILES_CORPORATE_CA_DIR]:-}"
    info "env file: $ENV_FILE (read only - update never rewrites it)"
  else
    ENV_USERNAME="$(id -un)"
    TARGET_HOME="$HOME"
    info "role hermes: no env file, no chezmoi, no runtime refresh"
  fi

  set_role_plan "path:$CHECKOUT"

  # Only tracked modifications can change what a flake build sees, so only
  # those make the checkout "dirty" for this purpose.
  local dirty
  dirty="$(git -C "$CHECKOUT" status --porcelain --untracked-files=no || true)"
  if [ -n "$dirty" ] && [ "$ALLOW_DIRTY" -ne 1 ]; then
    printf '%s\n' "$dirty" >&2
    die "$CHECKOUT has uncommitted changes - commit or stash them, or pass --allow-dirty"
  fi

  export NIX_CONFIG="experimental-features = nix-command flakes"

  if [ "$DRY_RUN" -eq 1 ]; then
    echo
    echo "# dry-run - nothing will be pulled, written, built or activated."
    echo "# plan:"
    echo "#   mode:       update"
    echo "#   role:       $ROLE"
    echo "#   checkout:   $CHECKOUT"
    if [ "$ROLE" = hermes ]; then
      echo "#   env:        none (role hermes reads no env file)"
    else
      echo "#   env:        read $ENV_FILE (never written)"
    fi
    echo "#   host:       $HOST_LABEL"
    if [ "$ALLOW_DIRTY" -eq 1 ]; then
      echo "#   dirty:      allowed (--allow-dirty)"
    fi
    echo "# commands that WOULD run:"
    echo "  export NIX_CONFIG=\"experimental-features = nix-command flakes\""
    if [ "$ROLE" = wsl ] && [ -n "${DOTFILES_CORPORATE_CA_DIR:-}" ]; then
      echo "  cat <system default CA bundle> $DOTFILES_CORPORATE_CA_DIR/* > $CA_BUNDLE_FILE"
      echo "  export NIX_SSL_CERT_FILE=$CA_BUNDLE_FILE SSL_CERT_FILE=$CA_BUNDLE_FILE GIT_SSL_CAINFO=$CA_BUNDLE_FILE"
    fi
    echo "  retry git -C \"$CHECKOUT\" pull --ff-only"
    if [ "$BUMP" -eq 1 ]; then
      echo "  (cd \"$CHECKOUT\" && nix flake update)  # --bump"
    fi
    if [ "${#BUILD_CMD[@]}" -gt 0 ]; then
      echo "  retry ${BUILD_CMD[*]}"
    fi
    if [ "$SET_SYSTEM_PROFILE" -eq 1 ]; then
      echo "  retry sudo nix-env --profile /nix/var/nix/profiles/system --set \"\$(readlink -f ./result)\""
    fi
    echo "  ${ACTIVATE[*]}"
    if [ "$ROLE" = hermes ]; then
      echo "  # role hermes: no chezmoi apply (this profile must not touch the hermes user's dotfiles)"
      echo "  # role hermes: no runtime refresh"
    else
      echo "  retry nix shell nixpkgs#git nixpkgs#jq nixpkgs#curl nixpkgs#chezmoi -c chezmoi init \"$DOTFILES_REPO_URL\" --apply --force --no-tty --purge"
      if [ "$SKIP_RUNTIME" -eq 1 ]; then
        echo "  # runtime refresh skipped (--skip-runtime)"
      else
        echo "  $HOME/.local/bin/pi update --all            # when pi is installed"
        echo "  hermes update --yes                        # when hermes is installed"
        echo "  herdr update                               # when herdr is installed"
        echo "  npm update --prefix \"$HOME/.local\" -g <installed axi tools>"
        echo "  bash \"$HOME/firstmate/bin/fm-update.sh\"    # when ~/firstmate is a clone"
      fi
    fi
    echo "  # verify (read-only readiness report - never fails the run)"
    echo "# dry-run complete."
    return 0
  fi

  log "Pull"
  retry git -C "$CHECKOUT" pull --ff-only || die "git pull --ff-only failed in $CHECKOUT - it has local/diverged commits that can't fast-forward; resolve it by hand (git -C $CHECKOUT status) and re-run"
  info "checkout at $(git -C "$CHECKOUT" rev-parse --short HEAD)"
  if [ "$BUMP" -eq 1 ]; then
    log "Bump"
    info "running: nix flake update (in $CHECKOUT)"
    (cd "$CHECKOUT" && retry nix flake update) || die "nix flake update failed in $CHECKOUT"
  fi

  info "flakes enabled for this session (NIX_CONFIG; /etc/nix/nix.conf left untouched)"
  if [ "$ROLE" = wsl ] && [ -n "${DOTFILES_CORPORATE_CA_DIR:-}" ]; then
    assemble_ca_bundle
  fi

  if [ "${SET_SYSTEM_PROFILE:-0}" -eq 1 ] && ! sudo -n true 2>/dev/null; then
    die "update never prompts, but sudo would ask for a password here - run 'sudo -v' first (or allow NOPASSWD for this user) and re-run"
  fi

  build_and_activate

  if [ "$ROLE" = hermes ]; then
    log "chezmoi"
    info "skipped for role hermes - this profile must not touch the hermes user's dotfiles"
  else
    apply_chezmoi
    if [ "$SKIP_RUNTIME" -eq 0 ]; then
      refresh_runtimes
    else
      log "Refresh runtimes"
      info "skipped (--skip-runtime)"
    fi
  fi

  verify_readiness
}

# --- environment detection ----------------------------------------------------

log "Environment"

if [ -n "${SETUP_OS_ID:-}" ]; then
  OS_ID="$SETUP_OS_ID"
else
  OS_ID=""
  if [ -f /etc/os-release ]; then
    OS_ID="$(sed -n 's/^ID=//p' /etc/os-release | head -n 1)"
  fi
fi
IS_NIXOS=0
if [ "$OS_ID" = nixos ]; then
  IS_NIXOS=1
  info "distro: NixOS (os-release ID=nixos)"
fi

# Role detection: distro NixOS -> wsl (the only NixOS host is NixOS-WSL);
# hostname "laptop" -> laptop; login user "hermes" -> the joy host's hermes
# account; otherwise ask (install), defaulting to server, or refuse (update,
# which never prompts).
if [ -z "$ROLE" ]; then
  if [ "$IS_NIXOS" -eq 1 ]; then
    ROLE=wsl
    info "role: wsl (detected from NixOS)"
  elif [ "$(hostname)" = laptop ]; then
    ROLE=laptop
    info "role: laptop (detected from hostname)"
  elif [ "$(id -un)" = hermes ]; then
    ROLE=hermes
    info "role: hermes (detected from the login user)"
  elif [ "$MODE" = update ]; then
    die "cannot detect the host role without prompting (distro: ${OS_ID:-unknown}, hostname: $(hostname)) - pass --role <laptop|server|wsl|hermes>"
  else
    info "distro: ${OS_ID:-unknown}, hostname: $(hostname) - no automatic role"
    while :; do
      ROLE="$(ask 'Host role for this machine (laptop/server/wsl)' server)"
      case "$ROLE" in
        laptop | server | wsl) break ;;
        *) warn "'$ROLE' is not a valid role - enter laptop, server or wsl" ;;
      esac
    done
    info "role: $ROLE"
  fi
else
  info "role: $ROLE (forced)"
fi

# The `hermes` role can only be applied by the hermes account itself:
# homeConfigurations.hermes fixes home.username/home.homeDirectory to that
# user, and standalone home-manager activates a profile as the invoking user
# and writes that user's home. Refuse before any prompt, pull, build or write,
# and name the exact re-run command - never build a plan that claims to apply
# /home/hermes "as" somebody else.
if [ "$ROLE" = hermes ] && [ "$(id -un)" != "$HERMES_PROFILE_USER" ]; then
  die "role hermes activates homeConfigurations.hermes, which manages /home/$HERMES_PROFILE_USER as the '$HERMES_PROFILE_USER' account - it cannot be applied by '$(id -un)'.
Run it as that account, from the $HERMES_PROFILE_USER user's own checkout, e.g.:
  sudo -iu $HERMES_PROFILE_USER -- /home/$HERMES_PROFILE_USER/.nix-config/setup.sh $MODE --role hermes"
fi

if ! command -v nix >/dev/null 2>&1; then
  if [ "$IS_NIXOS" -eq 1 ]; then
    die "nix is not on PATH, but NixOS ships with it preinstalled - check your PATH (/nix/var/nix/profiles/default/bin/nix)"
  fi
  cat >&2 <<'EOF'
error: nix is not installed. Install it first, e.g.:
  sh <(curl -L https://nixos.org/nix/install) --daemon
or the Determinate Nix installer: https://install.determinate.systems
then re-run this script.
EOF
  exit 1
fi
info "nix: $(nix --version)"

HAS_GIT=0
if command -v git >/dev/null 2>&1; then
  HAS_GIT=1
  info "git: $(git --version)"
else
  info "git: not found (fine - nix fetches the repo itself; git is only used for a clone if you pick that source)"
fi

if [ "$(id -u)" -eq 0 ]; then
  warn "running as root - DOTFILES_USERNAME should be your regular user, not root"
fi

# Update takes over here: no repo-source prompt, no env prompts, no writes
# before the pull decides what to build.
if [ "$MODE" = update ]; then
  update_main
  exit 0
fi

# --- repo source ----------------------------------------------------------------

# Nothing personal is hardcoded here: this repo is public, and each user's
# Gitea host/owner differs, so option 1 prompts for the repo URL. GITEA_REPO_URL
# and LAN_URL are filled in below when option 1 is chosen.
GITEA_REPO_URL=""
LAN_URL=""
GH_URL="https://github.com/babbarc/nix-config.git"
GH_TARBALL="https://github.com/babbarc/nix-config/archive/refs/heads/master.tar.gz"

log "Repo source"
cat <<'EOF'
Where should I get the nix-config repo from?
  1) Your own Gitea server (e.g. on your home LAN) - I'll ask for its URL
  2) Public GitHub mirror - github.com/babbarc/nix-config
  3) An existing local checkout - I'll ask for its path
If you are not sure, pick 2 - the GitHub mirror needs no setup.
EOF
if [ -n "${SETUP_SOURCE:-}" ]; then
  SOURCE="$SETUP_SOURCE"
  case "$SOURCE" in
    1 | 2 | 3) : ;;
    *) die "invalid SETUP_SOURCE '$SOURCE' - valid: 1 (Gitea), 2 (GitHub), 3 (local checkout)" ;;
  esac
  info "repo source: $SOURCE (from SETUP_SOURCE)"
else
  SOURCE="$(ask 'choice' 1)"
  while :; do
    case "$SOURCE" in
      1 | 2 | 3) break ;;
      *)
        warn "'$SOURCE' is not a valid choice - enter 1, 2 or 3"
        SOURCE="$(ask 'choice' 1)"
        ;;
    esac
  done
fi

if [ "$SOURCE" = 1 ]; then
  while :; do
    printf '%s: ' 'Gitea repo URL (e.g. http://gitea.example.com:3222/user/nix-config, no trailing slash)' >&2
    if ! IFS= read -r gitea_answer; then
      die "no Gitea URL provided (stdin ended) - re-run and type it, or pick option 2 for the GitHub mirror"
    fi
    GITEA_REPO_URL="${gitea_answer%/}"
    if [ -n "$GITEA_REPO_URL" ]; then
      break
    fi
    warn "the Gitea repo URL must not be empty - type it, or pick option 2 for the GitHub mirror"
  done
  LAN_URL="$GITEA_REPO_URL/archive/master.tar.gz"
  info "Gitea source: $LAN_URL"
fi

# Natural default for source 3: the checkout this script is running from (e.g.
# ~/.nix-config after a bootstrap, or any worktree), else ~/.nix-config.
if [ -f "$REPO/flake.nix" ]; then
  LOCAL_REPO_DEFAULT="$REPO"
else
  LOCAL_REPO_DEFAULT="$HOME/.nix-config"
fi
LOCAL_REPO="$LOCAL_REPO_DEFAULT"
if [ "$SOURCE" = 3 ]; then
  while :; do
    LOCAL_REPO="$(ask 'path to your existing nix-config checkout' "$LOCAL_REPO")"
    LOCAL_REPO="${LOCAL_REPO/#\~/$HOME}"
    if [ -f "$LOCAL_REPO/flake.nix" ]; then
      break
    fi
    warn "no flake.nix found at $LOCAL_REPO - enter the path to a nix-config checkout"
  done
  info "using existing checkout at $LOCAL_REPO"
fi

# --- per-machine env values ------------------------------------------------------

# The hermes role reads nothing from ~/.config/dotfiles/env (its standalone
# profile has no dotfiles-env input), so install skips every env question for
# it - it must never write a file or prompt for values nothing reads.
if [ "$ROLE" = hermes ]; then
  ENV_USERNAME="$(id -un)"
  TARGET_HOME="$HOME"
else
log "Per-machine values"

# An existing env file's values become the prompt defaults (later lines win),
# so a re-run keeps the machine's setup. An empty line in the prompts keeps
# the [default]; type 'skip' to omit a machine-specific key.
load_env
if [ "$ENV_EXISTED" -eq 1 ]; then
  info "found existing env file at $ENV_FILE - its values are the defaults below (Enter keeps them)"
fi

def() { printf '%s' "${DEF[$1]:-${2:-}}"; }

# This role asks for and writes exactly these keys. An existing env file's
# keys outside this matrix are dropped on rewrite, so the file stays
# deterministic per role. WEZTERM_* are never part of any role's matrix:
# they are Windows-side and the Windows machine keeps its own env file
# (see env.example).

info "Prompts with a [default] accept it with Enter. Optional machine-specific"
info "values are omitted by Enter or 'skip' - each omission prints a warning so"
info "nothing breaks silently."

CUR_USER="${USER:-$(id -un)}"
DOTFILES_USERNAME="${SETUP_USERNAME:-}"
if [ -z "$DOTFILES_USERNAME" ]; then
  DOTFILES_USERNAME="$(ask 'Username of your user on this machine' "$(def DOTFILES_USERNAME "$CUR_USER")")"
fi
while [ -z "$DOTFILES_USERNAME" ]; do
  warn "the username must not be empty"
  DOTFILES_USERNAME="$(ask 'Username of your user on this machine' "$CUR_USER")"
done
case "$DOTFILES_USERNAME" in
  *' '*) die "username contains spaces: '$DOTFILES_USERNAME'" ;;
esac

# The env file's user is the TARGET user of this machine; setup.sh may be
# invoked by a different (image/bootstrap) user before that account exists.
# Everything user-specific below (env placement, chezmoi, password store)
# runs as this user; the build and switch stay as the invoking user because
# they are root/system operations and the target account does not exist yet
# on a fresh machine. (run_as_target itself lives with the shared helpers.)
ENV_USERNAME="$DOTFILES_USERNAME"
# getent fails before the target account exists (fresh machine, run as the
# image user) - that must not abort the script under set -e/pipefail.
TARGET_HOME="$(getent passwd "$ENV_USERNAME" 2>/dev/null | cut -d: -f6 || true)"
[ -n "$TARGET_HOME" ] || TARGET_HOME="/home/$ENV_USERNAME"

DOTFILES_USER_EMAIL="${SETUP_USER_EMAIL:-}"
if [ -z "$DOTFILES_USER_EMAIL" ]; then
  DOTFILES_USER_EMAIL="$(ask 'Email for your global git identity' "$(def DOTFILES_USER_EMAIL "")")"
fi
while [ -z "$DOTFILES_USER_EMAIL" ]; do
  warn "the email must not be empty"
  DOTFILES_USER_EMAIL="$(ask 'Email for your global git identity' "")"
done
case "$DOTFILES_USER_EMAIL" in
  *'@'*) ;;
  *) die "email must contain '@': '$DOTFILES_USER_EMAIL'" ;;
esac

# Fixed to the detected/chosen role - never prompted, never taken from an
# existing file (a different role in an existing file is simply overwritten).
DOTFILES_HOST_ROLE="$ROLE"

# Architecture is detected, not prompted: the flake builds for this machine's
# own arch. Overridable for testing/scripted use via SETUP_SYSTEM.
if [ -n "${SETUP_SYSTEM:-}" ]; then
  DOTFILES_SYSTEM="$SETUP_SYSTEM"
else
  case "$(uname -m)" in
    x86_64 | amd64) DOTFILES_SYSTEM="x86_64-linux" ;;
    aarch64 | arm64) DOTFILES_SYSTEM="aarch64-linux" ;;
    *) die "unsupported architecture: $(uname -m) (set SETUP_SYSTEM to override)" ;;
  esac
fi

if [ "$ROLE" = laptop ]; then
  DOTFILES_SERVER_HOST="$(ask_skip 'Home server hostname or ssh alias' "$(def DOTFILES_SERVER_HOST "")")"
  [ -n "$DOTFILES_SERVER_HOST" ] || warn "skipped DOTFILES_SERVER_HOST - the fish joy-console won't know your server"
  DOTFILES_SERVER_USER="$(ask_skip 'Username to ssh into the server as (same as yours by default)' "$(def DOTFILES_SERVER_USER "$DOTFILES_USERNAME")")"
  [ -n "$DOTFILES_SERVER_USER" ] || warn "skipped DOTFILES_SERVER_USER - ssh-to-server integrations won't know which user to use"

  log "joy-console (a container on the server - machine-specific, Enter or 'skip' omits)"
  JOY_CONSOLE_CONTAINER_USER="$(ask_skip 'Container user (sudo -u target)' "$(def JOY_CONSOLE_CONTAINER_USER "")")"
  JOY_CONSOLE_CONTAINER="$(ask_skip 'Container name (podman exec target)' "$(def JOY_CONSOLE_CONTAINER "")")"
  JOY_CONSOLE_CONTAINER_HOME="$(ask_skip 'Container user home directory' "$(def JOY_CONSOLE_CONTAINER_HOME "")")"
  [ -n "$JOY_CONSOLE_CONTAINER_USER" ] || warn "skipped JOY_CONSOLE_CONTAINER_USER - the joy-console function won't work"
  [ -n "$JOY_CONSOLE_CONTAINER" ] || warn "skipped JOY_CONSOLE_CONTAINER - the joy-console function won't work"
  [ -n "$JOY_CONSOLE_CONTAINER_HOME" ] || warn "skipped JOY_CONSOLE_CONTAINER_HOME"

  log "stereo-transcode (a LAN service - machine-specific, Enter or 'skip' omits)"
  STEREO_TRANSCODE_ENDPOINT="$(ask_skip 'HTTP endpoint' "$(def STEREO_TRANSCODE_ENDPOINT "")")"
  [ -n "$STEREO_TRANSCODE_ENDPOINT" ] || warn "skipped STEREO_TRANSCODE_ENDPOINT - the stereo-transcode CLI won't work"
fi

if [ "$ROLE" = wsl ]; then
  log "corporate CA (only on a corporate network with a TLS-intercepting proxy - Enter or 'skip' omits)"
  DOTFILES_CORPORATE_CA_DIR="$(ask_skip 'Absolute path to a directory of root CA cert files already on this machine' "$(def DOTFILES_CORPORATE_CA_DIR "")")"

  # Windows account name (the `<user>` in C:\Users\<user>). Only
  # modules/dev/hermes-agent.nix uses it, to build the Cua desktop driver's
  # install path. Detect it rather than prompt: WSL interop first
  # (powershell.exe, then cmd.exe), then a /mnt/c/Users scan that skips the
  # standard system profiles, and only prompt when that scan is ambiguous or
  # comes up empty. SETUP_WINDOWS_USER / an existing env value short-circuit
  # detection.
  log "Windows account (for the Cua desktop-driver path in hermes-agent.nix)"
  DOTFILES_WINDOWS_USER="${SETUP_WINDOWS_USER:-$(def DOTFILES_WINDOWS_USER "")}"
  if [ -n "$DOTFILES_WINDOWS_USER" ]; then
    if [ -n "${SETUP_WINDOWS_USER:-}" ]; then
      info "Windows account: $DOTFILES_WINDOWS_USER (from SETUP_WINDOWS_USER)"
    else
      info "Windows account: $DOTFILES_WINDOWS_USER (from the existing env file)"
    fi
  else
    win_user=""
    if command -v powershell.exe >/dev/null 2>&1; then
      # SC2016: '$env:USERNAME' is PowerShell syntax, intentionally single-quoted
      # so the shell passes it through unchanged.
      # shellcheck disable=SC2016
      win_user="$(powershell.exe -NoProfile -NonInteractive -Command '$env:USERNAME' 2>/dev/null | tr -d '\r' | head -n 1 || true)"
    fi
    if [ -z "$win_user" ] && command -v cmd.exe >/dev/null 2>&1; then
      win_user="$(cmd.exe /c 'echo %USERNAME%' 2>/dev/null | tr -d '\r' | head -n 1 || true)"
    fi
    case "$win_user" in
      '' | '%USERNAME%') win_user="" ;;
    esac
    if [ -n "$win_user" ]; then
      info "Windows account: $win_user (detected via WSL interop)"
    elif [ -d /mnt/c/Users ]; then
      win_candidates=()
      for d in /mnt/c/Users/*/; do
        [ -d "$d" ] || continue
        name="$(basename "$d")"
        case "$name" in
          Default | 'Default User' | 'Default.migrated' | Public | 'All Users' | defaultuser0 | WDAGUtilityAccount) continue ;;
        esac
        win_candidates+=("$name")
      done
      if [ "${#win_candidates[@]}" -eq 1 ]; then
        win_user="${win_candidates[0]}"
        info "Windows account: $win_user (only non-system profile under /mnt/c/Users)"
      elif [ "${#win_candidates[@]}" -gt 1 ]; then
        info "multiple Windows profiles under /mnt/c/Users: ${win_candidates[*]}"
        win_user="$(ask 'Windows account name' "${win_candidates[0]}")"
      fi
    fi
    if [ -n "$win_user" ]; then
      DOTFILES_WINDOWS_USER="$win_user"
    else
      DOTFILES_WINDOWS_USER="$(ask_skip 'Windows account name (Enter or skip to omit - hermes-agent.nix then falls back to its env.example placeholder)' '')"
      [ -n "$DOTFILES_WINDOWS_USER" ] || warn "skipped DOTFILES_WINDOWS_USER - the Cua desktop-driver path will use hermes-agent.nix's placeholder default until you set it"
    fi
  fi
fi

fi  # ROLE != hermes

# --- assemble the env file ----------------------------------------------------------

# env_line <key> <value>: echoes "key=value", or nothing when the value is
# empty (skipped keys stay out of the file entirely).
env_line() {
  if [ -n "$2" ]; then
    printf '%s=%s\n' "$1" "$2"
  fi
}

ENV_CONTENT=""
if [ "$ROLE" != hermes ]; then
  ENV_CONTENT="# Generated by setup.sh on $(date '+%F %T') - re-run the script to regenerate.
# Per-machine values for this nix-config repo (host role: $ROLE). See env.example
# in the repo for documentation of every key. Plaintext and gitignored - keep
# secrets OUT of this file; credentials stay in the OS secret store / pass.

# nix
$(env_line DOTFILES_USERNAME "$DOTFILES_USERNAME")
$(env_line DOTFILES_USER_EMAIL "$DOTFILES_USER_EMAIL")
$(env_line DOTFILES_HOST_ROLE "$DOTFILES_HOST_ROLE")
$(env_line DOTFILES_SYSTEM "$DOTFILES_SYSTEM")
"
if [ "$ROLE" = laptop ]; then
  ENV_CONTENT+="# nix (laptop: server + joy-console + stereo-transcode keys)
$(env_line DOTFILES_SERVER_HOST "$DOTFILES_SERVER_HOST")
$(env_line DOTFILES_SERVER_USER "$DOTFILES_SERVER_USER")

# fish joy-console
$(env_line JOY_CONSOLE_CONTAINER_USER "$JOY_CONSOLE_CONTAINER_USER")
$(env_line JOY_CONSOLE_CONTAINER "$JOY_CONSOLE_CONTAINER")
$(env_line JOY_CONSOLE_CONTAINER_HOME "$JOY_CONSOLE_CONTAINER_HOME")

# zsh stereo-transcode
$(env_line STEREO_TRANSCODE_ENDPOINT "$STEREO_TRANSCODE_ENDPOINT")
"
fi
if [ "$ROLE" = wsl ]; then
  ENV_CONTENT+="# nix (wsl: optional corporate CA + Windows account for the Cua driver path)
$(env_line DOTFILES_CORPORATE_CA_DIR "$DOTFILES_CORPORATE_CA_DIR")
$(env_line DOTFILES_WINDOWS_USER "${DOTFILES_WINDOWS_USER:-}")
"
fi
fi  # ROLE != hermes

# --- plan -----------------------------------------------------------------------------

UPDATE_REPO="$HOME/.nix-config" # checkout path named in the final hint
case "$SOURCE" in
  1)
    REPO_PLAN="fetch the repo tarball from your Gitea ($LAN_URL) with nix-prefetch-url and unpack it to $HOME/.nix-config"
    BUILD_FLAKE="$LAN_URL"
    ;;
  2)
    if [ "$HAS_GIT" -eq 1 ]; then
      REPO_PLAN="git clone the public GitHub mirror ($GH_URL) to $HOME/.nix-config"
      BUILD_FLAKE="path:$HOME/.nix-config"
    else
      REPO_PLAN="fetch the repo tarball from the GitHub mirror ($GH_TARBALL) with nix-prefetch-url and unpack it to $HOME/.nix-config"
      BUILD_FLAKE="$GH_TARBALL"
    fi
    ;;
  3)
    REPO_PLAN="use the existing checkout at $LOCAL_REPO"
    BUILD_FLAKE="path:$LOCAL_REPO"
    if [ "$LOCAL_REPO" != "$HOME/.nix-config" ]; then
      UPDATE_REPO="$LOCAL_REPO"
    fi
    ;;
esac

# Build target + activation depend on the role (and, for wsl, the distro);
# set_role_plan is the one implementation install and update both use.
set_role_plan "$BUILD_FLAKE"

# --- dry-run: print the plan, change nothing ----------------------------------------------

if [ "$DRY_RUN" -eq 1 ]; then
  echo
  echo "# dry-run - nothing will be fetched, written, built or activated."
  echo "# plan:"
  echo "#   role: $ROLE"
  echo "#   repo: $REPO_PLAN"
  if [ "$ROLE" = hermes ]; then
    echo "#   env:  none (role hermes reads no env file)"
  else
    echo "#   env:  write $ENV_FILE"
  fi
  echo "#   host: $HOST_LABEL"
  echo "# commands that WOULD run:"
  echo "  export NIX_CONFIG=\"experimental-features = nix-command flakes\""
  if [ "$ROLE" = wsl ] && [ -n "${DOTFILES_CORPORATE_CA_DIR:-}" ]; then
    echo "  # bootstrap trust for this script's own fetches (nix build/git/curl below"
    echo "  # need it before the declarative security.pki.certificateFiles work can"
    echo "  # ever apply - that only affects the system this script has yet to build):"
    echo "  cat <system default CA bundle> $DOTFILES_CORPORATE_CA_DIR/* > $CA_BUNDLE_FILE"
    echo "  export NIX_SSL_CERT_FILE=$CA_BUNDLE_FILE SSL_CERT_FILE=$CA_BUNDLE_FILE GIT_SSL_CAINFO=$CA_BUNDLE_FILE"
    echo "  # also passed to the build below as --option ssl-cert-file: this reaches a"
    echo "  # multi-user nix-daemon's own substituter/fixed-output-derivation fetches"
    echo "  # only if this account is a trusted user (nix.settings.trusted-users) -"
    echo "  # NIX_SSL_CERT_FILE/SSL_CERT_FILE alone never reach daemon-side fetches,"
    echo "  # confirmed by hand: the daemon computes its own default from its own"
    echo "  # (systemd-service) environment, not the connecting client's. On an"
    echo "  # untrusted connection nix will print its own warning that the setting"
    echo "  # was ignored - that does not affect this script's own fetches above,"
    echo "  # which use the exported env vars directly and are unaffected either way."
  fi
  case "$SOURCE" in
    1) echo "  retry nix-prefetch-url --unpack --print-path \"$LAN_URL\"" ;;
    2)
      if [ "$HAS_GIT" -eq 1 ]; then
        if [ -e "$HOME/.nix-config" ] && [ -n "$(ls -A "$HOME/.nix-config" 2>/dev/null)" ]; then
          echo "  retry git -C \"$HOME/.nix-config\" pull --ff-only  # existing repo reused, updated with a fast-forward pull"
        else
          echo "  retry git clone \"$GH_URL\" \"$HOME/.nix-config\""
        fi
      else
        echo "  retry nix-prefetch-url --unpack --print-path \"$GH_TARBALL\""
      fi
      ;;
    3) echo "  # existing checkout at $LOCAL_REPO reused (linked to ~/.nix-config if free)" ;;
  esac
  if [ "${#BUILD_CMD[@]}" -gt 0 ]; then
    echo "  retry ${BUILD_CMD[*]}"
  fi
  if [ "${SET_SYSTEM_PROFILE:-0}" -eq 1 ]; then
    echo "  retry sudo nix-env --profile /nix/var/nix/profiles/system --set \"\$(readlink -f ./result)\""
  fi
  echo "  ${ACTIVATE[*]}"
  if [ "$ROLE" = hermes ]; then
    echo "  # role hermes: no chezmoi apply (this profile must not touch the hermes user's dotfiles)"
    echo "  # role hermes: no password-store step"
  else
    if [ "$(id -un)" != "$ENV_USERNAME" ]; then
      echo "  # env file would also be synced into $ENV_USERNAME's home ($TARGET_HOME/.config/dotfiles/env) after the switch"
    fi
    echo "  retry nix shell nixpkgs#git nixpkgs#jq nixpkgs#curl nixpkgs#chezmoi -c chezmoi init \"$DOTFILES_REPO_URL\" --apply --force --no-tty --purge"
    if [ -e "$TARGET_HOME/.password-store" ]; then
      echo "  # ~/.password-store already exists - would leave it untouched"
    else
      echo "  # ~/.password-store missing - would prompt for its git remote URL (Enter to skip) and clone it via nix-shell git"
    fi
  fi
  echo "  # verify (read-only readiness report - never fails the run)"
  echo "# dry-run complete."
  exit 0
fi

# --- confirmation -----------------------------------------------------------------------------

echo
echo "== Plan =="
echo "  role: $ROLE"
echo "  repo: $REPO_PLAN"
if [ "$ROLE" = hermes ]; then
  echo "  env:  none (role hermes reads no env file)"
else
  echo "  env:  write $ENV_FILE"
  if [ "$ENV_EXISTED" -eq 1 ]; then
    echo "        (this file EXISTS - its values were the defaults above; it will be overwritten)"
    OLD_ROLE="$(def DOTFILES_HOST_ROLE "")"
    if [ -n "$OLD_ROLE" ] && [ "$OLD_ROLE" != "$ROLE" ]; then
      echo "        (its DOTFILES_HOST_ROLE=$OLD_ROLE is replaced by the detected role $ROLE)"
    fi
  else
    echo "        (new file)"
  fi
fi
echo "  host: $HOST_LABEL"
echo
if [ "$ROLE" != hermes ]; then
  echo "== Env file contents =="
  printf '%s\n' "$ENV_CONTENT"
  echo
fi
echo "The first build downloads nixpkgs + home-manager and can take a while"
echo "(a few hundred MB, several minutes); later switches are fast."
if ! confirm "Proceed?"; then
  echo "aborted - nothing was changed."
  exit 1
fi

# --- bootstrap -----------------------------------------------------------------------------------

log "Bootstrap"

# Flakes are enabled per-invocation. On NixOS /etc/nix/nix.conf is generated
# and read-only - never instruct editing it; NIX_CONFIG is the supported way.
export NIX_CONFIG="experimental-features = nix-command flakes"
info "flakes enabled for this session (NIX_CONFIG; /etc/nix/nix.conf left untouched)"

# On a corporate network, DOTFILES_CORPORATE_CA_DIR's declarative
# security.pki.certificateFiles wiring (hosts/wsl/configuration.nix) only
# takes effect on the ACTIVATED system - it cannot help this script's own
# network calls below, which is why the bundle is assembled before fetching.
# See assemble_ca_bundle for the full rationale.
if [ "$ROLE" = wsl ] && [ -n "${DOTFILES_CORPORATE_CA_DIR:-}" ]; then
  assemble_ca_bundle
fi

# unpack_repo <store-path>: copy a nix-prefetch-url --unpack result to
# ~/.nix-config (unless a repo is already there - re-runs stay put).
unpack_repo() {
  local store="$1"
  if repo_present_at "$HOME/.nix-config"; then
    info "reusing existing $HOME/.nix-config (the fetched tarball stays in the nix store for the build)"
    return
  fi
  if [ -e "$HOME/.nix-config" ] && [ -n "$(ls -A "$HOME/.nix-config" 2>/dev/null)" ]; then
    die "$HOME/.nix-config exists but does not look like this repo (no flake.nix) - move it aside or choose a different source"
  fi
  mkdir -p "$HOME"
  if [ -d "$HOME/.nix-config" ]; then
    cp -a "$store/." "$HOME/.nix-config/"
  else
    cp -a "$store" "$HOME/.nix-config"
  fi
  chmod -R u+w "$HOME/.nix-config"
  info "unpacked the repo to $HOME/.nix-config"
}

fetch_repo() {
  local store
  case "$SOURCE" in
    1)
      info "fetching the repo tarball from your Gitea (cached for the build)..."
      store="$(retry nix-prefetch-url --unpack --print-path "$LAN_URL" | tail -n 1)"
      unpack_repo "$store"
      ;;
    2)
      if [ "$HAS_GIT" -eq 1 ]; then
        if [ -e "$HOME/.nix-config" ] && [ -n "$(ls -A "$HOME/.nix-config" 2>/dev/null)" ]; then
          if repo_present_at "$HOME/.nix-config"; then
            info "pulling latest into existing $HOME/.nix-config..."
            retry git -C "$HOME/.nix-config" pull --ff-only ||
              die "git pull --ff-only failed in $HOME/.nix-config - it has local/diverged commits that can't fast-forward; resolve or move it aside and re-run"
          else
            die "$HOME/.nix-config exists but does not look like this repo - move it aside or choose a different source"
          fi
        else
          info "cloning the public GitHub mirror to $HOME/.nix-config..."
          retry git clone "$GH_URL" "$HOME/.nix-config"
        fi
      else
        info "fetching the repo tarball from the GitHub mirror (cached for the build)..."
        store="$(retry nix-prefetch-url --unpack --print-path "$GH_TARBALL" | tail -n 1)"
        unpack_repo "$store"
      fi
      ;;
    3)
      if [ "$LOCAL_REPO" != "$HOME/.nix-config" ]; then
        if [ ! -e "$HOME/.nix-config" ]; then
          ln -s "$LOCAL_REPO" "$HOME/.nix-config"
          info "linked $HOME/.nix-config -> $LOCAL_REPO"
        elif [ -d "$HOME/.nix-config" ] && [ -z "$(ls -A "$HOME/.nix-config" 2>/dev/null)" ]; then
          rmdir "$HOME/.nix-config"
          ln -s "$LOCAL_REPO" "$HOME/.nix-config"
          info "linked $HOME/.nix-config -> $LOCAL_REPO (replaced the empty dir)"
        else
          info "existing $HOME/.nix-config is kept as-is; the build uses $LOCAL_REPO"
        fi
      else
        info "using existing checkout at $LOCAL_REPO"
      fi
      ;;
  esac
}

write_env() {
  local dir
  dir="$(dirname "$ENV_FILE")"
  if [ "$ENV_EXISTED" -eq 1 ]; then
    warn "overwriting the existing env file at $ENV_FILE (you confirmed above)"
  fi
  mkdir -p "$dir"
  printf '%s' "$ENV_CONTENT" > "$ENV_FILE"
  info "wrote $ENV_FILE"
}

fetch_repo
if [ "$ROLE" = hermes ]; then
  info "role hermes: no env file to write (this profile reads none)"
else
  write_env
fi

build_and_activate

# The env file is needed by the target user post-reboot (chezmoi templates,
# fish, wezterm all read ~/.config/dotfiles/env). When setup ran as a
# different (image) user, sync it into the target user's home now that the
# switch has created the account.
if [ "$(id -un)" != "$ENV_USERNAME" ]; then
  if [ -d "$TARGET_HOME" ]; then
    if sudo mkdir -p "$TARGET_HOME/.config/dotfiles" \
      && sudo install -o "$ENV_USERNAME" -m 600 "$ENV_FILE" "$TARGET_HOME/.config/dotfiles/env" \
      && sudo chown "$ENV_USERNAME" "$TARGET_HOME/.config/dotfiles"; then
      info "synced env file into $ENV_USERNAME's home ($TARGET_HOME/.config/dotfiles/env)"
    else
      warn "could not sync env file into $TARGET_HOME - the switch succeeded; re-run setup.sh as $ENV_USERNAME to place it"
    fi
  else
    warn "target home $TARGET_HOME does not exist yet - env file stays at $ENV_FILE; re-run setup.sh as $ENV_USERNAME to place it"
  fi
fi

if [ "$ROLE" = hermes ]; then
  log "chezmoi"
  info "skipped for role hermes - this profile must not touch the hermes user's dotfiles"
else
  apply_chezmoi
fi

# --- password store ---------------------------------------------------------------------------------

# Independent of the activated pass-git-sync hook (modules/dev/pass-git-sync.nix)
# - that hook wires itself into a store the moment one exists on this host,
# via home-manager activation, regardless of whether this step ever runs.
# This step only gets a store onto a brand-new host that doesn't have one
# yet. Resilient warn-not-die: failures here never fail the whole script -
# the host is already built and activated by this point.
if [ "$ROLE" = hermes ]; then
  log "Password store"
  info "skipped for role hermes - its home is hand-managed"
else
log "Password store"
if [ -e "$TARGET_HOME/.password-store" ]; then
  info "$TARGET_HOME/.password-store already exists - leaving it untouched"
else
  # Optional, same semantics as the other ask_skip prompts: Enter or 'skip'
  # skips cleanly with a warning (each omission warns, nothing breaks
  # silently).
  PASS_STORE_URL="$(ask_skip 'Git remote URL for your pass password-store (e.g. git@gitea.example.com:user/password-store.git) (Enter to skip)' '')"
  if [ -n "$PASS_STORE_URL" ]; then
    if run_as_target nix shell nixpkgs#git -c git clone "$PASS_STORE_URL" "$TARGET_HOME/.password-store"; then
      info "cloned password store to $TARGET_HOME/.password-store"
    else
      warn "failed to clone password store from $PASS_STORE_URL - set it up manually later with: git clone $PASS_STORE_URL $TARGET_HOME/.password-store"
    fi
  else
    warn "no password-store URL provided - skipping; clone it manually later with: git clone <url> $TARGET_HOME/.password-store"
  fi
fi
fi  # ROLE != hermes

# Readiness report: shared with update, report-only (never fails the run).
verify_readiness

# --- summary -----------------------------------------------------------------------------------------

log "Done"

echo "What happened:"
echo "  * role: $ROLE - built + activated $HOST_LABEL"
echo "  * nix-config repo at $UPDATE_REPO ($REPO_PLAN)"
if [ "$ROLE" = hermes ]; then
  echo "  * no per-machine env file and no chezmoi apply (role hermes reads none and owns its home)"
else
  echo "  * per-machine env file at $ENV_FILE (values from your answers above)"
  if [ "$(id -un)" != "$ENV_USERNAME" ]; then
    echo "  * env file also synced into $ENV_USERNAME's home ($TARGET_HOME/.config/dotfiles/env)"
  fi
  if [ "$ENV_EXISTED" -eq 1 ]; then
    echo "  * your previous env file's values were kept as defaults and rewritten"
  fi
fi
echo
echo "Install runs once per machine; update maintains it from now on:"
echo "  $UPDATE_REPO/setup.sh update             # pull + rebuild + re-apply config + refresh runtimes"
echo "  $UPDATE_REPO/setup.sh update --dry-run   # print every command first"
echo "  $UPDATE_REPO/setup.sh --help             # --bump, --skip-runtime, --allow-dirty, --role"
echo
echo "SSH/GPG keys and other credentials are per-machine and NOT managed by this"
echo "repo - set them up on this machine yourself (README: 'Deploying to a new machine')."
