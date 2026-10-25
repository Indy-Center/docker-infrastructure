# host/: a server's base setup

Everything below Docker on a server docker-infrastructure deploys to, as files in git: who
can log in over SSH, Docker itself, security updates, logs, swap and the clock. A fresh
Ubuntu 26.04 server gets it from one script at its first login. After that, a change is a
pull request, which an admin applies by hand.

Nothing here is secret: the keys in it are public halves.

| Path | What it is |
| ---- | ---------- |
| `bootstrap.sh` | Run once, as root, at a new server's first login. Creates the first admin and `deploy`, sets the hostname, runs `apply.sh`, then adds `deploy` to `docker` |
| `apply.sh` | Makes the server match `files/` and the rest of the list below. Safe to run again. `--check` prints what differs and changes nothing |
| `files/` | The config files, at the paths they go to on the server (`files/etc/docker/daemon.json` is `/etc/docker/daemon.json`) |

## What `apply.sh` sets

| What | How |
| ---- | --- |
| SSH | `/etc/ssh/sshd_config.d/00-indy-center.conf`: keys only, no root login, no X11 forwarding, and `AllowUsers` lists every admin plus `deploy`. Port 22. No fail2ban: with keys only, password guessing can't succeed |
| Docker | From Docker's own apt repository for the server's Ubuntu release (`docker.sources`, whose `Suites:` `apply.sh` fills in from `/etc/os-release`; signed by `docker.asc`, Docker's key `9DC8 5822 9FC7 DD38 854A E2D8 8D81 803C 0EBF CD88`), never the snap. Its packages are held. `daemon.json` turns on `live-restore`, so containers keep running while the daemon restarts, and gives every container json-file logs of 10m × 5 unless it sets its own |
| Updates | `unattended-upgrades` installs security updates every day, and never reboots. An admin reboots by hand at a quiet time, away from the 07:00 UTC backups |
| Logs | journald keeps at most 1 GB, for 30 days, overriding the image's own `journald.conf` |
| Memory | A 4 GB `/swapfile`, in `/etc/fstab`, at swappiness 10 |
| Clock | UTC, the runner's timezone, kept synchronised by whichever time service the image came with (chrony on ALEXANDRIA, or `systemd-timesyncd`). `apply.sh` starts it if it's stopped, but never installs one: installing `systemd-timesyncd` would remove chrony. `--check` reports a clock that isn't synchronised |
| `/home/deploy` | `traefik/`, `apps/`, `backup-runner/` and `backups/`, owned by `deploy` |
| Docker network | `traefik-shared`, which Traefik and every app join |

It changes only what differs, and reloads only what changed: `ssh` for the sshd drop-in,
Docker for `daemon.json` (its containers stay up, since `live-restore` is on), journald,
and the swappiness setting. A reload that fails counts as refused: the run says so and
exits non-zero, since the new config is in place but not in use.

It never touches users or keys (`bootstrap.sh` makes the first two, and admins the rest by
hand), the hostname, or the firewall, which is Hostinger's (below). There is no `ufw`:
it can't see the ports Docker publishes, so it would look like it covers them when it
doesn't.

### SSH guards

A bad sshd config can lock everyone out, so `apply.sh` puts the drop-in in place, checks
the whole sshd config, and puts the old version back (and says why) if:

- `sshd -t` rejects it;
- `deploy` isn't in `AllowUsers` (every deploy would fail);
- the admin running it isn't in `AllowUsers`;
- it turns off password login and the admin running it has no key in
  `~/.ssh/authorized_keys`.

It knows the admin from `sudo`, so run it with `sudo` from your own account, not from a
root shell. The rest of the setup is still applied, and the run exits non-zero.

## First login (a new server)

As root, from the provider's console or over SSH. Before running anything, note what the
image came with, since Hostinger doesn't document it:

```bash
sshd -T | grep -Ei 'passwordauth|permitroot'
swapon --show
systemctl list-units --type=service --state=running
```

Fetch `host/` at a pinned commit: the full SHA of the commit you reviewed (the head of the
merged pull request, or `git rev-parse HEAD` in your checkout), never a branch name, so
what runs is exactly what you read. The repository is public, so no login is needed:

```bash
commit=<full commit SHA>
curl -fsSL "https://github.com/Indy-Center/docker-infrastructure/archive/$commit.tar.gz" | tar -xz
cd "docker-infrastructure-$commit/host"
```

Then run `bootstrap.sh` with the server's hostname, your username, your public key, and the
public half of the new `deploy` key pair made for this server (never another server's: a
leak on one server then can't open another). Quote each key, since it has spaces:

```bash
bash bootstrap.sh alexandria hayden 'ssh-ed25519 AAAA... hayden@laptop' 'ssh-ed25519 AAAA... deploy@alexandria'
```

You must already be in `AllowUsers` in `files/etc/ssh/sshd_config.d/00-indy-center.conf`;
it stops before changing anything if you aren't. It first runs `apt-get update` and
`upgrade`, since an image's package lists can be weeks old. It asks for your password, which `sudo`
asks for later. `deploy`'s key line gets `restrict`: no forwarding, no terminal, no
`~/.ssh/rc`, none of which the deploy's commands and rsync need. It removes cloud-init's
`/etc/sudoers.d/90-cloud-init-users`, which grants passwordless sudo to an `ubuntu` user
the image doesn't have (any `ubuntu` account made later would get root), then checks the
sudoers files with `visudo -c` and stops if they fail. Once `apply.sh` has
finished, it removes `/etc/ssh/sshd_config.d/01-interim.conf`, if an admin put one there to
turn password login off until bootstrap ran. Run again, it changes only what isn't right
yet.

**Before closing the root session,** check from a second terminal that you can log in and
use sudo, since root can't log in over SSH any more:

```bash
ssh hayden@alexandria.flyzid.org
sudo -v
```

Then open Hostinger's browser terminal once to check it works. It is a serial console, so
it still gets you in if SSH locks you out.

## Applying a change

Change the files here in a pull request. Once it's merged, the deploy copies `host/` to
`/home/deploy/host/` on every server, but never runs it. On each server, from your own
account:

```bash
sudo bash /home/deploy/host/apply.sh --check   # read what would change
sudo bash /home/deploy/host/apply.sh
```

`--check` prints a `differs` line for each difference (with a diff for a changed file) and
ends with the count. It exits 0 when the server matches, 1 when it doesn't, 2 for a bad
option, and 3 when it couldn't finish, so its list isn't complete. It needs no root, so
the backup runner can run it as `deploy`. What it can't see as the user running it counts
as a difference, since it can't say the server matches: the Docker network without access
to Docker (or with Docker down), and `/home/deploy`'s folders from an admin's account
(`deploy`'s home is private). Run it with `sudo` to see both.

It also prints an `extra` line for each sshd drop-in that isn't in `files/`, such as the
image's own `50-cloud-init.conf`, saying if it sets `PasswordAuthentication yes` or lets
root log in. These aren't differences: `00-indy-center.conf` sorts first, and sshd keeps
the first value it reads, so they can't undo it. Likewise for each file in
`/etc/sudoers.d/` apart from sudo's `README`: `host/` manages none, so any there was added
by hand or by the image. That folder is root's alone, so without `sudo` it says it can't
list it.

To upgrade Docker (about every quarter, at a quiet time):

```bash
sudo apt-mark unhold docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo apt-get update && sudo apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo bash /home/deploy/host/apply.sh   # holds them again
```

## Adding or removing an admin

Each admin has their own account, in `sudo` with their own password, and not in `docker`.

**To add one:**

1. In a pull request, add their username to `AllowUsers` in
   `files/etc/ssh/sshd_config.d/00-indy-center.conf`, and merge it.
2. On each server, as an existing admin, make the account and install their key. Get the
   key from them directly, never from GitHub's list of their keys, which trusts every key
   they have ever added:

   ```bash
   sudo adduser steve                 # asks for their password; give it to them privately
   sudo usermod -aG sudo steve
   sudo install -d -m 700 -o steve -g steve /home/steve/.ssh
   echo 'ssh-ed25519 AAAA... steve@laptop' | sudo tee /home/steve/.ssh/authorized_keys > /dev/null
   sudo chown steve:steve /home/steve/.ssh/authorized_keys
   sudo chmod 600 /home/steve/.ssh/authorized_keys
   ```

3. Apply the change: `sudo bash /home/deploy/host/apply.sh --check`, then without `--check`.
4. Have them log in and run `sudo -v`.

**To remove one** (as another admin; `apply.sh` won't let you remove yourself):

1. In a pull request, remove them from `AllowUsers`, and merge it.
2. On each server: apply the change, then `sudo deluser --remove-home steve`.

## Hostinger's firewall

Hostinger's firewall runs in their network, before traffic reaches the server, so it also
covers ports Docker publishes. Set it by hand in the server's firewall settings in hPanel,
one set of rules per server, for IPv4 and IPv6. It drops everything not allowed:

| Protocol | Port | Source | For |
| -------- | ---- | ------ | --- |
| TCP | 22 | any | SSH |
| TCP | 80 | any | Traefik (redirects to HTTPS) |
| TCP | 443 | any | Traefik |
| UDP | 9987 | any | TeamSpeak voice, only once TeamSpeak moves to the server |
| TCP | 30033 | any | TeamSpeak file transfer, only once TeamSpeak moves |

Nothing else, including TeamSpeak's ServerQuery ports. Apps publish no ports of their own
(TeamSpeak is the one exception), which review checks.

### The outside port test

Once, after setting the firewall, prove it drops a port nothing allows. On the server:

```bash
sudo docker run --rm -d --name port-test -p 9999:80 traefik/whoami
```

From your own computer, this must time out, not answer:

```bash
curl -m 5 http://alexandria.flyzid.org:9999/
```

Then, on the server, remove it and check nothing else is listening that shouldn't be: only
sshd on 22, Docker's proxy on 80 and 443 for Traefik, and services on `127.0.0.x`:

```bash
sudo docker stop port-test
sudo ss -tulpn
```

## If the server's IP changes

Hostinger doesn't promise to keep it. Everything uses the server's hostname
(`alexandria.flyzid.org`), never its IP, so a change is fixed by hand in three places:

1. **Its DNS record:** in Cloudflare, set the server's A record (DNS only, not proxied) to
   the new IP. App records are CNAMEs to it, so they follow.
2. **The Cloudflare DNS token's IP allow-list:** add the new IP and remove the old one.
   Until then, Traefik can't renew its certificate.
3. **The known-hosts line:** from your computer, `ssh-keyscan alexandria.flyzid.org`. If the
   line differs from the `<SERVER>_KNOWN_HOSTS` org secret (it will if the server was
   rebuilt), check its fingerprint against the browser terminal's
   (`ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`) and update the secret.

The status page shows the outage until DNS catches up. Hostinger's firewall rules belong
to the server, so they stay.

## Tests

CI runs these on every pull request (`.github/workflows/ci.yml`, job `host`):

- `bash tests/host/test.sh`: `apply.sh` against a fake server root, with the commands that
  need a real kernel, init or apt (`systemctl`, `apt-get`, `swapon`, `docker`, ...)
  stubbed, and the real `sshd`. Needs `openssh-server`.
- `bash tests/host/bootstrap-test.sh`: `bootstrap.sh` in an `ubuntu:26.04` container, run
  twice. Needs Docker.
- `bash tests/host/deploy-test.sh`: the deploy's step that copies `host/`, against a fake
  server, showing it lands and nothing runs.
