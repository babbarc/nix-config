{ pkgs, ... }:
let
  # deepseek's v4 models each expose a real 1M-token context window and a
  # 384K max output (verify with `pi --list-models deepseek`). pi's built-in
  # catalog already carries those numbers today, but pi's auto-compaction
  # triggers off whatever `contextWindow` the resolved model reports
  # (core/compaction: `contextTokens > contextWindow - reserveTokens`), so
  # declaring them here pins the compaction budget to the model's real
  # capacity instead of leaving it to a catalog value that a future `pi
  # update` could quietly lower. Shape mirrors kunchenguid/dotfiles'
  # `~/.pi/agent/models.json` (`providers.<id>.modelOverrides.<model>`); the
  # `cost` blocks are the captain's existing live overrides, preserved
  # verbatim so this file is a superset of what it replaces.
  #
  # modelOverrides is pi's topmost user-config layer and each field is a
  # plain `override.<field> ?? model.<field>` (core/provider-composer
  # applyModelOverride), so listing `contextWindow`/`maxTokens` alongside
  # `cost` overrides only those keys and leaves everything else from the
  # built-in entry intact.
  deepseekWindow = {
    contextWindow = 1000000;
    maxTokens = 384000;
  };
  piModels = {
    providers.deepseek.modelOverrides = {
      deepseek-v4-flash = deepseekWindow // {
        cost = { input = 0.44; output = 1.32; cacheRead = 0.014; cacheWrite = 0; };
      };
      deepseek-v4-flash-vision-exp = deepseekWindow // {
        cost = { input = 0.44; output = 1.32; cacheRead = 0.014; cacheWrite = 0; };
      };
      deepseek-v4-pro = deepseekWindow // {
        cost = { input = 1.32; output = 3.96; cacheRead = 0.044; cacheWrite = 0; };
      };
    };
  };
in
{
  home.packages = with pkgs; [
    pi-coding-agent
  ];

  # models.json is pure read-only user config: pi only ever reads it (model
  # catalog + overrides). Unlike settings.json - which pi rewrites at runtime
  # and is therefore merged by an activation script, now in dotfiles' chezmoi
  # - models.json has no runtime writer, so a plain read-only home.file
  # symlink is the correct declarative form. `pi install` pins packages into
  # settings.json's `packages` array, not here.
  home.file.".pi/agent/models.json".source =
    (pkgs.formats.json { }).generate "pi-models.json" piModels;
}
