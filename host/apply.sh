#!/usr/bin/env bash
# Makes this server's base system match host/: the files under host/files/ copied to the
# same paths, plus Docker from its apt repository (held), the swapfile, UTC kept
# synchronised by the image's own time service (chrony or systemd-timesyncd), the
# /home/deploy layout and the traefik-shared network. Safe to run
# again: it changes only what differs, and reloads only the services whose config changed.
#
#   sudo bash /home/deploy/host/apply.sh --check   # print each difference; changes nothing
#   sudo bash /home/deploy/host/apply.sh           # apply them
#
# --check needs no root (the backup runner runs it as deploy). It exits 0 when the server
# matches, 1 when anything differs or can't be seen as the user running it. Without
# --check it exits 1 if anything was refused or failed, after doing the rest. Either way,
# 2 is a bad option and 3 means it couldn't finish, so what it printed is not the whole
# story. See host/README.md.
#
# HOST_ROOT=<folder> runs it against a fake server root instead of /, for the tests.

# shellcheck disable=SC2317 # the functions fix runs look unreachable to shellcheck
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="${HOST_ROOT:-}"
PATH="$PATH:/usr/sbin:/sbin"

DOCKER_PACKAGES=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
SWAPFILE_GB=4
TIMEZONE=/usr/share/zoneinfo/Etc/UTC
DEPLOY_DIRS=(traefik apps backup-runner backups)
NETWORK=traefik-shared

# The comment at the top of this file, without its #s.
usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; }

check=false
case "${1:-}" in
  "") ;;
  --check) check=true ;;
  -h | --help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

if ! $check && [ -z "$root" ] && [ "$(id -u)" != 0 ]; then
  echo "apply.sh: changing the server needs root. Run it with sudo, or use --check." >&2
  exit 1
fi

# From here, any way out but the end of this script (such as an unset variable) exits 3.
finished=false
trap '$finished || { echo "apply.sh: couldn'"'"'t finish; see above. This is not the whole story." >&2; exit 3; }' EXIT

differences=0   # found by --check
changes_made=0  # without --check
failed=0
changed_files=" " # the managed files this run changed, space-separated

# differs WHAT [WHY]: one difference, in --check.
differs() {
  differences=$((differences + 1))
  echo "differs  $1${2:+  ($2)}"
}
# did WHAT: one change made.
did() {
  changes_made=$((changes_made + 1))
  echo "changed  $*"
}
# refuse WHAT WHY: something not done, so the run ends non-zero.
refuse() {
  failed=1
  echo "refused  $1: $2"
}
was_changed() { [[ $changed_files == *" $1 "* ]]; }

# fix WHAT WHY COMMAND...: WHAT isn't as host/ says, because WHY. --check reports it;
# otherwise COMMAND fixes it, and a failure is refused.
fix() {
  local what="$1" why="$2"
  shift 2
  if $check; then
    differs "$what" "$why"
  elif "$@"; then
    did "$what"
  else
    refuse "$what" "$why, and fixing it failed"
  fi
}

# reload WHAT COMMAND...: puts changed config in use. A failure is refused, since the new
# config is in place but not running.
reload() {
  local what="$1"
  shift
  if "$@"; then
    echo "reloaded $what"
  else
    refuse "$what" "its new config is in place, but $* failed"
  fi
}

# ---------------------------------------------------------------------------
# The managed files
# ---------------------------------------------------------------------------

# Managed files may say @VERSION_CODENAME@ for this server's Ubuntu release (resolute).
# shellcheck source=/dev/null # the server's, not the repo's
codename="$(. "$root/etc/os-release" 2> /dev/null && echo "${VERSION_CODENAME:-}")"
[ -n "$codename" ] || { echo "apply.sh: no VERSION_CODENAME in /etc/os-release" >&2; exit 3; }

# render FILE: host/'s version of a managed file, as it should be on this server.
render() { sed "s/@VERSION_CODENAME@/$codename/g" "$here/files$1"; }

# put_in_place FILE: writes host/'s version of FILE to the server.
put_in_place() {
  local tmp
  tmp="$(mktemp)" && render "$1" > "$tmp" && install -D -m 644 "$tmp" "$root$1"
  local rc=$?
  rm -f "$tmp"
  return $rc
}

install_file() {
  if put_in_place "$1"; then
    did "$1"
    changed_files+="$1 "
  else
    refuse "$1" "couldn't write it"
  fi
}

# The admin running this: bootstrap.sh names the first admin in HOST_ADMIN, and sudo
# names the account it was run from.
admin="${HOST_ADMIN:-${SUDO_USER:-}}"
[ "$admin" = root ] && admin=""

# Why the sshd config now in place could lock someone out, or nothing if it can't.
sshd_lockout() {
  local config="$root/etc/ssh/sshd_config" effective
  # sshd -t needs this folder, which only exists once sshd has run: Ubuntu 24.04 starts
  # it from a socket, so before the first SSH login it may not have.
  install -d -m 755 "$root/run/sshd"
  sshd -t -f "$config" 2>&1 | sed 's/^/    /' >&2
  [ "${PIPESTATUS[0]}" = 0 ] || { echo "sshd -t rejects it"; return; }
  effective="$(sshd -T -f "$config" 2> /dev/null)"
  allowed() { grep -qxi "allowusers $1" <<< "$effective"; }
  allowed deploy || { echo "deploy is not in AllowUsers, so every deploy would fail"; return; }
  [ -n "$admin" ] || {
    echo "can't tell which admin is running this; run it with sudo from your own account"
    return
  }
  allowed "$admin" || { echo "$admin, who is running this, is not in its AllowUsers"; return; }
  # ssh-keygen -l reads authorized_keys lines with or without options, and fails if
  # there is no key at all.
  if grep -qxi 'passwordauthentication no' <<< "$effective" &&
    ! ssh-keygen -l -f "$root/home/$admin/.ssh/authorized_keys" > /dev/null 2>&1; then
    echo "$admin, who is running this, has no SSH key in ~/.ssh/authorized_keys, and it turns off password login"
  fi
}

# An sshd drop-in. It goes in place, then sshd checks the whole config; anything that
# could lock an admin or deploy out puts the old version back.
sshd_changed=false
install_sshd_file() {
  local f="$1" dest="$root$1" backup="" why
  if [ -e "$dest" ]; then backup="$(mktemp)" && cp -p "$dest" "$backup"; fi
  put_in_place "$f" || { refuse "$f" "couldn't write it"; return; }
  why="$(sshd_lockout)"
  if [ -n "$why" ]; then
    if [ -n "$backup" ]; then mv "$backup" "$dest"; else rm -f "$dest"; fi
    refuse "$f" "$why. The old version stays"
    return
  fi
  rm -f "$backup"
  did "$f"
  sshd_changed=true
}

managed="$(cd "$here/files" && find . -type f | sed 's|^\.||' | sort)" || exit 3
while read -r f; do
  dest="$root$f"
  render "$f" | cmp -s - "$dest" && continue
  if $check; then
    if [ ! -e "$dest" ]; then
      differs "$f" "missing"
    elif [ ! -r "$dest" ]; then
      differs "$f" "can't read it as $(id -un) to compare; run --check with sudo"
    else
      differs "$f" "changed"
      render "$f" | diff -u --label "$f (on the server)" --label "$f (in host/)" "$dest" - | sed 's/^/    /'
    fi
    continue
  fi
  case "$f" in
    /etc/ssh/sshd_config.d/*) install_sshd_file "$f" ;;
    *) install_file "$f" ;;
  esac
done <<< "$managed"

# sshd drop-ins host/ doesn't manage, such as the image's own. They're `extra` lines, not
# differences:
# ours sorts first and sshd keeps the first value it reads, so they can't undo it. Each
# is listed so a reader of the folder isn't misled, saying if it tries to.
if $check; then
  for dropin in "$root"/etc/ssh/sshd_config.d/*.conf; do
    [ -e "$dropin" ] || continue
    f="${dropin#"$root"}"
    grep -qxF "$f" <<< "$managed" && continue
    tries="$(grep -hiE '^[[:space:]]*(PasswordAuthentication[[:space:]]+yes|PermitRootLogin[[:space:]]+[a-z-]+)' "$dropin" 2> /dev/null |
      grep -viE 'PermitRootLogin[[:space:]]+no' | awk '{print $1 " " $2}' | paste -sd, - | sed 's/,/, /g')"
    echo "extra    $f  (not in host/${tries:+; sets $tries, which ours overrides})"
  done

  # Likewise any sudoers drop-in, such as cloud-init's 90-cloud-init-users (bootstrap.sh
  # removes that one). host/ manages none. The folder is root's alone.
  if [ -r "$root/etc/sudoers.d" ] && [ -x "$root/etc/sudoers.d" ]; then
    for f in "$root"/etc/sudoers.d/*; do
      if [ ! -e "$f" ] || [ "${f##*/}" = README ]; then continue; fi
      echo "extra    ${f#"$root"}  (not in host/; it can grant sudo)"
    done
  elif [ -d "$root/etc/sudoers.d" ]; then
    echo "extra    /etc/sudoers.d/  (can't list it as $(id -un); run --check with sudo to see any files there)"
  fi
fi

# ---------------------------------------------------------------------------
# Packages: Docker from its repository, held, and unattended-upgrades
# ---------------------------------------------------------------------------

# dpkg's own state only: a held package's ${Status} reads "hold ok installed".
installed() { [ "$(dpkg-query -W -f='${db:Status-Status}' "$1" 2> /dev/null)" = installed ]; }

docker_was_installed=false
installed docker-ce && docker_was_installed=true

apt_install() {
  DEBIAN_FRONTEND=noninteractive apt-get update -q &&
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

# ensure_installed PACKAGE...: installs whichever of them aren't, in one apt-get.
ensure_installed() {
  local p missing=()
  for p in "$@"; do installed "$p" || missing+=("$p"); done
  [ ${#missing[@]} = 0 ] || fix "packages ${missing[*]}" "not installed" apt_install "${missing[@]}"
}

ensure_installed "${DOCKER_PACKAGES[@]}"
ensure_installed unattended-upgrades

held="$(apt-mark showhold 2> /dev/null)"
unheld=()
for p in "${DOCKER_PACKAGES[@]}"; do
  grep -qxF "$p" <<< "$held" || unheld+=("$p")
done
[ ${#unheld[@]} = 0 ] || fix "holds on ${unheld[*]}" "not held" apt-mark hold "${unheld[@]}"

# ---------------------------------------------------------------------------
# Reload what changed
# ---------------------------------------------------------------------------

if ! $check; then
  # try-: Ubuntu 24.04 starts sshd from a socket, so it may not be running. A new
  # connection reads the new config either way.
  ! $sshd_changed || reload ssh systemctl try-reload-or-restart ssh
  # A fresh install already started Docker with daemon.json. live-restore keeps
  # containers running through a restart, once it is on.
  if was_changed /etc/docker/daemon.json && $docker_was_installed; then
    reload docker systemctl restart docker
  fi
  ! was_changed /etc/systemd/journald.conf.d/00-indy-center.conf ||
    reload systemd-journald systemctl restart systemd-journald
  ! was_changed /etc/sysctl.d/60-indy-center.conf ||
    reload "the sysctl settings" sysctl -q -p "$root/etc/sysctl.d/60-indy-center.conf"
fi

# ---------------------------------------------------------------------------
# The clock: UTC, kept synchronised by the image's time service
# ---------------------------------------------------------------------------

[ "$(readlink "$root/etc/localtime")" = "$TIMEZONE" ] ||
  fix /etc/localtime "not UTC" ln -sfn "$TIMEZONE" "$root/etc/localtime"

# Whichever time service the image came with is kept: chrony on ALEXANDRIA. Installing
# systemd-timesyncd would remove chrony, so apply.sh never installs one, and only starts
# one that is installed but stopped.
TIME_SERVICES=(chrony systemd-timesyncd)
time_service=""
for s in "${TIME_SERVICES[@]}"; do
  if systemctl is-active --quiet "$s"; then time_service="$s" && break; fi
done
if [ -z "$time_service" ]; then
  for s in "${TIME_SERVICES[@]}"; do installed "$s" && time_service="$s" && break; done
  if [ -n "$time_service" ]; then
    fix "$time_service" "installed, but not running" systemctl enable --now "$time_service"
  elif $check; then
    differs clock "no time service installed (chrony or systemd-timesyncd)"
  else
    refuse clock "no time service installed; install chrony or systemd-timesyncd by hand"
  fi
elif [ "$(timedatectl show -p NTPSynchronized --value 2> /dev/null)" != yes ]; then
  if $check; then
    differs clock "not synchronised ($time_service is running)"
  else
    refuse clock "not synchronised, though $time_service is running; see timedatectl"
  fi
fi

# ---------------------------------------------------------------------------
# Swap: a 4 GB swapfile, in fstab and on
# ---------------------------------------------------------------------------

swapfile="$root/swapfile"
swap_on() { swapon --show=NAME --noheadings 2> /dev/null | grep -qxF "$swapfile"; }

make_swapfile() {
  if swap_on && ! swapoff "$swapfile"; then
    echo "swapoff couldn't free /swapfile to replace it. Run apply.sh again after a reboot." >&2
    return 1
  fi
  rm -f "$swapfile" &&
    fallocate -l "${SWAPFILE_GB}G" "$swapfile" &&
    chmod 600 "$swapfile" &&
    mkswap "$swapfile" > /dev/null
}

add_swap_to_fstab() { echo "/swapfile none swap sw 0 0" >> "$root/etc/fstab"; }

if [ "$(stat -c %s "$swapfile" 2> /dev/null)" != $((SWAPFILE_GB * 1024 * 1024 * 1024)) ]; then
  fix /swapfile "missing, or not $SWAPFILE_GB GB" make_swapfile
elif [ "$(stat -c %a "$swapfile")" != 600 ]; then
  fix /swapfile "not mode 600" chmod 600 "$swapfile"
fi

grep -qE '^/swapfile[[:space:]]' "$root/etc/fstab" 2> /dev/null ||
  fix /etc/fstab "no /swapfile line" add_swap_to_fstab

swap_on || fix swap "/swapfile is not on" swapon "$swapfile"

# ---------------------------------------------------------------------------
# /home/deploy and the traefik-shared network
# ---------------------------------------------------------------------------

dirs=("$root/home/deploy")
for d in "${DEPLOY_DIRS[@]}"; do dirs+=("$root/home/deploy/$d"); done
make_deploy_dirs() { mkdir -p "${dirs[@]}" && chown deploy:deploy "${dirs[@]}"; }

if [ -d "$root/home/deploy" ] && [ ! -x "$root/home/deploy" ]; then
  # Only deploy and root can look inside.
  differs "/home/deploy's folders" "can't look inside as $(id -un); run --check with sudo"
else
  missing=()
  for d in "${dirs[@]}"; do [ -d "$d" ] || missing+=("${d#"$root"}"); done
  [ ${#missing[@]} = 0 ] || fix "${missing[*]}" "missing" make_deploy_dirs
fi

if ! docker info > /dev/null 2>&1; then
  if $check; then
    differs "Docker network $NETWORK" "can't reach Docker as $(id -un): it isn't running, or run --check with sudo"
  else
    refuse "Docker network $NETWORK" "Docker isn't running"
  fi
elif ! docker network inspect "$NETWORK" > /dev/null 2>&1; then
  fix "Docker network $NETWORK" "missing" docker network create "$NETWORK"
fi

# ---------------------------------------------------------------------------

finished=true
if $check; then
  if [ "$differences" = 0 ]; then
    echo "No differences from host/."
    exit 0
  fi
  echo "$differences difference(s) from host/. To apply them: sudo bash $here/apply.sh"
  exit 1
fi

if [ "$changes_made" = 0 ] && [ "$failed" = 0 ]; then
  echo "Nothing to change: the server already matches host/."
fi
[ "$failed" = 0 ] || echo "Some changes were refused or failed (above); the rest were made." >&2
exit "$failed"
