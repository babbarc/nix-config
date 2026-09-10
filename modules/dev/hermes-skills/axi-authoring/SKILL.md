---
name: axi-authoring
description: "How to build a missing capability as a reusable AXI artifact: the 10 AXI principles, the artifact kinds (CLI/tool, plugin, skill), where each lives, and the build -> validate -> use -> refine loop. Load this when a task needs a capability you do not have yet, before improvising a one-off."
annotation: "AXI authoring: build reusable, token-efficient capability artifacts"
version: 1.0.0
user-invocable: false
metadata:
  hermes:
    tags: [axi, authoring, capability, tooling, plugin, skill, workflow]
    category: workflow
---

# axi-authoring

You are expected to grow your own capability. When a task needs something you
do not have - a way to query a system, operate an app, enforce a rule, or
repeat a workflow - do not do it one-off by hand and do not just write a note
about it. **Design and build the capability as a reusable AXI artifact,
validate it, then use it.**

This skill is the spec. It applies to the orchestrator and to every domain
expert.

## The learning loop

1. **Identify the gap.** Name the missing capability in one line: what can you
   not do (well) today?
2. **Choose the artifact kind** (below) - usually more than one.
3. **Design it to the AXI spec** (the 10 principles below).
4. **Build it** in your own writable area (see "Where your artifacts live").
5. **Validate it** against the checklist before you trust it.
6. **Use it** for the real task.
7. **Refine it** when reality disagrees - patch the skill, fix the CLI, tighten
   the plugin.
8. **Prefer reuse.** At the start of a task, check your own skills, plugins,
   and CLIs first; extend an existing artifact instead of writing a parallel
   one. If you will need it twice, build it once.

## The three artifact kinds

| You need... | Build... | Lives in |
| --- | --- | --- |
| A repeatable action or query against a real system | an executable CLI/tool | a writable PATH dir (`~/.local/bin`) |
| A rule that must hold no matter what the model decides | a Hermes plugin (`pre_tool_call`/hook) | your profile's `plugins/` |
| Judgment: when, why, and how to do something, with context | a skill | your profile's `skills/` |

One capability often needs two of these: the CLI is the **capability**, the
plugin is the **structural enforcement** (the thing that cannot be talked
around), and the skill is the **judgment layer** (the part that needs context).
Build the pieces the task actually needs - not more.

The existing suite is the worked example: `pass-access` is a skill +
`pass-axi` CLI, with `pass-enforcement` as the plugin that structurally blocks
the unsafe form; `browse` is a skill + `hermes-browse` CLI; `web-login` is a
skill + `hermes-web-login` CLI.

## The 10 AXI principles

### Efficiency

1. **Token-efficient output.** Emit structured, TOON-style key/value lines
   (`page: {title: "...", refs: 3}`), not pretty prose and not raw JSON. AXI
   shapes are roughly 40% cheaper than JSON for the same content.
2. **Minimal default schemas.** The default view is 3-4 fields. Widen it with
   an explicit flag (`--fields a,b,c`) instead of printing everything and
   hoping the reader filters.
3. **Content truncation.** Never dump large content into context. Truncate
   with an explicit marker (`(truncated, N chars - use --full)`), and write
   large bodies to a file, printing the **path** rather than the body.

### Robustness

4. **Pre-computed aggregates.** Put counts and summaries inline (`entries: 12`,
   `matches: 0`) so the next call is never "how many were there?".
5. **Definitive empty states.** "0 results found" is a success state and must
   read differently from a failure. Never make emptiness look like an error,
   and never make an error look like emptiness.
6. **Structured errors and exit codes.** Errors are `error: <CODE>` lines on
   stdout (plus detail), with exit `0` success, `1` no result / operational
   failure, `2` bad usage. Never prompt interactively - a tool that blocks on
   stdin is a bug. Make every mutation idempotent: re-running it must be safe.

### Discoverability

7. **Ambient context.** A session hook, or the skill itself, surfaces the
   relevant state up front so the agent does not have to ask for it
   (`plugins: 2 enabled`, `store: ok`).
8. **Content first.** A no-argument run prints live data plus `bin:`, a
   one-line description, and concrete next steps - **not** help text. Help is a
   flag on the side, not the front door.
9. **Contextual disclosure.** End with `help[]:` lines carrying templated next
   commands, with real values substituted where you have them (`Run
   'pass-axi inspect <path>' ...`), and a clear placeholder where you do not -
   never a guessed value.
10. **Consistent `--help`.** Every subcommand answers `--help` with its own
    usage. `--help` is the reliable escape hatch when nothing else fits.

## Where your artifacts live

You are **self-contained**: you build and own your own capability, and there is
**no fleet-wide AXI registry and no shared catalog**. Nothing you build is
discoverable by, or shared with, another expert - an expert that needs the same
capability builds its own. Never assume a tool you did not build exists.

Built artifacts are **runtime state in your own writable area**, not Nix-managed
repo content:

- **Skills built by you** -> your profile's local skills dir, written by
  `skill_manage(action="create", name="<domain>-<topic>")` or `operate-<app>`.
  This is `~/.hermes/profiles/<you>/skills/`.
- **Plugins built by you** -> your profile's `plugins/` dir
  (`~/.hermes/profiles/<you>/plugins/<name>/`).
- **CLIs/tools built by you** -> a writable dir on your PATH, by default
  `~/.local/bin`. That directory is user-level rather than per-profile, so
  domain-prefix the name (`<domain>-<capability>`) both to mark ownership and to
  avoid colliding with another expert's tool.

The shared base skills (`axi-authoring`, `browse`, `operate-desktop`,
`pass-access`, `web-login`, `recover-blocked-page`, `delegated-task`) are
**read-only Nix-managed symlinks**. Never patch or edit them -
`skill_manage` reports them "not found in active profile". Make your own and
reuse it.

Name artifacts `<domain>-<capability>` in kebab-case and do not shadow a shared
base name. Own the capability you build: if a later task needs it, use it again
rather than rebuilding it.

## Validation checklist

Before you rely on a new artifact, check it against the spec:

- [ ] No-argument run shows live content (principle 8), not help.
- [ ] Happy path, empty case, and bad input all behave: correct exit codes
      (0/1/2) and no prompting (4, 5, 6).
- [ ] Default output is the minimal schema; `--fields` widens it; `--full`
      defeats truncation (2, 3).
- [ ] Aggregates are inline and emptiness is definitive (4, 5).
- [ ] `help[]:` lines give the next real command (9).
- [ ] `--help` works on every subcommand (10).
- [ ] Any mutation is safe to re-run (6).
- [ ] For a plugin: prove the blocked action is refused structurally, and that
      the refusal tells the agent the sanctioned path instead.

Only then treat the capability as available and note it in your task report.

## Related skills

- **delegated-task** - the scope, irreversible-action gate, secret hygiene, and
  outcome-report contract that governs all of the above.
- **pass-access**, **web-login**, **browse**, **operate-desktop**,
  **recover-blocked-page** - worked AXI examples (skill + CLI, some with a
  plugin).
