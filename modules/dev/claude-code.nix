{ ... }:
{
  # ~/.claude/settings.json (including the autoCompactWindow key this module
  # used to jq-merge in) is now chezmoi-owned - see AGENTS.md "Chezmoi
  # cutover" and "Harness auto-compaction windows". Relinquished the same way
  # as git.nix/nvim.nix: kept as an empty module (still imported by
  # default.nix) rather than removed, so a future re-adoption has an obvious
  # home.
}
