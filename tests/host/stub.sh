#!/usr/bin/env bash
# Stands in for the commands host/apply.sh needs a real kernel, init or apt for. The tests
# put a wrapper per command in a folder first on PATH, which runs this with STUB_NAME set
# to the command's name. Every call is logged to $STUB_LOG, one line each ("systemctl
# restart docker"), and what a real system would remember (installed and held packages,
# swap, Docker networks) is kept under $STUB_STATE.
name="$STUB_NAME"
echo "$name $*" >> "$STUB_LOG"
state="$STUB_STATE"
mkdir -p "$state/installed" "$state/held" "$state/networks"
touch "$state/swaps"

case "$name" in
  dpkg-query)
    # dpkg-query -W -f='${Status}' <package>
    pkg="${*: -1}"
    if [ -e "$state/installed/$pkg" ]; then echo "install ok installed"; else exit 1; fi
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
      "network inspect") [ -e "$state/networks/$3" ] ;;
      "network create") touch "$state/networks/$3" ;;
      *) exit 0 ;;
    esac
    ;;
  *) exit 0 ;;
esac
