# Runbook — Keimelion server

## Setup from scratch

Follow the README "Initial setup". Run `scripts/setup-data-dirs.sh` (with `sudo` if `data/` already exists and is owned by root) before the first `docker compose up`.

## Start / stop the stack

```bash
cd ~/keimelion/Keimelion-Infra
docker compose up -d           # start everything
docker compose down            # stop (containers + network, keeps volumes)
docker compose restart caddy   # restart one service
docker compose ps              # see what's running
```

Services use `restart: unless-stopped` and Docker is enabled at boot: a reboot
brings everything back up.

## Check the logs

```bash
docker compose logs -f api            # follow one service
docker compose logs --tail=200 caddy  # last 200 lines (includes access logs
                                      # for *.keimelion.zalbani.dev, see Caddyfile)
docker compose logs                   # everything, from the beginning
```

Caddy writes an access log for each public hostname (the `log` directive in
`caddy/Caddyfile`). Lines look like `host="keimelion.zalbani.dev" status=200
remote_ip=192.168.1.100 …`, where `remote_ip` is the NAS reverse-proxy
address (TLS was terminated upstream).

## Deploy a new version

Automatic: a push to `dev` with a green CI run deploys it to the pre-prod
(health check + rollback, see "Deploy, migrations & rollback" below). A green `Release` on
`main` deploys it to the production ("Production stack" below). See
[release-process.md](release-process.md).
Manual redeploy: run the repo's `Deploy` workflow from GitHub, choosing the stack.

Fallback without CI (runner down):

```bash
cd ~/keimelion
git -C Keimelion-API checkout dev && git -C Keimelion-API pull --ff-only   # every app repo tracks dev on the server
cd Keimelion-Infra
docker compose up -d --build api  # or back / landing / caddy
```

Infra changes (compose, Caddyfile) are applied automatically after a merge on `main`
by `deploy-infra.yml` (pull, `docker compose up -d --no-build`, Caddy reload, health
check, rollback). Never edit tracked files directly on the server: the workflow refuses
to run until they are committed or discarded.

Manual reload of Caddy after editing `caddy/Caddyfile` **without** restarting the
container (zero downtime):

```bash
docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile
```

The whole `caddy/` folder is bind-mounted (not just the file), so edits land
in the container through the host, and `caddy reload` picks them up.

## Deploy, migrations & rollback

`deploy.yml` (steps in `scripts/deploy/app-deploy.sh`). For the API:

1. **Pull & build** — the running image is tagged `keimelion-api:previous` first (instant
   rollback, no rebuild), then the new one is built. The old container keeps serving.
2. **Pre-deploy backup** — `keimelion-db-backup@pre-deploy-api`: restic snapshot, its ID
   recorded in `/var/backups/keimelion/last-pre-deploy-api`. No snapshot, no deploy.
3. **Migrate** — `docker compose run --rm api npm run db:migrate` with the **new** image,
   **while the old API still serves**. Drizzle applies all pending migrations in one
   transaction: a failing migration leaves the schema untouched.
4. **Deploy** — `up -d api` (its own `db:migrate` on start is a no-op).
5. **Health check** — `/health` (waited for, ~90 s), then smoke tests reading real tables
   (`/v1/categories`, `/v1/occasion-types`): `/health` alone only runs `SELECT 1`.
6. **Rollback on failure** — previous commit + `:previous` image, health + smoke tests
   again. If the previous release is unhealthy **and** this deploy migrated the schema:
   `keimelion-db-restore@pre-deploy-api` restores the step-2 snapshot (after a
   `pre-restore` snapshot of the broken state), then checks again.

| What goes wrong | Outcome | Downtime |
|---|---|---|
| A migration fails | job red with the SQL error, schema unchanged, old API never stopped | none |
| Migrations OK, new release fails health/smoke | previous image back, schema kept (backward compatible) | until the health check gives up (~90 s) + a few s |
| …and the previous release fails on the new schema | + restore of the pre-deploy snapshot | + ~10 s; **writes since the snapshot are lost** (the API was broken meanwhile) |
| Still unhealthy after all that | job red "manual intervention needed" | until fixed |

All three were rehearsed with trap migrations on a throwaway compose project (PR #15).
After an automatic restore, the broken state is kept twice for the post-mortem:
`pre-restore` snapshot and database `keimelion_pre_restore_<ts>` (drop it once analysed).

**Rule for migrations: the previous release must still work on the new schema**
(expand/contract). Add a column/table in release N, start using it, drop the old one in
N+1; never rename in place. With it, a rollback never needs the restore. The restore is
the safety net when the rule is broken. Statements that cannot run in a transaction
(`CREATE INDEX CONCURRENTLY`…) are not supported by this flow.

The smoke tests only see what those endpoints read. A release broken on another table is
caught by the next layers only (Kuma, users).

## Seeding the database

Dev/test data only, never in production. The API image does not ship `src/db/seed`, so run the compiled seed in a one-off container with the fixtures mounted read-only (seeders are idempotent):

```bash
docker compose run --rm --no-deps \
  -v ../Keimelion-API/src/db/seed/fixtures:/app/src/db/seed/fixtures:ro \
  api node dist/db/seed/index.js
```

## Postgres major upgrade

A major version cannot read the previous one's files: the upgrade is a dump/restore with
the backup tooling, done through a PR (17 → 18 was #14 — `data/postgres`, the 17 cluster,
is kept until the new one is trusted).

1. PR: new `image:` tag (+ mount path if the image changed its layout). Before merging,
   rehearse on a throwaway compose project with the new image: `db-restore.sh` of the
   latest snapshot into it (`KEIMELION_INFRA_DIR=<rehearsal dir>`), API health check.
2. Merge: `deploy-infra` takes the `pre-deploy` snapshot (old major), starts the new
   major on an empty data dir; the API creates an empty schema, health checks pass.
3. Restore the data right away (the safety backup would only save the empty base):
   ```bash
   restic -r /var/backups/keimelion/restic snapshots --tag pre-deploy --latest 1   # its ID
   scripts/backup/db-restore.sh --snapshot <ID> --skip-safety-backup
   docker compose exec postgres dropdb -U keimelion keimelion_pre_restore_<timestamp>   # the empty base
   ```
4. Run the restore test (`sudo systemctl start --wait keimelion-backup-verify`).
5. Rollback: revert the PR — the old cluster comes back from its untouched data dir
   (minus the writes made since the upgrade). Once confident, delete it
   (`sudo rm -rf data/postgres`).

## Postgres backup

Automatic (restic, every 6 h + before every deploy, copied to the NAS, restore-tested
weekly). Details, alerting and setup: [backup.md](backup.md).

```bash
systemctl list-timers 'keimelion-*'
sudo systemctl start --wait keimelion-db-backup@manual   # backup now
journalctl -u 'keimelion-*' -n 50
```

## Postgres restore

`scripts/backup/db-restore.sh [--snapshot ID] [--from offsite]`: restores next to the live
database, validates it, then swaps (the previous database is kept). Scenarios — bad
migration, a few rows, server lost — in [backup.md](backup.md#restore).

## Secret rotation

Secrets live in the server's `.env`, which is not in git, so the deploy workflows never
change it. To change a value, for example `EMAIL_API_KEY`:

```bash
ssh milky-way
cd ~/keimelion/Keimelion-Infra
nano .env
docker compose up -d api   # recreates the service with the new value
```

Replace `api` with every service that reads the changed value. Never paste a secret into
a ticket, a commit or a log.

## Production stack

`keimelion.app` runs on the same server, next to the pre-prod and isolated from it:

| | Pre-prod | Production |
|---|---|---|
| Branch | `dev` | `main` |
| Checkouts | `~/keimelion` (runner's path) | `/home/zalbani/keimelion-prod` |
| Compose project | `keimelion` | `keimelion-prod` (`COMPOSE_PROJECT_NAME` in `.env`) |
| Caddy | `:80`, `caddy/` | `:8080`, `caddy-prod/` |
| Debug ports (API, back, landing, Postgres) | 3000, 3001, 3002, 5432 | 3100, 3101, 3102, 5433 |
| Units | `keimelion-*` | `keimelion-prod-*` |
| Backups | `/var/backups/keimelion`, `restic` on the NAS | `/var/backups/keimelion-prod`, `restic-prod` on the NAS |

Setup: the README "Initial setup" in `/home/zalbani/keimelion-prod`, cloning `main` for every
repo (mode 2775, group `keimelion-stack`), with the variables of the "Production stack only"
block of `.env.example` and new secrets. Then `docs/backup.md` "One-time setup", from that
checkout. An Infra merge on `main` is applied to the pre-prod, then to the production;
the production is skipped while `/home/zalbani/keimelion-prod/Keimelion-Infra/.env` is missing.

## Reboot and post-reboot checks

## Known incidents

## NEXT_PUBLIC_API_URL is baked in at build time

`NEXT_PUBLIC_API_URL` (and the landing's `PUBLIC_API_BASE_URL`) is inlined
into the browser bundle at build time. Changing `PUBLIC_API_URL` in `.env`
requires `docker compose up -d --build back landing` for the new value to
reach the browser.

## Landing language redirect

The redirect to `/en/` based on the browser language (defined in `vercel.json`) is not active in the Docker image. Port it to the Caddyfile when exposing to the internet.

## Networking & firewall

- Docker publishes ports through its own iptables rules (NAT + `FORWARD` chain, filterable only in `DOCKER-USER`), not through `INPUT`: **UFW rules do not apply to published ports**.
- Debug ports (api 3000, back 3001, landing 3002, postgres 5432) are deliberately bound to `127.0.0.1`: reach them through an SSH tunnel from a dev workstation.
- Caddy on `:80` is bound to `0.0.0.0`. It is the only entry point from the LAN **and** from the NAS reverse proxy, routing by `Host` header (see "Cloudflare / NAS exposure" and "Access from a LAN client"). UFW is currently **inactive**.
- The home router forwards `:80` and `:443` to the Synology NAS (`192.168.1.100`), which handles TLS for `*.zalbani.dev`. No port is forwarded directly to milky-way (`192.168.1.102`).

## Client IP behind the NAS

Caddy only sees the NAS (`192.168.1.100`), which appends the visitor's IP to
`X-Forwarded-For`. The Caddyfile trusts that one proxy in strict mode (the client IP is the
right-most address the NAS didn't add, so a forged `X-Forwarded-For` is ignored) and sends
the API `X-Forwarded-For: <client IP>` alone, which is what its rate limiter keys on.
If the NAS IP changes, update `trusted_proxies` or every visitor shares one rate-limit bucket
again. Check: `docker compose logs caddy | grep -o '"client_ip":"[^"]*"' | sort | uniq -c`.

## Container logs

Rotated by Docker: 3 files of 10 MB per service (`x-logging` in `docker-compose.yml`),
so `docker compose logs` covers the recent past only. Older access logs are gone by design.

## Cloudflare / NAS exposure

The public hostnames follow the same rail as `ha.zalbani.dev` and
`seerr.zalbani.dev` — no Cloudflare Tunnel, no local ACME. Managed outside
this repo (dashboard, not Git) because the setup predates the project:

1. **Cloudflare DNS** (`zalbani.dev` zone, Cloudflare-managed nameservers):
   three `DNS only` CNAMEs → `backward.zalbani.dev` (A record pointing to the
   home public IP, kept fresh by the Home Assistant Cloudflare DDNS plugin).
   | Record                        | Target                 |
   |-------------------------------|------------------------|
   | keimelion.zalbani.dev         | backward.zalbani.dev   |
   | admin.keimelion.zalbani.dev   | backward.zalbani.dev   |
   | api.keimelion.zalbani.dev     | backward.zalbani.dev   |

2. **Home router port forwards**: `80/tcp` and `443/tcp` → `192.168.1.100` (NAS).

3. **Synology DSM → Control Panel → Login Portal → Advanced → Reverse Proxy**:
   three entries, all HTTPS :443 (source) → HTTP `192.168.1.102:80` (destination,
   milky-way LAN IP). "Create → WebSocket" preset enabled so `Upgrade` /
   `Connection` headers pass through. DSM preserves the original `Host`
   header (nginx `proxy_set_header Host $host`), which lets Caddy dispatch.

4. **Synology DSM → Control Panel → Security → Certificate**: one Let's
   Encrypt certificate per public hostname (HTTP-01 challenge, served by DSM
   on :80). Each cert is assigned to its reverse-proxy service in
   `Certificate → Settings`.

Rolling out a new public hostname is three steps outside this repo (CNAME +
reverse-proxy entry + cert) and one block in `caddy/Caddyfile` + `up -d
caddy` + `caddy reload`.

## Access from a LAN client

The stack is reachable in two ways from the LAN:

- Through the public hostnames, if the home router does NAT loopback
  (hairpin): https://keimelion.zalbani.dev etc. resolve via Cloudflare and
  bounce back inside. This has been verified on the current router.
- Plain-HTTP LAN fallback (useful for low-level debug, or when the NAS
  reverse proxy is down). Add this line to `/etc/hosts` on each client:
  ```
  192.168.1.102   keimelion.local admin.keimelion.local api.keimelion.local
  ```
  Then: http://keimelion.local, http://admin.keimelion.local,
  http://api.keimelion.local. http://192.168.1.102 redirects to the landing.
  Caveat: the front-end bundles call `https://api.keimelion.zalbani.dev`
  (baked at build time), and the API's CORS allow-list does not include the
  `.local` origins, so opening a front via `.local` from a browser gives a
  working shell but failing XHR. Use `.local` for curl-level checks only.

## Accessing the DB from a dev workstation

The DB is not routed through Caddy. Postgres only listens on the server's `127.0.0.1:5432`: open an SSH tunnel (`ssh -L 5433:localhost:5432 milky-way -N`), then connect to `postgres://keimelion:<POSTGRES_PASSWORD>@localhost:5433/keimelion`. The tunnel is authenticated by your SSH key: no need to open 5432 on the firewall.
