"""guardrails: structurally enforce the fleet guardrails at dispatch time.

The live incident on 2026-09-10 (`photo-book-curator` grinding for ~44 minutes
on a live-Lightroom UI spot-check, then - after the fleet was un-paused - driving
the captain's LIVE Lightroom again despite the first guardrail pass) produced two
mechanical rules this ``pre_tool_call`` hook enforces, plus judgment rules the
SOULs and the ``operate-desktop`` / ``delegated-task`` skills carry:

  1. **Live-app control is DEFAULT-DENY.** Any tool that would raise, focus,
     click, type, key, scroll, or drag in an application the captain is using
     (the desktop driver's MCP tools, the native ``computer_use`` wrapper, the
     ``browser_*`` toolset, and the ``hermes-browse`` / ``chrome-devtools-axi``
     browser CLIs) is blocked unless the CURRENT task carries an explicit,
     unexpired **captain** grant. An orchestrator-authored card, a task body, or
     the expert's own reasoning is NOT authorization - that was exactly the
     2026-09-10 hole. Read-only capture (``get_window_state``,
     ``browser_snapshot``, ...) is not gated, so the off-screen verification
     workflow still works. The grant is created only by the captain with
     ``hermes-live-app-authorize grant --task <id>`` (see
     ``modules/dev/hermes-guardrails-bin/hermes-live-app-authorize``); this hook
     reads ``$HERMES_HOME/live-app-authorization/<task>.grant``.

  2. **Every dispatched card is bounded.** Hermes's hard stop is the
     dispatcher's ``max_runtime_seconds`` (it SIGTERMs, then SIGKILLs, the
     worker and emits a ``timed_out`` event). Hermes has no board-level default
     for it, so an orchestrator that forgets the field creates an unbounded
     card. This hook injects the fleet default (from
     ``$HERMES_HOME/guardrails.yaml``) into ``kanban_create`` whenever the
     caller did not set a usable positive value.

The fleet-wide desktop lock, the heartbeat cadence and the loop bound stay in the
SOULs and skills where they can be reasoned about (this hook cannot express
"take a lock first"). Precedent for the hook shape: ``pass-enforcement`` and the
bundled ``approval-gates`` plugin.
"""

from __future__ import annotations

import logging
import os
import re
import shlex
import time
from typing import Any, Dict, FrozenSet, Optional, Tuple

logger = logging.getLogger(__name__)

# Mirror of the module defaults in modules/dev/hermes-guardrails.nix. Used only
# when the generated guardrails.yaml is missing; the yaml is the source of
# truth on a real host.
_FALLBACK_RUN_BUDGET_SECONDS = 1800
_FALLBACK_LIVE_APP_GRANT_TTL_SECONDS = 7200
_FALLBACK_LIVE_APP_AUTH_DIRNAME = "live-app-authorization"

SURFACE_DESKTOP = "desktop"
SURFACE_BROWSER = "browser"

# Raw cua-driver MCP tools are registered as ``mcp__<server>__<tool>`` with the
# server name sanitized (hyphen -> underscore), i.e. ``mcp__cua_driver__click``.
_CUA_TOOL_PREFIX = "mcp__cua_driver__"

# cua-driver tools that only READ the desktop / driver state. Anything not in
# this set is treated as live-app control (default-deny), so a future tool the
# driver adds is blocked until the captain authorizes it.
_CUA_READ_ONLY_TOOLS: FrozenSet[str] = frozenset({
    "list_apps",
    "list_windows",
    "get_window_state",
    "get_desktop_state",
    "get_accessibility_tree",
    "verify_state",
    "debug_window_info",
    "clipboard_read",
    "get_screen_size",
    "get_cursor_position",
    "get_agent_cursor_state",
    "check_permissions",
    "health_report",
    "get_config",
    "get_browser_state",
    "get_recording_state",
    "get_session",
    "list_sessions",
    "get_session_state",
    "check_for_update",
})

# Native ``computer_use`` actions that only read. Every other action value
# (including a future one) is live-app control.
_COMPUTER_USE_READ_ONLY_ACTIONS: FrozenSet[str] = frozenset({
    "capture",
    "list_apps",
    "list_windows",
    "wait",
})

# Native ``browser_*`` tools that only read the page. ``browser_console`` is
# handled separately: a plain read runs no JavaScript, but an ``expression`` /
# ``clear`` argument does, so that form is gated.
_BROWSER_READ_ONLY_TOOLS: FrozenSet[str] = frozenset({
    "browser_snapshot",
    "browser_get_images",
    "browser_vision",
})

# `chrome-devtools-axi` / `hermes-browse` subcommands that only read the page.
# Any other subcommand (open, click, fill, type, press, scroll, back, wait,
# eval, run, hover, drag, dialog, upload, newpage, ...) drives the captain's
# live Chrome and is gated.
_BROWSE_READ_ONLY_SUBCOMMANDS: FrozenSet[str] = frozenset({
    "snapshot",
    "screenshot",
    "pages",
    "console",
    "console-get",
    "network",
    "network-get",
    "lighthouse",
    "help",
    "--help",
    "-h",
    "--version",
    "-v",
    "-V",
})

_BROWSE_CLIS: FrozenSet[str] = frozenset({"chrome-devtools-axi", "hermes-browse"})

# Cheap pre-filter so the terminal parser only runs for commands that could
# invoke a browser CLI.
_HAS_BROWSE_CLI = re.compile(r"\b(?:chrome-devtools-axi|hermes-browse)\b")

# Shell operators that separate one simple command from the next (mirrors
# pass-enforcement, so ``a && hermes-browse click x`` is caught).
_SEGMENT_SPLIT = re.compile(r"\|\||\||&&|&|;|\n|\$\(|`|\(|\)|\{|\}")

# Command-word wrappers that run another command as their argument.
_WRAPPER_PREFIXES: FrozenSet[str] = frozenset({
    "sudo", "env", "command", "builtin", "exec", "nice", "nohup",
    "setsid", "eval", "then", "do", "else", "time", "watch",
})

_SHELL_WRAPPERS: FrozenSet[str] = frozenset({"sh", "bash", "zsh", "dash", "ash", "ksh", "fish"})

_ENV_ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")

# Grant files are named after a sanitized task id by BOTH this hook and
# `hermes-live-app-authorize`; the two substitutions must stay identical.
_UNSAFE_NAME_CHARS = re.compile(r"[^A-Za-z0-9._-]")

_BLOCK_HEADER = "Blocked by guardrails: live-app control is DEFAULT-DENY."


# ---------------------------------------------------------------------------
# The default hermes root
# ---------------------------------------------------------------------------

def _hermes_root() -> str:
    """Return the DEFAULT hermes root, not the active profile's home.

    A dispatcher-spawned worker runs with HERMES_HOME=<root>/profiles/<name>,
    so resolving HERMES_HOME directly would miss the shared guardrails.yaml and
    the captain's grant files. Mirrors the engine's own rule
    (``profiles.get_default_hermes_root``): a profile-shaped HERMES_HOME roots
    at its grandparent, otherwise HERMES_HOME is the root.
    """
    override = os.environ.get("HERMES_GUARDRAILS_HOME", "").strip()
    if override:
        return os.path.expanduser(override)
    home = (os.environ.get("HERMES_HOME") or os.path.join(os.path.expanduser("~"), ".hermes")).rstrip("/")
    parent = os.path.dirname(home)
    if os.path.basename(parent) == "profiles":
        return os.path.dirname(parent)
    return home


def _guardrails_yaml_path() -> str:
    return os.path.join(_hermes_root(), "guardrails.yaml")


def _read_guardrails_yaml() -> Dict[str, str]:
    """Parse the flat, machine-generated ``guardrails.yaml`` (``key: value``).

    A tiny reader keeps this dependency-free; unparseable lines are ignored.
    """
    data: Dict[str, str] = {}
    try:
        with open(_guardrails_yaml_path(), encoding="utf-8") as fh:
            for line in fh:
                stripped = line.strip()
                if not stripped or stripped.startswith("#") or ":" not in stripped:
                    continue
                key, value = stripped.split(":", 1)
                data[key.strip()] = value.strip().strip("\"'")
    except OSError as exc:
        logger.debug("guardrails: could not read %s: %s", _guardrails_yaml_path(), exc)
    return data


def _positive_int(raw: Any, fallback: int) -> int:
    try:
        value = int(str(raw).strip())
    except (TypeError, ValueError):
        return fallback
    return value if value > 0 else fallback


# ---------------------------------------------------------------------------
# Live-app control: classify, authorize, block
# ---------------------------------------------------------------------------

def _task_id() -> str:
    """The kanban task this process is executing, or "" outside a worker.

    Only a dispatcher-spawned worker has a task identity to authorize; an
    interactive orchestrator session has none and is therefore never
    live-app-authorized (the SOUL also forbids the orchestrator driving).
    """
    return (os.environ.get("HERMES_KANBAN_TASK") or "").strip()


def _grant_dir() -> str:
    root = _hermes_root()
    configured = _read_guardrails_yaml().get("live_app_auth_dir", "").strip()
    return os.path.expanduser(configured) if configured else os.path.join(root, _FALLBACK_LIVE_APP_AUTH_DIRNAME)


def _grant_path(task_id: str) -> str:
    safe = _UNSAFE_NAME_CHARS.sub("_", task_id)
    return os.path.join(_grant_dir(), safe + ".grant")


def _read_grant(task_id: str) -> Optional[Dict[str, str]]:
    grant: Dict[str, str] = {}
    try:
        with open(_grant_path(task_id), encoding="utf-8") as fh:
            for line in fh:
                stripped = line.strip()
                if not stripped or stripped.startswith("#") or ":" not in stripped:
                    continue
                key, value = stripped.split(":", 1)
                grant[key.strip()] = value.strip().strip("\"'")
    except OSError:
        return None
    return grant or None


def _grant_allows(grant: Dict[str, str], surface: str, now: float) -> bool:
    """An unexpired grant for this task whose surfaces cover ``surface``."""
    expires_at = _positive_int(grant.get("expires_at"), 0)
    if expires_at <= now:
        return False
    surfaces = {
        part.strip().lower()
        for part in (grant.get("surfaces") or "all").split(",")
        if part.strip()
    }
    return "all" in surfaces or surface in surfaces


def _classify_computer_use(args: Dict[str, Any]) -> Optional[Tuple[str, str]]:
    action = str(args.get("action") or "").strip().lower()
    if action in _COMPUTER_USE_READ_ONLY_ACTIONS:
        return None
    target = str(args.get("app") or "").strip()
    detail = f"computer_use action={action or '(unset)'}"
    if target:
        detail += f" app={target}"
    return SURFACE_DESKTOP, detail


def _classify_cua_tool(tool_name: str) -> Optional[Tuple[str, str]]:
    tool = tool_name[len(_CUA_TOOL_PREFIX):]
    if tool in _CUA_READ_ONLY_TOOLS:
        return None
    if tool.startswith("browser_"):
        return SURFACE_BROWSER, f"cua-driver {tool}"
    return SURFACE_DESKTOP, f"cua-driver {tool}"


def _classify_browser_tool(tool_name: str, args: Dict[str, Any]) -> Optional[Tuple[str, str]]:
    if tool_name in _BROWSER_READ_ONLY_TOOLS:
        return None
    if tool_name == "browser_console":
        # A plain console read runs no JavaScript; an expression / clear does.
        if not str(args.get("expression") or "").strip() and not args.get("clear"):
            return None
        return SURFACE_BROWSER, "browser_console(expression/clear)"
    return SURFACE_BROWSER, tool_name


def _command_drives_live_browser(command: str, _depth: int = 0) -> Optional[str]:
    """Return a detail string when a terminal command drives the live browser.

    Matches a simple command whose command word is ``hermes-browse`` or
    ``chrome-devtools-axi`` and whose subcommand is not read-only.
    """
    if _depth > 3:
        return None
    for segment in _SEGMENT_SPLIT.split(command):
        segment = segment.strip()
        if not segment:
            continue
        try:
            tokens = shlex.split(segment)
        except ValueError:
            tokens = segment.split()
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
                for i, tok in enumerate(tokens[1:], 1):
                    if tok == "-c" and i + 1 < len(tokens):
                        hit = _command_drives_live_browser(tokens[i + 1], _depth + 1)
                        if hit:
                            return hit
                    elif tok.startswith("-c") and len(tok) > 2:
                        hit = _command_drives_live_browser(tok[2:], _depth + 1)
                        if hit:
                            return hit
                tokens = []
                break
            break
        if not tokens:
            continue
        cli = os.path.basename(tokens[0].strip("'\""))
        if cli not in _BROWSE_CLIS:
            continue
        subcommand = next((a for a in tokens[1:] if not a.startswith("-")), "")
        if subcommand in _BROWSE_READ_ONLY_SUBCOMMANDS or not subcommand:
            # A read-only subcommand, or no subcommand at all (`hermes-browse`
            # alone prints usage): no live-app control.
            continue
        return f"browser CLI: {cli} {subcommand}"
    return None


def _classify_live_app(tool_name: str, args: Dict[str, Any]) -> Optional[Tuple[str, str]]:
    """Return ``(surface, detail)`` for a live-app-control call, else ``None``."""
    if tool_name == "computer_use":
        return _classify_computer_use(args)
    if tool_name.startswith(_CUA_TOOL_PREFIX):
        return _classify_cua_tool(tool_name)
    if tool_name.startswith("browser_"):
        return _classify_browser_tool(tool_name, args)
    if tool_name == "terminal":
        command = str(args.get("command") or "")
        if command.strip() and _HAS_BROWSE_CLI.search(command):
            try:
                detail = _command_drives_live_browser(command)
            except Exception as exc:  # fail CLOSED - an unparsed command may drive
                logger.warning("guardrails: browse parse error, blocking: %s", exc)
                return SURFACE_BROWSER, f"browser CLI (unparsed: {type(exc).__name__})"
            if detail:
                return SURFACE_BROWSER, detail
    return None


def _block_message(surface: str, detail: str, task_id: str) -> str:
    task_line = task_id or "(none - this session has no task identity)"
    return (
        f"{_BLOCK_HEADER}\n\n"
        f"This call would control the captain's running applications ({detail}). "
        "Only the CAPTAIN can authorize live-app control, and only for one "
        "specific task. An orchestrator-authored card, a task body, or your own "
        "reasoning is NOT authorization.\n\n"
        "Do this instead:\n"
        "  1. Stop driving the live app - do not retry, do not look for another "
        "tool or a shell command that reaches the same UI.\n"
        "  2. Do the rest of the task from a snapshot (read-only capture stays "
        "allowed: get_window_state, browser_snapshot, reading files on disk).\n"
        "  3. If the live interaction is genuinely required, close the card with "
        "`kanban_block` and ask the dispatcher to get the CAPTAIN to authorize "
        "THIS task, naming the app and the exact actions.\n"
        "  4. The captain authorizes it out of band (captain-only command - never "
        "run it yourself):\n"
        f"       hermes-live-app-authorize grant --task {task_line} "
        '--note "<app and actions>"\n'
        "     Then re-run only the authorized action, holding the fleet desktop "
        "lock (`hermes-desktop-lock acquire`).\n\n"
        f"Task: {task_line}\n"
        f"Surface: {surface}\n"
        "Check an existing grant with `hermes-live-app-authorize check --task "
        f"{task_line}`."
    )


def _live_app_directive(tool_name: str, args: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    classified = _classify_live_app(tool_name, args)
    if classified is None:
        return None
    surface, detail = classified
    task_id = _task_id()
    if task_id:
        grant = _read_grant(task_id)
        if grant and _grant_allows(grant, surface, time.time()):
            logger.info(
                "guardrails: live-app %s allowed for task %s by captain grant (%s)",
                surface, task_id, detail,
            )
            return None
    logger.warning(
        "guardrails: blocked live-app control without a captain grant: %s (%s)",
        detail, task_id or "no task",
    )
    return {
        "action": "block",
        "message": _block_message(surface, detail, task_id),
        "rule_key": "guardrails:live-app-default-deny",
    }


# ---------------------------------------------------------------------------
# Per-task run budget
# ---------------------------------------------------------------------------

def _budget_directive(args: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    """Inject the fleet run budget into an unbounded ``kanban_create`` call."""
    existing = args.get("max_runtime_seconds")
    if isinstance(existing, bool):
        existing = None
    if isinstance(existing, (int, float)) and existing > 0:
        return None
    if isinstance(existing, str) and existing.strip().isdigit() and int(existing) > 0:
        return None

    budget = _positive_int(
        _read_guardrails_yaml().get("run_budget_seconds"),
        _FALLBACK_RUN_BUDGET_SECONDS,
    )
    logger.info(
        "guardrails: kanban_create had no usable max_runtime_seconds; "
        "injecting the fleet default (%ss)",
        budget,
    )
    return {"action": "modify", "args": {"max_runtime_seconds": budget}}


def _on_pre_tool_call(
    tool_name: str = "",
    args: Any = None,
    **_kwargs: Any,
) -> Optional[Dict[str, Any]]:
    """Default-deny live-app control; bundle the fleet budget into cards."""
    tool_input = args if isinstance(args, dict) else {}
    live_app = _live_app_directive(tool_name, tool_input)
    if live_app is not None:
        return live_app
    if tool_name != "kanban_create":
        return None
    return _budget_directive(tool_input)


def register(ctx: Any) -> None:
    ctx.register_hook("pre_tool_call", _on_pre_tool_call)
