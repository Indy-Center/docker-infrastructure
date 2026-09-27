# docker-infrastructure

The Traefik reverse proxy for the Vanderbelt VPS. It terminates TLS for `*.flyindycenter.com` and routes traffic to every app container on the box. GitHub Actions deploys it to `/opt/traefik/` on push to `main`.

[![Build and Deploy](https://github.com/Indy-Center/docker-infrastructure/actions/workflows/build-and-deploy.yml/badge.svg)](https://github.com/Indy-Center/docker-infrastructure/actions/workflows/build-and-deploy.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

This repository holds Traefik and nothing else. Each app has its own repository, its own `ci.yml` / `build-and-deploy.yml`, and its own `docker-compose.yml` under `/opt/apps/<app>/`. It joins Traefik over a shared Docker network.

## Project layout

- `traefik/`: everything deployed to `/opt/traefik/` on the VPS, and nothing else.
  - `docker-compose.yml`: the Traefik service. Publishes `:80` and `:443`, joins `traefik-shared`, and keeps issued certificates in the `acme` volume.
  - `traefik.yml`: static config, meaning the entrypoints (`web` redirects to `websecure`), the `letsencrypt` DNS-01 resolver and the Docker and file providers.
  - `dynamic/`: file-provider config. Traefik watches it, so changes apply without a restart. `tls.yml` requests the wildcard certificate, and `dashboard.yml` routes the dashboard.
- `examples/app/`: what an app's own repository copies to run behind Traefik.
- `staging/`: a throwaway Traefik against Let's Encrypt staging, used by `staging.yml` to prove certificate issuance. Never deployed.
- `.github/workflows/ci.yml`: starts Traefik against the config and checks the container stays up.
- `.github/workflows/build-and-deploy.yml`: runs CI, then rsyncs `traefik/` to `/opt/traefik/` and runs `docker compose up -d` over SSH.

## Certificates

Traefik requests one wildcard certificate, `flyindycenter.com` + `*.flyindycenter.com`, from Let's Encrypt using the DNS-01 challenge through Cloudflare, and serves it as the default certificate. Apps don't request their own. `tls=true` on a router is enough.

The Cloudflare token (`CF_DNS_API_TOKEN`) is a runtime secret. It lives in `/opt/traefik/.env` on the VPS, and Traefik reads it at every renewal. It never appears in this repository or in GitHub Actions. The token is scoped to Zone:DNS:Edit on the one zone and locked to the VPS's IP.

## Adding an app

Only containers labelled `traefik.enable=true` are routed (`exposedByDefault: false`). An app's `docker-compose.yml` joins the shared network and labels its web service. [`examples/app/docker-compose.yml`](examples/app/docker-compose.yml) is the full version:

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
| `/opt/traefik/` | `deploy` | This repository's deployed config, plus `.env` (not in git) |
| `/opt/apps/<app>/` | `deploy` | One directory per app, deployed by that app's workflow |
| `/opt/backups/<app>/` | `deploy` | Staging area for that app's nightly backup before upload |

Docker network `traefik-shared` is created once, by hand (`docker network create traefik-shared`). Every compose project, this one included, treats it as `external: true`.

Traefik also joins `frontend`, the network the previous Traefik used, so apps not yet moved to `traefik-shared` stay reachable after cutover. Once nothing is left on `frontend` (DEV-170), it comes out of `traefik/docker-compose.yml`.

## Dashboard

The dashboard is read-only and listens on the VPS's loopback address only, never on a public port. To open it, tunnel over SSH:

```bash
ssh -L 8080:localhost:8080 <user>@<vps>
# then browse to http://localhost:8080/dashboard/
```

Backups go to the Cloudflare R2 bucket `vanderbelt-backups`, one prefix per app, with a 60-day lifecycle. rclone's R2 credentials live in the `deploy` user's rclone config on the VPS, not in GitHub.

## Deployment

`build-and-deploy.yml` calls `ci.yml` first and only deploys if it passes. It rsyncs `traefik/` into `/opt/traefik/`, deleting files removed from the repo but never `.env`. Then it runs `docker compose up -d` over SSH and checks the container is still up 15 seconds later. `main` is protected, so changes go through a pull request with passing checks.

For now it only runs when triggered by hand (**Actions → Build and Deploy → Run workflow**). Push-to-`main` deploys get switched on after the first cutover from the old Traefik (DEV-166).

`ci.yml` runs on every pull request. It starts Traefik and the example app on a runner, then checks that Traefik stays up, loads `dynamic/`, redirects HTTP to HTTPS and routes the example app. The runner has no Cloudflare token, so its certificate request fails against Let's Encrypt staging. That's expected.

`staging.yml` (**Actions → Staging certificate check**) runs the real pipeline without touching production. It uses the same secrets, SSH, rsync and `docker compose`, plus the real Cloudflare token. It starts a throwaway Traefik from `staging/` in `~/traefik-staging/` on the VPS, on `127.0.0.1:8443`. That Traefik asks Let's Encrypt **staging** for the wildcard using production's own `dynamic/tls.yml`, and the run passes once it serves a certificate covering `*.flyindycenter.com`. It then removes the container, volume and directory. Run it before any change to certificate settings.

Repository secrets:

| Secret | Value |
| ------ | ----- |
| `VPS_HOST` | VPS hostname or IP |
| `VPS_DEPLOY_USER` | `deploy` |
| `VPS_DEPLOY_SSH_KEY` | Private key of the deploy user's key pair |
| `VPS_KNOWN_HOSTS` | The VPS's SSH host key line(s), so the runner can check it's talking to the real VPS |

A change to `traefik/traefik.yml` or `traefik/docker-compose.yml` recreates the Traefik container, and every app behind it is briefly unreachable. Changes under `traefik/dynamic/` are picked up live.

## Disclaimer

We are not affiliated with the FAA or any aviation governing body. This software is for flight simulation use on the [VATSIM](https://www.vatsim.net) network.
