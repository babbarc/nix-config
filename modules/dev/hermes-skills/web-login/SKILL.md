---
name: web-login
description: "Fill a username / password / OTP into a browser login form with the secret read from `pass` internally - never through a tool parameter, a shell argument, or the browser command surface. Use for any web login or credential/OTP field. Owns the entire login surface; there is no other sanctioned path for typing a secret into a page."
annotation: "Zero-exposure credential entry into a web login form"
version: 1.1.0
user-invocable: false
metadata:
  hermes:
    tags: [security, credentials, pass, login, otp, browser, cdp]
    category: security
---

# web-login

The one place a secret is allowed to enter a web page. It exists so that the
general **browse** command surface can stay completely secret-free.

## The rule

A secret value must **never** appear in a tool call, a shell argument, a log
line, a screenshot, or model context. That rules out:

- `browse` / `chrome-devtools-axi` `fill` / `type` / `eval` with the secret,
- the native `browser_type` / `browser_cdp Input.insertText` tools,
- `cua-driver` `type_text` / `set_value` (the text is an MCP parameter -> it
  lands in the tool-call record),
- `pass show <path>` to read it "just to paste it".

The secret's only sanctioned path is: GPG -> pipe -> the login helper's memory
-> CDP `Runtime.evaluate` -> the DOM. It is read **inside** the helper from
`pass`, addressed only by its store path.

## Scope

This skill owns the **full** login surface - password forms, OTP fields, and
browser-based SSO. There is no proxy-credential or token-swap alternative for
web logins (assessed and ruled out); if a login is required, it goes through
here.

## The tool: `hermes-web-login`

```
hermes-web-login <pass-path> [--selector <css>] [--submit]
hermes-web-login otp <pass-path> [--selector <css>] [--submit]
hermes-web-login --help
```

- Reads the secret internally with `pass` (via the `~/.hermes/bin/pass-to`
  helper), auto-discovers the CDP socket from
  `http://localhost:3333/json/version`, attaches to the best page target
  (prefers a login/signin/auth URL), and sets the field value with an
  SPA-safe native setter plus `input`/`change`/`blur` events. Default
  selector: `input[type=password]`; pass `--selector` with the real ref
  from `browse snapshot` for anything else.
- `otp <pass-path>` runs `pass otp <pass-path>` the same way and fills the OTP
  field (default selector targets a one-time-code / numeric input). TOTP is a
  30s window - generate it right before submit.
- `--submit` submits the login after the fill and reports the resulting URL.
  It calls the owning `<form>`'s `requestSubmit()` when there is one; when the
  filled field has no `<form>` (JS-only logins - e.g. an `onclick="validate()"`
  button), it locates and clicks the page's submit control instead. The result
  adds `submitted` (what actually happened) and `navigated` (did the URL
  change); if no submit control can be found it reports `submitted: false`
  with a one-line `help[]` hint to snapshot and click it by hand.
- Structured result, no secret: `ok: {selector, filled_len, target}` (plus
  `submitted, url, navigated` with `--submit`) where `filled_len` is the
  length only. Errors: `PASS_ENTRY_NOT_FOUND`,
  `SELECTOR_NOT_FOUND`, `NO_PAGE_TARGET`, `CDP_UNREACHABLE` (plus
  `PASS_HELPER_MISSING`, `PASS_READ_FAILED`, `OTP_UNAVAILABLE`,
  `FILL_NOT_VERIFIED`). Exit 0 filled-and-verified, 1 operational error, 2 bad
  usage. Idempotent - re-running re-fills the same value.

`hermes-web-login` is packaged onto PATH by `modules/dev/hermes-skills.nix`
(nix profile, shell-independent) - it is the one sanctioned path for a secret
to enter a web page. If it cannot fill the field within the timebox below,
stop and tell the dispatcher - do **not** fall back to typing the secret
through a browser or desktop tool.

## Procedure

1. Use **pass-access** to find the entry and confirm its fields
   (`login:`, `url:`, `otpauth:`).
2. With **browse**, `open` the login page and `snapshot` it to get the real
   field refs.
3. `hermes-web-login <path> --selector "#username"` for the username (or a
   non-secret field - a plain `browse fill` is fine for a username), then
   `hermes-web-login <path>` for the password.
4. If the entry has OTP: submit the first factor, wait for the OTP page, then
   `hermes-web-login otp <path>` and submit.
5. Verify the logged-in state with a `browse snapshot` before reporting.

## Timebox

SPA logins can defeat value injection. Budget 2 strategies x 3 tries. If it
still fails, **stop and ask the dispatcher** for permission to use a single
visible type-in, or to run a password-reset flow. Never silently fall back to
`browse type` with the secret.

## Related skills

- **pass-access** - locate the entry and its fields.
- **browse** - open the page and find the field refs.
- **delegated-task** - secret-hygiene rules in full.
