"""guardrails: structurally apply the fleet guardrail defaults at dispatch time.

The live incident on 2026-09-10 (`photo-book-curator` grinding for ~44 minutes
on a live-Lightroom UI spot-check with no interim report) produced three fleet
rules. Two are judgment rules the SOULs and the `operate-desktop` /
`delegated-task` skills carry:

  * never drive the captain's live applications without an explicit task-level
    instruction (default: read-only verification from a snapshot), and
  * take the fleet-wide desktop lock before any live-app interaction, because a
    visible/focused desktop is one shared resource.

The third is mechanical and this plugin enforces it: every dispatched card
carries a per-task run budget. Hermes's hard stop is the dispatcher's
``max_runtime_seconds`` (it SIGTERMs, then SIGKILLs, the worker and emits a
``timed_out`` event). Hermes has no board-level default for it, so an
orchestrator that forgets the field creates an unbounded card. This
``pre_tool_call`` hook injects the fleet default (from
``$HERMES_HOME/guardrails.yaml``) into ``kanban_create`` whenever the caller did
not set a usable value, so a card can never be dispatched unbounded.

It deliberately does NOT block: an explicit positive ``max_runtime_seconds``
always wins, and the desktop-lock / live-app / heartbeat / loop rules stay in
the SOULs and skills where they can be reasoned about. Precedent for the hook
shape: ``pass-enforcement`` and the bundled ``approval-gates`` plugin.
"""

from __future__ import annotations

import logging
import os
from typing import Any, Dict, Optional

logger = logging.getLogger(__name__)

# Mirror of the module default in modules/dev/hermes-guardrails.nix. Used only
# when the generated guardrails.yaml is missing; the yaml is the source of
# truth on a real host.
_FALLBACK_RUN_BUDGET_SECONDS = 1800

_YAML_KEY = "run_budget_seconds"


def _hermes_root() -> str:
    """Return the DEFAULT hermes root, not the active profile's home.

    A dispatcher-spawned worker runs with HERMES_HOME=<root>/profiles/<name>,
    so resolving HERMES_HOME directly would miss the shared guardrails.yaml.
    Mirrors the engine's own rule (``profiles.get_default_hermes_root``): a
    profile-shaped HERMES_HOME roots at its grandparent, otherwise HERMES_HOME
    is the root.
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


def _read_run_budget() -> int:
    """Return the fleet default run budget in seconds.

    Reads the flat, machine-generated ``guardrails.yaml`` (one ``key: value``
    per line) so no yaml dependency is needed. Falls back to the module default
    if the file is absent or malformed.
    """
    path = _guardrails_yaml_path()
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                stripped = line.strip()
                if not stripped or stripped.startswith("#"):
                    continue
                if stripped.startswith(_YAML_KEY + ":"):
                    raw = stripped.split(":", 1)[1].strip().strip("\"'")
                    value = int(raw)
                    if value > 0:
                        return value
                    break
    except (OSError, ValueError) as exc:
        logger.debug("guardrails: could not read %s: %s", path, exc)
    return _FALLBACK_RUN_BUDGET_SECONDS


def _on_pre_tool_call(
    tool_name: str = "",
    args: Any = None,
    **_kwargs: Any,
) -> Optional[Dict[str, Any]]:
    """Inject the fleet run budget into an unbounded ``kanban_create`` call."""
    if tool_name != "kanban_create":
        return None
    tool_input = args if isinstance(args, dict) else {}

    existing = tool_input.get("max_runtime_seconds")
    if isinstance(existing, bool):
        existing = None
    if isinstance(existing, (int, float)) and existing > 0:
        return None
    if isinstance(existing, str) and existing.strip().isdigit() and int(existing) > 0:
        return None

    budget = _read_run_budget()
    logger.info(
        "guardrails: kanban_create had no usable max_runtime_seconds; "
        "injecting the fleet default (%ss)",
        budget,
    )
    return {"action": "modify", "args": {"max_runtime_seconds": budget}}


def register(ctx: Any) -> None:
    ctx.register_hook("pre_tool_call", _on_pre_tool_call)
