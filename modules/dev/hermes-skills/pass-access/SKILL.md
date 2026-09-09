---
name: pass-access
description: "Safely work with the `pass` password store - search entry names, list the tree, inspect an entry's metadata (login/url/otpauth), generate an OTP, and diagnose GPG/env failures - without ever exposing a secret value. Use before any login to find the entry and its fields, or when `pass` itself is failing."
annotation: "Safe pass store access: find / inspect / otp / doctor - never the secret"
version: 1.0.0
user-invocable: false
metadata:
  hermes:
    tags: [security, credentials, pass, gpg, otp, diagnostics]
    category: security
---

# pass-access

Read the `pass` store safely. Every operation here is metadata-only or a
generated code - **the first line of an entry (the secret) never reaches
stdout or context.**

The store lives at `~/.password-store`. Never reference `/opt/data` paths.

## The tool: `pass-axi`

```
pass-axi                 # content-first: store path, entry count, recent, help[]
pass-axi find <term>     # name search  -> `matches: N` then the paths
pass-axi ls [subdir]     # tree listing
pass-axi inspect <path>  # metadata only - login:/url:/otpauth: - NEVER line 1
pass-axi otp <path>      # 6-digit code only
pass-axi doctor          # GPG / env / gpg-id / secret-key pass-fail matrix
pass-axi --help
```

There is deliberately **no** `show` / `get` / `cat` - the tool cannot dump a
secret. `inspect` masks `secret=` inside `otpauth://` URIs.

> **Status:** `pass-axi` ships in a follow-up change. Use the interim path
> below until it lands.

## Interim path (no `pass-axi` yet)

`pass` and the `~/.hermes/bin` helpers are available now:

- **Search / list:** `pass find <term>`, `pass ls [subdir]`, `pass git log`.
  These never print a secret.
- **Metadata:** `~/.hermes/bin/pass-to <path> -- pass-inspect` - the secret
  goes GPG -> pipe -> `pass-inspect` stdin, which prints every line **except**
  the first and masks `secret=`. Nothing sensitive hits stdout.
- **OTP:** `pass otp <path>` prints only the 6-digit code.
- **Into a command:** `~/.hermes/bin/pass-to <path> -- <cmd>` (secret to the
  child's stdin) or `~/.hermes/bin/pass-env <path> <VAR> -- <cmd>` (secret in
  an env var for the child only).

**Never** run `pass show <path>` or bare `pass <path>` - both print the secret
to stdout, i.e. into context. (This instance also blocks those forms
structurally in the terminal.)

## `doctor` / diagnosing a `pass` failure

When `pass` errors, check, in order:

1. `PASSWORD_STORE_DIR` - set, and points at `~/.password-store`?
2. `GNUPGHOME` - set and readable?
3. `~/.password-store/.gpg-id` - exists, lists a key id?
4. `gpg --list-secret-keys` - does it contain the key id from `.gpg-id`?
   (No matching secret key = cannot decrypt anything.)
5. `.gpg` files actually present under the entry path?
6. Headless gpg-agent: a non-interactive session needs the passphrase already
   cached or a loopback pinentry - a first decrypt in a fresh session can hang
   or fail with no TTY. Prime it once, or extend the agent cache TTL.

Report a pass/fail line for each, not a narrative.

## Storage policy (when asked to *store* a secret - rare)

Three tiers: **durable** secrets (real passwords, long-lived API keys) go in
`pass` only; **long-lived** tokens likewise; **ephemeral/refreshable** tokens
(short OAuth access tokens) are used in-session and **not** written back.
When in doubt, ask firstmate rather than persisting something.

## Related skills

- **web-login** - fill a located entry into a browser form.
- **delegated-task** - secret-hygiene rules in full.
