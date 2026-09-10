---
name: recover-blocked-page
description: "Use when a fetch fails - 403/429, paywall, WAF, Cloudflare 'Just a moment...', a bot-detection interstitial. Work down the archive ladder (Wayback -> archive.today -> reader -> API/RSS/sitemap pivot -> browser as last resort), keep provenance, and reject fake successes. Try this before spending a real browser session on a blocked page."
annotation: "Recover a blocked/paywalled page via the archive ladder"
version: 1.0.0
user-invocable: false
metadata:
  hermes:
    tags: [research, archives, wayback, paywall, waf, fallback]
    category: research
---

# recover-blocked-page

A page won't fetch - 403/429, a paywall, a WAF, a bot interstitial. Don't loop
on the same URL and don't give up. Third parties usually hold a **copy**. Work
down this ladder, cheapest first, and record which route produced the content.

## The ladder

```
1. Wayback Machine  - archive.org "available" API (snapshot URL + timestamp)
2. archive.today    - domain rotation: archive.ph -> .md -> .li -> .is
3. Reader endpoint  - a text-extraction reader proxy (needs its API key set)
4. API / feed pivot - the site's own JSON API, RSS/Atom feed, or sitemap
5. Browser          - `browse` as the LAST resort (real session, slow)
```

## The tool: `recover-page` (use this first)

```
recover-page <url>          # -> ok: {route, provenance, snapshot_date, saved: <path>}
recover-page <url> --json   # full route trace
recover-page --help         # the ladder, the output shape, exit codes
```

`recover-page` wraps `recover_page.py` - the **canonical Hermes-core recovery
script** (MIT, vendored byte-identical in this repo, not a bespoke port). It
walks routes 1-3 of the ladder in one shot, validates every body (see "Reject
fake successes"), and:

- writes the page body to a **file** (`saved:`), never into context;
- carries provenance + snapshot date in the output, so a report can cite
  "as archived <date>" correctly;
- on a `snapshot` hit, prints a `help[]` snapshot-age line - if the task needs
  **current** values, say so to the dispatcher rather than passing stale data
  as live;
- on total failure prints `ALL_ROUTES_FAILED - tried wayback,
  archive.today(x4), api-pivot` with the route trace - never an empty file;
- exit `0` recovered · `1` no route worked / operational error · `2` bad usage.

Routes 4 (API / feed pivot) and 5 (browser) are **not** in the script - do them
by hand, in that order, only after `recover-page` reports `ALL_ROUTES_FAILED`.

## Fallback ladder (only after `recover-page` fails)

1. **Wayback:**
   `curl -s "https://archive.org/wayback/available?url=<url>"` - if
   `archived_snapshots.closest.available` is true, fetch `.url` and note
   `.timestamp`. (`recover-page` already tries this - only re-run by hand to
   debug.)
2. **archive.today:** try `https://archive.ph/newest/<url>`, then `.md`, `.li`,
   `.is` (they rotate/block independently). Fetch the resulting snapshot.
3. **Reader proxy:** if a reader/extraction endpoint and its key are
   configured, request the URL through it.
4. **API / feed pivot:** look for `/api/`, `?format=json`, `/feed`, `/rss`,
   `/sitemap.xml` on the same host - often unguarded.
5. **Browser:** only now, hand off to **browse**.

## Reject fake successes

A 200 response is not success. Discard and continue the ladder if the body is:

- a dead Google-cache / "page not found" stub,
- an AMP or consent-wall shell with no article text,
- a rate-limit / "are you a robot" body echoed with status 200,
- shorter than a plausible version of the real content.

## Provenance discipline

Always carry where the content came from and its date into the outcome report.
If the task needs **current** values and all you have is a dated snapshot, say
so to the dispatcher - don't present stale data as live.

## Related skills

- **browse** - the last rung of the ladder.
- **delegated-task** - outcome-report and honesty rules.
