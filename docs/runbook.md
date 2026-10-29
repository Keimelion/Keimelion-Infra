# Runbook — Keimelion server

## Setup from scratch

Follow the README "Initial setup". Run `scripts/setup-data-dirs.sh` (with `sudo` if `data/` already exists and is owned by root) before the first `docker compose up`.

## Start / stop the stack

## Check the logs

## Deploy a new version

## Database migrations

## Seeding the database

Dev/test data only, never in production. The API image does not ship `src/db/seed`, so run the compiled seed in a one-off container with the fixtures mounted read-only (seeders are idempotent):

```bash
docker compose run --rm --no-deps \
  -v ../Keimelion-API/src/db/seed/fixtures:/app/src/db/seed/fixtures:ro \
  api node dist/db/seed/index.js
```

## Postgres backup

## Postgres restore

Disaster recovery on a fresh machine: run `scripts/setup-data-dirs.sh` before starting the stack, then restore the dump.

## Secret rotation

## Reboot and post-reboot checks

## Known incidents

## NEXT_PUBLIC_API_URL is baked in at build time

`NEXT_PUBLIC_API_URL` is inlined into the back-office bundle at build time. Changing domain (e.g. moving to `api.keimelion.app` in production) requires rebuilding the `back` image with the new URL as a build argument.

## Landing language redirect

The redirect to `/en/` based on the browser language (defined in `vercel.json`) is not active in the Docker image. Port it to the Caddyfile when exposing to the internet.

## Networking & firewall

- Docker publishes ports through its own iptables rules (NAT + `FORWARD` chain, filterable only in `DOCKER-USER`), not through `INPUT`: **UFW rules do not apply to published ports**.
- Debug ports (api 3000, back 3001, landing 3002, postgres 5432) are deliberately bound to `127.0.0.1`: reach them through an SSH tunnel from a dev workstation.
- Caddy on `:80` is the only LAN entry point, with hostname-based routing (see "Access from a LAN client"). Note: UFW is currently **inactive** (a `80/tcp` rule exists but is not enforced).
- Protection from the internet currently relies only on the router NAT (no port forwarding). The exposure ticket must address it (`ufw-docker` or binding to the LAN IP).

## Access from a LAN client

Add this line to `/etc/hosts` on each client machine:

```
192.168.1.102   keimelion.local admin.keimelion.local api.keimelion.local
```

- Landing: http://keimelion.local
- Back-office: http://admin.keimelion.local
- API: http://api.keimelion.local (uploads under `/uploads/*`)

Hitting http://192.168.1.102 directly redirects (301) to http://keimelion.local. For production, switch `.local` to `.app` in the Caddyfile and `.env` (and rebuild `back`).

## Accessing the DB from a dev workstation

The DB is not routed through Caddy. Postgres only listens on the server's `127.0.0.1:5432`: open an SSH tunnel (`ssh -L 5433:localhost:5432 milky-way -N`), then connect to `postgres://keimelion:<POSTGRES_PASSWORD>@localhost:5433/keimelion`. The tunnel is authenticated by your SSH key: no need to open 5432 on the firewall.
