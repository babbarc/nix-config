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

## The tool: `recover-page`

```
recover-page <url>          # -> ok: {route, provenance, snapshot_date, saved: <path>}
recover-page <url> --json   # full route trace
```

- The page body is written to a **file** (`saved:`), not dumped into context.
- Definitive failure: `error: ALL_ROUTES_FAILED - tried wayback,
  archive.today(x4), api-pivot` - never an empty file.
- Provenance is in the output, so a report can cite "as archived <date>"
  correctly.

> **Status:** `recover-page` ships in a follow-up change. Use the manual ladder
> below until it lands.

## Interim path (no `recover-page` yet)

1. **Wayback:**
   `curl -s "https://archive.org/wayback/available?url=<url>"` - if
   `archived_snapshots.closest.available` is true, fetch `.url` and note
   `.timestamp`.
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
so to firstmate - don't present stale data as live.

## Related skills

- **browse** - the last rung of the ladder.
- **delegated-task** - outcome-report and honesty rules.
