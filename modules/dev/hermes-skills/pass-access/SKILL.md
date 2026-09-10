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

The store lives at `~/.password-store` (the captain's real store). Never
reference `/opt/data` paths.

## The tool: `pass-axi`

`pass-axi` is on `PATH`. It is safe by construction: there is no
`show` / `get` / `cat` / `edit`, so it cannot dump or mutate a secret.

```
pass-axi                 # content-first: store path, entry count, recent, help[]
pass-axi find <term>     # name search  -> `matches: N` then the paths
pass-axi ls [subdir]     # tree listing -> `entries: N` then the paths
pass-axi inspect <path>  # metadata only - login:/url:/otpauth: - NEVER line 1
pass-axi otp <path>      # current TOTP code, digits only
pass-axi doctor          # GPG / env / .gpg-id / secret-key / decrypt-probe matrix
pass-axi --help
```

- `inspect` routes through `~/.hermes/bin/pass-to <path> -- ~/.hermes/bin/pass-inspect`:
  the secret goes GPG -> pipe -> filter, and only the lines **after** line 1
  are printed. `secret=` inside `otpauth://` URIs (and any other
  secret-shaped metadata) is masked to `HIDDEN`.
- `otp` runs the `pass otp` extension - it prints only the code.
- Every subcommand gives structured output, a definitive empty state
  (`matches: 0 - ...`), a structured error with `help[]`, and a meaningful
  exit code (`0` ok, `2` usage, `3` store not initialised, `4` not found,
  `5` decrypt/gpg failure, `6` helper missing; `doctor` exits `1` on any
  failed check).

### Typical flow (feeding `web-login`)

```
pass-axi find kraken            # -> matches: 1 / myaccounts/kraken.com
pass-axi inspect myaccounts/kraken.com
                                # -> login: ... / url: ... / otpauth://...secret=HIDDEN
# then hand the path to web-login; never read the secret yourself
```

## If `pass-axi` is somehow unavailable

Fall back to `pass` + the `~/.hermes/bin` helpers - never `pass show <path>`
or bare `pass <path>` (both print the secret to stdout, i.e. into context;
this instance also blocks those forms structurally):

- **Search / list:** `pass find <term>`, `pass ls [subdir]`, `pass git log`.
- **Metadata:** `~/.hermes/bin/pass-to <path> -- ~/.hermes/bin/pass-inspect`.
- **OTP:** `pass otp <path>`.
- **Into a command:** `~/.hermes/bin/pass-to <path> -- <cmd>` (secret to the
  child's stdin) or `~/.hermes/bin/pass-env <path> <VAR> -- <cmd>` (secret in
  an env var for the child only).

## `doctor` / diagnosing a `pass` failure

When `pass` errors, run `pass-axi doctor`. It checks, and prints a pass/fail
row for each:

1. `PASSWORD_STORE_DIR` - unset (default) or pointing at a real directory.
2. `GNUPGHOME` - unset (default) or readable.
3. `gpg` / `pass` on `PATH`.
4. `~/.password-store/.gpg-id` - exists and lists recipients.
5. secret-key intersection - `gpg --list-secret-keys` matches at least one
   `.gpg-id` recipient (no matching secret key = cannot decrypt anything).
6. `.gpg` files actually present under the store.
7. **decrypt probe** - a non-interactive `gpg --batch --decrypt` of one entry.
   A fail here is the headless-gpg-agent case: no TTY, passphrase not cached,
   or no loopback pinentry. Prime the agent once interactively, or raise
   `gpg-agent` `default-cache-ttl` / `max-cache-ttl`.

## Storage policy (when asked to *store* a secret - rare)

Three tiers: **durable** secrets (real passwords, long-lived API keys) go in
`pass` only; **long-lived** tokens likewise; **ephemeral/refreshable** tokens
(short OAuth access tokens) are used in-session and **not** written back.
`pass-axi` deliberately cannot write - storing a secret is a `pass insert`
done deliberately, and when in doubt, ask the dispatcher rather than persisting
something.

## Related skills

- **web-login** - fill a located entry into a browser form (the only place a
  secret enters a page).
- **delegated-task** - secret-hygiene rules in full.
