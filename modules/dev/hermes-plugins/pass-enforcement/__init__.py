"""pass-enforcement: structurally block the secret-dumping ``pass`` forms.

The ``pre_tool_call`` hook vetoes any ``terminal`` command that would print a
``pass`` entry's first line (the secret) to stdout - i.e. into the model's
context / the transcript:

    pass show <path>          # explicit
    pass <path>               # bare path - `pass` treats this as `show`
    pass -c <path>            # `show -c`: also exfiltrates (clipboard)
    pass -q <path>            # `show -q`: QR of the secret to stdout

It is deliberately precise so the sanctioned paths keep working. It does NOT
block:

  * ``pass-axi`` / ``pass-to`` / ``pass-env`` / ``pass-inspect`` (the wrappers)
  * ``pass otp <path>`` (the pass-otp extension - prints only the code)
  * ``pass ls|list|find|search|grep|insert|add|edit|generate|mv|cp|rm|git|init``
  * ``pass`` with no args, ``pass --help`` / ``pass --version``
  * ``hermes-web-login`` / ``recover-page`` / ``pass-axi`` and any unrelated
    command that merely contains the word "pass"

Why a plugin and not a config shell hook: the config ``hooks:`` shell-hook
mechanism only accepts ``block`` / ``modify`` for ``pre_tool_call``; that is
enough here (this rule only needs ``block``), but a plugin hook keeps the
enforcement in one repo-tracked, testable unit and matches the bundled
``approval-gates`` precedent. The directive shape is documented in
``hermes_cli.plugins._get_pre_tool_call_directive_details``.
"""

from __future__ import annotations

import logging
import os
import re
import shlex
from typing import Any, Dict, List, Optional

logger = logging.getLogger(__name__)

# ``pass`` subcommands that never write the secret (entry line 1) to stdout.
# A bare ``pass`` (tree listing) and ``pass show`` are deliberately absent.
_SAFE_PASS_SUBCOMMANDS = frozenset({
    "init", "ls", "list", "find", "search", "grep",
    "insert", "add", "edit", "generate",
    "mv", "rename", "cp", "copy", "rm", "remove", "delete",
    "git", "otp", "help", "version",
})

# Flags that, on a bare ``pass <path>`` (== ``pass show <path>``), still move
# the secret off the machine (clipboard / QR on stdout).
_SHOW_EXFIL_FLAGS = frozenset({"-c", "--clip", "-q", "--qrcode"})

# Shell operators that separate one simple command from the next. Splitting on
# these reduces ``pass show x | head -1``, ``a && pass show x``, ``$(pass show
# x)`` etc. to a segment whose command word is ``pass``.
_SEGMENT_SPLIT = re.compile(r"\|\||\||&&|&|;|\n|\$\(|`|\(|\)|\{|\}")

# Command-word wrappers that run another command as their argument.
_WRAPPER_PREFIXES = frozenset({
    "sudo", "env", "command", "builtin", "exec", "nice", "nohup",
    "setsid", "eval", "then", "do", "else", "time", "watch",
})

_SHELL_WRAPPERS = frozenset({"sh", "bash", "zsh", "dash", "ash", "ksh", "fish"})

_ENV_ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")

# Cheap pre-filter: `pass` present as a whole word somewhere (so `password`,
# `passphrase`, `passwd` are skipped, but `/usr/bin/pass` and `pass-axi` are
# not - the real parser below rejects the wrapper names precisely). Only when
# this matches do we do the full parse.
_HAS_PASS_WORD = re.compile(r"\bpass\b")

_BLOCK_MESSAGE = (
    "Blocked by pass-enforcement: `pass show <path>` / bare `pass <path>` "
    "prints the entry's first line (the secret) straight to stdout and into "
    "this transcript. This Hermes instance forbids that form structurally.\n"
    "Use the sanctioned paths instead - the secret never reaches stdout:\n"
    "  - Entry METADATA (login / url / otpauth): `pass-axi inspect <path>`  "
    "(pass-access skill)\n"
    "  - Put a credential or OTP into a web form: `hermes-web-login <path>`  "
    "(web-login skill)\n"
    "  - Names / tree / OTP code only: `pass-axi find <term>`, `pass-axi ls`, "
    "`pass-axi otp <path>`\n"
    "Never dump the secret value into context."
)


def _pass_invocation_dumps_secret(tokens: List[str]) -> bool:
    """``tokens`` is a shell-split simple command whose command word is ``pass``."""
    args = tokens[1:]
    if not args:
        return False  # bare `pass` -> tree listing
    first = args[0]
    non_flag = [a for a in args if not a.startswith("-")]
    if first == "show":
        # `pass show` alone == tree listing; `pass show <path>` dumps.
        return len(non_flag) > 1
    if first.startswith("-"):
        if first in _SHOW_EXFIL_FLAGS:
            # `pass -c <path>` == `pass show -c <path>`.
            return bool(non_flag)
        return False  # `pass --help`, `pass --version`, ...
    if first in _SAFE_PASS_SUBCOMMANDS:
        return False
    # `first` is a bare entry path -> `pass <path>` == `pass show <path>`.
    return True


def _command_dumps_pass_secret(command: str, _depth: int = 0) -> bool:
    if _depth > 3:
        return False
    for segment in _SEGMENT_SPLIT.split(command):
        segment = segment.strip()
        if not segment:
            continue
        try:
            tokens = shlex.split(segment)
        except ValueError:
            tokens = segment.split()
        # Strip leading env assignments and command wrappers.
        while tokens:
            head = tokens[0]
            if _ENV_ASSIGN.match(head):
                tokens.pop(0)
                continue
            base = os.path.basename(head.strip("'\""))
            if base in _WRAPPER_PREFIXES:
                tokens.pop(0)
                continue
            if base in _SHELL_WRAPPERS:
                # `bash -c "pass show x"` - recurse into the -c payload.
                for i, tok in enumerate(tokens[1:], 1):
                    if tok == "-c" and i + 1 < len(tokens):
                        if _command_dumps_pass_secret(tokens[i + 1], _depth + 1):
                            return True
                    elif tok.startswith("-c") and len(tok) > 2:
                        if _command_dumps_pass_secret(tok[2:], _depth + 1):
                            return True
                tokens = []
                break
            break
        if not tokens:
            continue
        if os.path.basename(tokens[0].strip("'\"")) != "pass":
            continue
        if _pass_invocation_dumps_secret(tokens):
            return True
    return False


def _on_pre_tool_call(
    tool_name: str = "",
    args: Any = None,
    **_kwargs: Any,
) -> Optional[Dict[str, Any]]:
    """Veto a ``terminal`` command that would dump a ``pass`` secret to stdout."""
    if tool_name != "terminal":
        return None
    tool_input = args if isinstance(args, dict) else {}
    command = str(tool_input.get("command") or "")
    if not command.strip() or not _HAS_PASS_WORD.search(command):
        return None
    try:
        hit = _command_dumps_pass_secret(command)
    except Exception as exc:  # never brick the terminal on a parser bug
        logger.debug("pass-enforcement: parse error, allowing: %s", exc)
        return None
    if not hit:
        return None
    return {
        "action": "block",
        "message": _BLOCK_MESSAGE,
        "rule_key": "pass-enforcement:no-secret-dump",
    }


def register(ctx: Any) -> None:
    ctx.register_hook("pre_tool_call", _on_pre_tool_call)
