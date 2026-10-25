#!/usr/bin/env bash
# Tests that the deploy ships host/ to ~/host/ on each server and never runs it. It runs
# build-and-deploy.yml's own step, with a fake ssh that runs the server's side in a temp
# folder standing in for deploy's home, and logs each command the step sends there.
#
#   bash tests/host/deploy-test.sh
#
# Needs rsync and python3 with PyYAML.
set -uo pipefail

repo="$(cd "$(dirname "$0")/../.." && pwd)"
STEP="Sync host/ to ~/host/ (never run)"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home" "$T/bin"

# The step's shell, exactly as the workflow has it.
python3 - "$repo/.github/workflows/build-and-deploy.yml" "$STEP" > "$T/step.sh" <<'EOF' || exit 1
import sys, yaml
steps = yaml.safe_load(open(sys.argv[1]))["jobs"]["build-and-deploy"]["steps"]
run = [s["run"] for s in steps if s.get("name") == sys.argv[2]]
if not run:
    sys.exit(f"no step named {sys.argv[2]!r} in build-and-deploy.yml")
print(run[0])
EOF

# ssh vps <command>: runs the command in the fake home, as the server would, and logs it.
cat > "$T/bin/ssh" <<EOF
#!/usr/bin/env bash
while [ "\$1" != vps ]; do shift; done
shift
echo "\$*" >> "$T/remote-commands"
cd "$T/home" && exec bash -c "\$*"
EOF
chmod +x "$T/bin/ssh"

failed=0
fail() { echo "FAIL: $*"; failed=1; }

# Something left over from an earlier deploy, which --delete should remove.
mkdir -p "$T/home/host" && touch "$T/home/host/dropped-from-the-repo"

(cd "$repo" && PATH="$T/bin:$PATH" RSYNC_RSH="$T/bin/ssh" bash -e "$T/step.sh") || fail "the step failed"

diff -r "$repo/host" "$T/home/host" > /dev/null || fail "the server's host/ differs from the repo's:$(diff -rq "$repo/host" "$T/home/host")"
# Nothing ran on the server but rsync's receiving end: apply.sh would have written
# /etc files, created ~/apps and the rest, which a copy never does.
others="$(grep -v '^rsync --server ' "$T/remote-commands")"
[ -z "$others" ] || fail "the step ran more than rsync on the server: $others"
[ "$(ls "$T/home")" = host ] || fail "the step made more than ~/host: $(ls "$T/home")"

[ "$failed" = 0 ] && echo "ok   the deploy ships host/ to ~/host/ and runs nothing"
exit "$failed"
