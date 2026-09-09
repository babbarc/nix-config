---
name: operate-desktop
description: "Operate the Windows desktop through the cua-driver MCP tools with an observe -> act -> verify loop - read the accessibility tree first, target elements by index not pixels, expect popups and multi-step wizards, and never type a secret through type_text. Use for native Windows apps (Lightroom, installers, settings panes, file dialogs)."
annotation: "Windows desktop operation via cua-driver (guide only)"
version: 1.0.0
user-invocable: false
metadata:
  hermes:
    tags: [desktop, windows, cua-driver, computer-use, mcp, automation]
    category: automation
---

# operate-desktop

Drive the Windows desktop like a careful human. This is a **guide** - the
capability is the `cua-driver` MCP tools, already registered; there is no CLI
wrapper.

## Tools

`cua-driver` (registered as a Hermes MCP server, reached over `powershell.exe`
interop) exposes: `get_window_state` / `get_desktop_state` / `list_apps` /
`list_windows`, `click` / `double_click` / `right_click` (by `element_index`
or `x,y`), `type_text` / `press_key` / `hotkey`, `scroll` / `drag`,
`set_value`, `zoom`, `launch_app` / `bring_to_front`, `invoke_menu`,
`verify_state`, `clipboard_read` / `clipboard_write`.

Hermes's native `computer_use` toolset is also enabled. Prefer the
**`cua-driver` MCP tools** - that path is the one explicitly wired for this
host. Do not mix the two mid-task.

`cua-driver` is GUI/desktop only - no shell, filesystem, or registry. For
those, use the terminal directly (`/mnt/c`, `powershell.exe` are reachable
from this WSL environment).

## The loop: observe -> act -> verify

1. **Observe first.** `get_window_state` (or `get_desktop_state` for a fast
   overview) before any action. Read the structured `elements[]` and the
   markdown accessibility tree. Request the screenshot **only** when the pixels
   matter (visual layout, a rendered image, a canvas) - pass the
   screenshot-omit option otherwise to save tokens.
2. **Target by `element_index`**, not `x,y`, whenever the tree has the element -
   it survives layout shifts. `x,y` is the fallback.
3. **Act, then verify, then move on.** After each action, `verify_state` with a
   bounded predicate (or a fresh `get_window_state` narrowed with `query`)
   before the next step. Never fire a sequence of blind clicks.
4. **Expect the mess.** Popups, modal dialogs, permission prompts, UAC,
   installer/wizard pages, slow loads - handle each deliberately.
5. **Menus:** `invoke_menu` with the exact path rather than hunting the menu
   bar by click.
6. **Windows:** `list_windows` / `bring_to_front` to focus the right window
   before acting or screenshotting.

## Credentials on the desktop

The `pass` rules still apply. `cua-driver`'s `type_text` / `set_value` take the
text as an **MCP parameter**, so typing a secret that way leaks it into the
tool-call record. Do not. Instead:

- `pass -c <path>` copies the secret to the clipboard for ~45s; paste it with
  `hotkey Ctrl V` (or `clipboard_write` fed from a piped read), then clear the
  clipboard.
- Or bounce to firstmate if that is not workable.

See **pass-access** and **web-login**.

## Researching an unfamiliar app

If you do not know how to do something in a Windows app, use **browse** to web
search ("how to X in <app>") before poking at the UI blindly.

## Stop points

Same as **browse**: purchases, sends, deletions, and account/system setting
changes are gated on explicit task authorization. Prefer the reversible path;
if unsure whether a step can be undone, treat it as irreversible. Capture a
screenshot and return to firstmate rather than improvising.

## Related skills

- **browse** - the sibling skill when the task lives in a web app.
- **pass-access** / **web-login** - credentials.
- **delegated-task** - the scope and gate rules that govern this skill.
