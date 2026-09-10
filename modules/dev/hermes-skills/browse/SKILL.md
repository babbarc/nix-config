---
name: browse
description: "Drive the captain's real Windows Chrome for authenticated web tasks - navigate, read the accessibility tree, click, fill non-secret fields, run JS, inspect console/network, screenshot. Use for logged-in flows, JS-only apps, multi-step account/checkout processes, and researching how to operate an app. Prefer the `hermes-browse` wrapper (chrome-devtools-axi over the CDP proxy) over the native browser_* tools."
annotation: "Real-browser operation via hermes-browse (chrome-devtools-axi) over the CDP proxy"
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

## Preferred tool: `hermes-browse`

Prefer the `hermes-browse` wrapper over Hermes's native `browser_*` tools. It
runs the `chrome-devtools-axi` CLI attached to the proxy Chrome. The native
toolset stays enabled as a fallback (for `browser_vision` or if the wrapper is
unavailable), but it truncates heavy snapshots and its `browser_navigate`
resets the session - the CLI does neither.

```sh
hermes-browse <command> [args]
```

`hermes-browse` is a thin launcher. It does exactly three things and then hands
off to `chrome-devtools-axi` with your arguments untouched:

1. points the CLI at the CDP proxy (`CHROME_DEVTOOLS_AXI_BROWSER_URL=http://localhost:3333`),
2. cold-start warm-up: `http://localhost:3333/json/version` carries no
   `webSocketDebuggerUrl` until a CDP request wakes Chrome, so it POSTs
   `http://localhost:3335/show` and polls until the debugger URL appears
   (instant when Chrome is already up),
3. retries the command once if the first attempt cannot reach a CDP target
   (the bridge can briefly lag a just-woken Chrome).

You do not need to export any env var or run the warm-up yourself.

### AXI ergonomics (inherited from chrome-devtools-axi)

TOON output; combined `page: {...}` + `snapshot:` + `help[]` next-step hints;
`g<N>:` generation prefix on refs with `STALE_REF` detection on re-render;
`--full` to defeat truncation; `network-get --response-file <path>` to keep
response bodies out of context. Run `hermes-browse --help` for the command
list. Follow the `help[]` suggestions, invoking them with the same
`hermes-browse ...` prefix.

## Interaction discipline

- **Read the snapshot before acting.** Target elements by their `uid` ref, not
  guessed selectors.
- **Verify after every state-changing command.** The CLI catches stale refs,
  not valid-ref no-ops - re-`snapshot` or `eval document.title` / check the URL
  to confirm the step landed before the next one. Never fire a sequence of
  blind clicks.
- **A screenshot you report must be the page that was asked for.** Confirm the
  URL/title first.
- **Never put a credential into `fill` / `type` / `eval`** or any browser
  command. Password and OTP entry goes through **web-login**, which reads the
  secret internally so it never appears in a tool call.
- Expect popups, cookie banners, consent walls, multi-step wizards, and slow
  loads. Handle each deliberately.

## Web search

Use the native **`web_search`** tool for searches - commonly "how do I do X in
<Windows app>". It is wired to a keyless DuckDuckGo backend (the `web-ddgs`
plugin), so it needs no browser session and does not spend the captain's real
Chrome on a lookup. Follow up with `web_extract` or a plain `curl` to read a
result page.

Fall back to a browser SERP only when the results you need are login-walled
(behind an account, a corporate wiki, etc.): `hermes-browse open` a results
page that renders without JS (e.g. `https://duckduckgo.com/html/?q=<query>`),
read the `snapshot`, then `open` the chosen result.

Keep searches scoped to the task.

## Stop points

Capture a screenshot and return to the dispatcher - do not improvise past:

- a CAPTCHA or a hard bot-detection wall,
- a prompt for payment, a purchase confirmation, account deletion, or a
  consent/permission the assigned task did not authorize,
- anything that would send a message or change an account/system setting
  without explicit authorization (see **delegated-task**).

## Raw CDP escape hatch

For something the CLI does not cover, `hermes-browse eval` runs JS in the page,
and `hermes-browse` exposes navigate/console/network as first-class commands.
Raw `browser_cdp` (native tool) remains available if you truly need a protocol
method directly.

## Related skills

- **web-login** - the only place a secret enters a page.
- **pass-access** - find the entry name and its fields before a login.
- **recover-blocked-page** - try before spending a Chrome session on a WAF.
- **operate-desktop** - the sibling skill when the task is a native Windows app.
- **delegated-task** - the scope and stop-point rules that govern this skill.
