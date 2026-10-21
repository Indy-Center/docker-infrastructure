#!/usr/bin/env bash
# Tests for install-command.sh: after it runs, `backups` works by name in a new shell, both
# a login shell (`sudo -iu deploy`, SSH) and an interactive one (`sudo su deploy`), for a
# home folder with Ubuntu's usual dotfiles and for a bare one. Each case uses its own
# throwaway home folder, so this never touches the real one.
#
#   bash tests/backup-runner/install-command-test.sh
set -uo pipefail

repo="$(cd "$(dirname "$0")/../.." && pwd)"
failed=0

fail() {
  echo "FAIL ($1): $2"
  failed=1
}

# Installs the command twice (as repeated deploys do) into a new home folder, set up as
# the case says, then checks a fresh shell of each kind finds it.
check() {
  local case="$1" home
  home="$(mktemp -d)"
  [ "$case" = ubuntu ] && cp -a /etc/skel/. "$home/"
  mkdir -p "$home/backup-runner"
  cp "$repo"/backup-runner/*.sh "$home/backup-runner/"
  for _ in 1 2; do
    HOME="$home" bash "$repo/backup-runner/install-command.sh" > /dev/null || fail "$case" "install-command.sh failed"
  done

  # A bare environment, as a new login has: only the system PATH.
  local kind flag found
  for kind in login interactive; do
    flag=-l
    [ "$kind" = interactive ] && flag=-i
    found="$(env -i HOME="$home" PATH=/usr/bin:/bin TERM=dumb bash "$flag" -c 'command -v backups' 2> /dev/null)"
    [ "$found" = "$home/.local/bin/backups" ] || fail "$case" "a new $kind shell doesn't find backups (got '$found')"
  done
  env -i HOME="$home" PATH=/usr/bin:/bin bash -l -c 'backups --help' 2> /dev/null \
    | grep -q '^backups: everyday backup jobs' || fail "$case" "backups --help didn't run"

  # However often the deploy runs, each file gets the line once.
  local f n
  for f in "$home"/.bashrc "$home"/.profile; do
    n="$(grep -c '# backups command$' "$f" 2> /dev/null || true)"
    [ "${n:-0}" -le 1 ] || fail "$case" "$(basename "$f") has the PATH line $n times"
  done
  rm -rf "$home"
  [ "$failed" = 0 ] && echo "ok   $case home folder"
}

check ubuntu
check bare
[ "$failed" = 0 ] && echo "PASS" || exit 1
