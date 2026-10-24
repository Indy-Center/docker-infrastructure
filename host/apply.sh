#!/usr/bin/env bash
# Makes this server's base system match host/: the files under host/files/ copied to the
# same paths, plus Docker from its apt repository (held), the swapfile, UTC kept by
# systemd-timesyncd, the /home/deploy layout and the traefik-shared network. Safe to run
# again: it changes only what differs, and reloads only the services whose config changed.
#
#   sudo bash /home/deploy/host/apply.sh --check   # print each difference; changes nothing
#   sudo bash /home/deploy/host/apply.sh           # apply them
#
# --check needs no root (the runner runs it too). It exits 0 when the server matches,
# 1 when anything differs. Without --check it exits 1 if anything was refused or failed,
# after doing the rest. Either way, 2 is a bad option and 3 means it couldn't finish, so
# what it printed is not the whole story. See host/README.md.
#
# HOST_ROOT=<folder> runs it against a fake server root instead of /, for the tests.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="${HOST_ROOT:-}"
PATH="$PATH:/usr/sbin:/sbin"

DOCKER_PACKAGES=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
SWAPFILE_GB=4
TIMEZONE=/usr/share/zoneinfo/Etc/UTC
DEPLOY_DIRS=(traefik apps backup-runner backups)
NETWORK=traefik-shared

usage() { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; }

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

differences=0 # in --check
changes=0     # without --check
failed=0
changed=" "   # the managed files this run changed, space-separated

# differs WHAT [WHY]: one difference, in --check.
differs() {
  differences=$((differences + 1))
  echo "differs  $1${2:+  ($2)}"
}
# did WHAT: one change made.
did() {
  changes=$((changes + 1))
  echo "changed  $*"
}
# refuse WHAT WHY: something not done, so the run ends non-zero.
refuse() {
  failed=1
  echo "refused  $1: $2"
}
was_changed() { [[ $changed == *" $1 "* ]]; }

# ---------------------------------------------------------------------------
# The managed files
# ---------------------------------------------------------------------------

install_file() {
  install -D -m 644 "$here/files$1" "$root$1" && did "$1" && changed+="$1 "
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
  if grep -qxi 'passwordauthentication no' <<< "$effective" &&
    ! grep -qE '^(ssh|ecdsa|sk-)' "$root/home/$admin/.ssh/authorized_keys" 2> /dev/null; then
    echo "$admin, who is running this, has no SSH key in ~/.ssh/authorized_keys, and it turns off password login"
  fi
}

# The sshd drop-in. It goes in place, then sshd checks the whole config; anything that
# could lock an admin or deploy out puts the old version back.
install_sshd_file() {
  local f="$1" dest="$root$1" backup="" why
  if [ -e "$dest" ]; then backup="$(mktemp)" && cp -p "$dest" "$backup"; fi
  install -D -m 644 "$here/files$f" "$dest" || return
  why="$(sshd_lockout)"
  if [ -n "$why" ]; then
    if [ -n "$backup" ]; then mv "$backup" "$dest"; else rm -f "$dest"; fi
    refuse "$f" "$why. The old version stays"
    return
  fi
  rm -f "$backup"
  did "$f"
  changed+="$f "
}

managed="$(cd "$here/files" && find . -type f | sed 's|^\.||' | sort)" || exit 3
while read -r f; do
  src="$here/files$f"
  dest="$root$f"
  cmp -s "$src" "$dest" && continue
  if $check; then
    if [ ! -e "$dest" ]; then
      differs "$f" "missing"
    elif [ ! -r "$dest" ]; then
      differs "$f" "can't read it to compare; run --check with sudo"
    else
      differs "$f" "changed"
      diff -u --label "$f (on the server)" --label "$f (in host/)" "$dest" "$src" | sed 's/^/    /'
    fi
    continue
  fi
  case "$f" in
    /etc/ssh/sshd_config.d/*) install_sshd_file "$f" ;;
    *) install_file "$f" ;;
  esac
done <<< "$managed"

# ---------------------------------------------------------------------------
# Packages: Docker from its repository, held, and unattended-upgrades
# ---------------------------------------------------------------------------

installed() { dpkg-query -W -f='${Status}' "$1" 2> /dev/null | grep -q 'install ok installed'; }

docker_was_installed=false
installed docker-ce && docker_was_installed=true

# ensure_installed PACKAGE...: installs whichever of them aren't, in one apt-get.
ensure_installed() {
  local p missing=()
  for p in "$@"; do installed "$p" || missing+=("$p"); done
  [ ${#missing[@]} = 0 ] && return
  if $check; then
    for p in "${missing[@]}"; do differs "package $p" "not installed"; done
  elif DEBIAN_FRONTEND=noninteractive apt-get update -q &&
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"; then
    did "installed ${missing[*]}"
  else
    refuse "packages ${missing[*]}" "apt-get failed"
  fi
}

ensure_installed "${DOCKER_PACKAGES[@]}"
ensure_installed unattended-upgrades

held="$(apt-mark showhold 2> /dev/null)"
unheld=()
for p in "${DOCKER_PACKAGES[@]}"; do
  grep -qxF "$p" <<< "$held" || unheld+=("$p")
done
if [ ${#unheld[@]} != 0 ]; then
  if $check; then
    for p in "${unheld[@]}"; do differs "package $p" "not held"; done
  elif apt-mark hold "${unheld[@]}" > /dev/null; then
    did "held ${unheld[*]}"
  else
    refuse "holding ${unheld[*]}" "apt-mark failed"
  fi
fi

# ---------------------------------------------------------------------------
# Reload what changed
# ---------------------------------------------------------------------------

if ! $check; then
  if was_changed /etc/ssh/sshd_config.d/00-indy-center.conf; then
    # try-: Ubuntu 24.04 starts sshd from a socket, so it may not be running. A new
    # connection reads the new config either way.
    systemctl try-reload-or-restart ssh && echo "reloaded ssh"
  fi
  # A fresh install already started Docker with daemon.json. live-restore keeps
  # containers running through a restart, once it is on.
  if was_changed /etc/docker/daemon.json && $docker_was_installed; then
    systemctl restart docker && echo "restarted docker"
  fi
  if was_changed /etc/systemd/journald.conf.d/00-indy-center.conf; then
    systemctl restart systemd-journald && echo "restarted systemd-journald"
  fi
  if was_changed /etc/sysctl.d/60-indy-center.conf; then
    sysctl -q -p "$root/etc/sysctl.d/60-indy-center.conf" && echo "loaded the sysctl settings"
  fi
fi

# ---------------------------------------------------------------------------
# The clock: UTC, kept by systemd-timesyncd
# ---------------------------------------------------------------------------

if [ "$(readlink "$root/etc/localtime")" != "$TIMEZONE" ]; then
  if $check; then
    differs /etc/localtime "not UTC"
  else
    ln -sfn "$TIMEZONE" "$root/etc/localtime" && did "/etc/localtime (UTC)"
  fi
fi

if ! systemctl is-active --quiet systemd-timesyncd; then
  if $check; then
    differs systemd-timesyncd "not running"
  elif systemctl enable --now systemd-timesyncd; then
    did "started systemd-timesyncd"
  else
    refuse systemd-timesyncd "couldn't start it"
  fi
fi

# ---------------------------------------------------------------------------
# Swap: a 4 GB swapfile, in fstab and on
# ---------------------------------------------------------------------------

swapfile="$root/swapfile"
swap_on() { swapon --show=NAME --noheadings 2> /dev/null | grep -qxF "$swapfile"; }

if [ "$(stat -c %s "$swapfile" 2> /dev/null)" != $((SWAPFILE_GB * 1024 * 1024 * 1024)) ]; then
  if $check; then
    differs /swapfile "missing, or not $SWAPFILE_GB GB"
  elif swap_on && ! swapoff "$swapfile"; then
    refuse /swapfile "it isn't $SWAPFILE_GB GB, and swapoff couldn't free it to replace it. Run apply.sh again after a reboot"
  else
    rm -f "$swapfile"
    if fallocate -l "${SWAPFILE_GB}G" "$swapfile" && chmod 600 "$swapfile" && mkswap "$swapfile" > /dev/null; then
      did "/swapfile ($SWAPFILE_GB GB)"
    else
      refuse /swapfile "couldn't create it"
    fi
  fi
elif [ "$(stat -c %a "$swapfile")" != 600 ]; then
  if $check; then differs /swapfile "not mode 600"; else chmod 600 "$swapfile" && did "/swapfile (mode 600)"; fi
fi

if ! grep -qE '^/swapfile[[:space:]]' "$root/etc/fstab" 2> /dev/null; then
  if $check; then
    differs /etc/fstab "no /swapfile line"
  else
    echo "/swapfile none swap sw 0 0" >> "$root/etc/fstab" && did "/etc/fstab (/swapfile line)"
  fi
fi

if ! swap_on; then
  if $check; then
    differs "swap" "/swapfile is not on"
  elif [ -f "$swapfile" ]; then
    swapon "$swapfile" && did "swap on"
  fi
fi

# ---------------------------------------------------------------------------
# /home/deploy and the traefik-shared network
# ---------------------------------------------------------------------------

dirs=("$root/home/deploy")
for d in "${DEPLOY_DIRS[@]}"; do dirs+=("$root/home/deploy/$d"); done
missing=()
for d in "${dirs[@]}"; do [ -d "$d" ] || missing+=("${d#"$root"}"); done
if [ -d "$root/home/deploy" ] && [ ! -x "$root/home/deploy" ]; then
  # Only deploy and root can look inside, so an admin's --check without sudo can't tell.
  echo "skipped  /home/deploy's folders (can't look inside as $(id -un); run --check with sudo to include them)"
elif [ ${#missing[@]} != 0 ]; then
  if $check; then
    for d in "${missing[@]}"; do differs "$d" "missing"; done
  elif mkdir -p "${dirs[@]}" && chown deploy:deploy "${dirs[@]}"; then
    did "${missing[*]}"
  else
    refuse "/home/deploy" "couldn't create its folders"
  fi
fi

if docker info > /dev/null 2>&1; then
  if ! docker network inspect "$NETWORK" > /dev/null 2>&1; then
    if $check; then
      differs "Docker network $NETWORK" "missing"
    elif docker network create "$NETWORK" > /dev/null; then
      did "Docker network $NETWORK"
    else
      refuse "Docker network $NETWORK" "docker network create failed"
    fi
  fi
elif $check; then
  echo "skipped  Docker network $NETWORK (can't reach Docker as $(id -un); run --check with sudo to include it)"
else
  refuse "Docker network $NETWORK" "Docker isn't running"
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

if [ "$changes" = 0 ] && [ "$failed" = 0 ]; then
  echo "Nothing to change: the server already matches host/."
fi
[ "$failed" = 0 ] || echo "Some changes were refused or failed (above); the rest were made." >&2
exit "$failed"
