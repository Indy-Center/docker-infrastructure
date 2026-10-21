#!/usr/bin/env bash
# The backup runner. Cron starts it every hour as `deploy`. Each run backs up every app
# in ~/apps whose schedule says it is due: it runs the app's own recipe (backup.sh),
# encrypts the one file the recipe made, and uploads it to the backup bucket.
#
# The README's "Backups" section is the full description, including the app contract.
set -uo pipefail

# Settings, the log, Discord, and backing up one app (back_up), shared with the helper
# commands in backups.sh.
source "$(dirname "$0")/lib.sh"

# Like a recipe's time limit (lib.sh), for copying one media bucket.
MEDIA_COPY_TIMEOUT=1h

# Only one run at a time: if the last hour's run is still going (a slow recipe), this
# one stops, and the next hour's run picks up whatever was missed. A helper command
# (backups.sh) holds the same lock.
open_lock
if ! flock -n 9; then
  log "run as $NOW skipped: the previous run is still running" >>"$LOG" 2>&1
  exit 0
fi

# Everything this run prints goes to the log (lib.sh, "Log"). Rotated only with the lock
# held, so no helper command is writing to it at the time.
rotate_log
exec >>"$LOG" 2>&1

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

# --- The weekly restore check --------------------------------------------------------
# Every Sunday, in the nightly run after the backups, `backups restore-check` loads the
# newest CMS backup into a throwaway Postgres and checks its tables and row counts
# (backups.sh, "The restore check"). Only on a box that runs the CMS.

# Sunday, as `date +%u` numbers the days.
RESTORE_CHECK_DAY=7
# Like a recipe's time limit (lib.sh). Loading today's CMS takes well under a minute.
RESTORE_CHECK_TIMEOUT=30m

# Whether this box runs the CMS, so has a CMS backup to check.
has_cms() { [ -f "$APPS_DIR/$CMS_APP/backup.sh" ]; }

# Whether the check is due: on Sunday at the nightly hour, or a week after the last check
# if a Sunday was missed.
restore_check_due() {
  local last
  last="$(cat "$STATE/restore-check.last-run")"
  (( HOUR == NIGHTLY_HOUR && $(date -u -d "$NOW" +%u) == RESTORE_CHECK_DAY )) && return 0
  (( RUN_HOUR - last >= 7 * 24 ))
}

# Runs the check, keeps its result for the report, and alerts if it fails. A check that
# times out shows as failed in the report, without an alert. The check removes its
# container however it ends, a timeout included: timeout stops it with TERM, which it
# traps, and KILLs it a minute later if it is still going. A container left by that is
# removed by the next check before it starts its own.
run_restore_check() {
  local out="$STAGING_DIR/restore-check.log" status when
  when="$(date -u -d "$NOW" '+%Y-%m-%d %H:%M')"
  log "restore check of the newest $CMS_APP backup"
  mkdir -p "$STAGING_DIR"
  # This run holds the run lock, so the check must not wait for it.
  BACKUP_RUN_LOCK_HELD=yes timeout -k 1m "$RESTORE_CHECK_TIMEOUT" \
    bash "$RUNNER_DIR/backups.sh" restore-check > "$out" 2>&1 9>&- < /dev/null
  status=$?
  cat "$out"
  if [ "$status" = 0 ]; then
    echo "passed $when" > "$STATE/restore-check"
  # timeout exits 124 when it stops the check, 137 when it has to kill it.
  elif [ "$status" = 124 ] || [ "$status" = 137 ]; then
    echo "failed $when" > "$STATE/restore-check"
    log "restore check still running after $RESTORE_CHECK_TIMEOUT, so it was stopped"
  else
    echo "failed $when" > "$STATE/restore-check"
    local detail
    # From the line naming the step that failed (backups.sh's die), or the last lines.
    detail="$(sed -n '/^Failed at /,$p' "$out" | head -n 15)"
    [ -n "$detail" ] || detail="$(tail -n 10 "$out")"
    alert "Weekly restore check of the newest CMS backup failed, so it may not restore. \`backups restore-check\` runs it again.
\`\`\`
$detail
\`\`\`"
  fi
  rm -f "$out"
}

# --- Results and the daily report ----------------------------------------------------
# Each app's latest result (backed up, failed, no data, no recipe) is kept in
# state/<app>, for the report. Last-good times and sizes come from the bucket itself, so
# they stay right after a rebuild loses the state folder.

mkdir -p "$STATE"

# Saves an app's result from this run: record <app> <result>.
record() { echo "$2" > "$STATE/$1"; }

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
  # The last weekly restore check, on a box that runs the CMS.
  local check=""
  if has_cms; then
    check="$(printf '%-28s %s' "restore check" "$(cat "$STATE/restore-check" 2>/dev/null || echo "not run yet")")"$'\n'
  fi
  post_discord report-webhook.url "**Backups for $DAY** (times UTC)
\`\`\`
$(printf '%-16s %-10s %-17s %s' app result "last good" space)
${rows}total space: $(human "$total")
${media}${check}\`\`\`${notes:+$'\n'$notes}"
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

# Weekly, after the backups and before the report, so that day's report shows it. A
# runner's first run counts as its last check, so a new box waits for Sunday rather than
# checking a backup it has only just taken.
if has_cms; then
  [ -f "$STATE/restore-check.last-run" ] || echo "$RUN_HOUR" > "$STATE/restore-check.last-run"
  if restore_check_due; then
    echo "$RUN_HOUR" > "$STATE/restore-check.last-run"
    run_restore_check
  fi
fi

# Once a day, after the nightly backups: the report, then the status page's ping. If the
# nightly run was missed, the first run after it sends them.
if (( HOUR >= NIGHTLY_HOUR )) && [ "$(cat "$STATE/report-day" 2>/dev/null)" != "$DAY" ]; then
  send_report
  ping_status_page
  echo "$DAY" > "$STATE/report-day"
fi
log "run done"
