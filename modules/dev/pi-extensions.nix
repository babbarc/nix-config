{ pkgs, ... }:
let
  # "Kun's Pi Agent Config" guide
  # (https://blog.kunchenguid.com/p/kuns-pi-agent-config) names three
  # third-party pi extensions and installs them through pi's own `packages`
  # array in settings.json. This repo deliberately does NOT adopt that path:
  # settings.json - including pi's own `packages` array, which already
  # carries `npm:pi-scroll` - is now wholly chezmoi-owned (see AGENTS.md
  # "Chezmoi cutover"), and nix-config carries no agent config content at
  # all. Instead each extension is packaged here as a nix derivation and
  # symlinked into pi's auto-discovery directory
  # (`~/.pi/agent/extensions/<name>/`, the "Global (subdirectory)" row of
  # <pi-docs>/extensions.md's "Extension Locations" table) - a mechanism
  # that never touches settings.json. herdr's own
  # `~/.pi/agent/extensions/herdr-agent-state.ts` (modules/dev/herdr.nix)
  # lives in the same directory as a sibling plain file; these are separate
  # leaf entries (home.file only manages the three below) and never collide.
  #
  # Each extension pins EXACTLY the guide's version/ref. nixpkgs packages
  # none of them, so each is built here (buildNpmPackage, or a plain fetch
  # for the one with zero runtime deps) against a vendored
  # `pi-extensions/<name>/package-lock.json` generated with
  # `--legacy-peer-deps`. That flag matters: all three declare pi's own
  # runtime (`@earendil-works/pi-ai`, `pi-coding-agent`, `pi-tui`) as a
  # peerDependency, which <pi-docs>/extensions.md's "Available Imports"
  # table confirms is already resolvable at runtime without a separate
  # install - installing it anyway (npm's default auto-install-peers
  # behavior) would be wrong, and for pi-web-access it drags in an unrelated
  # multi-hundred-package tree (AWS/Google SDKs pulled in only to satisfy
  # `pi-coding-agent`'s own transitive deps). Only each package's real
  # `dependencies` get installed; `devDependencies` are stripped from
  # package.json (jq, in postPatch) before generating the lockfile, since
  # the runtime never needs them (typecheck-only compilers, `@types/*`,
  # pi's own packages pinned only for that package's local dev loop).
  piWebAccessVersion = "0.14.0";
  piWebAccess = pkgs.buildNpmPackage {
    pname = "pi-web-access";
    version = piWebAccessVersion;
    src = pkgs.fetchurl {
      url = "https://registry.npmjs.org/pi-web-access/-/pi-web-access-${piWebAccessVersion}.tgz";
      hash = "sha512-7RDVCfYkcGSgWMtroDCq47davp6W36Nc4ETLd8dhyPjox/rA89nxUwvvjba+ln39G28uiebnTh5G83UYFjkjWw==";
    };
    postPatch = ''
      ${pkgs.jq}/bin/jq 'del(.devDependencies)' package.json > package.json.tmp
      mv package.json.tmp package.json
      cp ${./pi-extensions/pi-web-access/package-lock.json} package-lock.json
    '';
    npmDepsHash = "sha256-rB/KsPuLR3wH4Vhz4hOS7Z5nkIesvVKCis8J5wgA5I8=";
    npmFlags = [ "--legacy-peer-deps" ];
    dontNpmBuild = true;
  };

  # Zero runtime dependencies (only the same optional-in-spirit peer deps
  # above) - a plain fetch+copy of the published tarball, no npm install
  # needed at all.
  piExtensionCodexFastModeVersion = "0.2.6";
  piExtensionCodexFastMode = pkgs.stdenv.mkDerivation {
    pname = "pi-extension-codex-fast-mode";
    version = piExtensionCodexFastModeVersion;
    src = pkgs.fetchurl {
      url = "https://registry.npmjs.org/@ryan_nookpi/pi-extension-codex-fast-mode/-/pi-extension-codex-fast-mode-${piExtensionCodexFastModeVersion}.tgz";
      hash = "sha512-DzJCqiXMnkAT77OjiGZm4y1nYPieTQzsjgR05O6+o43L4WrLrvxjUf360qBrNbNT2hGX6AbHvwC7fgXr0WrpmQ==";
    };
    dontBuild = true;
    installPhase = ''
      mkdir -p $out
      cp -r . $out/
    '';
  };

  piOpenaiServerCompactionRev = "c6d593087709e9481223dc6c6c2269b371b5e055";
  piOpenaiServerCompaction = pkgs.buildNpmPackage {
    pname = "pi-openai-server-compaction";
    version = "0.1.0";
    src = pkgs.fetchFromGitHub {
      owner = "algal";
      repo = "pi-openai-server-compaction";
      rev = piOpenaiServerCompactionRev;
      hash = "sha256-SFGcISdYblxGonhipIHPAOons8MdwYtu+A+WbHnNSVg=";
    };
    # This package's real entry point is `src/index.ts`, declared in its own
    # `pi.extensions` manifest key. extensions.md's "Extension Locations"
    # table only documents a bare `<dir>/index.ts` for directory
    # auto-discovery, but pi's real loader (core/extensions/loader.js
    # `resolveExtensionEntries`) checks a discovered subdirectory's
    # package.json `pi.extensions` field FIRST, falling back to `index.ts`
    # only when that field is absent - confirmed by loading this exact
    # derivation through that loader (see the PR body for the harness/output).
    # So the untouched manifest is already enough; no shim needed here.
    postPatch = ''
      ${pkgs.jq}/bin/jq 'del(.devDependencies)' package.json > package.json.tmp
      mv package.json.tmp package.json
      cp ${./pi-extensions/pi-openai-server-compaction/package-lock.json} package-lock.json
    '';
    npmDepsHash = "sha256-oFxSOmOk7ptwPBI/wmvD7XPksvZyQYbh5xWlq0N5fkI=";
    dontNpmBuild = true;
  };
in
{
  # Leaf-only home.file entries (not the whole `extensions` dir, which herdr
  # also writes into) so these three coexist with herdr's own
  # herdr-agent-state.ts and anything chezmoi later drops in the same
  # directory. See modules/dev/pi.nix for the models.json half of this split.
  home.file = {
    ".pi/agent/extensions/pi-web-access".source =
      "${piWebAccess}/lib/node_modules/pi-web-access";
    ".pi/agent/extensions/pi-extension-codex-fast-mode".source =
      piExtensionCodexFastMode;
    ".pi/agent/extensions/pi-openai-server-compaction".source =
      "${piOpenaiServerCompaction}/lib/node_modules/pi-openai-server-compaction";
  };
}
