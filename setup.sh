#!/usr/bin/env bash
# nix/setup.sh - guided bootstrap for every host (laptop, server, wsl).
#
# Interactive installer that takes a bare machine (nix only - no git, no
# editors, no checkout) to a fully configured dotfiles setup on any of the
# flake's three hosts:
#
#   1. detects the role (laptop / server / wsl) from the environment, with a
#      prompt fallback and a --role / SETUP_ROLE / positional override
#   2. asks where to get the repo from (home LAN Gitea / public GitHub mirror /
#      an existing local checkout) and walks through only the per-machine env
#      values that role needs (Enter accepts the [default]; Enter on an
#      optional machine-specific key omits it with a warning)
#   3. fetches the repo to ~/.dotfiles, writes ~/.config/dotfiles/env with
#      exactly the role's keys, then builds + activates the right host:
#      - laptop/server: homeConfigurations.<role>.activationPackage, then
#        env HOME_MANAGER_BACKUP_EXT=backup ./result/activate
#      - wsl on NixOS: nixosConfigurations.wsl.config.system.build.toplevel,
#        then sudo ./result/bin/switch-to-configuration switch
#      - wsl on any other distro: the portable dev-only home-manager profile
#        (homeConfigurations.server) + env HOME_MANAGER_BACKUP_EXT=backup
#        ./result/activate
#
# Role detection: distro NixOS (os-release ID=nixos) -> wsl; hostname "laptop"
# -> laptop; otherwise prompted (laptop/server/wsl, default server). The role
# decides which env keys are asked for and written: every role gets
# DOTFILES_USERNAME + DOTFILES_USER_EMAIL + DOTFILES_HOST_ROLE (the latter
# fixed to the role); laptop also gets its server / joy-console /
# stereo-transcode keys. WEZTERM_*
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
# must carry the path: scheme (nix ignores ?dir=nix on a bare path); remote
# URLs need no prefix:
#   nix build 'path:<url>?dir=nix#<attr>' \
#     --override-input dotfiles-env "path:$HOME/.config/dotfiles/env"
#
# Usage:
#   setup.sh [--role <laptop|server|wsl>] [--dry-run] [--help]
#
#   --role <role>  force the host role instead of detecting it
#   --dry-run      run detection and prompts, then print every command that
#                  would run - nothing is fetched, written, built or activated.
#
# Non-interactive / testing: pipe answers on stdin (empty line accepts the
# default, EOF accepts defaults for the rest) and set SETUP_YES=1 to
# auto-confirm, e.g.:
#   printf '1\n\n\n\n...\n' | SETUP_YES=1 ./setup.sh
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: setup.sh [--role <laptop|server|wsl>] [--dry-run] [--help]

Guided bootstrap of this dotfiles repo on any host (laptop, server, wsl).

  --role <role>  force the host role (default: detect from the environment,
                 then prompt)
  --dry-run      run detection and prompts, then print every command that
                 would run - change nothing
  --help         show this help

Environment (all optional):
  SETUP_YES=1      auto-confirm the final yes/no (testing/scripts)
  SETUP_ENV_FILE   where to write the env file
                   (default ~/.config/dotfiles/env)
  SETUP_OS_ID      pretend /etc/os-release ID is this value, e.g. nixos
                   (test hook - normally read from /etc/os-release)
  SETUP_ROLE       force the host role, same as --role
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
ROLE=""
while [ "$#" -gt 0 ]; do
  arg="$1"
  case "$arg" in
    --dry-run | --check) DRY_RUN=1 ;;
    --role)
      shift
      [ "$#" -ge 1 ] || die "option --role needs a value (laptop|server|wsl)"
      ROLE="$1"
      ;;
    --role=*) ROLE="${arg#--role=}" ;;
    --help | -h) usage ;;
    -*)
      echo "error: unknown option: $arg" >&2
      usage
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
    laptop | server | wsl) : ;;
    *) die "invalid role '$ROLE' - valid roles: laptop, server, wsl" ;;
  esac
fi

# Repo root is the parent of this script's directory (the script lives in nix/).
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Per-machine env file location (override for testing).
ENV_FILE="${SETUP_ENV_FILE:-$HOME/.config/dotfiles/env}"
# Persistent corporate CA bundle assembled for this script's own fetches (see
# the "Bootstrap" section below) - lives next to $ENV_FILE, not under /tmp:
# mktemp's default TMPDIR is /tmp, and a sandboxed nix build gets its own
# private, empty /tmp, so a /tmp path is not a reliable place to put a file
# that anything sandbox-adjacent needs to see. Overwritten fresh on every run.
CA_BUNDLE_FILE="${SETUP_CA_BUNDLE_FILE:-$HOME/.config/dotfiles/bootstrap-ca.crt}"

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
# hostname "laptop" -> laptop; otherwise ask, defaulting to server.
if [ -z "$ROLE" ]; then
  if [ "$IS_NIXOS" -eq 1 ]; then
    ROLE=wsl
    info "role: wsl (detected from NixOS)"
  elif [ "$(hostname)" = laptop ]; then
    ROLE=laptop
    info "role: laptop (detected from hostname)"
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

# --- repo source ----------------------------------------------------------------

# Nothing personal is hardcoded here: this repo is public, and each user's
# Gitea host/owner differs, so option 1 prompts for the repo URL. GITEA_REPO_URL
# and LAN_URL are filled in below when option 1 is chosen.
GITEA_REPO_URL=""
LAN_URL=""
GH_URL="https://github.com/babbarc/dotfiles.git"
GH_TARBALL="https://github.com/babbarc/dotfiles/archive/refs/heads/master.tar.gz"

log "Repo source"
cat <<'EOF'
Where should I get the dotfiles repo from?
  1) Your own Gitea server (e.g. on your home LAN) - I'll ask for its URL
  2) Public GitHub mirror - github.com/babbarc/dotfiles
  3) An existing local checkout - I'll ask for its path
If you are not sure, pick 2 - the GitHub mirror needs no setup.
EOF
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

if [ "$SOURCE" = 1 ]; then
  while :; do
    printf '%s: ' 'Gitea repo URL (e.g. http://gitea.example.com:3222/user/dotfiles, no trailing slash)' >&2
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
# ~/.dotfiles after a bootstrap, or any worktree), else ~/.dotfiles.
if [ -f "$REPO/nix/flake.nix" ]; then
  LOCAL_REPO_DEFAULT="$REPO"
else
  LOCAL_REPO_DEFAULT="$HOME/.dotfiles"
fi
LOCAL_REPO="$LOCAL_REPO_DEFAULT"
if [ "$SOURCE" = 3 ]; then
  while :; do
    LOCAL_REPO="$(ask 'path to your existing dotfiles checkout' "$LOCAL_REPO")"
    LOCAL_REPO="${LOCAL_REPO/#\~/$HOME}"
    if [ -f "$LOCAL_REPO/nix/flake.nix" ]; then
      break
    fi
    warn "no nix/flake.nix found at $LOCAL_REPO - enter the path to a dotfiles checkout"
  done
  info "using existing checkout at $LOCAL_REPO"
fi

# --- per-machine env values ------------------------------------------------------

log "Per-machine values"

# An existing env file's values become the prompt defaults (later lines win),
# so a re-run keeps the machine's setup. An empty line in the prompts keeps
# the [default]; type 'skip' to omit a machine-specific key.
declare -A DEF=()
ENV_EXISTED=0
if [ -f "$ENV_FILE" ]; then
  ENV_EXISTED=1
  info "found existing env file at $ENV_FILE - its values are the defaults below (Enter keeps them)"
  while IFS= read -r line; do
    line="${line%$'\r'}"
    case "$line" in
      '' | '#'*) continue ;;
    esac
    key="${line%%=*}"
    DEF["$key"]="${line#*=}"
  done < "$ENV_FILE"
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
DOTFILES_USERNAME="$(ask 'Username of your user on this machine' "$(def DOTFILES_USERNAME "$CUR_USER")")"
while [ -z "$DOTFILES_USERNAME" ]; do
  warn "the username must not be empty"
  DOTFILES_USERNAME="$(ask 'Username of your user on this machine' "$CUR_USER")"
done
case "$DOTFILES_USERNAME" in
  *' '*) die "username contains spaces: '$DOTFILES_USERNAME'" ;;
esac

DOTFILES_USER_EMAIL="$(ask 'Email for your global git identity' "$(def DOTFILES_USER_EMAIL "")")"
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
fi

# --- assemble the env file ----------------------------------------------------------

# env_line <key> <value>: echoes "key=value", or nothing when the value is
# empty (skipped keys stay out of the file entirely).
env_line() {
  if [ -n "$2" ]; then
    printf '%s=%s\n' "$1" "$2"
  fi
}

ENV_CONTENT="# Generated by nix/setup.sh on $(date '+%F %T') - re-run the script to regenerate.
# Per-machine values for this dotfiles repo (host role: $ROLE). See env.example
# in the repo for documentation of every key. Plaintext and gitignored - keep
# secrets OUT of this file; credentials stay in the OS secret store / pass.

# nix
$(env_line DOTFILES_USERNAME "$DOTFILES_USERNAME")
$(env_line DOTFILES_USER_EMAIL "$DOTFILES_USER_EMAIL")
$(env_line DOTFILES_HOST_ROLE "$DOTFILES_HOST_ROLE")
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
  ENV_CONTENT+="# nix (wsl: optional corporate CA)
$(env_line DOTFILES_CORPORATE_CA_DIR "$DOTFILES_CORPORATE_CA_DIR")
"
fi

# --- plan -----------------------------------------------------------------------------

# Build target + activation depend on the role (and, for wsl, the distro).
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
      ACTIVATE=(sudo ./result/bin/switch-to-configuration switch)
      HOST_LABEL="NixOS-WSL system (nixosConfigurations.wsl)"
    else
      ATTR="homeConfigurations.server.activationPackage"
      ACTIVATE=(env HOME_MANAGER_BACKUP_EXT=backup ./result/activate)
      HOST_LABEL="portable home-manager profile (homeConfigurations.server)"
    fi
    ;;
esac

UPDATE_REPO="$HOME/.dotfiles" # path used in the update-later commands
case "$SOURCE" in
  1)
    REPO_PLAN="fetch the repo tarball from your Gitea ($LAN_URL) with nix-prefetch-url and unpack it to $HOME/.dotfiles"
    BUILD_FLAKE="$LAN_URL?dir=nix"
    ;;
  2)
    if [ "$HAS_GIT" -eq 1 ]; then
      REPO_PLAN="git clone the public GitHub mirror ($GH_URL) to $HOME/.dotfiles"
      BUILD_FLAKE="path:$HOME/.dotfiles?dir=nix"
    else
      REPO_PLAN="fetch the repo tarball from the GitHub mirror ($GH_TARBALL) with nix-prefetch-url and unpack it to $HOME/.dotfiles"
      BUILD_FLAKE="$GH_TARBALL?dir=nix"
    fi
    ;;
  3)
    REPO_PLAN="use the existing checkout at $LOCAL_REPO"
    BUILD_FLAKE="path:$LOCAL_REPO?dir=nix"
    if [ "$LOCAL_REPO" != "$HOME/.dotfiles" ]; then
      UPDATE_REPO="$LOCAL_REPO"
    fi
    ;;
esac

BUILD_CMD=(nix build "$BUILD_FLAKE#$ATTR" --override-input dotfiles-env "path:$ENV_FILE")
# DOTFILES_CORPORATE_CA_DIR points at an arbitrary on-disk path outside the
# flake's inputs; flakes evaluate in pure mode by default, which forbids
# importing such a path into the store, so --impure is required only when
# that key is actually set (confirmed by hand: a plain path string in
# security.pki.certificateFiles fails in the sandboxed cacert build with
# "No such file or directory" since the sandbox has no access to it, and even
# after converting it to a real Nix path so it's imported into the store at
# eval time, pure eval itself then refuses with "access to absolute path ...
# is forbidden in pure evaluation mode" - only --impure resolves both).
if [ "$ROLE" = wsl ] && [ -n "${DOTFILES_CORPORATE_CA_DIR:-}" ]; then
  BUILD_CMD+=(--impure)
fi

# --- dry-run: print the plan, change nothing ----------------------------------------------

if [ "$DRY_RUN" -eq 1 ]; then
  echo
  echo "# dry-run - nothing will be fetched, written, built or activated."
  echo "# plan:"
  echo "#   role: $ROLE"
  echo "#   repo: $REPO_PLAN"
  echo "#   env:  write $ENV_FILE"
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
        if [ -e "$HOME/.dotfiles" ] && [ -n "$(ls -A "$HOME/.dotfiles" 2>/dev/null)" ]; then
          echo "  retry git -C \"$HOME/.dotfiles\" pull --ff-only  # existing repo reused, updated with a fast-forward pull"
        else
          echo "  retry git clone \"$GH_URL\" \"$HOME/.dotfiles\""
        fi
      else
        echo "  retry nix-prefetch-url --unpack --print-path \"$GH_TARBALL\""
      fi
      ;;
    3) echo "  # existing checkout at $LOCAL_REPO reused (linked to ~/.dotfiles if free)" ;;
  esac
  echo "  retry ${BUILD_CMD[*]}"
  echo "  ${ACTIVATE[*]}"
  echo "# dry-run complete."
  exit 0
fi

# --- confirmation -----------------------------------------------------------------------------

echo
echo "== Plan =="
echo "  role: $ROLE"
echo "  repo: $REPO_PLAN"
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
echo "  host: $HOST_LABEL"
echo
echo "== Env file contents =="
printf '%s\n' "$ENV_CONTENT"
echo
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
# security.pki.certificateFiles wiring (nix/hosts/wsl/configuration.nix) only
# takes effect on the ACTIVATED system - it cannot help THIS script's own
# network calls below (nix-prefetch-url/git clone in fetch_repo, and the nix
# build itself fetching flake inputs), because the system generation that
# would set it hasn't built yet. So before any of that, build a CA bundle for
# this script's own fetches (system default bundle + every file in the given
# directory) at a persistent path under $HOME (not mktemp's /tmp - a
# sandboxed nix build gets its own private, empty /tmp, so a /tmp path is not
# reliably visible where it might be needed) and export it via the env vars
# Nix/git/curl actually honor. Regenerated (overwritten, not appended) on
# every run rather than trying to detect staleness; left in place afterwards
# since it's a plain, inspectable, non-secret CA bundle - a missing/unset
# directory changes nothing.
if [ "$ROLE" = wsl ] && [ -n "${DOTFILES_CORPORATE_CA_DIR:-}" ]; then
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
  # makes directly (nix-prefetch-url, git clone, and flake-input evaluation
  # inside `nix build`). They do NOT reach a multi-user nix-daemon's own
  # fetches (substituter/binary-cache downloads, and fixed-output-derivation
  # builds) - confirmed by hand against this repo's own nix (2.35.2): the
  # daemon resolves its ssl-cert-file setting from ITS OWN process
  # environment (the systemd service's, not the connecting client's), and a
  # client-side env var never even reaches the client/daemon settings
  # handshake. Passing --option ssl-cert-file explicitly on the build command
  # below DOES reach the daemon and takes effect - but ONLY if this account
  # is in nix.settings.trusted-users (NixOS default: root only); otherwise
  # the daemon logs "ignoring the client-specified setting 'ssl-cert-file'
  # ... you are not a trusted user" and keeps using its own default.
  #
  # nix/hosts/wsl/configuration.nix now declares this login user as a
  # trusted user (see its nix.settings.trusted-users comment for the
  # security tradeoff), so this stops being a problem from the SECOND
  # activation onward. It cannot help the very first run on a fresh
  # corporate-network machine, though: that declarative setting only takes
  # effect once a generation built with it has been activated, and this
  # script's own process is what builds/activates that first generation -
  # chicken-and-egg. For that one-time first run, invoke this script with
  # `sudo` (root is trusted by default) if package/binary-cache downloads
  # during the build below hit SSL errors.
  BUILD_CMD+=(--option ssl-cert-file "$CA_BUNDLE_FILE")
fi

# repo_present_at <dir>: non-empty dir that looks like this repo.
repo_present_at() {
  [ -f "$1/nix/flake.nix" ] && [ -f "$1/env.example" ]
}

# unpack_repo <store-path>: copy a nix-prefetch-url --unpack result to
# ~/.dotfiles (unless a repo is already there - re-runs stay put).
unpack_repo() {
  local store="$1"
  if repo_present_at "$HOME/.dotfiles"; then
    info "reusing existing $HOME/.dotfiles (the fetched tarball stays in the nix store for the build)"
    return
  fi
  if [ -e "$HOME/.dotfiles" ] && [ -n "$(ls -A "$HOME/.dotfiles" 2>/dev/null)" ]; then
    die "$HOME/.dotfiles exists but does not look like this repo (no nix/flake.nix) - move it aside or choose a different source"
  fi
  mkdir -p "$HOME"
  if [ -d "$HOME/.dotfiles" ]; then
    cp -a "$store/." "$HOME/.dotfiles/"
  else
    cp -a "$store" "$HOME/.dotfiles"
  fi
  chmod -R u+w "$HOME/.dotfiles"
  info "unpacked the repo to $HOME/.dotfiles"
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
        if [ -e "$HOME/.dotfiles" ] && [ -n "$(ls -A "$HOME/.dotfiles" 2>/dev/null)" ]; then
          if repo_present_at "$HOME/.dotfiles"; then
            info "pulling latest into existing $HOME/.dotfiles..."
            retry git -C "$HOME/.dotfiles" pull --ff-only ||
              die "git pull --ff-only failed in $HOME/.dotfiles - it has local/diverged commits that can't fast-forward; resolve or move it aside and re-run"
          else
            die "$HOME/.dotfiles exists but does not look like this repo - move it aside or choose a different source"
          fi
        else
          info "cloning the public GitHub mirror to $HOME/.dotfiles..."
          retry git clone "$GH_URL" "$HOME/.dotfiles"
        fi
      else
        info "fetching the repo tarball from the GitHub mirror (cached for the build)..."
        store="$(retry nix-prefetch-url --unpack --print-path "$GH_TARBALL" | tail -n 1)"
        unpack_repo "$store"
      fi
      ;;
    3)
      if [ "$LOCAL_REPO" != "$HOME/.dotfiles" ]; then
        if [ ! -e "$HOME/.dotfiles" ]; then
          ln -s "$LOCAL_REPO" "$HOME/.dotfiles"
          info "linked $HOME/.dotfiles -> $LOCAL_REPO"
        elif [ -d "$HOME/.dotfiles" ] && [ -z "$(ls -A "$HOME/.dotfiles" 2>/dev/null)" ]; then
          rmdir "$HOME/.dotfiles"
          ln -s "$LOCAL_REPO" "$HOME/.dotfiles"
          info "linked $HOME/.dotfiles -> $LOCAL_REPO (replaced the empty dir)"
        else
          info "existing $HOME/.dotfiles is kept as-is; the build uses $LOCAL_REPO"
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
write_env

# Build + activation run from $HOME so ./result lands somewhere sensible
# regardless of where the script was invoked from.
cd "$HOME"

log "Build"
info "building $HOST_LABEL from $BUILD_FLAKE"
info "  (first run downloads nixpkgs + home-manager - a few hundred MB and a few minutes; later runs are fast)"
info "running: ${BUILD_CMD[*]}"
retry "${BUILD_CMD[@]}"

log "Activate"
info "running: ${ACTIVATE[*]}"
"${ACTIVATE[@]}"

# --- summary -----------------------------------------------------------------------------------------

log "Done"

echo "What happened:"
echo "  * role: $ROLE - built + activated $HOST_LABEL"
echo "  * dotfiles repo at $UPDATE_REPO ($REPO_PLAN)"
echo "  * per-machine env file at $ENV_FILE (values from your answers above)"
if [ "$ENV_EXISTED" -eq 1 ]; then
  echo "  * your previous env file's values were kept as defaults and rewritten"
fi
echo
echo "Update this machine later:"
case "$ROLE" in
  laptop)
    echo "  home-manager switch --flake path:$UPDATE_REPO?dir=nix#laptop --override-input dotfiles-env path:$HOME/.config/dotfiles/env"
    ;;
  server)
    echo "  home-manager switch --flake path:$UPDATE_REPO?dir=nix#server --override-input dotfiles-env path:$HOME/.config/dotfiles/env"
    ;;
  wsl)
    if [ "$IS_NIXOS" -eq 1 ]; then
      echo "  sudo nixos-rebuild switch --flake path:$UPDATE_REPO?dir=nix#wsl --override-input dotfiles-env path:$HOME/.config/dotfiles/env"
    else
      echo "  home-manager switch --flake path:$UPDATE_REPO?dir=nix#server --override-input dotfiles-env path:$HOME/.config/dotfiles/env"
    fi
    ;;
esac
echo "  (or just re-run $UPDATE_REPO/nix/setup.sh - it re-detects everything)"
echo
echo "SSH/GPG keys and other credentials are per-machine and NOT managed by this"
echo "repo - set them up on this machine yourself (README: 'Keys and credentials')."
