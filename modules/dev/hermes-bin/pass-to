#!/usr/bin/env bash
# pass-to — Pipe a pass secret to a command's stdin, never to stdout/LLM.
#
# Usage:
#   pass-to <pass-path> [-- <command> [args...]]
#
# Fetches the secret via `pass show <path>` and pipes it to <command>'s stdin.
# The secret flows: GPG → pipe → command's stdin.
# Only the command's stdout/stderr reaches the caller — the secret never does.
#
# If no command is given after --, the secret is printed to /dev/null (sink).
# Use this to verify the pass-path exists without exposing the secret.
#
# Examples:
#   pass-to pallav/google/token -- python3 -c "
#     import sys, json
#     token = json.load(sys.stdin)
#     print('Token valid:', 'token' in token)
#   "
#
#   pass-to joy/tools/microsoft/client-id -- wc -c
#
#   # Just check the entry exists (no output secret)
#   pass-to pallav/google/client-secret
#
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: pass-to <pass-path> [-- <command> [args...]]" >&2
  exit 1
fi

PASS_PATH="$1"
shift

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

# If no command was given, just validate the path exists (sink the output)
if [ ${#CMD[@]} -eq 0 ]; then
  pass show "$PASS_PATH" > /dev/null
  exit $?
fi

# Pipe the secret to the command's stdin
#
# CRITICAL: pass show stdout goes to the pipe, NOT to the terminal.
# The command's stdout goes to terminal() — the caller sees only the result.
pass show "$PASS_PATH" | "${CMD[@]}"
