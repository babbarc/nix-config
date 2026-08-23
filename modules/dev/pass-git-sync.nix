{ config, lib, pkgs, ... }:
{
  # Auto-sync the captain's `pass` password store (~/.password-store, already
  # a git repo with a remote named `origin` on every host) after every
  # mutation, so it stays in sync across hosts without manual `pass git
  # push`/`pass git pull`. Deliberately git-hook-only - no wrapper around the
  # `pass` binary, nothing shadowing it in PATH. `pass` already runs `git
  # commit` internally on every mutating command (insert/generate/rm/mv/cp/
  # edit), so a post-commit hook fires automatically with no `pass`-side
  # changes needed.
  home.packages = [ pkgs.git ];

  # Only wires the hook into a store that's already cloned onto this host -
  # never creates or initializes one (setup.sh's clone-on-first-boot step
  # handles that separately). Rewritten idempotently on every activation,
  # same as every other activation script here.
  home.activation.passGitSyncHook = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    PATH="${pkgs.git}/bin:$PATH"
    store_git_dir="${config.home.homeDirectory}/.password-store/.git"
    if [ -d "$store_git_dir" ]; then
      hook="$store_git_dir/hooks/post-commit"
      cat > "$hook" <<'EOF'
#!/usr/bin/env sh
if ! ${pkgs.git}/bin/git pull --rebase --autostash; then
  ${pkgs.git}/bin/git rebase --abort 2>/dev/null
  echo "pass-git-sync: could not sync - your change is saved locally but not pushed. Resolve manually (cd ~/.password-store)." >&2
  exit 0
fi
if ! ${pkgs.git}/bin/git push; then
  echo "pass-git-sync: push failed - your change is saved locally but not yet pushed. Run 'pass git push' manually." >&2
fi
EOF
      chmod 0755 "$hook"
    fi
  '';
}
