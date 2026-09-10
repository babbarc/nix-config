#!/usr/bin/env bash
# pass-env — Set an environment variable from a pass secret, run a command.
#
# Usage:
#   pass-env <pass-path> <var-name> [-- <command> [args...]]
#
# Loads the first line of the pass entry into the environment variable
# <var-name>, then executes <command>. The env var is set only in this
# process's scope — it is never echoed to stdout, never written to a file,
# and dies when the command finishes.
#
# The first line of a pass entry is the primary secret (password, token, key).
# For multi-line secrets (like JSON tokens), use pass-to instead.
#
# Examples:
#   pass-env joy/tools/microsoft/client-id CLIENT_ID -- python3 -c "
#     import os; print('Client ID length:', len(os.environ['CLIENT_ID']))
#   "
#
#   pass-env pallav/google/client-secret CLIENT_SECRET -- \
#     curl -s -X POST https://oauth2.googleapis.com/token \
#       -d "client_id=$CLIENT_ID" \
#       -d "client_secret=$CLIENT_SECRET" \
#       -d "grant_type=refresh_token" \
#       -d "refresh_token=$REFRESH_TOKEN"
#
# ⚠️ Security note: env vars are visible to child processes and via /proc
#    while the command runs. Prefer pass-to (stdin pipe) when possible.
#    Use pass-env only when the target command REQUIRES env vars.
#
set -euo pipefail

if [ $# -lt 2 ]; then
  echo "Usage: pass-env <pass-path> <var-name> [-- <command> [args...]]" >&2
  exit 1
fi

PASS_PATH="$1"
VAR_NAME="$2"
shift 2

# Find the -- separator and consume it
FOUND_SEP=false
CMD=()
for arg in "$@"; do
  if [ "$arg" = "--" ]; then
    FOUND_SEP=true
    continue
  fi
  if $FOUND_SEP; then
    CMD+=("$arg")
  fi
done

# Read only the FIRST LINE of the pass entry into the env var.
# This is the secret. It stays in process memory — never on stdout.
SECRET="$(pass show "$PASS_PATH" | head -1)"
export "$VAR_NAME=$SECRET"

# Unset SECRET immediately so it can't accidentally leak
unset SECRET

# Execute the command
if [ ${#CMD[@]} -eq 0 ]; then
  # No command — just confirm the variable was set
  echo "Set $VAR_NAME from $PASS_PATH (secret not displayed)" >&2
  exit 0
fi

exec "${CMD[@]}"
