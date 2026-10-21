#!/usr/bin/env bash
# The backup runner. Cron starts it every hour as `deploy`. Each run backs up every app
# in ~/apps whose schedule says it is due: it runs the app's own recipe (backup.sh),
# encrypts the one file the recipe made, and uploads it to the backup bucket.
#
# The README's "Backups" section is the full description, including the app contract.
set -uo pipefail

# --- Settings ----------------------------------------------------------------------
# Each can be overridden from the environment; the tests use that to point the runner at
# a fake VPS. On the VPS the defaults are always right.
RUNNER_HOME="${BACKUP_RUNNER_HOME:-$HOME/backup-runner}"
APPS_DIR="${APPS_DIR:-$HOME/apps}"
STAGING_DIR="${STAGING_DIR:-$HOME/backups}"
BUCKET="${BACKUP_BUCKET:-r2:indy-center-backups}"
SCHEDULE="${BACKUP_SCHEDULE:-$(dirname "$0")/schedule.conf}"
MEDIA_BUCKETS="${BACKUP_MEDIA:-$(dirname "$0")/media.conf}"
SECRETS="$RUNNER_HOME/secrets"
LOG="$RUNNER_HOME/logs/runner.log"

# A recipe still running after this long is stopped and counts as failed.
RECIPE_TIMEOUT=2h
# The same for copying one media bucket.
MEDIA_COPY_TIMEOUT=1h

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

# --- Log -----------------------------------------------------------------------------
# Everything the runner and the recipes print goes to logs/runner.log. Once it passes
# 5 MB it becomes runner.log.1 (replacing the older one), so the log never tops 10 MB.
#   tail -f ~/backup-runner/logs/runner.log

mkdir -p "$(dirname "$LOG")"
if [ "$(stat -c %s "$LOG" 2>/dev/null || echo 0)" -gt $((5 * 1024 * 1024)) ]; then
  mv "$LOG" "$LOG.1"
fi
exec >>"$LOG" 2>&1

# Writes one timestamped line to the log.
log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*"; }

# Only one run at a time: if the last hour's run is still going (a slow recipe), this
# one stops, and the next hour's run picks up whatever was missed.
exec 9> "$RUNNER_HOME/logs/run.lock"
if ! flock -n 9; then
  log "run as $NOW skipped: the previous run is still running"
  exit 0
fi

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

# --- The schedule ------------------------------------------------------------------

# The hour (UTC) that nightly backups run: 07:00 UTC is 3am in Indianapolis in summer and
# 2am in winter. Apps backed up more often run on this hour too, then every N hours after.
NIGHTLY_HOUR=7

# Reads an app's line from the schedule file into EVERY (hours between backups) and KEEP
# (days frequent copies are kept; 0 means no frequent tier). An app with no line gets
# the default: nightly, no frequent tier.
#
# EVERY must divide 24 (1, 2, 3, 4, 6, 8, 12 or 24) so the hours repeat each day, and an
# app backed up more than once a day needs a frequent tier to keep the extra copies in.
# A line that breaks either rule is put in BAD_SCHEDULE, and the app falls back to the
# default.
read_schedule() {
  EVERY=24 KEEP=0 BAD_SCHEDULE=""
  local name every keep
  while read -r name every keep _; do
    [ "$name" = "$1" ] || continue
    if [[ "$every" =~ ^(1|2|3|4|6|8|12|24)$ && "${keep:-0}" =~ ^[0-9]+$ ]] \
      && { [ "$every" = 24 ] || (( keep > 0 )); }; then
      EVERY="$every" KEEP="${keep:-0}"
    else
      BAD_SCHEDULE="$name $every $keep"
    fi
  done < <(sed 's/#.*//' "$SCHEDULE" 2>/dev/null)
}

# Whether an app is due this run. Its hours are the nightly hour and every EVERY hours
# after it. It is also due if its last run was more than EVERY hours ago: a run missed
# while the VPS was down is made up at the next one, and a new app is backed up the
# first hour the runner sees it.
is_due() {
  read_schedule "$1"
  (( (HOUR - NIGHTLY_HOUR + 24) % EVERY == 0 )) && return 0
  local last
  last="$(cat "$STATE/$1.last-run" 2>/dev/null || echo 0)"
  (( RUN_HOUR - last > EVERY ))
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
upload() {
  local app="$1" file="$2" name="$3"
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

# --- The media copy ------------------------------------------------------------------
# The CMS keeps uploaded files in R2 buckets, not on the VPS, so no recipe holds them.
# Each night the runner copies new files from each bucket in media.conf into
# media/<bucket>/ in the backup bucket. It never deletes or overwrites there, so a
# database backup from any date still finds its files (decision 0002).

# The media buckets, one name per line, comments and blank lines skipped.
media_buckets() { sed 's/#.*//' "$MEDIA_BUCKETS" 2>/dev/null | awk 'NF { print $1 }'; }

# Copies new files from one media bucket, on the same R2 account as the backup bucket.
# --ignore-existing skips every file the copy already has, so nothing is ever replaced.
# R2 copies the files itself; they never pass through the VPS. A failure alerts.
copy_media() {
  local bucket="$1" out="$STAGING_DIR/media-$1.log" status detail
  # The source is on the backup bucket's rclone remote (r2:), so r2:payload-media.
  local source="${BUCKET%%:*}:$bucket"
  log "media copy: $bucket"
  mkdir -p "$STAGING_DIR"
  timeout "$MEDIA_COPY_TIMEOUT" rclone copy --ignore-existing -v \
    "$source" "$BUCKET/media/$bucket" > "$out" 2>&1
  status=$?
  cat "$out"
  if [ "$status" != 0 ]; then
    local why="rclone exited $status"
    # timeout exits 124 when it stops rclone.
    [ "$status" = 124 ] && why="still running after $MEDIA_COPY_TIMEOUT, so it was stopped"
    # rclone's own error lines; none if timeout stopped it.
    detail="$(grep -E ' (ERROR|NOTICE) *:' "$out" | tail -n 5)"
    alert "Media copy of **$bucket** failed: $why${detail:+.$'\n'\`\`\`$'\n'$detail$'\n'\`\`\`}"
  fi
  rm -f "$out"
}

# --- Results and the daily report ----------------------------------------------------
# Each app's latest result (backed up, failed, no data, no recipe) is kept in
# state/<app>, for the report. Last-good times and sizes come from the bucket itself, so
# they stay right after a rebuild loses the state folder.

STATE="$RUNNER_HOME/state"
mkdir -p "$STATE"

# Saves an app's result from this run: record <app> <result>.
record() { echo "$2" > "$STATE/$1"; }

# The bucket's top-level folders that hold app backups (media/ is the media copy's).
TIERS="frequent daily monthly"

# The time of an app's newest backup in any tier, as "2026-10-20 07:00", or "never".
# File names start with their time, so the last in sorted order is the newest.
last_good() {
  local tier newest
  newest="$(for tier in $TIERS; do rclone lsf --files-only "$BUCKET/$tier/$1/" 2>/dev/null; done \
    | sort | tail -n 1)"
  if [ -z "$newest" ]; then
    echo never
  else
    echo "${newest:0:10} ${newest:11:2}:${newest:13:2}"
  fi
}

# Bytes an app's backups take up across all tiers.
space_used() {
  local tier bytes total=0
  for tier in $TIERS; do
    bytes="$(rclone size --json "$BUCKET/$tier/$1/" 2>/dev/null | grep -o '"bytes":[0-9]*' | cut -d: -f2)"
    total=$((total + ${bytes:-0}))
  done
  echo "$total"
}

# Bytes as people read them: 1536 becomes 1.5KiB.
human() { numfmt --to=iec-i --suffix=B "${1:-0}"; }

# Builds the report and posts it to tech-team-notifications.
send_report() {
  local rows="" notes="" total=0 dir app result bytes when
  for dir in "$APPS_DIR"/*/; do
    [ -d "$dir" ] || continue
    app="$(basename "$dir")"
    result="$(cat "$STATE/$app" 2>/dev/null || echo "not run yet")"
    # Backed up but can't be restored the standard way (decision 0005): say so.
    if [ -f "$dir/backup.sh" ] && [ ! -f "$dir/restore.sh" ]; then
      notes+="$app has no restore.sh"$'\n'
    fi
    case "$result" in
      "no data" | "no recipe") rows+="$(printf '%-16s %s' "$app" "$result")"$'\n' ;;
      *)
        bytes="$(space_used "$app")"
        total=$((total + ${bytes:-0}))
        when="$(last_good "$app")"
        rows+="$(printf '%-16s %-10s %-17s %s' "$app" "$result" "$when" "$(human "$bytes")")"$'\n'
        ;;
    esac
  done
  # The media copy, per bucket, after the apps' total: it only ever grows, so adding it
  # in would hide the apps' own growth. Its sizes line up under "space".
  local media="" bucket stats count files
  for bucket in $(media_buckets); do
    if stats="$(rclone size --json "$BUCKET/media/$bucket/" 2>/dev/null)"; then
      count="$(echo "$stats" | grep -o '"count":[0-9]*' | cut -d: -f2)"
      bytes="$(echo "$stats" | grep -o '"bytes":[0-9]*' | cut -d: -f2)"
      files="${count:-0} files"
      [ "$files" = "1 files" ] && files="1 file"
      media+="$(printf '%-28s %-16s %s' "media/$bucket" "$files" "$(human "$bytes")")"$'\n'
    else
      media+="$(printf '%-28s %s' "media/$bucket" "size unknown: rclone size failed")"$'\n'
    fi
  done
  post_discord report-webhook.url "**Backups for $DAY** (times UTC)
\`\`\`
$(printf '%-16s %-10s %-17s %s' app result "last good" space)
${rows}total space: $(human "$total")
${media}\`\`\`${notes:+$'\n'$notes}"
  log "report sent"
}

# Tells the status page the day's backups finished, so it can alert if this never comes.
# Until the status page exists its secret files are absent, and this is skipped quietly.
ping_status_page() {
  local url_file="$SECRETS/status-ping.url" secret_file="$SECRETS/status-ping.secret"
  if [ ! -s "$url_file" ] || [ ! -s "$secret_file" ]; then
    log "no status page secret, ping skipped"
    return
  fi
  # The secret goes in a header read from stdin, so it never appears in a command line.
  if printf 'Authorization: Bearer %s\n' "$(cat "$secret_file")" \
    | curl -fsS --max-time 30 --retry 2 -o /dev/null -X POST -H @- "$(cat "$url_file")"; then
    log "status page pinged"
  else
    log "status page ping failed"
  fi
}

# --- The run -------------------------------------------------------------------------

log "run as $NOW"
for dir in "$APPS_DIR"/*/; do
  [ -d "$dir" ] || continue
  app="$(basename "$dir")"
  is_due "$app" || continue
  echo "$RUN_HOUR" > "$STATE/$app.last-run"
  if [ -n "$BAD_SCHEDULE" ]; then
    alert "The schedule line \`$BAD_SCHEDULE\` for **$app** is not valid (every: 1, 2, 3, 4, 6, 8, 12 or 24 hours; keep: whole days, more than 0 unless every is 24), so $app is on the default, nightly."
  fi

  # The app contract: backup.sh, or a no-backup marker for an app with nothing to keep.
  if [ -f "$dir/backup.sh" ]; then
    if back_up "$app"; then record "$app" "backed up"; else record "$app" failed; fi
  elif [ -e "$dir/no-backup" ]; then
    log "$app: no-backup marker, nothing to back up"
    record "$app" "no data"
  else
    alert "**$app** has no backup.sh and no no-backup marker in ${dir%/}, so it is not being backed up."
    record "$app" "no recipe"
  fi
done

# The media copy is nightly, and made up at the next run if a night was missed, as an
# app's backup is.
last_media_copy="$(cat "$STATE/media-copy.last-run" 2>/dev/null || echo 0)"
if (( HOUR == NIGHTLY_HOUR || RUN_HOUR - last_media_copy > 24 )); then
  echo "$RUN_HOUR" > "$STATE/media-copy.last-run"
  buckets="$(media_buckets)"
  # A missing, unreadable or empty media.conf would otherwise stop the copy silently.
  [ -n "$buckets" ] || alert "Media copy skipped: no buckets listed in $MEDIA_BUCKETS (missing, unreadable or empty), so no media was copied."
  for bucket in $buckets; do
    copy_media "$bucket"
  done
fi

# Once a day, after the nightly backups: the report, then the status page's ping. If the
# nightly run was missed, the first run after it sends them.
if (( HOUR >= NIGHTLY_HOUR )) && [ "$(cat "$STATE/report-day" 2>/dev/null)" != "$DAY" ]; then
  send_report
  ping_status_page
  echo "$DAY" > "$STATE/report-day"
fi
log "run done"
