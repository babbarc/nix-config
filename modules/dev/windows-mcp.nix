{ config, lib, pkgs, ... }:

let
  # Shared content builders. These are pure functions of the option values
  # (name/command/args) rather than reading the module `config` argument at
  # definition time - the harness-specific blocks below pass the live option
  # values in, which keeps evaluation cycle-free.
  #
  # [mcp_servers.<id>] TOML table for codex and grok (both document this
  # exact shape in ~/.codex/config.toml and ~/.grok/config.toml).
  tomlBlock = name: command: args: ''
    [mcp_servers.${name}]
    command = "${command}"
    args = [${lib.concatMapStringsSep ", " (a: ''"${a}"'') args}]
  '';

  # Claude Code's stdio entry shape (type + command + args), written into its
  # user-scope ~/.claude.json mcpServers map via `claude mcp add-json`.
  claudeJson = command: args: builtins.toJSON {
    type = "stdio";
    command = command;
    args = args;
  };

  # opencode's "mcp" map uses a single command array (command + args
  # concatenated), type "local", and an explicit enabled flag.
  opencodeJson = command: args: builtins.toJSON {
    type = "local";
    command = [ command ] ++ args;
    enabled = true;
  };

  # kimi's user-level ~/.kimi-code/mcp.json uses the classic mcpServers
  # shape; an entry with a "command" field is a stdio server (no type key).
  kimiJson = name: command: args: builtins.toJSON {
    mcpServers = {
      ${name} = {
        command = command;
        args = args;
      };
    };
  };

  # Appends the [mcp_servers.<id>] block to a TOML config file only when that
  # section is not already present - preserves any other user content in the
  # file and never rewrites a hand-edited entry (same skip-if-present posture
  # as the repo's other one-time bootstrap blocks).
  mkTomlRegistration = after: name: command: args: configFile: lib.hm.dag.entryAfter after ''
    mkdir -p "$(dirname "${configFile}")"
    if [ ! -f "${configFile}" ] || ! grep -q '^\[mcp_servers\.${name}\]' "${configFile}" 2>/dev/null; then
      cat >> "${configFile}" <<'WINDOWS_MCP_EOF'
${tomlBlock name command args}
WINDOWS_MCP_EOF
    fi
  '';
in
{
  options.windowsMcp = {
    harness = lib.mkOption {
      type = lib.types.enum [ "none" "claude" "codex" "opencode" "grok" "kimi" ];
      default = "none";
      description = ''
        Which additional GUI-control harness to install alongside pi (always
        present on every host; not managed here) and register with the
        Windows windows-mcp bridge. "none" installs nothing and writes no
        registration; every other value installs exactly that one harness and
        registers the windows-mcp stdio server in it. Supported values and
        their tradeoffs are documented in the README's "Windows-MCP bridge"
        section - cursor was evaluated and deliberately excluded (it is a
        Windows GUI app, not a WSL-side CLI harness).
      '';
    };
    serverName = lib.mkOption {
      type = lib.types.str;
      default = "windows";
      description = "MCP server name registered in the chosen harness.";
    };
    serverCommand = lib.mkOption {
      type = lib.types.str;
      default = "powershell.exe";
      description = "WSL-side command that spawns the Windows MCP server over stdio.";
    };
    serverArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "-Command" "uvx.exe windows-mcp serve" ];
      description = "Arguments passed to serverCommand (the Windows-side uvx invocation as one argument).";
    };
  };

  config = lib.mkIf (config.windowsMcp.harness != "none") (lib.mkMerge [

    (lib.mkIf (config.windowsMcp.harness == "claude") {
      # Claude Code is not in nixpkgs as a free package (its license is
      # non-free), and the captain already runs it via its native installer at
      # ~/.local/bin/claude - so it is installed the same way here: npm, once,
      # under ~/.local (pinned), self-updating via `claude update`.
      home.activation.windowsMcpInstall = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        PATH="$HOME/.local/bin:${pkgs.curl}/bin:$PATH"
        if ! command -v claude >/dev/null 2>&1; then
          ${pkgs.nodejs_26}/bin/npm install --prefix "$HOME/.local" -g @anthropic-ai/claude-code@2.1.265 \
            || echo "warning: claude install failed (offline?) - retry later with: npm install --prefix $HOME/.local -g @anthropic-ai/claude-code@2.1.265" >&2
        fi
      '';
      # ~/.claude.json is Claude Code's own state file (sessions, projects,
      # plus the user-scope mcpServers map), so it is updated through Claude
      # Code's own writer rather than managed wholesale. Idempotent:
      # re-adding the same server name replaces the entry.
      home.activation.windowsMcpRegister = lib.hm.dag.entryAfter [ "windowsMcpInstall" ] ''
        PATH="$HOME/.local/bin:$PATH"
        claude mcp add-json --scope user \
          ${lib.escapeShellArg config.windowsMcp.serverName} \
          ${lib.escapeShellArg (claudeJson config.windowsMcp.serverCommand config.windowsMcp.serverArgs)} \
          || echo "warning: could not register windows-mcp with Claude Code - retry later with: claude mcp add-json --scope user ${config.windowsMcp.serverName}" >&2
      '';
    })

    (lib.mkIf (config.windowsMcp.harness == "codex") {
      home.packages = [ pkgs.codex ];
      home.activation.windowsMcpRegister = mkTomlRegistration
        [ "writeBoundary" ]
        config.windowsMcp.serverName
        config.windowsMcp.serverCommand
        config.windowsMcp.serverArgs
        "${config.home.homeDirectory}/.codex/config.toml";
    })

    (lib.mkIf (config.windowsMcp.harness == "opencode") {
      home.packages = [ pkgs.opencode ];
      # opencode has no CLI for adding local stdio servers, so merge the
      # entry into its global config with jq - idempotent and preserves any
      # other keys (providers, models, permissions) already in the file.
      home.activation.windowsMcpRegister = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        cfg_dir="${config.home.homeDirectory}/.config/opencode"
        cfg_file="$cfg_dir/opencode.json"
        mkdir -p "$cfg_dir"
        if [ ! -s "$cfg_file" ]; then
          printf '{}\n' > "$cfg_file"
        fi
        ${pkgs.jq}/bin/jq --argjson entry ${lib.escapeShellArg (opencodeJson config.windowsMcp.serverCommand config.windowsMcp.serverArgs)} \
          '.mcp.${config.windowsMcp.serverName} = $entry' "$cfg_file" > "$cfg_file.tmp" \
          && mv "$cfg_file.tmp" "$cfg_file" \
          || echo "warning: could not register windows-mcp with opencode" >&2
      '';
    })

    (lib.mkIf (config.windowsMcp.harness == "grok") {
      # Official xAI CLI, distributed as platform npm binaries; not in
      # nixpkgs. Installed once under ~/.local like the axi suite
      # (agent-cli-tools.nix); self-updates via `grok update`.
      home.activation.windowsMcpInstall = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        PATH="$HOME/.local/bin:${pkgs.curl}/bin:$PATH"
        if ! command -v grok >/dev/null 2>&1; then
          ${pkgs.nodejs_26}/bin/npm install --prefix "$HOME/.local" -g @xai-official/grok@1.0.13 \
            || echo "warning: grok install failed (offline?) - retry later with: npm install --prefix $HOME/.local -g @xai-official/grok@1.0.13" >&2
        fi
      '';
      home.activation.windowsMcpRegister = mkTomlRegistration
        [ "windowsMcpInstall" ]
        config.windowsMcp.serverName
        config.windowsMcp.serverCommand
        config.windowsMcp.serverArgs
        "${config.home.homeDirectory}/.grok/config.toml";
    })

    (lib.mkIf (config.windowsMcp.harness == "kimi") {
      # Official Moonshot single-binary CLI; not in nixpkgs. Installed once
      # under ~/.local via the official installer. KIMI_NO_MODIFY_PATH stops
      # it editing the chezmoi-owned fish rc; ~/.local/bin is already first
      # on PATH (session-path.nix / the shell's default).
      home.activation.windowsMcpInstall = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        PATH="$HOME/.local/bin:${pkgs.curl}/bin:$PATH"
        if ! command -v kimi >/dev/null 2>&1; then
          KIMI_INSTALL_DIR="$HOME/.local" KIMI_NO_MODIFY_PATH=1 KIMI_VERSION=0.41.0 \
            ${pkgs.curl}/bin/curl -fsSL https://code.kimi.com/kimi-code/install.sh \
            | PATH="${pkgs.curl}/bin:$PATH" bash \
            || echo "warning: kimi install failed (offline?) - retry later with: curl -fsSL https://code.kimi.com/kimi-code/install.sh | KIMI_INSTALL_DIR=$HOME/.local KIMI_NO_MODIFY_PATH=1 bash" >&2
        fi
      '';
      # ~/.kimi-code/mcp.json is dedicated to MCP servers only (kimi's
      # documented user-level file), so it is managed declaratively as a
      # whole file rather than merged.
      home.file.".kimi-code/mcp.json".text = kimiJson
        config.windowsMcp.serverName
        config.windowsMcp.serverCommand
        config.windowsMcp.serverArgs;
    })

  ]);
}
