#!/usr/bin/env bash
# Tests for the helper commands (backup-runner/backups.sh), on the same fake VPS as the
# runner's tests (fake-vps.sh). Backups are made by the real runner, then each command
# is run the way the maintainer would, and the test checks what it printed and did.
#
#   bash tests/backup-runner/helpers-test.sh          # every test
#   bash tests/backup-runner/helpers-test.sh restore  # tests whose name contains "restore"
#
# Needs what test.sh needs. The scratch CMS tests also need Docker, and are skipped
# without it.
set -uo pipefail
source "$(dirname "$0")/fake-vps.sh"

# Runs one helper command against the fake VPS. Its output is also kept in $T/run.out,
# which a failing test prints.
backups() {
  env $(fake_vps_env) bash "$repo/backup-runner/backups.sh" "$@" 2>&1 | tee "$T/run.out"
  return "${PIPESTATUS[0]}"
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

test_list_shows_an_apps_backups_oldest_first_with_their_tiers() {
  app_working cms
  echo "cms 6 14" > "$T/schedule.conf"
  run_at 2026-10-20T07:00:00Z
  run_at 2026-10-20T13:00:00Z
  local out
  out="$(backups list cms)" || fail "list failed: $out" || return 1
  echo "$out" | grep -Eq '^2026-10-20T070000Z-cms\.txt\.age +[0-9.]+ ?[KM]?i?B +frequent daily monthly$' \
    || fail "first backup's line: $out" || return 1
  echo "$out" | grep -Eq '^2026-10-20T130000Z-cms\.txt\.age +[0-9.]+ ?[KM]?i?B +frequent$' \
    || fail "second backup's line: $out" || return 1
  # Oldest first, so the newest is the last line.
  echo "$out" | tail -n 1 | grep -q 130000Z || fail "newest is not last: $out"
}

test_list_of_an_app_with_no_backups_says_so() {
  local out
  out="$(backups list nothing)" && fail "list should fail: $out" && return 1
  echo "$out" | grep -q "No backups of nothing" || fail "unexpected output: $out"
}

test_fetch_downloads_and_decrypts_a_chosen_backup() {
  app_working cms
  echo "cms 6 14" > "$T/schedule.conf"
  run_at 2026-10-20T07:00:00Z
  echo 'echo "later data" > "$1/cms.txt"' > "$T/apps/cms/backup.sh"
  run_at 2026-10-20T13:00:00Z
  mkdir "$T/out"
  # The start of a name is enough, as long as only one backup matches.
  backups fetch cms 2026-10-20T07 "$T/out" > /dev/null || fail "fetch failed" || return 1
  assert_eq "$(cat "$T/out/2026-10-20T070000Z-cms.txt")" "data of cms" || return 1
  # Only the person running it can read the decrypted copy.
  assert_eq "$(stat -c %a "$T/out/2026-10-20T070000Z-cms.txt")" 600 "mode"
}

test_fetch_latest_gets_the_newest_backup() {
  app_working cms
  echo "cms 6 14" > "$T/schedule.conf"
  run_at 2026-10-20T07:00:00Z
  echo 'echo "later data" > "$1/cms.txt"' > "$T/apps/cms/backup.sh"
  run_at 2026-10-20T13:00:00Z
  mkdir "$T/out"
  backups fetch cms latest "$T/out" > /dev/null || fail "fetch failed" || return 1
  assert_eq "$(cat "$T/out/2026-10-20T130000Z-cms.txt")" "later data"
}

test_fetch_refuses_a_name_that_matches_more_than_one_backup() {
  app_working cms
  echo "cms 6 14" > "$T/schedule.conf"
  run_at 2026-10-20T07:00:00Z
  run_at 2026-10-20T13:00:00Z
  mkdir "$T/out"
  local out
  out="$(backups fetch cms 2026-10-20 "$T/out")" && fail "fetch should fail: $out" && return 1
  echo "$out" | grep -q "matches 2 backups" || fail "unexpected output: $out" || return 1
  assert_eq "$(ls -A "$T/out")" "" "nothing fetched"
}

test_fetch_never_overwrites_a_file() {
  app_working cms
  run_at 2026-10-20T07:00:00Z
  mkdir "$T/out"
  echo "mine" > "$T/out/2026-10-20T070000Z-cms.txt"
  backups fetch cms latest "$T/out" > /dev/null && fail "fetch should fail" && return 1
  assert_eq "$(cat "$T/out/2026-10-20T070000Z-cms.txt")" "mine"
}

test_now_backs_up_into_frequent_the_way_the_runner_does() {
  app_working cms
  BACKUP_RUNNER_NOW=2026-10-20T05:30:00Z backups now cms > /dev/null || fail "now failed" || return 1
  assert_eq "$(backups_in frequent/cms)" "2026-10-20T053000Z-cms.txt.age" || return 1
  assert_eq "$(decrypt frequent/cms/2026-10-20T053000Z-cms.txt.age)" "data of cms" || return 1
  # Never promoted: daily/ and monthly/ keep the scheduled backups.
  assert_count daily/cms 0 || return 1
  assert_count monthly/cms 0 || return 1
  assert_eq "$(ls -A "$T/staging")" "" "staging left behind" || return 1
  grep -q "cms: backed up 2026-10-20T053000Z-cms.txt.age" "$T/runner/logs/runner.log" \
    || fail "not in the runner's log"
}

test_now_leaves_the_schedule_alone() {
  app_working cms
  run_at 2026-10-20T07:00:00Z
  BACKUP_RUNNER_NOW=2026-10-20T09:00:00Z backups now cms > /dev/null
  run_at 2026-10-21T07:00:00Z
  assert_eq "$(backups_in daily/cms | tr '\n' ' ')" \
    "2026-10-20T070000Z-cms.txt.age 2026-10-21T070000Z-cms.txt.age "
}

test_now_says_why_when_the_recipe_fails_and_sends_no_alert() {
  app_failing cms
  local out
  out="$(backups now cms)" && fail "now should fail: $out" && return 1
  echo "$out" | grep -q "connection refused" || fail "the recipe's error is not shown: $out" || return 1
  assert_eq "$(message_count alerts)" 0 "alerts"
}

test_now_stops_at_an_app_with_no_recipe() {
  mkdir -p "$T/apps/stateless"
  touch "$T/apps/stateless/no-backup"
  local out
  out="$(backups now stateless)" && fail "now should fail: $out" && return 1
  echo "$out" | grep -q "stateless has no backup.sh" || fail "unexpected output: $out"
}

# An app whose restore.sh writes down what it was given: the folder it ran in, and the
# contents of the file it was passed.
app_restorable() {
  app_working "$1"
  cat > "$T/apps/$1/restore.sh" <<EOF
pwd > "$T/restore-ran-in"
cat "\$1" > "$T/restore-got"
EOF
}

test_restore_runs_the_apps_restore_with_the_decrypted_backup() {
  app_restorable cms
  echo "cms 6 14" > "$T/schedule.conf"
  run_at 2026-10-20T07:00:00Z
  echo 'echo "later data" > "$1/cms.txt"' > "$T/apps/cms/backup.sh"
  run_at 2026-10-20T13:00:00Z
  local out
  out="$(echo cms | backups restore cms 2026-10-20T07)" || fail "restore failed: $out" || return 1
  assert_eq "$(cat "$T/restore-got")" "data of cms" || return 1
  assert_eq "$(cat "$T/restore-ran-in")" "$T/apps/cms" "restore.sh's folder" || return 1
  # The decrypted copy is gone once the restore is done.
  assert_eq "$(ls -A "$T/staging")" "" "staging left behind" || return 1
  grep -q "cms: restore.sh finished" "$T/runner/logs/runner.log" || fail "not in the runner's log"
}

test_restore_asks_first_and_stops_on_any_other_answer() {
  app_restorable cms
  run_at 2026-10-20T07:00:00Z
  local out
  out="$(echo y | backups restore cms latest)" && fail "restore should stop: $out" && return 1
  echo "$out" | grep -q "replaces cms's live data" || fail "does not say what it will do: $out" || return 1
  [ ! -e "$T/restore-got" ] || fail "restore.sh ran without the app's name typed" || return 1
  assert_eq "$(ls -A "$T/staging")" "" "staging left behind"
}

test_restore_stops_at_an_app_with_no_restore_script() {
  app_working cms
  rm "$T/apps/cms/restore.sh"
  run_at 2026-10-20T07:00:00Z
  local out
  out="$(echo cms | backups restore cms latest)" && fail "restore should stop: $out" && return 1
  echo "$out" | grep -q "cms has no restore.sh" || fail "unexpected output: $out" || return 1
  echo "$out" | grep -q "Downloading" && fail "it downloaded before stopping: $out" && return 1
  return 0
}

test_restore_that_fails_says_so() {
  app_working cms
  printf 'echo "database is busy" >&2\nexit 3\n' > "$T/apps/cms/restore.sh"
  run_at 2026-10-20T07:00:00Z
  local out
  out="$(echo cms | backups restore cms latest)" && fail "restore should fail: $out" && return 1
  echo "$out" | grep -q "database is busy" || fail "restore.sh's error is not shown: $out" || return 1
  echo "$out" | grep -q "restore.sh exited 3" || fail "unexpected output: $out" || return 1
  assert_eq "$(ls -A "$T/staging")" "" "staging left behind"
}

run_tests "$@"
