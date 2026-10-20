#!/usr/bin/env bash
# Installs the runner's hourly crontab entry for the user running it (on the VPS,
# `deploy`). It replaces the entry an earlier deploy installed, found by the
# "# backup-runner" tag at its end, and leaves every other crontab line alone.
#
#   bash install-cron.sh
#   crontab -l      # to see it
set -euo pipefail

tag='# backup-runner'

# Minute 7 of every hour. Cron's own output (only if the runner cannot start at all)
# goes to the same log the runner writes.
entry="7 * * * * bash \"\$HOME/backup-runner/run-backups.sh\" >> \"\$HOME/backup-runner/logs/runner.log\" 2>&1 $tag"

mkdir -p "$HOME/backup-runner/logs"
{
  crontab -l 2>/dev/null | grep -vF "$tag" || true
  echo "$entry"
} | crontab -
echo "crontab entry installed: $entry"
