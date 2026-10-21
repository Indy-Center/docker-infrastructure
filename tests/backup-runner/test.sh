#!/usr/bin/env bash
# Tests for the backup runner. Each test builds a fake VPS in a temp folder (apps, a
# schedule file, secrets with a test age key, a local folder standing in for R2 and its
# media buckets) and a fake Discord and status page, runs the runner once as a chosen
# time, and checks what came out: files in the bucket, messages sent, staging left behind.
#
#   bash tests/backup-runner/test.sh            # every test
#   bash tests/backup-runner/test.sh due        # tests whose name contains "due"
#   KEEP_FAKE_VPS=1 bash tests/backup-runner/test.sh due   # keep each fake VPS to look at
#
# Needs age, age-keygen and rclone on PATH (backup-runner/install-tools.sh), python3, curl.
set -uo pipefail
source "$(dirname "$0")/fake-vps.sh"

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

test_nightly_app_lands_encrypted_in_daily() {
  app_working cms
  run_at 2026-10-20T07:00:00Z
  assert_count daily/cms 1 || return 1
  local file
  file="$(backups_in daily/cms)"
  assert_eq "$file" "2026-10-20T070000Z-cms.txt.age" || return 1
  assert_eq "$(decrypt "daily/cms/$file")" "data of cms"
}

test_nightly_app_is_not_due_again_until_the_next_night() {
  app_working cms
  run_at 2026-10-20T07:00:00Z
  run_at 2026-10-20T08:00:00Z
  run_at 2026-10-21T06:00:00Z
  assert_count daily/cms 1 || return 1
  run_at 2026-10-21T07:00:00Z
  assert_count daily/cms 2
}

test_missed_nightly_run_is_made_up_at_the_next_run() {
  app_working cms
  run_at 2026-10-20T07:00:00Z
  # The VPS was down at 07:00 on the 21st; it is back at 09:00.
  run_at 2026-10-21T09:00:00Z
  run_at 2026-10-21T10:00:00Z
  assert_eq "$(backups_in daily/cms | tr '\n' ' ')" \
    "2026-10-20T070000Z-cms.txt.age 2026-10-21T090000Z-cms.txt.age " || return 1
  assert_eq "$(message_count report)" 2 "reports: one each day" || return 1
  # And back on its hour the next night.
  run_at 2026-10-22T07:00:00Z
  assert_count daily/cms 3
}

test_daily_keeps_one_copy_a_day_when_a_nightly_app_runs_twice() {
  app_working cms
  # A new app is backed up the hour it appears, then again at 07:00 the same day.
  run_at 2026-10-20T03:00:00Z
  run_at 2026-10-20T07:00:00Z
  assert_eq "$(backups_in daily/cms | tr '\n' ' ')" "2026-10-20T030000Z-cms.txt.age " || return 1
  assert_eq "$(backups_in frequent/cms | tr '\n' ' ')" "2026-10-20T070000Z-cms.txt.age "
}

test_six_hourly_app_goes_to_frequent_and_first_of_day_is_promoted() {
  app_working payload
  echo "payload 6 14" > "$T/schedule.conf"
  for t in 2026-10-20T07 2026-10-20T08 2026-10-20T13 2026-10-20T19 2026-10-21T01 2026-10-21T07; do
    run_at "$t:00:00Z"
  done
  assert_eq "$(backups_in frequent/payload | tr '\n' ' ')" \
    "2026-10-20T070000Z-payload.txt.age 2026-10-20T130000Z-payload.txt.age 2026-10-20T190000Z-payload.txt.age 2026-10-21T010000Z-payload.txt.age 2026-10-21T070000Z-payload.txt.age " || return 1
  # 01:00 is the first backup of the 21st; 07:00 is not.
  assert_eq "$(backups_in daily/payload | tr '\n' ' ')" \
    "2026-10-20T070000Z-payload.txt.age 2026-10-21T010000Z-payload.txt.age " || return 1
  assert_eq "$(decrypt daily/payload/2026-10-21T010000Z-payload.txt.age)" "data of payload"
}

test_shipped_schedule_backs_up_payload_every_six_hours_and_others_nightly() {
  app_working payload
  app_working cms
  cp "$repo/backup-runner/schedule.conf" "$T/schedule.conf"
  for t in 2026-10-20T07 2026-10-20T13 2026-10-20T19; do run_at "$t:00:00Z"; done
  assert_count frequent/payload 3 || return 1
  assert_count daily/cms 1 || return 1
  assert_eq "$(message_count alerts)" 0 "alerts"
}

test_bad_schedule_line_alerts_and_falls_back_to_nightly() {
  app_working cms
  printf '# app  every  keep\ncms  5h  14\npayload  6  0\n' > "$T/schedule.conf"
  app_working payload
  run_at 2026-10-20T07:00:00Z
  run_at 2026-10-20T13:00:00Z
  assert_count daily/cms 1 || return 1
  assert_count frequent/cms 0 || return 1
  messages alerts | grep -q "schedule.*cms" || fail "no alert about cms's line: $(messages alerts)" || return 1
  # More than one backup a day needs a frequent tier to put them in.
  messages alerts | grep -q "schedule.*payload" || fail "no alert about payload's line: $(messages alerts)" || return 1
  assert_count daily/payload 1
}

test_alert_webhook_being_down_does_not_stop_backups() {
  app_failing broken
  app_working cms
  sed 's|/alerts$|/fail|' "$T/runner/secrets/alert-webhook.url" > "$T/runner/secrets/alert-webhook.url.new"
  mv "$T/runner/secrets/alert-webhook.url.new" "$T/runner/secrets/alert-webhook.url"
  run_at 2026-10-20T07:00:00Z
  assert_eq "$(cat "$T/run.status")" 0 "runner exit status" || return 1
  assert_count daily/cms 1 || return 1
  assert_eq "$(message_count report)" 1 "reports" || return 1
  grep -q "posting to alert-webhook.url failed" "$T/runner/logs/runner.log" || fail "the failed post is not logged"
}

test_report_notes_an_app_with_no_restore_script() {
  app_working cms
  rm "$T/apps/cms/restore.sh"
  run_at 2026-10-20T07:00:00Z
  messages report | grep -q "cms has no restore.sh" || fail "report: $(messages report)"
}

test_first_backup_of_each_month_is_promoted_to_monthly() {
  app_working cms
  app_working payload
  echo "payload 6 14" > "$T/schedule.conf"
  for t in 2026-10-31T07 2026-10-31T13 2026-11-01T01 2026-11-01T07 2026-11-02T07; do
    run_at "$t:00:00Z"
  done
  assert_eq "$(backups_in monthly/cms | tr '\n' ' ')" \
    "2026-10-31T070000Z-cms.txt.age 2026-11-01T070000Z-cms.txt.age " || return 1
  assert_eq "$(backups_in monthly/payload | tr '\n' ' ')" \
    "2026-10-31T070000Z-payload.txt.age 2026-11-01T010000Z-payload.txt.age " || return 1
  assert_eq "$(decrypt monthly/cms/2026-11-01T070000Z-cms.txt.age)" "data of cms"
}

test_failing_recipe_alerts_and_the_other_apps_still_run() {
  app_failing aaa-broken
  app_working cms
  run_at 2026-10-20T07:00:00Z
  assert_count daily/cms 1 || return 1
  assert_count daily/aaa-broken 0 || return 1
  assert_eq "$(message_count alerts)" 1 "alerts sent" || return 1
  messages alerts | grep -q "aaa-broken" || fail "alert does not name the app: $(messages alerts)" || return 1
  messages alerts | grep -q "connection refused" || fail "alert does not show the recipe's error: $(messages alerts)" || return 1
  assert_eq "$(ls -A "$T/staging")" "" "staging left behind"
}

test_failed_upload_alerts_and_staging_is_pruned() {
  app_working cms
  # A file where the daily/ folder should be makes every upload into it fail.
  touch "$T/r2/indy-center-backups/daily"
  run_at 2026-10-20T07:00:00Z
  assert_eq "$(message_count alerts)" 1 "alerts sent" || return 1
  messages alerts | grep -q "cms.*upload failed" || fail "unexpected alert: $(messages alerts)" || return 1
  assert_eq "$(ls -A "$T/staging")" "" "staging left behind"
}

test_failed_encryption_alerts() {
  app_working cms
  echo "not a key" > "$T/runner/secrets/age.key"
  run_at 2026-10-20T07:00:00Z
  assert_count daily/cms 0 || return 1
  messages alerts | grep -q "cms.*encryption failed" || fail "unexpected alert: $(messages alerts)"
}

test_app_with_no_recipe_alerts_once_a_night_and_no_backup_marker_does_not() {
  mkdir -p "$T/apps/stateless" "$T/apps/forgotten"
  touch "$T/apps/stateless/no-backup"
  run_at 2026-10-20T07:00:00Z
  run_at 2026-10-20T08:00:00Z
  assert_eq "$(message_count alerts)" 1 "alerts sent" || return 1
  messages alerts | grep -q "forgotten.*no backup.sh" || fail "unexpected alert: $(messages alerts)" || return 1
  assert_eq "$(ls -A "$T/r2/indy-center-backups")" "" "nothing should be uploaded"
}

test_report_goes_out_once_a_day_with_each_apps_result() {
  app_working cms
  app_working payload
  app_failing broken
  mkdir -p "$T/apps/stateless" "$T/apps/forgotten"
  touch "$T/apps/stateless/no-backup"
  echo "payload 6 14" > "$T/schedule.conf"

  run_at 2026-10-20T01:00:00Z
  assert_eq "$(message_count report)" 0 "reports before the nightly hour" || return 1
  run_at 2026-10-20T07:00:00Z
  run_at 2026-10-20T08:00:00Z
  assert_eq "$(message_count report)" 1 "reports sent" || return 1

  local report
  report="$(messages report)"
  echo "$report" | grep -q "2026-10-20" || fail "report has no date: $report" || return 1
  # app, result, last good backup, space used
  echo "$report" | grep -Eq '^cms +backed up +2026-10-20 07:00 +[0-9.]+ ?[KM]?i?B$' || fail "cms line: $report" || return 1
  echo "$report" | grep -Eq '^payload +backed up +2026-10-20 07:00 +[0-9.]+ ?[KM]?i?B$' || fail "payload line: $report" || return 1
  echo "$report" | grep -Eq '^broken +failed +never +0 ?B$' || fail "broken line: $report" || return 1
  echo "$report" | grep -Eq '^stateless +no data( |$)' || fail "stateless line: $report" || return 1
  echo "$report" | grep -Eq '^forgotten +no recipe( |$)' || fail "forgotten line: $report" || return 1
}

test_log_is_size_limited() {
  app_working cms
  mkdir -p "$T/runner/logs"
  head -c 6000000 /dev/zero | tr '\0' 'x' > "$T/runner/logs/runner.log"
  head -c 100 /dev/zero > "$T/runner/logs/runner.log.1"
  run_at 2026-10-20T07:00:00Z
  [ "$(stat -c %s "$T/runner/logs/runner.log.1")" = 6000000 ] || fail "the full log was not moved to runner.log.1" || return 1
  [ "$(stat -c %s "$T/runner/logs/runner.log")" -lt 100000 ] || fail "runner.log was not started afresh" || return 1
  grep -q "cms: backed up" "$T/runner/logs/runner.log" || fail "this run is not in the new log"
}

test_run_that_starts_while_one_is_going_steps_aside() {
  mkdir -p "$T/apps/slow"
  printf 'sleep 2\necho slow > "$1/slow.txt"\n' > "$T/apps/slow/backup.sh"
  run_at 2026-10-20T07:00:00Z &
  sleep 0.5
  run_at 2026-10-20T08:00:00Z
  wait
  assert_count daily/slow 1 || return 1
  assert_eq "$(message_count alerts)" 0 "alerts" || return 1
  grep -q "still running" "$T/runner/logs/runner.log" || fail "the second run did not log why it stopped"
}

test_recipe_writing_two_files_fails() {
  mkdir -p "$T/apps/cms"
  printf 'touch "$1/a" "$1/b"\n' > "$T/apps/cms/backup.sh"
  run_at 2026-10-20T07:00:00Z
  assert_count daily/cms 0 || return 1
  messages alerts | grep -q "cms.*exactly one file" || fail "unexpected alert: $(messages alerts)"
}

test_status_page_is_pinged_after_the_report_when_its_secret_is_set() {
  app_working cms
  run_at 2026-10-20T07:00:00Z
  assert_eq "$(message_count ping)" 0 "pings without a secret" || return 1
  grep -q ALERT "$T/runner/logs/runner.log" && fail "a missing ping secret should not alert" && return 1

  sed 's|/report$|/ping|' "$T/runner/secrets/report-webhook.url" >"$T/runner/secrets/status-ping.url"
  echo "s3cret" > "$T/runner/secrets/status-ping.secret"
  run_at 2026-10-21T07:00:00Z
  assert_eq "$(message_count ping)" 1 "pings" || return 1
  assert_eq "$(cat "$T/endpoint/ping/1.auth")" "Bearer s3cret"
}

test_media_copy_adds_new_files_and_never_deletes() {
  media_bucket payload-media
  media_bucket payload-private
  echo "plane" > "$T/r2/payload-media/plane.png"
  echo "notes" > "$T/r2/payload-private/notes.pdf"
  run_at 2026-10-20T07:00:00Z
  assert_eq "$(cat "$T/r2/indy-center-backups/media/payload-media/plane.png")" "plane" || return 1
  assert_eq "$(cat "$T/r2/indy-center-backups/media/payload-private/notes.pdf")" "notes" || return 1

  # The next night: one file deleted at the source, one changed, one added.
  rm "$T/r2/payload-media/plane.png"
  echo "changed" > "$T/r2/payload-private/notes.pdf"
  echo "tower" > "$T/r2/payload-media/tower.png"
  run_at 2026-10-21T07:00:00Z
  assert_eq "$(backups_in media/payload-media | tr '\n' ' ')" "plane.png tower.png " || return 1
  assert_eq "$(cat "$T/r2/indy-center-backups/media/payload-private/notes.pdf")" "notes" "changed file" || return 1
  assert_eq "$(message_count alerts)" 0 "alerts"
}

test_shipped_media_config_copies_both_cms_buckets() {
  cp "$repo/backup-runner/media.conf" "$T/media.conf"
  mkdir -p "$T/r2/payload-media" "$T/r2/payload-private"
  echo "plane" > "$T/r2/payload-media/plane.png"
  echo "notes" > "$T/r2/payload-private/notes.pdf"
  run_at 2026-10-20T07:00:00Z
  assert_eq "$(backups_in media | tr '\n' ' ')" "payload-media payload-private " || return 1
  assert_eq "$(message_count alerts)" 0 "alerts"
}

test_media_copy_runs_nightly_and_a_missed_night_is_made_up() {
  media_bucket payload-media
  echo "plane" > "$T/r2/payload-media/plane.png"
  run_at 2026-10-20T07:00:00Z
  echo "tower" > "$T/r2/payload-media/tower.png"
  run_at 2026-10-20T08:00:00Z
  run_at 2026-10-21T06:00:00Z
  assert_eq "$(backups_in media/payload-media)" "plane.png" "copied before the next night" || return 1
  # The VPS was down at 07:00 on the 21st; it is back at 09:00.
  run_at 2026-10-21T09:00:00Z
  assert_eq "$(backups_in media/payload-media | tr '\n' ' ')" "plane.png tower.png "
}

test_report_shows_the_media_copys_size_and_file_count() {
  app_working cms
  media_bucket payload-media
  media_bucket payload-private
  head -c 2048 /dev/zero > "$T/r2/payload-media/plane.png"
  head -c 1024 /dev/zero > "$T/r2/payload-media/tower.png"
  head -c 10 /dev/zero > "$T/r2/payload-private/notes.pdf"
  run_at 2026-10-20T07:00:00Z
  local report
  report="$(messages report)"
  echo "$report" | grep -Eq '^media/payload-media +2 files +3(\.0)? ?KiB$' || fail "payload-media line: $report" || return 1
  echo "$report" | grep -Eq '^media/payload-private +1 file +10 ?B$' || fail "payload-private line: $report" || return 1
  # The apps' total leaves the media copy out.
  echo "$report" | grep -Eq '^total space: [0-9]+ ?B$' || fail "total line: $report"
}

test_failed_media_copy_alerts_and_the_other_bucket_is_still_copied() {
  # Listed, but missing from R2: copying it fails.
  echo "aaa-missing" > "$T/media.conf"
  media_bucket payload-media
  echo "plane" > "$T/r2/payload-media/plane.png"
  run_at 2026-10-20T07:00:00Z
  assert_eq "$(backups_in media/payload-media)" "plane.png" || return 1
  assert_eq "$(message_count alerts)" 1 "alerts sent" || return 1
  messages alerts | grep -q "Media copy of \*\*aaa-missing\*\* failed" || fail "unexpected alert: $(messages alerts)" || return 1
  assert_eq "$(ls -A "$T/staging")" "" "staging left behind"
}

test_missing_or_empty_media_config_alerts() {
  rm "$T/media.conf"
  run_at 2026-10-20T07:00:00Z
  assert_eq "$(message_count alerts)" 1 "alerts after a missing media.conf" || return 1
  messages alerts | grep -q "Media copy skipped: no buckets" || fail "unexpected alert: $(messages alerts)" || return 1

  printf '# no buckets\n\n' > "$T/media.conf"
  run_at 2026-10-21T07:00:00Z
  assert_eq "$(message_count alerts)" 2 "alerts after an empty media.conf"
}

test_media_copy_that_times_out_says_so() {
  # A timeout that stops the media copy at once, as the real one would after an hour.
  # Recipes still get the real timeout.
  local real
  real="$(command -v timeout)"
  mkdir -p "$T/runner/bin"
  cat > "$T/runner/bin/timeout" <<EOF
#!/usr/bin/env bash
[ "\$2 \$3" = "rclone copy" ] && exit 124
exec "$real" "\$@"
EOF
  chmod +x "$T/runner/bin/timeout"
  run_at 2026-10-20T07:00:00Z
  assert_eq "$(message_count alerts)" 1 "alerts sent" || return 1
  messages alerts | grep -q "Media copy of \*\*test-media\*\* failed: still running after 1h" || fail "unexpected alert: $(messages alerts)"
}

# --- The weekly restore check ---------------------------------------------------------
# 2026-10-25 is a Sunday.

test_restore_check_runs_on_sunday_at_the_nightly_hour_and_is_in_that_days_report() {
  have_docker || return 0
  remove_check_on_exit
  cms_backup_with_counts 'pages\t1\n'
  run_at 2026-10-24T07:00:00Z
  messages report | grep -Eq '^restore check +not run yet$' || fail "Saturday's report: $(messages report)" || return 1
  run_at 2026-10-25T06:00:00Z
  grep -q "Restore check passed" "$T/runner/logs/runner.log" && fail "checked before the nightly hour" && return 1
  run_at 2026-10-25T07:00:00Z
  grep -q "Restore check passed: 2026-10-25T070000Z-payload.tar.age" "$T/runner/logs/runner.log" \
    || fail "Sunday's backup was not checked" || return 1
  messages report | grep -Eq '^restore check +passed 2026-10-25 07:00$' || fail "Sunday's report: $(messages report)" || return 1
  assert_eq "$(message_count alerts)" 0 "alerts" || return 1
  ! restore_check_container_exists || fail "the container is still there"
}

test_failed_restore_check_alerts_naming_the_step_and_the_report_says_failed() {
  # Its recipe writes a text file, not a CMS backup, so the check fails before it needs
  # Docker.
  app_working payload
  run_at 2026-10-25T07:00:00Z
  assert_eq "$(message_count alerts)" 1 "alerts" || return 1
  messages alerts | grep -q "Weekly restore check of the newest CMS backup failed" || fail "unexpected alert: $(messages alerts)" || return 1
  messages alerts | grep -q "Failed at unpack" || fail "the alert does not name the step: $(messages alerts)" || return 1
  messages report | grep -Eq '^restore check +failed 2026-10-25 07:00$' || fail "report: $(messages report)"
}

test_restore_check_missed_on_sunday_is_made_up_a_week_after_the_last() {
  app_working payload
  # Not on the runner's first run: a week from then, or the next Sunday, whichever is first.
  run_at 2026-10-19T07:00:00Z
  assert_eq "$(message_count alerts)" 0 "alerts on Monday" || return 1
  # The VPS was down on Sunday the 25th at 07:00; it is back on Monday the 26th.
  run_at 2026-10-26T07:00:00Z
  assert_eq "$(message_count alerts)" 1 "alerts after the missed Sunday" || return 1
  run_at 2026-10-26T08:00:00Z
  run_at 2026-10-27T07:00:00Z
  assert_eq "$(message_count alerts)" 1 "alerts the days after" || return 1
}

test_restore_check_that_times_out_says_so() {
  app_working payload
  # A timeout that stops the check at once, as the real one would after 30 minutes.
  local real
  real="$(command -v timeout)"
  mkdir -p "$T/runner/bin"
  cat > "$T/runner/bin/timeout" <<EOF
#!/usr/bin/env bash
for arg; do [[ "\$arg" == */backups.sh ]] && exit 124; done
exec "$real" "\$@"
EOF
  chmod +x "$T/runner/bin/timeout"
  run_at 2026-10-25T07:00:00Z
  assert_eq "$(message_count alerts)" 1 "alerts" || return 1
  messages alerts | grep -q "still running after 30m" || fail "unexpected alert: $(messages alerts)"
}

test_no_restore_check_without_a_cms_on_the_box() {
  app_working cms
  run_at 2026-10-25T07:00:00Z
  grep -qi "restore check" "$T/runner/logs/runner.log" && fail "it ran a restore check" && return 1
  messages report | grep -qi "restore check" && fail "the report has a restore check line: $(messages report)" && return 1
  return 0
}

run_tests "$@"
