#!/usr/bin/env bash
# Installs the `backups` command (the helper commands, backups.sh) for the user running
# it (on the VPS, `deploy`), as a small file in ~/.local/bin that runs backups.sh with
# bash. Ubuntu puts ~/.local/bin on PATH at login when the folder exists, so after the
# first install, log in again (or `sudo -iu deploy`) and `backups` works.
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
