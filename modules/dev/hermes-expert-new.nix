# hermes-expert-new - the orchestrator's one deterministic command for creating
# a domain-expert Hermes profile.
#
# Why this is a packaged helper and not a paragraph in the orchestrator's SOUL
# (captain decision #4, data/hermes-orchestrator-design/report.md sections 3.3
# and 5.4): the raw `hermes profile create --clone` flow has four sharp edges
# every time - the cloned orchestrator `toolsets` gate, the cloned memory, the
# stale cloned skill tree, and the plugins that `--clone` does not copy. A
# model re-deriving that each time is the most likely silent failure. The
# helper runs the whole normalization in a fixed order, refuses a bad name or
# an existing profile, and fails loudly.
#
# The script itself (modules/dev/hermes-expert-new) is repo-tracked and
# shellcheck-able; writeShellApplication only pins its runtime closure so it
# resolves from a non-interactive Hermes `terminal` tool call, not just an
# interactive shell. It reads the runtime artifacts the activation materializes
# - the expert SOUL template at $HERMES_HOME/templates/domain-expert-SOUL.md
# and the repo base plugins at $HERMES_HOME/plugins/{pass-enforcement,guardrails}
# - so it fails or warns clearly if run before those exist. Its
# `--sync-plugins <name>|--all` mode copies + enables those plugins on an
# existing profile, which is the fix path for an expert created before a
# plugin existed.
{ pkgs, ... }:
{
  home.packages = [
    (pkgs.writeShellApplication {
      name = "hermes-expert-new";
      runtimeInputs = with pkgs; [
        python3 # SOUL template substitution (multi-line scope, no sed escaping)
        coreutils
        findutils
        gnused
      ];
      text = builtins.readFile ./hermes-expert-new;
    })
  ];
}
