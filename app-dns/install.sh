#!/usr/bin/env bash
# Installs the `app-dns` command for the user running it (on the VPS, `deploy`), as a
# small file in ~/.local/bin that runs ~/app-dns/app-dns.py. An app's deploy runs it by
# that full path, since a command sent over SSH doesn't read the PATH lines in deploy's
# dotfiles. Interactive shells find it by name once the `backups` command's install has
# put ~/.local/bin on PATH.
#
#   bash ~/app-dns/install.sh
#   ~/.local/bin/app-dns --help
set -euo pipefail

bin="$HOME/.local/bin"
mkdir -p "$bin"
# Written to a temp file and moved into place, so a running `app-dns` is never cut short.
cat > "$bin/app-dns.tmp" <<'EOF'
#!/usr/bin/env bash
# Installed by docker-infrastructure's app-dns/install.sh.
exec python3 "$HOME/app-dns/app-dns.py" "$@"
EOF
chmod 755 "$bin/app-dns.tmp"
mv "$bin/app-dns.tmp" "$bin/app-dns"
echo "installed $bin/app-dns"
