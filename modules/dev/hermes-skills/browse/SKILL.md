---
name: browse
description: "Drive the captain's real Windows Chrome for authenticated web tasks - navigate, read the accessibility tree, click, fill non-secret fields, run JS, inspect console/network, screenshot. Use for logged-in flows, JS-only apps, multi-step account/checkout processes, and researching how to operate an app. Prefer the chrome-devtools-axi CLI over the native browser_* tools."
annotation: "Real-browser operation via chrome-devtools-axi over the CDP proxy"
version: 1.0.0
user-invocable: false
metadata:
  hermes:
    tags: [browser, chrome, chrome-devtools-axi, cdp, web, research, automation]
    category: automation
---

# browse

Operate the captain's real, logged-in Windows Chrome for tasks that need a
browser. The browser is shared infrastructure - treat it like someone else's
machine you have been lent.

## Routing: do you actually need the browser?

1. If a plain `curl` / `fetch` answers it (public page, JSON API, static
   content), do that. Chrome is ~10x slower and it is the captain's real
   session.
2. If the page is blocked (403/429/paywall/WAF), try **recover-blocked-page**
   first - don't spend a Chrome session fighting a bot wall.
3. Use `browse` for: authenticated flows, JS-only single-page apps, anything
   that needs the captain's existing cookies/session, and step-by-step
   operation of a web UI.

## The browser you are driving

- A **persistent** Chrome behind a CDP proxy at `http://localhost:3333`. It is
  the captain's real profile - saved logins and sessions are live.
- The proxy launches Chrome lazily on the first CDP request and idle-stops it
  after ~1h. One tab/session; `open <url>` is safe to call repeatedly - it does
  **not** reset cookies (unlike the native `browser_navigate` tool).
- Downloads land on the **Windows** filesystem (the captain's Downloads
  folder), not in this WSL environment.

## Preferred tool: chrome-devtools-axi

Prefer the `chrome-devtools-axi` CLI over Hermes's native `browser_*` tools.
The native toolset stays enabled as a fallback (for `browser_vision` or if the
CLI is unavailable), but it truncates heavy snapshots and its `browser_navigate`
resets the session - the CLI does neither.

Invoke it attached to the proxy Chrome:

```sh
export CHROME_DEVTOOLS_AXI_BROWSER_URL=http://localhost:3333
npx -y chrome-devtools-axi <command>
```

(A later change adds a pinned wrapper that sets this env and does the warm-up
for you; until then, export it yourself.)

### Cold-start warm-up

`http://localhost:3333/json/version` is empty until a CDP request wakes Chrome,
and the CLI needs a `webSocketDebuggerUrl` there to attach. Nudge it awake
before the first command (safe and instant when Chrome is already up):

```sh
curl -s -X POST http://localhost:3335/show >/dev/null 2>&1 || true
for _ in $(seq 1 15); do
  curl -sf http://localhost:3333/json/version 2>/dev/null | grep -q webSocketDebuggerUrl && break
  sleep 1
done
```

If the first real command still fails to find a target, retry it once.

### AXI ergonomics (inherited from chrome-devtools-axi)

TOON output; combined `page: {...}` + `snapshot:` + `help[]` next-step hints;
`g<N>:` generation prefix on refs with `STALE_REF` detection on re-render;
`--full` to defeat truncation; `network-get --response-file <path>` to keep
response bodies out of context. Run `npx -y chrome-devtools-axi --help` for the
command list. Follow the `help[]` suggestions, invoking them with the same
`npx -y chrome-devtools-axi ...` prefix.

## Interaction discipline

- **Read the snapshot before acting.** Target elements by their `uid` ref, not
  guessed selectors.
- **Verify after every state-changing command.** `chrome-devtools-axi` catches
  stale refs, not valid-ref no-ops - re-`snapshot` or `eval document.title` /
  check the URL to confirm the step landed before the next one. Never fire a
  sequence of blind clicks.
- **A screenshot you report must be the page that was asked for.** Confirm the
  URL/title first.
- **Never put a credential into `fill` / `type` / `eval`** or any browser
  command. Password and OTP entry goes through **web-login**, which reads the
  secret internally so it never appears in a tool call.
- Expect popups, cookie banners, consent walls, multi-step wizards, and slow
  loads. Handle each deliberately.

## Web search

Hermes has no dedicated search tool. When a task needs a web search - commonly
"how do I do X in <Windows app>" - use this skill:

- Open a search engine results page with `chrome-devtools-axi open`
  (e.g. `https://duckduckgo.com/html/?q=<query>` renders without JS and
  snapshots cleanly), read the `snapshot`, then `open` the chosen result.
- Or `curl` a search endpoint directly if a plain fetch is enough.

Keep searches scoped to the task. (A first-class `search` route is a planned
follow-up.)

## Stop points

Capture a screenshot and return to firstmate - do not improvise past:

- a CAPTCHA or a hard bot-detection wall,
- a prompt for payment, a purchase confirmation, account deletion, or a
  consent/permission the assigned task did not authorize,
- anything that would send a message or change an account/system setting
  without explicit authorization (see **delegated-task**).

## Raw CDP escape hatch

For something the CLI does not cover, `chrome-devtools-axi eval` runs JS in the
page and `chrome-devtools-axi` exposes navigate/console/network as first-class
commands. Raw `browser_cdp` (native tool) remains available if you truly need a
protocol method directly.

## Related skills

- **web-login** - the only place a secret enters a page.
- **pass-access** - find the entry name and its fields before a login.
- **recover-blocked-page** - try before spending a Chrome session on a WAF.
- **operate-desktop** - the sibling skill when the task is a native Windows app.
- **delegated-task** - the scope and stop-point rules that govern this skill.
