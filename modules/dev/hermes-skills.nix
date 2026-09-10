{ config, lib, pkgs, ... }:
let
  hermesHome = "${config.home.homeDirectory}/.hermes";

  # Purpose-built, AXI-shaped skill set for the curated (wsl) Hermes instance -
  # the firstmate-delegated browser + Windows-desktop + secure-`pass` operator.
  # These REPLACE the joy-brain browser/security skills that
  # modules/dev/joy-brain.nix used to symlink in (its `includedSkills` is now
  # empty - see the cutover note there). They are vendored in this repo, the
  # same posture as modules/dev/hermes-soul.md: repo-tracked, restored on every
  # rebuild, never pulled from the private joy-brain clone.
  #
  # Scope: wsl only (captain decision 2026-09-09). Deliberately NOT imported by
  # the alps full brain (hosts/hermes/home.nix), which keeps joy-brain's own
  # skill tree.
  #
  # This module materializes the skills and packages the CLIs they call
  # (`pass-axi` for pass-access, `hermes-web-login` for web-login). The remaining
  # wrapper binary the SKILL.md files point at (recover-page) and the
  # chrome-devtools-axi proxy env/warm-up wrapper land in follow-up changes;
  # those SKILL.md files still document their interim path.
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
  # Runs after joyBrainInstantiate (which creates ~/.hermes and its skills/
  # dir, and - post-cutover - prunes any stale joy-brain skill symlinks).
  home.activation.hermesSkillsInstall =
    lib.hm.dag.entryAfter [ "joyBrainInstantiate" ] ''
      _home=${lib.escapeShellArg hermesHome}
      $DRY_RUN_CMD mkdir -p "$_home/skills"
      for _s in ${lib.escapeShellArgs skillNames}; do
        $DRY_RUN_CMD ln -sfn "${skillsSrc}/$_s" "$_home/skills/$_s"
      done
    '';

  # `pass-axi` (pass-access) and `hermes-web-login` (web-login) on PATH via the
  # nix profile so they resolve for the Hermes agent regardless of shell. Both
  # read the captain's real store at ~/.password-store.
  home.packages = [ passAxi hermesWebLogin ];
}
