{ lib, pkgs, ... }:
{
  # Laptop-only gpg-agent/session-secret split (migration report S3.3,
  # decision S5.5): gpg-agent is the sole SSH-agent provider on every host
  # (modules/dev/gpg-agent.nix), and this module layers the laptop's
  # additional desktop-secret-service pieces on top - a Qt pinentry (laptop
  # has a display server; server/wsl use pinentry-curses instead, set
  # directly in their own host files) and pass-secret-service, so apps that
  # expect a freedesktop Secret Service can read the captain's `pass` store.
  services.gpg-agent.pinentry.package = pkgs.pinentry-qt;

  services.pass-secret-service.enable = true;

  # gpg-agent's own ssh support (enableSshSupport, set in
  # modules/dev/gpg-agent.nix) only wires up gpg-agent's ssh.socket - it
  # doesn't stop a distro/session default ssh-agent.socket or gcr's
  # gcr-ssh-agent.socket from also claiming SSH_AUTH_SOCK, which would race
  # with gpg-agent for the same role. Masking both keeps gpg-agent the sole
  # provider. Masking a unit that doesn't exist yet is a normal, idempotent
  # systemd operation (just a symlink to /dev/null in the user's systemd
  # config dir), so this is safe to run unconditionally on every activation.
  home.activation.maskConflictingSshAgentSockets = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    PATH="${pkgs.systemd}/bin:$PATH"
    $DRY_RUN_CMD ${pkgs.systemd}/bin/systemctl --user mask ssh-agent.socket gcr-ssh-agent.socket
  '';
}
