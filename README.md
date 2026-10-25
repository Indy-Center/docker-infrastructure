# docker-infrastructure

The Traefik reverse proxy and backup runner for Indy Center's servers. Traefik terminates TLS for `*.flyindycenter.com` and routes traffic to every app container on its box; the runner backs up every app's data to Cloudflare R2. GitHub Actions deploys both to every server on push to `main`.

Each server runs its own Traefik and runner. DNS decides which server answers each hostname, and each Traefik routes only the containers on its own box. Today that is the Vanderbilt VPS (a DigitalOcean droplet) and the new server beside it, while apps move across.

[![Build and Deploy](https://github.com/Indy-Center/docker-infrastructure/actions/workflows/build-and-deploy.yml/badge.svg)](https://github.com/Indy-Center/docker-infrastructure/actions/workflows/build-and-deploy.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

This repository holds the machinery shared by every app on the box, and no app. Each app has its own repository, its own `ci.yml` / `build-and-deploy.yml`, and its own `docker-compose.yml` under `/home/deploy/apps/<app>/`. It joins Traefik over a shared Docker network, and ships its own backup recipe (see [Backups](#backups)).

## Project layout

- `traefik/`: everything deployed to `/home/deploy/traefik/` on the VPS, and nothing else.
  - `docker-compose.yml`: the Traefik service. Publishes `:80` and `:443`, joins `traefik-shared`, and keeps issued certificates in the `acme` volume.
  - `traefik.yml`: static config, meaning the entrypoints (`web` redirects to `websecure`), the `letsencrypt` DNS-01 resolver and the Docker and file providers.
  - `dynamic/`: file-provider config. Traefik watches it, so changes apply without a restart. `tls.yml` requests the wildcard certificate, and `dashboard.yml` routes the dashboard.
- `examples/app/`: what an app's own repository copies to run behind Traefik: `deploy/docker-compose.yml` (what lands in `~/apps/<app>/`) and `.github/workflows/` (CI and deploy over SSH). GitHub only runs workflows from the repository root, so these never run here.
- `backup-runner/`: everything deployed to `/home/deploy/backup-runner/`, the backup runner (see [Backups](#backups)).
  - `run-backups.sh`: the runner. Cron starts it every hour.
  - `lib.sh`: the runner's settings and its steps for backing up one app, shared by `run-backups.sh` and `backups.sh`.
  - `backups.sh`: the [helper commands](#helper-commands), for people.
  - `schedule.conf`: how often each app is backed up, and how long its frequent copies are kept.
  - `media.conf`: the CMS's media buckets the media copy copies.
  - `install-tools.sh`: installs pinned, checksum-checked age and rclone into `~/backup-runner/bin/`.
  - `install-cron.sh`: installs the runner's hourly crontab entry for `deploy`.
  - `install-command.sh`: installs the `backups` command for `deploy`.
- `app-dns/`: deployed to `/home/deploy/app-dns/`. `app-dns.py` creates an app's missing DNS record when the app deploys (see [The app's DNS record](#the-apps-dns-record)), and `install.sh` installs it as the `app-dns` command for `deploy`.
- `host/`: each server's base setup below Docker, copied to `/home/deploy/host/` and never run by the deploy (see [Server base setup](#server-base-setup)).
- `tests/host/`: `host/`'s tests: `apply.sh` against a fake server root, `bootstrap.sh` in an `ubuntu:26.04` container, and the deploy's copy of `host/`. Never deployed.
- `tests/backup-runner/`: the runner's tests (`test.sh`) and the helper commands' (`helpers-test.sh`), run in CI on a fake VPS (`fake-vps.sh`). Never deployed.
- `tests/app-dns/`: `app-dns`'s tests (`test.sh`), against a fake Cloudflare API that records each request (`fake-cloudflare.py`), never the real one; and the deploy's steps that install it and the example app's that runs it (`deploy-test.sh`). Never deployed.
- `staging/`: a throwaway Traefik against Let's Encrypt staging, used by `staging.yml` to prove certificate issuance. Never deployed.
- `.github/workflows/ci.yml`: starts Traefik against the config and checks the container stays up, and runs the backup runner's and `host/`'s tests.
- `.github/workflows/build-and-deploy.yml`: runs CI, then, for each server in its list, rsyncs `traefik/` to `/home/deploy/traefik/` and runs `docker compose up -d` over SSH. Then it writes the runner's secrets (rclone config, age key, Discord webhooks), rsyncs `backup-runner/` to `/home/deploy/backup-runner/`, and installs its tools, crontab entry and `backups` command. Last, it rsyncs `host/` to `/home/deploy/host/`, without running it, then writes the server's hostname for `app-dns`, rsyncs `app-dns/` to `/home/deploy/app-dns/` and installs the `app-dns` command.

## Server base setup

Everything below Docker on a server (SSH logins, Docker from its apt repository, security updates, journald's cap, swap, UTC, the `/home/deploy` layout and `traefik-shared`) is in [`host/`](host/README.md): real config files, a `bootstrap.sh` an admin runs once as root on a fresh Ubuntu 26.04 server, and an `apply.sh` that makes a server match the files and is safe to run again. The setup is the same work on every server and should come out the same each time, so it lives in git rather than in someone's memory; an admin applies each change by hand, with `--check` first, rather than the deploy, because a bad SSH change applied with nobody watching could lock everyone out. The DigitalOcean droplet predates `host/` and was set up by hand.

## Certificates

Traefik requests one wildcard certificate, `flyindycenter.com` + `*.flyindycenter.com`, from Let's Encrypt using the DNS-01 challenge through Cloudflare, and serves it as the default certificate. Apps don't request their own. `tls=true` on a router is enough.

The Cloudflare token is the repository secret `CF_DNS_API_TOKEN`, one token shared by every server. Every deploy writes it to `/home/deploy/traefik/.env` (mode 600, never in git), and Traefik reads it at every renewal. [`app-dns`](#the-apps-dns-record) uses it too, to create a new app's record. The deploy owns that file and rewrites it each run, so don't edit it on the server. To rotate the token, roll it in Cloudflare, update 1Password ("Traefik — Cloudflare DNS token") and the secret, then run **Build and Deploy** by hand. The token is scoped to Zone:DNS:Edit on the one zone and locked to an allow-list of IPs: a new server's IP goes on it before its Traefik can get the certificate.

## Adding an app

Only containers labelled `traefik.enable=true` are routed (`exposedByDefault: false`). An app's `docker-compose.yml` joins the shared network and labels its web service. [`examples/app/deploy/docker-compose.yml`](examples/app/deploy/docker-compose.yml) is the full version:

```yaml
services:
  app:
    # ...
    networks:
      - traefik-shared
    labels:
      - traefik.enable=true
      - traefik.http.routers.myapp.rule=Host(`myapp.flyindycenter.com`)
      - traefik.http.routers.myapp.entrypoints=websecure
      - traefik.http.routers.myapp.tls=true
      - traefik.http.services.myapp.loadbalancer.server.port=3000

networks:
  traefik-shared:
    external: true
```

Router names (`myapp` above) must be unique across every app on the box. Keep databases and other internal services on the app's own network, not on `traefik-shared`. Don't publish ports on the host. Traefik reaches the container over the network.

An app runs on one server, picked by that server's settings prefix in `SERVER` at the top of its [`build-and-deploy.yml`](examples/app/.github/workflows/build-and-deploy.yml) (`SERVER: ALEXANDRIA` reads `ALEXANDRIA_HOST` and the other three [settings](#deployment)). An org admin gives the app's repository access to those four settings.

### The app's DNS record

A new app's hostname works from its first deploy, with no trip to Cloudflare. After `docker compose up -d`, the example workflow's **DNS record** step runs `~/.local/bin/app-dns --app <app>` on the server (by its full path: a command sent over SSH doesn't get `~/.local/bin` on `PATH`). It reads every hostname in the app's Traefik `Host()` rules (through `docker compose config`, so only services with `traefik.enable=true`), and for each one, in Cloudflare:

| The hostname has | app-dns |
| ---------------- | ------- |
| No record of its own (a name only the `*.flyindycenter.com` wildcard answers has none) | Creates a DNS-only CNAME to the server's hostname, its `_HOST` setting (`alexandria.flyzid.org`) |
| A CNAME to this server already | Does nothing |
| Any other record: a CNAME elsewhere, an A record | Warns, naming where it points, and leaves it alone. The step still passes |

It never changes or deletes a record. So **switching an app's DNS to another server during a move stays a step done by hand**, in the move's ticket, and a typo in a `Host()` rule can leave a stray record but can't take over another app's. Names outside the token's zone (`flyindycenter.com`) are skipped with a warning. A Cloudflare error fails the step with Cloudflare's message; the app is already up by then. On a server whose `_HOST` setting is an IP rather than a hostname, it warns and makes no records.

It runs on the server because it uses Traefik's Cloudflare token (`~/traefik/.env`), which Cloudflare accepts only from the servers' IPs. docker-infrastructure's deploy installs it, from [`app-dns/`](app-dns/), and writes the server's hostname to `~/app-dns/server-host`. `app-dns <hostname>...` does the same for names given by hand, and `app-dns --help` explains it.

**Opting out.** An app whose first visitor matters, such as Postiz, whose first sign-up owns it, wants its record made only after that first run: its owner signs up through a hosts-file line first, so nobody else can get there before them. Such an app leaves the **DNS record** step out of its workflow until its first run is done, and then either adds the step or makes the record by hand. Adding it later is safe: a record already pointing at the server is left as it is. Apps that already run, and are moving, add the step when they move; by then their record points at the new server, so the step does nothing.

## VPS layout

| Path | Owner | Purpose |
| ---- | ----- | ------- |
| `/home/deploy/traefik/` | `deploy` | This repository's deployed config, plus `.env` with the Cloudflare token, written by each deploy (not in git) |
| `/home/deploy/apps/<app>/` | `deploy` | One directory per app, deployed by that app's workflow |
| `/home/deploy/backup-runner/` | `deploy` | The backup runner, deployed from `backup-runner/`, plus `secrets/`, `bin/`, `state/` and `logs/` (not in git) |
| `/home/deploy/backups/<app>/` | `deploy` | Staging area for one app's backup while the runner encrypts and uploads it. Emptied after each one |
| `/home/deploy/host/` | `deploy` | The server's [base setup](#server-base-setup), deployed from `host/` for an admin to apply. Never run by the deploy |
| `/home/deploy/app-dns/` | `deploy` | [`app-dns`](#the-apps-dns-record), deployed from `app-dns/`, plus `server-host`, the server's hostname, written by each deploy (not in git). `~/.local/bin/app-dns` runs it |

On a server set up from `host/`, Docker comes from Docker's apt repository, its packages are held, and `apply.sh` creates `traefik-shared`. The rest of this section is about the droplet.

Everything lives under the deploy user's home folder because Docker on the droplet is the Canonical snap. Snap confinement stops both the `docker` CLI and the daemon from reading paths such as `/opt`, but allows non-hidden paths under `/home`. The snap's automatic updates would restart every container, so they are held (`snap refresh --hold docker`). Update Docker by hand in a quiet period with `snap refresh docker`.

Docker network `traefik-shared` is created once, by hand (`docker network create traefik-shared`). Every compose project, this one included, treats it as `external: true`.

Traefik also joins `frontend`, the network the previous Traefik used, so apps not yet moved to `traefik-shared` stay reachable after cutover. Once nothing is left on `frontend` (DEV-170), it comes out of `traefik/docker-compose.yml`.

## Dashboard

The dashboard is read-only and listens on the VPS's loopback address only, never on a public port. To open it, tunnel over SSH:

```bash
ssh -L 8080:localhost:8080 <user>@<vps>
# then browse to http://localhost:8080/dashboard/
```

## Backups

The **runner** (`backup-runner/run-backups.sh`) backs up every app in `/home/deploy/apps/` to the Cloudflare R2 bucket `indy-center-backups`. Cron starts it as `deploy` at minute 7 of every hour. Each run, for each app that is due:

1. runs the app's **recipe** (`backup.sh`) with an empty output folder;
2. encrypts the one file the recipe wrote with `age`;
3. uploads it to the bucket, then copies the first backup of each day to `daily/` and the first of each month to `monthly/`;
4. empties the app's staging folder, `/home/deploy/backups/<app>/`.

Each night it also updates the **media copy**, and each Sunday it runs the **restore check** (both below).

A failed recipe, encryption or upload raises an **alert** in tech-team-alerts for that app, and the runner moves on to the next. Once a day, after the 07:00 UTC run, it posts the **backup report** to tech-team-notifications, then tells the status page the day's backups finished. The report lists each app's result, last good backup and space used, then each media bucket's file count and size in the media copy, then the last restore check's result.

Under that, on a server set up from [`host/`](#server-base-setup), the report says when the server is waiting on an admin, with one line for each that applies:

- `Reboot needed since 2026-10-18 (linux-image-…, libc6)`: security updates install themselves but never reboot the server, so `/var/run/reboot-required` is there, with the packages from `reboot-required.pkgs`. The date is when the runner first saw it. A reboot still needed after 14 days raises one alert, and the runner forgets it once the file goes (a reboot removes it). Reboot at a quiet time, away from the 07:00 UTC backups.
- `Host config: 2 differences from the repo, run apply.sh --check`: `~/host/apply.sh --check`, run as `deploy`, found the server differs from `host/`, usually a merged change not yet applied. Its `extra` lines, for files `host/` doesn't manage, aren't counted. A check that fails or takes over 10 minutes says `Host config: apply.sh --check failed to run (exit 3), see runner.log` instead, and its output is in the log.

The runner goes by whether `~/host/apply.sh` exists, and the deploy doesn't ship `host/` to the droplet, so the droplet's report has neither line, and the droplet raises no reboot alert.

Every server's runner posts to the same two channels, so the report's title (`Backups on vanderbilt for 2026-10-20`) and each alert (`vanderbilt: Backup of …`) name the server, and the status page ping adds `?server=vanderbilt`. The name is the server's settings prefix in lower case, which the deploy writes to `~/backup-runner/server`; the box's own hostname is whatever the provider set, so it isn't used. A runner without that file says `unnamed server`.

### What an app ships

The runner knows nothing about any app, except the CMS for the [restore check](#restore-check). An app takes part by shipping, in its repository's `deploy/` folder (so in `~/apps/<app>/` on the box), either:

- **`backup.sh` and `restore.sh`**.
  - `backup.sh` is the recipe. It is called with one argument, an empty folder, and must write exactly one file there holding a consistent copy of all the app's data (a database dump, or an archive of a dump and files). It exits non-zero on any failure.
  - `restore.sh` is the reverse. It is called with one argument, the path of a file `backup.sh` wrote (decrypted), and puts that data back into the running app, stopping and starting what it needs to.
- **An empty `no-backup` file**, for an app with nothing to keep. It shows as "no data" in the report.

An app with neither raises an alert every night until it ships one. An app with `backup.sh` but no `restore.sh` is still backed up, and the report notes it.

Both scripts:

- are run with `bash` (the deploy's rsync drops the execute bit), as `deploy`, from the app's folder;
- may use `docker`, `docker compose` and throwaway containers, but nothing else installed on the host;
- never encrypt, upload or delete old backups: the runner encrypts and uploads, and R2's lifecycle rules delete;
- are tested by the app's own CI: back up, wipe, restore, check the data is back.

A recipe still running after 2 hours is stopped and counts as failed. An app does not choose its own schedule; that is in `schedule.conf`, here.

### Schedule file

[`backup-runner/schedule.conf`](backup-runner/schedule.conf) has one line per app: its folder name, how often to back it up (1, 2, 3, 4, 6, 8, 12 or 24 hours, counted from 07:00 UTC), and how many days to keep its frequent copies (0 for none, which only works with 24):

```
payload  6  14
```

An app not listed is backed up nightly at 07:00 UTC, with no frequent copies. To change an app's schedule, change its line and merge; the deploy ships it. A line the runner can't read raises an alert, and that app falls back to nightly.

An app is also backed up when its last run was longer ago than its schedule allows. So a run missed while the VPS was down is made up at the next one, and a new app is backed up within the hour it appears.

### Media copy

The CMS keeps uploaded files in R2 buckets, not on the VPS, so its recipe doesn't hold them, and the CMS's own key can delete them. Each night at 07:00 UTC the runner copies any new files from each bucket listed in [`backup-runner/media.conf`](backup-runner/media.conf) into `media/<bucket>/` in `indy-center-backups`:

```
payload-media
payload-private
```

It never deletes or replaces a file in the copy: a file deleted at the source stays, and a file changed at the source keeps its first version. Payload never overwrites an upload, so a database backup from any date still finds its files. R2 copies the files itself; they don't pass through the VPS. A failed copy, or one still running after an hour, raises an alert for that bucket, and the next bucket is still copied. If `media.conf` is missing or lists no buckets, the runner alerts instead of copying nothing quietly. A night missed while the VPS was down is made up at the next run.

To copy another bucket, add its name and merge. It must be on the same Cloudflare account, and the runner's R2 key must be able to read it.

### Restore check

Every Sunday, in the 07:00 UTC run after the backups, the runner proves the newest CMS backup is usable with `backups restore-check` (a [helper command](#helper-commands), so you can also run it by hand). It:

1. downloads the newest `payload` backup in any tier and decrypts it;
2. unpacks `payload.tar`, which holds `payload.dump` and `row-counts.tsv` (each table in `public` and its row count, counted by payload's recipe at the same moment as the dump);
3. starts a throwaway Postgres 17 container, `backups-restore-check`, with no published port;
4. loads the dump with `pg_restore --no-owner --no-privileges`;
5. checks each table in `row-counts.tsv` is there with at least that many rows.

The container and the decrypted backup are removed afterwards, pass or fail. A failure raises an alert naming the step that failed (`Failed at load: pg_restore exited 1`, `Failed at check tables: table users is missing`), and the report shows `restore check  failed` with its time until the next check passes. A check still running after 30 minutes is stopped and shows as failed in the report, without an alert. A Sunday missed while the VPS was down is made up a week after the last check. A new box waits for its first Sunday. A box without `payload` runs no check. Run by hand, it first waits for any hourly run, since both use the same container name.

It loads the dump itself rather than running payload's `restore.sh` (decision 0005's standard way back), because `restore.sh` replaces the live CMS's data. So it proves the backup is good, not that `restore.sh` works: payload's own CI tests that.

That makes the restore check the one part of the runner that knows about an app. It knows the CMS by name (`CMS_APP=payload` in `lib.sh`; `scratch-cms` uses it too), and it relies on what payload's recipe writes: a `payload.tar` holding a custom-format `pg_dump` and a `row-counts.tsv` of `table<TAB>rows` lines. That format is a contract between the two repos that only this README records:

- If payload's recipe changes it (renames a file, drops the counts, or stops using `pg_dump`'s custom format), the next Sunday's check fails at "unpack" or "check tables" and alerts. Nothing breaks silently, but change both repos together.
- If the CMS's folder in `~/apps` is renamed, change `CMS_APP` to match. Until then the check stops running, and the restore check line drops out of the report.
- A second app with a database gets no restore check until the runner learns its format too.

### Where backups go

```
indy-center-backups/
  frequent/<app>/   every backup of an app with frequent copies (payload: every 6 hours),
                    and any second backup in a day of an app without them
  daily/<app>/      the first backup of each day, kept 60 days
  monthly/<app>/    the first backup of each month, kept 12 months
  media/<bucket>/   the media copy: every file ever uploaded to the CMS, not encrypted
```

Each file is named for the UTC time of its run and the recipe's file, plus `.age`: `daily/payload/2026-10-20T070000Z-payload.tar.age`. R2's lifecycle rules delete each tier's files at their age, and the bucket lock stops anyone, the VPS included, deleting them sooner. `media/` has no lifecycle rule; its lock protects each file for 60 days. `frequent/` has one age for every app, so it should match the largest "keep" in the schedule file. The runner doesn't delete anything itself, so an app's own "keep" is a note of what it needs; the lifecycle rule sets how long copies actually last.

### On the box

| Path | What it is |
| ---- | ---------- |
| `~/backup-runner/secrets/` | The runner's secrets, readable only by `deploy` (folder 700, files 600). Source copies in 1Password |
| `~/backup-runner/bin/` | The pinned `age`, `age-keygen` and `rclone`, installed by the deploy |
| `~/backup-runner/server` | The server's name for the report, alerts and status ping (`vanderbilt`), written by the deploy |
| `~/backup-runner/logs/runner.log` | Everything each run did, and all the recipes' output. At 5 MB it moves to `runner.log.1`, replacing the older one |
| `~/backup-runner/state/` | Each app's latest result and last run hour, the last restore check's, and when a reboot was first needed, for the schedule and the report. Losing it means every app is backed up at the next run, the restore check waits for Sunday, and a needed reboot dates from the file's own time |
| `~/.local/bin/backups` | The `backups` command: runs `~/backup-runner/backups.sh` |

```bash
tail -f ~/backup-runner/logs/runner.log
```

The secrets folder holds:

| File | What it is | Where it comes from |
| ---- | ---------- | ------------------- |
| `rclone.conf` | rclone config with one remote, `r2`, holding the runner's R2 key | The deploy, from this repository's secrets (below) |
| `age.key` | The age key that encrypts every backup and decrypts it for a restore. Its source copy is "Backups — age encryption key" in 1Password: **without it, every backup is unreadable** | The deploy |
| `report-webhook.url` | Discord webhook "Backups" in tech-team-notifications, for the daily backup report | The deploy |
| `alert-webhook.url` | Discord webhook "Backup alerts" in tech-team-alerts, for alerts | The deploy |
| `status-ping.url`, `status-ping.secret` | The status page's "backup finished" endpoint and its secret, sent as `Authorization: Bearer <secret>`. Until both exist the ping is skipped | By hand, once the status page exists |

The deploy writes each file mode 600, so a rebuilt VPS gets them back from one deploy. A missing webhook file is logged and the message skipped, so backups still run without Discord.

Never rotate the age key by replacing it: backups made with the old key need the old key to restore.

The R2 key can write to `indy-center-backups` and read the CMS media buckets, but cannot create or delete buckets. The rebuilt VPS gets it back from one deploy. To rotate it, make a new R2 token, update both secrets, and run **Build and Deploy** by hand. The [helper commands](#helper-commands) cover everyday jobs; to use the bucket by hand:

```bash
export PATH=~/backup-runner/bin:$PATH RCLONE_CONFIG=~/backup-runner/secrets/rclone.conf
rclone lsf r2:indy-center-backups/daily/payload/
```

### Helper commands

`backups` does each everyday backup job in one command, so nobody has to remember rclone or age. Run it as `deploy` on the VPS (from your own login, `sudo -iu deploy` first). The deploy installs it in `~/.local/bin` and adds that folder to `PATH` in `deploy`'s `~/.bashrc` and `~/.profile`, so any new shell finds it (one already open needs `exec bash -l`); `bash ~/backup-runner/backups.sh` is the same thing. Every command prints what it is about to do, and `backups <command> --help` explains it in full.

| Command | What it does |
| ------- | ------------ |
| `backups now <app>` | Backs up one app straight away, before a risky change. Exactly the runner's own steps (recipe, encrypt, upload), into `frequent/` only: it is never copied to `daily/` or `monthly/`, and the app's schedule is unchanged. A failure is shown, not sent to Discord |
| `backups list <app>` | Lists an app's backups, oldest first, with each one's size and the tiers it is in |
| `backups fetch <app> <backup> [folder]` | Downloads one backup and decrypts it into a folder (default: the current one), readable only by you. Never overwrites a file |
| `backups restore <app> <backup>` | Fetches and decrypts a backup, asks you to type the app's name, then runs the app's `restore.sh` with the file, which replaces the app's live data. Stops at a message if the app has no `restore.sh`. The decrypted file is deleted afterwards |
| `backups scratch-cms <backup>` | Loads a CMS backup into a throwaway Postgres 17 container, `backups-scratch-cms`, beside the live CMS, and prints how to connect: `docker exec` on the VPS, or an SSH tunnel to `127.0.0.1:15432` from your computer. The live CMS is never touched |
| `backups scratch-cms remove` | Removes that container and its data |
| `backups restore-check` | Loads the newest CMS backup into a throwaway Postgres 17 and checks its tables and row counts, then removes it: the weekly [restore check](#restore-check), run now. A failure is shown, not sent to Discord |
| `backups media-find <text>` | Finds files in the media copy whose path contains the text, in any case |
| `backups media-get <bucket>/<path> [folder]` | Downloads one file from the media copy, such as an image deleted from the CMS, and says where to upload it back in Cloudflare's dashboard (the runner's R2 key can only read the CMS's buckets) |
| `backups inventory` | Prints the VPS's facts under headings, for planning work: system, memory, disk, containers, images, volumes and sizes, networks, each `~/apps` folder's backup files, and the runner's last runs, alerts and results. It only reads. Agents have no access to the VPS, so paste them the whole output |

`<backup>` is a name from `backups list` (`2026-10-20T070000Z-payload.tar.age`), the start of one (`2026-10-20T07`), or `latest`. A start that matches more than one backup lists the matches and stops.

Only `restore` changes a live app, and it asks first. `now` and `restore` take the run lock just before they back up or restore (`restore` only once you have confirmed), and from then on write to `runner.log` as the hourly runs do. They wait for a running hourly run to finish, and an hourly run that starts while they work steps aside until the next hour, which makes up anything missed.

`scratch-cms` loads a `pg_dump` custom-format dump with `pg_restore`: the backup itself, or the dump inside it when it is a tar archive. payload's recipe writes `payload.tar`, holding `payload.dump` and `row-counts.tsv`, so it unpacks that and loads `payload.dump`. Ownership and grants are left out, since the dump's tables belong to the live CMS's `payload` role and the scratch database has only `postgres`. If `pg_restore` fails, it says so and stops, leaving the container to look at until you remove it.

The runbooks for recovering one app or rebuilding the VPS, being written for tech.flyindycenter.com's Operations section, are built on these commands.

### Running and testing it

To run it by hand, as `deploy`: `bash ~/backup-runner/run-backups.sh`. It does exactly what the hourly run does, so it backs up only what is due. To back up one app now, use `backups now <app>`.

`bash tests/backup-runner/test.sh` runs the runner's tests, and `bash tests/backup-runner/helpers-test.sh` the helper commands' (CI runs both on every pull request). Each test builds a fake VPS in a temp folder, with fake apps, a local folder standing in for R2, a test age key and a fake Discord. The runner's tests run it as a chosen time and check what landed where and what was sent; the helpers' tests run each command against backups the runner made, and check what it printed, downloaded, decrypted or restored. They need `age`, `age-keygen` and `rclone` on `PATH`: `bash backup-runner/install-tools.sh ~/.local/bin` installs them. The `scratch-cms` and restore check tests that load a dump also need Docker and the `postgres:17` image, and pass without running when Docker is missing.

## Deployment

`build-and-deploy.yml` calls `ci.yml` first and only deploys if it passes. It then deploys to each server in its `server:` list (`[VANDERBILT, …]`), by settings prefix, as a separate job: **add or drop a server in that list**. Every server gets the same Traefik, runner secrets, runner and tools. Each server's job has its own concurrency group, and one failing doesn't cancel the others. A server missing any of its four settings fails its own job at the first step, naming each missing setting, before anything reaches it, and so does an empty `CF_DNS_API_TOKEN`. On each server it writes `/home/deploy/traefik/.env` from that secret, then rsyncs `traefik/` into `/home/deploy/traefik/`, deleting files removed from the repo but never `.env`. Then it runs `docker compose up -d` over SSH and checks the container is still up 15 seconds later. `main` is protected, so changes go through a pull request with passing checks.

It runs on every push to `main`, and by hand from **Actions → Build and Deploy → Run workflow** (for example, to redeploy without a change).

`ci.yml` runs on every pull request. It starts Traefik and the example app on a runner, then checks that Traefik stays up, loads `dynamic/`, redirects HTTP to HTTPS and routes the example app. The runner has no Cloudflare token, so its certificate request fails against Let's Encrypt staging. That's expected. It also runs `bash tests/traefik/token-test.sh`, which runs the deploy's and the staging check's token steps against a fake server: the file gets the token and mode 600, an empty secret fails before reaching the server, and the token is never printed. And it runs `app-dns`'s tests, `bash tests/app-dns/test.sh` and `bash tests/app-dns/deploy-test.sh` (Python 3, plus `docker compose` for the `--app` cases), against a fake Cloudflare API that records each request.

`staging.yml` (**Actions → Staging certificate check**) runs the real pipeline without touching production. It uses the same secrets, SSH, rsync and `docker compose`, plus the real Cloudflare token, which it writes from the same secret into its own `~/traefik-staging/.env`, so it works on a new server before its first deploy. It starts a throwaway Traefik from `staging/` in `~/traefik-staging/` on the server, on `127.0.0.1:8443`. That Traefik asks Let's Encrypt **staging** for the wildcard using production's own `dynamic/tls.yml`, and the run passes once it serves a certificate covering `*.flyindycenter.com`. It then removes the container, volume and directory. Its `server` input picks the server to check, by settings prefix (default `VANDERBILT`). Run it before any change to certificate settings, and on a new server once its settings exist.

Organization secrets and variables (**Org Settings → Secrets and variables → Actions**), the same four for each server, named with its prefix. Access to each is limited to **Selected repositories**: this one, plus each app repository that runs on that server. Each deploy key can do anything `deploy` can on its server, and `deploy` is in the docker group.

`vanderbilt` is the DigitalOcean droplet, which runs every app until they move. `alexandria` is the new server, a Hostinger VPS at `alexandria.flyzid.org`.

| Name | Kind | Value |
| ---- | ---- | ----- |
| `VANDERBILT_HOST` | variable | The droplet's hostname or IP |
| `VANDERBILT_DEPLOY_USER` | variable | `deploy` |
| `VANDERBILT_DEPLOY_SSH_KEY` | secret | Private key of the droplet's deploy user's key pair |
| `VANDERBILT_KNOWN_HOSTS` | secret | The droplet's SSH host key line(s), so the runner can check it's talking to the real server |
| `ALEXANDRIA_HOST` | variable | The new server's hostname or IP |
| `ALEXANDRIA_DEPLOY_USER` | variable | `deploy` |
| `ALEXANDRIA_DEPLOY_SSH_KEY` | secret | Private key of the new server's deploy user's key pair |
| `ALEXANDRIA_KNOWN_HOSTS` | secret | The new server's SSH host key line(s) |

Repository secrets and variables (**Settings → Secrets and variables → Actions**), used only by this repository's deploy:

| Name | Kind | Value |
| ---- | ---- | ----- |
| `CF_DNS_API_TOKEN` | secret | Traefik's Cloudflare DNS token, which every deploy writes to `/home/deploy/traefik/.env` ("Traefik — Cloudflare DNS token" in 1Password; see [Certificates](#certificates)) |
| `INDY_CENTER_BACKUP_RUNNER_ACCESS_KEY_ID` | secret | Access Key ID of the R2 token ("Backups — R2 runner key" in 1Password) |
| `INDY_CENTER_BACKUP_RUNNER_SECRET_ACCESS_KEY` | secret | Secret Access Key of the same token |
| `INDY_CENTER_BACKUP_RUNNER_AGE_KEY` | secret | The age key: its `AGE-SECRET-KEY-1…` line, with or without the comment lines age-keygen writes above it ("Backups — age encryption key" in 1Password) |
| `INDY_CENTER_BACKUP_RUNNER_REPORT_WEBHOOK` | secret | URL of Discord webhook "Backups" (1Password) |
| `INDY_CENTER_BACKUP_RUNNER_ALERT_WEBHOOK` | secret | URL of Discord webhook "Backup alerts" (1Password) |
| `CLOUDFLARE_ACCOUNT_ID` | variable | Cloudflare account ID, the first part of the R2 endpoint (`https://<id>.r2.cloudflarestorage.com`) |

The host and user are variables because neither is secret, and GitHub masks a secret's value everywhere it appears in logs. As a secret, `deploy` turned every `deploy/` path in every app's logs into `***/`.

A change to `traefik/traefik.yml` or `traefik/docker-compose.yml` recreates the Traefik container, and every app behind it is briefly unreachable. Changes under `traefik/dynamic/` are picked up live.

## Disclaimer

We are not affiliated with the FAA or any aviation governing body. This software is for flight simulation use on the [VATSIM](https://www.vatsim.net) network.
