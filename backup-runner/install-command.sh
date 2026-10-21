#!/usr/bin/env bash
# Installs the `backups` command (the helper commands, backups.sh) for the user running
# it (on the VPS, `deploy`), as a small file in ~/.local/bin that runs backups.sh with
# bash, and puts ~/.local/bin on that user's PATH in every new shell: a login one
# (`sudo -iu deploy`, SSH) and an interactive one (`sudo su deploy`). Ubuntu's own
# dotfiles only do the first, and only when they are there. Shells already open need
# `exec bash -l`, or a new login, to pick it up.
#
#   bash install-command.sh
#   backups --help
set -euo pipefail

bin="$HOME/.local/bin"
mkdir -p "$bin"
# Written to a temp file and moved into place, so a running `backups` is never cut short.
cat > "$bin/backups.tmp" <<'EOF'
#!/usr/bin/env bash
# Installed by docker-infrastructure's backup-runner/install-command.sh.
exec bash "$HOME/backup-runner/backups.sh" "$@"
EOF
chmod 755 "$bin/backups.tmp"
mv "$bin/backups.tmp" "$bin/backups"
echo "installed $bin/backups"

# One line, added once to each file, that puts ~/.local/bin on PATH unless it is there.
# It is plain sh, so it also works in .profile.
tag='# backups command'
line="case \":\$PATH:\" in *\":\$HOME/.local/bin:\"*) ;; *) PATH=\"\$HOME/.local/bin:\$PATH\" ;; esac $tag"
add_path_line() {
  touch "$1"
  grep -qF "$tag" "$1" || printf '\n%s\n' "$line" >> "$1"
}

# Interactive shells that aren't login shells read ~/.bashrc.
add_path_line "$HOME/.bashrc"
# Login shells read the first of these that exists (a new ~/.profile if none does).
login_file="$HOME/.profile"
for f in .bash_profile .bash_login .profile; do
  if [ -e "$HOME/$f" ]; then login_file="$HOME/$f"; break; fi
done
add_path_line "$login_file"
echo "put $bin on PATH in ~/.bashrc and ~/$(basename "$login_file")"
