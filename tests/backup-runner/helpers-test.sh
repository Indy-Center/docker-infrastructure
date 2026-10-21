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

run_tests "$@"
