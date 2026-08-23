{ ... }:
{
  xdg.configFile = {
    "nvim/init.lua".source = ../../../nvim/init.lua;
    "nvim/lazyvim.json".source = ../../../nvim/lazyvim.json;
    "nvim/stylua.toml".source = ../../../nvim/stylua.toml;
    "nvim/lua" = {
      source = ../../../nvim/lua;
      recursive = true;
    };
    "nvim/snippets" = {
      source = ../../../nvim/snippets;
      recursive = true;
    };
  };
}
