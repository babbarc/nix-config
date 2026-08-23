{ ... }:
{
  # ~/.config/wezterm is populated entirely from this repo's wezterm/ tree -
  # the entrypoint plus config/, utils/, events/ (wezterm/setup-windows.ps1
  # stays out; it's Windows-side setup tooling, not something wezterm loads).
  #
  # This used to overlay 6 files onto a separately-cloned
  # KevinSilvester/wezterm-config framework at ~/.config/wezterm. That
  # framework is no longer a runtime dependency: utils/ and events/ here are
  # vendored copies (MIT-licensed, attribution headers in each file) of the
  # parts of that framework worth keeping, config/appearance.lua was
  # rewritten to fix the "sharp corners / colour spilling" root causes (see
  # its comments), and colors/custom.lua + utils/backdrops.lua +
  # utils/gpu-adapter.lua were dropped rather than vendored - see
  # config/appearance.lua's window_background_opacity comment for why.
  xdg.configFile = {
    "wezterm/wezterm.lua".source = ../../wezterm/wezterm.lua;
    "wezterm/config".source = ../../wezterm/config;
    "wezterm/utils".source = ../../wezterm/utils;
    "wezterm/events".source = ../../wezterm/events;
  };
}
