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
  # This module does the skill materialization only. The wrapper binaries the
  # SKILL.md files point at (hermes-web-login, pass-axi, recover-page) and the
  # chrome-devtools-axi proxy env/warm-up wrapper land in follow-up changes;
  # each SKILL.md already documents the interim (no-wrapper) path.
  skillsSrc = ./hermes-skills;
  skillNames = builtins.attrNames
    (lib.filterAttrs (_: t: t == "directory") (builtins.readDir skillsSrc));
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
}
