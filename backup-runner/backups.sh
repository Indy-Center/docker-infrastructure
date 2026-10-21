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

# Prints a message to stderr and stops. A command made of steps sets STEP first, and the
# message then names the step that failed.
STEP=""
die() { echo "${STEP:+Failed at $STEP: }$*" >&2; exit 1; }

# --- Cleaning up -----------------------------------------------------------------------
# Decrypted backups and recipe output hold members' data, so whatever a command puts in
# staging or a temp folder, or loads into a throwaway container, is removed when it ends,
# however it ends: done, failed, Ctrl-C, killed, or its SSH session dropped (a hang-up).

CLEANUP=() CONTAINERS=()
# Marks paths to remove when this command ends.
remove_on_exit() { CLEANUP+=("$@"); }
# Marks a container to remove, with its data, when this command ends.
remove_container_on_exit() { CONTAINERS+=("$1"); }
trap 'rm -rf "${CLEANUP[@]}"
  [ "${#CONTAINERS[@]}" = 0 ] || docker rm -f -v "${CONTAINERS[@]}" > /dev/null 2>&1' EXIT
# Each of these signals ends the command through the EXIT trap above.
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# Makes a new staging folder for this command, ~/backups/.<name>.XXXXXX, that only deploy
# can open and that is removed when the command ends. Sets STAGE to its path. Its own
# name keeps it apart from the runner's ~/backups/<app> and from other helper commands.
new_stage() {
  mkdir -p "$STAGING_DIR"
  STAGE="$(mktemp -d "$STAGING_DIR/.$1.XXXXXX")" || die "Couldn't make a folder in $STAGING_DIR."
  remove_on_exit "$STAGE"
}

# A person is watching a helper, so its failures are shown to them rather than sent to
# tech-team-alerts (lib.sh's alert, which back_up uses).
alert() { log "not sent to Discord, as a person ran this: $1"; }

# For the commands that back up or restore, right before they do: waits for any hourly
# run to finish (the run lock), so the two never work on an app at once, then sends
# everything printed from here on to the runner's log as well. Take it as late as
# possible: while it is held, the hourly runs step aside.
lock_and_log() {
  open_lock
  if ! flock -n 9; then
    echo "The hourly run is going; waiting for it to finish (Ctrl-C to give up)…"
    flock 9
  fi
  # Only once the lock is held, so the runner is not rotating the log at the same time.
  rotate_log
  # tee closes the lock: it can outlive this command (fed by anything restore.sh left
  # running), and must not hold up the hourly runs while it does.
  exec > >(tee -a "$LOG" 9>&-) 2>&1
  log "backups $*, run by hand"
}

# --- Finding backups -------------------------------------------------------------------
# A backup is named for the UTC time of its run and the recipe's file:
# 2026-10-20T070000Z-payload.tar.age. The same file can sit in several tiers (the first
# of a day is copied to daily/, and so on), and all copies are the same backup.

# Lists a folder in the bucket with `rclone lsf`, options first, the folder last. A
# folder that doesn't exist lists as empty (rclone exits 3; on R2 an empty folder doesn't
# exist). Any other failure (R2 unreachable, a bad key, a broken rclone.conf) prints
# rclone's own error and returns non-zero, so it never reads as "nothing there".
list_bucket() {
  local err status
  # rclone's output goes straight out (fd 3); only its errors are caught, in err.
  { err="$(rclone lsf "$@" 2>&1 >&3 3>&-)"; status=$?; } 3>&1
  [ "$status" = 0 ] || [ "$status" = 3 ] && return 0
  echo "Couldn't list ${*: -1}: $(echo "$err" | tail -n 1)" >&2
  return 1
}

# Every backup of an app, one line each, oldest first: "<name> <bytes> <tiers…>".
app_backups() {
  local app="$1" tier listing all=""
  for tier in $TIERS; do
    listing="$(list_bucket --files-only --format ps --separator ' ' "$BUCKET/$tier/$app/")" || return 1
    [ -n "$listing" ] && all+="$(sed "s/\$/ $tier/" <<< "$listing")"$'\n'
  done
  printf '%s' "$all" | awk '
    # Joins the tiers of each name, keeping the order the tiers were listed in.
    { if (!($1 in size)) { size[$1] = $2; order[++n] = $1 }; tiers[$1] = tiers[$1] " " $3 }
    END { for (i = 1; i <= n; i++) print order[i], size[order[i]] tiers[order[i]] }
  ' | sort
}

# The same, but stops with a message if the app has no backups at all. Use it as
#   lines="$(backups_of "$app")" || exit 1
backups_of() {
  local lines
  lines="$(app_backups "$1")" || exit 1
  [ -n "$lines" ] || die "No backups of $1 in $BUCKET. Is the name right? Apps are named for their folder in $APPS_DIR."
  echo "$lines"
}

# Finds the one backup of an app that a person asked for: "latest", a full name, or the
# start of one (2026-10-20T07). Sets FOUND_NAME and FOUND_TIER (the first tier holding
# it), or stops with a message if none or several match.
find_backup() {
  local app="$1" want="$2" lines matches count
  lines="$(backups_of "$app")" || exit 1
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
  # Downloaded and decrypted in a hidden work folder beside the result, that only deploy
  # can open (mktemp -d makes it so), then moved into place: a failed or interrupted
  # fetch leaves nothing half-written, and the work folder goes when the command ends.
  local work
  work="$(mktemp -d "$folder/.fetching-XXXXXX")" || die "Can't write to $folder."
  remove_on_exit "$work"
  rclone copyto "$BUCKET/$FOUND_TIER/$app/$FOUND_NAME" "$work/$FOUND_NAME" || die "Download failed."
  age -d -i "$SECRETS/age.key" -o "$work/decrypted" "$work/$FOUND_NAME" \
    || die "Decrypting failed: is $SECRETS/age.key the key these backups were made with?"
  # It holds members' data: only deploy may read it, wherever it is moved to.
  chmod 600 "$work/decrypted"
  mv "$work/decrypted" "$FETCHED"
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
  lines="$(backups_of "$app")" || exit 1
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

help_now() {
  cat <<'EOF'
backups now <app>

Backs up one app straight away, for example right before a risky change. It runs the
app's backup.sh, encrypts the file and uploads it exactly as the hourly runner does, into
frequent/ (kept as long as R2's rule on frequent/ keeps files, 14 days today). It is never
copied to daily/ or monthly/, and the app's schedule carries on as before.

The app keeps running: a recipe takes a consistent copy while it is up. A failure is
shown here, not sent to Discord.

  backups now payload
EOF
}

cmd_now() {
  local app="${1:-}"
  need "$app" now
  [ -d "$APPS_DIR/$app" ] || die "No app $app: there is no folder $APPS_DIR/$app."
  [ -f "$APPS_DIR/$app/backup.sh" ] || die "$app has no backup.sh in $APPS_DIR/$app, so it can't be backed up."
  lock_and_log now "$app"
  # back_up removes its staging folder when it finishes; this covers being interrupted,
  # which would otherwise leave the recipe's unencrypted file there.
  remove_on_exit "$STAGING_DIR/$app"
  echo "Backing up $app into frequent/ with its backup.sh…"
  ONLY_FREQUENT=yes back_up "$app" || die "The backup of $app failed (above)."
  echo "Done: frequent/$app/ in $BUCKET. backups list $app shows it."
}

help_restore() {
  cat <<'EOF'
backups restore <app> <backup>

Puts one app's data back from a backup. It downloads and decrypts the backup, then, once
you type the app's name to confirm, runs the app's own restore.sh with the decrypted file.
restore.sh replaces the app's live data, stopping and starting what it needs to; anything
changed since that backup is lost.

<backup> is a name from `backups list <app>`, the start of one, or "latest". To keep
today's data as well, run `backups now <app>` first. The decrypted file is deleted when
the restore ends.

  backups restore payload 2026-10-20T07
EOF
}

cmd_restore() {
  local app="${1:-}" want="${2:-}"
  need "$want" restore
  local dir="$APPS_DIR/$app"
  [ -d "$dir" ] || die "No app $app: there is no folder $dir."
  # The app contract (decision 0005): without restore.sh there is no standard way back.
  [ -f "$dir/restore.sh" ] || die "$app has no restore.sh in $dir, so it can't be restored with this command. Its backups can still be fetched (backups fetch $app $want); putting the data back is then up to the app's own README."

  # The decrypted backup waits in its own staging folder, removed however this ends.
  new_stage "restore-$app"
  fetch_into "$app" "$want" "$STAGE"

  echo
  echo "This runs $dir/restore.sh with $FOUND_NAME."
  echo "It replaces $app's live data with the data from that backup."
  printf "Type the app's name (%s) to go ahead, anything else to stop: " "$app"
  local answer=""
  read -r answer || true
  [ "$answer" = "$app" ] || die "Stopped; nothing was changed."

  # Only now, with the answer given, wait for the run lock: a restore left at the
  # question above never holds up the hourly runs.
  lock_and_log restore "$app" "$FOUND_NAME"

  # Run as the runner runs a recipe: with bash, from the app's folder, with the lock kept
  # out of anything it starts.
  log "$app: running restore.sh with $FOUND_NAME"
  (cd "$dir" && bash restore.sh "$FETCHED") 9>&- < /dev/null
  local status=$?
  [ "$status" = 0 ] || die "restore.sh exited $status: the restore of $app failed (its output is above). Check the app before anything else."
  log "$app: restore.sh finished"
  echo "Done: $app is restored from $FOUND_NAME. Check it works."
}

# --- The scratch CMS database ----------------------------------------------------------
# A throwaway Postgres 17 (the CMS's version) loaded from a CMS backup, beside the live
# CMS and never touching it: to look at old data, or copy something out of it.

CMS_APP=payload
SCRATCH_CONTAINER="${BACKUP_SCRATCH_CONTAINER:-backups-scratch-cms}"
# Published on the VPS's loopback address only, for an SSH tunnel from a laptop.
SCRATCH_PORT="${BACKUP_SCRATCH_PORT:-15432}"

# Whether the scratch container exists, running or not.
scratch_exists() { [ -n "$(docker ps -aq -f name="^$SCRATCH_CONTAINER\$")" ]; }

# Whether a file is a pg_dump custom-format dump: those start "PGDMP".
is_dump() { [ "$(head -c 5 "$1")" = PGDMP ]; }

# Finds the database dump in a decrypted CMS backup and prints its path: the file itself
# if it is a custom-format dump, or the dump inside it if it is a tar archive. payload's
# recipe writes the archive: payload.tar, holding payload.dump and row-counts.tsv. An
# archive is unpacked beside it, in the staging folder.
find_dump() {
  local file="$1" unpacked f
  if is_dump "$file"; then
    echo "$file"
    return
  fi
  if tar -tf "$file" > /dev/null 2>&1; then
    unpacked="$(dirname "$file")/unpacked"
    mkdir "$unpacked" && tar -xf "$file" -C "$unpacked" || return 1
    # Each file in the archive, by name, until one is a dump.
    while IFS= read -r -d '' f; do
      is_dump "$f" && { echo "$f"; return; }
    done < <(find "$unpacked" -type f -print0 | sort -z)
  fi
  echo "$FOUND_NAME holds no pg_dump custom-format dump, neither as the file itself nor inside it as a tar archive." >&2
  return 1
}

# A new random password for a throwaway database.
new_password() { tr -dc a-z0-9 < /dev/urandom | head -c 20; }

# Starts a throwaway Postgres 17 (the CMS's version) with an empty database "payload",
# and waits until it answers. Any further arguments are docker run options, such as a
# published port. Returns 1 if docker run fails, 2 if it does not answer within a minute.
#   start_postgres <container> <password> [docker run options…]
start_postgres() {
  local name="$1" password="$2"
  shift 2
  docker run -d --name "$name" -e POSTGRES_PASSWORD="$password" -e POSTGRES_DB=payload \
    "$@" postgres:17 > /dev/null || return 1
  # Ready once it answers over TCP: while it sets itself up it listens on a socket only.
  local tries=0
  until docker exec "$name" pg_isready -h 127.0.0.1 -U postgres -q; do
    (( ++tries < 60 )) || return 2
    sleep 1
  done
}

# Loads a dump into a throwaway Postgres's "payload" database with pg_restore, over
# stdin, so nothing needs copying into the container. Ownership and grants are left out:
# the dump's tables belong to the live CMS's "payload" role, and the throwaway database
# has only the postgres user. Returns pg_restore's exit status.
#   load_dump <container> <dump>
load_dump() {
  docker exec -i "$1" pg_restore -U postgres -d payload --no-owner --no-privileges < "$2"
}

help_scratch-cms() {
  cat <<'EOF'
backups scratch-cms <backup>
backups scratch-cms remove

Loads one CMS (payload) backup into a throwaway Postgres 17 database, beside the live CMS,
so you can look at old data or copy something out of it. The live CMS is never touched.
<backup> is a name from `backups list payload`, the start of one, or "latest".

It starts a container named backups-scratch-cms, loads the backup into its database
"payload", and prints how to connect: with psql on the VPS, or from your computer over an
SSH tunnel (it listens on the VPS's 127.0.0.1:15432 only). Only one runs at a time.

`backups scratch-cms remove` deletes the container and its data when you are done.

  backups scratch-cms latest
  backups scratch-cms remove
EOF
}

cmd_scratch-cms() {
  local want="${1:-}"
  need "$want" scratch-cms
  if [ "$want" = remove ]; then
    scratch_exists || die "There is no scratch CMS database ($SCRATCH_CONTAINER) to remove."
    echo "Removing $SCRATCH_CONTAINER and its data…"
    docker rm -f -v "$SCRATCH_CONTAINER" > /dev/null || die "docker rm failed."
    echo "Done."
    return
  fi
  scratch_exists && die "A scratch CMS database is already running ($SCRATCH_CONTAINER). Remove it first: backups scratch-cms remove"

  # 1. The backup, decrypted into its own staging folder, removed however this ends.
  local dump
  new_stage scratch-cms
  fetch_into "$CMS_APP" "$want" "$STAGE"
  dump="$(find_dump "$FETCHED")" || exit 1

  # 2. A throwaway Postgres 17 with a new random password, on loopback only. -v on
  #    removal deletes its data volume too.
  local password status
  password="$(new_password)"
  echo "Starting a throwaway Postgres 17, $SCRATCH_CONTAINER…"
  start_postgres "$SCRATCH_CONTAINER" "$password" -p "127.0.0.1:$SCRATCH_PORT:5432"
  status=$?
  [ "$status" = 1 ] && die "docker run failed."
  [ "$status" = 2 ] && die "Postgres did not start within a minute: docker logs $SCRATCH_CONTAINER shows why. Remove it with: backups scratch-cms remove"

  # 3. Load the dump.
  echo "Loading $FOUND_NAME…"
  load_dump "$SCRATCH_CONTAINER" "$dump"
  status=$?
  rm -rf "$STAGE"
  [ "$status" = 0 ] || die "Loading failed: pg_restore exited $status (its errors are above), so the scratch database is incomplete or empty. It is still there to look at:
  docker exec -it $SCRATCH_CONTAINER psql -U postgres payload
Remove it with: backups scratch-cms remove"

  cat <<EOF

The scratch CMS database is ready, loaded from $FOUND_NAME. The live CMS is untouched.

On the VPS:
  docker exec -it $SCRATCH_CONTAINER psql -U postgres payload

From your computer, tunnel in (with your usual SSH login), then connect any Postgres tool:
  ssh -L $SCRATCH_PORT:127.0.0.1:$SCRATCH_PORT <you>@<vps>
  postgres://postgres:$password@127.0.0.1:$SCRATCH_PORT/payload

When you are done: backups scratch-cms remove
EOF
}

# --- The restore check -----------------------------------------------------------------
# Proves the newest CMS backup is usable: it loads into a throwaway Postgres 17, and holds
# at least the rows payload's recipe counted when it took the backup. The hourly runner
# runs it weekly and alerts if it fails; a person can run it any time.

RESTORE_CHECK_CONTAINER="${BACKUP_RESTORE_CHECK_CONTAINER:-backups-restore-check}"

help_restore-check() {
  cat <<'EOF'
backups restore-check

Checks that the newest CMS (payload) backup can be restored. It downloads and decrypts it,
loads it into a throwaway Postgres 17 container, and checks that every table the backup's
row-counts.tsv lists is there with at least the rows counted when the backup was taken.
The container is removed afterwards, pass or fail. The live CMS is never touched.

The hourly runner does this every Sunday and alerts in tech-team-alerts if it fails.
A failure here says which step failed.

  backups restore-check
EOF
}

# Compares each line of a backup's row counts ("table<TAB>rows", each table in public)
# with the loaded database. Prints one line per problem, and returns non-zero if any.
#   check_row_counts <container> <row-counts.tsv>
check_row_counts() {
  local container="$1" counts="$2" tables table want got problems="" checked=0
  tables="$(docker exec "$container" psql -U postgres -d payload -tAc \
    "SELECT tablename FROM pg_tables WHERE schemaname = 'public'" < /dev/null)" \
    || { echo "couldn't list the loaded database's tables"; return 1; }
  while IFS=$'\t' read -r table want _; do
    [ -n "$table" ] || continue
    checked=$((checked + 1))
    if [[ ! "$want" =~ ^[0-9]+$ ]]; then
      problems+="row-counts.tsv's line for $table has no row count: \"$want\""$'\n'
    elif ! grep -qxF -- "$table" <<< "$tables"; then
      problems+="table $table is missing"$'\n'
    else
      # Quoted as an identifier: any " in the name is doubled.
      got="$(docker exec "$container" psql -U postgres -d payload -tAc \
        "SELECT count(*) FROM public.\"${table//\"/\"\"}\"" < /dev/null)" \
        || { problems+="couldn't count the rows of $table"$'\n'; continue; }
      (( got >= want )) || problems+="table $table has $got rows; the backup counted $want"$'\n'
    fi
  done < "$counts"
  (( checked > 0 )) || problems+="row-counts.tsv lists no tables"$'\n'
  [ -z "$problems" ] && return 0
  printf '%s' "$problems"
  return 1
}

cmd_restore-check() {
  # 1. The newest backup, decrypted into its own staging folder, removed however this ends.
  STEP="download and decrypt"
  new_stage restore-check
  fetch_into "$CMS_APP" latest "$STAGE"

  STEP="unpack"
  local dump counts
  dump="$(find_dump "$FETCHED")" || die "see above."
  counts="$(dirname "$dump")/row-counts.tsv"
  [ -f "$counts" ] || die "$FOUND_NAME has no row-counts.tsv beside its dump, so there is nothing to check it against."

  # 2. A throwaway Postgres 17, on no port, removed with its data however this ends.
  STEP="start Postgres"
  echo "Starting a throwaway Postgres 17, $RESTORE_CHECK_CONTAINER…"
  docker rm -f -v "$RESTORE_CHECK_CONTAINER" > /dev/null 2>&1
  remove_container_on_exit "$RESTORE_CHECK_CONTAINER"
  start_postgres "$RESTORE_CHECK_CONTAINER" "$(new_password)" \
    || die "Postgres did not start: docker run failed, or it did not answer within a minute."

  # 3. Load it.
  STEP="load"
  echo "Loading $FOUND_NAME…"
  load_dump "$RESTORE_CHECK_CONTAINER" "$dump"
  local status=$?
  [ "$status" = 0 ] || die "pg_restore exited $status (its errors are above)."

  # 4. Every table there, with at least the rows counted at backup time.
  STEP="check tables"
  local problems
  problems="$(check_row_counts "$RESTORE_CHECK_CONTAINER" "$counts")" || die "$problems"

  STEP=""
  echo "Restore check passed: $FOUND_NAME loads, and every table in its row-counts.tsv holds at least the rows counted at backup time."
}

help_media-find() {
  cat <<'EOF'
backups media-find <text>

Searches the media copy (every file ever uploaded to the CMS) for files whose path
contains <text>, in any case. Prints each as <bucket>/<path>, ready for media-get.
Changes nothing.

  backups media-find plane
EOF
}

cmd_media-find() {
  local text="${1:-}"
  need "$text" media-find
  local all found
  all="$(list_bucket -R --files-only "$BUCKET/media/")" || exit 1
  found="$(grep -iF -- "$text" <<< "$all")"
  [ -n "$found" ] || die "No file in the media copy has \"$text\" in its path."
  echo "Files in the media copy matching \"$text\":"
  echo "$found"
}

help_media-get() {
  cat <<'EOF'
backups media-get <bucket>/<path> [folder]

Downloads one file from the media copy into a folder (the current one if none is given),
for example an image deleted from the CMS. <bucket>/<path> is a line from media-find.
Media files are not encrypted, so it is ready to use.

It changes nothing: the runner's R2 key can only read the CMS's buckets. It prints where
the file belongs, to upload it back in Cloudflare's dashboard.

  backups media-get payload-media/plane.png
EOF
}

cmd_media-get() {
  local path="${1:-}" folder="${2:-.}"
  need "$path" media-get
  # A bucket, then a file's path in it: payload-media/plane.png, not payload-media alone.
  [[ "$path" == ?*/*[^/] ]] || die "Give the file as <bucket>/<path>, as media-find prints it (payload-media/plane.png), not \"$path\"."
  local name="${path##*/}" bucket="${path%%/*}" key="${path#*/}"
  [ -d "$folder" ] || die "No folder $folder to download into."
  [ ! -e "$folder/$name" ] || die "$folder/$name already exists; move it or download into another folder."
  # lsf of one file lists it only if it exists.
  local listing
  listing="$(list_bucket "$BUCKET/media/$path")" || exit 1
  [ -n "$listing" ] || die "No file media/$path in the media copy. backups media-find <part of its name> finds it."
  echo "Downloading media/$path to $folder/$name"
  rclone copyto "$BUCKET/media/$path" "$folder/$name" || die "Download failed."
  echo "Done: $folder/$name"
  # The folder inside the bucket it goes back into, if any.
  local where="the bucket's top level"
  [ "$key" != "$name" ] && where="the folder ${key%/*}/"
  echo "To put it back in the CMS: Cloudflare dashboard → R2 → $bucket, open $where,"
  echo "and upload it there as $name, so the CMS finds it at $key again."
  # The dashboard is in a browser on your computer, and your own login can't read
  # deploy's files, so the file goes through /tmp.
  local file
  file="$(realpath "$folder/$name")"
  echo
  echo "To get it to your computer: here, as deploy, run"
  echo "  install -m 644 '$file' '/tmp/$name'"
  echo "then on your computer"
  echo "  scp '<you>@<vps>:/tmp/$name' ."
  echo "and delete /tmp/$name on the VPS once it's uploaded."
}

# --- Inventory -------------------------------------------------------------------------

help_inventory() {
  cat <<'EOF'
backups inventory

Prints, each under its own heading, the facts needed to plan work on the VPS: the
system, memory, disk, Docker's containers, images, volumes (with sizes) and networks,
each folder in ~/apps with the backup files it ships, and the backup runner's last run.
Agents have no access to the VPS, so run this and paste the whole output to them.

It only reads: it changes nothing, and needs no sudo.

  backups inventory
EOF
}

# Prints one heading, then the output of a command in a code block. A failing command
# prints its error and the inventory carries on.
section() {
  local title="$1"
  shift
  printf '\n## %s\n```\n' "$title"
  "$@" 2>&1 || echo "(that failed, exit $?)"
  echo '```'
}

# The parts of the inventory that need more than one command.
inv_system() {
  (. /etc/os-release && echo "$PRETTY_NAME")
  uname -srm
  echo "$(nproc) CPUs, $(uptime -p)"
  echo "docker: $(command -v docker || echo 'not found') $(docker version --format '{{.Server.Version}}' 2>&1)"
}

# The disks holding / and /home, each once when they are the same disk.
inv_disk() { df -h / /home | awk '!seen[$0]++'; }

# Volume sizes come from `docker system df -v`; only its volumes part is shown.
inv_volumes() {
  local all
  all="$(docker system df -v)" || { echo "$all"; return 1; }
  if grep -q '^Local Volumes' <<< "$all"; then
    awk '/^Local Volumes/ { on = 1 } /^Build cache/ { on = 0 } on' <<< "$all"
  else
    echo "$all"
  fi
}

# Each app folder, and which of the files the runner looks for (decision 0005) it has.
inv_apps() {
  local dir has f
  for dir in "$APPS_DIR"/*/; do
    [ -d "$dir" ] || continue
    has=""
    for f in backup.sh restore.sh no-backup; do
      [ -e "$dir/$f" ] && has+=" $f"
    done
    has="${has# }"
    printf '%-20s %s\n' "$(basename "$dir")" "${has:-none}"
  done
}

# The runner's crontab entry, tools, last runs and alerts, and each app's last result.
inv_runner() {
  echo "crontab: $(crontab -l 2>/dev/null | grep -F '# backup-runner' || echo 'no backup-runner entry')"
  echo "age $(age --version 2>&1), $(rclone version 2>&1 | head -n 1)"
  echo
  echo "Last runs (from $LOG):"
  grep -E ' (run as|run done)' "$LOG" 2>/dev/null | tail -n 6 || echo "(none in the log)"
  echo
  echo "Last alerts:"
  grep -F 'ALERT:' "$LOG" 2>/dev/null | tail -n 5 || echo "(none in the log)"
  echo
  echo "Each app's last result:"
  local f
  for f in "$STATE"/*; do
    [ -f "$f" ] || continue
    case "$f" in *.last-run | */report-day) continue ;; esac
    printf '%-20s %s\n' "$(basename "$f")" "$(cat "$f")"
  done
}

cmd_inventory() {
  echo "# VPS inventory, $(date -u +'%Y-%m-%d %H:%M UTC'), as $(whoami)"
  section "System" inv_system
  section "Memory" free -h
  section "Disk" inv_disk
  section "Containers" docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
  section "Images" docker images --format 'table {{.Repository}}:{{.Tag}}\t{{.ID}}\t{{.CreatedSince}}\t{{.Size}}'
  section "Volumes and their sizes" inv_volumes
  section "Docker networks" docker network ls
  section "Apps and their backup files" inv_apps
  section "Backup runner" inv_runner
}

# --- Help and dispatch -----------------------------------------------------------------

help_all() {
  cat <<'EOF'
backups: everyday backup jobs, run as deploy on the VPS.

  backups now <app>                  back up one app now, before a risky change
  backups list <app>                 list an app's backups, oldest first
  backups fetch <app> <backup>       download and decrypt one, to look inside it
  backups restore <app> <backup>     put an app's data back from a backup (asks first)
  backups scratch-cms <backup>       load a CMS backup into a throwaway database
  backups scratch-cms remove         and remove it again
  backups restore-check              check the newest CMS backup loads (weekly by itself)
  backups media-find <text>          find a CMS upload in the media copy
  backups media-get <bucket>/<path>  download one file from the media copy
  backups inventory                  print the VPS's facts, to paste to an agent

Every command takes --help, for example: backups list --help
Only restore changes a live app, and it asks first. now and restore also write to
~/backup-runner/logs/runner.log, as the hourly runs do.
EOF
}

command="${1:-}"
shift || true
case "$command" in
  "" | -h | --help | help) help_all ;;
  list | fetch | now | restore | scratch-cms | restore-check | media-find | media-get | inventory)
    # Each command's --help, wherever it is given.
    [[ " $* " == *" --help "* || " $* " == *" -h "* ]] && { "help_$command"; exit 0; }
    "cmd_$command" "$@"
    ;;
  *) die "No such command: $command. backups --help lists them." ;;
esac
