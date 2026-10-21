# The runner's shared parts: its settings, logging, Discord, and backing up one app.
# run-backups.sh (the hourly run) and backups.sh (the helper commands) both source this
# file, so a backup taken by hand goes through exactly the same steps as a scheduled one.
#
# Sourcing it only sets variables and defines functions: it creates and changes nothing.

# --- Settings ----------------------------------------------------------------------
# Each can be overridden from the environment; the tests use that to point the runner at
# a fake VPS. On the VPS the defaults are always right.
RUNNER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER_HOME="${BACKUP_RUNNER_HOME:-$HOME/backup-runner}"
APPS_DIR="${APPS_DIR:-$HOME/apps}"
STAGING_DIR="${STAGING_DIR:-$HOME/backups}"
BUCKET="${BACKUP_BUCKET:-r2:indy-center-backups}"
SCHEDULE="${BACKUP_SCHEDULE:-$RUNNER_DIR/schedule.conf}"
MEDIA_BUCKETS="${BACKUP_MEDIA:-$RUNNER_DIR/media.conf}"
SECRETS="$RUNNER_HOME/secrets"
LOG="$RUNNER_HOME/logs/runner.log"
STATE="$RUNNER_HOME/state"

# A recipe still running after this long is stopped and counts as failed.
RECIPE_TIMEOUT=2h

# Cron starts with a bare PATH. Add the runner's own age and rclone, and /snap/bin, where
# the snap's docker lives, so recipes can find it.
export PATH="$RUNNER_HOME/bin:/snap/bin:/usr/local/bin:$PATH"
export RCLONE_CONFIG="$SECRETS/rclone.conf"

# The time this run counts as, in UTC. Tests pass a chosen time; normally it is now.
NOW="$(date -u -d "${BACKUP_RUNNER_NOW:-now}" +%Y-%m-%dT%H:%M:%SZ)"
STAMP="$(date -u -d "$NOW" +%Y-%m-%dT%H%M%SZ)"
HOUR="$(date -u -d "$NOW" +%-H)"
DAY="${NOW:0:10}"
MONTH="${NOW:0:7}"
RUN_HOUR=$(( $(date -u -d "$NOW" +%s) / 3600 ))  # hours since 1970, for "how long ago"

# The bucket's top-level folders that hold app backups (media/ is the media copy's).
TIERS="frequent daily monthly"

# --- Log -----------------------------------------------------------------------------
# Everything the runner and the recipes print goes to logs/runner.log. Once it passes
# 5 MB it becomes runner.log.1 (replacing the older one), so the log never tops 10 MB.
#   tail -f ~/backup-runner/logs/runner.log

# Starts a fresh log if the current one is over 5 MB.
rotate_log() {
  mkdir -p "$(dirname "$LOG")"
  if [ "$(stat -c %s "$LOG" 2>/dev/null || echo 0)" -gt $((5 * 1024 * 1024)) ]; then
    mv "$LOG" "$LOG.1"
  fi
}

# Writes one timestamped line.
log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*"; }

# The run lock, so a run and a helper never back up or restore at the same time. Opens it
# on file descriptor 9; the caller then runs `flock -n 9` (give up) or `flock 9` (wait).
open_lock() {
  mkdir -p "$RUNNER_HOME/logs"
  exec 9> "$RUNNER_HOME/logs/run.lock"
}

# --- Discord ---------------------------------------------------------------------------

# Turns text into a JSON string, quotes included.
json_string() {
  local s
  s="$(printf '%s' "$1" | tr -d '\000-\010\013-\037')"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\n'/\\n}"
  printf '"%s"' "$s"
}

# Posts a message to the Discord webhook whose URL is in the given secrets file. A
# missing file is logged and skipped, so a runner without webhooks still backs up.
post_discord() {
  local url_file="$SECRETS/$1" text="$2"
  if [ ! -s "$url_file" ]; then
    log "no $1, not sent: $text"
    return
  fi
  # Discord refuses messages over 2000 characters.
  if [ "${#text}" -gt 1990 ]; then
    text="${text:0:1980}…"
  fi
  curl -fsS --max-time 30 --retry 2 -o /dev/null \
    -H 'Content-Type: application/json' \
    -d "{\"content\": $(json_string "$text")}" \
    "$(cat "$url_file")" || log "posting to $1 failed"
}

# An alert is something a person needs to act on. It goes to tech-team-alerts at once.
alert() {
  log "ALERT: $1"
  post_discord alert-webhook.url "$1"
}

# --- Uploading -----------------------------------------------------------------------

# Whether the bucket already holds a backup of this app in a tier whose name starts with
# the given prefix (a day, 2026-10-20, or a month, 2026-10). A tier folder that does not
# exist yet lists as empty.
has_backup() {
  local tier="$1" app="$2" prefix="$3"
  [ -n "$(rclone lsf --files-only --include "$prefix*" "$BUCKET/$tier/$app/" 2>/dev/null)" ]
}

# Uploads an encrypted backup, then promotes it: the first backup of each day is copied
# to daily/, the first of each month to monthly/, so each holds one copy per day or month.
# The copies are made inside the bucket, so the file crosses the network once.
# --immutable refuses to overwrite.
#
# An app with a frequent tier uploads to frequent/ every time. An app without one uploads
# its day's first backup straight to daily/, and any extra one that day (a made-up run,
# or the first run of a new app before 07:00) to frequent/.
#
# A backup taken by hand (ONLY_FREQUENT=yes, from `backups now`) goes to frequent/ and is
# never promoted, so daily/ and monthly/ keep holding the scheduled backups.
upload() {
  local app="$1" file="$2" name="$3"
  if [ "${ONLY_FREQUENT:-}" = yes ]; then
    rclone copyto --immutable "$file" "$BUCKET/frequent/$app/$name"
    return
  fi

  local uploaded_to first_of_day=no
  has_backup daily "$app" "$DAY" || first_of_day=yes

  if (( KEEP > 0 )) || [ "$first_of_day" = no ]; then
    uploaded_to="frequent/$app/$name"
  else
    uploaded_to="daily/$app/$name"
  fi
  rclone copyto --immutable "$file" "$BUCKET/$uploaded_to" || return 1

  if [ "$first_of_day" = yes ] && [ "$uploaded_to" != "daily/$app/$name" ]; then
    rclone copyto --immutable "$BUCKET/$uploaded_to" "$BUCKET/daily/$app/$name" || return 1
  fi
  if ! has_backup monthly "$app" "$MONTH"; then
    rclone copyto --immutable "$BUCKET/$uploaded_to" "$BUCKET/monthly/$app/$name" || return 1
  fi
}

# --- Backing up one app ------------------------------------------------------------

# Runs one app's recipe in an empty staging folder, encrypts the one file it made, and
# uploads it. On any failure it alerts, naming the step, and returns non-zero. The
# staging folder is removed either way.
back_up() {
  local app="$1"
  local stage="$STAGING_DIR/$app"
  rm -rf "$stage"
  mkdir -p "$stage/out"

  # 1. The recipe, run from the app's folder with bash (the deploy's rsync drops the
  #    execute bit). Its output is kept for the alert as well as the log. 9>&- keeps
  #    the run lock out of anything the recipe starts.
  log "$app: running backup.sh"
  (cd "$APPS_DIR/$app" && timeout "$RECIPE_TIMEOUT" bash backup.sh "$stage/out") \
    > "$stage/recipe.log" 2>&1 9>&- < /dev/null
  local status=$?
  cat "$stage/recipe.log"
  if [ "$status" != 0 ]; then
    fail_app "$app" "backup.sh exited $status" "$(tail -n 10 "$stage/recipe.log")"
    return 1
  fi

  # 2. Exactly one file, or the recipe broke the contract.
  local written file
  written="$(ls -A "$stage/out")"
  if [ -z "$written" ] || [ "$(echo "$written" | wc -l)" != 1 ] || [ ! -f "$stage/out/$written" ]; then
    fail_app "$app" "backup.sh must write exactly one file, but wrote: ${written:-nothing}"
    return 1
  fi
  file="$written"

  # 3. Encrypt it with the age key, then drop the unencrypted copy.
  if ! age -e -i "$SECRETS/age.key" -o "$stage/$file.age" "$stage/out/$file" 2> "$stage/age.log"; then
    fail_app "$app" "encryption failed" "$(cat "$stage/age.log")"
    return 1
  fi
  rm -f "$stage/out/$file"

  # 4. Upload and promote.
  if ! upload "$app" "$stage/$file.age" "$STAMP-$file.age" 2> "$stage/rclone.log"; then
    cat "$stage/rclone.log"
    fail_app "$app" "upload failed" "$(tail -n 5 "$stage/rclone.log")"
    return 1
  fi

  rm -rf "$stage"
  log "$app: backed up $STAMP-$file.age"
}

# Alerts that one app's backup failed and removes its staging folder.
fail_app() {
  local app="$1" what="$2" detail="${3:-}"
  rm -rf "${STAGING_DIR:?}/$app"
  alert "Backup of **$app** failed: $what.${detail:+$'\n'\`\`\`$'\n'$detail$'\n'\`\`\`}"
}

# Bytes as people read them: 1536 becomes 1.5KiB.
human() { numfmt --to=iec-i --suffix=B "${1:-0}"; }
