{ pkgs, ... }:
{
  home.packages = with pkgs; [
    pi-coding-agent
  ];

  # ~/.pi/agent/settings.json and ~/.pi/agent/models.json are now both
  # chezmoi-owned (see AGENTS.md "Chezmoi cutover"). models.json is the one
  # deliberate exception to "chezmoi owns the content outright": chezmoi
  # seeds it CREATE-ONLY (a starting point matching this module's former
  # `providers.deepseek.modelOverrides`), and the captain edits it freely
  # afterward - nix never touches it again. This module used to manage
  # models.json directly as a read-only `home.file` symlink (`force = true`);
  # that block is retired outright, not replaced, so a future `home-manager
  # switch` removes the symlink it used to own (home-manager only ever
  # cleans up paths present in a PREVIOUS generation's own manifest, never an
  # arbitrary plain file at the same path) and leaves chezmoi's seeded file
  # - or, on hosts that already carried a hand-written models.json predating
  # this module, that pre-existing plain file - untouched either way.
  #
  # The guide's three third-party extensions (pi-web-access,
  # @ryan_nookpi/pi-extension-codex-fast-mode, and the git source
  # algal/pi-openai-server-compaction) are pi-managed: `dotfiles` seeds them
  # into settings.json `packages`, so `pi update` keeps them current. Nothing
  # here packages them.
}
