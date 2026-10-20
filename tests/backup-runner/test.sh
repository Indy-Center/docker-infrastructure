#!/usr/bin/env bash
# Tests for the backup runner. Each test builds a fake VPS in a temp folder (apps, a
# schedule file, secrets with a test age key, a local folder standing in for R2) and a
# fake Discord and status page, runs the runner once as a chosen time, and checks what
# came out: files in the bucket, messages sent, staging left behind.
#
#   bash tests/backup-runner/test.sh            # every test
#   bash tests/backup-runner/test.sh due        # tests whose name contains "due"
#   KEEP_FAKE_VPS=1 bash tests/backup-runner/test.sh due   # keep each fake VPS to look at
#
# Needs age, age-keygen and rclone on PATH (backup-runner/install-tools.sh), python3, curl.
set -uo pipefail

repo="$(cd "$(dirname "$0")/../.." && pwd)"
here="$repo/tests/backup-runner"

# ---------------------------------------------------------------------------
# The fake VPS
# ---------------------------------------------------------------------------

# Builds a fresh fake VPS in $T and starts the fake endpoint.
setup() {
  T="$(mktemp -d)"
  mkdir -p "$T/apps" "$T/staging" "$T/r2/indy-center-backups" "$T/runner/secrets" "$T/endpoint"
  python3 "$here/fake-endpoint.py" "$T/endpoint" &
  endpoint_pid=$!
  for _ in $(seq 50); do [ -f "$T/endpoint/port" ] && break; sleep 0.1; done
  local url
  url="http://127.0.0.1:$(cat "$T/endpoint/port")"

  # rclone's alias backend makes r2:indy-center-backups a plain folder on disk.
  printf '[r2]\ntype = alias\nremote = %s\n' "$T/r2" > "$T/runner/secrets/rclone.conf"
  age-keygen -o "$T/runner/secrets/age.key" 2>/dev/null
  echo "$url/report" > "$T/runner/secrets/report-webhook.url"
  echo "$url/alerts" > "$T/runner/secrets/alert-webhook.url"
  : > "$T/schedule.conf"
}

teardown() {
  kill "$endpoint_pid" 2>/dev/null
  wait "$endpoint_pid" 2>/dev/null
  # KEEP_FAKE_VPS=1 leaves the fake VPS behind, to look at what a test produced.
  if [ -n "${KEEP_FAKE_VPS:-}" ]; then echo "    kept $T"; else rm -rf "$T"; fi
}

# An app whose recipe writes one file with known contents.
app_working() {
  mkdir -p "$T/apps/$1"
  cat > "$T/apps/$1/backup.sh" <<EOF
echo "data of $1" > "\$1/$1.txt"
EOF
  touch "$T/apps/$1/restore.sh"
}

# An app whose recipe fails.
app_failing() {
  mkdir -p "$T/apps/$1"
  printf 'echo "pg_dump: connection refused" >&2\nexit 1\n' > "$T/apps/$1/backup.sh"
  touch "$T/apps/$1/restore.sh"
}

# The messages the fake Discord received on one webhook (report or alerts), in order.
# Always succeeds, so `messages alerts | grep -q …` passes on grep's answer alone even
# when grep stops reading early.
messages() {
  local f
  for f in $(ls "$T/endpoint/$1"/*.body 2>/dev/null | sort -V); do
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["content"])' "$f" 2>/dev/null || true
  done
}

message_count() { ls "$T/endpoint/$1"/*.body 2>/dev/null | grep -c . || true; }

# Runs the runner once, as the given UTC time, against the fake VPS.
run_at() {
  BACKUP_RUNNER_HOME="$T/runner" \
  BACKUP_SCHEDULE="$T/schedule.conf" \
  APPS_DIR="$T/apps" \
  STAGING_DIR="$T/staging" \
  BACKUP_RUNNER_NOW="$1" \
    bash "$repo/backup-runner/run-backups.sh" > "$T/run.out" 2>&1
  echo $? > "$T/run.status"
}

# Lists the files in one tier/app folder of the fake bucket, by name.
backups_in() { ls "$T/r2/indy-center-backups/$1" 2>/dev/null; }

# Decrypts one backup with the test key and prints it.
decrypt() { age -d -i "$T/runner/secrets/age.key" "$T/r2/indy-center-backups/$1"; }

# ---------------------------------------------------------------------------
# Assertions: each prints what went wrong and returns non-zero.
# ---------------------------------------------------------------------------

fail() { echo "    $*"; return 1; }

assert_eq() { [ "$1" = "$2" ] || fail "expected [$2], got [$1]${3:+ ($3)}"; }

assert_count() {
  local n
  n="$(backups_in "$1" | grep -c . || true)"
  [ "$n" = "$2" ] || fail "expected $2 file(s) in $1, found $n: $(backups_in "$1" | tr '\n' ' ')"
}

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

# ---------------------------------------------------------------------------
# Runs every test function (or those matching $1), each on its own fake VPS.
# ---------------------------------------------------------------------------

passed=0
failed=0
for t in $(declare -F | awk '{print $3}' | grep '^test_' | grep -- "${1:-}"); do
  setup
  if ( set -e; "$t" ); then
    echo "ok   $t"
    passed=$((passed + 1))
  else
    echo "FAIL $t"
    cat "$T/run.out" "$T/runner/logs/runner.log" 2>/dev/null | sed 's/^/    | /' | tail -20
    failed=$((failed + 1))
  fi
  teardown
done
echo "$passed passed, $failed failed"
[ "$failed" = 0 ]
