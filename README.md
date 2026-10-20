# docker-infrastructure

The Traefik reverse proxy for the Vanderbilt VPS. It terminates TLS for `*.flyindycenter.com` and routes traffic to every app container on the box. GitHub Actions deploys it to `/home/deploy/traefik/` on push to `main`.

[![Build and Deploy](https://github.com/Indy-Center/docker-infrastructure/actions/workflows/build-and-deploy.yml/badge.svg)](https://github.com/Indy-Center/docker-infrastructure/actions/workflows/build-and-deploy.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

This repository holds Traefik and nothing else. Each app has its own repository, its own `ci.yml` / `build-and-deploy.yml`, and its own `docker-compose.yml` under `/home/deploy/apps/<app>/`. It joins Traefik over a shared Docker network.

## Project layout

- `traefik/`: everything deployed to `/home/deploy/traefik/` on the VPS, and nothing else.
  - `docker-compose.yml`: the Traefik service. Publishes `:80` and `:443`, joins `traefik-shared`, and keeps issued certificates in the `acme` volume.
  - `traefik.yml`: static config, meaning the entrypoints (`web` redirects to `websecure`), the `letsencrypt` DNS-01 resolver and the Docker and file providers.
  - `dynamic/`: file-provider config. Traefik watches it, so changes apply without a restart. `tls.yml` requests the wildcard certificate, and `dashboard.yml` routes the dashboard.
- `examples/app/`: what an app's own repository copies to run behind Traefik: `deploy/docker-compose.yml` (what lands in `~/apps/<app>/`) and `.github/workflows/` (CI and deploy over SSH). GitHub only runs workflows from the repository root, so these never run here.
- `staging/`: a throwaway Traefik against Let's Encrypt staging, used by `staging.yml` to prove certificate issuance. Never deployed.
- `.github/workflows/ci.yml`: starts Traefik against the config and checks the container stays up.
- `.github/workflows/build-and-deploy.yml`: runs CI, then rsyncs `traefik/` to `/home/deploy/traefik/` and runs `docker compose up -d` over SSH.

## Certificates

Traefik requests one wildcard certificate, `flyindycenter.com` + `*.flyindycenter.com`, from Let's Encrypt using the DNS-01 challenge through Cloudflare, and serves it as the default certificate. Apps don't request their own. `tls=true` on a router is enough.

The Cloudflare token (`CF_DNS_API_TOKEN`) is a runtime secret. It lives in `/home/deploy/traefik/.env` on the VPS, and Traefik reads it at every renewal. It never appears in this repository or in GitHub Actions. The token is scoped to Zone:DNS:Edit on the one zone and locked to the VPS's IP.

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

## VPS layout

| Path | Owner | Purpose |
| ---- | ----- | ------- |
| `/home/deploy/traefik/` | `deploy` | This repository's deployed config, plus `.env` (not in git) |
| `/home/deploy/apps/<app>/` | `deploy` | One directory per app, deployed by that app's workflow |
| `/home/deploy/backups/<app>/` | `deploy` | Staging area for that app's nightly backup before upload |

Everything lives under the deploy user's home folder because Docker on this VPS is the Canonical snap. Snap confinement stops both the `docker` CLI and the daemon from reading paths such as `/opt`, but allows non-hidden paths under `/home`. The snap's automatic updates would restart every container, so they are held (`snap refresh --hold docker`). Update Docker by hand in a quiet period with `snap refresh docker`.

Docker network `traefik-shared` is created once, by hand (`docker network create traefik-shared`). Every compose project, this one included, treats it as `external: true`.

Traefik also joins `frontend`, the network the previous Traefik used, so apps not yet moved to `traefik-shared` stay reachable after cutover. Once nothing is left on `frontend` (DEV-170), it comes out of `traefik/docker-compose.yml`.

## Dashboard

The dashboard is read-only and listens on the VPS's loopback address only, never on a public port. To open it, tunnel over SSH:

```bash
ssh -L 8080:localhost:8080 <user>@<vps>
# then browse to http://localhost:8080/dashboard/
```

## Backups

Backups go to the Cloudflare R2 bucket `indy-center-backups`. The deploy writes the backup runner's rclone config to `/home/deploy/backup-runner/secrets/rclone.conf` (folder mode 700, file mode 600), with one remote, `r2`. The keys come from this repository's secrets (below), so a rebuilt VPS gets them back from one deploy. To use that config by hand:

```bash
RCLONE_CONFIG=~/backup-runner/secrets/rclone.conf rclone lsd r2:indy-center-backups
```

The key can write to `indy-center-backups` and read the CMS media buckets, but cannot create or delete buckets. To rotate it, make a new R2 token, update both secrets, and run **Build and Deploy** by hand.

The deploy also writes the runner's other secrets to the same folder, each mode 600:

| File | What it is |
| ---- | ---------- |
| `age.key` | The age key that encrypts every backup and decrypts it for a restore. Its source copy is "Backup encryption key (age)" in 1Password: without it, every backup is unreadable |
| `report-webhook.url` | Discord webhook "Backups" in tech-team-notifications, for the daily backup report |
| `alert-webhook.url` | Discord webhook "Backup alerts" in tech-team-alerts |

Never rotate the age key by replacing it: backups made with the old key need the old key to restore.

## Deployment

`build-and-deploy.yml` calls `ci.yml` first and only deploys if it passes. It rsyncs `traefik/` into `/home/deploy/traefik/`, deleting files removed from the repo but never `.env`. Then it runs `docker compose up -d` over SSH and checks the container is still up 15 seconds later. `main` is protected, so changes go through a pull request with passing checks.

It runs on every push to `main`, and by hand from **Actions → Build and Deploy → Run workflow** (for example, to redeploy without a change).

`ci.yml` runs on every pull request. It starts Traefik and the example app on a runner, then checks that Traefik stays up, loads `dynamic/`, redirects HTTP to HTTPS and routes the example app. The runner has no Cloudflare token, so its certificate request fails against Let's Encrypt staging. That's expected.

`staging.yml` (**Actions → Staging certificate check**) runs the real pipeline without touching production. It uses the same secrets, SSH, rsync and `docker compose`, plus the real Cloudflare token. It starts a throwaway Traefik from `staging/` in `~/traefik-staging/` on the VPS, on `127.0.0.1:8443`. That Traefik asks Let's Encrypt **staging** for the wildcard using production's own `dynamic/tls.yml`, and the run passes once it serves a certificate covering `*.flyindycenter.com`. It then removes the container, volume and directory. Run it before any change to certificate settings.

Organization secrets and variables (**Org Settings → Secrets and variables → Actions**). Access to each is limited to **Selected repositories**: this one, plus each app repository as it moves onto the pipeline. The deploy key can do anything `deploy` can, and `deploy` is in the docker group.

| Name | Kind | Value |
| ---- | ---- | ----- |
| `VANDERBILT_HOST` | variable | VPS hostname or IP |
| `VANDERBILT_DEPLOY_USER` | variable | `deploy` |
| `VANDERBILT_DEPLOY_SSH_KEY` | secret | Private key of the deploy user's key pair |
| `VANDERBILT_KNOWN_HOSTS` | secret | The VPS's SSH host key line(s), so the runner can check it's talking to the real VPS |

Repository secrets and variables (**Settings → Secrets and variables → Actions**), used only by this repository's deploy:

| Name | Kind | Value |
| ---- | ---- | ----- |
| `INDY_CENTER_BACKUP_RUNNER_ACCESS_KEY_ID` | secret | Access Key ID of the "R2 backup runner" token (1Password) |
| `INDY_CENTER_BACKUP_RUNNER_SECRET_ACCESS_KEY` | secret | Secret Access Key of the same token |
| `INDY_CENTER_BACKUP_RUNNER_AGE_KEY` | secret | The age key: its `AGE-SECRET-KEY-1…` line, with or without the comment lines age-keygen writes above it ("Backup encryption key (age)" in 1Password) |
| `INDY_CENTER_BACKUP_RUNNER_REPORT_WEBHOOK` | secret | URL of Discord webhook "Backups" (1Password) |
| `INDY_CENTER_BACKUP_RUNNER_ALERT_WEBHOOK` | secret | URL of Discord webhook "Backup alerts" (1Password) |
| `CLOUDFLARE_ACCOUNT_ID` | variable | Cloudflare account ID, the first part of the R2 endpoint (`https://<id>.r2.cloudflarestorage.com`) |

The host and user are variables because neither is secret, and GitHub masks a secret's value everywhere it appears in logs. As a secret, `deploy` turned every `deploy/` path in every app's logs into `***/`.

A change to `traefik/traefik.yml` or `traefik/docker-compose.yml` recreates the Traefik container, and every app behind it is briefly unreachable. Changes under `traefik/dynamic/` are picked up live.

## Disclaimer

We are not affiliated with the FAA or any aviation governing body. This software is for flight simulation use on the [VATSIM](https://www.vatsim.net) network.
