#!/usr/bin/env bash
# Stands in for the commands host/apply.sh needs a real kernel, init or apt for. The tests
# put a wrapper per command in a folder first on PATH, which runs this with STUB_NAME set
# to the command's name. Every call is logged to $STUB_LOG, one line each ("systemctl
# restart docker"), and what a real system would remember (installed and held packages,
# swap, running services, Docker networks) is kept under $STUB_STATE.
name="$STUB_NAME"
echo "$name $*" >> "$STUB_LOG"
state="$STUB_STATE"
mkdir -p "$state/installed" "$state/held" "$state/networks" "$state/active"
touch "$state/swaps"

# A test makes a command fail with a <command>-fails file, as swapoff does when the memory
# it holds can't go elsewhere.
[ ! -e "$state/$name-fails" ] || exit 1

case "$name" in
  systemctl)
    case "${1:-}" in
      is-active) [ -e "$state/active/${*: -1}" ] ;;
      enable) touch "$state/active/${*: -1}" ;;
    esac
    ;;
  timedatectl)
    # timedatectl show -p NTPSynchronized --value: synchronised, unless a test made it not.
    if [ -e "$state/unsynchronised" ]; then echo no; else echo yes; fi
    ;;
  swapoff)
    grep -vxF "$1" "$state/swaps" > "$state/swaps.new"
    mv "$state/swaps.new" "$state/swaps"
    ;;
  dpkg-query)
    # dpkg-query -W -f=<format> <package>, for ${Status} ("hold ok installed" once the
    # package is held, as real dpkg says) or ${db:Status-Status} ("installed").
    pkg="${*: -1}"
    [ -e "$state/installed/$pkg" ] || exit 1
    # shellcheck disable=SC2016 # the format's text, not an expansion
    case "$*" in
      *'${db:Status-Status}'*) echo installed ;;
      *) if [ -e "$state/held/$pkg" ]; then echo "hold ok installed"; else echo "install ok installed"; fi ;;
    esac
    ;;
  apt-get)
    if [ "${1:-}" = install ]; then
      for arg in "${@:2}"; do
        case "$arg" in -*) ;; *) touch "$state/installed/$arg" ;; esac
        # Docker's package creates the docker group. Only possible as root, in a container.
        if [ "$arg" = docker-ce ] && [ "$(id -u)" = 0 ]; then groupadd -f docker; fi
      done
    fi
    ;;
  apt-mark)
    case "${1:-}" in
      hold) for p in "${@:2}"; do touch "$state/held/$p"; done ;;
      showhold) ls "$state/held" ;;
    esac
    ;;
  fallocate)
    # fallocate -l <size> <file>: a sparse file of that size, so no disk is used.
    truncate -s "$2" "$3"
    ;;
  swapon)
    case "${1:-}" in
      --show*) cat "$state/swaps" ;;
      *) echo "$1" >> "$state/swaps" ;;
    esac
    ;;
  docker)
    case "$1 ${2:-}" in
      "info "*) [ ! -e "$state/docker-down" ] ;;
      "network inspect") [ -e "$state/networks/$3" ] ;;
      "network create") touch "$state/networks/$3" ;;
      *) exit 0 ;;
    esac
    ;;
  *) exit 0 ;;
esac
