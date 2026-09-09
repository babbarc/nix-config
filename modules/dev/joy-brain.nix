{ config, lib, pkgs, ... }:
let
  hermesHome = "${config.home.homeDirectory}/.hermes";
  joyBrainRepo = "ssh://git@alps:2222/babbarc/joy-brain.git";
  joyBrainDir = "${config.home.homeDirectory}/.local/share/joy-brain";

  # Pinned commit of the private joy-brain repo. Set this to a 40-char SHA to
  # pin (the activation enforces it on every run). Empty = clone HEAD and warn,
  # which keeps a fresh host working but is NOT the intended steady state.
  joyBrainRev = "8c95745461bf7b01dbcc17659853bad62f35bd88";

  # Curated skill subset (captain scope decision, see README "Hermes agent").
  # Only browser skills (drive the Windows Chrome via the CDP proxy) plus the
  # MCP workflow skill are instantiated; every other joy-brain skill stays
  # private in the clone and is deliberately NOT materialized into ~/.hermes.
  # This list is the single place to extend. Paths are relative to
  # <clone>/skills/; a bare name is a flat skill dir, a/b is a skill inside a
  # category dir (both resolve to the same shape under ~/.hermes/skills/).
  includedSkills = [
    # browser skills
    "chrome-devtools-axi"              # primary browser CLI driver
    "web"                              # blocked-page-recovery (fetch failure recovery)
    "software/choose-web-tool"         # load first for web: curl/browser/scrapling
    "software/operate-browser"         # built-in browser_navigate/click/type/scroll
    "software/preserve-browser-session" # CDP session preservation pattern
    "software/use-cdp-protocol"        # raw CDP via the browser_cdp tool
    "software/run-cdp-scripts"         # cdp-*.py CLI scripts (target localhost:3333)
    "software/recaptcha-solver"        # reCAPTCHA v2 challenges
    "research/scrapling"               # stealth browser scraping / Cloudflare bypass
    "research/duckduckgo-search"       # free web search (no API key)
    # workflow
    "mcp"                              # native-mcp (MCP client: stdio/HTTP servers)
  ];

  # Deep-merged into ~/.hermes/config.yaml at activation. `*` is yq's merge
  # operator (right-hand side wins), so only browser.cdp_url is forced and any
  # other keys - joy-brain's config plus Hermes's own runtime edits - survive.
  browserOverride = pkgs.writeText "hermes-browser-cdp-override.yaml" ''
    browser:
      cdp_url: "http://localhost:3333"
  '';
in
{
  # Instantiates the captain's private joy-brain assistant as the Hermes home
  # (~/.hermes) WITHOUT vendoring any of its private content into this repo.
  # Same posture as modules/dev/firstmate.nix: the private git tree is cloned
  # at activation from the gitea SSH URL and never committed here. This repo
  # only carries the clone URL, the pin, the curated skill list and the
  # browser.cdp_url wiring.
  #
  # Layout:
  #   ~/.local/share/joy-brain   the pinned clone (source of truth, never
  #                              edited by this module)
  #   ~/.hermes                  the materialized HERMES_HOME: config.yaml is
  #                              a writable copy (merged with browser.cdp_url),
  #                              identity/state/plugins/skills are symlinks
  #                              back into the clone
  #
  # Runtime state Hermes writes under ~/.hermes (sessions/, logs/, cron/,
  # memories/) lands as untracked files in the clone via the symlinks - the
  # same model the production container uses (HERMES_HOME == the joy-brain
  # working tree), so nothing here needs to invent a new state layout.

  home.activation.joyBrainClone = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    _git=${pkgs.git}/bin/git
    if [ ! -d "${joyBrainDir}/.git" ]; then
      $DRY_RUN_CMD mkdir -p "$(dirname "${joyBrainDir}")"
      $DRY_RUN_CMD "$_git" clone ${lib.escapeShellArg joyBrainRepo} "${joyBrainDir}" \
        || echo "warning: could not clone joy-brain into ${joyBrainDir} (offline or no ssh access to alps?) - retry later: git clone ${joyBrainRepo} ${joyBrainDir}" >&2
    fi
    if [ -d "${joyBrainDir}/.git" ]; then
${
      lib.optionalString (joyBrainRev != "") ''
        $DRY_RUN_CMD "$_git" -C "${joyBrainDir}" fetch origin 2>/dev/null || true
        $DRY_RUN_CMD "$_git" -C "${joyBrainDir}" checkout --detach ${lib.escapeShellArg joyBrainRev} 2>/dev/null \
          || echo "warning: could not pin joy-brain to ${joyBrainRev}" >&2
      ''
    }${
      lib.optionalString (joyBrainRev == "") ''
        echo "warning: joy-brain rev is not pinned yet (joyBrainRev is empty) - clone is at HEAD" >&2
      ''
    }
    fi
  '';

  home.activation.joyBrainInstantiate = lib.hm.dag.entryAfter [ "joyBrainClone" ] ''
    _src="${joyBrainDir}"
    _home="${hermesHome}"
    _yq=${pkgs.yq-go}/bin/yq

    $DRY_RUN_CMD mkdir -p "$_home"

    # config.yaml: first activation copies joy-brain's config; every activation
    # then deep-merges ONLY the browser.cdp_url override into the on-disk file,
    # so Hermes's own runtime edits (`hermes config set`, TUI settings) survive.
    if [ ! -e "$_home/config.yaml" ] && [ -e "$_src/config.yaml" ]; then
      $DRY_RUN_CMD cp "$_src/config.yaml" "$_home/config.yaml"
    fi
    if [ -e "$_home/config.yaml" ]; then
      $_yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' \
        "$_home/config.yaml" ${lib.escapeShellArg browserOverride} > "$_home/config.yaml.tmp" \
        && $DRY_RUN_CMD mv "$_home/config.yaml.tmp" "$_home/config.yaml"
    fi

    # Identity + context files: read-only symlinks into the clone.
    for _f in SOUL.md .hermes.md; do
      if [ -e "$_src/$_f" ] && [ ! -e "$_home/$_f" ]; then
        $DRY_RUN_CMD ln -sfn "$_src/$_f" "$_home/$_f"
      fi
    done

    # Private state dirs: symlink whichever of these joy-brain actually has
    # (guarded, so a missing dir is skipped rather than failing activation).
    # scripts/ + bin/ are included because the browser skills above reference
    # the cdp-*.py helpers that live there (and those helpers already target
    # the proxy contract at localhost:3333).
    for _d in bin contacts memory memories plugins profiles scripts; do
      if [ -d "$_src/$_d" ] && [ ! -e "$_home/$_d" ]; then
        $DRY_RUN_CMD ln -sfn "$_src/$_d" "$_home/$_d"
      fi
    done
    # Bridge: Hermes v0.21 reads memories/ (plural); an older joy-brain layout
    # used memory/ (singular). If only memory/ exists, expose it as memories/ too.
    if [ -d "$_src/memory" ] && [ ! -e "$_src/memories" ] && [ ! -e "$_home/memories" ]; then
      $DRY_RUN_CMD ln -sfn "$_src/memory" "$_home/memories"
    fi

    # Skills: ONLY the curated subset (never all of joy-brain/skills).
    $DRY_RUN_CMD mkdir -p "$_home/skills"
    for _s in ${lib.escapeShellArgs includedSkills}; do
      if [ -d "$_src/skills/$_s" ]; then
        $DRY_RUN_CMD mkdir -p "$(dirname "$_home/skills/$_s")"
        $DRY_RUN_CMD ln -sfn "$_src/skills/$_s" "$_home/skills/$_s"
      else
        echo "warning: joy-brain skill '$_s' not found under $_src/skills - not instantiated" >&2
      fi
    done
  '';
}
