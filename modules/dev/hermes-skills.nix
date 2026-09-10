{ config, lib, pkgs, ... }:
let
  hermesHome = "${config.home.homeDirectory}/.hermes";

  # Purpose-built, AXI-shaped skill set for the curated (wsl) Hermes instance.
  # The default profile is now the captain-facing ORCHESTRATOR, which never
  # executes domain work; these skills are the shared base capability set every
  # domain-expert profile sees through `skills.external_dirs` (see the expert
  # provisioning path in modules/dev/hermes-expert-new.nix).
  # They are vendored in this repo, the same posture as
  # modules/dev/hermes-soul.md and modules/dev/hermes-bin/: repo-tracked,
  # restored on every rebuild, never pulled from a private external repo.
  #
  # Scope: wsl only (captain decision 2026-09-09). Deliberately NOT imported by
  # the alps full brain (hosts/hermes/home.nix), which keeps its own skill tree.
  #
  # This module materializes the skills and packages the CLIs they call
  # (`pass-axi` for pass-access, `hermes-web-login` for web-login, `hermes-browse`
  # for browse, `recover-page` for recover-blocked-page).
  skillsSrc = ./hermes-skills;
  skillNames = builtins.attrNames
    (lib.filterAttrs (_: t: t == "directory") (builtins.readDir skillsSrc));

  # pass-axi: the safe-by-construction `pass` access CLI for the `pass-access`
  # skill. Metadata only - it has no show/get/cat, so it cannot dump a secret.
  # `inspect` and `otp` decrypt through the sanctioned path (the ~/.hermes/bin
  # helpers + the pass-otp extension), not a reimplementation. It reads the real
  # store at ~/.password-store (override with PASSWORD_STORE_DIR).
  #
  # runtimeInputs pins the whole closure so the CLI works from a non-interactive
  # `hermes` invocation, not just an interactive shell: pass (with pass-otp for
  # `pass otp`), gnupg for the `doctor` gpg checks, python3 + bash so the
  # ~/.hermes/bin/{pass-to,pass-inspect} helper shebangs resolve, and the
  # coreutils/find/grep/sed userland the script uses.
  passAxi = pkgs.writeShellApplication {
    name = "pass-axi";
    runtimeInputs = with pkgs; [
      (pass.withExtensions (exts: [ exts.pass-otp ]))
      gnupg
      python3
      bash
      coreutils
      findutils
      gnugrep
      gnused
    ];
    text = builtins.readFile ./hermes-skills/pass-access/scripts/pass-axi;
  };

  # hermes-web-login: the zero-exposure credential / OTP entry path for the
  # `web-login` skill - the only sanctioned way for a secret to reach a web
  # page. The secret is read INSIDE the script from `pass` (via the
  # ~/.hermes/bin/pass-to helper) and pushed GPG -> pipe -> python memory -> CDP
  # `Runtime.evaluate` -> DOM; it is never an argument, never printed, never on
  # stdout, never in a tool-call record. Full surface: web-login/SKILL.md.
  #
  # The logic is the vendored python script; writeShellApplication just execs it
  # under a pinned runtime closure so it resolves from a non-interactive
  # `hermes` call, not only an interactive shell: python3 + websockets for the
  # CDP client, pass (with pass-otp) + gnupg for the internal `pass show` /
  # `pass otp`, bash + coreutils so the ~/.hermes/bin/pass-to helper shebang and
  # its `head -n 1` resolve.
  hermesWebLoginPython = pkgs.python3.withPackages (ps: [ ps.websockets ]);
  hermesWebLogin = pkgs.writeShellApplication {
    name = "hermes-web-login";
    runtimeInputs = with pkgs; [
      hermesWebLoginPython
      (pass.withExtensions (exts: [ exts.pass-otp ]))
      gnupg
      bash
      coreutils
    ];
    text = ''
      exec ${hermesWebLoginPython}/bin/python3 \
        ${./hermes-skills/web-login/scripts/hermes-web-login} "$@"
    '';
  };

  # hermes-browse: the `browse` skill's launcher for the chrome-devtools-axi
  # CLI. Its only jobs are to point the CLI at the persistent CDP proxy
  # (CHROME_DEVTOOLS_AXI_BROWSER_URL=http://localhost:3333), do the cold-start
  # warm-up against the idle-stopped proxy Chrome (POST :3335/show, then poll
  # :3333/json/version for webSocketDebuggerUrl), and retry the command once if
  # the first target lookup loses the race with a just-woken Chrome.
  #
  # chrome-devtools-axi is an npm global pinned by
  # modules/dev/agent-cli-tools.nix (`npm install -g`), NOT a nix package - so
  # it is resolved from PATH at runtime and is deliberately absent from
  # runtimeInputs; this wrapper never installs it. runtimeInputs pins only the
  # warm-up userland (curl for the probes, coreutils for `sleep`) so it works
  # from a non-interactive `hermes` call, not just an interactive shell.
  hermesBrowse = pkgs.writeShellApplication {
    name = "hermes-browse";
    runtimeInputs = with pkgs; [ curl coreutils ];
    text = builtins.readFile ./hermes-skills/browse/scripts/hermes-browse;
  };

  # recover-page: the `recover-blocked-page` skill's front end to the archive
  # ladder. The recovery logic is the vendored, byte-identical Hermes-core
  # script (recover_page.py, MIT) - re-sync it from a fresh Hermes install, do
  # not fork it. `recover-page` only reshapes the output: a content-first
  # no-arg / --help view, a one-line `ok: {route, provenance, snapshot_date,
  # saved}` with snapshot-age disclosure, and a definitive `ALL_ROUTES_FAILED`
  # line with the route trace on total failure.
  #
  # python3-only closure: recover_page.py is stdlib-only and the wrapper's own
  # JSON reshape runs in the same python3. `JINA_API_KEY` is optional and unset
  # here, so the script's route 3 is a no-op - fine. $RECOVER_PAGE_PY is pinned
  # to the sibling script's store path so it resolves from a non-interactive
  # `hermes` call, not just an interactive shell.
  recoverPage = pkgs.writeShellApplication {
    name = "recover-page";
    runtimeInputs = with pkgs; [ python3 ];
    text = ''
      export RECOVER_PAGE_PY=${./hermes-skills/recover-blocked-page/scripts/recover_page.py}
      ${builtins.readFile ./hermes-skills/recover-blocked-page/scripts/recover-page}
    '';
  };
in
{
  # Skill discovery needs NO trust/enable step: Hermes scans
  # {HERMES_HOME}/skills/ recursively (os.walk with followlinks=True) and any
  # dir with a SKILL.md registers as a "local" skill - visible in
  # `hermes skills list` (source: local) and loadable by the agent. `hermes
  # skills trust` is only for repo-local project skills (./.hermes/skills in a
  # git checkout), not this directory. Confirmed against the pinned engine
  # (tools/skills_tool.py `_find_all_skills` / agent/skill_utils.py
  # `iter_skill_index_files`).
  #
  # Runs after hermesHomeInstantiate (which creates ~/.hermes and its real
  # skills/ dir).
  home.activation.hermesSkillsInstall =
    lib.hm.dag.entryAfter [ "hermesHomeInstantiate" ] ''
      _home=${lib.escapeShellArg hermesHome}
      $DRY_RUN_CMD mkdir -p "$_home/skills"
      for _s in ${lib.escapeShellArgs skillNames}; do
        $DRY_RUN_CMD ln -sfn "${skillsSrc}/$_s" "$_home/skills/$_s"
      done
    '';

  # `pass-axi` (pass-access), `hermes-web-login` (web-login), `hermes-browse`
  # (browse) and `recover-page` (recover-blocked-page) on PATH via the nix
  # profile so they resolve for the Hermes agent regardless of shell. `pass-axi`
  # / `hermes-web-login` read the captain's real store at ~/.password-store;
  # `hermes-browse` drives the CDP proxy Chrome; `recover-page` fetches archive
  # copies over plain HTTP.
  home.packages = [ passAxi hermesWebLogin hermesBrowse recoverPage ];
}
