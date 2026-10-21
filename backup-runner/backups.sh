#!/usr/bin/env bash
# The helper commands: everyday backup jobs for a person, one short command each, so
# nobody has to remember rclone or age. Run as `deploy` on the VPS:
#
#   backups --help
#
# (`backups` is installed by install-command.sh; `bash ~/backup-runner/backups.sh` is
# the same thing.) Each command prints what it is about to do, and asks before anything
# that changes a live app. The README's "Helper commands" section describes them all.
set -uo pipefail

# The runner's settings and its own backup steps (back_up), so a backup taken here is
# made exactly the way a scheduled one is.
source "$(dirname "$0")/lib.sh"

# Decrypted backups hold members' data: everything this script writes is for deploy only.
umask 077

# Prints a message to stderr and stops.
die() { echo "$*" >&2; exit 1; }

# --- Finding backups -------------------------------------------------------------------
# A backup is named for the UTC time of its run and the recipe's file:
# 2026-10-20T070000Z-payload.dump.age. The same file can sit in several tiers (the first
# of a day is copied to daily/, and so on), and all copies are the same backup.

# Every backup of an app, one line each, oldest first: "<name> <bytes> <tiers…>".
app_backups() {
  local app="$1" tier
  for tier in $TIERS; do
    rclone lsf --files-only --format ps --separator ' ' "$BUCKET/$tier/$app/" 2>/dev/null \
      | sed "s/\$/ $tier/"
  done | awk '
    # Joins the tiers of each name, keeping the order the tiers were listed in.
    { if (!($1 in size)) { size[$1] = $2; order[++n] = $1 }; tiers[$1] = tiers[$1] " " $3 }
    END { for (i = 1; i <= n; i++) print order[i], size[order[i]] tiers[order[i]] }
  ' | sort
}

# Finds the one backup of an app that a person asked for: "latest", a full name, or the
# start of one (2026-10-20T07). Sets FOUND_NAME and FOUND_TIER (the first tier holding
# it), or stops with a message if none or several match.
find_backup() {
  local app="$1" want="$2" lines matches count
  lines="$(app_backups "$app")"
  [ -n "$lines" ] || die "No backups of $app in $BUCKET. Is the name right? Apps are named for their folder in $APPS_DIR."
  if [ "$want" = latest ]; then
    matches="$(echo "$lines" | tail -n 1)"
  else
    matches="$(echo "$lines" | awk -v w="$want" 'index($1, w) == 1')"
  fi
  count="$(echo -n "$matches" | grep -c .)"
  [ "$count" != 0 ] || die "No backup of $app starts with \"$want\". backups list $app shows them."
  [ "$count" = 1 ] || die "\"$want\" matches $count backups of $app; give more of the name:
$(echo "$matches" | cut -d' ' -f1)"
  read -r FOUND_NAME _ FOUND_TIER _ <<< "$matches"
}

# Downloads one backup and decrypts it into a folder, under its name without .age.
# Never overwrites a file. Sets FETCHED to the decrypted file's path.
fetch_into() {
  local app="$1" want="$2" folder="$3"
  find_backup "$app" "$want"
  FETCHED="$folder/${FOUND_NAME%.age}"
  [ -d "$folder" ] || die "No folder $folder to fetch into."
  [ ! -e "$FETCHED" ] || die "$FETCHED already exists; move it or fetch into another folder."
  echo "Downloading $FOUND_TIER/$app/$FOUND_NAME and decrypting it to $FETCHED"
  # The encrypted file goes to a temp folder first, so a failed download or decrypt
  # leaves nothing half-written behind.
  local work
  work="$(mktemp -d)"
  if ! rclone copyto "$BUCKET/$FOUND_TIER/$app/$FOUND_NAME" "$work/$FOUND_NAME"; then
    rm -rf "$work"
    die "Download failed."
  fi
  if ! age -d -i "$SECRETS/age.key" -o "$work/decrypted" "$work/$FOUND_NAME"; then
    rm -rf "$work"
    die "Decrypting failed: is $SECRETS/age.key the key these backups were made with?"
  fi
  mv "$work/decrypted" "$FETCHED"
  rm -rf "$work"
}

# Stops with a command's help when a required argument is missing.
need() { [ -n "$1" ] || { "help_$2" >&2; exit 1; }; }

# --- Commands --------------------------------------------------------------------------

help_list() {
  cat <<'EOF'
backups list <app>

Lists every backup of one app, oldest first, so the newest is at the bottom. Each line is
the backup's name (its UTC time, then the file the app's recipe wrote), its size, and the
tiers it is kept in: frequent, daily (one a day, 60 days) and monthly (one a month, 12
months). Changes nothing.

Pass a backup's name, or just the start of it (2026-10-20T07), to fetch or restore.

  backups list payload
EOF
}

cmd_list() {
  local app="${1:-}" lines
  need "$app" list
  lines="$(app_backups "$app")"
  [ -n "$lines" ] || die "No backups of $app in $BUCKET. Is the name right? Apps are named for their folder in $APPS_DIR."
  echo "Backups of $app (UTC, oldest first):"
  # The size, printed as people read it, between the name and the tiers.
  local name bytes tiers
  while read -r name bytes tiers; do
    printf '%-44s %-9s %s\n' "$name" "$(human "$bytes")" "$tiers"
  done <<< "$lines"
}

help_fetch() {
  cat <<'EOF'
backups fetch <app> <backup> [folder]

Downloads one backup of an app and decrypts it into a folder (the current one if none is
given), so you can look inside it. <backup> is a name from `backups list <app>`, the
start of one (2026-10-20T07), or "latest". The file keeps its name, without .age.

It holds the app's data, members' details included, so only you can read it. Delete it
when you are done. Changes nothing on the live app.

  backups fetch payload latest
  backups fetch payload 2026-10-20T07 /tmp
EOF
}

cmd_fetch() {
  local app="${1:-}" want="${2:-}" folder="${3:-.}"
  need "$want" fetch
  fetch_into "$app" "$want" "$folder"
  echo "Done: $FETCHED"
  echo "Delete it when you are done: rm $FETCHED"
}

# --- Help and dispatch -----------------------------------------------------------------

help_all() {
  cat <<'EOF'
backups: everyday backup jobs, as deploy on the VPS.

  backups list <app>              list an app's backups, oldest first
  backups fetch <app> <backup>    download and decrypt one, to look inside it

Every command takes --help, for example: backups list --help
Everything is logged to ~/backup-runner/logs/runner.log, as the hourly runs are.
EOF
}

command="${1:-}"
shift || true
case "$command" in
  "" | -h | --help | help) help_all ;;
  list | fetch)
    # Each command's --help, wherever it is given.
    [[ " $* " == *" --help "* || " $* " == *" -h "* ]] && { "help_$command"; exit 0; }
    "cmd_$command" "$@"
    ;;
  *) die "No such command: $command. backups --help lists them." ;;
esac
