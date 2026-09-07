{ ... }:
{
  # The `joy` hermes-agent stack, declared as config-as-code for the separate
  # `hermes` system user (uid 1003, gid 1004, home /home/hermes) that runs it
  # rootless under podman. Phase 6 of the hermes-agent migration - see
  # /home/yeti/firstmate/data/hermes-agent-stack-scout/report.md section 4d
  # and the Phase 6 row of its phased plan.
  #
  # Mirrors modules/dev/browser-proxy-firstmate.nix exactly: a plain
  # xdg.configFile drop of vendored *.container quadlet files into
  # ~/.config/containers/systemd/, NOT home-manager's structured
  # `services.podman.containers.*` generator (that would mean translating
  # every quadlet field into Nix attrs and would build the units at eval
  # time; a raw file drop matches what this repo already vendors and keeps
  # the files byte-comparable against their upstream source). podman's
  # rootless user quadlet generator reads *.container from
  # $XDG_CONFIG_HOME/containers/systemd/ and turns each into a systemd --user
  # unit at session start - no systemd.user.services translation needed.
  #
  # Source of truth for the quadlets and the pinned image tags is the
  # joy-stack deployment overlay (Gitea gitea:babbarc/joy-stack.git). The
  # three files under containers/systemd/hermes/ are synced verbatim from it
  # (commit 515036a) apart from a vendoring header. This deliberately does
  # NOT adopt the upstream hermes-agent repo's nix/nixosModules.nix /
  # services.hermes-agent: that module builds an ubuntu:24.04 + /nix/store
  # image, not the fleet's forked OCI image, so it does not fit. Vendor the
  # quadlets + a pinned Image= and be done.
  #
  # Scope boundary (imperative state stays out of this repo, by design):
  #   - hermes-data / hermes-browser-data / qmd-data named volumes and their
  #     contents (the joy-brain working tree, pass/.ssh/.gnupg for the hermes
  #     user) are data, not config. They live in joy-brain and on the host,
  #     never here. The quadlets reference them by plain name only.
  #   - Building/pulling the four localhost/*:v2026.8.31-babbarc.1 images
  #     (hermes, browser-proxy, hermes-browser, qmd) is the overlay's
  #     build.sh job, run by hand on alps - deliberately not scripted here.
  #   - Creating the `hermes` user, `loginctl enable-linger hermes`, and the
  #     /mnt/nebula ACL for the runtime UID are root-only and cannot be
  #     declared by standalone (per-user) home-manager on Arch. They are
  #     already in place on the live host (verified: user exists uid 1003;
  #     `loginctl show-user hermes` -> Linger=yes; `getfacl /mnt/nebula` ->
  #     `user:hermes:rwx` present). The PR that introduced this module lists
  #     the exact one-time root commands for a fresh host.
  xdg.configFile."containers/systemd/hermes.container".source =
    ../containers/systemd/hermes/hermes.container;
  xdg.configFile."containers/systemd/browser-proxy.container".source =
    ../containers/systemd/hermes/browser-proxy.container;
  xdg.configFile."containers/systemd/qmd.container".source =
    ../containers/systemd/hermes/qmd.container;
}
