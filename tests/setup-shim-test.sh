#!/usr/bin/env bash
# SC2016: write_shim() emits literal shell code into the generated shims, so
# its single-quoted "$SHIM_LOG"/"$@" strings must not expand here. SC2329:
# cleanup() runs from the EXIT trap below.
# shellcheck disable=SC2016,SC2329
# tests/setup-shim-test.sh - hermetic end-to-end lifecycle test for setup.sh.
#
# Why this exists: a dry-run returns before build_and_activate() runs, so it
# cannot catch a variable that only one lifecycle assigns. The real
# `setup.sh update --role wsl` died in the Build phase with
#   bash: line NNN: BUILD_FLAKE: unbound variable
# while every dry-run passed. So this harness runs the REAL (non-dry-run)
# lifecycles - update for wsl/server/hermes, install for wsl/hermes, and
# update --dry-run - with every side-effecting command replaced by a PATH
# shim that records its argv and exits 0.
#
# Nothing here touches the real host: HOME, the checkout and the env file all
# live under one mktemp dir, every shim is a no-op logger (the sudo shim never
# escalates), and the harness refuses to run as root. Nothing is fetched,
# pulled, built, installed or activated.
#
# Usage:
#   bash tests/setup-shim-test.sh
#   KEEP=1 bash tests/setup-shim-test.sh   # keep the temp dir for inspection
set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
  echo "error: this harness must run as a normal user - it must never touch the real host as root" >&2
  exit 2
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_USER="$(id -un)"
BASE_PATH="$PATH"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/setup-shim-test.XXXXXX")"
KEEP="${KEEP:-0}"

FAILED=0
CASE=""
TBIN=""
SHIM_LOG=""
STDOUT=""
STDERR=""
RC=0
CHECKOUT=""

cleanup() {
  if [ "$KEEP" = 1 ]; then
    printf '\nkept the sandbox at %s\n' "$ROOT"
  else
    rm -rf "$ROOT"
  fi
}
trap cleanup EXIT

pass() { printf '  PASS  %s\n' "$*"; }
fail() {
  printf '  FAIL  %s\n' "$*" >&2
  FAILED=$((FAILED + 1))
}

# --- shims ---------------------------------------------------------------------

# write_shim <name>: write an executable shim that appends "<name> <argv...>"
# to $SHIM_LOG; the heredoc body runs after the logging and defines the
# behavior (default: exit 0).
write_shim() {
  local name="$1"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'printf "%s" "${0##*/}" >> "$SHIM_LOG"'
    printf '%s\n' 'for a in "$@"; do printf " %s" "$a" >> "$SHIM_LOG"; done'
    printf '%s\n' 'printf "\n" >> "$SHIM_LOG"'
    cat
  } >"$TBIN/$name"
  chmod +x "$TBIN/$name"
}

write_shims() {
  write_shim nix <<'EOF'
case "${1:-}" in
  --version) echo "nix (Nix) 2.99.0-shim" ;;
esac
exit 0
EOF

  # Never escalates - records argv and succeeds. A real switch/activation can
  # therefore never happen from this harness.
  write_shim sudo <<'EOF'
exit 0
EOF

  write_shim git <<'EOF'
args="$*"
case "$args" in
  *--version) echo "git version 2.99.0-shim" ;;
  *"rev-parse --git-dir") echo "/tmp/setup-shim-test.git" ;;
  *"rev-parse --short HEAD") echo "deadbeef" ;;
  *"rev-parse --abbrev-ref --symbolic-full-name @{u}") echo "origin/master" ;;
  *"rev-list --count"*) echo 0 ;;
  *"remote get-url origin") echo "https://github.com/babbarc/firstmate.git" ;;
  *"status --porcelain"*) : ;;
esac
exit 0
EOF

  write_shim getent <<'EOF'
if [ "${1:-}" = passwd ]; then
  printf '%s:x:1000:1000::%s:/bin/bash\n' "${2:-}" "${HOME}"
  exit 0
fi
exit 0
EOF

  write_shim pi <<'EOF'
exit 0
EOF

  write_shim hermes <<'EOF'
case "${1:-}" in
  --version) echo "hermes 2026.8.31 (shim)" ;;
  skills)
    printf '| %s | skill | local | managed | enabled |\n' \
      axi-authoring browse delegated-task operate-desktop pass-access recover-blocked-page web-login
    ;;
  plugins)
    printf '| %s | enabled |\n' guardrails pass-enforcement
    ;;
esac
exit 0
EOF

  write_shim herdr <<'EOF'
exit 0
EOF

  write_shim npm <<'EOF'
exit 0
EOF

  write_shim chezmoi <<'EOF'
exit 0
EOF

  write_shim systemctl <<'EOF'
exit 0
EOF

  write_shim hermes-guardrails <<'EOF'
exit 0
EOF

  write_shim gh <<'EOF'
exit 0
EOF

  write_shim gpg <<'EOF'
case "${1:-}" in
  --list-secret-keys)
    echo "sec   rsa4096 2020-01-01 [SC] 0123456789ABCDEF"
    echo "uid           [ultimate] Captain <captain@example.com>"
    ;;
esac
exit 0
EOF
}

# The hermes role is only applicable by the `hermes` account itself, so those
# cases shim `id` inside setup.sh's PATH (the harness's own id checks ran above,
# before any shim existed).
write_hermes_id_shim() {
  write_shim id <<'EOF'
case "${1:-}" in
  -un) echo hermes ;;
  -u) echo 1003 ;;
  *) echo "uid=1003(hermes) gid=1003(hermes) groups=1003(hermes)" ;;
esac
exit 0
EOF
}

# --- case setup ----------------------------------------------------------------

start_case() {
  CASE="$1"
  CASE_DIR="$ROOT/$CASE"
  HOME_UNDER_TEST="$CASE_DIR/home"
  CHECKOUT="$HOME_UNDER_TEST/.nix-config"
  TBIN="$CASE_DIR/bin"
  SHIM_LOG="$CASE_DIR/calls.log"
  STDOUT="$CASE_DIR/stdout.log"
  STDERR="$CASE_DIR/stderr.log"

  mkdir -p "$HOME_UNDER_TEST" "$CHECKOUT" "$TBIN"
  : >"$SHIM_LOG"
  : >"$STDOUT"
  : >"$STDERR"

  # Reset every knob a previous case may have set.
  unset -v SETUP_ROLE SETUP_SOURCE SETUP_USERNAME SETUP_USER_EMAIL \
    SETUP_WINDOWS_USER SETUP_SYSTEM SETUP_YES SETUP_OS_ID SETUP_ENV_FILE \
    SETUP_CA_BUNDLE_FILE

  export HOME="$HOME_UNDER_TEST"
  export SHIM_LOG
  export SETUP_ENV_FILE="$CASE_DIR/dotfiles-env"
  export SETUP_OS_ID=nixos
  export PATH="$TBIN:$BASE_PATH"

  # The checkout the script runs from is a throwaway copy of this worktree -
  # never the real one.
  tar -C "$REPO_ROOT" --exclude=.git --exclude=result -cf - . | tar -C "$CHECKOUT" -xf -

  write_shims
  prepare_fake_home

  printf '\n=== case: %s ===\n' "$CASE"
  case "$HOME" in
    "$CASE_DIR"/*) : ;;
    *) echo "internal error: HOME ($HOME) escaped the sandbox" >&2; exit 1 ;;
  esac
}

# A home that looks provisioned to refresh_runtimes()/verify_readiness(), so
# the whole lifecycle runs its real branches instead of skipping them.
prepare_fake_home() {
  mkdir -p "$HOME/.local/bin" "$HOME/.local/lib/node_modules/gh-axi" \
    "$HOME/.local/lib/node_modules/chrome-devtools-axi" "$HOME/.pi/agent/install" \
    "$HOME/.local/share/hermes-agent/bin" "$HOME/firstmate/bin" "$HOME/firstmate/.git" \
    "$HOME/result" "$HOME/.password-store"

  # Managed pi install + its launcher symlink (the layout piInstall creates).
  cp "$TBIN/pi" "$HOME/.pi/agent/install/pi"
  ln -s "$HOME/.pi/agent/install/pi" "$HOME/.local/bin/pi"

  # The pinned hermes venv layout hermesAgentInstall creates.
  cp "$TBIN/hermes" "$HOME/.local/share/hermes-agent/bin/hermes"
  export PATH="$HOME/.local/share/hermes-agent/bin:$PATH"

  cat >"$HOME/result/activate" <<'EOF'
#!/usr/bin/env bash
printf 'result/activate' >>"$SHIM_LOG"
for a in "$@"; do printf ' %s' "$a" >>"$SHIM_LOG"; done
printf '\n' >>"$SHIM_LOG"
EOF
  chmod +x "$HOME/result/activate"

  cat >"$HOME/firstmate/bin/fm-update.sh" <<'EOF'
#!/usr/bin/env bash
printf 'fm-update.sh' >>"$SHIM_LOG"
for a in "$@"; do printf ' %s' "$a" >>"$SHIM_LOG"; done
printf '\n' >>"$SHIM_LOG"
EOF
  chmod +x "$HOME/firstmate/bin/fm-update.sh"
}

write_env_file() { # <role>
  {
    echo "# test env file (throwaway copy - update must never rewrite it)"
    echo "DOTFILES_USERNAME=$REAL_USER"
    echo "DOTFILES_USER_EMAIL=captain@example.com"
    echo "DOTFILES_HOST_ROLE=$1"
    echo "DOTFILES_SYSTEM=x86_64-linux"
    if [ "$1" = wsl ]; then
      echo "DOTFILES_WINDOWS_USER=winuser"
    fi
  } >"$SETUP_ENV_FILE"
}

run_setup() {
  local rc=0
  (cd "$CHECKOUT" && bash ./setup.sh "$@" >"$STDOUT" 2>"$STDERR") </dev/null || rc=$?
  RC=$rc
  printf '  --- stdout (%s) ---\n' "$CASE"
  sed 's/^/  | /' "$STDOUT"
  if [ -s "$STDERR" ]; then
    printf '  --- stderr ---\n'
    sed 's/^/  | /' "$STDERR"
  fi
  printf '  --- calls ---\n'
  sed 's/^/  | /' "$SHIM_LOG"
  printf '  --- exit: %s ---\n' "$RC"
}

# --- assertions ----------------------------------------------------------------

assert_rc() {
  if [ "$RC" -eq "$1" ]; then
    pass "exit code is $1"
  else
    fail "expected exit code $1, got $RC"
  fi
}

assert_out_has() {
  if grep -Fq -- "$1" "$STDOUT"; then
    pass "stdout: $1"
  else
    fail "stdout missing: $1"
  fi
}

assert_out_lacks() {
  if grep -Fq -- "$1" "$STDOUT"; then
    fail "stdout unexpectedly contains: $1"
  else
    pass "stdout lacks: $1"
  fi
}

assert_log_has() {
  if grep -Fq -- "$1" "$SHIM_LOG"; then
    pass "calls: $1"
  else
    fail "calls missing: $1"
  fi
}

assert_log_lacks() {
  if grep -Fq -- "$1" "$SHIM_LOG"; then
    fail "calls unexpectedly contain: $1"
  else
    pass "calls lack: $1"
  fi
}

assert_file_absent() {
  if [ -e "$1" ]; then
    fail "file should not exist: $1"
  else
    pass "file absent: $1"
  fi
}

assert_env_unchanged() {
  local before="$1" after
  after="$(sha256sum "$SETUP_ENV_FILE")"
  if [ "$before" = "$after" ]; then
    pass "env file is byte-identical ($SETUP_ENV_FILE)"
  else
    fail "env file changed: $before -> $after"
  fi
}

# assert_log_order <pattern...>: each pattern's first matching call line must
# come after the previous one's.
assert_log_order() {
  local prev=0 pat line
  for pat in "$@"; do
    line="$(grep -nF -- "$pat" "$SHIM_LOG" | head -n 1 | cut -d: -f1)" || line=""
    if [ -z "$line" ]; then
      fail "order: missing '$pat'"
      return
    fi
    if [ "$line" -le "$prev" ]; then
      fail "order: '$pat' did not run after the previous step"
      return
    fi
    prev="$line"
  done
  pass "call order: $*"
}

# --- cases ---------------------------------------------------------------------

case_update_wsl() {
  start_case update-wsl
  write_env_file wsl
  local before
  before="$(sha256sum "$SETUP_ENV_FILE")"

  run_setup update --role wsl

  assert_rc 0
  # The regression this harness exists for: the Build phase must print the
  # planned flake ref on the UPDATE path too (no "unbound variable").
  assert_out_has "building NixOS-WSL system (nixosConfigurations.wsl) from path:$CHECKOUT"
  assert_out_lacks "unbound variable"
  assert_log_has "git -C $CHECKOUT pull --ff-only"
  assert_log_has "nix build path:$CHECKOUT#nixosConfigurations.wsl.config.system.build.toplevel"
  assert_log_has "--override-input dotfiles-env path:$SETUP_ENV_FILE"
  assert_log_has "sudo nix-env --profile /nix/var/nix/profiles/system --set"
  assert_log_has "sudo ./result/bin/switch-to-configuration switch"
  assert_log_has "nix shell nixpkgs#git nixpkgs#jq nixpkgs#curl nixpkgs#chezmoi -c chezmoi init https://github.com/babbarc/dotfiles.git --apply --force --no-tty --purge"
  assert_log_has "pi update --all"
  assert_log_has "hermes update --yes"
  assert_log_has "herdr update"
  assert_log_has "npm update --prefix $HOME/.local -g gh-axi chrome-devtools-axi"
  assert_log_has "fm-update.sh"
  assert_log_lacks "nix flake update"
  assert_log_lacks "nix-prefetch-url"
  assert_log_order \
    "git -C $CHECKOUT pull --ff-only" \
    "nix build path:$CHECKOUT#" \
    "sudo ./result/bin/switch-to-configuration switch" \
    "chezmoi init" \
    "pi update --all"
  assert_env_unchanged "$before"
}

case_update_wsl_dry_run() {
  start_case update-wsl-dry-run
  write_env_file wsl
  local before
  before="$(sha256sum "$SETUP_ENV_FILE")"

  run_setup update --dry-run --role wsl

  assert_rc 0
  assert_out_has "# dry-run - nothing will be pulled, written, built or activated."
  assert_out_has "#   checkout:   $CHECKOUT"
  assert_out_has "retry nix build path:$CHECKOUT#nixosConfigurations.wsl.config.system.build.toplevel"
  assert_out_has "retry sudo nix-env --profile /nix/var/nix/profiles/system"
  assert_out_has "sudo ./result/bin/switch-to-configuration switch"
  assert_log_lacks "pull --ff-only"
  assert_log_lacks "nix build"
  assert_log_lacks "switch-to-configuration"
  assert_log_lacks "chezmoi"
  assert_log_lacks "pi update"
  assert_log_lacks "sudo"
  assert_env_unchanged "$before"
}

case_update_server() {
  start_case update-server
  write_env_file server
  local before
  before="$(sha256sum "$SETUP_ENV_FILE")"

  run_setup update --role server

  assert_rc 0
  assert_out_has "building home-manager profile (homeConfigurations.server) from path:$CHECKOUT"
  assert_out_lacks "unbound variable"
  assert_log_has "nix build path:$CHECKOUT#homeConfigurations.server.activationPackage"
  assert_log_has "result/activate"
  assert_log_has "chezmoi init https://github.com/babbarc/dotfiles.git"
  assert_log_has "pi update --all"
  # No system profile on a standalone home-manager host.
  assert_log_lacks "nix-env"
  assert_log_lacks "sudo"
  assert_log_order \
    "git -C $CHECKOUT pull --ff-only" \
    "nix build path:$CHECKOUT#" \
    "result/activate" \
    "chezmoi init" \
    "pi update --all"
  assert_env_unchanged "$before"
}

case_update_hermes() {
  start_case update-hermes
  write_hermes_id_shim
  export SETUP_ENV_FILE="$CASE_DIR/no-such-env"

  run_setup update --role hermes

  assert_rc 0
  assert_out_has "role hermes: no env file, no chezmoi, no runtime refresh"
  assert_log_has "git -C $CHECKOUT pull --ff-only"
  assert_log_has "nix run home-manager -- switch -b hm-bak --flake path:$CHECKOUT#hermes"
  assert_log_lacks "nix build"
  assert_log_lacks "chezmoi"
  assert_log_lacks "npm update"
  assert_log_lacks "pi update"
  assert_log_lacks "sudo"
  assert_file_absent "$SETUP_ENV_FILE"
}

case_install_wsl() {
  start_case install-wsl
  write_env_file wsl

  export SETUP_SOURCE=3
  export SETUP_USERNAME="$REAL_USER"
  export SETUP_USER_EMAIL="captain@example.com"
  export SETUP_WINDOWS_USER="winuser"
  export SETUP_SYSTEM="x86_64-linux"
  export SETUP_YES=1

  run_setup --role wsl

  assert_rc 0
  assert_out_has "building NixOS-WSL system (nixosConfigurations.wsl) from path:$CHECKOUT"
  assert_out_lacks "unbound variable"
  assert_out_has "wrote $SETUP_ENV_FILE"
  assert_log_has "nix build path:$CHECKOUT#nixosConfigurations.wsl.config.system.build.toplevel"
  assert_log_has "sudo ./result/bin/switch-to-configuration switch"
  assert_log_has "chezmoi init https://github.com/babbarc/dotfiles.git"
  if grep -Fq "DOTFILES_HOST_ROLE=wsl" "$SETUP_ENV_FILE"; then
    pass "install wrote DOTFILES_HOST_ROLE=wsl to the env file"
  else
    fail "install did not write DOTFILES_HOST_ROLE=wsl to $SETUP_ENV_FILE"
  fi
}

case_install_hermes() {
  start_case install-hermes
  write_hermes_id_shim
  export SETUP_ENV_FILE="$CASE_DIR/no-such-env"
  export SETUP_SOURCE=3
  export SETUP_YES=1

  run_setup --role hermes

  assert_rc 0
  assert_out_lacks "unbound variable"
  assert_log_has "nix run home-manager -- switch -b hm-bak --flake path:$CHECKOUT#hermes"
  assert_log_lacks "nix build"
  assert_log_lacks "chezmoi"
  assert_log_lacks "sudo"
  assert_file_absent "$SETUP_ENV_FILE"
}

printf 'setup.sh shim test - sandbox: %s\n' "$ROOT"
case_update_wsl
case_update_wsl_dry_run
case_update_server
case_update_hermes
case_install_wsl
case_install_hermes

printf '\n'
if [ "$FAILED" -eq 0 ]; then
  echo "shim test: PASS (6 cases, nothing fetched/built/activated)"
  exit 0
fi
echo "shim test: FAIL ($FAILED assertion(s) failed)" >&2
exit 1
